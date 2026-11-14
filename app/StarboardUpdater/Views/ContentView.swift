import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = "usb"

    var body: some View {
        VStack(spacing: 0) {
            FirmwareHeader()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            Divider()
            TabView(selection: $tab) {
                USBView()
                    .tabItem { Label("USB", systemImage: "cable.connector") }
                    .tag("usb")
                DMXView()
                    .tabItem { Label("DMX", systemImage: "network") }
                    .tag("dmx")
            }
            .padding(12)
        }
        .frame(minWidth: 600, minHeight: 600)
        .alert("Starboard Updater", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

/// Board type and firmware release: shared by both tabs.
struct FirmwareHeader: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Board").gridColumnAlignment(.trailing)
                Picker("Board", selection: $model.board) {
                    ForEach(BoardType.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
            }
            GridRow {
                Text("Firmware")
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                    Picker("Firmware", selection: $model.firmwareKey) {
                        if model.releases.isEmpty && model.custom == nil {
                            Text("No \(model.board.name) releases").tag("")
                        }
                        ForEach(model.releases) { Text($0.title).tag($0.id) }
                        if let custom = model.custom {
                            Divider()
                            Text(custom.title).tag(custom.id)
                        }
                        Divider()
                        Text("Other build…").tag(AppModel.otherBuildTag)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    .onChange(of: model.firmwareKey) { old, new in
                        if new == AppModel.otherBuildTag && !model.chooseOtherBuild() {
                            model.firmwareKey = old
                        }
                    }
                    Button { model.refreshReleases() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Check GitHub for new releases")
                    if model.refreshing { ProgressView().controlSize(.small) }
                    }
                    detail
                }
            }
        }
        .disabled(model.busy)
    }

    @ViewBuilder private var detail: some View {
        if let fw = model.firmware {
            Text(fw.firmwareID.raw + (fw.isCustom ? "  ·  " + fw.bin.deletingLastPathComponent().path : ""))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else if model.releases.isEmpty && !model.refreshing {
            Text("No \(model.board.name) releases downloaded. Connect to the internet and press ↻, or choose Other build.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !model.releaseStatus.isEmpty {
            Text(model.releaseStatus).font(.caption).foregroundStyle(.secondary)
        }
        ForEach(model.problems, id: \.self) {
            Text("⚠️ " + $0).font(.caption).foregroundStyle(.orange)
        }
    }
}

/// A scrolling log that follows new lines.
struct LogView: View {
    let lines: [LogLine]
    var placeholder = ""

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if lines.isEmpty && !placeholder.isEmpty {
                        Text(placeholder).foregroundStyle(.secondary).padding(.top, 2)
                    }
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.timeFormat.string(from: line.time))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Text(line.style.emoji.isEmpty ? line.text : line.style.emoji + " " + line.text)
                                .foregroundStyle(color(line.style))
                                .fontWeight(bold(line.style) ? .semibold : .regular)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(line.id)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            .onChange(of: lines.last?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }

    private func color(_ style: LogStyle) -> Color {
        switch style {
        case .ok: return .green
        case .current: return .teal
        case .fail, .refused: return .red
        case .warn: return .orange
        case .dim: return .secondary
        case .plain, .work, .ready: return .primary
        }
    }

    private func bold(_ style: LogStyle) -> Bool {
        [.ok, .fail, .refused, .warn, .ready].contains(style)
    }
}
