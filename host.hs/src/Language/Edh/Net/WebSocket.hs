module Language.Edh.Net.WebSocket where

-- import           Debug.Trace

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as BL
import Data.Dynamic
import Data.Functor
import qualified Data.HashSet as Set
import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Language.Edh.EHI
import Language.Edh.Net.Addr
import Language.Edh.Net.MicroProto
import Language.Edh.Net.Peer
import Network.Socket
import qualified Network.WebSockets as WS
import qualified Snap.Core as Snap
import Prelude

data EdhWsServer = EdhWsServer
  { -- Edh procedure to run for the service
    edh'ws'service'proc :: !EdhValue,
    -- the world in which the service will run
    edh'ws'service'world :: !EdhWorld,
    -- local network interface to bind
    edh'ws'server'addr :: !Text,
    -- local network port to bind
    edh'ws'server'port :: !PortNumber,
    -- max port number to try bind
    edh'ws'server'port'max :: !PortNumber,
    -- actually listened network addresses
    edh'ws'serving'addrs :: !(TMVar [AddrInfo]),
    -- end-of-life status
    edh'ws'server'eol :: !(TMVar (Either SomeException ())),
    -- each connected peer is sunk into this
    edh'ws'serving'clients :: !Sink
  }

createWsServerClass ::
  (Text -> STM ()) ->
  Object ->
  Object ->
  Symbol ->
  EntityStore ->
  Edh Object
