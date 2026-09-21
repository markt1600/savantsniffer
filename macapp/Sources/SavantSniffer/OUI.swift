import Foundation

enum OUI {
    // Lutron Electronics registered prefixes. Matching also falls back to a vendor
    // string containing "lutron", so an unlisted prefix is still caught by name.
    static let lutron: Set<String> = ["0016E1", "001BB1", "0007E0"]

    static let apple: Set<String> = [
        "F0189E","3C0754","A45E60","8C8590","C82A14","D0817A","8C7C92","A8BBCF",
        "F0DBF8","AC87A3","E0F847","F86214","40A6D9","7CD1C3","68967B","D89E3F",
        "B8E856","38C986","88665A","34363B"
    ]

    /// First three octets, zero-padded and uppercased. macOS `arp -a` prints
    /// octets without leading zeros ("0:16:e1:…"), so each octet is padded.
    static func normalize(_ mac: String) -> String {
        let octets = mac.split(whereSeparator: { $0 == ":" || $0 == "-" })
            .map { String($0).uppercased() }
            .map { $0.count == 1 ? "0" + $0 : $0 }
        if octets.count >= 3 { return octets.prefix(3).joined() }
        // fallback for separator-less input
        let hex = mac.uppercased().filter { $0.isHexDigit }
        return String(hex.prefix(6))
    }

    static func classify(mac: String, vendorHint: String = "") -> String {
        let oui = normalize(mac)
        let hint = vendorHint.lowercased()
        if lutron.contains(oui) || hint.contains("lutron") { return "Lutron" }
        if apple.contains(oui) || hint.contains("apple") { return "Apple" }
        return vendorHint.isEmpty ? "unknown" : vendorHint
    }
}
