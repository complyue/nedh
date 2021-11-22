module Language.Edh.Net.Sniffer where

-- import           Debug.Trace

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding
import Language.Edh.EHI
import Language.Edh.Net.Mcast
import Network.Socket
import Network.Socket.ByteString as Sock
import Prelude

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

createSnifferClass :: Object -> Edh Object
createSnifferClass !addrClass =
  mkEdhClass "Sniffer" (allocObjM snifferAllocator) [] $ do
    !mths <-
      sequence
        [ (AttrByName nm,) <$> mkEdhProc vc nm hp
          | (nm, vc, hp) <-
              [ ("addrs", EdhMethod, wrapEdhProc addrsMth),
                ("eol", EdhMethod, wrapEdhProc eolMth),
                ("join", EdhMethod, wrapEdhProc joinMth),
                ("stop", EdhMethod, wrapEdhProc stopMth),
                ("__repr__", EdhMethod, wrapEdhProc reprProc)
              ]
        ]

    !clsScope <- contextScope . edh'context <$> edhThreadState
    iopdUpdateEdh mths $ edh'scope'entity clsScope
  where
    snifferAllocator ::
      "service" !: EdhValue ->
      "addr" ?: Text ->
      "port" ?: Int ->
      Edh ObjectStore
    snifferAllocator
      (mandatoryArg -> !service)
      (defaultArg "127.0.0.1" -> !ctorAddr)
      (defaultArg 3721 -> !ctorPort) = do
        !world <- edh'prog'world <$> edhProgramState
        !sniffer <- inlineSTM $ do
          snifAddrs <- newEmptyTMVar
          snifEoL <- newEmptyTMVar
          return
            EdhSniffer
              { edh'sniffer'service = service,
                edh'sniffer'world = world,
                edh'sniffer'addr = ctorAddr,
                edh'sniffer'port = ctorPort,
                edh'sniffing'addrs = snifAddrs,
                edh'sniffing'eol = snifEoL
              }
        afterTxIO $ do
          void $
            forkFinally
              (sniffThread sniffer)
              ( atomically
                  -- fill empty addrs if the sniffing has ever failed
                  . ((void $ tryPutTMVar (edh'sniffing'addrs sniffer) []) <*)
                  -- mark end-of-life anyway finally
                  . tryPutTMVar (edh'sniffing'eol sniffer)
              )
        pinAndStoreHostValue sniffer
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

                  let eolProc :: Edh EdhValue
                      eolProc = do
                        !world <- edh'prog'world <$> edhProgramState
                        inlineSTM (tryReadTMVar snifEoL) >>= \case
                          Nothing -> return $ EdhBool False
                          Just (Left !e) -> do
                            !ets <- edhThreadState
                            !exo <-
                              inlineSTM $
                                edh'exception'wrapper world (Just ets) e
                            return $ EdhObject exo
                          Just (Right ()) -> return $ EdhBool True
                      sniffProc :: Scope -> Edh EdhValue
                      sniffProc !sandbox =
                        inlineSTM
                          ( (Right <$> takeTMVar pktSink)
                              `orElse` (Left <$> readTMVar snifEoL)
                          )
                          >>= \case
                            -- reached normal end-of-stream
                            Left Right {} -> return nil
                            -- previously eol due to error
                            Left (Left !ex) -> throwHostM ex
                            Right (!fromAddr, !payload) -> do
                              !addrObj <-
                                createArbiHostObjectM
                                  addrClass
                                  onAddr {addrAddress = fromAddr}
                              -- provide the effectful sourceAddr
                              defineEffectM
                                (AttrByName "sourceAddr")
                                (EdhObject addrObj)
                              -- interpret the payload as command,
                              -- return as is
                              let !src = decodeUtf8 payload
                              runInSandboxM
                                sandbox
                                ( evalSrcM
                                    (T.pack $ "sniff:" ++ show fromAddr)
                                    src
                                )

                      edhHandler = runNested $ do
                        -- prepare a dedicated scope atop world root scope,
                        -- with provisioned effects implanted, then call the
                        -- configured service procedure from there
                        !effsScope <-
                          contextScope . edh'context <$> edhThreadState
                        !sandboxScope <- mkSandboxM effsScope
                        !effMths <-
                          sequence
                            [ (AttrByName nm,)
                                <$> mkEdhProc vc nm hp
                              | (nm, vc, hp) <-
                                  [ ("eol", EdhMethod, wrapEdhProc eolProc),
                                    ( "sniff",
                                      EdhMethod,
                                      wrapEdhProc $ sniffProc sandboxScope
                                    )
                                  ]
                            ]
                        !sbWrapper <- wrapScopeM effsScope
                        let !effArts =
                              (AttrByName "svcScope", EdhObject sbWrapper) :
                              effMths
                        prepareEffStoreM >>= iopdUpdateEdh effArts
                        callM servProc []

                  -- run the sniffer service procedure as another program
                  void $
                    forkFinally (runProgramM' servWorld edhHandler) $
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

    reprProc :: Edh EdhValue
    reprProc =
      thisHostObjectOf >>= \(EdhSniffer _ _ !addr !port _ _) ->
        return $
          EdhString $
            "Sniffer<addr= "
              <> T.pack (show addr)
              <> ", port= "
              <> T.pack (show port)
              <> ">"

    addrsMth :: Edh EdhValue
    addrsMth =
      thisHostObjectOf >>= \ !sniffer ->
        inlineSTM (readTMVar $ edh'sniffing'addrs sniffer) >>= wrapAddrs []
      where
        wrapAddrs :: [EdhValue] -> [AddrInfo] -> Edh EdhValue
        wrapAddrs addrs [] =
          return $ EdhArgsPack $ ArgsPack addrs odEmpty
        wrapAddrs !addrs (addr : rest) =
          createArbiHostObjectM addrClass addr
            >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

    eolMth :: Edh EdhValue
    eolMth =
      thisHostObjectOf >>= \ !sniffer ->
        inlineSTM (tryReadTMVar $ edh'sniffing'eol sniffer) >>= \case
          Nothing -> return $ EdhBool False
          Just (Left !e) -> throwHostM e
          Just (Right ()) -> return $ EdhBool True

    joinMth :: Edh EdhValue
    joinMth =
      thisHostObjectOf >>= \ !sniffer ->
        inlineSTM (readTMVar $ edh'sniffing'eol sniffer) >>= \case
          Left !e -> throwHostM e
          Right () -> return nil

    stopMth :: Edh EdhValue
    stopMth =
      thisHostObjectOf >>= \ !sniffer ->
        inlineSTM $
          fmap EdhBool $
            tryPutTMVar (edh'sniffing'eol sniffer) $ Right ()
