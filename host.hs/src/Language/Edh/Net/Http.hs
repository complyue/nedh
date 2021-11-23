module Language.Edh.Net.Http where

-- import           Debug.Trace

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Monad.IO.Class
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as BL
import Data.Char
import Data.Functor
import Data.List
import Data.Map.Strict as Map
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy as TL
import Data.Text.Lazy.Builder
import qualified Data.Text.Lazy.Encoding as TLE
import Language.Edh.EHI
import Network.Socket
import qualified Snap.Core as Snap
import qualified Snap.Http.Server as Snap
import qualified Snap.Util.FileServe as Snap
import qualified System.Directory as D
import System.FilePath
import System.IO.Streams (OutputStream)
import qualified System.IO.Streams as Streams
import Prelude

-- todo make this tunable
mimeTypes :: Snap.MimeMap
mimeTypes = Snap.defaultMimeTypes

parseRoutes ::
  Maybe Dict ->
  Maybe EdhValue ->
  Text ->
  Edh (Snap.Snap ())
parseRoutes !maybeRoutes !maybeFront !defMime = case maybeRoutes of
  Nothing -> withFront
  (Just (Dict !dsRoutes)) -> iopdToListEdh dsRoutes >>= go []
  where
    withFront = case maybeFront of
      Nothing -> return Snap.pass
      Just !frontHndlr ->
        edhValueNullM frontHndlr >>= \case
          True -> return Snap.pass
          False ->
            parseRoute frontHndlr >>= \ !front -> return $ Snap.ifTop front
    go !rts [] =
      withFront
        >>= \ !front -> return $ front <|> Snap.route (reverse rts)
    go !rts ((pv, hv) : rest) = case edhUltimate pv of
      EdhString !p ->
        parseRoute hv >>= \ !r ->
          go ((TE.encodeUtf8 p, r) : rts) rest
      _ ->
        edhSimpleDescM pv >>= \ !badDesc ->
          throwEdhM UsageError $ "bad snap route: " <> badDesc

    parseRoute :: EdhValue -> Edh (Snap.Snap ())
    parseRoute !hv = case edhUltimate hv of
      EdhBlob !payload -> return $ inMemRes payload defMime
      EdhArgsPack (ArgsPack [EdhBlob !payload] !kwargs) ->
        let mimeVal =
              odLookupDefault (EdhString defMime) (AttrByName "mime") kwargs
         in edhValueStrM mimeVal >>= \ !mime ->
              return $ inMemRes payload mime
      !handlerProc -> do
        !world <- edh'prog'world <$> edhProgramState
        return $ edhHandleHttp defMime world handlerProc

    inMemRes :: ByteString -> Text -> Snap.Snap ()
    inMemRes !payload !mime = do
      Snap.modifyResponse $
        Snap.setContentLength (fromIntegral $ B.length payload)
          . Snap.setContentType (TE.encodeUtf8 mime)
      Snap.writeBS payload

htmlEscapeProc :: Text -> Edh EdhValue
htmlEscapeProc !txt =
  return $ EdhString $ TL.toStrict $ toLazyText $ htmlEscape txt

htmlEscape :: Text -> Builder
htmlEscape "" = mempty
htmlEscape t =
  let (p, s) = T.break needEscape t
      r = T.uncons s
   in fromText p `mappend` case r of
        Nothing -> mempty
        Just (c, ss) -> entity c `mappend` htmlEscape ss
  where
    needEscape c = c < ' ' || c `elem` ("<>&\"'" :: String)

    entity :: Char -> Builder
    entity '&' = fromText "&amp;"
    entity '<' = fromText "&lt;"
    entity '>' = fromText "&gt;"
    entity '\"' = fromText "&quot;"
    entity '\'' = fromText "&apos;"
    entity c =
      fromText "&#"
        `mappend` fromText (T.pack (show (ord c)))
        `mappend` fromText ";"

