#!/usr/bin/env bash
# test/lint_appinfo.sh -- every database session the suite opens is labelled,
# so V$SESSION / ASH / AWR attribute its work to MODULE 'AWRCAP/...':
#   * every runnable SQL*Plus script (each tracked *.sql except the included
#     ones: ddl/, ml/, repository/, report/sections/, report/html/,
#     report/defaults.sql, report/scope.sql, test/pga_probe.sql and the
#     generated apex/awrcap_app.sql) runs SET APPINFO OFF, then
#     SET APPINFO "AWRCAP/<its own path>";
#   * every procedure in the specs of CAP_RESULTS, CAP_FORECAST_ML and
#     CAP_REPO (build_model aside: it labels only ACTION, inside the train_*
#     MODULE) sets MODULE 'AWRCAP/<package>.<procedure>', and every procedure
#     install_jobs.sql creates (CAP_NIGHTLY, CAP_REPORT_SPOOL) 'AWRCAP/<name>';
#   * every scheduler job_action in install_jobs.sql sets CLIENT_IDENTIFIER
#     to its own job name.
# Exit 1 and list the offenders on a violation.
set -u
cd "$(dirname "$0")/.." || exit 2
rc=0
fail() { echo "lint_appinfo: $*"; rc=1; }

while IFS= read -r f; do
  case "$f" in
    ddl/*|ml/*|repository/*|report/sections/*|report/html/*) continue;;
    report/defaults.sql|report/scope.sql|test/pga_probe.sql|apex/awrcap_app.sql) continue;;
  esac
  grep -qiE '^set appinfo off$' "$f" || fail "$f has no SET APPINFO OFF"
  grep -qiF "set appinfo \"AWRCAP/$f\"" "$f" || fail "$f does not SET APPINFO \"AWRCAP/$f\""
done < <(git ls-files '*.sql')

# spec_procs <file> <package>: the PROCEDURE names declared in its spec.
spec_procs() {
  awk -v pkg="$2" '
    toupper($0) ~ "^CREATE OR REPLACE PACKAGE " toupper(pkg) "( |$)" { on = 1; next }
    on && toupper($0) ~ "^END " toupper(pkg) ";" { on = 0 }
    on && match($0, /^[ \t]*PROCEDURE[ \t]+[a-z_]+/) {
      s = substr($0, RSTART, RLENGTH); sub(/^[ \t]*PROCEDURE[ \t]+/, "", s); print tolower(s)
    }' "$1"
}
check_pkg() {   # <spec file> <body file> <package>
  local procs p
  procs=$(spec_procs "$1" "$3")
  [ -n "$procs" ] || fail "$1: no procedures found in the spec of $3"
  for p in $procs; do
    [ "$3.$p" = cap_forecast_ml.build_model ] && continue
    grep -qF "SET_MODULE('AWRCAP/$3.$p'" "$2" || fail "$2: $3.$p does not set MODULE 'AWRCAP/$3.$p'"
  done
}
check_pkg ddl/60_results.sql        ddl/60_results.sql        cap_results
check_pkg ml/cap_forecast_ml.pks    ml/cap_forecast_ml.pkb    cap_forecast_ml
check_pkg repository/cap_repo.sql   repository/cap_repo.sql   cap_repo
procs=$(sed -n 's/^CREATE OR REPLACE PROCEDURE \([a-z_]*\).*/\1/p' install_jobs.sql)
[ -n "$procs" ] || fail "install_jobs.sql creates no procedure?"
for p in $procs; do
  grep -qF "SET_MODULE('AWRCAP/$p'" install_jobs.sql \
    || fail "install_jobs.sql: $p does not set MODULE 'AWRCAP/$p'"
done

awk '
  /DBMS_SCHEDULER\.CREATE_JOB\(/ { name = ""; n++ }
  match($0, /job_name[ \t]*=>[ \t]*'\''[A-Z_]+'\''/) {
    name = substr($0, RSTART, RLENGTH); sub(/.*=>[ \t]*'\''/, "", name); sub(/'\''$/, "", name)
  }
  /job_action[ \t]*=>/ {
    if (index($0, "DBMS_SESSION.SET_IDENTIFIER('\'''\''" name "'\'''\'')") == 0) {
      printf "lint_appinfo: install_jobs.sql:%d job %s does not SET_IDENTIFIER to its name\n", NR, name; bad = 1
    }
  }
  END { if (n == 0) { print "lint_appinfo: install_jobs.sql creates no job?"; bad = 1 } exit bad }
' install_jobs.sql || rc=1

exit $rc
