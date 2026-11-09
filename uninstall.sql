--
-- uninstall.sql -- remove every object the suite created from the current schema.
-- =====================================================================
-- Removes the opt-in scheduler jobs first (uninstall_jobs.sql), then the OML
-- models (via the package, which needs the registry), then all views, then
-- the persisted tables, the two types and the two packages, then the grants a
-- local-mode install (retired in M25) gave the owner: revoked as SYSDBA,
-- printed as statements otherwise (revoke_local_grants.sql). Idempotent: safe
-- to run against a partial or already-removed install. "Does not exist" is
-- silent; any other error is printed and the script carries on, except one
-- while writing the config replay file (below), which ends the run before
-- anything is dropped. The last block counts what is left in the current
-- schema (0 expected).
--
-- CAP_FIXTURE_* test tables are not the suite's; test/fixture_remove.sql
-- drops them. The closing count lists them separately.
--
-- Before it drops anything it writes the operator's config to a replay file,
-- reports/cap_config_replay_<schema>_<YYYYMMDD_HH24MISS>.sql (path printed):
-- one UPDATE per CAP_CONFIG knob whose value differs from its default
-- (suite_version aside) and one MERGE per CAP_TBSPC_OVERRIDE row. Run it in
-- the new owner after the new install.sql, which has seeded every knob by
-- then. A knob the new release no longer has updates no row and is named.
-- With no such knob and no override row it writes no file.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/uninstall.sql"
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

PROMPT -- writing the config replay file (knobs off their default, tablespace overrides) ...
VARIABLE cap_replay      CLOB
VARIABLE cap_replay_n    NUMBER
VARIABLE cap_replay_file VARCHAR2(200)
DECLARE
    v_out   CLOB;
    v_n     PLS_INTEGER := 0;
    v_cur   SYS_REFCURSOR;
    v_name  VARCHAR2(128);
    v_val   NUMBER;
    v_row   VARCHAR2(32767);
    v_sel   VARCHAR2(32767);
    v_cols  VARCHAR2(4000);
    v_vals  VARCHAR2(4000);
    v_on    VARCHAR2(4000);
    v_set   VARCHAR2(4000);
    v_pk    VARCHAR2(4000);
    v_owner VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
    v_knobs PLS_INTEGER := 0;

    PROCEDURE put(p_line IN VARCHAR2) IS
    BEGIN
        v_out := v_out || p_line || CHR(10);
    END put;

    FUNCTION num(p_n IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN NVL(TO_CHAR(p_n, 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,'''), 'NULL');
    END num;

    FUNCTION literal_sql(p_col IN VARCHAR2, p_type IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_type IN ('NUMBER', 'FLOAT') THEN
            RETURN 'NVL(TO_CHAR(' || p_col || q'[, 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,'''), 'NULL')]';
        ELSIF p_type IN ('VARCHAR2', 'CHAR', 'NVARCHAR2', 'NCHAR') THEN
            RETURN 'NVL2(' || p_col || q'[, '''' || REPLACE(REPLACE(REPLACE(]' || p_col
                   || q'[, '''', ''''''), CHR(13), ''' || CHR(13) || '''), CHR(10), ''' || CHR(10) || ''') || '''', 'NULL')]';
        ELSIF p_type = 'DATE' THEN
            RETURN 'NVL2(' || p_col || q'[, 'TO_DATE(''' || TO_CHAR(]' || p_col
                   || q'[, 'YYYY-MM-DD HH24:MI:SS') || ''', ''YYYY-MM-DD HH24:MI:SS'')', 'NULL')]';
        END IF;
        RETURN NULL;
    END literal_sql;
