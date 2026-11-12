#!/usr/bin/env bash
# test/oem_test.sh -- the Enterprise Manager hook (oem/), no OMS and no Oracle.
# A mock emcli (and a mock emx) answer "list -sql" with a canned inventory
# and record every call. The inventory has the shapes a real one showed
# (EM 24.1): two CDBs with the same name on two hosts, a Data Guard pair, a
# cluster database with its two instances, a non-CDB, a target that is down
# and has no global name.
#   1. no option            -> lists every target, names the non-candidates
#   2. selection errors     -> unknown, standby, RAC instance, no candidate: exit 2
#   3. --targets / --match  -> exactly the named or matching candidates
#   4. --all                -> candidates only; names, addresses, readers, global names
#   5. the default mode     -> prints prepare.sql / check.sql steps, calls only "list"
#   6. no password          -> none in any output, file or emcli argument; the
#                              repository script asks with ACCEPT ... HIDE
#   7. --submit             -> one SQLScript job per target type, named credentials,
#                              target/prepare.sql and target/check.sql verbatim inside
#   8. --submit failures    -> missing credentials: exit 2, nothing called; emcli fails: exit 1
#   9. --out DIR            -> the files, nothing but notes on standard output
#  10. the metric extension -> the statement oem/README.md extracts is one plain
#                              SELECT with the eight documented columns
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/oem_test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/jobs"
PT="$HERE/oem/prepare_targets.sh"
export MOCK_LOG="$T/calls.log" MOCK_INV="$T/inventory.tsv" MOCK_JOBS="$T/jobs"

row() { local IFS=$'\t'; printf '%s\n' "$*"; }
{
  row TARGET_NAME TARGET_TYPE HOST_NAME MACHINE PORT SID DBNAME DBDOMAIN SERVICE CDB RAC DG VERSION ORACLE_HOME GLOBAL_NAME DB_UNIQUE_NAME STATUS
  row prod1_db01      oracle_database db01.example.com  db01.example.com  1521 prod1  prod1      example.com - YES NO  Primary            19.27.0.0.0 /u01/oh19 PROD1.EXAMPLE.COM  prod1      "Target Up"
  row prod1_stby_db02 oracle_database db02.example.com  db02.example.com  1521 prod1  prod1_stby example.com - YES NO  "Physical Standby" 19.27.0.0.0 /u01/oh19 PROD1.EXAMPLE.COM  prod1_stby "Target Up"
  row hr_db03         oracle_database db03.example.com  db03.example.com  1521 hr     hr         -           - YES NO  None               19.23.0.0.0 /u01/oh19 HR                 hr         "Target Up"
  row hr_db04         oracle_database db04.example.com  db04.example.com  1521 hr     hr         -           - YES NO  None               19.23.0.0.0 /u01/oh19 HR                 hr         "Target Up"
  row legacy_db05     oracle_database db05.example.com  db05.example.com  1522 legacy legacy     example.com - NO  NO  None               19.20.0.0.0 /u01/oh19 LEGACY.EXAMPLE.COM legacy     "Target Up"
  row dw_db06         oracle_database db06.example.com  -                 1521 dw     dw         -           - YES NO  None               19.27.0.0.0 /u01/oh19 -                  -          "Target Down"
  row racdb_racdb1    oracle_database rac01.example.com rac01.example.com 1521 racdb1 racdb      -           - YES YES None               19.27.0.0.0 /u01/oh19 RACDB.EXAMPLE.COM  racdb      "Target Up"
  row racdb_racdb2    oracle_database rac02.example.com rac02.example.com 1521 racdb2 racdb      -           - YES YES None               19.27.0.0.0 /u01/oh19 RACDB.EXAMPLE.COM  racdb      "Target Up"
  row racdb           rac_database    rac01.example.com rac01.example.com 1521 racdb1 racdb      -           racdb.example.com YES YES None 19.27.0.0.0 /u01/oh19 RACDB.EXAMPLE.COM racdb     "Target Up"
} > "$MOCK_INV"

