#!/usr/bin/env bash
# Tests for _build.yml's label + manifest steps and _image.yml's digest
# resolution — extracted from the workflow YAML at test time.
set -euo pipefail
cd "$(dirname "$0")/../.."
source .github/scripts/test-lib.sh

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

## _build.yml: Set build label ----------------------------------------------
LABEL=$(extract_step .github/workflows/_build.yml build 'Set build label')

OUT="$WORK/out"; : > "$OUT"
(export GITHUB_OUTPUT="$OUT" INPUT_VERSION="1.2.3-build.7" RUN_NUMBER=42; bash -e "$LABEL")
check "explicit version wins" "$(grep '^value=' "$OUT" | cut -d= -f2)" "1.2.3-build.7"

: > "$OUT"
(export GITHUB_OUTPUT="$OUT" INPUT_VERSION="" RUN_NUMBER=42; bash -e "$LABEL")
V=$(grep '^value=' "$OUT" | cut -d= -f2)
note "empty version falls back to YYYYMMDD.run_number" "$([[ "$V" =~ ^[0-9]{8}\.42$ ]] && echo yes || echo no)"

## _build.yml: Write artifact manifest ---------------------------------------
MANIFEST=$(extract_step .github/workflows/_build.yml build 'Write artifact manifest')

mkdir -p "$WORK/build/publish/sub"
printf 'app' > "$WORK/build/publish/Api.dll"
printf 'cfg' > "$WORK/build/publish/sub/appsettings.json"
(cd "$WORK/build" && bash -e "$MANIFEST") > /dev/null
note "manifest written into publish/" "$([ -f "$WORK/build/publish/SHA256SUMS" ] && echo yes || echo no)"
check "manifest covers every file (recursively)" "$(wc -l < "$WORK/build/publish/SHA256SUMS" | tr -d ' ')" "2"
(cd "$WORK/build/publish" && sha256sum --check --quiet SHA256SUMS) \
  && note "manifest hashes verify against the files" yes \
  || note "manifest hashes verify against the files" no
printf 'tampered' > "$WORK/build/publish/Api.dll"
(cd "$WORK/build/publish" && sha256sum --check --quiet SHA256SUMS) > /dev/null 2>&1 \
  && note "tampered file fails manifest verification" no \
  || note "tampered file fails manifest verification" yes

## _image.yml: Resolve image digest ------------------------------------------
DIGEST=$(extract_step .github/workflows/_image.yml image 'Resolve image digest')

mkdir -p "$WORK/bin"
cat > "$WORK/bin/az" <<'AZEOF'
#!/usr/bin/env bash
printf '%s\n' "$STUB_DIGEST"
AZEOF
chmod +x "$WORK/bin/az"
export PATH="$WORK/bin:$PATH"

: > "$OUT"
GOOD="sha256:$(printf 'a%.0s' {1..64})"
(export GITHUB_OUTPUT="$OUT" ACR=stubacr REPO=cicd-demo/api SHA=abc STUB_DIGEST="$GOOD"; bash -e "$DIGEST") > /dev/null
check "digest resolved and output" "$(grep '^value=' "$OUT" | cut -d= -f2)" "$GOOD"
check "bare hex emitted for artifact-safe marker names" "$(grep '^hex=' "$OUT" | cut -d= -f2)" "${GOOD#sha256:}"

: > "$OUT"
(export GITHUB_OUTPUT="$OUT" ACR=stubacr REPO=cicd-demo/api SHA=abc STUB_DIGEST=""; bash -e "$DIGEST") > /dev/null 2>&1 \
  && note "empty digest fails the job" no \
  || note "empty digest fails the job" yes

## _image.yml: Build and push image — empty-repo guard -----------------------
BUILD=$(extract_step .github/workflows/_image.yml image 'Build and push image (az acr build)')
(export RUNNER_TEMP="$WORK" ACR=stubacr REPO="" LABEL=1.0.0 SHA=abc; bash -e "$BUILD") > /dev/null 2>&1 \
  && note "empty image-repository fails the build (no unqualified image)" no \
  || note "empty image-repository fails the build (no unqualified image)" yes

finish
