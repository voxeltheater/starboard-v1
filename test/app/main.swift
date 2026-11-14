// Command-line harness for the Starboard Updater engine (app/.../Engine),
// so it can be checked against tools/dmx_update.py and real boards without
// the UI. Built and driven by test/app/run.sh.
import Foundation

let args = CommandLine.arguments
func write(_ bytes: [UInt8], _ path: String) { FileManager.default.createFile(atPath: path, contents: Data(bytes)) }
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

switch args.count > 1 ? args[1] : "" {
case "frames":   // frames <firmware.bin> <out>: one raw (un-gzipped) pass
    let bin = Array(try! Data(contentsOf: URL(fileURLWithPath: args[2])))
    guard let id = FirmwareID.find(in: bin) else { fail("no ID") }
    let frames = try! UpdateProtocol.passFrames(image: bin, model: id.model, buildID: id.buildID)
    write(frames.flatMap { $0 }, args[3])
case "gzip":     // gzip <in> <out>
    write(Gzip.compress(Array(try! Data(contentsOf: URL(fileURLWithPath: args[2]))))!, args[3])
case "packets":  // packets <out>: sACN (fixed CID) and Art-Net packets for a test frame
    var sacn = SacnPacketBuilder(name: "Starboard firmware update", priority: 200, cid: Array(0..<16))
    var art = ArtnetPacketBuilder()
    let slots = (0..<512).map { UInt8($0 & 0xFF) }
    var out: [UInt8] = []
    for u in [1, 40, 300, 63999] { out += sacn.packet(universe: u, slots: slots); out += sacn.packet(universe: u, slots: slots) }
    out += sacn.packet(universe: 40, slots: [UInt8](repeating: 0, count: 512), options: 0x40)
    for u in [0, 39, 300, 32767] { out += art.dmx(universe: u, slots: slots) }
    out += ArtnetPacketBuilder.poll()
    write(out, args[2])
case "load":     // load <uf2-or-bin-or-dir> <board>: cross-check a build
    let board = BoardType.allCases.first { $0.fileStem == args[3] }!
    do { let fw = try Firmware.custom(at: URL(fileURLWithPath: args[2]), board: board); print("ok", fw.firmwareID.raw, fw.title) }
    catch { print("error:", error.localizedDescription) }
case "releases": // releases <firmware dir> <board>
    let board = BoardType.allCases.first { $0.fileStem == args[3] }!
    let r = FirmwareLibrary.releases(for: board, in: URL(fileURLWithPath: args[2]))
    for f in r.releases { print(f.title, f.firmwareID.raw) }
    for p in r.problems { print("problem:", p) }
case "usb":      // usb <uf2-or-dir> <board> <seconds>: run the USB flasher
    let board = BoardType.allCases.first { $0.fileStem == args[3] }!
    let fw = try! Firmware.custom(at: URL(fileURLWithPath: args[2]), board: board)
    let job = USBFlashJob(firmware: fw, log: { print(ISO8601DateFormatter().string(from: Date()), $1.emoji, $0); fflush(stdout) }, flashed: {})
    let t = Thread { job.run() }; t.start()
    Thread.sleep(forTimeInterval: Double(args[4])!); job.stop(); Thread.sleep(forTimeInterval: 1.5)
case "discover": // discover <bin-dir> <board> <prefix> <universes> <interface-ip>: Art-Net dry run, sends nothing
    let board = BoardType.allCases.first { $0.fileStem == args[3] }!
    let fw = try! Firmware.custom(at: URL(fileURLWithPath: args[2]), board: board)
    let iface = NetworkInterface.all().first { $0.ip == args[6] }
    let s = DMXSettings(proto: .artnet, nodePrefix: args[4], universes: parseUniverses(args[5])!, consoleNumbering: true, interface: iface)
    let job = DMXUpdateJob(settings: s, firmware: fw, log: { print($1.emoji, $0) },
                           routes: { for r in $0 { print("  ", r.universe, "->", r.nodes, r.merging ? "MERGING" : "") } },
                           progress: { _, _ in })
    job.run(send: false)
case "interfaces":
    for i in NetworkInterface.all() { print(i.label, "bcast", i.broadcast) }
default:
    fail("usage: see test/app/run.sh")
}
