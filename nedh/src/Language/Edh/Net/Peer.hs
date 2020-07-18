
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

postPeerCommand :: EdhProgState -> Peer -> Packet -> EdhProcExit -> STM ()
postPeerCommand !pgs !peer !pkt !exit =
  tryReadTMVar (edh'peer'eol peer) >>= \case
    Just _ -> throwEdhSTM pgs EvalError "posting to a peer already end-of-life"
    Nothing ->
      edhPerformSTM pgs (edh'peer'posting peer pkt) $ const $ exitEdhProc exit
                                                                          nil

readPeerSource :: EdhProgState -> Peer -> EdhProcExit -> STM ()
readPeerSource !pgs peer@(Peer _ !eol _ !ho _) !exit =
  edhPerformSTM pgs ((Right <$> ho) `orElse` (Left <$> readTMVar eol)) $ \case
    -- reached normal end-of-stream
    Left (Right _) -> exitEdhProc exit nil
    -- previously eol due to error
    Left (Left !ex) ->
      contEdhSTM $ toEdhError pgs ex $ \exv -> edhThrowSTM pgs exv
    -- got next command source incoming
    Right pkt@(Packet !dir !payload) -> case dir of
      "" -> exitEdhProc exit $ EdhString $ TE.decodeUtf8 payload
      _  -> contEdhSTM $ landPeerCmd peer pkt pgs exit

-- | Read next command from peer
--
-- Note a command may target a specific channel, thus get posted to that 
--      channel's sink, and nil will be returned from here for it.
readPeerCommand :: EdhProgState -> Peer -> EdhProcExit -> STM ()
readPeerCommand !pgs peer@(Peer _ !eol _ !ho _) !exit =
  edhPerformSTM pgs ((Right <$> ho) `orElse` (Left <$> readTMVar eol)) $ \case
    -- reached normal end-of-stream
    Left (Right _) -> exitEdhProc exit nil
    -- previously eol due to error
    Left (Left !ex) ->
      contEdhSTM $ toEdhError pgs ex $ \exv -> edhThrowSTM pgs exv
    -- got next command incoming
    Right !pkt -> contEdhSTM $ landPeerCmd peer pkt pgs exit

landPeerCmd :: Peer -> Packet -> EdhProgState -> EdhProcExit -> STM ()
landPeerCmd (Peer !ident _ _ _ !chdVar) (Packet !dir !payload) !pgs !exit =
  case T.stripPrefix "blob:" dir of
    Just !chLctr -> runEdhProc pgs $ landValue chLctr $ EdhBlob payload
    Nothing ->
      runEdhProc pgs
        $ evalEdh srcName (TE.decodeUtf8 payload)
        $ \(OriginalValue !cmdVal _ _) -> landValue dir cmdVal
 where
  !srcName = T.unpack ident
  landValue !chLctr !val = if T.null chLctr
    -- to the default channel, which yields as direct result of 
    -- `peer.readCommand()`
    then exitEdhProc exit val
    -- to a specific channel, which should be located by the directive
    else evalEdh srcName chLctr $ \(OriginalValue !lctr _ _) -> contEdhSTM $ do
      chd <- readTVar chdVar
      case Map.lookup lctr chd of
        Nothing ->
          throwEdhSTM pgs UsageError $ "Missing command channel: " <> T.pack
            (show lctr)
        Just !chSink -> do
          publishEvent chSink val  -- post the cmd to channel
          -- yield nil as for `peer.readCommand()` wrt this cmd packet
          exitEdhSTM pgs exit nil


-- | host constructor Peer()
peerCtor :: EdhHostCtor
-- not really constructable from Edh code, relies on host code to fill
-- the in-band storage
peerCtor _ _ !ctorExit = ctorExit $ toDyn nil

