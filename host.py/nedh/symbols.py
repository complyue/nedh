"""
"""
__all__ = [
    "CONIN",
    "CONOUT",
    "CONMSG",
    "sendConOut",
    "sendConMsg",
    "ERR_CHAN",
    "DATA_CHAN",
    "netPeer",
    "dataSink",
    "sendCmd",
    "sendData",
]

from edh import *


# conventional Nedh channels for console IO
CONIN, CONOUT, CONMSG = 0, 1, 2


# identifier for the effect to send commands to remote site's stdio out
sendConOut = Symbol("@sendConOut")
# identifier for the effect to send commands to remote site's stdio err
sendConMsg = Symbol("@sendConMsg")

# conventional Nedh channel for error reporting
ERR_CHAN = "err"

# conventional Nedh channel for data exchange
DATA_CHAN = "data"

# effectful identifier of the peer object
netPeer = Symbol("@netPeer")

# effectful identifier of the local event sink for data intaking
dataSink = Symbol("@dataSink")

# effectful identifier of the method procedure for normal command sending
sendCmd = Symbol("@sendCmd")

# effectful identifier of the method procedure for normal data sending
sendData = Symbol("@sendData")

