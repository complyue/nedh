
module Language.Edh.Net.Discover where

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
      Right (Just modu, addr, port, __peer_init__) -> do
        servAddrs <- newEmptyTMVar
        servEoL   <- newEmptyTMVar
        let !sniffer = EdhSniffer { edh'sniffer'modu   = modu
                                  , edh'sniffer'addr   = addr
                                  , edh'sniffer'port   = port
                                  , edh'sniffing'addrs = servAddrs
                                  , edh'sniffing'eol   = servEoL
                                  , edh'sniffing'init  = __peer_init__
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
                         (atomically . void . tryPutTMVar servEoL)
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
      case fromDynamic esd :: Maybe EdhSniffer of
        Nothing ->
          throwEdhSTM pgs UsageError $ "bug: this is not a sniffer : " <> T.pack
            (show esd)
        Just !sniffer ->
          waitEdhSTM pgs (readTMVar $ edh'sniffing'addrs sniffer) $ wrapAddrs []

  eolProc :: EdhProcedure
  eolProc _ !exit = do
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

  joinProc :: EdhProcedure
  joinProc _ !exit = do
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

  stopProc :: EdhProcedure
  stopProc _ !exit = do
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
  sniffThread (EdhSniffer !snifModu !snifAddr !snifPort !snifAddrs !snifEoL !__peer_init__)
    = do
      snifThId <- myThreadId
      void $ forkIO $ do -- async terminate the accepter thread on stop signal
        _ <- atomically $ readTMVar snifEoL
        killThread snifThId
      addr <- resolveServAddr
      bracket (open addr) close forageFrom
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
    forageFrom :: Socket -> IO ()
    forageFrom !sock = do
      (payload, wsAddr) <- recvFrom sock
      -- don't expect too large a call-for-workers announcement
                                    1500

      forageFrom sock -- tail recursion

