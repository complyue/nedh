
module Language.Edh.Net.MicroProto where

import           Prelude
-- import           Debug.Trace

import           Control.Exception
import           Control.Monad.Reader
import           Control.Concurrent
import           Control.Concurrent.STM

import           Data.Hashable
import qualified Data.ByteString               as B
import qualified Data.ByteString.Lazy          as BL
import qualified Data.ByteString.Lazy.Char8    as C
import           Data.Text                      ( Text
                                                , isPrefixOf
                                                , isSuffixOf
                                                )
import qualified Data.Text                     as T
import qualified Data.Text.Lazy                as TL
import qualified Data.Text.Encoding            as TE
import qualified Data.Text.Lazy.Encoding       as TLE
import           Data.Int

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
  payload = TE.encodeUtf8 $ finishLine $ onSepLine txt
  onSepLine :: Text -> Text
  onSepLine "" = ""
  onSepLine !t = if "\n" `isPrefixOf` t then t else "\n" <> t
  finishLine :: Text -> Text
  finishLine "" = ""
  finishLine !t = if "\n" `isSuffixOf` t then t else t <> "\n"


-- | Send out a binary packet.
sendPacket :: Text -> (B.ByteString -> IO ()) -> Packet -> IO ()
sendPacket peerSite !outletter (Packet !dir !payload) = do
  let !pktLen = B.length payload
      !pktHdr =
        TE.encodeUtf8 $ T.pack ("[" <> show pktLen <> "#") <> dir <> "]"
  when (B.length pktHdr > maxHeaderLength) $ throwIO $ EdhPeerError
    peerSite
    "sending out long packet header"
  -- write packet header
  outletter pktHdr
  -- write packet payload
  outletter payload


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
receivePacketStream
  :: Text -> (Int -> IO B.ByteString) -> PacketSink -> EndOfStream -> IO ()
receivePacketStream peerSite !intaker !pktSink !eos = do
  recvThId <- myThreadId -- async kill the receiving action on eos
  void $ forkIO $ atomically (readTMVar eos) >> killThread recvThId
  catch (parsePkts BL.empty)
    -- note this thread can be killed as above due to eos, don't rethrow
    -- here, some informed thread should rethrow the error in eos if any
    -- get recorded there.
    -- here just try mark end-of-stream with the error occurred, i.e.
    -- previous eos state will be reserved if already signaled. and done.
    $ \(e :: SomeException) -> void $ atomically $ tryPutTMVar eos $ Left e
 where

  getExact :: Int64 -> IO (BL.ByteString, B.ByteString)
  getExact !nbytes64 = intaker nbytes >>= \chunk ->
    let more2read = nbytes64 - fromIntegral (B.length chunk)
    in  if more2read > 0
          then getExact more2read >>= \(chunk', readahead) ->
            return (BL.fromStrict chunk <> chunk', readahead)
          else case B.splitAt nbytes chunk of
            (exact, readahead) -> return (BL.fromStrict exact, readahead)
    where nbytes = fromIntegral nbytes64

  parsePkts :: BL.ByteString -> IO ()
  parsePkts !readahead = do
    (payloadLen, directive, readahead') <- parseHdr readahead
    if payloadLen < 0
      then -- normal eos, try mark and done
           void $ atomically $ tryPutTMVar eos $ Right ()
      else do
        let (payload, rest) = BL.splitAt payloadLen readahead'
            more2read       = payloadLen - BL.length payload
        if more2read > 0
          then do
            (morePayload, moreAhead) <- getExact more2read
            atomically
                (        (Right <$> putTMVar
                           pktSink
                           (Packet directive $ BL.toStrict (payload <> morePayload))
                         )
                `orElse` (Left <$> readTMVar eos)
                )
              >>= \case
                    Left  (Left  e ) -> throwIO e
                    Left  (Right ()) -> return ()
                    Right _          -> parsePkts $ BL.fromStrict moreAhead
          else
            atomically
                ((Right <$> putTMVar pktSink
                                     (Packet directive $ BL.toStrict payload)
                 )
                `orElse` (Left <$> readTMVar eos)
                )
              >>= \case
                    Left  (Left  e ) -> throwIO e
                    Left  (Right ()) -> return ()
                    Right _          -> parsePkts rest

  parseHdr :: BL.ByteString -> IO (Int64, Text, BL.ByteString)
  parseHdr !readahead = do
    peeked <- if BL.null readahead
      then BL.fromStrict <$> intaker chunkSize
      else return readahead
    if BL.null peeked
      then return (-1, "eos", BL.empty)
      else do
        unless ("[" `BL.isPrefixOf` peeked) $ throwIO $ EdhPeerError
          peerSite
          "missing packet header"
        let (hdrPart, rest) = C.break (== ']') peeked
        if not $ BL.null rest
          then do -- got a full packet header
            let !hdrContent         = BL.drop 1 hdrPart
                !readahead'         = BL.drop 1 rest
                (lenStr, directive) = C.break (== '#') hdrContent
                payloadLen          = read $ TL.unpack $ TLE.decodeUtf8 lenStr
            return
              ( payloadLen
              , TL.toStrict $ TLE.decodeUtf8 $ BL.drop 1 directive
              , readahead'
              )
          else if BL.length peeked < fromIntegral maxHeaderLength
            then do
              morePeek <- BL.fromStrict <$> intaker chunkSize
              parseHdr $ peeked <> morePeek
            else throwIO
              $ EdhPeerError peerSite "incoming packet header too long"

  -- | Considering hardware and network realities, the maximum number of bytes
  -- to receive should be a small power of 2
  chunkSize :: Int
  chunkSize = 4096
