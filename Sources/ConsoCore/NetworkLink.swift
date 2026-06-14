import Foundation
import Darwin
#if canImport(CoreWLAN)
import CoreWLAN
#endif

/// A short label for the active network link (the Network card badge).
/// Uses CoreWLAN's PHY mode for Wi-Fi — no location permission needed (unlike SSID).
/// Falls back to a wired check, and finally "Offline" when no interface is up.
public enum NetworkLink {
    public static func label() -> String {
        #if canImport(CoreWLAN)
        // A Wi-Fi interface with an active PHY mode means we're on Wi-Fi and online.
        if let iface = CWWiFiClient.shared().interface() {
            switch iface.activePHYMode() {
            case .mode11ax: return "Wi-Fi 6"
            case .mode11ac: return "Wi-Fi 5"
            case .mode11n:  return "Wi-Fi 4"
            case .mode11a, .mode11b, .mode11g: return "Wi-Fi"
            case .modeNone: break        // Wi-Fi hardware present but not associated.
            @unknown default: break
            }
        }
        #endif
        // No Wi-Fi link: report a wired connection if one is up, else "Offline".
        return hasActiveWiredLink() ? "Ethernet" : "Offline"
    }

    /// True when a non-Wi-Fi, non-loopback interface is up and running (`IFF_UP` +
    /// `IFF_RUNNING`) — i.e. a live wired link. Excludes Wi-Fi (en0-style awdl/utun
    /// is also skipped by name) so this only fires for genuine wired connectivity.
    static func hasActiveWiredLink() -> Bool {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return false }
        defer { freeifaddrs(addrs) }
        let upRunning = UInt32(IFF_UP | IFF_RUNNING)
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            defer { ptr = ifa.ifa_next }
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: ifa.ifa_name)
            // Skip loopback and virtual/transient links that don't represent a real wire.
            if name.hasPrefix("lo") || name.hasPrefix("awdl") || name.hasPrefix("llw")
                || name.hasPrefix("utun") || name.hasPrefix("bridge") || name.hasPrefix("ap") {
                continue
            }
            if ifa.ifa_flags & upRunning == upRunning { return true }
        }
        return false
    }
}
