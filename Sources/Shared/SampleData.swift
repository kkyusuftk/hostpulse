import Foundation

/// Example reading used for widget placeholders and the gallery preview.
enum SampleData {
    static var macMini: HostSnapshot {
        var s = HostSnapshot(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Mac mini", target: "mini")
        var m = Metrics()
        m.os = "Darwin"
        m.osName = "macOS 15.4.1"
        m.model = "Mac mini"
        m.chip = "Apple M4"
        m.uptime = 4 * 86400 + 5 * 3600
        m.cpuUsage = 23
        m.cpuUser = 14
        m.cpuSystem = 9
        m.cores = [42, 35, 18, 12, 9, 6, 61, 28, 14, 7]
        m.coreKinds = "EEEEEEPPPP"
        m.coreCount = 10
        m.performanceCores = 4
        m.efficiencyCores = 6
        m.load = [2.41, 1.98, 1.87]
        let gb = 1_073_741_824.0
        m.memoryTotal = 16 * gb
        m.memoryUsed = 9.6 * gb
        m.memoryApp = 6.1 * gb
        m.memoryWired = 2.2 * gb
        m.memoryCompressed = 1.3 * gb
        m.memoryPressure = "normal"
        m.swapTotal = 1 * gb
        m.swapUsed = 0.26 * gb
        m.gpuUsage = 7
        m.cpuTemp = 46
        m.cpuTempMax = 58
        m.gpuTemp = 38
        m.ssdTemp = 31
        m.thermalState = "nominal"
        m.fans = [Fan(rpm: 1000, min: 1000, max: 4900)]
        m.systemPower = 6.4
        m.wifi = WiFi(interface: "en1", poweredOn: true, ssid: "Home 5G", rssi: -58, noise: -96, txRate: 526, channel: 36, band: "5", standard: "Wi-Fi 5")
        m.networkInterface = "en1"
        m.networkPort = "Wi-Fi"
        m.rxRate = 182_000
        m.txRate = 24_000
        m.diskTotal = 245 * gb
        m.diskUsed = 144 * gb
        m.processes = [
            ProcessSample(pid: 166, name: "WindowServer", cpu: 18.4, memory: 0.21 * gb),
            ProcessSample(pid: 812, name: "node", cpu: 12.9, memory: 0.48 * gb),
            ProcessSample(pid: 0, name: "kernel_task", cpu: 6.1, memory: 0),
        ]
        m.helper = .running
        s.metrics = m
        s.lastSuccess = Date()
        s.lastAttempt = Date()
        s.cpuHistory = [0.12, 0.18, 0.15, 0.22, 0.30, 0.26, 0.21, 0.19, 0.24, 0.23]
        return s
    }
}
