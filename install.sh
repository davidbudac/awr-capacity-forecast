#!/usr/bin/env bash
# install.sh -- guided installer for the AWR Capacity Forecast suite.
#
#   ./install.sh                              # wizard: asks what to install and how
#   ./install.sh --profile target --set CONNECT='/ as sysdba'   # prepare a target
#   ./install.sh --profile standalone         # silent: every answer from a profile
#   ./install.sh --profile standalone --set OWNER=C##CAPMON --set JOBS_ENABLE=Y
#   ./install.sh --profile my.env --dry-run   # print the SQL*Plus driver, run nothing
#   ./install.sh --list-profiles
#
# Options:
#   --profile P     a name from profiles/ (quickstart, standalone, target,
#                   repository, fixture-test, demo) or a path to a KEY=VALUE
#                   file. Without --interactive it runs silently.
#   --set KEY=VAL   override one answer (repeatable; applied after the profile)
#   --interactive   with --profile: walk the wizard, profile answers as defaults
#   --save FILE     write the final answers to FILE (secrets never written)
#   --dry-run       print the generated driver (passwords masked) and stop
#   --yes           do not ask for the final confirmation
#   --list-profiles show the shipped profiles and exit
#   -h, --help      this text
#
# Every answer is a KEY in the table below (see profiles/*.env for examples).
# Secrets never live in a profile. They come from the environment, or from a
# hidden prompt in the wizard:
#   CAP_DB_PW     password for CONNECT when it names a user but no password
#   CAP_OWNER_PW  password for a new owner (empty: NO AUTHENTICATION, the
#                 schema-only user you install into as SYSDBA)
#   CAP_READER_PW password for the read-only reader (ROLE=target; required,
#                 the repository's DB link logs in with it). ROLE=standalone
#                 needs none: the run gives the reader a random password that
#                 never leaves the SQL*Plus session.
#
# The answers become one SQL*Plus driver, written next to this script (the @@
# includes resolve relative to the outermost script) with mode 600, run with
# `sqlplus -L /nolog` and deleted afterwards. The session log goes to
# reports/install_<timestamp>.log. Exits with the sqlplus exit status.
# Needs bash 4+ (associative arrays) and sqlplus on PATH (on the DB host: . oraenv).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE"

# key | default | kind | question
#   kind: yn, choice:a/b/c, list:a/b/c (comma list or none), name (SQL
#   identifier or empty), text (no quotes or newlines), int
KEYS=(
"ROLE|standalone|choice:standalone/target/repository/fixture|What this database is: standalone (the suite here, reading this database as its own target), target (only a read-only AWR reader for a repository), repository (the suite reads AWR copied from registered targets), fixture (test data)"
"CONNECT|/ as sysdba|text|SQL*Plus connect string (no password; '/ as sysdba' for OS auth)"
"CONTAINER||name|Container to switch to after connecting (empty = stay where you land, e.g. CDB\$ROOT). Standalone: the PDB the suite lives in (empty = the one open PDB)"
"INTO|self|choice:self/schema|Install into the connected schema (self) or into another schema via CURRENT_SCHEMA (schema)"
"OWNER||name|Owner schema (empty = C##AWRCAP in CDB\$ROOT, AWRCAP elsewhere, e.g. in the standalone PDB)"
"OWNER_CREATE|N|yn|Create or refresh that owner with create_owner.sql (needs SYSDBA)"
"OWNER_TS||name|Owner default tablespace (empty = the database default)"
"OWNER_QUOTA|1G|text|Owner quota on that tablespace (e.g. 1G, UNLIMITED)"
"READER||name|Read-only AWR reader to create on the target, the user the repository's DB link connects as (empty = C##AWRRDR in a CDB, AWRRDR in a non-CDB)"
"SELF_CONNECT||text|Standalone: the address the loopback link connects to (empty = //localhost:<listener port>/<the root's default service>)"
"FIXTURE_DATA|test|choice:none/test/demo|Fixture data to load first: none (keep existing), test (assertion fixture), demo (150-day ECOMPRD story)"
"DOCTOR|Y|yn|Run the doctor.sql preflight before installing"
"FORCE_INSTALL|N|yn|Install even when doctor reports FAIL lines"
"TRAIN_ML|N|yn|Train the Tier 2 OML ESM models now (needs CREATE MINING MODEL)"
"JOBS|N|yn|Create the DBMS_SCHEDULER jobs (CAP_NIGHTLY_JOB: purge, retrain, refresh, alert spool in order; repository: hourly collect)"
"JOBS_ENABLE|N|yn|Enable the jobs right away (they are created disabled): CAP_NIGHTLY_JOB, and for standalone CAP_COLLECT_JOB too (a repository enables it once targets are added)"
"REPORT_DIR|CAP_REPORTS|name|Directory object the alert-spool job writes to"
"NIGHTLY_INTERVAL|FREQ=DAILY;BYHOUR=1;BYMINUTE=0;BYSECOND=0|text|CAP_NIGHTLY_JOB calendar string"
"ORDS|N|yn|Publish the ORDS REST module awrcap (Grafana / Prometheus feed; needs ORDS in this database)"
"ORDS_ALIAS||text|ORDS URL alias (empty = lower-case schema name)"
"APEX|N|yn|Import the APEX application (needs APEX and an existing workspace)"
"APEX_WORKSPACE|AWRCAP|name|APEX workspace"
"APEX_APP_ID|110|int|APEX application id"
"REPORTS|text|list:text/html/brief/csv|Reports to write into reports/ after install (comma list, or none)"
"RUN_TESTS|N|yn|Run the fixture assertion suite (test/run_test.sql, + run_test_ml.sql with ML; ~20 min)"
)

