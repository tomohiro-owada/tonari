# Tonari (隣)

> 隣にいるローカル AI アシスタント — macOS メニューバーから Ollama を呼ぶ常駐アプリ

<img width="256" height="256" alt="tonari" src="https://github.com/user-attachments/assets/11e914b3-675f-4da1-8584-a4d010b70043" />


Tonari は menubar に常駐する Mac ネイティブ (SwiftUI) の Ollama クライアントです。
カレンダー・メール・Slack・カメラから取得した情報をローカル LLM に渡して、
あなたを「補佐」させます。データはマシンの外には出ません。

## 主な機能

### コア
- **メニューバー常駐** (`MenuBarExtra`) — Dock を汚さない
- **マルチモデル切替** — `/api/tags` から自動取得してドロップダウン (デフォルト `gemma4:26b`)
- **ストリーミングチャット** — `/api/chat` 経由、思考トークンも別表示
- **画像入力** (vision モデル使用時) — 📎 / ⌘V / ドラッグドロップ
- **読み上げ (TTS)** — `say` コマンド経由で日本語音声 (Kyoko)
- **思考モード切替** — qwen3 の `/no_think` ソフトスイッチで CoT 制御
- **Markdown 抑制システムプロンプト** — SwiftUI Text と TTS に優しいプレーンテキスト出力

### ブリーフィング (アプリ側 fetch + context 注入)
- **今日のブリーフィング** — カレンダー (EventKit) + 未読メール (Mail.app) を LLM に渡して要約
- **未読メール要約** — Mail.app から未読 N 件を抽出して要約
- **Slack 未読要約** (beta) — DM・メンション・チャンネル本文を抽出して優先度付き要約
- **Slack 未読リプライ** (beta) — 購読中スレッドの新着リプライのみ要約

### 自動化 (バックグラウンド)
- **Meet 自動オープン** — N 分間隔でカレンダーをスキャンし、次の予定の `meet.google.com/...` を開始 M 分前にブラウザで自動オープン
- **「次の Meet」ボタン** — 直近の Meet URL 付き予定を即座に開く手動トリガー
- **在席状況の定期チェック** — `AVCaptureSession` で 1 フレーム撮影 → vision LLM が `present / away / eating / on_phone / talking / other` を判定。写真は即破棄、結果のみ JSON ログ (`~/Library/Application Support/Tonari/presence-log.json`)

### 書き込み (LLM tool calling + 確認 UI)
- **リマインダー追加** — 自然言語から LLM が `add_reminder()` を提案 → 確認ダイアログ → EventKit で作成

## 必要環境

