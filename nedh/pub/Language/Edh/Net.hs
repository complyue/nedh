
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
import           Language.Edh.Net.WebSocket
import           Language.Edh.Net.Http
import           Language.Edh.Net.Sniffer
import           Language.Edh.Net.Advertiser


installNetBatteries :: EdhWorld -> IO ()
installNetBatteries !world =

  void $ installEdhModule world "net/RT" $ \pgs exit -> do

    let moduScope = contextScope $ edh'context pgs
        modu      = thisObject moduScope

    peerClassVal <-
      mkHostClass moduScope "Peer" peerCtor
      =<< createSideEntityManipulater True
      =<< peerMethods pgs
    let peerClass = case peerClassVal of
          EdhClass cls -> cls
          _            -> error "bug: mkHostClass returned non-class"

    addrClassVal <-
      mkHostClass moduScope "Addr" addrCtor
      =<< createSideEntityManipulater True
      =<< addrMethods pgs
    let addrClass = case addrClassVal of
          EdhClass cls -> cls
          _            -> error "bug: mkHostClass returned non-class"

    serverClassVal <-
      mkHostClass moduScope "Server" (serverCtor peerClass)
      =<< createSideEntityManipulater True
      =<< serverMethods addrClass pgs


    clientClassVal <-
      mkHostClass moduScope "Client" (clientCtor peerClass)
      =<< createSideEntityManipulater True
      =<< clientMethods addrClass pgs

    wsServerClassVal <-
      mkHostClass moduScope "WsServer" (wsServerCtor peerClass)
      =<< createSideEntityManipulater True
      =<< wsServerMethods addrClass pgs

    httpServerClassVal <-
      mkHostClass moduScope "HttpServer" httpServerCtor
      =<< createSideEntityManipulater True
      =<< httpServerMethods addrClass pgs

    snifferClassVal <-
      mkHostClass moduScope "Sniffer" (snifferCtor addrClass)
      =<< createSideEntityManipulater True
      =<< snifferMethods addrClass pgs

    advertiserClassVal <-
      mkHostClass moduScope "Advertiser" advertiserCtor
      =<< createSideEntityManipulater True
      =<< advertiserMethods addrClass pgs

    let !moduArts =
          [ ("Peer"      , peerClassVal)
          , ("Addr"      , addrClassVal)
          , ("Server"    , serverClassVal)
          , ("Client"    , clientClassVal)
          , ("WsServer"  , wsServerClassVal)
          , ("HttpServer", httpServerClassVal)
          , ("Sniffer"   , snifferClassVal)
          , ("Advertiser", advertiserClassVal)
          ]
    artsDict <- createEdhDict [ (EdhString k, v) | (k, v) <- moduArts ]
    updateEntityAttrs pgs (objEntity modu)
      $  [ (AttrByName k, v) | (k, v) <- moduArts ]
      ++ [(AttrByName "__exports__", artsDict)]

    exit

