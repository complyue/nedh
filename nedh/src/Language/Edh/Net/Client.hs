
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
import qualified Data.HashMap.Strict           as Map
import           Data.Dynamic

import           Network.Socket
import           Network.Socket.ByteString      ( recv
                                                , sendAll
                                                )

import qualified Data.Lossless.Decimal         as D

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
serviceAddressFrom !ets !addrObj !exit =
  withHostObject ets addrObj $ \_hsv !addr -> case addr of
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
  mkHostClass' clsOuterScope "Client" clientAllocator [] $ \ !clsScope -> do
    !mths <- sequence
      [ (AttrByName nm, ) <$> mkHostProc clsScope vc nm hp args
      | (nm, vc, hp, args) <-
        [ ("addrs"   , EdhMethod, addrsProc, PackReceiver [])
        , ("eol"     , EdhMethod, eolProc  , PackReceiver [])
        , ("join"    , EdhMethod, joinProc , PackReceiver [])
        , ("stop"    , EdhMethod, stopProc , PackReceiver [])
        , ("__repr__", EdhMethod, reprProc , PackReceiver [])
        ]
      ]
    iopdUpdate mths $ edh'scope'entity clsScope

 where

  -- | host constructor Client()
  clientAllocator :: EdhObjectAllocator
  clientAllocator !etsCtor !apk !ctorExit = if edh'in'tx etsCtor
    then throwEdh etsCtor
                  UsageError
                  "you don't create network objects within a transaction"
    else
      case
        parseArgsPack
          (Nothing, Left ("127.0.0.1" :: ServiceAddr, 3721 :: ServicePort), nil)
          parseCtorArgs
          apk
      of
        Left err -> throwEdh etsCtor UsageError err
        Right (Nothing, _, _) ->
          throwEdh etsCtor UsageError "missing consumer module"
        Right (Just consumer, Right addrObj, __peer_init__) ->
          serviceAddressFrom etsCtor addrObj
            $ \(addr, port) -> go consumer addr port __peer_init__
        Right (Just consumer, Left (addr, port), __peer_init__) ->
          go consumer addr port __peer_init__
   where
    go consumer addr port __peer_init__ = do
      serviceAddrs <- newEmptyTMVar
      cnsmrEoL     <- newEmptyTMVar
      let !client = EdhClient { edh'consumer'modu = consumer
                              , edh'service'addr  = addr
                              , edh'service'port  = port
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
        atomically $ ctorExit =<< HostStore <$> newTVar (toDyn client)
    parseCtorArgs =
      ArgsPackParser
          [ \arg (_, addr', init') -> case edhUltimate arg of
            EdhString !consumer -> Right (Just consumer, addr', init')
            _                   -> Left "invalid consumer"
          , \arg (consumer', addr', init') -> case edhUltimate arg of
            EdhString host -> case addr' of
              Left  (_, port') -> Right (consumer', Left (host, port'), init')
              Right _addrObj   -> Right (consumer', Left (host, 3721), init')
            EdhObject addrObj -> Right (consumer', Right addrObj, init')
            _                 -> Left "invalid addr"
          , \arg (consumer', addr', init') -> case edhUltimate arg of
            EdhDecimal d -> case D.decimalToInteger d of
              Just port -> case addr' of
                Left (host', _) ->
                  Right (consumer', Left (host', fromIntegral port), init')
                Right _addrObj ->
                  Left "can not specify both addr object and port"
              Nothing -> Left "port must be integer"
            _ -> Left "invalid port"
          ]
        $ Map.fromList
            [ ( "addr"
              , \arg (consumer', addr', init') -> case edhUltimate arg of
                EdhString host -> case addr' of
                  Left (_, port') ->
                    Right (consumer', Left (host, port'), init')
                  Right _addrObj -> Right (consumer', Left (host, 3721), init')
                EdhObject addrObj -> Right (consumer', Right addrObj, init')
                _                 -> Left "invalid addr"
              )
            , ( "port"
              , \arg (consumer', addr', init') -> case edhUltimate arg of
                EdhDecimal d -> case D.decimalToInteger d of
                  Just port -> case addr' of
                    Left (host', _) ->
                      Right (consumer', Left (host', fromIntegral port), init')
                    Right _addrObj ->
                      Left "can not specify both addr object and port"
                  Nothing -> Left "port must be integer"
                _ -> Left "invalid port"
              )
            , ( "init"
              , \arg (consumer', addr', _) -> case edhUltimate arg of
                EdhNil -> Right (consumer', addr', nil)
                mth@(EdhProcedure EdhMethod{} _) ->
                  Right (consumer', addr', mth)
                mth@(EdhProcedure EdhIntrpr{} _) ->
                  Right (consumer', addr', mth)
                mth@(EdhBoundProc EdhMethod{} _ _ _) ->
                  Right (consumer', addr', mth)
                mth@(EdhBoundProc EdhIntrpr{} _ _ _) ->
                  Right (consumer', addr', mth)
                _ -> Left "invalid init"
              )
            ]

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
          !peer = Peer { edh'peer'ident    = clientId
                       , edh'peer'eol      = cnsmrEoL
                       , edh'peer'posting  = putTMVar poq
                       , edh'peer'hosting  = takeTMVar pktSink
                       , edh'peer'channels = chdVar
                       }
          prepConsumer :: EdhModulePreparation
          prepConsumer !etsModu !exit =
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
                  edhPrepareCall' etsModu __peer_init__ (ArgsPack [] odEmpty)
                    $ \ !mkCall ->
                        runEdhTx etsModu $ mkCall $ \_result _ets -> exit
            where !moduScope = contextScope $ edh'context etsModu

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
  reprProc _ !exit !ets =
    withThisHostObj ets $ \_hsv (EdhClient !consumer !addr !port _ _ _) ->
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
  addrsProc _ !exit !ets = withThisHostObj ets
    $ \_hsv !client -> readTMVar (edh'service'addrs client) >>= wrapAddrs []
   where
    wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
    wrapAddrs addrs [] =
      exitEdh ets exit $ EdhArgsPack $ ArgsPack addrs odEmpty
    wrapAddrs !addrs (addr : rest) = edhCreateHostObj addrClass (toDyn addr) []
      >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

  eolProc :: EdhHostProc
  eolProc _ !exit !ets = withThisHostObj ets $ \_hsv !client ->
    tryReadTMVar (edh'consumer'eol client) >>= \case
      Nothing        -> exitEdh ets exit $ EdhBool False
      Just (Left !e) -> edh'exception'wrapper world e
        >>= \ !exo -> exitEdh ets exit $ EdhObject exo
      Just (Right ()) -> exitEdh ets exit $ EdhBool True
    where world = edh'ctx'world $ edh'context ets

  joinProc :: EdhHostProc
  joinProc _ !exit !ets = withThisHostObj ets $ \_hsv !client ->
    readTMVar (edh'consumer'eol client) >>= \case
      Left !e ->
        edh'exception'wrapper world e >>= \ !exo -> edhThrow ets $ EdhObject exo
      Right () -> exitEdh ets exit nil
    where world = edh'ctx'world $ edh'context ets

  stopProc :: EdhHostProc
  stopProc _ !exit !ets = withThisHostObj ets $ \_hsv !client -> do
    stopped <- tryPutTMVar (edh'consumer'eol client) $ Right ()
    exitEdh ets exit $ EdhBool stopped

