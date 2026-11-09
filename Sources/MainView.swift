import AppKit
import SwiftUI

// MARK: - Shared pieces

struct Badge: View {
    let text: String
    var icon: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
    }
}

struct RunningDot: View {
    var body: some View {
        Circle().fill(.green).frame(width: 7, height: 7).help("Running now")
    }
}

/// A small "?" button that opens the help window at a topic.
struct HelpButton: View {
    var topic: HelpTopic = .overview
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            HelpModel.shared.topic = topic
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "help")
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .help("How this works")
    }
}

struct SessionRow: View {
    @ObservedObject var store: SessionStore
    let session: SessionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if store.isRunning(session) { RunningDot() }
                if session.isDeleted {
                    Image(systemName: "trash").foregroundStyle(.secondary).help("Deleted: summary only")
                }
                Text(session.title).fontWeight(.medium).lineLimit(1)
                    .foregroundStyle(session.isDeleted ? .secondary : .primary)
            }
            HStack(spacing: 4) {
                if !session.isDeleted && !session.isUnsaved {
                    Image(systemName: session.source.icon).help(session.source.label)
                }
                Text(session.projectName)
                if let b = session.gitBranch { Text("· \(b)").lineLimit(1) }
                Spacer(minLength: 4)
                Text(relativeTime(session.lastActivity))
                if store.expiresSoon(session) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                        .help("Will be auto-deleted around \(fullDate(store.expiry(session)))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Main window

struct MainView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        NavigationSplitView {
            Sidebar(store: store)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } content: {
            SessionList(store: store)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 520)
        } detail: {
            if let s = store.selectedSession {
                SessionDetail(store: store, session: s)
            } else {
                ContentUnavailableView(
                    "Select a session", systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Pick a conversation to see what it was about and resume it."))
            }
        }
        .searchable(text: $store.search, placement: .toolbar, prompt: "Search titles, prompts, projects")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.refreshLive()
                    store.rescan()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Re-read sessions now (also happens automatically every 30 s)")
                HelpButton()
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

struct Sidebar: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var favorites = FavoritesStore.shared

    var body: some View {
        List(selection: $store.filter) {
            FavoritesSection(store: store, favorites: favorites)
            Section("Sessions") {
                row(.running, "Running now", "dot.radiowaves.left.and.right")
                row(.today, "Today", "sun.max")
                row(.week, "Last 7 days", "calendar")
                row(.all, "All", "tray.full")
                row(.expiring, "Deleted soon", "clock.badge.exclamationmark")
                if store.showDeleted {
                    row(.deleted, "Deleted", "trash")
                }
            }
            Section("Projects") {
                ForEach(store.projects, id: \.path) { p in
                    HStack {
                        Label(p.name, systemImage: projectIcon(p.path, onlyDeleted: p.onlyDeleted))
                            .foregroundStyle(p.onlyDeleted ? .secondary : .primary)
                            .help(p.onlyDeleted ? "\(p.path)\nAll conversations here were deleted by cleanup" : p.path)
                        Spacer()
                        Text("\(p.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(SidebarFilter.project(p.path))
                    .contextMenu {
                        if favorites.contains(p.path) {
                            Button("Remove from Favorites") {
                                favorites.items.first { $0.path == p.path }.map(favorites.remove)
                            }
                        } else if FileManager.default.fileExists(atPath: p.path) {
                            Button("Add to Favorites") { favorites.add(p.path) }
                        }
                        Button("Open Folder in VS Code") { Actions.openFolderInVSCode(p.path) }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)])
                        }
                    }
                }
            }
            Section {
                ForEach(store.accountRows, id: \.id) { a in
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(a.label).lineLimit(1)
                                if let d = a.detail {
                                    Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        } icon: {
                            Image(systemName: a.id.isEmpty ? "person.crop.circle.badge.questionmark" : "person.crop.circle")
                        }
                        Spacer()
                        Text("\(a.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(SidebarFilter.account(a.id))
                }
            } header: {
                HStack {
                    Text("Accounts")
                    Spacer()
                    HelpButton(topic: .accounts)
                }
            }
            Section {
                Toggle(isOn: $store.showDeleted) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show deleted sessions (\(store.deletedSessions.count))")
                        Text("Summaries that survived cleanup; not resumable")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                CleanupSummary(store: store)
            }
        }
    }

    private func projectIcon(_ path: String, onlyDeleted: Bool) -> String {
        if onlyDeleted { return "folder.badge.minus" }
        return store.vscodeWorkspaces.contains(path) ? "folder.fill" : "folder"
    }

    private func row(_ f: SidebarFilter, _ title: String, _ icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text("\(store.count(f))").foregroundStyle(.secondary).monospacedDigit()
        }
        .tag(f)
    }
}

