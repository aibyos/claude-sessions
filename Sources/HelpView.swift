import AppKit
import SwiftUI

enum HelpTopic: String, CaseIterable, Identifiable {
    case overview, storage, cleanup, resume, running, accounts, titles, privacy, about
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "What this app does"
        case .storage: "Where sessions are stored"
        case .cleanup: "Automatic cleanup (history retention)"
        case .resume: "Resuming a session"
        case .running: "Running sessions"
        case .accounts: "Multiple Claude accounts"
        case .titles: "Titles, prompts and search"
        case .privacy: "Privacy and safety"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .overview: "sparkles"
        case .storage: "folder"
        case .cleanup: "clock.arrow.circlepath"
        case .resume: "play.circle"
        case .running: "dot.radiowaves.left.and.right"
        case .accounts: "person.2"
        case .titles: "text.magnifyingglass"
        case .privacy: "lock.shield"
        case .about: "info.circle"
        }
    }
}

@MainActor
final class HelpModel: ObservableObject {
    static let shared = HelpModel()
    @Published var topic: HelpTopic = .overview
}

struct HelpView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var model = HelpModel.shared

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: Binding(get: { model.topic }, set: { if let t = $0 { model.topic = t } })) {
                Label($0.title, systemImage: $0.icon).tag($0)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(model.topic.title, systemImage: model.topic.icon).font(.title2.weight(.semibold))
                    content(model.topic)
                }
                .textSelection(.enabled)
                .padding(28)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 780, minHeight: 520)
    }

    @ViewBuilder private func content(_ topic: HelpTopic) -> some View {
        switch topic {
        case .overview: overview
        case .storage: storage
        case .cleanup: CleanupHelp(store: store)
        case .resume: resume
        case .running: running
        case .accounts: accounts
        case .titles: titles
        case .privacy: privacy
        case .about: about
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            P("Claude Code saves every conversation to disk, but only shows them one project at a time. This app reads all of them and puts them in one place, so you don't have to remember which VS Code window or folder a conversation was in.")
            Bullets([
                "**Menu bar icon**: the number next to it is how many sessions are running right now. Click it for a searchable list of recent sessions.",
                "**Full window** (window button in the panel): sidebar with Running / Today / Last 7 days / All / Deleted soon, plus every project. Pick a session to see its details and every prompt you sent.",
                "**Resume**: “Open in VS Code” or “Resume in Terminal” brings a conversation back with its full history.",
                "**Deleted soon**: Claude Code deletes old transcripts automatically. This list shows which ones go next. See *Automatic cleanup*.",
                "The list refreshes on its own: running sessions every 5 seconds, transcripts every 30 seconds.",
            ])
            P("Look for the **?** buttons. Each one opens this help on the relevant topic.")
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Code("~/.claude/projects/<project-folder>/<session-id>.jsonl")
            Bullets([
                "**One folder per project.** The folder name is the project's path with `/` (and `.`) replaced by `-`. For example `/Users/you/my-app` becomes `-Users-you-my-app`.",
                "**One file per conversation**, named by its session ID. It's a JSON Lines log of everything: your prompts, Claude's replies, tool calls and their output. That's why some files are tens of MB.",
                "`~/.claude/sessions/<pid>.json` lists the sessions whose process is running right now. This app uses it for the Running list.",
                "`~/.claude/ide/*.lock` lists the VS Code windows connected to Claude Code. That's how the app knows a project folder is already open.",
                "`/private/tmp/claude-…/` is **not** your history. It's scratch space for temporary files created during a session, and macOS clears it.",
            ])
            P(
                "Right now: \(store.sessions.count) transcripts, \(bytes(store.totalTranscriptBytes)) in total. The oldest has activity from \(fullDate(store.oldestSession))."
            )
            Button("Open ~/.claude/projects in Finder") { NSWorkspace.shared.open(projectsDir) }
        }
    }

    private var resume: some View {
        VStack(alignment: .leading, spacing: 12) {
            P("Resuming brings back a conversation with its full history, so Claude remembers what you were doing.")
            H("Open in VS Code")
            P("Opens the session's project folder in VS Code, then asks the Claude Code extension to open that conversation through its link handler:")
            Code("vscode://anthropic.claude-code/open?session=<session-id>")
            P("The link opens in the VS Code window that's in front, which is why the folder is opened first. If the folder wasn't open yet, VS Code needs a few seconds to start the extension; the app waits for that. If the conversation doesn't appear, click the button again once the window is ready.")
            H("Resume in Terminal")
            P("Opens Terminal and runs:")
            Code("cd <project folder> && claude --resume <session-id>")
            P("**It has to run from the original folder.** Claude Code stores sessions per project and looks for the ID in the current folder's history. “Copy command” puts this exact line on your clipboard.")
            H("Other ways, inside Claude Code")
            Bullets([
                "`claude --continue` (or `-c`): continue the most recent conversation in the current folder.",
                "`claude --resume` with no ID, or `/resume` inside a session: pick from a list of this folder's past conversations.",
                "In VS Code, the Claude Code panel lists past conversations, but only for the open workspace.",
            ])
            H("Things to know")
            Bullets([
                "Resuming a session that's still running elsewhere opens a second copy of it. Close the old one first (or use its existing tab) to avoid two copies writing to the same history.",
                "Sessions that have been auto-deleted can't be resumed. See *Automatic cleanup*.",
            ])
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 12) {
            P("A session is “running” while its `claude` process is alive: an open Claude Code tab in VS Code, or a terminal where `claude` is running. Every one of them uses memory, even when idle.")
            P(
                "Right now: \(store.running.count) running, using \(bytes(store.runningFootprint, memory: true)) of memory in total (main process only; helpers such as MCP servers come on top)."
            )
            Bullets([
                "Sessions often stay running for days or weeks because the VS Code tab was never closed. The **Running now** list shows how long each has been up.",
                "**Stop…** ends the process (a normal quit signal, not a force-kill). The conversation is already saved, so you can resume it later. A reply being written at that moment is cut off.",
                "Closing the Claude Code tab in VS Code also ends its session.",
            ])
        }
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 12) {
            P("**All Claude accounts on this Mac share one history.** Signing in with a different account (`/login` or `/logout`) doesn't give it a separate folder. Every account's conversations are saved in the same `~/.claude/projects`. They all show up together here, and in Claude Code's own `/resume` list.")
            H("How the app tells them apart")
            Bullets([
                "Newer Claude Code versions write the owning account into each transcript (a “session-owner” record). The app reads it and shows it in the **Accounts** sidebar section and in each session's details.",
                "Older sessions don't have that record, so they're listed as **Not recorded**.",
                "Names come from `~/.claude.json` (the account signed in now) and `~/.claude.json.backup` (usually the previous one). The app remembers every account it has seen, so names stay after you switch.",
            ])
            P(store.accountRows.map { "\($0.label): \($0.count) session\($0.count == 1 ? "" : "s")" }.joined(separator: " · "))
            H("Resuming another account's session")
            Bullets([
                "The transcript is a local file, so **any session can be resumed whichever account is signed in.**",
                "New messages then run under, and count toward, **the account signed in now**, not the one that started the session.",
                "Watch work and personal boundaries: resuming a work session while signed in to a personal account sends that work context through the personal account, and the other way round.",
                "Links tied to the original account (artifacts, remote-control sessions) may not open under a different account.",
            ])
            H("If you want them fully separate")
            P("Give each account its own config folder with the `CLAUDE_CONFIG_DIR` environment variable, e.g. `CLAUDE_CONFIG_DIR=~/.claude-work claude`. That account's settings, login and history then live in `~/.claude-work`. This app currently reads `~/.claude` only, so a separate folder wouldn't appear here yet.")
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 12) {
            Bullets([
                "**Title**: the one you set with `/rename`, otherwise the short title Claude Code generates for the session, otherwise your first prompt.",
                "**What you asked**: every prompt you typed, in order, with times. Tool output, system messages and IDE context are left out. Pasted blocks show as “[pasted text]”, and slash commands as `/command args`.",
                "**Search** looks in titles, all prompts, project paths and branch names (and session IDs).",
                "**Source**: VS Code or Terminal, depending on where the session was started.",
                "**Links**: pull requests and artifacts created during the session, when Claude Code recorded them.",
            ])
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Sessions").font(.title3.weight(.semibold))
                    Text("Version \(appVersion)").foregroundStyle(.secondary)
                }
            }
            P("Made by **Orkhan Amrullayev** at [aibyos.com](https://aibyos.com).")
            HStack(spacing: 16) {
                Link("aibyos.com", destination: URL(string: "https://aibyos.com")!)
                Link("orkhan.amrullayev@gmail.com", destination: URL(string: "mailto:orkhan.amrullayev@gmail.com")!)
                Link("Source on GitHub", destination: URL(string: repoURL)!)
            }
            P("Open source under the MIT License. Bug reports and ideas are welcome on GitHub.")
            P("Claude Sessions is an independent project and isn't affiliated with or endorsed by Anthropic. Claude and Claude Code are trademarks of Anthropic.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 12) {
            Bullets([
                "**Read-only.** The app reads transcripts and never edits or deletes them.",
                "**Local only.** Nothing is sent anywhere. A small index is cached in `~/Library/Caches/ClaudeSessions` so it starts fast.",
                "**The one exception** is the history-retention setting. It's only changed when you press Apply and confirm, and a backup of `settings.json` is saved first.",
                "Transcripts are plain text and include everything you pasted, including any secrets. Keep that in mind before sharing or syncing `~/.claude`.",
            ])
        }
    }
}

