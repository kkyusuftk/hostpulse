import Foundation

/// A machine HostPulse watches over SSH.
struct HostConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Name shown in the widget and the menu.
    var name: String
    /// SSH destination: an alias from ~/.ssh/config or user@host.
    var target: String
    var port: Int?
    var identityFile = ""
    /// Extra ssh arguments, e.g. "-J bastion".
    var extraArguments = ""
    /// Copy the small sensor helper to remote Macs. It provides temperatures,
    /// fans, power, per-core load and Wi-Fi details.
    var installHelper = true
    var enabled = true

    init(name: String, target: String) {
        self.name = name
        self.target = target
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        extraArguments = try c.decodeIfPresent(String.self, forKey: .extraArguments) ?? ""
        installHelper = try c.decodeIfPresent(Bool.self, forKey: .installHelper) ?? true
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct AppSettings: Codable, Equatable {
    var hosts: [HostConfig] = []
    /// Seconds between polls of each host.
    var pollInterval: Double = 10
    /// Host shown by the single-host widget and in the menu bar. Defaults to the first host.
    var primaryHostID: UUID?
    var showMenuBarStats = true
    var showDesktopWidget = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try c.decodeIfPresent([HostConfig].self, forKey: .hosts) ?? []
        pollInterval = try c.decodeIfPresent(Double.self, forKey: .pollInterval) ?? 10
        primaryHostID = try c.decodeIfPresent(UUID.self, forKey: .primaryHostID)
        showMenuBarStats = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarStats) ?? true
        showDesktopWidget = try c.decodeIfPresent(Bool.self, forKey: .showDesktopWidget) ?? false
    }

    /// Hosts to poll: enabled and with a destination filled in.
    var enabledHosts: [HostConfig] {
        hosts.filter { $0.enabled && !$0.target.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var primaryHost: HostConfig? {
        enabledHosts.first { $0.id == primaryHostID } ?? enabledHosts.first
    }
}

enum HelperStatus: String, Codable {
    case notNeeded, running, missing, installing, failed, disabled
}

struct Fan: Codable, Equatable {
    var rpm: Double
    var min: Double
    var max: Double
}

struct WiFi: Codable, Equatable {
    var interface: String?
    var poweredOn: Bool?
    var ssid: String?
    var rssi: Int?
    var noise: Int?
    var txRate: Double?
    var channel: Int?
    var band: String?
    var standard: String?
}

struct ProcessSample: Codable, Equatable, Identifiable {
    var pid: Int
    var name: String
    /// Percent of one core, like Activity Monitor and top.
    var cpu: Double
    /// Resident memory in bytes (0 when unknown).
    var memory: Double
    var id: Int { pid }
}

/// One reading of a remote machine. Byte values are in bytes, rates in bytes/s.
struct Metrics: Codable, Equatable {
    var os = ""
    var osName: String?
    var hostname: String?
    var model: String?
    var modelID: String?
    var chip: String?
    var cpuModel: String?
    var uptime: Double?

    var cpuUsage: Double?
    var cpuUser: Double?
    var cpuSystem: Double?
    var cores: [Double] = []
    var coreKinds = ""
    var coreCount: Int?
    var performanceCores: Int?
    var efficiencyCores: Int?
    var load: [Double] = []

    var memoryTotal: Double?
    var memoryUsed: Double?
    var memoryApp: Double?
    var memoryWired: Double?
    var memoryCompressed: Double?
    var memoryCached: Double?
    var memoryPressure: String?
    var swapTotal: Double?
    var swapUsed: Double?

    var gpuUsage: Double?

    var cpuTemp: Double?
    var cpuTempMax: Double?
    var gpuTemp: Double?
    var ssdTemp: Double?
    var hottestTemp: Double?
    var hottestSensor: String?
    var thermalState: String?
    var fans: [Fan] = []
    var systemPower: Double?

    var wifi: WiFi?
    var networkInterface: String?
    var networkPort: String?
    var ipAddress: String?
    var rxBytes: Double?
    var txBytes: Double?
    var rxRate: Double?
    var txRate: Double?

    var diskTotal: Double?
    var diskUsed: Double?

    var processes: [ProcessSample] = []
    var helper: HelperStatus = .notNeeded
    var helperMessage: String?
}

extension Metrics {
    var cpuFraction: Double? { cpuUsage.map { min(max($0 / 100, 0), 1) } }

    var memoryFraction: Double? {
        guard let total = memoryTotal, total > 0, let used = memoryUsed else { return nil }
        return min(max(used / total, 0), 1)
    }

    var diskFraction: Double? {
        guard let total = diskTotal, total > 0, let used = diskUsed else { return nil }
        return min(max(used / total, 0), 1)
    }

    var swapFraction: Double? {
        guard let total = swapTotal, total > 0, let used = swapUsed else { return nil }
        return used / total
    }

    /// True when the default route goes over Wi-Fi.
    var isOnWiFi: Bool {
        if networkPort == "Wi-Fi" { return true }
        if let iface = wifi?.interface, iface == networkInterface { return true }
        return false
    }

    var connectedWiFi: WiFi? {
        guard let w = wifi, let rssi = w.rssi, rssi != 0 else { return nil }
        return w
    }

    var fan: Fan? { fans.max { $0.rpm < $1.rpm } }

    var platformLine: String {
        [chip ?? cpuModel, osName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct HostSnapshot: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var target: String
    var metrics: Metrics?
    var lastSuccess: Date?
    var lastAttempt: Date?
    var error: String?
    var cpuHistory: [Double] = []
    var memoryHistory: [Double] = []

    init(id: UUID, name: String, target: String) {
        self.id = id
        self.name = name
        self.target = target
    }

    init(host: HostConfig) {
        self.init(id: host.id, name: host.name, target: host.target)
    }
}

struct HostStatus {
    enum Kind { case live, stale, offline, waiting }
    var kind: Kind
    var message: String?

    static func of(_ snapshot: HostSnapshot?, now: Date = Date()) -> HostStatus {
        guard let s = snapshot else { return HostStatus(kind: .waiting, message: "Waiting for first reading") }
        let age = s.lastSuccess.map { now.timeIntervalSince($0) } ?? .infinity
        if let error = s.error, s.metrics == nil || age > 45 {
            return HostStatus(kind: .offline, message: error)
        }
        if s.metrics == nil { return HostStatus(kind: .waiting, message: "Connecting…") }
        if age > 180 { return HostStatus(kind: .stale, message: s.error) }
        return HostStatus(kind: .live, message: s.error)
    }
}
