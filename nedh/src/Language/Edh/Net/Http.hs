
module Language.Edh.Net.Http where

import           Prelude
-- import           Debug.Trace

import qualified System.Directory              as D
import           System.FilePath

import           Control.Exception
import           Control.Applicative
import           Control.Monad
import           Control.Concurrent
import           Control.Concurrent.STM

import           Control.Monad.Reader

import           Data.List
import           Data.Maybe
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import qualified Data.Text.Encoding            as TE
import           Data.ByteString                ( ByteString )
import qualified Data.ByteString               as B
import qualified Data.ByteString.Char8         as C
import qualified Data.HashMap.Strict           as Map
import           Data.Dynamic

import           Network.Socket

import qualified Snap.Core                     as Snap
import qualified Snap.Http.Server              as Snap
import qualified Snap.Util.FileServe           as Snap

import qualified Data.Lossless.Decimal         as D

import           Language.Edh.EHI


parseRoutes :: EdhProgState -> EdhValue -> (Snap.Snap () -> STM ()) -> STM ()
parseRoutes !pgs !routes !exit = case edhUltimate routes of
  EdhArgsPack (ArgsPack !args !kwargs) ->
    mimeArg "text/plain" kwargs $ \defMime -> if null args
      then exit Snap.pass
      else foldl'contSTM Snap.pass (<|>) (parseRoute defMime <$> args) exit
  _ -> throwEdhSTM pgs UsageError "Invalid routes"
 where
  mimeArg :: Text -> Map.HashMap AttrKey EdhValue -> (Text -> STM ()) -> STM ()
  mimeArg !defMime !kwargs !exit' =
    case Map.lookup (AttrByName "mime") kwargs of
      Nothing                -> exit' defMime
      Just (EdhString !mime) -> exit' mime
      Just !badMime ->
        throwEdhSTM pgs UsageError $ "Invalid mime: " <> T.pack (show badMime)
  inMemRoute :: Text -> Text -> ByteString -> Snap.Snap ()
  inMemRoute !path !mime !payload = Snap.path (TE.encodeUtf8 path) $ do
    Snap.modifyResponse
      $ Snap.setContentLength (fromIntegral $ B.length payload)
      . Snap.setContentType (TE.encodeUtf8 mime)
    Snap.writeBS payload
  parseRoute :: Text -> EdhValue -> (Snap.Snap () -> STM ()) -> STM ()
  parseRoute !defMime !route !exit' = case edhUltimate route of
    EdhArgsPack (ArgsPack !args !kwargs) -> mimeArg defMime kwargs $ \mime ->
      case args of
        [EdhString !path, EdhBlob !payload] ->
          exit' $ inMemRoute path mime payload
        [EdhString !path, EdhString !content] ->
          exit' $ inMemRoute path mime (TE.encodeUtf8 content)
        badRoute -> throwEdhSTM pgs UsageError $ "Invalid route: " <> T.pack
          (show badRoute)
    badRoute ->
      throwEdhSTM pgs UsageError $ "Invalid route: " <> T.pack (show badRoute)


type HttpServerAddr = Text
type HttpServerPort = PortNumber

data EdhHttpServer = EdhHttpServer {
    -- the import spec of the modules to provide static resources
      edh'http'server'modus :: ![Text]
    -- custom http routes
    , edh'http'custom'routes :: Snap.Snap ()
    -- local network interface to bind
    , edh'http'server'addr :: !HttpServerAddr
    -- local network port to bind
    , edh'http'server'port :: !HttpServerPort
    -- max port number to try bind
    , edh'http'server'port'max :: !HttpServerPort
    -- actually listened network addresses
    , edh'http'serving'addrs :: !(TMVar [AddrInfo])
    -- end-of-life status
    , edh'http'server'eol :: !(TMVar (Either SomeException ()))
  }

