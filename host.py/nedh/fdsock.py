"""
Python Client speaking Nedh by taking over a socket from an inherited fd

"""
__all__ = ["takeEdhFd"]

from typing import *
import asyncio
import inspect
import socket

import runpy

from edh import *

from . import log
from .mproto import *
from .peer import *

logger = log.get_logger(__name__)


async def takeEdhFd(wsc_fd: int, net_opts: Optional[Dict] = None):
    loop = asyncio.get_running_loop()

    # prepare the peer object
    ident = f"<fd:{wsc_fd}>"

    eol = loop.create_future()

    # outletting currently has no rate limit, maybe add in the future?
    # with an unbounded queue, backpressure from remote peer is ignored
    # and outgoing packets can pile up locally
    poq = asyncio.Queue()
    # intaking should create backpressure when handled slowly, so use a
    # bounded queue
    hoq = asyncio.Queue(maxsize=1)

    peer = Peer(ident=ident, eol=eol, posting=poq.put, hosting=hoq.get)

    # mark end-of-life anyway finally
    def client_cleanup(clnt_fut):
        if eol.done():
            return

        if clnt_fut.cancelled():
            eol.set_exception(asyncio.CancelledError())
            return
        exc = clnt_fut.exception()
        if exc is not None:
            eol.set_exception(exc)
        else:
            eol.set_result(None)

    async def _consumer_thread():
        outlet = None
        try:

            # take over the network connection
            sock = socket.socket(fileno=wsc_fd)
            intake, outlet = await asyncio.open_connection(
                sock=sock,
                **net_opts or {},
            )

            async def pumpCmdsOut():
                # this task is the only one writing the socket
                try:
                    while True:
                        pkt = await read_stream(eol, poq.get())
                        if pkt is EndOfStream:
                            break
                        await sendPacket(ident, outlet, pkt)
                except Exception as exc:
                    logger.error("Nedh fd client error.", exc_info=True)
                    if not eol.done():
                        eol.set_exception(exc)

            asyncio.create_task(pumpCmdsOut())

            # pump commands in,
            # this task is the only one reading the socket
            await receivePacketStream(
                peer_site=ident, intake=intake, pkt_sink=hoq.put, eos=eol
            )

        except Exception as exc:
            logger.error("Nedh fd client error.", exc_info=True)
            if not eol.done():
                eol.set_exception(exc)
        finally:
            if not eol.done():
                eol.set_result(None)
            if outlet is not None:
                # todo post err (if any) to peer
                outlet.write_eof()
                outlet.close()
                # don't do this to workaround https://bugs.python.org/issue39758
                # await outlet.wait_closed()

    asyncio.create_task(_consumer_thread()).add_done_callback(client_cleanup)

    return peer
