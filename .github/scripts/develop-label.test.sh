#!/usr/bin/env bash
# Tests for on-develop.yml's "Validate and resolve build label" step — the
# dev redeploy input validation (format, date sanity, run-history lookup).
# gh is stubbed; the script is extracted from the workflow YAML.
set -euo pipefail
cd "$(dirname "$0")/../.."
source .github/scripts/test-lib.sh

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "${STUB_RUN_COUNT:-0}"
GHEOF
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

VALIDATE=$(extract_step .github/workflows/on-develop.yml prepare 'Validate and resolve build label')

run_v() { # INPUT_LABEL STUB_RUN_COUNT; sets RS_EXIT
  : > "$WORK/out"
  RS_EXIT=0
  (export GITHUB_OUTPUT="$WORK/out" GH_TOKEN=stub INPUT_LABEL="$1" STUB_RUN_COUNT="$2"
   bash -e "$VALIDATE") > "$WORK/log" 2>&1 || RS_EXIT=$?
}

run_v "" 0
check "empty label passes through (normal push behavior)" "$RS_EXIT" "0"
check "empty label yields empty output" "$(grep -c '^build-label=$' "$WORK/out")" "1"

run_v "not-a-label" 1
note "malformed label rejected" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"

run_v "20261501.5" 1
note "impossible date (month 15) rejected" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"

run_v "20260721.99" 0
note "label with no matching run in history rejected" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"

run_v "20260721.82" 1
check "label matching a historical run accepted" "$RS_EXIT" "0"
check "accepted label emitted for the build" "$(grep '^build-label=' "$WORK/out" | cut -d= -f2)" "20260721.82"

finish
