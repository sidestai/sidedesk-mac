#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="SidestMac"
BUNDLE_ID="ai.sidest.sidedesk"
APP_DIR="dist/$APP_NAME.app"
ENTITLEMENTS="Resources/SidestMac.entitlements"
PLIST_BUDDY=/usr/libexec/PlistBuddy
SPARKLE_PUBLIC_KEY_FILE=".sparkle-public-key"

# Stable self-signed identity (see setup-signing.sh). Keeps the Accessibility
# grant valid across rebuilds, unlike ad-hoc signing.
# Override for shipping builds: SIDEMAC_SIGN_IDENTITY="Developer ID Application: …".
SIGN_IDENTITY="${SIDEMAC_SIGN_IDENTITY:-SidestMac Dev}"
SIGN_KEYCHAIN="sidest-signing.keychain"
SIGN_KEYCHAIN_PASS="sidest-signing"

# Universal (arm64 + x86_64) is the shipping artifact; debug builds stay native
# to keep the loop short. Override with SIDEMAC_ARCH="arm64" to slim a release.
if [ "$CONFIG" = "release" ]; then
    ARCHS="${SIDEMAC_ARCH:-arm64 x86_64}"
else
    ARCHS="$(uname -m)"
fi

# Secure timestamps + notarization only make sense for a real developer
# certificate; without SIDEMAC_NOTARIZE_PROFILE we build a local-only bundle.
NEED_TIMESTAMP=""
NOTARY_PROFILE="${SIDEMAC_NOTARIZE_PROFILE:-}"
[ -n "$NOTARY_PROFILE" ] && NEED_TIMESTAMP=1

echo "==> Building ($CONFIG, arch: $ARCHS)..."
# shellcheck disable=SC2086  # arch list is intentionally word-split into flags
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"

# Where the product actually landed. A multi-arch build goes through XCBuild and
# writes .build/apple/Products/<Config>/, while a single-arch build writes
# .build/<triple>/<config>/ — hardcoding ".build/$CONFIG" silently ships the
# previous build instead. Ask SwiftPM instead of guessing.
BUILD_DIR=$(swift build --show-bin-path -c "$CONFIG" "${ARCH_FLAGS[@]}")
echo "    Product dir: $BUILD_DIR"

echo "==> Assembling app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# SPM resource bundles (langs / themes / data-templates). Bundle.module looks
# here first and otherwise falls back to the absolute .build path baked in at
# compile time, which breaks the moment .build is cleaned or the app is moved.
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done

# ---------------------------------------------------------------------------
# Sparkle.framework (auto-update, #63/#64).
#
# The executable links @rpath/Sparkle.framework/Versions/B/Sparkle; Package.swift
# adds -rpath @executable_path/../Frameworks so the copy below is what actually
# gets loaded. Without it the app dies at dyld launch, so a missing framework is
# a hard error rather than a warning.
# ---------------------------------------------------------------------------
echo "==> Embedding Sparkle..."
SPARKLE_SRC=$(ls -d .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework 2>/dev/null | head -1 || true)
if [ -z "$SPARKLE_SRC" ]; then
    echo "    ERROR: Sparkle.xcframework not found under .build/artifacts."
    echo "           Run 'swift package resolve' (needs network) and rebuild."
    exit 1
fi
# ditto, not cp: the framework is a symlink farm (Versions/Current, top-level
# aliases) and ditto preserves the symlinks + xattrs.
mkdir -p "$APP_DIR/Contents/Frameworks"
ditto "$SPARKLE_SRC" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
SPARKLE_ARCHS=$(lipo -archs "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle")
for a in $ARCHS; do
    case " $SPARKLE_ARCHS " in
        *" $a "*) ;;
        *) echo "    ERROR: Sparkle slice for $a missing (has: $SPARKLE_ARCHS)"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Info.plist overrides (release-time values; the checked-in plist is the floor).
# ---------------------------------------------------------------------------
apply_version="${SIDEMAC_VERSION:-}"
apply_build="${SIDEMAC_BUILD:-}"
if [ -n "$apply_version" ]; then
    echo "==> Setting version $apply_version (build ${apply_build:-unchanged})..."
    $PLIST_BUDDY -c "Set :CFBundleShortVersionString $apply_version" "$APP_DIR/Contents/Info.plist"
