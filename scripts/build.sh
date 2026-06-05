#!/usr/bin/env bash
# Build and ad-hoc-sign the voice-listener binary.
# Ad-hoc signing is REQUIRED on macOS 26 — without it, TCC silently delivers
# zero-valued audio buffers to the binary even after the user grants Mic
# permission. The buffer-callback fires, but every sample is 0.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$REPO_DIR/bin"
cd "$BIN_DIR"

swiftc voice-listener.swift -o voice-listener \
    -framework Speech -framework AVFoundation -framework Foundation

# Strip any iCloud / quarantine xattrs that interfere with signing
xattr -cr voice-listener

# Ad-hoc sign so TCC delivers real audio data.
codesign --force --sign - voice-listener

echo "build: voice-listener compiled and signed"
