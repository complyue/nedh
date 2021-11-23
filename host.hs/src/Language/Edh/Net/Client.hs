module Language.Edh.Net.Client where

-- import           Debug.Trace

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
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

serviceAddressFrom :: Object -> Edh (Text, Int)
serviceAddressFrom !addrObj =
  hostObjectOf addrObj >>= \case
    (_, AddrInfo _ _ _ _ (SockAddrInet !port !host) _) ->
      case hostAddressToTuple host of
        (n1, n2, n3, n4) ->
          return
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
    (_, AddrInfo _ _ _ _ (SockAddrInet6 !port _ (n1, n2, n3, n4) _) _) ->
      return
        ( T.pack $
            show n1 <> ":" <> show n2 <> ":" <> show n3 <> "::" <> show n4,
          fromIntegral port
        )
    _ -> naM "unsupported addr object"

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
  Edh Object
createClientClass
  !consoleWarn
  !addrClass
  !peerClass
  !symNetPeer
  !esNetEffs =
    mkEdhClass' "Client" clientAllocator [] $ do
      !mths <-
        sequence
          [ (AttrByName nm,) <$> mkEdhProc vc nm hp
            | (nm, vc, hp) <-
                [ ("addrs", EdhMethod, wrapEdhProc addrsProc),
                  ("eol", EdhMethod, wrapEdhProc eolProc),
                  ("join", EdhMethod, wrapEdhProc joinProc),
                  ("stop", EdhMethod, wrapEdhProc stopProc),
                  ("__repr__", EdhMethod, wrapEdhProc reprProc)
                ]
          ]

      !clsScope <- contextScope . edh'context <$> edhThreadState
      iopdUpdateEdh mths $ edh'scope'entity clsScope
    where
      clientAllocator ::
        "consumer" !: EdhValue ->
        "addrSpec" ?: EdhValue ->
        "port" ?: Int ->
        "useSandbox" ?: Bool ->
        Edh ObjectStore
      clientAllocator
        (mandatoryArg -> !consumer)
        (defaultArg (EdhString "127.0.0.1") -> !addrSpec)
        (defaultArg 3721 -> !ctorPort)
        (defaultArg True -> !useSandbox) = case addrSpec of
          EdhObject !addrObj -> do
            (addr, port) <- serviceAddressFrom addrObj
            go addr port
          EdhString !addr ->
            go addr ctorPort
          !badSpec -> do
            !badDesc <- edhSimpleDescM badSpec
            throwEdhM UsageError $ "bad address: " <> badDesc
          where
            go !addr !port = do
              !world <- edh'prog'world <$> edhProgramState
              !client <- inlineSTM $ do
                !serviceAddrs <- newEmptyTMVar
                !cnsmrEoL <- newEmptyTMVar
                return
                  EdhClient
                    { edh'consumer'proc = consumer,
                      edh'consumer'world = world,
                      edh'service'addr = addr,
                      edh'service'port = fromIntegral port,
                      edh'service'addrs = serviceAddrs,
                      edh'consumer'eol = cnsmrEoL
                    }
              let cleanupConsumer :: Either SomeException () -> IO ()
                  cleanupConsumer !result = atomically $ do
                    -- fill empty addrs if the connection has ever failed
                    void $ tryPutTMVar (edh'service'addrs client) []
                    -- mark consumer end-of-life anyway finally
                    void $ tryPutTMVar (edh'consumer'eol client) result
                    readTMVar (edh'consumer'eol client) >>= \case
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
              afterTxIO $
                void $ forkFinally (consumerThread client) cleanupConsumer
              pinAndStoreHostValue client

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

                    let edhHandler = runNested $ do
                          -- prepare a dedicated scope atop world root scope,
                          -- with provisioned effects implanted, then call the
                          -- configured service procedure from there
                          !effsScope <-
                            contextScope . edh'context <$> edhThreadState
                          let withSandbox !maybeSandbox = do
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
                                !peerObj <- createArbiHostObjectM peerClass peer
                                !netEffs <- iopdToListEdh esNetEffs
                                let effArts =
                                      ( AttrBySym symNetPeer,
                                        EdhObject peerObj
                                      ) :
                                      netEffs
                                prepareEffStoreM >>= iopdUpdateEdh effArts
                                callM cnsmrProc []

                          if useSandbox
                            then mkSandboxM effsScope >>= withSandbox . Just
                            else withSandbox Nothing

                    -- run the service procedure on a separate thread as another Edh program
                    --
                    -- this implements structured concurrency per client connection,
                    -- i.e. all Edh threads spawned by this client will terminate upon its
                    -- disconnection, while resource cleanups should be scheduled via defer
                    -- mechanism, or exception handling, that expecting `ThreadTerminate` to be
                    -- thrown, the cleanup action is usually in a finally block in this way
                    void $
                      forkFinally (runProgramM' cnsmrWorld edhHandler) $
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

      reprProc :: Edh EdhValue
      reprProc =
        thisHostObjectOf >>= \(EdhClient _consumer _world !addr !port _ _) ->
          return $
            EdhString $
              T.pack $ "Client<" <> show addr <> ", " <> show port <> ">"

      addrsProc :: Edh EdhValue
      addrsProc =
        thisHostObjectOf >>= \ !client ->
          inlineSTM (readTMVar $ edh'service'addrs client) >>= wrapAddrs []
        where
          wrapAddrs :: [EdhValue] -> [AddrInfo] -> Edh EdhValue
          wrapAddrs addrs [] =
            return $ EdhArgsPack $ ArgsPack addrs odEmpty
          wrapAddrs !addrs (addr : rest) =
            createArbiHostObjectM addrClass addr
              >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

      eolProc :: Edh EdhValue
      eolProc =
        thisHostObjectOf >>= \ !client ->
          inlineSTM (tryReadTMVar $ edh'consumer'eol client) >>= \case
            Nothing -> return $ EdhBool False
            Just (Left !e) -> throwHostM e
            Just (Right ()) -> return $ EdhBool True

      joinProc :: Edh EdhValue
      joinProc =
        thisHostObjectOf >>= \ !client ->
          inlineSTM (readTMVar $ edh'consumer'eol client) >>= \case
            Left !e -> throwHostM e
            Right () -> return nil

      stopProc :: Edh EdhValue
      stopProc =
        thisHostObjectOf >>= \ !client ->
          inlineSTM $
            fmap EdhBool $
              tryPutTMVar (edh'consumer'eol client) $ Right ()
