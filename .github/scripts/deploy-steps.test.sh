#!/usr/bin/env bash
# Tests for _deploy.yml's critical step scripts — digest-shape validation,
# revision-suffix sanitization, FQDN guard, and the revision staging
# branches (reuse / collision / not-found / transient error).
#
# Drift-proof by construction: the scripts under test are extracted from
# .github/workflows/_deploy.yml itself at test time (no copy to fall out
# of sync) and executed against a stubbed `az` on PATH.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Probe by executing (not command -v): Windows ships store-alias stubs
# that exist on PATH but only print an install hint. We need yaml too.
PY=""
for c in python3 python py; do
  if "$c" -c 'import yaml' > /dev/null 2>&1; then
    PY=$c
    break
  fi
done
if [ -z "$PY" ]; then
  echo "SKIP-FAIL: no python with pyyaml found — cannot extract workflow steps." >&2
  exit 1
fi

extract_step() { # <step-name> -> file path of the step's run script
  local out
  out=$(mktemp)
  "$PY" - "$1" > "$out" <<'PYEOF'
import sys, yaml
wf = yaml.safe_load(open('.github/workflows/_deploy.yml', encoding='utf-8'))
for s in wf['jobs']['deploy']['steps']:
    if s.get('name') == sys.argv[1]:
        sys.stdout.write(s['run'])
        break
else:
    sys.exit(f"step not found: {sys.argv[1]}")
PYEOF
  printf '%s' "$out"
}

STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT
mkdir -p "$STUB/bin"
export STUB_LOG="$STUB/az-calls.log"

# Stubbed az: behavior driven by STUB_* env vars; mutating calls are
# recorded to STUB_LOG so tests can assert which path ran.
cat > "$STUB/bin/az" <<'AZEOF'
#!/usr/bin/env bash
cmd="$*"
case "$cmd" in
  *"revision show"*"properties.fqdn"*)
    echo "stubrev.example.azurecontainerapps.io" ;;
  *"revision show"*)
    case "${STUB_REV_SHOW:-notfound}" in
      exists) printf '%s\n' "$STUB_REV_IMAGE" ;;
      notfound) echo "ERROR: RevisionNotFound: the revision was not found." >&2; exit 1 ;;
      *) echo "ERROR: GatewayTimeout: transient ARM failure." >&2; exit 1 ;;
    esac ;;
  *"revision activate"*)
    echo "activate" >> "$STUB_LOG" ;;
  *"containerapp update"*)
    echo "update" >> "$STUB_LOG" ;;
  *"containerapp show"*)
    printf '%s\n' "${STUB_FQDN-app.example.azurecontainerapps.io}" ;;
  *)
    echo "unexpected az call: $cmd" >&2; exit 1 ;;
esac
AZEOF
chmod +x "$STUB/bin/az"
export PATH="$STUB/bin:$PATH"

PASS=0
FAIL=0
note() { # <description> <ok?>
  if [ "$2" = yes ]; then echo "ok: $1"; PASS=$((PASS + 1)); else echo "FAIL: $1"; FAIL=$((FAIL + 1)); fi
}

run_step() { # <script> [ENV=val ...] — runs under the workflow's bash -e
  local script="$1"; shift
  : > "$STUB_LOG"
  ( export GITHUB_OUTPUT="$STUB/out" RUNNER_TEMP="$STUB" "$@"
    : > "$GITHUB_OUTPUT"
    bash -e "$script" ) > "$STUB/stdout" 2>&1
}

GOOD_DIGEST="sha256:$(printf '0%.0s' {1..63})a"

## Resolve deployment target
TARGET=$(extract_step 'Resolve deployment target')
BASE=(APP=app RG=rg ACR=myacr LABEL=1.22.0-Build.187)

if run_step "$TARGET" "${BASE[@]}" DIGEST="$GOOD_DIGEST"; then
  grep -q "suffix=1-22-0-build-187" "$STUB/out" && grep -q "image=myacr.azurecr.io/cicd-demo/api@$GOOD_DIGEST" "$STUB/out" \
    && note "valid digest: image pinned, label sanitized to lowercase suffix" yes \
    || note "valid digest: image pinned, label sanitized to lowercase suffix" no
else
  note "valid digest: image pinned, label sanitized to lowercase suffix" no
fi

run_step "$TARGET" "${BASE[@]}" DIGEST="latest" && note "tag instead of digest rejected" no || note "tag instead of digest rejected" yes
run_step "$TARGET" "${BASE[@]}" DIGEST="" && note "empty digest rejected" no || note "empty digest rejected" yes
run_step "$TARGET" "${BASE[@]}" DIGEST="${GOOD_DIGEST^^}" && note "uppercase-hex digest rejected" no || note "uppercase-hex digest rejected" yes
run_step "$TARGET" "${BASE[@]}" DIGEST="$GOOD_DIGEST" STUB_FQDN="" && note "empty FQDN fails fast" no || note "empty FQDN fails fast" yes

## Stage new revision (zero traffic)
STAGE=$(extract_step 'Stage new revision (zero traffic)')
SBASE=(APP=app RG=rg IMAGE="myacr.azurecr.io/cicd-demo/api@$GOOD_DIGEST" SUFFIX=1-22-0-build-187)

if run_step "$STAGE" "${SBASE[@]}" STUB_REV_SHOW=notfound; then
  grep -q "^update$" "$STUB_LOG" && grep -q "rev-fqdn=" "$STUB/out" \
    && note "revision not found: creates it and resolves its FQDN" yes \
    || note "revision not found: creates it and resolves its FQDN" no
else
  note "revision not found: creates it and resolves its FQDN" no
fi

if run_step "$STAGE" "${SBASE[@]}" STUB_REV_SHOW=exists STUB_REV_IMAGE="myacr.azurecr.io/cicd-demo/api@$GOOD_DIGEST"; then
  grep -q "^activate$" "$STUB_LOG" && ! grep -q "^update$" "$STUB_LOG" \
    && note "same-label same-image revision reused (no update)" yes \
    || note "same-label same-image revision reused (no update)" no
else
  note "same-label same-image revision reused (no update)" no
fi

run_step "$STAGE" "${SBASE[@]}" STUB_REV_SHOW=exists STUB_REV_IMAGE="myacr.azurecr.io/cicd-demo/api@sha256:deadbeef" \
  && note "same-label different-image collision fails" no || note "same-label different-image collision fails" yes

if run_step "$STAGE" "${SBASE[@]}" STUB_REV_SHOW=error; then
  note "transient revision-show error fails (not treated as not-found)" no
else
  grep -q "Could not determine" "$STUB/stdout" \
    && note "transient revision-show error fails (not treated as not-found)" yes \
    || note "transient revision-show error fails (not treated as not-found)" no
fi

rm -f "$TARGET" "$STAGE"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
