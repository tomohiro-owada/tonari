# Tonari (隣)

> 隣にいるローカル AI アシスタント — macOS メニューバーから Ollama を呼ぶ常駐アプリ

Tonari は menubar に常駐する Mac ネイティブ (SwiftUI) の Ollama クライアントです。
あなたのカレンダーやメールをローカルで読み取り、LLM に「補佐」させます。
データはマシンの外には出ません。

## 主な機能

- **メニューバー常駐** (`MenuBarExtra`) — Dock を汚さない
- **マルチモデル切替** — `/api/tags` から自動取得してドロップダウン
- **ストリーミングチャット** — `/api/chat` 経由、思考トークンも別表示
- **画像入力** (vision モデル使用時) — 📎 / ⌘V / ドラッグドロップ
- **読み上げ (TTS)** — `say` コマンド経由で日本語音声 (Kyoko)
- **思考モード切替** — qwen3 の `/no_think` ソフトスイッチで CoT 制御
- **今日のブリーフィング** — カレンダー (EventKit) + 未読メール (Mail.app) を LLM に渡して要約
- **リマインダー追加 (tool calling)** — 自然言語から LLM がリマインダーを提案 → 確認ダイアログ → EventKit で作成

## 必要環境

- macOS 14 (Sonoma) 以上 (動作確認は macOS 26 Tahoe)
- Swift 6 (Xcode コマンドラインツール `xcode-select --install` で入る)
- [Ollama](https://ollama.com) — `brew install ollama && brew services start ollama`
- 任意のモデル:
  - テキストのみ: `qwen3:30b-a3b` 等
  - 画像入力: `gemma4:26b` 等の vision capability 持ち (`ollama show <model>` で確認)
  - **MLX バリアントは vision 非対応** (画像は無視される) — 注意

## ビルド & 起動

```sh
./build.sh                  # build/Tonari.app が生成される
open build/Tonari.app       # 起動 (メニューバーに 💬 が出る)
```

`/Applications` にコピーすればログイン項目にもできます。

## 権限

初回操作で macOS の許諾ダイアログが出ます (アプリは ad-hoc 署名なので「許可するか?」のシステム標準プロンプト):

| 機能 | 権限 |
|---|---|
| 今日のブリーフィング (カレンダー) | カレンダーへのフルアクセス |
| リマインダー追加 | リマインダーへのフルアクセス |
| 未読メール要約 | Mail.app のオートメーション制御 (Apple Events) |

権限を後から変えるには: **システム設定 > プライバシーとセキュリティ** で対象項目を編集。

## アーキテクチャ

```
Sources/Tonari/
├─ TonariApp.swift          @main, MenuBarExtra シーン定義
├─ AppState.swift           @MainActor — チャット状態 / tool dispatch /
│                            CheckedContinuation で確認ダイアログを待機
├─ ChatView.swift           SwiftUI UI: ヘッダ / アクションバー /
│                            MessageRow / ToolCallCard / ConfirmationSheet
├─ OllamaClient.swift       /api/chat ストリーミング・tool_calls 抽出
├─ EventKitService.swift    Calendar 読み取り + Reminders 読み書き
├─ MailService.swift        Mail.app を NSAppleScript で操作
└─ Speaker.swift            Process(/usr/bin/say) で TTS
```

### 設計判断

- **読み取りはアプリ側 fetch + context 注入**、書き込みは LLM tool calling — 読み取りは決定的にしておきたく、書き込みは自然言語で柔軟に呼べた方が便利
- **書き込み tool は必ず確認 UI** — `AppState.pendingConfirmation` に立てて `withCheckedContinuation` で UI 操作を待つ
- **system role メッセージで context を持ち回る** — ブリーフィング起動時に折りたたみカードで挿入され、後続の質問にも引き継がれる
- **qwen3 / Ollama の `think: false` バグ回避** — 公式の `/no_think` ソフトスイッチを user メッセージ末尾に注入 (Ollama 0.24 + qwen3 でテキスト崩れを防止)
- **AVSpeechSynthesizer は LSUIElement と相性悪い** — `Process` で `say` コマンドを叩く方式に切替済み

## 拡張ポイント

- **新しい読み取りソース** → `ChatView.actionBar` にボタン追加 + `AppState.run<X>()` で fetch → `ChatMessage(role: "system", ...)` 注入
- **新しい書き込みアクション** → `AppState.tools` に `OllamaTool` 追加 + `executeTool` に case 追加。確認 UI は自動で動く
- **グローバルホットキー** → `HotKey` パッケージ追加で 10 行程度
- **複数 LLM プロバイダ** → `OllamaClient` を `LLMClient` プロトコルに抽象化

## ライセンス

MIT — `LICENSE` 参照。

## 謝辞

- [Ollama](https://ollama.com) — 全部これのおかげ
- [Apple Developer Documentation](https://developer.apple.com/documentation/) — EventKit / AVFoundation / SwiftUI
