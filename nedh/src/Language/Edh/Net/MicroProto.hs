
module Language.Edh.Net.MicroProto where

import           Prelude
-- import           Debug.Trace

import           System.IO

import           Control.Exception
import           Control.Monad.Reader
import           Control.Concurrent.STM
import qualified Data.ByteString               as B
import qualified Data.ByteString.Char8         as C
import           Data.Text
import qualified Data.Text                     as T
import           Data.Text.Encoding


maxHeaderLength :: Int
maxHeaderLength = 60


type PacketDirective = Text
type PacketPayload = B.ByteString
type PacketSink = TMVar (PacketDirective, PacketPayload)
type EndOfStream = TMVar (Either SomeException ())


-- | Send out a binary packet.
sendPacket :: Handle -> PacketDirective -> PacketPayload -> IO ()
sendPacket !outletHndl !dir !payload = do
  let !pktLen = B.length payload
      !pktHdr = encodeUtf8 $ T.pack ("[" <> show pktLen <> "#") <> dir <> "]"
  when (B.length pktHdr > maxHeaderLength) $ throwIO $ userError
    "packet header too long"
  -- write packet header
  B.hPut outletHndl pktHdr
  -- write packet payload
  B.hPut outletHndl payload


-- | Send out a textual packet.
sendTextPacket :: Handle -> PacketDirective -> Text -> IO ()
sendTextPacket !outletHndl !dir !txt = sendPacket outletHndl dir payload
 where
  payload = encodeUtf8 $ finishLine $ onSepLine txt
  onSepLine :: Text -> Text
  onSepLine "" = ""
  onSepLine !t = if "\n" `isPrefixOf` t then t else "\n" <> t
  finishLine :: Text -> Text
  finishLine "" = ""
  finishLine !t = if "\n" `isSuffixOf` t then t else t <> "\n"


-- | Receive all packets being streamed to the specified (socket) handle,
-- or have been streamed into a file then have the specified handle 
-- opened that file for read.
--
-- Reading of the stream will only flow when packets are taken away from
-- the sink concurrently, and back-pressure will be created by not taking
-- packets away too quickly.
--
-- The caller is responsible to close the handle anyway.
receivePacketStream :: Handle -> PacketSink -> EndOfStream -> IO ()
receivePacketStream !intakeHndl !pktSink !eos =
  catch (parsePkts B.empty) $ \(e :: SomeException) -> do
    -- mark end-of-stream with the error occurred
    void $ atomically $ tryPutTMVar eos $ Left e
    throwIO e -- re-throw the exception
 where

  parsePkts :: B.ByteString -> IO ()
  parsePkts !readahead = do
    (payloadLen, directive, readahead') <- parsePktHdr readahead
    if payloadLen < 0
      then -- mark eos and done
           void $ atomically $ tryPutTMVar eos $ Right ()
      else do
        let (payload, rest) = B.splitAt payloadLen readahead'
            more2read       = payloadLen - B.length payload
        if more2read > 0
          then do
            morePayload <- B.hGet intakeHndl more2read
            atomically
                ((Right <$> putTMVar pktSink (directive, payload <> morePayload)
                 )
                `orElse` (Left <$> readTMVar eos)
                )
              >>= \case
                    Left  (Left  e ) -> throwIO e
                    Left  (Right ()) -> return ()
                    Right _          -> parsePkts B.empty
          else
            atomically
                (        (Right <$> putTMVar pktSink (directive, payload))
                `orElse` (Left <$> readTMVar eos)
                )
              >>= \case
                    Left  (Left  e ) -> throwIO e
                    Left  (Right ()) -> return ()
                    Right _          -> parsePkts rest

  parsePktHdr :: B.ByteString -> IO (Int, Text, B.ByteString)
  parsePktHdr !readahead = do
    peeked <- if B.null readahead
      then B.hGetSome intakeHndl maxHeaderLength
      else return readahead
    if B.null peeked
      then return (-1, "eos", B.empty)
      else do
        unless ("[" `B.isPrefixOf` peeked) $ throwIO $ userError
          "no packet header as expected"
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
              parsePktHdr $ readahead <> morePeek
            else throwIO $ userError "packet header too long"

