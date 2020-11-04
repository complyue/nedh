
module Language.Edh.Net.Client where

import           Prelude
-- import           Debug.Trace

import           Control.Exception
import           Control.Monad
import           Control.Concurrent
import           Control.Concurrent.STM

import           Data.Maybe
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import           Data.Dynamic

import           Network.Socket
import           Network.Socket.ByteString      ( recv
                                                , sendAll
                                                )

import           Language.Edh.EHI

import           Language.Edh.Net.MicroProto
import           Language.Edh.Net.Peer


type ServiceAddr = Text
type ServicePort = Int

serviceAddressFrom
  :: EdhThreadState
  -> Object
  -> ((ServiceAddr, ServicePort) -> STM ())
  -> STM ()
serviceAddressFrom !ets !addrObj !exit = castObjectStore addrObj >>= \case
  Nothing         -> throwEdh ets UsageError "unsupported addr object"
  Just (_, !addr) -> case addr of
    (AddrInfo _ _ _ _ (SockAddrInet !port !host) _) ->
      case hostAddressToTuple host of
        (n1, n2, n3, n4) -> exit
          ( T.pack
          $  show n1
          <> "."
          <> show n2
          <> "."
          <> show n3
          <> "."
          <> show n4
          , fromIntegral port
          )
    (AddrInfo _ _ _ _ (SockAddrInet6 !port _ (n1, n2, n3, n4) _) _) -> exit
      ( T.pack $ show n1 <> ":" <> show n2 <> ":" <> show n3 <> "::" <> show n4
      , fromIntegral port
      )
    _ -> throwEdh ets UsageError "unsupported addr object"


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


