#!/usr/bin/env bash
# test/dbmint_stub_install.sh -- prove a fixture install works over the
# zero-row contract stubs of ddl/12_seam_fixture.sql (SYSDBA +
# CURRENT_SCHEMA, PDB1, like test/dbmint_harness.sh).
#
#   test/dbmint_stub_install.sh <SCHEMA> [--no-fixture] [--only TABLE]...
#
#   <SCHEMA>      throwaway fixture schema in PDB1 (CAPX1 etc.)
#   --no-fixture  skip test/fixture_install.sql (the tables are there)
#   --only TABLE  drop only this CAP_FIXTURE_* table (repeatable). Default:
#                 every table ddl/12 can stub, so each stub is installed
#                 beside every other one.
#
# Steps: fixture_install -> DROP the optional fixture tables -> install
# (fixture) -> checks. It fails when the install fails, when a CAP% object of
# the schema is INVALID, when a dropped table's seam view returns a row, or
# when CAPD_SERIES_DAILY / CAPR_ALERTS do not run. Two stubs joined to each
# other once raised ORA-00932 (PGASTAT + PARAMETER, 19.27), which left about
# twenty views INVALID and failed cap_results.build_snap_tables.
#
# The schema is left on the stub install: the next test/dbmint_harness.sh
# run (without --no-fixture) restores the full fixture.
# Exit 0 pass, 1 a check failed, 2 usage, 3 rsync, else the SQL*Plus status.
# Log: /tmp/dbmint_stub_install_<SCHEMA>.log.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCHEMA=${1:?schema}; shift
FIXTURE=1; ONLY=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-fixture) FIXTURE=0;;
    --only) shift; ONLY+=("$(echo "${1:?table}" | tr 'a-z' 'A-Z')");;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac; shift
done
REMOTE=awr_cap_$(echo "$SCHEMA" | tr 'A-Z' 'a-z')
SSH="ssh -p 2200 oracle@dbmint"
LOG=/tmp/dbmint_stub_install_${SCHEMA}.log

# The tables ddl/12 can stub: the first argument of each mk('...') call.
mapfile -t STUBBABLE < <(grep -oE "^ +mk\('CAP_FIXTURE_[A-Z_]+'" "$HERE"/ddl/12_seam_fixture.sql \
                         | grep -oE "CAP_FIXTURE_[A-Z_]+")
