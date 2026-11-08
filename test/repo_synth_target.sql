--
-- test/repo_synth_target.sql -- a synthetic target in a repository install.
-- =====================================================================
--   @test/repo_synth_target.sql <TARGET> <DBID> <SHIFT_DAYS>
--
-- Test-only. Run in a repository-mode schema (as its owner, or SYSDBA with
-- CURRENT_SCHEMA set) that already collected a real target. Registers TARGET
-- with dbid DBID and fills every CAP_H_* copy with the rows of the lowest
-- registered dbid, under DBID (the root's con_dbid, which equals the dbid,
-- too) and with every DATE / TIMESTAMP column moved SHIFT_DAYS into the past. That gives a fleet of two or more targets from
-- one database: labels, CAPR_TARGETS, report scoping, and with a SHIFT_DAYS
-- beyond stale_hours a DATA_STALE target. The target's link CAP_<TARGET>
-- does not exist, so its collects fail (collect_state FAILING once one ran).
-- link_owned = 'N': cap_repo.remove_target(TARGET) deletes the rows and
-- drops no link.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/test/repo_synth_target.sql"
SET DEFINE '&'
SET VERIFY OFF
SET FEEDBACK OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR EXIT FAILURE

DECLARE
    v_name  cap_target.target_name%TYPE := UPPER('&1');
    v_dbid  NUMBER := TO_NUMBER('&2');
    v_shift NUMBER := TO_NUMBER('&3');
    v_owner VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
    v_src   NUMBER;
    v_id    NUMBER;
    v_cols  VARCHAR2(4000);
    v_expr  VARCHAR2(4000);
BEGIN
    SELECT MIN(dbid) INTO v_src FROM cap_target_dbid;
    IF v_src IS NULL THEN
        RAISE_APPLICATION_ERROR(-20001, 'no collected target to clone in ' || v_owner);
    END IF;
    INSERT INTO cap_target (target_name, db_link, link_owned, connect_string, link_user)
    VALUES (v_name, 'CAP_' || v_name, 'N', '//synthetic/' || LOWER(v_name), 'NONE')
    RETURNING target_id INTO v_id;
    INSERT INTO cap_target_dbid (dbid, target_id, last_snap_id)
    SELECT v_dbid, v_id, last_snap_id FROM cap_target_dbid WHERE dbid = v_src;

    FOR t IN (SELECT copy_table FROM cap_repo_source ORDER BY seq) LOOP
        v_cols := NULL;
        v_expr := NULL;
        FOR c IN (SELECT column_name, data_type FROM all_tab_columns
                  WHERE  owner = v_owner AND table_name = UPPER(t.copy_table)
                  ORDER  BY column_id) LOOP
            v_cols := v_cols || CASE WHEN v_cols IS NOT NULL THEN ', ' END || '"' || c.column_name || '"';
            v_expr := v_expr || CASE WHEN v_expr IS NOT NULL THEN ', ' END
                   || CASE WHEN c.column_name = 'DBID' THEN ':d'
                           WHEN c.column_name = 'CON_DBID'
                           THEN 'DECODE(con_dbid, ' || v_src || ', :d, con_dbid)'
                           WHEN c.data_type = 'DATE' OR c.data_type LIKE 'TIMESTAMP%'
                           THEN '"' || c.column_name || '" - :s'
                           ELSE '"' || c.column_name || '"' END;
        END LOOP;
        EXECUTE IMMEDIATE 'INSERT INTO ' || t.copy_table || ' (' || v_cols || ') SELECT '
                          || REPLACE(REPLACE(v_expr, ':d', TO_CHAR(v_dbid)), ':s', TO_CHAR(v_shift))
                          || ' FROM ' || t.copy_table || ' WHERE dbid = :1'
            USING v_src;
        DBMS_OUTPUT.PUT_LINE('  ' || RPAD(t.copy_table, 32) || LPAD(SQL%ROWCOUNT, 9) || ' rows');
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('  target ' || v_name || ' = dbid ' || v_dbid || ', copies of dbid '
                         || v_src || ' moved ' || v_shift || ' days back');
END;
/

UNDEFINE 1 2 3
WHENEVER SQLERROR CONTINUE
SET FEEDBACK ON
