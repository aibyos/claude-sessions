import AppKit
import Darwin
import Foundation
import SwiftUI

/// A pinned project folder (or `.code-workspace` file) to reopen in VS Code.
struct Favorite: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var name: String
    /// Optional folder to group favorites; nil = ungrouped.
    var group: String?

    /// Sample data for screenshots points at made-up paths.
    nonisolated(unsafe) static var assumeExist = false

    var exists: Bool { Self.assumeExist || FileManager.default.fileExists(atPath: path) }
}

/// Favorites live in UserDefaults; the list is small and edited by hand.
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()
    private static let key = "favorites"

    @Published private(set) var items: [Favorite] = []
    /// Memory used by all VS Code processes, refreshed with the live data.
    @Published private(set) var vscodeMemory: UInt64 = 0
    @Published private(set) var vscodeRunning = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
            let list = try? JSONDecoder().decode([Favorite].self, from: data)
        {
            items = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Ungrouped favorites first, then folders alphabetically; names sorted within each.
    var grouped: [(group: String?, items: [Favorite])] {
        let byGroup = Dictionary(grouping: items, by: \.group)
        let keys = byGroup.keys.sorted { a, b in
            switch (a, b) {
            case (nil, _): true
            case (_, nil): false
            case let (a?, b?): a.localizedStandardCompare(b) == .orderedAscending
            }
        }
        return keys.map { k in
            (k, byGroup[k]!.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }

    var groups: [String] { Array(Set(items.compactMap(\.group))).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    func contains(_ path: String) -> Bool { items.contains { $0.path == path } }

    func add(_ path: String, group: String? = nil) {
        guard !contains(path) else { return }
        var name = (path as NSString).lastPathComponent
        if name.hasSuffix(".code-workspace") { name = (name as NSString).deletingPathExtension }
        items.append(Favorite(path: path, name: name, group: group))
        save()
    }

    func remove(_ f: Favorite) {
        items.removeAll { $0.id == f.id }
        save()
    }

    func rename(_ f: Favorite, to name: String) {
        guard let i = items.firstIndex(where: { $0.id == f.id }), !name.isEmpty else { return }
        items[i].name = name
        save()
    }

    func move(_ f: Favorite, to group: String?) {
        guard let i = items.firstIndex(where: { $0.id == f.id }) else { return }
        items[i].group = group
        save()
    }

    func renameGroup(_ old: String, to new: String) {
        guard !new.isEmpty else { return }
        for i in items.indices where items[i].group == old { items[i].group = new }
        save()
    }

    /// Removes the folder but keeps its favorites (they become ungrouped).
    func dissolveGroup(_ g: String) {
        for i in items.indices where items[i].group == g { items[i].group = nil }
        save()
    }

    // MARK: Adding

    /// Lets the user pick one or more folders or `.code-workspace` files.
    func chooseAndAdd(group: String? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Favorites"
        panel.message = "Choose project folders or .code-workspace files to keep as favorites."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue || url.pathExtension == "code-workspace" { add(url.path, group: group) }
        }
    }

    // MARK: VS Code

    func open(_ f: Favorite) {
        guard f.exists else {
            Actions.alert("“\(f.name)” isn't there anymore", "\(f.path)\n\nIt may have been moved or deleted. Remove the favorite, or add the new location.")
            return
        }
        Actions.openFolderInVSCode(f.path)
    }

    func openAll(_ list: [Favorite]) {
        for f in list where f.exists { Actions.openFolderInVSCode(f.path) }
    }

    func refreshVSCode() {
        let (running, memory) = Self.measureVSCode(
            app: NSRunningApplication.runningApplications(withBundleIdentifier: Actions.vscodeBundleID)
                .first?.bundleURL?.path)
        if running != vscodeRunning { vscodeRunning = running }
        // Avoid republishing for tiny changes; the UI shows it rounded anyway.
        if memory / 10_000_000 != vscodeMemory / 10_000_000 { vscodeMemory = memory }
    }

    /// Sums the memory footprint of the VS Code app and its helper processes.
    /// `app` is the running bundle's real location, which differs from the
    /// installed one when macOS runs a quarantined app from a translocated copy.
    nonisolated private static func measureVSCode(app: String?) -> (Bool, UInt64) {
        guard let app else { return (false, 0) }
        let prefix = app + "/"
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return (false, 0) }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        var total: UInt64 = 0
        var found = false
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, String(cString: buf).hasPrefix(prefix) else { continue }
            found = true
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if ok == 0 { total += info.ri_phys_footprint }
        }
        return (found, total)
    }

    /// Asks VS Code to quit normally, so it can save state and prompt about unsaved files.
    func quitVSCode() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Actions.vscodeBundleID)
        guard !apps.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "Quit VS Code?"
        a.informativeText = """
            Frees about \(bytes(vscodeMemory, memory: true)) of memory. VS Code quits normally: it asks about unsaved files, and reopens your windows next time if “Restore Windows” is on.

            Claude Code sessions running in VS Code tabs end too. Their conversations are saved and can be resumed.
            """
        a.addButton(withTitle: "Quit VS Code")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            for app in apps { app.terminate() }
        }
    }

    /// Replaces favorites with sample data for screenshots.
    func loadDemo(_ list: [Favorite], memory: UInt64) {
        items = list
        vscodeMemory = memory
        vscodeRunning = memory > 0
    }
}