declare -A CFG DEFAULT KIND QUESTION
ORDER=()
for row in "${KEYS[@]}"; do
  IFS='|' read -r k d t q <<<"$row"
  ORDER+=("$k"); DEFAULT[$k]=$d; KIND[$k]=$t; QUESTION[$k]=$q; CFG[$k]=$d
done

die() { echo "install.sh: $*" >&2; exit 2; }

# ROLE -> install.sql deploy_mode (target installs no suite)
deploy_mode() {
  case ${CFG[ROLE]} in
    standalone) echo repository ;;
    target)     echo none ;;
    *)          echo "${CFG[ROLE]}" ;;
  esac
}

# CONNECT names a user but carries no password ('/ as sysdba' is OS auth)
needs_pw() { local c=${CFG[CONNECT]}; [[ $c != /* && ${c%%[@ ]*} != */* ]]; }

# valid KEY VALUE -> 0/1, reason in $WHY
valid() {
  local k=$1 v=$2 opts
  WHY=""
  case "${KIND[$k]}" in
    yn)       [[ $v == Y || $v == N ]] || WHY="want Y or N" ;;
    choice:*) opts=${KIND[$k]#choice:}
              [[ "/$opts/" == */"$v"/* && -n $v ]] || WHY="want one of ${opts//\// | }" ;;
    list:*)   opts=${KIND[$k]#list:}
              if [[ $v != none ]]; then
                local IFS=, x
                [[ -n $v ]] || WHY="want a comma list of ${opts//\//,} or none"
                for x in $v; do [[ "/$opts/" == */"$x"/* && -n $x ]] || WHY="unknown item '$x' (have ${opts//\//,})"; done
              fi ;;
    name)     [[ -z $v || $v =~ ^[A-Za-z][A-Za-z0-9_\$#]{0,127}$ ]] || WHY="want a plain SQL name (letters, digits, _ \$ #)" ;;
    int)      [[ $v =~ ^[0-9]+$ ]] || WHY="want a number" ;;
    text)     [[ $v != *[\'\"\&]* && $v != *$'\n'* ]] || WHY="no quotes or & allowed" ;;
  esac
  [[ -z $WHY ]]
}

norm() {   # norm KEY VALUE -> the canonical spelling of VALUE
  case "${KIND[$1]}" in
    yn|name) printf '%s' "${2^^}" ;;
    choice:*|list:*) printf '%s' "${2,,}" ;;
    *) printf '%s' "$2" ;;
  esac
}

set_key() {
  local k=$1 v
  [[ -n ${KIND[$k]+x} ]] || die "unknown key '$k' (see ./install.sh --help)"
  v=$(norm "$k" "$2")
  valid "$k" "$v" || die "$k='$v': $WHY"
  CFG[$k]=$v
}

load_profile() {
  local f=$1 line k v n=0
  [[ -f $f ]] || f="profiles/$1.env"
  [[ -f $f ]] || die "no profile '$1' (try --list-profiles)"
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    # a comment is a '#' at line start or after a blank (C##AWRCAP is a value)
    line=$(printf '%s' "$line" | sed -E -e 's/(^|[[:space:]])#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [[ -z $line ]] && continue
    [[ $line == *=* ]] || die "$f:$n: want KEY=VALUE"
    k=${line%%=*}; v=${line#*=}
    k=${k%"${k##*[![:space:]]}"}; v=${v#"${v%%[![:space:]]*}"}
    [[ $v == \"*\" ]] && v=${v:1:${#v}-2}
    set_key "$k" "$v"
  done < "$f"
  PROFILE_NAME=$(basename "$f" .env)
}

list_profiles() {
  local f
  for f in profiles/*.env; do
    printf '  %-14s %s\n' "$(basename "$f" .env)" "$(sed -n 's/^# *//p' "$f" | head -1)"
  done
}

# ---------------------------------------------------------------- wizard

ask() {   # ask KEY: re-asks until the answer is valid
  local k=$1 kind=${KIND[$1]} cur=${CFG[$1]} ans hint=""
  case "$kind" in
    yn)       hint="Y/N" ;;
    choice:*) hint=${kind#choice:} ;;
    list:*)   hint="${kind#list:}, comma separated, or none"; hint=${hint//\//,} ;;
  esac
  while :; do
    printf '\n%s\n' "${QUESTION[$k]}"
    read -r -p "  $k${hint:+ ($hint)} [${cur:-<empty>}]: " ans </dev/tty || die "no terminal to ask on"
    [[ -z $ans ]] && ans=$cur
    [[ $ans == - ]] && ans=""
    ans=$(norm "$k" "$ans")
    if valid "$k" "$ans"; then CFG[$k]=$ans; return; fi
    echo "  -> $WHY"
  done
}

section() { printf '\n== %s ==\n' "$1"; }

wizard() {
  cat <<EOF

AWR Capacity Forecast installer
Press Enter to keep the value in brackets, '-' to clear it.
Nothing touches the database until you confirm the summary.
EOF
  section "Role"
  cat <<EOF
  standalone  the suite on this database, reading its own AWR over a loopback DB link
              (this database is its own target; the suite goes into a PDB)
  target      no suite: a read-only AWR reader that a repository database pulls from
  repository  the suite here, reading AWR copied from the targets you register
  fixture     test data instead of AWR (assertion harness, demo)
EOF
  ask ROLE
  [[ ${CFG[ROLE]} == fixture ]] && ask FIXTURE_DATA

  section "Connection"
  ask CONNECT; ask CONTAINER

  if [[ ${CFG[ROLE]} == target ]]; then
    section "Reader"
    echo "  Run in CDB\$ROOT (or a non-CDB) as SYSDBA. Creates the reader with direct SELECT on"
    echo "  the AWR views the suite reads. Nothing else on this database changes."
    ask READER
    if [[ -z ${CAP_READER_PW+x} ]]; then
      read -r -s -p "  Reader password: " CAP_READER_PW </dev/tty; echo
      export CAP_READER_PW
    fi
    return 0
  fi

  if [[ ${CFG[ROLE]} == standalone ]]; then
    section "This database as its own target"
    echo "  Connect as SYSDBA in CDB\$ROOT (or a non-CDB). The run creates the reader there with a"
    echo "  random password, then installs the suite into a dedicated owner in the PDB (CONTAINER)."
    ask READER; ask SELF_CONNECT
  fi

  section "Where the suite lives"
  if [[ ${CFG[ROLE]} == standalone ]]; then
    CFG[INTO]=schema
  else
    cat <<EOF
  self    install into the schema you connect as (SYS for '/ as sysdba': fine for
          a first look, but everything ends up in the dictionary schema)
  schema  a dedicated owner, the production path; installed as SYSDBA through
          ALTER SESSION SET CURRENT_SCHEMA
EOF
    ask INTO
  fi
  if [[ ${CFG[INTO]} == schema ]]; then
    ask OWNER; ask OWNER_CREATE
    if [[ ${CFG[OWNER_CREATE]} == Y ]]; then
      ask OWNER_TS; ask OWNER_QUOTA
      if [[ -z ${CAP_OWNER_PW+x} ]]; then
        read -r -s -p "  Owner password (Enter = NO AUTHENTICATION, schema-only): " CAP_OWNER_PW </dev/tty; echo
        export CAP_OWNER_PW
      fi
    fi
  fi

  section "Install"
  ask DOCTOR
  [[ ${CFG[DOCTOR]} == Y ]] && ask FORCE_INSTALL
  ask TRAIN_ML

  section "Automation"
  ask JOBS
  if [[ ${CFG[JOBS]} == Y ]]; then
    ask JOBS_ENABLE; ask REPORT_DIR; ask NIGHTLY_INTERVAL
  fi

  section "Integrations inside the database (ELK and Grafana run elsewhere: see elk/ and grafana/)"
  ask ORDS
  [[ ${CFG[ORDS]} == Y ]] && ask ORDS_ALIAS
  ask APEX
  if [[ ${CFG[APEX]} == Y ]]; then ask APEX_WORKSPACE; ask APEX_APP_ID; fi

  section "Afterwards"
  ask REPORTS
  [[ ${CFG[ROLE]} == fixture ]] && ask RUN_TESTS
  return 0
}

# Clear answers that cannot apply, so the summary, the saved profile and
# the driver all say the same thing.
normalise() {
  if [[ ${CFG[ROLE]} == target ]]; then
    local k
    for k in INTO OWNER OWNER_CREATE OWNER_TS OWNER_QUOTA FIXTURE_DATA DOCTOR FORCE_INSTALL TRAIN_ML \
             JOBS JOBS_ENABLE REPORT_DIR NIGHTLY_INTERVAL ORDS ORDS_ALIAS APEX \
             APEX_WORKSPACE APEX_APP_ID REPORTS RUN_TESTS; do
      CFG[$k]=${DEFAULT[$k]}
    done
    CFG[FIXTURE_DATA]=none; CFG[REPORTS]=none
  elif [[ ${CFG[ROLE]} != standalone ]]; then
    CFG[READER]=${DEFAULT[READER]}
  fi
  [[ ${CFG[ROLE]} == standalone ]] || CFG[SELF_CONNECT]=""
  [[ ${CFG[ROLE]} == standalone ]] && CFG[INTO]=schema
  if [[ ${CFG[INTO]} == self ]]; then CFG[OWNER]=""; CFG[OWNER_CREATE]=N; fi
  [[ ${CFG[OWNER_CREATE]} == Y ]] || { CFG[OWNER_TS]=""; CFG[OWNER_QUOTA]=${DEFAULT[OWNER_QUOTA]}; }
  [[ ${CFG[ROLE]} == fixture ]] || { CFG[FIXTURE_DATA]=none; CFG[RUN_TESTS]=N; }
  [[ ${CFG[DOCTOR]} == Y ]] || CFG[FORCE_INSTALL]=N
  [[ ${CFG[JOBS]} == Y ]] || CFG[JOBS_ENABLE]=N
  [[ ${CFG[ORDS]} == Y ]] || CFG[ORDS_ALIAS]=""
  [[ -n ${CFG[REPORTS]} ]] || CFG[REPORTS]=none
  if [[ ${CFG[ROLE]} == standalone && ${CFG[CONNECT],,} != *"as sysdba"* ]]; then
    echo "install.sh: note: ROLE=standalone needs a SYSDBA connection (target/self.sql stops otherwise)" >&2
  elif [[ ${CFG[OWNER_CREATE]} == Y && ${CFG[CONNECT],,} != *"as sysdba"* ]]; then
    echo "install.sh: note: OWNER_CREATE=Y needs SYSDBA (or CREATE USER + GRANT ANY [OBJECT] PRIVILEGE)" >&2
  fi
  return 0
}

skip_key() {
  case ${CFG[ROLE]} in
    target)     [[ ! " ROLE CONNECT CONTAINER READER " =~ " $1 " ]] ;;
    standalone) [[ $1 == INTO ]] ;;
    *)          [[ $1 == READER || $1 == SELF_CONNECT ]] ;;
  esac
}

