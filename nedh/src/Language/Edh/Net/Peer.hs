
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
    , postPeerCommand :: !(CommCmd -> STM ())
  }


readPeerCommand :: Peer -> EdhProcExit -> EdhProc
readPeerCommand (Peer !ident !eol !ho !po) !exit = ask >>= \pgs ->
  contEdhSTM
    $ edhPerformIO
        pgs
        (atomically $ (Right <$> ho) `orElse` (Left <$> readTMVar eol))
    $ \case
        -- reached normal end-of-stream
        Left (Right _) -> exitEdhSTM pgs exit nil
        -- previously eol due to error
        Left (Left ex) -> toEdhError pgs ex $ \exv -> edhThrowSTM pgs exv
        -- got next command incoming
        Right (CommCmd !dir !src) -> case dir of
          "" ->
            runEdhProc pgs
              $ edhCatch (evalEdh (T.unpack ident) src) exit
              $ \_recover rethrow -> do
                  pgsPassOn <- ask
                  let !exv = contextMatch $ edh'context pgsPassOn
                  if exv == nil -- no exception occurred,
                    then rethrow -- rethrow just passes on in this case
                    else contEdhSTM $ edhValueReprSTM pgs exv $ \exr -> do
                      -- send peer the error details
                      po $ CommCmd "err" exr
                      -- mark eol with this error
                      fromEdhError pgs exv
                        $ \e -> void $ tryPutTMVar eol $ Left e
                      -- rethrow the error
                      runEdhProc pgs rethrow
          "err" -> do
            let !ex = toException $ EdhPeerError ident src
            void $ tryPutTMVar eol $ Left ex
            toEdhError pgs ex $ \exv -> edhThrowSTM pgs exv

          -- TODO ways to direct to manifested event sinks

          _ ->
            createEdhError pgs UsageError ("invalid packet directive: " <> dir)
              $ \exv ex -> do
                  void $ tryPutTMVar eol $ Left $ toException ex
                  edhThrowSTM pgs exv


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
        Just (peer :: Peer) -> runEdhProc pgs $ readPeerCommand peer exit

  postPeerCmdProc :: EdhProcedure
  postPeerCmdProc !apk !exit = do
    pgs <- ask
    let
      this = thisObject $ contextScope $ edh'context pgs
      es   = entity'store $ objEntity this
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
    case parseArgsPack (Nothing, "") parseArgs apk of
      Left  err             -> throwEdh UsageError err
      Right (maybeCmd, dir) -> case maybeCmd of
        Nothing                -> throwEdh UsageError "missing command"
        Just (EdhString src  ) -> contEdhSTM $ postCmd src dir
        Just (EdhExpr _ _ src) -> if src == ""
          then throwEdh UsageError "missing source for the expr as command"
          else contEdhSTM $ postCmd src dir
        Just cmdVal ->
          throwEdh UsageError $ "Unsupported command type: " <> T.pack
            (edhTypeNameOf cmdVal)
   where
    parseArgs =
      ArgsPackParser
          [ \arg (_, dir') -> Right (Just arg, dir')
          , \arg (cmd', _) -> case arg of
            EdhString dir -> Right (cmd', dir)
            _             -> Left "Invalid dir"
          ]
        $ Map.fromList
            [ ("cmd", \arg (_, dir') -> Right (Just arg, dir'))
            , ( "dir"
              , \arg (cmd', _) -> case arg of
                EdhString dir -> Right (cmd', dir)
                _             -> Left "Invalid dir"
              )
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

