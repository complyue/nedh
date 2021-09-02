module Language.Edh.Net.Addr where

-- import           Debug.Trace

import Control.Concurrent.STM
import Data.Dynamic
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Conc (unsafeIOToSTM)
import Language.Edh.CHI
import Network.Socket
import Prelude

createAddrClass :: Scope -> STM Object
createAddrClass !clsOuterScope =
  mkHostClass clsOuterScope "Addr" (allocEdhObj addrAllocator) [] $
    \ !clsScope -> do
      !mths <-
        sequence
          [ (AttrByName nm,) <$> mkHostProc clsScope vc nm hp
            | (nm, vc, hp) <-
                [ ("__repr__", EdhMethod, wrapHostProc addrReprProc),
                  ("host", EdhMethod, wrapHostProc addrHostProc),
                  ("port", EdhMethod, wrapHostProc addrPortProc),
                  ("info", EdhMethod, wrapHostProc addrInfoProc)
                ]
          ]
      iopdUpdate mths $ edh'scope'entity clsScope
  where
    addrAllocator :: "host" ?: Text -> "port" ?: Int -> EdhObjectAllocator
    addrAllocator
      (optionalArg -> !maybeHost)
      (optionalArg -> !maybePort)
      !ctorExit
      !etsCtor =
        case (maybeHost, maybePort) of
          (Nothing, Nothing) -> ctorExit Nothing $ HostStore (toDyn nil)
          (!host, !port) ->
            unsafeIOToSTM
              ( getAddrInfo
                  ( Just
                      defaultHints
                        { addrSocketType = Stream,
                          addrFlags = [AI_PASSIVE]
                        }
                  )
                  (T.unpack <$> host)
                  (show <$> port)
              )
              >>= \case
                addr : _ -> ctorExit Nothing $ HostStore (toDyn addr)
                _ -> throwEdh etsCtor UsageError "bad network address spec"

    addrReprProc :: EdhHostProc
    addrReprProc !exit !ets =
      withThisHostObj' ets (exitEdh ets exit $ EdhString "Addr()") $
        \(addr :: AddrInfo) -> exitEdh ets exit $ EdhString $ addrRepr addr

    addrHostProc :: EdhHostProc
    addrHostProc !exit !ets =
      withThisHostObj' ets (exitEdh ets exit $ EdhString "") $
        \(addr :: AddrInfo) -> case addrAddress addr of
          SockAddrInet _ !host -> case hostAddressToTuple host of
            (n1, n2, n3, n4) ->
              exitEdh ets exit $
                EdhString $
                  T.pack $
                    show n1
                      <> "."
                      <> show n2
                      <> "."
                      <> show n3
                      <> "."
                      <> show n4
          SockAddrInet6 _ _ (n1, n2, n3, n4) _ ->
            exitEdh ets exit $
              EdhString $
                T.pack $
                  show n1
                    <> ":"
                    <> show n2
                    <> ":"
                    <> show n3
                    <> "::"
                    <> show n4
          _ -> exitEdh ets exit $ EdhString "<unsupported-addr>"

    addrPortProc :: EdhHostProc
    addrPortProc !exit !ets =
      withThisHostObj' ets (exitEdh ets exit $ EdhDecimal 0) $
        \(addr :: AddrInfo) -> case addrAddress addr of
          SockAddrInet !port _ ->
            exitEdh ets exit $ EdhDecimal $ fromIntegral port
          SockAddrInet6 !port _ _ _ ->
            exitEdh ets exit $ EdhDecimal $ fromIntegral port
          _ -> exitEdh ets exit $ EdhDecimal 0

    addrInfoProc :: EdhHostProc
    addrInfoProc !exit !ets =
      withThisHostObj' ets (exitEdh ets exit $ EdhString "<bogus-addr>") $
        \(addr :: AddrInfo) ->
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
      T.pack $
        "Addr('"
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
    T.pack $
      "Addr('"
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