cat > "$T/bin/emcli" <<'MOCK'
#!/usr/bin/env bash
{ printf 'emcli'; printf ' [%s]' "$@"; printf '\n'; } >> "$MOCK_LOG"
case "${1:-}" in
  list)       cat "$MOCK_INV";;
  create_job) for a in "$@"; do
                case "$a" in -input_file=property_file:*) cp "${a#-input_file=property_file:}" "$MOCK_JOBS/";; esac
              done
              if [ -n "${MOCK_FAIL:-}" ]; then echo "Error: Named credential not found"; exit 1; fi
              echo "Creation of job was successful.";;
  *)          echo "mock emcli: unexpected verb ${1:-}"; exit 3;;
esac
MOCK
cat > "$T/bin/emx" <<'MOCK'
#!/usr/bin/env bash
{ printf 'emx'; printf ' [%s]' "$@"; printf '\n'; } >> "$MOCK_LOG"
case "${1:-} ${2:-}" in
  "raw list") cat "$MOCK_INV";;
  "job run")  while [ $# -gt 0 ]; do [ "$1" = --props-file ] && cp "$2" "$MOCK_JOBS/"; shift; done
              echo "Creation of job was successful.";;
  *)          echo "mock emx: unexpected call $*"; exit 3;;
esac
MOCK
chmod +x "$T/bin/emcli" "$T/bin/emx"
export EMCLI="$T/bin/emcli"

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }   # check <name> <shell test>
run()   { : > "$MOCK_LOG"; "$PT" "$@" > "$T/out" 2> "$T/err"; rc=$?; }
has()   { grep -qF -- "$1" "$T/out"; }
calls() { grep -c . "$MOCK_LOG"; }

# ---- 1. list ------------------------------------------------------------------
run
check "list: exit 0"                               '[ $rc -eq 0 ]'
check "list: nine targets"                         '[ "$(grep -cE " (oracle|rac)_database " "$T/out")" -eq 9 ]'
check "list: the standby is no candidate"          'grep -qE "^prod1_stby_db02 .*not a candidate: standby" "$T/out"'
check "list: RAC instances are no candidates"      '[ "$(grep -c "not a candidate: RAC instance" "$T/out")" -eq 2 ]'
check "list: six candidates carry no note"         '[ "$(grep -E " (oracle|rac)_database " "$T/out" | grep -vc "not a candidate")" -eq 6 ]'
check "list: one emcli call, the verb list"        '[ "$(calls)" -eq 1 ] && grep -q "^emcli \[list\] \[-sql=select " "$MOCK_LOG"'
check "list: the query reads the four repository views" \
      'for v in "mgmt\$target " "mgmt\$target_properties" "mgmt\$db_dbninstanceinfo" "mgmt\$availability_current"; do grep -qF "$v" "$MOCK_LOG" || exit 1; done'

# ---- 2. selection errors --------------------------------------------------------
run --targets nosuch_db
check "unknown target: exit 2"                     '[ $rc -eq 2 ] && grep -q "no database target nosuch_db" "$T/err"'
run --targets prod1_stby_db02
check "standby named: exit 2"                      '[ $rc -eq 2 ] && grep -q "not a candidate (standby" "$T/err"'
run --targets racdb_racdb1
check "RAC instance named: exit 2"                 '[ $rc -eq 2 ] && grep -q "not a candidate (RAC instance" "$T/err"'
run --match 'prod1_stby*'
check "glob on non-candidates only: exit 2"        '[ $rc -eq 2 ] && grep -q "matches no candidate" "$T/err"'
run --print
check "--print without a selection: exit 2"        '[ $rc -eq 2 ]'
run --all --reader awrrdr
check "a local reader name on a CDB: exit 2"       '[ $rc -eq 2 ] && grep -q "must be a common user" "$T/err"'
run --all --reader 'x;y'
check "a reader that is no SQL name: exit 2"       '[ $rc -eq 2 ]'

# ---- 3. --targets / --match -------------------------------------------------------
run --targets hr_db03,legacy_db05
check "--targets: exit 0, two add_target calls"    '[ $rc -eq 0 ] && [ "$(grep -c "^EXEC cap_repo.add_target" "$T/out")" -eq 2 ]'
check "--targets: a name used once stays bare" \
      'has "EXEC cap_repo.add_target('"'HR', '//db03.example.com:1521/hr', 'C##AWRRDR', q'~&cap_reader_pw~', p_global_name => 'HR')"'"'
