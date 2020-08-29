
module Language.Edh.Net.Sniffer where

import           Prelude
-- import           Debug.Trace

import           Control.Exception
import           Control.Monad
import           Control.Concurrent
import           Control.Concurrent.STM

import           Data.Maybe
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import           Data.Text.Encoding
import qualified Data.HashMap.Strict           as Map
import           Data.Dynamic

import           Network.Socket
import           Network.Socket.ByteString     as Sock

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


createSnifferClass :: Object -> Scope -> STM Object
createSnifferClass !addrClass !clsOuterScope =
  mkHostClass' clsOuterScope "Sniffer" snifferAllocator [] $ \ !clsScope -> do
    !mths <- sequence
      [ (AttrByName nm, ) <$> mkHostProc clsScope vc nm hp args
      | (nm, vc, hp, args) <-
        [ ("addrs"   , EdhMethod, addrsMth, PackReceiver [])
        , ("eol"     , EdhMethod, eolMth  , PackReceiver [])
        , ("join"    , EdhMethod, joinMth , PackReceiver [])
        , ("stop"    , EdhMethod, stopMth , PackReceiver [])
        , ("__repr__", EdhMethod, reprProc, PackReceiver [])
        ]
      ]
    iopdUpdate mths $ edh'scope'entity clsScope

 where

  -- | host constructor Sniffer()
  snifferAllocator :: EdhObjectAllocator
  snifferAllocator !etsCtor !apk !ctorExit = if edh'in'tx etsCtor
    then throwEdh etsCtor
                  UsageError
                  "you don't create network objects within a transaction"
    else
      case
        parseArgsPack
          (Nothing, "127.0.0.1" :: SniffAddr, 3721 :: SniffPort, nil)
          parseCtorArgs
          apk
      of
        Left err -> throwEdh etsCtor UsageError err
        Right (Nothing, _, _, _) ->
          throwEdh etsCtor UsageError "missing sniffer module"
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
          runEdhTx etsCtor $ edhContIO $ do
            void $ forkFinally
              (sniffThread sniffer)
              ( atomically
              -- fill empty addrs if the sniffing has ever failed
              . ((void $ tryPutTMVar snifAddrs []) <*)
              -- mark end-of-life anyway finally
              . tryPutTMVar snifEoL
              )
            atomically $ ctorExit =<< HostStore <$> newTVar (toDyn sniffer)
   where
    parseCtorArgs =
      ArgsPackParser
          [ \arg (_, addr', port', init') -> case edhUltimate arg of
            EdhString !modu -> Right (Just modu, addr', port', init')
            _               -> Left "invalid sniffer module"
          , \arg (modu', _, port', init') -> case edhUltimate arg of
            EdhString addr -> Right (modu', addr, port', init')
            _              -> Left "invalid addr"
          , \arg (modu', addr', _, init') -> case edhUltimate arg of
            EdhDecimal d -> case D.decimalToInteger d of
              Just port -> Right (modu', addr', fromIntegral port, init')
              Nothing   -> Left "port must be integer"
            _ -> Left "invalid port"
          ]
        $ Map.fromList
            [ ( "addr"
              , \arg (modu', _, port', init') -> case edhUltimate arg of
                EdhString addr -> Right (modu', addr, port', init')
                _              -> Left "invalid addr"
              )
            , ( "port"
              , \arg (modu', addr', _, init') -> case edhUltimate arg of
                EdhDecimal d -> case D.decimalToInteger d of
                  Just port -> Right (modu', addr', fromIntegral port, init')
                  Nothing   -> Left "port must be integer"
                _ -> Left "invalid port"
              )
            , ( "init"
              , \arg (modu', addr', port', _) -> case edhUltimate arg of
                EdhNil -> Right (modu', addr', port', nil)
                mth@(EdhProcedure EdhMethod{} _) ->
                  Right (modu', addr', port', mth)
                mth@(EdhProcedure EdhIntrpr{} _) ->
                  Right (modu', addr', port', mth)
                mth@(EdhBoundProc EdhMethod{} _ _ _) ->
                  Right (modu', addr', port', mth)
                mth@(EdhBoundProc EdhIntrpr{} _ _ _) ->
                  Right (modu', addr', port', mth)
                _ -> Left "invalid init"
              )
            ]

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
      ctx             = edh'context etsCtor
      world           = edh'ctx'world ctx

      resolveServAddr = do
        let
          hints =
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
          eolProc :: EdhHostProc
          eolProc _ !exit !ets = tryReadTMVar snifEoL >>= \case
            Nothing        -> exitEdh ets exit $ EdhBool False
            Just (Left !e) -> edh'exception'wrapper world e
              >>= \ !exo -> exitEdh ets exit $ EdhObject exo
            Just (Right ()) -> exitEdh ets exit $ EdhBool True
          sniffProc :: EdhHostProc
          sniffProc _ !exit !ets =
            takeTMVar pktSink >>= \(!fromAddr, !payload) ->
              edhCreateHostObj addrClass
                               (toDyn onAddr { addrAddress = fromAddr })
                               []
                >>= \ !addrObj -> do
                    -- update sniffer module's global `addr`
                      iopdInsert
                        (AttrByName "addr")
                        (EdhObject addrObj)
                        (edh'scope'entity $ contextScope $ edh'context ets)
                      -- interpret the payload as command, return as is
                      let !src = decodeUtf8 payload
                      runEdhTx ets $ evalEdh (show fromAddr) src exit
          prepSniffer :: EdhModulePreparation
          prepSniffer !etsModu !exit = do

            -- define and implant procedures to the module being prepared
            !moduMths <- sequence
              [ (AttrByName nm, ) <$> mkHostProc moduScope vc nm hp args
              | (nm, vc, hp, args) <-
                [ ("eol"  , EdhMethod, eolProc  , PackReceiver [])
                , ("sniff", EdhMethod, sniffProc, PackReceiver [])
                ]
              ]
            iopdUpdate moduMths $ edh'scope'entity moduScope

            -- call the sniffer module initialization method in the module
            -- context (where both contextual this/that are the module object)
            if __modu_init__ == nil
              then exit
              else
                edhPrepareCall' etsModu __modu_init__ (ArgsPack [] odEmpty)
                  $ \ !mkCall ->
                      runEdhTx etsModu $ mkCall $ \_result _ets -> exit
            where !moduScope = contextScope $ edh'context etsModu

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
              (payload, fromAddr) <- Sock.recvFrom sock 1500
              atomically $ putTMVar pktSink (fromAddr, payload)
              pumpPkts -- tail recursion
        pumpPkts -- loop until killed on eol


  reprProc :: EdhHostProc
  reprProc _ !exit !ets =
    withThisHostObj ets $ \_hsv (EdhSniffer !modu !addr !port _ _ _) ->
      exitEdh ets exit
        $  EdhString
        $  "Sniffer("
        <> T.pack (show modu)
        <> ", "
        <> T.pack (show addr)
        <> ", "
        <> T.pack (show port)
        <> ")"

  addrsMth :: EdhHostProc
  addrsMth _ !exit !ets = withThisHostObj ets
    $ \_hsv !sniffer -> readTMVar (edh'sniffing'addrs sniffer) >>= wrapAddrs []
   where
    wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
    wrapAddrs addrs [] =
      exitEdh ets exit $ EdhArgsPack $ ArgsPack addrs odEmpty
    wrapAddrs !addrs (addr : rest) = edhCreateHostObj addrClass (toDyn addr) []
      >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

  eolMth :: EdhHostProc
  eolMth _ !exit !ets = withThisHostObj ets $ \_hsv !sniffer ->
    tryReadTMVar (edh'sniffing'eol sniffer) >>= \case
      Nothing        -> exitEdh ets exit $ EdhBool False
      Just (Left !e) -> edh'exception'wrapper world e
        >>= \ !exo -> exitEdh ets exit $ EdhObject exo
      Just (Right ()) -> exitEdh ets exit $ EdhBool True
    where world = edh'ctx'world $ edh'context ets

  joinMth :: EdhHostProc
  joinMth _ !exit !ets = withThisHostObj ets $ \_hsv !sniffer ->
    readTMVar (edh'sniffing'eol sniffer) >>= \case
      Left !e ->
        edh'exception'wrapper world e >>= \ !exo -> edhThrow ets $ EdhObject exo
      Right () -> exitEdh ets exit nil
    where world = edh'ctx'world $ edh'context ets

  stopMth :: EdhHostProc
  stopMth _ !exit !ets = withThisHostObj ets $ \_hsv !sniffer -> do
    !stopped <- tryPutTMVar (edh'sniffing'eol sniffer) $ Right ()
    exitEdh ets exit $ EdhBool stopped

