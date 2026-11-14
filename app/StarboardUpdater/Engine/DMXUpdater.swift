import Foundation

enum DMXProtocol: String, CaseIterable, Identifiable {
    case artnet = "Art-Net"
    case sacn = "sACN"
    var id: String { rawValue }
}

struct DMXSettings {
    var proto: DMXProtocol
    /// Art-Net: send each universe only to nodes whose name starts with this.
    var nodePrefix: String
    /// As typed by the user.
    var universes: [Int]
    /// Art-Net: the universes were typed in the console's sACN numbering,
    /// which these nodes put one above Art-Net (sACN N = Art-Net N-1).
    var consoleNumbering: Bool
    var interface: NetworkInterface?
    var passes: Int = 5
    /// Frames per second per universe; at or below the nodes' DMX output rate.
    var rate: Double = 25
    var priority: UInt8 = 200

    /// Offset from wire (Art-Net) numbers to typed numbers.
    var offset: Int { proto == .artnet && consoleNumbering ? 1 : 0 }
    var wireUniverses: [Int] { universes.map { $0 - offset } }

    func label(wire u: Int) -> String {
        switch proto {
        case .sacn: return "sACN \(u)"
        case .artnet: return offset != 0 ? "sACN \(u + offset) = Art-Net \(u)" : "Art-Net \(u)"
        }
    }

    func validate() throws {
        if universes.isEmpty { throw FirmwareError("Enter the universes to update, e.g. 40-71.") }
        // Art-Net carries 15-bit universes (0-32767); with console numbering
        // that's 1-32768. sACN universes are 1-63999.
        let (lo, hi) = proto == .sacn ? (1, 63999) : consoleNumbering ? (1, 32768) : (0, 32767)
        if let bad = universes.first(where: { $0 < lo || $0 > hi }) {
            throw FirmwareError("Universe \(bad) is out of range (\(lo)-\(hi)).")
        }
        if interface == nil { throw FirmwareError("Pick this Mac's address on the lighting network.") }
    }
}

/// Where each universe goes, from Art-Net discovery.
struct DMXRoute: Identifiable, Hashable {
    let universe: String
    let nodes: String
    let merging: Bool
    var id: String { universe }
}

/// Sends a firmware.bin to every board on the chosen universes, through the
/// existing Art-Net or sACN nodes. A port of tools/dmx_update.py.
///
/// Boards can't reply over DMX, so the image repeats for several passes. Any
/// other source on these universes merges into the update packets and
/// corrupts them, so boards never complete the image (and stay on their
/// current firmware): everything else must be off.
final class DMXUpdateJob {
    let settings: DMXSettings
    let firmware: Firmware
    let stopFlag = StopFlag()
    private let log: (String, LogStyle) -> Void
    private let routes: ([DMXRoute]) -> Void
    private let progress: (Double, String) -> Void

    init(settings: DMXSettings, firmware: Firmware,
         log: @escaping (String, LogStyle) -> Void,
         routes: @escaping ([DMXRoute]) -> Void,
         progress: @escaping (Double, String) -> Void) {
        self.settings = settings
        self.firmware = firmware
        self.log = log
        self.routes = routes
        self.progress = progress
    }

    func stop() { stopFlag.stop() }

    // MARK: Art-Net discovery

    private final class Poller {
        let socket: UDPSocket
        let destinations: [String]
        var ports: [String: ArtnetPacketBuilder.Port] = [:]   // "ip/universe" -> port

        init(interface: NetworkInterface?) throws {
            // Replies come back to port 6454, shared in case a lighting app has it.
            socket = try UDPSocket(bindIP: nil, port: ArtnetPacketBuilder.port, shared: true, broadcast: true)
            destinations = (interface.map { [$0.broadcast] } ?? []) + ["255.255.255.255"]
        }

        func start(keep: Bool = false) {
            if !keep { ports = [:] }
            for d in destinations { socket.send(ArtnetPacketBuilder.poll(), to: d, port: ArtnetPacketBuilder.port) }
        }

        func collect() {
            while let p = socket.receive() {
                for port in ArtnetPacketBuilder.parseReply(p) { ports["\(port.ip)/\(port.universe)"] = port }
            }
        }

