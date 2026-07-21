#!/usr/bin/env bash
# Marker artifacts encode values in their *names* — <artifact>.label.<label>
# (from _build.yml) and <artifact>.image.<digest-hex> (from _image.yml) — so
# the promotion paths can read them from a provenance-verified run without
# downloading anything. This helper finds a marker's value by prefix in a
# pre-fetched, newline-separated artifact-name list: fetch the run's list
# ONCE and reuse it for every marker.
#
# Usage (sourced):
#   source .github/scripts/run-markers.sh
#   NAMES=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$RUN_ID/artifacts?per_page=100" \
#     --jq '.artifacts[].name')
#   LABEL=$(marker_value "$NAMES" "webapp-$SHA.label.") || LABEL=""
#
# Returns 1 (empty output) when no marker matches; a marker with an empty
# value (nothing after the prefix) is treated as absent.
#
# Tests: .github/scripts/run-markers.test.sh (run on every PR by the
# "Test workflow scripts" job in on-pr.yml).

marker_value() {
  local names="$1" prefix="$2" n
  while IFS= read -r n; do
    case "$n" in
      "$prefix"?*)
        printf '%s' "${n#"$prefix"}"
        return 0
        ;;
    esac
  done <<< "$names"
  return 1
}
