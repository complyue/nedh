
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


-- | A sniffer can perceive commands conveyed by (UDP as impl. so far)
-- packets from broadcast/multicast or sometimes unicast traffic.
--
-- The sniffer module normally loops in perceiving such commands, and
-- triggers appropriate action responding to each command, e.g.
-- connecting to the source address, via TCP, for further service
-- consuming and/or vending, as advertised.
data EdhSniffer = EdhSniffer {
    -- the import spec of the module to run as the sniffer
      edh'sniffer'modu :: !Text
    -- local network addr to bind
    , edh'sniffer'addr :: !Text
    -- local network port to bind
    , edh'sniffer'port :: !Int
    -- actually bound network addresses
    , edh'sniffing'addrs :: !(TMVar [AddrInfo])
    -- end-of-life status
    , edh'sniffing'eol :: !(TMVar (Either SomeException ()))
    -- sniffer module initializer, must callable if not nil
    , edh'sniffing'init :: !EdhValue
  }


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
    , edh'ad'target'addr :: !Text
    -- remote network port as target
    , edh'ad'target'port :: !Int
    -- actual network addresses as target
    , edh'ad'target'addrs :: !(TMVar [AddrInfo])
    -- local network addr to bind
    , edh'advertiser'addr :: !AddrInfo
    -- end-of-life status
    , edh'advertising'eol :: !(TMVar (Either SomeException ()))
  }

