#!/usr/bin/env bash
# Tests for _deploy.yml's "Verify image attestation" step — the deploy-time
# cryptographic supply-chain gate. Asserts the gh registry client is handed
# the right ACR credentials (throwaway docker config with the token-auth
# user), that the verify call pins this repo's _image.yml as the signer,
# that a failed verification fails the step before any deploy call, and
# that the credential file is cleaned up either way.
#
# Drift-proof by construction: the script under test is extracted from
# .github/workflows/_deploy.yml at test time and executed against stubbed
# `az` and `gh` on PATH.
set -euo pipefail
cd "$(dirname "$0")/../.."
source .github/scripts/test-lib.sh

STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT
mkdir -p "$STUB/bin"

# az: only `acr login --expose-token` is expected — emits the stub token.
cat > "$STUB/bin/az" <<'AZEOF'
#!/usr/bin/env bash
case "$*" in
  *"acr login"*"--expose-token"*)
    [ "${STUB_AZ_EXIT:-0}" = 0 ] || { echo "ERROR: AADSTS oops" >&2; exit 1; }
    printf '%s\n' "stub-acr-token" ;;
  *) echo "unexpected az call: $*" >&2; exit 1 ;;
esac
AZEOF
chmod +x "$STUB/bin/az"

# gh: records the attestation-verify invocation and captures the docker
# config the step wired up (it is deleted right after, so capture now).
cat > "$STUB/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
if [ -n "${DOCKER_CONFIG:-}" ] && [ -f "$DOCKER_CONFIG/config.json" ]; then
  cp "$DOCKER_CONFIG/config.json" "$STUB_CAPTURE"
fi
exit "${STUB_GH_EXIT:-0}"
GHEOF
chmod +x "$STUB/bin/gh"
export PATH="$STUB/bin:$PATH"
export STUB_LOG="$STUB/gh-calls.log" STUB_CAPTURE="$STUB/captured-config.json"

VERIFY=$(extract_step .github/workflows/_deploy.yml deploy 'Verify image attestation')
DIGEST="sha256:$(printf '0%.0s' {1..63})a"

run_step() { # [ENV=val ...] — runs the step under the workflow's bash -e
  : > "$STUB_LOG"
  rm -f "$STUB_CAPTURE"
  ( export RUNNER_TEMP="$STUB" GITHUB_REPOSITORY="example/repo" GH_TOKEN=dummy \
      ACR=myacr DIGEST="$DIGEST" "$@"
    bash -e "$VERIFY" ) > "$STUB/stdout" 2>&1
}

# 1. Happy path: verify call pins the digest and this repo's _image.yml.
if run_step; then
  grep -q -- "attestation verify oci://myacr.azurecr.io/cicd-demo/api@$DIGEST" "$STUB_LOG" \
    && grep -q -- "--repo example/repo" "$STUB_LOG" \
    && grep -q -- "--signer-workflow example/repo/.github/workflows/_image.yml" "$STUB_LOG" \
    && note "verify pins the digest, the repo, and _image.yml as signer" yes \
    || note "verify pins the digest, the repo, and _image.yml as signer" no
else
  note "verify pins the digest, the repo, and _image.yml as signer" no
fi

# 2. The docker config gh saw carries the ACR token-auth credential.
EXPECTED_AUTH=$(printf '00000000-0000-0000-0000-000000000000:%s' "stub-acr-token" | base64 -w0)
check "gh was handed the ACR token as a docker registry credential" \
  "$(cat "$STUB_CAPTURE")" \
  "{\"auths\":{\"myacr.azurecr.io\":{\"auth\":\"$EXPECTED_AUTH\"}}}"

# 3. The throwaway credential file is removed after a successful verify.
[ ! -e "$STUB/docker-attest" ] \
  && note "throwaway docker config removed after verify" yes \
  || note "throwaway docker config removed after verify" no

# 4. A digest that fails verification fails the step (deploy never starts).
run_step STUB_GH_EXIT=1 && note "failed attestation verification fails the step" no \
  || note "failed attestation verification fails the step" yes

# 5. Token acquisition failure fails the step (no unauthenticated verify).
run_step STUB_AZ_EXIT=1 && note "ACR token failure fails the step" no \
  || note "ACR token failure fails the step" yes

rm -f "$VERIFY"
finish
