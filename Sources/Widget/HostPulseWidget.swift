import SwiftUI
import WidgetKit

// The widget only reads what the HostPulse app writes to
// ~/Library/Application Support/HostPulse. The app does the SSH polling and
// asks WidgetKit to reload after each round.

struct HostEntry: TimelineEntry {
    let date: Date
    let snapshot: HostSnapshot?
    let hasHosts: Bool
}

struct HostProvider: TimelineProvider {
    func placeholder(in context: Context) -> HostEntry {
        SharedStore.logWidget("host placeholder \(context.family)")
        return HostEntry(date: Date(), snapshot: SampleData.macMini, hasHosts: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (HostEntry) -> Void) {
        SharedStore.logWidget("host snapshot \(context.family) preview=\(context.isPreview)")
        let entry = Self.current()
        completion(context.isPreview && entry.snapshot?.metrics == nil ? placeholder(in: context) : entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HostEntry>) -> Void) {
        SharedStore.logWidget("host timeline \(context.family)")
        SharedStore.recordWidgetRefresh()
        completion(Timeline(entries: [Self.current()], policy: .after(Date().addingTimeInterval(5 * 60))))
    }

    static func current() -> HostEntry {
        let settings = SharedStore.loadSettings()
        let snapshots = SharedStore.loadSnapshots()
        guard let host = settings.primaryHost else {
            return HostEntry(date: Date(), snapshot: nil, hasHosts: !settings.hosts.isEmpty)
        }
        let snapshot = snapshots.first { $0.id == host.id } ?? HostSnapshot(host: host)
        return HostEntry(date: Date(), snapshot: snapshot, hasHosts: true)
    }
}

struct HostWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HostEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                HostView(snapshot: snapshot, layout: layout, now: entry.date)
            } else {
                EmptyHostsView()
            }
        }
        .containerBackground(for: .widget) { CardBackground() }
        .widgetURL(URL(string: "hostpulse://dashboard"))
    }

    private var layout: HostLayout {
        switch family {
        case .systemSmall: return .small
        case .systemMedium: return .medium
        default: return .large
        }
    }
}

struct HostWidget: Widget {
    let kind = "HostPulseHost"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HostProvider()) { entry in
            HostWidgetView(entry: entry)
        }
        .configurationDisplayName(described("Host Vitals"))
        .description("CPU, memory, temperatures, Wi-Fi and the top processes of your primary host. Choose the host in HostPulse settings.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - All hosts

struct OverviewEntry: TimelineEntry {
    let date: Date
    let snapshots: [HostSnapshot]
}

struct OverviewProvider: TimelineProvider {
    func placeholder(in context: Context) -> OverviewEntry {
        var second = SampleData.macMini
        second.id = UUID()
        second.name = "Build server"
        second.metrics?.cpuUsage = 71
        second.metrics?.cpuTemp = 64
        second.metrics?.networkPort = "Ethernet"
        return OverviewEntry(date: Date(), snapshots: [SampleData.macMini, second])
    }

    func getSnapshot(in context: Context, completion: @escaping (OverviewEntry) -> Void) {
        SharedStore.logWidget("overview snapshot \(context.family) preview=\(context.isPreview)")
        let entry = Self.current()
        completion(context.isPreview && entry.snapshots.isEmpty ? placeholder(in: context) : entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OverviewEntry>) -> Void) {
        SharedStore.logWidget("overview timeline \(context.family)")
        SharedStore.recordWidgetRefresh()
        completion(Timeline(entries: [Self.current()], policy: .after(Date().addingTimeInterval(5 * 60))))
    }

    static func current() -> OverviewEntry {
        let settings = SharedStore.loadSettings()
        let byID = Dictionary(SharedStore.loadSnapshots().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let list = settings.enabledHosts.map { byID[$0.id] ?? HostSnapshot(host: $0) }
        return OverviewEntry(date: Date(), snapshots: list)
    }
}

struct OverviewWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: OverviewEntry

    var body: some View {
        OverviewView(snapshots: entry.snapshots, maxRows: family == .systemLarge ? 8 : 3, now: entry.date)
            .containerBackground(for: .widget) { CardBackground() }
            .widgetURL(URL(string: "hostpulse://dashboard"))
    }
}

struct OverviewWidget: Widget {
    let kind = "HostPulseOverview"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OverviewProvider()) { entry in
            OverviewWidgetView(entry: entry)
        }
        .configurationDisplayName(described("All Hosts"))
        .description("One line per machine: status, CPU, memory, temperature and network.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

/// Logs when WidgetKit reads the widget descriptions (diagnostics for the gallery).
private func described(_ name: String) -> String {
    SharedStore.logWidget("describing \(name)")
    return name
}

@main
struct HostPulseWidgets: WidgetBundle {
    init() {
        SharedStore.logWidget("extension started")
    }

    var body: some Widget {
        HostWidget()
        OverviewWidget()
    }
}
