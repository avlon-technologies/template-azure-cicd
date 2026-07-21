#!/usr/bin/env bash
# Tests for every version/branch validation gate in the pipeline — the
# scripts are extracted from the workflow YAML at test time (see
# test-lib.sh), so this exercises the exact bash CI runs.
#
# Covered:
#   on-pr.yml            "Enforce release, hotfix, or support source"
#   on-release.yml       "Derive version from the commit"
#   _hotfix-support.yml  "Derive version from the commit"
#   on-main.yml          "Validate dispatch"
#   on-main.yml          "Extract version from merge commit"
set -euo pipefail
cd "$(dirname "$0")/../.."
source .github/scripts/test-lib.sh

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Fixture repo with 3 commits — the derive steps embed the commit height
# (git rev-list --count HEAD) in the label.
FIXTURE="$WORK/repo"
git init -q "$FIXTURE"
(
  cd "$FIXTURE"
  git config user.email t@t && git config user.name t
  for i in 1 2 3; do
    echo "$i" > f && git add f && git commit -qm "c$i"
  done
)

run_step() { # <script> [ENV=val ...]; sets RS_EXIT, RS_OUT (outputs file), RS_LOG
  local script="$1"; shift
  RS_OUT="$WORK/gh-out"
  : > "$RS_OUT"
  RS_EXIT=0
  (cd "$FIXTURE" && export GITHUB_OUTPUT="$RS_OUT" "$@" && bash -e "$script") > "$WORK/log" 2>&1 || RS_EXIT=$?
  RS_LOG="$WORK/log"
}

out_value() { grep "^${1}=" "$RS_OUT" | head -1 | cut -d= -f2-; }

## on-pr guard ---------------------------------------------------------------
GUARD=$(extract_step .github/workflows/on-pr.yml guard-main-source 'Enforce release, hotfix, or support source')

for ref in release/1.2.0 hotfix/1.2.3 support/9.9.9; do
  run_step "$GUARD" HEAD_REF="$ref"
  check "guard allows $ref" "$RS_EXIT" "0"
done
for ref in release/1.2 release/2.0.0-beta feature/foo milestone/demo develop; do
  run_step "$GUARD" HEAD_REF="$ref"
  note "guard rejects $ref" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"
done

## on-release derive ---------------------------------------------------------
DERIVE_REL=$(extract_step .github/workflows/on-release.yml prepare 'Derive version from the commit')

run_step "$DERIVE_REL" REF=release/1.2.0
check "release derive: label = version-build.height" "$(out_value value)" "1.2.0-build.3"
run_step "$DERIVE_REL" REF=milestone/demo
check "milestone derive: ms-name.height" "$(out_value value)" "ms-demo.3"
run_step "$DERIVE_REL" REF=release/1.2
note "release derive rejects non-X.Y.Z version" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"
run_step "$DERIVE_REL" REF=develop
note "release derive rejects non-release branch (dispatch selector trap)" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"
run_step "$DERIVE_REL" REF='milestone/bad_name'
note "milestone derive rejects label-unsafe characters" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"

## _hotfix-support derive ----------------------------------------------------
DERIVE_HF=$(extract_step .github/workflows/_hotfix-support.yml prepare 'Derive version from the commit')

run_step "$DERIVE_HF" REF=hotfix/1.2.3 BRANCH_TYPE=hotfix
check "hotfix derive: version-hotfix.height" "$(out_value value)" "1.2.3-hotfix.3"
run_step "$DERIVE_HF" REF=support/1.2.3 BRANCH_TYPE=support
check "support derive: version-patch.height" "$(out_value value)" "1.2.3-patch.3"
run_step "$DERIVE_HF" REF=hotfix/1.2 BRANCH_TYPE=hotfix
note "hotfix derive rejects non-X.Y.Z version" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"
run_step "$DERIVE_HF" REF=develop BRANCH_TYPE=hotfix
note "hotfix derive rejects wrong branch (dispatch selector trap)" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"

## on-main Validate dispatch -------------------------------------------------
VALIDATE=$(extract_step .github/workflows/on-main.yml prepare 'Validate dispatch')

run_step "$VALIDATE" REF=refs/heads/main INPUT_VERSION=1.5.0 REBUILD=false
check "dispatch from main with version allowed" "$RS_EXIT" "0"
run_step "$VALIDATE" REF=refs/heads/main INPUT_VERSION= REBUILD=true
check "dispatch rebuild-from-source escape hatch allowed" "$RS_EXIT" "0"
run_step "$VALIDATE" REF=refs/heads/release/1.5.0 INPUT_VERSION=1.5.0 REBUILD=false
note "dispatch from a non-main ref rejected" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"
run_step "$VALIDATE" REF=refs/heads/main INPUT_VERSION= REBUILD=false
note "version-less dispatch without rebuild flag rejected" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"

## on-main Extract version ---------------------------------------------------
EXTRACT=$(extract_step .github/workflows/on-main.yml prepare 'Extract version from merge commit')

run_step "$EXTRACT" EVENT=push INPUT_VERSION= \
  COMMIT_MESSAGE='Merge pull request #5 from avlon-technologies/release/1.23.0'
check "push: version parsed from release merge subject" "$(out_value value)" "1.23.0"
check "push: source branch captured" "$(out_value branch)" "release/1.23.0"

run_step "$EXTRACT" EVENT=push INPUT_VERSION= \
  COMMIT_MESSAGE='Merge pull request #9 from avlon-technologies/hotfix/1.23.1'
check "push: hotfix merge subject parsed" "$(out_value value)" "1.23.1"

run_step "$EXTRACT" EVENT=push INPUT_VERSION= \
  COMMIT_MESSAGE='Ship the new feature (#12)'
note "push: squash-style subject refused (no untested rebuild for prod)" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"

run_step "$EXTRACT" EVENT=workflow_dispatch INPUT_VERSION=1.5.0 COMMIT_MESSAGE=
check "rollback dispatch: released version accepted" "$(out_value value)" "1.5.0"
run_step "$EXTRACT" EVENT=workflow_dispatch INPUT_VERSION=v1.5.0 COMMIT_MESSAGE=
note "rollback dispatch: v-prefixed version rejected" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"
run_step "$EXTRACT" EVENT=workflow_dispatch INPUT_VERSION=1.5 COMMIT_MESSAGE=
note "rollback dispatch: two-part version rejected" "$([ "$RS_EXIT" != 0 ] && echo yes || echo no)"
run_step "$EXTRACT" EVENT=workflow_dispatch INPUT_VERSION= COMMIT_MESSAGE=
check "version-less rebuild dispatch: empty version passes through" "$(out_value value)" ""

finish