summary() {
  local k
  printf '\nPlan%s\n' "${PROFILE_NAME:+ (profile $PROFILE_NAME)}"
  for k in "${ORDER[@]}"; do
    skip_key "$k" && continue
    printf '  %-17s %s\n' "$k" "${CFG[$k]:-<empty>}"
  done
  [[ ${CFG[OWNER_CREATE]} == Y ]] && printf '  %-17s %s\n' "owner password" "$([[ -n ${CAP_OWNER_PW:-} ]] && echo set || echo 'none (NO AUTHENTICATION)')"
  [[ ${CFG[ROLE]} == target ]] && printf '  %-17s %s\n' "reader password" "$([[ -n ${CAP_READER_PW:-} ]] && echo set || echo 'MISSING (export CAP_READER_PW)')"
  echo
  echo "Steps:"; steps | sed 's/^/  /'
}

steps() {
  local n=1
  p() { echo "$n. $*"; n=$((n + 1)); }
  if [[ ${CFG[ROLE]} == standalone ]]; then
    p "connect as '${CFG[CONNECT]}'"
    p "target/self.sql: reader ${CFG[READER]:-(default name)} with a random password (target/prepare.sql, target/check.sql), then switch to the PDB ${CFG[CONTAINER]:-(the one open PDB)}"
  else
    p "connect as '${CFG[CONNECT]}'${CFG[CONTAINER]:+, container ${CFG[CONTAINER]}}"
  fi
  if [[ ${CFG[ROLE]} == target ]]; then
    p "target/prepare.sql (reader ${CFG[READER]:-(default name)})"
    p "target/check.sql"
    return 0
  fi
  [[ ${CFG[OWNER_CREATE]} == Y ]] && p "create_owner.sql (${CFG[OWNER]:-default owner})"
  [[ ${CFG[INTO]} == schema ]] && p "CURRENT_SCHEMA = ${CFG[OWNER]:-default owner}"
  [[ ${CFG[FIXTURE_DATA]} == test ]] && p "test/fixture_install.sql"
  [[ ${CFG[FIXTURE_DATA]} == demo ]] && p "test/demo_fixture.sql"
  [[ ${CFG[ROLE]} == standalone ]] && p "repository/self.sql: on an existing install, rebuild the link if the new password broke it, collect"
  [[ ${CFG[DOCTOR]} == Y ]] && p "doctor.sql ($([[ ${CFG[FORCE_INSTALL]} == Y ]] && echo 'a FAIL is reported, install goes on' || echo 'a FAIL stops before install'))"
  p "install.sql (deploy_mode = $(deploy_mode))"
  [[ ${CFG[ROLE]} == standalone ]] && p "repository/self.sql: register this database as its own target (or refresh its link), collect"
  [[ ${CFG[TRAIN_ML]} == Y ]] && p "cap_forecast_ml.train_all"
  [[ ${CFG[JOBS]} == Y ]] && p "install_jobs.sql$([[ ${CFG[JOBS_ENABLE]} == Y ]] && echo ", then enable $(enable_jobs)")"
  [[ ${CFG[ORDS]} == Y ]] && p "grafana/ords/awrcap_module.sql"
  [[ ${CFG[APEX]} == Y ]] && p "apex/install.sql (workspace ${CFG[APEX_WORKSPACE]}, app ${CFG[APEX_APP_ID]})"
  [[ ${CFG[RUN_TESTS]} == Y ]] && p "test/run_test.sql$([[ ${CFG[TRAIN_ML]} == Y ]] && echo ' + test/run_test_ml.sql')"
  [[ ${CFG[REPORTS]} != none ]] && p "reports: ${CFG[REPORTS]}"
  return 0
}

