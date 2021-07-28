module Language.Edh.Net.Client where

-- import           Debug.Trace

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.Dynamic
import qualified Data.HashSet as Set
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import Language.Edh.EHI
import Language.Edh.Net.MicroProto
import Language.Edh.Net.Peer
import Network.Socket
import Network.Socket.ByteString
import Prelude

serviceAddressFrom ::
  EdhThreadState -> Object -> ((Text, Int) -> STM ()) -> STM ()
serviceAddressFrom !ets !addrObj !exit =
  castObjectStore addrObj >>= \case
    Nothing -> throwEdh ets UsageError "unsupported addr object"
    Just (_, !addr) -> case addr of
      (AddrInfo _ _ _ _ (SockAddrInet !port !host) _) ->
        case hostAddressToTuple host of
          (n1, n2, n3, n4) ->
            exit
              ( T.pack $
                  show n1
                    <> "."
                    <> show n2
                    <> "."
                    <> show n3
                    <> "."
                    <> show n4,
                fromIntegral port
              )
      (AddrInfo _ _ _ _ (SockAddrInet6 !port _ (n1, n2, n3, n4) _) _) ->
        exit
          ( T.pack $
              show n1 <> ":" <> show n2 <> ":" <> show n3 <> "::" <> show n4,
            fromIntegral port
          )
      _ -> throwEdh ets UsageError "unsupported addr object"

data EdhClient = EdhClient
  { -- Edh procedure to run as the consumer
    edh'consumer'proc :: !EdhValue,
    -- the world in which the consumer will run
    edh'consumer'world :: !EdhWorld,
    -- local network interface to bind
    edh'service'addr :: !Text,
    -- local network port to bind
    edh'service'port :: !Int,
    -- actually connected network addresses
    edh'service'addrs :: !(TMVar [AddrInfo]),
    -- end-of-life status
    edh'consumer'eol :: !(TMVar (Either SomeException ()))
  }

createClientClass ::
  (Text -> STM ()) ->
  Object ->
  Object ->
  Symbol ->
  EntityStore ->
  Scope ->
  STM Object