createClientClass :: Object -> Object -> Scope -> STM Object
createClientClass !addrClass !peerClass !clsOuterScope =
  mkHostClass clsOuterScope "Client" (allocEdhObj clientAllocator) []
    $ \ !clsScope -> do
        !mths <- sequence
          [ (AttrByName nm, ) <$> mkHostProc clsScope vc nm hp
          | (nm, vc, hp) <-
            [ ("addrs"   , EdhMethod, wrapHostProc addrsProc)
            , ("eol"     , EdhMethod, wrapHostProc eolProc)
            , ("join"    , EdhMethod, wrapHostProc joinProc)
            , ("stop"    , EdhMethod, wrapHostProc stopProc)
            , ("__repr__", EdhMethod, wrapHostProc reprProc)
            ]
          ]
        iopdUpdate mths $ edh'scope'entity clsScope

 where

  -- | host constructor Client()
  clientAllocator
    :: "consumer" !: Text
    -> "addrSpec" ?: EdhValue
    -> "port" ?: Int
    -> "init" ?: EdhValue
    -> EdhObjectAllocator
  clientAllocator (mandatoryArg -> !consumer) (defaultArg (EdhString "127.0.0.1") -> !addrSpec) (defaultArg 3721 -> !ctorPort) (defaultArg nil -> !init_) !ctorExit !etsCtor
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
    withInit !__peer_init__ = case addrSpec of
      EdhObject !addrObj ->
        serviceAddressFrom etsCtor addrObj $ \(addr, port) -> go addr port
      EdhString !addr -> go addr ctorPort
      !badSpec        -> edhValueDesc etsCtor badSpec $ \ !badDesc ->
        throwEdh etsCtor UsageError $ "bad address: " <> badDesc
     where
      go !addr !port = do
        serviceAddrs <- newEmptyTMVar
        cnsmrEoL     <- newEmptyTMVar
        let !client = EdhClient { edh'consumer'modu = consumer
                                , edh'service'addr  = addr
                                , edh'service'port  = fromIntegral port
                                , edh'service'addrs = serviceAddrs
                                , edh'consumer'eol  = cnsmrEoL
                                , edh'consumer'init = __peer_init__
                                }
        runEdhTx etsCtor $ edhContIO $ do
          void $ forkFinally
            (consumerThread client)
            ( void
            . atomically
              -- fill empty addrs if the connection has ever failed
            . (tryPutTMVar serviceAddrs [] <*)
              -- mark consumer end-of-life anyway finally
            . tryPutTMVar cnsmrEoL
            )
          atomically $ ctorExit $ HostStore (toDyn client)

    consumerThread :: EdhClient -> IO ()
    consumerThread (EdhClient !cnsmrModu !servAddr !servPort !serviceAddrs !cnsmrEoL !__peer_init__)
      = do
        addr <- resolveServAddr
        bracket
            (socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr))
            close
          $ \sock -> do
              connect sock $ addrAddress addr
              srvAddr <- getPeerName sock
              atomically
                $   fromMaybe []
                <$> tryTakeTMVar serviceAddrs
                >>= putTMVar serviceAddrs
                .   (addr :)
              try (consumeService (T.pack $ show srvAddr) sock)
                >>= (gracefulClose sock 5000 <*)
                .   atomically
                .   tryPutTMVar cnsmrEoL

     where
      ctx             = edh'context etsCtor
      world           = edh'ctx'world ctx

      resolveServAddr = do
        let hints =
              defaultHints { addrFlags = [AI_PASSIVE], addrSocketType = Stream }
        addr : _ <- getAddrInfo (Just hints)
                                (Just $ T.unpack servAddr)
                                (Just (show servPort))
        return addr

      consumeService :: Text -> Socket -> IO ()
      consumeService !clientId !sock = do
        pktSink <- newEmptyTMVarIO
        poq     <- newEmptyTMVarIO
        chdVar  <- newTVarIO mempty

        let
          prepConsumer :: EdhModulePreparation
          prepConsumer !etsModu !exit =
            mkSandbox etsModu moduObj $ \ !sandboxScope ->
              let !peer = Peer { edh'peer'ident    = clientId
                               , edh'peer'sandbox  = sandboxScope
                               , edh'peer'eol      = cnsmrEoL
                               , edh'peer'posting  = putTMVar poq
                               , edh'peer'hosting  = takeTMVar pktSink
                               , edh'peer'channels = chdVar
                               }
              in
                edhCreateHostObj peerClass (toDyn peer) [] >>= \ !peerObj -> do
                  -- implant to the module being prepared
                  iopdInsert (AttrByName "peer")
                             (EdhObject peerObj)
                             (edh'scope'entity moduScope)
                  -- call the per-connection peer module initialization method in the
                  -- module context (where both contextual this/that are the module
                  -- object)
                  if __peer_init__ == nil
                    then exit
                    else
                      edhPrepareCall'
                          etsModu
                          __peer_init__
                          (ArgsPack [EdhObject $ edh'scope'this moduScope]
                                    odEmpty
                          )
                        $ \ !mkCall ->
                            runEdhTx etsModu $ mkCall $ \_result _ets -> exit
           where
            !moduScope = contextScope $ edh'context etsModu
            !moduObj   = edh'scope'this moduScope

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
        void $ forkIO $ receivePacketStream clientId
                                            (recv sock)
                                            pktSink
                                            cnsmrEoL

        let
          serializeCmdsOut :: IO ()
          serializeCmdsOut =
            atomically
                (        (Right <$> takeTMVar poq)
                `orElse` (Left <$> readTMVar cnsmrEoL)
                )
              >>= \case
                    Left _ -> return ()
                    Right !pkt ->
                      catch
                          (  sendPacket clientId (sendAll sock) pkt
                          >> serializeCmdsOut
                          )
                        $ \(e :: SomeException) -> -- mark eol on error
                            atomically $ void $ tryPutTMVar cnsmrEoL $ Left e
        -- pump commands out,
        -- make this thread the only one writing the handle
        serializeCmdsOut


  reprProc :: EdhHostProc
  reprProc !exit !ets =
    withThisHostObj ets $ \(EdhClient !consumer !addr !port _ _ _) ->
      exitEdh ets exit
        $  EdhString
        $  "Client("
        <> T.pack (show consumer)
        <> ", "
        <> T.pack (show addr)
        <> ", "
        <> T.pack (show port)
        <> ")"

  addrsProc :: EdhHostProc
  addrsProc !exit !ets = withThisHostObj ets
    $ \ !client -> readTMVar (edh'service'addrs client) >>= wrapAddrs []
   where
    wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
    wrapAddrs addrs [] =
      exitEdh ets exit $ EdhArgsPack $ ArgsPack addrs odEmpty
    wrapAddrs !addrs (addr : rest) = edhCreateHostObj addrClass (toDyn addr) []
      >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

  eolProc :: EdhHostProc
  eolProc !exit !ets = withThisHostObj ets $ \ !client ->
    tryReadTMVar (edh'consumer'eol client) >>= \case
      Nothing        -> exitEdh ets exit $ EdhBool False
      Just (Left !e) -> edh'exception'wrapper world e
        >>= \ !exo -> exitEdh ets exit $ EdhObject exo
      Just (Right ()) -> exitEdh ets exit $ EdhBool True
    where world = edh'ctx'world $ edh'context ets

  joinProc :: EdhHostProc
  joinProc !exit !ets = withThisHostObj ets $ \ !client ->
    readTMVar (edh'consumer'eol client) >>= \case
      Left !e ->
        edh'exception'wrapper world e >>= \ !exo -> edhThrow ets $ EdhObject exo
      Right () -> exitEdh ets exit nil
    where world = edh'ctx'world $ edh'context ets

  stopProc :: EdhHostProc
  stopProc !exit !ets = withThisHostObj ets $ \ !client -> do
    stopped <- tryPutTMVar (edh'consumer'eol client) $ Right ()
    exitEdh ets exit $ EdhBool stopped