peerMethods :: EdhProgState -> STM [(AttrKey, EdhValue)]
peerMethods !pgsModule = sequence
  [ (AttrByName nm, ) <$> mkHostProc scope vc nm hp args
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
 where
  !scope = contextScope $ edh'context pgsModule

  eolProc :: EdhProcedure
  eolProc _ !exit =
    withThatEntity' (\ !pgs -> exitEdhSTM pgs exit $ EdhBool True)
      $ \ !pgs !peer -> tryReadTMVar (edh'peer'eol peer) >>= \case
          Nothing         -> exitEdhSTM pgs exit $ EdhBool False
          Just (Left  e ) -> toEdhError pgs e $ \exv -> exitEdhSTM pgs exit exv
          Just (Right ()) -> exitEdhSTM pgs exit $ EdhBool True

  joinProc :: EdhProcedure
  joinProc _ !exit =
    withThatEntity' (\ !pgs -> exitEdhSTM pgs exit nil) $ \ !pgs !peer ->
      edhPerformSTM pgs (readTMVar (edh'peer'eol peer)) $ \case
        Left  e  -> contEdhSTM $ toEdhError pgs e $ \exv -> edhThrowSTM pgs exv
        Right () -> exitEdhProc exit nil

  stopProc :: EdhProcedure
  stopProc _ !exit =
    withThatEntity' (\ !pgs -> exitEdhSTM pgs exit $ EdhBool False)
      $ \ !pgs !peer -> do
          stopped <- tryPutTMVar (edh'peer'eol peer) $ Right ()
          exitEdhSTM pgs exit $ EdhBool stopped

  armedChannelProc :: EdhProcedure
  armedChannelProc !apk !exit = withThatEntity $ \ !pgs !peer -> do
    let getArmedSink :: EdhValue -> STM ()
        getArmedSink !chLctr =
          Map.lookup chLctr <$> readTVar (edh'peer'channels peer) >>= \case
            Nothing      -> exitEdhSTM pgs exit nil
            Just !chSink -> exitEdhSTM pgs exit $ EdhSink chSink
    case apk of
      ArgsPack [!chLctr] !kwargs | odNull kwargs -> getArmedSink chLctr
      _ -> throwEdhSTM pgs UsageError "Invalid args to armedChannelProc"

  armChannelProc :: EdhProcedure
  armChannelProc !apk !exit = withThatEntity $ \ !pgs !peer -> do
    let armSink :: EdhValue -> EventSink -> STM ()
        armSink !chLctr !chSink = do
          modifyTVar' (edh'peer'channels peer) $ Map.insert chLctr chSink
          exitEdhSTM pgs exit $ EdhSink chSink
    case parseArgsPack (Nothing, nil) parseArgs apk of
      Left  err                  -> throwEdhSTM pgs UsageError err
      Right (maybeLctr, sinkVal) -> case maybeLctr of
        Nothing      -> throwEdhSTM pgs UsageError "Missing channel locator"
        Just !chLctr -> case edhUltimate sinkVal of
          EdhNil -> do
            chSink <- newEventSink
            armSink chLctr chSink
          EdhSink !chSink -> armSink chLctr chSink
          !badSinkVal ->
            throwEdhSTM pgs UsageError
              $  "Invalid command channel type: "
              <> T.pack (edhTypeNameOf badSinkVal)
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

  readPeerSrcProc :: EdhProcedure
  readPeerSrcProc _ !exit =
    withThatEntity $ \ !pgs !peer -> readPeerSource pgs peer exit

  readPeerCmdProc :: EdhProcedure
  readPeerCmdProc apk !exit = withThatEntity $ \ !pgs !peer ->
    case parseArgsPack Nothing argsParser apk of
      Left  err        -> throwEdhSTM pgs UsageError err
      Right !inScopeOf -> do
        let !ctx = edh'context pgs
        -- mind to inherit this host proc's exception handler anyway
        cmdScope <- case inScopeOf of
          Just !so -> isScopeWrapper ctx so >>= \case
            True -> return $ (wrappedScopeOf so)
              { exceptionHandler = exceptionHandler $ contextScope ctx
              }
            False -> return $ (contextScope ctx)
            -- eval cmd source in the specified object's (probably a module)
            -- context scope
              { scopeEntity = objEntity so
              , thisObject  = so
              , thatObject  = so
              , scopeProc   = objClass so
              , scopeCaller = StmtSrc
                                ( SourcePos { sourceName   = "<peer-cmd>"
                                            , sourceLine   = mkPos 1
                                            , sourceColumn = mkPos 1
                                            }
                                , VoidStmt
                                )
              }
          _ -> case NE.tail $ callStack ctx of
            -- eval cmd source with caller's this/that, and lexical context,
            -- while the entity is already the same as caller's
            callerScope : _ -> return $ (contextScope ctx)
              { thisObject  = thisObject callerScope
              , thatObject  = thatObject callerScope
              , scopeProc   = scopeProc callerScope
              , scopeCaller = scopeCaller callerScope
              }
            _ -> return $ contextScope ctx
        let !pgsCmd = pgs
              { edh'context = ctx
                                { callStack        = cmdScope
                                                       NE.:| NE.tail (callStack ctx)
                                , contextExporting = False
                                }
              }
        readPeerCommand pgsCmd peer exit
   where
    argsParser = ArgsPackParser [] $ Map.fromList
      [ ( "inScopeOf"
        , \arg _ -> case arg of
          EdhObject so -> Right $ Just so
          _            -> Left "Invalid inScopeOf object"
        )
      ]

  postCmd :: EdhValue -> EdhValue -> EdhProcExit -> EdhProc
  postCmd !dirVal !cmdVal !exit = withThatEntity $ \ !pgs !peer -> do
    let withDir :: (PacketDirective -> STM ()) -> STM ()
        withDir !exit' = case edhUltimate dirVal of
          EdhNil  -> exit' ""
          !chLctr -> edhValueReprSTM pgs chLctr $ \lctr -> exit' lctr
    withDir $ \dir -> case cmdVal of
      EdhString !src   -> postPeerCommand pgs peer (textPacket dir src) exit
      EdhExpr _ _ !src -> if src == ""
        then throwEdhSTM pgs
                         UsageError
                         "Missing source from the expr as command"
        else postPeerCommand pgs peer (textPacket dir src) exit
      EdhBlob !payload ->
        postPeerCommand pgs peer (Packet ("blob:" <> dir) payload) exit
      _ -> throwEdhSTM pgs UsageError $ "Unsupported command type: " <> T.pack
        (edhTypeNameOf cmdVal)

  -- | peer.p2c( dir, cmd ) - shorthand for post-to-channel
  p2cProc :: EdhProcedure
  p2cProc !apk !exit = case parseArgsPack (Nothing, Nothing) parseArgs apk of
    Left  err                          -> throwEdh UsageError err
    Right (Nothing, _) -> throwEdh UsageError "Missing directive"
    Right (_           , Nothing     ) -> throwEdh UsageError "Missing command"
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

  postPeerCmdProc :: EdhProcedure
  postPeerCmdProc !apk !exit =
    case parseArgsPack (Nothing, nil) parseArgs apk of
      Left  err                     -> throwEdh UsageError err
      Right (Nothing     , _      ) -> throwEdh UsageError "Missing command"
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

  identProc :: EdhProcedure
  identProc _ !exit =
    withThatEntity' (\ !pgs -> exitEdhSTM pgs exit $ EdhString "<bogus-peer>")
      $ \ !pgs !peer -> exitEdhSTM pgs exit $ EdhString $ edh'peer'ident peer

  reprProc :: EdhProcedure
  reprProc _ !exit =
    withThatEntity' (\ !pgs -> exitEdhSTM pgs exit $ EdhString "peer:<bogus>")
      $ \ !pgs !peer ->
          exitEdhSTM pgs exit
            $  EdhString
            $  "peer:<"
            <> edh'peer'ident peer
            <> ">"

