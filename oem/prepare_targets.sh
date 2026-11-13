#!/usr/bin/env bash
# oem/prepare_targets.sh -- prepare many targets and register them in the
# repository from the Oracle Enterprise Manager inventory (oem/README.md).
#
#   oem/prepare_targets.sh                       list the candidates
#   oem/prepare_targets.sh --targets A,B         print what to run (the default mode)
#   oem/prepare_targets.sh --match 'prod*'       the same, by a glob on the EM target name
#   oem/prepare_targets.sh --all --out DIR       ... into files under DIR
#   oem/prepare_targets.sh --all --submit --db-cred NC_SYSDBA --host-cred NC_ORACLE
#
# Candidates are the CDBs and non-CDBs Enterprise Manager knows: targets of
# type oracle_database that are no RAC instance, and rac_database. A standby
# is listed and not selectable (prepare its primary: the reader arrives with
# the redo). The inventory is one read-only "emcli list -sql" on the
# repository views MGMT$TARGET, MGMT$TARGET_PROPERTIES, MGMT$DB_DBNINSTANCEINFO
# and MGMT$AVAILABILITY_CURRENT; the EM user needs access to them.
#
# Modes
#   --print   (default) Changes nothing. Prints, per selected target, the
#             commands to run on its host (target/prepare.sql, target/check.sql)
#             and then a SQL*Plus script for the repository with one
#             cap_repo.add_target call per target.
#   --submit  Creates one EM job of type SQLScript per target type that runs
#             target/prepare.sql and target/check.sql on the selected targets,
#             and prints the same repository script. Only a database without
#             the reader is changed: the job gives a new reader a random
#             password made on the server and shown nowhere. An existing
#             reader is left as it is (prepare.sql would reset its password).
#
# Passwords. None is read, written or passed by this script, in any mode.
#   * On a target, target/prepare.sql takes the reader's password from a
#     no-echo prompt: ACCEPT reader_pw CHAR PROMPT '...' HIDE (printed below).
#   * After --submit the reader has a password nobody knows. Set the real one
#     on the target with the SQL*Plus command PASSWORD <reader> (no echo).
#   * The repository script asks for it with ACCEPT ... HIDE and hands it to
#     cap_repo.add_target. --per-target-password asks before every target.
#
# Options
#   --targets LIST        EM target names, comma separated (repeatable)
#   --match GLOB          every candidate whose EM target name matches
#   --all                 every candidate
#   --reader NAME         the reader (default C##AWRRDR in a CDB, AWRRDR in a non-CDB)
#   --per-target-password one password prompt per target in the repository script
#   --out DIR             write add_targets.sql, prepare_targets.txt (and the job
#                         property files) into DIR instead of standard output
#   --db-cred NAME        --submit: named credential, SYSDBA, valid on every selected target
#   --host-cred NAME      --submit: named host credential of the Oracle software owner
#   --job-name NAME       --submit: job name (default AWRCAP_PREPARE_<time>)
#   --inventory FILE      read the inventory from FILE (the tab separated output of
#                         the query, see --inventory-sql) and do not call emcli
#   --inventory-sql       print the inventory query and exit
#
# emcli: $EMCLI names the command, e.g. EMCLI="emcli" or EMCLI="emx raw".
# Default: "emx raw" when emx is on the PATH, else "emcli". Log in first
# (emcli login); this script never handles the EM password either. --submit
# runs "emcli create_job -input_file=property_file:FILE", so emcli must run
# on this machine, or be emx, which copies the file to where emcli runs.
# Needs bash 4.4 or later.
#
# Exit: 0 done, 1 emcli or the job failed, 2 usage or selection error.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

die()  { echo "prepare_targets.sh: $*" >&2; exit 2; }
note() { echo "prepare_targets.sh: $*" >&2; }

