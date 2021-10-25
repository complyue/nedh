module Language.Edh.Net.Addr where

-- import           Debug.Trace

import Control.Monad.IO.Class
import Data.Dynamic
import Data.Text (Text)
import qualified Data.Text as T
import Language.Edh.MHI
import Network.Socket
import Prelude

createAddrClass :: Edh Object
createAddrClass =
  mkEdhClass "Addr" (allocObjM addrAllocator) [] $ do
    !mths <-
      sequence
        [ (AttrByName nm,) <$> mkEdhProc vc nm hp
          | (nm, vc, hp) <-
              [ ("__repr__", EdhMethod, wrapEdhProc addrReprProc),
                ("host", EdhMethod, wrapEdhProc addrHostProc),
                ("port", EdhMethod, wrapEdhProc addrPortProc),
                ("info", EdhMethod, wrapEdhProc addrInfoProc)
              ]
        ]

    !clsScope <- contextScope . edh'context <$> edhThreadState
    iopdUpdateEdh mths $ edh'scope'entity clsScope
  where
    addrAllocator ::
      "host" ?: Text ->
      "port" ?: Int ->
      Edh (Maybe Unique, ObjectStore)
    addrAllocator
      (optionalArg -> !maybeHost)
      (optionalArg -> !maybePort) =
        case (maybeHost, maybePort) of
          (Nothing, Nothing) -> return (Nothing, HostStore (toDyn nil))
          (!host, !port) ->
            liftIO
              ( getAddrInfo
                  ( Just
                      defaultHints
                        { addrSocketType = Stream,
                          addrFlags = [AI_PASSIVE]
                        }
                  )
                  (T.unpack <$> host)
                  (show <$> port)
              )
              >>= \case
                addr : _ -> return (Nothing, HostStore (toDyn addr))
                _ -> throwEdhM UsageError "bad network address spec"

    withThisAddr :: forall r. (Object -> AddrInfo -> Edh r) -> Edh r
    withThisAddr withAddr = do
      !this <- edh'scope'this . contextScope . edh'context <$> edhThreadState
      case fromDynamic =<< dynamicHostData this of
        Nothing -> throwEdhM EvalError "bug: this is not an Addr"
        Just !col -> withAddr this col

    addrReprProc :: Edh EdhValue
    addrReprProc = withThisAddr $ \_this addr ->
      return $ EdhString $ addrRepr addr

    addrHostProc :: Edh EdhValue
    addrHostProc = withThisAddr $ \_this addr -> case addrAddress addr of
      SockAddrInet _ !host -> case hostAddressToTuple host of
        (n1, n2, n3, n4) ->
          return $
            EdhString $
              T.pack $
                show n1
                  <> "."
                  <> show n2
                  <> "."
                  <> show n3
                  <> "."
                  <> show n4
      SockAddrInet6 _ _ (n1, n2, n3, n4) _ ->
        return $
          EdhString $
            T.pack $
              show n1
                <> ":"
                <> show n2
                <> ":"
                <> show n3
                <> "::"
                <> show n4
      _ -> return $ EdhString "<unsupported-addr>"

    addrPortProc :: Edh EdhValue
    addrPortProc = withThisAddr $ \_this addr -> case addrAddress addr of
      SockAddrInet !port _ ->
        return $ EdhDecimal $ fromIntegral port
      SockAddrInet6 !port _ _ _ ->
        return $ EdhDecimal $ fromIntegral port
      _ -> return $ EdhDecimal 0

    addrInfoProc :: Edh EdhValue
    addrInfoProc = withThisAddr $ \_this addr ->
      return $ EdhString $ T.pack $ show addr

addrWithPort :: SockAddr -> PortNumber -> SockAddr
addrWithPort (SockAddrInet _ !host) !port = SockAddrInet port host
addrWithPort (SockAddrInet6 _ !fi !host !scope) !port =
  SockAddrInet6 port fi host scope
addrWithPort (SockAddrUnix !name) _ = SockAddrUnix name

addrRepr :: AddrInfo -> Text
addrRepr !addr = case addrAddress addr of
  SockAddrInet !port !host -> case hostAddressToTuple host of
    (n1, n2, n3, n4) ->
      T.pack $
        "Addr('"
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
  SockAddrInet6 port _ (n1, n2, n3, n4) _ ->
    T.pack $
      "Addr('"
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
  _ -> "<unsupported-addr>"