edhHandleHttp :: Text -> EdhWorld -> EdhValue -> Snap.Snap ()
edhHandleHttp !defMime world !handlerProc = do
  !req <- Snap.getRequest
  !reqBody <- Snap.readRequestBody $ 10 * 1024 * 1024
  !rsp <-
    liftIO $
      newTVarIO $
        Snap.setContentType (TE.encodeUtf8 defMime) Snap.emptyResponse
  let rspAddToOutput ::
        (OutputStream BB.Builder -> IO (OutputStream BB.Builder)) -> Edh ()
      rspAddToOutput enum = modifyTVarEdh' rsp $
        Snap.modifyResponseBody $ \b out -> b out >>= enum
      rspWriteBuilder b =
        rspAddToOutput $ \str -> Streams.write (Just b) str >> return str
      rspWriteBS = rspWriteBuilder . BB.byteString
      rspWriteText = rspWriteBS . TE.encodeUtf8

      returnEdh :: EdhValue -> Edh EdhValue
      returnEdh = return

      runEdhHandler = runProgramM' world $
        runNested $ do
          !effsScope <- contextScope . edh'context <$> edhThreadState
          !sbScope <- mkSandboxM effsScope
          !readBlob <-
            mkEdhProc EdhMethod "readBlob" $
              wrapEdhProc $ returnEdh $ EdhBlob $ BL.toStrict reqBody
          !readSource <- mkEdhProc EdhMethod "readSource" $
            wrapEdhProc $ do
              let !src = TL.toStrict $ TLE.decodeUtf8 reqBody
              returnEdh $ EdhString src
          !readCommand <- mkEdhProc EdhIntrpr "readCommand" $
            wrapEdhProc $ do
              let !src = TL.toStrict $ TLE.decodeUtf8 reqBody
                  !srcName =
                    TE.decodeUtf8 $
                      Snap.rqClientAddr req <> " @>@ " <> Snap.rqURI req
              runInSandboxM sbScope (evalSrcM srcName src)
          !setResponseCode <-
            mkEdhProc EdhMethod "setResponseCode" $
              wrapEdhProc $ \ !stCode -> do
                modifyTVarEdh' rsp $ Snap.setResponseCode stCode
                returnEdh nil
          !setContentType <-
            mkEdhProc EdhMethod "setContentType" $
              wrapEdhProc $ \ !mimeType -> do
                modifyTVarEdh' rsp $
                  Snap.setContentType $ TE.encodeUtf8 mimeType
                returnEdh nil
          !writeText <- mkEdhProc EdhMethod "writeText" $
            wrapEdhProc $ \ !payload -> do
              rspWriteText payload
              returnEdh nil
          !writeBS <- mkEdhProc EdhMethod "writeBS" $
            wrapEdhProc $ \ !payload -> do
              rspWriteBS payload
              returnEdh nil
          let effArts =
                [ ( AttrByName "rqPathInfo",
                    EdhString $ TE.decodeUtf8 $ Snap.rqPathInfo req
                  ),
                  ( AttrByName "rqContextPath",
                    EdhString $ TE.decodeUtf8 $ Snap.rqContextPath req
                  ),
                  ( AttrByName "rqParams",
                    EdhArgsPack $ wrapParams (Snap.rqParams req)
                  ),
                  (AttrByName "readBlob", readBlob),
                  (AttrByName "readSource", readSource),
                  (AttrByName "readCommand", readCommand),
                  (AttrByName "setResponseCode", setResponseCode),
                  (AttrByName "setContentType", setContentType),
                  (AttrByName "writeText", writeText),
                  -- TODO more Snap API as effects
                  (AttrByName "writeBS", writeBS)
                ]
          prepareEffStoreM >>= iopdUpdateEdh effArts
          callM handlerProc []
  liftIO runEdhHandler >>= \case
    EdhCaseOther -> Snap.pass
    EdhFallthrough -> Snap.pass
    _ -> Snap.finishWith =<< liftIO (readTVarIO rsp)
  where
    wrapParams :: Snap.Params -> ArgsPack
    wrapParams params =
      ArgsPack [] $
        odFromList
          [ (AttrByName $ TE.decodeUtf8 k, decodeVs vs)
            | (k, vs) <- Map.toList params
          ]
    decodeVs :: [ByteString] -> EdhValue
    decodeVs [] = edhNone
    decodeVs [v] = EdhString $ TE.decodeUtf8 v
    decodeVs vs =
      EdhArgsPack $ flip ArgsPack odEmpty $ vs <&> EdhString . TE.decodeUtf8

data EdhHttpServer = EdhHttpServer
  { -- the import spec of the modules to provide static resources
    edh'http'server'modus :: ![Text],
    -- custom http routes
    edh'http'custom'routes :: Snap.Snap (),
    -- local network interface to bind
    edh'http'server'addr :: !Text,
    -- local network port to bind
    edh'http'server'port :: !PortNumber,
    -- max port number to try bind
    edh'http'server'port'max :: !PortNumber,
    -- actually listened network addresses
    edh'http'serving'addrs :: !(TMVar [AddrInfo]),
    -- end-of-life status
    edh'http'server'eol :: !(TMVar (Either SomeException ()))
  }