        /// Nodes answer with one ArtPollReply per port, and over Wi-Fi some get
        /// lost; polling a few times, keeping what's arrived, fills the gaps.
        func poll(seconds: TimeInterval = 3, repeats: Int = 3, stop: StopFlag) -> [ArtnetPacketBuilder.Port] {
            start()
            let begin = Date()
            var sent = 1
            while Date().timeIntervalSince(begin) < seconds && !stop.isStopped {
                if sent < repeats && Date().timeIntervalSince(begin) >= Double(sent) * seconds / Double(repeats) {
                    start(keep: true)
                    sent += 1
                }
                collect()
                Thread.sleep(forTimeInterval: 0.05)
            }
            return Array(ports.values)
        }
    }

    private struct Plan {
        var targets: [Int: [String]]   // wire universe -> node IPs
        var merging: [ArtnetPacketBuilder.Port]
    }

    private func isMine(_ p: ArtnetPacketBuilder.Port) -> Bool {
        let prefix = settings.nodePrefix.trimmingCharacters(in: .whitespaces).lowercased()
        return prefix.isEmpty || p.shortName.lowercased().hasPrefix(prefix) || p.longName.lowercased().hasPrefix(prefix)
    }

    private func mergingPorts(_ ports: [ArtnetPacketBuilder.Port], targets: [Int: [String]]) -> [ArtnetPacketBuilder.Port] {
        ports.filter { $0.merging && (targets[$0.universe]?.contains($0.ip) ?? false) }
            .sorted { $0.universe < $1.universe }
    }

    private func describe(_ merging: [ArtnetPacketBuilder.Port]) -> String {
        merging.map { "\($0.name) (\($0.ip)) \(settings.label(wire: $0.universe))" }.joined(separator: "; ")
    }

    private func discover(_ poller: Poller) throws -> Plan {
        let nodes = settings.nodePrefix.isEmpty ? "Art-Net nodes" : "nodes named \(settings.nodePrefix)…"
        log("Looking for \(nodes)", .work)
        let wanted = settings.wireUniverses
        var found: [String: ArtnetPacketBuilder.Port] = [:]
        for _ in 0..<5 where !stopFlag.isStopped {
            for p in poller.poll(stop: stopFlag) { found["\(p.ip)/\(p.universe)"] = p }
            let have = Set(found.values.filter(isMine).map(\.universe))
            if wanted.allSatisfy(have.contains) { break }
        }
        if stopFlag.isStopped { throw FirmwareError("Stopped.") }
        let ports = Array(found.values)
        let mine = ports.filter(isMine)
        guard !mine.isEmpty else {
            throw FirmwareError("No \(nodes) answered. Check the address you're sending from and that this Mac is on their network.")
        }
        var targets: [Int: [String]] = [:]
        for p in mine where wanted.contains(p.universe) {
            if !(targets[p.universe]?.contains(p.ip) ?? false) { targets[p.universe, default: []].append(p.ip) }
        }
        let merging = mergingPorts(ports, targets: targets)
        let names = Dictionary(mine.map { ($0.ip, $0.name) }, uniquingKeysWith: { a, _ in a })
        routes(wanted.map { u in
            DMXRoute(universe: settings.label(wire: u),
                     nodes: targets[u].map { $0.map { "\(names[$0] ?? "?") (\($0))" }.joined(separator: ", ") } ?? "no node found",
                     merging: merging.contains { $0.universe == u })
        })
        let missing = wanted.filter { targets[$0] == nil }
        if !missing.isEmpty {
            throw FirmwareError("No node outputs \(missing.map(settings.label(wire:)).joined(separator: ", ")). Check the universe numbers (and the console-numbering setting) and that every node is on.")
        }
        log("Found a node for all \(wanted.count) universe\(wanted.count == 1 ? "" : "s").", .ok)
        return Plan(targets: targets, merging: merging)
    }

    // MARK: Running

    /// Discovers nodes (Art-Net) and, if `send`, sends the update. Call on a
    /// background thread.
    func run(send: Bool) {
        do {
            try settings.validate()
            var poller: Poller?
            var plan = Plan(targets: [:], merging: [])
            if settings.proto == .artnet {
                let p = try Poller(interface: settings.interface)
                poller = p
                plan = try discover(p)
                if !plan.merging.isEmpty {
                    throw FirmwareError("STOP: a node reports merging another source: \(describe(plan.merging)). Turn the other source off; it corrupts the update.")
                }
            } else {
                routes(settings.wireUniverses.map {
                    DMXRoute(universe: settings.label(wire: $0), nodes: "multicast \(SacnPacketBuilder.multicastAddress($0))", merging: false)
                })
            }
            guard send else {
                log(settings.proto == .artnet ? "No merging reported. Ready to send." : "Ready to send (sACN can't check for other sources).", .ok)
                return
            }
            try transmit(plan: plan, poller: poller)
        } catch {
            log(error.localizedDescription, error.localizedDescription == "Stopped." ? .plain : .fail)
        }
    }

