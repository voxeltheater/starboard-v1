import Darwin
import Foundation

/// An IPv4 address on this Mac.
struct NetworkInterface: Hashable, Identifiable {
    let name: String       // en0
    let ip: String
    let broadcast: String  // from the netmask
    var id: String { ip }
    var label: String { "\(ip)  (\(name))" }

    static func all() -> [NetworkInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var out: [NetworkInterface] = []
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let maskPtr = ifa.pointee.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            out.append(NetworkInterface(name: String(cString: ifa.pointee.ifa_name),
                                        ip: ipString(ip), broadcast: ipString(ip | ~mask)))
        }
        return out
    }

    /// in_addr (network byte order) -> dotted quad.
    static func ipString(_ s: in_addr_t) -> String {
        var a = in_addr(s_addr: s)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }
}

/// A plain BSD UDP socket. Sends are best effort, like any DMX-over-IP sender.
final class UDPSocket {
    private let fd: Int32
    private var addresses: [String: sockaddr_in] = [:]

    /// - bindIP: this Mac's address to send from (picks the network), or nil.
    /// - port: local port; 0 for any.
    /// - shared: allow other apps (a lighting console) to hold the same port.
    init(bindIP: String?, port: UInt16 = 0, shared: Bool = false, broadcast: Bool = false) throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw FirmwareError("Couldn't open a network socket.") }
        var one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        if shared {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, size)
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, size)
        }
        if broadcast { setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, size) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, size)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        if bindIP != nil || port != 0 {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            a.sin_addr.s_addr = INADDR_ANY
            if let bindIP { inet_pton(AF_INET, bindIP, &a.sin_addr) }
            let r = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if r != 0 {
                let err = String(cString: strerror(errno))
                close(fd)
                throw FirmwareError(bindIP != nil && port == 0
                    ? "Can't send from \(bindIP!): \(err). Pick this Mac's address on the lighting network."
                    : "Can't listen on UDP port \(port): \(err).")
            }
        }
    }

    deinit { close(fd) }

    /// Send multicast out of the interface with this address (not whatever
    /// the OS picks, which on a laptop is often Wi-Fi).
    func setMulticast(interfaceIP: String?, ttl: UInt8 = 8) {
        var t = ttl
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &t, socklen_t(MemoryLayout<UInt8>.size))
        if let interfaceIP {
            var a = in_addr()
            inet_pton(AF_INET, interfaceIP, &a)
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &a, socklen_t(MemoryLayout<in_addr>.size))
        }
    }

    @discardableResult
    func send(_ bytes: [UInt8], to ip: String, port: UInt16) -> Bool {
        let key = "\(ip):\(port)"
        var a: sockaddr_in
        if let cached = addresses[key] {
            a = cached
        } else {
            a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            guard inet_pton(AF_INET, ip, &a.sin_addr) == 1 else { return false }
            addresses[key] = a
        }
        let n = bytes.withUnsafeBufferPointer { buf in
            withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return n == bytes.count
    }

    /// Next waiting datagram, or nil if none.
    func receive() -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = recv(fd, &buf, buf.count, 0)
        return n > 0 ? Array(buf[0..<n]) : nil
    }
}
