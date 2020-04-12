
module Language.Edh.Net.Peer where

import           Prelude
-- import           Debug.Trace

import           Control.Exception
import           Control.Monad
import           Control.Monad.Reader
import           Control.Concurrent.STM

import           Data.Hashable
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import qualified Data.HashMap.Strict           as Map
import           Data.Dynamic

import           Language.Edh.EHI


type CmdDir = Text
type CmdSrc = Text
data CommCmd = CommCmd !CmdDir !CmdSrc
  deriving (Eq, Show)
instance Hashable CommCmd where
  hashWithSalt s (CommCmd cmd src) = s `hashWithSalt` cmd `hashWithSalt` src


data Peer = Peer {
      edh'peer'ident :: !Text
    , edh'peer'eol :: !(TMVar (Either SomeException ()))
    , edh'peer'hosting :: !(STM CommCmd)
    , edh'peer'channels :: !(Map.HashMap EdhValue EventSink)
    , postPeerCommand :: !(CommCmd -> STM ())
  }


readPeerCommand :: EdhProgState -> Peer -> EdhProcExit -> STM ()
readPeerCommand !pgs (Peer !ident !eol !ho !chd !po) !exit =
  edhPerformIO pgs
               (atomically $ (Right <$> ho) `orElse` (Left <$> readTMVar eol))
    $ \case
        -- reached normal end-of-stream
        Left (Right _) -> exitEdhSTM pgs exit nil
        -- previously eol due to error
        Left (Left ex) -> toEdhError pgs ex $ \exv -> edhThrowSTM pgs exv
        -- got next command incoming
        Right (CommCmd !dir !src) -> if "err" == dir
          then do
            let !ex = toException $ EdhPeerError ident src
            void $ tryPutTMVar eol $ Left ex
            toEdhError pgs ex $ \exv -> edhThrowSTM pgs exv
          else
            edhCatchSTM pgs (landCmd src dir) exit $ \exv _recover rethrow ->
              if exv == nil -- no exception occurred,
                then rethrow -- rethrow just passes on in this case
                else edhValueReprSTM pgs exv $ \exr -> do
                  -- send peer the error details
                  po $ CommCmd "err" exr
                  -- mark eol with this error
                  fromEdhError pgs exv $ \e -> void $ tryPutTMVar eol $ Left e
                  -- rethrow the error
                  rethrow
 where
  srcName = T.unpack ident
  landCmd :: Text -> Text -> EdhProgState -> EdhProcExit -> STM ()
  landCmd !src !dir !pgs' !exit' =
    runEdhProc pgs' $ evalEdh srcName src $ \cr@(OriginalValue !cmdVal _ _) ->
      if T.null dir
        then exitEdhProc' exit' cr
        else evalEdh srcName dir $ \(OriginalValue !chVal _ _) ->
          case Map.lookup chVal chd of
            Nothing ->
              throwEdh UsageError $ "Missing command channel: " <> T.pack
                (show chVal)
            Just !chSink -> contEdhSTM $ do
              publishEvent chSink cmdVal
              exitEdhSTM pgs' exit' nil

-- | host constructor Peer()
peerCtor
  :: EdhProgState
  -> ArgsPack  -- ctor args, if __init__() is provided, will go there too
  -> TVar (Map.HashMap AttrKey EdhValue)  -- out-of-band attr store
  -> (Dynamic -> STM ())  -- in-band data to be written to entity store
  -> STM ()