createHttpServerClass :: Object -> Edh Object
createHttpServerClass !addrClass =
  mkEdhClass' "HttpServer" serverAllocator [] $ do
    !mths <-
      sequence
        [ (AttrByName nm,) <$> mkEdhProc vc nm hp
          | (nm, vc, hp) <-
              [ ("addrs", EdhMethod, wrapEdhProc addrsProc),
                ("eol", EdhMethod, wrapEdhProc eolProc),
                ("join", EdhMethod, wrapEdhProc joinProc),
                ("stop", EdhMethod, wrapEdhProc stopProc),
                ("__repr__", EdhMethod, wrapEdhProc reprProc)
              ]
        ]

    !clsScope <- contextScope . edh'context <$> edhThreadState
    iopdUpdateEdh mths $ edh'scope'entity clsScope
  where
    serverAllocator ::
      "resource'modules" !: EdhValue ->
      "addr" ?: Text ->
      "port" ?: Int ->
      "port'max" ?: Int ->
      "routes" ?: Dict ->
      "front" ?: EdhValue ->
      "defaultMime" ?: Text ->
      Edh ObjectStore
    serverAllocator
      (mandatoryArg -> !resource'modules)
      (defaultArg "127.0.0.1" -> !ctorAddr)
      (defaultArg 3780 -> !ctorPort)
      (optionalArg -> port'max)
      (optionalArg -> !maybeRoutes)
      (optionalArg -> !maybeFront)
      (defaultArg "text/plain" -> !defMime) =
        case edhUltimate resource'modules of
          EdhString !modu -> withModules [modu]
          EdhArgsPack (ArgsPack !args _kwargs) -> do
            !modus <- forM args $ \case
              EdhString !modu -> return modu
              !v ->
                edhSimpleDescM v >>= \ !badDesc ->
                  throwEdhM UsageError $
                    "invalid modu: " <> badDesc
            withModules modus
          _ ->
            throwEdhM UsageError $
              "invalid type for modus: " <> edhTypeNameOf resource'modules
        where
          withModules !modus = do
            !world <- edh'prog'world <$> edhProgramState
            !custRoutes <- parseRoutes maybeRoutes maybeFront defMime
            !server <- inlineSTM $ do
              servAddrs <- newEmptyTMVar
              servEoL <- newEmptyTMVar
              return
                EdhHttpServer
                  { edh'http'server'modus = modus,
                    edh'http'custom'routes = custRoutes,
                    edh'http'server'addr = ctorAddr,
                    edh'http'server'port = fromIntegral ctorPort,
                    edh'http'server'port'max =
                      fromIntegral $ fromMaybe ctorPort port'max,
                    edh'http'serving'addrs = servAddrs,
                    edh'http'server'eol = servEoL
                  }
            afterTxIO $ do
              void $
                forkFinally
                  (serverThread world server)
                  ( atomically
                      . void
                      . (
                          -- fill empty addrs if the connection has ever failed
                          tryPutTMVar (edh'http'serving'addrs server) [] <*
                        )
                      -- mark server end-of-life anyway finally
                      . tryPutTMVar (edh'http'server'eol server)
                  )
            pinAndStoreHostValue server

          serverThread :: EdhWorld -> EdhHttpServer -> IO ()
          serverThread
            !world
            ( EdhHttpServer
                !resModus
                !custRoutes
                !servAddr
                !servPort
                !portMax
                !servAddrs
                !servEoL
              ) =
              do
                !servThId <- myThreadId
                void $
                  forkIO $ do
                    -- async terminate the snap thread on stop signal
                    _ <- atomically $ readTMVar servEoL
                    killThread servThId
                !wd <- D.canonicalizePath "."
                !addr <- resolveServAddr
                let httpCfg :: Snap.Config Snap.Snap ()
                    httpCfg =
                      Snap.setBind (TE.encodeUtf8 servAddr) $
                        Snap.setStartupHook httpListening $
                          Snap.setVerbose False $
                            Snap.setAccessLog Snap.ConfigNoLog $
                              Snap.setErrorLog
                                (Snap.ConfigIoLog logSnapError)
                                mempty
                    httpListening !httpInfo = do
                      listenAddrs <-
                        sequence
                          (getSocketName <$> Snap.getStartupSockets httpInfo)
                      atomically $
                        fromMaybe [] {- HLINT ignore "Redundant <$>" -}
                          <$> tryTakeTMVar servAddrs
                          >>= putTMVar servAddrs
                            . ( ( (\sockName -> addr {addrAddress = sockName})
                                    <$> listenAddrs
                                )
                                  ++
                              )
                    staticRoutes = do
                      Snap.getSafePath >>= \case
                        "" -> Snap.modifyRequest $ \r ->
                          r {Snap.rqPathInfo = "front.html"}
                        path | "/" `isSuffixOf` path ->
                          Snap.modifyRequest $ \r ->
                            r
                              { Snap.rqPathInfo =
                                  C.pack $ path <> "front.html"
                              }
                        _ -> pure ()
                      serveStaticArtifacts mimeTypes wd resModus
                    tryServ !cfg !port =
                      Snap.simpleHttpServe
                        (Snap.setPort (fromIntegral port) cfg)
                        (custRoutes <|> staticRoutes)
                        `catch` \(e :: SomeException) ->
                          if port < portMax
                            then tryServ cfg (port + 1)
                            else throw e
                tryServ httpCfg servPort
              where
                resolveServAddr = do
                  let hints =
                        defaultHints
                          { addrFlags = [AI_PASSIVE],
                            addrSocketType = Stream
                          }
                  addr : _ <-
                    getAddrInfo
                      (Just hints)
                      (Just $ T.unpack servAddr)
                      (Just (show servPort))
                  return addr

                logger = consoleLogger $ edh'world'console world
                logSnapError :: ByteString -> IO ()
                logSnapError payload =
                  atomically $ logger 40 (Just "snap-http") (TE.decodeUtf8 payload)

    reprProc :: Edh EdhValue
    reprProc =
      thisHostObjectOf
        >>= \(EdhHttpServer !modus _ !addr !port !port'max _ _) ->
          return $
            EdhString $
              "HttpServer("
                <> T.pack (show modus)
                <> ", "
                <> T.pack (show addr)
                <> ", "
                <> T.pack (show port)
                <> ", port'max="
                <> T.pack (show port'max)
                <> ")"

    addrsProc :: Edh EdhValue
    addrsProc =
      thisHostObjectOf >>= \ !server ->
        inlineSTM (readTMVar $ edh'http'serving'addrs server) >>= wrapAddrs []
      where
        wrapAddrs :: [EdhValue] -> [AddrInfo] -> Edh EdhValue
        wrapAddrs addrs [] =
          return $ EdhArgsPack $ ArgsPack addrs odEmpty
        wrapAddrs !addrs (addr : rest) =
          createArbiHostObjectM addrClass addr
            >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

    eolProc :: Edh EdhValue
    eolProc =
      thisHostObjectOf >>= \ !server ->
        inlineSTM (tryReadTMVar $ edh'http'server'eol server) >>= \case
          Nothing -> return $ EdhBool False
          Just (Left !e) -> throwHostM e
          Just (Right ()) -> return $ EdhBool True

    joinProc :: Edh EdhValue
    joinProc =
      thisHostObjectOf >>= \ !server ->
        inlineSTM (readTMVar $ edh'http'server'eol server) >>= \case
          Left !e -> throwHostM e
          Right () -> return nil

    stopProc :: Edh EdhValue
    stopProc =
      thisHostObjectOf >>= \ !server ->
        inlineSTM $
          fmap EdhBool $
            tryPutTMVar (edh'http'server'eol server) $ Right ()

serveStaticArtifacts ::
  Snap.MonadSnap m => Snap.MimeMap -> FilePath -> [Text] -> m ()
serveStaticArtifacts !mimes !wd !modus = do
  reqPath <- Snap.getSafePath
  liftIO (locateModuFile wd reqPath) >>= \case
    Nothing -> Snap.pass
    Just !mfp -> Snap.serveFileAs (Snap.fileType mimes $ takeFileName mfp) mfp
  where
    locateModuFile :: FilePath -> FilePath -> IO (Maybe FilePath)
    locateModuFile !d !reqPath =
      moduHomeFrom d >>= \case
        Nothing -> return Nothing
        Just !mhd -> searchModuHome mhd modus
      where
        searchModuHome :: FilePath -> [Text] -> IO (Maybe FilePath)
        searchModuHome !mhd [] =
          locateModuFile (takeDirectory $ takeDirectory mhd) reqPath
        searchModuHome !mhd (modu : restModus) =
          D.doesFileExist mfp >>= \case
            False -> searchModuHome mhd restModus
            True -> return $ Just mfp
          where
            !mfp = mhd </> T.unpack modu </> reqPath

moduHomeFrom :: FilePath -> IO (Maybe FilePath)
moduHomeFrom !candiPath = do
  let !hd = candiPath </> "edh_modules"
  D.doesDirectoryExist hd >>= \case
    True -> return $ Just hd
    False -> do
      let !parentPath = takeDirectory candiPath
      if equalFilePath parentPath candiPath
        then return Nothing
        else moduHomeFrom parentPath
