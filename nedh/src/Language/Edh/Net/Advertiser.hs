
module Language.Edh.Net.Advertiser where

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
import qualified Data.HashMap.Strict           as Map
import           Data.Dynamic

import           Network.Socket
import           Network.Socket.ByteString

import qualified Data.Lossless.Decimal         as D

import           Language.Edh.EHI

import           Language.Edh.Net.Addr
import           Language.Edh.Net.Sniffer


type TargetAddr = Text
type TargetPort = Int


-- | An advertiser sends a stream of commands from a (possibly broadcast)
-- channel, as (UDP as impl. so far) packets to the specified
-- broadcast/multicast or sometimes unicast address.
--
-- The local network address of the advertiser can be deliberately set to some
-- TCP service's listening address, so a potential responder can use that
-- information to connect to the service as advertised.
data EdhAdvertiser = EdhAdvertiser {
    -- the source of advertisment
      edh'ad'source :: !(TMVar Text)
    -- remote network address as target, can be multicast or broadcast addr
    , edh'ad'target'addr :: !TargetAddr
    -- remote network port as target
    , edh'ad'target'port :: !TargetPort
    -- actual network addresses as target
    , edh'ad'target'addrs :: !(TMVar [AddrInfo])
    -- local network addr to bind
    , edh'advertiser'addr :: !(Maybe AddrInfo)
    -- end-of-life status
    , edh'advertising'eol :: !(TMVar (Either SomeException ()))
  }

-- | host constructor Advertiser()
advertiserCtor :: EdhHostCtor
advertiserCtor !pgsCtor !apk !ctorExit =
  case
      parseArgsPack ("255.255.255.255" :: TargetAddr, 3721 :: TargetPort, nil)
                    parseCtorArgs
                    apk
    of
      Left  !err                         -> throwEdhSTM pgsCtor UsageError err
      Right (!addr, !port, !fromAddrVal) -> case edhUltimate fromAddrVal of
        EdhObject !fromAddrObj -> do
          esd <- readTVar $ entity'store $ objEntity fromAddrObj
          case fromDynamic esd :: Maybe AddrInfo of
            Nothing        -> throwEdhSTM pgsCtor UsageError "bogus addr object"
            Just !fromAddr -> go addr port (Just fromAddr)
        EdhNil -> go addr port Nothing
        _ -> throwEdhSTM pgsCtor UsageError $ "Invalid fromAddr: " <> T.pack
          (show fromAddrVal)
 where
  go addr port fromAddr = do
    adSrc     <- newEmptyTMVar
    advtAddrs <- newEmptyTMVar
    advtEoL   <- newEmptyTMVar
    let !advertiser = EdhAdvertiser { edh'ad'source       = adSrc
                                    , edh'ad'target'addr  = addr
                                    , edh'ad'target'port  = port
                                    , edh'ad'target'addrs = advtAddrs
                                    , edh'advertiser'addr = fromAddr
                                    , edh'advertising'eol = advtEoL
                                    }
    edhPerformIO
        pgsCtor
        -- mark service end-of-life anyway finally
        (forkFinally (advtThread advertiser)
                     (atomically . void . tryPutTMVar advtEoL)
        )
      $ \_ -> contEdhSTM $ ctorExit $ toDyn advertiser
  -- TODO accept sink in ctor args as ad'src
  parseCtorArgs =
    ArgsPackParser
        [ \arg (_, port', fromAddr') -> case edhUltimate arg of
          EdhString addr -> Right (addr, port', fromAddr')
          _              -> Left "Invalid addr"
        , \arg (addr', _, fromAddr') -> case edhUltimate arg of
          EdhDecimal d -> case D.decimalToInteger d of
            Just port -> Right (addr', fromIntegral port, fromAddr')
            Nothing   -> Left "port must be integer"
          _ -> Left "Invalid port"
        ]
      $ Map.fromList
          [ ( "addr"
            , \arg (_, port', fromAddr') -> case edhUltimate arg of
              EdhString addr -> Right (addr, port', fromAddr')
              _              -> Left "Invalid addr"
            )
          , ( "port"
            , \arg (addr', _, fromAddr') -> case edhUltimate arg of
              EdhDecimal d -> case D.decimalToInteger d of
                Just port -> Right (addr', fromIntegral port, fromAddr')
                Nothing   -> Left "port must be integer"
              _ -> Left "Invalid port"
            )
          , ( "fromAddr"
            , \arg (addr', port', _) -> Right (addr', port', edhUltimate arg)
            )
          ]

  advtThread :: EdhAdvertiser -> IO ()
  advtThread (EdhAdvertiser !adSrc !advtAddr !advtPort !advtAddrs !fromAddr !advtEoL)
    = do
      advtThId <- myThreadId
      void $ forkIO $ do -- async terminate the advertising thread on stop signal
        _ <- atomically $ readTMVar advtEoL
        killThread advtThId
      addr <- resolveServAddr
      bracket (open addr) close $ advtTo $ addrAddress addr
   where

    resolveServAddr = do
      let hints =
            defaultHints { addrFlags = [AI_PASSIVE], addrSocketType = Datagram }
      addr : _ <- getAddrInfo (Just hints)
                              (Just $ T.unpack advtAddr)
                              (Just (show advtPort))
      return addr
    open addr =
      bracketOnError
          (socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr))
          close
        $ \sock -> do
            setSocketOption sock ReuseAddr 1
            setSocketOption sock ReusePort 1
            setSocketOption sock Broadcast 1
            -- setSocketOption sock UseLoopBack 1 -- TODO why this deadlocks ?
            if isMultiCastAddr addr
              then do
                case fromAddr of
                  Nothing        -> pure ()
                  Just localAddr -> bind sock (addrAddress localAddr)
                -- todo support mcast 
                --   for now `setSockOpt` is not released yet, 
                --   HIE ceases to render a project with .hsc files,
                --   not a good time to get it straight.
                -- setSockOpt sock (SockOpt _IPPROTO_IP _IP_MULTICAST_LOOP) 1
                -- setSockOpt sock (SockOpt _IPPROTO_IP _IP_MULTICAST_IF) xxx
                error "mcast not supported yet"
              else case fromAddr of
                Nothing        -> pure ()
                Just localAddr -> bind sock (addrAddress localAddr)
            atomically
              $   fromMaybe []
              <$> tryTakeTMVar advtAddrs
              >>= putTMVar advtAddrs
              .   (addr :)
            return sock

    advtTo :: SockAddr -> Socket -> IO ()
    advtTo !addr !sock = do
      cmd <- atomically $ takeTMVar adSrc
      let !payload = encodeUtf8 cmd
      sendAllTo sock payload addr
      advtTo addr sock


