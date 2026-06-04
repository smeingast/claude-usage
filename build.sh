#!/usr/bin/env bash
# Builds "Claude Usage.app" (arm64, self-contained) and ad-hoc signs it.
# Usage:
#   ./build.sh            # build into ./build/
#   ./build.sh --install  # build, then copy to /Applications and clear quarantine
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Claude Usage"
EXE="ClaudeUsage"
BUNDLE_ID="eu.smeingast.claude-menubar-usage"
MIN_MACOS="13.0"

BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$APP/Contents/Resources"

echo "==> Compiling (arm64, macOS $MIN_MACOS+)…"
# shellcheck disable=SC2046
swiftc -O -wmo \
    -target "arm64-apple-macosx$MIN_MACOS" \
    -o "$MACOS_DIR/$EXE" \
    $(ls "$ROOT"/Sources/*.swift)

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon. Regenerate with ./tools/make_icon.sh; we ship the prebuilt .icns so
# a plain build needs no extra steps.
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Prefer a stable self-signed identity so the macOS "Always Allow" keychain
# permission survives rebuilds (an ad-hoc signature's identity is its code hash,
# which changes every build and re-triggers the password prompt). Detect via
# find-certificate — the cert needn't be trusted for codesign to use it, and
# find-identity would not list an untrusted self-signed cert.
SIGN_IDENTITY="${CLAUDE_USAGE_SIGN_IDENTITY:-Claude Usage Self-Signed}"
if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    echo "==> Code signing with '$SIGN_IDENTITY'…"
    codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
    echo "==> Ad-hoc code signing (run ./tools/make_signing_cert.sh once so"
    echo "    'Always Allow' persists across rebuilds)…"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

echo "==> Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/$APP_NAME.app"
    echo "==> Installing to $DEST"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
    echo "==> Installed. Launch it from /Applications (or it will start at next login)."
fi
