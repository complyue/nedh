
module Language.Edh.Net.Sniffer where

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
import           Data.Text.Encoding
import qualified Data.HashMap.Strict           as Map
import           Data.Dynamic

import           Network.Socket
import           Network.Socket.ByteString

import qualified Data.Lossless.Decimal         as D

import           Language.Edh.EHI


isMultiCastAddr :: AddrInfo -> Bool
isMultiCastAddr (AddrInfo _ _ _ _ (SockAddrInet _ !hostAddr) _) =
  case hostAddressToTuple hostAddr of
    (n, _, _, _) -> 224 <= n && n <= 239
isMultiCastAddr (AddrInfo _ _ _ _ SockAddrInet6{} _) =
  error "IPv6 not supported yet"
isMultiCastAddr _ = False


type SniffAddr = Text
type SniffPort = Int

-- | A sniffer can perceive commands conveyed by (UDP as impl. so far)
-- packets from broadcast/multicast or sometimes unicast traffic.
--
-- The sniffer module normally loops in perceiving such commands, and
-- triggers appropriate action responding to each command, e.g.
-- connecting to the source address, via TCP, for further service
-- consuming and/or vending, as advertised.
data EdhSniffer = EdhSniffer {
    -- the import spec of the module to run as the sniffer
      edh'sniffer'modu :: !Text
    -- local network addr to bind
    , edh'sniffer'addr :: !SniffAddr
    -- local network port to bind
    , edh'sniffer'port :: !SniffPort
    -- network interface to sniffer on, only meaningful for mcast
    -- TODO need this field when mcast gets supported
    --, edh'sniffer'ni :: !Text
    -- actually bound network addresses
    , edh'sniffing'addrs :: !(TMVar [AddrInfo])
    -- end-of-life status
    , edh'sniffing'eol :: !(TMVar (Either SomeException ()))
    -- sniffer module initializer, must callable if not nil
    , edh'sniffing'init :: !EdhValue
  }


-- | host constructor Sniffer()
snifferCtor
  :: Class
  -> EdhProgState
  -> ArgsPack  -- ctor args, if __init__() is provided, will go there too
  -> TVar (Map.HashMap AttrKey EdhValue)  -- out-of-band attr store
  -> (Dynamic -> STM ())  -- in-band data to be written to entity store
  -> STM ()
