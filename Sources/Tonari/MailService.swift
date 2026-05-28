import Foundation

struct MailMessage: Identifiable {
    let id = UUID()
    let subject: String
    let sender: String
    let date: String
    let snippet: String
}

/// Reads Mail.app via AppleScript.
///
/// Mail.app must be running (or will be launched). On first invocation macOS
/// shows the Apple Events automation permission prompt — without it the script
/// returns errAEEventNotPermitted.
final class MailService {

    enum MailError: Error, LocalizedError {
        case scriptCompile
        case scriptExecution(String)
        case notAuthorized

        var errorDescription: String? {
            switch self {
            case .scriptCompile: return "AppleScript のコンパイルに失敗"
            case .scriptExecution(let s): return "Mail.app 実行エラー: \(s)"
            case .notAuthorized: return "Mail.app へのアクセスが許可されていません。システム設定 > プライバシーとセキュリティ > オートメーション で OllamaBar に Mail を許可してください。"
            }
        }
    }

    /// Fetch up to `limit` unread messages from the unified inbox.
    /// `bodyChars` caps how much of each message body is returned.
    func fetchUnread(limit: Int = 10, bodyChars: Int = 400) throws -> [MailMessage] {
        let script = """
        tell application "Mail"
            set RS to character id 30
            set FS to character id 31
            set out to ""
            set msgs to (messages of inbox whose read status is false)
            set N to count of msgs
            if N > \(limit) then set N to \(limit)
            repeat with i from 1 to N
                set msg to item i of msgs
                try
                    set msgSubj to subject of msg
                on error
                    set msgSubj to ""
                end try
                try
                    set msgFrom to sender of msg
                on error
                    set msgFrom to ""
                end try
                try
                    set msgDate to (date received of msg) as string
                on error
                    set msgDate to ""
                end try
                try
                    set msgBody to content of msg
                    if (length of msgBody) > \(bodyChars) then set msgBody to (text 1 thru \(bodyChars) of msgBody)
                on error
                    set msgBody to ""
                end try
                set out to out & msgSubj & FS & msgFrom & FS & msgDate & FS & msgBody & RS
            end repeat
            return out
        end tell
        """
        return try run(script: script)
    }

    /// Fetch recent N messages (read or unread) from the unified inbox.
    func fetchRecent(limit: Int = 10, bodyChars: Int = 400) throws -> [MailMessage] {
        let script = """
        tell application "Mail"
            set RS to character id 30
            set FS to character id 31
            set out to ""
            set msgs to (messages of inbox)
            set N to count of msgs
            if N > \(limit) then set N to \(limit)
            repeat with i from 1 to N
                set msg to item i of msgs
                try
                    set msgSubj to subject of msg
                on error
                    set msgSubj to ""
                end try
                try
                    set msgFrom to sender of msg
                on error
                    set msgFrom to ""
                end try
                try
                    set msgDate to (date received of msg) as string
                on error
                    set msgDate to ""
                end try
                try
                    set msgBody to content of msg
                    if (length of msgBody) > \(bodyChars) then set msgBody to (text 1 thru \(bodyChars) of msgBody)
                on error
                    set msgBody to ""
                end try
                set out to out & msgSubj & FS & msgFrom & FS & msgDate & FS & msgBody & RS
            end repeat
            return out
        end tell
        """
        return try run(script: script)
    }

    // MARK: - Internal

    private func run(script: String) throws -> [MailMessage] {
        guard let s = NSAppleScript(source: script) else { throw MailError.scriptCompile }
        var err: NSDictionary?
        let result = s.executeAndReturnError(&err)
        if let err {
            let n = (err["NSAppleScriptErrorNumber"] as? Int) ?? 0
            if n == -1743 { throw MailError.notAuthorized }
            let msg = (err["NSAppleScriptErrorMessage"] as? String) ?? "unknown"
            throw MailError.scriptExecution("\(msg) (code \(n))")
        }
        guard let raw = result.stringValue else { return [] }
        return parse(raw)
    }

    private func parse(_ raw: String) -> [MailMessage] {
        let RS = String(UnicodeScalar(30)!)
        let FS = String(UnicodeScalar(31)!)
        var out: [MailMessage] = []
        for record in raw.components(separatedBy: RS) where !record.isEmpty {
            let parts = record.components(separatedBy: FS)
            guard parts.count >= 4 else { continue }
            // Clean body: collapse whitespace, drop quoted reply lines
            let body = parts[3]
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
                .joined(separator: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(MailMessage(
                subject: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                sender: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
                date: parts[2].trimmingCharacters(in: .whitespacesAndNewlines),
                snippet: body
            ))
        }
        return out
    }

    // MARK: - Formatting

    func format(_ messages: [MailMessage]) -> String {
        if messages.isEmpty { return "該当するメールはありません。" }
        return messages.enumerated().map { i, m in
            "[\(i+1)] \(m.subject)\n   差出人: \(m.sender)\n   日時: \(m.date)\n   本文抜粋: \(m.snippet)"
        }.joined(separator: "\n\n")
    }
}
