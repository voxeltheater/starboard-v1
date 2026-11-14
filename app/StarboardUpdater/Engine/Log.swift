import Foundation

/// How a log line is shown. Mirrors the styles of the old tools/usb_flash.py.
enum LogStyle {
    case plain, ok, current, fail, refused, warn, work, ready, dim

    var emoji: String {
        switch self {
        case .ok: return "✅"
        case .current: return "👍"
        case .fail: return "❌"
        case .refused: return "🚫"
        case .warn: return "⚠️"
        case .work: return "⚡"
        case .ready: return "🚀"
        case .plain, .dim: return ""
        }
    }

    /// Worth a sound: the user may be across the room plugging boards in.
    var alerts: Bool { self == .ok || self == .fail || self == .refused || self == .warn }
}

struct LogLine: Identifiable {
    let id = UUID()
    let time = Date()
    let text: String
    let style: LogStyle
}

/// Thread-safe stop flag for the background jobs.
final class StopFlag {
    private let lock = NSLock()
    private var stopped = false
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// Sleeps up to `seconds`, waking early if stopped. Returns false if stopped.
    @discardableResult
    func sleep(_ seconds: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if isStopped { return false }
            Thread.sleep(forTimeInterval: min(0.05, max(0, end.timeIntervalSinceNow)))
        }
        return !isStopped
    }
}
