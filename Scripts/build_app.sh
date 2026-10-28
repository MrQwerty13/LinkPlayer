#!/usr/bin/env bash
# LinkPlayer — сборка самостоятельного LinkPlayer.app на macOS (Apple Silicon).
#
# Требования: macOS 13+, Xcode 15+ (или Command Line Tools со Swift 5.9+).
# Запуск:    ./Scripts/build_app.sh            (Debug)
#            ./Scripts/build_app.sh release    (Release, optimized)
# Результат: build/LinkPlayer.app
#
# Приложение собирается без Xcode-проекта: бинарь через swiftc по manifest API,
# затем вручную собирается стандартная структура .app (Info.plist, Resources).
# Подпись: ad-hoc (--sign -). Для распространения замените на Developer ID
# и выполните notarization (см. README.md → Signing & Notarization).

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/LinkPlayer.app"
BUNDLE_ID="com.linkplayer.app"
MIN_MACOS="13.0"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "error: сборка .app возможна только на macOS" >&2
    exit 1
fi

ARCH="$(uname -m)"   # arm64 на Apple Silicon; x86_64 тоже поддерживается этой командой
OPT="-Onone"; [[ "$CONFIG" == "release" ]] && OPT="-O"

echo "==> Компиляция бинаря ($ARCH, $CONFIG)…"
mkdir -p "$ROOT/build/tmp"
xcrun swiftc \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -target "${ARCH}-apple-macosx${MIN_MACOS}" \
    -parse-as-library $OPT \
    -module-name LinkPlayer \
    -o "$ROOT/build/tmp/LinkPlayer" \
    "$ROOT"/Sources/LinkPlayerCore/**/*.swift \
    "$ROOT"/macOS/Sources/LinkPlayerApp/*.swift \
    "$ROOT"/macOS/Sources/LinkPlayerApp/Features/*.swift

echo "==> Сборка ${APP##*/}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$ROOT/build/tmp/LinkPlayer" "$APP/Contents/MacOS/LinkPlayer"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LinkPlayer</string>
    <key>CFBundleDisplayName</key><string>LinkPlayer</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>LinkPlayer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

# Иконка: если есть AppIcon.icns в macOS/Support — кладём в Resources.
if [[ -f "$ROOT/macOS/Support/AppIcon.icns" ]]; then
    cp "$ROOT/macOS/Support/AppIcon.icns" "$APP/Contents/Resources/"
fi

echo "==> Ad-hoc подпись…"
codesign --force --deep --sign - "$APP"

rm -rf "$ROOT/build/tmp"
echo "Готово: $APP"
echo "Запуск:  open \"$APP\"   либо   \"$APP/Contents/MacOS/LinkPlayer\""
