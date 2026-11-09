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
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: s.projectPath)], withApplicationAt: app, configuration: config)
        let delay: TimeInterval = folderAlreadyOpen ? 1.0 : 4.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let url = URL(string: "vscode://anthropic.claude-code/open?session=\(s.id)") {
                NSWorkspace.shared.open(url)
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
