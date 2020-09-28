"""
Micro Protocol that Nedh speaks

"""
__all__ = ["Packet", "textPacket", "sendPacket", "receivePacketStream"]
import asyncio

from typing import *

from edh import *
from . import log

logger = log.get_logger(__name__)


MAX_HEADER_LENGTH = 60


PacketDirective = str
PacketPayload = bytes


class Packet(NamedTuple):
    dir: PacketDirective
    payload: PacketPayload


def textPacket(dir_: str, txt: str):
    if not txt.startswith("\n"):
        txt = "\n" + txt
    if not txt.endswith("\n"):
        txt = txt + "\n"
    return Packet(dir_, txt.encode("utf-8"))


async def sendPacket(
    peer_site: str, outlet: asyncio.StreamWriter, pkt: Packet,
):
    pkt_len = len(pkt.payload)
    pkt_hdr = f"[{pkt_len!r}#{pkt.dir!s}]"
    if len(pkt_hdr) > MAX_HEADER_LENGTH:
        raise EdhPeerError(self.peer_site, "sending out long packet header")
    outlet = outlet
    await outlet.drain()
    outlet.write(pkt_hdr.encode("utf-8"))
    outlet.write(pkt.payload)


PacketSink = Callable[[Packet], Awaitable]

# as Python lacks tail-call-optimization, looping within (async) generator
# is used here instead of tail recursion
async def receivePacketStream(
    peer_site: str,
    intake: asyncio.StreamReader,
    pkt_sink: PacketSink,
    eos: asyncio.Future,
):
    """
    Receive all packets being streamed to the specified intake stream

    The caller is responsible to close the intake/outlet streams anyway
    appropriate, but only after eos is signaled.
    """

    readahead = b""

    async def parse_hdr():
        nonlocal readahead
        while True:
            if len(readahead) < 1:
                readahead = await read_stream(eos, intake.read(MAX_HEADER_LENGTH))
                if readahead is EndOfStream:
                    return EndOfStream  # reached end-of-stream
                if not readahead:
                    return EndOfStream  # reached end-of-stream
            if b"["[0] != readahead[0]:
                logger.error(f"readahead: {readahead!r}")
                raise EdhPeerError(peer_site, "missing packet header")
            hdr_end_pos = readahead.find(b"]")
            if hdr_end_pos < 0:
                readmore = await read_stream(eos, intake.read(MAX_HEADER_LENGTH))
                if readmore is EndOfStream:
                    raise RuntimeError("premature end of packet stream")
                readahead += readmore
                continue
            # got a full packet header
            hdr = readahead[1:hdr_end_pos].decode("utf-8")
            readahead = readahead[hdr_end_pos + 1 :]
            plls, dir_ = hdr.split("#", 1)
            payload_len = int(plls)
            return payload_len, dir_

    try:
        while True:
            hdr = await parse_hdr()
            if hdr is EndOfStream:  # normal eos, try mark and done
                if not eos.done():
                    eos.set_result(EndOfStream)
                break

            payload_len, dir_ = hdr
            more2read = payload_len - len(readahead)
            if more2read == 0:
                payload = readahead
                readahead = b""
            elif more2read > 0:
                more_payload = await read_stream(eos, intake.readexactly(more2read))
                if more_payload is EndOfStream:
                    raise RuntimeError("premature end of packet stream")
                payload = readahead + more_payload
                readahead = b""
            else:  # readahead contains more than this packet
                payload = readahead[:more2read]
                readahead = readahead[more2read:]
            await pkt_sink(Packet(dir_, payload))
    except Exception as exc:
        if not eos.done():
            eos.set_exception(exc)
