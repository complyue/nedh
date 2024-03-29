module Language.Edh.Net.Peer where

-- import           Debug.Trace

import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import qualified Data.HashMap.Strict as Map
import qualified Data.HashSet as Set
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Language.Edh.EHI
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
    -- | channels to be cut-off (i.e. marked eos) on eol of this peer
    edh'peer'disposals :: !(TVar (Set.HashSet BChan)),
    -- | registry of comm channels associated with this peer,
    -- identified by arbitrary Edh values
    edh'peer'channels :: !(TVar (Map.HashMap EdhValue BChan))
  }

postPeerCommand :: EdhThreadState -> Peer -> Packet -> STM ()
postPeerCommand !ets !peer !pkt =
  tryReadTMVar (edh'peer'eol peer) >>= \case
    Just _ -> throwEdhSTM ets EvalError "posting to a peer already end-of-life"
    Nothing -> edh'peer'posting peer pkt

readPeerSource :: Peer -> Edh EdhValue
readPeerSource peer@(Peer _ _ !eol _ !ho _ _) =
  inlineSTM ((Right <$> ho) `orElse` (Left <$> readTMVar eol)) >>= \case
    -- reached normal end-of-stream
    Left (Right _) -> return nil
    -- previously eol due to error
    Left (Left !ex) -> throwHostM ex
    -- got next command source incoming
    Right pkt@(Packet !dir !payload) -> case dir of
      "" -> return $ EdhString $ TE.decodeUtf8 payload
      _ -> landPeerCmd peer pkt

-- | Read next command from peer
--
-- Note a command may target a specific channel, thus get posted to that
--      channel, and nil will be returned from here for it.
readPeerCommand :: Peer -> Edh EdhValue
readPeerCommand peer@(Peer _ _ !eol _ !ho _ _) =
  inlineSTM ((Right <$> ho) `orElse` (Left <$> readTMVar eol)) >>= \case
    -- reached normal end-of-stream
    Left (Right _) -> return nil
    -- previously eol due to error
    Left (Left !ex) -> throwHostM ex
    -- got next command incoming
    Right !pkt -> landPeerCmd peer pkt

landPeerCmd :: Peer -> Packet -> Edh EdhValue
landPeerCmd
  (Peer !ident !maybeSandbox _ _ _ _ !chdVar)
  (Packet !dir !payload) =
    case T.stripPrefix "blob:" dir of
      Just !chLctr -> landValue chLctr $ EdhBlob payload
      Nothing -> case maybeSandbox of
        Nothing -> do
          !cmdVal <- evalSrcM srcName (TE.decodeUtf8 payload)
          landValue dir cmdVal
        Just !sandbox -> do
          !cmdVal <-
            runInSandboxM sandbox (evalSrcM srcName (TE.decodeUtf8 payload))
          landValue dir cmdVal
    where
      !srcName = "peer:" <> ident

      landValue :: Text -> EdhValue -> Edh EdhValue
      landValue !chLctr !val =
        if T.null chLctr
          then -- to the default channel,
          -- which yields as direct result of `peer.readCommand()`
            return val
          else case maybeSandbox of -- to a specific channel,
          -- which should be located by the directive
            Nothing -> do
              evalSrcM srcName chLctr >>= postToChan val
              return nil
            Just !sandbox -> do
              runInSandboxM sandbox (evalSrcM srcName chLctr) >>= postToChan val
              return nil

      postToChan :: EdhValue -> EdhValue -> Edh ()
      postToChan !val !lctr = do
        !chd <- inlineSTM $ readTVar chdVar
        case Map.lookup lctr chd of
          Nothing ->
            throwEdhM UsageError $
              "missing command channel: " <> T.pack (show lctr)
          Just !chan -> do
            -- post the cmd to channel, but evals to nil as for
            -- `peer.readCommand()` wrt this cmd packet
            void $ writeChanM chan val

