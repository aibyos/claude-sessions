import AppKit
import CryptoKit
import Foundation
import SwiftUI

// Self-update from GitHub releases.
//
// A release carries `Claude-Sessions.zip` and `Claude-Sessions.zip.sig`, an
// Ed25519 signature of the zip made by `package.sh` with a private key that
// never leaves the maintainer's Mac. The app only installs a zip whose
// signature matches `updatePublicKey`, whose bundle ID matches this app, and
// whose version is newer than the running one.

private let releasesAPI = "https://api.github.com/repos/aibyos/claude-sessions/releases/latest"
private let zipAsset = "Claude-Sessions.zip"
private let checkInterval: TimeInterval = 24 * 3600
/// Release notes containing this marker show a pop-up, not just a badge.
private let importantMarker = "[important]"

enum UpdateMode: String, CaseIterable, Identifiable {
    case auto, notify, off
    var id: Self { self }
    var label: String {
        switch self {
        case .auto: "Install updates automatically"
        case .notify: "Notify me, I'll install"
        case .off: "Don't check for updates"
        }
    }
}

struct ReleaseInfo: Equatable {
    var version: String
    var notes: String
    var important: Bool
    var zipURL: URL
    var sigURL: URL
    var pageURL: URL
}

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Status: Equatable {
        case idle, checking, upToDate
        case available(ReleaseInfo)
        case installing(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastCheck: Date?
    @Published var mode: UpdateMode? {
        didSet {
            guard !testing else { return }
            UserDefaults.standard.set(mode?.rawValue, forKey: "updateMode")
            if mode == .auto || mode == .notify { checkIfDue() }
        }
    }

    /// Set by `CLAUDE_SESSIONS_UPDATE_FEED`: reads releases from that URL,
    /// installs automatically, saves nothing and doesn't relaunch.
    private let testFeed = ProcessInfo.processInfo.environment["CLAUDE_SESSIONS_UPDATE_FEED"]
    private var testing: Bool { testFeed != nil }
    private var timer: Timer?
    private var latest: ReleaseInfo?

    var available: ReleaseInfo? {
        switch status {
        case .available(let r): r
        default: latest.flatMap { isNewer($0.version, than: appVersion) ? $0 : nil }
        }
    }

    private init() {
        mode = testing ? .auto : UserDefaults.standard.string(forKey: "updateMode").flatMap(UpdateMode.init)
        lastCheck = testing ? nil : UserDefaults.standard.object(forKey: "updateLastCheck") as? Date
    }

    func start() {
        if mode == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.askConsent() }
        }
        // Hourly ticks catch up after the Mac was asleep or the app was quit;
        // the check itself only runs once a day.
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in Updater.shared.checkIfDue() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            // Give Wi-Fi a moment to reconnect.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                MainActor.assumeIsolated { Updater.shared.checkIfDue() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (testing ? 1 : 8)) { self.checkIfDue() }
    }

    private func askConsent() {
        guard mode == nil else { return }
        let a = NSAlert()
        a.messageText = "Keep Claude Sessions up to date?"
        a.informativeText = """
            Once a day, Claude Sessions can check GitHub for a new version. It only downloads release information; nothing about you or your sessions is sent. Every update is checked against the developer's signature before it's installed.

            You can change this any time under ? → Updates.
            """
        a.addButton(withTitle: "Install Automatically")
        a.addButton(withTitle: "Just Notify Me")
        a.addButton(withTitle: "Don't Check")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: mode = .auto
        case .alertSecondButtonReturn: mode = .notify
        default: mode = .off
        }
    }

    /// Shows a made-up available update for screenshots.
    func loadDemo(_ r: ReleaseInfo) {
        latest = r
        status = .available(r)
        lastCheck = Date().addingTimeInterval(-3 * 3600)
    }

    // MARK: Checking

    func checkIfDue() {
        guard mode == .auto || mode == .notify else { return }
        if let r = available, mode == .auto {
            Task { await install(r, automatic: true) }  // retry a postponed install
            return
        }
        if let last = lastCheck, Date().timeIntervalSince(last) < checkInterval - 600 { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        if case .installing = status { return }
        status = .checking
        do {
            let release = try await fetchLatest()
            lastCheck = Date()
            if !testing { UserDefaults.standard.set(lastCheck, forKey: "updateLastCheck") }
            latest = release
            guard let r = release, isNewer(r.version, than: appVersion) else {
                status = .upToDate
                return
            }
            status = .available(r)
            if mode == .auto && !userInitiated {
                await install(r, automatic: true)
            } else if r.important && !userInitiated {
                announceImportant(r)
            }
        } catch {
            status = userInitiated ? .failed("Couldn't check for updates: \(error.localizedDescription)") : .idle
        }
    }

    private func fetchLatest() async throws -> ReleaseInfo? {
        var request = URLRequest(url: URL(string: testFeed ?? releasesAPI)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeSessions/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return nil }  // no releases yet
            guard http.statusCode == 200 else { throw UpdateError("GitHub answered with status \(http.statusCode)") }
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = obj["tag_name"] as? String,
            let assets = obj["assets"] as? [[String: Any]]
        else { throw UpdateError("Unexpected answer from GitHub") }
        func asset(_ name: String) -> URL? {
            (assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String).flatMap(URL.init)
        }
        guard let zip = asset(zipAsset), let sig = asset(zipAsset + ".sig") else { return nil }
        var notes = obj["body"] as? String ?? ""
        let important = notes.localizedCaseInsensitiveContains(importantMarker)
        notes = notes.replacingOccurrences(of: importantMarker, with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ReleaseInfo(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, notes: notes, important: important,
            zipURL: zip, sigURL: sig,
            pageURL: (obj["html_url"] as? String).flatMap(URL.init) ?? URL(string: repoURL + "/releases")!)
    }

    private func announceImportant(_ r: ReleaseInfo) {
        let key = "updateAnnounced"
        guard UserDefaults.standard.string(forKey: key) != r.version else { return }
        UserDefaults.standard.set(r.version, forKey: key)
        let a = NSAlert()
        a.messageText = "Important update: Claude Sessions \(r.version)"
        a.informativeText = String(r.notes.prefix(600))
        a.addButton(withTitle: "Install Now")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            Task { await install(r, automatic: false) }
        }
    }

    // MARK: Installing

    /// Why this copy can't replace itself, if it can't.
    var installBlocker: String? {
        let app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/") {
            return "macOS is running this copy from a temporary location. Move Claude Sessions to your Applications folder and open it from there."
        }
        let fm = FileManager.default
        if !fm.isWritableFile(atPath: app.deletingLastPathComponent().path) || !fm.isWritableFile(atPath: app.path) {
            return "This user can't change \(app.deletingLastPathComponent().path). Download the new version from GitHub instead."
        }
        return nil
    }

    func install(_ r: ReleaseInfo, automatic: Bool) async {
        if case .installing = status { return }
        if let blocker = installBlocker {
            status = .available(r)
            if !automatic {
                Actions.alert("Can't update automatically", blocker)
                NSWorkspace.shared.open(r.pageURL)
            }
            return
        }
        // Don't restart under someone who has the window open; try again next hour.
        if automatic && NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            status = .available(r)
            return
        }
        do {
            status = .installing("Downloading \(r.version)…")
            let (zip, _) = try await URLSession.shared.data(from: r.zipURL)
            let (sigData, _) = try await URLSession.shared.data(from: r.sigURL)
            guard verifySignature(zip: zip, signature: sigData) else {
                throw UpdateError("The download isn't signed by the developer, so it wasn't installed.")
            }

            status = .installing("Installing \(r.version)…")
            let current = Bundle.main.bundleURL
            let fm = FileManager.default
            // A staging folder on the same volume, so the swap is a rename.
            let stage = try fm.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true)
            defer { try? fm.removeItem(at: stage) }
            let zipFile = stage.appendingPathComponent(zipAsset)
            try zip.write(to: zipFile)
            try await run("/usr/bin/ditto", ["-x", "-k", zipFile.path, stage.path])
            let newApp = stage.appendingPathComponent(current.lastPathComponent)
            let fallback = stage.appendingPathComponent("Claude Sessions.app")
            let app = fm.fileExists(atPath: newApp.path) ? newApp : fallback
            guard let info = Bundle(url: app)?.infoDictionary,
                info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                let version = info["CFBundleShortVersionString"] as? String,
                isNewer(version, than: appVersion)
            else { throw UpdateError("The download doesn't contain a newer Claude Sessions.") }
            try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
            _ = try fm.replaceItemAt(current, withItemAt: app)

            if testing {
                print("updated \(current.path) to \(version)")
                exit(0)
            }
            relaunch(current)
        } catch {
            status = .failed(error.localizedDescription)
            if !automatic { Actions.alert("Update failed", error.localizedDescription) }
        }
    }

    private func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ args: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 { throw UpdateError("\(tool) failed (\(p.terminationStatus))") }
        }.value
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Numeric comparison of dotted versions: 0.10.0 > 0.9.2.
func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }
    let y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0
        let r = i < y.count ? y[i] : 0
        if l != r { return l > r }
    }
    return false
}