    private func transmit(plan: Plan, poller: Poller?) throws {
        guard let raw = try? Data(contentsOf: firmware.bin) else { throw FirmwareError("Can't read the firmware file.") }
        guard let image = Gzip.compress(Array(raw)) else { throw FirmwareError("Couldn't compress the firmware.") }
        let id = firmware.firmwareID
        let frames = try UpdateProtocol.passFrames(image: image, model: id.model, buildID: id.buildID)
        let universes = settings.wireUniverses
        let perPass = Double(frames.count) / settings.rate
        log("Sending \(id.label) for \(firmware.board.name) boards to \(universes.count) universe\(universes.count == 1 ? "" : "s"): \(image.count / 1024) KB in \(UpdateProtocol.chunkCount(imageSize: image.count)) packets, \(settings.passes) passes, about \(Int((perPass * Double(settings.passes)).rounded())) s.", .work)

        let socket = try UDPSocket(bindIP: settings.interface?.ip, broadcast: true)
        var artnet = ArtnetPacketBuilder()
        var sacn = SacnPacketBuilder(name: "Starboard firmware update", priority: settings.priority)
        if settings.proto == .sacn { socket.setMulticast(interfaceIP: settings.interface?.ip) }

        func sendFrame(_ frame: [UInt8]) {
            for u in universes {
                switch settings.proto {
                case .artnet:
                    let packet = artnet.dmx(universe: u, slots: frame)
                    for ip in plan.targets[u] ?? [] { socket.send(packet, to: ip, port: ArtnetPacketBuilder.port) }
                case .sacn:
                    socket.send(sacn.packet(universe: u, slots: frame),
                                to: SacnPacketBuilder.multicastAddress(u), port: SacnPacketBuilder.port)
                }
            }
        }
        defer {
            if settings.proto == .sacn {
                // Stream_Terminated, so nodes drop us now instead of holding our
                // last frame until they time out.
                let blank = [UInt8](repeating: 0, count: UpdateProtocol.slots)
                for _ in 0..<3 {
                    for u in universes {
                        socket.send(sacn.packet(universe: u, slots: blank, options: 0x40),
                                    to: SacnPacketBuilder.multicastAddress(u), port: SacnPacketBuilder.port)
                    }
                }
            }
        }

        // A few seconds in, ask the nodes again: a source that was idle at the
        // pre-check, or only merging now we're sending, shows up here.
        let start = Date()
        var recheck: Date? = nil       // when the re-poll's answers are due
        var rechecked = poller == nil
        let interval = 1.0 / settings.rate
        var next = ProcessInfo.processInfo.systemUptime
        let total = frames.count * settings.passes
        for pass in 0..<settings.passes {
            for (i, frame) in frames.enumerated() {
                if stopFlag.isStopped {
                    log("Stopped. Boards only install a complete image, so nothing partial was installed.", .warn)
                    return
                }
                sendFrame(frame)
                if let poller, !rechecked {
                    if recheck == nil && Date().timeIntervalSince(start) >= 3 {
                        poller.start()
                        recheck = Date().addingTimeInterval(2.5)
                    } else if let due = recheck {
                        poller.collect()
                        if Date() >= due {
                            rechecked = true
                            let merging = mergingPorts(Array(poller.ports.values), targets: plan.targets)
                            if !merging.isEmpty {
                                log("STOPPED: merging another source: \(describe(merging)). Turn it off and send again (nothing was installed).", .fail)
                                return
                            }
                        }
                    }
                }
                next += interval
                let delay = next - ProcessInfo.processInfo.systemUptime
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                if i % 10 == 0 {
                    let done = pass * frames.count + i
                    progress(Double(done) / Double(total), "Pass \(pass + 1) of \(settings.passes)")
                }
            }
        }
        progress(1, "Done")
        log("Done. Boards that got the whole image install it, double-flash and come back in a few seconds.", .ok)
    }
}
