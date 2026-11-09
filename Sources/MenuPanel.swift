import AppKit
import SwiftUI

/// The panel that drops down from the menu bar icon.
struct MenuPanel: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var favorites = FavoritesStore.shared
    @ObservedObject var updater = Updater.shared
    @Environment(\.openWindow) private var openWindow
    @State private var query: String
    @State private var tab: Tab

    init(store: SessionStore, initialTab: Tab? = nil, initialQuery: String = "") {
        self.store = store
        let saved = UserDefaults.standard.string(forKey: "panelTab").flatMap(Tab.init(rawValue:))
        _tab = State(initialValue: initialTab ?? saved ?? .recent)
        _query = State(initialValue: initialQuery)
    }

    enum Tab: String, Hashable { case favorites, running, recent, expiring }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            UpdateBanner(updater: updater)
            if tab != .favorites {
                TextField("Search sessions", text: $query)
                    .textFieldStyle(.roundedBorder)
            }
            Picker("", selection: $tab) {
                Image(systemName: "star.fill").help("Favorite projects").tag(Tab.favorites)
                Text("Running \(store.count(.running))").tag(Tab.running)
                Text("Recent").tag(Tab.recent)
                Text("Deleted soon \(store.count(.expiring))").tag(Tab.expiring)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: tab) { _, t in UserDefaults.standard.set(t.rawValue, forKey: "panelTab") }

            if tab == .favorites {
                FavoritesPanelList(favorites: favorites, store: store).frame(height: 388)
            } else {
                list
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 420)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("Claude Sessions").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HelpButton()
            Button {
                showMain(nil)
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("Open the full window")
        }
    }

    private var summary: String {
        let n = store.count(.running)
        let mem = bytes(store.runningFootprint, memory: true)
        return "\(store.visibleSessions.count) sessions · \(n) running (\(mem))"
    }

    private var items: [SessionInfo] {
        let filter: SidebarFilter =
            switch tab {
            case .running: .running
            case .recent: .all
            case .expiring: .expiring
            case .favorites: .all
            }
        return Array(store.sessions(for: filter, search: query).prefix(40))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if items.isEmpty {
                    Text(emptyText).foregroundStyle(.secondary).font(.callout).padding(8)
                }
                ForEach(items) { s in
                    PanelRow(store: store, session: s) { showMain(s.id) }
                }
            }
        }
        .frame(height: 360)
    }

    private var emptyText: String {
        if !query.isEmpty { return "No sessions match “\(query)”." }
        switch tab {
        case .running: return "No Claude Code sessions are running."
        case .recent: return store.isScanning ? "Reading sessions…" : "No sessions found in ~/.claude/projects."
        case .expiring: return "Nothing will be auto-deleted in the next 5 days."
        case .favorites: return ""
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: store.cleanupDays <= 30 ? "exclamationmark.triangle.fill" : "checkmark.seal")
                .foregroundStyle(store.cleanupDays <= 30 ? .orange : .green)
            Text("History kept \(store.cleanupDays) days").font(.caption)
            Button("Change…") {
                HelpModel.shared.topic = .cleanup
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "help")
            }
            .buttonStyle(.link).font(.caption)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
        }
    }

    private func showMain(_ id: String?) {
        if let id {
            store.selection = id
            if store.sessions(for: store.filter, search: store.search).first(where: { $0.id == id }) == nil {
                store.filter = .all
                store.search = ""
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}

private struct PanelRow: View {
    @ObservedObject var store: SessionStore
    let session: SessionInfo
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                SessionRow(store: store, session: session).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(session.prompts.first?.text.firstLine(limit: 300) ?? session.title)
            if hovering && !session.isDeleted && !session.isUnsaved {
                Button {
                    Actions.openInVSCode(session, folderAlreadyOpen: store.isOpenInVSCode(session))
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .help("Open in VS Code")
                Button {
                    Actions.resumeInTerminal(session)
                } label: {
                    Image(systemName: "terminal")
                }
                .help("Resume in Terminal")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .onHover { hovering = $0 }
    }
}
