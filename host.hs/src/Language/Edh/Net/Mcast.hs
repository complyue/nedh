module Language.Edh.Net.Mcast where

import Network.Socket
import Prelude

isMultiCastAddr :: AddrInfo -> Bool
isMultiCastAddr (AddrInfo _ _ _ _ (SockAddrInet _ !hostAddr) _) =
  case hostAddressToTuple hostAddr of
    (n, _, _, _) -> 224 <= n && n <= 239
isMultiCastAddr (AddrInfo _ _ _ _ SockAddrInet6 {} _) =
  error "IPv6 not supported yet"
isMultiCastAddr _ = False
