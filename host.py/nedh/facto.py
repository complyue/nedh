__all__ = [
    "Factotum",
]

import os, signal, socket
import time, threading
import asyncio
from typing import *

from edh import *

from . import log
from .fdsock import *
from .peer import *
from .mproto import *

from .symbols import *


logger = log.get_logger(__name__)


class Factotum:
    """
    Create & control a subprocess working as a factotum.

    """

    def __init__(
        self,
        cmdl: Sequence[str] = ["epm", "x", "nedhm", "net/factotum"],
        work_dir=None,
    ):
        self.facto_pid = None

        downlink, uplink = socket.socketpair()
        # setting the sockets to non-blocking mode is essential,
        # or Haskell subprocess will have read blocking write,
        # even with multi-(tho green)-threading
        downlink.setblocking(False)
        uplink.setblocking(False)

        uplink_fd = uplink.fileno()
        # Make sure the uplink_fd remains open in subprocess
        os.set_inheritable(uplink_fd, True)
        try:
            facto_pid = os.fork()
            if facto_pid == 0:  # Child process
                downlink.close()

                if work_dir is not None:
                    os.chdir(work_dir)

                os.environ["FACTO_SOCK_FD"] = str(uplink_fd)
                # todo: why above is necessary?
                #       exec of /usr/bin/env can't propagate the setting to cmdl
                os.execv(
                    "/usr/bin/env",
                    [f"FACTO_SOCK_FD={uplink_fd}"] + cmdl,
                )

                # it won't return to parent code here
        finally:
            uplink.close()
            uplink = None

        ident = f"<facto-child#{facto_pid}>"
        self.facto_pid = facto_pid

        # outletting currently has no rate limit, maybe add in the future?
        # with an unbounded queue, backpressure from remote peer is ignored
        # and outgoing packets can pile up locally
        poq = asyncio.Queue()
        # intaking should create backpressure when handled slowly, so use a
        # bounded queue
        hoq = asyncio.Queue(maxsize=1)

        loop = asyncio.get_running_loop()
        self.eol = eol = loop.create_future()

        self.peer = Peer(
            ident=ident,
            eol=eol,
            posting=poq.put,
            hosting=hoq.get,
        )
        self.uplink = self.peer.ensure_channel(DATA_CHAN)

        async def _facto_owner_task():
            intake, outlet = await asyncio.open_connection(sock=downlink)
            try:

                async def pumpCmdsOut():
                    # this task is the only one writing the socket
                    try:
                        while True:
                            pkt = await read_stream(eol, poq.get())
                            if pkt is EndOfStream:
                                break
                            await sendPacket(ident, outlet, pkt)
                    except Exception as exc:
                        logger.error("Factotum owner error.", exc_info=True)
                        if not eol.done():
                            eol.set_exception(exc)

                asyncio.create_task(pumpCmdsOut())

                # pump commands in,
                # this task is the only one reading the socket
                await receivePacketStream(
                    peer_site=ident,
                    intake=intake,
                    pkt_sink=hoq.put,
                    eos=eol,
                )

            except Exception as exc:
                logger.error("Factotum owner error.", exc_info=True)
                if not eol.done():
                    eol.set_exception(exc)
            finally:
                if not eol.done():
                    eol.set_result(None)
                downlink.close()

        # mark end-of-life anyway finally
        def owner_cleanup(task_fut):
            eol = self.eol

            if eol.done():
                return

            if task_fut.cancelled():
                eol.set_exception(asyncio.CancelledError())
                return
            exc = task_fut.exception()
            if exc is not None:
                eol.set_exception(exc)
            else:
                eol.set_result(None)

        asyncio.create_task(_facto_owner_task()).add_done_callback(owner_cleanup)

        asyncio.create_task(self.host_back_pkts())

    async def host_back_pkts(self):
        """
        Child class can override this method to customize the feedback landing loop

        """
        peer = self.peer
        eol = self.eol
        try:
            while True:
                # Note: `factoScript`s from the owner process run as if here
                cmd_val = await peer.read_command()
                if cmd_val is EndOfStream:
                    break
                if cmd_val is not None:
                    logger.info(
                        f"Factotum owner got unexpected peer command from factotum pid={self.facto_pid}\n  {cmd_val!r}"
                    )

        except asyncio.CancelledError:
            pass

        except Exception as exc:
            logger.error(
                f"Factotum owner error occurred with factotum pid={self.facto_pid}",
                exc_info=True,
            )
            if not eol.done():
                eol.set_exception(exc)

        finally:
            logger.debug(f"Factotum owner done with factotum pid={self.facto_pid}")

            if not eol.done():
                eol.set_result(None)

    async def eval(self, factotum_expr):
        await self.peer.post_command(
            f"peer.p2c({DATA_CHAN!r}, repr({factotum_expr!r}))"
        )
        return await self.uplink.get()

    def stop(self):
        self.peer.stop()

    @property
    def stopped(self):
        return self.eol.done()

    def __del__(self):
        pid = self.facto_pid
        if pid is not None:
            th = threading.Thread(target=confirmKill, args=(pid,))
            th.start()


def confirmKill(pid):
    try:
        while True:
            os.waitpid(pid, os.WNOHANG)  # prevent it from becoming a zombie
            os.kill(pid, signal.SIGKILL)
            time.sleep(0.1)
            # wait 0.1 second before checking it's actually killed
            os.kill(pid, 0)
            time.sleep(3)  # wait 3 seconds before try another round
    except OSError:
        # assuming failure means the process by this pid doesn't exist (anymore)
        return
