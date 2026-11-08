#!/usr/bin/env bash
# test/dbmint_scale.sh -- how a repository's nightly work grows with its fleet
# (M24.10). Syncs this checkout to the dbmint VM, gives a repository-mode
# schema in PDB1 K synthetic targets and times the nightly steps, each in its
# own SYSDBA + CURRENT_SCHEMA session ended by test/pga_probe.sql.
#
#   test/dbmint_scale.sh <SCHEMA> <K> [--days N] [--source S] [--install]
#                        [--reload] [--no-ml] [--steps a,b]
#
#   <SCHEMA>    the scale schema (CAPX3): a repository install that holds only
#               synthetic targets, so its numbers are K targets exactly
#   <K>         targets SCALE01..SCALEnn (dbid 3000000000 + n); missing ones
#               are added and higher-numbered ones removed, so a run at a
#               larger K only loads the difference
#   --days N    history per target, at least N days (default 120: the 90-day
#               training window plus the 28-day backtest holdout)
#   --source S  repository schema whose collected target is cloned (CAPX2)
#   --install   first install deploy_mode = repository into SCHEMA
#   --reload    remove every SCALE target first (after a --days change)
#   --no-ml     skip cap_forecast_ml.train_all
#   --steps L   run only these steps (comma list of the labels below)
#
# Steps in nightly order (install_jobs.sql: retrain, refresh, reports):
# train_all, refresh (cap_results.refresh), report_fleet / report_one
# (report.sql for the fleet and for SCALE01), html_fleet / html_one
# (report_html.sql the same), report_snap / html_snap (the fleet reports in
# SNAPSHOT mode: alerts and fits from the refresh just run). Appends one line per step to
# /tmp/dbmint_scale_<SCHEMA>.tsv (utc, K, days, step, seconds, peak PGA MB);
# the full output is in /tmp/dbmint_scale_<SCHEMA>.log.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCHEMA=${1:?schema}; K=${2:?K}; shift 2
DAYS=120; SRC=CAPX2; INSTALL=0; RELOAD=0; ML=1; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --days) shift; DAYS=$1;;
    --source) shift; SRC=$1;;
    --install) INSTALL=1;;
    --reload) RELOAD=1;;
    --no-ml) ML=0;;
    --steps) shift; ONLY=",$1,";;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac; shift
done
REMOTE=awr_cap_$(echo "$SCHEMA" | tr 'A-Z' 'a-z')
SSH="ssh -p 2200 oracle@dbmint"
LOG=/tmp/dbmint_scale_${SCHEMA}.log
TSV=/tmp/dbmint_scale_${SCHEMA}.tsv

python3 "$HERE"/repository/build.py --check || { echo "generated seam stale: not syncing"; exit 4; }
rsync -az --delete -e 'ssh -p 2200' \
  --exclude .git --exclude .claude --exclude reports --exclude '__pycache__' \
  --exclude grafana/.ords.env --exclude grafana/ords/config --exclude grafana/.env \
  "$HERE"/ oracle@dbmint:~/"$REMOTE"/ || exit 3

run() {   # run <label> <SQL*Plus lines>: one session, exit status of sqlplus
  echo "### $1" >> "$LOG"
  $SSH 'bash -s' <<REMOTE_EOF >> "$LOG" 2>&1
export ORACLE_SID=cdb1; export ORAENV_ASK=NO; . oraenv >/dev/null 2>&1
cd ~/$REMOTE && sqlplus -S -L / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT FAILURE
ALTER SESSION SET CONTAINER = PDB1;
ALTER SESSION SET CURRENT_SCHEMA = $SCHEMA;
SET SERVEROUTPUT ON SIZE UNLIMITED
$2
EXIT
SQL
REMOTE_EOF
}
fail() { echo "### $1 failed, see $LOG"; tail -20 "$LOG"; exit 1; }

: > "$LOG"
if [ $INSTALL = 1 ]; then
  run install "DEFINE deploy_mode = repository
@install.sql" || fail install
fi

purge="EXEC NULL"
[ $RELOAD = 1 ] && purge="BEGIN
  FOR r IN (SELECT target_name FROM cap_target WHERE target_name LIKE 'SCALE%') LOOP
    cap_repo.remove_target(r.target_name);
  END LOOP;
END;
/"
run trim "$purge
BEGIN
  FOR r IN (SELECT target_name FROM cap_target
            WHERE  REGEXP_LIKE(target_name, '^SCALE[0-9]+\$')
              AND  TO_NUMBER(SUBSTR(target_name, 6)) > $K) LOOP
    cap_repo.remove_target(r.target_name);
  END LOOP;
END;
/
SET HEADING OFF FEEDBACK OFF
SELECT 'HAVE ' || target_name FROM cap_target WHERE target_name LIKE 'SCALE%';" || fail trim
have=$(sed -n 's/^HAVE //p' "$LOG")

load=""
for n in $(seq 1 "$K"); do
  name=$(printf 'SCALE%02d' "$n")
  grep -qx "$name" <<<"$have" || load+="@test/repo_synth_target.sql $name $((3000000000 + n)) 0 $DAYS $SRC
"
done
if [ -n "$load" ]; then
  t0=$(date +%s)
  run load "$load
EXEC DBMS_STATS.GATHER_SCHEMA_STATS('$SCHEMA')" || fail load
  echo "### loaded $(grep -c . <<<"$load") target(s) + stats in $(( $(date +%s) - t0 )) s" | tee -a "$LOG"
fi
run size "SET HEADING OFF FEEDBACK OFF
SELECT 'SIZE ' || (SELECT COUNT(*) FROM cap_target) || ' targets, '
       || (SELECT COUNT(*) FROM cap_h_snapshot) || ' snapshots, '
       || (SELECT ROUND(SUM(bytes) / 1048576) FROM dba_segments
           WHERE owner = '$SCHEMA' AND segment_name LIKE 'CAP\_H\_%' ESCAPE '\\') || ' MB of copies'
FROM dual;" || fail size
sed -n 's/^SIZE /### /p' "$LOG" | tail -1

STEPS=()
[ $ML = 1 ] && STEPS+=("train_all|EXEC cap_forecast_ml.train_all")
STEPS+=("refresh|EXEC cap_results.refresh"
        "report_fleet|@report/report.sql"
        "report_one|@report/report.sql - - - SCALE01"
        "html_fleet|@report/report_html.sql"
        "html_one|@report/report_html.sql - - - SCALE01"
        "report_snap|@report/report.sql - - - - - SNAPSHOT"
        "html_snap|@report/report_html.sql - - - - - SNAPSHOT")
for s in "${STEPS[@]}"; do
  label=${s%%|*}
  [ -n "$ONLY" ] && [[ $ONLY != *",$label,"* ]] && continue
  t0=$(date +%s)
  run "$label" "${s#*|}
@test/pga_probe.sql" || fail "$label"
  sec=$(( $(date +%s) - t0 ))
  pga=$(awk '/^### /{l=$2} l=="'"$label"'" && /session pga memory max/{v=$(NF-1)} END{gsub(",","",v); print v}' "$LOG")
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$K" "$DAYS" "$label" "$sec" "$pga" | tee -a "$TSV"
done
