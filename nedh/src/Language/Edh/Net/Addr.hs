
module Language.Edh.Net.Addr where

import           Prelude
-- import           Debug.Trace

import           GHC.Conc                       ( unsafeIOToSTM )

import           Control.Concurrent.STM

import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import qualified Data.HashMap.Strict           as Map
import           Data.Dynamic

import           Network.Socket

import qualified Data.Lossless.Decimal         as D

import           Language.Edh.EHI


createAddrClass :: Scope -> STM Object
createAddrClass !clsOuterScope =
  mkHostClass' clsOuterScope "Addr" addrAllocator [] $ \ !clsScope -> do
    !mths <- sequence
      [ (AttrByName nm, ) <$> mkHostProc clsScope vc nm hp args
      | (nm, vc, hp, args) <-
        [ ("__repr__", EdhMethod, addrReprProc, PackReceiver [])
        , ("host"    , EdhMethod, addrHostProc, PackReceiver [])
        , ("port"    , EdhMethod, addrPortProc, PackReceiver [])
        , ("info"    , EdhMethod, addrInfoProc, PackReceiver [])
        ]
      ]
    iopdUpdate mths $ edh'scope'entity clsScope

 where

  -- | host constructor Addr()
  addrAllocator :: EdhObjectAllocator
  addrAllocator !etsCtor !apk !ctorExit =
    case parseArgsPack (Nothing, Nothing) parseCtorArgs apk of
      Left !err -> throwEdh etsCtor UsageError err
      Right (Nothing, Nothing) ->
        ctorExit =<< HostStore <$> newTVar (toDyn nil)
      Right (!host, !port) ->
        unsafeIOToSTM
            ( getAddrInfo
                (Just defaultHints { addrSocketType = Stream
                                   , addrFlags      = [AI_PASSIVE]
                                   }
                )
                (T.unpack <$> host)
            $ case port of
                Nothing                  -> Nothing
                Just (Left  (pn :: Int)) -> Just $ show pn
                Just (Right sn         ) -> Just $ T.unpack sn
            )
          >>= \case
                addr : _ -> ctorExit =<< HostStore <$> newTVar (toDyn addr)
                _ -> throwEdh etsCtor UsageError "bad network address spec"
   where
    parseCtorArgs =
      ArgsPackParser
          [ \arg (_, port') -> case edhUltimate arg of
            EdhString host -> Right (Just host, port')
            _              -> Left "invalid host"
          , \arg (host', _) -> case edhUltimate arg of
            EdhString  port -> Right (host', Just $ Right port)
            EdhDecimal d    -> case D.decimalToInteger d of
              Just port -> Right (host', Just $ Left $ fromInteger port)
              Nothing   -> Left "port must be integer"
            _ -> Left "invalid port"
          ]
        $ Map.fromList
            [ ( "host"
              , \arg (_, port') -> case edhUltimate arg of
                EdhString host -> Right (Just host, port')
                _              -> Left "invalid host"
              )
            , ( "port"
              , \arg (host', _) -> case edhUltimate arg of
                EdhString  port -> Right (host', Just $ Right port)
                EdhDecimal d    -> case D.decimalToInteger d of
                  Just port -> Right (host', Just $ Left $ fromInteger port)
                  Nothing   -> Left "port must be integer"
                _ -> Left "invalid port"
              )
            ]

  addrReprProc :: EdhHostProc
  addrReprProc _ !exit !ets =
    withThisHostObj' ets (exitEdh ets exit $ EdhString "Addr()")
      $ \_hsv (addr :: AddrInfo) -> exitEdh ets exit $ EdhString $ addrRepr addr

  addrHostProc :: EdhHostProc
  addrHostProc _ !exit !ets =
    withThisHostObj' ets (exitEdh ets exit $ EdhString "")
      $ \_hsv (addr :: AddrInfo) -> case addrAddress addr of
          SockAddrInet _ !host -> case hostAddressToTuple host of
            (n1, n2, n3, n4) ->
              exitEdh ets exit
                $  EdhString
                $  T.pack
                $  show n1
                <> "."
                <> show n2
                <> "."
                <> show n3
                <> "."
                <> show n4
          SockAddrInet6 _ _ (n1, n2, n3, n4) _ ->
            exitEdh ets exit
              $  EdhString
              $  T.pack
              $  show n1
              <> ":"
              <> show n2
              <> ":"
              <> show n3
              <> "::"
              <> show n4
          _ -> exitEdh ets exit $ EdhString "<unsupported-addr>"

  addrPortProc :: EdhHostProc
  addrPortProc _ !exit !ets =
    withThisHostObj' ets (exitEdh ets exit $ EdhDecimal 0)
      $ \_hsv (addr :: AddrInfo) -> case addrAddress addr of
          SockAddrInet !port _ ->
            exitEdh ets exit $ EdhDecimal $ fromIntegral port
          SockAddrInet6 !port _ _ _ ->
            exitEdh ets exit $ EdhDecimal $ fromIntegral port
          _ -> exitEdh ets exit $ EdhDecimal 0

  addrInfoProc :: EdhHostProc
  addrInfoProc _ !exit !ets =
    withThisHostObj' ets (exitEdh ets exit $ EdhString "<bogus-addr>")
      $ \_hsv (addr :: AddrInfo) ->
          exitEdh ets exit $ EdhString $ T.pack $ show addr


addrWithPort :: SockAddr -> PortNumber -> SockAddr
addrWithPort (SockAddrInet _ !host) !port = SockAddrInet port host
addrWithPort (SockAddrInet6 _ !fi !host !scope) !port =
  SockAddrInet6 port fi host scope
addrWithPort (SockAddrUnix !name) _ = SockAddrUnix name


addrRepr :: AddrInfo -> Text
addrRepr !addr = case addrAddress addr of
  SockAddrInet !port !host -> case hostAddressToTuple host of
    (n1, n2, n3, n4) ->
      T.pack
        $  "Addr('"
        <> show n1
        <> "."
        <> show n2
        <> "."
        <> show n3
        <> "."
        <> show n4
        <> "', "
        <> show port
        <> ")"
  SockAddrInet6 port _ (n1, n2, n3, n4) _ ->
    T.pack
      $  "Addr('"
      <> show n1
      <> ":"
      <> show n2
      <> ":"
      <> show n3
      <> "::"
      <> show n4
      <> "', "
      <> show port
      <> ")"
  _ -> "<unsupported-addr>"
