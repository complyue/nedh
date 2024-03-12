import asyncio

from edh import *
from nedh import *


async def __run__():

    fa = Factotum(
        ["epm", "x", "nedhm", "net/factotum"],
        work_dir=None,
    )

    await fa.peer.post_command(expr("factotumHello('gotcha')"))

    print("calc result=", await fa.eval(expr("3*7")))


asyncio.run(__run__())
