module Language.Edh.Net.Peer where

-- import           Debug.Trace

import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.Dynamic
import qualified Data.HashMap.Strict as Map
import qualified Data.HashSet as Set
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Language.Edh.CHI
import Language.Edh.Net.MicroProto
import Prelude

data Peer = Peer
  { -- | identifier of the peer
    edh'peer'ident :: !Text,
    -- | sandboxed scope or nothing for no sandboxing
    edh'peer'sandbox :: !(Maybe Scope),
    -- | end-of-life with the cause
    edh'peer'eol :: !(TMVar (Either SomeException ())),
    -- | outlet for outgoing packets
    edh'peer'posting :: !(Packet -> STM ()),
    -- | intake for incoming packets
    edh'peer'hosting :: !(STM Packet),
    -- | sinks to be cut-off (i.e. marked eos) on eol of this peer
    edh'peer'disposals :: !(TVar (Set.HashSet Sink)),
    -- | registry of comm channels associated with this peer,
    -- identified by arbitrary Edh values
    edh'peer'channels :: !(TVar (Map.HashMap EdhValue Sink))
  }

postPeerCommand :: EdhThreadState -> Peer -> Packet -> EdhTxExit () -> STM ()
postPeerCommand !ets !peer !pkt !exit =
  tryReadTMVar (edh'peer'eol peer) >>= \case
    Just _ -> throwEdh ets EvalError "posting to a peer already end-of-life"
    Nothing -> do
      edh'peer'posting peer pkt
      exitEdh ets exit ()

readPeerSource :: EdhThreadState -> Peer -> EdhTxExit EdhValue -> STM ()
readPeerSource !ets peer@(Peer _ _ !eol _ !ho _ _) !exit =
  ((Right <$> ho) `orElse` (Left <$> readTMVar eol)) >>= \case
    -- reached normal end-of-stream
    Left (Right _) -> exitEdh ets exit nil
    -- previously eol due to error
    Left (Left !ex) ->
      edh'exception'wrapper (edh'prog'world $ edh'thread'prog ets) (Just ets) ex
        >>= \ !exo -> edhThrow ets $ EdhObject exo
    -- got next command source incoming
    Right pkt@(Packet !dir !payload) -> case dir of
      "" -> exitEdh ets exit $ EdhString $ TE.decodeUtf8 payload
      _ -> landPeerCmd peer pkt ets exit

-- | Read next command from peer
--
-- Note a command may target a specific channel, thus get posted to that
--      channel's sink, and nil will be returned from here for it.
readPeerCommand :: EdhThreadState -> Peer -> EdhTxExit EdhValue -> STM ()
readPeerCommand !ets peer@(Peer _ _ !eol _ !ho _ _) !exit =
  ((Right <$> ho) `orElse` (Left <$> readTMVar eol)) >>= \case
    -- reached normal end-of-stream
    Left (Right _) -> exitEdh ets exit nil
    -- previously eol due to error
    Left (Left !ex) ->
      edh'exception'wrapper (edh'prog'world $ edh'thread'prog ets) (Just ets) ex
        >>= \ !exo -> edhThrow ets $ EdhObject exo
    -- got next command incoming
    Right !pkt -> landPeerCmd peer pkt ets exit

landPeerCmd :: Peer -> Packet -> EdhThreadState -> EdhTxExit EdhValue -> STM ()
landPeerCmd
  (Peer !ident !maybeSandbox _ _ _ _ !chdVar)
  (Packet !dir !payload)
  !ets
  !exit =
    case T.stripPrefix "blob:" dir of
      Just !chLctr -> runEdhTx ets $ landValue chLctr $ EdhBlob payload
      Nothing -> case maybeSandbox of
        Nothing ->
          runEdhTx ets $
            evalEdh srcName (TE.decodeUtf8 payload) $ \ !cmdVal ->
              landValue dir cmdVal
        Just !sandbox ->
          runEdhInSandbox
            ets
            sandbox
            (evalEdh srcName (TE.decodeUtf8 payload))
            $ \ !cmdVal -> landValue dir cmdVal
    where
      !srcName = "peer:" <> ident
      landValue !chLctr !val =
        if T.null chLctr
          then -- to the default channel, which yields as direct result of
          -- `peer.readCommand()`
            exitEdhTx exit val
          else -- to a specific channel, which should be located by the directive
          case maybeSandbox of
            Nothing -> evalEdh srcName chLctr (postToChan val)
            Just !sandbox ->
              runEdhTxInSandbox
                sandbox
                (evalEdh srcName chLctr)
                (postToChan val)
      postToChan :: EdhValue -> EdhValue -> EdhTx
      postToChan !val !lctr _ets = do
        !chd <- readTVar chdVar
        case Map.lookup lctr chd of
          Nothing ->
            throwEdh ets UsageError $
              "missing command channel: "
                <> T.pack
                  (show lctr)
          Just !chSink -> do
            -- post the cmd to channel, but evals to nil as for
            -- `peer.readCommand()` wrt this cmd packet
            void $ postEvent chSink val
            exitEdh ets exit nil

