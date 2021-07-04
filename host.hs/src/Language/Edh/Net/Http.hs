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
import Data.Char
import Data.Dynamic
import Data.Functor
import Data.List
import Data.Map.Strict as Map
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy as TL
import Data.Text.Lazy.Builder
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
  EdhThreadState -> Maybe Dict -> Text -> (Snap.Snap () -> STM ()) -> STM ()
parseRoutes _ets Nothing _defMime !exit = exit Snap.pass
parseRoutes !ets (Just (Dict _ !dsRoutes)) !defMime !exit =
  iopdToList dsRoutes >>= go []
  where
    go !rts [] = exit $ Snap.route $ reverse rts
    go !rts ((rv, av) : rest) = case edhUltimate rv of
      EdhString !r -> case edhUltimate av of
        EdhBlob !payload ->
          go ((TE.encodeUtf8 r, inMemRes payload defMime) : rts) rest
        EdhArgsPack (ArgsPack [EdhBlob !payload] !kwargs) ->
          let mimeVal =
                odLookupDefault (EdhString defMime) (AttrByName "mime") kwargs
           in edhValueStr ets mimeVal $ \ !mime ->
                go ((TE.encodeUtf8 r, inMemRes payload mime) : rts) rest
        !handlerProc ->
          go
            ( (TE.encodeUtf8 r, edhHandleHttp defMime world handlerProc) :
              rts
            )
            rest
      _ -> edhValueDesc ets rv $ \ !badDesc ->
        throwEdh ets UsageError $ "bad snap route: " <> badDesc

    inMemRes :: ByteString -> Text -> Snap.Snap ()
    inMemRes !payload !mime = do
      Snap.modifyResponse $
        Snap.setContentLength (fromIntegral $ B.length payload)
          . Snap.setContentType (TE.encodeUtf8 mime)
      Snap.writeBS payload

    world = edh'prog'world $ edh'thread'prog ets

htmlEscapeProc :: Text -> EdhHostProc
htmlEscapeProc !txt !exit =
  exitEdhTx exit $ EdhString $ TL.toStrict $ toLazyText $ htmlEscape txt

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
  !rsp <-
    liftIO $
      newTVarIO $
        Snap.setContentType (TE.encodeUtf8 defMime) Snap.emptyResponse
  let rspAddToOutput ::
        (OutputStream BB.Builder -> IO (OutputStream BB.Builder)) -> STM ()
      rspAddToOutput enum = modifyTVar rsp $
        Snap.modifyResponseBody $ \b out -> b out >>= enum
      rspWriteBuilder b =
        rspAddToOutput $ \str -> Streams.write (Just b) str >> return str
      rspWriteBS = rspWriteBuilder . BB.byteString
      rspWriteText = rspWriteBS . TE.encodeUtf8

      runEdhHandler = runEdhProgram' world $
        pushEdhStack $ \ !etsEffs -> do
          let effsScope = contextScope $ edh'context etsEffs
          !setResponseCode <- mkHostProc effsScope EdhMethod "setResponseCode" $
            wrapHostProc $ \ !stCode !exit !ets -> do
              modifyTVar' rsp $ Snap.setResponseCode stCode
              exitEdh ets exit nil
          !setContentType <- mkHostProc effsScope EdhMethod "setContentType" $
            wrapHostProc $ \ !mimeType !exit !ets -> do
              modifyTVar' rsp $ Snap.setContentType $ TE.encodeUtf8 mimeType
              exitEdh ets exit nil
          !writeText <- mkHostProc effsScope EdhMethod "writeText" $
            wrapHostProc $ \ !payload !exit !ets -> do
              rspWriteText payload
              exitEdh ets exit nil
          !writeBS <- mkHostProc effsScope EdhMethod "writeBS" $
            wrapHostProc $ \ !payload !exit !ets -> do
              rspWriteBS payload
              exitEdh ets exit nil
          prepareEffStore etsEffs (edh'scope'entity effsScope)
            >>= iopdUpdate
              [ ( AttrByName "rqPathInfo",
                  EdhString $ TE.decodeUtf8 $ Snap.rqPathInfo req
                ),
                ( AttrByName "rqContextPath",
                  EdhString $ TE.decodeUtf8 $ Snap.rqContextPath req
                ),
                ( AttrByName "rqParams",
                  EdhArgsPack $ wrapParams (Snap.rqParams req)
                ),
                (AttrByName "setResponseCode", setResponseCode),
                (AttrByName "setContentType", setContentType),
                (AttrByName "writeText", writeText),
                -- TODO more Snap API as effects
                (AttrByName "writeBS", writeBS)
              ]
          runEdhTx etsEffs $ edhMakeCall handlerProc [] haltEdhProgram
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

