module Language.Edh.Net.Server where

-- import           Debug.Trace

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.Dynamic
import qualified Data.HashSet as Set
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import Language.Edh.EHI
import Language.Edh.Net.Addr
import Language.Edh.Net.MicroProto
import Language.Edh.Net.Peer
import Network.Socket
import Network.Socket.ByteString
import Prelude

data EdhServer = EdhServer
  { -- the import spec of the service module
    edh'server'modu :: !Text,
    -- local network interface to bind
    edh'server'addr :: !Text,
    -- local network port to bind
    edh'server'port :: !PortNumber,
    -- max port number to try bind
    edh'server'port'max :: !PortNumber,
    -- actually listened network addresses
    edh'serving'addrs :: !(TMVar [AddrInfo]),
    -- end-of-life status
    edh'server'eol :: !(TMVar (Either SomeException ())),
    -- service module initializer, must callable if not nil
    edh'server'init :: !EdhValue,
    -- each connected peer is sunk into this
    edh'serving'clients :: !EdhSink
  }

createServerClass :: (Text -> STM ()) -> Object -> Object -> Scope -> STM Object
createServerClass !consoleWarn !addrClass !peerClass !clsOuterScope =
  mkHostClass clsOuterScope "Server" (allocEdhObj serverAllocator) [] $
    \ !clsScope -> do
      !mths <-
        sequence $
          [ (AttrByName nm,) <$> mkHostProc clsScope vc nm hp
            | (nm, vc, hp) <-
                [ ("addrs", EdhMethod, wrapHostProc addrsProc),
                  ("eol", EdhMethod, wrapHostProc eolProc),
                  ("join", EdhMethod, wrapHostProc joinProc),
                  ("stop", EdhMethod, wrapHostProc stopProc),
                  ("__repr__", EdhMethod, wrapHostProc reprProc)
                ]
          ]
            ++ [ (AttrByName nm,) <$> mkHostProperty clsScope nm getter setter
                 | (nm, getter, setter) <- [("clients", clientsProc, Nothing)]
               ]
      iopdUpdate mths $ edh'scope'entity clsScope
  where
    serverAllocator ::
      "service" !: Text ->
      "addr" ?: Text ->
      "port" ?: Int ->
      "port'max" ?: Int ->
      "init" ?: EdhValue ->
      "clients" ?: EdhSink ->
      "useSandbox" ?: Bool ->
      EdhObjectAllocator
    serverAllocator
      (mandatoryArg -> !service)
      (defaultArg "127.0.0.1" -> !ctorAddr)
      (defaultArg 3721 -> !ctorPort)
      (defaultArg ctorPort -> port'max)
      (defaultArg nil -> !init_)
      (optionalArg -> maybeClients)
      (defaultArg True -> !useSandbox)
      !ctorExit
      !etsCtor =
        if edh'in'tx etsCtor
          then
            throwEdh
              etsCtor
              UsageError
              "you don't create network objects within a transaction"
          else case edhUltimate init_ of
            EdhNil -> withInit nil
            mth@(EdhProcedure EdhMethod {} _) -> withInit mth
            mth@(EdhBoundProc EdhMethod {} _ _ _) -> withInit mth
            !badInit -> edhValueDesc etsCtor badInit $ \ !badDesc ->
              throwEdh etsCtor UsageError $ "invalid init: " <> badDesc
        where
          withInit !__modu_init__ = do
            !servAddrs <- newEmptyTMVar
            !servEoL <- newEmptyTMVar
            !clients <- maybe newEdhSink return maybeClients
            let !server =
                  EdhServer
                    { edh'server'modu = service,
                      edh'server'addr = ctorAddr,
                      edh'server'port = fromIntegral ctorPort,
                      edh'server'port'max = fromIntegral port'max,
                      edh'serving'addrs = servAddrs,
                      edh'server'eol = servEoL,
                      edh'server'init = __modu_init__,
                      edh'serving'clients = clients
                    }
                finalCleanup !result = atomically $ do
                  -- fill empty addrs if the listening has ever failed
                  void $ tryPutTMVar servAddrs []
                  -- mark server end-of-life anyway finally
                  void $ tryPutTMVar servEoL result
                  -- mark eos for clients sink anyway finally
                  void $ postEvent clients nil

            runEdhTx etsCtor $
              edhContIO $ do
                void $ forkFinally (serverThread server) finalCleanup
                atomically $ ctorExit Nothing $ HostStore (toDyn server)

          serverThread :: EdhServer -> IO ()
          serverThread
            ( EdhServer
                !servModu
                !servAddr
                !servPort
                !portMax
                !servAddrs
                !servEoL
                !__modu_init__
                !clients
              ) =
              do
                !servThId <- myThreadId
                void $
                  forkIO $ do
                    -- async terminate the accepter thread on stop signal
                    _ <- atomically $ readTMVar servEoL
                    killThread servThId
                !addr <- resolveServAddr
                bracket (open addr) close acceptClients
              where
                world = edh'prog'world $ edh'thread'prog etsCtor

                resolveServAddr = do
                  let hints =
                        defaultHints
                          { addrFlags = [AI_PASSIVE],
                            addrSocketType = Stream
                          }
                  addr : _ <-
                    getAddrInfo
                      (Just hints)
                      (Just $ T.unpack servAddr)
                      (Just (show servPort))
                  return addr

                tryBind !ssock !addr !port =
                  catch (bind ssock $ addrWithPort addr port) $
                    \(e :: SomeException) ->
                      if port < portMax
                        then tryBind ssock addr (port + 1)
                        else throw e
                open addr =
                  bracketOnError
                    ( socket
                        (addrFamily addr)
                        (addrSocketType addr)
                        (addrProtocol addr)
                    )
                    close
                    $ \ssock -> do
                      tryBind ssock (addrAddress addr) servPort
                      listen ssock 300 -- todo make this tunable ?
                      listenAddr <- getSocketName ssock
                      atomically $
                        tryTakeTMVar servAddrs
                          >>= putTMVar servAddrs
                            . (addr {addrAddress = listenAddr} :)
                            . fromMaybe []
                      return ssock

                acceptClients :: Socket -> IO ()
                acceptClients ssock = do
                  bracketOnError (accept ssock) (close . fst) $ \(sock, addr) ->
                    do
                      !clientEoL <- newEmptyTMVarIO
                      let cleanupClient :: Either SomeException () -> IO ()
                          cleanupClient !result =
                            (gracefulClose sock 5000 >>) $
                              atomically $ do
                                void $ tryPutTMVar clientEoL result
                                readTMVar clientEoL >>= \case
                                  Right {} -> pure ()
                                  Left !err ->
                                    consoleWarn $
                                      "Service module ["
                                        <> servModu
                                        <> "] incurred error:\n"
                                        <> T.pack (show err)
                      void $
                        forkFinally
                          (servClient clientEoL (T.pack $ show addr) sock)
                          cleanupClient
                  acceptClients ssock -- tail recursion
                servClient ::
                  TMVar (Either SomeException ()) ->
                  Text ->
                  Socket ->
                  IO ()
                servClient !clientEoL !clientId !sock = do
                  !pktSink <- newEmptyTMVarIO
                  !poq <- newEmptyTMVarIO
                  !disposalsVar <- newTVarIO mempty
                  !chdVar <- newTVarIO mempty

                  let prepService :: EdhModulePreparation
                      prepService !etsModu !exit =
                        if useSandbox
                          then mkObjSandbox etsModu moduObj $ withSandbox . Just
                          else withSandbox Nothing
                        where
                          !moduScope = contextScope $ edh'context etsModu
                          !moduObj = edh'scope'this moduScope
                          withSandbox !maybeSandbox = do
                            !peerObj <-
                              edhCreateHostObj peerClass peer
                            -- implant to the module being prepared
                            iopdInsert
                              (AttrByName "peer")
                              (EdhObject peerObj)
                              (edh'scope'entity moduScope)
                            -- announce this new client connected
                            void $ postEvent clients $ EdhObject peerObj
                            if __modu_init__ == nil
                              then exit
                              else -- call the per-connection peer module
                              -- initialization method in the module context
                              -- (where both contextual this/that are the module
                              -- object)
                              edhPrepareCall'
                                etsModu
                                __modu_init__
                                ( ArgsPack
                                    [EdhObject $ edh'scope'this moduScope]
                                    odEmpty
                                )
                                $ \ !mkCall -> runEdhTx etsModu $
                                  mkCall $ \_result _ets -> exit
                            where
                              !peer =
                                Peer
                                  { edh'peer'ident = clientId,
                                    edh'peer'sandbox = maybeSandbox,
                                    edh'peer'eol = clientEoL,
                                    edh'peer'posting = putTMVar poq,
                                    edh'peer'hosting = takeTMVar pktSink,
                                    edh'peer'disposals = disposalsVar,
                                    edh'peer'channels = chdVar
                                  }

                  -- run the server module on a separate Edh thread as another
                  -- Edh program
                  --
                  -- this implements structured concurrency per client
                  -- connection, i.e. all Edh threads spawned by this client
                  -- will terninate upon its disconnection, while resource
                  -- cleanups should be scheduled via defer mechanism or
                  -- exception catching
                  --
                  -- `ThreadTerminate` will be thrown, the cleanup action is
                  -- usually in a finally block
                  void $
                    forkFinally
                      (runEdhModule' world (T.unpack servModu) prepService)
                      -- anyway after the module code done:
                      --   dispose of all dependent (channel or not) sinks
                      --   mark client end-of-life with the result
                      $ \ !result -> atomically $ do
                        !sinks2Dispose <- readTVar disposalsVar
                        sequence_ $
                          flip postEvent EdhNil <$> Set.toList sinks2Dispose
                        void $ tryPutTMVar clientEoL $ void result

                  -- pump commands in,
                  -- making this thread the only one reading the handle
                  --
                  -- note this won't return, will be asynchronously killed on
                  -- eol
                  void $
                    forkIO $
                      receivePacketStream
                        clientId
                        (recv sock)
                        pktSink
                        clientEoL

                  let serializeCmdsOut :: IO ()
                      serializeCmdsOut =
                        atomically
                          ( (Right <$> takeTMVar poq)
                              `orElse` (Left <$> readTMVar clientEoL)
                          )
                          >>= \case
                            Left _ -> return () -- stop on eol any way
                            Right !pkt -> do
                              sendPacket clientId (sendAll sock) pkt
                              serializeCmdsOut
                  -- pump commands out,
                  -- make this thread the only one writing the handle
                  serializeCmdsOut `catch` \(e :: SomeException) ->
                    -- mark eol on error
                    atomically $ void $ tryPutTMVar clientEoL $ Left e

    clientsProc :: EdhHostProc
    clientsProc !exit !ets = withThisHostObj ets $
      \ !server -> exitEdh ets exit $ EdhEvs $ edh'serving'clients server

    reprProc :: EdhHostProc
    reprProc !exit !ets =
      withThisHostObj ets $ \(EdhServer !modu !addr !port !port'max _ _ _ _) ->
        exitEdh ets exit $
          EdhString $
            "Server("
              <> T.pack (show modu)
              <> ", "
              <> T.pack (show addr)
              <> ", "
              <> T.pack (show port)
              <> ", port'max="
              <> T.pack (show port'max)
              <> ")"

    addrsProc :: EdhHostProc
    addrsProc !exit !ets = withThisHostObj ets $
      \ !server -> readTMVar (edh'serving'addrs server) >>= wrapAddrs []
      where
        wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
        wrapAddrs addrs [] =
          exitEdh ets exit $ EdhArgsPack $ ArgsPack addrs odEmpty
        wrapAddrs !addrs (addr : rest) =
          edhCreateHostObj addrClass addr
            >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

    eolProc :: EdhHostProc
    eolProc !exit !ets = withThisHostObj ets $ \ !server ->
      tryReadTMVar (edh'server'eol server) >>= \case
        Nothing -> exitEdh ets exit $ EdhBool False
        Just (Left !e) ->
          edh'exception'wrapper world (Just ets) e
            >>= \ !exo -> exitEdh ets exit $ EdhObject exo
        Just (Right ()) -> exitEdh ets exit $ EdhBool True
      where
        world = edh'prog'world $ edh'thread'prog ets

    joinProc :: EdhHostProc
    joinProc !exit !ets = withThisHostObj ets $ \ !server ->
      readTMVar (edh'server'eol server) >>= \case
        Left !e ->
          edh'exception'wrapper world (Just ets) e
            >>= \ !exo -> edhThrow ets $ EdhObject exo
        Right () -> exitEdh ets exit nil
      where
        world = edh'prog'world $ edh'thread'prog ets

    stopProc :: EdhHostProc
    stopProc !exit !ets = withThisHostObj ets $ \ !server -> do
      stopped <- tryPutTMVar (edh'server'eol server) $ Right ()
      exitEdh ets exit $ EdhBool stopped