save_profile() {
  local f=$1 k
  {
    echo "# saved by install.sh on $(date '+%Y-%m-%d %H:%M')"
    echo "# replay: ./install.sh --profile $f"
    for k in "${ORDER[@]}"; do
      skip_key "$k" && continue
      echo "$k=${CFG[$k]}"
    done
  } > "$f"
  echo "answers saved to $f (no passwords)"
}

# ---------------------------------------------------------------- driver

enable_jobs() {
  if [[ ${CFG[ROLE]} == standalone ]]; then echo "CAP_NIGHTLY_JOB CAP_COLLECT_JOB"; else echo "CAP_NIGHTLY_JOB"; fi
}

# Re-asserted before every step: several included scripts leave
# WHENEVER SQLERROR CONTINUE or SET DEFINE OFF behind.
STRICT="SET DEFINE '&'
WHENEVER SQLERROR EXIT FAILURE
WHENEVER OSERROR EXIT FAILURE
SET FEEDBACK OFF"

driver() {   # driver <mask>: prints the SQL*Plus driver; mask=1 hides passwords
  local mask=$1 conn=${CFG[CONNECT]} pw=${CAP_DB_PW:-} opw=${CAP_OWNER_PW:-} rpw=${CAP_READER_PW:-}
  if [[ $mask == 1 ]]; then
    [[ -n $pw ]] && pw='********'; [[ -n $opw ]] && opw='********'; [[ -n $rpw ]] && rpw='********'
  fi
  if needs_pw && [[ -n $pw ]]; then
    # user[@svc][ as sysdba] -> user/pw[@svc][ as sysdba]
    local user=${conn%%[@ ]*} rest=${conn#"${conn%%[@ ]*}"}
    conn="$user/\"$pw\"$rest"
  fi
  cat <<EOF
-- generated by install.sh $(date '+%Y-%m-%d %H:%M:%S')${PROFILE_NAME:+, profile $PROFILE_NAME}
SET ECHO OFF
SET VERIFY OFF
SET FEEDBACK OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
$STRICT
CONNECT $conn
SET APPINFO OFF
SET APPINFO "AWRCAP/install.sh"
EOF
  if [[ ${CFG[ROLE]} == standalone ]]; then
    cat <<EOF

PROMPT ==== install.sh: target/self.sql (this database as its own target) ====
DEFINE container    = '${CFG[CONTAINER]}'
DEFINE reader       = '${CFG[READER]}'
DEFINE self_connect = '${CFG[SELF_CONNECT]}'
@@target/self.sql
$STRICT
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
EOF
  elif [[ -n ${CFG[CONTAINER]} ]]; then
    echo "ALTER SESSION SET CONTAINER = ${CFG[CONTAINER]};"
  fi

  if [[ ${CFG[ROLE]} == target ]]; then
    cat <<EOF

PROMPT ==== install.sh: target/prepare.sql ====
DEFINE reader    = '${CFG[READER]}'
DEFINE reader_pw = '$rpw'
@@target/prepare.sql
$STRICT
UNDEFINE reader_pw

PROMPT ==== install.sh: target/check.sql ====
@@target/check.sql
$STRICT
UNDEFINE reader

PROMPT
PROMPT ==== install.sh: done, reader ${CFG[READER]} ready ====
EXIT
EOF
    return 0
  fi

  # cap_owner: the owner name, defaulted the way create_owner.sql defaults it
  cat <<EOF
SET TERMOUT OFF
COLUMN cap_owner_v NEW_VALUE cap_owner NOPRINT
SELECT UPPER(NVL('${CFG[OWNER]}', CASE SYS_CONTEXT('USERENV', 'CON_ID')
                 WHEN '1' THEN 'C##AWRCAP' ELSE 'AWRCAP' END)) AS cap_owner_v FROM dual;
COLUMN cap_owner_v CLEAR
SET TERMOUT ON
EOF

  if [[ ${CFG[OWNER_CREATE]} == Y ]]; then
    cat <<EOF

PROMPT ==== install.sh: create_owner.sql ====
DEFINE owner       = '&cap_owner'
DEFINE owner_pw    = '$opw'
DEFINE owner_ts    = '${CFG[OWNER_TS]}'
DEFINE owner_quota = '${CFG[OWNER_QUOTA]}'
@@create_owner.sql
$STRICT
UNDEFINE owner owner_pw owner_ts owner_quota
EOF
  fi
  [[ ${CFG[INTO]} == schema ]] && echo "ALTER SESSION SET CURRENT_SCHEMA = &cap_owner;"
  cat <<EOF
SET TERMOUT OFF
COLUMN cap_target_v NEW_VALUE cap_target NOPRINT
SELECT SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') AS cap_target_v FROM dual;
COLUMN cap_target_v CLEAR
SET TERMOUT ON
PROMPT install.sh: target schema &cap_target
EOF

  case ${CFG[FIXTURE_DATA]} in
    test) printf '\nPROMPT ==== install.sh: test/fixture_install.sql ====\n@@test/fixture_install.sql\n%s\n' "$STRICT" ;;
    demo) printf '\nPROMPT ==== install.sh: test/demo_fixture.sql ====\n@@test/demo_fixture.sql\n%s\n' "$STRICT" ;;
  esac

  [[ ${CFG[ROLE]} == standalone ]] && cat <<EOF

