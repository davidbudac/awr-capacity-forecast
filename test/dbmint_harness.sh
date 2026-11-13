#!/usr/bin/env bash
# test/dbmint_harness.sh -- sync this checkout to the dbmint VM and run the
# fixture harness in a throwaway schema (SYSDBA + CURRENT_SCHEMA, PDB1).
#
#   test/dbmint_harness.sh <SCHEMA> [--ml] [--no-fixture] [--pga] [--parity]
#                          [--sql FILE]... [--ml-only] [--sql-only]
#                          [--wait-slot [N]]
#   test/dbmint_harness.sh <SCHEMA> --attach
#   test/dbmint_harness.sh <SCHEMA> --status
#
#   <SCHEMA>      target schema in PDB1 (CAPX1 etc.; must already exist with
#                 CREATE TABLE/VIEW/TYPE/PROCEDURE[/MINING MODEL] + USERS quota)
#   --ml          also run cap_forecast_ml.train_all + test/run_test_ml.sql
#   --no-fixture  skip test/fixture_install.sql (reinstall views + test only)
#   --sql FILE    run extra SQL*Plus script(s) after the tests, same session
#                 settings (handy for ad-hoc probes against the fixture)
#   --pga         end every step with test/pga_probe.sql (that session's peak
#                 PGA, its largest work areas, the instance PGA counters)
#   --parity      after a passing run, test/snapshot_parity.sh: LIVE and
#                 SNAPSHOT reports must match (resets the run history)
#   --ml-only     the schema as it is: no fixture load, no install, no
#                 run_test.sql. Runs the --ml step, then any --sql FILE.
#   --sql-only    the schema as it is: only the --sql FILE scripts (and the
#                 --ml step when --ml is given too)
#   --wait-slot [N]  before starting, wait while N (default 2) or more
#                 SQL*Plus processes or harness runs are active on the VM,
#                 polling every 15 s (the VM has 2 vCPUs)
#   --attach      start nothing: follow the schema's run to its end, or
#                 print the result of its last finished run, and exit with
#                 that run's status (5 when the schema has no run)
#   --status      one line: running since / finished with exit N / none
#                 (times are the VM's clock)
#
# The run is detached. The steps go into ~/awr_cap_<schema>.harness/run.sh
# on the VM, started there under setsid + nohup, one SQL*Plus session per
# step. Beside it: harness.log (the output), state (pid, start time, git
# SHA, step list, then exit status and end time) and lock, a flock the run
# and its SQL*Plus sessions hold for as long as one of them lives. This
# script only follows harness.log into /tmp/dbmint_harness_<SCHEMA>.log.
# When it is killed, or the ssh connection drops, the run finishes on the
# VM and --attach picks it up. The directory is a sibling of the synced
# tree because four levers rsync --delete into ~/awr_cap_<schema>/.
#
# A start while the schema's lock is held is refused (exit 3). The state
# keeps the last run only. A warning is printed when the VM clock is within
# 100 minutes of its midnight: the fixture is anchored to the load day, and
# run_test.sql fails date assertions when a run crosses midnight.
#
# test/check.sh (every check that needs no database: the generated-file
# checks, the lints, the docs lint and the offline tests) runs first and a
# failure of any stops the run (exit 4).
# Exit status is the SQL*Plus exit status of the last failing step; the log is
# left in /tmp/dbmint_harness_<SCHEMA>.log (a copy of harness.log) and the
# RESULT / FAIL / ORA- lines are echoed at the end. Other statuses: 2 usage,
# 3 the VM did not answer, rsync failed or the schema has a run, 4 offline
# checks, 5 nothing to attach to, 130 this script was interrupted (the run
# goes on), 143 the runner on the VM was killed. One schema per concurrent
# run (see CLAUDE.md).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCHEMA=${1:?schema}; shift
ML=0; FIXTURE=1; BASE=1; PGA=0; PARITY=0; EXTRA=(); MODE=run; SLOT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ml) ML=1;;
    --no-fixture) FIXTURE=0;;
    --pga) PGA=1;;
    --parity) PARITY=1;;
    --sql) shift; EXTRA+=("${1:?--sql needs a file}");;
    --ml-only) BASE=0; ML=1;;
    --sql-only) BASE=0;;
    --wait-slot) SLOT=2
      case "${2-}" in ''|*[!0-9]*) ;; *) SLOT=$2; shift;; esac
      [ "$SLOT" -ge 1 ] || { echo "--wait-slot needs N >= 1" >&2; exit 2; };;
    --attach) MODE=attach;;
    --status) MODE=status;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac; shift