createWsServerClass
  !consoleWarn
  !addrClass
  !peerClass
  !symNetPeer
  !esNetEffs =
    mkEdhClass "WsServer" (allocObjM serverAllocator) [] $ do
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
        (optionalArg -> port'max)
        (optionalArg -> maybeClients)
        (defaultArg True -> !useSandbox) = do
          !world <- edh'prog'world <$> edhProgramState
          !server <- inlineSTM $ do
            !servAddrs <- newEmptyTMVar
            !servEoL <- newEmptyTMVar
            !clients <- maybe newSink return maybeClients
            return
              EdhWsServer
                { edh'ws'service'proc = service,
                  edh'ws'service'world = world,
                  edh'ws'server'addr = ctorAddr,
                  edh'ws'server'port = fromIntegral ctorPort,
                  edh'ws'server'port'max =
                    fromIntegral $ fromMaybe ctorPort port'max,
                  edh'ws'serving'addrs = servAddrs,
                  edh'ws'server'eol = servEoL,
                  edh'ws'serving'clients = clients
                }
          let finalCleanup !result = atomically $ do
                -- fill empty addrs if the listening has ever failed
                void $ tryPutTMVar (edh'ws'serving'addrs server) []
                -- mark server end-of-life anyway finally
                void $ tryPutTMVar (edh'ws'server'eol server) result
                -- mark eos for clients sink anyway finally
                void $ postEvent (edh'ws'serving'clients server) nil

          afterTxIO $ do
            void $ forkFinally (serverThread server) finalCleanup
          return (Nothing, HostStore (toDyn server))
          where
            serverThread :: EdhWsServer -> IO ()
            serverThread
              ( EdhWsServer
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
                  servThId <- myThreadId
                  void $
                    forkIO $ do
                      -- async terminate the accepter thread on stop signal
                      _ <- atomically $ readTMVar servEoL
                      killThread servThId
                  addr <- resolveServAddr
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
                    bracketOnError (accept ssock) (close . fst) $
                      \(sock, addr) -> do
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
                                          "WsServer client ["
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
                    !pConn <-
                      WS.makePendingConnection sock $
                        WS.defaultConnectionOptions {WS.connectionStrictUnicode = True}
                    case parseWsRequest $ WS.pendingRequest pConn of
                      Left !err -> WS.rejectRequest pConn err
                      Right (!rqURI, !rqParams) -> do
                        !wsc <- WS.acceptRequest pConn
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
                                          [ (AttrByName "rqURI", EdhString rqURI),
                                            ( AttrByName "rqParams",
                                              EdhArgsPack $ ArgsPack [] rqParams
                                            ),
                                            (AttrBySym symNetPeer, EdhObject peerObj)
                                          ]
                                            ++ netEffs
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
                        !incomingDir <- newIORef ("" :: Text)
                        let settlePkt !payload = do
                              !dir <- readIORef incomingDir
                              -- channel directive is effective only for the
                              -- immediately following packet
                              writeIORef incomingDir ""
                              atomically
                                ( (Right <$> putTMVar pktSink (Packet dir payload))
                                    `orElse` (Left <$> readTMVar clientEoL)
                                )
                                >>= \case
                                  Left (Left e) -> throwIO e
                                  Left (Right ()) -> return ()
                                  -- anyway we should continue receiving, even
                                  -- after close request sent, we are expected to
                                  -- process a CloseRequest ctrl message from peer
                                  Right _ -> pumpPkts

                            pumpPkts =
                              WS.receiveDataMessage wsc >>= \case
                                (WS.Text !bytes _) ->
                                  case BL.stripPrefix "[dir#" bytes of
                                    Just !dirRest ->
                                      case BL.stripSuffix "]" dirRest of
                                        Just !dir -> do
                                          writeIORef incomingDir $
                                            TL.toStrict $ TLE.decodeUtf8 dir
                                          pumpPkts
                                        Nothing -> settlePkt $ BL.toStrict bytes
                                    Nothing -> settlePkt $ BL.toStrict bytes
                                (WS.Binary !payload) ->
                                  settlePkt $ BL.toStrict payload

                        void $
                          forkIOWithUnmask $ \unmask -> catch (unmask pumpPkts) $
                            \case
                              WS.CloseRequest closeCode closeReason
                                | closeCode == 1000 || closeCode == 1001 ->
                                  atomically $
                                    void $ tryPutTMVar clientEoL $ Right ()
                                | otherwise ->
                                  do
                                    atomically $
                                      void $
                                        tryPutTMVar clientEoL $
                                          Left $
                                            toException $
                                              EdhPeerError clientId $
                                                T.pack $
                                                  "Client closing WebSocket with code "
                                                    <> show closeCode
                                                    <> " and reason ["
                                                    <> show closeReason
                                                    <> "]"
                                    -- yet still try to receive ctrl msg back from peer
                                    unmask pumpPkts
                              WS.ConnectionClosed ->
                                atomically $
                                  void $ tryPutTMVar clientEoL $ Right ()
                              _ ->
                                atomically $
                                  void $
                                    tryPutTMVar clientEoL $
                                      Left $
                                        toException $
                                          EdhPeerError
                                            clientId
                                            "unexpected WebSocket packet."

                        let sendWsPacket :: Packet -> IO ()
                            sendWsPacket (Packet !dir !payload) =
                              if "blob:" `T.isPrefixOf` dir
                                then do
                                  WS.sendDataMessage wsc $
                                    flip WS.Text Nothing $
                                      TLE.encodeUtf8 $
                                        ("[dir#" :: TL.Text)
                                          <> TL.fromStrict dir
                                          <> "]"
                                  WS.sendDataMessage wsc $
                                    WS.Binary $ BL.fromStrict payload
                                else do
                                  unless (T.null dir) $
                                    WS.sendDataMessage wsc $
                                      flip WS.Text Nothing $
                                        TLE.encodeUtf8 $
                                          ("[dir#" :: TL.Text)
                                            <> TL.fromStrict dir
                                            <> "]"
                                  WS.sendDataMessage wsc $
                                    WS.Text (BL.fromStrict payload) Nothing

                            serializeCmdsOut :: IO ()
                            serializeCmdsOut =
                              atomically
                                ( (Right <$> takeTMVar poq)
                                    `orElse` (Left <$> readTMVar clientEoL)
                                )
                                >>= \case
                                  Left _ -> return () -- stop on eol any way
                                  Right !pkt -> do
                                    sendWsPacket pkt
                                    serializeCmdsOut

                        -- pump commands out,
                        -- making this thread the only one writing the handle
                        catch serializeCmdsOut $ \(e :: SomeException) ->
                          -- mark eol on error
                          atomically $ void $ tryPutTMVar clientEoL $ Left e

      withThisServer :: forall r. (Object -> EdhWsServer -> Edh r) -> Edh r
      withThisServer withServer = do
        !this <- edh'scope'this . contextScope . edh'context <$> edhThreadState
        case fromDynamic =<< dynamicHostData this of
          Nothing -> throwEdhM EvalError "bug: this is not an Server"
          Just !col -> withServer this col

      clientsProc :: Edh EdhValue
      clientsProc = withThisServer $ \_this !server ->
        return $ EdhSink $ edh'ws'serving'clients server

      reprProc :: Edh EdhValue
      reprProc = withThisServer $
        \_this (EdhWsServer _proc _world !addr !port !port'max _ _ _) ->
          return $
            EdhString $
              T.pack $
                "WsServer<"
                  <> show addr
                  <> ", "
                  <> show port
                  <> ", port'max="
                  <> show port'max
                  <> ">"

      addrsProc :: Edh EdhValue
      addrsProc = withThisServer $ \_this !server ->
        inlineSTM (readTMVar $ edh'ws'serving'addrs server) >>= wrapAddrs []
        where
          wrapAddrs :: [EdhValue] -> [AddrInfo] -> Edh EdhValue
          wrapAddrs addrs [] =
            return $ EdhArgsPack $ ArgsPack addrs odEmpty
          wrapAddrs !addrs (addr : rest) =
            createHostObjectM addrClass addr
              >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

      eolProc :: Edh EdhValue
      eolProc = withThisServer $ \_this !server ->
        inlineSTM (tryReadTMVar $ edh'ws'server'eol server) >>= \case
          Nothing -> return $ EdhBool False
          Just (Left !e) -> throwHostM e
          Just (Right ()) -> return $ EdhBool True

      joinProc :: Edh EdhValue
      joinProc = withThisServer $ \_this !server ->
        inlineSTM (readTMVar $ edh'ws'server'eol server) >>= \case
          Left !e -> throwHostM e
          Right () -> return nil

      stopProc :: Edh EdhValue
      stopProc = withThisServer $ \_this !server ->
        inlineSTM $
          fmap EdhBool $
            tryPutTMVar (edh'ws'server'eol server) $ Right ()

parseWsRequest :: WS.RequestHead -> Either ByteString (Text, KwArgs)
parseWsRequest !reqHead = do
  let (!rqURIBytes, !rqQueryString) =
        C.break (== '?') (WS.requestPath reqHead)
  case Snap.urlDecode rqURIBytes of
    Nothing -> Left $ TE.encodeUtf8 "bad request path"
    Just !pathBytes -> do
      !rqURI <- decode1 pathBytes
      if C.length rqQueryString < 1
        then return (rqURI, odEmpty)
        else
          (rqURI,)
            <$> decodeParams (Snap.parseUrlEncoded $ C.tail rqQueryString)
  where
    decodeParams ::
      Map.Map ByteString [ByteString] -> Either ByteString KwArgs
    decodeParams = go [] . Map.toDescList

    go ::
      [(Text, [Text])] ->
      [(ByteString, [ByteString])] ->
      Either ByteString KwArgs
    go result [] =
      Right $ odFromList [(AttrByName k, wrapVs vs) | (k, vs) <- result]
    go result ((n, vs) : rest) = do
      !n' <- decode1 n
      !vs' <- sequence $ decode1 <$> vs
      go ((n', vs') : result) rest

    decode1 :: ByteString -> Either ByteString Text
    decode1 !bytes = case TE.decodeUtf8' bytes of
      Left !exc -> Left $ TE.encodeUtf8 $ T.pack $ show exc
      Right !txt -> return txt

    wrapVs :: [Text] -> EdhValue
    wrapVs [] = edhNone
    wrapVs [v] = EdhString v
    wrapVs vs = EdhArgsPack $ flip ArgsPack odEmpty $ vs <&> EdhString
