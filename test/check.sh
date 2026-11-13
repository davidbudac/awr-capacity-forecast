#!/usr/bin/env bash
# test/check.sh -- every check that needs no database, in one run.
#
#   test/check.sh [-v] [NAME...]
#
#   -v      print the output of the passing checks too
#   NAME    run only the checks whose name contains NAME (lint_, docs, ...)
#
# One line per check, "OK   <name>" or "FAIL <name>", and under a FAIL the
# whole output of that check. Exit 1 when any check failed, 2 on a usage
# error or when NAME selects nothing. Runs from any directory. Needs bash,
# git, python3 and node (test/report_html_test.sh).
#
# The checks: the generated-file checks (repository/build.py --check,
# report/html/build.py --check, apex/build.py --check), the structure check
# of the APEX export (apex/test/export_check.py), every test/lint_*.sh (found
# by name, so a new lint joins by existing), test/docs_lint.sh and the offline tests
# test/run_report_sh_test.sh, test/report_html_test.sh,
# test/notify_sh_test.sh and test/oem_test.sh. The tests are a list, not
# test/*_test.sh: a test of that name may need a database, and one picked up
# by name would fail every run without one. A new offline test joins
# OFFLINE_TESTS below.
# test/dbmint_harness.sh and the GitHub workflow .github/workflows/check.yml
# both run this script.
set -u
cd "$(dirname "$0")/.." || exit 2

VERBOSE=0; ONLY=()
while [ $# -gt 0 ]; do
  case "$1" in
    -v) VERBOSE=1;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*) echo "check.sh: unknown option $1" >&2; exit 2;;
    *) ONLY+=("$1");;
  esac; shift
done

CHECKS=("repository/build.py --check" "report/html/build.py --check"
        "apex/build.py --check" "apex/test/export_check.py")
for f in test/lint_*.sh; do [ -f "$f" ] && CHECKS+=("$f"); done
OFFLINE_TESTS=(test/run_report_sh_test.sh test/report_html_test.sh
               test/notify_sh_test.sh test/oem_test.sh)
CHECKS+=(test/docs_lint.sh "${OFFLINE_TESTS[@]}")

wanted() {
  local o
  [ ${#ONLY[@]} -eq 0 ] && return 0
  for o in "${ONLY[@]}"; do case "$1" in *"$o"*) return 0;; esac; done
  return 1
}

ran=0; failed=0
for c in "${CHECKS[@]}"; do
  wanted "$c" || continue
  ran=$((ran + 1))
  # $c is a path plus its arguments: word splitting is wanted here.
  case "$c" in
    *.py*) out=$(python3 $c 2>&1); rc=$?;;
    *)     out=$(bash $c 2>&1); rc=$?;;
  esac
  if [ $rc -eq 0 ]; then
    echo "OK   $c"
    [ $VERBOSE = 1 ] && [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/     /'
  else
    echo "FAIL $c (exit $rc)"
    printf '%s\n' "$out" | sed 's/^/     /'
    failed=$((failed + 1))
  fi
done

if [ $ran -eq 0 ]; then
  echo "check.sh: no check matches: ${ONLY[*]}" >&2; exit 2
fi
if [ $failed -eq 0 ]; then
  echo "check.sh: $ran checks, all passed"
else
  echo "check.sh: $ran checks, $failed FAILED"
fi
[ $failed -eq 0 ]
