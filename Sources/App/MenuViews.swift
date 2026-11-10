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
                .frame(width: 364, height: 200)
            } else {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(snapshots) { HostCard(snapshot: $0, now: context.date) }
                        }
                    }
                    .frame(width: 368, height: min(CGFloat(snapshots.count) * 410, 640))
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
        .frame(width: 392)
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

struct DesktopWidgetView: View {
    @EnvironmentObject private var monitor: Monitor

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            Group {
                if let snapshot = monitor.primarySnapshot {
                    HostView(snapshot: snapshot, layout: .large, now: context.date)
                } else {
                    EmptyHostsView()
                }
            }
            .frame(width: 364, height: 382)
            .background(CardBackground())
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
        }
        .contextMenu {
            Button("Open Dashboard") { AppWindows.showDashboard() }
            Button("Settings…") { AppWindows.showSettings() }
            Divider()
            Button("Hide Desktop Widget") { monitor.update { $0.showDesktopWidget = false } }
        }
    }
}
