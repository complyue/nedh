
module Language.Edh.Net.Server where

import           Prelude
-- import           Debug.Trace

import           Control.Exception
import           Control.Monad
import           Control.Concurrent
import           Control.Concurrent.STM

import           Control.Monad.Reader

import           Data.Maybe
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import qualified Data.HashMap.Strict           as Map
import           Data.Dynamic

import           Network.Socket
import           Network.Socket.ByteString      ( recv
                                                , sendAll
                                                )

import qualified Data.Lossless.Decimal         as D

import           Language.Edh.EHI

import           Language.Edh.Net.MicroProto
import           Language.Edh.Net.Peer

import           Language.Edh.Net.Addr


type ServerAddr = Text
type ServerPort = PortNumber

data EdhServer = EdhServer {
    -- the import spec of the module to run as the server
      edh'server'modu :: !Text
    -- local network interface to bind
    , edh'server'addr :: !ServerAddr
    -- local network port to bind
    , edh'server'port :: !ServerPort
    -- max port number to try bind
    , edh'server'port'max :: !ServerPort
    -- actually listened network addresses
    , edh'serving'addrs :: !(TMVar [AddrInfo])
    -- end-of-life status
    , edh'server'eol :: !(TMVar (Either SomeException ()))
    -- server module initializer, must callable if not nil
    , edh'server'init :: !EdhValue
    -- each connected peer is sunk into this
    , edh'serving'clients :: !EventSink
  }


-- | host constructor Server()
serverCtor
  :: Class
  -> Class
  -> EdhProgState
  -> ArgsPack  -- ctor args, if __init__() is provided, will go there too
  -> TVar (Map.HashMap AttrKey EdhValue)  -- out-of-band attr store
  -> (Dynamic -> STM ())  -- in-band data to be written to entity store
  -> STM ()
serverCtor !addrClass !peerClass !pgsCtor !apk !obs !ctorExit =
  case
      parseArgsPack
        ( Nothing -- modu
        , "127.0.0.1" :: ServerAddr -- addr
        , 3721 :: ServerPort -- port
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
          let !server = EdhServer
                { edh'server'modu     = modu
                , edh'server'addr     = addr
                , edh'server'port     = port
                , edh'server'port'max = fromMaybe port port'max
                , edh'serving'addrs   = servAddrs
                , edh'server'eol      = servEoL
                , edh'server'init     = __peer_init__
                , edh'serving'clients = clients
                }
              !scope = contextScope $ edh'context pgsCtor
          methods <- sequence
            [ (AttrByName nm, ) <$> mkHostProc scope vc nm hp args
            | (nm, vc, hp, args) <-
              [ ("addrs", EdhMethod, addrsProc, PackReceiver [])
              , ("eol"  , EdhMethod, eolProc  , PackReceiver [])
              , ("join" , EdhMethod, joinProc , PackReceiver [])
              , ("stop" , EdhMethod, stopProc , PackReceiver [])
              ]
            ]
          modifyTVar' obs
            $  Map.union
            $  Map.fromList
            $  methods
            ++ [ (AttrByName "clients", EdhSink clients)
               , ( AttrByName "__repr__"
                 , EdhString
                 $  "Server("
                 <> T.pack (show modu)
                 <> ", "
                 <> T.pack (show addr)
                 <> ", "
                 <> T.pack (show port)
                 <> ")"
                 )
               ]
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

  addrsProc :: EdhProcedure
  addrsProc _ !exit = do
    pgs <- ask
    let
      ctx  = edh'context pgs
      this = thisObject $ contextScope ctx
      es   = entity'store $ objEntity this
      wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
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
    contEdhSTM $ do
      esd <- readTVar es
      case fromDynamic esd :: Maybe EdhServer of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a server : " <> T.pack
            (show esd)
        Just !server ->
          edhPerformSTM pgs (readTMVar $ edh'serving'addrs server)
            $ contEdhSTM
            . wrapAddrs []

  eolProc :: EdhProcedure
  eolProc _ !exit = do
    pgs <- ask
    let ctx  = edh'context pgs
        this = thisObject $ contextScope ctx
        es   = entity'store $ objEntity this
    contEdhSTM $ do
      esd <- readTVar es
      case fromDynamic esd :: Maybe EdhServer of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a server : " <> T.pack
            (show esd)
        Just !server -> tryReadTMVar (edh'server'eol server) >>= \case
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
      case fromDynamic esd :: Maybe EdhServer of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a server : " <> T.pack
            (show esd)
        Just !server ->
          edhPerformSTM pgs (readTMVar (edh'server'eol server)) $ \case
            Left e ->
              contEdhSTM $ toEdhError pgs e $ \exv -> edhThrowSTM pgs exv
            Right () -> exitEdhProc exit nil

  stopProc :: EdhProcedure
  stopProc _ !exit = do
    pgs <- ask
    let ctx  = edh'context pgs
        this = thisObject $ contextScope ctx
        es   = entity'store $ objEntity this
    contEdhSTM $ do
      esd <- readTVar es
      case fromDynamic esd :: Maybe EdhServer of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a server : " <> T.pack
            (show esd)
        Just !server -> do
          stopped <- tryPutTMVar (edh'server'eol server) $ Right ()
          exitEdhSTM pgs exit $ EdhBool stopped


  serverThread :: EdhServer -> IO ()
  serverThread (EdhServer !servModu !servAddr !servPort !portMax !servAddrs !servEoL !__peer_init__ !clients)
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
          void $ forkIO $ receivePacketStream clientId
                                              (recv sock)
                                              pktSink
                                              clientEoL

          let
            serializeCmdsOut :: IO ()
            serializeCmdsOut =
              atomically
                  (        (Right <$> takeTMVar poq)
                  `orElse` (Left <$> readTMVar clientEoL)
                  )
                >>= \case
                      Left _ -> return () -- stop on eol any way
                      Right !pkt ->
                        catch
                            (  sendPacket clientId (sendAll sock) pkt
                            >> serializeCmdsOut
                            )
                          $ \(e :: SomeException) -> -- mark eol on error
                              atomically $ void $ tryPutTMVar clientEoL $ Left e
          -- pump commands out,
          -- make this thread the only one writing the handle
          serializeCmdsOut

