#!/bin/bash
# Build Splitvox and package it as a proper .app bundle.
# A real bundle keeps TCC permission stable across rebuilds: macOS binds
# microphone and audio-recording consent to the bundle id plus the code
# signature, not to the raw binary path.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Building (release)…"
swift build -c release

BIN=".build/release/Splitvox"
APP="Splitvox.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"
cp "$BIN" "$MACOS/Splitvox"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Splitvox</string>
    <key>CFBundleDisplayName</key><string>Splitvox</string>
    <key>CFBundleIdentifier</key><string>com.ryo.splitvox</string>
    <key>CFBundleExecutable</key><string>Splitvox</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>会議中のあなたの発言を録音し、端末内で文字起こしするために使用します。音声が外部に送信されることはありません。</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>録音した会議音声を端末内で文字起こしするために使用します。音声が外部に送信されることはありません。</string>
    <!--
      Required for the Core Audio process tap. Without this key macOS never
      prompts, and AudioHardwareCreateProcessTap still succeeds — it just
      delivers digital silence forever. Verified against Zoom and Krisp, which
      both ship this key to capture other applications' audio.
    -->
    <key>NSAudioCaptureUsageDescription</key><string>会議相手の音声を録音し、端末内で文字起こしするために使用します。音声が外部に送信されることはありません。</string>
</dict>
</plist>
PLIST

# --- Code signing -----------------------------------------------------------
# Sign with a STABLE self-signed identity so the Designated Requirement is tied
# to the certificate rather than the per-build cdhash. Without this, macOS
# forgets microphone consent on every rebuild.
#
# A self-signed certificate is untrusted (CSSMERR_TP_NOT_TRUSTED) so it never
# appears under "valid identities only", but codesign can still sign with it —
# hence no -v on find-identity.
PRIMARY_IDENTITY="${SPLITVOX_SIGN_IDENTITY:-splitvox Self-Signed}"
# Reuse of a certificate created for another local project. TCC keys on bundle
# id plus signature, so sharing one certificate keeps permissions independent.
# The trailing space in this name is intentional — it is part of the CN.
FALLBACK_IDENTITY="NaniMini Self-Signed "

AVAILABLE="$(security find-identity -p codesigning 2>/dev/null || true)"

if printf '%s' "$AVAILABLE" | grep -qF "$PRIMARY_IDENTITY"; then
    SIGN_IDENTITY="$PRIMARY_IDENTITY"
elif printf '%s' "$AVAILABLE" | grep -qF "$FALLBACK_IDENTITY"; then
    SIGN_IDENTITY="$FALLBACK_IDENTITY"
else
    SIGN_IDENTITY=""
fi

if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> Signing with stable identity: '$SIGN_IDENTITY'"
    codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
    echo "!! No stable code-signing identity found — using AD-HOC."
    echo "   (Microphone permission will reset on every rebuild.)"
    echo "   One-time fix: Keychain Access → Certificate Assistant → Create a Certificate"
    echo "     Name='$PRIMARY_IDENTITY', Identity Type='Self Signed Root', Type='Code Signing'."
    echo "   Or point SPLITVOX_SIGN_IDENTITY at an identity you already have."
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "==> Built $APP"
echo "    Run with:  open $APP"
