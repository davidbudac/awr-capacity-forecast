--
-- create_owner.sql -- create a dedicated schema that owns the suite.
-- =====================================================================
-- Every install is a repository (M25): the owner reads AWR copied from its
-- targets over DB links, never its own AWR. Run this script once as SYSDBA
-- (or a DBA holding CREATE USER, GRANT ANY PRIVILEGE and GRANT ANY OBJECT
-- PRIVILEGE), then install into that owner. quickstart.sql and install.sh
-- (OWNER_CREATE=Y) call it.
--
-- Where to run it, and the default owner name:
--   a PDB    a local user, default AWRCAP: the usual home of the suite, also
--            when it measures its own CDB (the standalone path).
--   non-CDB  in the database. Default owner AWRCAP. No CONTAINER clause.
--   CDB      in CDB$ROOT: a COMMON user, default C##AWRCAP (the C## prefix is
--            mandatory), granted with CONTAINER=ALL. Possible, not the default.
--
-- Usage (every DEFINE is optional):
--   sqlplus / as sysdba
--   SQL> DEFINE owner       = C##AWRCAP   -- default by container, see above
--   SQL> DEFINE owner_pw    = secret      -- omitted: NO AUTHENTICATION
--   SQL> DEFINE owner_ts    = USERS       -- default: database default tablespace
--   SQL> DEFINE owner_quota = 1G          -- default 1G; UNLIMITED is allowed
--   SQL> @create_owner.sql
--
-- Without owner_pw the user is schema-only (NO AUTHENTICATION): nobody can log
-- in as it, and you install as SYSDBA with
--   ALTER SESSION SET CURRENT_SCHEMA = C##AWRCAP;
-- or give it a password later with ALTER USER ... IDENTIFIED BY. The password
-- may not contain a single or double quote.
--
-- What it grants, all DIRECT (views and the definer's-rights ML package
-- ignore privileges that arrive through a role):
--   system  CREATE SESSION / TABLE / VIEW / TYPE / PROCEDURE / MINING MODEL /
--           JOB / DATABASE LINK (the definer's-rights collector,
--           repository/cap_repo.sql, creates the links it reads targets over)
--   quota   owner_quota on owner_ts.
-- No DBA_HIST_* grant: the reader on each target holds those
-- (target/prepare.sql). An owner that a local-mode install left with them
-- (SELECT on DBA_HIST_* and V_$PARAMETER, CONTAINER_DATA = ALL) loses them
-- here, through revoke_local_grants.sql.
--
-- Idempotent: an existing user (ORA-01920) is kept as is, password and default
-- tablespace untouched; the quota and grants are re-applied. Exits non-zero if
-- any statement failed.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/create_owner.sql"
SET DEFINE '&'
SET VERIFY   OFF
SET FEEDBACK OFF
SET LINESIZE 200
SET TAB      OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR EXIT FAILURE

-- Optional DEFINEs. A zero-row NEW_VALUE query defines an unset variable as
-- empty and leaves a set one alone, so nothing prompts. Distinct column
-- aliases, because COLUMN settings key on the alias for the whole session.
SET TERMOUT OFF
COLUMN cap_o_in  NEW_VALUE owner       NOPRINT
COLUMN cap_p_in  NEW_VALUE owner_pw    NOPRINT
COLUMN cap_t_in  NEW_VALUE owner_ts    NOPRINT
COLUMN cap_q_in  NEW_VALUE owner_quota NOPRINT
SELECT NULL AS cap_o_in, NULL AS cap_p_in, NULL AS cap_t_in, NULL AS cap_q_in
FROM   dual WHERE 1 = 0;

COLUMN cap_o_eff NEW_VALUE owner       NOPRINT
COLUMN cap_t_eff NEW_VALUE owner_ts    NOPRINT
COLUMN cap_q_eff NEW_VALUE owner_quota NOPRINT
SELECT UPPER(NVL('&owner',
                 CASE SYS_CONTEXT('USERENV', 'CON_ID')
                      WHEN '1' THEN 'C##AWRCAP' ELSE 'AWRCAP' END)) AS cap_o_eff,
       UPPER(NVL('&owner_ts',
                 (SELECT property_value FROM database_properties
                  WHERE  property_name = 'DEFAULT_PERMANENT_TABLESPACE')))  AS cap_t_eff,
       UPPER(NVL('&owner_quota', '1G'))                                    AS cap_q_eff
FROM   dual;
COLUMN cap_o_in  CLEAR
COLUMN cap_p_in  CLEAR
COLUMN cap_t_in  CLEAR
COLUMN cap_q_in  CLEAR
COLUMN cap_o_eff CLEAR
COLUMN cap_t_eff CLEAR
COLUMN cap_q_eff CLEAR
SET TERMOUT ON

PROMPT
PROMPT ============================================================
PROMPT  AWR Capacity Forecast -- create_owner
PROMPT ============================================================

