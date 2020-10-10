
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

import           Language.Edh.EHI


-- todo make this tunable
mimeTypes :: Snap.MimeMap
mimeTypes = flip Map.union Snap.defaultMimeTypes
  $ Map.fromList [(".mjs", "text/javascript")]


parseRoutes :: EdhThreadState -> EdhValue -> (Snap.Snap () -> STM ()) -> STM ()
parseRoutes !ets !routes !exit = case edhUltimate routes of
  EdhArgsPack (ArgsPack !args !kwargs) ->
    mimeArg "text/plain" kwargs $ \defMime -> if null args
      then exit Snap.pass
      else foldcontSTM Snap.pass (<|>) (parseRoute defMime <$> args) exit
  _ -> throwEdh ets UsageError "invalid routes"
 where
  mimeArg :: Text -> KwArgs -> (Text -> STM ()) -> STM ()
  mimeArg !defMime !kwargs !exit' = case odLookup (AttrByName "mime") kwargs of
    Nothing                -> exit' defMime
    Just (EdhString !mime) -> exit' mime
    Just !badMime ->
      throwEdh ets UsageError $ "invalid mime: " <> T.pack (show badMime)
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
        badRoute ->
          throwEdh ets UsageError $ "invalid route: " <> T.pack (show badRoute)
    badRoute ->
      throwEdh ets UsageError $ "invalid route: " <> T.pack (show badRoute)


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


createHttpServerClass :: Object -> Scope -> STM Object
createHttpServerClass !addrClass !clsOuterScope =
  mkHostClass clsOuterScope "HttpServer" (allocEdhObj serverAllocator) []
    $ \ !clsScope -> do
        !mths <- sequence
          [ (AttrByName nm, ) <$> mkHostProc clsScope vc nm hp
          | (nm, vc, hp) <-
            [ ("addrs"   , EdhMethod, wrapHostProc addrsProc)
            , ("eol"     , EdhMethod, wrapHostProc eolProc)
            , ("join"    , EdhMethod, wrapHostProc joinProc)
            , ("stop"    , EdhMethod, wrapHostProc stopProc)
            , ("__repr__", EdhMethod, wrapHostProc reprProc)
            ]
          ]
        iopdUpdate mths $ edh'scope'entity clsScope

 where

  -- | host constructor HttpServer()
  serverAllocator
    :: "resModules" !: EdhValue
    -> "addr" ?: Text
    -> "port" ?: Int
    -> "port'max" ?: Int
    -> "routes" ?: EdhValue
    -> EdhObjectAllocator
  serverAllocator (mandatoryArg -> !resModules) (defaultArg "127.0.0.1" -> !ctorAddr) (defaultArg 3780 -> !ctorPort) (optionalArg -> port'max) (defaultArg nil -> !routes) !ctorExit !etsCtor
    = if edh'in'tx etsCtor
      then throwEdh etsCtor
                    UsageError
                    "you don't create network objects within a transaction"
      else case edhUltimate resModules of
        EdhString !modu -> withModules [modu]
        EdhArgsPack (ArgsPack !args _kwargs) ->
          seqcontSTM
              (flip fmap args $ \ !moduVal !exit' -> case moduVal of
                EdhString !modu -> exit' modu
                !v ->
                  throwEdh etsCtor UsageError
                    $  "invalid type for modu: "
                    <> T.pack (edhTypeNameOf v)
              )
            $ withModules
        _ ->
          throwEdh etsCtor UsageError $ "invalid type for modus: " <> T.pack
            (edhTypeNameOf resModules)

   where
    withModules !modus = parseRoutes etsCtor routes $ \ !custRoutes -> do
      servAddrs <- newEmptyTMVar
      servEoL   <- newEmptyTMVar
      let
        !server = EdhHttpServer
          { edh'http'server'modus    = modus
          , edh'http'custom'routes   = custRoutes
          , edh'http'server'addr     = ctorAddr
          , edh'http'server'port     = fromIntegral ctorPort
          , edh'http'server'port'max = fromIntegral
                                         $ fromMaybe ctorPort port'max
          , edh'http'serving'addrs   = servAddrs
          , edh'http'server'eol      = servEoL
          }
      runEdhTx etsCtor $ edhContIO $ do
        void $ forkFinally
          (serverThread server)
          ( atomically
          . void
          . (
              -- fill empty addrs if the connection has ever failed
             tryPutTMVar servAddrs [] <*)
            -- mark server end-of-life anyway finally
          . tryPutTMVar servEoL
          )
        atomically $ ctorExit $ HostStore (toDyn server)

    serverThread :: EdhHttpServer -> IO ()
    serverThread (EdhHttpServer !resModus !custRoutes !servAddr !servPort !portMax !servAddrs !servEoL)
      = do
        !servThId <- myThreadId
        void $ forkIO $ do -- async terminate the snap thread on stop signal
          _ <- atomically $ readTMVar servEoL
          killThread servThId
        !wd   <- D.canonicalizePath "."
        !addr <- resolveServAddr
        let
          httpCfg :: Snap.Config Snap.Snap ()
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
              . (((\sockName -> addr { addrAddress = sockName }) <$> listenAddrs
                 ) ++
                )
          staticRoutes = serveStaticArtifacts mimeTypes wd resModus
          frontRoute   = Snap.getSafePath >>= \case
            "" -> do
              Snap.modifyRequest $ \r -> r { Snap.rqPathInfo = "front.html" }
              staticRoutes
            path -> if "/" `isSuffixOf` path
              then do
                Snap.modifyRequest $ \r ->
                  r { Snap.rqPathInfo = C.pack $ path <> "front.html" }
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


  reprProc :: EdhHostProc
  reprProc !exit !ets =
    withThisHostObj ets
      $ \(EdhHttpServer !modus _ !addr !port !port'max _ _) ->
          exitEdh ets exit
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

  addrsProc :: EdhHostProc
  addrsProc !exit !ets = withThisHostObj ets
    $ \ !server -> readTMVar (edh'http'serving'addrs server) >>= wrapAddrs []
   where
    wrapAddrs :: [EdhValue] -> [AddrInfo] -> STM ()
    wrapAddrs addrs [] =
      exitEdh ets exit $ EdhArgsPack $ ArgsPack addrs odEmpty
    wrapAddrs !addrs (addr : rest) = edhCreateHostObj addrClass (toDyn addr) []
      >>= \ !addrObj -> wrapAddrs (EdhObject addrObj : addrs) rest

  eolProc :: EdhHostProc
  eolProc !exit !ets = withThisHostObj ets $ \ !server ->
    tryReadTMVar (edh'http'server'eol server) >>= \case
      Nothing        -> exitEdh ets exit $ EdhBool False
      Just (Left !e) -> edh'exception'wrapper world e
        >>= \ !exo -> exitEdh ets exit $ EdhObject exo
      Just (Right ()) -> exitEdh ets exit $ EdhBool True
    where world = edh'ctx'world $ edh'context ets

  joinProc :: EdhHostProc
  joinProc !exit !ets = withThisHostObj ets $ \ !server ->
    readTMVar (edh'http'server'eol server) >>= \case
      Left !e ->
        edh'exception'wrapper world e >>= \ !exo -> edhThrow ets $ EdhObject exo
      Right () -> exitEdh ets exit nil
    where world = edh'ctx'world $ edh'context ets

  stopProc :: EdhHostProc
  stopProc !exit !ets = withThisHostObj ets $ \ !server -> do
    stopped <- tryPutTMVar (edh'http'server'eol server) $ Right ()
    exitEdh ets exit $ EdhBool stopped


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
