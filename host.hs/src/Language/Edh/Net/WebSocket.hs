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
import Language.Edh.CHI
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
    edh'ws'serving'clients :: !EdhSink
  }

createWsServerClass ::
  (Text -> STM ()) ->
  Object ->
  Object ->
  Symbol ->
  EntityStore ->
  Scope ->
  STM Object
createWsServerClass
  !consoleWarn
  !addrClass
  !peerClass
  !symNetPeer
  !esNetEffs
  !clsOuterScope =
    mkHostClass clsOuterScope "WsServer" (allocEdhObj serverAllocator) [] $
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
        "service" !: EdhValue ->
        "addr" ?: Text ->
        "port" ?: Int ->
        "port'max" ?: Int ->
        "clients" ?: EdhSink ->
        "useSandbox" ?: Bool ->
        EdhObjectAllocator
      serverAllocator
        (mandatoryArg -> !service)
        (defaultArg "127.0.0.1" -> !ctorAddr)
        (defaultArg 3721 -> !ctorPort)
        (optionalArg -> port'max)
        (optionalArg -> maybeClients)
        (defaultArg True -> !useSandbox)
        !ctorExit
        !etsCtor = do
          !servAddrs <- newEmptyTMVar
          !servEoL <- newEmptyTMVar
          !clients <- maybe newEdhSink return maybeClients
          let !server =
                EdhWsServer
                  { edh'ws'service'proc = service,
                    edh'ws'service'world =
                      edh'prog'world $ edh'thread'prog etsCtor,
                    edh'ws'server'addr = ctorAddr,
                    edh'ws'server'port = fromIntegral ctorPort,
                    edh'ws'server'port'max =
                      fromIntegral $ fromMaybe ctorPort port'max,
                    edh'ws'serving'addrs = servAddrs,
                    edh'ws'server'eol = servEoL,
                    edh'ws'serving'clients = clients
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

                        let edhHandler = pushEdhStack $ \ !etsEffs -> do
                              -- prepare a dedicated scope atop world root scope, with net effects
                              -- implanted, then call the configured service procedure from there
                              let effsScope = contextScope $ edh'context etsEffs
                                  withSandbox !maybeSandbox = do
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
                                    !peerObj <- edhCreateHostObj peerClass peer
                                    !netEffs <- iopdToList esNetEffs
                                    (prepareEffStore etsEffs (edh'scope'entity effsScope) >>=) $
                                      iopdUpdate $
                                        [ (AttrByName "rqURI", EdhString rqURI),
                                          ( AttrByName "rqParams",
                                            EdhArgsPack $ ArgsPack [] rqParams
                                          ),
                                          (AttrBySym symNetPeer, EdhObject peerObj)
                                        ]
                                          ++ netEffs

                                    void $ postEvent clients $ EdhObject peerObj
                                    runEdhTx etsEffs $ edhMakeCall servProc [] haltEdhProgram
                              if useSandbox
                                then mkScopeSandbox etsEffs effsScope $ withSandbox . Just
                                else withSandbox Nothing

                        -- run the service procedure on a separate thread as another Edh program
                        --
                        -- this implements structured concurrency per client connection,
                        -- i.e. all Edh threads spawned by this client will terminate upon its
                        -- disconnection, while resource cleanups should be scheduled via defer
                        -- mechanism, or exception handling, that expecting `ThreadTerminate` to be
                        -- thrown, the cleanup action is usually in a finally block in this way
                        void $
                          forkFinally (runEdhProgram' servWorld edhHandler) $
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

      clientsProc :: EdhHostProc
      clientsProc !exit !ets = withThisHostObj ets $
        \ !server -> exitEdh ets exit $ EdhEvs $ edh'ws'serving'clients server

      reprProc :: EdhHostProc
      reprProc !exit !ets =
        withThisHostObj ets $
          \(EdhWsServer _proc _world !addr !port !port'max _ _ _) ->
            exitEdh ets exit $
              EdhString $
                T.pack $
                  "WsServer<"
                    <> show addr
                    <> ", "
                    <> show port
                    <> ", port'max="
                    <> show port'max
                    <> ">"

      addrsProc :: EdhHostProc
      addrsProc !exit !ets = withThisHostObj ets $
        \ !server -> readTMVar (edh'ws'serving'addrs server) >>= wrapAddrs []
        where
          wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
          wrapAddrs addrs [] =
            exitEdh ets exit $ EdhArgsPack $ ArgsPack addrs odEmpty
          wrapAddrs !addrs (addr : rest) =
            edhCreateHostObj addrClass addr
              >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

      eolProc :: EdhHostProc
      eolProc !exit !ets = withThisHostObj ets $ \ !server ->
        tryReadTMVar (edh'ws'server'eol server) >>= \case
          Nothing -> exitEdh ets exit $ EdhBool False
          Just (Left !e) ->
            edh'exception'wrapper world (Just ets) e
              >>= \ !exo -> exitEdh ets exit $ EdhObject exo
          Just (Right ()) -> exitEdh ets exit $ EdhBool True
        where
          world = edh'prog'world $ edh'thread'prog ets

      joinProc :: EdhHostProc
      joinProc !exit !ets = withThisHostObj ets $ \ !server ->
        readTMVar (edh'ws'server'eol server) >>= \case
          Left !e ->
            edh'exception'wrapper world (Just ets) e
              >>= \ !exo -> edhThrow ets $ EdhObject exo
          Right () -> exitEdh ets exit nil
        where
          world = edh'prog'world $ edh'thread'prog ets

      stopProc :: EdhHostProc
      stopProc !exit !ets = withThisHostObj ets $ \ !server -> do
        stopped <- tryPutTMVar (edh'ws'server'eol server) $ Right ()
        exitEdh ets exit $ EdhBool stopped

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
