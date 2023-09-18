import os, sys

import asyncio
import logging

from edh import *
from nedh import *


# os pid of owner process
ownerPid = os.getppid()
# os pid of factotum process
factotumPid = os.getpid()

logger = logging.getLogger(f"Factotum[{factotumPid}<-*{ownerPid}]")


def factotumHello(msg):
    print(f"I ({sys.executable}) got a msg from factotum owner:\n   {msg}")


async def _run_():
    if len(sys.argv) == 2:
        commSockFd = sys.argv[1]
    else:
        raise RuntimeError("Not expected factotum worker cmdl: " + sys.argv)

    peer = await takeEdhFd(int(commSockFd))
    peer.ensure_channel(DATA_CHAN)

    import nedh.effects

    effect_import(nedh.effects)

    effect(
        {
            netPeer: peer,
        }
    )

    eol = peer.eol
    try:
        while True:
            # Note: `factoScript`s from the owner process run as if here
            cmd_val = await peer.read_command()
            if cmd_val is EndOfStream:
                break
            if cmd_val is not None:
                logger.info(
                    f"Factotum pid={factotumPid} got unexpected peer command from owner pid={ownerPid}\n  {cmd_val!r}"
                )

    except asyncio.CancelledError:
        pass

    except Exception as exc:
        logger.error(
            "Factotum pid={factotumPid} error occurred with owner pid={ownerPid}",
            exc_info=True,
        )
        if not eol.done():
            eol.set_exception(exc)

    finally:
        logger.debug(f"Factotum pid={factotumPid} done with owner pid={ownerPid}")

        if not eol.done():
            eol.set_result(None)


asyncio.run(_run_())
