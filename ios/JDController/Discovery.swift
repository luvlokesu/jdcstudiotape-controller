import Foundation
import Darwin

/// Busca el PC con JDCStudioTape: pregunta "JDC-CONTROLLER?" por UDP (puerto 8767) a una IP concreta o a cada dirección de la
/// red /24 del móvil (iOS no deja hacer broadcast sin un permiso especial de Apple; preguntar una a una sí, con el permiso de
/// «Red local»). El PC responde con su nombre, puertos y huella de la CA (Capture/PhoneServer.cs › StartDiscovery).
enum Discovery {
    static let port: UInt16 = 8767
    private static let probe = Array("JDC-CONTROLLER?".utf8)

    static func find(ip: String?, done: @escaping ([[String: Any]]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = run(targets: ip.map { [$0] } ?? sweepTargets())
            DispatchQueue.main.async { done(list) }
        }
    }

    private static func run(targets: [String]) -> [[String: Any]] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        func send(_ ip: String) {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            guard inet_pton(AF_INET, ip, &a.sin_addr) == 1 else { return }
            _ = withUnsafePointer(to: &a) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, probe, probe.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        var out: [[String: Any]] = []
        var seenIp = Set<String>(), seenCa = Set<String>()
        let end = Date().addingTimeInterval(1.8)
        var sends = 0, nextSend = Date.distantPast
        let cap = 4096
        var buf = [UInt8](repeating: 0, count: cap)
        while Date() < end {
            if sends < 3 && Date() >= nextSend { targets.forEach(send); sends += 1; nextSend = Date().addingTimeInterval(0.5) }
            var from = sockaddr_in(), len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, raw.baseAddress, cap, 0, $0, &len) }
                }
            }
            guard n > 0 else { continue }
            var addr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &addr, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: addr)
            guard !seenIp.contains(ip),
                  var o = (try? JSONSerialization.jsonObject(with: Data(buf[0..<n]))) as? [String: Any],
                  o["t"] as? String == "jdc" else { continue }
            seenIp.insert(ip)
            if let ca = o["caSha256"] as? String, !ca.isEmpty, !seenCa.insert(ca).inserted { continue }
            o["ip"] = ip
            out.append(o)
            if targets.count == 1 { break }
        }
        return out
    }

    /// Las 254 direcciones de la red /24 de la Wi-Fi del móvil (en0), sin la propia.
    private static func sweepTargets() -> [String] {
        var list: [String] = []
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let first = ifa else { return list }
        defer { freeifaddrs(ifa) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  String(cString: i.ifa_name).hasPrefix("en") else { continue }
            let me = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let base = me & 0xFFFF_FF00
            for h in 1...254 where base | UInt32(h) != me {
                let v = base | UInt32(h)
                list.append("\(v >> 24 & 255).\(v >> 16 & 255).\(v >> 8 & 255).\(v & 255)")
            }
        }
        return list
    }
}
