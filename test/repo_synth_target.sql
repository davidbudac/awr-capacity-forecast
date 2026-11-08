-- =====================================================================
-- test/repo_synth_target.sql -- a synthetic target in a repository install.
-- =====================================================================
--   @test/repo_synth_target.sql <TARGET> <DBID> <SHIFT_DAYS> [DAYS] [SOURCE_SCHEMA]
--
-- Test-only. Run in a repository-mode schema (as its owner, or SYSDBA with
-- CURRENT_SCHEMA set). Registers TARGET with dbid DBID and fills every
-- CAP_H_* copy with the rows of the lowest dbid registered in SOURCE_SCHEMA
-- (default: this schema, which must then have collected a real target),
-- under DBID (the root's con_dbid, which equals the dbid, too) and with
-- every DATE / TIMESTAMP column moved SHIFT_DAYS into the past. That gives a
-- fleet of two or more targets from one database: labels, CAPR_TARGETS,
-- report scoping, and with a SHIFT_DAYS beyond stale_hours a DATA_STALE
-- target. The target's link CAP_<TARGET> does not exist, so its collects
-- fail (collect_state FAILING once one ran). link_owned = 'N':
-- cap_repo.remove_target(TARGET) deletes the rows and drops no link.
--
-- DAYS (default, or '-': one copy) makes the history at least DAYS long for
-- scale tests (test/dbmint_scale.sh): the source's rows repeat in blocks,
-- each one source span (whole days, plus one) further back, with snap_ids
-- 100000 apart so blocks never interleave. Each block boundary reads as an
-- instance restart (the startup_time moved with the block). Tables without
-- a snap_id or a date (tablespace, datafile, PDB, diskgroup and segment
-- names) are copied once, because their rows are keys, not history.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/test/repo_synth_target.sql"
SET DEFINE '&'
SET VERIFY OFF
SET FEEDBACK OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR EXIT FAILURE

SET TERMOUT OFF
COLUMN 4 NEW_VALUE 4 NOPRINT
COLUMN 5 NEW_VALUE 5 NOPRINT
SELECT NULL AS "4", NULL AS "5" FROM dual WHERE 1 = 0;
SET TERMOUT ON

DECLARE
    c_gap   CONSTANT NUMBER := 100000;
    v_name  cap_target.target_name%TYPE := UPPER('&1');
    v_dbid  NUMBER := TO_NUMBER('&2');
    v_shift NUMBER := TO_NUMBER('&3');
    v_days  NUMBER := TO_NUMBER(NULLIF('&4', '-'));
    v_owner VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
    v_from  VARCHAR2(128) := NVL(UPPER(NULLIF('&5', '-')), SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'));
    v_src   NUMBER;
    v_id    NUMBER;
    v_span  NUMBER;
    v_n     PLS_INTEGER;
    v_rows  NUMBER;
    v_cols  VARCHAR2(4000);
    v_expr  VARCHAR2(4000);
    v_snap  BOOLEAN;
    v_date  BOOLEAN;
BEGIN
    EXECUTE IMMEDIATE 'SELECT MIN(dbid) FROM "' || v_from || '".cap_target_dbid' INTO v_src;
    IF v_src IS NULL THEN
        RAISE_APPLICATION_ERROR(-20001, 'no collected target to clone in ' || v_from);
    END IF;
    EXECUTE IMMEDIATE
        'SELECT CEIL(CAST(MAX(end_interval_time) AS DATE) - CAST(MIN(begin_interval_time) AS DATE)) + 1 '
        || 'FROM "' || v_from || '".cap_h_snapshot WHERE dbid = :1' INTO v_span USING v_src;
    v_n := CASE WHEN v_days IS NULL THEN 1 ELSE GREATEST(1, CEIL(v_days / v_span)) END;

    INSERT INTO cap_target (target_name, db_link, link_owned, connect_string, link_user)
    VALUES (v_name, 'CAP_' || v_name, 'N', '//synthetic/' || LOWER(v_name), 'NONE')
    RETURNING target_id INTO v_id;
    EXECUTE IMMEDIATE 'INSERT INTO cap_target_dbid (dbid, target_id, last_snap_id) '
        || 'SELECT :1, :2, last_snap_id + :3 FROM "' || v_from || '".cap_target_dbid WHERE dbid = :4'
        USING v_dbid, v_id, (v_n - 1) * c_gap, v_src;

    FOR t IN (SELECT copy_table FROM cap_repo_source ORDER BY seq) LOOP
        v_cols := NULL;
        v_expr := NULL;
        v_snap := FALSE;
        v_date := FALSE;
        FOR c IN (SELECT column_name, data_type FROM all_tab_columns
                  WHERE  owner = v_owner AND table_name = UPPER(t.copy_table)
                  ORDER  BY column_id) LOOP
            v_cols := v_cols || CASE WHEN v_cols IS NOT NULL THEN ', ' END || '"' || c.column_name || '"';
            v_expr := v_expr || CASE WHEN v_expr IS NOT NULL THEN ', ' END
                   || CASE WHEN c.column_name = 'DBID' THEN ':d'
                           WHEN c.column_name = 'CON_DBID'
                           THEN 'DECODE(con_dbid, ' || v_src || ', :d, con_dbid)'
                           WHEN c.column_name = 'SNAP_ID' THEN '"SNAP_ID" + :o'
                           WHEN c.data_type = 'DATE' OR c.data_type LIKE 'TIMESTAMP%'
                           THEN '"' || c.column_name || '" - :s'
                           ELSE '"' || c.column_name || '"' END;
            v_snap := v_snap OR c.column_name = 'SNAP_ID';
            v_date := v_date OR c.data_type = 'DATE' OR c.data_type LIKE 'TIMESTAMP%';
        END LOOP;
        v_rows := 0;
        FOR b IN 0 .. CASE WHEN v_snap OR v_date THEN v_n - 1 ELSE 0 END LOOP
            EXECUTE IMMEDIATE 'INSERT INTO ' || t.copy_table || ' (' || v_cols || ') SELECT '
                || REPLACE(REPLACE(REPLACE(v_expr, ':d', TO_CHAR(v_dbid)),
                                   ':o', TO_CHAR((v_n - 1 - b) * c_gap)),
                           ':s', TO_CHAR(v_shift + b * v_span))
                || ' FROM "' || v_from || '".' || t.copy_table || ' WHERE dbid = :1'
                USING v_src;
            v_rows := v_rows + SQL%ROWCOUNT;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('  ' || RPAD(t.copy_table, 32) || LPAD(v_rows, 9) || ' rows');
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('  target ' || v_name || ' = dbid ' || v_dbid || ', copies of dbid '
                         || v_src || ' (' || v_from || ') moved ' || v_shift || ' days back, '
                         || v_n || ' block(s) of ' || v_span || ' days');
END;
/

UNDEFINE 1 2 3 4 5
COLUMN 4 CLEAR
COLUMN 5 CLEAR
WHENEVER SQLERROR CONTINUE
SET FEEDBACK ON
