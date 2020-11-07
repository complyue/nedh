
module Language.Edh.Net
  ( installNetBatteries
  -- TODO organize and doc the re-exports
  , module Language.Edh.Net.MicroProto
  , module Language.Edh.Net.Addr
  , module Language.Edh.Net.Peer
  , module Language.Edh.Net.Server
  , module Language.Edh.Net.Client
  )
where

import           Prelude
-- import           Debug.Trace

import           Control.Monad.Reader

import           Language.Edh.EHI

import           Language.Edh.Net.MicroProto
import           Language.Edh.Net.Peer
import           Language.Edh.Net.Addr
import           Language.Edh.Net.Server
import           Language.Edh.Net.Client
import           Language.Edh.Net.WebSocket
import           Language.Edh.Net.Http
import           Language.Edh.Net.Sniffer
import           Language.Edh.Net.Advertiser


installNetBatteries :: EdhWorld -> IO ()
installNetBatteries !world =

  void $ installEdhModule world "net/RT" $ \ !ets exit -> do

    let !moduScope = contextScope $ edh'context ets

    !peerClass       <- createPeerClass moduScope
    !addrClass       <- createAddrClass moduScope

    !serverClass     <- createServerClass addrClass peerClass moduScope
    !clientClass     <- createClientClass addrClass peerClass moduScope

    !wsServerClass   <- createWsServerClass addrClass peerClass moduScope
    !httpServerClass <- createHttpServerClass addrClass moduScope

    !snifferClass    <- createSnifferClass addrClass moduScope
    !advertiserClass <- createAdvertiserClass addrClass moduScope

    let !moduArts =
          [ ("Peer"      , EdhObject peerClass)
          , ("Addr"      , EdhObject addrClass)
          , ("Server"    , EdhObject serverClass)
          , ("Client"    , EdhObject clientClass)
          , ("WsServer"  , EdhObject wsServerClass)
          , ("HttpServer", EdhObject httpServerClass)
          , ("Sniffer"   , EdhObject snifferClass)
          , ("Advertiser", EdhObject advertiserClass)
          ]
    !artsDict <- EdhDict
      <$> createEdhDict [ (EdhString k, v) | (k, v) <- moduArts ]
    flip iopdUpdate (edh'scope'entity moduScope)
      $  [ (AttrByName k, v) | (k, v) <- moduArts ]
      ++ [(AttrByName "__exports__", artsDict)]

    exit

