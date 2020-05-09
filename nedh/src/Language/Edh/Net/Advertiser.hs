
module Language.Edh.Net.Advertiser where

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


type TargetAddr = Text
type TargetPort = Int


-- | An advertiser sends a stream of commands from a (possibly broadcast)
-- channel, as (UDP as impl. so far) packets to the specified
-- broadcast/multicast or sometimes unicast address.
--
-- The local network address of the advertiser can be deliberately set to some
-- TCP service's listening address, so a potential responder can use that
-- information to connect to the service as advertised.
data EdhAdvertiser = EdhAdvertiser {
    -- the source of advertisment, possibly duplicated from a broadcast channel
      edh'ad'source :: !(TChan Text)
    -- remote network address as target, can be multicast or broadcast addr
    , edh'ad'target'addr :: !TargetAddr
    -- remote network port as target
    , edh'ad'target'port :: !TargetPort
    -- actual network addresses as target
    , edh'ad'target'addrs :: !(TMVar [AddrInfo])
    -- local network addr to bind
    , edh'advertiser'addr :: !AddrInfo
    -- end-of-life status
    , edh'advertising'eol :: !(TMVar (Either SomeException ()))
  }

