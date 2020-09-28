"""
Python Server speaking Nedh

"""
__all__ = ["EdhServer"]


from typing import *
import asyncio
import inspect

import runpy

from edh import *
from . import log

from .mproto import *
from .peer import *

logger = log.get_logger(__name__)


class EdhServer:
    """
    """

    def __init__(
        self,
        service_modu: str,
        server_addr: str = "127.0.0.1",
        server_port: int = 3721,
        server_port_max: Optional[int] = None,
        init: Optional[Callable] = None,
        clients: Optional[EventSink] = None,
        net_opts: Optional[Dict] = None,
    ):
        loop = asyncio.get_running_loop()
        eol = loop.create_future()
        self.service_modu = service_modu
        self.server_addr = server_addr
        self.server_port = server_port
        self.server_port_max = server_port_max
        self.init = init
        self.clients = clients or EventSink()

        self.server_sockets = loop.create_future()
        self.eol = eol
        self.net_opts = net_opts or {}

        # mark end-of-stream for clients, end-of-life for server, finally
        def server_cleanup(svr_fut):
            self.clients.publish(EndOfStream)

            if not self.server_sockets.done():
                # fill empty addrs if the connection has ever failed
                self.server_sockets.set_result([])

            if eol.done():
                return

            if svr_fut.cancelled():
                eol.set_exception(asyncio.CancelledError())
                return
            exc = svr_fut.exception()
            if exc is not None:
                eol.set_exception(exc)
            else:
                eol.set_result(None)

        asyncio.create_task(self._server_thread()).add_done_callback(server_cleanup)

    def __repr__(self):
        return f"EdhServer({self.service_modu!r}, {self.server_addr!r}, {self.server_port!r})"

    def __await__(self):
        yield from self.server_sockets
        # server_addrs = [sock.getsockname() for sock in self.server_sockets.result()]
        return self

    async def join(self):
        await self.eol

    def stop(self):
        if not self.eol.done():
            self.eol.set_result(None)

    async def _server_thread(self):
        port = self.server_port
        while True:

            async with await asyncio.start_server(
                self._serv_client,
                self.server_addr,
                port,
                reuse_address=False,
                start_serving=False,
                **self.net_opts,
            ) as server:

                try:
                    await server.start_serving()
                except:
                    if port is 0 or self.server_port_max is None:
                        raise
                    port = port + 1
                    if port > self.server_port_max:
                        raise
                    continue  # try next port

                self.server_sockets.set_result(server.sockets)

                try:
                    await self.eol
                except:
                    pass
                return

    async def _serv_client(
        self, intake: asyncio.StreamReader, outlet: asyncio.StreamWriter,
    ):
        loop = asyncio.get_running_loop()
        eol = loop.create_future()
        try:
            addr = outlet.get_extra_info("peername", "<some-peer>")

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
                self.service_modu, modu,
            )
            logger.debug(f"Nedh client peer module {self.service_modu} initialized")

            self.clients.publish(peer)

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

        except asyncio.CancelledError:
            pass

        except Exception as exc:
            logger.error("Nedh client caused error.", exc_info=True)
            if not eol.done():
                eol.set_exception(exc)

        finally:
            if not eol.done():
                eol.set_result(None)
            # todo post err (if any) to peer
            outlet.close()
            await outlet.wait_closed()

