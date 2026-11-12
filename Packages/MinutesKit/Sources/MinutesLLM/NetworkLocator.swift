// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// Tells where a server is from its address, so Minutes can say when a transcript would leave the
/// Mac or the user's network.
public enum NetworkLocator {
    /// Where `url`'s host is. A name is resolved and every address it has is checked, the farthest
    /// counting. Nil when the name doesn't resolve and doesn't look local.
    @concurrent
    public static func location(of url: URL) async -> NetworkLocation? {
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            return nil
        }
        return location(ofHost: host)
    }

    static func location(ofHost host: String) -> NetworkLocation? {
        let host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        if let literal = location(ofAddress: host) {
            return literal
        }
        // Reserved for this Mac, so never looked up.
        if host == "localhost" || host.hasSuffix(".localhost") {
            return .thisMac
        }
        let resolved = addresses(of: host).compactMap(location(ofAddress:))
        if let farthest = resolved.max() {
            return farthest
        }
        // A server that's off right now, like a Mac asleep on the network.
        let localSuffixes = [".local", ".lan", ".home.arpa", ".internal"]
        return localSuffixes.contains { host.hasSuffix($0) } ? .localNetwork : nil
    }

    /// Where an IPv4 or IPv6 address is, or nil when `text` isn't one.
    public static func location(ofAddress text: String) -> NetworkLocation? {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, text, &ipv4) == 1 {
            return location(ipv4: withUnsafeBytes(of: ipv4.s_addr) { Array($0) })
        }
        // Without a zone, like `%en0`, which `inet_pton` doesn't read.
        let unscoped = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, unscoped, &ipv6) == 1 {
            return location(ipv6: withUnsafeBytes(of: ipv6) { Array($0) })
        }
        return nil
    }

    /// `bytes` in network order.
    static func location(ipv4 bytes: [UInt8]) -> NetworkLocation {
        let (first, second) = (bytes[0], bytes[1])
        switch first {
        // Loopback, and 0.0.0.0, which reaches this Mac too.
        case 127, 0:
            return .thisMac
        case 10:
            return .localNetwork
        // 172.16/12, 192.168/16 and link-local 169.254/16.
        case 172 where (16 ... 31).contains(second), 192 where second == 168, 169 where second == 254:
            return .localNetwork
        // 100.64/10: carrier-grade NAT, which Tailscale uses for its own network.
        case 100 where (64 ... 127).contains(second):
            return .localNetwork
        default:
            return .internet
        }
    }

    static func location(ipv6 bytes: [UInt8]) -> NetworkLocation {
        if bytes == [UInt8](repeating: 0, count: 15) + [1] || bytes == [UInt8](repeating: 0, count: 16) {
            return .thisMac
        }
        // An IPv4 address written as IPv6, `::ffff:a.b.c.d`.
        if bytes[..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return location(ipv4: Array(bytes[12...]))
        }
        // Unique local fc00::/7 and link-local fe80::/10.
        if bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) {
            return .localNetwork
        }
        return .internet
    }

    /// Every address `host` resolves to, as text. Blocks while it asks, so it's only called off the
    /// main actor.
    private static func addresses(of host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else {
            return []
        }
        defer {
            freeaddrinfo(list)
        }
        var found: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &name, socklen_t(name.count),
                                     nil, 0, NI_NUMERICHOST)
            let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            if status == 0, let text = String(bytes: bytes, encoding: .utf8) {
                found.append(text)
            }
        }
        return found
    }
}