/// Retention status with a shortcut to the explanation and the setting.
struct CleanupSummary: View {
    @ObservedObject var store: SessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: store.cleanupDays <= 30 ? "exclamationmark.triangle.fill" : "checkmark.seal")
                    .foregroundStyle(store.cleanupDays <= 30 ? .orange : .green)
                Text("History kept \(store.cleanupDays) days")
                    .fontWeight(.medium)
            }
            Text(
                store.cleanupIsExplicit
                    ? "Set in ~/.claude/settings.json"
                    : "Claude Code's default: older transcripts are deleted"
            )
            .font(.caption).foregroundStyle(.secondary)
            Button("Change / learn more…") {
                HelpModel.shared.topic = .cleanup
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "help")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

struct SessionList: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        let list = store.sessions(for: store.filter, search: store.search)
        List(selection: $store.selection) {
            if list.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            }
            ForEach(list) { s in
                SessionRow(store: store, session: s).tag(s.id)
                    .contextMenu { SessionMenu(store: store, session: s) }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle("\(list.count) session\(list.count == 1 ? "" : "s")")
    }

    private var emptyText: String {
        if !store.search.isEmpty { return "No sessions match “\(store.search)”." }
        if case .favorite = store.filter {
            return "No Claude Code sessions in this project yet. Use the open button next to the favorite to open it in VS Code."
        }
        if case .project = store.filter, store.showDeleted {
            return "All conversations in this project were deleted by Claude Code's cleanup, and no summaries survived."
        }
        return "No sessions here."
    }

    private var title: String {
        switch store.filter {
        case .running: "Running now"
        case .today: "Today"
        case .week: "Last 7 days"
        case .all: "All sessions"
        case .expiring: "Deleted soon"
        case .deleted: "Deleted"
        case .project(let p): projectDisplayName(p)
        case .favorite(let p): FavoritesStore.shared.items.first { $0.path == p }?.name ?? projectDisplayName(p)
        case .account(let id): store.accountRows.first { $0.id == id }?.label ?? "Account"
        }
    }
}

struct SessionMenu: View {
    @ObservedObject var store: SessionStore
    let session: SessionInfo

    var body: some View {
        if session.isDeleted {
            Button("Copy First Prompt") { Actions.copy(session.prompts.first?.text ?? "") }
            Button("Copy Session ID") { Actions.copy(session.id) }
        } else if session.isUnsaved {
            if let r = store.running[session.id] {
                Button("Stop Session…") { Actions.stop(r, title: "\(session.projectName) (nothing saved)") }
            }
            Button("Copy Session ID") { Actions.copy(session.id) }
        } else {
            liveItems
        }
    }

    @ViewBuilder private var liveItems: some View {
        Button("Open in VS Code") { Actions.openInVSCode(session, folderAlreadyOpen: store.isOpenInVSCode(session)) }
        Button("Resume in Terminal") { Actions.resumeInTerminal(session) }
        Button("Copy Resume Command") { Actions.copy(Actions.resumeCommand(session)) }
        Button("Copy Session ID") { Actions.copy(session.id) }
        Divider()
        Button("Show Transcript in Finder") { Actions.revealTranscript(session) }
        if let r = store.running[session.id] {
            Divider()
            Button("Stop Session…") { Actions.stop(r, title: session.title) }
        }
    }
}

// MARK: - Detail

