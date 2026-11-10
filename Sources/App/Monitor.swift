import AppKit
import Foundation
import WidgetKit

/// Polls every enabled host over SSH, keeps the latest reading of each, writes
/// them where the widget can read them and asks WidgetKit to refresh.
@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published private(set) var settings: AppSettings
    @Published private(set) var snapshots: [UUID: HostSnapshot] = [:]
    @Published private(set) var polling: Set<UUID> = []
    @Published private(set) var lastWidgetRefresh: Date?
    /// The menu bar has no room for HostPulse's item (e.g. hidden behind the notch).
    @Published var menuBarIconHidden = false

    private var loops: [UUID: Task<Void, Never>] = [:]
    private var pollCount: [UUID: Int] = [:]
    private var helperAttempt: [UUID: Date] = [:]
    private var helperError: [UUID: String] = [:]
    private var counters: [UUID: (rx: Double, tx: Double, iface: String?, at: Date)] = [:]
    private var lastWidgetReload = Date.distantPast
    private var saveTask: Task<Void, Never>?
    private var paused = false

    private static let historyLength = 40
    private static let minWidgetReloadInterval: TimeInterval = 10

    private init() {
        settings = SharedStore.loadSettings()
        for s in SharedStore.loadSnapshots() { snapshots[s.id] = s }
        lastWidgetRefresh = SharedStore.lastWidgetRefresh()
    }

    var primarySnapshot: HostSnapshot? {
        guard let host = settings.primaryHost else { return nil }
        return snapshots[host.id] ?? HostSnapshot(host: host)
    }

    var orderedSnapshots: [HostSnapshot] {
        settings.enabledHosts.map { snapshots[$0.id] ?? HostSnapshot(host: $0) }
    }

    // MARK: Lifecycle

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Monitor.shared.pause() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Monitor.shared.resumeAfterWake() }
        }
        restartLoops()
    }

    private func pause() {
        paused = true
        loops.values.forEach { $0.cancel() }
        loops = [:]
    }

    private func resumeAfterWake() {
        paused = false
        let hosts = settings.enabledHosts
        Task {
            // Shared connections died with the network; drop them before polling again.
            for host in hosts { await SSH.closeMaster(host) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.restartLoops()
        }
    }

    /// Polls everything right away.
    func refreshNow() { restartLoops() }

    private func restartLoops() {
        loops.values.forEach { $0.cancel() }
        loops = [:]
        guard !paused else { return }
        for host in settings.enabledHosts { startLoop(host.id) }
    }

    /// (Re)starts one host's poll loop; the first poll happens immediately.
    private func startLoop(_ id: UUID) {
        loops[id]?.cancel()
        loops[id] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let host = self.settings.enabledHosts.first(where: { $0.id == id }) else { return }
                await self.poll(host)
                let interval = max(self.settings.pollInterval, 3)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    // MARK: Settings

    func update(_ change: (inout AppSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let previous = settings
        settings = next
        try? SharedStore.save(next)

        let ids = Set(next.hosts.map(\.id))
        snapshots = snapshots.filter { ids.contains($0.key) }
        for host in next.hosts {
            if let old = previous.hosts.first(where: { $0.id == host.id }), old != host {
                // Connection settings changed: forget the old reading and connection.
                if old.target != host.target || old.port != host.port || old.identityFile != host.identityFile || old.extraArguments != host.extraArguments {
                    snapshots[host.id] = nil
                    counters[host.id] = nil
                    helperAttempt[host.id] = nil
                    Task { await SSH.closeMaster(old) }
                } else {
                    snapshots[host.id]?.name = host.name
                }
            }
        }
        if previous.hosts != next.hosts || previous.pollInterval != next.pollInterval {
            restartLoops()
        }
        scheduleSave()
    }

    // MARK: Polling

    private func poll(_ host: HostConfig) async {
        polling.insert(host.id)
        defer { polling.remove(host.id) }
        let n = pollCount[host.id, default: 0]
        pollCount[host.id] = n + 1
        let full = n % 60 == 0 // model name etc. rarely change
        let started = Date()

        let result = await RemoteCollector.collect(host, full: full)
        guard !Task.isCancelled, let current = settings.hosts.first(where: { $0.id == host.id }), current.target == host.target else { return }

        var snap = snapshots[host.id] ?? HostSnapshot(host: current)
        snap.name = current.name
        snap.target = current.target
        snap.lastAttempt = started

        switch result {
        case .success(var m):
            if let previous = snap.metrics {
                // Slow, rarely-changing facts only come with full polls.
                m.model = m.model ?? previous.model
                m.chip = m.chip ?? previous.chip
            }
            let now = Date()
            if let rx = m.rxBytes, let tx = m.txBytes {
                if let c = counters[host.id], c.iface == m.networkInterface, rx >= c.rx, tx >= c.tx {
                    let dt = now.timeIntervalSince(c.at)
                    if dt > 0.5 {
                        m.rxRate = (rx - c.rx) / dt
                        m.txRate = (tx - c.tx) / dt
                    }
                }
                counters[host.id] = (rx, tx, m.networkInterface, now)
            }
            if m.helper == .missing {
                if current.installHelper, RemoteCollector.probe != nil {
                    installHelperIfNeeded(current)
                    m.helper = helperError[host.id] == nil ? .installing : .failed
                }
                m.helperMessage = helperError[host.id]
            }
            snap.metrics = m
            snap.lastSuccess = now
            snap.error = nil
            snap.cpuHistory = Array((snap.cpuHistory + [m.cpuFraction ?? 0]).suffix(Self.historyLength))
            snap.memoryHistory = Array((snap.memoryHistory + [m.memoryFraction ?? 0]).suffix(Self.historyLength))
        case .failure(let error):
            snap.error = error.message
        }
        snapshots[host.id] = snap
        scheduleSave()
    }

    private func installHelperIfNeeded(_ host: HostConfig) {
        if let last = helperAttempt[host.id], Date().timeIntervalSince(last) < 600 { return }
        helperAttempt[host.id] = Date()
        helperError[host.id] = nil
        Task {
            switch await RemoteCollector.installProbe(host) {
            case .success:
                self.helperError[host.id] = nil
                if !self.paused, self.loops[host.id] != nil { self.startLoop(host.id) } // read sensors right away
            case .failure(let e):
                self.helperError[host.id] = e.message
            }
        }
    }

    /// One-off connection check for the settings window.
    func test(_ host: HostConfig) async -> String {
        switch await RemoteCollector.collect(host, full: true) {
        case .success(let m):
            var parts = ["Connected to \(m.hostname ?? host.target)"]
            if let os = m.osName { parts.append(os) }
            if m.os == "Darwin" {
                switch m.helper {
                case .running: parts.append("sensor helper running")
                case .disabled: parts.append("sensor helper off: no temperatures")
                default: parts.append("sensor helper will be installed")
                }
            }
            return "✓ " + parts.joined(separator: " · ")
        case .failure(let e):
            return "✗ " + e.message
        }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func persist() {
        try? SharedStore.save(settings.hosts.compactMap { snapshots[$0.id] })
        lastWidgetRefresh = SharedStore.lastWidgetRefresh()
        let now = Date()
        if now.timeIntervalSince(lastWidgetReload) >= Self.minWidgetReloadInterval {
            lastWidgetReload = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