func verifySignature(zip: Data, signature: Data) -> Bool {
    guard let keyData = Data(base64Encoded: updatePublicKey),
        let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
        let sig = Data(base64Encoded: String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    else { return false }
    return key.isValidSignature(sig, for: zip)
}

// MARK: - Release tooling (used by package.sh)

/// `--generate-update-key <file>`: writes a new private key and prints its public key.
func generateUpdateKey(at path: String) {
    guard !FileManager.default.fileExists(atPath: path) else {
        FileHandle.standardError.write(Data("\(path) already exists; not overwriting it.\n".utf8))
        exit(1)
    }
    let key = Curve25519.Signing.PrivateKey()
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
        attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
}

/// `--sign-update <zip> <key file>`: prints the base64 signature of the zip.
func signUpdate(zip: String, keyFile: String) {
    guard let zipData = FileManager.default.contents(atPath: zip),
        let keyText = FileManager.default.contents(atPath: keyFile),
        let raw = Data(base64Encoded: String(decoding: keyText, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
        let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw),
        let sig = try? key.signature(for: zipData)
    else {
        FileHandle.standardError.write(Data("Couldn't sign \(zip) with \(keyFile).\n".utf8))
        exit(1)
    }
    guard key.publicKey.rawRepresentation.base64EncodedString() == updatePublicKey else {
        FileHandle.standardError.write(Data("\(keyFile) doesn't match the public key built into the app.\n".utf8))
        exit(1)
    }
    print(sig.base64EncodedString())
}

// MARK: - Views

/// Banner in the menu bar panel while an update is available or installing.
struct UpdateBanner: View {
    @ObservedObject var updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch updater.status {
        case .installing(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.callout)
                Spacer()
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
        case .available(let r):
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Version \(r.version) is available").font(.callout.weight(.medium))
                    Button("What's new") {
                        HelpModel.shared.topic = .updates
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "help")
                    }
                    .buttonStyle(.link).font(.caption)
                }
                Spacer()
                Button("Install") { Task { await updater.install(r, automatic: false) } }
                    .controlSize(.small)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
        default:
            EmptyView()
        }
    }
}

