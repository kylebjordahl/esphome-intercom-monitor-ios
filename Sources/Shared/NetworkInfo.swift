import Foundation
import Darwin

/// Returns the IPv4 address of the primary Wi-Fi interface (en0), or nil if unavailable.
func localWiFiIPAddress() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    defer { freeifaddrs(ifaddr) }

    var ptr = ifaddr
    while let current = ptr {
        defer { ptr = current.pointee.ifa_next }
        let ifa = current.pointee
        guard
            ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET),
            String(cString: ifa.ifa_name) == "en0"
        else { continue }

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                    &hostname, socklen_t(hostname.count),
                    nil, 0, NI_NUMERICHOST)
        return String(cString: hostname)
    }
    return nil
}