advertiserMethods :: Class -> EdhProgState -> STM [(AttrKey, EdhValue)]
advertiserMethods !addrClass !pgsModule = sequence
  [ (AttrByName nm, ) <$> mkHostProc scope vc nm hp args
  | (nm, vc, hp, args) <-
    [ ("addrs"   , EdhMethod, addrsMth, PackReceiver [])
    , ("post"    , EdhMethod, postMth , PackReceiver [])
    , ("eol"     , EdhMethod, eolMth  , PackReceiver [])
    , ("join"    , EdhMethod, joinMth , PackReceiver [])
    , ("stop"    , EdhMethod, stopMth , PackReceiver [])
    , ("__repr__", EdhMethod, reprProc, PackReceiver [])
    ]
  ]
 where
  !scope = contextScope $ edh'context pgsModule

  reprProc :: EdhProcedure
  reprProc _ !exit =
    withThatEntity $ \ !pgs (EdhAdvertiser _ !addr !port _ !adAddr _) ->
      exitEdhSTM pgs exit
        $  EdhString
        $  "Advertiser("
        <> T.pack (show addr)
        <> ", "
        <> T.pack (show port)
        <> (case adAddr of
             Nothing        -> ""
             Just !fromAddr -> ", " <> addrRepr fromAddr
           )
        <> ")"

  addrsMth :: EdhProcedure
  addrsMth _ !exit = withThatEntity $ \ !pgs !advertiser -> do
    let wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
        wrapAddrs addrs [] =
          exitEdhSTM pgs exit $ EdhArgsPack $ ArgsPack addrs odEmpty
        wrapAddrs !addrs (addr : rest) =
          runEdhProc pgs
            $ createEdhObject addrClass (ArgsPack [] odEmpty)
            $ \(OriginalValue !addrVal _ _) -> case addrVal of
                EdhObject !addrObj -> contEdhSTM $ do
                  -- actually fill in the in-band entity storage here
                  writeTVar (entity'store $ objEntity addrObj) $ toDyn addr
                  wrapAddrs (addrVal : addrs) rest
                _ -> error "bug: addr ctor returned non-object"
    edhPerformSTM pgs (readTMVar $ edh'ad'target'addrs advertiser)
      $ contEdhSTM
      . wrapAddrs []

  postMth :: EdhProcedure
  postMth (ArgsPack !args _) !exit = withThatEntity $ \ !pgs !advertiser -> do
    let advt :: [Text] -> TMVar Text -> STM ()
        advt [] _ = exitEdhSTM pgs exit nil
        advt (cmd : rest) q =
          -- don't let Edh track stm retries,
          -- and post each cmd to ad queue with separate tx
          edhPerformSTM pgs (putTMVar q cmd) $ \_ -> contEdhSTM $ advt rest q
    seqcontSTM (edhValueReprSTM pgs <$> args)
      $ \reprs -> advt reprs $ edh'ad'source advertiser

  eolMth :: EdhProcedure
  eolMth _ !exit = withThatEntity $ \ !pgs !advertiser ->
    tryReadTMVar (edh'advertising'eol advertiser) >>= \case
      Nothing         -> exitEdhSTM pgs exit $ EdhBool False
      Just (Left  e ) -> toEdhError pgs e $ \exv -> exitEdhSTM pgs exit exv
      Just (Right ()) -> exitEdhSTM pgs exit $ EdhBool True

  joinMth :: EdhProcedure
  joinMth _ !exit = withThatEntity $ \ !pgs !advertiser ->
    edhPerformSTM pgs (readTMVar (edh'advertising'eol advertiser)) $ \case
      Left  e  -> contEdhSTM $ toEdhError pgs e $ \exv -> edhThrowSTM pgs exv
      Right () -> exitEdhProc exit nil

  stopMth :: EdhProcedure
  stopMth _ !exit = withThatEntity $ \ !pgs !advertiser -> do
    stopped <- tryPutTMVar (edh'advertising'eol advertiser) $ Right ()
    exitEdhSTM pgs exit $ EdhBool stopped

