
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

import           Language.Edh.Net.MicroProto
import           Language.Edh.Net.Peer
import           Language.Edh.Net.Server

import           Language.Edh.EHI


installNetBatteries :: EdhWorld -> IO ()
installNetBatteries !world =

  void $ installEdhModule world "net/Server" $ \pgs modu -> do

    let ctx       = edh'context pgs
        moduScope = objectScope ctx modu

    !moduArts <-
      sequence
        $ [ (AttrByName nm, ) <$> mkHostProc moduScope mc nm hp args
          | (mc, nm, hp, args) <-
            [ 
              -- ( EdhMethod
              -- , "serveClients"
              -- , serveClientsProc
              -- , PackReceiver
              --   [ RecvArg "bindLocalAddr" (Just (EdhString "127.0.0.1")) Nothing
              --   , RecvArg "bindLocalPort"
              --             (Just (EdhDecimal $ fromIntegral 3721))
              --             Nothing
              --   ]
              -- )
            ]
          ]

    updateEntityAttrs pgs (objEntity modu) moduArts