createClientClass
  !consoleWarn
  !addrClass
  !peerClass
  !symNetPeer
  !esNetEffs
  !clsOuterScope =
    mkHostClass clsOuterScope "Client" (allocEdhObj clientAllocator) [] $
      \ !clsScope -> do
        !mths <-
          sequence
            [ (AttrByName nm,) <$> mkHostProc clsScope vc nm hp
              | (nm, vc, hp) <-
                  [ ("addrs", EdhMethod, wrapHostProc addrsProc),
                    ("eol", EdhMethod, wrapHostProc eolProc),
                    ("join", EdhMethod, wrapHostProc joinProc),
                    ("stop", EdhMethod, wrapHostProc stopProc),
                    ("__repr__", EdhMethod, wrapHostProc reprProc)
                  ]
            ]
        iopdUpdate mths $ edh'scope'entity clsScope
    where
      clientAllocator ::
        "consumer" !: EdhValue ->
        "addrSpec" ?: EdhValue ->
        "port" ?: Int ->
        "useSandbox" ?: Bool ->
        EdhObjectAllocator
      clientAllocator
        (mandatoryArg -> !consumer)
        (defaultArg (EdhString "127.0.0.1") -> !addrSpec)
        (defaultArg 3721 -> !ctorPort)
        (defaultArg True -> !useSandbox)
        !ctorExit
        !etsCtor = case addrSpec of
          EdhObject !addrObj ->
            serviceAddressFrom etsCtor addrObj $
              {- HLINT ignore "Use uncurry" -}
              \(addr, port) -> go addr port
          EdhString !addr -> go addr ctorPort
          !badSpec -> edhValueDesc etsCtor badSpec $ \ !badDesc ->
            throwEdh etsCtor UsageError $ "bad address: " <> badDesc
          where
            go !addr !port = do
              !serviceAddrs <- newEmptyTMVar
              !cnsmrEoL <- newEmptyTMVar
              let !client =
                    EdhClient
                      { edh'consumer'proc = consumer,
                        edh'consumer'world =
                          edh'prog'world $ edh'thread'prog etsCtor,
                        edh'service'addr = addr,
                        edh'service'port = fromIntegral port,
                        edh'service'addrs = serviceAddrs,
                        edh'consumer'eol = cnsmrEoL
                      }
                  cleanupConsumer :: Either SomeException () -> IO ()
                  cleanupConsumer !result = atomically $ do
                    -- fill empty addrs if the connection has ever failed
                    void $ tryPutTMVar serviceAddrs []
                    -- mark consumer end-of-life anyway finally
                    void $ tryPutTMVar cnsmrEoL result
                    readTMVar cnsmrEoL >>= \case
                      Right {} -> pure ()
                      Left !err ->
                        consoleWarn $
                          T.pack $
                            "Consumer of ["
                              <> show addr
                              <> ":"
                              <> show port
                              <> "] incurred error:\n"
                              <> show err
              runEdhTx etsCtor $
                edhContIO $ do
                  void $ forkFinally (consumerThread client) cleanupConsumer
                  atomically $ ctorExit Nothing $ HostStore (toDyn client)

            consumerThread :: EdhClient -> IO ()
            consumerThread
              ( EdhClient
                  !cnsmrProc
                  !cnsmrWorld
                  !servAddr
                  !servPort
                  !serviceAddrs
                  !cnsmrEoL
                ) =
                do
                  !addr <- resolveServAddr
                  bracket
                    ( socket
                        (addrFamily addr)
                        (addrSocketType addr)
                        (addrProtocol addr)
                    )
                    close
                    $ \ !sock -> do
                      connect sock $ addrAddress addr
                      !srvAddr <- getPeerName sock
                      atomically $
                        tryTakeTMVar serviceAddrs
                          >>= putTMVar serviceAddrs
                            . (addr :)
                            . fromMaybe []
                      try (consumeService (T.pack $ show srvAddr) sock)
                        >>= (gracefulClose sock 5000 <*)
                          . atomically
                          . tryPutTMVar cnsmrEoL
                where
                  resolveServAddr = do
                    let hints =
                          defaultHints
                            { addrFlags = [AI_PASSIVE],
                              addrSocketType = Stream
                            }
                    addr : _ <-
                      getAddrInfo
                        (Just hints)
                        (Just $ T.unpack servAddr)
                        (Just (show servPort))
                    return addr

                  consumeService :: Text -> Socket -> IO ()
                  consumeService !clientId !sock = do
                    !pktSink <- newEmptyTMVarIO
                    !poq <- newEmptyTMVarIO
                    !disposalsVar <- newTVarIO mempty
                    !chdVar <- newTVarIO mempty

                    let edhHandler = pushEdhStack $ \ !etsEffs -> do
                          -- prepare a dedicated scope atop world root scope, with net effects
                          -- implanted, then call the configured service procedure from there
                          let effsScope = contextScope $ edh'context etsEffs
                              withSandbox !maybeSandbox = do
                                let !peer =
                                      Peer
                                        { edh'peer'ident = clientId,
                                          edh'peer'sandbox = maybeSandbox,
                                          edh'peer'eol = cnsmrEoL,
                                          edh'peer'posting = putTMVar poq,
                                          edh'peer'hosting = takeTMVar pktSink,
                                          edh'peer'disposals = disposalsVar,
                                          edh'peer'channels = chdVar
                                        }
                                !peerObj <- edhCreateHostObj peerClass peer
                                !netEffs <- iopdToList esNetEffs
                                (prepareEffStore etsEffs (edh'scope'entity effsScope) >>=) $
                                  iopdUpdate $
                                    (AttrBySym symNetPeer, EdhObject peerObj) : netEffs

                                runEdhTx etsEffs $ edhMakeCall cnsmrProc [] haltEdhProgram
                          if useSandbox
                            then mkScopeSandbox etsEffs effsScope $ withSandbox . Just
                            else withSandbox Nothing

                    -- run the service procedure on a separate thread as another Edh program
                    --
                    -- this implements structured concurrency per client connection,
                    -- i.e. all Edh threads spawned by this client will terminate upon its
                    -- disconnection, while resource cleanups should be scheduled via defer
                    -- mechanism, or exception handling, that expecting `ThreadTerminate` to be
                    -- thrown, the cleanup action is usually in a finally block in this way
                    void $
                      forkFinally (runEdhProgram' cnsmrWorld edhHandler) $
                        -- anyway after the service procedure done:
                        --   dispose of all dependent (channel or not) sinks
                        --   try mark client end-of-life with the result
                        \ !result -> atomically $ do
                          !sinks2Dispose <- readTVar disposalsVar
                          sequence_ $
                            flip postEvent EdhNil <$> Set.toList sinks2Dispose
                          void $ tryPutTMVar cnsmrEoL $ void result

                    -- pump commands in, making this thread the only one reading
                    -- the handle
                    -- note this won't return, will be asynchronously killed on
                    -- eol
                    void $
                      forkIO $
                        receivePacketStream
                          clientId
                          (recv sock)
                          pktSink
                          cnsmrEoL

                    let serializeCmdsOut :: IO ()
                        serializeCmdsOut =
                          atomically
                            ( (Right <$> takeTMVar poq)
                                `orElse` (Left <$> readTMVar cnsmrEoL)
                            )
                            >>= \case
                              Left _ -> return ()
                              Right !pkt -> do
                                sendPacket clientId (sendAll sock) pkt
                                serializeCmdsOut

                    -- pump commands out,
                    -- making this thread the only one writing the handle
                    catch serializeCmdsOut $ \(e :: SomeException) ->
                      -- mark eol on error
                      atomically $ void $ tryPutTMVar cnsmrEoL $ Left e

      reprProc :: EdhHostProc
      reprProc !exit !ets =
        withThisHostObj ets $ \(EdhClient _consumer _world !addr !port _ _) ->
          exitEdh ets exit $
            EdhString $
              T.pack $ "Client<" <> show addr <> ", " <> show port <> ">"

      addrsProc :: EdhHostProc
      addrsProc !exit !ets = withThisHostObj ets $
        \ !client -> readTMVar (edh'service'addrs client) >>= wrapAddrs []
        where
          wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
          wrapAddrs addrs [] =
            exitEdh ets exit $ EdhArgsPack $ ArgsPack addrs odEmpty
          wrapAddrs !addrs (addr : rest) =
            edhCreateHostObj addrClass addr
              >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

      eolProc :: EdhHostProc
      eolProc !exit !ets = withThisHostObj ets $ \ !client ->
        tryReadTMVar (edh'consumer'eol client) >>= \case
          Nothing -> exitEdh ets exit $ EdhBool False
          Just (Left !e) ->
            edh'exception'wrapper world (Just ets) e
              >>= \ !exo -> exitEdh ets exit $ EdhObject exo
          Just (Right ()) -> exitEdh ets exit $ EdhBool True
        where
          world = edh'prog'world $ edh'thread'prog ets

      joinProc :: EdhHostProc
      joinProc !exit !ets = withThisHostObj ets $ \ !client ->
        readTMVar (edh'consumer'eol client) >>= \case
          Left !e ->
            edh'exception'wrapper world (Just ets) e
              >>= \ !exo -> edhThrow ets $ EdhObject exo
          Right () -> exitEdh ets exit nil
        where
          world = edh'prog'world $ edh'thread'prog ets

      stopProc :: EdhHostProc
      stopProc !exit !ets = withThisHostObj ets $ \ !client -> do
        stopped <- tryPutTMVar (edh'consumer'eol client) $ Right ()
        exitEdh ets exit $ EdhBool stopped
