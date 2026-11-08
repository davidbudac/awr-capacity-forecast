--
-- target/check.sql -- is this database ready to be a repository's target?
-- =====================================================================
-- Read-only. Run as SYSDBA where target/prepare.sql ran (CDB$ROOT or a
-- non-CDB), after it:
--   SQL> DEFINE reader = C##AWRRDR      -- optional, same default as prepare.sql
--   SQL> @target/check.sql
--
-- One PASS / WARN / FAIL line per check: the container, the reader account
-- and its password expiry, its direct grants on the seventeen DBA_HIST_* views, CONTAINER_DATA (CDB),
-- the Diagnostics Pack setting, STATISTICS_LEVEL, AWR retention / interval and
-- how fresh the newest snapshot is. Exits non-zero when a FAIL line printed.
-- The proof that the repository can read through its link is
-- cap_repo.add_target, which probes every view over the link.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/target/check.sql"
SET DEFINE '&'
SET VERIFY   OFF
SET FEEDBACK OFF
SET LINESIZE 200
SET TAB      OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR EXIT FAILURE

SET TERMOUT OFF
COLUMN cap_r_in NEW_VALUE reader NOPRINT
SELECT NULL AS cap_r_in FROM dual WHERE 1 = 0;
COLUMN cap_r_in CLEAR
SET TERMOUT ON

PROMPT
PROMPT ============================================================
PROMPT  AWR Capacity Forecast -- target check
PROMPT ============================================================

DECLARE
    v_con     VARCHAR2(10)  := SYS_CONTEXT('USERENV', 'CON_ID');
    v_cdb     BOOLEAN       := v_con <> '0';
    v_reader  VARCHAR2(128) := UPPER(NVL('&reader',
                                 CASE WHEN SYS_CONTEXT('USERENV', 'CON_ID') = '1'
                                      THEN 'C##AWRRDR' ELSE 'AWRRDR' END));
    v_fail    PLS_INTEGER   := 0;
    v_status  VARCHAR2(40);
    v_expiry  DATE;
    v_profile VARCHAR2(128);
    v_missing VARCHAR2(4000);
    v_n       NUMBER;
    v_txt     VARCHAR2(400);
    v_ret     NUMBER;
    v_ivl     NUMBER;
    v_age     NUMBER;

    TYPE t_list IS TABLE OF VARCHAR2(40);
    v_obj t_list := t_list(
        'DBA_HIST_SNAPSHOT', 'DBA_HIST_TBSPC_SPACE_USAGE', 'DBA_HIST_OSSTAT',
        'DBA_HIST_SYS_TIME_MODEL', 'DBA_HIST_CON_SYS_TIME_MODEL',
        'DBA_HIST_RESOURCE_LIMIT', 'DBA_HIST_SYSSTAT', 'DBA_HIST_CON_SYSSTAT',
        'DBA_HIST_PARAMETER', 'DBA_HIST_ASM_DISKGROUP_STAT', 'DBA_HIST_SEG_STAT',
        'DBA_HIST_TABLESPACE', 'DBA_HIST_DATAFILE', 'DBA_HIST_PDB_INSTANCE',
        'DBA_HIST_DATABASE_INSTANCE', 'DBA_HIST_ASM_DISKGROUP', 'DBA_HIST_SEG_STAT_OBJ');

    PROCEDURE emit(p_lvl VARCHAR2, p_what VARCHAR2, p_txt VARCHAR2) IS
    BEGIN
        IF p_lvl = 'FAIL' THEN v_fail := v_fail + 1; END IF;
        DBMS_OUTPUT.PUT_LINE('  [' || RPAD(p_lvl, 4) || '] ' || RPAD(p_what, 16) || ' ' || p_txt);
    END emit;

    FUNCTION param(p_name VARCHAR2) RETURN VARCHAR2 IS
        v VARCHAR2(400);
    BEGIN
        EXECUTE IMMEDIATE 'SELECT value FROM v$parameter WHERE name = :1' INTO v USING p_name;
        RETURN v;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN RETURN NULL;
    END param;