struct SessionDetail: View {
    @ObservedObject var store: SessionStore
    let session: SessionInfo
    @State private var showAllPrompts = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if session.isDeleted {
                    deletedBox
                } else if session.isUnsaved {
                    unsavedBox
                } else {
                    actions
                }
                if let r = store.running[session.id] { runningBox(r) }
                detailsGrid
                if !session.prs.isEmpty || !session.artifacts.isEmpty || !session.htmlFiles.isEmpty { links }
                outline
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 6) {
                if store.isRunning(session) { Badge(text: "Running", icon: "circle.fill", color: .green) }
                if session.isDeleted {
                    Badge(text: "Deleted", icon: "trash", color: .red)
                } else if session.isUnsaved {
                    Badge(text: "Nothing saved", icon: "exclamationmark.circle", color: .orange)
                } else {
                    Badge(text: session.source.label, icon: session.source.icon)
                }
                if store.isOpenInVSCode(session) {
                    Badge(text: "Folder open in VS Code", icon: "macwindow", color: .blue)
                }
                if store.expiresSoon(session) {
                    Badge(text: "Auto-deleted \(relativeTime(store.expiry(session)))", icon: "clock", color: .orange)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                actionButtons(short: false)
                actionButtons(short: true)
            }
            Menu {
                SessionMenu(store: store, session: session)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 0)
            HelpButton(topic: .resume)
        }
    }

    private func actionButtons(short: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                Actions.openInVSCode(session, folderAlreadyOpen: store.isOpenInVSCode(session))
            } label: {
                Label(short ? "VS Code" : "Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .buttonStyle(.borderedProminent)
            .help("Opens the project folder in VS Code, then this conversation in the Claude Code extension")
            Button {
                Actions.resumeInTerminal(session)
            } label: {
                Label(short ? "Terminal" : "Resume in Terminal", systemImage: "terminal")
            }
            .help(Actions.resumeCommand(session))
            Button {
                Actions.copy(Actions.resumeCommand(session))
            } label: {
                Label(short ? "Copy" : "Copy command", systemImage: "doc.on.doc")
            }
            .help("Copy: " + Actions.resumeCommand(session))
        }
        .fixedSize()
    }

    private var deletedBox: some View {
        GroupBox {
            HStack(alignment: .top) {
                Image(systemName: "trash").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("This conversation was deleted by Claude Code's automatic cleanup").fontWeight(.semibold)
                    Text(
                        "Only this summary survived, in an old sessions-index.json: the first prompt, dates, branch and message count. The full transcript is gone, so it can't be opened or resumed."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                HelpButton(topic: .cleanup)
            }
            .padding(4)
        }
    }

    private var unsavedBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text("A Claude Code process is running here, but no conversation is saved").fontWeight(.semibold)
                Text(
                    "Usually a VS Code tab that was opened and never used. If it started more than \(store.cleanupDays) days ago, its transcript may already have been removed by cleanup while the tab stayed open. There's nothing to resume, but it still uses memory. Stopping it is safe."
                )
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runningBox(_ r: RunningSession) -> some View {
        GroupBox {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This session is running right now")
                        .fontWeight(.semibold)
                    Text(
                        "Process \(String(r.pid)) · running for \(duration(from: r.startedAt, to: .now)) · using \(bytes(r.footprint, memory: true)) of memory"
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    Text("Idle sessions keep their memory until they're closed. Stopping is safe: the conversation stays resumable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop…") { Actions.stop(r, title: session.title) }
                HelpButton(topic: .running)
            }
            .padding(4)
        }
    }

    private var detailsGrid: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                row("Folder", session.projectPath)
                if let b = session.gitBranch { row("Git branch", b) }
                row("Started", fullDate(session.created))
                row("Last activity", "\(fullDate(session.lastActivity)) (\(relativeTime(session.lastActivity)))")
                if session.isDeleted {
                    if let n = session.messageCount { row("Messages", "\(n)") }
                } else {
                    row("Prompts", "\(session.promptCount)")
                }
                row("Account", store.accountLabel(session))
                if let m = session.model { row("Model", m) }
                if let v = session.version { row("Claude Code", "v\(v)") }
                if session.isDeleted || session.isUnsaved {
                    row("Transcript", session.isDeleted ? "Deleted" : "None on disk")
                } else {
                    row("Transcript", "\(bytes(session.fileSize)) · \(session.filePath)")
                }
                row("Session ID", session.id)
                if !session.isDeleted && !session.isUnsaved {
                    row(
                        "Auto-delete",
                        store.isRunning(session)
                            ? "Not while it's active"
                            : "around \(fullDate(store.expiry(session))) (\(store.cleanupDays)-day retention)")
                }
            }
            .textSelection(.enabled)
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).lineLimit(2).truncationMode(.middle)
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Links").font(.headline)
            ForEach(session.prs, id: \.url) { pr in
                Button {
                    Actions.open(pr.url)
                } label: {
                    Label("PR #\(pr.number) · \(pr.repo)", systemImage: "arrow.triangle.pull")
                }
                .buttonStyle(.link)
            }
            ForEach(session.artifacts, id: \.url) { a in
                Button {
                    Actions.open(a.url)
                } label: {
                    Label(a.title, systemImage: "doc.richtext")
                }
                .buttonStyle(.link)
            }
            ForEach(session.htmlFiles, id: \.self) { path in
                HTMLFileRow(path: path)
            }
        }
    }

    private var outline: some View {
        let prompts = showAllPrompts ? session.prompts : Array(session.prompts.prefix(12))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What you asked").font(.headline)
                Text("\(session.promptCount) prompt\(session.promptCount == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Spacer()
                HelpButton(topic: .titles)
            }
            ForEach(Array(prompts.enumerated()), id: \.offset) { i, p in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.text).lineLimit(6).textSelection(.enabled)
                        if let t = p.time {
                            Text(t.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            if session.prompts.count > 12 {
                Button(showAllPrompts ? "Show fewer" : "Show all \(session.prompts.count)") {
                    showAllPrompts.toggle()
                }
                .buttonStyle(.link)
            }
        }
    }
}

