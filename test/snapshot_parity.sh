#!/usr/bin/env bash
# test/snapshot_parity.sh <SCHEMA> [--no-sync] -- LIVE and SNAPSHOT reports
# must say the same thing (M24.13). On dbmint, in PDB1 as SYSDBA with
# CURRENT_SCHEMA = <SCHEMA> (a fixture install, e.g. after
# test/dbmint_harness.sh <SCHEMA>):
#   1. cap_results.reset, then one timed cap_results.refresh, so the alert
#      states equal the live alerts (no acks, no resolve grace). It deletes
#      the schema's run history: use a throwaway schema.
#   2. report.sql and report_csv.sql, LIVE then SNAPSHOT, unscoped and scoped
#      to dbid 42424242. The text spools must match once the Generated /
#      Source header lines and the TIMING lines are dropped; the CSV
#      directories must match file for file.
#   3. report_html.sql and report_brief.sql, LIVE then SNAPSHOT, unscoped:
#      the HTML data block must match without its source / generated /
#      file / run / seconds fields, the briefing without its generated line
#      and file name.
#      The unscoped runs pass top_n 12: LIVE as the only argument
#      (@report/report.sql 12), SNAPSHOT with '-' for the arguments between.
#      Both spools must say "top 12" and the HTML data "topN":12, so an
#      argument list with omitted arguments is honoured (a lone top_n was
#      once ignored: test/lint_nullif_args.sh).
#   4. Every SQL statement the SNAPSHOT runs executed (V$SQL by MODULE
#      AWRCAP/report/%, active since the first SNAPSHOT run) and the objects
#      in its plan: none may read a CAP_FIXTURE_* seam source except
#      report/scope.sql's identity lookups (CAPV_TARGET, CAPV_CONTAINER,
#      CAPR_CONTAINER, CAPR_FRESHNESS).
# Prints per run: wall seconds and the session's peak PGA. Log:
# /tmp/snapshot_parity_<SCHEMA>.log. Exit 1 on a difference or a forbidden
# read, 3 on an ssh / sync failure.
set -u
SCHEMA=${1:?schema}; shift
SYNC=1; REMOTE_MODE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-sync) SYNC=0;;
    --remote) REMOTE_MODE=1;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac; shift
done
REMOTE=awr_cap_$(echo "$SCHEMA" | tr 'A-Z' 'a-z')

if [ $REMOTE_MODE = 0 ]; then
  HERE=$(cd "$(dirname "$0")/.." && pwd)
  LOG=/tmp/snapshot_parity_${SCHEMA}.log
  if [ $SYNC = 1 ]; then
    rsync -az --delete -e 'ssh -p 2200' \
      --exclude .git --exclude .claude --exclude reports --exclude '__pycache__' \
      --exclude grafana/.ords.env --exclude grafana/ords/config --exclude grafana/.env \
      "$HERE"/ oracle@dbmint:~/"$REMOTE"/ || exit 3
  fi
  ssh -p 2200 oracle@dbmint "bash ~/$REMOTE/test/snapshot_parity.sh $SCHEMA --remote" > "$LOG" 2>&1
  rc=$?
  grep -E '^(TIME|PGA|DIFF|SAME|FORBIDDEN|READS|RESULT|ERROR)' "$LOG"
  echo "log: $LOG  (exit $rc)"
  exit $rc
fi

export ORACLE_SID=cdb1; export ORAENV_ASK=NO; . oraenv >/dev/null 2>&1
cd ~/"$REMOTE" || exit 3
OUT=/tmp/snapshot_parity_$SCHEMA
rm -rf "$OUT"; mkdir -p "$OUT"
rc=0