check "--targets: a non-CDB gets AWRRDR, its port and its domain" \
      'has "EXEC cap_repo.add_target('"'LEGACY', '//db05.example.com:1522/legacy.example.com', 'AWRRDR', q'~&cap_reader_pw~', p_global_name => 'LEGACY.EXAMPLE.COM')"'"'
run --match 'prod1*'
check "--match: the primary only, the standby dropped" \
      '[ $rc -eq 0 ] && [ "$(grep -c "^EXEC cap_repo.add_target" "$T/out")" -eq 1 ] && has "add_target('"'PROD1', '//db01.example.com:1521/prod1.example.com'"'"'

# ---- 4. --all -----------------------------------------------------------------------
run --all
check "--all: exit 0, six add_target calls"        '[ $rc -eq 0 ] && [ "$(grep -c "^EXEC cap_repo.add_target" "$T/out")" -eq 6 ]'
check "--all: no call for a standby or a RAC instance" '! grep -qE "add_target.*(db02|rac02)" "$T/out"'
check "--all: two databases of one name get the host" \
      'has "add_target('"'HR_DB03', '//db03.example.com:1521/hr'"'" && has "add_target('"'HR_DB04', '//db04.example.com:1521/hr'"'"'
check "--all: the cluster database uses ServiceName" \
      'has "EXEC cap_repo.add_target('"'RACDB', '//rac01.example.com:1521/racdb.example.com', 'C##AWRRDR', q'~&cap_reader_pw~', p_global_name => 'RACDB.EXAMPLE.COM')"'"'
check "--all: no global name, no p_global_name; host and name fall back" \
      'has "EXEC cap_repo.add_target('"'DW', '//db06.example.com:1521/dw', 'C##AWRRDR', q'~&cap_reader_pw~')"'"'
check "--all: a target that is down is named on stderr" 'grep -q "warning: dw_db06 is .Target Down." "$T/err"'
check "--all: every repository name fits cap_repo" \
      '! grep "^EXEC cap_repo.add_target" "$T/out" | sed -e "s/^[^'"'"']*'"'"'//" -e "s/'"'"'.*//" | grep -qvE "^[A-Z][A-Z0-9_]{0,25}$"'
run --all --reader c##capread
check "--reader: used for every target, upper case" '[ $rc -eq 0 ] && [ "$(grep "^EXEC cap_repo.add_target" "$T/out" | grep -c "'"'C##CAPREAD'"'")" -eq 6 ]'

# ---- 5. the default mode prints, and only reads -------------------------------------
run --all
check "print: prepare.sql and check.sql per target" \
      '[ "$(grep -c "^  @target/prepare.sql" "$T/out")" -eq 6 ] && [ "$(grep -c "^  @target/check.sql" "$T/out")" -eq 6 ]'
check "print: the reader per target (one non-CDB)" \
      '[ "$(grep -c "^  DEFINE reader = C##AWRRDR" "$T/out")" -eq 5 ] && [ "$(grep -c "^  DEFINE reader = AWRRDR" "$T/out")" -eq 1 ]'
check "print: the target password is a no-echo prompt" \
      '[ "$(grep -c "^  ACCEPT reader_pw CHAR PROMPT .* HIDE$" "$T/out")" -eq 6 ]'
check "print: only the verb list reached emcli"    '[ "$(calls)" -eq 1 ] && ! grep -qv "^emcli \[list\]" "$MOCK_LOG"'
check "print: the repository script is labelled and quiet" \
      'has "SET APPINFO \"AWRCAP/oem/add_targets.sql\"" && has "SET VERIFY OFF"'

