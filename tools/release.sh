#!/bin/sh
# Builds the firmware for every board type and saves it as a release in
# firmware/<version>/, where the Starboard Updater app picks it up (it bundles
# the whole firmware/ folder when the app is built).
#
#   1. Bump FIRMWARE_VERSION in src/main.cpp and commit your changes.
#   2. sh tools/release.sh
#   3. Commit firmware/<version>/ and rebuild the app.
#
# Releases are never overwritten: boards and the app identify a release by its
# version, so the files behind a version must not change once made.
set -e
cd "$(dirname "$0")/.."

version=$(sed -n 's/^#define FIRMWARE_VERSION "\(.*\)"$/\1/p' src/main.cpp)
[ -n "$version" ] || { echo "no FIRMWARE_VERSION in src/main.cpp"; exit 1; }
dest="firmware/$version"
if [ -e "$dest" ]; then
  echo "$dest already exists. Bump FIRMWARE_VERSION in src/main.cpp for a new release."
  exit 1
fi
if ! git diff --quiet HEAD -- src lib platformio.ini; then
  echo "Commit your firmware changes first, so the release matches a commit:"
  git status --short -- src lib platformio.ini
  exit 1
fi

pio=$(command -v pio || echo "$HOME/.platformio/penv/bin/pio")
"$pio" run -e rgb12 -e mono12 -e mono20

mkdir -p "$dest"
for board in rgb12 mono12 mono20; do
  cp ".pio/build/$board/firmware.uf2" "$dest/$board.uf2"
  cp ".pio/build/$board/firmware.bin" "$dest/$board.bin"
done
{
  echo "Starboard firmware $version"
  echo "commit: $(git rev-parse HEAD)"
  echo "built:  $(date -u '+%Y-%m-%d %H:%M UTC')"
  for board in rgb12 mono12 mono20; do
    echo "$board: $(strings "$dest/$board.bin" | grep -m1 '^SBFWID:')"
  done
} > "$dest/RELEASE.txt"
cat "$dest/RELEASE.txt"
echo
echo "Saved to $dest. Commit it, then rebuild the Starboard Updater app."
