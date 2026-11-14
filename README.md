# Starboard firmware

Firmware for the Starboard V1 LED driver boards (RP2040 with TLC59711 LED
drivers, fed over DMX). This repo is named for the **V1 hardware**. The
firmware itself is now **v2** (tag `v2.0.0`).

## What's new in firmware v2

- **Quiet debug LED.** The green LED double-flashes at power-up, double-flashes
  again the first time DMX arrives, and then stays dark until the next power
  cycle. Faults are reported over USB serial only.
- **Firmware updates over DMX.** `tools/dmx_update.py` updates every board in
  the rig at once, through your existing Art-Net or sACN nodes.
- **USB auto-flasher.** `tools/usb_flash.py` flashes boards as you plug them in,
  including boards still on the old v1 firmware.
- **All red / all green / all blue test looks** on RGB12 boards (channel 511).
- **New core.** v2 moved from the Arduino mbed core to
  [arduino-pico](https://github.com/earlephilhower/arduino-pico), which
  provides the safe update bootloader. **Boards on v1 firmware can't take DMX
  updates.** Each one needs a single USB flash first; after that, every update
  can go over DMX.

## Quick reference

| I want to... | Do this |
|---|---|
| Build firmware | `pio run` (RGB12) or `pio run -e mono12` |
| Put v2 on a board by hand | Run `tools/usb_flash.py` and plug the board in |
| Update the whole rig | Build, then run `tools/dmx_update.py` (see below) |
| Check which build a board runs | Open its USB serial port at 115200 baud and send `?` |
| Run the update-protocol tests | `sh test/host/run.sh` |

## Board types and builds

Each board type needs its own build. Every image records the type it was built
for, so boards ignore DMX updates meant for another type. The USB flasher also
refuses to cross-flash a board that's running v2.

| Board | Build command | Output | DMX footprint, start address |
|---|---|---|---|
| RGB12 (default) | `pio run` | `.pio/build/nanorp2040connect/` | 36 ch, starts at 33 × dial + 1 |
| MONO12 | `pio run -e mono12` | `.pio/build/mono12/` | 12 ch, starts at 12 × drop + 1 (drops 0–41) |
| MONO20 | set `PCB_MODEL` to `PCB_MONO20` | | 20 ch, starts at 20 × drop + 1 (drops 0–24) |

Dial notes:

- **Mono boards:** drop = dial 1 × 10 + dial 2.
- **Test patterns from the dials:** RGB12 dial 15 or mono dial 1 = 15.

Every build gets a fresh build ID (the time it was built). Boards report it as
`SBFWID:<type>:<build time>`, where type 0 = RGB12, 1 = MONO20 and 2 = MONO12.
The tools use it to skip boards that already run that exact build.

Use `firmware.uf2` for USB and `firmware.bin` for DMX updates.

## DMX control channels

These are the last five channels of each universe:

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

## USB auto-flasher: `tools/usb_flash.py`

Leave it running and plug boards in one at a time. It works out what each
board needs, flashes it, verifies it, and rings a bell when you can unplug it.

```sh
# RGB12 boards (flashes the current RGB12 build)
~/.platformio/penv/bin/python tools/usb_flash.py

# MONO12 boards
~/.platformio/penv/bin/python tools/usb_flash.py --uf2 .pio/build/mono12/firmware.uf2
```

What you'll see:

| Line | Meaning |
|---|---|
| ✅ | Flashed and verified running the new build. Unplug it. |
| 👍 | Already on this build. Nothing to do. |
| 🚫 | Refused: the board is a different type from this firmware. |
| ❌ / ⚠️ | Something failed. The message says what to try. |

Things to know:

- **Use PlatformIO's Python** as shown, because it already includes pyserial.
  Plain `python3` fails without it.
- **v1 boards: plug USB in before powering the board**, or power-cycle it
  after plugging in. A powered v1 board doesn't show up on the Mac until it
  restarts.
- **Restart the flasher after every rebuild.** It loads the firmware once at
  startup. Run an old copy and it will flash boards back to the older build.
- **Keep board types in separate batches.** v1 and blank boards can't report
  their type, so they get whichever build the flasher was started with. Only
  boards already on v2 are type-checked.
- **Close anything holding the board's serial port**, such as a serial
  monitor, so the flasher can talk to the board.

## Updating the rig over DMX: `tools/dmx_update.py`

This sends a `firmware.bin` to every board on the given universes at once.
Updating ~100 boards on 32 universes takes about 30 seconds. Boards hold their
current look while the data plays. Each board then installs the update,
double-flashes and comes back on its own.

### Before you send

1. **Build** the firmware for the boards you're updating.
2. **Turn off the console and every other DMX source on those universes.** A
   second source merges into the update data and corrupts it. Boards then
   never complete the image, so they just stay on their current firmware.
3. **Find your Mac's IP on the lighting network.** You'll pass it as
   `--interface`.

### Our rig

Universes 40–71 in the console's (sACN) numbering, sent over Art-Net to the
nodes named `STARNET …`:

```sh
# 1. Dry run: shows which node gets each universe, and any merging. Sends nothing.
python3 tools/dmx_update.py .pio/build/nanorp2040connect/firmware.bin \
    --protocol artnet --nodes STARNET --numbering sacn --universes 40-71 \
    --interface <your IP> --dry-run

# 2. The real thing (asks you to confirm other sources are off)
python3 tools/dmx_update.py .pio/build/nanorp2040connect/firmware.bin \
    --protocol artnet --nodes STARNET --numbering sacn --universes 40-71 \
    --interface <your IP>
```

For MONO12 boards, pass `.pio/build/mono12/firmware.bin` instead. Run each
board type as its own send.

How it works:

- **Node discovery.** `--nodes STARNET` finds the nodes by name with ArtPoll
  and sends each universe only to the node that outputs it. It keeps polling
  until every universe's node has answered, which can take a few seconds over
  Wi-Fi.
- **Universe numbering.** `--numbering sacn` lets you use the console's
  numbers. These nodes put sACN universe N on Art-Net universe N − 1, and the
  tool translates for you.
- **Merge check.** The tool asks the nodes whether any target port is merging
  another source. It refuses to start if one is, and checks again a few
  seconds in. It has caught live merges on this rig, but it once missed one,
  so still turn other sources off.
- **sACN** works too. Leave out `--protocol artnet`, and it multicasts at
  priority 200 by default.

### Safety

- **Nothing is written to flash until a board has the whole image.** The
  image's checksum must match, and it must be built for that board type.
- **Power loss during a download** is harmless. The board just keeps its
  current firmware.
- **Power loss during the few seconds of install** is handled by the
  arduino-pico bootloader, which finishes the copy on the next boot.
- **Boards skip an image they're already running,** so repeating a send is
  safe.
- **If a board didn't update,** check for a second source on its universe.
  Then send again, or flash that board over USB.

Run `python3 tools/dmx_update.py --help` for every option. The packet format
is documented in `src/dmx_update.h`.

## Serial output

Each board reports on USB serial at 115200 baud:

- its firmware ID at boot;
- DMX faults (no signal, bad start code, all-0xFF data, address out of range);
- update download progress;
- a periodic line of the LED values for its address.

Send `?` to get the firmware ID back.

## Repo layout

| Path | Contents |
|---|---|
| `src/main.cpp` | Firmware: DMX input, LED output, test patterns, debug LED |
| `src/dmx_update.*` | Board side of DMX firmware updates |
| `tools/dmx_update.py` | Sends firmware over DMX (standard-library Python) |
| `tools/usb_flash.py` | USB auto-flasher |
| `lib/Adafruit_TLC59711/` | Vendored TLC59711 library with an arduino-pico fix (see its `STARBOARD.md`) |
| `test/host/` | Host round-trip test of the update protocol; no hardware needed |
| `platformio.ini` | Build settings and board-type builds |