/// Asks for a line of text in a small modal alert.
@MainActor
func promptText(_ title: String, message: String = "", initial: String = "", button: String = "OK") -> String? {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = initial
    a.accessoryView = field
    a.addButton(withTitle: button)
    a.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    a.window.initialFirstResponder = field
    guard a.runModal() == .alertFirstButtonReturn else { return nil }
    let s = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

// MARK: - Views

/// Context-menu items shared by the panel and the window.
struct FavoriteMenu: View {
    @ObservedObject var favorites: FavoritesStore
    let favorite: Favorite

    var body: some View {
        Button("Open in VS Code") { favorites.open(favorite) }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: favorite.path)])
        }
        Button("Copy Path") { Actions.copy(favorite.path) }
        Divider()
        Button("Rename…") {
            if let n = promptText("Rename favorite", initial: favorite.name, button: "Rename") {
                favorites.rename(favorite, to: n)
            }
        }
        Menu("Move to Folder") {
            if favorite.group != nil {
                Button("No Folder") { favorites.move(favorite, to: nil) }
                Divider()
            }
            ForEach(favorites.groups.filter { $0 != favorite.group }, id: \.self) { g in
                Button(g) { favorites.move(favorite, to: g) }
            }
            Divider()
            Button("New Folder…") {
                if let g = promptText("New folder", message: "Group favorites, e.g. by client or team.", button: "Create") {
                    favorites.move(favorite, to: g)
                }
            }
        }
        Divider()
        Button("Remove from Favorites") { favorites.remove(favorite) }
    }
}

struct FolderMenu: View {
    @ObservedObject var favorites: FavoritesStore
    let group: String
    let items: [Favorite]

    var body: some View {
        Button("Open All \(items.count) in VS Code") { favorites.openAll(items) }
        Button("Add Projects to “\(group)”…") { favorites.chooseAndAdd(group: group) }
        Button("Rename Folder…") {
            if let n = promptText("Rename folder", initial: group, button: "Rename") { favorites.renameGroup(group, to: n) }
        }
        Button("Remove Folder (keep favorites)") { favorites.dissolveGroup(group) }
    }
}

/// Menu for the "+" button: pick folders, or add open VS Code windows and Claude projects.
struct AddFavoriteMenu: View {
    @ObservedObject var favorites: FavoritesStore
    @ObservedObject var store: SessionStore

    var body: some View {
        Menu {
            Button("Choose Folders…") { favorites.chooseAndAdd() }
            let open = store.vscodeWorkspaces.filter { !favorites.contains($0) }
            if !open.isEmpty {
                Divider()
                Button("Add All Open VS Code Windows (\(open.count))") { open.forEach { favorites.add($0) } }
                ForEach(open, id: \.self) { p in
                    Button((p as NSString).lastPathComponent) { favorites.add(p) }
                }
            }
            let recent = store.projects.filter {
                !$0.onlyDeleted && !favorites.contains($0.path) && !open.contains($0.path)
                    && FileManager.default.fileExists(atPath: $0.path)
            }
            if !recent.isEmpty {
                Divider()
                Text("Projects with Claude sessions")
                ForEach(recent.prefix(15), id: \.path) { p in
                    Button(p.name) { favorites.add(p.path) }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add favorites")
    }
}

/// Favorites list for the menu bar panel: one click opens the project.
struct FavoritesPanelList: View {
    @ObservedObject var favorites: FavoritesStore
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            vscodeBar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if favorites.items.isEmpty {
                        empty
                    }
                    ForEach(favorites.grouped, id: \.group) { section in
                        if let g = section.group {
                            HStack {
                                Label(g, systemImage: "folder").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Open all") { favorites.openAll(section.items) }
                                    .buttonStyle(.link).font(.caption)
                            }
                            .padding(.horizontal, 6).padding(.top, 6)
                            .contextMenu { FolderMenu(favorites: favorites, group: g, items: section.items) }
                        }
                        ForEach(section.items) { f in
                            FavoritePanelRow(favorites: favorites, store: store, favorite: f)
                        }
                    }
                }
            }
        }
    }

    private var vscodeBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "memorychip").foregroundStyle(.secondary)
            Text(
                favorites.vscodeRunning
                    ? "VS Code is using \(bytes(favorites.vscodeMemory, memory: true))" : "VS Code isn't running"
            )
            .font(.caption)
            Spacer()
            if favorites.vscodeRunning {
                Button("Quit VS Code…") { favorites.quitVSCode() }.controlSize(.small)
            }
            AddFavoriteMenu(favorites: favorites, store: store)
        }
        .padding(.horizontal, 6)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No favorites yet").font(.callout.weight(.medium))
            Text("Pin the projects you work on, then quit VS Code to free memory and reopen any of them here with one click. Use **+** to add folders or your open VS Code windows.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
    }
}

private struct FavoritePanelRow: View {
    @ObservedObject var favorites: FavoritesStore
    @ObservedObject var store: SessionStore
    let favorite: Favorite
    @State private var hovering = false

    var body: some View {
        let isOpen = store.vscodeWorkspaces.contains(favorite.path)
        let exists = favorite.exists
        Button {
            favorites.open(favorite)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: favorite.path.hasSuffix(".code-workspace") ? "square.stack.3d.up" : "folder")
                    .foregroundStyle(exists ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(favorite.name).lineLimit(1).foregroundStyle(exists ? .primary : .secondary)
                    Text(exists ? abbreviatePath(favorite.path) : "Not found: \(abbreviatePath(favorite.path))")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if isOpen {
                    Text("open").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.2)))
                        .help("Open in a VS Code window with Claude Code")
                }
                if hovering {
                    Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .onHover { hovering = $0 }
        .help("Open \(favorite.path) in VS Code")
        .contextMenu { FavoriteMenu(favorites: favorites, favorite: favorite) }
    }
}

func abbreviatePath(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }
