import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var inputFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            actionBar
            Divider()
            messagesArea
            Divider()
            inputArea
        }
        .onAppear { inputFocused = true }
        .sheet(item: $state.pendingConfirmation) { req in
            ToolConfirmationSheet(request: req) { approved in
                state.resolveConfirmation(approved: approved)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            Button {
                state.runTodayBriefing()
            } label: {
                Label("今日のブリーフィング", systemImage: "sun.max")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .disabled(state.isStreaming)

            Button {
                state.runMailSummary()
            } label: {
                Label("未読メール要約", systemImage: "envelope")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .disabled(state.isStreaming)

            Button {
                state.openNextMeetNow()
            } label: {
                Label("次の Meet", systemImage: "video.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .help("直近の Meet URL 付き予定をブラウザで開く")

            if state.slackConnected {
                Button {
                    state.runSlackUnreadSummary()
                } label: {
                    Label("Slack 未読", systemImage: "number.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(state.isStreaming)
                .help("未読 DM・メンション・チャンネルを要約")

                Button {
                    state.runSlackThreadReplies()
                } label: {
                    Label("未読リプライ", systemImage: "bubble.left.and.bubble.right")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(state.isStreaming)
                .help("購読中スレッドの未読リプライのみを要約")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(state.availableModels, id: \.self) { name in
                    Button {
                        state.model = name
                    } label: {
                        if name == state.model {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
                Divider()
                Button {
                    Task { await state.refreshModels() }
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    Text(state.model)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()

            if let p = state.currentPresence {
                HStack(spacing: 3) {
                    Text(p.status.emoji)
                    Text(p.status.label)
                        .font(.caption)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.7), in: Capsule())
                .help("最新の在席判定: \(p.note) (\(p.timestamp.formatted(date: .omitted, time: .shortened)))")
            }

            Toggle(isOn: $state.thinkMode) {
                Image(systemName: "brain")
            }
            .toggleStyle(.button)
            .help("思考モード")

            Toggle(isOn: $state.autoSpeak) {
                Image(systemName: state.autoSpeak ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .toggleStyle(.button)
            .help("応答を読み上げ")

            Button(action: state.clear) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("履歴をクリア")

            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("設定")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if state.messages.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("ローカル LLM とチャット")
                                .foregroundStyle(.secondary)
                            Text("⌘↵ で送信 · 画像は D&D / ⌘V")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                    ForEach(state.messages) { msg in
                        if msg.role == "tool" {
                            ToolResultRow(message: msg)
                                .id(msg.id)
                        } else if msg.role == "system" {
                            SystemContextRow(message: msg)
                                .id(msg.id)
                        } else {
                            MessageRow(message: msg) {
                                state.speaker.speak(msg.content)
                            }
                            .id(msg.id)
                        }
                    }
                    if let err = state.errorMessage {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
                .padding(12)
            }
            .onChange(of: state.messages.reduce(0) { $0 + $1.thinking.count + $1.content.count }) { _, _ in
                if let last = state.messages.last {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var inputArea: some View {
        VStack(spacing: 6) {
            if !state.pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.pendingImages.indices, id: \.self) { idx in
                            PendingImageThumb(data: state.pendingImages[idx]) {
                                state.pendingImages.remove(at: idx)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 56)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: pickImage) {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .help("画像を添付")

                TextField("メッセージ…", text: $state.input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .background(PasteCatcher { data in
                        state.pendingImages.append(data)
                    })

                if state.isStreaming {
                    Button(action: state.stop) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("停止")
                } else {
                    Button(action: state.send) {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && state.pendingImages.isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help("送信 (⌘↵)")
                }
            }
        }
        .padding(12)
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let data = try? Data(contentsOf: url) {
                    state.pendingImages.append(data)
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data {
                        Task { @MainActor in
                            state.pendingImages.append(data)
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url) else { return }
                    Task { @MainActor in
                        state.pendingImages.append(data)
                    }
                }
            }
        }
        return accepted
    }
}

struct PendingImageThumb: View {
    let data: Data
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary.opacity(0.2))
                    .frame(width: 52, height: 52)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .offset(x: 4, y: -4)
        }
        .padding(4)
    }
}

/// Catches Cmd+V containing image data and forwards as Data via the callback.
struct PasteCatcher: NSViewRepresentable {
    let onPaste: (Data) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = PasteView()
        v.onPaste = onPaste
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PasteView)?.onPaste = onPaste
    }

    final class PasteView: NSView {
        var onPaste: ((Data) -> Void)?
        override var acceptsFirstResponder: Bool { false }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "v" {
                let pb = NSPasteboard.general
                if let img = pb.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
                   let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    onPaste?(png)
                    return true  // consume — don't paste as text
                }
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let onSpeak: () -> Void
    @State private var showFullThinking = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: message.role == "user" ? "person.crop.circle.fill" : "sparkles")
                .foregroundStyle(message.role == "user" ? .blue : .purple)
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                if !message.images.isEmpty {
                    imageStrip
                }
                if !message.thinking.isEmpty {
                    thinkingView
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if message.role == "assistant" && message.thinking.isEmpty && message.toolCalls.isEmpty {
                    Text("…")
                        .foregroundStyle(.secondary)
                }
                if !message.toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(message.toolCalls) { call in
                            ToolCallCard(call: call)
                        }
                    }
                }
                if message.role == "assistant" && !message.content.isEmpty {
                    Button(action: onSpeak) {
                        Label("読み上げ", systemImage: "speaker.wave.2")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(message.images.indices, id: \.self) { idx in
                    if let nsImage = NSImage(data: message.images[idx]) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .frame(height: 100)
    }

    @ViewBuilder
    private var thinkingView: some View {
        let stillThinking = message.content.isEmpty
        let preview = message.thinking
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)

        if stillThinking {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .foregroundStyle(.purple.opacity(0.7))
                    .font(.caption)
                    .symbolEffect(.pulse, options: .repeating)
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            DisclosureGroup(isExpanded: $showFullThinking) {
                Text(message.thinking)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                    Text("思考 (\(message.thinking.count) 文字)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Tool call / system context rows

struct ToolCallCard: View {
    let call: PendingToolCall

    private var statusBadge: (label: String, color: Color, icon: String) {
        switch call.status {
        case .pending:   return ("確認待ち",  .orange,  "questionmark.circle.fill")
        case .executing: return ("実行中…",  .blue,    "hourglass")
        case .succeeded: return ("実行成功", .green,   "checkmark.seal.fill")
        case .failed:    return ("失敗",     .red,     "xmark.octagon.fill")
        case .declined:  return ("拒否",     .secondary, "hand.raised.fill")
        }
    }

    var body: some View {
        let badge = statusBadge
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.adjustable.fill")
                    .foregroundStyle(.purple)
                Text(call.name)
                    .font(.caption.monospaced())
                    .bold()
                Spacer()
                Label(badge.label, systemImage: badge.icon)
                    .font(.caption2)
                    .foregroundStyle(badge.color)
            }
            Text(call.argumentsJSON)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ToolResultRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wrench.adjustable.fill")
                .foregroundStyle(.purple)
                .font(.caption)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                if let name = message.toolName {
                    Text("\(name) → 結果")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(message.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(6)
        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct SystemContextRow: View {
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(message.content)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                Text("コンテキスト挿入 (\(message.content.count) 文字)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ToolConfirmationSheet: View {
    let request: AppState.ConfirmationRequest
    let resolve: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                Text("ツール実行の確認")
                    .font(.headline)
            }
            Text("LLM が以下のツールを実行しようとしています:")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.adjustable.fill")
                    Text(request.toolName).font(.body.monospaced()).bold()
                }
                Divider()
                ForEach(request.arguments.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    HStack(alignment: .top, spacing: 8) {
                        Text(k)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)
                        Text(v)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("拒否") { resolve(false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("実行する") { resolve(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

// MARK: - Settings sheet

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "gearshape.fill").foregroundStyle(.secondary)
                Text("設定").font(.headline)
                Spacer()
            }
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $state.autoOpenMeet) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("会議開始前に Google Meet を自動で開く")
                            .font(.body)
                        Text("カレンダーに Meet URL があるイベントが対象")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if state.autoOpenMeet {
                    HStack {
                        Text("チェック間隔:")
                        Stepper(value: $state.meetCheckIntervalMinutes, in: 1...30) {
                            Text("\(state.meetCheckIntervalMinutes) 分")
                                .frame(minWidth: 60, alignment: .trailing)
                                .monospacedDigit()
                        }
                    }
                    HStack {
                        Text("何分前に開く:")
                        Stepper(value: $state.meetLeadMinutes, in: 1...30) {
                            Text("\(state.meetLeadMinutes) 分前")
                                .frame(minWidth: 60, alignment: .trailing)
                                .monospacedDigit()
                        }
                    }
                    if !state.meetMonitorStatus.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(state.meetMonitorStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        state.runMeetMonitorOnce()
                    } label: {
                        Label("今すぐチェック", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $state.autoPresenceCheck) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("カメラで在席状況を定期チェック")
                            .font(.body)
                        Text("写真は判定後すぐ破棄、結果のみ JSON に保存")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if state.autoPresenceCheck {
                    HStack {
                        Text("チェック間隔:")
                        Stepper(value: $state.presenceIntervalMinutes, in: 1...60) {
                            Text("\(state.presenceIntervalMinutes) 分")
                                .frame(minWidth: 60, alignment: .trailing)
                                .monospacedDigit()
                        }
                    }
                }

                HStack {
                    Button {
                        Task { await state.runPresenceCheckOnce() }
                    } label: {
                        if state.isCheckingPresence {
                            ProgressView().controlSize(.small)
                            Text("撮影中…").font(.caption)
                        } else {
                            Label("今すぐ撮影してテスト", systemImage: "camera")
                                .font(.caption)
                        }
                    }
                    .disabled(state.isCheckingPresence)

                    Spacer()
                    if !state.presenceHistory.isEmpty {
                        Button(role: .destructive) {
                            state.clearPresenceHistory()
                        } label: {
                            Label("履歴削除", systemImage: "trash")
                                .font(.caption)
                        }
                    }
                }

                if !state.presenceHistory.isEmpty {
                    Text("最近の判定 (最大5件)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(state.presenceHistory.suffix(5).reversed()) { entry in
                            HStack(spacing: 6) {
                                Text(entry.status.emoji)
                                Text(entry.status.label).bold()
                                Text(entry.note)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                            .font(.caption)
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Slack 連携").font(.body).bold()
                    Text("BETA")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.85), in: Capsule())
                    Spacer()
                }
                Text("Slack デスクトップアプリのローカルストレージから自分のトークン (xoxc) と d クッキーを抽出します。会社ワークスペースでの利用はセキュリティポリシーをご確認ください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Image(systemName: state.slackConnected ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(state.slackConnected ? .green : .secondary)
                    Text(state.slackConnected
                         ? "接続済み (token: …\(state.slackTokenPreview))"
                         : "未接続")
                        .font(.caption)
                    Spacer()
                }

                HStack {
                    Button {
                        state.attemptSlackExtraction()
                    } label: {
                        if state.isExtractingSlack {
                            ProgressView().controlSize(.small)
                            Text("抽出中…").font(.caption)
                        } else {
                            Label(state.slackConnected ? "再抽出" : "Slack に接続", systemImage: "link")
                                .font(.caption)
                        }
                    }
                    .disabled(state.isExtractingSlack)
                    if state.slackConnected {
                        Button {
                            state.testSlackConnection()
                        } label: {
                            Label("接続テスト", systemImage: "antenna.radiowaves.left.and.right")
                                .font(.caption)
                        }
                        Button(role: .destructive) {
                            state.disconnectSlack()
                        } label: {
                            Label("切断", systemImage: "link.badge.plus")
                                .font(.caption)
                        }
                    }
                    Spacer()
                }
                if !state.slackExtractStatus.isEmpty {
                    Text(state.slackExtractStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("閉じる") { dismissWindow(id: "settings") }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
