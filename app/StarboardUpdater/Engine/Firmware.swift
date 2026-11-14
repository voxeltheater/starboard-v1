import Foundation

/// Board types, numbered as PCB_MODEL in src/main.cpp.
enum BoardType: Int, CaseIterable, Identifiable {
    // Declaration order is the picker order; raw values are fixed by the firmware.
    case rgb12 = 0
    case mono12 = 2
    case mono20 = 1

    var id: Int { rawValue }
    var name: String {
        switch self {
        case .rgb12: return "RGB12"
        case .mono20: return "MONO20"
        case .mono12: return "MONO12"
        }
    }
    /// File names in firmware/<version>/ and build envs in platformio.ini.
    var fileStem: String { name.lowercased() }

    static func named(model: Int) -> String {
        BoardType(rawValue: model)?.name ?? "unknown (\(model))"
    }
}

struct FirmwareError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// FIRMWARE_ID from src/main.cpp: "SBFWID:<model>:<build time>[:<version>]".
struct FirmwareID: Equatable {
    static let prefix = "SBFWID:"

    let raw: String
    let model: Int
    let buildTime: String
    let version: String?

    init?(_ raw: String) {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "SBFWID", let model = Int(parts[1]) else { return nil }
        self.raw = raw
        self.model = model
        self.buildTime = parts[2]
        self.version = parts.count >= 4 && !parts[3].isEmpty ? parts[3] : nil
    }

    /// What boards compare to skip an image they already run: CRC-32 of the ID.
    var buildID: UInt32 { CRC32.checksum(Array(raw.utf8)) }

    /// "v1.3", or the build time for builds from before versions existed.
    var label: String {
        if let version { return "v\(version)" }
        return "unversioned build \(buildTime)"
    }

    /// Finds the ID string embedded in a firmware image.
    static func find(in data: [UInt8]) -> FirmwareID? {
        let needle = Array(prefix.utf8)
        guard data.count >= needle.count else { return nil }
        var i = 0
        while i <= data.count - needle.count {
            if data[i] == needle[0] && Array(data[i..<i + needle.count]) == needle {
                if let end = data[i...].firstIndex(of: 0), end - i <= 64,
                   let s = String(bytes: data[i..<end], encoding: .ascii) {
                    return FirmwareID(s)
                }
                return nil
            }
            i += 1
        }
        return nil
    }
}

/// One firmware release for one board type: the .uf2 (for USB) and the .bin
/// (for DMX updates) of the same build.
struct Firmware: Identifiable, Hashable {
    let id: String          // version, or the file path for a custom build
    var title: String
    let board: BoardType
    let uf2: URL
    let bin: URL
    let firmwareID: FirmwareID
    let isCustom: Bool

    static func == (a: Firmware, b: Firmware) -> Bool { a.id == b.id && a.board == b.board }
    func hash(into h: inout Hasher) { h.combine(id); h.combine(board) }

    /// Loads and cross-checks a .uf2/.bin pair: both must carry the same ID,
    /// built for `board`.
    static func load(uf2: URL, bin: URL, board: BoardType, id: String, title: String,
                     isCustom: Bool) throws -> Firmware {
        guard let binData = try? Data(contentsOf: bin) else {
            throw FirmwareError("Can't read \(bin.lastPathComponent).")
        }
        guard let binID = FirmwareID.find(in: Array(binData)) else {
            throw FirmwareError("\(bin.lastPathComponent) has no firmware ID: it isn't a Starboard 1.3+ build.")
        }
        guard let uf2Data = try? Data(contentsOf: uf2) else {
            throw FirmwareError("Can't read \(uf2.lastPathComponent).")
        }
        let payload = UF2.payload(Array(uf2Data))
        guard !payload.isEmpty else { throw FirmwareError("\(uf2.lastPathComponent) isn't a UF2 file.") }
        guard let uf2ID = FirmwareID.find(in: payload) else {
            throw FirmwareError("\(uf2.lastPathComponent) has no firmware ID: it isn't a Starboard 1.3+ build.")
        }
        guard uf2ID == binID else {
            throw FirmwareError("\(uf2.lastPathComponent) and \(bin.lastPathComponent) are different builds.")
        }
        guard binID.model == board.rawValue else {
            throw FirmwareError("That build is for \(BoardType.named(model: binID.model)) boards, not \(board.name).")
        }
        return Firmware(id: id, title: title, board: board, uf2: uf2, bin: bin,
                        firmwareID: binID, isCustom: isCustom)
    }

