module Language.Edh.Net
  ( installNetBatteries,
    withPeerClass,
    withAddrClass,
    withNetSymbol,
    -- TODO organize and doc the re-exports
    module Language.Edh.Net.MicroProto,
    module Language.Edh.Net.Addr,
    module Language.Edh.Net.Peer,
    module Language.Edh.Net.Server,
    module Language.Edh.Net.Client,
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
installNetBatteries !world =
  void $
    installEdhModule world "net/RT" $ \ !ets exit -> runEdhTx ets $
      importEdhModule "net/effects" $ \ !moduEffs _ets ->
        lookupEdhObjAttr moduEffs (AttrByName "netPeer") >>= \case
          (_, EdhSymbol !symNetPeer) ->
            prepareExpStore ets moduEffs $ \ !esNetEffs -> do
              let !moduScope = contextScope $ edh'context ets

              !peerClass <- createPeerClass moduScope
              !addrClass <- createAddrClass moduScope

              !serverClass <-
                createServerClass
                  consoleWarn
                  addrClass
                  peerClass
                  symNetPeer
                  esNetEffs
                  moduScope
              !clientClass <-
                createClientClass
                  consoleWarn
                  addrClass
                  peerClass
                  symNetPeer
                  esNetEffs
                  moduScope

              !wsServerClass <-
                createWsServerClass
                  consoleWarn
                  addrClass
                  peerClass
                  symNetPeer
                  esNetEffs
                  moduScope
              !httpServerClass <- createHttpServerClass addrClass moduScope
              !htmlEscapeMth <-
                mkHostProc moduScope EdhMethod "htmlEscape" $
                  wrapHostProc htmlEscapeProc

              !snifferClass <- createSnifferClass addrClass moduScope
              !advertiserClass <- createAdvertiserClass addrClass moduScope

              let !moduArts =
                    [ (AttrByName "Peer", EdhObject peerClass),
                      (AttrByName "Addr", EdhObject addrClass),
                      (AttrByName "Server", EdhObject serverClass),
                      (AttrByName "Client", EdhObject clientClass),
                      (AttrByName "WsServer", EdhObject wsServerClass),
                      (AttrByName "HttpServer", EdhObject httpServerClass),
                      (AttrByName "htmlEscape", htmlEscapeMth),
                      (AttrByName "Sniffer", EdhObject snifferClass),
                      (AttrByName "Advertiser", EdhObject advertiserClass)
                    ]
              iopdUpdate moduArts $ edh'scope'entity moduScope
              prepareExpStore ets (edh'scope'this moduScope) $ \ !esExps ->
                iopdUpdate moduArts esExps

              exit
          _ ->
            throwEdh
              ets
              EvalError
              "bug: @netPeer symbol not imported into 'net/effects'"
  where
    !worldLogger = consoleLogger $ edh'world'console world
    consoleWarn !msg = worldLogger 30 (Just "<nedh>") msg

withPeerClass :: (Object -> EdhTx) -> EdhTx
withPeerClass !act = importEdhModule "net/RT" $ \ !moduRT !ets ->
  lookupEdhObjAttr moduRT (AttrByName "Peer") >>= \case
    (_, EdhObject !clsPeer) -> runEdhTx ets $ act clsPeer
    _ -> error "bug: net/RT provides no Peer class"

withAddrClass :: (Object -> EdhTx) -> EdhTx
withAddrClass !act = importEdhModule "net/RT" $ \ !moduRT !ets ->
  lookupEdhObjAttr moduRT (AttrByName "Addr") >>= \case
    (_, EdhObject !clsAddr) -> runEdhTx ets $ act clsAddr
    _ -> error "bug: net/RT provides no Addr class"

withNetSymbol :: AttrName -> (Symbol -> EdhTx) -> EdhTx
withNetSymbol !symName !act = importEdhModule "net/symbols" $
  \ !moduSyms !ets ->
    lookupEdhObjAttr moduSyms (AttrByName symName) >>= \case
      (_, EdhSymbol !sym) -> runEdhTx ets $ act sym
      _ ->
        throwEdh ets EvalError $
          "bug: net/symbols provides no symbol named '" <> symName <> "'"
