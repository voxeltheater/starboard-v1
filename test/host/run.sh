#!/bin/sh
# Round-trips a random image through tools/dmx_update.py (sender) and
# src/dmx_update.cpp (board receiver) on the host. No hardware needed.
set -e
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

c++ -std=c++17 -Wall -Wextra -O1 -o "$out/test" test/host/test_dmx_update.cpp src/dmx_update.cpp

for size in 32 479 480 481 65000 150000; do
  # Random bytes with a FIRMWARE_ID embedded, as the sender requires.
  python3 -c "import os,sys; d=bytearray(os.urandom(max($size,32))); d=d.replace(b'SBFWID',b'xxxxxx'); d[4:24]=b'SBFWID:0:test-$size'.ljust(20,b'x')[:19]+b'\0'; sys.stdout.buffer.write(bytes(d[:max($size,32)]))" > "$out/image.bin"
  python3 tools/dmx_update.py "$out/image.bin" --model rgb12 --universes 1 \
    --no-gzip --dump "$out/frames.bin" > /dev/null
  python3 tools/dmx_update.py "$out/image.bin" --model rgb12 --universes 1 \
    --no-gzip --chunk-size 400 --dump "$out/frames400.bin" > /dev/null
  printf '%7d bytes: ' "$size"
  "$out/test" "$out/frames.bin" "$out/image.bin" 0 "$out/frames400.bin"
done
