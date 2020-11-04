
module Language.Edh.Net.WebSocket where

import           Prelude
-- import           Debug.Trace

import           Control.Exception
import           Control.Monad
import           Control.Concurrent
import           Control.Concurrent.STM

import           Data.Maybe
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import qualified Data.Text.Lazy                as TL
import qualified Data.Text.Lazy.Encoding       as TLE
import qualified Data.ByteString.Lazy          as BL
import           Data.Dynamic
import           Data.IORef

import           Network.Socket
import qualified Network.WebSockets            as WS

import           Language.Edh.EHI

import           Language.Edh.Net.MicroProto
import           Language.Edh.Net.Peer

import           Language.Edh.Net.Addr


type WsServerAddr = Text
type WsServerPort = PortNumber

data EdhWsServer = EdhWsServer {
    -- the import spec of the module to run as the server
      edh'ws'server'modu :: !Text
    -- local network interface to bind
    , edh'ws'server'addr :: !WsServerAddr
    -- local network port to bind
    , edh'ws'server'port :: !WsServerPort
    -- max port number to try bind
    , edh'ws'server'port'max :: !WsServerPort
    -- actually listened network addresses
    , edh'ws'serving'addrs :: !(TMVar [AddrInfo])
    -- end-of-life status
    , edh'ws'server'eol :: !(TMVar (Either SomeException ()))
    -- server module initializer, must callable if not nil
    , edh'ws'server'init :: !EdhValue
    -- each connected peer is sunk into this
    , edh'ws'serving'clients :: !EventSink
  }


