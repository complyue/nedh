
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
    , edh'peer'channels :: !(TVar (Map.HashMap EdhValue EventSink))
      -- todo this ever needs to be in CPS?
    , postPeerCommand :: !(CommCmd -> STM ())
  }


-- | Read next command from peer
--
-- Note a command may target a specific channel, thus get posted to that 
--      channel's sink, and nil will be returned by this procedure for it.
readPeerCommand :: EdhProgState -> Peer -> EdhProcExit -> STM ()
readPeerCommand !pgs (Peer !ident !eol !ho !chdVar !po) !exit =
  edhPerformIO pgs
               (atomically $ (Right <$> ho) `orElse` (Left <$> readTMVar eol))
    $ \case
        -- reached normal end-of-stream
        Left (Right _) -> exitEdhSTM pgs exit nil
        -- previously eol due to error
        Left (Left ex) -> toEdhError pgs ex $ \exv -> edhThrowSTM pgs exv
        -- got next command incoming
        Right (CommCmd !dir !src) -> if "err" == dir
          then do -- unexpected error occurred at peer site, it has sent the
            -- details back here, mark eol with it at local site, and throw
            let !ex = toException $ EdhPeerError ident src
            void $ tryPutTMVar eol $ Left ex
            toEdhError pgs ex $ \exv -> edhThrowSTM pgs exv
          else -- treat other directives as the expr of the target channel
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
        -- to the default channel, which yields as direct result of 
        --   `peer.readCommand()`
        then exitEdhProc' exit' cr
        -- to a specific channel, which should be located by the directive
        else evalEdh srcName dir $ \(OriginalValue !chLctr _ _) ->
          contEdhSTM $ do
            chd <- readTVar chdVar
            case Map.lookup chLctr chd of
              Nothing ->
                throwEdhSTM pgs UsageError
                  $  "Missing command channel: "
                  <> T.pack (show chLctr)
              Just !chSink -> do
                publishEvent chSink cmdVal -- post the cmd to channel
                -- yield nil as for `peer.readCommand()` wrt this cmd packet
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
      [ ("eol" , EdhMethod, eolProc , PackReceiver [])
      , ("join", EdhMethod, joinProc, PackReceiver [])
      , ("stop", EdhMethod, stopProc, PackReceiver [])
      , ( "armedChannel"
        , EdhMethod
        , armedChannelProc
        , PackReceiver [RecvArg "chLctr" Nothing Nothing]
        )
      , ( "armChannel"
        , EdhMethod
        , armChannelProc
        , PackReceiver
          [ RecvArg "chLctr" Nothing Nothing
          , RecvArg "chSink" Nothing $ Just $ LitExpr SinkCtor
          ]
        )
      , ("readCommand", EdhMethod, readPeerCmdProc, PackReceiver [])
      , ( "postCommand"
        , EdhMethod
        , postPeerCmdProc
        , PackReceiver
          [ RecvArg "cmd" Nothing Nothing
          , RecvArg "dir" Nothing $ Just $ LitExpr NilLiteral
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

  armedChannelProc :: EdhProcedure
  armedChannelProc !apk !exit = do
    pgs <- ask
    let
      this = thisObject $ contextScope $ edh'context pgs
      es   = entity'store $ objEntity this
      getArmedSink :: EdhValue -> STM ()
      getArmedSink !chLctr = do
        esd <- readTVar es
        case fromDynamic esd of
          Nothing ->
            throwEdhSTM pgs UsageError $ "bug: this is not a peer : " <> T.pack
              (show esd)
          Just (peer :: Peer) ->
            Map.lookup chLctr <$> readTVar (edh'peer'channels peer) >>= \case
              Nothing      -> exitEdhSTM pgs exit nil
              Just !chSink -> exitEdhSTM pgs exit $ EdhSink chSink
    case apk of
      ArgsPack [!chLctr] !kwargs | Map.null kwargs ->
        contEdhSTM $ getArmedSink chLctr
      _ -> throwEdh UsageError "Invalid args to armedChannelProc"

  armChannelProc :: EdhProcedure
  armChannelProc !apk !exit = do
    pgs <- ask
    let
      this = thisObject $ contextScope $ edh'context pgs
      es   = entity'store $ objEntity this
      armSink :: EdhValue -> EventSink -> STM ()
      armSink !chLctr !chSink = do
        esd <- readTVar es
        case fromDynamic esd of
          Nothing ->
            throwEdhSTM pgs UsageError $ "bug: this is not a peer : " <> T.pack
              (show esd)
          Just (peer :: Peer) -> do
            modifyTVar' (edh'peer'channels peer) $ Map.insert chLctr chSink
            exitEdhSTM pgs exit $ EdhSink chSink
    case parseArgsPack (Nothing, nil) parseArgs apk of
      Left  err                  -> throwEdh UsageError err
      Right (maybeLctr, sinkVal) -> case maybeLctr of
        Nothing      -> throwEdh UsageError "Missing channel locator"
        Just !chLctr -> contEdhSTM $ case edhUltimate sinkVal of
          EdhNil -> do
            chSink <- newEventSink
            armSink chLctr chSink
          EdhSink !chSink -> armSink chLctr chSink
          _ ->
            throwEdhSTM pgs UsageError
              $  "Invalid command channel type: "
              <> T.pack (edhTypeNameOf sinkVal)
   where
    parseArgs =
      ArgsPackParser
          [ \arg (_, chSink') -> Right (Just arg, chSink')
          , \arg (chLctr', _) -> Right (chLctr', arg)
          ]
        $ Map.fromList
            [ ("chLctr", \arg (_, chSink') -> Right (Just arg, chSink'))
            , ("chSink", \arg (chLctr', _) -> Right (chLctr', arg))
            ]

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
      postCmd' :: Text -> EdhValue -> STM ()
      postCmd' !cmd !dirVal = case dirVal of
        EdhNil -> postCmd cmd ""
        _      -> edhValueReprSTM pgs dirVal $ \dir -> postCmd cmd dir
    case parseArgsPack (Nothing, nil) parseArgs apk of
      Left  err                -> throwEdh UsageError err
      Right (maybeCmd, dirVal) -> case maybeCmd of
        Nothing                -> throwEdh UsageError "Missing command"
        Just (EdhString src  ) -> contEdhSTM $ postCmd' src dirVal
        Just (EdhExpr _ _ src) -> if src == ""
          then throwEdh UsageError "Missing source from the expr as command"
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