done
REMOTE=awr_cap_$(echo "$SCHEMA" | tr 'A-Z' 'a-z')
RUN="~/$REMOTE.harness"
# The keepalive ends a follow whose connection died, so it can reconnect.
SSH="ssh -p 2200 -o ServerAliveInterval=30 -o ServerAliveCountMax=4 oracle@dbmint"
LOG=/tmp/dbmint_harness_${SCHEMA}.log
PLOG=/tmp/snapshot_parity_${SCHEMA}.log

# remote <status | start N>: runs the helper below on the VM. Every probe
# of a run's lock happens under one VM-wide lock, so a probe never makes a
# start fail and the slot count and the start are one step.
#   status   prints state=running|finished|none, the state file, the VM
#            clock (now=HH:MM) and active= (SQL*Plus processes, or locked
#            harness runs when there are more of those)
#   start N  exit 3 when the schema has a run, 75 when N > 0 and N or more
#            are active; else starts run.sh.new detached and prints status
remote() {
  $SSH "bash -s -- $REMOTE $*" <<'HELPER'
RUN=$HOME/$1.harness; CMD=$2; LIMIT=${3:-0}
exec 8>> "$HOME/.awr_cap_harness.lock"; flock 8
held() { [ -e "$1/lock" ] && ! ( flock -n 9 ) 9< "$1/lock"; }
active() {
  local n h=0 d
  n=$(pgrep -x sqlplus | wc -l)
  for d in "$HOME"/awr_cap_*.harness; do held "$d" && h=$((h + 1)); done
  [ "$h" -gt "$n" ] && n=$h
  echo "$n"
}
show() {
  if held "$RUN"; then echo state=running
  elif [ -f "$RUN/state" ]; then echo state=finished
  else echo state=none; fi
  [ -f "$RUN/state" ] && cat "$RUN/state"
  echo "now=$(date +%H:%M)"
  echo "active=$(active)"
}
case $CMD in
  status) show;;
  start)
    if held "$RUN"; then show; exit 3; fi
    n=$(active)
    if [ "$LIMIT" -gt 0 ] && [ "$n" -ge "$LIMIT" ]; then echo "active=$n"; exit 75; fi
    exec 9>> "$RUN/lock"; flock -n 9 || exit 3
    mv "$RUN/run.sh.new" "$RUN/run.sh" || exit 4
    rm -f "$RUN/state" "$RUN/parity.log"; : > "$RUN/harness.log"
    # fd 9 goes with the run (its lock); fd 8 must not (the VM-wide lock)
    setsid nohup bash "$RUN/run.sh" 8>&- < /dev/null > /dev/null 2>&1 &
    for i in $(seq 50); do grep -q '^pid=' "$RUN/state" 2>/dev/null && break; sleep 0.1; done
    show;;
esac
HELPER
}

# rstate [start N]: asks the VM and fills ST_*. Returns the helper's status.
rstate() {
  local out src
  out=$(remote "${@:-status}"); src=$?
  st() { sed -n "s/^$1=//p" <<<"$out" | tail -1; }
  ST_state=$(st state); ST_pid=$(st pid); ST_started=$(st started)
  ST_sha=$(st sha); ST_steps=$(st steps); ST_exit=$(st exit)
  ST_finished=$(st finished); ST_parity=$(st parity)
  ST_now=$(st now); ST_active=$(st active)
  return $src
}
need_vm() { echo "dbmint did not answer (ssh -p 2200 oracle@dbmint)" >&2; exit 3; }
about() { echo "started $ST_started, pid $ST_pid, steps: $ST_steps, git $ST_sha"; }
status_line() {
  case "$ST_state" in
    running)  echo "$SCHEMA: running since $ST_started (pid $ST_pid, steps: $ST_steps, git $ST_sha)";;
    finished) if [ -n "$ST_exit" ]; then
                echo "$SCHEMA: finished with exit $ST_exit at $ST_finished ($(about))"
              else
                echo "$SCHEMA: finished with no exit status, runner killed or VM restarted ($(about))"
              fi;;
    *)        echo "$SCHEMA: none";;
  esac
}

detach() {
  pkill -P $$ 2>/dev/null
  echo "interrupted: the run goes on on dbmint. Follow it: test/dbmint_harness.sh $SCHEMA --attach" >&2
  exit 130
}