INV_SQL="select t.target_name, t.target_type, nvl(trim(t.host_name),'-') host_name, nvl(trim(max(decode(p.property_name,'MachineName',p.property_value))),'-') machine, nvl(trim(max(decode(p.property_name,'Port',p.property_value))),'-') port, nvl(trim(max(decode(p.property_name,'SID',p.property_value))),'-') sid, nvl(trim(max(decode(p.property_name,'DBName',p.property_value))),'-') dbname, nvl(trim(max(decode(p.property_name,'DBDomain',p.property_value))),'-') dbdomain, nvl(trim(max(decode(p.property_name,'ServiceName',p.property_value))),'-') service, nvl(trim(max(decode(p.property_name,'CDB',p.property_value))),'-') cdb, nvl(trim(max(decode(p.property_name,'RACOption',p.property_value))),'-') rac, nvl(trim(max(decode(p.property_name,'DataGuardStatus',p.property_value))),'-') dg, nvl(trim(max(decode(p.property_name,'DBVersion',p.property_value))),'-') version, nvl(trim(max(decode(p.property_name,'OracleHome',p.property_value))),'-') oracle_home, nvl((select trim(max(i.global_name)) from mgmt\$db_dbninstanceinfo i where i.target_guid = t.target_guid),'-') global_name, nvl((select trim(max(i.database_unique_name)) from mgmt\$db_dbninstanceinfo i where i.target_guid = t.target_guid),'-') db_unique_name, nvl((select trim(max(a.availability_status)) from mgmt\$availability_current a where a.target_guid = t.target_guid),'-') status from mgmt\$target t left join mgmt\$target_properties p on p.target_guid = t.target_guid where t.target_type in ('oracle_database','rac_database') group by t.target_name, t.target_type, t.host_name, t.target_guid order by t.target_type, t.target_name"
N_FIELDS=17

mode=""; reader=""; out=""; inventory=""; match=""; all=0; per_pw=0
db_cred=""; host_cred=""; job_name=""
declare -a want=()

while [ $# -gt 0 ]; do
  case "$1" in
    --list)                 mode=list;;
    --print)                mode=print;;
    --submit)               mode=submit;;
    --targets)              [ $# -ge 2 ] || die "--targets needs a list"
                            IFS=',' read -r -a more <<<"$2"; want+=("${more[@]}"); shift;;
    --match)                [ $# -ge 2 ] || die "--match needs a glob"; match=$2; shift;;
    --all)                  all=1;;
    --reader)               [ $# -ge 2 ] || die "--reader needs a name"; reader=$2; shift;;
    --per-target-password)  per_pw=1;;
    --out)                  [ $# -ge 2 ] || die "--out needs a directory"; out=$2; shift;;
    --db-cred)              [ $# -ge 2 ] || die "--db-cred needs a name"; db_cred=$2; shift;;
    --host-cred)            [ $# -ge 2 ] || die "--host-cred needs a name"; host_cred=$2; shift;;
    --job-name)             [ $# -ge 2 ] || die "--job-name needs a name"; job_name=$2; shift;;
    --inventory)            [ $# -ge 2 ] || die "--inventory needs a file"; inventory=$2; shift;;
    --inventory-sql)        printf '%s\n' "$INV_SQL"; exit 0;;
    -h|--help)              sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0;;
    *)                      die "unknown option $1 (see --help)";;
  esac
  shift
done

