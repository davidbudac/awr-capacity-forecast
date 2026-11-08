--
-- target/prepare.sql -- make a database a TARGET of a repository.
-- =====================================================================
-- A target runs none of the suite. It only needs a read-only user the
-- repository's DB link logs in as; the repository copies the AWR views below
-- and does every calculation itself (repository/cap_repo.sql). This script
-- creates that user and changes nothing else on the database.
--
-- Run as SYSDBA in CDB$ROOT (AWR lives at the CDB level) or in a non-CDB:
--   sqlplus / as sysdba
--   SQL> DEFINE reader    = C##AWRRDR   -- optional; AWRRDR in a non-CDB
--   SQL> DEFINE reader_pw = secret      -- required, no quotes
--   SQL> @target/prepare.sql
--   SQL> @target/check.sql
--
-- What it does:
--   * CREATE USER reader (a common user in CDB$ROOT). An existing user is
--     kept and its password set to reader_pw.
--   * CREATE SESSION, and SELECT on the seventeen DBA_HIST_* views the
--     repository copies (repository/build.py checks this list against its
--     manifest). Direct grants, nothing through a role.
--   * In CDB$ROOT: CONTAINER_DATA = ALL. Without it a common user reading the
--     DBA_HIST_* views from the root sees the root's rows only (verified on
--     19.27: 1 container instead of 3), and every PDB series would be missing.
-- The Diagnostics Pack is still required on the target: the repository reads
-- its AWR.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/target/prepare.sql"
SET DEFINE '&'
SET VERIFY   OFF
SET FEEDBACK OFF
SET LINESIZE 200
SET TAB      OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR EXIT FAILURE

SET TERMOUT OFF
COLUMN cap_r_in NEW_VALUE reader    NOPRINT
COLUMN cap_w_in NEW_VALUE reader_pw NOPRINT
SELECT NULL AS cap_r_in, NULL AS cap_w_in FROM dual WHERE 1 = 0;
COLUMN cap_r_in CLEAR
COLUMN cap_w_in CLEAR
SET TERMOUT ON

PROMPT
PROMPT ============================================================
PROMPT  AWR Capacity Forecast -- prepare a target
PROMPT ============================================================

DECLARE
    v_con    VARCHAR2(10)  := SYS_CONTEXT('USERENV', 'CON_ID');
    v_cdb    BOOLEAN       := v_con <> '0';
    v_reader VARCHAR2(128) := UPPER(NVL('&reader',
                                CASE WHEN SYS_CONTEXT('USERENV', 'CON_ID') = '1'
                                     THEN 'C##AWRRDR' ELSE 'AWRRDR' END));
    v_pw     VARCHAR2(200) := q'~&reader_pw~';
    v_cont   VARCHAR2(30);
    v_host   VARCHAR2(200) := SYS_CONTEXT('USERENV', 'SERVER_HOST');
    v_svc    VARCHAR2(200) := SYS_CONTEXT('USERENV', 'DB_UNIQUE_NAME')
                              || CASE WHEN SYS_CONTEXT('USERENV', 'DB_DOMAIN') IS NOT NULL
                                      THEN '.' || SYS_CONTEXT('USERENV', 'DB_DOMAIN') END;

    TYPE t_list IS TABLE OF VARCHAR2(40);
    v_obj t_list := t_list(
        'DBA_HIST_SNAPSHOT', 'DBA_HIST_TBSPC_SPACE_USAGE', 'DBA_HIST_OSSTAT',
        'DBA_HIST_SYS_TIME_MODEL', 'DBA_HIST_CON_SYS_TIME_MODEL',
        'DBA_HIST_RESOURCE_LIMIT', 'DBA_HIST_SYSSTAT', 'DBA_HIST_CON_SYSSTAT',
        'DBA_HIST_PARAMETER', 'DBA_HIST_ASM_DISKGROUP_STAT', 'DBA_HIST_SEG_STAT',
        'DBA_HIST_TABLESPACE', 'DBA_HIST_DATAFILE', 'DBA_HIST_PDB_INSTANCE',
        'DBA_HIST_DATABASE_INSTANCE', 'DBA_HIST_ASM_DISKGROUP', 'DBA_HIST_SEG_STAT_OBJ');

    PROCEDURE run(p_sql IN VARCHAR2, p_show IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
        DBMS_OUTPUT.PUT_LINE('  done    ' || NVL(p_show, p_sql));
    END run;
BEGIN
    IF v_cdb AND v_con <> '1' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Run this in CDB$ROOT, not in '
            || SYS_CONTEXT('USERENV', 'CON_NAME') || ': AWR lives at the CDB level.');
    END IF;
    IF v_cdb AND v_reader NOT LIKE 'C##%' THEN
        RAISE_APPLICATION_ERROR(-20001, 'In CDB$ROOT the reader must be a common user'
                                        || ' with the C## prefix, not ' || v_reader);
    END IF;
    IF NOT REGEXP_LIKE(v_reader, '^[A-Z][A-Z0-9_$#]{0,127}$') THEN
        RAISE_APPLICATION_ERROR(-20001, 'reader must be a plain SQL name, not ' || v_reader);
    END IF;
    IF v_pw IS NULL OR REGEXP_LIKE(v_pw, '["'']') THEN
        RAISE_APPLICATION_ERROR(-20001, 'DEFINE reader_pw first (no quotes): the repository''s'
                                        || ' DB link logs in with it.');
    END IF;
    IF v_cdb THEN v_cont := ' CONTAINER=ALL'; END IF;

    DBMS_OUTPUT.PUT_LINE('  reader     = ' || v_reader);
    DBMS_OUTPUT.PUT_LINE('  container  = ' || NVL(SYS_CONTEXT('USERENV', 'CON_NAME'), '(non-CDB)'));
    DBMS_OUTPUT.PUT_LINE(' ');

    BEGIN
        run('CREATE USER ' || v_reader || ' IDENTIFIED BY "' || v_pw || '"' || v_cont,
            'CREATE USER ' || v_reader || ' IDENTIFIED BY ********' || v_cont);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -1920 THEN RAISE; END IF;
            run('ALTER USER ' || v_reader || ' IDENTIFIED BY "' || v_pw || '"',
                'ALTER USER ' || v_reader || ' IDENTIFIED BY ********  (user existed)');
    END;
    run('GRANT CREATE SESSION TO ' || v_reader);
    FOR i IN 1 .. v_obj.COUNT LOOP
        run('GRANT SELECT ON SYS.' || v_obj(i) || ' TO ' || v_reader);
    END LOOP;
    IF v_cdb THEN
        run('ALTER USER ' || v_reader || ' SET CONTAINER_DATA = ALL CONTAINER = CURRENT');
    END IF;

    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE('  Reader ' || v_reader || ' is ready. Register this target on the repository');
    DBMS_OUTPUT.PUT_LINE('  (as the suite owner there). Check the address against lsnrctl status:');
    DBMS_OUTPUT.PUT_LINE('    EXEC cap_repo.add_target(''' || UPPER(SYS_CONTEXT('USERENV', 'DB_UNIQUE_NAME'))
                         || ''', ''//' || v_host || ':1521/' || v_svc || ''', '''
                         || v_reader || ''', ''<password>'')');
    DBMS_OUTPUT.PUT_LINE('    EXEC cap_repo.collect');
END;
/

UNDEFINE reader_pw
WHENEVER SQLERROR CONTINUE
SET FEEDBACK ON