# ---- 6. no password anywhere ------------------------------------------------------
no_secret() {   # <file>: no password value, only prompts and the substitution
  ! grep -iE "(^|[^A-Za-z])DEFINE +(cap_)?reader_pw|IDENTIFIED BY +[^\"' ]|-password|passwd=" "$1" | grep -q .
}
check "no password: standard output"               'no_secret "$T/out"'
check "no password: the emcli arguments"           '! grep -qiE "passw|reader_pw" "$MOCK_LOG"'
check "no password: one hidden prompt, before the first call" \
      '[ "$(grep -c "^ACCEPT cap_reader_pw CHAR PROMPT .* HIDE$" "$T/out")" -eq 1 ] &&
       [ "$(grep -n "^ACCEPT cap_reader_pw" "$T/out" | cut -d: -f1)" -lt "$(grep -n "^EXEC cap_repo.add_target" "$T/out" | head -1 | cut -d: -f1)" ]'
check "no password: every call takes it from the prompt" \
      '[ "$(grep "^EXEC cap_repo.add_target" "$T/out" | grep -c "q'"'"'~&cap_reader_pw~'"'"'")" -eq 6 ]'
check "no password: the variable is dropped at the end" 'has "UNDEFINE cap_reader_pw"'
check "no password: the script reads none itself"  '! grep -qE "read +-s|stty|getpass" "$PT"'
run --all --per-target-password
check "--per-target-password: one prompt per target" \
      '[ $rc -eq 0 ] && [ "$(grep -c "^ACCEPT cap_reader_pw CHAR PROMPT .* HIDE$" "$T/out")" -eq 6 ]'