selected=0
if [ ${#want[@]} -gt 0 ] || [ -n "$match" ] || [ "$all" = 1 ]; then selected=1; fi
[ -n "$mode" ] || { [ "$selected" = 1 ] && mode=print || mode=list; }
if [ "$mode" != list ] && [ "$selected" = 0 ]; then
  die "name the targets: --targets LIST, --match GLOB or --all"
fi
if [ -n "$reader" ]; then
  reader=$(printf '%s' "$reader" | tr '[:lower:]' '[:upper:]')
  [[ "$reader" =~ ^[A-Z][A-Z0-9_\$#]{0,127}$ ]] || die "--reader must be a plain SQL name, not $reader"
fi
if [ "$mode" = submit ]; then
  [ -n "$db_cred" ] && [ -n "$host_cred" ] || die "--submit needs --db-cred NAME and --host-cred NAME (named credentials)"
  [[ "$db_cred$host_cred" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "credential names: letters, digits, _ . : - only"
  [ -n "$job_name" ] || job_name="AWRCAP_PREPARE_$(date +%Y%m%d%H%M%S)"
  [[ "$job_name" =~ ^[A-Za-z][A-Za-z0-9_]{0,50}$ ]] || die "--job-name: a letter, then letters, digits or _"
  [ -f "$repo/target/prepare.sql" ] && [ -f "$repo/target/check.sql" ] \
    || die "target/prepare.sql and target/check.sql not found under $repo"
fi

# ---- emcli -------------------------------------------------------------------
declare -a emcli=()
if [ -n "${EMCLI:-}" ]; then
  read -r -a emcli <<<"$EMCLI"
elif command -v emx >/dev/null 2>&1; then
  emcli=(emx raw)
else
  emcli=(emcli)
fi

# ---- inventory ---------------------------------------------------------------
if [ -n "$inventory" ]; then
  [ -r "$inventory" ] || die "cannot read $inventory"
  inv=$(cat "$inventory")
else
  command -v "${emcli[0]}" >/dev/null 2>&1 \
    || die "${emcli[0]} not found: set EMCLI, or pass --inventory FILE"
  if ! inv=$("${emcli[@]}" list "-sql=$INV_SQL" "-format=name:script"); then
    printf '%s\n' "$inv" >&2
    note "emcli list -sql failed (logged in? access to the repository views?)"
    exit 1
  fi
fi

declare -a t_name=() t_type=() t_host=() t_port=() t_sid=() t_cdb=() t_dg=() t_ver=() t_home=()
declare -a t_gname=() t_status=() t_why=() t_cap=() t_conn=() t_rac=()
declare -A seen_cap=() idx_of=()

sanitize() {   # upper case, anything but A-Z 0-9 _ becomes _
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed -e 's/[^A-Z0-9_]/_/g' -e 's/__*/_/g' -e 's/^_//' -e 's/_$//'
}

n=0
while IFS=$'\t' read -r name type host machine port sid dbname dbdomain service cdb rac dg ver home gname uname status extra; do
  [ "$name" = TARGET_NAME ] && continue
  case "$type" in oracle_database|rac_database) ;; *) continue;; esac
  if [ -z "$status" ] || [ -n "$extra" ]; then
    note "skipped an inventory line that has not $N_FIELDS fields: $name"; continue
  fi
  [ "$machine" = - ] && machine=$host
  [ "$uname" = - ] && uname=$dbname
  why=""
  if [ "$type" = oracle_database ] && [ "$rac" = YES ]; then
    why="RAC instance: select its cluster database"
  elif [[ "$dg" == *[Ss]tandby* ]]; then
    why="standby: prepare its primary"
  elif [ "$uname" = - ] || [ "$machine" = - ] || [ "$port" = - ]; then
    why="the inventory has no name, host or port for it"
  fi
  # //host:port/service, as target/prepare.sql prints it: the default service
  # is DB_UNIQUE_NAME[.DB_DOMAIN]. A cluster database has ServiceName.
  svc=$service
  if [ "$svc" = - ]; then
    svc=$(printf '%s' "$uname" | tr '[:upper:]' '[:lower:]')
    [ "$dbdomain" != - ] && svc="$svc.$dbdomain"
  fi
  t_name[n]=$name; t_type[n]=$type; t_host[n]=$machine; t_port[n]=$port; t_sid[n]=$sid
  t_cdb[n]=$cdb; t_dg[n]=$dg; t_ver[n]=$ver; t_home[n]=$home; t_gname[n]=$gname
  t_status[n]=$status; t_why[n]=$why; t_rac[n]=$rac
  t_conn[n]="//$machine:$port/$svc"
  t_cap[n]=$(sanitize "$uname")
  idx_of[$name]=$n
  n=$((n + 1))
done <<<"$inv"

[ "$n" -gt 0 ] || { note "the inventory lists no oracle_database or rac_database target"; exit 1; }

# ---- selection -----------------------------------------------------------------
declare -a sel=()
if [ "$selected" = 1 ]; then
  for w in "${want[@]}"; do
    [ -n "${idx_of[$w]:-}" ] || die "no database target $w in the inventory (run without options to list them)"
  done
  for ((i = 0; i < n; i++)); do
    pick=0
    [ "$all" = 1 ] && pick=1
    # shellcheck disable=SC2053
    [ -n "$match" ] && [[ "${t_name[i]}" == $match ]] && pick=1
    explicit=0
    for w in "${want[@]}"; do [ "$w" = "${t_name[i]}" ] && explicit=1; done
    if [ "$explicit" = 1 ]; then
      [ -z "${t_why[i]}" ] || die "${t_name[i]} is not a candidate (${t_why[i]})"
      pick=1
    fi
    [ "$pick" = 1 ] && [ -z "${t_why[i]}" ] && sel+=("$i")
  done
  [ ${#sel[@]} -gt 0 ] || die "the selection matches no candidate"
fi

# ---- repository names: UPPER(DB_UNIQUE_NAME); two selected databases with the
# same name both get the short host name appended. cap_repo allows a letter
# and up to 25 letters, digits or _.
if [ ${#sel[@]} -gt 0 ]; then
  declare -A count=()
  for i in "${sel[@]}"; do count[${t_cap[i]}]=$(( ${count[${t_cap[i]}]:-0} + 1 )); done
  for i in "${sel[@]}"; do
    c=${t_cap[i]}
    if [ "${count[$c]}" -gt 1 ]; then
      h=$(sanitize "${t_host[i]%%.*}")
      c="${c:0:$((25 - ${#h} > 4 ? 25 - ${#h} : 4))}_$h"
    fi
    c=${c:0:26}; c=${c%_}
    [[ "$c" =~ ^[A-Z][A-Z0-9_]{0,25}$ ]] \
      || die "cannot make a repository name for ${t_name[i]} (got '$c'): register it by hand"
    [ -z "${seen_cap[$c]:-}" ] \
      || die "${t_name[i]} and ${seen_cap[$c]} both come out as $c: register one of them by hand"
    seen_cap[$c]=${t_name[i]}
    t_cap[i]=$c
  done
fi

reader_of() {   # the reader on target i
  if [ -n "$reader" ]; then printf '%s' "$reader"
  elif [ "${t_cdb[$1]}" = NO ]; then printf 'AWRRDR'
  else printf 'C##AWRRDR'; fi
}

# ---- list ----------------------------------------------------------------------
if [ "$mode" = list ]; then
  printf '%-34s %-15s %-8s %-12s %-28s %-18s %s\n' "EM TARGET" TYPE CDB VERSION HOST STATUS NOTE
  for ((i = 0; i < n; i++)); do
    printf '%-34s %-15s %-8s %-12s %-28s %-18s %s\n' "${t_name[i]}" "${t_type[i]}" "${t_cdb[i]}" \
      "${t_ver[i]}" "${t_host[i]}" "${t_status[i]}" "${t_why[i]:+not a candidate: ${t_why[i]}}"
  done
  echo
  echo "Select with --targets NAME[,NAME], --match GLOB or --all."
  exit 0
fi

for i in "${sel[@]}"; do
  if [ "${t_cdb[i]}" != NO ] && [ -n "$reader" ] && [[ "$reader" != C##* ]]; then
    die "${t_name[i]} is a CDB: its reader must be a common user (C##...), not $reader"
  fi
  [ "${t_status[i]}" = "Target Up" ] || [ "${t_status[i]}" = Up ] \
    || note "warning: ${t_name[i]} is '${t_status[i]}' in Enterprise Manager"
done

# ---- what to run on each target --------------------------------------------------
print_targets() {
  echo "# Per target: run target/prepare.sql and target/check.sql as SYSDBA in"
  echo "# CDB\$ROOT (or the non-CDB), from a copy of this repository on its host."
  echo "# The password is typed at a prompt that does not echo. Nothing here"
  echo "# holds one."
  for i in "${sel[@]}"; do
    echo
    echo "# == ${t_name[i]}  (${t_type[i]}, ${t_ver[i]}, ${t_status[i]})  ->  repository name ${t_cap[i]}"
    [ "${t_rac[i]}" = YES ] && echo "#    Cluster database: run it on one instance."
    echo "#    host ${t_host[i]}, ORACLE_SID ${t_sid[i]}, ORACLE_HOME ${t_home[i]}"
    echo "sqlplus /nolog"
    echo "  CONNECT / AS SYSDBA"
    echo "  DEFINE reader = $(reader_of "$i")"
    echo "  ACCEPT reader_pw CHAR PROMPT 'Password for the reader (not shown): ' HIDE"
    echo "  @target/prepare.sql"
    echo "  @target/check.sql"
  done
}

# ---- the repository script --------------------------------------------------------
print_add_targets() {
  cat <<EOF
--
-- add_targets.sql -- register $((${#sel[@]})) target(s) in the repository.
-- Written by oem/prepare_targets.sh from the Enterprise Manager inventory.
-- It holds no password: SQL*Plus asks for the reader's at a prompt that does
-- not echo. Run it in a terminal, as the suite owner on the repository:
--   sqlplus /nolog
--   SQL> CONNECT <owner>@<repository>
--   SQL> @add_targets.sql
-- Each address is the inventory's host and port and the database's default
-- service. target/prepare.sql prints the call with the address it sees on
-- the target: where they differ, that one is right. A cluster database
-- wants its SCAN name. A target that is registered already fails with
-- ORA-20073 and the script goes on.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/oem/add_targets.sql"
SET DEFINE '&'
SET VERIFY OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE
EOF
  [ "$per_pw" = 1 ] || echo "ACCEPT cap_reader_pw CHAR PROMPT 'Password of the reader on the targets (not shown): ' HIDE"
  for i in "${sel[@]}"; do
    echo
    echo "PROMPT == ${t_cap[i]}  (${t_name[i]})"
    [ "$per_pw" = 1 ] && echo "ACCEPT cap_reader_pw CHAR PROMPT 'Password of $(reader_of "$i") on ${t_cap[i]} (not shown): ' HIDE"
    g=""
    [ "${t_gname[i]}" != - ] && g=", p_global_name => '${t_gname[i]}'"
    echo "EXEC cap_repo.add_target('${t_cap[i]}', '${t_conn[i]}', '$(reader_of "$i")', q'~&cap_reader_pw~'$g)"
  done
  cat <<'EOF'

UNDEFINE cap_reader_pw
PROMPT
PROMPT Next: EXEC cap_repo.collect  (the first collect of a target copies all the AWR history it holds).
EOF
}

# ---- the job script: runs as SYSDBA through the EM job system --------------------
job_script() {
  cat <<'EOF'
WHENEVER OSERROR EXIT FAILURE
SET DEFINE '&'
SET VERIFY OFF
SET FEEDBACK OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
EOF
  [ -z "$reader" ] || echo "DEFINE reader = $reader"
  cat <<'EOF'
COLUMN cap_r_in NEW_VALUE reader NOPRINT
SELECT NULL AS cap_r_in FROM dual WHERE 1 = 0;
COLUMN cap_r_in CLEAR
WHENEVER SQLERROR EXIT SUCCESS
DECLARE
    v_reader VARCHAR2(128) := UPPER(NVL('&reader',
                                CASE WHEN SYS_CONTEXT('USERENV', 'CON_ID') = '1'
                                     THEN 'C##AWRRDR' ELSE 'AWRRDR' END));
    v_n      NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n FROM dba_users WHERE username = v_reader;
    IF v_n > 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'AWRCAP-SKIP: reader ' || v_reader || ' exists here and is left'
            || ' as it is (target/prepare.sql would reset its password). Nothing was changed.');
    END IF;
END;
/
WHENEVER SQLERROR EXIT FAILURE
COLUMN cap_oem_pw NEW_VALUE reader_pw NOPRINT
SELECT 'Rd' || DBMS_RANDOM.STRING('X', 22) || 'q7_' AS cap_oem_pw FROM dual;
COLUMN cap_oem_pw CLEAR
EOF
  cat "$repo/target/prepare.sql"
  cat "$repo/target/check.sql"
  echo "EXIT"
}

job_props() {   # job_props <job name> <target type> <indexes...>
  local jname=$1 jtype=$2; shift 2
  echo "name=$jname"
  echo "type=SQLScript"
  echo "description=AWR capacity suite: target/prepare.sql and target/check.sql, new readers only"
  echo "targetType=$jtype"
  local i
  for i in "$@"; do echo "target_list=${t_name[i]}:$jtype"; done
  for i in "$@"; do
    echo "cred.defaultDBCred.${t_name[i]}:$jtype=NAMED:$db_cred"
    echo "cred.defaultHostCred.${t_name[i]}:$jtype=NAMED:$host_cred"
  done
  echo "variable.large_sql_script=<<AWRCAPSCRIPT"
  job_script
  echo "AWRCAPSCRIPT"
  echo "schedule.frequency=IMMEDIATE"
}

after_submit() {
  echo "# The job changes a database only where the reader did not exist. There"
  echo "# the reader now has a random password that nobody knows. Set the real"
  echo "# one on each such target, at a prompt that does not echo:"
  for i in "${sel[@]}"; do
    echo "#   ${t_name[i]}  (host ${t_host[i]}, ORACLE_SID ${t_sid[i]}):"
    echo "#     sqlplus / as sysdba   then   PASSWORD $(reader_of "$i")"
  done
  echo "# A job output line AWRCAP-SKIP means the reader existed and nothing"
  echo "# was changed on that database."
}

# ---- output --------------------------------------------------------------------
if [ -n "$out" ]; then
  mkdir -p "$out"
  print_add_targets > "$out/add_targets.sql"
  [ "$mode" = print ] && print_targets > "$out/prepare_targets.txt"
else
  [ "$mode" = print ] && { print_targets; echo; }
fi

rc=0
if [ "$mode" = submit ]; then
  work=$out
  [ -n "$work" ] || work=$(mktemp -d "${TMPDIR:-/tmp}/awrcap_oem.XXXXXX")
  declare -a types=()
  for ty in oracle_database rac_database; do
    for i in "${sel[@]}"; do [ "${t_type[i]}" = "$ty" ] && { types+=("$ty"); break; }; done
  done
  for ty in "${types[@]}"; do
    declare -a of_type=()
    for i in "${sel[@]}"; do [ "${t_type[i]}" = "$ty" ] && of_type+=("$i"); done
    jname=$job_name
    [ ${#types[@]} -gt 1 ] && [ "$ty" = rac_database ] && jname="${job_name}_RAC"
    f="$work/$jname.props"
    ( umask 077; job_props "$jname" "$ty" "${of_type[@]}" > "$f" )
    note "submitting job $jname for ${#of_type[@]} target(s) of type $ty"
    # emx copies the file to where emcli runs (it may be on the OMS host).
    if [ "$(basename "${emcli[0]}")" = emx ]; then
      "${emcli[0]}" job run "$jname" --type SQLScript --props-file "$f" || rc=1
    else
      "${emcli[@]}" create_job "-name=$jname" "-type=SQLScript" "-input_file=property_file:$f" || rc=1
    fi
    unset of_type
  done
  [ -n "$out" ] || rm -rf "$work"
  [ "$rc" = 0 ] || note "a job was not created: see the emcli output above"
  if [ -n "$out" ]; then after_submit > "$out/after_submit.txt"; else after_submit; echo; fi
fi

if [ -n "$out" ]; then
  note "wrote $(cd "$out" && ls | tr '\n' ' ')into $out"
else
  print_add_targets
fi
exit "$rc"