# follow: copies harness.log into $LOG from where $LOG ends and prints its
# "### " lines, until the run has ended. tail --pid ends with the runner; a
# dropped connection is taken up again at the same byte.
follow() {
  local off fails=0 f t
  trap detach INT TERM HUP
  while :; do
    off=$(( $(wc -c < "$LOG") + 1 )); t=$SECONDS
    f=""; [ "$ST_state" = running ] && [ -n "$ST_pid" ] && f="-f --pid=$ST_pid"
    # cat takes over when grep cannot print any more, so the copy goes on
    $SSH -n "tail -c +$off $f $RUN/harness.log" 2>/dev/null \
      | tee -a "$LOG" | { grep --line-buffered '^### ' || cat > /dev/null; } &
    wait $!
    if ! rstate; then
      fails=$((fails + 1))
      [ $fails -ge 6 ] && { echo "dbmint does not answer. The run goes on there: test/dbmint_harness.sh $SCHEMA --attach" >&2; exit 3; }
      sleep 10; continue
    fi
    fails=0
    [ "$ST_state" = running ] || break
    # a tail that ended at once: the runner is gone, a session of it lives
    if [ $((SECONDS - t)) -lt 5 ]; then sleep 15; else sleep 2; fi
  done
  off=$(( $(wc -c < "$LOG") + 1 ))
  $SSH -n "tail -c +$off $RUN/harness.log" 2>/dev/null | tee -a "$LOG" | grep '^### '
  trap - INT TERM HUP
}

# finish: the summary lines of the run that ended, and its exit status.
finish() {
  local rc=$ST_exit
  case "$rc" in ''|*[!0-9]*) status_line; rc=1;; esac
  grep -E "RESULT:|FAIL|ORA-|PLS-|SP2-|Warning: .* compilation errors|step failed" "$LOG" | grep -v "^  PASS" | head -60
  if [ -n "$ST_parity" ]; then
    echo "log: $LOG  (exit 0)"
    $SSH -n "cat $RUN/parity.log" > "$PLOG" 2>&1
    grep -E '^(TIME|PGA|DIFF|SAME|FORBIDDEN|READS|RESULT|ERROR)' "$PLOG"
    echo "log: $PLOG  (exit $ST_parity)"
  else
    echo "log: $LOG  (exit $rc)"
  fi
  exit "$rc"
}

if [ $MODE = status ]; then
  rstate || need_vm
  status_line
  exit 0
fi
if [ $MODE = attach ]; then
  rstate || need_vm
  [ "$ST_state" = none ] && { echo "$SCHEMA: no harness run on dbmint to attach to"; exit 5; }
  status_line
  rm -f "$LOG"; : > "$LOG"
  follow
  finish
fi