BEGIN
    IF v_cdb AND v_con <> '1' THEN
        emit('FAIL', 'container', SYS_CONTEXT('USERENV', 'CON_NAME')
             || ': run in CDB$ROOT, where the CDB''s AWR lives');
    ELSE
        emit('PASS', 'container', NVL(SYS_CONTEXT('USERENV', 'CON_NAME'), '(non-CDB)'));
    END IF;

    BEGIN
        SELECT account_status, expiry_date, profile INTO v_status, v_expiry, v_profile
        FROM   dba_users WHERE username = v_reader;
        emit(CASE WHEN v_status = 'OPEN' THEN 'PASS' ELSE 'FAIL' END, 'reader',
             v_reader || ' ' || v_status);
        IF v_expiry IS NOT NULL THEN
            emit('WARN', 'password expiry', TO_CHAR(v_expiry, 'YYYY-MM-DD') || ' (profile '
                 || v_profile || '): collects fail with ORA-28001 from then on. Give the reader'
                 || ' a profile with PASSWORD_LIFE_TIME UNLIMITED, or rotate it here and run'
                 || ' cap_repo.set_link_password on the repository');
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            emit('FAIL', 'reader', v_reader || ' does not exist: run target/prepare.sql');
    END;

    SELECT COUNT(*) INTO v_n FROM dba_sys_privs
    WHERE  grantee = v_reader AND privilege = 'CREATE SESSION';
    IF v_n = 0 THEN
        emit('FAIL', 'create session', 'not granted directly to ' || v_reader);
    END IF;

    FOR i IN 1 .. v_obj.COUNT LOOP
        SELECT COUNT(*) INTO v_n FROM dba_tab_privs
        WHERE  grantee = v_reader AND owner = 'SYS'
          AND  table_name = v_obj(i) AND privilege = 'SELECT';
        IF v_n = 0 THEN
            v_missing := v_missing || CASE WHEN v_missing IS NOT NULL THEN ', ' END || v_obj(i);
        END IF;
    END LOOP;
    IF v_missing IS NULL THEN
        emit('PASS', 'grants', 'SELECT on all ' || v_obj.COUNT || ' DBA_HIST_* views');
    ELSE
        emit('FAIL', 'grants', 'missing: ' || v_missing);
    END IF;

    IF v_cdb THEN
        EXECUTE IMMEDIATE
            'SELECT COUNT(*) FROM cdb_container_data'
            || ' WHERE username = :1 AND all_containers = ''Y'' AND object_name IS NULL'
            INTO v_n USING v_reader;
        IF v_n > 0 THEN
            emit('PASS', 'container data', 'ALL: the reader sees every container''s AWR rows');
        ELSE
            emit('FAIL', 'container data', 'not ALL: the reader would see CDB$ROOT rows only'
                 || ' (ALTER USER ' || v_reader || ' SET CONTAINER_DATA = ALL CONTAINER = CURRENT)');
        END IF;
    END IF;

    v_txt := param('control_management_pack_access');
    emit(CASE WHEN UPPER(v_txt) LIKE '%DIAGNOSTIC%' THEN 'PASS' ELSE 'FAIL' END,
         'pack access', NVL(v_txt, '(unknown)')
         || CASE WHEN UPPER(v_txt) NOT LIKE '%DIAGNOSTIC%' THEN ': AWR needs the Diagnostics Pack' END);

    v_txt := param('statistics_level');
    emit(CASE WHEN UPPER(v_txt) = 'BASIC' THEN 'FAIL' ELSE 'PASS' END,
         'statistics_level', NVL(v_txt, '(unknown)')
         || CASE WHEN UPPER(v_txt) = 'BASIC' THEN ': BASIC takes no AWR snapshots' END);

    EXECUTE IMMEDIATE
        'SELECT EXTRACT(DAY FROM retention) + EXTRACT(HOUR FROM retention) / 24,'
        || '       EXTRACT(DAY FROM snap_interval) * 1440 + EXTRACT(HOUR FROM snap_interval) * 60'
        || '       + EXTRACT(MINUTE FROM snap_interval)'
        || ' FROM dba_hist_wr_control'
        || ' WHERE dbid = (SELECT dbid FROM v$database)'
        INTO v_ret, v_ivl;
    emit(CASE WHEN v_ret < 2 THEN 'WARN' ELSE 'PASS' END, 'awr retention',
         ROUND(v_ret, 1) || ' days, snapshot every ' || v_ivl || ' min'
         || CASE WHEN v_ret < 2 THEN ': a collection outage longer than this loses data'
                 ELSE ' (the repository keeps its own history; this only has to cover an outage)' END);

    EXECUTE IMMEDIATE
        'SELECT COUNT(*), (CAST(SYSTIMESTAMP AS DATE) - CAST(MAX(end_interval_time) AS DATE)) * 24'
        || ' FROM dba_hist_snapshot WHERE dbid = (SELECT dbid FROM v$database)'
        INTO v_n, v_age;
    IF v_n = 0 THEN
        emit('FAIL', 'snapshots', 'none in DBA_HIST_SNAPSHOT');
    ELSE
        emit(CASE WHEN v_age > GREATEST(3, 3 * v_ivl / 60) THEN 'WARN' ELSE 'PASS' END, 'snapshots',
             v_n || ', newest ' || ROUND(v_age, 1) || ' h old');
    END IF;

    DBMS_OUTPUT.PUT_LINE(' ');
    IF v_fail > 0 THEN
        RAISE_APPLICATION_ERROR(-20002, v_fail || ' check(s) FAILED for target reader ' || v_reader);
    END IF;
    DBMS_OUTPUT.PUT_LINE('  Target ready for reader ' || v_reader || '.');
END;
/

WHENEVER SQLERROR CONTINUE
SET FEEDBACK ON
