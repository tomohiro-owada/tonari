import Foundation
import SwiftUI

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
    @Published var model: String = "qwen3:30b-a3b"
    @Published var availableModels: [String] = []
    @Published var errorMessage: String? = nil

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

    private var currentTask: Task<Void, Never>?
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?

    init() {
        Task { await refreshModels() }
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

    private func chatLoop() async {
        isStreaming = true
        defer { isStreaming = false }

        // Loop until the assistant turn ends without pending tool calls.
        while true {
            let assistantIdx = messages.count
            messages.append(ChatMessage(role: "assistant", content: ""))

            let history = messages.dropLast().map { msg in
                ChatTurn(
                    role: msg.role,
                    content: msg.content,
                    images: msg.images,
                    toolName: msg.toolName
                )
            }
            let shouldSpeak = autoSpeak
            let useThink = thinkMode
            let modelName = model
            let toolDefs = tools

            var encounteredError: Error?
            do {
                for try await chunk in client.chat(
                    model: modelName,
                    messages: Array(history),
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
}
