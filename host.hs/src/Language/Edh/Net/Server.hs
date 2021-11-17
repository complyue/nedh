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
  { -- Edh procedure to run for the service
    edh'service'proc :: !EdhValue,
    -- the world in which the service will run
    edh'service'world :: !EdhWorld,
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
    -- each connected peer is sunk into this
    edh'serving'clients :: !Sink
  }

createServerClass ::
  (Text -> STM ()) ->
  Object ->
  Object ->
  Symbol ->
  EntityStore ->
  Edh Object
createServerClass
  !consoleWarn
  !addrClass
  !peerClass
  !symNetPeer
  !esNetEffs =
    mkEdhClass "Server" (allocObjM serverAllocator) [] $ do
      !mths <-
        sequence $
          [ (AttrByName nm,) <$> mkEdhProc vc nm hp
            | (nm, vc, hp) <-
                [ ("addrs", EdhMethod, wrapEdhProc addrsProc),
                  ("eol", EdhMethod, wrapEdhProc eolProc),
                  ("join", EdhMethod, wrapEdhProc joinProc),
                  ("stop", EdhMethod, wrapEdhProc stopProc),
                  ("__repr__", EdhMethod, wrapEdhProc reprProc)
                ]
          ]
            ++ [ (AttrByName nm,) <$> mkEdhProperty nm getter setter
                 | (nm, getter, setter) <- [("clients", clientsProc, Nothing)]
               ]

      !clsScope <- contextScope . edh'context <$> edhThreadState
      iopdUpdateEdh mths $ edh'scope'entity clsScope
    where
      serverAllocator ::
        "service" !: EdhValue ->
        "addr" ?: Text ->
        "port" ?: Int ->
        "port'max" ?: Int ->
        "clients" ?: Sink ->
        "useSandbox" ?: Bool ->
        Edh (Maybe Unique, ObjectStore)
      serverAllocator
        (mandatoryArg -> !service)
        (defaultArg "127.0.0.1" -> !ctorAddr)
        (defaultArg 3721 -> !ctorPort)
        (defaultArg ctorPort -> port'max)
        (optionalArg -> maybeClients)
        (defaultArg True -> !useSandbox) = do
          !world <- edh'prog'world <$> edhProgramState
          !server <- inlineSTM $ do
            !servAddrs <- newEmptyTMVar
            !servEoL <- newEmptyTMVar
            !clients <- maybe newSink return maybeClients
            return
              EdhServer
                { edh'service'proc = service,
                  edh'service'world = world,
                  edh'server'addr = ctorAddr,
                  edh'server'port = fromIntegral ctorPort,
                  edh'server'port'max = fromIntegral port'max,
                  edh'serving'addrs = servAddrs,
                  edh'server'eol = servEoL,
                  edh'serving'clients = clients
                }
          let finalCleanup !result = atomically $ do
                -- fill empty addrs if the listening has ever failed
                void $ tryPutTMVar (edh'serving'addrs server) []
                -- mark server end-of-life anyway finally
                void $ tryPutTMVar (edh'server'eol server) result
                -- mark eos for clients sink anyway finally
                void $ postEvent (edh'serving'clients server) nil
          afterTxIO $ do
            void $ forkFinally (serverThread server) finalCleanup
          return (Nothing, HostStore (toDyn server))
          where
            serverThread :: EdhServer -> IO ()
            serverThread
              ( EdhServer
                  !servProc
                  !servWorld
                  !servAddr
                  !servPort
                  !portMax
                  !servAddrs
                  !servEoL
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
                                        T.pack $
                                          "Client ["
                                            <> show addr
                                            <> "] incurred error:\n"
                                            <> show err
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

                    let edhHandler = runNested $ do
                          -- prepare a dedicated scope atop world root scope,
                          -- with provisioned effects implanted, then call the
                          -- configured service procedure from there
                          !effsScope <-
                            contextScope . edh'context <$> edhThreadState
                          let withSandbox !maybeSandbox = do
                                let !peer =
                                      Peer
                                        { edh'peer'ident = clientId,
                                          edh'peer'sandbox = maybeSandbox,
                                          edh'peer'eol = clientEoL,
                                          edh'peer'posting = putTMVar poq,
                                          edh'peer'hosting = takeTMVar pktSink,
                                          edh'peer'disposals = disposalsVar,
                                          edh'peer'channels = chdVar
                                        }
                                !peerObj <- createHostObjectM peerClass peer
                                !netEffs <- iopdToListEdh esNetEffs
                                let effArts =
                                      ( AttrBySym symNetPeer,
                                        EdhObject peerObj
                                      ) :
                                      netEffs
                                prepareEffStoreM >>= iopdUpdateEdh effArts
                                inlineSTM $
                                  void $ postEvent clients $ EdhObject peerObj
                                callM servProc []

                          if useSandbox
                            then mkSandboxM effsScope >>= withSandbox . Just
                            else withSandbox Nothing

                    -- run the service procedure on a separate thread as another Edh program
                    --
                    -- this implements structured concurrency per client connection,
                    -- i.e. all Edh threads spawned by this client will terminate upon its
                    -- disconnection, while resource cleanups should be scheduled via defer
                    -- mechanism, or exception handling, that expecting `ThreadTerminate` to be
                    -- thrown, the cleanup action is usually in a finally block in this way
                    void $
                      forkFinally (runProgramM' servWorld edhHandler) $
                        -- anyway after the service procedure done:
                        --   dispose of all dependent (channel or not) sinks
                        --   try mark client end-of-life with the result
                        \ !result -> atomically $ do
                          !sinks2Dispose <- readTVar disposalsVar
                          sequence_ $
                            flip postEvent EdhNil <$> Set.toList sinks2Dispose
                          void $ tryPutTMVar clientEoL $ void result

                    -- pump commands in,
                    -- making this thread the only one reading the handle
                    --
                    -- note this won't return, will be asynchronously killed on eol
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

      withThisServer :: forall r. (Object -> EdhServer -> Edh r) -> Edh r
      withThisServer withServer = do
        !this <- edh'scope'this . contextScope . edh'context <$> edhThreadState
        case fromDynamic =<< dynamicHostData this of
          Nothing -> throwEdhM EvalError "bug: this is not an Server"
          Just !col -> withServer this col

      clientsProc :: Edh EdhValue
      clientsProc = withThisServer $ \_this !server ->
        return $ EdhSink $ edh'serving'clients server

      reprProc :: Edh EdhValue
      reprProc = withThisServer $
        \_this (EdhServer _proc _world !addr !port !port'max _ _ _) ->
          return $
            EdhString $
              T.pack $
                "Server<"
                  <> show addr
                  <> ", "
                  <> show port
                  <> ", port'max="
                  <> show port'max
                  <> ">"

      addrsProc :: Edh EdhValue
      addrsProc = withThisServer $ \_this !server ->
        inlineSTM (readTMVar $ edh'serving'addrs server) >>= wrapAddrs []
        where
          wrapAddrs :: [EdhValue] -> [AddrInfo] -> Edh EdhValue
          wrapAddrs addrs [] =
            return $ EdhArgsPack $ ArgsPack addrs odEmpty
          wrapAddrs !addrs (addr : rest) =
            createHostObjectM addrClass addr
              >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

      eolProc :: Edh EdhValue
      eolProc = withThisServer $ \_this !server ->
        inlineSTM (tryReadTMVar $ edh'server'eol server) >>= \case
          Nothing -> return $ EdhBool False
          Just (Left !e) -> throwHostM e
          Just (Right ()) -> return $ EdhBool True

      joinProc :: Edh EdhValue
      joinProc = withThisServer $ \_this !server ->
        inlineSTM (readTMVar $ edh'server'eol server) >>= \case
          Left !e -> throwHostM e
          Right () -> return nil

      stopProc :: Edh EdhValue
      stopProc = withThisServer $ \_this !server ->
        inlineSTM $
          fmap EdhBool $
            tryPutTMVar (edh'server'eol server) $ Right ()
