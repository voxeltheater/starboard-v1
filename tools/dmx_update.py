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
  # universes 40-71 over sACN multicast, out of the interface at 10.0.0.5
  python3 tools/dmx_update.py .pio/build/nanorp2040connect/firmware.bin \\
      --universes 40-71 --interface 10.0.0.5

  # Art-Net, unicast to the nodes whose names start with STARNET, which are
  # found automatically; universes given in the console's sACN numbering
  python3 tools/dmx_update.py firmware.bin --protocol artnet \\
      --nodes STARNET --numbering sacn --universes 40-71 --interface 10.0.0.5

  # same, but only show which node gets which universe (sends nothing)
  python3 tools/dmx_update.py firmware.bin --protocol artnet \\
      --nodes STARNET --numbering sacn --universes 40-71 --dry-run

Any other source on the update universes (a console, a second controller)
merges into the update packets and corrupts many of them, so boards never
complete the image - they just keep running their current firmware. The
sender asks you to confirm every other source is off before sending. With
Art-Net it also asks the nodes (ArtPoll) whether a target port reports
merging and stops if one does, but don't rely on that: on hardware, nodes
merging two Art-Net sources didn't report it.

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
    if end < 0 or end - start > 64:
        raise ValueError("malformed FIRMWARE_ID (no terminator)")
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


def _make_socket(interface):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if interface:
        try:
            sock.bind((interface, 0))
        except OSError as e:
            raise SystemExit("can't use --interface %s: %s (it must be this computer's own "
                             "IP address on the lighting network)" % (interface, e))
    return sock


class SacnSender:
    PORT = 5568

    def __init__(self, target, priority, name, interface=None):
        self.target = target
        self.priority = priority
        self.name = name.encode("utf-8")[:63]
        self.cid = uuid.uuid4().bytes
        self.seq = {}
        self.sock = _make_socket(interface)
        self.sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 8)
        if interface:
            # Without this the OS picks the interface for multicast, which on a
            # laptop is often Wi-Fi rather than the lighting network.
            self.sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF,
                                 socket.inet_aton(interface))

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

    def __init__(self, targets, interface=None):
        """targets: {wire universe: [IP, ...]}"""
        self.targets = targets
        self.seq = {}
        self.sock = _make_socket(interface)
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
        for ip in self.targets[universe]:
            self.sock.sendto(packet + slots, (ip, self.PORT))

    def finish(self, universes):
        pass


class ArtnetPoller:
    """ArtPoll discovery. Replies come back to port 6454, so this needs its
    own socket bound there (shared, in case a lighting app has it too)."""

    def __init__(self, interface=None, broadcast=None):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, "SO_REUSEPORT"):
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self.sock.bind(("", ArtnetSender.PORT))
        self.sock.setblocking(False)
        self.dests = [broadcast] if broadcast else []
        if interface and not broadcast:
            # Assume a /24, the norm on lighting networks; --broadcast overrides.
            self.dests.append(".".join(interface.split(".")[:3] + ["255"]))
        self.dests.append("255.255.255.255")
        self.ports = {}

    def start(self):
        self.ports = {}
        poll = b"Art-Net\x00" + struct.pack("<H", 0x2000) + struct.pack(">H", 14) + b"\x00\x00"
        for dest in self.dests:
            try:
                self.sock.sendto(poll, (dest, ArtnetSender.PORT))
            except OSError:
                pass

    def collect(self):
        """Read whatever replies have arrived; call repeatedly."""
        while True:
            try:
                p, _ = self.sock.recvfrom(2048)
            except (BlockingIOError, OSError):
                return
            if p[:10] != b"Art-Net\x00\x00\x21" or len(p) < 207:
                continue
            ip = ".".join(str(b) for b in p[10:14])
            net, sub = p[18], p[19]
            short = p[26:44].split(b"\x00")[0].decode("ascii", "replace").strip()
            long_ = p[44:108].split(b"\x00")[0].decode("ascii", "replace").strip()
            nports = struct.unpack(">H", p[172:174])[0]
            for i in range(min(nports, 4)):
                if not p[174 + i] & 0x80:  # PortTypes: can output DMX
                    continue
                uni = (net << 8) | (sub << 4) | (p[190 + i] & 0x0F)
                good = p[182 + i]  # GoodOutput: bit 3 = merging Art-Net data
                self.ports[(ip, uni)] = {"ip": ip, "short": short, "long": long_,
                                         "universe": uni, "merging": bool(good & 0x08)}

    def poll(self, seconds=3.0, repeats=3):
        # Nodes answer with one ArtPollReply per port, and over Wi-Fi some get
        # lost; polling a few times (keeping what's already arrived) fills the
        # gaps instead of failing on a missing universe.
        self.start()
        start = time.monotonic()
        sent = 1
        while time.monotonic() - start < seconds:
            if sent < repeats and time.monotonic() - start >= sent * seconds / repeats:
                ports = self.ports
                self.start()
                self.ports = ports
                sent += 1
            self.collect()
            time.sleep(0.05)
        return list(self.ports.values())


