import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            HostsSettings()
                .tabItem { Label("Hosts", systemImage: "server.rack") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(.top, 4)
        .frame(minWidth: 680, minHeight: 480)
    }
}

// MARK: - Hosts

struct HostsSettings: View {
    @EnvironmentObject private var monitor: Monitor
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(monitor.settings.hosts) { host in
                        HostListRow(host: host, snapshot: monitor.snapshots[host.id],
                                    isPrimary: monitor.settings.primaryHost?.id == host.id)
                            .tag(host.id)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 2) {
                    Menu {
                        Button("New Host") { add(HostConfig(name: "New host", target: "")) }
                        let aliases = SSHConfigFile.hostAliases()
                        if !aliases.isEmpty {
                            Divider()
                            Text("From ~/.ssh/config")
                            ForEach(aliases, id: \.self) { alias in
                                Button(alias) { add(HostConfig(name: alias, target: alias)) }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 28)
                    .help("Add a host")
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .frame(width: 28)
                        .disabled(selection == nil)
                        .help("Remove the selected host")
                    Spacer()
                }
                .padding(6)
            }
            .frame(width: 220)

            Divider()

            if let id = selection, let host = monitor.settings.hosts.first(where: { $0.id == id }) {
                HostEditor(host: host).id(id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(monitor.settings.hosts.isEmpty ? "Add a machine you can reach over SSH" : "Select a host to edit it")
                        .foregroundStyle(.secondary)
                    if monitor.settings.hosts.isEmpty {
                        Text("Click + to pick one from ~/.ssh/config or enter user@host.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = monitor.settings.hosts.first?.id } }
    }

    private func add(_ host: HostConfig) {
        monitor.update { $0.hosts.append(host) }
        selection = host.id
    }

    private func removeSelected() {
        guard let id = selection else { return }
        monitor.update { s in
            s.hosts.removeAll { $0.id == id }
            if s.primaryHostID == id { s.primaryHostID = nil }
        }
        selection = monitor.settings.hosts.first?.id
    }
}

struct HostListRow: View {
    let host: HostConfig
    let snapshot: HostSnapshot?
    let isPrimary: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(kind: host.enabled ? HostStatus.of(snapshot).kind : .waiting, size: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name.isEmpty ? "Untitled" : host.name).lineLimit(1)
                Text(host.target.isEmpty ? "no destination" : host.target)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isPrimary {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .help("Shown in the menu bar and the Host Vitals widget")
            }
        }
        .padding(.vertical, 2)
    }
}

struct HostEditor: View {
    @EnvironmentObject private var monitor: Monitor
    let original: HostConfig
    @State private var draft: HostConfig
    @State private var portText: String
    @State private var testing = false
    @State private var testResult: String?

    init(host: HostConfig) {
        original = host
        _draft = State(initialValue: host)
        _portText = State(initialValue: host.port.map(String.init) ?? "")
    }

    private var edited: HostConfig {
        var h = draft
        h.target = h.target.trimmingCharacters(in: .whitespaces)
        h.name = h.name.trimmingCharacters(in: .whitespaces)
        if h.name.isEmpty { h.name = h.target }
        h.port = Int(portText.trimmingCharacters(in: .whitespaces))
        return h
    }

    private var isDirty: Bool { edited != original }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Mac mini"))
                TextField("SSH destination", text: $draft.target, prompt: Text("mini  or  user@192.168.1.20"))
                TextField("Port", text: $portText, prompt: Text("default"))
                TextField("Identity file", text: $draft.identityFile, prompt: Text("optional, e.g. ~/.ssh/id_ed25519"))
                TextField("Extra ssh options", text: $draft.extraArguments, prompt: Text("optional, e.g. -J jumphost"))
            } header: {
                Text("Connection")
            } footer: {
                Text("HostPulse runs /usr/bin/ssh with your ~/.ssh/config, keys and agent. The host has to accept key login without a password prompt; check with `ssh \(draft.target.isEmpty ? "host" : draft.target) true` in Terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Monitor this host", isOn: $draft.enabled)
                Toggle("Install the sensor helper on Macs", isOn: $draft.installHelper)
                Toggle("Primary host (menu bar and Host Vitals widget)", isOn: primaryBinding)
            } footer: {
                Text("The helper is a small read-only program that HostPulse copies to ~/.cache/hostpulse on remote Macs. Without root it reads temperatures, fans, power, per-core load and Wi-Fi signal. Linux needs no helper.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 10) {
                    Button("Test Connection") { runTest() }
                        .disabled(testing || edited.target.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult {
                        Text(testResult)
                            .font(.callout)
                            .foregroundStyle(testResult.hasPrefix("✓") ? Theme.good : Theme.bad)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Revert") {
                    draft = original
                    portText = original.port.map(String.init) ?? ""
                }
                .disabled(!isDirty)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDirty || edited.target.isEmpty)
            }
            .padding(12)
            .background(.bar)
        }
    }

    private var primaryBinding: Binding<Bool> {
        Binding(get: { monitor.settings.primaryHost?.id == original.id },
                set: { on in monitor.update { $0.primaryHostID = on ? original.id : nil } })
    }

    private func save() {
        let host = edited
        monitor.update { s in
            if let i = s.hosts.firstIndex(where: { $0.id == host.id }) { s.hosts[i] = host }
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        let host = edited
        Task {
            let result = await monitor.test(host)
            testing = false
            testResult = result
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject private var monitor: Monitor
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section("Polling") {
                Picker("Refresh every", selection: monitor.binding(\.pollInterval)) {
                    ForEach([5.0, 10, 15, 30, 60], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
                Picker("Primary host", selection: monitor.binding(\.primaryHostID)) {
                    Text("First enabled host").tag(UUID?.none)
                    ForEach(monitor.settings.hosts) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }

            Section("Display") {
                Toggle("Show CPU and temperature in the menu bar", isOn: monitor.binding(\.showMenuBarStats))
                Toggle("Live desktop widget (updates every poll)", isOn: monitor.binding(\.showDesktopWidget))
            }

            Section {
                Toggle("Open HostPulse at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LoginItem.setEnabled(on) }
            } header: {
                Text("System")
            } footer: {
                Text("The widgets show what HostPulse last collected, so keep it running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Last widget refresh", value: Fmt.ago(monitor.lastWidgetRefresh))
            } header: {
                Text("macOS widget")
            } footer: {
                Text("Add it from the desktop: right-click → Edit Widgets… → HostPulse. macOS decides how often widgets redraw when HostPulse isn't in front, sometimes only every few minutes. The menu bar, the popover and the live desktop widget update on every poll.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - ~/.ssh/config

enum SSHConfigFile {
    /// Concrete Host aliases (no wildcards) from ~/.ssh/config.
    static func hostAliases() -> [String] {
        let url = SharedStore.realHome.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            guard lower.hasPrefix("host ") || lower.hasPrefix("host\t") || lower.hasPrefix("host=") else { continue }
            let names = line.dropFirst(4).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            for name in names.map(String.init) where !name.contains("*") && !name.contains("?") && !name.hasPrefix("!") {
                if seen.insert(name).inserted { result.append(name) }
            }
        }
        return result
    }
}
