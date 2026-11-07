#!/usr/bin/env bash
# test/dbmint_parity.sh -- the M24.5 gate on dbmint: local mode and repository
# mode over the same AWR must present the same numbers.
#
#   test/dbmint_parity.sh <REPO_SCHEMA> <LOCAL_USER> [--seam-only] [--no-install]
#
#   REPO_SCHEMA   PDB1 schema for the repository install (CAPX2 etc.; must
#                 exist). Gets CREATE DATABASE LINK.
#   LOCAL_USER    common user in CDB$ROOT for the local install (C##CAPLOC
#                 etc.), created or refreshed by create_owner.sql.
#   --seam-only   stop after the CAPV_* comparison (seconds instead of minutes)
#   --no-install  keep both installs, only re-collect and compare
#
# Steps, all as SYSDBA on cdb1: target/prepare.sql + target/check.sql (reader
# C##AWRRDR, a new random password each run), install local into LOCAL_USER,
# install repository into REPO_SCHEMA, re-register the root as target CDB1
# over a loopback link (//localhost:1521/cdb1) and collect. Both installs
# start without run history, alert state or ML models (cap_results.reset,
# cap_forecast_ml.drop_all), which a deploy-mode change needs anyway and which
# would otherwise differ between the schemas. Then fingerprint
# (test/parity_fingerprint.sql):
#   seam   every CAPV_* view in both, cut at the repository's high-water mark,
#          but CAPV_CONTRACT and CAPV_TARGET (how each install is fed);
#   stack  every CAPD_/CAPF_/CAPA_/CAPR_ view but CAPR_TARGETS, both sessions
#          in parallel.
# The stack only compares when no snapshot landed during the run (dbmint
# snapshots every 15 minutes); otherwise it exits 5, rerun with --no-install.
# A view that errors fails the run even when both sides error alike.
# The two stack sessions run at once: pga_aggregate_limit must hold two suite
# sessions (~1.5 GB each, see CLAUDE.md). The seam cut bounds only the newest
# snap_id, so --no-install after the target purged old AWR shows the
# repository's older rows as a difference: reinstall instead.
# Exit 0 when both diffs are empty. Logs in /tmp/dbmint_parity.*.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
REPO=${1:?repository schema}; LOCAL=${2:?local common user}; shift 2
SEAM_ONLY=0; INSTALL=1
while [ $# -gt 0 ]; do
  case "$1" in
    --seam-only) SEAM_ONLY=1;;
    --no-install) INSTALL=0;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac; shift
done
case $LOCAL in C\#\#*) ;; *) echo "LOCAL_USER must be a common user (C##...)" >&2; exit 2;; esac
REMOTE=awr_cap_parity
SSH="ssh -p 2200 oracle@dbmint"
L=/tmp/dbmint_parity
PW="P$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')x"

python3 "$HERE"/repository/build.py --check || exit 4
"$HERE"/test/lint_anom_joins.sh >/dev/null || { echo "lint_anom_joins failed" >&2; exit 4; }

rsync -az --delete -e 'ssh -p 2200' \
  --exclude .git --exclude .claude --exclude reports --exclude '__pycache__' \
  --exclude grafana/.ords.env --exclude grafana/ords/config --exclude grafana/.env \
  "$HERE"/ oracle@dbmint:~/"$REMOTE"/ || exit 3

sql() {   # sql <log> <container|-> <schema|-> : runs stdin as SYSDBA on cdb1
  local log=$1 con=$2 sch=$3 pre=""
  [ "$con" != - ] && pre="ALTER SESSION SET CONTAINER = $con;"
  [ "$sch" != - ] && pre="$pre
ALTER SESSION SET CURRENT_SCHEMA = $sch;"
  { echo "WHENEVER SQLERROR EXIT FAILURE"; echo "$pre"; cat; echo "EXIT"; } |
    $SSH "export ORACLE_SID=cdb1 ORAENV_ASK=NO; . oraenv >/dev/null 2>&1; cd ~/$REMOTE && sqlplus -S -L / as sysdba" > "$log" 2>&1
}
step() { echo "### $*"; }
fail() { echo "### FAILED: $1 (log $2)"; grep -E 'ORA-|PLS-|SP2-|FAIL' "$2" | head -10; exit 1; }

if [ $INSTALL = 1 ]; then
  step "target/prepare.sql + check.sql"
  sql $L.target.log - - <<EOF || fail "target scripts" $L.target.log
