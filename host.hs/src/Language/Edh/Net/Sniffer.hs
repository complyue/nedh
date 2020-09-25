
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
import           Data.Dynamic

import           Network.Socket
import           Network.Socket.ByteString     as Sock

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
  mkHostClass clsOuterScope "Sniffer" (allocEdhObj snifferAllocator) []
    $ \ !clsScope -> do
        !mths <- sequence
          [ (AttrByName nm, ) <$> mkHostProc clsScope vc nm hp
          | (nm, vc, hp) <-
            [ ("addrs"   , EdhMethod, wrapHostProc addrsMth)
            , ("eol"     , EdhMethod, wrapHostProc eolMth)
            , ("join"    , EdhMethod, wrapHostProc joinMth)
            , ("stop"    , EdhMethod, wrapHostProc stopMth)
            , ("__repr__", EdhMethod, wrapHostProc reprProc)
            ]
          ]
        iopdUpdate mths $ edh'scope'entity clsScope

 where

  -- | host constructor Sniffer()
  snifferAllocator
    :: "modu" !: Text
    -> "addr" ?: Text
    -> "port" ?: Int
    -> "init" ?: EdhValue
    -> EdhObjectAllocator
  snifferAllocator (mandatoryArg -> !modu) (defaultArg "127.0.0.1" -> !ctorAddr) (defaultArg 3721 -> !ctorPort) (defaultArg nil -> !init_) !ctorExit !etsCtor
    = if edh'in'tx etsCtor
      then throwEdh etsCtor
                    UsageError
                    "you don't create network objects within a transaction"
      else case init_ of
        EdhNil                               -> withInit nil
        mth@(EdhProcedure EdhMethod{} _    ) -> withInit mth
        mth@(EdhProcedure EdhIntrpr{} _    ) -> withInit mth
        mth@(EdhBoundProc EdhMethod{} _ _ _) -> withInit mth
        mth@(EdhBoundProc EdhIntrpr{} _ _ _) -> withInit mth
        !badInit -> edhValueDesc etsCtor badInit $ \ !badDesc ->
          throwEdh etsCtor UsageError $ "invalid init: " <> badDesc
   where
    withInit !__modu_init__ = do
      snifAddrs <- newEmptyTMVar
      snifEoL   <- newEmptyTMVar
      let !sniffer = EdhSniffer { edh'sniffer'modu   = modu
                                , edh'sniffer'addr   = ctorAddr
                                , edh'sniffer'port   = ctorPort
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
        atomically $ ctorExit $ HostStore (toDyn sniffer)

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
          eolProc !exit !ets = tryReadTMVar snifEoL >>= \case
            Nothing        -> exitEdh ets exit $ EdhBool False
            Just (Left !e) -> edh'exception'wrapper world e
              >>= \ !exo -> exitEdh ets exit $ EdhObject exo
            Just (Right ()) -> exitEdh ets exit $ EdhBool True
          sniffProc :: EdhHostProc
          sniffProc !exit !ets =
            takeTMVar pktSink >>= \(!fromAddr, !payload) ->
              edhCreateHostObj addrClass
                               (toDyn onAddr { addrAddress = fromAddr })
                               []
                >>= \ !addrObj -> do
                      -- provide the effectful sourceAddr
                      implantEffect
                        (edh'scope'entity $ contextScope $ edh'context ets)
                        (AttrByName "sourceAddr")
                        (EdhObject addrObj)
                      -- interpret the payload as command, return as is
                      let !src = decodeUtf8 payload
                      runEdhTx ets $ evalEdh (show fromAddr) src exit
          prepSniffer :: EdhModulePreparation
          prepSniffer !etsModu !exit = do

            -- define and implant procedures to the module being prepared
            !moduMths <- sequence
              [ (AttrByName nm, ) <$> mkHostProc moduScope vc nm hp
              | (nm, vc, hp) <-
                [ ("eol"  , EdhMethod, wrapHostProc eolProc)
                , ("sniff", EdhMethod, wrapHostProc sniffProc)
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
  reprProc !exit !ets =
    withThisHostObj ets $ \(EdhSniffer !modu !addr !port _ _ _) ->
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
  addrsMth !exit !ets = withThisHostObj ets
    $ \ !sniffer -> readTMVar (edh'sniffing'addrs sniffer) >>= wrapAddrs []
   where
    wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
    wrapAddrs addrs [] =
      exitEdh ets exit $ EdhArgsPack $ ArgsPack addrs odEmpty
    wrapAddrs !addrs (addr : rest) = edhCreateHostObj addrClass (toDyn addr) []
      >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

  eolMth :: EdhHostProc
  eolMth !exit !ets = withThisHostObj ets $ \ !sniffer ->
    tryReadTMVar (edh'sniffing'eol sniffer) >>= \case
      Nothing        -> exitEdh ets exit $ EdhBool False
      Just (Left !e) -> edh'exception'wrapper world e
        >>= \ !exo -> exitEdh ets exit $ EdhObject exo
      Just (Right ()) -> exitEdh ets exit $ EdhBool True
    where world = edh'ctx'world $ edh'context ets

  joinMth :: EdhHostProc
  joinMth !exit !ets = withThisHostObj ets $ \ !sniffer ->
    readTMVar (edh'sniffing'eol sniffer) >>= \case
      Left !e ->
        edh'exception'wrapper world e >>= \ !exo -> edhThrow ets $ EdhObject exo
      Right () -> exitEdh ets exit nil
    where world = edh'ctx'world $ edh'context ets

  stopMth :: EdhHostProc
  stopMth !exit !ets = withThisHostObj ets $ \ !sniffer -> do
    !stopped <- tryPutTMVar (edh'sniffing'eol sniffer) $ Right ()
    exitEdh ets exit $ EdhBool stopped

