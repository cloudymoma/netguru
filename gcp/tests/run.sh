#!/usr/bin/env bash
# Plain-bash unit tests for netguru's pure helpers. Usage: gcp/tests/run.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=../lib.sh
. gcp/lib.sh
set +e # assertions below handle failures themselves

PASS=0
FAIL=0
_fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }
expect_ok() {
  local desc=$1; shift
  if ("$@") >/dev/null 2>&1; then PASS=$((PASS + 1)); else _fail "${desc} (expected success)"; fi
}
expect_fail() {
  local desc=$1; shift
  if ("$@") >/dev/null 2>&1; then _fail "${desc} (expected failure)"; else PASS=$((PASS + 1)); fi
}
expect_eq() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); else _fail "$1"$'\n'"  expected: [$3]"$'\n'"  actual:   [$2]"; fi
}
# vm_fn SCRIPT FN ARGS... — call a function from a VM-side script without running its main.
vm_fn() {
  local script=$1; shift
  (
    # shellcheck disable=SC2034 # read by the sourced script
    NETGURU_SOURCE_ONLY=1
    # shellcheck disable=SC1090
    . "$script"
    "$@"
  )
}
# shellcheck disable=SC2034 # used by the sourced test_*.sh files
FIXTURES=gcp/tests/fixtures

for t in gcp/tests/test_*.sh; do
  # shellcheck disable=SC1090
  . "$t"
done
echo "passed=${PASS} failed=${FAIL}"
((FAIL == 0))
