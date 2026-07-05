#!/usr/bin/env bash
# Builds "Claude Usage.app" (arm64, self-contained), signs it, and optionally notarizes.
# Usage:
#   ./build.sh                       # build into ./build/
#   ./build.sh --install             # build, then copy to /Applications + clear quarantine
#   ./build.sh --notarize            # build, hardened-runtime sign, notarize + staple
#   ./build.sh --notarize --install  # …and install the stapled app
#
# Signing identity is auto-detected:
#   1. Developer ID Application  → real Apple-trusted signature (required for --notarize)
#   2. ad-hoc                     → zero-setup fallback for source builds
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Claude Usage"
EXE="ClaudeUsage"
BUNDLE_ID="eu.smeingast.claude-menubar-usage"
MIN_MACOS="13.0"
NOTARY_PROFILE="${CLAUDE_USAGE_NOTARY_PROFILE:-claude-usage-notary}"

# Release version. Override per release: CLAUDE_USAGE_VERSION=0.6 ./build.sh --notarize
VERSION="${CLAUDE_USAGE_VERSION:-0.5}"
# Monotonic build number from commit count (falls back to 1 outside a git checkout).
BUILD_NUM="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"

# --- parse flags (any order) ---
DO_INSTALL=false
DO_NOTARIZE=false
for arg in "$@"; do
    case "$arg" in
        --install)  DO_INSTALL=true ;;
        --notarize) DO_NOTARIZE=true ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# --- pick a signing identity ---
# Full identity name of a Developer ID Application cert, if one is installed.
DEVID_ID="$(security find-identity -v -p codesigning \
            | awk -F'"' '/Developer ID Application/{print $2; exit}')"

if $DO_NOTARIZE && [[ -z "$DEVID_ID" ]]; then
    echo "ERROR: --notarize needs a 'Developer ID Application' certificate, but none" >&2
    echo "       is installed. See README → Install (Maintainer section)." >&2
    exit 1
fi

# --- compile ---
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$APP/Contents/Resources"

echo "==> Building $APP_NAME $VERSION (build $BUILD_NUM) — arm64, macOS $MIN_MACOS+…"
swiftc -O -wmo \
    -target "arm64-apple-macosx$MIN_MACOS" \
    -o "$MACOS_DIR/$EXE" \
    "$ROOT"/Sources/*.swift

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Stamp the version so releases are reproducible without hand-editing the plist.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon. Regenerate with ./tools/make_icon.sh; we ship the prebuilt .icns so
# a plain build needs no extra steps.
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# --- sign ---
if [[ -n "$DEVID_ID" ]]; then
    # Real Apple identity: hardened runtime + secure timestamp (both required for
    # notarization; harmless and desirable otherwise). --timestamp needs network.
    echo "==> Code signing with Developer ID (hardened runtime):"
    echo "    $DEVID_ID"
    codesign --force --options runtime --timestamp \
        --sign "$DEVID_ID" --identifier "$BUNDLE_ID" "$APP"
else
    # No Apple identity: ad-hoc sign so it runs locally. The keychain "Always Allow"
    # grant is tied to the code hash, so it re-prompts after each rebuild.
    echo "==> Ad-hoc code signing (no Developer ID cert found)…"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

echo "==> Built: $APP"

# --- notarize ---
if $DO_NOTARIZE; then
    ZIP="$BUILD/$EXE-notarize.zip"
    echo "==> Zipping for notarization…"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"

    echo "==> Submitting to Apple notary service (profile '$NOTARY_PROFILE')…"
    if ! xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait; then
        DEV_TEAM="$(echo "$DEVID_ID" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"
        echo >&2
        echo "ERROR: notarization failed. If this is the first run, store credentials once:" >&2
        echo "       ./tools/notarize_setup.sh" >&2
        echo "  (creates keychain profile '$NOTARY_PROFILE' for Team ID ${DEV_TEAM:-<your-team>})" >&2
        rm -f "$ZIP"
        exit 1
    fi
    rm -f "$ZIP"

    echo "==> Stapling ticket…"
    xcrun stapler staple "$APP"
    echo "==> Verifying…"
    xcrun stapler validate "$APP"
    # spctl is the authoritative Gatekeeper check — it MUST gate success, otherwise a
    # silently-unstapled build would still report "done" and ship broken.
    if spctl -a -vvv "$APP" 2>&1 | sed 's/^/    /'; then
        echo "==> Notarized & stapled — opens cleanly on Apple Silicon Macs."
    else
        echo "ERROR: Gatekeeper assessment failed after stapling (see spctl output)." >&2
        exit 1
    fi
fi

# --- install ---
if $DO_INSTALL; then
    DEST="/Applications/$APP_NAME.app"
    echo "==> Installing to $DEST"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
    echo "==> Installed. Launch it from /Applications (or it will start at next login)."
fi
