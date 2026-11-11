#!/bin/bash
# Produce the shipping artifacts for a SidestMac release (#64):
#   universal signed app  →  update archive  →  Sparkle appcast.xml
#
# Usage:
#   ./make-release.sh 0.2.0            # build number defaults to the short version
#   ./make-release.sh 0.2.0 17         # explicit CFBundleVersion
#
# Environment pass-through (see build.sh for the full list):
#   SIDEMAC_SIGN_IDENTITY       e.g. "Developer ID Application: Foo (TEAMID)"
#   SIDEMAC_NOTARIZE_PROFILE    notarytool keychain profile; set it to also notarize+staple
#   SPARKLE_FEED_URL            override SUFeedURL in the built bundle
#   SPARKLE_DOWNLOAD_PREFIX      URL prefix written into appcast enclosure URLs
#   SPARKLE_KEY_ACCOUNT          keychain account holding the Ed25519 private key
#   SPARKLE_PRIVATE_KEY_FILE     exported private key file (skips the keychain prompt)
#
# Release notes: drop a SidestMac-<version>.md/.html/.txt next to the archive
# before the appcast step (this script leaves the directory open for that) and
# Sparkle picks it up automatically.
#
# Output layout:
#   dist/SidestMac.app                 the local runnable bundle
#   dist/updates/SidestMac-<v>-<b>.zip what Sparkle downloads
#   dist/updates/appcast.xml           what your SUFeedURL points at
# Upload dist/updates/ (minus old_updates/) to the CDN path SUFeedURL implies.
set -euo pipefail

cd "$(dirname "$0")"

SHORT_VERSION="${1:-}"
BUILD_VERSION="${2:-$SHORT_VERSION}"
APP_NAME="SidestMac"
UPDATES_DIR="dist/updates"
FEED_PREFIX="${SPARKLE_DOWNLOAD_PREFIX:-https://cdn.bigjing.com/updates/sidestmac/}"
KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-ed25519}"

if [ -z "$SHORT_VERSION" ]; then
    echo "usage: $0 <short-version> [build-version]"
    exit 1
fi

BIN_DIR=$(ls -d .build/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1 || true)
if [ -z "$BIN_DIR" ]; then
    echo "ERROR: Sparkle tools not found. Run 'swift build' first."
    exit 1
fi
if [ ! -f .sparkle-public-key ]; then
    echo "ERROR: .sparkle-public-key missing — run ./sparkle-setup.sh first."
    echo "       Without SUPublicEDKey the built app can verify no update at all."
    exit 1
fi

echo "==> Building $APP_NAME $SHORT_VERSION ($BUILD_VERSION)..."
SIDEMAC_VERSION="$SHORT_VERSION" SIDEMAC_BUILD="$BUILD_VERSION" ./build.sh release

ARCHIVE="$UPDATES_DIR/$APP_NAME-$SHORT_VERSION-$BUILD_VERSION.zip"
mkdir -p "$UPDATES_DIR"
rm -f "$ARCHIVE"

echo "==> Zipping update archive -> $ARCHIVE"
# -c -k --keepParent keeps the .app at the root of the zip with its symlinks and
# extended attributes intact; plain `zip -r` breaks both the signature and the
# framework's Versions/Current symlink farm.
ditto -c -k --keepParent "dist/$APP_NAME.app" "$ARCHIVE"

echo "==> Signing archives and generating appcast..."
# The private Ed25519 key normally lives in the login keychain, and the first
# run of generate_appcast after sparkle-setup pops a keychain dialog that has to
# be clicked ("Always Allow"). For unattended/CI runs, export the key once with
# `generate_keys -x <file>` (see sparkle-setup.sh) and point SPARKLE_PRIVATE_KEY_FILE at it.
# (Split in two calls rather than an optional flag array: bash 3.2 chokes on
# expanding an empty array under `set -u`.)
if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
    "$BIN_DIR/generate_appcast" --account "$KEY_ACCOUNT" \
        --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
        --download-url-prefix "$FEED_PREFIX" "$UPDATES_DIR"
else
    "$BIN_DIR/generate_appcast" --account "$KEY_ACCOUNT" \
        --download-url-prefix "$FEED_PREFIX" "$UPDATES_DIR"
fi

echo "==> Done."
echo "    $( [ -f "$UPDATES_DIR/appcast.xml" ] && echo "appcast:  $UPDATES_DIR/appcast.xml" )"
echo "    archive:  $ARCHIVE"
echo "    Upload both to ${FEED_PREFIX} (Sparkle moves superseded archives into"
echo "    $UPDATES_DIR/old_updates/ itself — those do not need re-uploading)."
