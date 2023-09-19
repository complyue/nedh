module Language.Edh.Net.Factotum where

-- import           Debug.Trace

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Monad.IO.Class
import qualified Data.HashSet as Set
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import Data.Void
import Foreign.Concurrent (newForeignPtr)
import Foreign.ForeignPtr (ForeignPtr, touchForeignPtr)
import Foreign.Ptr
import Language.Edh.EHI
import Language.Edh.Net.MicroProto
import Language.Edh.Net.Peer
import Network.Socket
import Network.Socket.ByteString
import System.Posix
import Prelude

factotumProc ::
  Object ->
  Symbol ->
  "cmdl" !: ExprDefi ->
  "factoScript" !: ExprDefi ->
  "workDir" ?: ExprDefi ->
  Edh EdhValue
factotumProc
  !peerClass
  !symNetPeer
  (mandatoryArg -> !cmdlExpr)
  (mandatoryArg -> !factoScript)
  (optionalArg -> !workDirExpr) = do
    cmdl <- evalExprDefiM cmdlExpr
    factoCmdl <- case cmdl of
      EdhString !executable -> return [T.unpack executable]
      EdhArgsPack (ArgsPack !vs _) -> strSeq vs []
      EdhList (List _ !lv) -> readTVarEdh lv >>= \vs -> strSeq vs []
      badCmdl ->
        edhValueReprM badCmdl >>= \badRepr ->
          throwEdhM UsageError $ "invalid factotum cmdl: " <> badRepr
    workDir <- case workDirExpr of
      Nothing -> return Nothing
      Just wdx ->
        evalExprDefiM wdx >>= \case
          EdhString wds | not (T.null wds) -> return $ Just wds
          EdhNamedValue _ EdhNil -> return Nothing
          badWorkDir ->
            edhValueReprM badWorkDir >>= \badRepr ->
              throwEdhM UsageError $ "invalid factotum workDir: " <> badRepr

    FactoProc spTracker factoPid factoSock <- liftIO $ startFactoProc factoCmdl workDir

    let !factotumId = "<facto-child#" <> T.pack (show factoPid) <> ">"
    !pktSink <- newEmptyTMVarEdh
    !poq <- newEmptyTMVarEdh
    !disposalsVar <- newTVarEdh mempty
    !chdVar <- newTVarEdh mempty
    !factoEoL <- newEmptyTMVarEdh
    let !peer =
          Peer
            { edh'peer'ident = factotumId,
              edh'peer'sandbox = Nothing,
              edh'peer'eol = factoEoL,
              edh'peer'posting = putTMVar poq,
              edh'peer'hosting = takeTMVar pktSink,
              edh'peer'disposals = disposalsVar,
              edh'peer'channels = chdVar
            }
    !peerObj <- createArbiHostObjectM peerClass peer

    let commThread = do
          void $
            forkIO $
              -- pump commands in, making this thread the only one reading the handle
              -- note this won't return, will be asynchronously killed on eol
              receivePacketStream
                factotumId
                (recv factoSock)
                pktSink
                factoEoL

          let serializeCmdsOut :: IO ()
              serializeCmdsOut =
                atomically
                  ( (Right <$> takeTMVar poq)
                      `orElse` (Left <$> readTMVar factoEoL)
                  )
                  >>= \case
                    Left _ -> return ()
                    Right !pkt -> do
                      sendPacket factotumId (sendAll factoSock) pkt
                      serializeCmdsOut

          -- pump commands out,
          -- making this thread the only one writing the handle
          catch serializeCmdsOut $ \(e :: SomeException) ->
            -- mark eol on error
            atomically $ void $ tryPutTMVar factoEoL $ Left e

    liftIO $
      void $
        forkFinally commThread $ \_ -> atomically $ do
          !chs2Dispose <- readTVar disposalsVar
          sequence_ $ closeBChan <$> Set.toList chs2Dispose

    !result <- runNested $ do
      defineEffectM (AttrBySym symNetPeer) (EdhObject peerObj)
      runNested $ evalExprDefiM factoScript

    -- TODO do this in a `finally` block
    void $ tryPutTMVarEdh factoEoL $ Right ()

    liftIO $ touchForeignPtr spTracker -- GC will kill the subprocess, keep it until here
    return result
    where
      strSeq :: [EdhValue] -> [String] -> Edh [String]
      strSeq [] !sl = return $ reverse sl
      strSeq (v : vs) !sl = case edhUltimate v of
        EdhString !s -> strSeq vs (T.unpack s : sl)
        _ -> throwEdhM UsageError $ "In factotum cmdl, not a string: " <> T.pack (show v)

confirmKill :: ProcessID -> IO ()
-- assuming failure means the process by this pid doesn't exist (anymore)
-- todo improve such confirmation criteria
confirmKill !pid = handle (\(_ :: SomeException) -> return ()) $ do
  void $ getProcessStatus False True pid -- prevent it from becoming a zombie
  signalProcess killProcess pid
  threadDelay 100000 -- wait 0.1 second before checking it's actually killed
  signalProcess nullSignal pid
  threadDelay 3000000 -- wait 3 seconds before try another round
  confirmKill pid

data FactoProc = FactoProc
  { facto'tracker :: !(ForeignPtr Void),
    facto'pid :: !ProcessID,
    facto'downlink :: !Socket
  }

startFactoProc :: [String] -> Maybe Text -> IO FactoProc
startFactoProc !cmdl !workDir = bracket
  ( socketPair
      AF_UNIX
      Stream
      defaultProtocol
  )
  (\(_downlink, uplink) -> close uplink)
  $ \(!downlink, !uplink) ->
    try (go downlink uplink) >>= \case
      Left (e :: SomeException) -> do
        -- don't wait for finalizer to close it
        close downlink -- close it now
        throwIO e -- rethrow the error
      Right fp -> return fp
  where
    go :: Socket -> Socket -> IO FactoProc
    go downlink uplink = bracket (socketToFd uplink) (closeFd . Fd) $ \factoFd -> do
      -- clear FD_CLOEXEC flag so it can be passed to subprocess
      setFdOption (Fd factoFd) CloseOnExec False
      !factoPid <- forkProcess $ do
        mapM_ (changeWorkingDirectory . T.unpack) workDir
        executeFile
          "/usr/bin/env"
          False
          (cmdl ++ [show factoFd])
          Nothing
      !pt <- newForeignPtr nullPtr $ confirmKill factoPid
      return $ FactoProc pt factoPid downlink