DEFINE reader_pw = '$PW'
@target/prepare.sql
@target/check.sql
EOF
  step "local install into $LOCAL (CDB\$ROOT)"
  sql $L.local.log - - <<EOF || fail "local install" $L.local.log
DEFINE owner = $LOCAL
DEFINE owner_quota = UNLIMITED
@create_owner.sql
ALTER SESSION SET CURRENT_SCHEMA = $LOCAL;
DEFINE deploy_mode = local
@install.sql
EXEC cap_results.reset
EXEC cap_forecast_ml.drop_all
EOF
  step "repository install into $REPO (PDB1)"
  sql $L.repo.log PDB1 - <<EOF || fail "repository install" $L.repo.log
GRANT CREATE DATABASE LINK TO $REPO;
ALTER SESSION SET CURRENT_SCHEMA = $REPO;
DEFINE deploy_mode = repository
@install.sql
EXEC cap_results.reset
EXEC cap_forecast_ml.drop_all
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR CONTINUE
EXEC cap_repo.remove_target('CDB1')
WHENEVER SQLERROR EXIT FAILURE
EXEC cap_repo.add_target('CDB1', '//localhost:1521/cdb1', 'C##AWRRDR', '$PW')
EOF
fi

step "collect + seam fingerprints"
sql $L.seam_r.log PDB1 "$REPO" <<'EOF' || fail "collect / repository seam" $L.seam_r.log
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
EXEC cap_repo.collect('CDB1')
COLUMN hwm NEW_VALUE hwm
SELECT TO_CHAR(MAX(last_snap_id)) AS hwm FROM cap_target_dbid;
@test/parity_fingerprint.sql seam &hwm
EOF
HWM=$(grep -A2 '^HWM' $L.seam_r.log | tail -1 | tr -d ' ')
[ -n "$HWM" ] || fail "no high-water mark" $L.seam_r.log
sql $L.seam_l.log - "$LOCAL" <<EOF || fail "local seam" $L.seam_l.log
@test/parity_fingerprint.sql seam $HWM
EOF
grep '^FP' $L.seam_l.log | sed 's/ *--.*//' > $L.seam_l.fp
grep '^FP' $L.seam_r.log | sed 's/ *--.*//' > $L.seam_r.fp
if grep -q ' ERROR ' $L.seam_l.fp $L.seam_r.fp; then
  echo "### seam views failed:"; grep -h ' ERROR ' $L.seam_l.fp $L.seam_r.fp; exit 1
fi
if ! diff $L.seam_l.fp $L.seam_r.fp; then
  echo "### SEAM DIFFERS at snap_id $HWM (< local, > repository)"; exit 1
fi
echo "### seam parity: $(grep -c '^FP CAPV' $L.seam_r.fp) CAPV views equal at snap_id $HWM"
[ $SEAM_ONLY = 1 ] && exit 0

step "stack fingerprints (parallel)"
sql $L.stack_r.log PDB1 "$REPO" <<'EOF' &
@test/parity_fingerprint.sql stack
EOF
PID_R=$!
sql $L.stack_l.log - "$LOCAL" <<'EOF' &
@test/parity_fingerprint.sql stack
EOF
PID_L=$!
wait $PID_R || fail "repository stack fingerprint" $L.stack_r.log
wait $PID_L || fail "local stack fingerprint" $L.stack_l.log
NEWEST=$(grep 'FP-NEWEST-SNAP' $L.stack_l.log | awk '{print $2}')
grep '^FP' $L.stack_l.log | sed 's/ *--.*//' > $L.stack_l.fp
grep '^FP' $L.stack_r.log | sed 's/ *--.*//' > $L.stack_r.fp
if [ "$NEWEST" != "$HWM" ]; then
  echo "### INCONCLUSIVE: snapshot $NEWEST landed after the collect at $HWM; rerun with --no-install"; exit 5
fi
if ! diff $L.stack_l.fp $L.stack_r.fp; then
  echo "### STACK DIFFERS (< local, > repository)"; exit 1
fi
if grep -q ' ERROR ' $L.stack_r.fp; then
  echo "### stack views failed (alike on both sides):"; grep -h ' ERROR ' $L.stack_r.fp; exit 1
fi
echo "### stack parity: $(grep -c '^FP CAP' $L.stack_r.fp) views equal at snap_id $HWM"
exit 0
