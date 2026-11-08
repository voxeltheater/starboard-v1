#!/usr/bin/env python3
"""Flash Starboard boards automatically as they're plugged in over USB.

Leave it running and plug boards in one at a time. For each board it:
  1. asks a running board which build it has (boards running this build are
     skipped; boards built for a different board type are refused),
  2. reboots it into the RP2040 bootloader (or uses it directly if it's
     already there, e.g. a blank board or one plugged in holding BOOTSEL),
  3. writes and verifies the new firmware with picotool,
  4. waits for it to come back and confirms it's running the new build.
Then unplug it and plug in the next. A bell rings on success and failure.

Boards on the old mbed firmware can't report their build, so they're always
flashed - and their board type can't be checked, so make sure the firmware
matches the boards you're plugging in.

Run it with PlatformIO's Python, which already has pyserial:
  ~/.platformio/penv/bin/python tools/usb_flash.py

Options let you point at a different .uf2 (default: the current build).
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmx_update import MODEL_NAMES, read_firmware_id  # noqa: E402

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    raise SystemExit("needs pyserial. Run with PlatformIO's Python instead:\n"
                     "  ~/.platformio/penv/bin/python tools/usb_flash.py")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_UF2 = os.path.join(ROOT, ".pio", "build", "nanorp2040connect", "firmware.uf2")
DEFAULT_PICOTOOL = os.path.expanduser(
    "~/.platformio/packages/tool-picotool-rp2040-earlephilhower/picotool")

# USB vendor IDs of boards we're allowed to touch. Anything else (a USB-DMX
# interface, a phone, ...) is left strictly alone.
DEFAULT_VIDS = {0x2E8A: "Raspberry Pi", 0x2341: "Arduino"}

BOOTSEL_WAIT = 10    # seconds for a board to reappear in the bootloader
VERIFY_WAIT = 20     # seconds for a flashed board to come back running


def log(msg, bell=False):
    sys.stdout.write("%s %s%s\n" % (time.strftime("%H:%M:%S"), msg, "\a" if bell else ""))
    sys.stdout.flush()


def uf2_payload(path):
    """Flatten a .uf2 into the bytes it writes, in address order."""
    with open(path, "rb") as f:
        data = f.read()
    blocks = []
    for off in range(0, len(data) - 511, 512):
        m0, m1, _flags, addr, size = struct.unpack_from("<IIIII", data, off)
        if m0 == 0x0A324655 and m1 == 0x9E5D5157 and size <= 476:
            blocks.append((addr, data[off + 32: off + 32 + size]))
    if not blocks:
        raise SystemExit("%s isn't a UF2 file" % path)
    blocks.sort()
    return b"".join(b for _, b in blocks)


# USB IDs of the RP2040 / RP2350 boot ROM (BOOTSEL mode).
BOOTROM_IDS = {(0x2E8A, 0x0003), (0x2E8A, 0x000F)}


def _usb_ids():
    """(vid, pid) of every USB device, read passively, or None if unsupported.

    Must not open the devices: polling with picotool (which opens every
    Raspberry Pi device to look for BOOTSEL) stalls macOS mid-enumeration,
    so a board being plugged in never gets its serial port.
    """
    if sys.platform == "darwin":
        out = subprocess.run(["ioreg", "-p", "IOUSB", "-l", "-w0"],
                             capture_output=True, text=True).stdout
        ids = set()
        for block in out.split("+-o ")[1:]:
            vid = pid = None
            for line in block.splitlines():
                line = line.strip(" |")
                if line.startswith('"idVendor" = '):
                    vid = int(line.split("=")[1])
                elif line.startswith('"idProduct" = '):
                    pid = int(line.split("=")[1])
            if vid is not None and pid is not None:
                ids.add((vid, pid))
        return ids
    if os.path.isdir("/sys/bus/usb/devices"):
        ids = set()
        for d in os.listdir("/sys/bus/usb/devices"):
            try:
                with open("/sys/bus/usb/devices/%s/idVendor" % d) as f:
                    vid = int(f.read(), 16)
                with open("/sys/bus/usb/devices/%s/idProduct" % d) as f:
                    pid = int(f.read(), 16)
                ids.add((vid, pid))
            except (OSError, ValueError):
                pass
        return ids
    return None


def bootsel_present(picotool):
    ids = _usb_ids()
    if ids is not None:
        return bool(ids & BOOTROM_IDS)
    out = subprocess.run([picotool, "info"], capture_output=True, text=True).stdout
    return "No accessible" not in out and out.strip() != ""


def flash(picotool, uf2):
    r = subprocess.run([picotool, "load", "-v", "-x", uf2], capture_output=True, text=True)
    ok = r.returncode == 0
    if not ok:
        detail = (r.stdout + r.stderr).strip().splitlines()
        log("   picotool: %s" % (detail[-1] if detail else "failed"))
        if any("multiple" in line.lower() for line in detail):
            log("   (more than one board in the bootloader - plug in one at a time)")
    return ok


def query_id(device):
    """Ask a running board for its FIRMWARE_ID; None if it doesn't answer."""
    try:
        with serial.Serial(device, 115200, timeout=0.1) as s:
            time.sleep(0.3)
            buf = b""
            # A freshly booted board takes ~1 s (setup delays) before loop()
            # answers; queued "?"s are answered once it does. Too short a wait
            # would mistake a just-flashed board for old firmware and reflash it.
            deadline = time.time() + 4.0
            while time.time() < deadline:
                s.write(b"?")
                buf += s.read(512)
                start = buf.find(b"SBFWID:")
                if start >= 0:
                    end = buf.find(b"\n", start)
                    if end > 0:
                        return buf[start:end].strip().decode("ascii", "replace")
    except (serial.SerialException, OSError):
        return None
    return None


