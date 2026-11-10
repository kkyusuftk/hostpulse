import Foundation

/// Parses the key=value output of collect.sh (and the helper it runs).
enum CollectorParser {
    static func parse(_ text: String) -> Metrics {
        var m = Metrics()
        var wifi = WiFi()
        var hasWiFi = false
        var idle: Double?
        let body = text.range(of: "@@HOSTPULSE").map { text[$0.upperBound...] } ?? Substring(text)

        for line in body.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq]
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let num = Double(value)
            let str: String? = value.isEmpty ? nil : value

            switch key {
            case "os": m.os = value
            case "os.name": m.osName = str
            case "hostname": m.hostname = str
            case "model.name": m.model = str
            case "model.id": m.modelID = str
            case "model.chip": m.chip = str
            case "cpu.model": m.cpuModel = str
            case "cpu.count": m.coreCount = num.map { Int($0) }
            case "cpu.pcores": m.performanceCores = num.map { Int($0) }
            case "cpu.ecores": m.efficiencyCores = num.map { Int($0) }
            case "load": m.load = value.split(separator: "|").compactMap { Double($0) }
            case "uptime": m.uptime = num
            case "cpu.user": m.cpuUser = num
            case "cpu.sys": m.cpuSystem = num
            case "cpu.idle": idle = num
            case "cpu.cores": m.cores = value.split(separator: ",").compactMap { Double($0) }
            case "cpu.kinds": m.coreKinds = value

            case "mem.total": m.memoryTotal = num
            case "mem.used": m.memoryUsed = num
            case "mem.app": m.memoryApp = num
            case "mem.wired": m.memoryWired = num
            case "mem.compressed": m.memoryCompressed = num
            case "mem.cached": m.memoryCached = num
            case "mem.pressure": m.memoryPressure = str
            case "swap.total": m.swapTotal = num
            case "swap.used": m.swapUsed = num

            case "gpu.usage": m.gpuUsage = num
            case "disk.total": m.diskTotal = num
            case "disk.used": m.diskUsed = num

            case "net.iface": m.networkInterface = str
            case "net.port": m.networkPort = str
            case "net.ip": m.ipAddress = str
            case "net.rx": m.rxBytes = num
            case "net.tx": m.txBytes = num

            case "temp.cpu": m.cpuTemp = num
            case "temp.cpu_max": m.cpuTempMax = num
            case "temp.gpu": m.gpuTemp = num
            case "temp.ssd": m.ssdTemp = num
            case "temp.max": m.hottestTemp = num
            case "temp.max_name": m.hottestSensor = str
            case "thermal": m.thermalState = str
            case "power.system": m.systemPower = num
            case "fan":
                let f = value.split(separator: "|", omittingEmptySubsequences: false).map { Double($0) ?? 0 }
                if f.count >= 4 { m.fans.append(Fan(rpm: f[1], min: f[2], max: f[3])) }

            case "wifi.iface": wifi.interface = str; hasWiFi = true
            case "wifi.power": wifi.poweredOn = value == "1"; hasWiFi = true
            case "wifi.ssid": wifi.ssid = str; hasWiFi = true
            case "wifi.rssi": wifi.rssi = num.map { Int($0) }; hasWiFi = true
            case "wifi.noise": wifi.noise = num.map { Int($0) }
            case "wifi.tx": wifi.txRate = num
            case "wifi.channel": wifi.channel = num.map { Int($0) }
            case "wifi.band": wifi.band = str
            case "wifi.phy": wifi.standard = str

            case "proc":
                let parts = value.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
                if parts.count == 4, let pid = Int(parts[0]) {
                    m.processes.append(ProcessSample(pid: pid, name: String(parts[3]),
                                                     cpu: Double(parts[1]) ?? 0, memory: Double(parts[2]) ?? 0))
                }

            case "probe": m.helper = value == "ok" ? .running : .missing
            default: break
            }
        }

        if let idle {
            m.cpuUsage = min(max(100 - idle, 0), 100)
        } else if let u = m.cpuUser, let s = m.cpuSystem {
            m.cpuUsage = min(u + s, 100)
        }
        if hasWiFi { m.wifi = wifi }
        if m.os != "Darwin" { m.helper = .notNeeded }
        return m
    }
}