/// The Updates help page: setting, status and Check Now.
struct UpdatesHelp: View {
    @ObservedObject var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You have version \(appVersion).")
            Picker("Updates", selection: Binding(get: { updater.mode ?? .notify }, set: { updater.mode = $0 })) {
                ForEach(UpdateMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            HStack(spacing: 10) {
                Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                    .disabled(updater.status == .checking)
                statusText
            }
            if let r = updater.available {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Version \(r.version)").font(.headline)
                    if !r.notes.isEmpty {
                        Text((try? AttributedString(markdown: r.notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(r.notes))
                            .font(.callout)
                    }
                    HStack {
                        Button("Install and Restart") { Task { await updater.install(r, automatic: false) } }
                            .buttonStyle(.borderedProminent)
                        Link("Release page", destination: r.pageURL)
                    }
                    if let blocker = updater.installBlocker {
                        Text(blocker).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            Divider()
            H("How updates work")
            Bullets([
                "Once a day, and when your Mac wakes up, the app asks GitHub whether there's a newer release of Claude Sessions. Nothing about you or your sessions is sent; it's an anonymous request, like opening the release page.",
                "**Install automatically**: the update is downloaded, checked and installed, and the app restarts in about a second. If the window is open, it waits until you close it.",
                "**Notify me**: a ↑ appears next to the menu bar icon and the panel shows an **Install** button. Important updates also show a pop-up.",
                "Every update is signed by the developer. The app checks the signature, that it really is Claude Sessions, and that the version is newer, before replacing itself. Anything else is refused.",
                "Updating needs the app to sit in a folder you can change, such as Applications. A copy run straight from Downloads can't update itself.",
            ])
            if let last = updater.lastCheck {
                Text("Last checked \(last.formatted(.relative(presentation: .named))).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var statusText: some View {
        switch updater.status {
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Label("You're up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .installing(let t):
            Text(t).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.orange).font(.callout)
        default:
            EmptyView()
        }
    }
}
