#!/usr/bin/env bash
# Shared provenance check for the artifact reuse/promotion paths — the
# promotion pipeline's core security control, defined once and sourced by
# on-main.yml, on-release.yml, and _hotfix-support.yml.
#
# Artifact *names* (webapp-<sha>) are forgeable: any workflow in the repo
# can upload one. This function walks the unexpired artifacts carrying a
# name, newest first, and returns the first one whose producing workflow
# run is trusted — a listed workflow path, building exactly the expected
# commit, triggered by push or workflow_dispatch. Everything else is
# rejected with a ::warning:: naming the offending run.
#
# The trusted-workflow list is passed by each caller and deliberately
# lives in reviewed workflow code (never a repo variable — that would move
# the trust anchor into a mutable setting). Keep the lists in sync with
# entry-workflow renames: see docs/customization.md §2.
#
# Usage (sourced; requires gh, GH_TOKEN, GITHUB_REPOSITORY):
#   source .github/scripts/find-verified-artifact.sh
#   find_verified_artifact <artifact-name> <expected-sha> "<trusted-path> [<trusted-path> ...]"
#
# Results (shell variables):
#   FVA_RUN_ID           producing run of the newest verified artifact; '' if none verified
#   FVA_ARTIFACTS_FOUND  'true' if any unexpired artifact carried the name at all
#
# Tests: .github/scripts/find-verified-artifact.test.sh (run on every PR
# by the "Test workflow scripts" job in on-pr.yml).

find_verified_artifact() {
  local name="$1" expected_sha="$2" trusted="$3"
  local candidate run_path run_event run_sha w is_trusted
  FVA_RUN_ID=""
  FVA_ARTIFACTS_FOUND=false
  for candidate in $(gh api "repos/$GITHUB_REPOSITORY/actions/artifacts?name=$name" \
    --jq '[.artifacts[] | select(.expired == false)] | sort_by(.created_at) | reverse | .[].workflow_run.id'); do
    FVA_ARTIFACTS_FOUND=true
    if ! read -r run_path run_event run_sha < <(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$candidate" \
      --jq '"\(.path) \(.event) \(.head_sha)"'); then
      echo "::warning::Could not resolve the run that produced artifact $name (run $candidate) — treating it as unverified."
      continue
    fi
    is_trusted=false
    for w in $trusted; do
      if [ "$run_path" = "$w" ]; then
        is_trusted=true
        break
      fi
    done
    if [ "$is_trusted" != "true" ]; then
      echo "::warning::Ignoring artifact $name from run $candidate — produced by untrusted workflow '$run_path'."
      continue
    fi
    if [ "$run_sha" != "$expected_sha" ]; then
      echo "::warning::Ignoring artifact $name from run $candidate — built from $run_sha, not $expected_sha."
      continue
    fi
    if [ "$run_event" != "push" ] && [ "$run_event" != "workflow_dispatch" ]; then
      echo "::warning::Ignoring artifact $name from run $candidate — unexpected trigger '$run_event'."
      continue
    fi
    FVA_RUN_ID="$candidate"
    break
  done
}
