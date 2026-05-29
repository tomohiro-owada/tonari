import Foundation
import SwiftUI
import AppKit

struct PendingToolCall: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let argumentsJSON: String
    var status: Status = .pending
    var resultText: String? = nil

    enum Status: String, Equatable {
        case pending      // awaiting user approval
        case executing
        case succeeded
        case failed
        case declined
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String  // user | assistant | tool | system
    var content: String
    var thinking: String = ""
    var images: [Data] = []
    var toolCalls: [PendingToolCall] = []  // assistant-issued requests
    var toolName: String? = nil            // for role == "tool" messages
}

@MainActor
final class AppState: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input: String = ""
    @Published var pendingImages: [Data] = []
    @Published var isStreaming: Bool = false
    @Published var autoSpeak: Bool = true
    @Published var thinkMode: Bool = false
    @Published var model: String = "gemma4:26b"
    @Published var availableModels: [String] = []
    @Published var errorMessage: String? = nil

    // Presence (camera) monitor settings (persisted in UserDefaults)
    @Published var autoPresenceCheck: Bool {
        didSet {
            UserDefaults.standard.set(autoPresenceCheck, forKey: "autoPresenceCheck")
            if autoPresenceCheck { startPresenceMonitor() } else { stopPresenceMonitor() }
        }
    }
    @Published var presenceIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(presenceIntervalMinutes, forKey: "presenceIntervalMinutes")
            if autoPresenceCheck { startPresenceMonitor() }
        }
    }
    @Published var presenceHistory: [PresenceLogEntry] = []
    @Published var currentPresence: PresenceLogEntry?
    @Published var isCheckingPresence: Bool = false

    // Slack (beta) — extracted credentials cached in Keychain
    @Published var slackConnected: Bool = false
    @Published var slackTokenPreview: String = ""
    @Published var slackExtractStatus: String = ""
    @Published var isExtractingSlack: Bool = false

    // Meet auto-open settings (persisted in UserDefaults)
    @Published var autoOpenMeet: Bool {
        didSet {
            UserDefaults.standard.set(autoOpenMeet, forKey: "autoOpenMeet")
            if autoOpenMeet { startMeetMonitor() } else { stopMeetMonitor() }
        }
    }
    @Published var meetLeadMinutes: Int {
        didSet { UserDefaults.standard.set(meetLeadMinutes, forKey: "meetLeadMinutes") }
    }
    @Published var meetCheckIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(meetCheckIntervalMinutes, forKey: "meetCheckIntervalMinutes")
            if autoOpenMeet { startMeetMonitor() }  // re-arm with new interval
        }
    }
    @Published var meetMonitorStatus: String = ""

    /// Tool call awaiting user confirmation. UI binds a sheet to this.
    @Published var pendingConfirmation: ConfirmationRequest? = nil

    struct ConfirmationRequest: Identifiable, Equatable {
        let id = UUID()
        let messageId: UUID       // ChatMessage that contains the tool call
        let toolCallId: UUID
        let toolName: String
        let arguments: [String: String]  // human-readable display
    }

    let client = OllamaClient()
    let speaker = Speaker()
    let eventKit = EventKitService()
    let mail = MailService()
    let camera = CameraService()
    let slackExtractor = SlackCredentialExtractor()
    private let presenceStore = PresenceLogStore()

    private var currentTask: Task<Void, Never>?
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?

    // Meet monitor state
    private var monitorTask: Task<Void, Never>?
    private var pendingOpenTasks: [Task<Void, Never>] = []
    private var openedEventIDs: Set<String> = []

    // Presence monitor state
    private var presenceMonitorTask: Task<Void, Never>?

    init() {
        let ud = UserDefaults.standard
        self.autoOpenMeet = ud.bool(forKey: "autoOpenMeet")
        self.meetLeadMinutes = max(1, ud.object(forKey: "meetLeadMinutes") as? Int ?? 5)
        self.meetCheckIntervalMinutes = max(1, ud.object(forKey: "meetCheckIntervalMinutes") as? Int ?? 10)
        self.autoPresenceCheck = ud.bool(forKey: "autoPresenceCheck")
        self.presenceIntervalMinutes = max(1, ud.object(forKey: "presenceIntervalMinutes") as? Int ?? 10)
        self.presenceHistory = presenceStore.load()
        self.currentPresence = self.presenceHistory.last
        // Load Slack creds from Tonari's keychain (no prompt — same bundle id)
        if let creds = SlackKeychain.load() {
            self.slackConnected = true
            self.slackTokenPreview = String(creds.token.suffix(6))
        }
        Task { await refreshModels() }
        if autoOpenMeet { startMeetMonitor() }
        if autoPresenceCheck { startPresenceMonitor() }
    }

    // MARK: - Slack (beta)

    func attemptSlackExtraction() {
        guard !isExtractingSlack else { return }
        isExtractingSlack = true
        slackExtractStatus = "抽出中…"
        Task.detached(priority: .userInitiated) { [extractor = slackExtractor] in
            do {
                let creds = try extractor.extract()
                try SlackKeychain.save(creds: creds)
                await MainActor.run {
                    self.slackConnected = true
                    self.slackTokenPreview = String(creds.token.suffix(6))
                    self.slackExtractStatus = "✓ 抽出成功 (token: …\(self.slackTokenPreview)、cookie: \(creds.cookieD.count)文字)"
                    self.isExtractingSlack = false
                }
            } catch {
                await MainActor.run {
                    self.slackConnected = false
                    self.slackExtractStatus = "✗ \(error.localizedDescription)"
                    self.isExtractingSlack = false
                }
            }
        }
    }

    func disconnectSlack() {
        SlackKeychain.clear()
        slackConnected = false
        slackTokenPreview = ""
        slackExtractStatus = "切断しました"
    }

    /// Briefing-style button: fetch unread DMs/mentions, inject as context,
    /// ask the LLM to summarize with priorities.
    func runSlackUnreadSummary() {
        guard !isStreaming else { return }
        guard let creds = SlackKeychain.load() else {
            errorMessage = "Slack に未接続。設定から接続してください"
            return
        }
        errorMessage = nil
        Task {
            let svc = SlackService(creds: creds)
            do {
                let auth = try await svc.authTest()
                let summary = try await svc.fetchUnreadSummary(myUserId: auth.userId)
                let block = svc.format(summary)
                messages.append(ChatMessage(
                    role: "system",
                    content: "=== Slack 未読 (\(auth.team)) ===\n\(block)"
                ))
                messages.append(ChatMessage(
                    role: "user",
                    content: "上の Slack 未読を要約し、特に対応が必要なものを優先度付きで教えてください。"
                ))
                runChatLoop()
            } catch {
                errorMessage = "Slack 取得エラー: \(error.localizedDescription)"
            }
        }
    }

    /// Briefing-style button: only unread thread replies (subscriptions.thread.getView).
    func runSlackThreadReplies() {
        guard !isStreaming else { return }
        guard let creds = SlackKeychain.load() else {
            errorMessage = "Slack に未接続。設定から接続してください"
            return
        }
        errorMessage = nil
        Task {
            let svc = SlackService(creds: creds)
            do {
                let replies = try await svc.fetchUnreadThreadReplies()
                let block = svc.formatThreadReplies(replies)
                messages.append(ChatMessage(
                    role: "system",
                    content: "=== Slack 未読リプライ ===\n\(block)"
                ))
                messages.append(ChatMessage(
                    role: "user",
                    content: "上の未読リプライを要約し、対応が必要そうなものを優先度付きで教えてください。"
                ))
                runChatLoop()
            } catch {
                errorMessage = "Slack 取得エラー: \(error.localizedDescription)"
            }
        }
    }

    func testSlackConnection() {
        guard let creds = SlackKeychain.load() else {
            slackExtractStatus = "クレデンシャル未取得"
            return
        }
        slackExtractStatus = "接続確認中…"
        Task.detached(priority: .userInitiated) {
            let svc = SlackService(creds: creds)
            do {
                let info = try await svc.authTest()
                await MainActor.run {
                    self.slackExtractStatus = "✓ \(info.team) / \(info.user) (\(info.url))"
                }
            } catch {
                await MainActor.run {
                    self.slackExtractStatus = "✗ \(error.localizedDescription)"
                }
            }
        }
    }

    func refreshModels() async {
        do {
            let models = try await client.listModels()
            self.availableModels = models
            if !models.isEmpty, !models.contains(model) {
                self.model = models.first(where: { $0.contains("gemma4") && !$0.contains("mlx") })
                    ?? models.first!
            }
        } catch {}
    }

    // MARK: - Tool definitions

    private var tools: [OllamaTool] {
        [
            OllamaTool(
                name: "add_reminder",
                description: "Create a new reminder in the user's macOS Reminders. Always asks the user for confirmation before saving.",
                parametersJSON: """
                {
                  "type": "object",
                  "properties": {
                    "title": {
                      "type": "string",
                      "description": "Reminder title shown to the user."
                    },
                    "due_date": {
                      "type": "string",
                      "description": "Optional due date in ISO 8601 e.g. 2026-05-30T09:00:00 (local time)."
                    },
                    "notes": {
                      "type": "string",
                      "description": "Optional additional notes."
                    },
                    "list_name": {
                      "type": "string",
                      "description": "Optional reminder list name. Defaults to the system default if omitted."
                    }
                  },
                  "required": ["title"]
                }
                """
            )
        ]
    }

    // MARK: - Send / chat loop

    func send() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        guard (!prompt.isEmpty || !images.isEmpty), !isStreaming else { return }
        input = ""
        pendingImages = []
        errorMessage = nil

        messages.append(ChatMessage(role: "user", content: prompt, images: images))
        runChatLoop()
    }

    /// Briefing button: fetches calendar + mail, injects as a system context
    /// message, then asks the LLM to brief the user.
    func runTodayBriefing() {
        guard !isStreaming else { return }
        errorMessage = nil

        Task {
            // Permissions
            _ = await eventKit.requestCalendarAccess()

            let calBlock = eventKit.formatTodayBriefing()

            // Mail is best-effort; if not authorized, just note it
            var mailBlock = "(メール取得をスキップ)"
            do {
                let unread = try mail.fetchUnread(limit: 5)
                mailBlock = mail.format(unread)
            } catch {
                mailBlock = "(メール取得エラー: \(error.localizedDescription))"
            }

            let now = DateFormatter()
            now.locale = Locale(identifier: "ja_JP")
            now.dateFormat = "yyyy年M月d日 (E) HH:mm"
            let context = """
            現在時刻: \(now.string(from: Date()))

            === 今日のカレンダー ===
            \(calBlock)

            === 未読メール (最大5件) ===
            \(mailBlock)
            """

            messages.append(ChatMessage(role: "system", content: context))
            messages.append(ChatMessage(
                role: "user",
                content: "上のコンテキストをもとに、今日の動きを簡潔にブリーフィングしてください。優先度が高そうな項目があれば指摘して。"
            ))
            runChatLoop()
        }
    }

    /// Inject a generic mail summary request.
    func runMailSummary() {
        guard !isStreaming else { return }
        errorMessage = nil

        Task {
            var mailBlock = ""
            do {
                let unread = try mail.fetchUnread(limit: 10)
                mailBlock = mail.format(unread)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            messages.append(ChatMessage(role: "system", content: "=== 未読メール (最大10件) ===\n\(mailBlock)"))
            messages.append(ChatMessage(
                role: "user",
                content: "未読メールの要約と、特に対応が必要そうなものを教えてください。"
            ))
            runChatLoop()
        }
    }

    // MARK: - Chat loop with tool-call handling

    private func runChatLoop() {
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            await self?.chatLoop()
        }
    }

    private static let baseSystemPrompt = """
    あなたは macOS で動く個人アシスタント "Tonari" です。応答は以下のルールに従ってください:
    - Markdown の装飾記号は使わない: アスタリスクによる太字や斜体 (**bold**, *italic*)、シャープによる見出し (#, ##)、ハイフンの箇条書き (- )、引用 (>) を一切出力しない
    - 列挙が必要な場合は行頭に「・」を使ったプレーンテキスト箇条書き
    - 見出しが必要な場合は「── タイトル ──」のような区切り線
    - コードを示す場合のみバッククォートを使ってよい
    - 装飾より中身を重視し、簡潔に
    - ユーザーの言語に合わせる (日本語の質問には日本語で)
    """

    private func chatLoop() async {
        isStreaming = true
        defer { isStreaming = false }

        // Loop until the assistant turn ends without pending tool calls.
        while true {
            let assistantIdx = messages.count
            messages.append(ChatMessage(role: "assistant", content: ""))

            var history: [ChatTurn] = [
                ChatTurn(role: "system", content: Self.baseSystemPrompt)
            ]
            history.append(contentsOf: messages.dropLast().map { msg in
                ChatTurn(
                    role: msg.role,
                    content: msg.content,
                    images: msg.images,
                    toolName: msg.toolName
                )
            })
            let shouldSpeak = autoSpeak
            let useThink = thinkMode
            let modelName = model
            let toolDefs = tools

            var encounteredError: Error?
            do {
                for try await chunk in client.chat(
                    model: modelName,
                    messages: history,
                    tools: toolDefs,
                    think: useThink
                ) {
                    guard assistantIdx < messages.count else { continue }
                    switch chunk {
                    case .thinking(let s):
                        messages[assistantIdx].thinking += s
                    case .answer(let s):
                        messages[assistantIdx].content += s
                    case .toolCall(let name, let argsJSON):
                        let call = PendingToolCall(name: name, argumentsJSON: argsJSON)
                        messages[assistantIdx].toolCalls.append(call)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                encounteredError = error
            }

            if let err = encounteredError {
                errorMessage = "エラー: \(err.localizedDescription)"
                return
            }

            // TTS: speak the assistant's natural-language content only
            if shouldSpeak, assistantIdx < messages.count {
                let text = messages[assistantIdx].content
                if !text.isEmpty { speaker.speak(text) }
            }

            // Handle pending tool calls (if any). For each: ask user, execute, append tool message.
            let pendingCalls = messages[assistantIdx].toolCalls
            if pendingCalls.isEmpty { return }

            var anyDispatched = false
            for (i, call) in pendingCalls.enumerated() {
                guard call.status == .pending else { continue }
                let approved = await requestConfirmation(
                    messageId: messages[assistantIdx].id,
                    toolCallId: call.id,
                    name: call.name,
                    argumentsJSON: call.argumentsJSON
                )
                guard assistantIdx < messages.count,
                      i < messages[assistantIdx].toolCalls.count else { return }

                if approved {
                    messages[assistantIdx].toolCalls[i].status = .executing
                    let result = await executeTool(name: call.name, argumentsJSON: call.argumentsJSON)
                    messages[assistantIdx].toolCalls[i].resultText = result.text
                    messages[assistantIdx].toolCalls[i].status = result.success ? .succeeded : .failed
                    messages.append(ChatMessage(
                        role: "tool",
                        content: result.text,
                        toolName: call.name
                    ))
                } else {
                    messages[assistantIdx].toolCalls[i].status = .declined
                    messages[assistantIdx].toolCalls[i].resultText = "ユーザーが拒否しました"
                    messages.append(ChatMessage(
                        role: "tool",
                        content: "User declined the tool call.",
                        toolName: call.name
                    ))
                }
                anyDispatched = true
            }

            // If we dispatched at least one tool, loop again for the LLM follow-up.
            if !anyDispatched { return }
        }
    }

    private func requestConfirmation(
        messageId: UUID,
        toolCallId: UUID,
        name: String,
        argumentsJSON: String
    ) async -> Bool {
        let argsObj = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let humanArgs = Dictionary(uniqueKeysWithValues: argsObj.map { (k, v) in (k, "\(v)") })
        pendingConfirmation = ConfirmationRequest(
            messageId: messageId,
            toolCallId: toolCallId,
            toolName: name,
            arguments: humanArgs
        )
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.confirmationContinuation = cont
        }
    }

    /// UI calls this when the user approves or declines a pending tool call.
    func resolveConfirmation(approved: Bool) {
        pendingConfirmation = nil
        confirmationContinuation?.resume(returning: approved)
        confirmationContinuation = nil
    }

    // MARK: - Tool execution

    private struct ToolResult {
        let success: Bool
        let text: String
    }

    private func executeTool(name: String, argumentsJSON: String) async -> ToolResult {
        switch name {
        case "add_reminder":
            return executeAddReminder(argumentsJSON: argumentsJSON)
        default:
            return ToolResult(success: false, text: "Unknown tool: \(name)")
        }
    }

    private func executeAddReminder(argumentsJSON: String) -> ToolResult {
        guard let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any],
              let title = args["title"] as? String, !title.isEmpty else {
            return ToolResult(success: false, text: "Missing or invalid 'title' argument.")
        }
        let notes = args["notes"] as? String
        let listName = args["list_name"] as? String
        var dueDate: Date? = nil
        if let dueStr = args["due_date"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: dueStr) {
                dueDate = d
            } else {
                let f2 = ISO8601DateFormatter()
                f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                dueDate = f2.date(from: dueStr)
            }
            if dueDate == nil {
                // try without timezone "yyyy-MM-dd'T'HH:mm:ss"
                let f3 = DateFormatter()
                f3.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                f3.timeZone = TimeZone.current
                dueDate = f3.date(from: dueStr)
            }
        }
        do {
            let id = try eventKit.addReminder(title: title, dueDate: dueDate, notes: notes, listName: listName)
            return ToolResult(success: true, text: "Reminder created (id: \(id)) title: \(title)")
        } catch {
            return ToolResult(success: false, text: "Failed to create reminder: \(error.localizedDescription)")
        }
    }

    // MARK: - Control

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        // If a confirmation was pending, treat stop as decline so the loop unwinds.
        if let cont = confirmationContinuation {
            confirmationContinuation = nil
            pendingConfirmation = nil
            cont.resume(returning: false)
        }
        speaker.stop()
        isStreaming = false
    }

    func clear() {
        stop()
        messages.removeAll()
        errorMessage = nil
    }

    // MARK: - Meet auto-open monitor

    func startMeetMonitor() {
        stopMeetMonitor()
        let interval = TimeInterval(meetCheckIntervalMinutes) * 60
        monitorTask = Task { [weak self] in
            // Run an initial check immediately, then loop.
            while !Task.isCancelled {
                await self?.checkAndScheduleMeetOpens()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        meetMonitorStatus = "ON (\(meetCheckIntervalMinutes)分間隔 / \(meetLeadMinutes)分前に起動)"
    }

    func stopMeetMonitor() {
        monitorTask?.cancel()
        monitorTask = nil
        for t in pendingOpenTasks { t.cancel() }
        pendingOpenTasks.removeAll()
        meetMonitorStatus = ""
    }

    private func checkAndScheduleMeetOpens() async {
        // Make sure we have calendar permission (no-op if already granted).
        _ = await eventKit.requestCalendarAccess()

        // Window: check events starting within (interval + lead) so we never miss
        // one between polls.
        let now = Date()
        let windowEnd = now.addingTimeInterval(
            TimeInterval(meetCheckIntervalMinutes + meetLeadMinutes) * 60
        )
        let events = eventKit.events(from: now, to: windowEnd)

        for ev in events {
            if openedEventIDs.contains(ev.id) { continue }
            guard let meetURL = extractMeetURL(url: ev.url, notes: ev.notes, location: ev.location) else { continue }

            let openAt = ev.start.addingTimeInterval(-TimeInterval(meetLeadMinutes) * 60)
            let delay = openAt.timeIntervalSinceNow
            let eventID = ev.id
            let title = ev.title

            if delay <= 0 {
                // Already within the lead window — open immediately.
                NSWorkspace.shared.open(meetURL)
                openedEventIDs.insert(eventID)
                NSLog("Tonari: opened Meet for '%@' (now)", title)
            } else {
                let task = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, !Task.isCancelled, self.autoOpenMeet else { return }
                    if self.openedEventIDs.contains(eventID) { return }
                    NSWorkspace.shared.open(meetURL)
                    self.openedEventIDs.insert(eventID)
                    NSLog("Tonari: opened Meet for '%@' (scheduled)", title)
                }
                pendingOpenTasks.append(task)
            }
        }
        // Prune completed scheduled tasks
        pendingOpenTasks.removeAll { $0.isCancelled }
    }

    /// Find a Google Meet URL across event.url / notes / location.
    private func extractMeetURL(url: URL?, notes: String?, location: String?) -> URL? {
        if let url, url.host?.contains("meet.google.com") == true { return url }
        let pattern = #"https?://meet\.google\.com/[a-zA-Z0-9\-_?=&]+"#
        for text in [notes, location, url?.absoluteString] {
            guard let text else { continue }
            if let range = text.range(of: pattern, options: .regularExpression) {
                if let u = URL(string: String(text[range])) { return u }
            }
        }
        return nil
    }

    /// Manual "test" trigger — runs the same logic once. Useful from settings UI.
    func runMeetMonitorOnce() {
        Task { await checkAndScheduleMeetOpens() }
    }

    /// Open the next upcoming meeting's Meet URL right now.
    /// Walks the next 2 days, skipping events that have already ended.
    func openNextMeetNow() {
        errorMessage = nil
        Task {
            _ = await eventKit.requestCalendarAccess()
            let now = Date()
            let windowStart = now.addingTimeInterval(-5 * 60)   // catch events that just started
            let windowEnd = Calendar.current.date(byAdding: .day, value: 2, to: now) ?? now
            let events = eventKit.events(from: windowStart, to: windowEnd)
                .sorted { $0.start < $1.start }
            for ev in events {
                if ev.end < now { continue }
                if let url = extractMeetURL(url: ev.url, notes: ev.notes, location: ev.location) {
                    NSWorkspace.shared.open(url)
                    return
                }
            }
            errorMessage = "今後2日以内のカレンダーに Meet URL を持つ予定が見つかりません"
        }
    }

    // MARK: - Presence monitor (camera → vision LLM)

    private static let presencePrompt = """
    あなたはウェブカメラの 1 フレームを見て、ユーザーの状態を判定するアシスタントです。
    以下のカテゴリから1つだけ選んでください: present, away, eating, on_phone, talking, other

    意味:
    - present: 人物が机に向かって作業している
    - away: 人物が写っていない (席を外している)
    - eating: 飲食している
    - on_phone: スマートフォンを見ている
    - talking: 誰かと会話している、または通話中
    - other: 上記に当てはまらない

    必ず以下の JSON 形式のみで応答してください。説明文や前置きは一切不要:
    {"status": "<カテゴリ>", "note": "<20文字以内の日本語補足>"}
    """

    func startPresenceMonitor() {
        stopPresenceMonitor()
        let interval = TimeInterval(presenceIntervalMinutes) * 60
        presenceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runPresenceCheckOnce()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPresenceMonitor() {
        presenceMonitorTask?.cancel()
        presenceMonitorTask = nil
    }

    func runPresenceCheckOnce() async {
        guard !isCheckingPresence else { return }
        isCheckingPresence = true
        defer { isCheckingPresence = false }

        let modelName = model
        let entry: PresenceLogEntry

        do {
            let jpeg = try await camera.captureOneJPEG()
            let raw = try await client.oneShot(
                model: modelName,
                prompt: Self.presencePrompt + " /no_think",
                image: jpeg,
                timeout: 120
            )
            let (status, note) = Self.parsePresenceResponse(raw)
            entry = PresenceLogEntry(
                status: status,
                note: note,
                model: modelName,
                rawResponse: raw
            )
        } catch {
            entry = PresenceLogEntry(
                status: .error,
                note: error.localizedDescription,
                model: modelName,
                rawResponse: nil
            )
        }

        presenceHistory.append(entry)
        currentPresence = entry
        presenceStore.save(presenceHistory)
    }

    /// Extract `{"status": "...", "note": "..."}` from the LLM's text reply.
    private static func parsePresenceResponse(_ text: String) -> (PresenceStatus, String) {
        // Find the first JSON object in the response
        if let range = text.range(of: #"\{[^{}]*\}"#, options: .regularExpression),
           let data = String(text[range]).data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let statusStr = (json["status"] as? String) ?? "other"
            let note = (json["note"] as? String) ?? ""
            let status = PresenceStatus(rawValue: statusStr) ?? .other
            return (status, note)
        }
        return (.other, text.prefix(40).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func clearPresenceHistory() {
        presenceHistory.removeAll()
        currentPresence = nil
        presenceStore.save(presenceHistory)
    }
}