PROMPT ==== install.sh: repository/self.sql (an existing install: refresh the link first) ====
@@repository/self.sql
$STRICT
EOF

  if [[ ${CFG[DOCTOR]} == Y ]]; then
    cat <<EOF

PROMPT ==== install.sh: doctor.sql (preflight) ====
DEFINE cap_doctor_mode = '$(deploy_mode)'
@@doctor.sql
$STRICT
EOF
    [[ ${CFG[FORCE_INSTALL]} == Y ]] || cat <<'EOF'
SET HEADING OFF
SELECT 'install.sh: STOPPED before install. doctor.sql reported &cap_doctor_fail FAIL line(s).'
       || CHR(10) || 'Fix them and re-run, or set FORCE_INSTALL=Y.'
FROM   dual WHERE TO_NUMBER('&cap_doctor_fail') > 0;
SET HEADING ON
COLUMN cap_gate NOPRINT
SELECT CASE WHEN TO_NUMBER('&cap_doctor_fail') > 0 THEN 1/0 ELSE 0 END AS cap_gate FROM dual;
COLUMN cap_gate CLEAR
EOF
  fi

  cat <<EOF

PROMPT ==== install.sh: install.sql (deploy_mode = $(deploy_mode)) ====
DEFINE deploy_mode = '$(deploy_mode)'
@@install.sql
$STRICT
EOF
  [[ ${CFG[ROLE]} == standalone ]] && cat <<EOF

