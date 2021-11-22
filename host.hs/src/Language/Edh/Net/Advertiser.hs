module Language.Edh.Net.Advertiser where

-- import           Debug.Trace

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding
import Language.Edh.EHI
import Language.Edh.Net.Addr
import Language.Edh.Net.Mcast
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

createAdvertiserClass :: Object -> Edh Object
createAdvertiserClass !addrClass =
  mkEdhClass "Advertiser" (allocObjM advertiserAllocator) [] $ do
    !mths <-
      sequence
        [ (AttrByName nm,) <$> mkEdhProc vc nm hp
          | (nm, vc, hp) <-
              [ ("addrs", EdhMethod, wrapEdhProc addrsMth),
                ("post", EdhMethod, wrapEdhProc postMth),
                ("eol", EdhMethod, wrapEdhProc eolMth),
                ("join", EdhMethod, wrapEdhProc joinMth),
                ("stop", EdhMethod, wrapEdhProc stopMth),
                ("__repr__", EdhMethod, wrapEdhProc reprProc)
              ]
        ]

    !clsScope <- contextScope . edh'context <$> edhThreadState
    iopdUpdateEdh mths $ edh'scope'entity clsScope
  where
    advertiserAllocator ::
      "addr" ?: Text ->
      "port" ?: Int ->
      "fromAddr" ?: Object ->
      Edh ObjectStore
    advertiserAllocator
      (defaultArg "255.255.255.255" -> !ctorAddr)
      (defaultArg 3721 -> !ctorPort)
      (optionalArg -> !maybeFromAddr) = case maybeFromAddr of
        Just !fromAddrObj ->
          ( do
              (_, fromAddr :: AddrInfo) <- hostObjectOf fromAddrObj
              go ctorAddr ctorPort (Just fromAddr)
          )
            <|> ( edhObjDescM fromAddrObj >>= \ !badDesc ->
                    throwEdhM UsageError $ "bad addr object: " <> badDesc
                )
        _ -> go ctorAddr ctorPort Nothing
        where
          go addr port fromAddr = do
            !advertiser <- inlineSTM $ do
              adSrc <- newEmptyTMVar
              advtAddrs <- newEmptyTMVar
              advtEoL <- newEmptyTMVar
              return
                EdhAdvertiser
                  { edh'ad'source = adSrc,
                    edh'ad'target'addr = addr,
                    edh'ad'target'port = port,
                    edh'ad'target'addrs = advtAddrs,
                    edh'advertiser'addr = fromAddr,
                    edh'advertising'eol = advtEoL
                  }
            afterTxIO $ do
              void $
                forkFinally
                  -- mark service end-of-life anyway finally
                  (advtThread advertiser)
                  -- mark end-of-life anyway finally
                  ( atomically . void
                      . tryPutTMVar (edh'advertising'eol advertiser)
                  )
            pinAndStoreHostValue advertiser

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

    reprProc :: Edh EdhValue
    reprProc =
      thisHostObjectOf >>= \(EdhAdvertiser _ !addr !port _ !adAddr _) ->
        return $
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

    addrsMth :: Edh EdhValue
    addrsMth =
      thisHostObjectOf >>= \ !advertiser ->
        inlineSTM (readTMVar $ edh'ad'target'addrs advertiser) >>= wrapAddrs []
      where
        wrapAddrs :: [EdhValue] -> [AddrInfo] -> Edh EdhValue
        wrapAddrs addrs [] =
          return $ EdhArgsPack $ ArgsPack addrs odEmpty
        wrapAddrs !addrs (addr : rest) =
          createArbiHostObjectM addrClass addr
            >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

    -- post each cmd to ad queue with separate tx if not `ai` quoted
    postMth :: [EdhValue] -> Edh EdhValue
    postMth !args =
      thisHostObjectOf >>= \ !advertiser -> do
        let q = edh'ad'source advertiser
        forM_ args $ \val -> do
          cmd <- edhValueReprM val
          inlineSTM $ putTMVar q cmd
        return nil

    eolMth :: Edh EdhValue
    eolMth =
      thisHostObjectOf >>= \ !advertiser ->
        inlineSTM (tryReadTMVar $ edh'advertising'eol advertiser) >>= \case
          Nothing -> return $ EdhBool False
          Just (Left !e) -> throwHostM e
          Just (Right ()) -> return $ EdhBool True

    joinMth :: Edh EdhValue
    joinMth =
      thisHostObjectOf >>= \ !advertiser ->
        inlineSTM (readTMVar $ edh'advertising'eol advertiser) >>= \case
          Left !e -> throwHostM e
          Right () -> return nil

    stopMth :: Edh EdhValue
    stopMth =
      thisHostObjectOf >>= \ !advertiser ->
        fmap EdhBool $
          inlineSTM $ tryPutTMVar (edh'advertising'eol advertiser) $ Right ()
