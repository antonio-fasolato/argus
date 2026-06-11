#!/bin/bash
# ArgusAI unit tests — compiles the pure-logic sources + Tests/main.swift with swiftc
# (same philosophy as build.sh: no SPM, no Xcode project, no XCTest).
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Compiling tests..."
swiftc \
    Sources/ClaudeMetrics/Models.swift \
    Sources/ClaudeMetrics/Theme.swift \
    Tests/main.swift \
    -o "$TMP/argusai-tests"

echo "Running tests..."
"$TMP/argusai-tests"
