
module Language.Edh.Net.Client where

import           Prelude
-- import           Debug.Trace

import           System.IO

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

import qualified Data.Lossless.Decimal         as D

import           Language.Edh.EHI

import           Language.Edh.Net.MicroProto
import           Language.Edh.Net.Peer


type ServiceAddr = Text
type ServicePort = Int

data EdhClient = EdhClient {
    -- the import spec of the module to run as the consumer
      edh'consumer'modu :: !Text
    -- local network interface to bind
    , edh'service'addr :: !ServiceAddr
    -- local network port to bind
    , edh'service'port :: !ServicePort
    -- actually connected network addresses
    , edh'service'addrs :: !(TMVar [AddrInfo])
    -- end-of-life status
    , edh'consumer'eol :: !(TMVar (Either SomeException ()))
    -- consumer module initializer, must callable if not nil
    , edh'consumer'init :: !EdhValue
  }


-- | host constructor Client()
clientCtor
  :: Class
  -> Class
  -> EdhProgState
  -> ArgsPack  -- ctor args, if __init__() is provided, will go there too
  -> TVar (Map.HashMap AttrKey EdhValue)  -- out-of-band attr store
  -> (Dynamic -> STM ())  -- in-band data to be written to entity store
  -> STM ()
clientCtor !addrClass !peerClass !pgsCtor !apk !obs !ctorExit =
  case
      parseArgsPack
        (Nothing, "127.0.0.1" :: ServiceAddr, 3721 :: ServicePort, nil)
        parseCtorArgs
        apk
    of
      Left err -> throwEdhSTM pgsCtor UsageError err
      Right (Nothing, _, _, _) ->
        throwEdhSTM pgsCtor UsageError "missing consumer module"
      Right (Just consumer, addr, port, __peer_init__) -> do
        serviceAddrs <- newEmptyTMVar
        cnsmrEoL     <- newEmptyTMVar
        let !client = EdhClient { edh'consumer'modu = consumer
                                , edh'service'addr  = addr
                                , edh'service'port  = port
                                , edh'service'addrs = serviceAddrs
                                , edh'consumer'eol  = cnsmrEoL
                                , edh'consumer'init = __peer_init__
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
          ++ [ ( AttrByName "__repr__"
               , EdhString
               $  "Client("
               <> T.pack (show consumer)
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
              (consumerThread client)
              ( void
              . atomically
                -- fill empty addrs if the connection has ever failed
              . (tryPutTMVar serviceAddrs [] <*)
                -- mark consumer end-of-life anyway finally
              . tryPutTMVar cnsmrEoL
              )
            )
          $ \_ -> ctorExit $ toDyn client
 where
  parseCtorArgs =
    ArgsPackParser
        [ \arg (_, addr', port', init') -> case edhUltimate arg of
          EdhString !consumer -> Right (Just consumer, addr', port', init')
          _                   -> Left "Invalid consumer"
        , \arg (consumer', _, port', init') -> case edhUltimate arg of
          EdhString addr -> Right (consumer', addr, port', init')
          _              -> Left "Invalid addr"
        , \arg (consumer', addr', _, init') -> case edhUltimate arg of
          EdhDecimal d -> case D.decimalToInteger d of
            Just port -> Right (consumer', addr', fromIntegral port, init')
            Nothing   -> Left "port must be integer"
          _ -> Left "Invalid port"
        ]
      $ Map.fromList
          [ ( "addr"
            , \arg (consumer', _, port', init') -> case edhUltimate arg of
              EdhString addr -> Right (consumer', addr, port', init')
              _              -> Left "Invalid addr"
            )
          , ( "port"
            , \arg (consumer', addr', _, init') -> case edhUltimate arg of
              EdhDecimal d -> case D.decimalToInteger d of
                Just port -> Right (consumer', addr', fromIntegral port, init')
                Nothing   -> Left "port must be integer"
              _ -> Left "Invalid port"
            )
          , ( "init"
            , \arg (consumer', addr', port', _) -> case edhUltimate arg of
              EdhNil          -> Right (consumer', addr', port', nil)
              mth@EdhMethod{} -> Right (consumer', addr', port', mth)
              mth@EdhIntrpr{} -> Right (consumer', addr', port', mth)
              _               -> Left "Invalid init"
            )
          ]

  addrsProc :: EdhProcedure
  addrsProc _ !exit = do
    pgs <- ask
    let ctx  = edh'context pgs
        this = thisObject $ contextScope ctx
        es   = entity'store $ objEntity this
        wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
        wrapAddrs addrs [] = exitEdhSTM pgs exit $ EdhTuple addrs
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
      case fromDynamic esd :: Maybe EdhClient of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a client : " <> T.pack
            (show esd)
        Just !client ->
          waitEdhSTM pgs (readTMVar $ edh'service'addrs client) $ wrapAddrs []

  eolProc :: EdhProcedure
  eolProc _ !exit = do
    pgs <- ask
    let ctx  = edh'context pgs
        this = thisObject $ contextScope ctx
        es   = entity'store $ objEntity this
    contEdhSTM $ do
      esd <- readTVar es
      case fromDynamic esd :: Maybe EdhClient of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a client : " <> T.pack
            (show esd)
        Just !client -> tryReadTMVar (edh'consumer'eol client) >>= \case
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
      case fromDynamic esd :: Maybe EdhClient of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a client : " <> T.pack
            (show esd)
        Just !client ->
          edhPerformIO pgs (atomically $ readTMVar (edh'consumer'eol client))
            $ \case
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
      case fromDynamic esd :: Maybe EdhClient of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a client : " <> T.pack
            (show esd)
        Just !client -> do
          stopped <- tryPutTMVar (edh'consumer'eol client) $ Right ()
          exitEdhSTM pgs exit $ EdhBool stopped


  consumerThread :: EdhClient -> IO ()
  consumerThread (EdhClient !cnsmrModu !servAddr !servPort !serviceAddrs !cnsmrEoL !__peer_init__)
    = do
      servThId <- myThreadId
      void $ forkIO $ do -- async terminate the recv thread on stop signal
        _ <- atomically $ readTMVar cnsmrEoL
        killThread servThId
      addr <- resolveServAddr
      bracket
          (socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr))
          close -- repeated `close` is okay with network package
        $ \sock -> do
            connect sock $ addrAddress addr
            atomically
              $   fromMaybe []
              <$> tryTakeTMVar serviceAddrs
              >>= putTMVar serviceAddrs
              .   (addr :)
            bracket (socketToHandle sock ReadWriteMode) hClose $ \hndl ->
              try (cnsmService (T.pack $ show $ addrAddress addr) hndl)
                >>= atomically
                .   void
                .   tryPutTMVar cnsmrEoL

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

    cnsmService :: Text -> Handle -> IO ()
    cnsmService !clientId !hndl = do
      pktSink <- newEmptyTMVarIO
      poq     <- newEmptyTMVarIO
      chdVar  <- newTVarIO mempty

      let
        !peer = Peer { edh'peer'ident    = clientId
                     , edh'peer'eol      = cnsmrEoL
                     , edh'peer'posting  = putTMVar poq
                     , edh'peer'hosting  = takeTMVar pktSink
                     , edh'peer'channels = chdVar
                     }
        prepConsumer :: EdhModulePreparation
        prepConsumer !pgs !exit = do
          let !modu = thisObject $ contextScope $ edh'context pgs
          runEdhProc pgs
            $ createEdhObject peerClass (ArgsPack [] mempty)
            $ \(OriginalValue !peerVal _ _) -> case peerVal of
                EdhObject !peerObj -> contEdhSTM $ do
                  -- actually fill in the in-band entity storage here
                  writeTVar (entity'store $ objEntity peerObj) $ toDyn peer
                  -- implant to the module being prepared
                  changeEntityAttr pgs
                                   (objEntity modu)
                                   (AttrByName "peer")
                                   peerVal
                  -- insert a tick here, for Consumer to start in next stm tx
                  flip (exitEdhSTM pgs) nil $ \_ ->
                    contEdhSTM $ if __peer_init__ == nil
                      then exit
                      -- call the per-connection peer module initialization method,
                      -- with the module object as `that`
                      else
                        edhMakeCall
                            pgs
                            __peer_init__
                            (thisObject $ contextScope $ edh'context pgs)
                            []
                          $ \mkCall ->
                              runEdhProc pgs $ mkCall $ \_ -> contEdhSTM exit
                _ -> error "bug: Peer ctor returned non-object"

      void
        -- run the consumer module as another program
        $ forkFinally (runEdhModule' world (T.unpack cnsmrModu) prepConsumer)
        -- mark client end-of-life with the result anyway
        $ void
        . atomically
        . tryPutTMVar cnsmrEoL
        . void

      -- pump commands in, 
      -- make this thread the only one reading the handle
      -- note this won't return, will be asynchronously killed on eol
      void $ forkIO $ receivePacketStream clientId hndl pktSink cnsmrEoL

      let
        serializeCmdsOut :: IO ()
        serializeCmdsOut =
          atomically
              ((Right <$> readTMVar poq) `orElse` (Left <$> readTMVar cnsmrEoL))
            >>= \case
                  Left _ -> return () -- stop on eol any way
                  Right !pkt ->
                    catch (sendPacket clientId hndl pkt >> serializeCmdsOut)
                      $ \(e :: SomeException) -> -- mark eol on error
                          atomically $ void $ tryPutTMVar cnsmrEoL $ Left e
      -- pump commands out,
      -- make this thread the only one writing the handle
      serializeCmdsOut

