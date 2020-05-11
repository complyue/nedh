
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

import qualified Data.HashMap.Strict           as Map

import           Language.Edh.EHI

import           Language.Edh.Net.MicroProto
import           Language.Edh.Net.Peer
import           Language.Edh.Net.Addr
import           Language.Edh.Net.Server
import           Language.Edh.Net.Client
import           Language.Edh.Net.Sniffer
import           Language.Edh.Net.Advertiser


installNetBatteries :: EdhWorld -> IO ()
installNetBatteries !world =

  void $ installEdhModule world "net/RT" $ \pgs exit -> do

    let moduScope = contextScope $ edh'context pgs
        modu      = thisObject moduScope

    peerClassVal <- mkHostClass moduScope "Peer" True peerCtor
    let peerClass = case peerClassVal of
          EdhClass cls -> cls
          _            -> error "bug: mkHostClass returned non-class"

    addrClassVal <- mkHostClass moduScope "Addr" True addrCtor
    let addrClass = case addrClassVal of
          EdhClass cls -> cls
          _            -> error "bug: mkHostClass returned non-class"

    serverClassVal <- mkHostClass moduScope
                                  "Server"
                                  True
                                  (serverCtor addrClass peerClass)
    clientClassVal <- mkHostClass moduScope
                                  "Client"
                                  True
                                  (clientCtor addrClass peerClass)
    snifferClassVal <- mkHostClass moduScope
                                   "Sniffer"
                                   True
                                   (snifferCtor addrClass)
    advertiserClassVal <- mkHostClass moduScope
                                      "Advertiser"
                                      True
                                      (advertiserCtor addrClass)
    let !moduArts =
          [ ("Peer"      , peerClassVal)
          , ("Addr"      , addrClassVal)
          , ("Server"    , serverClassVal)
          , ("Client"    , clientClassVal)
          , ("Sniffer"   , snifferClassVal)
          , ("Advertiser", advertiserClassVal)
          ]
    artsDict <- createEdhDict
      $ Map.fromList [ (EdhString k, v) | (k, v) <- moduArts ]
    updateEntityAttrs pgs (objEntity modu)
      $  [ (AttrByName k, v) | (k, v) <- moduArts ]
      ++ [(AttrByName "__exports__", artsDict)]

    exit