BEGIN
    :cap_replay_file := 'reports/cap_config_replay_'
                        || REGEXP_REPLACE(LOWER(v_owner), '[^a-z0-9_]', '') || '_'
                        || TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS') || '.sql';
    put('-- ' || :cap_replay_file);
    put('-- Written by uninstall.sql from schema ' || v_owner || ' at '
        || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS') || ': its CAP_CONFIG knobs');
    put('-- off their default and its CAP_TBSPC_OVERRIDE rows. Run it in the new owner');
    put('-- after install.sql:');
    put('--   SQL> @' || :cap_replay_file);
    put('SET APPINFO OFF');
    put('SET APPINFO "AWRCAP/reports/cap_config_replay"');
    put('SET DEFINE OFF');
    put('SET FEEDBACK OFF');
    put('SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED');
    put('WHENEVER SQLERROR EXIT FAILURE ROLLBACK');

    BEGIN
        OPEN v_cur FOR 'SELECT cfg_name, cfg_value FROM cap_config'
                       || q'[ WHERE cfg_name <> 'suite_version']'
                       || ' AND DECODE(cfg_value, cfg_default, 0, 1) = 1 ORDER BY cfg_name';
        LOOP
            FETCH v_cur INTO v_name, v_val;
            EXIT WHEN v_cur%NOTFOUND;
            IF v_knobs = 0 THEN
                put('DECLARE');
                put('    v_set  PLS_INTEGER := 0;');
                put('    v_miss PLS_INTEGER := 0;');
                put('    PROCEDURE knob(p_name IN VARCHAR2, p_value IN NUMBER) IS');
                put('    BEGIN');
                put('        UPDATE cap_config SET cfg_value = p_value WHERE cfg_name = p_name;');
                put('        IF SQL%ROWCOUNT = 0 THEN');
                put('            v_miss := v_miss + 1;');
                put(q'[            DBMS_OUTPUT.PUT_LINE('  not replayed: knob ' || p_name || ' (not in this release)');]');
                put('        ELSE');
                put('            v_set := v_set + 1;');
                put('        END IF;');
                put('    END knob;');
                put('BEGIN');
            END IF;
            v_knobs := v_knobs + 1;
            put('    knob(''' || REPLACE(v_name, '''', '''''') || ''', ' || num(v_val) || ');');
        END LOOP;
        CLOSE v_cur;
        IF v_knobs > 0 THEN
            put(q'[    DBMS_OUTPUT.PUT_LINE('  ' || v_set || ' knob(s) replayed, ' || v_miss || ' not');]');
            put('END;');
            put('/');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            IF v_cur%ISOPEN THEN CLOSE v_cur; END IF;
            IF SQLCODE <> -942 THEN RAISE; END IF;
    END;
    v_n := v_knobs;

    FOR c IN (SELECT c.column_name, c.data_type,
                     (SELECT COUNT(*)
                      FROM   all_constraints k
                      JOIN   all_cons_columns kc ON kc.owner = k.owner
                                                AND kc.constraint_name = k.constraint_name
                      WHERE  k.owner = c.owner AND k.table_name = c.table_name
                        AND  k.constraint_type = 'P' AND kc.column_name = c.column_name) AS is_pk
              FROM   all_tab_columns c
              WHERE  c.owner = v_owner AND c.table_name = 'CAP_TBSPC_OVERRIDE'
              ORDER  BY c.column_id) LOOP
        CONTINUE WHEN literal_sql(c.column_name, c.data_type) IS NULL;
        v_sel  := v_sel || CASE WHEN v_sel IS NOT NULL THEN q'[ || ', ' || ]' END
                  || literal_sql(c.column_name, c.data_type) || q'[ || ' AS ]' || c.column_name || q'[']';
        v_cols := v_cols || CASE WHEN v_cols IS NOT NULL THEN ', ' END || c.column_name;
        v_vals := v_vals || CASE WHEN v_vals IS NOT NULL THEN ', ' END || 's.' || c.column_name;
        IF c.is_pk > 0 THEN
            v_on := v_on || CASE WHEN v_on IS NOT NULL THEN ' AND ' END
                    || 'o.' || c.column_name || ' = s.' || c.column_name;
            v_pk := v_pk || CASE WHEN v_pk IS NOT NULL THEN ', ' END || c.column_name;
        ELSE
            v_set := v_set || CASE WHEN v_set IS NOT NULL THEN ', ' END
                     || 'o.' || c.column_name || ' = s.' || c.column_name;
        END IF;
    END LOOP;
    IF v_sel IS NOT NULL AND v_on IS NOT NULL THEN
        BEGIN
            OPEN v_cur FOR 'SELECT ' || v_sel || ' FROM cap_tbspc_override ORDER BY ' || v_pk;
            LOOP
                FETCH v_cur INTO v_row;
                EXIT WHEN v_cur%NOTFOUND;
                v_n := v_n + 1;
                put('MERGE INTO cap_tbspc_override o');
                put('USING (SELECT ' || v_row || ' FROM dual) s');
                put('ON (' || v_on || ')');
                IF v_set IS NOT NULL THEN
                    put('WHEN MATCHED THEN UPDATE SET ' || v_set);
                END IF;
                put('WHEN NOT MATCHED THEN INSERT (' || v_cols || ') VALUES (' || v_vals || ');');
            END LOOP;
            CLOSE v_cur;
        EXCEPTION
            WHEN OTHERS THEN
                IF v_cur%ISOPEN THEN CLOSE v_cur; END IF;
                IF SQLCODE <> -942 THEN RAISE; END IF;
        END;
    END IF;
    put('COMMIT;');
    put('PROMPT -- config replayed (' || (v_n - v_knobs) || ' tablespace override row(s)).');
    put('WHENEVER SQLERROR CONTINUE');
    put('SET FEEDBACK ON');
    :cap_replay_n := v_n;
    :cap_replay   := CASE WHEN v_n > 0 THEN v_out END;
END;
/
WHENEVER SQLERROR CONTINUE
SET DEFINE '&'
SET VERIFY OFF
SET TERMOUT OFF
COLUMN cap_r_spool_termout  NEW_VALUE cap_replay_spool_termout  NOPRINT
COLUMN cap_r_mkdir NEW_VALUE cap_replay_mkdir NOPRINT
COLUMN cap_r_spool NEW_VALUE cap_replay_spool NOPRINT
COLUMN cap_r_note  NEW_VALUE cap_replay_note  NOPRINT
SELECT CASE WHEN :cap_replay_n > 0 THEN 'ON' ELSE 'OFF' END AS cap_r_spool_termout,
       CASE WHEN :cap_replay_n > 0 THEN 'mkdir -p reports' ELSE ':' END AS cap_r_mkdir,
       CASE WHEN :cap_replay_n > 0 THEN :cap_replay_file ELSE 'OFF' END AS cap_r_spool,
       CASE WHEN :cap_replay_n > 0
            THEN '-- config replay file: ' || :cap_replay_file || ' (' || :cap_replay_n
                 || ' statement(s)), run it in the new owner after install.sql'
            ELSE '-- no config replay file: no knob off its default, no tablespace override' END AS cap_r_note
FROM   dual;
COLUMN cap_r_spool_termout  CLEAR
COLUMN cap_r_mkdir CLEAR
COLUMN cap_r_spool CLEAR
COLUMN cap_r_note  CLEAR
SET TERMOUT &cap_replay_spool_termout
HOST &cap_replay_mkdir
SPOOL &cap_replay_spool
SET TERMOUT OFF
SET LINESIZE 32767
SET TRIMSPOOL ON
DECLARE
    v_len PLS_INTEGER := NVL(DBMS_LOB.GETLENGTH(:cap_replay), 0);
    v_pos PLS_INTEGER := 1;
    v_nl  PLS_INTEGER;
BEGIN
    WHILE v_pos <= v_len LOOP
        v_nl := DBMS_LOB.INSTR(:cap_replay, CHR(10), v_pos);
        IF v_nl = 0 THEN
            v_nl := v_len + 1;
        END IF;
        DBMS_OUTPUT.PUT_LINE(DBMS_LOB.SUBSTR(:cap_replay, v_nl - v_pos, v_pos));
        v_pos := v_nl + 1;
    END LOOP;
END;
/
SPOOL OFF
SET TERMOUT ON
PROMPT &cap_replay_note
UNDEFINE cap_replay_spool_termout cap_replay_mkdir cap_replay_spool cap_replay_note
SET DEFINE OFF

PROMPT -- removing scheduler jobs + cap_report_spool (uninstall_jobs.sql) ...
@@uninstall_jobs.sql
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET FEEDBACK OFF

PROMPT -- dropping OML models (cap_forecast_ml.drop_all) ...
BEGIN
    -- Dynamic, so a missing package is a runtime error we can recognise
    -- instead of a compile error of this block.
    EXECUTE IMMEDIATE 'BEGIN cap_forecast_ml.drop_all; END;';
    DBMS_OUTPUT.PUT_LINE('  OML models dropped');
EXCEPTION
    WHEN OTHERS THEN
        -- ORA-06550 wraps PLS-00201: package not installed.
        IF SQLCODE = -6550 THEN
            DBMS_OUTPUT.PUT_LINE('  (cap_forecast_ml not present)');
        ELSE
            DBMS_OUTPUT.PUT_LINE('  ERROR in drop_all: ' || SQLERRM);
        END IF;
END;
/

PROMPT -- dropping the DB links cap_repo.add_target created (repository mode) ...
-- A private link can be dropped only by its owner, not by SYS under
-- CURRENT_SCHEMA, so a throwaway definer's-rights procedure in this schema
-- drops them. It reads CAP_TARGET directly: cap_repo may be gone or INVALID
-- (a local re-install drops it).
DECLARE
    v_n NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n FROM all_tables
    WHERE  owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') AND table_name = 'CAP_TARGET';
    IF v_n = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  (no CAP_TARGET)');
        RETURN;
    END IF;
    EXECUTE IMMEDIATE q'~CREATE OR REPLACE PROCEDURE cap_uninstall_links AUTHID DEFINER AS
    BEGIN
        FOR l IN (SELECT db_link FROM cap_target WHERE link_owned = 'Y') LOOP
            BEGIN
                EXECUTE IMMEDIATE 'DROP DATABASE LINK ' || l.db_link;
                DBMS_OUTPUT.PUT_LINE('  DROP DATABASE LINK ' || l.db_link);
            EXCEPTION
                WHEN OTHERS THEN
                    DBMS_OUTPUT.PUT_LINE('  ERROR dropping link ' || l.db_link || ': ' || SQLERRM);
            END;
        END LOOP;
    END;~';
    EXECUTE IMMEDIATE 'BEGIN cap_uninstall_links; END;';
    EXECUTE IMMEDIATE 'DROP PROCEDURE cap_uninstall_links';
END;
/

PROMPT -- dropping suite objects (ddl/00_drop.sql) ...
@@ddl/00_drop.sql
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET FEEDBACK OFF

PROMPT -- dropping persisted tables, types and packages ...
-- The persisted tables outlive 00_drop (which preserves them across a
-- re-install). A true uninstall removes them here.
DECLARE
    PROCEDURE drop_it(p_ddl IN VARCHAR2, p_gone IN PLS_INTEGER) IS
    BEGIN
        EXECUTE IMMEDIATE p_ddl;
        DBMS_OUTPUT.PUT_LINE('  ' || p_ddl);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE != p_gone THEN
                DBMS_OUTPUT.PUT_LINE('  ERROR on "' || p_ddl || '": ' || SQLERRM);
            END IF;
    END drop_it;
BEGIN
    -- ORA-00942 table does not exist, ORA-04043 object does not exist.
    drop_it('DROP PACKAGE cap_results',            -4043);
    drop_it('DROP TABLE cap_alert_event PURGE',    -942);
    drop_it('DROP TABLE cap_alert_state PURGE',    -942);
    drop_it('DROP TABLE cap_fit_hist PURGE',       -942);
    drop_it('DROP TABLE cap_run PURGE',            -942);
    drop_it('DROP TABLE cap_ml_model PURGE',       -942);
    drop_it('DROP TABLE cap_ml_input',             -942);
    drop_it('DROP TABLE cap_tbspc_override PURGE', -942);
    drop_it('DROP TABLE cap_config PURGE',         -942);
    drop_it('DROP TYPE cap_esm_tab',               -4043);
    drop_it('DROP TYPE cap_esm_row',               -4043);
    drop_it('DROP PACKAGE cap_forecast_ml',        -4043);
    drop_it('DROP TABLE cap_collect_log PURGE',    -942);
    drop_it('DROP TABLE cap_target_dbid PURGE',    -942);
    drop_it('DROP TABLE cap_target PURGE',         -942);
    FOR t IN (SELECT table_name FROM all_tables
              WHERE  owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
                AND  table_name LIKE 'CAP\_H\_%' ESCAPE '\'
              ORDER BY table_name) LOOP
        drop_it('DROP TABLE ' || t.table_name || ' PURGE', -942);
    END LOOP;
END;
/

PROMPT -- grants a local-mode install left (revoke_local_grants.sql) ...
SET DEFINE '&'
SET TERMOUT OFF
COLUMN cap_rv_owner NEW_VALUE revoke_owner NOPRINT
SELECT SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') AS cap_rv_owner FROM dual;
COLUMN cap_rv_owner CLEAR
SET TERMOUT ON
@@revoke_local_grants.sql
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET FEEDBACK OFF

PROMPT -- what is left ...
DECLARE
    v_owner VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
    v_left  PLS_INTEGER := 0;
    v_fix   PLS_INTEGER := 0;
BEGIN
    FOR r IN (SELECT object_type, object_name
              FROM   all_objects
              WHERE  owner = v_owner
                AND  object_name LIKE 'CAP%'
              ORDER BY object_type, object_name) LOOP
        IF r.object_name LIKE 'CAP\_FIXTURE\_%' ESCAPE '\' THEN
            v_fix := v_fix + 1;
        ELSE
            v_left := v_left + 1;
            DBMS_OUTPUT.PUT_LINE('  still present: ' || r.object_type || ' ' || r.object_name);
        END IF;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('  ' || v_left || ' CAP% object(s) left in schema ' || v_owner
                         || ' (0 expected)');
    IF v_fix > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  plus ' || v_fix || ' CAP_FIXTURE_* test table(s);'
                             || ' remove them with @test/fixture_remove.sql');
    END IF;
END;
/

PROMPT -- uninstall complete.
SET FEEDBACK ON
