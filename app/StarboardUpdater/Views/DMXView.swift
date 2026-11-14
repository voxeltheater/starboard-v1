import SwiftUI

struct DMXView: View {
    @EnvironmentObject private var model: AppModel

    // Remembered between launches. Defaults suit the installed rig.
    @AppStorage("dmx.protocol") private var proto = DMXProtocol.artnet.rawValue
    @AppStorage("dmx.nodePrefix") private var nodePrefix = "STARNET"
    @AppStorage("dmx.universes") private var universes = "40-71"
    @AppStorage("dmx.consoleNumbering") private var consoleNumbering = true
    @AppStorage("dmx.interface") private var interfaceIP = ""
    @AppStorage("dmx.passes") private var passes = 5

    @State private var interfaces = NetworkInterface.all()
    @State private var confirming = false
    @State private var inputError: String?

    private var protocolValue: DMXProtocol { DMXProtocol(rawValue: proto) ?? .artnet }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsForm
            buttons
            if let progress = model.progress {
                ProgressView(value: progress) {
                    Text(model.progressLabel.isEmpty ? "Starting…" : model.progressLabel)
                        .font(.caption)
                }
            }
            if !model.routes.isEmpty { routeTable }
            LogView(lines: model.dmxLog,
                    placeholder: "Check Nodes shows which node gets each universe and sends nothing. Send Update updates every \(model.board.name) board on these universes at once.")
        }
        .padding(4)
        .onAppear(perform: pickDefaultInterface)
        .alert("Are all other DMX sources off?", isPresented: $confirming) {
            Button("Send Update") { start(send: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Consoles and every other Art-Net or sACN source on these universes must be off. A second source corrupts the update, and boards just stay on their current firmware.\n\nSending \(model.firmware?.firmwareID.label ?? "") to \(model.board.name) boards on universes \(universes).")
        }
    }

    private var settingsForm: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Protocol").gridColumnAlignment(.trailing)
                Picker("Protocol", selection: $proto) {
                    ForEach(DMXProtocol.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
            if protocolValue == .artnet {
                GridRow {
                    Text("Node names")
                    HStack {
                        TextField("any", text: $nodePrefix).frame(width: 140)
                        Text("Only nodes whose name starts with this").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                Text("Universes")
                VStack(alignment: .leading, spacing: 4) {
                    TextField("40-71", text: $universes).frame(width: 140)
                    if protocolValue == .artnet {
                        Toggle("Numbered as on the console (sACN), sent as Art-Net one lower", isOn: $consoleNumbering)
                            .font(.caption)
                    }
                }
            }
            GridRow {
                Text("Send from")
                HStack {
                    Picker("Send from", selection: $interfaceIP) {
                        if interfaces.isEmpty { Text("No network").tag("") }
                        ForEach(interfaces) { Text($0.label).tag($0.ip) }
                        if !interfaceIP.isEmpty && !interfaces.contains(where: { $0.ip == interfaceIP }) {
                            Text("\(interfaceIP) (not connected)").tag(interfaceIP)
                        }
                    }
                    .labelsHidden().frame(width: 260)
                    Button {
                        interfaces = NetworkInterface.all()
                        pickDefaultInterface()
                    } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh this Mac's network addresses")
                }
            }
            GridRow {
                Text("Passes")
                Stepper("\(passes)  (repeats fill in what boards missed)", value: $passes, in: 1...20)
            }
        }
        .disabled(model.busy)
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            if model.dmxRunning {
                Button("Stop", role: .cancel) { model.stopDMX() }
                    .keyboardShortcut(.cancelAction)
                ProgressView().controlSize(.small)
            } else {
                Button("Check Nodes") { start(send: false) }
                    .disabled(model.firmware == nil || model.firmware?.legacy == true || model.busy)
                Button("Send Update…") {
                    if settings() != nil { confirming = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.firmware == nil || model.firmware?.legacy == true || model.busy)
            }
            if model.firmware?.legacy == true {
                Text("Pre-1.3 firmware installs over USB only.").font(.caption).foregroundStyle(.secondary)
            }
            if let inputError {
                Text(inputError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var routeTable: some View {
        Table(model.routes) {
            TableColumn("Universe", value: \.universe).width(min: 150, ideal: 170)
            TableColumn("Node") { route in
                Text(route.nodes).foregroundStyle(route.nodes == "no node found" ? .red : .primary)
            }
            TableColumn("Merging") { route in
                Text(route.merging ? "⚠️ another source" : "—")
                    .foregroundStyle(route.merging ? .red : .secondary)
            }
            .width(min: 90, ideal: 120)
        }
        .frame(height: 150)
    }

    private func settings() -> DMXSettings? {
        guard let list = parseUniverses(universes) else {
            inputError = "Universes: use a range or list, like 40-71 or 1,2,5-8."
            return nil
        }
        let s = DMXSettings(proto: protocolValue, nodePrefix: nodePrefix, universes: list,
                            consoleNumbering: consoleNumbering,
                            interface: interfaces.first { $0.ip == interfaceIP }, passes: passes)
        do {
            try s.validate()
        } catch {
            inputError = error.localizedDescription
            return nil
        }
        inputError = nil
        return s
    }

    private func start(send: Bool) {
        guard let s = settings() else { return }
        model.runDMX(s, send: send)
    }

    /// Keep the saved choice if it's connected; otherwise prefer the
    /// lighting network (192.168.5.x), then anything that isn't link-local.
    private func pickDefaultInterface() {
        if interfaces.contains(where: { $0.ip == interfaceIP }) { return }
        let pick = interfaces.first { $0.ip.hasPrefix("192.168.5.") }
            ?? interfaces.first { !$0.ip.hasPrefix("169.254.") }
            ?? interfaces.first
        if let pick { interfaceIP = pick.ip }
    }
}
