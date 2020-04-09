
module Language.Edh.Net.Server where

import           Prelude
-- import           Debug.Trace

import           GHC.Conc                       ( unsafeIOToSTM )

import           System.IO

import           Control.Exception
import           Control.Monad
import           Control.Concurrent
import           Control.Concurrent.STM

import           Control.Monad.Reader

import           Data.Unique
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import           Data.Text.Encoding
import qualified Data.HashMap.Strict           as Map
import           Data.Dynamic

import           Network.Socket

import qualified Data.Lossless.Decimal         as D

import           Language.Edh.EHI

import           Language.Edh.Net.MicroProto
import           Language.Edh.Net.Peer


type ServingAddr = Text
type ServingPort = Int

data EdhServer = EdhServer {
    -- the import spec of the module to run as the service
      edh'service'modu :: !Text
    -- local network interface to bind
    , edh'service'addr :: !ServingAddr
    -- local network port to bind
    , edh'service'port :: !ServingPort
    -- end-of-life status
    , edh'service'eol :: !(TMVar (Either SomeException ()))
    -- service module initializer, must callable if not nil
    , edh'service'init :: !EdhValue
    -- connected peers by id
    , edh'service'clients :: !Dict
  }


-- | host constructor Server()
serverCtor
  :: Class
  -> EdhProgState
  -> ArgsPack  -- ctor args, if __init__() is provided, will go there too
  -> TVar (Map.HashMap AttrKey EdhValue)  -- out-of-band attr store
  -> (Dynamic -> STM ())  -- in-band data to be written to entity store
  -> STM ()
