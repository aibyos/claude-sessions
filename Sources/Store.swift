import Darwin
import Foundation
import SwiftUI

enum SidebarFilter: Hashable {
    case running, today, week, all, expiring, deleted
    case project(String)
    /// Account UUID, or "" for sessions that don't record one.
    case account(String)
}

struct AccountInfo: Codable, Hashable, Sendable {
    var email: String
    var org: String?
}

/// Everything a background scan produces besides the per-file cache.
private struct ScanExtras: Sendable {
    var deleted: [SessionInfo] = []
    var emptyProjects: [String] = []
    var accounts: [String: AccountInfo] = [:]
    var currentAccount: String?
}

private struct CacheEntry: Codable {
    var mtime: Double
    var size: UInt64
    var info: SessionInfo
}

private struct CacheFile: Codable {
    static let currentVersion = 4
    var version: Int
    var entries: [String: CacheEntry]
}

private let cacheURL: URL = {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeSessions", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("index.json")
}()

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var running: [String: RunningSession] = [:]
    @Published private(set) var vscodeWorkspaces: [String] = []
    @Published private(set) var cleanupDays = defaultCleanupDays
    @Published private(set) var cleanupIsExplicit = false
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?

    /// Sessions whose transcript was deleted by cleanup but whose summary
    /// survives in an old `sessions-index.json`.
    @Published private(set) var deletedSessions: [SessionInfo] = []
    /// Project folders with no transcripts and no surviving summaries.
    @Published private(set) var emptyProjects: [String] = []
    /// Every Claude account seen on this Mac, by account UUID.
    @Published private(set) var accounts: [String: AccountInfo] = [:]
    @Published private(set) var currentAccountId: String?

    @Published var showDeleted = UserDefaults.standard.bool(forKey: "showDeleted") {
        didSet {
            UserDefaults.standard.set(showDeleted, forKey: "showDeleted")
            if !showDeleted && filter == .deleted { filter = .all }
        }
    }

    @Published var filter: SidebarFilter = .all
    @Published var selection: String?
    @Published var search = ""

    private var cache: [String: CacheEntry] = [:]
    private var timer: Timer?
    private var tick = 0

    private init() {
        if let data = try? Data(contentsOf: cacheURL),
            let file = try? JSONDecoder().decode(CacheFile.self, from: data),
            file.version == CacheFile.currentVersion
        {
            cache = file.entries
            publish()
        }
        if let data = UserDefaults.standard.data(forKey: "knownAccounts"),
            let known = try? JSONDecoder().decode([String: AccountInfo].self, from: data)
        {
            accounts = known
        }
    }

    func start() {
        refreshLive()
        readCleanupSetting()
        rescan()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.timerFired() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func timerFired() {
        tick += 1
        refreshLive()
        if tick % 6 == 0 {  // every 30 s
            readCleanupSetting()
            rescan()
        }
    }

    /// Replaces live data with a fixed sample set and stops refreshing.
    /// Used to render the README screenshots without exposing real sessions.
    func loadDemo(
        sessions: [SessionInfo], running: [RunningSession], deleted: [SessionInfo],
        accounts: [String: AccountInfo], currentAccount: String, workspaces: [String]
    ) {
        timer?.invalidate()
        timer = nil
        self.sessions = sessions
        self.running = Dictionary(uniqueKeysWithValues: running.map { ($0.sessionId, $0) })
        deletedSessions = deleted
        emptyProjects = []
        self.accounts = accounts
        currentAccountId = currentAccount
        vscodeWorkspaces = workspaces
        cleanupDays = defaultCleanupDays
        cleanupIsExplicit = false
        lastScan = .now
    }

    // MARK: Transcript index

    func rescan() {
        guard !isScanning else { return }
        isScanning = true
        let previous = cache
        Task.detached(priority: .utility) { [weak self] in
            let entries = Self.scan(previous: previous)
            let extras = Self.scanExtras(liveFiles: Set(entries.keys))
            await self?.finishScan(entries, extras)
        }
    }

    private func finishScan(_ entries: [String: CacheEntry], _ extras: ScanExtras) {
        cache = entries
        isScanning = false
        lastScan = .now
        deletedSessions = extras.deleted.sorted { $0.lastActivity > $1.lastActivity }
        emptyProjects = extras.emptyProjects
        currentAccountId = extras.currentAccount
        // Remember every account ever seen, so an account stays named after
        // you sign out of it.
        let merged = accounts.merging(extras.accounts) { _, new in new }
        if merged != accounts {
            accounts = merged
            if let data = try? JSONEncoder().encode(merged) {
                UserDefaults.standard.set(data, forKey: "knownAccounts")
            }
        }
        publish()
        let file = CacheFile(version: CacheFile.currentVersion, entries: entries)
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(file) { try? data.write(to: cacheURL, options: .atomic) }
        }
    }

    private func publish() {
        sessions = cache.values.map(\.info).sorted { $0.lastActivity > $1.lastActivity }
    }

    nonisolated private static func scan(previous: [String: CacheEntry]) -> [String: CacheEntry] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let projects = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var result: [String: CacheEntry] = [:]
        for project in projects {
            guard
                let files = try? fm.contentsOfDirectory(
                    at: project, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: keys)
                let mtime = values?.contentModificationDate ?? .distantPast
                let size = UInt64(values?.fileSize ?? 0)
                if let old = previous[file.path], old.mtime == mtime.timeIntervalSince1970, old.size == size {
                    result[file.path] = old
                    continue
                }
                if let info = parseSession(
                    at: file, projectFolder: project.lastPathComponent, size: size, mtime: mtime)
                {
                    result[file.path] = CacheEntry(mtime: mtime.timeIntervalSince1970, size: size, info: info)
                }
            }
        }
        return result
    }

    /// Deleted-session summaries, empty project folders and account names.
    nonisolated private static func scanExtras(liveFiles: Set<String>) -> ScanExtras {
        var extras = ScanExtras()
        let fm = FileManager.default

        // Accounts: the signed-in one, plus the previous one in the backup copy.
        for (i, name) in [".claude.json", ".claude.json.backup"].enumerated() {
            guard let data = try? Data(contentsOf: homeDir.appendingPathComponent(name)),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let acct = obj["oauthAccount"] as? [String: Any],
                let id = acct["accountUuid"] as? String,
                let email = acct["emailAddress"] as? String
            else { continue }
            extras.accounts[id] = AccountInfo(email: email, org: acct["organizationName"] as? String)
            if i == 0 { extras.currentAccount = id }
        }

        // Real project paths, to name folders that have no transcripts left.
        var knownPaths: [String: String] = [:]
        if let data = try? Data(contentsOf: homeDir.appendingPathComponent(".claude.json")),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let projects = obj["projects"] as? [String: Any]
        {
            for path in projects.keys { knownPaths[encodeProjectPath(path)] = path }
        }

        let projects = (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        for project in projects {
            let files = (try? fm.contentsOfDirectory(atPath: project.path)) ?? []
            let hasLive = files.contains { $0.hasSuffix(".jsonl") }
            var foundDeleted = false

            let index = project.appendingPathComponent("sessions-index.json")
            if let data = try? Data(contentsOf: index),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let entries = obj["entries"] as? [[String: Any]]
            {
                for e in entries {
                    guard let id = e["sessionId"] as? String, e["isSidechain"] as? Bool != true else { continue }
                    let path = e["fullPath"] as? String ?? ""
                    if liveFiles.contains(path) || fm.fileExists(atPath: path) { continue }
                    let created = (e["created"] as? String).flatMap(parseISODate)
                    let modified = (e["modified"] as? String).flatMap(parseISODate) ?? created ?? .distantPast
                    let first = cleanIndexPrompt(e["firstPrompt"] as? String ?? "")
                    var s = SessionInfo(
                        id: id, filePath: path, projectFolder: project.lastPathComponent,
                        cwd: e["projectPath"] as? String ?? knownPaths[project.lastPathComponent],
                        lastActivity: modified, fileSize: 0)
                    s.created = created
                    s.gitBranch = e["gitBranch"] as? String
                    s.prompts = first.isEmpty ? [] : [Prompt(text: first, time: created)]
                    s.promptCount = s.prompts.count
                    s.messageCount = e["messageCount"] as? Int
                    s.isDeleted = true
                    extras.deleted.append(s)
                    foundDeleted = true
                }
            }
            if !hasLive && !foundDeleted {
                extras.emptyProjects.append(knownPaths[project.lastPathComponent] ?? project.lastPathComponent)
            }
        }
        return extras
    }

    // MARK: Running sessions and open VS Code windows

    func refreshLive() {
        running = Self.readRunning()
        vscodeWorkspaces = Self.readVSCodeWorkspaces()
    }

    nonisolated private static func readRunning() -> [String: RunningSession] {
        let dir = claudeDir.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var result: [String: RunningSession] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let pid = (obj["pid"] as? NSNumber)?.int32Value,
                let sessionId = obj["sessionId"] as? String,
                isClaudeProcess(pid)
            else { continue }
            let started = (obj["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            result[sessionId] = RunningSession(
                pid: pid, sessionId: sessionId, cwd: obj["cwd"] as? String ?? "",
                startedAt: started, version: obj["version"] as? String, kind: obj["kind"] as? String,
                footprint: footprint(pid))
        }
        return result
    }

    nonisolated private static func readVSCodeWorkspaces() -> [String] {
        let dir = claudeDir.appendingPathComponent("ide")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.flatMap { file -> [String] in
            guard file.pathExtension == "lock", let data = try? Data(contentsOf: file),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let pid = (obj["pid"] as? NSNumber)?.int32Value, kill(pid, 0) == 0 || errno == EPERM
            else { return [] }
            return obj["workspaceFolders"] as? [String] ?? []
        }
    }

    // MARK: Derived data

    func isRunning(_ s: SessionInfo) -> Bool { running[s.id] != nil }

    func isOpenInVSCode(_ s: SessionInfo) -> Bool {
        vscodeWorkspaces.contains { s.projectPath == $0 || s.projectPath.hasPrefix($0 + "/") }
    }

    /// Approximate date Claude Code's cleanup will delete this transcript.
    func expiry(_ s: SessionInfo) -> Date {
        s.lastActivity.addingTimeInterval(Double(cleanupDays) * 86_400)
    }

    func expiresSoon(_ s: SessionInfo) -> Bool {
        !s.isDeleted && !s.isUnsaved && !isRunning(s) && expiry(s).timeIntervalSinceNow < 5 * 86_400
    }

    /// Sessions worth listing: ones with at least one prompt, or that are
    /// running, plus deleted-session summaries when the toggle is on.
    var visibleSessions: [SessionInfo] {
        let live = sessions.filter { $0.promptCount > 0 || running[$0.id] != nil }
        let all = (live + unsavedRunning).sorted { $0.lastActivity > $1.lastActivity }
        return showDeleted ? all + deletedSessions : all
    }

    /// Running processes whose session has no transcript (a tab opened but
    /// never used, or a transcript already removed by cleanup). They still use
    /// memory, so they're listed and can be stopped.
    var unsavedRunning: [SessionInfo] {
        let known = Set(sessions.map(\.id))
        return running.values.filter { !known.contains($0.sessionId) }.map { r in
            var s = SessionInfo(
                id: r.sessionId, filePath: "", projectFolder: encodeProjectPath(r.cwd), cwd: r.cwd,
                lastActivity: r.startedAt ?? .distantPast, fileSize: 0)
            s.created = r.startedAt
            s.aiTitle = "Running · nothing saved"
            s.version = r.version
            s.isUnsaved = true
            return s
        }
    }

    func sessions(for filter: SidebarFilter, search: String) -> [SessionInfo] {
        let calendar = Calendar.current
        return visibleSessions.filter { s in
            let keep: Bool =
                switch filter {
                case .running: isRunning(s)
                case .today: calendar.isDateInToday(s.lastActivity)
                case .week: s.lastActivity.timeIntervalSinceNow > -7 * 86_400
                case .all: true
                case .expiring: expiresSoon(s)
                case .deleted: s.isDeleted
                case .project(let path): s.projectPath == path
                case .account(let id): (s.accountId ?? "") == id
                }
            return keep && s.matches(search)
        }
    }

    func count(_ filter: SidebarFilter) -> Int { sessions(for: filter, search: "").count }

    /// Projects with their session counts. With deleted sessions shown, this
    /// also lists folders whose conversations are all gone (count 0).
    var projects: [(path: String, name: String, count: Int, last: Date, onlyDeleted: Bool)] {
        var list = Dictionary(grouping: visibleSessions, by: \.projectPath)
            .map { path, items in
                (
                    path: path, name: (path as NSString).lastPathComponent, count: items.count,
                    last: items.map(\.lastActivity).max() ?? .distantPast,
                    onlyDeleted: items.allSatisfy(\.isDeleted)
                )
            }
            .sorted { $0.last > $1.last }
        if showDeleted {
            list += emptyProjects.map {
                (path: $0, name: projectDisplayName($0), count: 0, last: .distantPast, onlyDeleted: true)
            }
        }
        return list
    }

    /// Accounts that own at least one listed session; "" = not recorded.
    var accountRows: [(id: String, label: String, detail: String?, count: Int)] {
        Dictionary(grouping: visibleSessions) { $0.accountId ?? "" }
            .map { id, items in
                let info = accounts[id]
                let label =
                    id.isEmpty ? "Not recorded" : (info?.email ?? "Account \(id.prefix(8))…")
                var detail = info?.org
                if id == currentAccountId { detail = "Signed in now" + (info?.org.map { " · \($0)" } ?? "") }
                return (id, label, detail, items.count)
            }
            .sorted { ($0.id.isEmpty ? 1 : 0, -$0.count) < ($1.id.isEmpty ? 1 : 0, -$1.count) }
    }

    func accountLabel(_ s: SessionInfo) -> String {
        guard let id = s.accountId else { return "Not recorded (older Claude Code version)" }
        let base = accounts[id].map { $0.email + ($0.org.map { " · \($0)" } ?? "") } ?? "Account \(id)"
        return id == currentAccountId ? base + " (signed in now)" : base
    }

    var runningFootprint: UInt64 { running.values.reduce(0) { $0 + $1.footprint } }

    var selectedSession: SessionInfo? {
        guard let selection else { return nil }
        return sessions.first { $0.id == selection } ?? deletedSessions.first { $0.id == selection }
            ?? unsavedRunning.first { $0.id == selection }
    }

    var totalTranscriptBytes: UInt64 { sessions.reduce(0) { $0 + $1.fileSize } }
    var oldestSession: Date? { sessions.map(\.lastActivity).min() }

    // MARK: cleanupPeriodDays in ~/.claude/settings.json

    func readCleanupSetting() {
        guard let data = try? Data(contentsOf: settingsFile),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let days = (obj["cleanupPeriodDays"] as? NSNumber)?.intValue
        else {
            cleanupDays = defaultCleanupDays
            cleanupIsExplicit = false
            return
        }
        cleanupDays = days
        cleanupIsExplicit = true
    }

    /// Sets `cleanupPeriodDays` with a minimal text edit, so the rest of the
    /// file keeps its formatting. A backup is written next to it first.
    func setCleanupDays(_ days: Int) throws {
        let fm = FileManager.default
        var text = (try? String(contentsOf: settingsFile, encoding: .utf8)) ?? "{\n}\n"
        if fm.fileExists(atPath: settingsFile.path) {
            let backup = claudeDir.appendingPathComponent("settings.json.bak-claude-sessions")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsFile, to: backup)
        }

        let existing = try NSRegularExpression(pattern: "\"cleanupPeriodDays\"\\s*:\\s*-?\\d+")
        let range = NSRange(text.startIndex..., in: text)
        if existing.firstMatch(in: text, range: range) != nil {
            text = existing.stringByReplacingMatches(
                in: text, range: range, withTemplate: "\"cleanupPeriodDays\": \(days)")
        } else {
            let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            guard let brace = text.firstIndex(of: "{") else { throw SettingsError.invalid }
            let entry = "\n  \"cleanupPeriodDays\": \(days)" + ((obj?.isEmpty ?? true) ? "\n" : ",")
            text.insert(contentsOf: entry, at: text.index(after: brace))
        }

        guard let check = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            (check["cleanupPeriodDays"] as? NSNumber)?.intValue == days
        else { throw SettingsError.invalid }
        try text.write(to: settingsFile, atomically: true, encoding: .utf8)
        readCleanupSetting()
    }
}

