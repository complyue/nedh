module Language.Edh.Net.Advertiser where

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
import Language.Edh.Net.Addr
import Language.Edh.Net.Sniffer
import Network.Socket
import Network.Socket.ByteString
import Prelude

type TargetAddr = Text

type TargetPort = Int

-- | An advertiser sends a stream of commands from a (possibly broadcast)
-- channel, as (UDP as impl. so far) packets to the specified
-- broadcast/multicast or sometimes unicast address.
--
-- The local network address of the advertiser can be deliberately set to some
-- TCP service's listening address, so a potential responder can use that
-- information to connect to the service as advertised.
data EdhAdvertiser = EdhAdvertiser
  { -- the source of advertisment
    edh'ad'source :: !(TMVar Text),
    -- remote network address as target, can be multicast or broadcast addr
    edh'ad'target'addr :: !TargetAddr,
    -- remote network port as target
    edh'ad'target'port :: !TargetPort,
    -- actual network addresses as target
    edh'ad'target'addrs :: !(TMVar [AddrInfo]),
    -- local network addr to bind
    edh'advertiser'addr :: !(Maybe AddrInfo),
    -- end-of-life status
    edh'advertising'eol :: !(TMVar (Either SomeException ()))
  }

createAdvertiserClass :: Object -> Scope -> STM Object
createAdvertiserClass !addrClass !clsOuterScope =
  mkHostClass clsOuterScope "Advertiser" (allocEdhObj advertiserAllocator) [] $
    \ !clsScope -> do
      !mths <-
        sequence
          [ (AttrByName nm,) <$> mkHostProc clsScope vc nm hp
            | (nm, vc, hp) <-
                [ ("addrs", EdhMethod, wrapHostProc addrsMth),
                  ("post", EdhMethod, wrapHostProc postMth),
                  ("eol", EdhMethod, wrapHostProc eolMth),
                  ("join", EdhMethod, wrapHostProc joinMth),
                  ("stop", EdhMethod, wrapHostProc stopMth),
                  ("__repr__", EdhMethod, wrapHostProc reprProc)
                ]
          ]
      iopdUpdate mths $ edh'scope'entity clsScope
  where
    advertiserAllocator ::
      "addr" ?: Text ->
      "port" ?: Int ->
      "fromAddr" ?: Object ->
      EdhObjectAllocator
    advertiserAllocator
      (defaultArg "255.255.255.255" -> !ctorAddr)
      (defaultArg 3721 -> !ctorPort)
      (optionalArg -> !maybeFromAddr)
      !ctorExit
      !etsCtor = case maybeFromAddr of
        Just !fromAddrObj ->
          castObjectStore fromAddrObj >>= \case
            Nothing ->
              edhValueDesc etsCtor (EdhObject fromAddrObj) $ \ !badDesc ->
                throwEdh etsCtor UsageError $ "bad addr object: " <> badDesc
            Just (_, fromAddr :: AddrInfo) ->
              go ctorAddr ctorPort (Just fromAddr)
        _ -> go ctorAddr ctorPort Nothing
        where
          go addr port fromAddr = do
            adSrc <- newEmptyTMVar
            advtAddrs <- newEmptyTMVar
            advtEoL <- newEmptyTMVar
            let !advertiser =
                  EdhAdvertiser
                    { edh'ad'source = adSrc,
                      edh'ad'target'addr = addr,
                      edh'ad'target'port = port,
                      edh'ad'target'addrs = advtAddrs,
                      edh'advertiser'addr = fromAddr,
                      edh'advertising'eol = advtEoL
                    }
            runEdhTx etsCtor $
              edhContIO $ do
                void $
                  forkFinally
                    -- mark service end-of-life anyway finally
                    (advtThread advertiser)
                    -- mark end-of-life anyway finally
                    (atomically . void . tryPutTMVar advtEoL)

                atomically $ ctorExit Nothing $ HostStore (toDyn advertiser)

          advtThread :: EdhAdvertiser -> IO ()
          advtThread
            ( EdhAdvertiser
                !adSrc
                !advtAddr
                !advtPort
                !advtAddrs
                !fromAddr
                !advtEoL
              ) =
              do
                advtThId <- myThreadId
                void $
                  forkIO $ do
                    -- async terminate the advertising thread on stop signal
                    _ <- atomically $ readTMVar advtEoL
                    killThread advtThId
                addr <- resolveServAddr
                bracket (open addr) close $ advtTo $ addrAddress addr
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
                      (Just $ T.unpack advtAddr)
                      (Just (show advtPort))
                  return addr
                open addr =
                  bracketOnError
                    ( socket
                        (addrFamily addr)
                        (addrSocketType addr)
                        (addrProtocol addr)
                    )
                    close
                    $ \sock -> do
                      setSocketOption sock ReuseAddr 1
                      setSocketOption sock ReusePort 1
                      setSocketOption sock Broadcast 1
                      -- setSocketOption sock UseLoopBack 1
                      -- TODO why above can deadlock ?
                      if isMultiCastAddr addr
                        then do
                          case fromAddr of
                            Nothing -> pure ()
                            Just !localAddr -> bind sock (addrAddress localAddr)
                          -- todo support mcast
                          --   for now `setSockOpt` is not released yet,
                          --   .hsc files are not well supported by HIE/HLS,
                          --   not a good time to get it straight.
                          -- setSockOpt sock (SockOpt _IPPROTO_IP _IP_MULTICAST_LOOP) 1
                          -- setSockOpt sock (SockOpt _IPPROTO_IP _IP_MULTICAST_IF) xxx
                          error "mcast not supported yet"
                        else case fromAddr of
                          Nothing -> pure ()
                          Just !localAddr -> bind sock (addrAddress localAddr)
                      atomically $
                        tryTakeTMVar advtAddrs
                          >>= putTMVar advtAddrs
                            . (addr :)
                            . fromMaybe []
                      return sock

                advtTo :: SockAddr -> Socket -> IO ()
                advtTo !addr !sock = do
                  cmd <- atomically $ takeTMVar adSrc
                  let !payload = encodeUtf8 cmd
                  sendAllTo sock payload addr
                  advtTo addr sock

    reprProc :: EdhHostProc
    reprProc !exit !ets =
      withThisHostObj ets $ \(EdhAdvertiser _ !addr !port _ !adAddr _) ->
        exitEdh ets exit $
          EdhString $
            "Advertiser("
              <> T.pack (show addr)
              <> ", "
              <> T.pack (show port)
              <> ( case adAddr of
                     Nothing -> ""
                     Just !fromAddr -> ", " <> addrRepr fromAddr
                 )
              <> ")"

    addrsMth :: EdhHostProc
    addrsMth !exit !ets = withThisHostObj ets $ \ !advertiser ->
      readTMVar (edh'ad'target'addrs advertiser) >>= wrapAddrs []
      where
        wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
        wrapAddrs addrs [] =
          exitEdh ets exit $ EdhArgsPack $ ArgsPack addrs odEmpty
        wrapAddrs !addrs (addr : rest) =
          edhCreateHostObj addrClass addr
            >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

    postMth :: [EdhValue] -> EdhHostProc
    postMth !args !exit !ets = withThisHostObj ets $ \ !advertiser -> do
      let advt :: [Text] -> TMVar Text -> STM ()
          advt [] _ = exitEdh ets exit nil
          advt (cmd : rest) q = do
            putTMVar q cmd
            -- post each cmd to ad queue with separate tx
            runEdhTx ets $ edhContSTM $ advt rest q
      seqcontSTM (edhValueRepr ets <$> args) $
        \ !reprs -> advt reprs $ edh'ad'source advertiser

    eolMth :: EdhHostProc
    eolMth !exit !ets = withThisHostObj ets $ \ !advertiser ->
      tryReadTMVar (edh'advertising'eol advertiser) >>= \case
        Nothing -> exitEdh ets exit $ EdhBool False
        Just (Left !e) ->
          edh'exception'wrapper world (Just ets) e
            >>= \ !exo -> exitEdh ets exit $ EdhObject exo
        Just (Right ()) -> exitEdh ets exit $ EdhBool True
      where
        world = edh'prog'world $ edh'thread'prog ets

    joinMth :: EdhHostProc
    joinMth !exit !ets = withThisHostObj ets $ \ !advertiser ->
      readTMVar (edh'advertising'eol advertiser) >>= \case
        Left !e ->
          edh'exception'wrapper world (Just ets) e
            >>= \ !exo -> edhThrow ets $ EdhObject exo
        Right () -> exitEdh ets exit nil
      where
        world = edh'prog'world $ edh'thread'prog ets

    stopMth :: EdhHostProc
    stopMth !exit !ets = withThisHostObj ets $ \ !advertiser -> do
      !stopped <- tryPutTMVar (edh'advertising'eol advertiser) $ Right ()
      exitEdh ets exit $ EdhBool stopped