peerCtor !pgsCtor _ !obs !ctorExit = do
  let !scope = contextScope $ edh'context pgsCtor
  methods <- sequence
    [ (AttrByName nm, ) <$> mkHostProc scope vc nm hp args
    | (nm, vc, hp, args) <-
      [ ("eol"        , EdhMethod, eolProc        , PackReceiver [])
      , ("join"       , EdhMethod, joinProc       , PackReceiver [])
      , ("stop"       , EdhMethod, stopProc       , PackReceiver [])
      , ("readCommand", EdhMethod, readPeerCmdProc, PackReceiver [])
      , ( "postCommand"
        , EdhMethod
        , postPeerCmdProc
        , PackReceiver
          [ RecvArg "cmd" Nothing Nothing
          , RecvArg "dir" Nothing $ Just $ LitExpr $ StringLiteral ""
          ]
        )
      , ("ident"   , EdhMethod, identProc, PackReceiver [])
      , ("__repr__", EdhMethod, reprProc , PackReceiver [])
      ]
    ]
  modifyTVar' obs $ Map.union $ Map.fromList methods
  -- not really constructable from Edh code, relies on host code to fill
  -- the in-band storage
  ctorExit $ toDyn nil

 where

  eolProc :: EdhProcedure
  eolProc _ !exit = do
    pgs <- ask
    let ctx  = edh'context pgs
        this = thisObject $ contextScope ctx
        es   = entity'store $ objEntity this
    contEdhSTM $ do
      esd <- readTVar es
      case fromDynamic esd :: Maybe Peer of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a peer : " <> T.pack
            (show esd)
        Just !peer -> tryReadTMVar (edh'peer'eol peer) >>= \case
          Nothing         -> exitEdhSTM pgs exit $ EdhBool False
          Just (Left  e ) -> toEdhError pgs e $ \exv -> exitEdhSTM pgs exit exv
          Just (Right ()) -> exitEdhSTM pgs exit $ EdhBool True

  joinProc :: EdhProcedure
  joinProc _ !exit = do
    pgs <- ask
    let ctx  = edh'context pgs
        this = thisObject $ contextScope ctx
        es   = entity'store $ objEntity this
    contEdhSTM $ do
      esd <- readTVar es
      case fromDynamic esd :: Maybe Peer of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a peer : " <> T.pack
            (show esd)
        Just !peer ->
          edhPerformIO pgs (atomically $ readTMVar (edh'peer'eol peer)) $ \case
            Left  e  -> toEdhError pgs e $ \exv -> edhThrowSTM pgs exv
            Right () -> exitEdhSTM pgs exit nil

  stopProc :: EdhProcedure
  stopProc _ !exit = do
    pgs <- ask
    let ctx  = edh'context pgs
        this = thisObject $ contextScope ctx
        es   = entity'store $ objEntity this
    contEdhSTM $ do
      esd <- readTVar es
      case fromDynamic esd :: Maybe Peer of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a peer : " <> T.pack
            (show esd)
        Just !peer -> do
          stopped <- tryPutTMVar (edh'peer'eol peer) $ Right ()
          exitEdhSTM pgs exit $ EdhBool stopped


  readPeerCmdProc :: EdhProcedure
  readPeerCmdProc _ !exit = do
    pgs <- ask
    let this = thisObject $ contextScope $ edh'context pgs
        es   = entity'store $ objEntity this
    contEdhSTM $ do
      esd <- readTVar es
      case fromDynamic esd of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a peer : " <> T.pack
            (show esd)
        Just (peer :: Peer) -> readPeerCommand pgs peer exit

  postPeerCmdProc :: EdhProcedure
  postPeerCmdProc !apk !exit = do
    pgs <- ask
    let
      this = thisObject $ contextScope $ edh'context pgs
      es   = entity'store $ objEntity this
      postCmd' :: Text -> EdhValue -> STM ()
      postCmd' !cmd !dirVal = case dirVal of
        EdhNil -> postCmd cmd ""
        _ ->
          runEdhProc pgs
            $ edhValueRepr dirVal
            $ \(OriginalValue dirRepr _ _) -> case dirRepr of
                EdhString !dir -> contEdhSTM $ postCmd cmd dir
                _              -> error "bug: edhValueRepr returned non-string"
      postCmd :: Text -> Text -> STM ()
      postCmd !cmd !dir = do
        esd <- readTVar es
        case fromDynamic esd of
          Nothing ->
            throwEdhSTM pgs UsageError $ "bug: this is not a peer : " <> T.pack
              (show esd)
          Just (peer :: Peer) -> do
            postPeerCommand peer $ CommCmd dir cmd
            exitEdhSTM pgs exit nil
    case parseArgsPack (Nothing, nil) parseArgs apk of
      Left  err                -> throwEdh UsageError err
      Right (maybeCmd, dirVal) -> case maybeCmd of
        Nothing                -> throwEdh UsageError "missing command"
        Just (EdhString src  ) -> contEdhSTM $ postCmd' src dirVal
        Just (EdhExpr _ _ src) -> if src == ""
          then throwEdh UsageError "missing source for the expr as command"
          else contEdhSTM $ postCmd' src dirVal
        Just cmdVal ->
          throwEdh UsageError $ "Unsupported command type: " <> T.pack
            (edhTypeNameOf cmdVal)
   where
    parseArgs =
      ArgsPackParser
          [ \arg (_, dir') -> Right (Just arg, dir')
          , \arg (cmd', _) -> Right (cmd', arg)
          ]
        $ Map.fromList
            [ ("cmd", \arg (_, dir') -> Right (Just arg, dir'))
            , ("dir", \arg (cmd', _) -> Right (cmd', arg))
            ]

  identProc :: EdhProcedure
  identProc _ !exit = do
    pgs <- ask
    let this = thisObject $ contextScope $ edh'context pgs
        es   = entity'store $ objEntity this
    contEdhSTM $ do
      esd <- readTVar es
      case fromDynamic esd of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a peer : " <> T.pack
            (show esd)
        Just (peer :: Peer) ->
          exitEdhSTM pgs exit $ EdhString $ edh'peer'ident peer

  reprProc :: EdhProcedure
  reprProc _ !exit = do
    pgs <- ask
    let this = thisObject $ contextScope $ edh'context pgs
        es   = entity'store $ objEntity this
    contEdhSTM $ do
      esd <- readTVar es
      case fromDynamic esd of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a peer : " <> T.pack
            (show esd)
        Just (peer :: Peer) ->
          exitEdhSTM pgs exit
            $  EdhString
            $  "peer:<"
            <> edh'peer'ident peer
            <> ">"

