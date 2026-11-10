import Foundation

/// Files shared between the app (writer) and the sandboxed widget (reader).
///
/// The app is signed ad-hoc, so there is no team-prefixed App Group. Instead the
/// widget's entitlements grant it access to this one folder in the real home
/// directory (a home-relative sandbox exception).
enum SharedStore {
    static let directory: URL = realHome.appendingPathComponent("Library/Application Support/HostPulse", isDirectory: true)

    static var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    static var snapshotsURL: URL { directory.appendingPathComponent("snapshots.json") }
    static var widgetHeartbeatURL: URL { directory.appendingPathComponent("widget-heartbeat.json") }

    /// The user's home folder, also from inside the widget's sandbox container.
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? decoder.decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    static func save(_ settings: AppSettings) throws {
        try write(encoder.encode(settings), to: settingsURL)
    }

    static func loadSnapshots() -> [HostSnapshot] {
        guard let data = try? Data(contentsOf: snapshotsURL),
              let file = try? decoder.decode(SnapshotFile.self, from: data) else { return [] }
        return file.hosts
    }

    static func save(_ snapshots: [HostSnapshot]) throws {
        try write(encoder.encode(SnapshotFile(written: Date(), hosts: snapshots)), to: snapshotsURL)
    }

    /// The widget records when WidgetKit last asked it for a timeline, so the app
    /// can show how often macOS refreshes it.
    static func recordWidgetRefresh() {
        let stamp = ["refreshed": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: stamp) {
            try? write(data, to: widgetHeartbeatURL)
        }
    }

    static var widgetLogURL: URL { directory.appendingPathComponent("widget.log") }
    static var appLogURL: URL { directory.appendingPathComponent("app.log") }

    /// Small diagnostic trail of what WidgetKit asked the widget for (last 300 lines).
    static func logWidget(_ message: String) { append(message, to: widgetLogURL) }

    /// Diagnostic trail for the app (last 300 lines).
    static func log(_ message: String) { append(message, to: appLogURL) }

    private static func append(_ message: String, to url: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append("\(stamp) [\(getpid())] \(message)")
        try? write(Data((lines.suffix(300).joined(separator: "\n") + "\n").utf8), to: url)
    }

    static func lastWidgetRefresh() -> Date? {
        guard let data = try? Data(contentsOf: widgetHeartbeatURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let t = obj["refreshed"] else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private struct SnapshotFile: Codable {
        var written: Date
        var hosts: [HostSnapshot]
    }
}