VARIABLE cap_owner_new VARCHAR2(1)
DECLARE
    v_con    VARCHAR2(10)  := SYS_CONTEXT('USERENV', 'CON_ID');
    v_owner  VARCHAR2(128) := DBMS_ASSERT.SIMPLE_SQL_NAME('&owner');
    v_pw     VARCHAR2(128) := '&owner_pw';
    v_ts     VARCHAR2(128) := DBMS_ASSERT.SIMPLE_SQL_NAME('&owner_ts');
    v_quota  VARCHAR2(20)  := '&owner_quota';
    v_cont   VARCHAR2(20);
    v_fail   PLS_INTEGER   := 0;

    TYPE t_list IS TABLE OF VARCHAR2(40);
    v_sys t_list := t_list(
        'CREATE SESSION', 'CREATE TABLE', 'CREATE VIEW', 'CREATE TYPE',
        'CREATE PROCEDURE', 'CREATE MINING MODEL', 'CREATE JOB',
        'CREATE DATABASE LINK');

    PROCEDURE run(p_sql IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
        DBMS_OUTPUT.PUT_LINE('  done    ' || p_sql);
    EXCEPTION
        WHEN OTHERS THEN
            v_fail := v_fail + 1;
            DBMS_OUTPUT.PUT_LINE('  FAILED  ' || p_sql);
            DBMS_OUTPUT.PUT_LINE('          ' || SQLERRM);
    END run;
BEGIN
    :cap_owner_new := 'Y';
    IF NOT REGEXP_LIKE(v_quota, '^([0-9]+[KMGT]?|UNLIMITED)$') THEN
        RAISE_APPLICATION_ERROR(-20001, 'owner_quota must look like 500M, 1G or UNLIMITED, not '
                                        || v_quota);
    END IF;
    IF v_con = '1' THEN
        IF v_owner NOT LIKE 'C##%' THEN
            RAISE_APPLICATION_ERROR(-20001, 'In CDB$ROOT the owner must be a common user'
                                            || ' with the C## prefix, not ' || v_owner);
        END IF;
        v_cont := ' CONTAINER=ALL';
    END IF;

    DBMS_OUTPUT.PUT_LINE('  owner      = ' || v_owner);
    DBMS_OUTPUT.PUT_LINE('  container  = ' || NVL(SYS_CONTEXT('USERENV', 'CON_NAME'), '(non-CDB)')
                         || CASE WHEN v_cont IS NOT NULL THEN '  (common user, CONTAINER=ALL)' END);
    DBMS_OUTPUT.PUT_LINE('  tablespace = ' || v_ts || '  quota ' || v_quota);
    DBMS_OUTPUT.PUT_LINE(' ');

    BEGIN
        EXECUTE IMMEDIATE 'CREATE USER ' || v_owner
            || CASE WHEN v_pw IS NULL THEN ' NO AUTHENTICATION'
                    ELSE ' IDENTIFIED BY "' || v_pw || '"' END
            || ' DEFAULT TABLESPACE ' || v_ts || v_cont;
        DBMS_OUTPUT.PUT_LINE('  done    CREATE USER ' || v_owner
            || CASE WHEN v_pw IS NULL THEN ' NO AUTHENTICATION'
                    ELSE ' IDENTIFIED BY ********' END
            || ' DEFAULT TABLESPACE ' || v_ts || v_cont);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = -1920 THEN
                :cap_owner_new := 'N';
                DBMS_OUTPUT.PUT_LINE('  exists  user ' || v_owner
                                     || ' (password and default tablespace left unchanged)');
            ELSE
                RAISE;
            END IF;
    END;

    run('ALTER USER ' || v_owner || ' QUOTA ' || v_quota || ' ON ' || v_ts);
    FOR i IN 1 .. v_sys.COUNT LOOP
        run('GRANT ' || v_sys(i) || ' TO ' || v_owner || v_cont);
    END LOOP;

    IF v_fail > 0 THEN
        RAISE_APPLICATION_ERROR(-20002, v_fail || ' statement(s) failed for owner '
                                        || v_owner || ' (see FAILED lines above).');
    END IF;
END;
/

DEFINE revoke_owner = '&owner'
@@revoke_local_grants.sql
SET DEFINE '&'
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE

DECLARE
    v_owner  VARCHAR2(128) := '&owner';
    v_auth   VARCHAR2(30);
BEGIN
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('  Owner ' || v_owner || ' is ready'
                         || CASE WHEN :cap_owner_new = 'Y' THEN ' (created)' ELSE ' (already existed)' END
                         || '. Next, from the repo root:');
    BEGIN
        SELECT authentication_type INTO v_auth FROM dba_users WHERE username = v_owner;
    EXCEPTION
        WHEN OTHERS THEN v_auth := NULL;
    END;
    IF v_auth = 'NONE' THEN
        DBMS_OUTPUT.PUT_LINE('    ALTER SESSION SET CURRENT_SCHEMA = ' || v_owner || ';');
    ELSE
        DBMS_OUTPUT.PUT_LINE('    CONNECT ' || v_owner || '/<password>');
    END IF;
    DBMS_OUTPUT.PUT_LINE('    @doctor.sql');
    DBMS_OUTPUT.PUT_LINE('    DEFINE deploy_mode = repository');
    DBMS_OUTPUT.PUT_LINE('    @install.sql');
END;
/

UNDEFINE owner_pw
WHENEVER SQLERROR CONTINUE
SET FEEDBACK ON