# ---- 7. --submit ------------------------------------------------------------------
rm -f "$T/jobs"/*
run --all --submit --db-cred NC_SYSDBA --host-cred NC_ORACLE --job-name AWRCAP_T
check "submit: exit 0"                             '[ $rc -eq 0 ]'
check "submit: list, then one create_job per target type" \
      '[ "$(calls)" -eq 3 ] && [ "$(grep -c "^emcli \[create_job\] \[-name=AWRCAP_T\(_RAC\)\{0,1\}\] \[-type=SQLScript\] \[-input_file=property_file:" "$MOCK_LOG")" -eq 2 ]'
P="$T/jobs/AWRCAP_T.props"; R="$T/jobs/AWRCAP_T_RAC.props"
check "submit: both property files reached emcli"  '[ -s "$P" ] && [ -s "$R" ]'
check "submit: five single databases in one job"   '[ "$(grep -c "^target_list=.*:oracle_database$" "$P")" -eq 5 ] && grep -q "^targetType=oracle_database$" "$P"'
check "submit: the cluster database in its own"    '[ "$(grep -c "^target_list=" "$R")" -eq 1 ] && grep -q "^target_list=racdb:rac_database$" "$R"'
check "submit: named credentials for every target" \
      '[ "$(grep -c "^cred.defaultDBCred\..*=NAMED:NC_SYSDBA$" "$P")" -eq 5 ] && [ "$(grep -c "^cred.defaultHostCred\..*=NAMED:NC_ORACLE$" "$P")" -eq 5 ]'
check "submit: job type, name and schedule"        'grep -q "^type=SQLScript$" "$P" && grep -q "^name=AWRCAP_T$" "$P" && grep -q "^schedule.frequency=IMMEDIATE$" "$P"'
sed -n '/^variable.large_sql_script=<<AWRCAPSCRIPT$/,/^AWRCAPSCRIPT$/p' "$P" | sed -e '1d' -e '$d' > "$T/script.sql"
check "submit: the script is one heredoc value"    '[ -s "$T/script.sql" ] && [ "$(grep -c "^AWRCAPSCRIPT$" "$P")" -eq 1 ]'
n_pre=$(grep -c . "$HERE/target/prepare.sql"); n_chk=$(grep -c . "$HERE/target/check.sql")
check "submit: target/prepare.sql and target/check.sql verbatim, then EXIT" \
      'tail -n $(( $(wc -l < "$HERE/target/prepare.sql") + $(wc -l < "$HERE/target/check.sql") + 1 )) "$T/script.sql" \
         | diff -q - <(cat "$HERE/target/prepare.sql" "$HERE/target/check.sql"; echo EXIT) >/dev/null && [ "$n_pre" -gt 50 ] && [ "$n_chk" -gt 50 ]'
head -n $(( $(wc -l < "$T/script.sql") - $(wc -l < "$HERE/target/prepare.sql") - $(wc -l < "$HERE/target/check.sql") - 1 )) "$T/script.sql" > "$T/wrapper.sql"
check "submit: an existing reader ends the script before prepare.sql" \
      'grep -q "^WHENEVER SQLERROR EXIT SUCCESS$" "$T/wrapper.sql" && grep -q "AWRCAP-SKIP" "$T/wrapper.sql" && grep -q "FROM dba_users WHERE username = v_reader" "$T/wrapper.sql"'
check "submit: a new reader gets a server-made password, never printed" \
      'grep -q "^COLUMN cap_oem_pw NEW_VALUE reader_pw NOPRINT$" "$T/wrapper.sql" && grep -q "DBMS_RANDOM.STRING" "$T/wrapper.sql" && grep -q "^SET VERIFY OFF$" "$T/wrapper.sql"'
check "submit: failures are fatal again before prepare.sql" \
      '[ "$(grep -n "^WHENEVER SQLERROR EXIT FAILURE$" "$T/wrapper.sql" | tail -1 | cut -d: -f1)" -gt "$(grep -n "^WHENEVER SQLERROR EXIT SUCCESS$" "$T/wrapper.sql" | cut -d: -f1)" ]'
check "submit: no password in the wrapper or the calls" 'no_secret "$T/wrapper.sql" && ! grep -qiE "passw|reader_pw" "$MOCK_LOG"'
check "submit: says how the real password is set"  'has "PASSWORD C##AWRRDR" && has "PASSWORD AWRRDR"'
check "submit: still prints the repository script" '[ "$(grep -c "^EXEC cap_repo.add_target" "$T/out")" -eq 6 ]'
rm -f "$T/jobs"/*
run --targets hr_db03 --submit --db-cred NC_SYSDBA --host-cred NC_ORACLE --job-name AWRCAP_ONE --reader C##CAPREAD
check "submit: one type, one job, no suffix"       '[ $rc -eq 0 ] && [ "$(calls)" -eq 2 ] && [ -s "$T/jobs/AWRCAP_ONE.props" ]'
check "submit: --reader reaches the job script"    'grep -q "^DEFINE reader = C##CAPREAD$" "$T/jobs/AWRCAP_ONE.props"'
rm -f "$T/jobs"/*
EMCLI="$T/bin/emx raw" run --targets hr_db03 --submit --db-cred NC_SYSDBA --host-cred NC_ORACLE --job-name AWRCAP_EMX
check "submit through emx: emx job run with the property file" \
      '[ $rc -eq 0 ] && grep -q "^emx \[job\] \[run\] \[AWRCAP_EMX\] \[--type\] \[SQLScript\] \[--props-file\] " "$MOCK_LOG" && [ -s "$T/jobs/AWRCAP_EMX.props" ]'

# ---- 8. --submit failures -----------------------------------------------------------
run --all --submit --db-cred NC_SYSDBA
check "submit without --host-cred: exit 2, emcli not called" '[ $rc -eq 2 ] && [ "$(calls)" -eq 0 ]'
run --all --submit --db-cred 'NC SYSDBA' --host-cred NC_ORACLE
check "submit with a bad credential name: exit 2"  '[ $rc -eq 2 ] && [ "$(calls)" -eq 0 ]'
MOCK_FAIL=1 run --targets hr_db03 --submit --db-cred NC_SYSDBA --host-cred NC_ORACLE
check "submit, emcli fails: exit 1 and says so"    '[ $rc -eq 1 ] && grep -q "a job was not created" "$T/err"'
printf 'Error: Session expired\n' > "$T/bad.tsv"
MOCK_INV="$T/bad.tsv" run --all
check "an inventory without targets: exit 1"       '[ $rc -eq 1 ] && grep -q "lists no oracle_database" "$T/err"'

# ---- 9. --out DIR, --inventory FILE ---------------------------------------------------
run --all --out "$T/o1"
check "--out: add_targets.sql and prepare_targets.txt" \
      '[ $rc -eq 0 ] && [ "$(grep -c "^EXEC cap_repo.add_target" "$T/o1/add_targets.sql")" -eq 6 ] && [ "$(grep -c "@target/prepare.sql" "$T/o1/prepare_targets.txt")" -eq 6 ]'
check "--out: nothing on standard output"          '[ ! -s "$T/out" ]'
check "--out: no password in the files"            'no_secret "$T/o1/add_targets.sql" && no_secret "$T/o1/prepare_targets.txt"'
run --all --submit --db-cred NC_SYSDBA --host-cred NC_ORACLE --job-name AWRCAP_O --out "$T/o2"
check "--out with --submit: the property files stay" \
      '[ $rc -eq 0 ] && [ -s "$T/o2/AWRCAP_O.props" ] && [ -s "$T/o2/AWRCAP_O_RAC.props" ] && [ -s "$T/o2/after_submit.txt" ] && [ -s "$T/o2/add_targets.sql" ]'
EMCLI="$T/bin/none" run --inventory "$MOCK_INV" --targets hr_db03
check "--inventory FILE: no emcli needed"          '[ $rc -eq 0 ] && [ "$(calls)" -eq 0 ] && has "add_target('"'HR'"'"'
EMCLI="$T/bin/none" run
check "no emcli and no --inventory: exit 2"        '[ $rc -eq 2 ] && grep -q "not found" "$T/err"'

# ---- 10. the metric extension statement -------------------------------------------------
Q="$T/me.sql"
sed -n '/^-- ME-QUERY-BEGIN/,/^;$/p' "$HERE/oem/awrcap_alerts.sql" | sed -e '1d' -e '$d' -e 's/&cap_owner\.\./AWRCAP./g' > "$Q"
check "metric extension: the README's extraction is in oem/README.md and the script header" \
      'grep -qF "sed -n '"'"'/^-- ME-QUERY-BEGIN/,/^;\$/p'"'"' oem/awrcap_alerts.sql" "$HERE/oem/README.md" && grep -qF "ME-QUERY-BEGIN/,/^;\$/p" "$HERE/oem/awrcap_alerts.sql"'
check "metric extension: one statement, no terminator, comment or substitution" \
      '[ "$(grep -c . "$Q")" -gt 20 ] && ! grep -qE ";|--|&|^[[:space:]]*$" "$Q" && head -1 "$Q" | grep -q "^SELECT "'
check "metric extension: the eight columns, in the documented order" \
      'head -1 "$Q" | grep -qx "SELECT alert_key, sev_num, severity, kind, target_name, db_pdb, series_key, message"'
check "metric extension: reads the two granted objects and nothing else" \
      '[ "$(grep -oE "AWRCAP\.[a-z_]+" "$Q" | sort -u | tr "\n" " ")" = "AWRCAP.cap_alert_state AWRCAP.capr_runs " ] && ! grep -qiE "FROM +cap|JOIN +cap" "$Q"'
check "metric extension: grant_monitor.sql grants exactly those two" \
      'grep -q "t_list('"'CAP_ALERT_STATE', 'CAPR_RUNS'"')" "$HERE/oem/grant_monitor.sql" && [ "$(grep -c "GRANT READ ON" "$HERE/oem/grant_monitor.sql")" -eq 2 ]'
for c in ALERT_KEY SEV_NUM SEVERITY KIND TARGET_NAME DB_PDB SERIES_KEY MESSAGE; do
  grep -qE "^\| +[1-8] +\| +\`$c\` " "$HERE/oem/README.md" || { fail "metric extension: README column table lacks $c"; continue; }
done
check "metric extension: README lists the columns in the query's order" \
      '[ "$(grep -oE "^\| +[1-8] +\| +\`[A-Z_]+\`" "$HERE/oem/README.md" | grep -oE "[A-Z_]+" | tr "A-Z\n" "a-z " | sed "s/ $//; s/ /, /g")" = "alert_key, sev_num, severity, kind, target_name, db_pdb, series_key, message" ]'

if [ $fails -eq 0 ]; then
    echo "oem test: all passed"
else
    echo "oem test: $fails failed"
    exit 1
fi
