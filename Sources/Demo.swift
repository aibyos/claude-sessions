import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// `ClaudeSessions --make-media <dir>` renders the README screenshots and the
// demo GIF from made-up sample data, so no real session ever ends up in them.

// MARK: - Sample data

private let workAccount = "a1b2c3d4-work"
private let personalAccount = "e5f6a7b8-personal"

private func ago(_ minutes: Double) -> Date { Date().addingTimeInterval(-minutes * 60) }

private func sample(
    _ n: Int, _ title: String, project: String, branch: String? = "main", minutesAgo: Double,
    source: String = "claude-vscode", account: String? = workAccount, prompts: [String],
    prs: [PRLink] = [], sizeMB: Double = 2.4
) -> SessionInfo {
    let id = String(format: "%08x-4c1d-4e2f-9a3b-%012x", 0x5e55_1000 + n, n * 7919)
    let created = ago(minutesAgo + Double(prompts.count) * 9)
    var s = SessionInfo(
        id: id, filePath: "~/.claude/projects/-Users-you-code-\(project)/\(id).jsonl",
        projectFolder: "-Users-you-code-\(project)", cwd: "/Users/you/code/\(project)",
        lastActivity: ago(minutesAgo), fileSize: UInt64(sizeMB * 1_000_000))
    s.aiTitle = title
    s.gitBranch = branch
    s.entrypoint = source
    s.version = "2.1.320"
    s.model = "claude-opus-5-5"
    s.created = created
    s.accountId = account
    s.prompts = prompts.enumerated().map { i, p in
        Prompt(text: p, time: created.addingTimeInterval(Double(i) * 9 * 60))
    }
    s.promptCount = prompts.count
    s.prs = prs
    return s
}

