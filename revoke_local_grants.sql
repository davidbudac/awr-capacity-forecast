--
-- revoke_local_grants.sql -- take back what a local-mode owner was granted.
-- =====================================================================
-- Before M25 an owner read its own AWR: create_owner.sql granted it SELECT on
-- DBA_HIST_* and V_$PARAMETER and, in CDB$ROOT, CONTAINER_DATA = ALL. Nothing
-- reads AWR in the owner's name any more (a repository reads its copies), so
-- create_owner.sql and uninstall.sql include this script to revoke those
-- grants from the owner. Also runnable on its own, from the repo root:
--
--   SQL> DEFINE revoke_owner = C##AWRCAP   -- default: the current schema
--   SQL> @revoke_local_grants.sql
--
-- Only the grantor can revoke, so it revokes as SYSDBA and otherwise prints
-- the statements to run as SYSDBA; a grant made CONTAINER=ALL is revoked only
-- from CDB$ROOT. Silent when the owner holds none of them. Idempotent.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/revoke_local_grants.sql"
SET DEFINE '&'
SET VERIFY OFF
SET FEEDBACK OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

SET TERMOUT OFF
COLUMN cap_rv_in NEW_VALUE revoke_owner NOPRINT
SELECT NULL AS cap_rv_in FROM dual WHERE 1 = 0;
COLUMN cap_rv_in CLEAR
SET TERMOUT ON

DECLARE
    v_owner VARCHAR2(128) := UPPER(NVL(TRIM('&revoke_owner'), SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')));
    v_dba   BOOLEAN       := SYS_CONTEXT('USERENV', 'ISDBA') = 'TRUE';
    v_root  BOOLEAN       := SYS_CONTEXT('USERENV', 'CON_ID') = '1';
    v_cur   SYS_REFCURSOR;
    v_tab   VARCHAR2(128);
    v_com   VARCHAR2(3);
    v_n     NUMBER;
    v_first BOOLEAN       := TRUE;

    PROCEDURE act(p_sql IN VARCHAR2, p_here IN BOOLEAN) IS
    BEGIN
        IF v_first THEN
            DBMS_OUTPUT.PUT_LINE('  local-mode grants of ' || v_owner || ' (retired in M25):');
            v_first := FALSE;
        END IF;
        IF v_dba AND p_here THEN
            EXECUTE IMMEDIATE p_sql;
            DBMS_OUTPUT.PUT_LINE('  done    ' || p_sql);
        ELSE
            DBMS_OUTPUT.PUT_LINE('  run as SYSDBA' || CASE WHEN NOT p_here THEN ' in CDB$ROOT' END
                                 || ': ' || p_sql || ';');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('  FAILED  ' || p_sql || ': ' || SQLERRM);
    END act;
BEGIN
    IF v_owner IN ('SYS', 'SYSTEM') THEN
        RETURN;
    END IF;
    IF v_dba THEN
        OPEN v_cur FOR 'SELECT table_name, common FROM dba_tab_privs'
                       || ' WHERE grantee = :1 AND owner = ''SYS'' AND privilege = ''SELECT'''
                       || q'[ AND (table_name LIKE 'DBA\_HIST\_%' ESCAPE '\' OR table_name = 'V_$PARAMETER')]'
                       || ' ORDER BY table_name' USING v_owner;
    ELSE
        OPEN v_cur FOR 'SELECT table_name, common FROM user_tab_privs'
                       || ' WHERE grantee = :1 AND owner = ''SYS'' AND privilege = ''SELECT'''
                       || q'[ AND (table_name LIKE 'DBA\_HIST\_%' ESCAPE '\' OR table_name = 'V_$PARAMETER')]'
                       || ' ORDER BY table_name' USING v_owner;
    END IF;
    LOOP
        FETCH v_cur INTO v_tab, v_com;
        EXIT WHEN v_cur%NOTFOUND;
        act('REVOKE SELECT ON SYS.' || v_tab || ' FROM ' || v_owner
            || CASE WHEN v_com = 'YES' THEN ' CONTAINER=ALL' END,
            v_com = 'NO' OR v_root);
    END LOOP;
    CLOSE v_cur;

    IF v_dba AND v_root THEN
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM dba_container_data WHERE username = :1'
            INTO v_n USING v_owner;
        IF v_n > 0 THEN
            act('ALTER USER ' || v_owner || ' SET CONTAINER_DATA = DEFAULT CONTAINER = CURRENT', TRUE);
        END IF;
    ELSIF v_owner LIKE 'C##%' AND NOT v_first THEN
        act('ALTER USER ' || v_owner || ' SET CONTAINER_DATA = DEFAULT CONTAINER = CURRENT', FALSE);
    END IF;
END;
/

UNDEFINE revoke_owner
