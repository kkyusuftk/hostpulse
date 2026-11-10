import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
enum HostPulseMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN) // a remote that hangs up mid-upload must not kill the app
        NSApp.mainMenu = makeMainMenu()
        let monitor = Monitor.shared

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "HostPulse")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        let content = NSHostingController(rootView: MenuContentView().environmentObject(monitor))
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        popover.behavior = .transient

        monitor.$snapshots.combineLatest(monitor.$settings)
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshots, settings in self?.updateStatusItem(snapshots, settings) }
            .store(in: &cancellables)
        monitor.$settings.map(\.showDesktopWidget).removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { DesktopPanel.shared.setVisible($0) }
            .store(in: &cancellables)

        monitor.start()

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didFirstRun") {
            defaults.set(true, forKey: "didFirstRun")
            LoginItem.setEnabled(true) // the widget only has fresh data while HostPulse runs
        }
        if monitor.settings.hosts.isEmpty { AppWindows.showSettings() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppWindows.showDashboard() // hostpulse:// links, e.g. clicking the widget
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppWindows.showDashboard() }
        return true
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc func openSettings(_ sender: Any?) { AppWindows.showSettings() }

    // MARK: Menu bar item

    /// On notched MacBooks a full menu bar hides items that don't fit right of the
    /// notch, so the item gets narrower until macOS shows it.
    private enum TitleStyle: Int { case cpuAndTemp, cpu, iconOnly }
    private var titleStyle = TitleStyle.cpuAndTemp
    private var visibilityCheck: DispatchWorkItem?
    private var lastSnapshots: [UUID: HostSnapshot] = [:]
    private var lastSettings = AppSettings()
    private var reportedHidden = false

    private func updateStatusItem(_ snapshots: [UUID: HostSnapshot], _ settings: AppSettings) {
        lastSnapshots = snapshots
        lastSettings = settings
        guard let button = statusItem.button else { return }
        var title = ""
        if settings.showMenuBarStats, titleStyle != .iconOnly, let host = settings.primaryHost {
            let snapshot = snapshots[host.id]
            let kind = HostStatus.of(snapshot).kind
            if let m = snapshot?.metrics, kind != .offline {
                var parts = [m.cpuUsage.map { String(format: "%.0f%%", $0) } ?? Fmt.dash]
                if titleStyle == .cpuAndTemp, let t = m.cpuTemp { parts.append(String(format: "%.0f°", t)) }
                title = " " + parts.joined(separator: " ")
            } else if kind == .offline {
                title = " " + Fmt.dash
            }
        }
        guard button.attributedTitle.string != title else { return }
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .baselineOffset: 0.5,
        ])
        scheduleVisibilityCheck()
    }

    private func scheduleVisibilityCheck() {
        visibilityCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkVisibility() }
        visibilityCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func checkVisibility() {
        guard isStatusItemHidden() else { return }
        SharedStore.log("menu bar item hidden (style \(titleStyle), frame \(statusItem.button?.window?.frame ?? .zero)); trying narrower")
        if let narrower = TitleStyle(rawValue: titleStyle.rawValue + 1) {
            titleStyle = narrower
            updateStatusItem(lastSnapshots, lastSettings)
            scheduleVisibilityCheck()
        } else if !reportedHidden {
            // Even the bare icon doesn't fit: say so and show the data in a window instead.
            reportedHidden = true
            Monitor.shared.menuBarIconHidden = true
            AppWindows.showDashboard()
        }
    }

    private func isStatusItemHidden() -> Bool {
        guard let window = statusItem.button?.window, window.windowNumber > 0 else { return NSMenu.menuBarVisible() }
        let frame = window.frame
        let screen = window.screen ?? NSScreen.screens.first
        if let screen, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           frame.minX < right.minX + screen.frame.minX, frame.maxX > left.maxX + screen.frame.minX {
            return true // overlaps the notch
        }
        // Items that don't fit stay "visible" to AppKit; only the window server knows they're off screen.
        let number = window.windowNumber
        guard NSMenu.menuBarVisible(),
              let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == number })
        else { return false }
        return !((info[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit HostPulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for (title, menu) in [("HostPulse", appMenu), ("Edit", editMenu), ("Window", windowMenu)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        return main
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("HostPulse: could not change login item: \(error.localizedDescription)")
        }
    }
}

/// Regular windows hosting SwiftUI views (settings, dashboard).
@MainActor
enum AppWindows {
    private static var windows: [String: NSWindow] = [:]

    static func showSettings() {
        show("settings", title: "HostPulse Settings", size: NSSize(width: 720, height: 520)) {
            SettingsView().environmentObject(Monitor.shared)
        }
    }

    static func showDashboard() {
        show("dashboard", title: "HostPulse", size: NSSize(width: 404, height: 640)) {
            DashboardView().environmentObject(Monitor.shared)
        }
    }

    private static func show<Content: View>(_ id: String, title: String, size: NSSize, content: () -> Content) {
        let window: NSWindow
        if let existing = windows[id] {
            window = existing
        } else {
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
            window.title = title
            window.isReleasedWhenClosed = false
            let controller = NSHostingController(rootView: content())
            controller.sizingOptions = [.minSize]
            window.contentViewController = controller
            window.setContentSize(size)
            window.center()
            window.setFrameAutosaveName("HostPulse.\(id)")
            windows[id] = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// A borderless panel pinned to the desktop that shows the primary host live,
/// for when macOS refreshes the real widget less often than you'd like.
@MainActor
final class DesktopPanel {
    static let shared = DesktopPanel()
    private var panel: NSPanel?

    func setVisible(_ visible: Bool) {
        if visible {
            show()
        } else {
            panel?.orderOut(nil)
            panel = nil
        }
    }

    private func show() {
        guard panel == nil else { return }
        let size = NSSize(width: 364, height: 382)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        let view = DraggableHostingView(rootView: DesktopWidgetView().environmentObject(Monitor.shared))
        view.frame = NSRect(origin: .zero, size: size)
        p.contentView = view
        if !p.setFrameUsingName("HostPulse.desktop"), let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - size.width - 28, y: f.maxY - size.height - 28))
        }
        p.setFrameAutosaveName("HostPulse.desktop")
        p.orderFrontRegardless()
        panel = p
    }
}

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}
