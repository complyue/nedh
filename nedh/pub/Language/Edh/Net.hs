
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

import qualified Data.Text                     as T
import qualified Data.HashMap.Strict           as Map
import qualified Data.Lossless.Decimal         as D

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

    serveClients <-
      mkHostProc moduScope EdhMethod "serveClients" (serveClientsProc peerClass)
        $ PackReceiver
            [ RecvArg "service" Nothing Nothing
            , RecvArg "addr"
                      Nothing
                      (Just (LitExpr $ StringLiteral "127.0.0.1"))
            , RecvArg "port" Nothing (Just (LitExpr $ DecLiteral 3721))
            ]

    updateEntityAttrs
      pgs
      (objEntity modu)
      [ (AttrByName "Peer"        , peerClassVal)
      , (AttrByName "serveClients", serveClients)
      ]

    exit


serveClientsProc :: Class -> EdhProcedure
serveClientsProc !peerClass !apk !exit =
  case
      parseArgsPack (Nothing, "127.0.0.1" :: ServingAddr, 3721 :: ServingPort)
                    parseArgs
                    apk
    of
      Left  err                        -> throwEdh UsageError err
      Right (Nothing     , _   , _   ) -> throwEdh UsageError "missing service"
      Right (Just service, addr, port) -> do
        pgs <- ask
        let !ctx = edh'context pgs
        contEdhSTM
          $ flip (edhPerformIO pgs) (\() -> exitEdhSTM pgs exit nil)
          $ servEdhClients (contextWorld ctx)
                           peerClass
                           addr
                           port
                           (T.unpack service)
 where
  parseArgs =
    ArgsPackParser
        [ \arg (_, addr', port') -> case arg of
          EdhString !service -> Right (Just service, addr', port')
          _                  -> Left "Invalid service"
        , \arg (service', _, port') -> case arg of
          EdhString addr -> Right (service', addr, port')
          _              -> Left "Invalid addr"
        , \arg (service', addr', _) -> case arg of
          EdhDecimal d -> case D.decimalToInteger d of
            Just port -> Right (service', addr', fromIntegral port)
            Nothing   -> Left "port must be integer"
          _ -> Left "Invalid port"
        ]
      $ Map.fromList
          [ ( "addr"
            , \arg (service', _, port') -> case arg of
              EdhString addr -> Right (service', addr, port')
              _              -> Left "Invalid addr"
            )
          , ( "port"
            , \arg (service', addr', _) -> case arg of
              EdhDecimal d -> case D.decimalToInteger d of
                Just port -> Right (service', addr', fromIntegral port)
                Nothing   -> Left "port must be integer"
              _ -> Left "Invalid port"
            )
          ]
