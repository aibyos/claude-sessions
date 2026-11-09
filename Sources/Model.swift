import Foundation

let homeDir = FileManager.default.homeDirectoryForCurrentUser
let claudeDir = homeDir.appendingPathComponent(".claude")
let projectsDir = claudeDir.appendingPathComponent("projects")
let settingsFile = claudeDir.appendingPathComponent("settings.json")

let repoURL = "https://github.com/aibyos/claude-sessions"
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

/// Claude Code deletes transcripts older than this unless `cleanupPeriodDays` is set.
let defaultCleanupDays = 30

struct Prompt: Codable, Hashable {
    var text: String
    var time: Date?
}

struct PRLink: Codable, Hashable {
    var number: Int
    var url: String
    var repo: String
}

struct ArtifactLink: Codable, Hashable {
    var title: String
    var url: String
}

enum SessionSource {
    case vscode, terminal, other

    var label: String {
        switch self {
        case .vscode: "VS Code"
        case .terminal: "Terminal"
        case .other: "Other"
        }
    }

    var icon: String {
        switch self {
        case .vscode: "chevron.left.forwardslash.chevron.right"
        case .terminal: "terminal"
        case .other: "app.dashed"
        }
    }
}

/// One Claude Code conversation, summarised from its `.jsonl` transcript.
struct SessionInfo: Codable, Identifiable, Hashable {
    var id: String
    var filePath: String
    var projectFolder: String
    var cwd: String?
    var gitBranch: String?
    var entrypoint: String?
    var version: String?
    var model: String?
    var created: Date?
    var lastActivity: Date
    var aiTitle: String?
    var lastPrompt: String?
    var prompts: [Prompt] = []
    var promptCount = 0
    var prs: [PRLink] = []
    var artifacts: [ArtifactLink] = []
    var fileSize: UInt64
    /// Claude account that owned the session (newer Claude Code versions record it).
    var accountId: String?
    var organizationId: String?
    /// Transcript is gone; only a summary from an old sessions-index.json survives.
    var isDeleted = false
    var messageCount: Int?
    /// A running claude process with no transcript on disk.
    var isUnsaved = false

    var title: String {
        if let t = aiTitle, !t.isEmpty { return t }
        if let p = prompts.first?.text { return p.firstLine(limit: 90) }
        return "Untitled session"
    }

    /// The folder the session ran in. Falls back to decoding the project
    /// folder name, which is lossy (Claude Code replaces "/" and "." with "-").
    var projectPath: String {
        cwd ?? projectFolder.replacingOccurrences(of: "-", with: "/")
    }

    var projectName: String { (projectPath as NSString).lastPathComponent }

    var source: SessionSource {
        guard let e = entrypoint else { return .other }
        if e.contains("vscode") { return .vscode }
        if e == "cli" { return .terminal }
        return .other
    }

    func matches(_ query: String) -> Bool {
        if query.isEmpty { return true }
        let q = query.lowercased()
        if title.lowercased().contains(q) || projectPath.lowercased().contains(q) { return true }
        if (gitBranch ?? "").lowercased().contains(q) || id.hasPrefix(q) { return true }
        return prompts.contains { $0.text.lowercased().contains(q) }
    }
}

/// A `claude` process that is alive right now (VS Code tab or terminal).
struct RunningSession: Hashable {
    var pid: Int32
    var sessionId: String
    var cwd: String
    var startedAt: Date?
    var version: String?
    var kind: String?
    var footprint: UInt64
}

extension String {
    func firstLine(limit: Int) -> String {
        let line = split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? self
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}

// MARK: - Formatting

func relativeTime(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: .now)
}

func fullDate(_ date: Date?) -> String {
    guard let date else { return "–" }
    return date.formatted(date: .abbreviated, time: .shortened)
}

func bytes(_ b: UInt64, memory: Bool = false) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: memory ? .memory : .file)
}

func duration(from: Date?, to: Date) -> String {
    guard let from else { return "–" }
    let f = DateComponentsFormatter()
    f.allowedUnits = [.day, .hour, .minute]
    f.unitsStyle = .abbreviated
    f.maximumUnitCount = 2
    return f.string(from: max(to.timeIntervalSince(from), 60)) ?? "–"
}
