#!/usr/bin/env bash
# Tests for on-main.yml's backmerge job — the release back-merge PR step
# (gh stubbed) and the hotfix/support cherry-pick step (real git against a
# bare origin fixture, gh stubbed). Scripts extracted from the workflow
# YAML at test time.
set -euo pipefail
cd "$(dirname "$0")/../.."
source .github/scripts/test-lib.sh

BACKMERGE=$(extract_step .github/workflows/on-main.yml backmerge 'Open back-merge PR to develop (release)')
CHERRY=$(extract_step .github/workflows/on-main.yml backmerge 'Cherry-pick fix and open backport PR (hotfix/support)')

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
export STUB_GH_LOG="$WORK/gh.log"

cat > "$WORK/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "$1 $2" >> "$STUB_GH_LOG"
case "$1" in
  api)
    # branch-existence probe: repos/<repo>/branches/<branch>
    [ "${STUB_BRANCH_EXISTS:-true}" = true ] && exit 0 || exit 1 ;;
  pr)
    case "$2" in
      list) printf '%s\n' "${STUB_PR_OPEN:-}" ;;
      create)
        case "${STUB_CREATE:-ok}" in
          ok) echo "https://stub/pr/1" ;;
          no-commits) echo "pull request create failed: No commits between develop and whatever"; exit 1 ;;
          *) echo "GraphQL: workflow not permitted to create pull requests"; exit 1 ;;
        esac ;;
    esac ;;
esac
GHEOF
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

## Release back-merge PR step ------------------------------------------------
run_bm() { # env overrides; sets RS_EXIT/RS_LOG
  : > "$STUB_GH_LOG"
  RS_EXIT=0
  (export GH_TOKEN=s GITHUB_REPOSITORY=s/s VERSION=1.2.3 BRANCH=release/1.2.3 "$@"
   bash -e "$BACKMERGE") > "$WORK/log" 2>&1 || RS_EXIT=$?
  RS_LOG="$WORK/log"
}

run_bm STUB_BRANCH_EXISTS=false
if [ "$RS_EXIT" = 0 ] && ! grep -q "pr create" "$STUB_GH_LOG"; then
  note "deleted source branch: skips gracefully, no PR attempted" yes
else
  note "deleted source branch: skips gracefully, no PR attempted" no
fi

run_bm STUB_PR_OPEN=12
if [ "$RS_EXIT" = 0 ] && ! grep -q "pr create" "$STUB_GH_LOG"; then
  note "back-merge PR already open: skips" yes
else
  note "back-merge PR already open: skips" no
fi

run_bm
if [ "$RS_EXIT" = 0 ] && grep -q "pr create" "$STUB_GH_LOG"; then
  note "back-merge PR created" yes
else
  note "back-merge PR created" no
fi

run_bm STUB_CREATE=no-commits
check "'No commits between' treated as benign" "$RS_EXIT" "0"

run_bm STUB_CREATE=error
note "other PR-creation failures fail loudly (not masked as benign)" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"

## Hotfix/support cherry-pick step -------------------------------------------
# Fixture: bare origin holding develop + main, where main carries a hotfix
# merge whose diff develop may (or may not) already contain.
make_fixture() { # <name> <develop-mode: clean|contains|conflict> -> sets CLONE, MERGE_SHA
  local name="$1" mode="$2"
  local seed="$WORK/$name-seed"
  local origin="$WORK/$name-origin.git"
  git init -q --bare "$origin"
  git init -q -b main "$seed"
  (
    cd "$seed"
    git config user.email t@t && git config user.name t
    echo base > app.txt && git add app.txt && git commit -qm base
    git branch develop
    git checkout -qb hotfix/1.0.1
    echo fixed > app.txt && git add app.txt && git commit -qm "the fix"
    git checkout -q main
    git merge -q --no-ff -m "Merge pull request #7 from x/hotfix/1.0.1" hotfix/1.0.1
    case "$mode" in
      contains) git checkout -q develop && git cherry-pick -m 1 main > /dev/null ;;
      conflict) git checkout -q develop && echo diverged > app.txt && git add app.txt && git commit -qm diverged ;;
    esac
    git checkout -q main
    git remote add origin "$origin"
    git push -q origin main develop
  )
  MERGE_SHA=$(git -C "$seed" rev-parse main)
  CLONE="$WORK/$name-clone"
  git clone -q "$origin" "$CLONE"
}

run_cp() { # <clone> <merge-sha> <version> [env...]; sets RS_EXIT/RS_LOG
  : > "$STUB_GH_LOG"
  RS_EXIT=0
  local clone="$1" sha="$2" ver="$3"; shift 3
  (cd "$clone" && export GH_TOKEN=s GITHUB_REPOSITORY=s/s GITHUB_SHA="$sha" \
     VERSION="$ver" SOURCE_BRANCH=hotfix/1.0.1 "$@"
   bash -e "$CHERRY") > "$WORK/log" 2>&1 || RS_EXIT=$?
  RS_LOG="$WORK/log"
}

make_fixture clean clean
run_cp "$CLONE" "$MERGE_SHA" 1.0.1
if [ "$RS_EXIT" = 0 ] && grep -q "pr create" "$STUB_GH_LOG" \
   && git -C "$WORK/clean-origin.git" show-ref --verify -q refs/heads/backport/1.0.1; then
  note "clean cherry-pick: backport branch pushed and PR opened" yes
else
  note "clean cherry-pick: backport branch pushed and PR opened" no
fi

make_fixture contains contains
run_cp "$CLONE" "$MERGE_SHA" 1.0.2
if [ "$RS_EXIT" = 0 ] && grep -q "Nothing to backport" "$RS_LOG" && ! grep -q "pr create" "$STUB_GH_LOG"; then
  note "develop already contains the fix: skips gracefully" yes
else
  note "develop already contains the fix: skips gracefully" no
fi

make_fixture conflict conflict
run_cp "$CLONE" "$MERGE_SHA" 1.0.3
if [ "$RS_EXIT" != 0 ] && grep -q "conflicts" "$RS_LOG"; then
  note "conflicting cherry-pick fails with manual instructions" yes
else
  note "conflicting cherry-pick fails with manual instructions" no
fi

make_fixture skip clean
run_cp "$CLONE" "$MERGE_SHA" 1.0.4 STUB_PR_OPEN=9
if [ "$RS_EXIT" = 0 ] && ! grep -q "pr create" "$STUB_GH_LOG"; then
  note "backport PR already open: skips" yes
else
  note "backport PR already open: skips" no
fi

finish
