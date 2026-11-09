--
-- test/parity_fingerprint.sql -- one fingerprint line per suite view, to diff two installs.
-- =====================================================================
--   @test/parity_fingerprint.sql seam  <cut_snap_id>
--   @test/parity_fingerprint.sql stack
--
-- Prints "FP <view> <rows> <hash>" for every view of the current schema in
-- the layer, sorted by name, so two installs over the same AWR (two
-- repositories that collect one target, e.g. a standalone install and
-- another schema registered to the same root) can be compared with diff.
--   seam   the CAPV_* views but CAPV_CONTRACT and CAPV_TARGET; a view with a
--          SNAP_ID column counts only rows with snap_id <= cut, so a snapshot
--          that lands between the two runs does not show up as a difference.
--   stack  every CAPD_ / CAPF_ / CAPA_ / CAPR_ view but CAPR_TARGETS, whole.
--          Only equal when both installs see the same snapshots, so run both
--          right after a collect and check that CAPV_SNAPSHOT's newest
--          snap_id matches.
-- CAPV_TARGET and CAPR_TARGETS describe how each install is fed (its link,
-- address, reader and collect log), so they differ by design.
-- The hash is order-free: SUM over rows of ORA_HASH of the row's column
-- hashes. Numbers are hashed at nine significant digits, so two plans that
-- add up the same values in a different order still agree. LOB columns are
-- skipped, and so are the three clock columns (SYSDATE minus a stored time:
-- AGE_HOURS, AGE_DAYS, LAST_OK_AGE_HOURS), which differ between any two runs.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/test/parity_fingerprint.sql"
SET DEFINE '&'
SET VERIFY OFF
SET FEEDBACK OFF
SET LINESIZE 200
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

COLUMN 1 NEW_VALUE 1
COLUMN 2 NEW_VALUE 2
SELECT NULL AS "1", NULL AS "2" FROM dual WHERE 1 = 0;

DECLARE
    v_owner VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
    v_layer VARCHAR2(10)  := LOWER('&1');
    v_cut   NUMBER        := TO_NUMBER(NULLIF('&2', ''));
    v_pat   VARCHAR2(40);
    v_expr  VARCHAR2(32767);
    v_where VARCHAR2(100);
    v_n     NUMBER;
    v_h     NUMBER;
    v_t0    PLS_INTEGER;
BEGIN
    IF v_layer = 'seam' THEN
        IF v_cut IS NULL THEN
            RAISE_APPLICATION_ERROR(-20001, 'seam needs a cut snap_id: @test/parity_fingerprint.sql seam 1234');
        END IF;
        v_pat := '^CAPV_';
    ELSIF v_layer = 'stack' THEN
        v_pat := '^CAP[DFAR]_';
    ELSE
        RAISE_APPLICATION_ERROR(-20001, 'layer must be seam or stack, not "' || v_layer || '"');
    END IF;

    FOR v IN (SELECT view_name FROM all_views
              WHERE  owner = v_owner AND REGEXP_LIKE(view_name, v_pat)
              ORDER  BY view_name) LOOP
        -- CAPV_CONTRACT has no snap_id to cut on, and the target views differ by design.
        CONTINUE WHEN v.view_name IN ('CAPV_CONTRACT', 'CAPV_TARGET', 'CAPR_TARGETS');
        v_expr  := NULL;
        v_where := NULL;
        FOR c IN (SELECT column_name, data_type FROM all_tab_columns
                  WHERE  owner = v_owner AND table_name = v.view_name
                  ORDER  BY column_id) LOOP
            CONTINUE WHEN c.data_type LIKE '%LOB' OR c.data_type IN ('LONG', 'BLOB', 'BFILE')
                       OR c.column_name IN ('AGE_HOURS', 'AGE_DAYS', 'LAST_OK_AGE_HOURS');
            v_expr := v_expr || CASE WHEN v_expr IS NOT NULL THEN ' || ''|'' || ' END
                   || 'NVL(TO_CHAR(ORA_HASH('
                   || CASE
                          WHEN c.data_type IN ('NUMBER', 'FLOAT', 'BINARY_DOUBLE', 'BINARY_FLOAT')
                          THEN 'TO_CHAR("' || c.column_name || '", ''FM9.99999999EEEE'')'
                          WHEN c.data_type = 'DATE'
                          THEN 'TO_CHAR("' || c.column_name || '", ''YYYYMMDDHH24MISS'')'
                          WHEN c.data_type LIKE 'TIMESTAMP%'
                          THEN 'TO_CHAR("' || c.column_name || '", ''YYYYMMDDHH24MISSFF6'')'
                          ELSE '"' || c.column_name || '"'
                      END
                   || ')), ''~'')';
            IF v_layer = 'seam' AND c.column_name = 'SNAP_ID' THEN
                v_where := ' WHERE snap_id <= ' || v_cut;
            END IF;
        END LOOP;
        v_t0 := DBMS_UTILITY.GET_TIME;
        BEGIN
            EXECUTE IMMEDIATE 'SELECT COUNT(*), NVL(SUM(ORA_HASH(' || v_expr || ')), 0) FROM "'
                              || v.view_name || '"' || v_where
                INTO v_n, v_h;
            DBMS_OUTPUT.PUT_LINE('FP ' || RPAD(v.view_name, 30) || ' ' || LPAD(v_n, 9) || ' ' || v_h
                                 || '   -- ' || ROUND((DBMS_UTILITY.GET_TIME - v_t0) / 100) || ' s');
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('FP ' || RPAD(v.view_name, 30) || ' ERROR ' || SQLCODE);
        END;
    END LOOP;
    FOR s IN (SELECT 1 FROM all_views WHERE owner = v_owner AND view_name = 'CAPV_SNAPSHOT') LOOP
        EXECUTE IMMEDIATE 'SELECT MAX(snap_id) FROM capv_snapshot' INTO v_n;
        DBMS_OUTPUT.PUT_LINE('FP-NEWEST-SNAP ' || v_n);
    END LOOP;
END;
/

UNDEFINE 1 2
