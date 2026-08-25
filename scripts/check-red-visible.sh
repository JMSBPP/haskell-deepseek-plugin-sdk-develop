#!/usr/bin/env bash
# Assert the conformance suite's red state is visible and that nothing flipped
# green unnoticed. Reads a captured tasty log rather than running the suite, so
# CI keeps one build of the test binary.
#
#   stack test 2>&1 | tee conformance.log
#   scripts/check-red-visible.sh conformance.log
set -euo pipefail

log=${1:?usage: check-red-visible.sh <tasty-output-log>}

if ! grep -q 'FAIL (expected:' "$log"; then
  echo "check-red-visible: no 'FAIL (expected:' line — the red state is invisible" >&2
  exit 1
fi

if grep -q 'OK (unexpected:' "$log"; then
  echo "check-red-visible: 'OK (unexpected:' — a scenario flipped green; delete its EXPECTED.md" >&2
  exit 1
fi

echo "check-red-visible: red state visible ($(grep -c 'FAIL (expected:' "$log") expected failures), no unexpected passes"
