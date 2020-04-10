
module Language.Edh.Net
  ( installNetBatteries
  -- TODO organize and doc the re-exports
  , module Language.Edh.Net.MicroProto
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
import           Language.Edh.Net.Server
import           Language.Edh.Net.Client


installNetBatteries :: EdhWorld -> IO ()
installNetBatteries !world =

  void $ installEdhModule world "net" $ \pgs exit -> do

    let moduScope = contextScope $ edh'context pgs
        modu      = thisObject moduScope

    peerClassVal <- mkHostClass moduScope "Peer" True peerCtor
    let peerClass = case peerClassVal of
          EdhClass cls -> cls
          _            -> error "bug: mkHostClass returned non-class"

    serverClassVal <- mkHostClass moduScope "Server" True (serverCtor peerClass)
    clientClassVal <- mkHostClass moduScope "Client" True (clientCtor peerClass)

    updateEntityAttrs
      pgs
      (objEntity modu)
      [ (AttrByName "Peer"  , peerClassVal)
      , (AttrByName "Server", serverClassVal)
      , (AttrByName "Client", clientClassVal)
      ]

    exit

