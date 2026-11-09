#!/usr/bin/env bash
# test/lint_dba_hist.sh -- AWR is read in one place (M25): only code under
# repository/ (the seam template, the manifest and cap_repo's probes),
# target/ (the reader's grants and checks), standalone/ (the no-install
# queries), test/ and bench/ names a
# DBA_HIST_* view, plus ddl/13_seam_repository.sql, which repository/build.py
# generates and whose CAP_REPO_SOURCE holds the pull statements. Everything
# else reads the CAPV_* seam. Comments do not count (SQL "--", shell and
# Python "#" lines), nor do the prose files (*.md, *.html, docs/).
# Exit 1 and list the offending lines.
set -u
cd "$(dirname "$0")/.." || exit 2
rc=0

while IFS= read -r f; do
  case "$f" in
    repository/*|target/*|standalone/*|test/*|bench/*|docs/*|*.md|*.html) continue;;
    ddl/13_seam_repository.sql) continue;;
  esac
  case "$f" in
    *.sql) hits=$(awk '{ sub(/--.*$/, "") } tolower($0) ~ /dba_hist_[a-z]/ { print FNR ": " $0 }' "$f") ;;
    *.sh|*.py) hits=$(awk '!/^[[:space:]]*#/ && tolower($0) ~ /dba_hist_[a-z]/ { print FNR ": " $0 }' "$f") ;;
    *) continue;;
  esac
  if [ -n "$hits" ]; then
    echo "$hits" | sed "s|^|lint_dba_hist: $f: |"
    rc=1
  fi
done < <(git ls-files '*.sql' '*.sh' '*.py')

[ $rc = 0 ] && echo "lint_dba_hist: no DBA_HIST_* read outside repository/, target/, standalone/, test/, bench/"
exit $rc