-- | host constructor HttpServer()
httpServerCtor :: EdhHostCtor
httpServerCtor !pgsCtor !apk !ctorExit =
  case
      parseArgsPack
        ( Nothing -- modus
        , "127.0.0.1" :: HttpServerAddr -- addr
        , 3780 :: HttpServerPort -- port
        , Nothing -- port'max
        , nil -- custom routes
        )
        parseCtorArgs
        apk
    of
      Left err -> throwEdhSTM pgsCtor UsageError err
      Right (Nothing, _, _, _, _) ->
        throwEdhSTM pgsCtor UsageError "missing resource modules"
      Right (Just !modus, !addr, !port, !port'max, !custRoutes) ->
        parseRoutes pgsCtor custRoutes $ \routes -> do
          servAddrs <- newEmptyTMVar
          servEoL   <- newEmptyTMVar
          let !server = EdhHttpServer
                { edh'http'server'modus    = modus
                , edh'http'custom'routes   = routes
                , edh'http'server'addr     = addr
                , edh'http'server'port     = port
                , edh'http'server'port'max = fromMaybe port port'max
                , edh'http'serving'addrs   = servAddrs
                , edh'http'server'eol      = servEoL
                }
              !scope = contextScope $ edh'context pgsCtor
          edhPerformIO
              pgsCtor
              (forkFinally
                (serverThread server)
                ( atomically
                . void
                . (
                    -- fill empty addrs if the connection has ever failed
                   tryPutTMVar servAddrs [] <*)
                  -- mark server end-of-life anyway finally
                . tryPutTMVar servEoL
                )
              )
            $ \_ -> contEdhSTM $ ctorExit $ toDyn server
 where
  parseCtorArgs =
    ArgsPackParser
        [ \arg (_, addr', port', port'max, routes) -> case edhUltimate arg of
          EdhString !modu ->
            Right (Just [modu], addr', port', port'max, routes)
          EdhArgsPack (ArgsPack !args _kwargs) ->
            (, addr', port', port'max, routes) <$> (Just <$>)
              (sequence $ flip fmap args $ \case
                EdhString !modu -> Right modu
                !v ->
                  Left $ "Invalid type for modu: " <> T.pack (edhTypeNameOf v)
              )
          _ -> Left $ "Invalid type for modus: " <> T.pack (edhTypeNameOf arg)
        , \arg (modu', _, port', port'max, routes) -> case edhUltimate arg of
          EdhString !addr -> Right (modu', addr, port', port'max, routes)
          _               -> Left "Invalid addr"
        , \arg (modu', addr', _, port'max, routes) -> case edhUltimate arg of
          EdhDecimal !d -> case D.decimalToInteger d of
            Just !port ->
              Right (modu', addr', fromIntegral port, port'max, routes)
            Nothing -> Left "port must be integer"
          _ -> Left "Invalid port"
        ]
      $ Map.fromList
          [ ( "addr"
            , \arg (modu', _, port', port'max, routes) ->
              case edhUltimate arg of
                EdhString !addr -> Right (modu', addr, port', port'max, routes)
                _               -> Left "Invalid addr"
            )
          , ( "port"
            , \arg (modu', addr', _, port'max, routes) ->
              case edhUltimate arg of
                EdhDecimal !d -> case D.decimalToInteger d of
                  Just !port ->
                    Right (modu', addr', fromIntegral port, port'max, routes)
                  Nothing -> Left "port must be integer"
                _ -> Left "Invalid port"
            )
          , ( "port'max"
            , \arg (modu', addr', port', _, routes) -> case edhUltimate arg of
              EdhDecimal d -> case D.decimalToInteger d of
                Just !port'max -> Right
                  (modu', addr', port', Just $ fromInteger port'max, routes)
                Nothing -> Left "port'max must be integer"
              _ -> Left "Invalid port'max"
            )
          , ( "routes"
            , \arg (modu', addr', port', port'max, _) -> case edhUltimate arg of
              !routes -> Right (modu', addr', port', port'max, routes)
            )
          ]

  serverThread :: EdhHttpServer -> IO ()
  serverThread (EdhHttpServer !resModus !custRoutes !servAddr !servPort !portMax !servAddrs !servEoL)
    = do
      servThId <- myThreadId
      void $ forkIO $ do -- async terminate the snap thread on stop signal
        _ <- atomically $ readTMVar servEoL
        killThread servThId
      wd   <- D.canonicalizePath "."
      addr <- resolveServAddr
      let
        httpCfg :: Snap.Config Snap.Snap a
        httpCfg =
          Snap.setBind (TE.encodeUtf8 servAddr)
            $ Snap.setStartupHook httpListening
            $ Snap.setVerbose False
            $ Snap.setAccessLog Snap.ConfigNoLog
            $ Snap.setErrorLog Snap.ConfigNoLog mempty
        httpListening !httpInfo = do
          listenAddrs <- sequence
            (getSocketName <$> Snap.getStartupSockets httpInfo)
          atomically
            $   fromMaybe []
            <$> tryTakeTMVar servAddrs
            >>= putTMVar servAddrs
            . (((\sockName -> addr { addrAddress = sockName }) <$> listenAddrs) ++
              )
        staticRoutes = serveStaticArtifacts Snap.defaultMimeTypes wd resModus
        frontRoute   = Snap.getSafePath >>= \case
          "" -> do
            Snap.modifyRequest $ \r -> r { Snap.rqPathInfo = "front.html" }
            staticRoutes
          path -> if "/" `isSuffixOf` path
            then do
              Snap.modifyRequest
                $ \r -> r { Snap.rqPathInfo = C.pack $ path <> "front.html" }
              staticRoutes
            else staticRoutes
        tryServ !cfg !port =
          Snap.simpleHttpServe (Snap.setPort (fromIntegral port) cfg)
                               (custRoutes <|> frontRoute <|> staticRoutes)
            `catch` \(e :: SomeException) -> if port < portMax
                      then tryServ cfg (port + 1)
                      else throw e
      tryServ httpCfg servPort

   where
    resolveServAddr = do
      let hints =
            defaultHints { addrFlags = [AI_PASSIVE], addrSocketType = Stream }
      addr : _ <- getAddrInfo (Just hints)
                              (Just $ T.unpack servAddr)
                              (Just (show servPort))
      return addr


httpServerMethods :: Class -> EdhProgState -> STM [(AttrKey, EdhValue)]
httpServerMethods !addrClass !pgsModule = sequence
  [ (AttrByName nm, ) <$> mkHostProc scope vc nm hp args
  | (nm, vc, hp, args) <-
    [ ("addrs"   , EdhMethod, addrsProc, PackReceiver [])
    , ("eol"     , EdhMethod, eolProc  , PackReceiver [])
    , ("join"    , EdhMethod, joinProc , PackReceiver [])
    , ("stop"    , EdhMethod, stopProc , PackReceiver [])
    , ("__repr__", EdhMethod, reprProc , PackReceiver [])
    ]
  ]
 where
  !scope = contextScope $ edh'context pgsModule

  reprProc :: EdhProcedure
  reprProc _ !exit =
    withThatEntity
      $ \ !pgs (EdhHttpServer !modus _ !addr !port !port'max _ _) ->
          exitEdhSTM pgs exit
            $  EdhString
            $  "HttpServer("
            <> T.pack (show modus)
            <> ", "
            <> T.pack (show addr)
            <> ", "
            <> T.pack (show port)
            <> ", port'max="
            <> T.pack (show port'max)
            <> ")"

  addrsProc :: EdhProcedure
  addrsProc _ !exit = withThatEntity $ \ !pgs !server -> do
    let wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
        wrapAddrs addrs [] =
          exitEdhSTM pgs exit $ EdhArgsPack $ ArgsPack addrs mempty
        wrapAddrs !addrs (addr : rest) =
          runEdhProc pgs
            $ createEdhObject addrClass (ArgsPack [] mempty)
            $ \(OriginalValue !addrVal _ _) -> case addrVal of
                EdhObject !addrObj -> contEdhSTM $ do
                  -- actually fill in the in-band entity storage here
                  writeTVar (entity'store $ objEntity addrObj) $ toDyn addr
                  wrapAddrs (addrVal : addrs) rest
                _ -> error "bug: addr ctor returned non-object"
    edhPerformSTM pgs (readTMVar $ edh'http'serving'addrs server)
      $ contEdhSTM
      . wrapAddrs []

  eolProc :: EdhProcedure
  eolProc _ !exit = withThatEntity $ \ !pgs !server ->
    tryReadTMVar (edh'http'server'eol server) >>= \case
      Nothing         -> exitEdhSTM pgs exit $ EdhBool False
      Just (Left  e ) -> toEdhError pgs e $ \exv -> exitEdhSTM pgs exit exv
      Just (Right ()) -> exitEdhSTM pgs exit $ EdhBool True

  joinProc :: EdhProcedure
  joinProc _ !exit = withThatEntity $ \ !pgs !server ->
    edhPerformSTM pgs (readTMVar (edh'http'server'eol server)) $ \case
      Left  e  -> contEdhSTM $ toEdhError pgs e $ \exv -> edhThrowSTM pgs exv
      Right () -> exitEdhProc exit nil

  stopProc :: EdhProcedure
  stopProc _ !exit = withThatEntity $ \ !pgs !server -> do
    stopped <- tryPutTMVar (edh'http'server'eol server) $ Right ()
    exitEdhSTM pgs exit $ EdhBool stopped


serveStaticArtifacts
  :: Snap.MonadSnap m => Snap.MimeMap -> FilePath -> [Text] -> m ()
serveStaticArtifacts !mimes !wd !modus = do
  reqPath <- Snap.getSafePath
  liftIO (locateModuFile wd reqPath) >>= \case
    Nothing   -> Snap.pass
    Just !mfp -> Snap.serveFileAs (Snap.fileType mimes $ takeFileName mfp) mfp
 where
  locateModuFile :: FilePath -> FilePath -> IO (Maybe FilePath)
  locateModuFile !d !reqPath = moduHomeFrom d >>= \case
    Nothing   -> return Nothing
    Just !mhd -> searchModuHome mhd modus
   where
    searchModuHome :: FilePath -> [Text] -> IO (Maybe FilePath)
    searchModuHome !mhd [] =
      locateModuFile (takeDirectory $ takeDirectory mhd) reqPath
    searchModuHome !mhd (modu : restModus) = D.doesFileExist mfp >>= \case
      False -> searchModuHome mhd restModus
      True  -> return $ Just mfp
      where !mfp = mhd </> T.unpack modu </> reqPath


moduHomeFrom :: FilePath -> IO (Maybe FilePath)
moduHomeFrom !candiPath = do
  let !hd = candiPath </> "edh_modules"
  D.doesDirectoryExist hd >>= \case
    True  -> return $ Just hd
    False -> do
      let !parentPath = takeDirectory candiPath
      if equalFilePath parentPath candiPath
        then return Nothing
        else moduHomeFrom parentPath