createWsServerClass :: Object -> Object -> Scope -> STM Object
createWsServerClass !addrClass !peerClass !clsOuterScope =
  mkHostClass clsOuterScope "WsServer" (allocEdhObj serverAllocator) []
    $ \ !clsScope -> do
        !mths <-
          sequence
          $  [ (AttrByName nm, ) <$> mkHostProc clsScope vc nm hp
             | (nm, vc, hp) <-
               [ ("addrs"   , EdhMethod, wrapHostProc addrsProc)
               , ("eol"     , EdhMethod, wrapHostProc eolProc)
               , ("join"    , EdhMethod, wrapHostProc joinProc)
               , ("stop"    , EdhMethod, wrapHostProc stopProc)
               , ("__repr__", EdhMethod, wrapHostProc reprProc)
               ]
             ]
          ++ [ (AttrByName nm, ) <$> mkHostProperty clsScope nm getter setter
             | (nm, getter, setter) <- [("clients", clientsProc, Nothing)]
             ]
        iopdUpdate mths $ edh'scope'entity clsScope

 where

  -- | host constructor WsServer()
  serverAllocator
    :: "modu" !: Text
    -> "addr" ?: Text
    -> "port" ?: Int
    -> "port'max" ?: Int
    -> "init" ?: EdhValue
    -> "clients" ?: EventSink
    -> EdhObjectAllocator
  serverAllocator (mandatoryArg -> !modu) (defaultArg "127.0.0.1" -> !ctorAddr) (defaultArg 3721 -> !ctorPort) (optionalArg -> port'max) (defaultArg nil -> !init_) (optionalArg -> maybeClients) !ctorExit !etsCtor
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
    withInit !__peer_init__ = do
      !servAddrs <- newEmptyTMVar
      !servEoL   <- newEmptyTMVar
      !clients   <- maybe newEventSink return maybeClients
      let
        !server = EdhWsServer
          { edh'ws'server'modu     = modu
          , edh'ws'server'addr     = ctorAddr
          , edh'ws'server'port     = fromIntegral ctorPort
          , edh'ws'server'port'max = fromIntegral $ fromMaybe ctorPort port'max
          , edh'ws'serving'addrs   = servAddrs
          , edh'ws'server'eol      = servEoL
          , edh'ws'server'init     = __peer_init__
          , edh'ws'serving'clients = clients
          }
      runEdhTx etsCtor $ edhContIO $ do
        void $ forkFinally
          (serverThread server)
          ( atomically
          . ((
              -- fill empty addrs if the connection has ever failed
              tryPutTMVar servAddrs [] >>
              -- mark eos for clients sink anyway finally
                                          publishEvent clients nil) <*)
            -- mark server end-of-life anyway finally
          . tryPutTMVar servEoL
          )
        atomically $ ctorExit $ HostStore (toDyn server)

    serverThread :: EdhWsServer -> IO ()
    serverThread (EdhWsServer !servModu !servAddr !servPort !portMax !servAddrs !servEoL !__peer_init__ !clients)
      = do
        servThId <- myThreadId
        void $ forkIO $ do -- async terminate the accepter thread on stop signal
          _ <- atomically $ readTMVar servEoL
          killThread servThId
        addr <- resolveServAddr
        bracket (open addr) close acceptClients
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

      tryBind !ssock !addr !port =
        catch (bind ssock $ addrWithPort addr port) $ \(e :: SomeException) ->
          if port < portMax then tryBind ssock addr (port + 1) else throw e
      open addr =
        bracketOnError
            (socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr))
            close
          $ \ssock -> do
              tryBind ssock (addrAddress addr) servPort
              listen ssock 300 -- todo make this tunable ?
              listenAddr <- getSocketName ssock
              atomically
                $   fromMaybe []
                <$> tryTakeTMVar servAddrs
                >>= putTMVar servAddrs
                .   (addr { addrAddress = listenAddr } :)
              return ssock

      acceptClients :: Socket -> IO ()
      acceptClients ssock = do
        bracketOnError (accept ssock) (close . fst) $ \(sock, addr) -> do
          clientEoL <- newEmptyTMVarIO
          void
            $ forkFinally (servClient clientEoL (T.pack $ show addr) sock)
            $ (gracefulClose sock 5000 <*)
            . atomically
            . tryPutTMVar clientEoL
        acceptClients ssock -- tail recursion

      servClient :: TMVar (Either SomeException ()) -> Text -> Socket -> IO ()
      servClient !clientEoL !clientId !sock = do
        pConn <- WS.makePendingConnection sock
          $ WS.defaultConnectionOptions { WS.connectionStrictUnicode = True }
        wsc     <- WS.acceptRequest pConn
        pktSink <- newEmptyTMVarIO
        poq     <- newEmptyTMVarIO
        chdVar  <- newTVarIO mempty

        let
          prepService :: EdhModulePreparation
          prepService !etsModu !exit =
            mkSandbox etsModu moduObj $ \ !sandboxScope ->
              let !peer = Peer { edh'peer'ident    = clientId
                               , edh'peer'sandbox  = sandboxScope
                               , edh'peer'eol      = clientEoL
                               , edh'peer'posting  = putTMVar poq
                               , edh'peer'hosting  = takeTMVar pktSink
                               , edh'peer'channels = chdVar
                               }
              in
                do
                  !peerObj <- edhCreateHostObj peerClass (toDyn peer) []
                  -- announce this new peer to the event sink
                  publishEvent clients $ EdhObject peerObj

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
          -- run the server module on a separate thread as another program
          $ forkFinally (runEdhModule' world (T.unpack servModu) prepService)
          -- mark client end-of-life with the result anyway
          $ void
          . atomically
          . tryPutTMVar clientEoL
          . void

        -- pump commands in, 
        -- make this thread the only one reading the handle
        -- note this won't return, will be asynchronously killed on eol
        incomingDir <- newIORef ("" :: Text)
        let
          settlePkt !payload = do
            dir <- readIORef incomingDir
            -- channel directive is effective only for the immediately
            -- following packet
            writeIORef incomingDir ""
            atomically
                (        (Right <$> putTMVar pktSink (Packet dir payload))
                `orElse` (Left <$> readTMVar clientEoL)
                )
              >>= \case
                    Left (Left  e ) -> throwIO e
                    Left (Right ()) -> return ()
                    Right _ ->
            -- anyway we should continue receiving, even after close request
            -- sent,  we are expected to process a CloseRequest ctrl message
            -- from peer.
                      pumpPkts
          pumpPkts = do
            pkt <- WS.receiveDataMessage wsc
            case pkt of
              (WS.Text !bytes _) -> case BL.stripPrefix "[dir#" bytes of
                Just !dirRest -> case BL.stripSuffix "]" dirRest of
                  Just !dir -> do
                    writeIORef incomingDir $ TL.toStrict $ TLE.decodeUtf8 dir
                    pumpPkts
                  Nothing -> settlePkt $ BL.toStrict bytes
                Nothing -> settlePkt $ BL.toStrict bytes
              (WS.Binary !payload) -> settlePkt $ BL.toStrict payload
        void $ forkIOWithUnmask $ \unmask -> catch (unmask pumpPkts) $ \case
          WS.CloseRequest closeCode closeReason
            | closeCode == 1000 || closeCode == 1001
            -> atomically $ void $ tryPutTMVar clientEoL $ Right ()
            | otherwise
            -> do
              atomically
                $  void
                $  tryPutTMVar clientEoL
                $  Left
                $  toException
                $  EdhPeerError clientId
                $  T.pack
                $  "Client closing WebSocket with code "
                <> show closeCode
                <> " and reason ["
                <> show closeReason
                <> "]"
              -- yet still try to receive ctrl msg back from peer
              unmask pumpPkts
          WS.ConnectionClosed ->
            atomically $ void $ tryPutTMVar clientEoL $ Right ()
          _ ->
            atomically
              $ void
              $ tryPutTMVar clientEoL
              $ Left
              $ toException
              $ EdhPeerError clientId "unexpected WebSocket packet."

        let
          sendWsPacket :: Packet -> IO ()
          sendWsPacket (Packet !dir !payload) = if "blob:" `T.isPrefixOf` dir
            then do
              WS.sendDataMessage wsc
                $  flip WS.Text Nothing
                $  TLE.encodeUtf8
                $  ("[dir#" :: TL.Text)
                <> TL.fromStrict dir
                <> "]"
              WS.sendDataMessage wsc $ WS.Binary $ BL.fromStrict payload
            else do
              unless (T.null dir)
                $  WS.sendDataMessage wsc
                $  flip WS.Text Nothing
                $  TLE.encodeUtf8
                $  ("[dir#" :: TL.Text)
                <> TL.fromStrict dir
                <> "]"
              WS.sendDataMessage wsc $ WS.Text (BL.fromStrict payload) Nothing

          serializeCmdsOut :: IO ()
          serializeCmdsOut =
            atomically
                (        (Right <$> takeTMVar poq)
                `orElse` (Left <$> readTMVar clientEoL)
                )
              >>= \case
                    Left  _    -> return () -- stop on eol any way
                    Right !pkt -> do
                      sendWsPacket pkt
                      serializeCmdsOut
        -- pump commands out,
        -- make this thread the only one writing the handle
        serializeCmdsOut `catch` \(e :: SomeException) -> -- mark eol on error
          atomically $ void $ tryPutTMVar clientEoL $ Left e


  clientsProc :: EdhHostProc
  clientsProc !exit !ets = withThisHostObj ets
    $ \ !server -> exitEdh ets exit $ EdhSink $ edh'ws'serving'clients server

  reprProc :: EdhHostProc
  reprProc !exit !ets =
    withThisHostObj ets $ \(EdhWsServer !modu !addr !port !port'max _ _ _ _) ->
      exitEdh ets exit
        $  EdhString
        $  "WsServer("
        <> T.pack (show modu)
        <> ", "
        <> T.pack (show addr)
        <> ", "
        <> T.pack (show port)
        <> T.pack (show port)
        <> ", port'max="
        <> T.pack (show port'max)
        <> ")"

  addrsProc :: EdhHostProc
  addrsProc !exit !ets = withThisHostObj ets
    $ \ !server -> readTMVar (edh'ws'serving'addrs server) >>= wrapAddrs []
   where
    wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
    wrapAddrs addrs [] =
      exitEdh ets exit $ EdhArgsPack $ ArgsPack addrs odEmpty
    wrapAddrs !addrs (addr : rest) = edhCreateHostObj addrClass (toDyn addr) []
      >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

  eolProc :: EdhHostProc
  eolProc !exit !ets = withThisHostObj ets $ \ !server ->
    tryReadTMVar (edh'ws'server'eol server) >>= \case
      Nothing        -> exitEdh ets exit $ EdhBool False
      Just (Left !e) -> edh'exception'wrapper world e
        >>= \ !exo -> exitEdh ets exit $ EdhObject exo
      Just (Right ()) -> exitEdh ets exit $ EdhBool True
    where world = edh'ctx'world $ edh'context ets

  joinProc :: EdhHostProc
  joinProc !exit !ets = withThisHostObj ets $ \ !server ->
    readTMVar (edh'ws'server'eol server) >>= \case
      Left !e ->
        edh'exception'wrapper world e >>= \ !exo -> edhThrow ets $ EdhObject exo
      Right () -> exitEdh ets exit nil
    where world = edh'ctx'world $ edh'context ets

  stopProc :: EdhHostProc
  stopProc !exit !ets = withThisHostObj ets $ \ !server -> do
    stopped <- tryPutTMVar (edh'ws'server'eol server) $ Right ()
    exitEdh ets exit $ EdhBool stopped