createPeerClass :: Scope -> STM Object
createPeerClass !clsOuterScope =
  mkHostClass clsOuterScope "Peer" peerAllocator [] $ \ !clsScope -> do
    !mths <-
      sequence $
        [ (AttrByName nm,) <$> mkHostProc clsScope vc nm hp
          | (nm, vc, hp) <-
              [ ("eol", EdhMethod, wrapHostProc eolProc),
                ("join", EdhMethod, wrapHostProc joinProc),
                ("stop", EdhMethod, wrapHostProc stopProc),
                ("armedChannel", EdhMethod, wrapHostProc armedChannelProc),
                ("armChannel", EdhMethod, wrapHostProc armChannelProc),
                ("dispose", EdhMethod, wrapHostProc disposeProc),
                ("readSource", EdhIntrpr, wrapHostProc readPeerSrcProc),
                ("readCommand", EdhIntrpr, wrapHostProc readPeerCmdProc),
                ("p2c", EdhMethod, wrapHostProc p2cProc),
                ("postCommand", EdhMethod, wrapHostProc postPeerCmdProc),
                ("__repr__", EdhMethod, wrapHostProc reprProc)
              ]
        ]
          ++ [ (AttrByName nm,) <$> mkHostProperty clsScope nm getter setter
               | (nm, getter, setter) <-
                   [ ("ident", identProc, Nothing),
                     ("sandbox", sandboxProc, Nothing)
                   ]
             ]
    iopdUpdate mths $ edh'scope'entity clsScope
  where
    peerAllocator :: ArgsPack -> EdhObjectAllocator
    -- not really constructable from Edh code, this only creates bogus peer obj
    peerAllocator _ !ctorExit _ = ctorExit Nothing $ HostStore (toDyn nil)

    eolProc :: EdhHostProc
    eolProc !exit !ets = withThisHostObj ets $ \ !peer ->
      tryReadTMVar (edh'peer'eol peer) >>= \case
        Nothing -> exitEdh ets exit $ EdhBool False
        Just (Left !e) ->
          edh'exception'wrapper world (Just ets) e
            >>= \ !exo -> exitEdh ets exit $ EdhObject exo
        Just (Right ()) -> exitEdh ets exit $ EdhBool True
      where
        world = edh'prog'world $ edh'thread'prog ets

    joinProc :: EdhHostProc
    joinProc !exit !ets = withThisHostObj ets $ \ !peer ->
      readTMVar (edh'peer'eol peer) >>= \case
        Left !e ->
          edh'exception'wrapper world (Just ets) e
            >>= \ !exo -> edhThrow ets $ EdhObject exo
        Right () -> exitEdh ets exit nil
      where
        world = edh'prog'world $ edh'thread'prog ets

    stopProc :: EdhHostProc
    stopProc !exit !ets = withThisHostObj ets $ \ !peer -> do
      !stopped <- tryPutTMVar (edh'peer'eol peer) $ Right ()
      exitEdh ets exit $ EdhBool stopped

    armedChannelProc :: "chLctr" !: EdhValue -> EdhHostProc
    armedChannelProc (mandatoryArg -> !chLctr) !exit !ets =
      withThisHostObj ets $ \ !peer ->
        {- HLINT ignore "Redundant <$>" -}
        Map.lookup chLctr <$> readTVar (edh'peer'channels peer) >>= \case
          Nothing -> exitEdh ets exit nil
          Just !chSink -> exitEdh ets exit $ EdhSink chSink

    armChannelProc ::
      "chLctr" !: EdhValue ->
      "chSink" ?: Sink ->
      "dispose" ?: Bool ->
      EdhHostProc
    armChannelProc
      (mandatoryArg -> !chLctr)
      (optionalArg -> !maybeSink)
      (defaultArg True -> !dispose)
      !exit
      !ets =
        withThisHostObj ets $ \ !peer -> do
          !chSink <- maybe newSink return maybeSink
          modifyTVar' (edh'peer'channels peer) $ Map.insert chLctr chSink
          when dispose $
            modifyTVar' (edh'peer'disposals peer) $ Set.insert chSink
          exitEdh ets exit $ EdhSink chSink

    disposeProc :: "dependentSink" !: Sink -> EdhHostProc
    disposeProc (mandatoryArg -> !sink) !exit !ets =
      withThisHostObj ets $ \ !peer -> do
        modifyTVar' (edh'peer'disposals peer) $ Set.insert sink
        tryReadTMVar (edh'peer'eol peer) >>= \case
          Just {} -> void $ postEvent sink EdhNil -- already eol, mark eos now
          _ -> pure ()
        exitEdh ets exit $ EdhSink sink

    readPeerSrcProc :: EdhHostProc
    readPeerSrcProc !exit !ets =
      withThisHostObj ets $ \ !peer -> readPeerSource ets peer exit

    readPeerCmdProc :: EdhHostProc
    readPeerCmdProc !exit !ets =
      withThisHostObj ets $ \ !peer -> readPeerCommand ets peer exit

    postCmd :: EdhValue -> EdhValue -> EdhTxExit () -> EdhTx
    postCmd !dirVal !cmdVal !exit !ets = withThisHostObj ets $ \ !peer -> do
      let withDir :: (PacketDirective -> STM ()) -> STM ()
          withDir !exit' = case edhUltimate dirVal of
            EdhNil -> exit' ""
            !chLctr -> edhValueRepr ets chLctr $ \ !lctr -> exit' lctr
      withDir $ \ !dir -> case cmdVal of
        EdhString !src -> postPeerCommand ets peer (textPacket dir src) exit
        EdhExpr _ !src ->
          if src == ""
            then
              throwEdh
                ets
                UsageError
                "missing source from the expr as command"
            else postPeerCommand ets peer (textPacket dir src) exit
        EdhBlob !payload ->
          postPeerCommand ets peer (Packet ("blob:" <> dir) payload) exit
        _ ->
          throwEdh ets UsageError $
            "unsupported command type: " <> edhTypeNameOf cmdVal

    p2cProc :: "dir" ?: EdhValue -> "cmd" ?: EdhValue -> EdhHostProc
    p2cProc (defaultArg nil -> !dirVal) (defaultArg nil -> !cmdVal) !exit =
      postCmd dirVal cmdVal $ \() -> exitEdhTx exit nil

    postPeerCmdProc :: "cmd" ?: EdhValue -> "dir" ?: EdhValue -> EdhHostProc
    postPeerCmdProc
      (defaultArg nil -> !cmdVal)
      (defaultArg nil -> !dirVal)
      !exit =
        postCmd dirVal cmdVal $ \() -> exitEdhTx exit nil

    identProc :: EdhHostProc
    identProc !exit !ets =
      withThisHostObj' ets (exitEdh ets exit $ EdhString "<bogus-peer>") $
        \ !peer -> exitEdh ets exit $ EdhString $ edh'peer'ident peer

    sandboxProc :: EdhHostProc
    sandboxProc !exit !ets = withThisHostObj ets $
      \ !peer -> case edh'peer'sandbox peer of
        Nothing -> exitEdh ets exit nil
        Just !sbScope ->
          edh'scope'wrapper world sbScope >>= exitEdh ets exit . EdhObject
      where
        world = edh'prog'world $ edh'thread'prog ets

    reprProc :: EdhHostProc
    reprProc !exit !ets =
      withThisHostObj' ets (exitEdh ets exit $ EdhString "peer:<bogus>") $
        \ !peer ->
          exitEdh ets exit $ EdhString $ "peer:<" <> edh'peer'ident peer <> ">"