def touch_1200(device):
    """Open at 1200 baud and drop DTR: both Arduino cores reboot into BOOTSEL."""
    try:
        s = serial.Serial(device, 1200)
        s.dtr = False
        s.close()
    except (serial.SerialException, OSError):
        pass


def wait_for(cond, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if cond():
            return True
        time.sleep(0.25)
    return False


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter,
                                epilog=__doc__.split("\n\n", 1)[1])
    p.add_argument("--uf2", default=DEFAULT_UF2, help="firmware to flash (default: current build)")
    p.add_argument("--picotool", default=DEFAULT_PICOTOOL)
    p.add_argument("--vid", action="append", default=[], metavar="HEX",
                   help="also treat this USB vendor ID as a board (e.g. 0x1234)")
    args = p.parse_args()

    picotool = args.picotool if os.path.exists(args.picotool) else shutil.which("picotool")
    if not picotool:
        raise SystemExit("picotool not found; build the project once with PlatformIO, or pass --picotool")
    if not os.path.exists(args.uf2):
        raise SystemExit("%s not found; build the project first (pio run)" % args.uf2)
    vids = dict(DEFAULT_VIDS)
    for v in args.vid:
        vids[int(v, 16)] = "custom"

    try:
        model, _, target = read_firmware_id(uf2_payload(args.uf2))
    except ValueError as e:
        raise SystemExit("%s: %s" % (args.uf2, e))
    model_tag = "SBFWID:%d:" % model

    log("Ready to flash %s (%s boards). Plug boards in one at a time; Ctrl-C to stop."
        % (target, MODEL_NAMES[model].upper()))

    seen = {}          # serial port -> what we concluded, while it stays plugged in
    ignored = set()
    pending = 0        # flashed, not yet seen running the new build
    pending_since = 0.0
    done = 0

    try:
        while True:
            # A board already in the bootloader: blank, BOOTSEL held, or one we
            # just rebooted.
            if bootsel_present(picotool):
                log("Board in bootloader: flashing...")
                if flash(picotool, args.uf2):
                    log("   written and verified, waiting for it to start...")
                    pending += 1
                    pending_since = time.time()
                else:
                    log("FAILED to flash. Unplug it and try again.", bell=True)
                    wait_for(lambda: not bootsel_present(picotool), 60)

            ports = {pt.device: pt for pt in serial.tools.list_ports.comports()}
            for dev in list(seen):
                if dev not in ports:
                    del seen[dev]

            for dev, pt in ports.items():
                if dev in seen or pt.vid is None:
                    continue
                if pt.vid not in vids:
                    if (dev, pt.vid) not in ignored:
                        ignored.add((dev, pt.vid))
                        log("(ignoring %s: USB vendor %04X isn't a board - add --vid %04X if it is)"
                            % (dev, pt.vid, pt.vid))
                    continue

                ident = query_id(dev)
                if ident == target:
                    seen[dev] = "current"
                    if pending:
                        pending -= 1
                        done += 1
                        log("OK: running %s. %d board(s) done this session - unplug it."
                            % (target, done), bell=True)
                    else:
                        log("Already up to date (%s) - unplug it." % dev)
                    continue
                if ident and not ident.startswith(model_tag):
                    seen[dev] = "wrong model"
                    other = ident.split(":")[1] if ident.count(":") >= 2 else "?"
                    other = MODEL_NAMES.get(int(other), other) if other.isdigit() else other
                    log("REFUSED: this is a %s board (%s); the firmware is for %s. Unplug it."
                        % (str(other).upper(), ident, MODEL_NAMES[model].upper()), bell=True)
                    continue

                if pending and ident is None:
                    # Almost certainly the board we just flashed, back up but not
                    # answering. Reflashing would just loop, so stop and say so.
                    seen[dev] = "unverified"
                    pending = 0
                    log("WARNING: the flashed board came back but didn't report its build. "
                        "Not reflashing; check it before putting it in the rig.", bell=True)
                    continue

                seen[dev] = "updating"
                log("Board on %s running %s: rebooting it into the bootloader..."
                    % (dev, ident or "older firmware (no ID)"))
                touch_1200(dev)
                if not wait_for(lambda: bootsel_present(picotool), BOOTSEL_WAIT):
                    log("FAILED: it didn't enter the bootloader. Unplug it, hold BOOTSEL, "
                        "and plug it back in.", bell=True)
                break  # re-scan from the top so the bootloader branch picks it up

            if pending and time.time() - pending_since > VERIFY_WAIT:
                log("WARNING: a flashed board didn't come back running %s within %d s. "
                    "Check it (unplug and replug to retry)." % (target, VERIFY_WAIT), bell=True)
                pending = 0

            time.sleep(0.5)
    except KeyboardInterrupt:
        log("Stopped. %d board(s) flashed and verified this session." % done)


if __name__ == "__main__":
    main()
