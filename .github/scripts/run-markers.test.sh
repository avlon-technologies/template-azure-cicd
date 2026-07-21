#!/usr/bin/env bash
# Tests for marker_value — the marker-name parsing the promotion paths use
# to resolve build labels and image digests from a verified run.
set -euo pipefail
cd "$(dirname "$0")"

source ./run-markers.sh

PASS=0
FAIL=0
check() { # <description> <actual> <expected>
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $1 (got '$2', want '$3')"
    FAIL=$((FAIL + 1))
  fi
}

NAMES="webapp-abc123
webapp-abc123.label.1.22.0-build.187
webapp-abc123.image.9f2a77c0ffee
test-results"

V=$(marker_value "$NAMES" "webapp-abc123.label.") || V="<none>"
check "label marker resolves (value keeps its dots)" "$V" "1.22.0-build.187"

V=$(marker_value "$NAMES" "webapp-abc123.image.") || V="<none>"
check "digest marker resolves" "$V" "9f2a77c0ffee"

V=$(marker_value "$NAMES" "webapp-abc123.sbom.") || V="<none>"
check "missing marker returns failure" "$V" "<none>"

V=$(marker_value "" "webapp-abc123.label.") || V="<none>"
check "empty artifact list returns failure" "$V" "<none>"

# A marker whose name is exactly the prefix (empty value) is absent, not
# an empty string — callers branch on emptiness.
V=$(marker_value "webapp-abc123.image." "webapp-abc123.image.") || V="<none>"
check "empty-value marker treated as absent" "$V" "<none>"

# First match wins when duplicates exist (mirrors the old head -1 behavior).
DUPES="webapp-abc123.image.first
webapp-abc123.image.second"
V=$(marker_value "$DUPES" "webapp-abc123.image.") || V="<none>"
check "first match wins" "$V" "first"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
