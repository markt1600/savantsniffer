import Foundation

/// MAC vendor lookup backed by the full IEEE MA-L registry (bundled as oui.tsv).
enum OUI {
    static let table: [String: String] = {
        guard let url = Bundle.module.url(forResource: "oui", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var t: [String: String] = [:]
        t.reserveCapacity(41_000)
        for line in text.split(separator: "\n") {
            if let tab = line.firstIndex(of: "\t") {
                t[String(line[line.startIndex..<tab])] = String(line[line.index(after: tab)...])
            }
        }
        return t
    }()

    /// First three octets, zero-padded and uppercased. macOS `arp -a` prints
    /// octets without leading zeros ("0:f:e7:…"), so each octet is padded.
    static func normalize(_ mac: String) -> String {
        let octets = mac.split(whereSeparator: { $0 == ":" || $0 == "-" })
            .map { String($0).uppercased() }
            .map { $0.count == 1 ? "0" + $0 : $0 }
        if octets.count >= 3 { return octets.prefix(3).joined() }
        let hex = mac.uppercased().filter { $0.isHexDigit }
        return String(hex.prefix(6))
    }

    /// Randomized "private" Wi-Fi addresses (phones, laptops) set the
    /// locally-administered bit in the first octet.
    static func isLocallyAdministered(_ mac: String) -> Bool {
        let first = normalize(mac).prefix(2)
        guard let v = UInt8(first, radix: 16) else { return false }
        return (v & 0x02) != 0
    }

    static func vendor(for mac: String) -> String? {
        table[normalize(mac)]
    }

    /// Coarse class used for sorting and colouring in Discover.
    static func classify(mac: String, vendorHint: String = "") -> String {
        if isLocallyAdministered(mac) { return "private" }
        let name = (vendorHint.isEmpty ? (vendor(for: mac) ?? "") : vendorHint).lowercased()
        if name.contains("lutron") { return "Lutron" }
        if name.contains("savant") { return "Savant" }
        if name.contains("apple") { return "Apple" }
        if name.contains("ubiquiti") { return "Ubiquiti" }
        if name.contains("d&m") || name.contains("denon") || name.contains("marantz") { return "Denon/Marantz" }
        if name.contains("sonos") { return "Sonos" }
        if name.contains("philips lighting") || name.contains("signify") { return "Hue" }
        if name.contains("espressif") { return "IoT" }
        return name.isEmpty ? "unknown" : "other"
    }
}
