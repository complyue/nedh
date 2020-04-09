
module Language.Edh.Net.Server where

import           Prelude
import           Debug.Trace

import           System.IO

import           Control.Exception
import           Control.Monad
import           Control.Concurrent
import           Control.Concurrent.STM

import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import           Data.Text.Encoding
import           Data.Dynamic

import           Network.Socket

import           Language.Edh.EHI

import           Language.Edh.Net.MicroProto
import           Language.Edh.Net.Peer


type ServingAddr = Text
type ServingPort = Int

servEdhClients
  :: EdhWorld -> Class -> ServingAddr -> ServingPort -> FilePath -> IO ()
servEdhClients !world !peerClass !servAddr !servPort !serviceModu = do
  addr <- resolveServAddr
  bracket (open addr) close acceptClients
 where
  resolveServAddr = do
    let hints =
          defaultHints { addrFlags = [AI_PASSIVE], addrSocketType = Stream }
    addr : _ <- getAddrInfo (Just hints)
                            (Just $ T.unpack servAddr)
                            (Just (show servPort))
    return addr
  open addr = do
    sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
    setSocketOption sock ReuseAddr 1
    bind sock (addrAddress addr)
    listen sock 30
    return sock
  acceptClients :: Socket -> IO ()
  acceptClients sock = do
    (conn, _) <- accept sock
    clientId  <- show <$> getPeerName conn
    hndl      <- socketToHandle conn ReadWriteMode
    void $ forkFinally (servClient clientId hndl) $ \result -> do
      case result of
        Left  exc -> trace ("Edh Client error: " <> show exc) $ pure ()
        Right _   -> pure ()
      hClose hndl -- close the socket anyway
    acceptClients sock -- tail recursion

  servClient :: String -> Handle -> IO ()
  servClient !clientId !hndl = do
    pktSink <- newEmptyTMVarIO
    eos     <- newEmptyTMVarIO
    poq     <- newTQueueIO

    let ho :: STM CommCmd
        ho = do
          (dir, payload) <- takeTMVar pktSink
          return $ CommCmd dir $ decodeUtf8 payload
        po :: CommCmd -> STM ()
        po    = writeTQueue poq

        !peer = Peer { peer'ident      = T.pack clientId
                     , peer'eos        = eos
                     , peer'hosting    = ho
                     , postPeerCommand = po
                     }
        prepService :: EdhModulePreparation
        prepService !pgs !exit =
          runEdhProc pgs
            $ createEdhObject peerClass (ArgsPack [] mempty)
            $ \(OriginalValue ov _ _) -> case ov of
                EdhObject peerObj -> contEdhSTM $ do
                  writeTVar (entity'store $ objEntity peerObj) $ toDyn peer
                  exit
                _ -> error "bug: createEdhObject returned non-object"

    void
      -- start another Edh program to serve this client
      $ forkFinally (runEdhModule' world serviceModu prepService)
      $ \case
          -- mark eos with the error occurred
          Left  e -> atomically $ void $ tryPutTMVar eos $ Left e
          -- mark normal eos
          Right _ -> atomically $ void $ tryPutTMVar eos $ Right ()

    let
      serializeCmdsOut :: IO ()
      serializeCmdsOut =
        atomically
            ((Right <$> readTQueue poq) `orElse` (Left <$> readTMVar eos))
          >>= \case
                Left _ -> return () -- stop on eos any way
                Right (CommCmd !dir !src) ->
                  catch (sendTextPacket hndl dir src >> serializeCmdsOut)
                    $ \(e :: SomeException) -> -- mark eos on error
                        atomically $ void $ tryPutTMVar eos $ Left e
    -- pump commands out,
    -- make this thread the only one writing the handle
    void $ forkIO serializeCmdsOut

    -- pump commands in, 
    -- make this thread the only one reading the handle
    receivePacketStream hndl pktSink eos