- macOS 14 (Sonoma) 以上 (動作確認は macOS 26 Tahoe)
- Swift 6 (Xcode コマンドラインツール `xcode-select --install` で入る)
- [Ollama](https://ollama.com) — `brew install ollama && brew services start ollama`
- 任意のモデル:
  - 推奨: `gemma4:26b` (vision + tool calling 対応)
  - テキストのみ: `qwen3:30b-a3b` 等
  - **MLX バリアントは vision 非対応** (画像は無視される) — `ollama show <model>` の Capabilities で確認

## ビルド & 起動

```sh
./build.sh                  # build/Tonari.app が生成される
open build/Tonari.app       # 起動 (メニューバーに 👥 アイコンが出る)
```

`/Applications` にコピーすればログイン項目にもできます。アイコンを差し替えたい場合:

```sh
./make-icon.sh /path/to/1024x1024.png   # Resources/AppIcon.icns を再生成
```

## 権限

初回操作で macOS の許諾ダイアログが出ます (アプリは ad-hoc 署名なので「許可するか?」のシステム標準プロンプト):

| 機能 | 権限 |
|---|---|
| 今日のブリーフィング / Meet 自動オープン | カレンダーへのフルアクセス |
| リマインダー追加 | リマインダーへのフルアクセス |
| 未読メール要約 | Mail.app のオートメーション制御 (Apple Events) |
| 在席状況チェック | カメラへのアクセス |
| Slack 連携 (beta) | キーチェイン項目「Slack Safe Storage」へのアクセス |

権限を後から変えるには: **システム設定 > プライバシーとセキュリティ** で対象項目を編集。

## 設定

メニューバーポップアップ右上の ⚙️ から設定ウィンドウを開きます (独立ウィンドウなので popover の dismiss に巻き込まれません)。

- Meet 自動オープン: チェック間隔 (1–30 分)、何分前に開く (1–30 分)、「今すぐチェック」
- 在席チェック: チェック間隔 (1–60 分)、「今すぐ撮影してテスト」、履歴削除、最近 5 件のログ表示
- Slack 連携 (BETA): 接続 (xoxc 抽出)、再抽出、接続テスト (`auth.test` で workspace / user 確認)、切断

## アーキテクチャ

```
Sources/Tonari/
├─ TonariApp.swift                 @main: MenuBarExtra + 設定 Window シーン
├─ AppState.swift                  @MainActor — チャット状態 / 各モニター /
│                                   tool dispatch (CheckedContinuation で UI 確認待機)
├─ ChatView.swift                  SwiftUI UI 全部: ヘッダ / アクションバー /
│                                   MessageRow / ToolCallCard / ConfirmationSheet /
│                                   SettingsView / PasteCatcher
├─ OllamaClient.swift              /api/chat ストリーミング + tool_calls 抽出 +
│                                   oneShot (非ストリーミング、プレゼンス判定用)
├─ EventKitService.swift           Calendar 読み取り + Reminders 読み書き
├─ MailService.swift               Mail.app を NSAppleScript で操作
├─ CameraService.swift             AVCaptureSession で 1 フレーム JPEG キャプチャ
├─ PresenceLog.swift               PresenceStatus enum + PresenceLogEntry + JSON store
├─ SlackCredentialExtractor.swift  LevelDB から xoxc トークン抽出 +
│                                   Cookies SQLite から d クッキーを
│                                   PBKDF2-SHA1 → AES-128-CBC で復号
├─ SlackKeychain.swift             抽出済み token + cookie を app.tonari Keychain に保管
├─ SlackService.swift              client.counts / conversations.history /
│                                   users.info / subscriptions.thread.getView 等
└─ Speaker.swift                   Process(/usr/bin/say) で TTS
```

### 設計判断

- **読み取りはアプリ側 fetch + context 注入**、書き込みは LLM tool calling — 読み取りは決定的にしておきたく、書き込みは自然言語で柔軟に呼べた方が便利
- **書き込み tool は必ず確認 UI** — `AppState.pendingConfirmation` に立てて `withCheckedContinuation` で UI 操作を待つ
- **system role メッセージで context を持ち回る** — ブリーフィング起動時に折りたたみカードで挿入され、後続の質問にも引き継がれる
- **設定は独立 `Window` シーン** — `MenuBarExtra` の popover 内に `.sheet` を出すと外部クリックで巻き込まれて消えるため、別ウィンドウに切り出し
- **qwen3 / Ollama の `think: false` バグ回避** — 公式の `/no_think` ソフトスイッチを user メッセージ末尾に注入 (Ollama 0.24 + qwen3 でテキスト崩れを防止)
- **MLX バリアントは vision 非対応** — `gemma4:26b-mlx` 等は画像を無視して幻覚応答する。`ollama show` の Capabilities で必ず確認
- **AVSpeechSynthesizer は LSUIElement と相性悪い** — `Process` で `say` コマンドを叩く方式に切替済み
- **Slack 連携は xoxc 抽出方式 (beta)** — LevelDB から token、Cookies から `d` を Chromium 標準フォーマット (PBKDF2-SHA1 1003 iter + AES-128-CBC, IV=空白16) で復号。会社ワークスペースで使う場合は所属ポリシーを確認
- **プレゼンス画像は判定後即破棄** — JSON には `status / note / model / rawResponse` のみ。photo は AVCaptureSession のメモリ内のみで完結

## 拡張ポイント

- **新しい読み取りソース** → `ChatView.actionBar` にボタン追加 + `AppState.run<X>()` で fetch → `ChatMessage(role: "system", ...)` 注入
- **新しい書き込みアクション** → `AppState.tools` に `OllamaTool` 追加 + `executeTool` に case 追加。確認 UI は自動で動く
- **新しい自動化モニター** → `AppState` に Timer 持って間隔ループ、UserDefaults に設定永続化 (`autoOpenMeet` / `autoPresenceCheck` を参考に)
- **グローバルホットキー** → `HotKey` パッケージ追加で 10 行程度
- **複数 LLM プロバイダ** → `OllamaClient` を `LLMClient` プロトコルに抽象化

## ライセンス

MIT — `LICENSE` 参照。

## 謝辞

- [Ollama](https://ollama.com) — 全部これのおかげ
- [Apple Developer Documentation](https://developer.apple.com/documentation/) — EventKit / AVFoundation / Security / SwiftUI
- Chromium クッキー復号方式リファレンス — Chromium / Electron コミュニティのオープンソースツール群
