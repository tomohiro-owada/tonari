#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Tonari"
BUNDLE_ID="app.tonari"
APP_DIR="build/${APP_NAME}.app"

echo "==> Building (release)..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "Binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling ${APP_DIR}..."
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "$BIN_PATH" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
    ICON_KEY=$'    <key>CFBundleIconFile</key>\n    <string>AppIcon</string>'
else
    ICON_KEY=""
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
${ICON_KEY}
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>今日の予定を LLM が補佐するために参照します。読み取り専用です。</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>リマインダー一覧を参照し、LLM 経由で新規追加します (追加時は必ず確認画面が出ます)。</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Mail.app から未読・最近のメールを読み出して LLM の補佐コンテキストにします。</string>
    <key>NSCameraUsageDescription</key>
    <string>定期的にカメラで写真を撮り、LLM に在席状況を判定させます。写真は判定後に破棄され、判定結果のみがローカルの JSON ログに保存されます。</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing..."
codesign --force --deep --sign - "$APP_DIR"

echo ""
echo "Done: $(pwd)/${APP_DIR}"
echo ""
echo "Run with:    open ${APP_DIR}"
echo "Install:     cp -R ${APP_DIR} /Applications/"
