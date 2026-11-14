# Starboard firmware

Firmware for the Starboard V1 LED driver boards (RP2040 with TLC59711 LED
drivers, fed over DMX), and **Starboard Updater**, the Mac app that installs
it. This repo is named for the **V1 hardware**; the current firmware is
**1.3**.

## What's new in 1.3

- **Quiet debug LED.** The green LED double-flashes at power-up, double-flashes
  again the first time DMX arrives, and then stays dark until the next power
  cycle. Faults are reported over USB serial only.
- **Firmware updates over DMX.** Update every board in the rig at once,
  through your existing Art-Net or sACN nodes.
- **Starboard Updater app.** Flash boards over USB as you plug them in, or
  update the whole rig over DMX, from one window.
- **Firmware versions.** Boards report which release they run, such as
  `v1.3`.
- **All red / all green / all blue test looks** on RGB12 boards (channel 511).
- **MONO12 addressing fix.** Drops 25–41 now work; before, they all landed on
  drop 24.
- **New core.** 1.3 moved from the Arduino mbed core to
  [arduino-pico](https://github.com/earlephilhower/arduino-pico), which
  provides the safe update bootloader. **Boards on pre-1.3 firmware can't take
  DMX updates.** Each one needs a single USB flash first; after that, every
  update can go over DMX.

## Starboard Updater (the app)

Open `app/StarboardUpdater.xcodeproj` in Xcode and press Run, or build it from
the command line:

```sh
cd app && xcodebuild -scheme StarboardUpdater -configuration Release -derivedDataPath build build
open "build/Build/Products/Release/Starboard Updater.app"
```

Build the firmware once with PlatformIO before building the app: the app
bundles PlatformIO's `picotool` for USB flashing. The app is Apple silicon
only, because that `picotool` is.

At the top of the window, pick the **board type** and the **firmware**. The
newest release is chosen by default; **Other build…** takes a `.pio/build/…`
folder for testing a development build. Both tabs use what's picked here.

### USB tab

Press **Start Flashing** and plug boards in one at a time. Each board is
checked, flashed, verified and announced with a sound:

| Line | Meaning |
|---|---|
| ✅ | Flashed and verified running the new firmware. Unplug it. |
| 👍 | Already on this firmware. Nothing to do. |
| 🚫 | Refused: the board is a different type. Pick its type above. |
| ❌ / ⚠️ | Something failed. The message says what to try. |

Things to know:

- **Pre-1.3 boards: plug USB in before powering the board**, or power-cycle it
  after plugging in. A powered pre-1.3 board doesn't show up on the Mac until
  it restarts.
- **Keep board types in separate batches.** Pre-1.3 and blank boards can't
  report their type, so they get whichever type is picked. Boards on 1.3 or
  later are type-checked and refused if they don't match.
- **macOS asks "Allow accessory to connect?"** for each new board, because a
  freshly flashed board shows up as a new USB device. Click Allow, or stop the
  prompts in System Settings › Privacy & Security › Allow accessories to
  connect › **Automatically When Unlocked**.
- **Close anything holding the board's serial port**, such as a serial
  monitor.

### DMX tab

This updates every board of the picked type on the given universes at once.
Updating ~100 boards on 32 universes takes about 30 seconds. Boards hold their
current look while the data plays. Each board then installs the update,
double-flashes and comes back on its own.

The settings default to this rig: Art-Net, nodes named `STARNET…`, universes
`40-71` numbered as on the console. The app remembers whatever you change.

1. **Turn off the console and every other DMX source on those universes.** A
   second source merges into the update data and corrupts it. Boards then
   never complete the image, so they just stay on their current firmware.
2. **Send from:** pick this Mac's address on the lighting network
   (`192.168.5.x` here).
3. **Check Nodes** finds the nodes and lists which one gets each universe,
   along with any node reporting a merge. It sends no DMX.
4. **Send Update…** asks you to confirm other sources are off, then sends.
   Run each board type as its own send.

How it works:

- **Node discovery.** Nodes are found by name with ArtPoll, and each universe
  goes only to the node that outputs it. The app keeps polling until every
  universe's node has answered, which can take a few seconds over Wi-Fi.
- **Universe numbering.** These nodes put sACN universe N on Art-Net universe
  N − 1. With "Numbered as on the console" ticked, you type the console's
  numbers and the app translates.
- **Merge check.** The app refuses to start if a node reports merging another
  source, and checks again a few seconds into the send. It has caught live
  merges on this rig but once missed one, so still turn other sources off.
- **sACN** works too: it multicasts at priority 200.

Safety:

- **Nothing is written to flash until a board has the whole image.** The
  image's checksum must match, and it must be built for that board type.
- **Power loss during a download** is harmless. The board keeps its current
  firmware.
- **Power loss during the few seconds of install** is handled by the
  arduino-pico bootloader, which finishes the copy on the next boot.
- **Boards skip an image they're already running,** so repeating a send is
  safe.
- **If a board didn't update,** check for a second source on its universe.
  Then send again, or flash that board over USB.

## Firmware releases

Every release lives in `firmware/<version>/`: a `.uf2` (USB) and a `.bin` (DMX)
for each board type, plus `RELEASE.txt` recording the commit it was built
from. The app bundles the whole folder, so each app build carries every
release, newest first.

To make a release:

1. Make and test your firmware changes. Use `pio run -e rgb12`, and the app's
   **Other build…** pointed at `.pio/build/rgb12`.
2. Bump `FIRMWARE_VERSION` in `src/main.cpp`, for example to `"1.3.1"` or
   `"1.4"`, and commit.
3. Run `sh tools/release.sh`. It builds all three board types into
   `firmware/<version>/`.
4. Commit `firmware/<version>/`, then rebuild the app.

The script refuses to overwrite an existing version or to build from
uncommitted changes. Boards and the app identify a release by its version, so
the files behind a version never change.

Boards report `SBFWID:<type>:<build time>:<version>`, where type 0 = RGB12,
1 = MONO20 and 2 = MONO12. Send `?` over USB serial at 115200 baud to get it.

## Boards and DMX

| Board | Build | DMX footprint, start address |
|---|---|---|
| RGB12 | `pio run -e rgb12` (the default) | 36 ch, starts at 33 × dial + 1 |
| MONO12 | `pio run -e mono12` | 12 ch, starts at 12 × drop + 1 (drops 0–41) |
| MONO20 | `pio run -e mono20` | 20 ch, starts at 20 × drop + 1 (drops 0–24) |

Dial notes:

- **Mono boards:** drop = dial 1 × 10 + dial 2.
- **Test patterns from the dials:** RGB12 dial 15 or mono dial 1 = 15.

The last five channels of each universe are control channels:

| Channel | Purpose |
|---|---|
| 508 / 509 / 510 | Red / green / blue scale |
| 511 | Mode (table below) |
| 512 | Brightness |

Channel 511 modes:

| Value | Look |
|---|---|
| 0 | Normal show |
| 10 | Monochrome |
| 20–34 | Index test |
| 40–54 | Solo RGB test |
| 60–74 | All-RGB test |
| 80–94 | White test |
| 100–114 | All red (RGB12) |
| 120–134 | All green (RGB12) |
| 140–154 | All blue (RGB12) |

Each board also reports on USB serial at 115200 baud:

- its firmware ID at boot;
- DMX faults;
- update download progress;
- a periodic line of the LED values for its address.

## Tests

- `sh test/host/run.sh`: the update protocol, round-tripped through the Python
  sender and the board's receiver code. No hardware needed.
- `sh test/app/run.sh`: checks the app's engine against the Python sender.
  Update frames and sACN/Art-Net packets must be byte-for-byte identical, and
  the app's gzip must unpack exactly.

## Repo layout

| Path | Contents |
|---|---|
| `src/main.cpp` | Firmware: DMX input, LED output, test patterns, debug LED |
| `src/dmx_update.*` | Board side of DMX firmware updates |
| `firmware/` | Released builds, bundled into the app |
| `app/` | Starboard Updater (SwiftUI). `Engine/` has no UI code; `project.yml` regenerates the Xcode project with XcodeGen; `make_icon.swift` redraws the app icon |
| `tools/release.sh` | Builds a release into `firmware/<version>/` |
| `tools/dmx_update.py` | Command-line DMX updater; the reference the app is tested against |
| `lib/Adafruit_TLC59711/` | Vendored TLC59711 library with an arduino-pico fix (see its `STARBOARD.md`) |
| `test/` | Host tests (above) |
| `platformio.ini` | Build settings, one env per board type |