PRE="ALTER SESSION SET CONTAINER = PDB1;
ALTER SESSION SET CURRENT_SCHEMA = $SCHEMA;"
STEPS=(); NAMES=()
if [ $BASE = 1 ]; then
  [ $FIXTURE = 1 ] && { STEPS+=("@test/fixture_install.sql"); NAMES+=(fixture); }
  STEPS+=("DEFINE deploy_mode = fixture
@install.sql"); NAMES+=(install)
  STEPS+=("@test/run_test.sql"); NAMES+=(run_test)
fi
[ $ML = 1 ] && { STEPS+=("EXEC cap_forecast_ml.train_all
@test/run_test_ml.sql"); NAMES+=(ml); }
for f in "${EXTRA[@]+"${EXTRA[@]}"}"; do STEPS+=("@$f"); NAMES+=("sql:$f"); done
[ ${#STEPS[@]} -gt 0 ] || { echo "nothing to run: --sql-only needs --sql FILE or --ml" >&2; exit 2; }
[ $PGA = 1 ] && NAMES+=("(pga)")
[ $PARITY = 1 ] && NAMES+=(parity)

refuse() {
  echo "refused: $(status_line)"
  echo "one run per schema. Follow it: test/dbmint_harness.sh $SCHEMA --attach"
  exit 3
}
rstate || need_vm
[ "$ST_state" = running ] && refuse

"$HERE"/test/check.sh || { echo "offline checks failed: not syncing"; exit 4; }

# The runner: its parameters, a fixed body, then one call per step.
SHA=$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)
[ -n "$(git -C "$HERE" status --porcelain 2>/dev/null)" ] && SHA="$SHA+changes"
RUNNER=$(mktemp) || exit 2
trap 'rm -f "$RUNNER"' EXIT
{
  printf '#!/usr/bin/env bash\n# Written by test/dbmint_harness.sh: the detached run of one schema.\n'
  printf 'REMOTE=%q\nSCHEMA=%q\nSHA=%q\nNAMES=%q\n' "$REMOTE" "$SCHEMA" "$SHA" "${NAMES[*]}"
  cat <<'BODY'
RUN=$HOME/$REMOTE.harness
exec >> "$RUN/harness.log" 2>&1 < /dev/null
rc=143    # what a killed runner leaves as its exit status
trap 'printf "exit=%s\nfinished=%s\n" "$rc" "$(date "+%Y-%m-%d %H:%M:%S")" >> "$RUN/state"' EXIT
printf 'pid=%s\nstarted=%s\nsha=%s\nsteps=%s\n' \
  "$$" "$(date '+%Y-%m-%d %H:%M:%S')" "$SHA" "$NAMES" > "$RUN/state"
export ORACLE_SID=cdb1; export ORAENV_ASK=NO; . oraenv >/dev/null 2>&1
cd ~/"$REMOTE" || { echo "### step failed (exit 3)"; rc=3; exit 3; }
# step <label>: one SQL*Plus session, its script on stdin
step() {
  local t0 src
  echo "### $1"
  t0=$(date +%s)
  sqlplus -S -L / as sysdba
  src=$?
  echo "### elapsed $(( $(date +%s) - t0 )) s"
  [ $src -eq 0 ] || { echo "### step failed (exit $src)"; rc=$src; exit "$src"; }
}
parity() {
  local t0 src
  echo "### test/snapshot_parity.sh $SCHEMA"
  t0=$(date +%s)
  bash test/snapshot_parity.sh "$SCHEMA" --remote > "$RUN/parity.log" 2>&1
  src=$?
  echo "parity=$src" >> "$RUN/state"
  echo "### elapsed $(( $(date +%s) - t0 )) s"
  [ $src -eq 0 ] || { echo "### step failed (exit $src)"; rc=$src; exit "$src"; }
}
BODY
  for step in "${STEPS[@]}"; do
    [ $PGA = 1 ] && step="$step
@test/pga_probe.sql"
    printf "step %q <<'SQL'\n" "$(echo "$step" | head -1)"
    printf 'WHENEVER SQLERROR EXIT FAILURE\n%s\n%s\nEXIT\nSQL\n' "$PRE" "$step"
  done
  [ $PARITY = 1 ] && echo parity
  echo 'rc=0'
} > "$RUNNER"

synced=0; waited=0
while :; do
  if [ $SLOT -gt 0 ]; then
    while rstate || need_vm; [ "$ST_state" != running ] && [ "$ST_active" -ge "$SLOT" ]; do
      [ $waited = 0 ] && echo "waiting for a slot: $ST_active SQL*Plus processes or harness runs active on dbmint (limit $SLOT), polling every 15 s"
      waited=1; sleep 15
    done
    [ "$ST_state" = running ] && refuse
  fi
  if [ $synced = 0 ]; then
    rsync -az --delete -e 'ssh -p 2200' \
      --exclude .git --exclude .claude --exclude reports --exclude '__pycache__' \
      --exclude grafana/.ords.env --exclude grafana/ords/config --exclude grafana/.env \
      "$HERE"/ oracle@dbmint:~/"$REMOTE"/ || exit 3
    $SSH "mkdir -p $RUN && cat > $RUN/run.sh.new" < "$RUNNER" || exit 3
    synced=1
  fi
  rstate start $SLOT
  case $? in
    0)  break;;
    75) continue;;
    3)  [ "$ST_state" = running ] && refuse; need_vm;;
    *)  echo "could not start the run on dbmint" >&2; exit 3;;
  esac
done
[ "$ST_state" = running ] || { echo "the run did not start on dbmint: $(status_line)" >&2; exit 3; }
[ $waited = 1 ] && echo "slot free: started"
case "$ST_now" in
  [0-9][0-9]:[0-9][0-9])
    left=$(( 1440 - 10#${ST_now%:*} * 60 - 10#${ST_now#*:} ))
    [ $left -le 100 ] && echo "warning: the dbmint clock is $ST_now, $left minutes before its midnight. run_test.sql fails date assertions when a run crosses it.";;
esac

rm -f "$LOG"; : > "$LOG"
follow
finish
