#!/usr/bin/env python3
"""Broadcast Starboard firmware to every board in the rig over DMX.

The image is cut into packets that ride in ordinary DMX frames (see
src/dmx_update.h for the layout), sent out through your existing sACN or
Art-Net nodes. Boards hold their last look while the update data plays, then
install the new firmware and reboot once they have a complete, verified copy.
Boards can't reply over DMX, so the image is repeated for several passes to
give every board a chance to fill in anything it missed.

Stop the console (or anything else outputting to these universes) first:
two sources on one universe will interleave and slow the update to a crawl.

Examples:
  # all of universes 1-20 over sACN multicast
  python3 tools/dmx_update.py .pio/build/nanorp2040connect/firmware.bin \\
      --universes 1-20

  # Art-Net, broadcast on the 2.x network, universes 0-19
  python3 tools/dmx_update.py firmware.bin \\
      --protocol artnet --target 2.255.255.255 --universes 0-19

Needs only the Python 3 standard library.
"""

import argparse
import gzip
import socket
import struct
import sys
import time
import uuid
import zlib

# Must match src/dmx_update.h.
MAGIC = bytes([ord("S"), ord("B"), ord("F"), ord("W"), 0xA5, 0x5A, 0xC3, 0x3C])
PROTOCOL_VERSION = 1
PACKET_HEADER = 1
PACKET_DATA = 2
SLOTS = 512
DATA_OFFSET = 18
CRC_OFFSET = 508
MAX_CHUNK = CRC_OFFSET - DATA_OFFSET
MAX_CHUNKS = 512
# Must not exceed DMX_UPDATE_MAX_IMAGE in src/main.cpp.
MAX_IMAGE = 160 * 1024

# PCB_MODEL values in src/main.cpp.
MODELS = {"rgb12": 0, "mono20": 1, "mono12": 2}
MODEL_NAMES = {v: k for k, v in MODELS.items()}

# FIRMWARE_ID in src/main.cpp: "SBFWID:<PCB_MODEL>:<build time>".
FIRMWARE_ID_PREFIX = b"SBFWID:"


def read_firmware_id(image):
    """Return (model, build_id, id_string) from a firmware.bin, or raise."""
    start = image.find(FIRMWARE_ID_PREFIX)
    if start < 0:
        raise ValueError(
            "no FIRMWARE_ID in this file: it isn't a Starboard build with DMX update "
            "support (or it's the .uf2/.signed file rather than firmware.bin)"
        )
    end = image.find(b"\x00", start)
    ident = image[start:end]
    try:
        model = int(ident.split(b":")[1])
    except (IndexError, ValueError):
        raise ValueError("malformed FIRMWARE_ID %r" % ident)
    if model not in MODEL_NAMES:
        raise ValueError("unknown board model %d in FIRMWARE_ID" % model)
    return model, zlib.crc32(ident), ident.decode("ascii", "replace")

# Interleave a header every this many data packets, so a board that joins
# mid-stream (or rebooted, or missed the first one) picks the image up quickly.
HEADER_EVERY = 16


def _seal(body):
    """Pad a packet to 512 slots and append the packet CRC."""
    frame = bytearray(SLOTS)
    frame[: len(body)] = body
    struct.pack_into("<I", frame, CRC_OFFSET, zlib.crc32(bytes(frame[:CRC_OFFSET])))
    return bytes(frame)


def build_frames(image, model, build_id, chunk_size=480):
    """Return (header_frame, [data_frames]) for one image."""
    if not 0 < chunk_size <= MAX_CHUNK:
        raise ValueError("chunk size must be 1-%d" % MAX_CHUNK)
    if len(image) > MAX_IMAGE:
        raise ValueError(
            "image is %d bytes; boards can only buffer %d" % (len(image), MAX_IMAGE)
        )
    chunks = [image[i : i + chunk_size] for i in range(0, len(image), chunk_size)]
    if len(chunks) > MAX_CHUNKS:
        raise ValueError("too many chunks; raise --chunk-size")

    crc = zlib.crc32(image)
    common = MAGIC + struct.pack("<BBI", PROTOCOL_VERSION, PACKET_HEADER, crc)
    header = _seal(common + struct.pack("<IBHI", len(image), model, chunk_size, build_id))

    data = []
    for index, chunk in enumerate(chunks):
        prefix = MAGIC + struct.pack("<BBI", PROTOCOL_VERSION, PACKET_DATA, crc)
        data.append(_seal(prefix + struct.pack("<HH", index, len(chunk)) + chunk))
    return header, data


def pass_frames(header, data):
    """One pass over the image, with headers interleaved."""
    frames = []
    for i, frame in enumerate(data):
        if i % HEADER_EVERY == 0:
            frames.append(header)
        frames.append(frame)
    return frames


class SacnSender:
    PORT = 5568

    def __init__(self, target, priority, name):
        self.target = target
        self.priority = priority
        self.name = name.encode("utf-8")[:63]
        self.cid = uuid.uuid4().bytes
        self.seq = {}
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 8)

    def _packet(self, universe, slots, options=0):
        seq = self.seq.get(universe, 0)
        self.seq[universe] = (seq + 1) & 0xFF
        dmp = struct.pack(">HBBHHH", 0x7000 | (10 + 513), 0x02, 0xA1, 0, 1, 513)
        dmp += b"\x00" + slots
        framing = struct.pack(">HI", 0x7000 | (77 + len(dmp)), 0x00000002)
        framing += self.name.ljust(64, b"\x00")
        framing += struct.pack(">BHBBH", self.priority, 0, seq, options, universe)
        root_vector = struct.pack(">HI", 0x7000 | (22 + len(framing) + len(dmp)), 0x00000004)
        root = struct.pack(">HH", 0x0010, 0x0000) + b"ASC-E1.17\x00\x00\x00"
        return root + root_vector + self.cid + framing + dmp

    def _dest(self, universe):
        if self.target:
            return (self.target, self.PORT)
        return ("239.255.%d.%d" % (universe >> 8, universe & 0xFF), self.PORT)

    def send(self, universe, slots):
        self.sock.sendto(self._packet(universe, slots), self._dest(universe))

    def finish(self, universes):
        # Stream_Terminated: tells nodes to drop this source straight away
        # rather than holding our last frame until they time out.
        for _ in range(3):
            for u in universes:
                self.sock.sendto(self._packet(u, bytes(SLOTS), options=0x40), self._dest(u))