createPeerClass :: Edh Object
createPeerClass =
  mkEdhClass "Peer" peerAllocator [] $ do
    !mths <-
      sequence $
        [ (AttrByName nm,) <$> mkEdhProc vc nm hp
          | (nm, vc, hp) <-
              [ ("eol", EdhMethod, wrapEdhProc eolProc),
                ("join", EdhMethod, wrapEdhProc joinProc),
                ("stop", EdhMethod, wrapEdhProc stopProc),
                ("armedChannel", EdhMethod, wrapEdhProc armedChannelProc),
                ("armChannel", EdhMethod, wrapEdhProc armChannelProc),
                ("dispose", EdhMethod, wrapEdhProc disposeProc),
                ("readSource", EdhIntrpr, wrapEdhProc readPeerSrcProc),
                ("readCommand", EdhIntrpr, wrapEdhProc readPeerCmdProc),
                ("p2c", EdhMethod, wrapEdhProc p2cProc),
                ("postCommand", EdhMethod, wrapEdhProc postPeerCmdProc),
                ("__repr__", EdhMethod, wrapEdhProc reprProc)
              ]
        ]
          ++ [ (AttrByName nm,) <$> mkEdhProperty nm getter setter
               | (nm, getter, setter) <-
                   [ ("ident", identProc, Nothing),
                     ("sandbox", sandboxProc, Nothing)
                   ]
             ]

    !clsScope <- contextScope . edh'context <$> edhThreadState
    iopdUpdateEdh mths $ edh'scope'entity clsScope
  where
    peerAllocator :: ArgsPack -> Edh ObjectStore
    -- not really constructable from Edh code, this only creates bogus peer obj
    peerAllocator _ = return $ storeHostValue nil

    eolProc :: Edh EdhValue
    eolProc =
      thisHostObjectOf >>= \ !peer ->
        inlineSTM (tryReadTMVar $ edh'peer'eol peer) >>= \case
          Nothing -> return $ EdhBool False
          Just (Left !e) -> throwHostM e
          Just (Right ()) -> return $ EdhBool True

    joinProc :: Edh EdhValue
    joinProc =
      thisHostObjectOf >>= \ !peer ->
        inlineSTM (readTMVar $ edh'peer'eol peer) >>= \case
          Left !e -> throwHostM e
          Right () -> return nil

    stopProc :: Edh EdhValue
    stopProc =
      thisHostObjectOf >>= \ !peer -> do
        !stopped <- inlineSTM $ tryPutTMVar (edh'peer'eol peer) $ Right ()
        return $ EdhBool stopped

    armedChannelProc :: "chLctr" !: EdhValue -> Edh EdhValue
    armedChannelProc (mandatoryArg -> !chLctr) =
      thisHostObjectOf >>= \ !peer ->
        {- HLINT ignore "Redundant <$>" -}
        inlineSTM (Map.lookup chLctr <$> readTVar (edh'peer'channels peer))
          >>= \case
            Nothing -> return nil
            Just !chan -> return $ EdhChan chan

    armChannelProc ::
      "chLctr" !: EdhValue ->
      "chan" ?: BChan ->
      "dispose" ?: Bool ->
      Edh EdhValue
    armChannelProc
      (mandatoryArg -> !chLctr)
      (optionalArg -> !maybeChan)
      (defaultArg True -> !dispose) =
        thisHostObjectOf >>= \ !peer -> do
          !chan <- maybe newChanM return maybeChan
          inlineSTM $ do
            modifyTVar' (edh'peer'channels peer) $ Map.insert chLctr chan
            when dispose $
              modifyTVar' (edh'peer'disposals peer) $ Set.insert chan
          return $ EdhChan chan

    disposeProc :: "dependentChan" !: BChan -> Edh EdhValue
    disposeProc (mandatoryArg -> !chan) =
      thisHostObjectOf >>= \ !peer -> do
        !maybeEoL <- inlineSTM $ do
          modifyTVar' (edh'peer'disposals peer) $ Set.insert chan
          tryReadTMVar (edh'peer'eol peer)
        case maybeEoL of
          Just {} -> void $ writeChanM chan EdhNil -- already eol, mark eos now
          _ -> pure ()
        return $ EdhChan chan

    readPeerSrcProc :: Edh EdhValue
    readPeerSrcProc = thisHostObjectOf >>= \ !peer -> readPeerSource peer

    readPeerCmdProc :: Edh EdhValue
    readPeerCmdProc = thisHostObjectOf >>= \ !peer -> readPeerCommand peer

    postCmd :: EdhValue -> EdhValue -> Edh ()
    postCmd !dirVal !cmdVal =
      thisHostObjectOf >>= \ !peer -> do
        !ets <- edhThreadState
        !dir <- case edhUltimate dirVal of
          EdhNil -> return ""
          !chLctr -> edhValueReprM chLctr
        case cmdVal of
          EdhString !src ->
            inlineSTM $ postPeerCommand ets peer (textPacket dir src)
          EdhExpr _ !src ->
            if src == ""
              then
                throwEdhM
                  UsageError
                  "missing source from the expr as command"
              else inlineSTM $ postPeerCommand ets peer (textPacket dir src)
          EdhBlob !payload ->
            inlineSTM $
              postPeerCommand ets peer (Packet ("blob:" <> dir) payload)
          _ ->
            throwEdhM UsageError $
              "unsupported command type: " <> edhTypeNameOf cmdVal

    p2cProc :: "dir" ?: EdhValue -> "cmd" ?: EdhValue -> Edh EdhValue
    p2cProc (defaultArg nil -> !dirVal) (defaultArg nil -> !cmdVal) = do
      postCmd dirVal cmdVal
      return nil

    postPeerCmdProc :: "cmd" ?: EdhValue -> "dir" ?: EdhValue -> Edh EdhValue
    postPeerCmdProc (defaultArg nil -> !cmdVal) (defaultArg nil -> !dirVal) =
      do
        postCmd dirVal cmdVal
        return nil

    identProc :: Edh EdhValue
    identProc =
      thisHostObjectOf >>= \ !peer ->
        return $ EdhString $ edh'peer'ident peer

    sandboxProc :: Edh EdhValue
    sandboxProc =
      thisHostObjectOf >>= \ !peer -> case edh'peer'sandbox peer of
        Nothing -> return nil
        Just !sbScope -> do
          ets <- edhThreadState
          let world = edh'prog'world $ edh'thread'prog ets
          inlineSTM $ EdhObject <$> edh'scope'wrapper world sbScope

    reprProc :: Edh EdhValue
    reprProc =
      thisHostObjectOf >>= \ !peer ->
        return $ EdhString $ "peer:<" <> edh'peer'ident peer <> ">"
