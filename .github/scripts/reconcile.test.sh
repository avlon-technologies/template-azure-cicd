#!/usr/bin/env bash
# Tests for reconcile-releases.yml's audit script — the safety net that
# catches release merges whose prod run was silently superseded. Runs the
# extracted script inside a fixture git repo with backdated merge commits;
# gh (release lookups) and curl (webhook) are stubbed.
set -euo pipefail
cd "$(dirname "$0")/../.."
source .github/scripts/test-lib.sh

AUDIT=$(extract_step .github/workflows/reconcile-releases.yml audit 'Check recent merges for missing deploys')

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
# Only `gh release view v<X> ...` is called; succeed when the version is
# in STUB_RELEASES (space-separated, e.g. "1.0.0 2.0.0").
ver=""
for a in "$@"; do case "$a" in v[0-9]*) ver="${a#v}";; esac; done
case " ${STUB_RELEASES:-} " in *" $ver "*) exit 0 ;; *) exit 1 ;; esac
GHEOF
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

# Fixture: main with one backdated release merge (old enough to be
# outside the 2-hour grace period) and helpers to add more. Epoch format
# ("@<seconds> +0000") because git parses bare timestamps as *local*
# time, which would silently cancel a `date -u`-derived offset.
FIXTURE="$WORK/repo"
git init -q -b main "$FIXTURE"
OLD="@$(( $(date +%s) - 14400 )) +0000"
fx() { (cd "$FIXTURE" && GIT_AUTHOR_DATE="${FX_DATE:-$OLD}" GIT_COMMITTER_DATE="${FX_DATE:-$OLD}" \
        git -c user.email=t@t -c user.name=t "$@"); }
fx commit -q --allow-empty -m base

merge_release() { # <branch e.g. release/1.0.0> [FX_DATE override via env]
  fx checkout -q -b "work-${1//\//-}"
  fx commit -q --allow-empty -m "fix for $1"
  fx checkout -q main
  fx merge -q --no-ff -m "Merge pull request #1 from avlon-technologies/$1" "work-${1//\//-}"
}

run_audit() { # STUB_RELEASES value; sets RS_EXIT/RS_LOG
  RS_EXIT=0
  (cd "$FIXTURE" && export GH_TOKEN=stub GITHUB_REPOSITORY=stub/stub \
     GITHUB_STEP_SUMMARY="$WORK/summary" STUB_RELEASES="$1"
   : > "$GITHUB_STEP_SUMMARY"
   bash -e "$AUDIT") > "$WORK/log" 2>&1 || RS_EXIT=$?
  RS_LOG="$WORK/log"
}

# 1. Healthy: tag + release both exist.
merge_release release/1.0.0
fx tag build/prod/1.0.0
run_audit "1.0.0"
check "complete version (tag + release) passes" "$RS_EXIT" "0"

# 2. Half-state: tag exists, release missing -> warn but don't fail.
merge_release release/1.1.0
fx tag build/prod/1.1.0
run_audit "1.0.0"
if [ "$RS_EXIT" = 0 ] && grep -q "inconsistent" "$RS_LOG"; then
  note "tag-without-release warns without failing" yes
else
  note "tag-without-release warns without failing" no
fi

# 3. Superseded signature: neither tag nor release -> fail with recovery.
merge_release release/1.2.0
run_audit "1.0.0 1.1.0"
if [ "$RS_EXIT" != 0 ] && grep -q "v1.2.0" "$RS_LOG" && grep -q "gh workflow run on-main.yml" "$WORK/summary"; then
  note "merged-but-never-deployed version fails with recovery command" yes
else
  note "merged-but-never-deployed version fails with recovery command" no
fi

# 4. Grace period: a fresh merge with nothing yet is skipped, not flagged.
FX_DATE="@$(date +%s) +0000"
export FX_DATE
merge_release release/1.3.0
unset FX_DATE
fx tag build/prod/1.2.0   # settle scenario 3 so only 1.3.0 is in question
run_audit "1.0.0 1.1.0 1.2.0"
if [ "$RS_EXIT" = 0 ] && grep -q "Skipping v1.3.0" "$RS_LOG"; then
  note "merge inside the 2h grace period is skipped" yes
else
  note "merge inside the 2h grace period is skipped" no
fi

# 5. Non-release merges (back-merge PRs etc.) are ignored entirely.
fx checkout -q -b feature-x
fx commit -q --allow-empty -m "feature work"
fx checkout -q main
fx merge -q --no-ff -m "Merge pull request #2 from avlon-technologies/feature-x" feature-x
run_audit "1.0.0 1.1.0 1.2.0"
check "non-release merge subjects are ignored" "$RS_EXIT" "0"

finish
