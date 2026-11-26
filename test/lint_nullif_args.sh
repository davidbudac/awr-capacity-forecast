#!/usr/bin/env bash
# test/lint_nullif_args.sh -- no NULLIF over a function of a substitution
# variable. An omitted positional argument is the empty string, and
# TRIM('') / UPPER('') fold to the NULL literal, which NULLIF rejects as its
# first argument: NULLIF(TRIM('&1'), '-') raises ORA-00932 (19.27) exactly
# when the argument is left out. The report drivers ran that SELECT under
# TERMOUT OFF, so a lone top_n was ignored without a word. Write
# DECODE(TRIM('&1'), '-', NULL, TRIM('&1')). NULLIF('&1', '-'), the literal
# itself, is fine. Judged: every tracked *.sql, comments stripped, a NULLIF
# whose first argument is a function call with a quoted &name or ~name in it.
# Exit 1 and list the offending lines.
set -u
cd "$(dirname "$0")/.." || exit 2
. test/repo_files.sh
rc=0

while IFS= read -r f; do
  hits=$(awk '{ sub(/--.*$/, "") }
              toupper($0) ~ /NULLIF[[:space:]]*\([[:space:]]*[A-Z_]+[[:space:]]*\([^,]*\047[&~][A-Za-z0-9_]/ { print FNR ": " $0 }' "$f")
  if [ -n "$hits" ]; then
    echo "$hits" | sed "s|^|lint_nullif_args: $f: |"
    rc=1
  fi
done < <(repo_files '*.sql')

[ $rc = 0 ] && echo "lint_nullif_args: no NULLIF over a function of a substitution variable"
exit $rc
