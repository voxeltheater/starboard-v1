import Compression
import Foundation

/// Firmware-update packets carried in ordinary DMX frames. Must match
/// src/dmx_update.h (board side) and tools/dmx_update.py (same sender, in
/// Python); test/app/run.sh checks this file against the Python output.
enum UpdateProtocol {
    static let magic: [UInt8] = [0x53, 0x42, 0x46, 0x57, 0xA5, 0x5A, 0xC3, 0x3C] // "SBFW" A5 5A C3 3C
    static let protocolVersion: UInt8 = 1
    static let packetHeader: UInt8 = 1
    static let packetData: UInt8 = 2
    static let slots = 512
    static let dataOffset = 18
    static let crcOffset = 508
    static let maxChunk = crcOffset - dataOffset
    static let maxChunks = 512
    /// Must not exceed DMX_UPDATE_MAX_IMAGE in src/main.cpp.
    static let maxImage = 160 * 1024
    /// A header every this many data packets, so a board that joins mid-stream
    /// picks the image up quickly.
    static let headerEvery = 16
    static let defaultChunk = 480

    private static func seal(_ body: [UInt8]) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: slots)
        frame.replaceSubrange(0..<body.count, with: body)
        var crc: [UInt8] = []
        LE.put32(CRC32.checksum(frame[0..<crcOffset]), into: &crc)
        frame.replaceSubrange(crcOffset..<slots, with: crc)
        return frame
    }

    /// One pass over `image` (already gzipped, if it's going to be), with
    /// headers interleaved: each element is one 512-slot DMX frame.
    static func passFrames(image: [UInt8], model: Int, buildID: UInt32,
                           chunkSize: Int = defaultChunk) throws -> [[UInt8]] {
        guard chunkSize > 0 && chunkSize <= maxChunk else {
            throw FirmwareError("Chunk size must be 1-\(maxChunk).")
        }
        guard image.count <= maxImage else {
            throw FirmwareError("The image is \(image.count) bytes; boards can only buffer \(maxImage).")
        }
        let chunkCount = (image.count + chunkSize - 1) / chunkSize
        guard chunkCount <= maxChunks else { throw FirmwareError("Too many chunks for one image.") }

        let crc = CRC32.checksum(image)
        var header = magic + [protocolVersion, packetHeader]
        LE.put32(crc, into: &header)
        LE.put32(UInt32(image.count), into: &header)
        header.append(UInt8(model))
        LE.put16(chunkSize, into: &header)
        LE.put32(buildID, into: &header)
        let headerFrame = seal(header)

        var frames: [[UInt8]] = []
        for index in 0..<chunkCount {
            if index % headerEvery == 0 { frames.append(headerFrame) }
            let chunk = image[(index * chunkSize)..<min(image.count, (index + 1) * chunkSize)]
            var data = magic + [protocolVersion, packetData]
            LE.put32(crc, into: &data)
            LE.put16(index, into: &data)
            LE.put16(chunk.count, into: &data)
            data.append(contentsOf: chunk)
            frames.append(seal(data))
        }
        return frames
    }

    /// Data packets in one pass (excludes the interleaved headers).
    static func chunkCount(imageSize: Int, chunkSize: Int = defaultChunk) -> Int {
        (imageSize + chunkSize - 1) / chunkSize
    }
}

enum Gzip {
    /// gzip-wraps a raw deflate stream; the arduino-pico OTA bootloader
    /// unpacks gzip images itself, and it roughly halves the send time.
    static func compress(_ input: [UInt8]) -> [UInt8]? {
        let capacity = input.count + input.count / 8 + 1024
        var out = [UInt8](repeating: 0, count: capacity)
        let n = input.withUnsafeBufferPointer { src in
            compression_encode_buffer(&out, capacity, src.baseAddress!, input.count, nil,
                                      COMPRESSION_ZLIB) // raw deflate, despite the name
        }
        guard n > 0 else { return nil }
        // Header: magic, deflate, no flags, mtime 0, max-compression hint, Unix.
        var gz: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x02, 0x03]
        gz.append(contentsOf: out[0..<n])
        LE.put32(CRC32.checksum(input), into: &gz)
        LE.put32(UInt32(truncatingIfNeeded: input.count), into: &gz)
        return gz
    }
}

/// sACN (E1.31) data packets.
struct SacnPacketBuilder {
    static let port: UInt16 = 5568
    let cid: [UInt8]
    let name: [UInt8]
    let priority: UInt8
    private var sequence: [Int: UInt8] = [:]

