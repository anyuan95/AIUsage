#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/glm-quota-regression.XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

swiftc -parse-as-library \
  "$ROOT_DIR/scripts/GLMCodingPlanQuotaStubs.swift" \
  "$ROOT_DIR/QuotaBackend/Sources/QuotaBackend/Providers/GLMProvider.swift" \
  "$ROOT_DIR/scripts/GLMCodingPlanQuotaRegression.swift" \
  -o "$WORK_DIR/glm-quota-regression"

"$WORK_DIR/glm-quota-regression"