/// An HTML file the session wrote: opens in the default browser, or shows
/// that it's gone (scratchpad files under /private/tmp get cleared).
struct HTMLFileRow: View {
    let path: String

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: path)
        let name = (path as NSString).lastPathComponent
        let folder = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        HStack(spacing: 6) {
            if exists {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: {
                    Label(name, systemImage: "globe")
                }
                .buttonStyle(.link)
                .help("Open \(path) in your browser")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            } else {
                Label(name, systemImage: "globe").foregroundStyle(.secondary)
                Text("no longer on disk").font(.caption).foregroundStyle(.tertiary)
            }
            Text(folder).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                .help(path)
        }
    }
}

/// Sidebar section with pinned projects, optionally grouped in folders.
struct FavoritesSection: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var favorites: FavoritesStore
    /// Folders are expanded unless the user collapsed them.
    @AppStorage("collapsedFavoriteFolders") private var collapsedRaw = ""

    private func expanded(_ g: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedRaw.split(separator: "\n").contains(Substring(g)) },
            set: { open in
                var set = Set(collapsedRaw.split(separator: "\n").map(String.init))
                if open { set.remove(g) } else { set.insert(g) }
                collapsedRaw = set.sorted().joined(separator: "\n")
            })
    }

    var body: some View {
        Section {
            if favorites.items.isEmpty {
                Text("Pin projects to reopen them in VS Code with one click. Use + or right-click a project.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(favorites.grouped, id: \.group) { section in
                if let g = section.group {
                    DisclosureGroup(isExpanded: expanded(g)) {
                        ForEach(section.items) { row($0) }
                    } label: {
                        Label(g, systemImage: "folder")
                            .contextMenu { FolderMenu(favorites: favorites, group: g, items: section.items) }
                    }
                } else {
                    ForEach(section.items) { row($0) }
                }
            }
            if favorites.vscodeRunning {
                HStack {
                    Text("VS Code: \(bytes(favorites.vscodeMemory, memory: true))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit…") { favorites.quitVSCode() }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.caption)
                        .help("Quit VS Code to free memory; reopen favorites from here later")
                }
            }
        } header: {
            HStack {
                Text("Favorites")
                Spacer()
                AddFavoriteMenu(favorites: favorites, store: store)
                HelpButton(topic: .favorites)
            }
        }
    }

    private func row(_ f: Favorite) -> some View {
        let count = store.count(.favorite(f.path))
        let isOpen = store.vscodeWorkspaces.contains(f.path)
        return HStack(spacing: 4) {
            Label(f.name, systemImage: f.exists ? (isOpen ? "star.fill" : "star") : "star.slash")
                .foregroundStyle(f.exists ? .primary : .secondary)
                .help(f.exists ? f.path + (isOpen ? "\nOpen in VS Code" : "") : "Not found: \(f.path)")
            Spacer()
            Button {
                favorites.open(f)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open in VS Code")
            if count > 0 {
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .tag(SidebarFilter.favorite(f.path))
        .contextMenu { FavoriteMenu(favorites: favorites, favorite: f) }
    }
}
