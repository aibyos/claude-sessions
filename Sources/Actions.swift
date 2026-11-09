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

    /// A VS Code that is still quitting accepts the request and then exits
    /// with it, so after launching we check it's really up and retry once.
    private static func openFolder(
        _ path: String, app: URL, retried: Bool = false, completion: ((Bool) -> Void)? = nil
    ) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: config) {
            _, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                if let message {
                    alert(
                        "Couldn't open VS Code",
                        "\(message)\n\nIf VS Code is in your Downloads folder, move it to Applications and try again.")
                    completion?(false)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if vscodeIsRunning {
                        completion?(true)
                    } else if !retried {
                        openFolder(path, app: app, retried: true, completion: completion)
                        return
                    } else {
                        alert("VS Code didn't start", "Try opening it again, or start VS Code from the Dock first.")
                        completion?(false)
                    }
                    // It may still be finishing a quit; check once more after it would have exited.
                    guard !retried else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                        if !vscodeIsRunning { openFolder(path, app: app, retried: true) }
                    }
                }
            }
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
