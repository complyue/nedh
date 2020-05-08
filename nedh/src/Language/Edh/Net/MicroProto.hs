
module Language.Edh.Net.MicroProto where

import           Prelude
-- import           Debug.Trace

import           System.IO

import           Control.Exception
import           Control.Monad.Reader
import           Control.Concurrent
import           Control.Concurrent.STM

import           Data.Hashable
import qualified Data.ByteString               as B
import qualified Data.ByteString.Char8         as C
import           Data.Text
import qualified Data.Text                     as T
import           Data.Text.Encoding

import           Language.Edh.EHI


maxHeaderLength :: Int
maxHeaderLength = 60


type PacketDirective = Text
type PacketPayload = B.ByteString
type PacketSink = TMVar Packet
type EndOfStream = TMVar (Either SomeException ())

data Packet = Packet !PacketDirective !PacketPayload
  deriving (Eq, Show)
instance Hashable Packet where
  hashWithSalt s (Packet dir payload) =
    s `hashWithSalt` dir `hashWithSalt` payload

-- | Construct a textual packet.
textPacket :: PacketDirective -> Text -> Packet
textPacket !dir !txt = Packet dir payload
 where
  payload = encodeUtf8 $ finishLine $ onSepLine txt
  onSepLine :: Text -> Text
  onSepLine "" = ""
  onSepLine !t = if "\n" `isPrefixOf` t then t else "\n" <> t
  finishLine :: Text -> Text
  finishLine "" = ""
  finishLine !t = if "\n" `isSuffixOf` t then t else t <> "\n"


-- | Send out a binary packet.
sendPacket :: Text -> Handle -> Packet -> IO ()
sendPacket peerSite !outletHndl (Packet !dir !payload) = do
  let !pktLen = B.length payload
      !pktHdr = encodeUtf8 $ T.pack ("[" <> show pktLen <> "#") <> dir <> "]"
  when (B.length pktHdr > maxHeaderLength) $ throwIO $ EdhPeerError
    peerSite
    "sending out long packet header"
  -- write packet header
  B.hPut outletHndl pktHdr
  -- write packet payload
  B.hPut outletHndl payload


-- | Receive all packets being streamed to the specified (socket) handle,
-- or have been streamed into a file then have the specified handle 
-- opened that file for read.
--
-- Note this should be forked to run in a dedicated thread, that without 
-- subsequent actions to perform, as this function will kill its thread
-- asynchronously on eos by design, in lacking of an otherwise better way
-- to cancel reading from the handle.
--
-- Reading of the stream will only flow when packets are taken away from
-- the sink concurrently, and back-pressure will be created by not taking
-- packets away too quickly.
--
-- The caller is responsible to close the handle anyway appropriate, but
-- only after eos is signaled.
receivePacketStream :: Text -> Handle -> PacketSink -> EndOfStream -> IO ()
receivePacketStream peerSite !intakeHndl !pktSink !eos = do
  recvThId <- myThreadId -- async kill the receiving action on eos
  void $ forkIO $ atomically (readTMVar eos) >> killThread recvThId
  catch (parsePkts B.empty)
    -- note this thread can be killed as above due to eos, don't rethrow
    -- here, some informed thread should rethrow the error in eos if any
    -- get recorded there.
    -- here just try mark end-of-stream with the error occurred, i.e.
    -- previous eos state will be reserved if already signaled. and done.
    $ \(e :: SomeException) -> void $ atomically $ tryPutTMVar eos $ Left e
 where

  parsePkts :: B.ByteString -> IO ()
  parsePkts !readahead = do
    (payloadLen, directive, readahead') <- parseHdr readahead
    if payloadLen < 0
      then -- normal eos, try mark and done
           void $ atomically $ tryPutTMVar eos $ Right ()
      else do
        let (payload, rest) = B.splitAt payloadLen readahead'
            more2read       = payloadLen - B.length payload
        if more2read > 0
          then do
            morePayload <- B.hGet intakeHndl more2read
            atomically
                (        (Right <$> putTMVar
                           pktSink
                           (Packet directive (payload <> morePayload))
                         )
                `orElse` (Left <$> readTMVar eos)
                )
              >>= \case
                    Left  (Left  e ) -> throwIO e
                    Left  (Right ()) -> return ()
                    Right _          -> parsePkts B.empty
          else
            atomically
                (        (Right <$> putTMVar pktSink (Packet directive payload))
                `orElse` (Left <$> readTMVar eos)
                )
              >>= \case
                    Left  (Left  e ) -> throwIO e
                    Left  (Right ()) -> return ()
                    Right _          -> parsePkts rest

  parseHdr :: B.ByteString -> IO (Int, Text, B.ByteString)
  parseHdr !readahead = do
    peeked <- if B.null readahead
      then B.hGetSome intakeHndl maxHeaderLength
      else return readahead
    if B.null peeked
      then return (-1, "eos", B.empty)
      else do
        unless ("[" `B.isPrefixOf` peeked) $ throwIO $ EdhPeerError
          peerSite
          "missing packet header"
        let (hdrPart, rest) = C.break (== ']') peeked
        if not $ B.null rest
          then do -- got a full packet header
            let !hdrContent         = B.drop 1 hdrPart
                !readahead'         = B.drop 1 rest
                (lenStr, directive) = C.break (== '#') hdrContent
                payloadLen          = read $ T.unpack $ decodeUtf8 lenStr
            return (payloadLen, decodeUtf8 $ B.drop 1 directive, readahead')
          else if B.length peeked < maxHeaderLength
            then do
              morePeek <- B.hGetSome intakeHndl maxHeaderLength
              parseHdr $ peeked <> morePeek
            else throwIO
              $ EdhPeerError peerSite "incoming packet header too long"