enum SettingsError: LocalizedError {
    case invalid
    var errorDescription: String? {
        "Couldn't update settings.json safely (it may not be valid JSON). Nothing was changed."
    }
}

// MARK: - Path and text helpers

/// Claude Code names a project's folder by replacing every non-alphanumeric
/// character of its path with "-".
func encodeProjectPath(_ path: String) -> String {
    String(path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
}

/// A readable name for a project path, or for an encoded folder name whose
/// real path is unknown.
func projectDisplayName(_ pathOrFolder: String) -> String {
    if pathOrFolder.hasPrefix("/") { return (pathOrFolder as NSString).lastPathComponent }
    // Unknown real path: drop the home/Documents prefix of the encoded name.
    var name = pathOrFolder
    for prefix in ["-Users-\(NSUserName())-Documents-", "-Users-\(NSUserName())-"] where name.hasPrefix(prefix) {
        name.removeFirst(prefix.count)
        break
    }
    return name
}

private let indexISO: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func parseISODate(_ s: String) -> Date? { indexISO.date(from: s) }

private let indexNoise = try! NSRegularExpression(
    pattern: "<(ide_[a-z_]+|system-reminder|command-message)>[\\s\\S]*?</\\1>")

/// First prompts in old index files still contain injected IDE context.
func cleanIndexPrompt(_ s: String) -> String {
    let cleaned = indexNoise.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // The index cut the prompt short inside an IDE block, so its end tag is missing.
    if cleaned.hasPrefix("<ide_") || cleaned.hasPrefix("<system-reminder") {
        if let file = cleaned.range(of: "from ").map({ cleaned[$0.upperBound...] }),
            let name = file.split(whereSeparator: { " :\n".contains($0) }).first
        {
            return "[Started with a selection in \((String(name) as NSString).lastPathComponent)]"
        }
        return "[Started with IDE context]"
    }
    return cleaned
}

// MARK: - Process helpers

private func isClaudeProcess(_ pid: Int32) -> Bool {
    guard kill(pid, 0) == 0 || errno == EPERM else { return false }
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
    // Guards against a recycled pid now belonging to something else.
    return String(cString: buf).lowercased().contains("claude")
}

private func footprint(_ pid: Int32) -> UInt64 {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return ok == 0 ? info.ri_phys_footprint : 0
}
