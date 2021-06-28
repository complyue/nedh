module Language.Edh.Net.Sniffer where

-- import           Debug.Trace

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.Dynamic
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding
import Language.Edh.EHI
import Network.Socket
import Network.Socket.ByteString as Sock
import Prelude

isMultiCastAddr :: AddrInfo -> Bool
isMultiCastAddr (AddrInfo _ _ _ _ (SockAddrInet _ !hostAddr) _) =
  case hostAddressToTuple hostAddr of
    (n, _, _, _) -> 224 <= n && n <= 239
isMultiCastAddr (AddrInfo _ _ _ _ SockAddrInet6 {} _) =
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
data EdhSniffer = EdhSniffer
  { -- Edh procedure to run for the service
    edh'sniffer'service :: !EdhValue,
    -- the world in which the service will run
    edh'sniffer'world :: !EdhWorld,
    -- local network addr to bind
    edh'sniffer'addr :: !SniffAddr,
    -- local network port to bind
    edh'sniffer'port :: !SniffPort,
    -- network interface to sniffer on, only meaningful for mcast
    -- TODO need this field when mcast gets supported
    --, edh'sniffer'ni :: !Text
    -- actually bound network addresses
    edh'sniffing'addrs :: !(TMVar [AddrInfo]),
    -- end-of-life status
    edh'sniffing'eol :: !(TMVar (Either SomeException ()))
  }

