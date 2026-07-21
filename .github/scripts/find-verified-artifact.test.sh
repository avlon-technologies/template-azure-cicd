#!/usr/bin/env bash
# Regression tests for find_verified_artifact — the promotion path's
# security control. Runs on every PR (the "Test workflow scripts" job in
# on-pr.yml). No network or token needed: `gh` is stubbed with a
# fixture-backed fake on PATH.
set -euo pipefail
cd "$(dirname "$0")"

STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT
export STUB_DIR GITHUB_REPOSITORY="example/repo"

# Fake gh: serves fixtures instead of the GitHub API. The real calls are
#   gh api repos/<repo>/actions/artifacts?name=<name> --jq <expr>
#   gh api repos/<repo>/actions/runs/<id> --jq <expr>
# so the stub keys on the URL ($2) and returns pre-jq'd fixture content:
#   $STUB_DIR/artifacts  — newline-separated candidate run ids (newest first)
#   $STUB_DIR/run-<id>   — one line: "<workflow-path> <event> <head-sha>"
mkdir -p "$STUB_DIR/bin"
cat > "$STUB_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
url="$2"
case "$url" in
  */actions/artifacts?*) cat "$STUB_DIR/artifacts" ;;
  */actions/runs/*) cat "$STUB_DIR/run-${url##*/}" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
GH
chmod +x "$STUB_DIR/bin/gh"
export PATH="$STUB_DIR/bin:$PATH"

source ./find-verified-artifact.sh

PASS=0
FAIL=0
check() { # <description> <expected-run-id> <expected-artifacts-found>
  if [ "$FVA_RUN_ID" = "$2" ] && [ "$FVA_ARTIFACTS_FOUND" = "$3" ]; then
    echo "ok: $1"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $1 (run-id='$FVA_RUN_ID' want '$2'; artifacts-found='$FVA_ARTIFACTS_FOUND' want '$3')"
    FAIL=$((FAIL + 1))
  fi
}

TRUSTED=".github/workflows/on-release.yml .github/workflows/on-hotfix.yml"

# 1. Happy path: trusted workflow, right commit, push trigger.
printf '101\n' > "$STUB_DIR/artifacts"
printf '.github/workflows/on-release.yml push shaA\n' > "$STUB_DIR/run-101"
find_verified_artifact webapp-shaA shaA "$TRUSTED"
check "matching artifact verifies" 101 true

# 2. Untrusted producing workflow is rejected.
printf '.github/workflows/evil.yml push shaA\n' > "$STUB_DIR/run-101"
find_verified_artifact webapp-shaA shaA "$TRUSTED"
check "untrusted workflow rejected" "" true

# 3. Trusted workflow but wrong commit is rejected.
printf '.github/workflows/on-release.yml push shaB\n' > "$STUB_DIR/run-101"
find_verified_artifact webapp-shaA shaA "$TRUSTED"
check "wrong head_sha rejected" "" true

# 4. Trusted workflow and commit but untrusted trigger is rejected.
printf '.github/workflows/on-release.yml pull_request shaA\n' > "$STUB_DIR/run-101"
find_verified_artifact webapp-shaA shaA "$TRUSTED"
check "untrusted trigger rejected" "" true

# 5. Spoofed newest artifact is skipped; older genuine one wins — the
#    attack the check exists to stop.
printf '202\n101\n' > "$STUB_DIR/artifacts"
printf '.github/workflows/evil.yml push shaA\n' > "$STUB_DIR/run-202"
printf '.github/workflows/on-release.yml push shaA\n' > "$STUB_DIR/run-101"
find_verified_artifact webapp-shaA shaA "$TRUSTED"
check "spoofed newest skipped, older genuine artifact chosen" 101 true

# 6. No artifacts at all: nothing found, nothing verified.
: > "$STUB_DIR/artifacts"
find_verified_artifact webapp-shaA shaA "$TRUSTED"
check "no artifacts" "" false

# 7. Any workflow on the trusted list is accepted (dispatch trigger too).
printf '101\n' > "$STUB_DIR/artifacts"
printf '.github/workflows/on-hotfix.yml workflow_dispatch shaA\n' > "$STUB_DIR/run-101"
find_verified_artifact webapp-shaA shaA "$TRUSTED"
check "second trusted workflow + dispatch trigger accepted" 101 true

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
