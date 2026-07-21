#!/usr/bin/env bash
# Tests for _deploy.yml's two smoke-test loops — the pipeline's "green
# means the right build is serving" guarantee. Scripts extracted from the
# workflow YAML at test time; curl/jq/sleep stubbed (sleep is a no-op so
# the 15-attempt timeout paths run instantly).
set -euo pipefail
cd "$(dirname "$0")/../.."
source .github/scripts/test-lib.sh

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

cat > "$WORK/bin/curl" <<'CURLEOF'
#!/usr/bin/env bash
for a in "$@"; do :; done   # last arg = URL
case "$a" in
  */v1/hello) printf '%s' "$STUB_BODY" ;;
  */openapi/v1.json) printf '{"info":{"version":"stub"}}' ;;
  *) exit 22 ;;
esac
CURLEOF
cat > "$WORK/bin/jq" <<'JQEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$STUB_VERSION"
JQEOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/sleep"
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"

run_smoke() { # <script> BODY VERSION EXPECTED; sets RS_EXIT/RS_LOG
  RS_EXIT=0
  (export STUB_BODY="$2" STUB_VERSION="$3" URL="https://stub.example" EXPECTED="$4"
   bash -e "$1") > "$WORK/log" 2>&1 || RS_EXIT=$?
  RS_LOG="$WORK/log"
}

for STEP in 'Smoke test staged revision' 'Smoke test deployment'; do
  S=$(extract_step .github/workflows/_deploy.yml deploy "$STEP")

  run_smoke "$S" "Hello World!" "1.23.0" "1.23.0"
  check "$STEP: exact version match passes" "$RS_EXIT" "0"

  run_smoke "$S" "Hello World!" "1.23.0-build.170" "1.23.0"
  check "$STEP: pre-release of expected version passes (promoted stamp)" "$RS_EXIT" "0"

  run_smoke "$S" "Hello World!" "1.23.01" "1.23.0"
  note "$STEP: lookalike version (1.23.01 vs 1.23.0) fails" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"

  run_smoke "$S" "Hello World!" "9.9.9" "1.23.0"
  if [ "$RS_EXIT" != 0 ] && grep -q "reports version" "$RS_LOG"; then
    note "$STEP: wrong build serving fails after retries, names the mismatch" yes
  else
    note "$STEP: wrong build serving fails after retries, names the mismatch" no
  fi

  run_smoke "$S" "" "1.23.0" "1.23.0"
  note "$STEP: app never answering fails" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"

  run_smoke "$S" "Internal Server Error" "1.23.0" "1.23.0"
  note "$STEP: wrong response body fails" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"

  rm -f "$S"
done

finish