    init(name: String, priority: UInt8, cid: [UInt8] = SacnPacketBuilder.randomCID()) {
        self.cid = cid
        self.name = Array(Array(name.utf8).prefix(63))
        self.priority = priority
    }

    static func randomCID() -> [UInt8] {
        let u = UUID().uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    static func multicastAddress(_ universe: Int) -> String {
        "239.255.\(universe >> 8).\(universe & 0xFF)"
    }

    /// options 0x40 = Stream_Terminated: nodes drop this source at once.
    mutating func packet(universe: Int, slots: [UInt8], options: UInt8 = 0) -> [UInt8] {
        let seq = sequence[universe, default: 0]
        sequence[universe] = seq &+ 1

        var dmp: [UInt8] = []
        BE.put16(0x7000 | (10 + 513), into: &dmp)
        dmp += [0x02, 0xA1]
        BE.put16(0, into: &dmp)
        BE.put16(1, into: &dmp)
        BE.put16(513, into: &dmp)
        dmp.append(0x00)
        dmp += slots

        var framing: [UInt8] = []
        BE.put16(0x7000 | (77 + dmp.count), into: &framing)
        BE.put32(0x0000_0002, into: &framing)
        framing += name + [UInt8](repeating: 0, count: 64 - name.count)
        framing.append(priority)
        BE.put16(0, into: &framing)
        framing += [seq, options]
        BE.put16(universe, into: &framing)

        var root: [UInt8] = [0x00, 0x10, 0x00, 0x00] + Array("ASC-E1.17".utf8) + [0, 0, 0]
        BE.put16(0x7000 | (22 + framing.count + dmp.count), into: &root)
        BE.put32(0x0000_0004, into: &root)
        return root + cid + framing + dmp
    }
}

/// Art-Net packets.
struct ArtnetPacketBuilder {
    static let port: UInt16 = 6454
    private static let id: [UInt8] = Array("Art-Net".utf8) + [0]
    private var sequence: [Int: UInt8] = [:]

    mutating func dmx(universe: Int, slots: [UInt8]) -> [UInt8] {
        let seq = UInt8(Int(sequence[universe, default: 0]) % 255 + 1) // 0 means "sequencing off"
        sequence[universe] = seq
        var p = ArtnetPacketBuilder.id
        LE.put16(0x5000, into: &p)       // OpDmx; OpCode is little endian
        BE.put16(14, into: &p)           // ProtVer
        p += [seq, 0, UInt8(universe & 0xFF), UInt8((universe >> 8) & 0x7F)]
        BE.put16(slots.count, into: &p)  // Length
        return p + slots
    }

    static func poll() -> [UInt8] {
        var p = id
        LE.put16(0x2000, into: &p)
        BE.put16(14, into: &p)
        return p + [0, 0]
    }

    /// One output port from an ArtPollReply.
    struct Port: Hashable {
        let ip: String
        let shortName: String
        let longName: String
        let universe: Int
        let merging: Bool
        var name: String { shortName.isEmpty ? longName : shortName }
    }

    static func parseReply(_ p: [UInt8]) -> [Port] {
        guard p.count >= 207, Array(p[0..<8]) == id, p[8] == 0x00, p[9] == 0x21 else { return [] }
        let ip = p[10..<14].map(String.init).joined(separator: ".")
        let net = Int(p[18]), sub = Int(p[19])
        func text(_ r: Range<Int>) -> String {
            let bytes = p[r].prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        let short = text(26..<44), long = text(44..<108)
        let ports = Int(p[172]) << 8 | Int(p[173])
        var out: [Port] = []
        for i in 0..<min(ports, 4) where p[174 + i] & 0x80 != 0 { // PortTypes: can output DMX
            let universe = net << 8 | sub << 4 | Int(p[190 + i] & 0x0F)
            let merging = p[182 + i] & 0x08 != 0                   // GoodOutput bit 3
            out.append(Port(ip: ip, shortName: short, longName: long, universe: universe, merging: merging))
        }
        return out
    }
}

/// "40-71" or "1,2,5-8" -> sorted unique universes.
func parseUniverses(_ text: String) -> [Int]? {
    var out = Set<Int>()
    for part in text.split(separator: ",") {
        let t = part.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        let ends = t.split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if ends.count == 2 {
            guard let lo = Int(ends[0]), let hi = Int(ends[1]), lo <= hi, hi - lo < 4096 else { return nil }
            out.formUnion(lo...hi)
        } else {
            guard let u = Int(t) else { return nil }
            out.insert(u)
        }
    }
    return out.isEmpty ? nil : out.sorted()
}
