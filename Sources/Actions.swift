import AppKit
import Foundation

@MainActor
enum Actions {
    static let vscodeBundleID = "com.microsoft.VSCode"

    static var vscodeURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: vscodeBundleID) }

    /// Opens the project folder in VS Code, then asks the Claude Code extension
    /// to open this conversation. The extension's URI handler acts on the
    /// focused VS Code window, which is why the folder is opened first.
    @MainActor
    static func openInVSCode(_ s: SessionInfo, folderAlreadyOpen: Bool) {
        guard let app = vscodeURL else {
            alert("Visual Studio Code isn't installed", "Use “Resume in Terminal” instead.")
            return
        }
        openFolder(s.projectPath, app: app)
        let delay: TimeInterval = folderAlreadyOpen ? 1.0 : 4.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let url = URL(string: "vscode://anthropic.claude-code/open?session=\(s.id)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Opens a folder or `.code-workspace` file in VS Code (focuses it if already open),
    /// starting VS Code if needed. `completion` reports whether VS Code is up.
    static func openFolderInVSCode(_ path: String, completion: ((Bool) -> Void)? = nil) {
        guard let app = vscodeURL else {
            alert("Visual Studio Code isn't installed", "Install it from code.visualstudio.com.")
            completion?(false)
            return
        }
        openFolder(path, app: app, completion: completion)
    }

    static var vscodeIsRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: vscodeBundleID)
            .contains { !$0.isTerminated }
    }

    /// Launches VS Code with the folder, then follows the launched process:
    /// a cold start can take several seconds (longer for a quarantined app in
    /// Downloads), while a request that reached a VS Code that was still
    /// quitting dies with it and is sent again once.
    private static func openFolder(
        _ path: String, app: URL, retried: Bool = false, completion: ((Bool) -> Void)? = nil
    ) {
        trace("open \(path) with \(app.path), running=\(vscodeIsRunning), retry=\(retried)")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: config) {
            launched, error in
            let pid = launched?.processIdentifier
            let message = error?.localizedDescription
            Task { @MainActor in
                trace("open returned pid=\(pid.map(String.init) ?? "nil") error=\(message ?? "none")")
                if let message {
                    alert(
                        "Couldn't open VS Code",
                        "\(message)\n\nIf VS Code is in your Downloads folder, move it to Applications and try again.")
                    completion?(false)
                    return
                }
                follow(pid: pid, path: path, app: app, retried: retried, since: Date(), completion: completion)
            }
        }
    }

    private static func follow(
        pid: pid_t?, path: String, app: URL, retried: Bool, since: Date, completion: ((Bool) -> Void)?
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let elapsed = Date().timeIntervalSince(since)
            let alive = pid.map { kill($0, 0) == 0 } ?? vscodeIsRunning
            if !alive {
                trace("VS Code process \(pid.map(String.init) ?? "?") exited after \(Int(elapsed)) s, running=\(vscodeIsRunning)")
                if vscodeIsRunning {
                    completion?(true)  // handed the folder to another VS Code instance
                } else if !retried {
                    openFolder(path, app: app, retried: true, completion: completion)
                } else {
                    alert("VS Code didn't start", "VS Code quit right after starting. Open it from the Dock, then try again.")
                    completion?(false)
                }
                return
            }
            // Stayed up long enough that it wasn't a VS Code on its way out.
            let ready = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.isFinishedLaunching } ?? true
            if ready && elapsed >= 3 {
                trace("VS Code up after \(Int(elapsed)) s")
                completion?(true)
            } else if elapsed > 45 {
                trace("VS Code still starting after 45 s")
                completion?(true)
            } else {
                follow(pid: pid, path: path, app: app, retried: retried, since: since, completion: completion)
            }
        }
    }

    /// Launch steps go to ~/Library/Caches/ClaudeSessions/vscode-launch.log for troubleshooting.
    static func trace(_ line: String) {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeSessions/vscode-launch.log")
        let entry = "\(Date().formatted(.iso8601)) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(entry.utf8))
            try? h.close()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func resumeCommand(_ s: SessionInfo) -> String {
        "cd \(shellQuote(s.projectPath)) && claude --resume \(s.id)"
    }

    /// Writes a `.command` file and opens it, which runs it in Terminal.app
    /// without needing any automation permission.
    static func resumeInTerminal(_ s: SessionInfo) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("resume-\(s.id.prefix(8)).command")
        let body = """
            #!/bin/zsh -l
            clear
            echo "Resuming: \(s.title.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "$", with: ""))"
            echo "Folder:   \(s.projectPath.replacingOccurrences(of: "\"", with: "'"))"
            echo
            cd \(shellQuote(s.projectPath)) || exit 1
            claude --resume \(s.id)
            exec $SHELL -l
            """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            alert("Couldn't start Terminal", error.localizedDescription)
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func revealTranscript(_ s: SessionInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.filePath)])
    }

    static func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    /// Ends a running session's process after confirmation. The transcript is
    /// already on disk, so the conversation can be resumed later.
    @MainActor
    static func stop(_ r: RunningSession, title: String) {
        let a = NSAlert()
        a.messageText = "Stop this session?"
        a.informativeText = """
            “\(title)” (process \(r.pid), using \(bytes(r.footprint, memory: true))).

            The conversation is saved, so you can resume it any time. A reply that is being written right now will be cut off, and an open VS Code tab for it will show the session as ended.
            """
        a.addButton(withTitle: "Stop Session")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            kill(r.pid, SIGTERM)
        }
    }

    @MainActor
    static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
