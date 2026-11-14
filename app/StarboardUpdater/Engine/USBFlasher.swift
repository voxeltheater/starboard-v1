import Foundation

/// Flashes boards as they're plugged in over USB, one at a time. A port of
/// the old tools/usb_flash.py. For each board it:
///  1. asks a running board which build it has (boards on this build are
///     skipped; boards of another type are refused),
///  2. reboots it into the RP2040 bootloader (or uses it directly if it's
///     already there: a blank board, or one plugged in holding BOOTSEL),
///  3. writes and verifies the firmware with picotool,
///  4. waits for it to come back and confirms it's running the new build.
final class USBFlashJob {
    static let bootselWait: TimeInterval = 10   // for a board to reappear in the bootloader
    static let verifyWait: TimeInterval = 20    // for a flashed board to come back running

    let firmware: Firmware
    let stopFlag = StopFlag()
    private let log: (String, LogStyle) -> Void
    private let flashed: () -> Void

    init(firmware: Firmware, log: @escaping (String, LogStyle) -> Void, flashed: @escaping () -> Void) {
        self.firmware = firmware
        self.log = log
        self.flashed = flashed
    }

    func stop() { stopFlag.stop() }

    private func describe(_ raw: String) -> String {
        FirmwareID(raw)?.label ?? raw
    }

    /// Runs until stopped; call on a background thread.
    func run() {
        guard let picotool = Picotool.find() else {
            log("picotool is missing. Rebuild the app with PlatformIO installed (it bundles PlatformIO's picotool).", .fail)
            return
        }
        let target = firmware.firmwareID
        let board = firmware.board
        log("Ready to flash \(target.label) onto \(board.name) boards. Plug them in one at a time.", .ready)

        var seen: [String: String] = [:]        // port -> what we concluded, while plugged in
        var notedOnce = Set<String>()
        var pending = 0                         // flashed, not yet seen running the new build
        var pendingSince = Date()
        var done = 0

        while !stopFlag.isStopped {
            // A board already in the bootloader: blank, BOOTSEL held, or one we
            // just rebooted.
            if USBDevices.bootselPresent() {
                log("Board in bootloader: flashing \(target.label)…", .work)
                if flash(picotool) {
                    log("Written and verified, waiting for it to start…", .dim)
                    pending += 1
                    pendingSince = Date()
                } else {
                    log("FAILED to flash. Unplug it and try again.", .fail)
                    waitFor(seconds: 60) { !USBDevices.bootselPresent() }
                }
            }

            let ports = USBDevices.serialPorts()
            let paths = Set(ports.map(\.path))
            for path in seen.keys where !paths.contains(path) { seen[path] = nil }

            for port in ports where seen[port.path] == nil {
                if stopFlag.isStopped { break }
                guard USBDevices.boardVendors.contains(port.vendor) else {
                    if notedOnce.insert("vendor:\(port.path):\(port.vendor)").inserted {
                        log("Ignoring \(port.path): USB vendor \(String(format: "%04X", port.vendor)) isn't a Starboard.", .dim)
                    }
                    continue
                }

                let answer = BoardQuery.firmwareID(port: port.path)
                if answer == .busy {
                    if notedOnce.insert("busy:\(port.path)").inserted {
                        log("Can't open \(port.path). Is another program (a serial monitor?) using it? Retrying.", .dim)
                    }
                    continue
                }
                notedOnce.remove("busy:\(port.path)")

                if case .id(let raw) = answer {
                    if raw == target.raw {
                        seen[port.path] = "current"
                        if pending > 0 {
                            pending -= 1
                            done += 1
                            log("OK: running \(target.label). \(done) board\(done == 1 ? "" : "s") done. Unplug it.", .ok)
                            flashed()
                        } else {
                            log("Already on \(target.label). Unplug it.", .current)
                        }
                        continue
                    }
                    if let other = FirmwareID(raw), other.model != board.rawValue {
                        seen[port.path] = "wrong type"
                        log("REFUSED: this is a \(BoardType.named(model: other.model)) board; the firmware is for \(board.name). Unplug it, or pick \(BoardType.named(model: other.model)) above.", .refused)
                        continue
                    }
                }

                if pending > 0 && answer == .noAnswer {
                    // Almost certainly the board we just flashed, back up but not
                    // answering. Reflashing would just loop, so stop and say so.
                    seen[port.path] = "unverified"
                    pending = 0
                    log("WARNING: the flashed board came back but didn't report its build. Not reflashing; check it before it goes in the rig.", .warn)
                    continue
                }

                seen[port.path] = "updating"
                let running: String
                if case .id(let raw) = answer { running = describe(raw) } else { running = "pre-1.3 firmware" }
                log("Board running \(running): rebooting it into the bootloader…", .work)
                BoardQuery.rebootToBootloader(port: port.path)
                if !waitFor(seconds: USBFlashJob.bootselWait, USBDevices.bootselPresent) && !stopFlag.isStopped {
                    log("FAILED: it didn't enter the bootloader. Unplug it, hold BOOTSEL, and plug it back in.", .fail)
                }
                break // rescan from the top so the bootloader branch picks it up
            }

            if pending > 0 && Date().timeIntervalSince(pendingSince) > USBFlashJob.verifyWait {
                log("WARNING: a flashed board didn't come back running \(target.label) within \(Int(USBFlashJob.verifyWait)) s. Check it (unplug and replug to retry).", .warn)
                pending = 0
            }
            stopFlag.sleep(0.5)
        }
        log("Stopped. \(done) board\(done == 1 ? "" : "s") flashed and verified.", .plain)
    }

    private func flash(_ picotool: String) -> Bool {
        // The boot ROM shows up in the device list a moment before picotool
        // can open it, so retry for a few seconds rather than failing at once.
        let deadline = Date().addingTimeInterval(8)
        var result = Picotool.run(picotool, ["load", "-v", "-x", firmware.uf2.path])
        while result.status != 0 && result.output.contains("No accessible") && Date() < deadline
                && !stopFlag.isStopped {
            Thread.sleep(forTimeInterval: 0.5)
            result = Picotool.run(picotool, ["load", "-v", "-x", firmware.uf2.path])
        }
        if result.status != 0 {
            let lines = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            log("picotool: \(lines.last ?? "failed")", .dim)
            if lines.contains(where: { $0.lowercased().contains("multiple") }) {
                log("More than one board is in the bootloader. Plug in one at a time.", .warn)
            }
        }
        return result.status == 0
    }

    @discardableResult
    private func waitFor(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !stopFlag.isStopped {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