@MainActor
private func loadSampleData(into store: SessionStore) {
    let sessions = [
        sample(
            1, "Add dark mode to the settings page", project: "acme-web", branch: "feature/dark-mode",
            minutesAgo: 0.3,
            prompts: [
                "Add a dark mode toggle to the settings page and remember the choice per user",
                "The page flashes white on first load in dark mode. Can you fix that?",
                "Write tests for the useTheme hook",
                "Looks good. Open a PR.",
            ],
            prs: [PRLink(number: 142, url: "https://github.com/acme/acme-web/pull/142", repo: "acme/acme-web")]),
        sample(
            2, "Fix flaky checkout tests", project: "acme-web", minutesAgo: 24, source: "cli",
            prompts: [
                "checkout.spec.ts fails about 1 in 5 runs on CI. Find out why",
                "Use fake timers instead of the real clock",
            ]),
        sample(
            3, "Retries for the nightly ETL job", project: "data-pipeline", branch: "feature/retries",
            minutesAgo: 70,
            prompts: [
                "The nightly ETL job dies when the warehouse times out. Add retries with backoff",
                "Log every retry with the batch id",
                "Add an alert if a batch still fails after 5 retries",
            ]),
        sample(
            4, "Split Terraform into modules", project: "infra", minutesAgo: 190, source: "cli",
            prompts: [
                "Our main.tf is 2,000 lines. Propose a module structure",
                "Do the networking module first and keep the state addresses stable",
            ]),
        sample(
            5, "Evaluation notebook for the classifier", project: "ml-experiments", minutesAgo: 60 * 26,
            account: personalAccount,
            prompts: [
                "Make a notebook that compares the three classifier checkpoints on the holdout set",
                "Add a confusion matrix and per-class F1",
            ], sizeMB: 9.1),
        sample(
            6, "Blog post: shipping smaller PRs", project: "personal-site", minutesAgo: 60 * 50,
            account: personalAccount,
            prompts: ["Help me outline a blog post about shipping smaller pull requests"]),
        sample(
            7, "Push notifications for iOS", project: "mobile-app", branch: "feature/push",
            minutesAgo: 60 * 75,
            prompts: [
                "Set up push notifications for the iOS app with APNs",
                "Ask for permission only after the first order, not on launch",
            ]),
        sample(
            8, "Explain the auth middleware", project: "acme-web", minutesAgo: 60 * 24 * 5, source: "cli",
            account: nil,
            prompts: ["Walk me through how the auth middleware decides which routes are public"]),
        sample(
            9, "Search for the docs site", project: "docs-site", minutesAgo: 60 * 24 * 12, account: nil,
            prompts: ["Add full-text search to the docs site", "Make the search box work with ⌘K"]),
        sample(
            10, "Kafka consumer lag alerts", project: "data-pipeline", minutesAgo: 60 * 24 * 27, account: nil,
            prompts: [
                "Alert when consumer lag on the orders topic is above 10k for 5 minutes",
                "Send the alert to the #data-oncall channel",
            ]),
    ]
    let running = [
        RunningSession(
            pid: 40121, sessionId: sessions[0].id, cwd: sessions[0].projectPath, startedAt: ago(45),
            version: "2.1.320", kind: "interactive", footprint: 412_000_000),
        RunningSession(
            pid: 39877, sessionId: sessions[1].id, cwd: sessions[1].projectPath, startedAt: ago(30),
            version: "2.1.320", kind: "interactive", footprint: 236_000_000),
        RunningSession(
            pid: 38410, sessionId: sessions[2].id, cwd: sessions[2].projectPath, startedAt: ago(60 * 5),
            version: "2.1.320", kind: "interactive", footprint: 301_000_000),
        RunningSession(
            pid: 21544, sessionId: sessions[4].id, cwd: sessions[4].projectPath, startedAt: ago(60 * 24 * 9),
            version: "2.1.301", kind: "interactive", footprint: 688_000_000),
    ]
    var deleted: [SessionInfo] = []
    for (i, (title, project, days)) in [
        ("Set up the CI pipeline for the monorepo", "acme-web", 64.0),
        ("Why is the Docker build so slow?", "infra", 71.0),
        ("Prototype the onboarding flow", "mobile-app", 88.0),
    ].enumerated() {
        var d = sample(
            50 + i, title, project: project, minutesAgo: 60 * 24 * days, account: nil, prompts: [title])
        d.aiTitle = nil
        d.isDeleted = true
        d.messageCount = [46, 18, 73][i]
        d.fileSize = 0
        d.model = nil
        d.version = nil
        deleted.append(d)
    }
    store.loadDemo(
        sessions: sessions, running: running, deleted: deleted,
        accounts: [
            workAccount: AccountInfo(email: "you@acme.example", org: "Acme Corp"),
            personalAccount: AccountInfo(email: "you@personal.example", org: nil),
        ],
        currentAccount: workAccount,
        workspaces: ["/Users/you/code/acme-web", "/Users/you/code/data-pipeline"])
    Favorite.assumeExist = true
    let code = "/Users/you/code/"
    FavoritesStore.shared.loadDemo(
        [
            Favorite(path: code + "acme-web", name: "acme-web", group: "Acme"),
            Favorite(path: code + "data-pipeline", name: "data-pipeline", group: "Acme"),
            Favorite(path: code + "infra", name: "infra", group: "Acme"),
            Favorite(path: code + "ml-experiments", name: "ml-experiments", group: "Research"),
            Favorite(path: code + "personal-site", name: "personal-site"),
            Favorite(path: code + "dotfiles", name: "dotfiles"),
        ], memory: 2_870_000_000)
}

// MARK: - Rendering

private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class Snapshotter {
    let window: NSWindow
    let host: NSHostingView<AnyView>

    init(size: CGSize) {
        host = NSHostingView(rootView: AnyView(EmptyView()))
        window = KeyWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
    }

    func activate() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func show<V: View>(_ view: V) {
        activate()
        host.rootView = AnyView(view.environment(\.colorScheme, .light))
    }

    func capture(settle: TimeInterval = 0.8) -> CGImage? {
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }
}

