#!/usr/bin/env bash
# Tests for the stg artifact-reuse steps — on-release.yml's "Locate
# existing rc artifact" and _hotfix-support.yml's "Locate existing
# artifact". The helpers they source (find_verified_artifact,
# marker_value) have their own unit suites; this covers the step scripts
# that wire them together: the rebuild fall-throughs (no artifact / no
# label marker / no digest marker), the reuse outputs, and the
# label-drift warning where the stamped label wins over the derived one.
#
# Drift-proof by construction: the scripts under test are extracted from
# the workflow YAML at test time and executed against a fixture-backed
# `gh` stub on PATH.
set -euo pipefail
cd "$(dirname "$0")/../.."
source .github/scripts/test-lib.sh

STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT
mkdir -p "$STUB/bin"
export STUB

# Fake gh serving pre-jq'd fixtures:
#   $STUB/artifacts      — candidate run ids, newest first (find_verified_artifact)
#   $STUB/run-info       — "<workflow-path> <event> <head-sha>" for any run id
#   $STUB/run-artifacts  — artifact-name list of the verified run (markers)
cat > "$STUB/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"/actions/artifacts?name="*) cat "$STUB/artifacts" ;;
  *"/artifacts?per_page="*) cat "$STUB/run-artifacts" ;;
  *"/actions/runs/"*) cat "$STUB/run-info" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
GHEOF
chmod +x "$STUB/bin/gh"
export PATH="$STUB/bin:$PATH"

run_step() { # <script> [ENV=val ...]
  local script="$1"; shift
  ( export GITHUB_REPOSITORY="example/repo" GH_TOKEN=dummy \
      GITHUB_OUTPUT="$STUB/out" GITHUB_STEP_SUMMARY="$STUB/summary" "$@"
    : > "$GITHUB_OUTPUT"
    : > "$GITHUB_STEP_SUMMARY"
    bash -e "$script" ) > "$STUB/stdout" 2>&1
}

# Both steps share the contract; exercise each against its own workflow.
# Fixture identity per variant: the trusted producing workflow and how the
# step receives the commit (GITHUB_SHA for release, `SHA` input for
# hotfix/support — where the trusted list is derived from BRANCH_TYPE).
run_release() { run_step "$RC_STEP" GITHUB_SHA=shaA DERIVED="$1"; }
run_hotfix() { run_step "$HF_STEP" SHA=shaA BRANCH_TYPE=hotfix DERIVED="$1"; }
RC_STEP=$(extract_step .github/workflows/on-release.yml prepare 'Locate existing rc artifact')
HF_STEP=$(extract_step .github/workflows/_hotfix-support.yml prepare 'Locate existing artifact')

DIGEST_HEX=$(printf '0%.0s' {1..63})a

for variant in release hotfix; do
  if [ "$variant" = release ]; then
    run_variant=run_release
    trusted_wf=.github/workflows/on-release.yml
    label=1.22.0-build.187
  else
    run_variant=run_hotfix
    trusted_wf=.github/workflows/on-hotfix.yml
    label=1.22.1-hotfix.3
  fi

  # 1. No artifact for the commit: falls through to a rebuild, no outputs.
  : > "$STUB/artifacts"
  if "$run_variant" "$label"; then
    grep -q "will build" "$STUB/stdout" && [ ! -s "$STUB/out" ] \
      && note "$variant: no artifact falls through to rebuild" yes \
      || note "$variant: no artifact falls through to rebuild" no
  else
    note "$variant: no artifact falls through to rebuild" no
  fi

  # 2. Untrusted producing workflow: provenance check rejects, rebuild.
  printf '101\n' > "$STUB/artifacts"
  printf '.github/workflows/evil.yml push shaA\n' > "$STUB/run-info"
  if "$run_variant" "$label"; then
    [ ! -s "$STUB/out" ] \
      && note "$variant: untrusted producing workflow rejected, rebuild" yes \
      || note "$variant: untrusted producing workflow rejected, rebuild" no
  else
    note "$variant: untrusted producing workflow rejected, rebuild" no
  fi

  # 3. Verified artifact with both markers: reused, outputs wired.
  printf '%s push shaA\n' "$trusted_wf" > "$STUB/run-info"
  printf 'webapp-shaA\nwebapp-shaA.label.%s\nwebapp-shaA.image.%s\n' \
    "$label" "$DIGEST_HEX" > "$STUB/run-artifacts"
  if "$run_variant" "$label"; then
    grep -q "artifact=webapp-shaA" "$STUB/out" && grep -q "run-id=101" "$STUB/out" \
      && grep -q "version=$label" "$STUB/out" \
      && grep -q "image-digest=sha256:$DIGEST_HEX" "$STUB/out" \
      && note "$variant: verified artifact reused with label + digest outputs" yes \
      || note "$variant: verified artifact reused with label + digest outputs" no
  else
    note "$variant: verified artifact reused with label + digest outputs" no
  fi

  # 4. Verified but no label marker (pre-marker build): rebuild.
  printf 'webapp-shaA\nwebapp-shaA.image.%s\n' "$DIGEST_HEX" > "$STUB/run-artifacts"
  if "$run_variant" "$label"; then
    [ ! -s "$STUB/out" ] && grep -q "no label marker" "$STUB/stdout" \
      && note "$variant: missing label marker falls through to rebuild" yes \
      || note "$variant: missing label marker falls through to rebuild" no
  else
    note "$variant: missing label marker falls through to rebuild" no
  fi

  # 5. Verified but no digest marker (pre-container build): rebuild.
  printf 'webapp-shaA\nwebapp-shaA.label.%s\n' "$label" > "$STUB/run-artifacts"
  if "$run_variant" "$label"; then
    [ ! -s "$STUB/out" ] && grep -q "no image-digest marker" "$STUB/stdout" \
      && note "$variant: missing digest marker falls through to rebuild" yes \
      || note "$variant: missing digest marker falls through to rebuild" no
  else
    note "$variant: missing digest marker falls through to rebuild" no
  fi

  # 6. Label drift: stamped label wins, warning raised, summary written.
  printf 'webapp-shaA\nwebapp-shaA.label.%s\nwebapp-shaA.image.%s\n' \
    "$label" "$DIGEST_HEX" > "$STUB/run-artifacts"
  if "$run_variant" "9.9.9-changed.1"; then
    grep -q "version=$label" "$STUB/out" \
      && grep -q "::warning::" "$STUB/stdout" \
      && grep -q "Label drift" "$STUB/summary" \
      && note "$variant: label drift deploys the stamped label and warns" yes \
      || note "$variant: label drift deploys the stamped label and warns" no
  else
    note "$variant: label drift deploys the stamped label and warns" no
  fi
done

rm -f "$RC_STEP" "$HF_STEP"
finish