snifferCtor !addrClass !pgsCtor !apk !obs !ctorExit =
  case
      parseArgsPack
        (Nothing, "127.0.0.1" :: SniffAddr, 3721 :: SniffPort, nil)
        parseCtorArgs
        apk
    of
      Left err -> throwEdhSTM pgsCtor UsageError err
      Right (Nothing, _, _, _) ->
        throwEdhSTM pgsCtor UsageError "missing sniffer module"
      Right (Just modu, addr, port, __modu_init__) -> do
        snifAddrs <- newEmptyTMVar
        snifEoL   <- newEmptyTMVar
        let !sniffer = EdhSniffer { edh'sniffer'modu   = modu
                                  , edh'sniffer'addr   = addr
                                  , edh'sniffer'port   = port
                                  , edh'sniffing'addrs = snifAddrs
                                  , edh'sniffing'eol   = snifEoL
                                  , edh'sniffing'init  = __modu_init__
                                  }
            !scope = contextScope $ edh'context pgsCtor
        methods <- sequence
          [ (AttrByName nm, ) <$> mkHostProc scope vc nm hp args
          | (nm, vc, hp, args) <-
            [ ("addrs", EdhMethod, addrsMth, PackReceiver [])
            , ("eol"  , EdhMethod, eolMth  , PackReceiver [])
            , ("join" , EdhMethod, joinMth , PackReceiver [])
            , ("stop" , EdhMethod, stopMth , PackReceiver [])
            ]
          ]
        modifyTVar' obs
          $  Map.union
          $  Map.fromList
          $  methods
          ++ [ ( AttrByName "__repr__"
               , EdhString
               $  "Sniffer("
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
            -- mark service end-of-life anyway finally
            (forkFinally (sniffThread sniffer)
                         (atomically . void . tryPutTMVar snifEoL)
            )
          $ \_ -> ctorExit $ toDyn sniffer
 where
  parseCtorArgs =
    ArgsPackParser
        [ \arg (_, addr', port', init') -> case edhUltimate arg of
          EdhString !modu -> Right (Just modu, addr', port', init')
          _               -> Left "Invalid sniffer module"
        , \arg (modu', _, port', init') -> case edhUltimate arg of
          EdhString addr -> Right (modu', addr, port', init')
          _              -> Left "Invalid addr"
        , \arg (modu', addr', _, init') -> case edhUltimate arg of
          EdhDecimal d -> case D.decimalToInteger d of
            Just port -> Right (modu', addr', fromIntegral port, init')
            Nothing   -> Left "port must be integer"
          _ -> Left "Invalid port"
        ]
      $ Map.fromList
          [ ( "addr"
            , \arg (modu', _, port', init') -> case edhUltimate arg of
              EdhString addr -> Right (modu', addr, port', init')
              _              -> Left "Invalid addr"
            )
          , ( "port"
            , \arg (modu', addr', _, init') -> case edhUltimate arg of
              EdhDecimal d -> case D.decimalToInteger d of
                Just port -> Right (modu', addr', fromIntegral port, init')
                Nothing   -> Left "port must be integer"
              _ -> Left "Invalid port"
            )
          , ( "init"
            , \arg (modu', addr', port', _) -> case edhUltimate arg of
              EdhNil          -> Right (modu', addr', port', nil)
              mth@EdhMethod{} -> Right (modu', addr', port', mth)
              mth@EdhIntrpr{} -> Right (modu', addr', port', mth)
              _               -> Left "Invalid init"
            )
          ]

  addrsMth :: EdhProcedure
  addrsMth _ !exit = do
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
      case fromDynamic esd :: Maybe EdhSniffer of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a sniffer : " <> T.pack
            (show esd)
        Just !sniffer ->
          waitEdhSTM pgs (readTMVar $ edh'sniffing'addrs sniffer) $ wrapAddrs []

  eolMth :: EdhProcedure
  eolMth _ !exit = do
    pgs <- ask
    let ctx  = edh'context pgs
        this = thisObject $ contextScope ctx
        es   = entity'store $ objEntity this
    contEdhSTM $ do
      esd <- readTVar es
      case fromDynamic esd :: Maybe EdhSniffer of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a sniffer : " <> T.pack
            (show esd)
        Just !sniffer -> tryReadTMVar (edh'sniffing'eol sniffer) >>= \case
          Nothing         -> exitEdhSTM pgs exit $ EdhBool False
          Just (Left  e ) -> toEdhError pgs e $ \exv -> exitEdhSTM pgs exit exv
          Just (Right ()) -> exitEdhSTM pgs exit $ EdhBool True

  joinMth :: EdhProcedure
  joinMth _ !exit = do
    pgs <- ask
    let ctx  = edh'context pgs
        this = thisObject $ contextScope ctx
        es   = entity'store $ objEntity this
    contEdhSTM $ do
      esd <- readTVar es
      case fromDynamic esd :: Maybe EdhSniffer of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a sniffer : " <> T.pack
            (show esd)
        Just !sniffer ->
          edhPerformIO pgs (atomically $ readTMVar (edh'sniffing'eol sniffer))
            $ \case
                Left  e  -> toEdhError pgs e $ \exv -> edhThrowSTM pgs exv
                Right () -> exitEdhSTM pgs exit nil

  stopMth :: EdhProcedure
  stopMth _ !exit = do
    pgs <- ask
    let ctx  = edh'context pgs
        this = thisObject $ contextScope ctx
        es   = entity'store $ objEntity this
    contEdhSTM $ do
      esd <- readTVar es
      case fromDynamic esd :: Maybe EdhSniffer of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a sniffer : " <> T.pack
            (show esd)
        Just !sniffer -> do
          stopped <- tryPutTMVar (edh'sniffing'eol sniffer) $ Right ()
          exitEdhSTM pgs exit $ EdhBool stopped


  sniffThread :: EdhSniffer -> IO ()
  sniffThread (EdhSniffer !snifModu !snifAddr !snifPort !snifAddrs !snifEoL !__modu_init__)
    = do
      snifThId <- myThreadId
      void $ forkIO $ do -- async terminate the sniffing thread on stop signal
        _ <- atomically $ readTMVar snifEoL
        killThread snifThId
      addr <- resolveServAddr
      bracket (open addr) close $ sniffFrom addr
   where
    ctx             = edh'context pgsCtor
    world           = contextWorld ctx

    resolveServAddr = do
      let hints =
            defaultHints { addrFlags = [AI_PASSIVE], addrSocketType = Datagram }
      addr : _ <- getAddrInfo (Just hints)
                              (Just $ T.unpack snifAddr)
                              (Just (show snifPort))
      return addr
    open addr =
      bracketOnError
          (socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr))
          close
        $ \sock -> do
            if isMultiCastAddr addr
              then do
                setSocketOption sock ReuseAddr 1
                -- setSocketOption sock ReusePort 1
                -- todo support mcast 
                --   for now `setSockOpt` is not released yet, 
                --   HIE ceases to render a project with .hsc files,
                --   not a good time to get it straight.
                -- setSockOpt sock (SockOpt _IPPROTO_IP _IP_ADD_MEMBERSHIP) xxx
                -- bind sock (addrAddress addr)
                error "mcast not supported yet"
              else -- receiving broadcast/unicast to the specified addr
                -- don't reuse addr/port here, if another process is sniffing,
                -- should fail loudly here
                   bind sock (addrAddress addr)
            atomically
              $   fromMaybe []
              <$> tryTakeTMVar snifAddrs
              >>= putTMVar snifAddrs
              .   (addr :)
            return sock

    sniffFrom :: AddrInfo -> Socket -> IO ()
    sniffFrom !onAddr !sock = do
      pktSink <- newEmptyTMVarIO
      let
        eolProc :: EdhProcedure
        eolProc _ !exit = do
          pgs <- ask
          contEdhSTM $ tryReadTMVar snifEoL >>= \case
            Nothing -> exitEdhSTM pgs exit $ EdhBool False
            Just (Left e) -> toEdhError pgs e $ \exv -> exitEdhSTM pgs exit exv
            Just (Right ()) -> exitEdhSTM pgs exit $ EdhBool True
        sniffProc :: EdhProcedure
        sniffProc _ !exit = do
          pgs <- ask
          let modu = thisObject $ contextScope $ edh'context pgs
          contEdhSTM
            $ waitEdhSTM pgs (takeTMVar pktSink)
            $ \(fromAddr, payload) ->
                runEdhProc pgs
                  $ createEdhObject addrClass (ArgsPack [] mempty)
                  $ \(OriginalValue !addrVal _ _) -> case addrVal of
                      EdhObject !addrObj -> contEdhSTM $ do
                        writeTVar (entity'store $ objEntity addrObj)
                          $ toDyn onAddr { addrAddress = fromAddr }
                        -- update sniffer module global `addr`
                        changeEntityAttr pgs
                                         (objEntity modu)
                                         (AttrByName "addr")
                                         addrVal
                        -- interpret the payload as command, return as is
                        let !src = decodeUtf8 payload
                        runEdhProc pgs
                          $ evalEdh (show fromAddr) src
                          $ exitEdhProc' exit
                      _ -> error "bug: Addr ctor returned non-object"
        prepSniffer :: EdhModulePreparation
        prepSniffer !pgs !exit = do
          let !scope = contextScope $ edh'context pgs
              !modu  = thisObject scope
          runEdhProc pgs $ contEdhSTM $ do
            methods <- sequence
              [ (AttrByName nm, ) <$> mkHostProc scope vc nm hp args
              | (nm, vc, hp, args) <-
                [ ("eol"  , EdhMethod, eolProc  , PackReceiver [])
                , ("sniff", EdhMethod, sniffProc, PackReceiver [])
                ]
              ]
            -- implant to the module being prepared
            updateEntityAttrs pgs (objEntity modu) methods
            if __modu_init__ == nil
              then exit
              else
                -- call the sniffer module initialization method,
                -- with the module object as `that`
                edhMakeCall pgs
                            __modu_init__
                            (thisObject $ contextScope $ edh'context pgs)
                            []
                  $ \mkCall -> runEdhProc pgs $ mkCall $ \_ -> contEdhSTM exit

      void
        -- run the sniffer module as another program
        $ forkFinally (runEdhModule' world (T.unpack snifModu) prepSniffer)
        -- mark sniffer end-of-life with the result anyway
        $ void
        . atomically
        . tryPutTMVar snifEoL
        . void

      -- pump sniffed packets into the sniffer loop
      let pumpPkts = do
            -- todo expecting packets within typical ethernet MTU=1500 for
            --      now, should we expect larger packets, e.g. with jumbo
            --      frames, in the future?
            (payload, fromAddr) <- recvFrom sock 1500
            atomically $ putTMVar pktSink (fromAddr, payload)
            pumpPkts -- tail recursion
      pumpPkts -- loop until killed on eol

