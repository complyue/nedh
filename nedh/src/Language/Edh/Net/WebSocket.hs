
module Language.Edh.Net.WebSocket where

import           Prelude
-- import           Debug.Trace

import           Control.Exception
import           Control.Monad
import           Control.Concurrent
import           Control.Concurrent.STM

import           Data.Maybe
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import qualified Data.Text.Lazy                as TL
import qualified Data.Text.Lazy.Encoding       as TLE
import qualified Data.ByteString.Lazy          as BL
import qualified Data.HashMap.Strict           as Map
import           Data.Dynamic
import           Data.IORef

import           Network.Socket
import qualified Network.WebSockets            as WS

import qualified Data.Lossless.Decimal         as D

import           Language.Edh.EHI

import           Language.Edh.Net.MicroProto
import           Language.Edh.Net.Peer

import           Language.Edh.Net.Addr


type WsServerAddr = Text
type WsServerPort = PortNumber

data EdhWsServer = EdhWsServer {
    -- the import spec of the module to run as the server
      edh'ws'server'modu :: !Text
    -- local network interface to bind
    , edh'ws'server'addr :: !WsServerAddr
    -- local network port to bind
    , edh'ws'server'port :: !WsServerPort
    -- max port number to try bind
    , edh'ws'server'port'max :: !WsServerPort
    -- actually listened network addresses
    , edh'ws'serving'addrs :: !(TMVar [AddrInfo])
    -- end-of-life status
    , edh'ws'server'eol :: !(TMVar (Either SomeException ()))
    -- server module initializer, must callable if not nil
    , edh'ws'server'init :: !EdhValue
    -- each connected peer is sunk into this
    , edh'ws'serving'clients :: !EventSink
  }


