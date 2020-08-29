
module Language.Edh.Net.Peer where

import           Prelude
-- import           Debug.Trace

import           Control.Exception
import           Control.Concurrent.STM

import qualified Data.List.NonEmpty            as NE
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import qualified Data.Text.Encoding            as TE
import qualified Data.HashMap.Strict           as Map
import           Data.Dynamic

import           Language.Edh.EHI

import           Language.Edh.Net.MicroProto


data Peer = Peer {
      edh'peer'ident :: !Text
    , edh'peer'eol :: !(TMVar (Either SomeException ()))
      -- todo this ever needs to be in CPS?
    , edh'peer'posting :: !(Packet -> STM ())
    , edh'peer'hosting :: !(STM Packet)
    , edh'peer'channels :: !(TVar (Map.HashMap EdhValue EventSink))
  }

postPeerCommand :: EdhThreadState -> Peer -> Packet -> EdhTxExit -> STM ()
postPeerCommand !ets !peer !pkt !exit =
  tryReadTMVar (edh'peer'eol peer) >>= \case
    Just _  -> throwEdh ets EvalError "posting to a peer already end-of-life"
    Nothing -> do
      edh'peer'posting peer pkt
      exitEdh ets exit nil

readPeerSource :: EdhThreadState -> Peer -> EdhTxExit -> STM ()
readPeerSource !ets peer@(Peer _ !eol _ !ho _) !exit =
  ((Right <$> ho) `orElse` (Left <$> readTMVar eol)) >>= \case
    -- reached normal end-of-stream
    Left (Right _) -> exitEdh ets exit nil
    -- previously eol due to error
    Left (Left !ex) ->
      edh'exception'wrapper (edh'ctx'world $ edh'context ets) ex
        >>= \ !exo -> edhThrow ets $ EdhObject exo
    -- got next command source incoming
    Right pkt@(Packet !dir !payload) -> case dir of
      "" -> exitEdh ets exit $ EdhString $ TE.decodeUtf8 payload
      _  -> landPeerCmd peer pkt ets exit

-- | Read next command from peer
--
-- Note a command may target a specific channel, thus get posted to that 
--      channel's sink, and nil will be returned from here for it.
readPeerCommand :: EdhThreadState -> Peer -> EdhTxExit -> STM ()
readPeerCommand !ets peer@(Peer _ !eol _ !ho _) !exit =
  ((Right <$> ho) `orElse` (Left <$> readTMVar eol)) >>= \case
    -- reached normal end-of-stream
    Left (Right _) -> exitEdh ets exit nil
    -- previously eol due to error
    Left (Left !ex) ->
      edh'exception'wrapper (edh'ctx'world $ edh'context ets) ex
        >>= \ !exo -> edhThrow ets $ EdhObject exo
    -- got next command incoming
    Right !pkt -> landPeerCmd peer pkt ets exit

landPeerCmd :: Peer -> Packet -> EdhThreadState -> EdhTxExit -> STM ()
landPeerCmd (Peer !ident _ _ _ !chdVar) (Packet !dir !payload) !ets !exit =
  case T.stripPrefix "blob:" dir of
    Just !chLctr -> runEdhTx ets $ landValue chLctr $ EdhBlob payload
    Nothing ->
      runEdhTx ets $ evalEdh srcName (TE.decodeUtf8 payload) $ \ !cmdVal ->
        landValue dir cmdVal
 where
  !srcName = T.unpack ident
  landValue !chLctr !val = if T.null chLctr
    -- to the default channel, which yields as direct result of 
    -- `peer.readCommand()`
    then exitEdhTx exit val
    -- to a specific channel, which should be located by the directive
    else evalEdh srcName chLctr $ \ !lctr _ets -> do
      !chd <- readTVar chdVar
      case Map.lookup lctr chd of
        Nothing ->
          throwEdh ets UsageError $ "missing command channel: " <> T.pack
            (show lctr)
        Just !chSink -> do
          publishEvent chSink val  -- post the cmd to channel
          -- yield nil as for `peer.readCommand()` wrt this cmd packet
          exitEdh ets exit nil


createPeerClass :: Scope -> STM Object
createPeerClass !clsOuterScope =
  mkHostClass' clsOuterScope "Peer" peerAllocator [] $ \ !clsScope -> do
    !mths <- sequence
      [ (AttrByName nm, ) <$> mkHostProc clsScope vc nm hp args
      | (nm, vc, hp, args) <-
        [ ("eol" , EdhMethod, eolProc , PackReceiver [])
        , ("join", EdhMethod, joinProc, PackReceiver [])
        , ("stop", EdhMethod, stopProc, PackReceiver [])
        , ( "armedChannel"
          , EdhMethod
          , armedChannelProc
          , PackReceiver [mandatoryArg "chLctr"]
          )
        , ( "armChannel"
          , EdhMethod
          , armChannelProc
          , PackReceiver
            [mandatoryArg "chLctr", optionalArg "chSink" $ LitExpr SinkCtor]
          )
        , ("readSource", EdhMethod, readPeerSrcProc, PackReceiver [])
        , ( "readCommand"
          , EdhMethod
          , readPeerCmdProc
          , PackReceiver [optionalArg "inScopeOf" edhNoneExpr]
          )
        , ( "p2c"
          , EdhMethod
          , p2cProc
          , PackReceiver [mandatoryArg "dir", mandatoryArg "cmd"]
          )
        , ( "postCommand"
          , EdhMethod
          , postPeerCmdProc
          , PackReceiver
            [mandatoryArg "cmd", optionalArg "dir" $ LitExpr NilLiteral]
          )
        , ("ident"   , EdhMethod, identProc, PackReceiver [])
        , ("__repr__", EdhMethod, reprProc , PackReceiver [])
        ]
      ]
    iopdUpdate mths $ edh'scope'entity clsScope

 where

  -- | host constructor Peer()
  peerAllocator :: EdhObjectAllocator
  -- not really constructable from Edh code, this only creates bogus peer obj
  peerAllocator _ _ !ctorExit = ctorExit =<< HostStore <$> newTVar (toDyn nil)

  eolProc :: EdhHostProc
  eolProc _ !exit !ets = withThisHostObj ets $ \_hsv !peer ->
    tryReadTMVar (edh'peer'eol peer) >>= \case
      Nothing        -> exitEdh ets exit $ EdhBool False
      Just (Left !e) -> edh'exception'wrapper world e
        >>= \ !exo -> exitEdh ets exit $ EdhObject exo
      Just (Right ()) -> exitEdh ets exit $ EdhBool True
    where world = edh'ctx'world $ edh'context ets

  joinProc :: EdhHostProc
  joinProc _ !exit !ets = withThisHostObj ets $ \_hsv !peer ->
    readTMVar (edh'peer'eol peer) >>= \case
      Left !e ->
        edh'exception'wrapper world e >>= \ !exo -> edhThrow ets $ EdhObject exo
      Right () -> exitEdh ets exit nil
    where world = edh'ctx'world $ edh'context ets

  stopProc :: EdhHostProc
  stopProc _ !exit !ets = withThisHostObj ets $ \_hsv !peer -> do
    !stopped <- tryPutTMVar (edh'peer'eol peer) $ Right ()
    exitEdh ets exit $ EdhBool stopped

  armedChannelProc :: EdhHostProc
  armedChannelProc !apk !exit !ets = withThisHostObj ets $ \_hsv !peer -> do
    let getArmedSink :: EdhValue -> STM ()
        getArmedSink !chLctr =
          Map.lookup chLctr <$> readTVar (edh'peer'channels peer) >>= \case
            Nothing      -> exitEdh ets exit nil
            Just !chSink -> exitEdh ets exit $ EdhSink chSink
    case apk of
      ArgsPack [!chLctr] !kwargs | odNull kwargs -> getArmedSink chLctr
      _ -> throwEdh ets UsageError "invalid args to armedChannelProc"

  armChannelProc :: EdhHostProc
  armChannelProc !apk !exit !ets = withThisHostObj ets $ \_hsv !peer -> do
    let armSink :: EdhValue -> EventSink -> STM ()
        armSink !chLctr !chSink = do
          modifyTVar' (edh'peer'channels peer) $ Map.insert chLctr chSink
          exitEdh ets exit $ EdhSink chSink
    case parseArgsPack (Nothing, nil) parseArgs apk of
      Left  err                  -> throwEdh ets UsageError err
      Right (maybeLctr, sinkVal) -> case maybeLctr of
        Nothing      -> throwEdh ets UsageError "missing channel locator"
        Just !chLctr -> case edhUltimate sinkVal of
          EdhNil -> do
            chSink <- newEventSink
            armSink chLctr chSink
          EdhSink !chSink -> armSink chLctr chSink
          !badSinkVal ->
            throwEdh ets UsageError $ "invalid command channel type: " <> T.pack
              (edhTypeNameOf badSinkVal)
   where
    parseArgs =
      ArgsPackParser
          [ \arg (_, chSink') -> Right (Just arg, chSink')
          , \arg (chLctr', _) -> Right (chLctr', arg)
          ]
        $ Map.fromList
            [ ("chLctr", \arg (_, chSink') -> Right (Just arg, chSink'))
            , ("chSink", \arg (chLctr', _) -> Right (chLctr', arg))
            ]

  readPeerSrcProc :: EdhHostProc
  readPeerSrcProc _ !exit !ets =
    withThisHostObj ets $ \_hsv !peer -> readPeerSource ets peer exit

  readPeerCmdProc :: EdhHostProc
  readPeerCmdProc !apk !exit !ets = withThisHostObj ets $ \_hsv !peer ->
    case parseArgsPack Nothing argsParser apk of
      Left err -> throwEdh ets UsageError err
      Right !inScopeOf ->
        let
          doReadCmd :: Scope -> STM ()
          doReadCmd !cmdScope = readPeerCommand etsCmd peer exit
           where
            !etsCmd = ets
              { edh'context = ctx
                { edh'ctx'stack =
                  cmdScope
                      {
                        -- mind to inherit caller's exception handler anyway
                        edh'excpt'hndlr  = edh'excpt'hndlr callerScope
                        -- use a meaningful caller stmt
                      , edh'scope'caller = StmtSrc
                                             ( SourcePos
                                               { sourceName   = "<peer-cmd>"
                                               , sourceLine   = mkPos 1
                                               , sourceColumn = mkPos 1
                                               }
                                             , VoidStmt
                                             )
                      }
                    NE.:| NE.tail (edh'ctx'stack ctx)
                }
              }
        in
          case inScopeOf of
            Just !so -> objectScope so >>= \case
              -- eval cmd source in scope of the specified object
              Just !inScope -> doReadCmd inScope
              Nothing       -> case edh'obj'store so of
                HostStore !hsv -> fromDynamic <$> readTVar hsv >>= \case
                  -- the specified objec is a scope object, eval cmd source in
                  -- the wrapped scope
                  Just (inScope :: Scope) -> doReadCmd inScope
                  _                       -> throwEdh
                    ets
                    UsageError
                    "you don't read command inScopeOf a host object"
                _ -> error "bug: objectScope not working for non-host object"

            -- eval cmd source with caller's scope
            _ -> doReadCmd callerScope
   where
    !ctx         = edh'context ets
    !callerScope = contextFrame ctx 1
    argsParser   = ArgsPackParser [] $ Map.fromList
      [ ( "inScopeOf"
        , \arg _ -> case arg of
          EdhObject so -> Right $ Just so
          _            -> Left "invalid inScopeOf object"
        )
      ]

  postCmd :: EdhValue -> EdhValue -> EdhTxExit -> EdhTx
  postCmd !dirVal !cmdVal !exit !ets = withThisHostObj ets $ \_hsv !peer -> do
    let withDir :: (PacketDirective -> STM ()) -> STM ()
        withDir !exit' = case edhUltimate dirVal of
          EdhNil  -> exit' ""
          !chLctr -> edhValueRepr ets chLctr $ \ !lctr -> exit' lctr
    withDir $ \ !dir -> case cmdVal of
      EdhString !src   -> postPeerCommand ets peer (textPacket dir src) exit
      EdhExpr _ _ !src -> if src == ""
        then throwEdh ets UsageError "missing source from the expr as command"
        else postPeerCommand ets peer (textPacket dir src) exit
      EdhBlob !payload ->
        postPeerCommand ets peer (Packet ("blob:" <> dir) payload) exit
      _ -> throwEdh ets UsageError $ "unsupported command type: " <> T.pack
        (edhTypeNameOf cmdVal)

  -- | peer.p2c( dir, cmd ) - shorthand for post-to-channel
  p2cProc :: EdhHostProc
  p2cProc !apk !exit = case parseArgsPack (Nothing, Nothing) parseArgs apk of
    Left err -> throwEdhTx UsageError err
    Right (Nothing, _) -> throwEdhTx UsageError "missing directive"
    Right (_, Nothing) -> throwEdhTx UsageError "missing command"
    Right (Just !dirVal, Just !cmdVal) -> postCmd dirVal cmdVal exit
   where
    parseArgs =
      ArgsPackParser
          [ \arg (_, cmd') -> Right (Just arg, cmd')
          , \arg (dir', _) -> Right (dir', Just arg)
          ]
        $ Map.fromList
            [ ("dir", \arg (_, cmd') -> Right (Just arg, cmd'))
            , ("cmd", \arg (dir', _) -> Right (dir', Just arg))
            ]

  postPeerCmdProc :: EdhHostProc
  postPeerCmdProc !apk !exit =
    case parseArgsPack (Nothing, nil) parseArgs apk of
      Left  err                     -> throwEdhTx UsageError err
      Right (Nothing     , _      ) -> throwEdhTx UsageError "missing command"
      Right (Just !cmdVal, !dirVal) -> postCmd dirVal cmdVal exit
   where
    parseArgs =
      ArgsPackParser
          [ \arg (_, dir') -> Right (Just arg, dir')
          , \arg (cmd', _) -> Right (cmd', arg)
          ]
        $ Map.fromList
            [ ("cmd", \arg (_, dir') -> Right (Just arg, dir'))
            , ("dir", \arg (cmd', _) -> Right (cmd', arg))
            ]

  identProc :: EdhHostProc
  identProc _ !exit !ets =
    withThisHostObj' ets (exitEdh ets exit $ EdhString "<bogus-peer>")
      $ \_hsv !peer -> exitEdh ets exit $ EdhString $ edh'peer'ident peer

  reprProc :: EdhHostProc
  reprProc _ !exit !ets =
    withThisHostObj' ets (exitEdh ets exit $ EdhString "peer:<bogus>")
      $ \_hsv !peer ->
          exitEdh ets exit $ EdhString $ "peer:<" <> edh'peer'ident peer <> ">"