PROMPT ==== install.sh: repository/self.sql ====
@@repository/self.sql
$STRICT
EOF

  # A model that fails to build keeps the previous one and raises ORA-20060
  # after the batch: report it, do not abort the rest of the install.
  [[ ${CFG[TRAIN_ML]} == Y ]] && cat <<'EOF'

PROMPT ==== install.sh: cap_forecast_ml.train_all ====
BEGIN
    cap_forecast_ml.train_all;
    DBMS_OUTPUT.PUT_LINE('  models trained');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  [WARN] train_all: ' || SQLERRM);
        DBMS_OUTPUT.PUT_LINE('         Short history is the usual reason; see CAPF_ESM_HEALTH. The nightly job retries.');
END;
/
EOF

  if [[ ${CFG[JOBS]} == Y ]]; then
    cat <<EOF

PROMPT ==== install.sh: install_jobs.sql ====
DEFINE report_dir       = '${CFG[REPORT_DIR]}'
DEFINE nightly_interval = '${CFG[NIGHTLY_INTERVAL]}'
@@install_jobs.sql
$STRICT
DECLARE
    v_n NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n FROM all_scheduler_jobs
    WHERE  owner = '&cap_target' AND job_name = 'CAP_NIGHTLY_JOB';
    IF v_n = 0 THEN
        RAISE_APPLICATION_ERROR(-20001, 'install.sh: install_jobs.sql created no CAP_NIGHTLY_JOB.'
            || ' See the ORA- lines above (CREATE JOB privilege, nightly_interval).');
    END IF;