fi
[ -n "$apply_build" ] && $PLIST_BUDDY -c "Set :CFBundleVersion $apply_build" "$APP_DIR/Contents/Info.plist"
if [ -n "${SPARKLE_FEED_URL:-}" ]; then
    echo "==> Overriding SUFeedURL -> $SPARKLE_FEED_URL"
    $PLIST_BUDDY -c "Set :SUFeedURL $SPARKLE_FEED_URL" "$APP_DIR/Contents/Info.plist"
fi
# EdDSA public key: build.sh writes it into the bundle, never into the repo's
# plist, because the matching private key lives only on the signing machine.
if [ -f "$SPARKLE_PUBLIC_KEY_FILE" ]; then
    PUB_KEY=$(tr -d '[:space:]' < "$SPARKLE_PUBLIC_KEY_FILE")
    echo "==> Injecting SUPublicEDKey from $SPARKLE_PUBLIC_KEY_FILE"
    $PLIST_BUDDY -c "Add :SUPublicEDKey string $PUB_KEY" "$APP_DIR/Contents/Info.plist" 2>/dev/null \
        || $PLIST_BUDDY -c "Set :SUPublicEDKey $PUB_KEY" "$APP_DIR/Contents/Info.plist"
else
    echo "    WARNING: $SPARKLE_PUBLIC_KEY_FILE missing — Sparkle will refuse every update."
    echo "             Run ./sparkle-setup.sh once, then rebuild."
fi

echo "==> Code signing..."
# Make sure the signing keychain is unlocked (it can lock after a reboot).
security unlock-keychain -p "$SIGN_KEYCHAIN_PASS" "$SIGN_KEYCHAIN" 2>/dev/null || true

if security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_IDENTITY" \
   || security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    SIGNING_ID="$SIGN_IDENTITY"
    echo "    Signing with '$SIGNING_ID'."
else
    echo "    WARNING: '$SIGN_IDENTITY' not found; falling back to ad-hoc signing."
    echo "             Run ./setup-signing.sh to create it. Accessibility permission"
    echo "             will need re-granting after every rebuild with ad-hoc signing."
    SIGNING_ID="-"
fi

# Nested code must be signed inside-out, and the hardened runtime flag has to be
# on every target or a notarized outer app gets rejected.
sign_nested() {
    local args=(--force --options runtime --preserve-metadata=entitlements --sign "$SIGNING_ID")
    [ -n "$NEED_TIMESTAMP" ] && args+=(--timestamp)
    codesign "${args[@]}" "$1"
}

SPARKLE_DST="$APP_DIR/Contents/Frameworks/Sparkle.framework"
sign_nested "$SPARKLE_DST/Versions/B/XPCServices/Downloader.xpc"
sign_nested "$SPARKLE_DST/Versions/B/XPCServices/Installer.xpc"
sign_nested "$SPARKLE_DST/Versions/B/Updater.app"
sign_nested "$SPARKLE_DST/Versions/B/Autoupdate"
sign_nested "$SPARKLE_DST"

APP_SIGN_ARGS=(--force --options runtime --identifier "$BUNDLE_ID" --entitlements "$ENTITLEMENTS" --sign "$SIGNING_ID")
[ -n "$NEED_TIMESTAMP" ] && APP_SIGN_ARGS+=(--timestamp)
if [ "$SIGNING_ID" = "-" ]; then
    # Ad-hoc + hardened runtime is a strange combo locally; drop the runtime flag
    # so the dev bundle still launches without a Developer ID chain.
    APP_SIGN_ARGS=(--force --identifier "$BUNDLE_ID" --sign "-")
fi
codesign "${APP_SIGN_ARGS[@]}" "$APP_DIR"

echo "==> Verifying signature..."
codesign --verify --strict --verbose=2 "$APP_DIR" 2>&1 | tail -3
echo "    Gatekeeper: $(spctl -a -vv "$APP_DIR" 2>&1 | tail -1 || true)"

# ---------------------------------------------------------------------------
# Optional notarization (only reachable with a Developer ID chain).
# ---------------------------------------------------------------------------
if [ -n "$NOTARY_PROFILE" ]; then
    TMP_ZIP="dist/.notarize-tmp.zip"
    echo "==> Notarizing via keychain profile '$NOTARY_PROFILE'..."
    ditto -c -k --keepParent "$APP_DIR" "$TMP_ZIP"
    xcrun notarytool submit "$TMP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    rm -f "$TMP_ZIP"
    echo "    Notarized and stapled."
fi

echo "==> Done: $APP_DIR"
echo "    Run with:  open \"$APP_DIR\""
