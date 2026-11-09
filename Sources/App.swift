import AppKit
import SwiftUI

@main
struct ClaudeSessionsApp: App {
    @StateObject private var store = SessionStore.shared

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--write-icon"), i + 1 < args.count {
            writeAppIcon(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--make-media"), i + 1 < args.count {
            MainActor.assumeIsolated { makeMedia(to: args[i + 1]) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count {
            MainActor.assumeIsolated { renderPreview(to: args[i + 1]) }
            exit(0)
        }
        MainActor.assumeIsolated { SessionStore.shared.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(store: store)
        } label: {
            MenuBarLabel(running: store.running.count)
        }
        .menuBarExtraStyle(.window)

        Window("Claude Sessions", id: "main") {
            MainView(store: store)
        }
        .defaultSize(width: 1180, height: 740)
        .defaultLaunchBehavior(.suppressed)

        Window("How Claude Sessions works", id: "help") {
            HelpView(store: store)
        }
        .defaultSize(width: 900, height: 640)
        .defaultLaunchBehavior(.suppressed)
    }
}

struct MenuBarLabel: View {
    let running: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "bubble.left.and.text.bubble.right")
            if running > 0 { Text("\(running)").monospacedDigit() }
        }
        .help("\(running) Claude Code sessions running")
    }
}

// MARK: - App icon

/// Draws the 1024×1024 app icon: two chat bubbles and a history clock on a
/// warm gradient squircle. `build.sh` turns it into AppIcon.icns.
func writeAppIcon(to url: URL) {
    let size = 1024
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824 pt body centered in 1024, ~185 pt corner radius.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(red: 0.95, green: 0.55, blue: 0.36, alpha: 1),
        NSColor(red: 0.82, green: 0.33, blue: 0.40, alpha: 1),
        NSColor(red: 0.42, green: 0.24, blue: 0.62, alpha: 1),
    ])?.draw(in: shape, angle: -60)

    func bubble(_ rect: NSRect, tailLeft: Bool) -> NSBezierPath {
        let p = NSBezierPath(roundedRect: rect, xRadius: 70, yRadius: 70)
        let tail = NSBezierPath()
        let x = tailLeft ? rect.minX + 90 : rect.maxX - 90
        let dir: CGFloat = tailLeft ? -1 : 1
        tail.move(to: NSPoint(x: x - 40 * dir, y: rect.minY + 10))
        tail.line(to: NSPoint(x: x + 50 * dir, y: rect.minY - 70))
        tail.line(to: NSPoint(x: x + 40 * dir, y: rect.minY + 10))
        tail.close()
        p.append(tail)
        return p
    }

    // Back bubble.
    NSColor.white.withAlphaComponent(0.35).setFill()
    bubble(NSRect(x: 360, y: 520, width: 440, height: 280), tailLeft: false).fill()

    // Front bubble with text lines.
    let front = NSRect(x: 210, y: 330, width: 500, height: 320)
    NSColor.white.setFill()
    bubble(front, tailLeft: true).fill()
    NSColor(red: 0.82, green: 0.33, blue: 0.40, alpha: 0.85).setFill()
    for (i, w) in [340.0, 280.0, 200.0].enumerated() {
        NSBezierPath(
            roundedRect: NSRect(x: front.minX + 70, y: front.maxY - 95 - CGFloat(i) * 75, width: w, height: 34),
            xRadius: 17, yRadius: 17
        ).fill()
    }

    // History clock badge.
    let clock = NSRect(x: 600, y: 180, width: 240, height: 240)
    NSColor(red: 0.30, green: 0.17, blue: 0.48, alpha: 1).setFill()
    NSBezierPath(ovalIn: clock.insetBy(dx: -14, dy: -14)).fill()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: clock).fill()
    let hands = NSBezierPath()
    hands.lineWidth = 26
    hands.lineCapStyle = .round
    hands.move(to: NSPoint(x: clock.midX, y: clock.midY + 75))
    hands.line(to: NSPoint(x: clock.midX, y: clock.midY))
    hands.line(to: NSPoint(x: clock.midX + 60, y: clock.midY - 35))
    NSColor(red: 0.30, green: 0.17, blue: 0.48, alpha: 1).setStroke()
    hands.stroke()

    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

// MARK: - Preview rendering (debug aid)

/// `--render-preview <dir>`: renders the panel and windows to PNGs after
/// indexing, so the UI can be checked without screen-recording access.
@MainActor
func renderPreview(to dir: String) {
    _ = NSApplication.shared  // NSApp is used by the views; the App lifecycle hasn't created it yet
    let store = SessionStore.shared
    store.start()
    let deadline = Date().addingTimeInterval(60)
    while (store.isScanning || store.lastScan == nil) && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
    print("indexed \(store.sessions.count) sessions, \(store.visibleSessions.count) visible, \(store.running.count) running")

    func render<V: View>(_ view: V, _ name: String, _ size: CGSize) {
        let r = ImageRenderer(
            content: view.frame(width: size.width, height: size.height).background(Color.white)
                .environment(\.colorScheme, .light))
        r.scale = 2
        if let tiff = r.nsImage?.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }
    render(MenuPanel(store: store), "panel.png", CGSize(width: 420, height: 560))
    // ImageRenderer draws nothing inside ScrollViews, so rows are rendered bare.
    render(
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.visibleSessions.prefix(8)) { SessionRow(store: store, session: $0) }
        }.padding(12), "rows.png", CGSize(width: 420, height: 400))
    render(CleanupHelp(store: store).padding(24), "help-cleanup.png", CGSize(width: 700, height: 760))
    print("running tab: \(store.count(.running)) of \(store.running.count) processes; unsaved: \(store.unsavedRunning.map { "\($0.projectName) since \(fullDate($0.created))" })")
    print("deleted summaries: \(store.deletedSessions.count), empty projects: \(store.emptyProjects)")
    for a in store.accountRows { print("account: \(a.label) [\(a.detail ?? "")] = \(a.count)") }
    for s in store.deletedSessions.prefix(4) { print("deleted: \(s.projectName) | \(s.title) | \(fullDate(s.created))") }
    for s in store.visibleSessions.prefix(5) {
        print("- [\(s.source.label)] \(s.projectName) | \(s.title) | prompts=\(s.promptCount) running=\(store.isRunning(s))")
    }
}