-- | host constructor WsServer()
wsServerCtor :: Class -> EdhHostCtor
wsServerCtor !peerClass !pgsCtor !apk !ctorExit =
  case
      parseArgsPack
        ( Nothing -- modu
        , "127.0.0.1" :: WsServerAddr -- addr
        , 3790 :: WsServerPort -- port
        , Nothing -- port'max
        , nil -- __peer_init__
        , Nothing -- maybeClients
        )
        parseCtorArgs
        apk
    of
      Left err -> throwEdhSTM pgsCtor UsageError err
      Right (Nothing, _, _, _, _, _) ->
        throwEdhSTM pgsCtor UsageError "missing server module"
      Right (Just !modu, !addr, !port, !port'max, !__peer_init__, !maybeClients)
        -> do
          servAddrs <- newEmptyTMVar
          servEoL   <- newEmptyTMVar
          clients   <- maybe newEventSink return maybeClients
          let !server = EdhWsServer
                { edh'ws'server'modu     = modu
                , edh'ws'server'addr     = addr
                , edh'ws'server'port     = port
                , edh'ws'server'port'max = fromMaybe port port'max
                , edh'ws'serving'addrs   = servAddrs
                , edh'ws'server'eol      = servEoL
                , edh'ws'server'init     = __peer_init__
                , edh'ws'serving'clients = clients
                }
          edhPerformIO
              pgsCtor
              (forkFinally
                (serverThread server)
                ( atomically
                . ((
                    -- fill empty addrs if the connection has ever failed
                    tryPutTMVar servAddrs [] >>
                    -- mark eos for clients sink anyway finally
                                                publishEvent clients nil) <*)
                  -- mark server end-of-life anyway finally
                . tryPutTMVar servEoL
                )
              )
            $ \_ -> contEdhSTM $ ctorExit $ toDyn server
 where
  parseCtorArgs =
    ArgsPackParser
        [ \arg (_, addr', port', port'max, init', clients') ->
          case edhUltimate arg of
            EdhString !modu ->
              Right (Just modu, addr', port', port'max, init', clients')
            _ -> Left "Invalid modu"
        , \arg (modu', _, port', port'max, init', clients') ->
          case edhUltimate arg of
            EdhString !addr ->
              Right (modu', addr, port', port'max, init', clients')
            _ -> Left "Invalid addr"
        , \arg (modu', addr', _, port'max, init', clients') ->
          case edhUltimate arg of
            EdhDecimal !d -> case D.decimalToInteger d of
              Just !port -> Right
                (modu', addr', fromIntegral port, port'max, init', clients')
              Nothing -> Left "port must be integer"
            _ -> Left "Invalid port"
        ]
      $ Map.fromList
          [ ( "addr"
            , \arg (modu', _, port', port'max, init', clients') ->
              case edhUltimate arg of
                EdhString !addr ->
                  Right (modu', addr, port', port'max, init', clients')
                _ -> Left "Invalid addr"
            )
          , ( "port"
            , \arg (modu', addr', _, port'max, init', clients') ->
              case edhUltimate arg of
                EdhDecimal !d -> case D.decimalToInteger d of
                  Just !port ->
                    Right
                      ( modu'
                      , addr'
                      , fromIntegral port
                      , port'max
                      , init'
                      , clients'
                      )
                  Nothing -> Left "port must be integer"
                _ -> Left "Invalid port"
            )
          , ( "port'max"
            , \arg (modu', addr', port', _, init', clients') ->
              case edhUltimate arg of
                EdhDecimal d -> case D.decimalToInteger d of
                  Just !port'max ->
                    Right
                      ( modu'
                      , addr'
                      , port'
                      , Just $ fromInteger port'max
                      , init'
                      , clients'
                      )
                  Nothing -> Left "port'max must be integer"
                _ -> Left "Invalid port'max"
            )
          , ( "init"
            , \arg (modu', addr', port', port'max, _, clients') ->
              case edhUltimate arg of
                EdhNil -> Right (modu', addr', port', port'max, nil, clients')
                mth@EdhMethod{} ->
                  Right (modu', addr', port', port'max, mth, clients')
                mth@EdhIntrpr{} ->
                  Right (modu', addr', port', port'max, mth, clients')
                _ -> Left "Invalid init"
            )
          , ( "clients"
            , \arg (modu', addr', port', port'max, init', _) ->
              case edhUltimate arg of
                EdhSink !sink ->
                  Right (modu', addr', port', port'max, init', Just sink)
                _ -> Left "Invalid clients"
            )
          ]

  serverThread :: EdhWsServer -> IO ()
  serverThread (EdhWsServer !servModu !servAddr !servPort !portMax !servAddrs !servEoL !__peer_init__ !clients)
    = do
      servThId <- myThreadId
      void $ forkIO $ do -- async terminate the accepter thread on stop signal
        _ <- atomically $ readTMVar servEoL
        killThread servThId
      addr <- resolveServAddr
      bracket (open addr) close acceptClients
   where
    ctx             = edh'context pgsCtor
    world           = contextWorld ctx

    resolveServAddr = do
      let hints =
            defaultHints { addrFlags = [AI_PASSIVE], addrSocketType = Stream }
      addr : _ <- getAddrInfo (Just hints)
                              (Just $ T.unpack servAddr)
                              (Just (show servPort))
      return addr

    tryBind !ssock !addr !port =
      catch (bind ssock $ addrWithPort addr port) $ \(e :: SomeException) ->
        if port < portMax then tryBind ssock addr (port + 1) else throw e
    open addr =
      bracketOnError
          (socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr))
          close
        $ \ssock -> do
            tryBind ssock (addrAddress addr) servPort
            listen ssock 300 -- todo make this tunable ?
            listenAddr <- getSocketName ssock
            atomically
              $   fromMaybe []
              <$> tryTakeTMVar servAddrs
              >>= putTMVar servAddrs
              .   (addr { addrAddress = listenAddr } :)
            return ssock

    acceptClients :: Socket -> IO ()
    acceptClients ssock = do
      bracketOnError (accept ssock) (close . fst) $ \(sock, addr) -> do
        clientEoL <- newEmptyTMVarIO
        void
          $ forkFinally (servClient clientEoL (T.pack $ show addr) sock)
          $ (gracefulClose sock 5000 <*)
          . atomically
          . tryPutTMVar clientEoL
      acceptClients ssock -- tail recursion

    servClient :: TMVar (Either SomeException ()) -> Text -> Socket -> IO ()
    servClient !clientEoL !clientId !sock = do
      pConn <- WS.makePendingConnection sock
        $ WS.defaultConnectionOptions { WS.connectionStrictUnicode = True }
      wsc     <- WS.acceptRequest pConn
      pktSink <- newEmptyTMVarIO
      poq     <- newEmptyTMVarIO
      chdVar  <- newTVarIO mempty

      let
        !peer = Peer { edh'peer'ident    = clientId
                     , edh'peer'eol      = clientEoL
                     , edh'peer'posting  = putTMVar poq
                     , edh'peer'hosting  = takeTMVar pktSink
                     , edh'peer'channels = chdVar
                     }
        prepPeer :: IO EdhValue
        prepPeer = do
          peerVar <- newTVarIO undefined
          void
            $ runEdhProgram' ctx
            $ createEdhObject peerClass (ArgsPack [] mempty)
            $ \(OriginalValue !peerVal _ _) -> case peerVal of
                EdhObject !peerObj -> contEdhSTM $ do
                  -- actually fill in the in-band entity storage here
                  writeTVar (entity'store $ objEntity peerObj) $ toDyn peer
                  -- announce this new peer to the event sink
                  publishEvent clients peerVal
                  -- save it and this part done
                  writeTVar peerVar peerVal
                _ -> error "bug: Peer ctor returned non-object"
          readTVarIO peerVar
        prepService :: EdhValue -> EdhModulePreparation
        prepService !peerVal !pgs !exit = do
          let !modu = thisObject $ contextScope $ edh'context pgs
          -- implant to the module being prepared
          changeEntityAttr pgs (objEntity modu) (AttrByName "peer") peerVal
          -- insert a tick here, for serving to start in next stm tx
          flip (exitEdhSTM pgs) nil $ \_ -> contEdhSTM $ if __peer_init__ == nil
            then exit
            else
              -- call the per-connection peer module initialization method,
              -- with the module object as `that`
              edhMakeCall pgs
                          __peer_init__
                          (thisObject $ contextScope $ edh'context pgs)
                          []
                          id
                $ \mkCall -> runEdhProc pgs $ mkCall $ \_ -> contEdhSTM exit

      try prepPeer >>= \case
        Left err -> atomically $ do
          -- mark the client eol with this error
          void $ tryPutTMVar clientEoL (Left err)
          -- failure in preparation for a peer object is considered so fatal
          -- that the server should terminate as well
          void $ tryPutTMVar servEoL (Left err)
        Right !peerVal -> do

          void
            -- run the server module on a separate thread as another program
            $ forkFinally
                (runEdhModule' world (T.unpack servModu) (prepService peerVal))
            -- mark client end-of-life with the result anyway
            $ void
            . atomically
            . tryPutTMVar clientEoL
            . void

          -- pump commands in, 
          -- make this thread the only one reading the handle
          -- note this won't return, will be asynchronously killed on eol
          incomingDir <- newIORef ("" :: Text)
          let
            settlePkt !payload = do
              dir <- readIORef incomingDir
              -- channel directive is effective only for the immediately
              -- following packet
              writeIORef incomingDir ""
              atomically
                  (        (Right <$> putTMVar pktSink (Packet dir payload))
                  `orElse` (Left <$> readTMVar clientEoL)
                  )
                >>= \case
                      Left (Left  e ) -> throwIO e
                      Left (Right ()) -> return ()
                      Right _ ->
              -- anyway we should continue receiving, even after close request
              -- sent,  we are expected to process a CloseRequest ctrl message
              -- from peer.
                        pumpPkts
            pumpPkts = do
              pkt <- WS.receiveDataMessage wsc
              case pkt of
                (WS.Text !bytes _) -> case BL.stripPrefix "[dir#" bytes of
                  Just !dirRest -> case BL.stripSuffix "]" dirRest of
                    Just !dir -> do
                      writeIORef incomingDir $ TL.toStrict $ TLE.decodeUtf8 dir
                      pumpPkts
                    Nothing -> settlePkt $ BL.toStrict bytes
                  Nothing -> settlePkt $ BL.toStrict bytes
                (WS.Binary !payload) -> settlePkt $ BL.toStrict payload
          void $ forkIOWithUnmask $ \unmask -> catch (unmask pumpPkts) $ \case
            WS.CloseRequest closeCode closeReason
              | closeCode == 1000 || closeCode == 1001
              -> atomically $ void $ tryPutTMVar clientEoL $ Right ()
              | otherwise
              -> do
                atomically
                  $  void
                  $  tryPutTMVar clientEoL
                  $  Left
                  $  toException
                  $  EdhPeerError clientId
                  $  T.pack
                  $  "Client closing WebSocket with code "
                  <> show closeCode
                  <> " and reason ["
                  <> show closeReason
                  <> "]"
                -- yet still try to receive ctrl msg back from peer
                unmask pumpPkts
            WS.ConnectionClosed ->
              atomically $ void $ tryPutTMVar clientEoL $ Right ()
            _ ->
              atomically
                $ void
                $ tryPutTMVar clientEoL
                $ Left
                $ toException
                $ EdhPeerError clientId "Unexpected WebSocket packet."

          let
            sendWsPacket :: Packet -> IO ()
            sendWsPacket (Packet !dir !payload) = if "blob:" `T.isPrefixOf` dir
              then do
                WS.sendDataMessage wsc
                  $  flip WS.Text Nothing
                  $  TLE.encodeUtf8
                  $  ("[dir#" :: TL.Text)
                  <> TL.fromStrict dir
                  <> "]"
                WS.sendDataMessage wsc $ WS.Binary $ BL.fromStrict payload
              else do
                unless (T.null dir)
                  $  WS.sendDataMessage wsc
                  $  flip WS.Text Nothing
                  $  TLE.encodeUtf8
                  $  ("[dir#" :: TL.Text)
                  <> TL.fromStrict dir
                  <> "]"
                WS.sendDataMessage wsc $ WS.Text (BL.fromStrict payload) Nothing

            serializeCmdsOut :: IO ()
            serializeCmdsOut =
              atomically
                  (        (Right <$> takeTMVar poq)
                  `orElse` (Left <$> readTMVar clientEoL)
                  )
                >>= \case
                      Left  _    -> return () -- stop on eol any way
                      Right !pkt -> do
                        sendWsPacket pkt
                        serializeCmdsOut
          -- pump commands out,
          -- make this thread the only one writing the handle
          serializeCmdsOut `catch` \(e :: SomeException) -> -- mark eol on error
            atomically $ void $ tryPutTMVar clientEoL $ Left e


wsServerMethods :: Class -> EdhProgState -> STM [(AttrKey, EdhValue)]
wsServerMethods !addrClass !pgsModule = sequence
  [ (AttrByName nm, ) <$> mkHostProc scope vc nm hp args
  | (nm, vc, hp, args) <-
    [ ("addrs"   , EdhMethod, addrsProc  , PackReceiver [])
    , ("eol"     , EdhMethod, eolProc    , PackReceiver [])
    , ("join"    , EdhMethod, joinProc   , PackReceiver [])
    , ("stop"    , EdhMethod, stopProc   , PackReceiver [])
    , ("clients" , EdhMethod, clientsProc, PackReceiver [])
    , ("__repr__", EdhMethod, reprProc   , PackReceiver [])
    ]
  ]
 where
  !scope = contextScope $ edh'context pgsModule

  clientsProc :: EdhProcedure
  clientsProc _ !exit = withThatEntityStore $ \ !pgs !server ->
    exitEdhSTM pgs exit $ EdhSink $ edh'ws'serving'clients server

  reprProc :: EdhProcedure
  reprProc _ !exit =
    withThatEntityStore
      $ \ !pgs (EdhWsServer !modu !addr !port !port'max _ _ _ _) ->
          exitEdhSTM pgs exit
            $  EdhString
            $  "WsServer("
            <> T.pack (show modu)
            <> ", "
            <> T.pack (show addr)
            <> ", "
            <> T.pack (show port)
            <> T.pack (show port)
            <> ", port'max="
            <> T.pack (show port'max)
            <> ")"

  addrsProc :: EdhProcedure
  addrsProc _ !exit = withThatEntityStore $ \ !pgs !server -> do
    let wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
        wrapAddrs addrs [] =
          exitEdhSTM pgs exit $ EdhArgsPack $ ArgsPack addrs mempty
        wrapAddrs !addrs (addr : rest) =
          runEdhProc pgs
            $ createEdhObject addrClass (ArgsPack [] mempty)
            $ \(OriginalValue !addrVal _ _) -> case addrVal of
                EdhObject !addrObj -> contEdhSTM $ do
                  -- actually fill in the in-band entity storage here
                  writeTVar (entity'store $ objEntity addrObj) $ toDyn addr
                  wrapAddrs (addrVal : addrs) rest
                _ -> error "bug: addr ctor returned non-object"
    edhPerformSTM pgs (readTMVar $ edh'ws'serving'addrs server)
      $ contEdhSTM
      . wrapAddrs []

  eolProc :: EdhProcedure
  eolProc _ !exit = withThatEntityStore $ \ !pgs !server ->
    tryReadTMVar (edh'ws'server'eol server) >>= \case
      Nothing         -> exitEdhSTM pgs exit $ EdhBool False
      Just (Left  e ) -> toEdhError pgs e $ \exv -> exitEdhSTM pgs exit exv
      Just (Right ()) -> exitEdhSTM pgs exit $ EdhBool True

  joinProc :: EdhProcedure
  joinProc _ !exit = withThatEntityStore $ \ !pgs !server ->
    edhPerformSTM pgs (readTMVar (edh'ws'server'eol server)) $ \case
      Left  e  -> contEdhSTM $ toEdhError pgs e $ \exv -> edhThrowSTM pgs exv
      Right () -> exitEdhProc exit nil

  stopProc :: EdhProcedure
  stopProc _ !exit = withThatEntityStore $ \ !pgs !server -> do
    stopped <- tryPutTMVar (edh'ws'server'eol server) $ Right ()
    exitEdhSTM pgs exit $ EdhBool stopped


