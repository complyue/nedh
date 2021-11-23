module Language.Edh.Net.Addr where

-- import           Debug.Trace

import Control.Monad.IO.Class
import Data.Text (Text)
import qualified Data.Text as T
import Language.Edh.EHI
import Network.Socket
import Prelude

createAddrClass :: Edh Object
createAddrClass =
  mkEdhClass' "Addr" addrAllocator [] $ do
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
      Edh ObjectStore
    addrAllocator
      (optionalArg -> !maybeHost)
      (optionalArg -> !maybePort) =
        case (maybeHost, maybePort) of
          (Nothing, Nothing) -> return $ storeHostValue nil
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
                addr : _ -> pinAndStoreHostValue addr
                _ -> throwEdhM UsageError "bad network address spec"

    addrReprProc :: Edh EdhValue
    addrReprProc =
      thisHostObjectOf @AddrInfo >>= \addr ->
        return $ EdhString $ addrRepr addr

    addrHostProc :: Edh EdhValue
    addrHostProc =
      thisHostObjectOf @AddrInfo >>= \addr -> case addrAddress addr of
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
    addrPortProc =
      thisHostObjectOf @AddrInfo >>= \addr -> case addrAddress addr of
        SockAddrInet !port _ ->
          return $ EdhDecimal $ fromIntegral port
        SockAddrInet6 !port _ _ _ ->
          return $ EdhDecimal $ fromIntegral port
        _ -> return $ EdhDecimal 0

    addrInfoProc :: Edh EdhValue
    addrInfoProc =
      thisHostObjectOf @AddrInfo >>= \addr ->
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
