
module Language.Edh.Net
  ( installNetBatteries
  -- TODO organize and doc the re-exports
  , module Language.Edh.Net.MicroProto
  , module Language.Edh.Net.Peer
  , module Language.Edh.Net.Server
  )
where

import           Prelude
-- import           Debug.Trace

import           Control.Monad.Reader

import           Language.Edh.EHI

import           Language.Edh.Net.MicroProto
import           Language.Edh.Net.Peer
import           Language.Edh.Net.Server


installNetBatteries :: EdhWorld -> IO ()
installNetBatteries !world =

  void $ installEdhModule world "net/Comm" $ \pgs exit -> do

    let moduScope = contextScope $ edh'context pgs
        modu      = thisObject moduScope

    peerClassVal <- mkHostClass moduScope "Peer" True peerCtor
    let peerClass = case peerClassVal of
          EdhClass cls -> cls
          _            -> error "bug: mkHostClass returned non-class"

    serverClassVal <- mkHostClass moduScope "Server" True (serverCtor peerClass)

    updateEntityAttrs
      pgs
      (objEntity modu)
      [(AttrByName "Peer", peerClassVal), (AttrByName "Server", serverClassVal)]

    exit