END;
/
EOF
    [[ ${CFG[JOBS_ENABLE]} == Y ]] && cat <<EOF
BEGIN
    FOR j IN (SELECT job_name FROM all_scheduler_jobs
              WHERE  owner = '&cap_target'
              AND    job_name IN ($(enable_jobs | sed "s/[A-Z_]\{1,\}/'&'/g; s/ /, /g"))) LOOP
        DBMS_SCHEDULER.ENABLE('"&cap_target"."' || j.job_name || '"');
        DBMS_OUTPUT.PUT_LINE('  enabled ' || j.job_name);
    END LOOP;
END;
/
EOF
  fi

  [[ ${CFG[ORDS]} == Y ]] && printf '\nPROMPT ==== install.sh: ORDS module ====\n@@grafana/ords/awrcap_module.sql &cap_target %s\n%s\n' "${CFG[ORDS_ALIAS]}" "$STRICT"
  [[ ${CFG[APEX]} == Y ]] && printf '\nPROMPT ==== install.sh: APEX application ====\n@@apex/install.sql %s &cap_target %s\n%s\n' "${CFG[APEX_WORKSPACE]}" "${CFG[APEX_APP_ID]}" "$STRICT"

  if [[ ${CFG[RUN_TESTS]} == Y ]]; then
    printf '\nPROMPT ==== install.sh: test/run_test.sql ====\n@@test/run_test.sql\n%s\n' "$STRICT"
    [[ ${CFG[TRAIN_ML]} == Y ]] && printf '@@test/run_test_ml.sql\n%s\n' "$STRICT"
  fi

  if [[ ${CFG[REPORTS]} != none ]]; then
    local r IFS=,
    for r in ${CFG[REPORTS]}; do
      case $r in
        text)  echo "@@report/report.sql - - - - - LIVE" ;;
        html)  echo "@@report/report_html.sql - - - - - LIVE" ;;
        brief) echo "@@report/report_brief.sql - - - - - LIVE" ;;
        csv)   echo "@@report/report_csv.sql - -" ;;
      esac
      echo "$STRICT"
    done
  fi

  cat <<'EOF'

