// Renders the widget layouts to PNGs so they can be checked without WidgetKit.
//   swiftc -parse-as-library Sources/Shared/*.swift Sources/App/Parser.swift Tools/render-previews.swift -o build/render
//   build/render <collector-output.txt> <out-dir>
import AppKit
import SwiftUI

@main
enum RenderPreviews {
    @MainActor static func main() {
        let args = CommandLine.arguments
        let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "build/previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var live = SampleData.macMini
        if args.count > 1, let text = try? String(contentsOfFile: args[1]) {
            var m = CollectorParser.parse(text)
            m.rxRate = 182_000
            m.txRate = 24_000
            live.metrics = m
            live.name = "Mac mini"
            live.lastSuccess = Date().addingTimeInterval(-7)
        }
        var offline = live
        offline.name = "Dev box"
        offline.target = "devbox"
        offline.id = UUID()
        offline.metrics = nil
        offline.error = "Login refused. Set up key auth: ssh-copy-id devbox"
        var second = live
        second.id = UUID()
        second.name = "Build box"
        second.metrics?.cpuUsage = 82
        second.metrics?.cpuTemp = 77
        second.metrics?.networkPort = "Ethernet"

        let sizes: [(String, HostLayout, CGSize)] = [
            ("small", .small, CGSize(width: 170, height: 170)),
            ("medium", .medium, CGSize(width: 364, height: 170)),
            ("large", .large, CGSize(width: 364, height: 382)),
        ]
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            for (name, layout, size) in sizes {
                render(HostView(snapshot: live, layout: layout), size: size, scheme: scheme, to: outDir.appendingPathComponent("\(name)-\(suffix).png"))
            }
            render(OverviewView(snapshots: [live, second, offline], maxRows: 3), size: CGSize(width: 364, height: 170), scheme: scheme,
                   to: outDir.appendingPathComponent("overview-\(suffix).png"))
            render(HostView(snapshot: offline, layout: .medium), size: CGSize(width: 364, height: 170), scheme: scheme,
                   to: outDir.appendingPathComponent("offline-\(suffix).png"))
        }
        print("wrote previews to \(outDir.path)")
    }

    @MainActor static func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, to url: URL) {
        let framed = view
            .frame(width: size.width, height: size.height)
            .background(CardBackground())
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(10)
            .background(scheme == .dark ? Color(white: 0.25) : Color(white: 0.85))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { print("render failed: \(url.lastPathComponent)"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
