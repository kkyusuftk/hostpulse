import AppKit
import SwiftUI

extension Monitor {
    func binding<T: Equatable>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] },
                set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
}

/// A host's large card plus any helper/connection notes underneath.
struct HostCard: View {
    let snapshot: HostSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HostView(snapshot: snapshot, layout: .large, now: now)
                .frame(width: 364, height: 382)
                .background(CardBackground())
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            if let note {
                Label(note.text, systemImage: note.icon)
                    .font(.system(size: 10.5))
                    .foregroundStyle(note.color)
                    .lineLimit(2)
                    .frame(width: 364, alignment: .leading)
            }
        }
    }

    private var note: (text: String, icon: String, color: Color)? {
        if let error = snapshot.error, snapshot.metrics != nil {
            return ("Last poll failed: \(error)", "exclamationmark.triangle.fill", Theme.warn)
        }
        switch snapshot.metrics?.helper {
        case .installing: return ("Installing the sensor helper for temperatures and Wi-Fi…", "arrow.down.circle", .secondary)
        case .failed: return ("Sensor helper not installed: \(snapshot.metrics?.helperMessage ?? "unknown error")", "exclamationmark.triangle.fill", Theme.warn)
        case .disabled: return ("Sensor helper is off for this host, so temperatures are hidden.", "thermometer.slash", .secondary)
        default: return nil
        }
    }
}

/// One line per machine in the menu bar popover: name, hardware and RAM use.
/// Click it for the full card in the dashboard window.
struct CompactHostRow: View {
    let snapshot: HostSnapshot
    let now: Date
    @State private var hovering = false

    var body: some View {
        let status = HostStatus.of(snapshot, now: now)
        let m = snapshot.metrics
        HStack(spacing: 10) {
            StatusDot(kind: status.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(configLine(m, status))
                    .font(.system(size: 10))
                    .foregroundStyle(status.kind == .offline ? AnyShapeStyle(Theme.bad) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let m, status.kind != .offline, let f = m.memoryFraction {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("RAM " + Fmt.usage(m.memoryUsed, of: m.memoryTotal))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Bar(fraction: f, color: Theme.level(f, base: Theme.memory), height: 5)
                }
                .frame(width: 104)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.10 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { AppWindows.showDashboard() }
        .help("Open the full view in the dashboard")
    }

    private func configLine(_ m: Metrics?, _ status: HostStatus) -> String {
        if status.kind == .offline { return status.message ?? "offline" }
        guard let m else { return "connecting…" }
        let cores = m.coreCount.map { "\($0) cores" }
        let parts = [m.model, m.chip ?? m.cpuModel, cores].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? snapshot.target : parts.joined(separator: " · ")
    }
}

struct MenuContentView: View {
    @EnvironmentObject private var monitor: Monitor

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack").foregroundStyle(Theme.cpu)
                Text("HostPulse").font(.system(size: 14, weight: .bold))
                Spacer()
                if !monitor.polling.isEmpty {
                    ProgressView().controlSize(.small)
                }
                Button { monitor.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh now")
                Button { AppWindows.showDashboard() } label: { Image(systemName: "macwindow") }
                    .buttonStyle(.borderless)
                    .help("Open dashboard window")
                Button { AppWindows.showSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings")
            }

            let snapshots = monitor.orderedSnapshots
            if snapshots.isEmpty {
                VStack(spacing: 8) {
                    EmptyHostsView()
                    Button("Add a Host…") { AppWindows.showSettings() }
                        .controlSize(.large)
                }
                .frame(width: 344, height: 200)
            } else {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(snapshots) { CompactHostRow(snapshot: $0, now: context.date) }
                        }
                    }
                    .frame(width: 344, height: min(CGFloat(snapshots.count) * 54, 432))
                }
            }

            Divider()
            HStack {
                Toggle("Live desktop widget", isOn: monitor.binding(\.showDesktopWidget))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
        }
        .padding(12)
        .frame(width: 368)
    }
}

struct DashboardView: View {
    @EnvironmentObject private var monitor: Monitor

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            ScrollView {
                if monitor.menuBarIconHidden {
                    Label("Your menu bar is full, so macOS is hiding the HostPulse icon behind the notch. Quit or hide a few menu bar apps (⌘-drag an icon off the bar), then reopen HostPulse. Until then, open HostPulse from Spotlight to get this window.",
                          systemImage: "menubar.rectangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: 740, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warn.opacity(0.15)))
                        .padding([.horizontal, .top], 16)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 364, maximum: 364), spacing: 14)], spacing: 14) {
                    ForEach(monitor.orderedSnapshots) { HostCard(snapshot: $0, now: context.date) }
                }
                .padding(16)
            }
        }
        .overlay {
            if monitor.settings.enabledHosts.isEmpty {
                VStack(spacing: 8) {
                    EmptyHostsView()
                    Button("Add a Host…") { AppWindows.showSettings() }
                }
            }
        }
        .frame(minWidth: 396, minHeight: 420)
    }
}

/// Desktop panel: one large card per machine, up to `columns` per row.
struct DesktopWidgetView: View {
    @EnvironmentObject private var monitor: Monitor

    static let cardSize = CGSize(width: 364, height: 382)
    static let spacing: CGFloat = 14
    static let maxColumns = 3

    /// Panel size for a number of hosts.
    static func size(hosts: Int) -> NSSize {
        let n = max(hosts, 1)
        let cols = min(n, maxColumns)
        let rows = (n + cols - 1) / cols
        return NSSize(width: CGFloat(cols) * cardSize.width + CGFloat(cols - 1) * spacing,
                      height: CGFloat(rows) * cardSize.height + CGFloat(rows - 1) * spacing)
    }

    var body: some View {
        let snapshots = monitor.orderedSnapshots
        let cols = min(max(snapshots.count, 1), Self.maxColumns)
        TimelineView(.periodic(from: .now, by: 5)) { context in
            Grid(alignment: .topLeading, horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
                if snapshots.isEmpty {
                    card { EmptyHostsView() }
                } else {
                    ForEach(Array(stride(from: 0, to: snapshots.count, by: cols)), id: \.self) { start in
                        GridRow {
                            ForEach(snapshots[start..<min(start + cols, snapshots.count)]) { snapshot in
                                card { HostView(snapshot: snapshot, layout: .large, now: context.date) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .contextMenu {
            Button("Open Dashboard") { AppWindows.showDashboard() }
            Button("Settings…") { AppWindows.showSettings() }
            Divider()
            Button("Hide Desktop Widget") { monitor.update { $0.showDesktopWidget = false } }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: Self.cardSize.width, height: Self.cardSize.height)
            .background(CardBackground())
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
    }
}