PROMPT
PROMPT ==== install.sh: done, schema &cap_target ====
EXIT
EOF
}

# ---------------------------------------------------------------- main

PROFILE=""; SETS=(); INTERACTIVE=""; SAVE=""; DRY=0; YES=0; PROFILE_NAME=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --profile)       PROFILE=${2:?--profile wants a name or file}; shift ;;
    --set)           SETS+=("${2:?--set wants KEY=VALUE}"); shift ;;
    --interactive)   INTERACTIVE=1 ;;
    --save)          SAVE=${2:?--save wants a file}; shift ;;
    --dry-run)       DRY=1 ;;
    --yes|-y)        YES=1 ;;
    --list-profiles) list_profiles; exit 0 ;;
    -h|--help)       sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *)               die "unknown argument '$1' (see --help)" ;;
  esac
  shift
done

[[ -n $PROFILE ]] && load_profile "$PROFILE"
for s in "${SETS[@]+"${SETS[@]}"}"; do
  [[ $s == *=* ]] || die "--set wants KEY=VALUE, got '$s'"
  set_key "${s%%=*}" "${s#*=}"
done
[[ -z $PROFILE ]] && INTERACTIVE=1

if [[ -n $INTERACTIVE ]]; then
  [[ -r /dev/tty ]] || die "the wizard needs a terminal; pass --profile for a silent install"
  wizard
fi
normalise

# A named user without a password: ask (wizard) or read CAP_DB_PW.
if needs_pw && [[ -z ${CAP_DB_PW:-} ]]; then
  if [[ -n $INTERACTIVE && $DRY == 0 ]]; then
    read -r -s -p "Password for ${CFG[CONNECT]%%[@ ]*}: " CAP_DB_PW </dev/tty; echo
  elif [[ $DRY == 0 ]]; then
    die "CONNECT '${CFG[CONNECT]}' has no password: export CAP_DB_PW"
  fi
fi
if [[ ${CFG[ROLE]} == target && -z ${CAP_READER_PW:-} && $DRY == 0 ]]; then
  die "ROLE=target needs the reader password: export CAP_READER_PW"
fi
[[ ${CAP_DB_PW:-}${CAP_OWNER_PW:-}${CAP_READER_PW:-} != *[\'\"\&]* ]] || die "passwords may not contain quotes or &"
needs_pw || [[ ${CFG[CONNECT]} == /* ]] || echo "install.sh: warning: CONNECT carries a password; keep it out of saved profiles and use CAP_DB_PW" >&2

summary
[[ -n $SAVE ]] && save_profile "$SAVE"
if [[ $DRY == 1 ]]; then
  printf '\n---- driver (dry run, passwords masked) ----\n'
  driver 1
  exit 0
fi

if [[ -n $INTERACTIVE && -z $SAVE ]]; then
  read -r -p "Save these answers as a profile for silent re-runs? File name (Enter = skip): " ans </dev/tty
  [[ -n $ans ]] && save_profile "$ans"
fi
if [[ $YES == 0 ]]; then
  [[ -r /dev/tty ]] || die "no terminal to confirm on; pass --yes for an unattended run"
  read -r -p "Run it now? [y/N]: " ans </dev/tty
  [[ $ans == [yY]* ]] || { echo "nothing done"; exit 0; }
fi

command -v sqlplus >/dev/null 2>&1 || die "sqlplus not on PATH (on the DB host: . oraenv)"
mkdir -p reports
DRIVER="$HERE/.install_driver_$$.sql"
LOG="reports/install_$(date +%Y%m%d_%H%M%S).log"
trap 'rm -f "$DRIVER"' EXIT
( umask 077; driver 0 > "$DRIVER" )

echo "running sqlplus; log: $LOG"
set +e
sqlplus -L /nolog @"$DRIVER" </dev/null 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
if [[ $rc -ne 0 ]]; then
  echo "install.sh: FAILED (sqlplus exit $rc). Last errors:" >&2
  grep -E '(ORA|SP2|PLS)-[0-9]{4,5}' "$LOG" | tail -5 >&2
  exit $rc
fi
nerr=$(grep -c -E '(ORA|SP2|PLS)-[0-9]{4,5}' "$LOG" || true)
[[ $nerr -gt 0 ]] && echo "install.sh: note: $nerr ORA-/SP2-/PLS- line(s) in the log (doctor and the reports report some on purpose); review: grep -nE '(ORA|SP2|PLS)-' $LOG"
echo "install.sh: OK. Log: $LOG"
