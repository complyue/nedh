
module Language.Edh.Net.Discover where

import           Prelude
-- import           Debug.Trace

import           System.IO

import           Control.Exception
import           Control.Monad
import           Control.Concurrent
import           Control.Concurrent.STM

import           Control.Monad.Reader

import           Data.Maybe
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import qualified Data.HashMap.Strict           as Map
import           Data.Dynamic

import           Network.Socket
import           Network.Socket.ByteString

import qualified Data.Lossless.Decimal         as D

import           Language.Edh.EHI


data EdhReactor = EdhReactor {
    -- the import spec of the module to run as the reactor
      edh'reactor'modu :: !Text
    -- local network interface to bind
    , edh'reactor'addr :: !Text
    -- local network port to bind
    , edh'reactor'port :: !Int
    -- actually bound network addresses
    , edh'reacting'addrs :: !(TMVar [AddrInfo])
    -- end-of-life status
    , edh'reacting'eol :: !(TMVar (Either SomeException ()))
    -- reactor module initializer, must callable if not nil
    , edh'reacting'init :: !EdhValue
  }


data EdhAdvertiser = EdhAdvertiser {
    -- the source of advertisment, possibly duplicated from a boradcast channel
      edh'ad'source :: !(TChan Text)
    -- remote network address as target, can be multicast or broadcast addr
    , edh'ad'target'addr :: !Text
    -- remote network port as target
    , edh'ad'target'port :: !Int
    -- actual network addresses as target
    , edh'ad'target'addrs :: !(TMVar [AddrInfo])
    -- local network addr to bind
    , edh'advertiser'addr :: !AddrInfo
    -- end-of-life status
    , edh'advertising'eol :: !(TMVar (Either SomeException ()))
    -- advertiser module initializer, must callable if not nil
    , edh'advertising'init :: !EdhValue
  }
