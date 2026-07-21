#!/usr/bin/env bash
# Shared plumbing for the workflow-script test suites (*.test.sh).
#
# The core idea: workflows under test are NOT copied into tests. extract_step
# pulls a step's `run:` script out of the workflow YAML at test time, so the
# suites always exercise the exact bash that runs in CI — coverage cannot
# drift from the real code.
#
# Provides:
#   PY               — a python interpreter that has pyyaml (probed by
#                      executing, because Windows ships store-alias stubs)
#   extract_step <workflow-file> <job-id> <step-name>
#                    — writes the step's run script to a temp file, prints
#                      its path
#   check <desc> <actual> <expected>       — string equality assertion
#   note <desc> <yes|no>                   — boolean assertion
#   finish                                 — prints totals, exits non-zero
#                                            on any failure

PY=""
for _c in python3 python py; do
  if "$_c" -c 'import yaml' > /dev/null 2>&1; then
    PY=$_c
    break
  fi
done
if [ -z "$PY" ]; then
  echo "FATAL: no python with pyyaml found — cannot extract workflow steps." >&2
  exit 1
fi

extract_step() { # <workflow-file> <job-id> <step-name>
  local out
  out=$(mktemp)
  "$PY" - "$1" "$2" "$3" > "$out" <<'PYEOF'
import sys, yaml
# Workflow scripts contain non-cp1252 characters (arrows in error
# messages); without this, Windows consoles silently truncate the
# extracted script at the first one.
sys.stdout.reconfigure(encoding='utf-8')
wf_path, job, step = sys.argv[1:4]
wf = yaml.safe_load(open(wf_path, encoding='utf-8'))
for s in wf['jobs'][job]['steps']:
    if s.get('name') == step:
        sys.stdout.write(s['run'])
        break
else:
    sys.exit(f"step not found: {wf_path} -> {job} -> {step}")
PYEOF
  printf '%s' "$out"
}

PASS=0
FAIL=0

check() { # <description> <actual> <expected>
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $1 (got '$2', want '$3')"
    FAIL=$((FAIL + 1))
  fi
}

note() { # <description> <yes|no>
  if [ "$2" = yes ]; then
    echo "ok: $1"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $1"
    FAIL=$((FAIL + 1))
  fi
}

finish() {
  echo "$PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
