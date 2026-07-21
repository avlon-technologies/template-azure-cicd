#!/usr/bin/env bash
# Tests for on-main.yml's "Locate promotable release artifact" step — the
# prod promotion/rollback gate. The helpers it sources
# (find_verified_artifact, marker_value) have their own unit suites; this
# covers the decision logic around them: merge-commit second-parent
# resolution (push and v-tag rollback), the build/stg/* "proven green on
# staging" requirement, and the three hard-fail branches that keep prod
# from ever rebuilding or shipping unverified bytes.
#
# Drift-proof by construction: the script under test is extracted from
# .github/workflows/on-main.yml at test time and executed against a
# fixture-backed `gh` stub on PATH.
set -euo pipefail
cd "$(dirname "$0")/../.."
source .github/scripts/test-lib.sh

STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT
mkdir -p "$STUB/bin"
export STUB

# Fake gh serving pre-jq'd fixtures:
#   $STUB/tag-commit     — merge SHA the v<version> tag resolves to (rollback)
#   $STUB/parent         — second-parent SHA of the merge commit ('' = squash)
#   $STUB/stg-refs       — build/stg/* refs pointing at the release SHA
#   $STUB/artifacts      — candidate run ids (find_verified_artifact)
#   $STUB/run-info       — "<workflow-path> <event> <head-sha>" for any run id
#   $STUB/run-artifacts  — artifact-name list of the verified run (markers)
cat > "$STUB/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"/commits/v"*) cat "$STUB/tag-commit" ;;
  *"/commits/"*) cat "$STUB/parent" ;;
  *"/git/matching-refs/tags/build/stg/"*) cat "$STUB/stg-refs" ;;
  *"/actions/artifacts?name="*) cat "$STUB/artifacts" ;;
  *"/artifacts?per_page="*) cat "$STUB/run-artifacts" ;;
  *"/actions/runs/"*) cat "$STUB/run-info" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
GHEOF
chmod +x "$STUB/bin/gh"
export PATH="$STUB/bin:$PATH"

PROMOTE=$(extract_step .github/workflows/on-main.yml prepare 'Locate promotable release artifact')
DIGEST_HEX=$(printf '0%.0s' {1..63})a

# Baseline fixture: a healthy push-path promotion — merge commit mergeshaA
# with release head relshaB, stg-tagged, artifact from a trusted release
# run, digest marker present. Tests then break one link at a time.
reset_fixtures() {
  printf 'relshaB\n' > "$STUB/parent"
  printf 'refs/tags/build/stg/1.5.0-build.42\n' > "$STUB/stg-refs"
  printf '101\n' > "$STUB/artifacts"
  printf '.github/workflows/on-release.yml push relshaB\n' > "$STUB/run-info"
  printf 'webapp-relshaB\nwebapp-relshaB.label.1.5.0-build.42\nwebapp-relshaB.image.%s\n' \
    "$DIGEST_HEX" > "$STUB/run-artifacts"
  : > "$STUB/tag-commit"
}

run_step() { # [ENV=val ...] — INPUT_VERSION='' is the push path
  ( export GITHUB_REPOSITORY="example/repo" GH_TOKEN=dummy GITHUB_SHA=mergeshaA \
      GITHUB_OUTPUT="$STUB/out" INPUT_VERSION= VERSION=1.5.0 "$@"
    : > "$GITHUB_OUTPUT"
    bash -e "$PROMOTE" ) > "$STUB/stdout" 2>&1
}

# 1. Push path happy: promotes the release head's verified candidate.
reset_fixtures
if run_step; then
  grep -q "artifact=webapp-relshaB" "$STUB/out" && grep -q "run-id=101" "$STUB/out" \
    && grep -q "sha=relshaB" "$STUB/out" \
    && grep -q "image-digest=sha256:$DIGEST_HEX" "$STUB/out" \
    && note "push path: verified stg-tested candidate promoted with digest" yes \
    || note "push path: verified stg-tested candidate promoted with digest" no
else
  note "push path: verified stg-tested candidate promoted with digest" no
fi

# 2. No second parent (squash merge): hard fail, no rebuild.
reset_fixtures
: > "$STUB/parent"
if run_step; then
  note "squash merge (no second parent) fails hard" no
else
  grep -q "does not resolve to a merge commit" "$STUB/stdout" \
    && note "squash merge (no second parent) fails hard" yes \
    || note "squash merge (no second parent) fails hard" no
fi

# 3. No build/stg/* tag on the release head: never deployed to staging.
reset_fixtures
: > "$STUB/stg-refs"
if run_step; then
  note "missing stg tag (never green on staging) fails hard" no
else
  grep -q "never successfully deployed to staging" "$STUB/stdout" \
    && note "missing stg tag (never green on staging) fails hard" yes \
    || note "missing stg tag (never green on staging) fails hard" no
fi

# 4. Artifacts exist but none verifies: refuse to promote, no fallback.
reset_fixtures
printf '.github/workflows/evil.yml push relshaB\n' > "$STUB/run-info"
if run_step; then
  note "unverifiable artifacts fail hard (no newest-wins fallback)" no
else
  grep -q "Refusing to promote unverifiable bytes" "$STUB/stdout" \
    && note "unverifiable artifacts fail hard (no newest-wins fallback)" yes \
    || note "unverifiable artifacts fail hard (no newest-wins fallback)" no
fi

# 5. No artifact at all (expired / never dispatched): fail with re-staging
#    instructions, never a silent rebuild.
reset_fixtures
: > "$STUB/artifacts"
if run_step; then
  note "missing/expired artifact fails hard with re-staging instructions" no
else
  grep -q "No unexpired stg-tested artifact" "$STUB/stdout" \
    && note "missing/expired artifact fails hard with re-staging instructions" yes \
    || note "missing/expired artifact fails hard with re-staging instructions" no
fi

# 6. Verified candidate without a digest marker (pre-container build):
#    prod never falls back to a tag or rebuild.
reset_fixtures
printf 'webapp-relshaB\nwebapp-relshaB.label.1.5.0-build.42\n' > "$STUB/run-artifacts"
if run_step; then
  note "candidate without digest marker fails hard" no
else
  grep -q "no image-digest marker" "$STUB/stdout" \
    && note "candidate without digest marker fails hard" yes \
    || note "candidate without digest marker fails hard" no
fi

# 7. Rollback path: v<version> tag → merge commit → second parent → same
#    verification chain, promoted from the historical release head.
reset_fixtures
printf 'mergeshaA\n' > "$STUB/tag-commit"
if run_step INPUT_VERSION=1.5.0; then
  grep -q "sha=relshaB" "$STUB/out" && grep -q "image-digest=sha256:$DIGEST_HEX" "$STUB/out" \
    && note "rollback dispatch: tag-resolved candidate promoted" yes \
    || note "rollback dispatch: tag-resolved candidate promoted" no
else
  note "rollback dispatch: tag-resolved candidate promoted" no
fi

# 8. Rollback to a version whose tag doesn't exist: fail fast.
reset_fixtures
if run_step INPUT_VERSION=1.5.0; then
  note "rollback to unknown version (no v-tag) fails fast" no
else
  grep -q "Tag v1.5.0 not found" "$STUB/stdout" \
    && note "rollback to unknown version (no v-tag) fails fast" yes \
    || note "rollback to unknown version (no v-tag) fails fast" no
fi

rm -f "$PROMOTE"
finish
