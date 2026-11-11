#!/bin/bash
# One-time Sparkle signing-key setup (#64).
#
# Creates (or imports) the Ed25519 keypair Sparkle uses to sign update archives
# and writes ONLY the public half to .sparkle-public-key, which build.sh injects
# into the bundle's Info.plist as SUPublicEDKey. The private half never touches
# this repo: Sparkle keeps it in the login keychain under the account "ed25519".
#
# Consequences to know before running:
#  - Losing the private key means every existing install refuses future updates:
#    back it up with the shipped tool —
#      .build/artifacts/sparkle/Sparkle/bin/generate_keys -x <offline-backup-file>
#    and restore on another machine with the same tool's -f option.
#  - Rotating the key is a breaking change: apps already shipped with the old
#    SUPublicEDKey will reject new signed archives.
#
# The public key is printed to a file on purpose (never to stdout) so it can be
# copy-pasted into a release runbook without leaking into logs.
set -euo pipefail

cd "$(dirname "$0")"

PUB_KEY_FILE=".sparkle-public-key"

BIN_DIR=$(ls -d .build/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1 || true)
if [ -z "$BIN_DIR" ]; then
    echo "ERROR: Sparkle tools not found. Run 'swift build' first (SPM downloads the artifact)."
    exit 1
fi

# No-arg run: generates the keypair if absent, otherwise reuses the existing
# keychain item. Its stdout is the copy-paste-into-Info.plist instruction block,
# which we deliberately discard.
if [ ! -f "$PUB_KEY_FILE" ]; then
    echo "==> Generating / importing Ed25519 keypair (keychain may prompt for access)..."
    "$BIN_DIR/generate_keys" > /dev/null
fi

echo "==> Reading public key..."
"$BIN_DIR/generate_keys" -p | tail -1 > "$PUB_KEY_FILE"

if [ ! -s "$PUB_KEY_FILE" ]; then
    echo "ERROR: $PUB_KEY_FILE is empty — keychain access was probably denied. Re-run and allow."
    rm -f "$PUB_KEY_FILE"
    exit 1
fi

echo "==> Wrote public key to $PUB_KEY_FILE (private key stays in the login keychain)."
echo "    Rebuild with ./build.sh release to bake SUPublicEDKey into the bundle."