[ ${#STUBBABLE[@]} -gt 0 ] || { echo "no mk('CAP_FIXTURE_...') call found in ddl/12" >&2; exit 2; }
if [ ${#ONLY[@]} -gt 0 ]; then
  for t in "${ONLY[@]}"; do
    printf '%s\n' "${STUBBABLE[@]}" | grep -qx "$t" || { echo "$t has no stub in ddl/12" >&2; exit 2; }
  done
  TABLES=("${ONLY[@]}")
else
  TABLES=("${STUBBABLE[@]}")
fi
IN_LIST=$(printf "'%s'," "${TABLES[@]}"); IN_LIST=${IN_LIST%,}
echo "stubbing ${#TABLES[@]} of ${#STUBBABLE[@]}: ${TABLES[*]}"

rsync -az --delete -e 'ssh -p 2200' \
  --exclude .git --exclude .claude --exclude reports --exclude '__pycache__' \
  --exclude grafana/.ords.env --exclude grafana/ords/config --exclude grafana/.env \
  "$HERE"/ oracle@dbmint:~/"$REMOTE"/ || exit 3

PRE="ALTER SESSION SET CONTAINER = PDB1;
ALTER SESSION SET CURRENT_SCHEMA = $SCHEMA;"

DROP_SQL="SET SERVEROUTPUT ON
BEGIN
    FOR t IN (SELECT table_name FROM all_tables
              WHERE  owner = '$SCHEMA' AND table_name IN ($IN_LIST)) LOOP
        EXECUTE IMMEDIATE 'DROP TABLE $SCHEMA.' || t.table_name || ' PURGE';
        DBMS_OUTPUT.PUT_LINE('dropped ' || t.table_name);
    END LOOP;
END;
/"

# A seam view is named after its table: CAP_FIXTURE_X -> CAPV_X.
CHECK_SQL="SET SERVEROUTPUT ON
DECLARE
    v_fail PLS_INTEGER := 0;
    v_n    PLS_INTEGER;
    PROCEDURE chk(p_ok BOOLEAN, p_what VARCHAR2) IS
    BEGIN
        IF p_ok THEN DBMS_OUTPUT.PUT_LINE('  PASS ' || p_what);
        ELSE v_fail := v_fail + 1; DBMS_OUTPUT.PUT_LINE('  FAIL ' || p_what);
        END IF;
    END;
BEGIN
    FOR o IN (SELECT object_type, object_name FROM all_objects
              WHERE  owner = '$SCHEMA' AND object_name LIKE 'CAP%' AND status <> 'VALID'
              ORDER  BY object_type, object_name) LOOP
        chk(FALSE, 'INVALID ' || o.object_type || ' ' || o.object_name);
    END LOOP;
    SELECT COUNT(*) INTO v_n FROM all_objects
    WHERE  owner = '$SCHEMA' AND object_name LIKE 'CAP%' AND status <> 'VALID';
    chk(v_n = 0, 'no INVALID CAP% object (' || v_n || ')');
    SELECT COUNT(*) INTO v_n FROM all_tables
    WHERE  owner = '$SCHEMA' AND table_name IN ($IN_LIST);
    chk(v_n = 0, 'the ${#TABLES[@]} stubbed fixture tables are absent (' || v_n || ' left)');
    FOR t IN (SELECT REPLACE(COLUMN_VALUE, 'CAP_FIXTURE_', 'CAPV_') AS vw
              FROM   TABLE(SYS.ODCIVARCHAR2LIST($IN_LIST))) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM $SCHEMA.' || t.vw INTO v_n;
            chk(v_n = 0, t.vw || ' is a zero-row stub (' || v_n || ' rows)');
        EXCEPTION WHEN OTHERS THEN
            chk(FALSE, t.vw || ': ' || SQLERRM);
        END;
    END LOOP;
    FOR t IN (SELECT COLUMN_VALUE AS vw
              FROM   TABLE(SYS.ODCIVARCHAR2LIST('CAPD_SERIES_DAILY', 'CAPR_ALERTS'))) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM $SCHEMA.' || t.vw INTO v_n;
            chk(v_n > 0, t.vw || ' runs over the stubs (' || v_n || ' rows)');
        EXCEPTION WHEN OTHERS THEN
            chk(FALSE, t.vw || ': ' || SQLERRM);
        END;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('RESULT: stub install ' || CASE WHEN v_fail = 0 THEN 'passed' ELSE 'FAILED' END
                         || ' (' || v_fail || ' failed)');
    IF v_fail > 0 THEN RAISE_APPLICATION_ERROR(-20001, 'stub install check failed'); END IF;
END;
/"

STEPS=()
[ $FIXTURE = 1 ] && STEPS+=("@test/fixture_install.sql")
STEPS+=("$DROP_SQL
DEFINE deploy_mode = fixture
@install.sql")
STEPS+=("$CHECK_SQL")

: > "$LOG"; rc=0
for step in "${STEPS[@]}"; do
  echo "### $step" | head -1 | tee -a "$LOG"
  t0=$(date +%s)
  $SSH 'bash -s' <<REMOTE_EOF >> "$LOG" 2>&1
export ORACLE_SID=cdb1; export ORAENV_ASK=NO; . oraenv >/dev/null 2>&1
cd ~/$REMOTE && sqlplus -S -L / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT FAILURE
$PRE
$step
EXIT
SQL
REMOTE_EOF
  src=$?
  echo "### elapsed $(( $(date +%s) - t0 )) s" | tee -a "$LOG"
  [ $src -ne 0 ] && { echo "### step failed (exit $src)" | tee -a "$LOG"; rc=$src; break; }
done
grep -E "RESULT:|FAIL|ORA-|PLS-|SP2-|Warning: .* compilation errors|step failed" "$LOG" | head -60
echo "log: $LOG  (exit $rc)"
exit $rc