serverCtor !peerClass !pgsCtor !apk !obs !ctorExit =
  case
      parseArgsPack
        (Nothing, "127.0.0.1" :: ServingAddr, 3721 :: ServingPort, nil)
        parseCtorArgs
        apk
    of
      Left err -> throwEdhSTM pgsCtor UsageError err
      Right (Nothing, _, _, _) ->
        throwEdhSTM pgsCtor UsageError "missing service module"
      Right (Just service, addr, port, __serv_init__) -> do
        eol <- newEmptyTMVar
        u   <- unsafeIOToSTM newUnique
        ds  <- newTVar Map.empty
        let !server = EdhServer { edh'service'modu    = service
                                , edh'service'addr    = addr
                                , edh'service'port    = port
                                , edh'service'eol     = eol
                                , edh'service'init    = __serv_init__
                                , edh'service'clients = Dict u ds
                                }
            !scope = contextScope $ edh'context pgsCtor
        methods <- sequence
          [ (AttrByName nm, ) <$> mkHostProc scope vc nm hp args
          | (nm, vc, hp, args) <-
            [ ("eol" , EdhMethod, eolProc , PackReceiver [])
            , ("join", EdhMethod, joinProc, PackReceiver [])
            , ("stop", EdhMethod, stopProc, PackReceiver [])
            ]
          ]
        modifyTVar' obs
          $  Map.union
          $  Map.fromList
          $  methods
          ++ [ (AttrByName "clients", EdhDict $ edh'service'clients server)
             , ( AttrByName "__repr__"
               , EdhString
               $  "Server("
               <> T.pack (show service)
               <> ", "
               <> T.pack (show addr)
               <> ", "
               <> T.pack (show port)
               <> ")"
               )
             ]
        edhPerformIO
            pgsCtor
            (forkFinally (serviceThread server)
                         (void . atomically . tryPutTMVar eol)
            )
          $ \_ -> ctorExit $ toDyn server
 where
  parseCtorArgs =
    ArgsPackParser
        [ \arg (_, addr', port', init') -> case arg of
          EdhString !service -> Right (Just service, addr', port', init')
          _                  -> Left "Invalid service"
        , \arg (service', _, port', init') -> case arg of
          EdhString addr -> Right (service', addr, port', init')
          _              -> Left "Invalid addr"
        , \arg (service', addr', _, init') -> case arg of
          EdhDecimal d -> case D.decimalToInteger d of
            Just port -> Right (service', addr', fromIntegral port, init')
            Nothing   -> Left "port must be integer"
          _ -> Left "Invalid port"
        ]
      $ Map.fromList
          [ ( "addr"
            , \arg (service', _, port', init') -> case arg of
              EdhString addr -> Right (service', addr, port', init')
              _              -> Left "Invalid addr"
            )
          , ( "port"
            , \arg (service', addr', _, init') -> case arg of
              EdhDecimal d -> case D.decimalToInteger d of
                Just port -> Right (service', addr', fromIntegral port, init')
                Nothing   -> Left "port must be integer"
              _ -> Left "Invalid port"
            )
          , ( "init"
            , \arg (service', addr', port', _) -> case arg of
              EdhNil          -> Right (service', addr', port', nil)
              mth@EdhMethod{} -> Right (service', addr', port', mth)
              mth@EdhIntrpr{} -> Right (service', addr', port', mth)
              _               -> Left "Invalid init"
            )
          ]

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
          throwEdhSTM pgs UsageError $ "bug: this is not a peer : " <> T.pack
            (show esd)
        Just !server -> tryReadTMVar (edh'service'eol server) >>= \case
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
          throwEdhSTM pgs UsageError $ "bug: this is not a peer : " <> T.pack
            (show esd)
        Just !server -> readTMVar (edh'service'eol server) >>= \case
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
      case fromDynamic esd :: Maybe EdhServer of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a peer : " <> T.pack
            (show esd)
        Just !server -> do
          stopped <- tryPutTMVar (edh'service'eol server) $ Right ()
          exitEdhSTM pgs exit $ EdhBool stopped


  serviceThread :: EdhServer -> IO ()
  serviceThread (EdhServer !servModu !servAddr !servPort !servEoL !__serv_init__ (Dict _ !clientsDS))
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
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption sock ReuseAddr 1
      bind sock (addrAddress addr)
      listen sock 30
      return sock
    acceptClients :: Socket -> IO ()
    acceptClients sock = do
      (conn, addr) <- accept sock
      hndl         <- socketToHandle conn ReadWriteMode
      clientEoL    <- newEmptyTMVarIO
      void
        $ forkFinally (servClient clientEoL (show addr) hndl)
        $ (hClose hndl <*) -- close the socket anyway
        . atomically
        . tryPutTMVar clientEoL

      acceptClients sock -- tail recursion

    servClient :: TMVar (Either SomeException ()) -> String -> Handle -> IO ()
    servClient !eol !clientId !hndl = do
      pktSink <- newEmptyTMVarIO
      poq     <- newTQueueIO

      let
        ho :: STM CommCmd
        ho = do
          (dir, payload) <- takeTMVar pktSink
          return $ CommCmd dir $ decodeUtf8 payload
        po :: CommCmd -> STM ()
        po    = writeTQueue poq

        !peer = Peer { peer'ident      = T.pack clientId
                     , peer'eol        = eol
                     , peer'hosting    = ho
                     , postPeerCommand = po
                     }
        prepService :: EdhModulePreparation
        prepService !pgs !exit =
          runEdhProc pgs
            $ createEdhObject peerClass (ArgsPack [] mempty)
            $ \(OriginalValue !ov _ _) -> case ov of
                EdhObject !peerObj -> contEdhSTM $ do
                  writeTVar (entity'store $ objEntity peerObj) $ toDyn peer
                  modifyTVar' clientsDS
                    $ setDictItem (EdhString $ peer'ident peer)
                    $ EdhObject peerObj
                  if __serv_init__ == nil
                    then exit
                    else
                      edhMakeCall
                          pgs
                          __serv_init__
            -- call the service init method with the module object as `that`
                          (thisObject $ contextScope $ edh'context pgs)
                          []
                        $ \mkCall ->
                            runEdhProc pgs $ mkCall $ \_ -> contEdhSTM exit
                _ -> error "bug: createEdhObject returned non-object"

      void
        -- run the service module as another program
        $ forkFinally (runEdhModule' world (T.unpack servModu) prepService)
        $ \case
            -- mark eol with the error occurred
            Left  e -> atomically $ void $ tryPutTMVar eol $ Left e
            -- mark normal eol
            Right _ -> atomically $ void $ tryPutTMVar eol $ Right ()

      let
        serializeCmdsOut :: IO ()
        serializeCmdsOut =
          atomically
              ((Right <$> readTQueue poq) `orElse` (Left <$> readTMVar eol))
            >>= \case
                  Left _ -> return () -- stop on eol any way
                  Right (CommCmd !dir !src) ->
                    catch (sendTextPacket hndl dir src >> serializeCmdsOut)
                      $ \(e :: SomeException) -> -- mark eol on error
                          atomically $ void $ tryPutTMVar eol $ Left e
      -- pump commands out,
      -- make this thread the only one writing the handle
      void $ forkIO serializeCmdsOut

      -- pump commands in, 
      -- make this thread the only one reading the handle
      receivePacketStream hndl pktSink eol

