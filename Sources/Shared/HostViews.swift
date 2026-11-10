import SwiftUI

enum HostLayout { case small, medium, large }

/// The host card used by the widget, the menu bar popover and the desktop panel.
struct HostView: View {
    let snapshot: HostSnapshot
    let layout: HostLayout
    var now = Date()

    var body: some View {
        let status = HostStatus.of(snapshot, now: now)
        if let m = snapshot.metrics {
            switch layout {
            case .small: SmallHostView(snapshot: snapshot, m: m, status: status)
            case .medium: MediumHostView(snapshot: snapshot, m: m, status: status)
            case .large: LargeHostView(snapshot: snapshot, m: m, status: status)
            }
        } else {
            UnavailableView(snapshot: snapshot, status: status, layout: layout)
        }
    }
}

// MARK: - Pieces

struct HostHeader: View {
    let snapshot: HostSnapshot
    let status: HostStatus
    var fontSize: CGFloat = 13
    var relative = false

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(kind: status.kind)
            Text(snapshot.name)
                .font(.system(size: fontSize, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Group {
                if status.kind == .offline {
                    Text("offline").foregroundStyle(Theme.bad)
                } else if let t = snapshot.lastSuccess {
                    if relative {
                        Text(t, style: .relative) + Text(" ago")
                    } else {
                        Text(t, style: .time)
                    }
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
        }
    }
}

/// "41° CPU   34° GPU"
struct TemperatureLine: View {
    let m: Metrics
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: size - 1, weight: .semibold))
                .foregroundStyle(Theme.temperature(m.cpuTemp ?? m.hottestTemp))
                .frame(width: size + 3)
            if m.cpuTemp == nil && m.gpuTemp == nil {
                Text(m.os == "Darwin" ? "needs helper" : "no sensors")
                    .font(.system(size: size - 1))
                    .foregroundStyle(.secondary)
            }
            if let t = m.cpuTemp { reading(t, "CPU") }
            if let t = m.gpuTemp { reading(t, "GPU") }
        }
        .lineLimit(1)
    }

    private func reading(_ t: Double, _ label: String) -> some View {
        HStack(spacing: 2) {
            Text(Fmt.temp(t))
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.temperature(t))
            Text(label)
                .font(.system(size: size - 2, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// "-60 dBm ▂▄▆█" or "Ethernet"
struct NetworkLine: View {
    let m: Metrics
    var size: CGFloat = 11
    var showSSID = false

    var body: some View {
        HStack(spacing: 5) {
            if let w = m.connectedWiFi, m.isOnWiFi || m.networkPort == nil {
                Image(systemName: "wifi")
                    .font(.system(size: size - 1, weight: .semibold))
                    .foregroundStyle(Theme.signal(w.rssi))
                    .frame(width: size + 3)
                Text("\(w.rssi ?? 0) dBm")
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                SignalBars(rssi: w.rssi, color: Theme.signal(w.rssi), scale: size / 12)
                if showSSID, let ssid = w.ssid {
                    Text(ssid)
                        .font(.system(size: size - 1))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if let port = m.networkPort {
                Image(systemName: port == "Wi-Fi" ? "wifi" : "cable.connector")
                    .font(.system(size: size - 1, weight: .semibold))
                    .foregroundStyle(Theme.good)
                    .frame(width: size + 3)
                Text(port == "Wi-Fi" ? "Wi-Fi" : "Wired")
                    .font(.system(size: size, weight: .semibold))
                if let w = m.wifi, w.poweredOn == false {
                    Text("Wi-Fi off").font(.system(size: size - 2)).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "network")
                    .font(.system(size: size - 1))
                    .foregroundStyle(.secondary)
                    .frame(width: size + 3)
                Text(Fmt.dash).font(.system(size: size))
            }
        }
        .lineLimit(1)
    }
}

struct ProcessRow: View {
    let process: ProcessSample
    var size: CGFloat = 11
    var showMemory = true

    var body: some View {
        HStack(spacing: 6) {
            Text(process.name)
                .font(.system(size: size, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(Fmt.percent(process.cpu))
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.level(process.cpu / 100, base: .primary))
                .frame(width: 42, alignment: .trailing)
            if showMemory {
                Text(process.memory > 0 ? Fmt.bytes(process.memory) : Fmt.dash)
                    .font(.system(size: size - 1, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.cpu.opacity(0.16))
                    .frame(width: geo.size.width * CGFloat(min(max(process.cpu / 100, 0.02), 1)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

struct ProcessList: View {
    let processes: [ProcessSample]
    var size: CGFloat = 11
    var showMemory = true

    var body: some View {
        VStack(spacing: 3) {
            if processes.isEmpty {
                Text("No process data").font(.system(size: size - 1)).foregroundStyle(.secondary)
            }
            ForEach(processes.prefix(3)) { ProcessRow(process: $0, size: size, showMemory: showMemory) }
        }
    }
}

// MARK: - Small

struct SmallHostView: View {
    let snapshot: HostSnapshot
    let m: Metrics
    let status: HostStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HostHeader(snapshot: snapshot, status: status, fontSize: 12)
            Spacer(minLength: 6)
            HStack(spacing: 12) {
                RingGauge(title: "CPU", fraction: m.cpuFraction, color: Theme.level(m.cpuFraction, base: Theme.cpu), size: 58)
                RingGauge(title: "RAM", fraction: m.memoryFraction, color: Theme.level(m.memoryFraction, base: Theme.memory), size: 58)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 6)
            VStack(alignment: .leading, spacing: 4) {
                TemperatureLine(m: m, size: 11)
                NetworkLine(m: m, size: 11)
            }
        }
        .padding(14)
    }
}

// MARK: - Medium

struct MediumHostView: View {
    let snapshot: HostSnapshot
    let m: Metrics
    let status: HostStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HostHeader(snapshot: snapshot, status: status, fontSize: 12)
                Spacer(minLength: 6)
                HStack(spacing: 10) {
                    RingGauge(title: "CPU", fraction: m.cpuFraction, color: Theme.level(m.cpuFraction, base: Theme.cpu), size: 56)
                    RingGauge(title: "RAM", fraction: m.memoryFraction, color: Theme.level(m.memoryFraction, base: Theme.memory), size: 56)
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 4) {
                    TemperatureLine(m: m, size: 11)
                    NetworkLine(m: m, size: 11)
                }
            }
            .frame(width: 142)

            VStack(alignment: .leading, spacing: 5) {
                SectionLabel(text: "Top processes", trailing: nil)
                ProcessList(processes: m.processes, size: 11, showMemory: false)
                Spacer(minLength: 0)
                MediumFooter(m: m)
            }
        }
        .padding(14)
    }
}

struct MediumFooter: View {
    let m: Metrics

    var body: some View {
        HStack(spacing: 9) {
            if let g = m.gpuUsage { stat("square.stack.3d.up.fill", "GPU \(Fmt.percent(g))") }
            if let w = m.systemPower { stat("bolt.fill", Fmt.watts(w)) }
            if let d = m.diskFraction { stat("internaldrive.fill", Fmt.percent(d * 100)) }
            if m.gpuUsage == nil || m.systemPower == nil, let f = m.fan { stat("fan.fill", Fmt.rpm(f.rpm)) }
        }
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func stat(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).monospacedDigit()
        }
    }
}

// MARK: - Large

struct LargeHostView: View {
    let snapshot: HostSnapshot
    let m: Metrics
    let status: HostStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HostHeader(snapshot: snapshot, status: status, fontSize: 15, relative: true)
                Group {
                    if status.kind == .offline, let msg = status.message {
                        Text(msg).foregroundStyle(Theme.bad)
                    } else {
                        Text([m.platformLine, m.uptime.map { "up " + Fmt.uptime($0) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 10))
                .lineLimit(1)
            }

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    CPUTile(m: m, history: snapshot.cpuHistory)
                    MemoryTile(m: m)
                }
                GridRow {
                    ThermalTile(m: m)
                    NetworkTile(m: m)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "Top processes", trailing: nil)
                ProcessList(processes: m.processes, size: 11)
            }

            DiskFooter(m: m)
        }
        .padding(14)
    }
}

struct CPUTile: View {
    let m: Metrics
    let history: [Double]

    var body: some View {
        Tile {
            SectionLabel(text: "CPU", trailing: Fmt.percent(m.cpuUsage), trailingColor: Theme.level(m.cpuFraction, base: Theme.cpu))
            if m.cores.isEmpty {
                ZStack {
                    SparklineFill(values: history).fill(Theme.cpu.opacity(0.18))
                    Sparkline(values: history).stroke(Theme.cpu, lineWidth: 1.5)
                }
                .frame(height: 26)
            } else {
                CoreBars(values: m.cores, kinds: m.coreKinds)
                    .frame(height: 26)
            }
            Text(cpuDetail)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !m.load.isEmpty {
                Text("load " + m.load.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: "  "))
                    .font(.system(size: 9.5, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var cpuDetail: String {
        var parts: [String] = []
        if let p = m.performanceCores, let e = m.efficiencyCores { parts.append("\(p)P+\(e)E") } else if let n = m.coreCount { parts.append("\(n) cores") }
        if let u = m.cpuUser, let s = m.cpuSystem { parts.append(String(format: "usr %.0f%% sys %.0f%%", u, s)) }
        return parts.joined(separator: " · ")
    }
}

struct MemoryTile: View {
    let m: Metrics

    var body: some View {
        Tile {
            SectionLabel(text: "Memory", trailing: Fmt.percent(m.memoryFraction.map { $0 * 100 }),
                         trailingColor: Theme.level(m.memoryFraction, base: Theme.memory))
            SegmentedBar(segments: segments, height: 7)
                .padding(.vertical, 2)
            Text(Fmt.usage(m.memoryUsed, of: m.memoryTotal))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 4) {
                if let p = m.memoryPressure {
                    Circle().fill(Theme.pressure(p)).frame(width: 5, height: 5)
                    Text(p)
                }
                if let swap = m.swapUsed, swap > 0 { Text("· swap \(Fmt.bytes(swap))") }
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var segments: [(fraction: Double, color: Color)] {
        guard let total = m.memoryTotal, total > 0 else { return [] }
        if let app = m.memoryApp, let wired = m.memoryWired, let comp = m.memoryCompressed {
            return [(app / total, Theme.memory), (wired / total, Theme.memoryWired), (comp / total, Theme.memoryCompressed)]
        }
        return [(m.memoryFraction ?? 0, Theme.memory)]
    }
}

struct ThermalTile: View {
    let m: Metrics

    var body: some View {
        Tile {
            SectionLabel(text: "Thermals", trailing: m.thermalState.map { $0 == "nominal" ? "normal" : $0 },
                         trailingColor: m.thermalState == "nominal" || m.thermalState == nil ? .secondary : Theme.warn)
            if m.cpuTemp == nil && m.gpuTemp == nil && m.ssdTemp == nil {
                Text(m.os == "Darwin" ? "Install the helper to read sensors" : "No temperature sensors found")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 10) {
                    if let t = m.cpuTemp { reading("CPU", t) }
                    if let t = m.gpuTemp { reading("GPU", t) }
                    if let t = m.ssdTemp { reading("SSD", t) }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if let f = m.fan { Label(Fmt.rpm(f.rpm), systemImage: "fan.fill") }
                if let w = m.systemPower { Label(Fmt.watts(w), systemImage: "bolt.fill") }
            }
            .labelStyle(CompactLabelStyle())
            .font(.system(size: 9.5, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func reading(_ label: String, _ t: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Fmt.temp(t))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.temperature(t))
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }
}

struct NetworkTile: View {
    let m: Metrics

    var body: some View {
        Tile {
            if let w = m.connectedWiFi, m.isOnWiFi || m.networkPort == nil {
                SectionLabel(text: "Wi-Fi", trailing: "\(w.rssi ?? 0) dBm", trailingColor: Theme.signal(w.rssi))
                HStack(spacing: 5) {
                    SignalBars(rssi: w.rssi, color: Theme.signal(w.rssi))
                    Text(w.ssid ?? Signal.quality(w.rssi))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                Text(wifiDetail(w))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                SectionLabel(text: "Network", trailing: m.networkInterface)
                HStack(spacing: 5) {
                    Image(systemName: m.networkPort == "Wi-Fi" ? "wifi" : "cable.connector")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.good)
                    Text(m.networkPort ?? "Unknown")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                Text(m.ipAddress ?? (m.wifi?.poweredOn == false ? "Wi-Fi off" : " "))
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Label(Fmt.rate(m.rxRate), systemImage: "arrow.down")
                Label(Fmt.rate(m.txRate), systemImage: "arrow.up")
            }
            .labelStyle(CompactLabelStyle())
            .font(.system(size: 9.5, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func wifiDetail(_ w: WiFi) -> String {
        var parts: [String] = []
        if let b = w.band, !b.isEmpty { parts.append("\(b) GHz") }
        if let c = w.channel { parts.append("ch \(c)") }
        if let t = w.txRate, t > 0 { parts.append(String(format: "%.0f Mbps", t)) }
        if parts.isEmpty, let s = w.standard { parts.append(s) }
        return parts.joined(separator: " · ")
    }
}

struct DiskFooter: View {
    let m: Metrics

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Bar(fraction: m.diskFraction, color: Theme.level(m.diskFraction, base: Theme.disk), height: 5)
                .frame(maxWidth: 90)
            Text(Fmt.usage(m.diskUsed, of: m.diskTotal, decimal: true))
                .monospacedDigit()
            Spacer(minLength: 4)
            if let g = m.gpuUsage {
                Text("GPU \(Fmt.percent(g))").monospacedDigit()
            }
        }
        .font(.system(size: 9.5, design: .rounded))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.font(.system(size: 8, weight: .bold))
            configuration.title
        }
    }
}

// MARK: - No data

struct UnavailableView: View {
    let snapshot: HostSnapshot
    let status: HostStatus
    let layout: HostLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HostHeader(snapshot: snapshot, status: status, fontSize: layout == .large ? 15 : 12)
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: status.kind == .offline ? "bolt.horizontal.circle" : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(status.kind == .offline ? Theme.bad : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.kind == .offline ? "Can't reach \(snapshot.target)" : "Connecting to \(snapshot.target)…")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    if let msg = status.message, status.kind == .offline {
                        Text(msg)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(layout == .small ? 3 : 4)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

struct EmptyHostsView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "server.rack")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("No hosts yet")
                .font(.system(size: 13, weight: .semibold))
            Text("Open HostPulse from the menu bar and add a machine you can reach over SSH.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(14)
    }
}

// MARK: - All hosts

struct OverviewView: View {
    let snapshots: [HostSnapshot]
    var maxRows = 3
    var now = Date()

    var body: some View {
        let online = snapshots.filter { HostStatus.of($0, now: now).kind == .live }.count
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "HostPulse", trailing: "\(online)/\(snapshots.count) online")
            if snapshots.isEmpty {
                Spacer()
                Text("No hosts yet. Add one from the menu bar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            ForEach(snapshots.prefix(maxRows)) { OverviewRow(snapshot: $0, now: now) }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

struct OverviewRow: View {
    let snapshot: HostSnapshot
    var now = Date()

    var body: some View {
        let status = HostStatus.of(snapshot, now: now)
        let m = snapshot.metrics
        HStack(spacing: 8) {
            StatusDot(kind: status.kind, size: 6)
            Text(snapshot.name)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let m, status.kind != .offline {
                meter("CPU", m.cpuFraction, Theme.cpu)
                meter("RAM", m.memoryFraction, Theme.memory)
                Text(Fmt.temp(m.cpuTemp))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.temperature(m.cpuTemp))
                    .frame(width: 28, alignment: .trailing)
                Group {
                    if let w = m.connectedWiFi, m.isOnWiFi {
                        SignalBars(rssi: w.rssi, color: Theme.signal(w.rssi), scale: 0.85)
                    } else {
                        Image(systemName: "cable.connector").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16)
            } else {
                Text(status.kind == .offline ? "offline" : "connecting…")
                    .font(.system(size: 10))
                    .foregroundStyle(status.kind == .offline ? Theme.bad : .secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func meter(_ title: String, _ f: Double?, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(title) \(Fmt.percent(f.map { $0 * 100 }))")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Bar(fraction: f, color: Theme.level(f, base: color), height: 4)
        }
        .frame(width: 58)
    }
}
