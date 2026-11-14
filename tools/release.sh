#!/bin/sh
# Builds the firmware for every board type and publishes it as a GitHub
# release. The Starboard Updater app downloads releases from there.
#
#   1. Bump FIRMWARE_VERSION in src/main.cpp, commit, and push.
#   2. sh tools/release.sh                 publish a release
#      sh tools/release.sh --prerelease    publish for testing: the app lists it
#                                          but never picks it by default
#
# Needs the GitHub CLI (brew install gh), logged in with write access.
#
# Releases are never overwritten: boards and the app identify a release by its
# version, so the files behind a version must not change once published. To
# withdraw a bad release, delete it on GitHub; the app removes it on its next
# check. The build is staged in .release/<version>/ first, and a staged build
# is published as is if this script is run again (for example after a failed
# upload).
set -e
cd "$(dirname "$0")/.."
repo=voxeltheater/starboard-v1

pre=""
case "$1" in
  "") ;;
  --prerelease) pre="--prerelease" ;;
  *) echo "usage: sh tools/release.sh [--prerelease]"; exit 1 ;;
esac

command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh"; exit 1; }
version=$(sed -n 's/^#define FIRMWARE_VERSION "\(.*\)"$/\1/p' src/main.cpp)
[ -n "$version" ] || { echo "no FIRMWARE_VERSION in src/main.cpp"; exit 1; }
tag="v$version"
if gh release view "$tag" -R "$repo" >/dev/null 2>&1; then
  echo "$tag is already published. Bump FIRMWARE_VERSION in src/main.cpp for a new release."
  exit 1
fi

stage=".release/$version"
if [ -f "$stage/RELEASE.txt" ]; then
  echo "Publishing the build already staged in $stage:"
  commit=$(sed -n 's/^commit: //p' "$stage/RELEASE.txt")
else
  if ! git diff --quiet HEAD -- src lib platformio.ini; then
    echo "Commit your firmware changes first, so the release matches a commit:"
    git status --short -- src lib platformio.ini
    exit 1
  fi
  commit=$(git rev-parse HEAD)
  pio=$(command -v pio || echo "$HOME/.platformio/penv/bin/pio")
  "$pio" run -e rgb12 -e mono12 -e mono20
  mkdir -p "$stage"
  for board in rgb12 mono12 mono20; do
    cp ".pio/build/$board/firmware.uf2" "$stage/starboard-$version-$board.uf2"
    cp ".pio/build/$board/firmware.bin" "$stage/starboard-$version-$board.bin"
  done
  {
    echo "Starboard firmware $version"
    echo "commit: $commit"
    echo "built:  $(date -u '+%Y-%m-%d %H:%M UTC')"
    for board in rgb12 mono12 mono20; do
      echo "$board: $(strings "$stage/starboard-$version-$board.bin" | grep -m1 '^SBFWID:')"
    done
  } > "$stage/RELEASE.txt"
fi
cat "$stage/RELEASE.txt"
echo

# Every file must report this version, or the app will reject the release.
for board in rgb12 mono12 mono20; do
  strings "$stage/starboard-$version-$board.bin" | grep -q "^SBFWID:.*:$version\$" || {
    echo "$stage/starboard-$version-$board.bin doesn't report version $version."; exit 1; }
done

git fetch -q origin
if [ -z "$(git branch -r --contains "$commit" 2>/dev/null)" ]; then
  echo "Push commit $commit to GitHub first, so the release points at code others can see."
  exit 1
fi

gh release create "$tag" -R "$repo" --target "$commit" $pre \
  --title "Starboard firmware $version" --notes-file "$stage/RELEASE.txt" \
  "$stage"/starboard-"$version"-*.uf2 "$stage"/starboard-"$version"-*.bin
echo
echo "Published $tag. Press ↻ in Starboard Updater (or reopen it) to download it."
