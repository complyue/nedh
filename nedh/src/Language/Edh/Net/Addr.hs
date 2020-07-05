
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


-- | host constructor Addr()
addrCtor :: EdhHostCtor
addrCtor !pgsCtor !apk !ctorExit =
  case parseArgsPack (Nothing, Nothing) parseCtorArgs apk of
    Left  !err               -> throwEdhSTM pgsCtor UsageError err
    Right (Nothing, Nothing) -> ctorExit $ toDyn nil
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
              addr : _ -> ctorExit $ toDyn addr
              _ -> throwEdhSTM pgsCtor UsageError "bad network address spec"

 where
  parseCtorArgs =
    ArgsPackParser
        [ \arg (_, port') -> case edhUltimate arg of
          EdhString host -> Right (Just host, port')
          _              -> Left "Invalid host"
        , \arg (host', _) -> case edhUltimate arg of
          EdhString  port -> Right (host', Just $ Right port)
          EdhDecimal d    -> case D.decimalToInteger d of
            Just port -> Right (host', Just $ Left $ fromInteger port)
            Nothing   -> Left "port must be integer"
          _ -> Left "Invalid port"
        ]
      $ Map.fromList
          [ ( "host"
            , \arg (_, port') -> case edhUltimate arg of
              EdhString host -> Right (Just host, port')
              _              -> Left "Invalid host"
            )
          , ( "port"
            , \arg (host', _) -> case edhUltimate arg of
              EdhString  port -> Right (host', Just $ Right port)
              EdhDecimal d    -> case D.decimalToInteger d of
                Just port -> Right (host', Just $ Left $ fromInteger port)
                Nothing   -> Left "port must be integer"
              _ -> Left "Invalid port"
            )
          ]

addrMethods :: EdhProgState -> STM [(AttrKey, EdhValue)]
addrMethods !pgsModule = sequence
  [ (AttrByName nm, ) <$> mkHostProc scope vc nm hp args
  | (nm, vc, hp, args) <-
    [ ("__repr__", EdhMethod, addrReprProc, PackReceiver [])
    , ("host"    , EdhMethod, addrHostProc, PackReceiver [])
    , ("port"    , EdhMethod, addrPortProc, PackReceiver [])
    , ("info"    , EdhMethod, addrInfoProc, PackReceiver [])
    ]
  ]
 where
  !scope = contextScope $ edh'context pgsModule

  addrReprProc :: EdhProcedure
  addrReprProc _ !exit =
    withThatEntityStore' (\ !pgs -> exitEdhSTM pgs exit $ EdhString "Addr()")
      $ \ !pgs (addr :: AddrInfo) ->
          exitEdhSTM pgs exit $ EdhString $ addrRepr addr

  addrHostProc :: EdhProcedure
  addrHostProc _ !exit =
    withThatEntityStore' (\ !pgs -> exitEdhSTM pgs exit $ EdhString "")
      $ \ !pgs (addr :: AddrInfo) -> case addrAddress addr of
          SockAddrInet _ !host -> case hostAddressToTuple host of
            (n1, n2, n3, n4) ->
              exitEdhSTM pgs exit
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
            exitEdhSTM pgs exit
              $  EdhString
              $  T.pack
              $  show n1
              <> ":"
              <> show n2
              <> ":"
              <> show n3
              <> "::"
              <> show n4
          _ -> exitEdhSTM pgs exit $ EdhString "<unsupported-addr>"

  addrPortProc :: EdhProcedure
  addrPortProc _ !exit =
    withThatEntityStore' (\ !pgs -> exitEdhSTM pgs exit $ EdhDecimal 0)
      $ \ !pgs (addr :: AddrInfo) -> case addrAddress addr of
          SockAddrInet !port _ ->
            exitEdhSTM pgs exit $ EdhDecimal $ fromIntegral port
          SockAddrInet6 !port _ _ _ ->
            exitEdhSTM pgs exit $ EdhDecimal $ fromIntegral port
          _ -> exitEdhSTM pgs exit $ EdhDecimal 0

  addrInfoProc :: EdhProcedure
  addrInfoProc _ !exit =
    withThatEntityStore'
        (\ !pgs -> exitEdhSTM pgs exit $ EdhString "<bogus-addr>")
      $ \ !pgs (addr :: AddrInfo) ->
          exitEdhSTM pgs exit $ EdhString $ T.pack $ show addr


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