class ArtnetSender:
    PORT = 6454

    def __init__(self, target):
        if not target:
            raise SystemExit("--target is required for Art-Net (e.g. 2.255.255.255)")
        self.target = target
        self.seq = {}
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

    def send(self, universe, slots):
        seq = self.seq.get(universe, 0) % 255 + 1  # 0 means "sequencing off"
        self.seq[universe] = seq
        # ArtDmx: OpCode is little endian, ProtVer and Length big endian.
        packet = (
            b"Art-Net\x00"
            + struct.pack("<H", 0x5000)
            + struct.pack(">H", 14)
            + struct.pack("BBBB", seq, 0, universe & 0xFF, (universe >> 8) & 0x7F)
            + struct.pack(">H", SLOTS)
        )
        self.sock.sendto(packet + slots, (self.target, self.PORT))

    def finish(self, universes):
        pass


def parse_universes(text):
    universes = []
    for part in text.split(","):
        part = part.strip()
        if "-" in part:
            lo, hi = (int(x) for x in part.split("-", 1))
            universes.extend(range(lo, hi + 1))
        elif part:
            universes.append(int(part))
    if not universes:
        raise argparse.ArgumentTypeError("no universes given")
    return sorted(set(universes))


def main(argv=None):
    p = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("\n\n", 1)[1],
    )
    p.add_argument("firmware", help="firmware.bin from the PlatformIO build (not the .uf2)")
    p.add_argument("--model", choices=sorted(MODELS),
                   help="optional safety check: refuse to send unless the firmware was "
                        "built for this board type (it's read from the file either way)")
    p.add_argument("--universes", required=True, type=parse_universes,
                   help="e.g. 1-20 or 1,2,5-8")
    p.add_argument("--protocol", choices=["sacn", "artnet"], default="sacn")
    p.add_argument("--target", help="unicast/broadcast IP (sACN defaults to multicast)")
    p.add_argument("--passes", type=int, default=5, help="times to repeat the image (default 5)")
    p.add_argument("--rate", type=float, default=25.0,
                   help="frames per second per universe (default 25); keep at or below "
                        "your nodes' DMX output rate")
    p.add_argument("--priority", type=int, default=200,
                   help="sACN priority (default 200, above a console's usual 100)")
    p.add_argument("--chunk-size", type=int, default=480)
    p.add_argument("--no-gzip", action="store_true",
                   help="send the raw image instead of gzip-compressing it")
    p.add_argument("--dump", metavar="FILE",
                   help="write one pass of 512-byte frames to FILE instead of sending")
    args = p.parse_args(argv)

    with open(args.firmware, "rb") as f:
        image = f.read()
    try:
        model, build_id, ident = read_firmware_id(image)
    except ValueError as e:
        raise SystemExit(str(e))
    if args.model and MODELS[args.model] != model:
        raise SystemExit("this firmware is for %s boards, not %s" % (MODEL_NAMES[model], args.model))
    raw_size = len(image)
    if not args.no_gzip:
        # The arduino-pico OTA bootloader unpacks gzip images itself.
        image = gzip.compress(image, compresslevel=9, mtime=0)

    try:
        header, data = build_frames(image, model, build_id, args.chunk_size)
    except ValueError as e:
        raise SystemExit(str(e))
    frames = pass_frames(header, data)

    if args.dump:
        with open(args.dump, "wb") as f:
            f.write(b"".join(frames))
        print("wrote %d frames to %s" % (len(frames), args.dump))
        return 0

    if args.protocol == "sacn":
        sender = SacnSender(args.target, args.priority, "Starboard firmware update")
    else:
        sender = ArtnetSender(args.target)

    per_pass = len(frames) / args.rate
    print("firmware: %s, for %s boards" % (ident, MODEL_NAMES[model].upper()))
    print("image: %d bytes%s, CRC %08X, %d chunks"
          % (len(image), "" if args.no_gzip else " (gzip of %d)" % raw_size,
             zlib.crc32(image), len(data)))
    print("%s to universes %s: %d passes, ~%.0f s each, ~%.0f s total"
          % (args.protocol, args.universes, args.passes, per_pass, per_pass * args.passes))

    interval = 1.0 / args.rate
    next_time = time.monotonic()
    try:
        for n in range(args.passes):
            for i, frame in enumerate(frames):
                for u in args.universes:
                    sender.send(u, frame)
                next_time += interval
                delay = next_time - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                if i % 50 == 0:
                    sys.stdout.write("\rpass %d/%d  %3d%%" % (n + 1, args.passes, 100 * i // len(frames)))
                    sys.stdout.flush()
        print("\rdone. Boards that got a complete image install it and reboot (a few seconds).")
    except KeyboardInterrupt:
        print("\ninterrupted. Boards only install a complete image, so nothing partial was "
              "installed; rerun to finish (boards keep what they have until they reboot).")
    finally:
        sender.finish(args.universes)
    return 0


if __name__ == "__main__":
    sys.exit(main())
