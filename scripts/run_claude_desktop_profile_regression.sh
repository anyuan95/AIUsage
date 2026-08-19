#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-desktop-profile-regression.XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

swiftc -parse-as-library \
  "$ROOT_DIR/AIUsage/Services/ClaudeDesktopProfileStore.swift" \
  "$ROOT_DIR/scripts/ClaudeDesktopProfileTransactionRegression.swift" \
  -o "$WORK_DIR/claude-desktop-profile-regression"

"$WORK_DIR/claude-desktop-profile-regression"
