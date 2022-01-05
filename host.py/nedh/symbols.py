"""
"""
__all__ = [
    "ERR_CHAN",
    "DATA_CHAN",
    "netPeer",
    "sendCmd",
    "sendData",
    "disconnectPeer",
]

from edh import *


# conventional Nedh channel for error reporting
ERR_CHAN = "err"

# conventional Nedh channel for data exchange
DATA_CHAN = "data"

# effectful identifier of the peer object
netPeer = Symbol("@netPeer")

# effectful identifier of the method procedure for normal command sending
sendCmd = Symbol("@sendCmd")

# effectful identifier of the method procedure for normal data sending
sendData = Symbol("@sendData")

# effectful identifier of the method procedure to disconnect the connection
disconnectPeer = Symbol("@disconnectPeer")
