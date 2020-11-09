
module Language.Edh.Net.Peer where

import           Prelude
-- import           Debug.Trace

import           Control.Exception
import           Control.Concurrent.STM

import qualified Data.List.NonEmpty            as NE
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import qualified Data.Text.Encoding            as TE
import qualified Data.HashMap.Strict           as Map
import           Data.Dynamic

import           Language.Edh.EHI

import           Language.Edh.Net.MicroProto


data Peer = Peer {
      edh'peer'ident :: !Text
    , edh'peer'sandbox :: !(Maybe Scope)
    , edh'peer'eol :: !(TMVar (Either SomeException ()))
      -- todo this ever needs to be in CPS?
    , edh'peer'posting :: !(Packet -> STM ())
    , edh'peer'hosting :: !(STM Packet)
    , edh'peer'channels :: !(TVar (Map.HashMap EdhValue EventSink))
  }

postPeerCommand :: EdhThreadState -> Peer -> Packet -> EdhTxExit -> STM ()
postPeerCommand !ets !peer !pkt !exit =
  tryReadTMVar (edh'peer'eol peer) >>= \case
    Just _  -> throwEdh ets EvalError "posting to a peer already end-of-life"
    Nothing -> do
      edh'peer'posting peer pkt
      exitEdh ets exit nil

