import Darwin
import Foundation
import IOKit
import IOKit.serial

/// USB device discovery, read passively from the IORegistry. It must never
/// open devices just to look: probing (as picotool does to find BOOTSEL)
/// stalls macOS mid-enumeration, so a board being plugged in never gets its
/// serial port.
enum USBDevices {
    /// RP2040 / RP2350 boot ROM (BOOTSEL mode).
    static let bootROMIDs: Set<[Int]> = [[0x2E8A, 0x0003], [0x2E8A, 0x000F]]
    /// Vendors of boards we may touch: Raspberry Pi (1.3+ firmware, boot ROM)
    /// and Arduino (pre-1.3 mbed firmware). Anything else - a phone, an FTDI
    /// USB-DMX interface - is left alone. Note this includes any other
    /// RP2040-based serial device: one that doesn't answer "?" is treated as a
    /// pre-1.3 board, so unplug those while flashing.
    static func isBoard(vendor: Int, product: Int) -> Bool {
        vendor == 0x2E8A || vendor == 0x2341
    }

    struct SerialPortInfo: Hashable {
        let path: String
        let vendor: Int
        let product: Int
        /// The USB port it's plugged into; a board keeps it across reboots.
        let location: Int
    }

    static func bootselPresent() -> Bool { !bootselLocations().isEmpty }

    /// USB ports with a board in the bootloader.
    static func bootselLocations() -> [Int] {
        var found: [Int] = []
        forEach(matching: IOServiceMatching("IOUSBHostDevice")) { service in
            if let v = intProperty(service, "idVendor"), let p = intProperty(service, "idProduct"),
               bootROMIDs.contains([v, p]) {
                found.append(intProperty(service, "locationID") ?? 0)
            }
        }
        return found
    }

    /// USB serial ports (non-USB ones, like Bluetooth, are skipped).
    static func serialPorts() -> [SerialPortInfo] {
        let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary
        matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
        var out: [SerialPortInfo] = []
        forEach(matching: matching as CFDictionary) { service in
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString,
                                                            kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  let vendor = parentInt(service, "idVendor")
            else { return }
            out.append(SerialPortInfo(path: path, vendor: vendor, product: parentInt(service, "idProduct") ?? 0,
                                      location: parentInt(service, "locationID") ?? 0))
        }
        return out.sorted { $0.path < $1.path }
    }

    private static func forEach(matching: CFDictionary?, _ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            body(service)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    /// A property of the USB device a serial port belongs to.
    private static func parentInt(_ service: io_object_t, _ key: String) -> Int? {
        (IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                         IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            as? NSNumber)?.intValue
    }

    private static func intProperty(_ service: io_object_t, _ key: String) -> Int? {
        (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.intValue
    }
}

/// A raw POSIX serial port.
final class SerialPort {
    // <sys/ttycom.h> ioctls; Swift doesn't import these macros.
    private static let TIOCEXCL: UInt = 0x2000_740D
    private static let TIOCSDTR: UInt = 0x2000_7479
    private static let TIOCCDTR: UInt = 0x2000_7478

    private let fd: Int32

    /// nil if the port can't be opened (gone, or another program has it).
    init?(path: String, baud: speed_t) {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        guard ioctl(fd, SerialPort.TIOCEXCL) != -1 else { Darwin.close(fd); return nil }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        cfsetspeed(&t, baud)
        tcsetattr(fd, TCSANOW, &t)
        self.fd = fd
    }

    deinit { Darwin.close(fd) }

    func setDTR(_ on: Bool) { _ = ioctl(fd, on ? SerialPort.TIOCSDTR : SerialPort.TIOCCDTR) }

    func write(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// Whatever arrives within `timeout`.
    func read(timeout: TimeInterval) -> [UInt8] {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = Darwin.read(fd, &buf, buf.count)
        return n > 0 ? Array(buf[0..<n]) : []
    }
}

enum BoardQuery {
    enum Result: Equatable {
        case busy             // couldn't open the port: never treat as old firmware
        case noAnswer         // opened, but no ID: pre-1.3 firmware (or not yet booted)
        case id(String)
    }

    /// Asks a running board for its FIRMWARE_ID ("?" on USB serial).
    static func firmwareID(port path: String) -> Result {
        guard let port = SerialPort(path: path, baud: 115200) else { return .busy }
        Thread.sleep(forTimeInterval: 0.3)
        var buf: [UInt8] = []
        // A freshly booted board takes ~1 s before loop() answers; queued "?"s
        // are answered once it does. Too short a wait would mistake a
        // just-flashed board for old firmware and reflash it.
        let deadline = Date().addingTimeInterval(4)
        let prefix = Array(FirmwareID.prefix.utf8)
        while Date() < deadline {
            port.write(Array("?".utf8))
            buf += port.read(timeout: 0.1)
            if let start = buf.firstRange(of: prefix)?.lowerBound,
               let end = buf[start...].firstIndex(of: UInt8(ascii: "\n")) {
                // The ID runs to the first space: the boot banner adds
                // " (build ID ...)" after it.
                let s = String(decoding: buf[start..<end], as: UTF8.self)
                return .id(String(s.split(whereSeparator: { $0.isWhitespace }).first ?? ""))
            }
        }
        return .noAnswer
    }

    /// Open at 1200 baud and drop DTR: both the pre-1.3 (mbed) and 1.3+
    /// (arduino-pico) cores reboot into BOOTSEL.
    static func rebootToBootloader(port path: String) {
        guard let port = SerialPort(path: path, baud: 1200) else { return }
        port.setDTR(true)
        Thread.sleep(forTimeInterval: 0.05)
        port.setDTR(false)
    }
}

enum Picotool {
    /// Bundled into the app at build time; falls back to PlatformIO's copy or
    /// a Homebrew install.
    static func find() -> String? {
        var candidates: [String] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("picotool/picotool").path)
        }
        candidates += [
            NSHomeDirectory() + "/.platformio/packages/tool-picotool-rp2040-earlephilhower/picotool",
            "/opt/homebrew/bin/picotool",
            "/usr/local/bin/picotool",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