createSnifferClass :: Object -> Scope -> STM Object
createSnifferClass !addrClass !clsOuterScope =
  mkHostClass clsOuterScope "Sniffer" (allocEdhObj snifferAllocator) [] $
    \ !clsScope -> do
      !mths <-
        sequence
          [ (AttrByName nm,) <$> mkHostProc clsScope vc nm hp
            | (nm, vc, hp) <-
                [ ("addrs", EdhMethod, wrapHostProc addrsMth),
                  ("eol", EdhMethod, wrapHostProc eolMth),
                  ("join", EdhMethod, wrapHostProc joinMth),
                  ("stop", EdhMethod, wrapHostProc stopMth),
                  ("__repr__", EdhMethod, wrapHostProc reprProc)
                ]
          ]
      iopdUpdate mths $ edh'scope'entity clsScope
  where
    snifferAllocator ::
      "service" !: EdhValue ->
      "addr" ?: Text ->
      "port" ?: Int ->
      EdhObjectAllocator
    snifferAllocator
      (mandatoryArg -> !service)
      (defaultArg "127.0.0.1" -> !ctorAddr)
      (defaultArg 3721 -> !ctorPort)
      !ctorExit
      !etsCtor =
        if edh'in'tx etsCtor
          then
            throwEdh
              etsCtor
              UsageError
              "you don't create network objects within a transaction"
          else do
            snifAddrs <- newEmptyTMVar
            snifEoL <- newEmptyTMVar
            let !sniffer =
                  EdhSniffer
                    { edh'sniffer'service = service,
                      edh'sniffer'world =
                        edh'prog'world $ edh'thread'prog etsCtor,
                      edh'sniffer'addr = ctorAddr,
                      edh'sniffer'port = ctorPort,
                      edh'sniffing'addrs = snifAddrs,
                      edh'sniffing'eol = snifEoL
                    }
            runEdhTx etsCtor $
              edhContIO $ do
                void $
                  forkFinally
                    (sniffThread sniffer)
                    ( atomically
                        -- fill empty addrs if the sniffing has ever failed
                        . ((void $ tryPutTMVar snifAddrs []) <*)
                        -- mark end-of-life anyway finally
                        . tryPutTMVar snifEoL
                    )
                atomically $ ctorExit Nothing $ HostStore (toDyn sniffer)
        where
          sniffThread :: EdhSniffer -> IO ()
          sniffThread
            ( EdhSniffer
                !servProc
                !servWorld
                !snifAddr
                !snifPort
                !snifAddrs
                !snifEoL
              ) =
              do
                snifThId <- myThreadId
                void $
                  forkIO $ do
                    -- async terminate the sniffing thread on stop signal
                    _ <- atomically $ readTMVar snifEoL
                    killThread snifThId
                addr <- resolveServAddr
                bracket (open addr) close $ sniffFrom addr
              where
                world = edh'prog'world $ edh'thread'prog etsCtor

                resolveServAddr = do
                  let hints =
                        defaultHints
                          { addrFlags = [AI_PASSIVE],
                            addrSocketType = Datagram
                          }
                  addr : _ <-
                    getAddrInfo
                      (Just hints)
                      (Just $ T.unpack snifAddr)
                      (Just (show snifPort))
                  return addr
                open addr =
                  bracketOnError
                    ( socket
                        (addrFamily addr)
                        (addrSocketType addr)
                        (addrProtocol addr)
                    )
                    close
                    $ \ !sock -> do
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
                        else -- receiving broadcast/unicast to the specified
                        -- addr don't reuse addr/port here, if another process
                        -- is sniffing, should fail loudly here
                          bind sock (addrAddress addr)
                      atomically $
                        tryTakeTMVar snifAddrs
                          >>= putTMVar snifAddrs
                            . (addr :)
                            . fromMaybe []
                      return sock

                sniffFrom :: AddrInfo -> Socket -> IO ()
                sniffFrom !onAddr !sock = do
                  pktSink <- newEmptyTMVarIO

                  let eolProc :: EdhHostProc
                      eolProc !exit !ets =
                        tryReadTMVar snifEoL >>= \case
                          Nothing -> exitEdh ets exit $ EdhBool False
                          Just (Left !e) -> do
                            !exo <- edh'exception'wrapper world (Just ets) e
                            exitEdh ets exit $ EdhObject exo
                          Just (Right ()) -> exitEdh ets exit $ EdhBool True
                      sniffProc :: Scope -> EdhHostProc
                      sniffProc !sandbox !exit !ets =
                        (Right <$> takeTMVar pktSink)
                          `orElse` (Left <$> readTMVar snifEoL) >>= \case
                            -- reached normal end-of-stream
                            Left Right {} -> exitEdh ets exit nil
                            -- previously eol due to error
                            Left (Left !ex) -> do
                              !exo <-
                                edh'exception'wrapper
                                  (edh'prog'world $ edh'thread'prog ets)
                                  (Just ets)
                                  ex
                              edhThrow ets $ EdhObject exo
                            Right (!fromAddr, !payload) -> do
                              !addrObj <-
                                edhCreateHostObj
                                  addrClass
                                  onAddr {addrAddress = fromAddr}
                              -- provide the effectful sourceAddr
                              defineEffect
                                ets
                                (AttrByName "sourceAddr")
                                (EdhObject addrObj)
                              -- interpret the payload as command,
                              -- return as is
                              let !src = decodeUtf8 payload
                              runEdhInSandbox
                                ets
                                sandbox
                                ( evalEdh
                                    (T.pack $ "sniff:" ++ show fromAddr)
                                    src
                                )
                                exit

                      edhHandler = pushEdhStack $ \ !etsEffs ->
                        -- prepare a dedicated scope atop world root scope, with els effects
                        -- implanted, then call the configured service procedure from there
                        let effsScope = contextScope $ edh'context etsEffs
                         in mkScopeSandbox etsEffs effsScope $ \ !sandboxScope -> do
                              !effMths <-
                                sequence
                                  [ (AttrByName nm,)
                                      <$> mkHostProc effsScope vc nm hp
                                    | (nm, vc, hp) <-
                                        [ ("eol", EdhMethod, wrapHostProc eolProc),
                                          ( "sniff",
                                            EdhMethod,
                                            wrapHostProc $ sniffProc sandboxScope
                                          )
                                        ]
                                  ]
                              !sbWrapper <- mkScopeWrapper etsEffs effsScope
                              let !effArts =
                                    (AttrByName "svcScope", EdhObject sbWrapper) : effMths
                              prepareEffStore etsEffs (edh'scope'entity effsScope)
                                >>= iopdUpdate effArts

                              runEdhTx etsEffs $ edhMakeCall servProc [] haltEdhProgram

                  -- run the sniffer service procedure as another program
                  void $
                    forkFinally (runEdhProgram' servWorld edhHandler) $
                      -- mark sniffer end-of-life with the result anyway
                      void . atomically . tryPutTMVar snifEoL . void

                  -- pump sniffed packets into the sniffer loop
                  let pumpPkts = do
                        -- todo expecting packets within typical ethernet
                        --      MTU=1500 for now, should we expect larger
                        --      packets, e.g. with jumbo frames, in the future?
                        (!payload, !fromAddr) <- Sock.recvFrom sock 1500
                        atomically $ putTMVar pktSink (fromAddr, payload)
                        pumpPkts -- tail recursion
                  pumpPkts -- loop until killed on eol
                  --

    --
    reprProc :: EdhHostProc
    reprProc !exit !ets =
      withThisHostObj ets $ \(EdhSniffer _ _ !addr !port _ _) ->
        exitEdh ets exit $
          EdhString $
            "Sniffer<addr= "
              <> T.pack (show addr)
              <> ", port= "
              <> T.pack (show port)
              <> ">"

    addrsMth :: EdhHostProc
    addrsMth !exit !ets = withThisHostObj ets $
      \ !sniffer -> readTMVar (edh'sniffing'addrs sniffer) >>= wrapAddrs []
      where
        wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
        wrapAddrs addrs [] =
          exitEdh ets exit $ EdhArgsPack $ ArgsPack addrs odEmpty
        wrapAddrs !addrs (addr : rest) =
          edhCreateHostObj addrClass addr
            >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

    eolMth :: EdhHostProc
    eolMth !exit !ets = withThisHostObj ets $ \ !sniffer ->
      tryReadTMVar (edh'sniffing'eol sniffer) >>= \case
        Nothing -> exitEdh ets exit $ EdhBool False
        Just (Left !e) ->
          edh'exception'wrapper world (Just ets) e
            >>= \ !exo -> exitEdh ets exit $ EdhObject exo
        Just (Right ()) -> exitEdh ets exit $ EdhBool True
      where
        world = edh'prog'world $ edh'thread'prog ets

    joinMth :: EdhHostProc
    joinMth !exit !ets = withThisHostObj ets $ \ !sniffer ->
      readTMVar (edh'sniffing'eol sniffer) >>= \case
        Left !e ->
          edh'exception'wrapper world (Just ets) e
            >>= \ !exo -> edhThrow ets $ EdhObject exo
        Right () -> exitEdh ets exit nil
      where
        world = edh'prog'world $ edh'thread'prog ets

    stopMth :: EdhHostProc
    stopMth !exit !ets = withThisHostObj ets $ \ !sniffer -> do
      !stopped <- tryPutTMVar (edh'sniffing'eol sniffer) $ Right ()
      exitEdh ets exit $ EdhBool stopped