readPeerSource :: EdhThreadState -> Peer -> EdhTxExit -> STM ()
readPeerSource !ets peer@(Peer _ _ !eol _ !ho _) !exit =
  ((Right <$> ho) `orElse` (Left <$> readTMVar eol)) >>= \case
    -- reached normal end-of-stream
    Left (Right _) -> exitEdh ets exit nil
    -- previously eol due to error
    Left (Left !ex) ->
      edh'exception'wrapper (edh'ctx'world $ edh'context ets) ex
        >>= \ !exo -> edhThrow ets $ EdhObject exo
    -- got next command source incoming
    Right pkt@(Packet !dir !payload) -> case dir of
      "" -> exitEdh ets exit $ EdhString $ TE.decodeUtf8 payload
      _  -> landPeerCmd peer pkt ets exit

-- | Read next command from peer
--
-- Note a command may target a specific channel, thus get posted to that 
--      channel's sink, and nil will be returned from here for it.
readPeerCommand :: EdhThreadState -> Peer -> EdhTxExit -> STM ()
readPeerCommand !ets peer@(Peer _ _ !eol _ !ho _) !exit =
  ((Right <$> ho) `orElse` (Left <$> readTMVar eol)) >>= \case
    -- reached normal end-of-stream
    Left (Right _) -> exitEdh ets exit nil
    -- previously eol due to error
    Left (Left !ex) ->
      edh'exception'wrapper (edh'ctx'world $ edh'context ets) ex
        >>= \ !exo -> edhThrow ets $ EdhObject exo
    -- got next command incoming
    Right !pkt -> landPeerCmd peer pkt ets exit

landPeerCmd :: Peer -> Packet -> EdhThreadState -> EdhTxExit -> STM ()
landPeerCmd (Peer !ident !maybeSandbox _ _ _ !chdVar) (Packet !dir !payload) !ets !exit
  = case T.stripPrefix "blob:" dir of
    Just !chLctr -> runEdhTx ets $ landValue chLctr $ EdhBlob payload
    Nothing      -> case maybeSandbox of
      Nothing ->
        runEdhTx ets $ evalEdh srcName (TE.decodeUtf8 payload) $ \ !cmdVal ->
          landValue dir cmdVal
      Just !sandbox ->
        runEdhInSandbox ets sandbox (evalEdh srcName (TE.decodeUtf8 payload))
          $ \ !cmdVal -> landValue dir cmdVal
 where
  !srcName = T.unpack ident
  landValue !chLctr !val = if T.null chLctr
    -- to the default channel, which yields as direct result of 
    -- `peer.readCommand()`
    then exitEdhTx exit val
    -- to a specific channel, which should be located by the directive
    else case maybeSandbox of
      Nothing -> evalEdh srcName chLctr (postToChan val)
      Just !sandbox ->
        runEdhTxInSandbox sandbox (evalEdh srcName chLctr) (postToChan val)
  postToChan :: EdhValue -> EdhValue -> EdhTx
  postToChan !val !lctr _ets = do
    !chd <- readTVar chdVar
    case Map.lookup lctr chd of
      Nothing ->
        throwEdh ets UsageError $ "missing command channel: " <> T.pack
          (show lctr)
      Just !chSink -> -- post the cmd to channel, but yield nil as for
        -- `peer.readCommand()` wrt this cmd packet
        runEdhTx ets $ publishEvent chSink val $ const $ exitEdhTx exit nil


createPeerClass :: Scope -> STM Object
createPeerClass !clsOuterScope =
  mkHostClass clsOuterScope "Peer" peerAllocator [] $ \ !clsScope -> do
    !mths <-
      sequence
      $  [ (AttrByName nm, ) <$> mkHostProc clsScope vc nm hp
         | (nm, vc, hp) <-
           [ ("eol"         , EdhMethod, wrapHostProc eolProc)
           , ("join"        , EdhMethod, wrapHostProc joinProc)
           , ("stop"        , EdhMethod, wrapHostProc stopProc)
           , ("armedChannel", EdhMethod, wrapHostProc armedChannelProc)
           , ("armChannel"  , EdhMethod, wrapHostProc armChannelProc)
           , ("readSource"  , EdhMethod, wrapHostProc readPeerSrcProc)
           , ("readCommand" , EdhMethod, wrapHostProc readPeerCmdProc)
           , ("p2c"         , EdhMethod, wrapHostProc p2cProc)
           , ("postCommand" , EdhMethod, wrapHostProc postPeerCmdProc)
           , ("__repr__"    , EdhMethod, wrapHostProc reprProc)
           ]
         ]
      ++ [ (AttrByName nm, ) <$> mkHostProperty clsScope nm getter setter
         | (nm, getter, setter) <- [("ident", identProc, Nothing)]
         ]
    iopdUpdate mths $ edh'scope'entity clsScope

 where

  -- | host constructor Peer()
  peerAllocator :: ArgsPack -> EdhObjectAllocator
  -- not really constructable from Edh code, this only creates bogus peer obj
  peerAllocator _ !ctorExit _ = ctorExit $ HostStore (toDyn nil)

  eolProc :: EdhHostProc
  eolProc !exit !ets = withThisHostObj ets $ \ !peer ->
    tryReadTMVar (edh'peer'eol peer) >>= \case
      Nothing        -> exitEdh ets exit $ EdhBool False
      Just (Left !e) -> edh'exception'wrapper world e
        >>= \ !exo -> exitEdh ets exit $ EdhObject exo
      Just (Right ()) -> exitEdh ets exit $ EdhBool True
    where world = edh'ctx'world $ edh'context ets

  joinProc :: EdhHostProc
  joinProc !exit !ets = withThisHostObj ets $ \ !peer ->
    readTMVar (edh'peer'eol peer) >>= \case
      Left !e ->
        edh'exception'wrapper world e >>= \ !exo -> edhThrow ets $ EdhObject exo
      Right () -> exitEdh ets exit nil
    where world = edh'ctx'world $ edh'context ets

  stopProc :: EdhHostProc
  stopProc !exit !ets = withThisHostObj ets $ \ !peer -> do
    !stopped <- tryPutTMVar (edh'peer'eol peer) $ Right ()
    exitEdh ets exit $ EdhBool stopped

  armedChannelProc :: "chLctr" !: EdhValue -> EdhHostProc
  armedChannelProc (mandatoryArg -> !chLctr) !exit !ets =
    withThisHostObj ets $ \ !peer ->
      Map.lookup chLctr <$> readTVar (edh'peer'channels peer) >>= \case
        Nothing      -> exitEdh ets exit nil
        Just !chSink -> exitEdh ets exit $ EdhSink chSink

  armChannelProc :: "chLctr" !: EdhValue -> "chSink" ?: EventSink -> EdhHostProc
  armChannelProc (mandatoryArg -> !chLctr) (optionalArg -> !maybeSink) !exit !ets
    = withThisHostObj ets $ \ !peer -> do
      let armSink :: EventSink -> STM ()
          armSink !chSink = do
            modifyTVar' (edh'peer'channels peer) $ Map.insert chLctr chSink
            exitEdh ets exit $ EdhSink chSink
      case maybeSink of
        Nothing      -> newEventSink >>= armSink
        Just !chSink -> armSink chSink

  readPeerSrcProc :: EdhHostProc
  readPeerSrcProc !exit !ets =
    withThisHostObj ets $ \ !peer -> readPeerSource ets peer exit

  readPeerCmdProc :: EdhHostProc
  readPeerCmdProc !exit !ets = withThisHostObj ets
    $ \ !peer -> readPeerCommand etsCmd peer exit
   where
    !ctx         = edh'context ets
    !callerScope = contextFrame ctx 1
    !etsCmd      = ets
      { edh'context = ctx
        { edh'ctx'stack =
          callerScope
              {
                      -- use a meaningful caller stmt
                edh'scope'caller = StmtSrc
                                     (startPosOfFile "<peer-cmd>", VoidStmt)
              }
            NE.:| NE.tail (edh'ctx'stack ctx)
        }
      }

  postCmd :: EdhValue -> EdhValue -> EdhTxExit -> EdhTx
  postCmd !dirVal !cmdVal !exit !ets = withThisHostObj ets $ \ !peer -> do
    let withDir :: (PacketDirective -> STM ()) -> STM ()
        withDir !exit' = case edhUltimate dirVal of
          EdhNil  -> exit' ""
          !chLctr -> edhValueRepr ets chLctr $ \ !lctr -> exit' lctr
    withDir $ \ !dir -> case cmdVal of
      EdhString !src   -> postPeerCommand ets peer (textPacket dir src) exit
      EdhExpr _ _ !src -> if src == ""
        then throwEdh ets UsageError "missing source from the expr as command"
        else postPeerCommand ets peer (textPacket dir src) exit
      EdhBlob !payload ->
        postPeerCommand ets peer (Packet ("blob:" <> dir) payload) exit
      _ -> throwEdh ets UsageError $ "unsupported command type: " <> T.pack
        (edhTypeNameOf cmdVal)

  -- | peer.p2c( dir, cmd ) - shorthand for post-to-channel
  p2cProc :: "dir" ?: EdhValue -> "cmd" ?: EdhValue -> EdhHostProc
  p2cProc (defaultArg nil -> !dirVal) (defaultArg nil -> !cmdVal) !exit =
    postCmd dirVal cmdVal exit

  postPeerCmdProc :: "cmd" ?: EdhValue -> "dir" ?: EdhValue -> EdhHostProc
  postPeerCmdProc (defaultArg nil -> !cmdVal) (defaultArg nil -> !dirVal) !exit
    = postCmd dirVal cmdVal exit

  identProc :: EdhHostProc
  identProc !exit !ets =
    withThisHostObj' ets (exitEdh ets exit $ EdhString "<bogus-peer>")
      $ \ !peer -> exitEdh ets exit $ EdhString $ edh'peer'ident peer

  reprProc :: EdhHostProc
  reprProc !exit !ets =
    withThisHostObj' ets (exitEdh ets exit $ EdhString "peer:<bogus>")
      $ \ !peer ->
          exitEdh ets exit $ EdhString $ "peer:<" <> edh'peer'ident peer <> ">"