/// Places a window capture on a soft background with macOS-style chrome.
private func framed(_ content: CGImage, canvas: CGSize, title: String) -> CGImage? {
    let scale = CGFloat(content.width) / (canvas.width - 80)
    let w = Int(canvas.width * scale)
    let h = Int(canvas.height * scale)
    guard
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let full = CGRect(x: 0, y: 0, width: w, height: h)
    drawBackground(ctx, full)

    let titleBar = 30 * scale
    let win = CGRect(
        x: 40 * scale, y: 30 * scale, width: CGFloat(content.width), height: CGFloat(content.height) + titleBar)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 40 * scale, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(CGPath(roundedRect: win, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: win, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil))
    ctx.clip()
    ctx.draw(content, in: CGRect(x: win.minX, y: win.minY, width: win.width, height: CGFloat(content.height)))
    let bar = CGRect(x: win.minX, y: win.maxY - titleBar, width: win.width, height: titleBar)
    ctx.setFillColor(CGColor(gray: 0.96, alpha: 1))
    ctx.fill(bar)
    ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
    ctx.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: max(1, scale)))
    for (i, c) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
        ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: bar.minX + (14 + CGFloat(i) * 20) * scale, y: bar.midY - 6 * scale, width: 12 * scale, height: 12 * scale))
    }
    ctx.restoreGState()
    drawText(ctx, title, at: CGPoint(x: bar.midX, y: bar.midY), size: 13 * scale, bold: true, centered: true)
    return ctx.makeImage()
}

/// Places the menu bar panel under a mock menu bar, as it appears on screen.
private func framedPanel(_ panel: CGImage, canvas: CGSize, running: Int, reference: CGImage) -> CGImage? {
    let scale = CGFloat(reference.width) / (canvas.width - 80)
    let w = Int(canvas.width * scale)
    let h = Int(canvas.height * scale)
    guard
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    drawBackground(ctx, CGRect(x: 0, y: 0, width: w, height: h))

    let barH = 26 * scale
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.55))
    ctx.fill(CGRect(x: 0, y: CGFloat(h) - barH, width: CGFloat(w), height: barH))
    let barY = CGFloat(h) - barH / 2
    drawText(ctx, "", at: CGPoint(x: 22 * scale, y: barY), size: 15 * scale, bold: false, centered: true)
    drawText(ctx, "Finder   File   Edit   View   Go   Window   Help", at: CGPoint(x: 44 * scale, y: barY), size: 13 * scale, bold: false, centered: false)
    drawText(ctx, "Mon 9 Nov  10:41", at: CGPoint(x: CGFloat(w) - 130 * scale, y: barY), size: 13 * scale, bold: false, centered: false)

    // Status item: icon + running count, highlighted because the panel is open.
    let itemX = CGFloat(w) - 230 * scale
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.12))
    ctx.addPath(CGPath(roundedRect: CGRect(x: itemX - 8 * scale, y: CGFloat(h) - barH + 3 * scale, width: 52 * scale, height: barH - 6 * scale), cornerWidth: 5 * scale, cornerHeight: 5 * scale, transform: nil))
    ctx.fillPath()
    if let sym = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 13 * scale, weight: .regular)),
        let cg = sym.cgImage(forProposedRect: nil, context: nil, hints: nil)
    {
        let s = CGSize(width: sym.size.width, height: sym.size.height)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: itemX, y: barY - s.height / 2, width: s.width, height: s.height), mask: cg)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: itemX, y: barY - s.height / 2, width: s.width, height: s.height))
        ctx.restoreGState()
        drawText(ctx, "\(running)", at: CGPoint(x: itemX + s.width + 4 * scale, y: barY), size: 13 * scale, bold: false, centered: false)
    }

    let p = CGRect(
        x: min(itemX + 20 * scale - CGFloat(panel.width) / 2, CGFloat(w) - CGFloat(panel.width) - 24 * scale), y: CGFloat(h) - barH - 8 * scale - CGFloat(panel.height),
        width: CGFloat(panel.width), height: CGFloat(panel.height))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 36 * scale, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(CGPath(roundedRect: p, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: p, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil))
    ctx.clip()
    ctx.draw(panel, in: p)
    ctx.restoreGState()
    return ctx.makeImage()
}

private func drawBackground(_ ctx: CGContext, _ rect: CGRect) {
    let colors = [
        CGColor(red: 0.98, green: 0.80, blue: 0.68, alpha: 1),
        CGColor(red: 0.86, green: 0.70, blue: 0.86, alpha: 1),
        CGColor(red: 0.68, green: 0.74, blue: 0.95, alpha: 1),
    ] as CFArray
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: rect.maxX, y: 0), options: [])
}

private func drawText(_ ctx: CGContext, _ text: String, at p: CGPoint, size: CGFloat, bold: Bool, centered: Bool) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
        .foregroundColor: NSColor(white: 0.15, alpha: 1),
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    let sz = s.size()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    s.draw(at: CGPoint(x: centered ? p.x - sz.width / 2 : p.x, y: p.y - sz.height / 2))
    NSGraphicsContext.restoreGraphicsState()
}

