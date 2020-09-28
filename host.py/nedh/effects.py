__all__ = []

from typing import *
import asyncio

from edh import *
from .symbols import *


async def sendConOut_(d, *ds):
    peer = effect(netPeer)
    peer.p2c(CONOUT, d)
    for d in ds:
        peer.p2c(CONOUT, d)


async def sendConMsg_(d, *ds):
    peer = effect(netPeer)
    peer.p2c(CONMSG, d)
    for d in ds:
        peer.p2c(CONMSG, d)


async def sendCmd_(c, *cs):
    peer = effect(netPeer)
    peer.postCommand(c)
    for c in cs:
        peer.postCommand(c)


async def sendData_(d, *ds):
    peer = effect(netPeer)
    peer.p2c(DATA_CHAN, d)
    for d in ds:
        peer.p2c(DATA_CHAN, d)


__all_symbolic__ = {
    sendConOut: sendConOut_,
    sendConMsg: sendConMsg_,
    sendCmd: sendCmd_,
    sendData: sendData_,
}

