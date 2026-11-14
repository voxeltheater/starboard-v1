#!/bin/sh
# Checks the Starboard Updater app's engine against tools/dmx_update.py (the
# Python sender, proven on hardware): update frames, gzip and network packets
# must be byte-for-byte the same. No hardware needed.
#   sh test/app/run.sh            build the harness and run the checks
#   test/app/.build/harness ...   hardware checks (see test/app/main.swift)
set -e
cd "$(dirname "$0")/../.."
mkdir -p test/app/.build
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -swift-version 5 -O -o test/app/.build/harness test/app/main.swift app/StarboardUpdater/Engine/*.swift
h=test/app/.build/harness

bin=${1:-.pio/build/rgb12/firmware.bin}
[ -f "$bin" ] || { echo "build the firmware first (pio run)"; exit 1; }

# 1. Update frames (raw image, so no compressor differences).
$h frames "$bin" "$out/swift.frames"
python3 tools/dmx_update.py "$bin" --universes 1 --no-gzip --dump "$out/py.frames" >/dev/null
cmp "$out/swift.frames" "$out/py.frames" && echo "frames: identical ($(($(wc -c < "$out/py.frames") / 512)) frames)"

# 2. gzip: Apple's deflate differs from Python's, so check it unpacks exactly.
$h gzip "$bin" "$out/fw.gz"
python3 -c "import gzip,sys; a=gzip.decompress(open(sys.argv[1],'rb').read()); b=open(sys.argv[2],'rb').read(); assert a==b, 'gzip mismatch'; print('gzip: unpacks to the original (%d -> %d bytes)' % (len(b), len(open(sys.argv[1],'rb').read())))" "$out/fw.gz" "$bin"

# 3. sACN and Art-Net packets, built by the Python sender's own classes.
$h packets "$out/swift.packets"
python3 - "$out/swift.packets" <<'PY'
import sys, struct
sys.path.insert(0, "tools")
import dmx_update as d
class Cap:
    def __init__(self): self.out = b""
    def sendto(self, p, dest): self.out += p
    def setsockopt(self, *a): pass
slots = bytes(i & 0xFF for i in range(512))
s = d.SacnSender(None, 200, "Starboard firmware update"); s.cid = bytes(range(16))
out = b""
for u in (1, 40, 300, 63999):
    out += s._packet(u, slots) + s._packet(u, slots)
out += s._packet(40, bytes(512), options=0x40)
a = d.ArtnetSender({u: ["x"] for u in (0, 39, 300, 32767)}); a.sock = Cap()
for u in (0, 39, 300, 32767): a.send(u, slots)
out += a.sock.out
out += b"Art-Net\x00" + struct.pack("<H", 0x2000) + struct.pack(">H", 14) + b"\x00\x00"
swift = open(sys.argv[1], "rb").read()
assert swift == out, "packets differ (swift %d bytes, python %d)" % (len(swift), len(out))
print("packets: sACN and Art-Net identical")
PY
echo "all app engine checks passed"