    /// A build picked by hand: a .uf2 or .bin (its partner must sit next to
    /// it, as in .pio/build/<env>/), or the build folder itself.
    static func custom(at url: URL, board: BoardType) throws -> Firmware {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let dir = isDir.boolValue ? url : url.deletingLastPathComponent()
        let stem = isDir.boolValue ? "firmware" : url.deletingPathExtension().lastPathComponent
        let uf2 = dir.appendingPathComponent(stem + ".uf2")
        let bin = dir.appendingPathComponent(stem + ".bin")
        let fm = FileManager.default
        guard fm.fileExists(atPath: uf2.path), fm.fileExists(atPath: bin.path) else {
            throw FirmwareError("Need both \(stem).uf2 and \(stem).bin in \(dir.path).")
        }
        // Copy both files aside, so rebuilding the project while the app runs
        // can't change what's being flashed (or mismatch the ID it checks).
        let snap = fm.temporaryDirectory.appendingPathComponent("starboard-\(UUID().uuidString)")
        try fm.createDirectory(at: snap, withIntermediateDirectories: true)
        let uf2Snap = snap.appendingPathComponent("firmware.uf2")
        let binSnap = snap.appendingPathComponent("firmware.bin")
        try fm.copyItem(at: uf2, to: uf2Snap)
        try fm.copyItem(at: bin, to: binSnap)
        var fw = try load(uf2: uf2Snap, bin: binSnap, board: board, id: "custom:" + url.path,
                          title: "", isCustom: true)
        fw.title = "Other build: \(fw.firmwareID.label)"
        return fw
    }
}

/// The releases bundled with the app (the repo's firmware/ folder).
enum FirmwareLibrary {
    static var folder: URL? { Bundle.main.resourceURL?.appendingPathComponent("firmware") }

    /// Releases for `board`, newest first. Problems are returned, not thrown,
    /// so one bad release can't hide the others.
    static func releases(for board: BoardType, in folder: URL? = FirmwareLibrary.folder)
        -> (releases: [Firmware], problems: [String]) {
        guard let folder,
              let versions = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return ([], [])
        }
        var found: [Firmware] = []
        var problems: [String] = []
        let sorted = versions.filter { !$0.hasPrefix(".") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in sorted {
            let dir = folder.appendingPathComponent(version)
            let uf2 = dir.appendingPathComponent(board.fileStem + ".uf2")
            let bin = dir.appendingPathComponent(board.fileStem + ".bin")
            guard FileManager.default.fileExists(atPath: uf2.path) else { continue }
            do {
                let fw = try Firmware.load(uf2: uf2, bin: bin, board: board, id: version,
                                           title: "v\(version)", isCustom: false)
                if fw.firmwareID.version != version {
                    problems.append("firmware/\(version): files report \(fw.firmwareID.label), not v\(version).")
                    continue
                }
                found.append(fw)
            } catch {
                problems.append("firmware/\(version): \(error.localizedDescription)")
            }
        }
        if !found.isEmpty { found[0].title += " (latest)" }
        return (found, problems)
    }
}

enum UF2 {
    /// The bytes a .uf2 writes, in address order.
    static func payload(_ data: [UInt8]) -> [UInt8] {
        var blocks: [(UInt32, ArraySlice<UInt8>)] = []
        var off = 0
        while off + 512 <= data.count {
            let m0 = LE.u32(data, off), m1 = LE.u32(data, off + 4)
            let addr = LE.u32(data, off + 12), size = Int(LE.u32(data, off + 16))
            if m0 == 0x0A32_4655 && m1 == 0x9E5D_5157 && size <= 476 {
                blocks.append((addr, data[(off + 32)..<(off + 32 + size)]))
            }
            off += 512
        }
        return blocks.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
    }
}

enum LE {
    static func u32(_ d: [UInt8], _ i: Int) -> UInt32 {
        UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }
    static func put16(_ v: Int, into a: inout [UInt8]) {
        a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF))
    }
    static func put32(_ v: UInt32, into a: inout [UInt8]) {
        for s in stride(from: 0, to: 32, by: 8) { a.append(UInt8((v >> UInt32(s)) & 0xFF)) }
    }
}

enum BE {
    static func put16(_ v: Int, into a: inout [UInt8]) {
        a.append(UInt8((v >> 8) & 0xFF)); a.append(UInt8(v & 0xFF))
    }
    static func put32(_ v: UInt32, into a: inout [UInt8]) {
        for s in stride(from: 24, through: 0, by: -8) { a.append(UInt8((v >> UInt32(s)) & 0xFF)) }
    }
}

/// zlib-compatible CRC-32 (the same one the boards use).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
