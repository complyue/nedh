"""
Nedh Peer Interface

"""
__all__ = ["Peer"]

from typing import *
import asyncio

import inspect
import ast

from edh import *
from .log import *

from .mproto import *

logger = get_logger(__name__)


class Peer:
    def __init__(
        self,
        ident,
        eol: asyncio.Future,
        posting: Callable[[Packet], Awaitable],
        hosting: Callable[[], Awaitable[Packet]],
        channels: Dict[Any, EventSink] = None,
    ):
        # identity of peer
        self.ident = ident
        # end-of-life state
        self.eol = eol
        # cmd outlet
        self.posting = posting
        # cmd intake
        self.hosting = hosting
        # cmd mux
        self.channels = channels or {}

        async def peer_cleanup():
            try:
                await self.eol
            except:
                pass

            for ch in self.channels.values():
                ch.publish(EndOfStream)

        asyncio.create_task(peer_cleanup())

    def __repr__(self):
        return f"Peer<{self.ident}>"

    async def join(self):
        await self.eol

    def stop(self):
        if not self.eol.done():
            self.eol.set_result(None)

    def armed_channel(self, ch_lctr: object) -> EventSink:
        return self.channels.get(ch_lctr, None)

    def ensure_channel(self, ch_lctr: object) -> EventSink:
        ch_sink = self.channels.get(ch_lctr, None)
        if ch_sink is None:
            ch_sink = EventSink()
            self.channels[ch_lctr] = ch_sink
        return ch_sink

    def arm_channel(
        self, ch_lctr: object, ch_sink: Optional[EventSink] = None
    ) -> EventSink:
        if ch_sink is None:
            ch_sink = EventSink()
        self.channels[ch_lctr] = ch_sink
        return ch_sink

    async def post_command(self, src: str, dir_: object = ""):
        if self.eol.done():
            await self.eol  # reraise the exception caused eol if any
            raise RuntimeError("peer end-of-life")
        await self.posting(textPacket(repr(dir_), str(src)))

    async def p2c(self, dir_: object, src: str):
        if self.eol.done():
            await self.eol  # reraise the exception caused eol if any
            raise RuntimeError("peer end-of-life")
        await self.posting(textPacket(repr(dir_), str(src)))

    async def read_command(
        self, cmd_globals: Optional[dict] = None, cmd_locals: Optional[dict] = None,
    ) -> Optional[object]:
        """
        Read next command from peer

        Note a command may target a specific channel, thus get posted to that
             channel's sink, and None will be returned from here for it.
        """
        eol = self.eol
        pkt = await read_stream(eol, self.hosting())
        if pkt is EndOfStream:
            return EndOfStream
        assert isinstance(pkt, Packet), f"Unexpected packet of type: {type(pkt)!r}"
        if cmd_globals is None:
            assert cmd_locals is None, "given locals but not globals ?!"
            caller_frame = inspect.currentframe().f_back
            cmd_globals = caller_frame.f_globals
            cmd_locals = caller_frame.f_locals
        if pkt.dir.startswith("blob:"):
            blob_dir = pkt.dir[5:]
            if len(blob_dir) < 1:
                return pkt.payload
            ch_lctr = await run_py(blob_dir, self.ident, cmd_globals, cmd_locals)
            ch_sink = self.channels.get(ch_lctr, None)
            if ch_sink is None:
                raise RuntimeError(f"Missing command channel: {ch_lctr!r}")
            ch_sink.publish(pkt.payload)
            return None
        # interpret as textual command
        src = pkt.payload.decode("utf-8")
        try:
            cmd_val = await run_py(src, self.ident, cmd_globals, cmd_locals)
            if len(pkt.dir) < 1:
                return cmd_val
            ch_lctr = await run_py(pkt.dir, self.ident, cmd_globals, cmd_locals)
            ch_sink = self.channels.get(ch_lctr, None)
            if ch_sink is None:
                raise RuntimeError(f"Missing command channel: {ch_lctr!r}")
            ch_sink.publish(cmd_val)
            return None
        except Exception as exc:
            if not eol.done():
                eol.set_exception(exc)
            raise  # reraise as is


async def run_py(
    code: str,
    src_name: str = "<py-code>",
    globals_: Optional[dict] = None,
    locals_: Optional[dict] = None,
) -> object:
    maybe_aw = exec_py(code, src_name, globals_, locals_)
    if inspect.isawaitable(maybe_aw):
        return await maybe_aw
    return maybe_aw


def exec_py(
    code: str,
    src_name: str = "<py-code>",
    globals_: Optional[dict] = None,
    locals_: Optional[dict] = None,
) -> object:
    """
    Run arbitrary Python code in supplied globals, return evaluated value of last statement.

    """
    if globals_ is None:
        globals_ = {}
    if locals_ is None:
        locals_ = globals_
    try:
        ast_ = ast.parse(code, src_name, "exec")
        last_expr = None
        last_def_name = None
        for field_ in ast.iter_fields(ast_):
            if "body" != field_[0]:
                continue
            if len(field_[1]) > 0:
                le = field_[1][-1]
                if isinstance(le, ast.Expr):
                    last_expr = ast.Expression()
                    last_expr.body = field_[1].pop().value
                elif isinstance(le, (ast.FunctionDef, ast.ClassDef)):
                    last_def_name = le.name
        exec(compile(ast_, src_name, "exec"), globals_, locals_)
        if last_expr is not None:
            return eval(compile(last_expr, src_name, "eval"), globals_, locals_)
        elif last_def_name is not None:
            # godforbid the code to declare global/nonlocal for the last defined artifact
            return locals_[last_def_name]
        return None
    except Exception:
        logger.error(
            f"""Error running Python code:
-=-{src_name}-=-
{code!s}
-=*{src_name}*=-
""",
            exc_info=True,
        )
        raise
