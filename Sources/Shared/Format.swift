import Foundation
import SwiftUI

enum Fmt {
    static let dash = "–"

    static func percent(_ v: Double?) -> String {
        guard let v else { return dash }
        let fractional = abs(v - v.rounded()) >= 0.05
        return v < 10 && v > 0 && fractional ? String(format: "%.1f%%", v) : String(format: "%.0f%%", v)
    }

    static func temp(_ c: Double?) -> String {
        guard let c else { return dash }
        return String(format: "%.0f°", c)
    }

    /// 1.5 GB, 820 MB, 12 KB
    static func bytes(_ v: Double?, digits: Int = 1) -> String {
        guard let v, v >= 0 else { return dash }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = v
        var i = 0
        while value >= 1024 && i < units.count - 1 {
            value /= 1024
            i += 1
        }
        if i <= 2 { return String(format: "%.0f %@", value, units[i]) }
        return String(format: "%.\(value >= 100 ? 0 : digits)f %@", value, units[i])
    }

    /// "6.0 / 16 GB". Memory uses binary units like Activity Monitor; disks use
    /// decimal units (`decimal: true`) like Finder.
    static func usage(_ used: Double?, of total: Double?, decimal: Bool = false) -> String {
        guard let used, let total else { return dash }
        let gb = decimal ? 1e9 : 1_073_741_824.0
        let tb = decimal ? 1e12 : 1024 * gb
        if total >= tb {
            return String(format: "%.1f / %.1f TB", used / tb, total / tb)
        }
        let u = used / gb, t = total / gb
        let totalText = t >= 100 || abs(t - t.rounded()) < 0.05 ? String(format: "%.0f", t) : String(format: "%.1f", t)
        return String(format: u >= 100 ? "%.0f / %@ GB" : "%.1f / %@ GB", u, totalText)
    }

    static func rate(_ v: Double?) -> String {
        guard let v, v >= 0 else { return dash }
        if v < 1024 { return String(format: "%.0f B/s", v) }
        if v < 1024 * 1024 { return String(format: "%.0f KB/s", v / 1024) }
        return String(format: "%.1f MB/s", v / 1024 / 1024)
    }

    static func uptime(_ s: Double?) -> String {
        guard let s, s > 0 else { return dash }
        let m = Int(s) / 60, h = m / 60, d = h / 24
        if d > 0 { return "\(d)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m % 60)m" }
        return "\(m)m"
    }

    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    static func rpm(_ v: Double?) -> String {
        guard let v else { return dash }
        return v < 1 ? "off" : String(format: "%.0f rpm", v)
    }

    static func watts(_ v: Double?) -> String {
        guard let v else { return dash }
        return v < 10 ? String(format: "%.1f W", v) : String(format: "%.0f W", v)
    }
}

enum Signal {
    /// 0...4 bars from RSSI in dBm.
    static func bars(_ rssi: Int?) -> Int {
        guard let r = rssi, r != 0 else { return 0 }
        switch r {
        case (-55)...: return 4
        case (-65)...: return 3
        case (-75)...: return 2
        case (-85)...: return 1
        default: return 0
        }
    }

    static func quality(_ rssi: Int?) -> String {
        switch bars(rssi) {
        case 4: return "Excellent"
        case 3: return "Good"
        case 2: return "Fair"
        case 1: return "Weak"
        default: return rssi == nil ? "" : "Very weak"
        }
    }
}

enum Theme {
    static let cpu = Color(red: 0.30, green: 0.60, blue: 1.00)
    static let memory = Color(red: 0.68, green: 0.45, blue: 1.00)
    static let memoryWired = Color(red: 0.95, green: 0.55, blue: 0.30)
    static let memoryCompressed = Color(red: 0.95, green: 0.80, blue: 0.30)
    static let gpu = Color(red: 0.20, green: 0.80, blue: 0.75)
    static let disk = Color(red: 0.55, green: 0.65, blue: 0.80)
    static let good = Color(red: 0.25, green: 0.80, blue: 0.45)
    static let warn = Color(red: 1.00, green: 0.66, blue: 0.20)
    static let bad = Color(red: 1.00, green: 0.33, blue: 0.33)

    /// The metric's own color until it gets high.
    static func level(_ fraction: Double?, base: Color) -> Color {
        guard let f = fraction else { return base }
        if f >= 0.9 { return bad }
        if f >= 0.75 { return warn }
        return base
    }

    static func temperature(_ c: Double?) -> Color {
        guard let c else { return .secondary }
        if c >= 85 { return bad }
        if c >= 70 { return warn }
        return good
    }

    static func signal(_ rssi: Int?) -> Color {
        switch Signal.bars(rssi) {
        case 3...: return good
        case 2: return warn
        default: return bad
        }
    }

    static func pressure(_ p: String?) -> Color {
        switch p {
        case "critical": return bad
        case "warning": return warn
        default: return good
        }
    }

    static func status(_ kind: HostStatus.Kind) -> Color {
        switch kind {
        case .live: return good
        case .stale: return warn
        case .offline: return bad
        case .waiting: return .secondary
        }
    }
}