def merging_ports(ports, targets):
    """Ports that are merging and that we're sending update data to."""
    return [pt for pt in ports
            if pt["merging"] and pt["universe"] in targets
            and (pt["ip"] in targets[pt["universe"]] or _is_broadcast(targets[pt["universe"]]))]


def _is_broadcast(ips):
    return any(ip.endswith(".255") for ip in ips)


def describe_merge(ports, numbering_offset):
    return "; ".join("%s (%s) Art-Net %d%s" % (
        pt["short"] or pt["long"], pt["ip"], pt["universe"],
        "" if not numbering_offset else " = sACN %d" % (pt["universe"] + numbering_offset))
        for pt in sorted(ports, key=lambda x: x["universe"]))


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
    p.add_argument("--nodes", metavar="PREFIX",
                   help="Art-Net: find nodes whose name starts with PREFIX (e.g. STARNET) and "
                        "send each universe only to the node(s) outputting it")
    p.add_argument("--numbering", choices=["artnet", "sacn"],
                   help="numbering --universes is given in (default: the protocol's own). "
                        "With --protocol artnet --numbering sacn, sACN universe N is sent as "
                        "Art-Net N-1, as these nodes map them")
    p.add_argument("--broadcast", metavar="IP",
                   help="Art-Net: where to send discovery polls (default: the --interface "
                        "network's .255 and 255.255.255.255)")
    p.add_argument("--allow-merge", action="store_true",
                   help="Art-Net: send even if a target port reports merging another source")
    p.add_argument("--yes", action="store_true",
                   help="skip the 'are all other sources off?' confirmation")
    p.add_argument("--dry-run", action="store_true",
                   help="show what would be sent where (and any merging), then stop")
    p.add_argument("--interface", metavar="IP",
                   help="this computer's IP address on the lighting network, so packets "
                        "leave on that network and not e.g. Wi-Fi (recommended)")
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
    numbering = args.numbering or args.protocol
    if args.protocol == "sacn" and numbering == "artnet":
        p.error("--numbering artnet with --protocol sacn isn't supported; give sACN universes")
    lo, hi = (1, 63999) if numbering == "sacn" else (0, 32767)
    bad = [u for u in args.universes if not lo <= u <= hi]
    if bad:
        p.error("%s universes must be %d-%d; got %s" % (numbering, lo, hi, bad))
    # Offset from wire (Art-Net) numbering to the numbering the user gave.
    offset = 1 if (args.protocol == "artnet" and numbering == "sacn") else 0
    wire_universes = [u - offset for u in args.universes]
    if args.protocol == "sacn" and args.nodes:
        p.error("--nodes is for Art-Net; for sACN use multicast or --target")
    if args.protocol == "artnet" and not args.nodes and not args.target and not args.dump:
        p.error("Art-Net needs --nodes PREFIX (recommended) or --target IP")

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

    def label(u):
        return ("sACN %d = Art-Net %d" % (u + offset, u)) if offset else ("%s %d" % (args.protocol, u))

    poller = None
    if args.protocol == "artnet":
        poller = ArtnetPoller(args.interface, args.broadcast)
        print("polling Art-Net nodes...")
        prefix = (args.nodes or "").lower()

        def is_mine(pt):
            return pt["short"].lower().startswith(prefix) or pt["long"].lower().startswith(prefix)

        # Replies get lost (especially over Wi-Fi), so keep polling until every
        # requested universe has answered, up to a few rounds.
        found = {}
        for _ in range(5):
            for pt in poller.poll():
                found[(pt["ip"], pt["universe"])] = pt
            if not args.nodes:
                break
            have = {pt["universe"] for pt in found.values() if is_mine(pt)}
            if all(u in have for u in wire_universes):
                break
        ports = list(found.values())
        if args.nodes:
            mine = [pt for pt in ports if is_mine(pt)]
            targets = {}
            for pt in mine:
                if pt["universe"] in wire_universes:
                    targets.setdefault(pt["universe"], [])
                    if pt["ip"] not in targets[pt["universe"]]:
                        targets[pt["universe"]].append(pt["ip"])
            missing = [u for u in wire_universes if u not in targets]
            names = {pt["ip"]: pt["short"] or pt["long"] for pt in mine}
            if not mine:
                raise SystemExit("no Art-Net nodes named %s* answered (check --interface / "
                                 "--broadcast and that this computer is on their network)" % args.nodes)
            for u in wire_universes:
                if u in targets:
                    print("  %-24s -> %s" % (label(u), ", ".join(
                        "%s (%s)" % (names[ip], ip) for ip in targets[u])))
            if missing:
                raise SystemExit("no %s* node outputs: %s. Check the universe numbers "
                                 "(--numbering?) and that every node answered."
                                 % (args.nodes, ", ".join(label(u) for u in missing)))
        else:
            targets = {u: [args.target] for u in wire_universes}
        merging = merging_ports(ports, targets)
        if merging:
            msg = "reports merging another source: " + describe_merge(merging, offset)
            if not args.allow_merge:
                raise SystemExit("STOP - %s.\nTurn the other source off (it corrupts the "
                                 "update) or pass --allow-merge." % msg)
            print("warning: " + msg)
        if args.dry_run:
            print("dry run: nothing sent.")
            return 0
        sender = ArtnetSender(targets, args.interface)
    else:
        if args.dry_run:
            print("dry run: would send sACN to universes %s (%s)."
                  % (args.universes, args.target or "multicast"))
            return 0
        sender = SacnSender(args.target, args.priority, "Starboard firmware update", args.interface)

    if not args.yes:
        print("\nEvery other DMX source on these universes (consoles, other controllers,"
              "\nArt-Net or sACN) must be OFF, or boards won't complete the update. The node"
              "\ncheck above can't always tell - you have to.")
        try:
            answer = input("Are all other sources off? [y/N] ")
        except EOFError:
            answer = ""
        if answer.strip().lower() not in ("y", "yes"):
            print("not sent.")
            return 1

    per_pass = len(frames) / args.rate
    print("firmware: %s, for %s boards" % (ident, MODEL_NAMES[model].upper()))
    print("image: %d bytes%s, CRC %08X, %d chunks"
          % (len(image), "" if args.no_gzip else " (gzip of %d)" % raw_size,
             zlib.crc32(image), len(data)))
    print("%s to %d universe(s): %d passes, ~%.0f s each, ~%.0f s total"
          % (args.protocol, len(wire_universes), args.passes, per_pass, per_pass * args.passes))

    # A few seconds in, ask the nodes again: a source that was idle at the
    # pre-check, or one only merging now that we're sending, shows up here.
    recheck_at = time.monotonic() + 3.0
    recheck_until = None
    interval = 1.0 / args.rate
    next_time = time.monotonic()
    try:
        for n in range(args.passes):
            for i, frame in enumerate(frames):
                for u in wire_universes:
                    sender.send(u, frame)
                if poller and not args.allow_merge:
                    now = time.monotonic()
                    if recheck_until is None and now >= recheck_at:
                        poller.start()
                        recheck_until = now + 2.5
                    elif recheck_until is not None:
                        poller.collect()
                        if now >= recheck_until and recheck_until > 0:
                            merging = merging_ports(list(poller.ports.values()), sender.targets)
                            if merging:
                                print("\nSTOPPED - merging another source: %s.\nTurn the other "
                                      "source off and rerun (nothing was installed)."
                                      % describe_merge(merging, offset))
                                return 1
                            recheck_until = 0  # checked; don't repeat
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
        sender.finish(wire_universes)
    return 0


if __name__ == "__main__":
    sys.exit(main())
