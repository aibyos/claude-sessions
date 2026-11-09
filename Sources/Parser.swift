import Darwin
import Foundation

// Transcripts can be tens of MB, mostly tool output and API payloads we don't
// need. Each line is classified by looking at its first bytes, and only the
// small set of interesting records is JSON-decoded.

private let maxStoredPrompts = 300
private let maxPromptLength = 800

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func parseSession(at url: URL, projectFolder: String, size: UInt64, mtime: Date) -> SessionInfo? {
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
    var info = SessionInfo(
        id: url.deletingPathExtension().lastPathComponent,
        filePath: url.path,
        projectFolder: projectFolder,
        lastActivity: mtime,
        fileSize: size
    )
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let p = base + offset
            let remaining = raw.count - offset
            let length = memchr(p, 0x0A, remaining).map { p.distance(to: UnsafeRawPointer($0)) } ?? remaining
            if length > 2 { handleLine(UnsafeRawBufferPointer(start: p, count: length), &info) }
            offset += length + 1
        }
    }
    return info
}

private func contains(_ line: UnsafeRawBufferPointer, _ needle: StaticString, within n: Int) -> Bool {
    guard let base = line.baseAddress else { return false }
    return memmem(base, min(n, line.count), needle.utf8Start, needle.utf8CodeUnitCount) != nil
}

/// Reads the JSON string value following `key` (e.g. `"model":"`) without decoding the line.
private func rawString(_ line: UnsafeRawBufferPointer, after key: StaticString, within n: Int) -> String? {
    guard let base = line.baseAddress else { return nil }
    let limit = min(n, line.count)
    guard let hit = memmem(base, limit, key.utf8Start, key.utf8CodeUnitCount) else { return nil }
    let start = UnsafeRawPointer(hit) + key.utf8CodeUnitCount
    let end = base + limit
    var q = start
    while q < end {
        let c = q.load(as: UInt8.self)
        if c == 0x22 { break }
        if c == 0x5C { q += 1 }
        q += 1
    }
    guard q < end else { return nil }
    return String(decoding: UnsafeRawBufferPointer(start: start, count: start.distance(to: q)), as: UTF8.self)
}

private func decode(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
    guard let base = line.baseAddress else { return nil }
    let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private let htmlToolPattern = try! NSRegularExpression(
    pattern: #""name":"(?:Write|Edit|MultiEdit|Artifact)","input":\{"file_path":"((?:[^"\\]|\\.)*?\.html?)""#,
    options: [.caseInsensitive])

/// Collects HTML files written or edited through tool calls. Only the few
/// lines that contain both markers are converted to a String.
private func collectHTMLFiles(_ line: UnsafeRawBufferPointer, _ info: inout SessionInfo) {
    guard contains(line, "\"input\":{\"file_path\":\"", within: line.count),
        contains(line, ".htm", within: line.count)
    else { return }
    let text = String(decoding: line, as: UTF8.self)
    for m in htmlToolPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let r = Range(m.range(at: 1), in: text) else { continue }
        let path = text[r].replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\\\", with: "\\")
        if !info.htmlFiles.contains(path) { info.htmlFiles.append(path) }
    }
}