createHttpServerClass :: Object -> Scope -> STM Object
createHttpServerClass !addrClass !clsOuterScope =
  mkHostClass clsOuterScope "HttpServer" (allocEdhObj serverAllocator) [] $
    \ !clsScope -> do
      !mths <-
        sequence
          [ (AttrByName nm,) <$> mkHostProc clsScope vc nm hp
            | (nm, vc, hp) <-
                [ ("addrs", EdhMethod, wrapHostProc addrsProc),
                  ("eol", EdhMethod, wrapHostProc eolProc),
                  ("join", EdhMethod, wrapHostProc joinProc),
                  ("stop", EdhMethod, wrapHostProc stopProc),
                  ("__repr__", EdhMethod, wrapHostProc reprProc)
                ]
          ]
      iopdUpdate mths $ edh'scope'entity clsScope
  where
    serverAllocator ::
      "resource'modules" !: EdhValue ->
      "addr" ?: Text ->
      "port" ?: Int ->
      "port'max" ?: Int ->
      "routes" ?: Dict ->
      "defaultMime" ?: Text ->
      EdhObjectAllocator
    serverAllocator
      (mandatoryArg -> !resource'modules)
      (defaultArg "127.0.0.1" -> !ctorAddr)
      (defaultArg 3780 -> !ctorPort)
      (optionalArg -> port'max)
      (optionalArg -> !maybeRoutes)
      (defaultArg "text/plain" -> !defMime)
      !ctorExit
      !etsCtor =
        if edh'in'tx etsCtor
          then
            throwEdh
              etsCtor
              UsageError
              "you don't create network objects within a transaction"
          else case edhUltimate resource'modules of
            EdhString !modu -> withModules [modu]
            EdhArgsPack (ArgsPack !args _kwargs) ->
              seqcontSTM
                ( flip fmap args $ \ !moduVal !exit' -> case moduVal of
                    EdhString !modu -> exit' modu
                    !v ->
                      throwEdh etsCtor UsageError $
                        "invalid type for modu: " <> edhTypeNameOf v
                )
                withModules
            _ ->
              throwEdh etsCtor UsageError $
                "invalid type for modus: "
                  <> edhTypeNameOf resource'modules
        where
          withModules !modus = parseRoutes etsCtor maybeRoutes defMime $
            \ !custRoutes -> do
              servAddrs <- newEmptyTMVar
              servEoL <- newEmptyTMVar
              let !server =
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
              runEdhTx etsCtor $
                edhContIO $ do
                  void $
                    forkFinally
                      (serverThread server)
                      ( atomically
                          . void
                          . (
                              -- fill empty addrs if the connection has ever
                              -- failed
                              tryPutTMVar servAddrs [] <*
                            )
                          -- mark server end-of-life anyway finally
                          . tryPutTMVar servEoL
                      )
                  atomically $ ctorExit Nothing $ HostStore (toDyn server)

          serverThread :: EdhHttpServer -> IO ()
          serverThread
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

          world = edh'prog'world $ edh'thread'prog etsCtor
          logger = consoleLogger $ edh'world'console world
          logSnapError :: ByteString -> IO ()
          logSnapError payload =
            atomically $ logger 40 (Just "snap-http") (TE.decodeUtf8 payload)

    reprProc :: EdhHostProc
    reprProc !exit !ets =
      withThisHostObj ets $
        \(EdhHttpServer !modus _ !addr !port !port'max _ _) ->
          exitEdh ets exit $
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

    addrsProc :: EdhHostProc
    addrsProc !exit !ets = withThisHostObj ets $
      \ !server -> readTMVar (edh'http'serving'addrs server) >>= wrapAddrs []
      where
        wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
        wrapAddrs addrs [] =
          exitEdh ets exit $ EdhArgsPack $ ArgsPack addrs odEmpty
        wrapAddrs !addrs (addr : rest) =
          edhCreateHostObj addrClass addr
            >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

    eolProc :: EdhHostProc
    eolProc !exit !ets = withThisHostObj ets $ \ !server ->
      tryReadTMVar (edh'http'server'eol server) >>= \case
        Nothing -> exitEdh ets exit $ EdhBool False
        Just (Left !e) ->
          edh'exception'wrapper world (Just ets) e
            >>= \ !exo -> exitEdh ets exit $ EdhObject exo
        Just (Right ()) -> exitEdh ets exit $ EdhBool True
      where
        world = edh'prog'world $ edh'thread'prog ets

    joinProc :: EdhHostProc
    joinProc !exit !ets = withThisHostObj ets $ \ !server ->
      readTMVar (edh'http'server'eol server) >>= \case
        Left !e ->
          edh'exception'wrapper world (Just ets) e
            >>= \ !exo -> edhThrow ets $ EdhObject exo
        Right () -> exitEdh ets exit nil
      where
        world = edh'prog'world $ edh'thread'prog ets

    stopProc :: EdhHostProc
    stopProc !exit !ets = withThisHostObj ets $ \ !server -> do
      stopped <- tryPutTMVar (edh'http'server'eol server) $ Right ()
      exitEdh ets exit $ EdhBool stopped

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
