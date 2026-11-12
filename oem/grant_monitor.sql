--
-- oem/grant_monitor.sql -- let a monitoring user read the suite's alert
-- states (oem/awrcap_alerts.sql, the Enterprise Manager metric extension).
-- =====================================================================
-- Run where the suite is installed (the PDB of the owner, or the non-CDB),
-- as the suite owner or as SYSDBA with CURRENT_SCHEMA set to the owner:
--   SQL> @oem/grant_monitor.sql DBSNMP
--   SQL> ALTER SESSION SET CURRENT_SCHEMA = AWRCAP
--   SQL> @oem/grant_monitor.sql DBSNMP
-- The argument is the user Enterprise Manager monitors the database with
-- (DBSNMP unless the target's monitoring credentials name another).
--
-- It grants READ on two objects of the owner and nothing else:
--   CAP_ALERT_STATE   table  the alert states cap_results.refresh keeps
--   CAPR_RUNS         view   the refresh runs and how old the last OK one is
-- READ allows a query and not SELECT ... FOR UPDATE. Both objects survive a
-- re-install (CAP_ALERT_STATE is never dropped, CAPR_RUNS is replaced in
-- place), so the grants do too. uninstall.sql drops the objects and with
-- them the grants. Take them back by hand with the two REVOKE lines the
-- script prints.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/oem/grant_monitor.sql"
SET DEFINE '&'
SET VERIFY   OFF
SET FEEDBACK OFF
SET LINESIZE 200
SET TAB      OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR EXIT FAILURE

SET TERMOUT OFF
COLUMN 1 NEW_VALUE 1 NOPRINT
SELECT NULL AS "1" FROM dual WHERE 1 = 0;
COLUMN 1 CLEAR
SET TERMOUT ON

DECLARE
    v_owner VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
    v_in    VARCHAR2(200) := UPPER(TRIM('&1'));
    v_user  VARCHAR2(128);
    v_n     NUMBER;

    TYPE t_list IS TABLE OF VARCHAR2(30);
    v_obj t_list := t_list('CAP_ALERT_STATE', 'CAPR_RUNS');
BEGIN
    IF v_in IS NULL THEN
        RAISE_APPLICATION_ERROR(-20001, 'usage: @oem/grant_monitor.sql <monitoring user>');
    END IF;
    IF NOT REGEXP_LIKE(v_in, '^[A-Z][A-Z0-9_$#]{0,127}$') THEN
        RAISE_APPLICATION_ERROR(-20001, 'the monitoring user must be a plain SQL name, not ' || v_in);
    END IF;
    SELECT COUNT(*) INTO v_n FROM all_users WHERE username = v_in;
    IF v_n = 0 THEN
        RAISE_APPLICATION_ERROR(-20001, 'no user ' || v_in || ' in '
            || NVL(SYS_CONTEXT('USERENV', 'CON_NAME'), 'this database'));
    END IF;
    v_user := v_in;
    FOR i IN 1 .. v_obj.COUNT LOOP
        SELECT COUNT(*) INTO v_n FROM all_objects
        WHERE  owner = v_owner AND object_name = v_obj(i) AND object_type IN ('TABLE', 'VIEW');
        IF v_n = 0 THEN
            RAISE_APPLICATION_ERROR(-20001, v_owner || ' has no ' || v_obj(i) || ': run this in the'
                || ' suite owner''s schema (ALTER SESSION SET CURRENT_SCHEMA), after install.sql');
        END IF;
    END LOOP;
    IF v_user = v_owner THEN
        RAISE_APPLICATION_ERROR(-20001, v_user || ' owns the suite here and needs no grant');
    END IF;

    DBMS_OUTPUT.PUT_LINE('  owner            = ' || v_owner);
    DBMS_OUTPUT.PUT_LINE('  monitoring user  = ' || v_user);
    DBMS_OUTPUT.PUT_LINE(' ');
    FOR i IN 1 .. v_obj.COUNT LOOP
        EXECUTE IMMEDIATE 'GRANT READ ON "' || v_owner || '".' || v_obj(i) || ' TO "' || v_user || '"';
        DBMS_OUTPUT.PUT_LINE('  done    GRANT READ ON ' || v_owner || '.' || v_obj(i) || ' TO ' || v_user);
    END LOOP;
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('  Check as ' || v_user || ':  @oem/awrcap_alerts.sql ' || v_owner);
    DBMS_OUTPUT.PUT_LINE('  To take the grants back:');
    FOR i IN 1 .. v_obj.COUNT LOOP
        DBMS_OUTPUT.PUT_LINE('    REVOKE READ ON ' || v_owner || '.' || v_obj(i) || ' FROM ' || v_user || ';');
    END LOOP;
END;
/

UNDEFINE 1
WHENEVER SQLERROR CONTINUE
SET FEEDBACK ON