# sq <label>: runs stdin in one SYSDBA session on the schema, then prints
# TIME <label> <ms> and PGA <label> <MB>; the session output goes to
# $OUT/<label>.out.
sq() {
  local t0 t1
  t0=$(date +%s%N)
  { sqlplus -S -L / as sysdba <<SQL
ALTER SESSION SET CONTAINER = PDB1;
ALTER SESSION SET CURRENT_SCHEMA = $SCHEMA;
$(cat)
SET TERMOUT ON HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT 'PGA_MAX_MB ' || ROUND(m.value / 1048576, 1) FROM v\$mystat m JOIN v\$statname n
    ON n.statistic# = m.statistic# WHERE n.name = 'session pga memory max';
EXIT
SQL
  } > "$OUT/$1.out" 2>&1
  t1=$(date +%s%N)
  echo "TIME $1 $(( (t1 - t0) / 1000000 )) ms"
  echo "PGA  $1 $(sed -n 's/^PGA_MAX_MB //p' "$OUT/$1.out" | tail -1) MB"
  if grep -q -E '^(ORA|SP2)-[0-9]{4,5}' "$OUT/$1.out"; then
    echo "ERROR $1: $(grep -E '^(ORA|SP2)-[0-9]{4,5}' "$OUT/$1.out" | head -3 | tr '\n' ' ')"
    rc=1
  fi
}
# written <label> <marker>: the path the driver printed after the marker.
written() { sed -n "s/^$2 *//p" "$OUT/$1.out" | tail -1; }

sq reset <<'SQL'
EXEC cap_results.reset
SQL
sq refresh <<'SQL'
EXEC cap_results.refresh
SQL

db_now() {
  sqlplus -S -L / as sysdba <<'SQL' | sed -n 's/^NOW //p'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT 'NOW ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS') FROM dual;
EXIT
SQL
}

# top_args <LIVE|SNAPSHOT>: the unscoped argument list. LIVE passes top_n
# alone, the form that leaves every later argument empty.
TOPN=12
top_args() { if [ "$1" = LIVE ]; then echo "$TOPN"; else echo "$TOPN - - - - $1"; fi; }

for src in LIVE SNAPSHOT; do
  # V$SQL.LAST_ACTIVE_TIME has whole seconds: keep the LIVE runs' last
  # cursors out of the SNAPSHOT window.
  [ $src = SNAPSHOT ] && { sleep 2; T0=$(db_now); sleep 1; }
  for scope in - 42424242; do
    tag=$(echo "$scope" | tr -d -)
    l=text_${src}_${tag:-all}
    args="- - - $scope - $src"
    [ "$scope" = - ] && args=$(top_args $src)
    sq "$l" <<SQL
DEFINE timing = Y
@report/report.sql $args
SQL
    f=$(written "$l" 'Report written to:')
    if [ -n "$f" ] && [ -f "$f" ]; then mv "$f" "$OUT/$l.txt"; else echo "ERROR $l: no spool"; rc=1; fi
    l=csv_${src}_${tag:-all}
    sq "$l" <<SQL
@report/report_csv.sql $scope - $src
SQL
    d=$(written "$l" 'CSV written to:')
    if [ -n "$d" ] && [ -d "$d" ]; then mv "$d" "$OUT/$l"; else echo "ERROR $l: no CSV directory"; rc=1; fi
  done
  for drv in html brief; do
    l=${drv}_${src}_all
    f=report/report_html.sql; [ $drv = brief ] && f=report/report_brief.sql
    sq "$l" <<SQL
@$f $(top_args $src)
SQL
    p=$(written "$l" 'Report written to:')
    if [ -n "$p" ] && [ -f "$p" ]; then
      mv "$p" "$OUT/$l.html"
      if grep -q -E '^(ORA|SP2)-[0-9]{4,5}' "$OUT/$l.html"; then echo "ERROR $l: ORA- in the spool"; rc=1; fi
    else
      echo "ERROR $l: no spool"; rc=1
    fi
  done
done

for src in LIVE SNAPSHOT; do
  if grep -q "top $TOPN) ==" "$OUT/text_${src}_all.txt" 2>/dev/null \
     && grep -q "\"topN\":$TOPN," "$OUT/html_${src}_all.html" 2>/dev/null; then
    echo "SAME args $src: top_n $TOPN in the text and HTML reports ($(top_args $src))"
  else
    echo "DIFF args $src: top_n $TOPN not honoured by report.sql or report_html.sql ($(top_args $src))"; rc=1
  fi