private func resized(_ image: CGImage, width: Int) -> CGImage? {
    let height = Int(Double(image.height) * Double(width) / Double(image.width))
    guard
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}

private func writePNG(_ image: CGImage, _ url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        return
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

private func writeGIF(_ frames: [(CGImage, Double)], _ url: URL) {
    guard
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
    else { return }
    CGImageDestinationSetProperties(
        dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for (image, delay) in frames {
        CGImageDestinationAddImage(
            dest, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }
    CGImageDestinationFinalize(dest)
}

// MARK: - Script

@MainActor
func makeMedia(to dir: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let out = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    let store = SessionStore.shared
    loadSampleData(into: store)
    store.showDeleted = false
    let ids = store.sessions.map(\.id)

    let canvas = CGSize(width: 1320, height: 800)
    let windowSize = CGSize(width: canvas.width - 80, height: canvas.height - 90)
    let main = Snapshotter(size: windowSize)
    let panelShot = Snapshotter(size: CGSize(width: 420, height: 600))
    let help = Snapshotter(size: windowSize)

    // A reference capture fixes the pixel scale for the panel frames.
    main.show(MainView(store: store))
    store.filter = .all
    store.selection = ids[0]
    guard let reference = main.capture(settle: 1.5) else {
        print("capture failed")
        return
    }

    var frames: [(CGImage, Double)] = []
    var stills: [String: CGImage] = [:]

    func panelFrame(_ tab: MenuPanel.Tab, query: String = "", delay: Double, still: String? = nil) {
        panelShot.show(MenuPanel(store: store, initialTab: tab, initialQuery: query).id("\(tab)|\(query)"))
        guard let img = panelShot.capture(),
            let f = framedPanel(img, canvas: canvas, running: store.count(.running), reference: reference)
        else { return }
        frames.append((f, delay))
        if let still { stills[still] = f }
    }

    func mainFrame(_ filter: SidebarFilter, select: String?, delay: Double, still: String? = nil) {
        store.filter = filter
        store.selection = select
        main.show(MainView(store: store))
        guard let img = main.capture(), let f = framed(img, canvas: canvas, title: "Claude Sessions") else { return }
        frames.append((f, delay))
        if let still { stills[still] = f }
    }

    func helpFrame(_ topic: HelpTopic, delay: Double, still: String? = nil) {
        HelpModel.shared.topic = topic
        help.show(HelpView(store: store))
        guard let img = help.capture(), let f = framed(img, canvas: canvas, title: "How Claude Sessions works")
        else { return }
        frames.append((f, delay))
        if let still { stills[still] = f }
    }

    panelFrame(.recent, delay: 2.6, still: "panel")
    panelFrame(.running, delay: 2.0)
    panelFrame(.recent, query: "terraform", delay: 1.8)
    panelFrame(.favorites, delay: 2.6, still: "favorites")
    mainFrame(.all, select: ids[0], delay: 3.2, still: "main")
    mainFrame(.favorite("/Users/you/code/data-pipeline"), select: ids[2], delay: 2.6, still: "favorites-window")
    mainFrame(.running, select: ids[4], delay: 3.0, still: "running")
    mainFrame(.account(personalAccount), select: ids[5], delay: 2.4)
    mainFrame(.expiring, select: ids[9], delay: 2.6)
    store.showDeleted = true
    mainFrame(.deleted, select: store.deletedSessions.first?.id, delay: 2.6, still: "deleted")
    store.showDeleted = false
    helpFrame(.cleanup, delay: 3.2, still: "help")
    helpFrame(.accounts, delay: 2.6)
    helpFrame(.favorites, delay: 2.4)

    // GIF at 1x keeps the file small; stills stay at full resolution.
    let gifFrames = frames.compactMap { f, d in resized(f, width: Int(canvas.width)).map { ($0, d) } }
    writeGIF(gifFrames, out.appendingPathComponent("demo.gif"))
    for (name, image) in stills { writePNG(image, out.appendingPathComponent("\(name).png")) }
    print("wrote demo.gif (\(gifFrames.count) frames) and \(stills.count) screenshots to \(dir)")
}
