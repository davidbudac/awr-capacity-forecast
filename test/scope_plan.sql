-- =====================================================================
-- test/scope_plan.sql -- does every seam read honour the session scope? (M24.11)
-- =====================================================================
--   @test/scope_plan.sql [VIEW_LIKE] [DETAIL]
--
-- Test-only, read-only. EXPLAINs SELECT * FROM <view> for every CAPV / CAPD /
-- CAPF / CAPA / CAPR view of CURRENT_SCHEMA (VIEW_LIKE narrows the list, a
-- LIKE pattern, default CAP%) and counts the plan's reads of a seam source
-- (CAP_H_* copies, CAP_FIXTURE_* tables, SYS.WRH$_* / WRM$_*) whose
-- predicates do not carry the CAP_SCOPE filter (the CLIENT_INFO lookup).
-- Such a read feeds every database's rows into the views above it, so a
-- report scoped to one target would cost a fleet report again. 0 is the only
-- right answer for every view. DETAIL = Y prints the offending plan lines.
--
-- Prints one line per view and leaves cap_scope_bad = the number of views
-- with an unscoped read. test/run_test.sql asserts it for the seam.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/test/scope_plan.sql"
SET DEFINE '&'
SET VERIFY OFF
SET FEEDBACK OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET LINESIZE 220

SET TERMOUT OFF
COLUMN 1 NEW_VALUE 1 NOPRINT
COLUMN 2 NEW_VALUE 2 NOPRINT
SELECT NULL AS "1", NULL AS "2" FROM dual WHERE 1 = 0;
SET TERMOUT ON

VARIABLE b_bad NUMBER

DECLARE
    v_owner  VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
    v_like   VARCHAR2(128) := UPPER(NVL(NULLIF('&1', '-'), 'CAP%'));
    v_detail BOOLEAN       := UPPER(NVL('&2', 'N')) = 'Y';
    v_id     VARCHAR2(30);
    v_seam   PLS_INTEGER;
    v_bad    PLS_INTEGER;
    v_views  PLS_INTEGER := 0;
    v_nbad   PLS_INTEGER := 0;
BEGIN
    FOR v IN (SELECT view_name
              FROM   all_views
              WHERE  owner = v_owner
                AND  view_name LIKE v_like
                AND  REGEXP_LIKE(view_name, '^CAP[VDFAR]_')
              ORDER  BY view_name) LOOP
        v_id := 'CAPSP' || TO_CHAR(v_views);
        v_views := v_views + 1;
        DELETE FROM plan_table WHERE statement_id = v_id;
        BEGIN
            EXECUTE IMMEDIATE 'EXPLAIN PLAN SET STATEMENT_ID = ''' || v_id
                              || ''' FOR SELECT * FROM ' || v.view_name;
        EXCEPTION
            WHEN OTHERS THEN
                v_nbad := v_nbad + 1;
                DBMS_OUTPUT.PUT_LINE(RPAD(v.view_name, 32) || ' EXPLAIN failed: ' || SQLERRM);
                CONTINUE;
        END;
        SELECT COUNT(*), COUNT(CASE WHEN NVL(access_predicates, ' ') || NVL(filter_predicates, ' ')
                                         NOT LIKE '%CLIENT_INFO%' THEN 1 END)
        INTO   v_seam, v_bad
        FROM   plan_table
        WHERE  statement_id = v_id
          AND  ((object_owner = v_owner
                 AND (object_name LIKE 'CAP\_H\_%' ESCAPE '\'
                      OR object_name LIKE 'CAP\_FIXTURE\_%' ESCAPE '\'))
                OR (object_owner = 'SYS'
                    AND (object_name LIKE 'WRH$\_%' ESCAPE '\'
                         OR object_name LIKE 'WRM$\_%' ESCAPE '\')));
        IF v_bad > 0 THEN
            v_nbad := v_nbad + 1;
        END IF;
        DBMS_OUTPUT.PUT_LINE(RPAD(v.view_name, 32) || LPAD(v_seam, 5) || ' seam reads'
                             || LPAD(v_bad, 5) || ' unscoped');
        IF v_detail AND v_bad > 0 THEN
            FOR p IN (SELECT id, operation || ' ' || options AS op, object_owner, object_name,
                             SUBSTR(NVL(filter_predicates, access_predicates), 1, 90) AS pr
                      FROM   plan_table
                      WHERE  statement_id = v_id
                        AND  object_owner IN (v_owner, 'SYS')
                        AND  REGEXP_LIKE(object_name, '^(CAP_H_|CAP_FIXTURE_|WR[HM]\$_)')
                        AND  NVL(access_predicates, ' ') || NVL(filter_predicates, ' ')
                             NOT LIKE '%CLIENT_INFO%'
                      ORDER  BY id) LOOP
                DBMS_OUTPUT.PUT_LINE('    ' || LPAD(p.id, 5) || ' ' || RPAD(p.op, 24)
                                     || RPAD(p.object_name, 30) || p.pr);
            END LOOP;
        END IF;
        DELETE FROM plan_table WHERE statement_id = v_id;
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE(v_views || ' view(s), ' || v_nbad || ' with an unscoped seam read');
    :b_bad := v_nbad;
END;
/

COLUMN sp_bad NEW_VALUE cap_scope_bad NOPRINT
SET TERMOUT OFF
SELECT TO_CHAR(:b_bad) AS sp_bad FROM dual;
SET TERMOUT ON
COLUMN sp_bad CLEAR
UNDEFINE 1 2
COLUMN 1 CLEAR
COLUMN 2 CLEAR
SET FEEDBACK ON
