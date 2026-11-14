import AppKit
import SwiftUI

/// App state. Jobs run on background threads and report back on the main
/// thread.
final class AppModel: ObservableObject {
    static let otherBuildTag = "other"

    @Published var board: BoardType {
        didSet {
            guard board != oldValue else { return }
            UserDefaults.standard.set(board.rawValue, forKey: "board")
            custom = nil
            reloadFirmware()
        }
    }
    @Published private(set) var releases: [Firmware] = []
    @Published private(set) var problems: [String] = []
    /// A release's id, the custom build's id, or `otherBuildTag`.
    @Published var firmwareKey = ""
    @Published private(set) var custom: Firmware?
    @Published var alertMessage: String?

    @Published private(set) var usbRunning = false
    @Published private(set) var usbLog: [LogLine] = []
    @Published private(set) var usbFlashed = 0
    private var usbJob: USBFlashJob?

    @Published private(set) var dmxRunning = false
    @Published private(set) var dmxLog: [LogLine] = []
    @Published private(set) var routes: [DMXRoute] = []
    @Published private(set) var progress: Double?
    @Published private(set) var progressLabel = ""
    private var dmxJob: DMXUpdateJob?

    init() {
        board = BoardType(rawValue: UserDefaults.standard.integer(forKey: "board")) ?? .rgb12
        reloadFirmware()
    }

    var busy: Bool { usbRunning || dmxRunning }

    var firmware: Firmware? {
        if let custom, firmwareKey == custom.id { return custom }
        return releases.first { $0.id == firmwareKey }
    }

    func reloadFirmware() {
        let found = FirmwareLibrary.releases(for: board)
        releases = found.releases
        problems = found.problems
        firmwareKey = releases.first?.id ?? ""
    }

    /// Asks for a build folder or file; returns false if cancelled or invalid.
    func chooseOtherBuild() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose a \(board.name) build"
        panel.message = "Pick a firmware .uf2 or .bin (its partner must be next to it), or a build folder such as .pio/build/\(board.fileStem)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.init(filenameExtension: "uf2")!, .init(filenameExtension: "bin")!, .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let fw = try Firmware.custom(at: url, board: board)
            custom = fw
            firmwareKey = fw.id
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    // MARK: USB

    func startUSB() {
        guard let fw = firmware, !busy else { return }
        usbLog = []
        usbFlashed = 0
        usbRunning = true
        let job = USBFlashJob(
            firmware: fw,
            log: { [weak self] text, style in
                DispatchQueue.main.async { self?.append(text, style, usb: true) }
            },
            flashed: { [weak self] in
                DispatchQueue.main.async { self?.usbFlashed += 1 }
            })
        usbJob = job
        Thread {
            job.run()
            DispatchQueue.main.async { [weak self] in
                self?.usbRunning = false
                self?.usbJob = nil
            }
        }.start()
    }

    func stopUSB() { usbJob?.stop() }

    // MARK: DMX

    func runDMX(_ settings: DMXSettings, send: Bool) {
        guard let fw = firmware, !busy else { return }
        dmxLog = []
        routes = []
        progress = send ? 0 : nil
        progressLabel = ""
        dmxRunning = true
        let job = DMXUpdateJob(
            settings: settings, firmware: fw,
            log: { [weak self] text, style in
                DispatchQueue.main.async { self?.append(text, style, usb: false) }
            },
            routes: { [weak self] routes in
                DispatchQueue.main.async { self?.routes = routes }
            },
            progress: { [weak self] fraction, label in
                DispatchQueue.main.async {
                    self?.progress = fraction
                    self?.progressLabel = label
                }
            })
        dmxJob = job
        Thread {
            job.run(send: send)
            DispatchQueue.main.async { [weak self] in
                self?.dmxRunning = false
                self?.dmxJob = nil
            }
        }.start()
    }

    func stopDMX() { dmxJob?.stop() }

    func stopAll() {
        usbJob?.stop()
        dmxJob?.stop()
    }

    private func append(_ text: String, _ style: LogStyle, usb: Bool) {
        let line = LogLine(text: text, style: style)
        if usb {
            usbLog.append(line)
            if usbLog.count > 500 { usbLog.removeFirst(usbLog.count - 500) }
            // Boards get plugged in away from the screen, so make results audible.
            if style.alerts { NSSound(named: style == .ok ? "Glass" : "Basso")?.play() }
        } else {
            dmxLog.append(line)
            if dmxLog.count > 500 { dmxLog.removeFirst(dmxLog.count - 500) }
        }
    }
}