/// Explains `cleanupPeriodDays` and lets the user change it.
struct CleanupHelp: View {
    @ObservedObject var store: SessionStore
    @State private var days = 365
    @State private var confirm = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                HStack {
                    Image(systemName: store.cleanupDays <= 30 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(store.cleanupDays <= 30 ? .orange : .green)
                    VStack(alignment: .leading) {
                        Text("Transcripts are kept for \(store.cleanupDays) days after their last activity")
                            .fontWeight(.semibold)
                        Text(
                            store.cleanupIsExplicit
                                ? "Set by `cleanupPeriodDays` in ~/.claude/settings.json."
                                : "Not set in ~/.claude/settings.json, so Claude Code's default of \(defaultCleanupDays) days applies."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            P("When Claude Code starts, it deletes transcripts whose last activity is older than the retention period. Once a transcript is deleted, the conversation can't be resumed or searched, and this app can't show it any more.")
            P(
                "That's why your oldest session is from \(fullDate(store.oldestSession)): anything older has already been removed. The **Deleted soon** list shows sessions within 5 days of the cut-off (approximate, based on the file's last change)."
            )
            H("Change how long history is kept")
            HStack {
                Picker("Keep history for", selection: $days) {
                    Text("30 days (default)").tag(30)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("1 year").tag(365)
                    Text("2 years").tag(730)
                    Text("5 years").tag(1825)
                }
                .frame(width: 280)
                Button("Apply…") { confirm = true }
                    .disabled(days == store.cleanupDays && store.cleanupIsExplicit)
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(message.hasPrefix("✓") ? .green : .red)
            }
            Bullets([
                "This writes `\"cleanupPeriodDays\": \(days)` into `~/.claude/settings.json` and leaves the rest of the file unchanged. A backup is saved as `settings.json.bak-claude-sessions`.",
                "It applies to Claude Code in VS Code and in the terminal. Already-deleted transcripts don't come back.",
                "Disk cost is small for most people: you have \(bytes(store.totalTranscriptBytes)) of transcripts now.",
                "Don't set it to 0. That doesn't mean “keep forever”.",
                "An organisation-managed settings policy can override your own setting.",
            ])
        }
        .onAppear { days = store.cleanupIsExplicit ? store.cleanupDays : 365 }
        .alert("Keep Claude Code history for \(days) days?", isPresented: $confirm) {
            Button("Apply") { apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This updates cleanupPeriodDays in ~/.claude/settings.json (backup saved first).")
        }
    }

    private func apply() {
        do {
            try store.setCleanupDays(days)
            message = "✓ Saved. Claude Code now keeps transcripts for \(days) days."
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Text helpers

private struct P: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(LocalizedStringKey(text)).fixedSize(horizontal: false, vertical: true)
    }
}

private struct H: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.headline).padding(.top, 6) }
}

private struct Code: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}

private struct Bullets: View {
    let items: [String]
    init(_ items: [String]) { self.items = items }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                    Text(LocalizedStringKey(item)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