done

strip() { grep -v -E '^ *(Generated|Source) *:|^timing for:|^Elapsed:' "$1"; }
for tag in all 42424242; do
  if diff <(strip "$OUT/text_LIVE_$tag.txt") <(strip "$OUT/text_SNAPSHOT_$tag.txt") > "$OUT/text_$tag.diff"; then
    echo "SAME text $tag ($(strip "$OUT/text_LIVE_$tag.txt" | wc -l) lines)"
  else
    echo "DIFF text $tag: $(wc -l < "$OUT/text_$tag.diff") diff lines, $OUT/text_$tag.diff"; rc=1
    head -40 "$OUT/text_$tag.diff"
  fi
  if diff -r "$OUT/csv_LIVE_$tag" "$OUT/csv_SNAPSHOT_$tag" > "$OUT/csv_$tag.diff"; then
    echo "SAME csv $tag ($(cat "$OUT/csv_LIVE_$tag"/*.csv | wc -l) lines in $(ls "$OUT/csv_LIVE_$tag" | wc -l) files)"
  else
    echo "DIFF csv $tag: $OUT/csv_$tag.diff"; rc=1
    head -40 "$OUT/csv_$tag.diff"
  fi
done

# The HTML data block minus its source, generation, file, run and timing
# fields; the briefing minus its generated line and file name.
norm_html() {
  sed -n '/id="cap-data"/,/<\/script>/p' "$1" \
    | sed -E 's/"seconds":\{[^}]*\}//; s/"(source|generated|file|run)":"[^"]*"//g'
}
norm_brief() { grep -v '<p class="gen">' "$1" | sed -E 's/Written to [^ <]*\.html//'; }
for drv in html brief; do
  if diff <(norm_$drv "$OUT/${drv}_LIVE_all.html") <(norm_$drv "$OUT/${drv}_SNAPSHOT_all.html") > "$OUT/$drv.diff"; then
    echo "SAME $drv all ($(norm_$drv "$OUT/${drv}_LIVE_all.html" | wc -l) lines)"
  else
    echo "DIFF $drv all: $OUT/$drv.diff"; rc=1
    head -20 "$OUT/$drv.diff"
  fi
done

sqlplus -S -L / as sysdba > "$OUT/reads.out" 2>&1 <<SQL
ALTER SESSION SET CONTAINER = PDB1;
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 300 TRIMSPOOL ON
SELECT DISTINCT 'READS ' || CASE WHEN p.object_name LIKE 'CAP\_FIXTURE\_%' ESCAPE '\'
                                  AND NOT REGEXP_LIKE(LOWER(s.sql_fulltext), 'capv_target|capv_container|capr_freshness|capr_container([^_]|$)')
                                 THEN 'FORBIDDEN ' END
       || p.object_owner || '.' || p.object_name || ' (' || s.module || ')'
FROM   v\$sql s
JOIN   v\$sql_plan p ON p.sql_id = s.sql_id AND p.child_number = s.child_number
WHERE  s.module LIKE 'AWRCAP/report/%'
  AND  s.last_active_time >= TO_DATE('$T0', 'YYYY-MM-DD HH24:MI:SS')
  AND  p.object_owner = '$SCHEMA'
  AND  UPPER(s.sql_fulltext) NOT LIKE '%V\$SQL%'
ORDER  BY 1;
EXIT
SQL
grep '^READS' "$OUT/reads.out"
if grep -q '^READS FORBIDDEN' "$OUT/reads.out"; then
  echo "FORBIDDEN: a SNAPSHOT run read a seam source outside report/scope.sql"; rc=1
fi
echo "RESULT: snapshot parity $([ $rc = 0 ] && echo passed || echo FAILED), files in $OUT"
exit $rc
