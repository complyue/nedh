
module Language.Edh.Net.Addr where

import           Prelude
-- import           Debug.Trace

import           GHC.Conc                       ( unsafeIOToSTM )

import           Control.Monad.Reader
import           Control.Concurrent.STM

import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import qualified Data.HashMap.Strict           as Map
import           Data.Dynamic

import           Network.Socket

import qualified Data.Lossless.Decimal         as D

import           Language.Edh.EHI


-- | host constructor Addr()
addrCtor
  :: EdhProgState
  -> ArgsPack  -- ctor args, if __init__() is provided, will go there too
  -> TVar (Map.HashMap AttrKey EdhValue)  -- out-of-band attr store
  -> (Dynamic -> STM ())  -- in-band data to be written to entity store
  -> STM ()
addrCtor !pgsCtor (ArgsPack [] kwargs) !obs !ctorExit | Map.null kwargs = do
  let !scope = contextScope $ edh'context pgsCtor
  methods <- sequence
    [ (AttrByName nm, ) <$> mkHostProc scope vc nm hp args
    | (nm, vc, hp, args) <-
      [ ("__repr__", EdhMethod, addrReprProc, PackReceiver [])
      , ("info"    , EdhMethod, addrInfoProc, PackReceiver [])
      ]
    ]
  modifyTVar' obs $ Map.union $ Map.fromList methods
  ctorExit $ toDyn nil
addrCtor !pgsCtor !apk !obs !ctorExit =
  case parseArgsPack (Nothing, Nothing) parseCtorArgs apk of
    Left err -> throwEdhSTM pgsCtor UsageError err
    Right (Nothing, Nothing) ->
      throwEdhSTM pgsCtor UsageError "neither host nor port specified"
    Right (host, port) ->
      unsafeIOToSTM
          ( getAddrInfo
              (Just defaultHints { addrSocketType = Stream
                                 , addrFlags      = [AI_PASSIVE]
                                 }
              )
              (T.unpack <$> host)
          $ case port of
              Nothing                  -> Nothing
              Just (Left  (pn :: Int)) -> Just $ show pn
              Just (Right sn         ) -> Just $ T.unpack sn
          )
        >>= \case
              addr : _ -> do
                let !scope = contextScope $ edh'context pgsCtor
                methods <- sequence
                  [ (AttrByName nm, ) <$> mkHostProc scope vc nm hp args
                  | (nm, vc, hp, args) <-
                    [ ( "__repr__"
                      , EdhMethod
                      , reprProc
                      $  T.pack
                      $  "Addr("
                      <> maybe "None" show host
                      <> (case port of
                           Nothing         -> ""
                           Just (Left  pn) -> ", " <> show pn
                           Just (Right sn) -> ", " <> show sn
                         )
                      <> ")"
                      , PackReceiver []
                      )
                    , ("info", EdhMethod, addrInfoProc, PackReceiver [])
                    ]
                  ]
                modifyTVar' obs $ Map.union $ Map.fromList methods
                ctorExit $ toDyn addr
              _ -> throwEdhSTM pgsCtor UsageError "bad network address spec"
 where
  parseCtorArgs =
    ArgsPackParser
        [ \arg (_, port') -> case edhUltimate arg of
          EdhString host -> Right (Just host, port')
          _              -> Left "Invalid host"
        , \arg (host', _) -> case edhUltimate arg of
          EdhString  port -> Right (host', Just $ Right port)
          EdhDecimal d    -> case D.decimalToInteger d of
            Just port -> Right (host', Just $ Left $ fromInteger port)
            Nothing   -> Left "port must be integer"
          _ -> Left "Invalid port"
        ]
      $ Map.fromList
          [ ( "host"
            , \arg (_, port') -> case edhUltimate arg of
              EdhString host -> Right (Just host, port')
              _              -> Left "Invalid host"
            )
          , ( "port"
            , \arg (host', _) -> case edhUltimate arg of
              EdhString  port -> Right (host', Just $ Right port)
              EdhDecimal d    -> case D.decimalToInteger d of
                Just port -> Right (host', Just $ Left $ fromInteger port)
                Nothing   -> Left "port must be integer"
              _ -> Left "Invalid port"
            )
          ]

  reprProc :: Text -> EdhProcedure
  reprProc !r _ !exit = exitEdhProc exit $ EdhString r

addrReprProc :: EdhProcedure
addrReprProc _ !exit = do
  pgs <- ask
  let ctx  = edh'context pgs
      this = thisObject $ contextScope ctx
      es   = entity'store $ objEntity this
  contEdhSTM $ do
    esd <- readTVar es
    case fromDynamic esd :: Maybe AddrInfo of
      Nothing -> exitEdhSTM pgs exit $ EdhString "Addr()"
      Just (AddrInfo _ _ _ _ (SockAddrInet port host) _) ->
        case hostAddressToTuple host of
          (n1, n2, n3, n4) ->
            exitEdhSTM pgs exit
              $  EdhString
              $  T.pack
              $  "Addr('"
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
      Just (AddrInfo _ _ _ _ (SockAddrInet6 port _ (n1, n2, n3, n4) _) _) ->
        exitEdhSTM pgs exit
          $  EdhString
          $  T.pack
          $  "Addr('"
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
      _ -> exitEdhSTM pgs exit $ EdhString "<unsupported-addr>"

addrInfoProc :: EdhProcedure
addrInfoProc _ !exit = do
  pgs <- ask
  let ctx  = edh'context pgs
      this = thisObject $ contextScope ctx
      es   = entity'store $ objEntity this
  contEdhSTM $ do
    esd <- readTVar es
    case fromDynamic esd :: Maybe AddrInfo of
      Nothing    -> exitEdhSTM pgs exit $ EdhString "<bogus-addr>"
      Just !addr -> exitEdhSTM pgs exit $ EdhString $ T.pack $ show addr
