module Language.Edh.Net
  ( installNetBatteries,
    getPeerClass,
    getAddrClass,
    serviceAddressFrom,
    -- TODO organize and doc the re-exports
    module Language.Edh.Net.Addr,
    module Language.Edh.Net.Peer,
    module Language.Edh.Net.MicroProto,
  )
where

-- import           Debug.Trace

import Control.Monad
import Language.Edh.EHI
import Language.Edh.Net.Addr
import Language.Edh.Net.Advertiser
import Language.Edh.Net.Client
import Language.Edh.Net.Http
import Language.Edh.Net.MicroProto
import Language.Edh.Net.Peer
import Language.Edh.Net.Server
import Language.Edh.Net.Sniffer
import Language.Edh.Net.WebSocket
import Prelude

installNetBatteries :: EdhWorld -> IO ()
installNetBatteries !world = runProgramM_ world $ do
  installModuleM_ "net/RT" $ do
    !moduScope <- contextScope . edh'context <$> edhThreadState

    moduEffs <- importModuleM "net/effects"
    expNetEffs <- prepareExpStoreM moduEffs
    getObjPropertyM moduEffs (AttrByName "netPeer") >>= \case
      EdhSymbol !symNetPeer -> do
        !addrClass <- createAddrClass
        !peerClass <- createPeerClass

        !serverClass <-
          createServerClass
            consoleWarn
            addrClass
            peerClass
            symNetPeer
            expNetEffs
        !clientClass <-
          createClientClass
            consoleWarn
            addrClass
            peerClass
            symNetPeer
            expNetEffs

        !wsServerClass <-
          createWsServerClass
            consoleWarn
            addrClass
            peerClass
            symNetPeer
            expNetEffs

        !httpServerClass <- createHttpServerClass addrClass
        !htmlEscapeMth <-
          mkEdhProc EdhMethod "htmlEscape" $ wrapEdhProc htmlEscapeProc

        !snifferClass <- createSnifferClass addrClass
        !advertiserClass <- createAdvertiserClass addrClass

        let !moduArts =
              [ (AttrByName "Addr", EdhObject addrClass),
                (AttrByName "Peer", EdhObject peerClass),
                (AttrByName "Server", EdhObject serverClass),
                (AttrByName "Client", EdhObject clientClass),
                (AttrByName "WsServer", EdhObject wsServerClass),
                (AttrByName "HttpServer", EdhObject httpServerClass),
                (AttrByName "htmlEscape", htmlEscapeMth),
                (AttrByName "Sniffer", EdhObject snifferClass),
                (AttrByName "Advertiser", EdhObject advertiserClass)
              ]

        iopdUpdateEdh moduArts $ edh'scope'entity moduScope
        !esExps <- prepareExpStoreM (edh'scope'this moduScope)
        iopdUpdateEdh moduArts esExps
      _ ->
        throwEdhM
          EvalError
          "bug: @netPeer symbol not imported into 'net/effects'"
  where
    !worldLogger = consoleLogger $ edh'world'console world
    consoleWarn !msg = worldLogger 30 (Just "<nedh>") msg

getAddrClass :: Edh Object
getAddrClass =
  importModuleM "net/RT" >>= \ !moduRT ->
    getObjPropertyM moduRT (AttrByName "Addr") >>= \case
      EdhObject !clsAddr -> return clsAddr
      _ -> naM "bug: net/RT provides no Addr class"

getPeerClass :: Edh Object
getPeerClass =
  importModuleM "net/RT" >>= \ !moduRT ->
    getObjPropertyM moduRT (AttrByName "Peer") >>= \case
      EdhObject !clsPeer -> return clsPeer
      _ -> naM "bug: net/RT provides no Peer class"