private func handleLine(_ line: UnsafeRawBufferPointer, _ info: inout SessionInfo) {
    let head = 1200
    collectHTMLFiles(line, &info)

    if info.created == nil, line.count < 8192,
        let ts = rawString(line, after: "\"timestamp\":\"", within: line.count)
    {
        info.created = isoFormatter.date(from: ts)
    }

    if contains(line, "\"type\":\"user\"", within: head) {
        // Tool results and subagent turns are the bulk of the file; skip them undecoded.
        if contains(line, "\"isSidechain\":true", within: head) || contains(line, "\"tool_result\"", within: head) {
            return
        }
        guard let obj = decode(line) else { return }
        if info.cwd == nil { info.cwd = obj["cwd"] as? String }
        if let b = obj["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { info.gitBranch = b }
        if info.entrypoint == nil { info.entrypoint = obj["entrypoint"] as? String }
        if let v = obj["version"] as? String { info.version = v }
        let time = (obj["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) }
        if info.created == nil { info.created = time }
        if let text = promptText(obj) {
            info.promptCount += 1
            if info.prompts.count < maxStoredPrompts {
                let clipped = text.count > maxPromptLength ? String(text.prefix(maxPromptLength)) + "…" : text
                info.prompts.append(Prompt(text: clipped, time: time))
            }
        }
        return
    }

    if contains(line, "\"type\":\"assistant\"", within: head) {
        if let m = rawString(line, after: "\"model\":\"", within: 4000), m.hasPrefix("claude") { info.model = m }
        return
    }

    // Small metadata records.
    guard line.count < 64 * 1024 else { return }
    if contains(line, "\"type\":\"session-owner\"", within: 200), let obj = decode(line) {
        info.accountId = obj["accountUuid"] as? String
        info.organizationId = obj["organizationUuid"] as? String
    } else if contains(line, "\"type\":\"ai-title\"", within: 200), let obj = decode(line) {
        info.aiTitle = obj["aiTitle"] as? String
    } else if contains(line, "\"type\":\"custom-title\"", within: 200), let obj = decode(line) {
        // A title the user set with /rename wins over the AI one.
        if let t = obj["customTitle"] as? String { info.aiTitle = t }
    } else if contains(line, "\"type\":\"last-prompt\"", within: 200), let obj = decode(line) {
        info.lastPrompt = obj["lastPrompt"] as? String
    } else if contains(line, "\"type\":\"pr-link\"", within: 200), let obj = decode(line),
        let url = obj["prUrl"] as? String, !info.prs.contains(where: { $0.url == url })
    {
        info.prs.append(
            PRLink(number: obj["prNumber"] as? Int ?? 0, url: url, repo: obj["prRepository"] as? String ?? ""))
    } else if contains(line, "\"type\":\"frame-link\"", within: 200), let obj = decode(line),
        let url = obj["frameUrl"] as? String, !info.artifacts.contains(where: { $0.url == url })
    {
        info.artifacts.append(ArtifactLink(title: obj["title"] as? String ?? "Artifact", url: url))
    } else if info.cwd == nil, let cwd = rawString(line, after: "\"cwd\":\"", within: line.count) {
        info.cwd = cwd
    }
}

// MARK: - Prompt text

private let noisePatterns: [NSRegularExpression] = [
    "<system-reminder>[\\s\\S]*?</system-reminder>",
    "<ide_[a-z_]+>[\\s\\S]*?</ide_[a-z_]+>",
    "<command-message>[\\s\\S]*?</command-message>",
    "<local-command-[a-z]+>[\\s\\S]*?</local-command-[a-z]+>",
].map { try! NSRegularExpression(pattern: $0) }

private let pastedPattern = try! NSRegularExpression(pattern: "<pasted_content[^>]*>[\\s\\S]*?</pasted_content>")

private let skippedPrefixes = [
    "<task-notification", "<local-command", "<bash-", "<user-prompt-submit-hook",
    "This session is being continued", "Caveat: The messages below",
]

private func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
    re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
}

private func between(_ s: String, _ open: String, _ close: String) -> String? {
    guard let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex) else { return nil }
    return String(s[a.upperBound..<b.lowerBound])
}

/// The human-typed text of a user record, or nil for tool results, meta and
/// system-injected messages.
private func promptText(_ obj: [String: Any]) -> String? {
    if obj["isMeta"] as? Bool == true || obj["isCompactSummary"] as? Bool == true { return nil }
    if obj["isSidechain"] as? Bool == true || obj["toolUseResult"] != nil { return nil }
    guard let message = obj["message"] as? [String: Any] else { return nil }

    var texts: [String] = []
    var images = 0
    if let s = message["content"] as? String {
        texts = [s]
    } else if let blocks = message["content"] as? [[String: Any]] {
        for b in blocks {
            switch b["type"] as? String {
            case "text": if let t = b["text"] as? String { texts.append(t) }
            case "image": images += 1
            case "tool_result": return nil
            default: break
            }
        }
    }

    var parts: [String] = []
    for raw in texts {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("<command-name>") {
            let name = between(t, "<command-name>", "</command-name>") ?? ""
            let args = between(t, "<command-args>", "</command-args>") ?? ""
            parts.append("\(name) \(args)".trimmingCharacters(in: .whitespacesAndNewlines))
            continue
        }
        if skippedPrefixes.contains(where: { t.hasPrefix($0) }) { continue }
        var cleaned = noisePatterns.reduce(t) { replace($1, in: $0, with: "") }
        cleaned = replace(pastedPattern, in: cleaned, with: "[pasted text]")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { parts.append(cleaned) }
    }
    if parts.isEmpty { return images > 0 ? "[image]" : nil }
    return parts.joined(separator: "\n")
}
