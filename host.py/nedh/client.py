"""
Python Client speaking Nedh

"""
__all__ = ["EdhClient"]

from typing import *
import asyncio
import inspect

import runpy

from edh import *

from .log import *
from .mproto import *
from .peer import *

logger = get_logger(__name__)


class EdhClient:
    """
    """

    def __init__(
        self,
        consumer_modu: str,
        service_addr: str = "127.0.0.1",
        service_port: int = 3721,
        init: Optional[Callable[[dict], Awaitable]] = None,
        net_opts: Optional[Dict] = None,
    ):
        loop = asyncio.get_running_loop()
        eol = loop.create_future()
        self.consumer_modu = consumer_modu
        self.service_addr = service_addr
        self.service_port = service_port
        self.init = init

        self.service_addrs = loop.create_future()
        self.eol = eol
        self.net_opts = net_opts or {}

        # mark end-of-life anyway finally
        def client_cleanup(clnt_fut):
            if not self.service_addrs.done():
                # fill empty addrs if the connection has ever failed
                self.service_addrs.set_result([])

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

        asyncio.create_task(self._consumer_thread()).add_done_callback(client_cleanup)

    def __repr__(self):
        return f"EdhClient({self.consumer_modu!r}, {self.service_addr!r}, {self.service_port!r})"

    def __await__(self):
        yield from self.service_addrs
        logger.info(f"Connected to service at {self.service_addrs.result()!s}")
        return self

    async def join(self):
        await self.eol

    def stop(self):
        if not self.eol.done():
            self.eol.set_result(None)

    async def _consumer_thread(self):
        outlet = None
        eol = self.eol
        try:

            # make the network connection
            intake, outlet = await asyncio.open_connection(
                self.service_addr, self.service_port, **self.net_opts,
            )
            addr = outlet.get_extra_info("peername", "<some-peer>")
            self.service_addrs.set_result([addr])

            # prepare the peer object
            ident = str(addr)
            # outletting currently has no rate limit, maybe add in the future?
            # with an unbounded queue, backpressure from remote peer is ignored
            # and outgoing packets can pile up locally
            poq = asyncio.Queue()
            # intaking should create backpressure when handled slowly, so use a
            # bounded queue
            hoq = asyncio.Queue(maxsize=1)

            peer = Peer(ident=ident, eol=eol, posting=poq.put, hosting=hoq.get,)

            # per-connection peer module preparation
            modu = {"peer": peer}
            if self.init is not None:
                # call per-connection peer module initialization method
                maybe_async = self.init(modu)
                if inspect.isawaitable(maybe_async):
                    await maybe_async
            # launch the peer module, it normally forks a concurrent task to
            # run a command landing loop
            runpy.run_module(
                self.consumer_modu, modu,
            )
            logger.debug(f"Nedh peer module {self.consumer_modu} initialized")

            # pump commands in,
            # this task is the only one reading the socket
            asyncio.create_task(
                receivePacketStream(
                    peer_site=ident, intake=intake, pkt_sink=hoq.put, eos=eol,
                )
            )

            # pump commands out,
            # this task is the only one writing the socket
            while True:
                pkt = await read_stream(eol, poq.get())
                if pkt is EndOfStream:
                    break
                await sendPacket(ident, outlet, pkt)

        except Exception as exc:
            logger.error("Nedh client error.", exc_info=True)
            if not eol.done():
                eol.set_exception(exc)
        finally:
            if outlet is not None:
                # todo post err (if any) to peer
                outlet.close()
                await outlet.wait_closed()
