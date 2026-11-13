--
-- doctor.sql -- preflight diagnostic for the AWR capacity-forecast suite.
-- =====================================================================
-- Answers, in one page, "will this suite actually produce forecasts for me,
-- and if not, why not?" -- BEFORE you run install.sql, and again afterwards.
--
-- Usage: run it as the suite owner, or as SYSDBA in the owner's schema, where
-- you install (or have installed) the repository:
--
--   sqlplus / as sysdba
--   SQL> ALTER SESSION SET CONTAINER = PDB1;
--   SQL> ALTER SESSION SET CURRENT_SCHEMA = AWRCAP;
--   SQL> @doctor.sql
--
-- STRICTLY READ-ONLY. It creates nothing, drops nothing, writes nothing: it
-- only SELECTs from data dictionary views (and, once installed, the suite's
-- own CAP_CONFIG / CAPV_ / CAPF_ views) and prints a PASS/WARN/FAIL checklist
-- through DBMS_OUTPUT.
--
-- It checks the repository side: this schema, its privileges, the history
-- the copies hold, the install, the config, the results layer, the jobs and
-- the targets. A measured database is checked where it runs, by
-- target/check.sql (pack access, AWR retention and interval, the reader's
-- grants, container visibility).
--
-- Section 10 checks CAP_NIGHTLY_JOB, its last run and the nightly steps that
-- run failed, and in repository mode CAP_COLLECT_JOB. In repository mode
-- section 11 checks every registered target: its link, its collect health
-- (state, freshness, gaps), whether its memory history (each optional
-- CAP_H_* copy) holds rows, the days copied against section 7's needs and
-- when the reader's password expires (reader_expiry_warn_days). The link is
-- read through cap_repo.ping and cap_repo.reader_expiry, which only SELECT
-- over it: a private DB link resolves for the session user, so only the
-- owner's definer's-rights code can use it when doctor runs as SYSDBA.
--
-- Section 12 reads CAPR_ALERT_VOLUME once, live (no refresh run needed):
-- the alerts the knobs raise now per kind, and for every noisy anomaly
-- series (noise_episodes, noise_flag_pct) the two ways to quiet it as
-- UPDATE cap_config statements. Its verdict is PASS or WARN, never FAIL.
--
-- It leaves one SQL*Plus variable behind for callers: cap_doctor_fail, the
-- number of FAIL lines ("1" if the block did not finish). quickstart.sql stops
-- before install when it is not 0.
--
-- Doctor takes the mode from the installed CAPV_SNAPSHOT and assumes
-- repository before install. A caller may say which install it is about to
-- run (any other value is ignored with a note):
--   SQL> DEFINE cap_doctor_mode = fixture     -- repository | fixture
--   SQL> @doctor.sql
--
-- Everything runs inside ONE anonymous block with per-check EXCEPTION
-- handlers, so no single privilege error can cut the checklist short.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/doctor.sql"
SET FEEDBACK OFF
SET VERIFY OFF
SET LINESIZE 200
SET TAB OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR CONTINUE

VARIABLE cap_doctor_fail_n NUMBER
VARIABLE cap_doctor_mode_v VARCHAR2(30)

-- Optional cap_doctor_mode, read without prompting: a zero-row NEW_VALUE
-- query defines an unset variable as empty and leaves a set one alone.
SET DEFINE '&'
SET TERMOUT OFF
COLUMN cap_mode_in NEW_VALUE cap_doctor_mode NOPRINT
SELECT NULL AS cap_mode_in FROM dual WHERE 1 = 0;
COLUMN cap_mode_in CLEAR
SET TERMOUT ON
EXEC :cap_doctor_mode_v := LOWER(TRIM('&cap_doctor_mode'))
SET DEFINE OFF

DECLARE
    -- checklist tallies
    n_pass      PLS_INTEGER := 0;
    n_warn      PLS_INTEGER := 0;
    n_fail      PLS_INTEGER := 0;

    v_schema    VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
    v_session   VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');

    v_installed     BOOLEAN     := FALSE;
    v_deploy_mode   VARCHAR2(30);
    v_seam_refs     VARCHAR2(200);
    v_intended      VARCHAR2(30) := :cap_doctor_mode_v;   -- caller's DEFINE, or NULL
    v_check_mode    VARCHAR2(30);

    -- knobs: CAP_CFG when installed, else the shipped defaults (05_config)
    v_knob_src      VARCHAR2(60) := 'shipped defaults (suite not installed here)';
    v_train         NUMBER := 90;
    v_min_train     NUMBER := 14;
    v_dow_weeks     NUMBER := 8;
    v_shift_days    NUMBER := 7;
    v_shift_base    NUMBER := 28;
    v_holdout       NUMBER := 28;
    v_esm_step      NUMBER := 30;
    v_mem_window    NUMBER := 30;

    TYPE t_names IS TABLE OF VARCHAR2(40);
    v_privs t_names := t_names(
        'CREATE TABLE',
        'CREATE VIEW',
        'CREATE PROCEDURE',
        'CREATE TYPE',
        'CREATE MINING MODEL',
        'CREATE JOB');

    -- Days of history each feature needs (section 7), also checked per
    -- target in section 11. The label's text before " (" is its short name.
    -- CAP_CFG_CHECK's repo_retention_days rule (ddl/05) takes the longest of
    -- the same windows: keep the two in step.
    TYPE t_need IS RECORD (label VARCHAR2(60), days NUMBER);
    TYPE t_needs IS TABLE OF t_need INDEX BY PLS_INTEGER;
    v_needs t_needs;

    PROCEDURE hdr(p_text IN VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(' ');
        DBMS_OUTPUT.PUT_LINE(p_text);
        DBMS_OUTPUT.PUT_LINE(RPAD('-', 74, '-'));
    END hdr;

    PROCEDURE note(p_text IN VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('         ' || p_text);
    END note;

    PROCEDURE tally(p_status IN VARCHAR2) IS
    BEGIN
        CASE p_status
            WHEN 'PASS' THEN n_pass := n_pass + 1;
            WHEN 'WARN' THEN n_warn := n_warn + 1;
            WHEN 'FAIL' THEN n_fail := n_fail + 1;
            ELSE NULL;      -- INFO lines do not count
        END CASE;
    END tally;

    -- One checklist line. Counts toward the summary tallies.
    PROCEDURE emit(p_status IN VARCHAR2,
                   p_label  IN VARCHAR2,
                   p_detail IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        tally(p_status);
        DBMS_OUTPUT.PUT_LINE('  [' || RPAD(p_status, 4) || '] '
                             || RPAD(p_label, 30) || ' ' || p_detail);
    END emit;

    -- SQLERRM trimmed to one readable line.
    FUNCTION err RETURN VARCHAR2 IS
    BEGIN
        RETURN SUBSTR(REPLACE(REPLACE(SQLERRM, CHR(10), ' '), CHR(13), ' '), 1, 90);
    END err;

    -- A knob read through CAP_CFG, or NULL when the knob or the view is missing.
    FUNCTION knob_raw(p_name IN VARCHAR2) RETURN NUMBER IS
        v_n NUMBER;
    BEGIN
        EXECUTE IMMEDIATE 'SELECT ' || DBMS_ASSERT.SIMPLE_SQL_NAME(p_name) || ' FROM cap_cfg'
            INTO v_n;
        RETURN v_n;
    EXCEPTION
        WHEN OTHERS THEN RETURN NULL;
    END knob_raw;

    FUNCTION knob(p_name IN VARCHAR2, p_default IN NUMBER) RETURN NUMBER IS
    BEGIN
        RETURN NVL(knob_raw(p_name), p_default);
    END knob;

    FUNCTION count_days(p_sql IN VARCHAR2, p_err OUT VARCHAR2) RETURN NUMBER IS
        v_n NUMBER;
    BEGIN
        EXECUTE IMMEDIATE p_sql INTO v_n;
        RETURN v_n;
    EXCEPTION
        WHEN OTHERS THEN
            p_err := err;
            RETURN NULL;
    END count_days;

    FUNCTION direct_sys_priv(p_priv IN VARCHAR2) RETURN NUMBER IS
        v_n NUMBER;
    BEGIN
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT COUNT(*) FROM dba_sys_privs WHERE grantee = :g AND privilege = :p'
                INTO v_n USING v_schema, p_priv;
        EXCEPTION
            WHEN OTHERS THEN
                IF v_schema <> v_session THEN
                    RETURN NULL;
                END IF;
                EXECUTE IMMEDIATE
                    'SELECT COUNT(*) FROM user_sys_privs WHERE privilege = :p'
                    INTO v_n USING p_priv;
        END;
        RETURN SIGN(v_n);
    EXCEPTION
        WHEN OTHERS THEN RETURN NULL;
    END direct_sys_priv;

    PROCEDURE add_need(p_label IN VARCHAR2, p_days IN NUMBER) IS
        i PLS_INTEGER := v_needs.COUNT + 1;
    BEGIN
        v_needs(i).label := p_label;
        v_needs(i).days  := p_days;
    END add_need;

    -- A scheduler job of the suite: enabled or not, and its last run.
    -- p_hint says where it comes from when it is missing.
    PROCEDURE job_check(p_job IN VARCHAR2, p_hint IN VARCHAR2) IS
        v_on  VARCHAR2(5);
        v_st  VARCHAR2(30);
        v_at  VARCHAR2(20);
        v_txt VARCHAR2(400);
    BEGIN
        EXECUTE IMMEDIATE
            'SELECT enabled, state FROM all_scheduler_jobs WHERE owner = :o AND job_name = :j'
            INTO v_on, v_st USING v_schema, p_job;
        emit(CASE WHEN v_on = 'TRUE' THEN 'PASS' ELSE 'INFO' END, p_job,
             CASE WHEN v_on = 'TRUE' THEN 'enabled' ELSE 'disabled (install_jobs.sql creates it disabled)' END
             || ', state ' || v_st);
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT status, TO_CHAR(actual_start_date, ''YYYY-MM-DD HH24:MI''),'
                || ' SUBSTR(errors, 1, 120) FROM ('
                || ' SELECT status, actual_start_date, errors FROM all_scheduler_job_run_details'
                || ' WHERE owner = :o AND job_name = :j'
                || ' ORDER BY log_date DESC) WHERE ROWNUM = 1'
                INTO v_st, v_at, v_txt USING v_schema, p_job;
            emit(CASE WHEN v_st = 'SUCCEEDED' THEN 'PASS' ELSE 'WARN' END, p_job || ' last run',
                 v_st || ' at ' || v_at || CASE WHEN v_txt IS NOT NULL THEN ': ' || v_txt END);
        EXCEPTION
            WHEN NO_DATA_FOUND THEN emit('INFO', p_job || ' last run', 'never ran');
            WHEN OTHERS THEN emit('INFO', p_job || ' last run', 'cannot read job history: ' || err);
        END;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            emit('INFO', p_job, 'not created (' || p_hint || ')');
        WHEN OTHERS THEN
            emit('INFO', p_job, 'cannot read ALL_SCHEDULER_JOBS: ' || err);
    END job_check;

BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 74, '='));
    DBMS_OUTPUT.PUT_LINE(' AWR Capacity Forecast -- doctor.sql preflight');
    DBMS_OUTPUT.PUT_LINE(' ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 74, '='));
    note('session user    : ' || v_session);
    note('current schema  : ' || v_schema);
    note('container       : ' || NVL(SYS_CONTEXT('USERENV', 'CON_NAME'), '(non-CDB)'));
    note('database        : ' || SYS_CONTEXT('USERENV', 'DB_NAME')
                              || '  instance ' || SYS_CONTEXT('USERENV', 'INSTANCE_NAME'));
    note('NOTE: probes and SESSION_PRIVS below are the SESSION USER''s. ALTER SESSION');
    note('      SET CURRENT_SCHEMA changes where objects resolve, not what you may do;');
    note('      the direct-grant checks look at the current schema itself.');
    IF v_intended = 'local' THEN
        note('mode under test : local ignored: local mode is retired (M25); a standalone');
        note('                  install is a repository that reads its own database');
        v_intended := NULL;
    ELSIF v_intended NOT IN ('repository', 'fixture') THEN
        note('mode under test : ' || v_intended || ' ignored (DEFINE cap_doctor_mode = repository | fixture)');
        v_intended := NULL;
    ELSIF v_intended IS NOT NULL THEN
        note('mode under test : ' || v_intended || ' (DEFINE cap_doctor_mode)');
    END IF;

    -- Installed here? Then the knobs come from CAP_CFG and the deploy mode is
    -- inferred from what CAPV_SNAPSHOT actually depends on.
    DECLARE
        v_rows NUMBER;
    BEGIN
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM cap_config' INTO v_rows;
        v_installed  := TRUE;
        v_knob_src   := 'CAP_CFG';
    EXCEPTION
        WHEN OTHERS THEN v_installed := FALSE;
    END;
    IF v_installed THEN
        v_train      := knob('train_days',            v_train);
        v_min_train  := knob('min_train_days',        v_min_train);
        v_dow_weeks  := knob('dow_weeks',             v_dow_weeks);
        v_shift_days := knob('shift_days',            v_shift_days);
        v_shift_base := knob('shift_baseline_days',   v_shift_base);
        v_holdout    := knob('backtest_holdout_days', v_holdout);
        v_esm_step   := knob('esm_prediction_step',   v_esm_step);
        v_mem_window := knob('mem_window_days',       v_mem_window);

        FOR r IN (SELECT referenced_owner, referenced_name
                  FROM   all_dependencies
                  WHERE  owner = v_schema
                    AND  name  = 'CAPV_SNAPSHOT'
                    AND  type  = 'VIEW') LOOP
            v_seam_refs := SUBSTR(v_seam_refs || r.referenced_name || ' ', 1, 200);
            IF    r.referenced_name LIKE 'CAP\_H\_%' ESCAPE '\' THEN v_deploy_mode := 'repository';
            ELSIF r.referenced_name LIKE 'CAP\_FIXTURE\_%' ESCAPE '\' THEN v_deploy_mode := 'fixture';
            ELSIF r.referenced_owner = 'SYS' AND r.referenced_name LIKE 'DBA\_%' ESCAPE '\'
                  AND v_deploy_mode IS NULL                    THEN v_deploy_mode := 'local';
            END IF;
        END LOOP;
    END IF;
    v_check_mode := COALESCE(v_intended, v_deploy_mode, 'repository');
    IF v_check_mode = 'repository' THEN
        v_privs.EXTEND;
        v_privs(v_privs.LAST) := 'CREATE DATABASE LINK';
    END IF;
    add_need('trend fit (min_train_days)',                       v_min_train);
    add_need('full training window (train_days)',                v_train);
    add_need('CPU weekday baseline (dow_weeks*7)',               v_dow_weeks * 7);
    add_need('CPU level shift (shift_days+shift_baseline_days)', v_shift_days + v_shift_base);
    add_need('backtest (backtest_holdout_days+min_train_days)',  v_holdout + v_min_train);
    add_need('ESM +' || LEAST(30, v_esm_step) || ' horizon (4 x step, 19c cap 30)',
             4 * LEAST(30, v_esm_step));
    add_need('memory verdict window (mem_window_days)',          v_mem_window);

    -- =================================================================
    -- 1. Target schema
    -- =================================================================
    hdr(' 1. Target schema (where install.sql would create objects)');
    IF v_schema = 'SYS' THEN
        emit('WARN', 'current schema', 'SYS -- every CAP* object would be owned by SYS');
        note('Install into a dedicated owner instead: run @create_owner.sql as SYSDBA,');
        note('then install as that user (or under ALTER SESSION SET CURRENT_SCHEMA).');
    ELSE
        emit('PASS', 'current schema', v_schema);
    END IF;
    note('Sections 2, 3, 5 and 6 check a measured database: run @target/check.sql');
    note('on each target (as SYSDBA in its CDB$ROOT, or in a non-CDB).');

    -- =================================================================
    -- 4. Object-creation privileges
    -- =================================================================
    hdr(' 4. Privileges to install (SESSION_PRIVS of the session user)');
    FOR i IN 1 .. v_privs.COUNT LOOP
        DECLARE
            v_n NUMBER := 0;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT COUNT(*) FROM session_privs WHERE privilege = :p'
                INTO v_n USING v_privs(i);
            IF v_n > 0 THEN
                emit('PASS', v_privs(i), 'granted');
            ELSIF v_privs(i) = 'CREATE MINING MODEL' THEN
                emit('WARN', v_privs(i),
                     'missing -- Tier 2 ESM (ml/) will fail at train time; Tier 1 is fine');
            ELSIF v_privs(i) = 'CREATE JOB' THEN
                emit('WARN', v_privs(i), 'missing -- install_jobs.sql cannot create jobs');
            ELSIF v_privs(i) = 'CREATE DATABASE LINK' THEN
                emit('WARN', v_privs(i), 'missing -- cap_repo.add_target can only use links a DBA made');
            ELSE
                emit('FAIL', v_privs(i), 'missing -- install.sql cannot create its objects');
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                emit('WARN', v_privs(i), 'cannot read SESSION_PRIVS: ' || err);
        END;
    END LOOP;
    -- cap_forecast_ml is definer's rights: it creates models with the
    -- owner's DIRECT privileges, whoever installed it.
    IF v_schema <> 'SYS' THEN
        DECLARE
            v_g NUMBER := direct_sys_priv('CREATE MINING MODEL');
        BEGIN
            IF v_g IS NULL THEN
                emit('WARN', 'direct MINING MODEL', 'cannot read DBA_SYS_PRIVS for ' || v_schema);
            ELSIF v_g = 1 THEN
                emit('PASS', 'direct MINING MODEL', 'granted directly to ' || v_schema);
            ELSE
                emit('WARN', 'direct MINING MODEL', v_schema
                     || ' lacks a direct CREATE MINING MODEL; Tier 2 training will fail');
            END IF;
        END;
    END IF;

    -- cap_repo (repository mode) creates its DB links with the owner's
    -- DIRECT privileges too. Without it, register targets over links the
    -- DBA made (cap_repo.add_target p_db_link).
    IF v_check_mode = 'repository' AND v_schema <> 'SYS' THEN
        DECLARE
            v_g NUMBER := direct_sys_priv('CREATE DATABASE LINK');
        BEGIN
            IF v_g IS NULL THEN
                emit('WARN', 'direct DB LINK', 'cannot read DBA_SYS_PRIVS for ' || v_schema);
            ELSIF v_g = 1 THEN
                emit('PASS', 'direct DB LINK', 'granted directly to ' || v_schema);
            ELSE
                emit('WARN', 'direct DB LINK', v_schema || ' lacks a direct CREATE DATABASE'
                     || ' LINK; add_target can only use links a DBA made (p_db_link)');
            END IF;
        END;
    END IF;

    -- =================================================================
    -- 7. Readiness: days each feature needs vs days of history available
    -- =================================================================
    DECLARE
        v_avail NUMBER;
        v_e     VARCHAR2(200);

        PROCEDURE ready(p_label IN VARCHAR2, p_need IN NUMBER) IS
            v_st VARCHAR2(4);
        BEGIN
            v_st := CASE WHEN v_avail IS NULL THEN 'INFO' WHEN v_avail >= p_need THEN 'PASS' ELSE 'WARN' END;
            tally(v_st);
            DBMS_OUTPUT.PUT_LINE('  ' || RPAD(p_label, 48) || LPAD(TO_CHAR(p_need), 6)
                                 || LPAD(NVL(TO_CHAR(v_avail), '?'), 7) || '   ' || v_st);
        END ready;
    BEGIN
        IF v_installed THEN
            v_avail := count_days('SELECT MAX(n) FROM (SELECT COUNT(DISTINCT'
                                  || ' TRUNC(end_interval_time)) n FROM capv_snapshot'
                                  || ' GROUP BY dbid)', v_e);
        END IF;

        hdr(' 7. Readiness per feature (days of history; best dbid in CAPV_SNAPSHOT'
            || '; knobs from ' || v_knob_src || ')');
        DBMS_OUTPUT.PUT_LINE('  ' || RPAD('feature', 48) || LPAD('need', 6)
                             || LPAD('have', 7) || '   status');
        FOR i IN 1 .. v_needs.COUNT LOOP
            ready(v_needs(i).label, v_needs(i).days);
        END LOOP;
        IF NOT v_installed THEN
            note('Not installed here yet: the days are counted in CAPV_SNAPSHOT once the');
            note('copies are collected. On a target, target/check.sql shows its AWR history.');
        ELSIF v_avail IS NULL THEN
            note('No history could be counted (' || NVL(v_e, CASE WHEN v_check_mode = 'repository'
                 THEN 'nothing copied yet: EXEC cap_repo.collect' ELSE 'no snapshot rows' END) || ').');
        END IF;
    END;

    -- =================================================================
    -- 8. Installed-suite health (only meaningful once install.sql has run)
    -- =================================================================
    hdr(' 8. Suite install state (current schema: ' || v_schema || ')');
    IF NOT v_installed THEN
        emit('WARN', 'CAP_CONFIG', 'not present -- suite not installed here yet');
    ELSE
        emit('PASS', 'CAP_CONFIG', 'present');
        DECLARE
            v_ver NUMBER := knob_raw('suite_version');
        BEGIN
            IF v_ver IS NULL THEN
                emit('WARN', 'suite_version', 'not stamped (installed before M13?);'
                     || ' re-run install.sql');
            ELSE
                emit('PASS', 'suite_version', TO_CHAR(v_ver));
            END IF;
        END;

        -- Invalid CAP* objects. NOTE: USER_OBJECTS / USER_DEPENDENCIES follow the
        -- SESSION USER, not CURRENT_SCHEMA (verified on 19c: with SYS connected
        -- and CURRENT_SCHEMA=CAPTEST, USER_OBJECTS shows none of CAPTEST's
        -- objects). So filter ALL_* on owner = CURRENT_SCHEMA instead, which is
        -- where install.sql actually put things.
        DECLARE
            v_bad   PLS_INTEGER := 0;
            v_list  VARCHAR2(300);
        BEGIN
            FOR r IN (SELECT object_name, object_type
                      FROM   all_objects
                      WHERE  owner = v_schema
                        AND  status = 'INVALID'
                        AND  object_name LIKE 'CAP%'
                      ORDER BY object_name) LOOP
                v_bad  := v_bad + 1;
                v_list := SUBSTR(v_list || CASE WHEN v_list IS NULL THEN '' ELSE ', ' END
                                 || r.object_name || ' (' || r.object_type || ')', 1, 300);
            END LOOP;
            -- WARN, not FAIL: re-running install.sql recreates or recompiles
            -- them, so this must not stop the quickstart that would fix it.
            IF v_bad = 0 THEN
                emit('PASS', 'CAP* objects', 'all valid');
            ELSE
                emit('WARN', 'CAP* objects', v_bad || ' INVALID: ' || v_list);
                note('install.sql recompiles CAP* objects and stops if any stay invalid.');
            END IF;
        END;

        IF v_deploy_mode IS NULL AND v_seam_refs IS NULL THEN
            emit('WARN', 'deploy mode', 'CAPV_SNAPSHOT not found in this schema');
        ELSIF v_deploy_mode IS NULL THEN
            emit('WARN', 'deploy mode', 'unrecognised: ' || v_seam_refs);
        ELSIF v_deploy_mode = 'local' THEN
            emit('WARN', 'deploy mode', 'local (CAPV_SNAPSHOT -> ' || v_seam_refs || '), retired in M25');
            note('Move to a repository: @uninstall.sql here (it writes a config replay');
            note('file), install standalone into a PDB, then run the replay file there.');
        ELSE
            emit('PASS', 'deploy mode', v_deploy_mode || '  (CAPV_SNAPSHOT -> ' || v_seam_refs || ')');
        END IF;

        -- A green checklist means little if every fit is untrustworthy, so say
        -- how the fits actually came out.
        DECLARE
            PROCEDURE quality(p_view IN VARCHAR2, p_label IN VARCHAR2) IS
                v_ok   NUMBER;
                v_low  NUMBER;
                v_flat NUMBER;
                v_ins  NUMBER;
                v_tot  NUMBER;
                v_txt  VARCHAR2(200);
            BEGIN
                EXECUTE IMMEDIATE
                    'SELECT COUNT(CASE WHEN quality = ''OK'' THEN 1 END),'
                    || ' COUNT(CASE WHEN quality = ''LOW_CONFIDENCE'' THEN 1 END),'
                    || ' COUNT(CASE WHEN quality = ''FLAT'' THEN 1 END),'
                    || ' COUNT(CASE WHEN quality = ''INSUFFICIENT_HISTORY'' THEN 1 END),'
                    || ' COUNT(*) FROM ' || p_view
                    INTO v_ok, v_low, v_flat, v_ins, v_tot;
                v_txt := v_ok || ' OK, ' || v_flat || ' FLAT, ' || v_low
                         || ' LOW_CONFIDENCE, ' || v_ins || ' INSUFFICIENT_HISTORY';
                IF v_tot = 0 THEN
                    emit('WARN', p_label, 'no rows');
                ELSIF v_ok + v_flat = 0 THEN
                    emit('WARN', p_label, v_txt || ' -- no trustworthy fit yet');
                ELSE
                    emit('PASS', p_label, v_txt);
                END IF;
            EXCEPTION
                WHEN OTHERS THEN emit('WARN', p_label, 'cannot read: ' || err);
            END quality;
        BEGIN
            quality('capf_tbspc_forecast', 'tablespace fits');
            quality('capf_cpu_trend',      'CPU fits');
        END;
    END IF;

    -- =================================================================
    -- 9. Config sanity (installed only): the rules live in CAP_CFG_CHECK
    -- =================================================================
    IF v_installed THEN
        hdr(' 9. Config sanity (CAP_CFG_CHECK)');
        DECLARE
            v_cur  SYS_REFCURSOR;
            v_knob VARCHAR2(40);
            v_stat VARCHAR2(10);
            v_why  VARCHAR2(400);
            v_all  PLS_INTEGER := 0;
            v_bad  PLS_INTEGER := 0;
        BEGIN
            OPEN v_cur FOR 'SELECT knob, status, reason FROM cap_cfg_check ORDER BY knob';
            LOOP
                FETCH v_cur INTO v_knob, v_stat, v_why;
                EXIT WHEN v_cur%NOTFOUND;
                v_all := v_all + 1;
                IF v_stat <> 'OK' THEN
                    v_bad := v_bad + 1;
                    emit('WARN', v_knob, v_stat || ': ' || v_why);
                END IF;
            END LOOP;
            CLOSE v_cur;
            IF v_bad = 0 THEN
                emit('PASS', 'CAP_CFG_CHECK', 'all ' || v_all || ' knobs OK');
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                emit('WARN', 'CAP_CFG_CHECK', 'cannot read: ' || err || ' (re-run install.sql)');
        END;
    END IF;

    -- =================================================================
    -- 10. Results layer and seam coverage (installed only, ddl/60 + seam).
    -- Every probe is dynamic SQL in its own block: a missing view or grant
    -- prints a WARN line and the next probe runs.
    -- =================================================================
    IF v_installed THEN
        hdr('10. Results layer and seam coverage');
        DECLARE
            v_cur   SYS_REFCURSOR;
            v_id    NUMBER;
            v_st    VARCHAR2(16);
            v_day   VARCHAR2(10);
            v_age   NUMBER;
            v_stale VARCHAR2(1);
            v_txt   VARCHAR2(400);
            v_txt2  VARCHAR2(400);
            v_n     NUMBER;
            v_n2    NUMBER;
            v_n3    NUMBER;
            v_cdb   BOOLEAN := FALSE;
        BEGIN
            -- last refresh run
            BEGIN
                EXECUTE IMMEDIATE
                    'SELECT run_id, status, TO_CHAR(as_of_day, ''YYYY-MM-DD''),'
                    || ' ROUND((SYSDATE - CAST(NVL(ended_at, started_at) AS DATE)) * 24, 1), stale_run'
                    || ' FROM capr_runs WHERE is_last = ''Y'''
                    INTO v_id, v_st, v_day, v_age, v_stale;
                emit(CASE WHEN v_st = 'OK' AND v_stale = 'N' THEN 'PASS' ELSE 'WARN' END,
                     'last refresh run',
                     v_id || ' ' || v_st || ', as of ' || v_day || ', ' || v_age || ' h ago'
                     || CASE WHEN v_stale = 'Y' THEN ' -- stale_run: no OK live run within refresh_stale_hours' END);
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    emit('INFO', 'last refresh run', 'none yet: EXEC cap_results.refresh, or install_jobs.sql');
                WHEN OTHERS THEN
                    emit('WARN', 'last refresh run', 'cannot read CAPR_RUNS: ' || err);
            END;
            -- FAILED runs in the last 7 days, with the first line of the error
            BEGIN
                v_n := 0;
                OPEN v_cur FOR
                    'SELECT run_id, TO_CHAR(started_at, ''YYYY-MM-DD HH24:MI''),'
                    || ' SUBSTR(REGEXP_SUBSTR(error_text, ''[^'' || CHR(10) || '']+''), 1, 120)'
                    || ' FROM capr_runs WHERE status = ''FAILED'''
                    || ' AND started_at > SYSTIMESTAMP - INTERVAL ''7'' DAY ORDER BY run_id DESC';
                LOOP
                    FETCH v_cur INTO v_id, v_txt, v_txt2;
                    EXIT WHEN v_cur%NOTFOUND;
                    v_n := v_n + 1;
                    IF v_n <= 5 THEN
                        emit('WARN', 'FAILED refresh run', v_id || ' at ' || v_txt || ': ' || v_txt2);
                    END IF;
                END LOOP;
                CLOSE v_cur;
                IF v_n = 0 THEN
                    emit('PASS', 'FAILED refresh runs', 'none in the last 7 days');
                ELSIF v_n > 5 THEN
                    note((v_n - 5) || ' more FAILED run(s) in the last 7 days (CAPR_RUNS).');
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    IF v_cur%ISOPEN THEN CLOSE v_cur; END IF;
                    emit('WARN', 'FAILED refresh runs', 'cannot read CAPR_RUNS: ' || err);
            END;
            -- RUNNING runs older than one hour (a killed session leaves them)
            BEGIN
                EXECUTE IMMEDIATE
                    'SELECT COUNT(*), MIN(run_id) FROM capr_runs WHERE status = ''RUNNING'''
                    || ' AND started_at < SYSTIMESTAMP - INTERVAL ''1'' HOUR'
                    INTO v_n, v_id;
                IF v_n = 0 THEN
                    emit('PASS', 'stuck RUNNING runs', 'none older than 1 h');
                ELSE
                    emit('WARN', 'stuck RUNNING runs', v_n || ' older than 1 h, oldest run_id ' || v_id
                         || ' (a killed refresh; the next refresh is unaffected)');
                END IF;
            EXCEPTION
                WHEN OTHERS THEN emit('WARN', 'stuck RUNNING runs', 'cannot read CAPR_RUNS: ' || err);
            END;
            -- the jobs and their last scheduler run
            job_check('CAP_NIGHTLY_JOB', 'install_jobs.sql; until then nothing refreshes, retrains'
                                         || ' or purges unless you run cap_nightly');
            -- The steps the last nightly run failed (its OUTPUT, one line per step).
            BEGIN
                -- CONNECT BY always returns its first row, hence the outer filter.
                FOR r IN (SELECT line
                          FROM  (SELECT REGEXP_SUBSTR(output, '^[A-Z]+ +FAILED.*$', 1, LEVEL, 'm') AS line
                                 FROM  (SELECT output FROM (SELECT output FROM all_scheduler_job_run_details
                                                            WHERE  owner = v_schema
                                                              AND  job_name = 'CAP_NIGHTLY_JOB'
                                                            ORDER  BY log_date DESC)
                                        WHERE ROWNUM = 1)
                                 CONNECT BY LEVEL <= REGEXP_COUNT(output, '^[A-Z]+ +FAILED', 1, 'm'))
                          WHERE  line IS NOT NULL) LOOP
                    emit('WARN', 'nightly step', SUBSTR(r.line, 1, 160));
                END LOOP;
            EXCEPTION
                WHEN OTHERS THEN emit('INFO', 'nightly steps', 'cannot read the job run OUTPUT: ' || err);
            END;
            IF v_check_mode = 'repository' THEN
                job_check('CAP_COLLECT_JOB', 'install_jobs.sql; until then nothing is copied'
                                             || ' unless you EXEC cap_repo.collect');
            END IF;
            -- alert states: open, acknowledged
            BEGIN
                EXECUTE IMMEDIATE
                    'SELECT COUNT(CASE WHEN state = ''OPEN'' THEN 1 END),'
                    || ' COUNT(CASE WHEN state = ''OPEN'' AND ack_until > SYSDATE THEN 1 END),'
                    || ' COUNT(CASE WHEN state = ''RESOLVED'' THEN 1 END) FROM cap_alert_state'
                    INTO v_n, v_n2, v_n3;
                emit('INFO', 'alert states', v_n || ' OPEN (' || v_n2 || ' acknowledged, '
                     || (v_n - v_n2) || ' in CAPR_ALERTS_LATEST), ' || v_n3 || ' RESOLVED');
            EXCEPTION
                WHEN OTHERS THEN emit('WARN', 'alert states', 'cannot read CAP_ALERT_STATE: ' || err);
            END;
            -- retired dbids (no snapshot for data_stale_max_days)
            BEGIN
                v_n := 0; v_txt := NULL;
                OPEN v_cur FOR 'SELECT summary FROM capr_coverage WHERE retired = ''Y'' ORDER BY dbid';
                LOOP
                    FETCH v_cur INTO v_txt2;
                    EXIT WHEN v_cur%NOTFOUND;
                    v_n := v_n + 1;
                    IF v_n <= 3 THEN note('retired: ' || SUBSTR(v_txt2, 1, 150)); END IF;
                END LOOP;
                CLOSE v_cur;
                emit('INFO', 'retired dbids', v_n || ' (CAPR_COVERAGE.retired = Y: listed, never alerted)');
            EXCEPTION
                WHEN OTHERS THEN
                    IF v_cur%ISOPEN THEN CLOSE v_cur; END IF;
                    emit('WARN', 'retired dbids', 'cannot read CAPR_COVERAGE: ' || err);
            END;
            -- the live seam contract: a per-container source that shows one
            -- con_dbid on a CDB is missing its PDB series
            BEGIN
                EXECUTE IMMEDIATE 'SELECT COUNT(DISTINCT con_dbid) FROM capv_container' INTO v_n;
                v_cdb := v_n > 1;
                OPEN v_cur FOR
                    'SELECT source_name, n_rows, n_con_dbid, per_container_expected'
                    || ' FROM capv_contract ORDER BY source_name';
                LOOP
                    FETCH v_cur INTO v_txt, v_n, v_n2, v_st;
                    EXIT WHEN v_cur%NOTFOUND;
                    IF v_st = 'Y' AND v_cdb AND v_n > 0 AND v_n2 = 1 THEN
                        emit('WARN', 'seam ' || v_txt, v_n || ' rows, 1 con_dbid on a CDB:'
                             || ' per-container rows expected, the PDB series are missing');
                    ELSE
                        emit('INFO', 'seam ' || v_txt, v_n || ' rows, ' || v_n2 || ' con_dbid'
                             || CASE WHEN v_st = 'Y' THEN ' (per container)' END);
                    END IF;
                END LOOP;
                CLOSE v_cur;
            EXCEPTION
                WHEN OTHERS THEN
                    IF v_cur%ISOPEN THEN CLOSE v_cur; END IF;
                    emit('WARN', 'CAPV_CONTRACT', 'cannot read: ' || err);
            END;
        END;
    END IF;

    -- =================================================================
    -- 11. Repository targets (installed, repository mode): per target the
    -- link, the collect health and the days copied per DBID.
    -- =================================================================
    IF v_installed AND v_check_mode = 'repository' THEN
        hdr('11. Repository targets (CAPR_TARGETS; links probed by cap_repo.ping)');
        DECLARE
            c_max     CONSTANT PLS_INTEGER := 50;
            v_cur     SYS_REFCURSOR;
            v_name    VARCHAR2(30);
            v_dbid    NUMBER;
            v_link    VARCHAR2(128);
            v_on      VARCHAR2(1);
            v_age     NUMBER;
            v_stale   VARCHAR2(1);
            v_hwm     NUMBER;
            v_ok_at   DATE;
            v_err_at  DATE;
            v_err     VARCHAR2(4000);
            v_gaps    NUMBER;
            v_state   VARCHAR2(10);
            v_n_dbid  NUMBER;
            v_prev    VARCHAR2(30);
            v_tag     VARCHAR2(60);
            v_ping    VARCHAR2(4000);
            v_days    NUMBER;
            v_pga     NUMBER;
            v_opt     t_names;
            v_miss    VARCHAR2(1000);
            v_short   VARCHAR2(1000);
            v_targets PLS_INTEGER := 0;
            v_stale_h NUMBER := knob('stale_hours', 36);
            v_warn_d  NUMBER := knob('reader_expiry_warn_days', 30);

            FUNCTION line1(p_txt IN VARCHAR2) RETURN VARCHAR2 IS
            BEGIN
                RETURN SUBSTR(REGEXP_SUBSTR(p_txt, '[^' || CHR(10) || ']+'), 1, 120);
            END line1;

            PROCEDURE expiry(p_name IN VARCHAR2) IS
                v_exp   DATE;
                v_user  VARCHAR2(128);
                v_owned VARCHAR2(1);
            BEGIN
                EXECUTE IMMEDIATE 'BEGIN :r := cap_repo.reader_expiry(:n); END;'
                    USING OUT v_exp, IN p_name;
                IF v_exp IS NULL THEN
                    emit('PASS', 'reader ' || p_name, 'password never expires');
                ELSIF v_exp - SYSDATE > v_warn_d THEN
                    emit('PASS', 'reader ' || p_name, 'password expires ' || TO_CHAR(v_exp, 'YYYY-MM-DD')
                         || ' (in ' || ROUND(v_exp - SYSDATE) || ' d)');
                ELSE
                    EXECUTE IMMEDIATE 'SELECT link_user, link_owned FROM cap_target WHERE target_name = :n'
                        INTO v_user, v_owned USING p_name;
                    emit('WARN', 'reader ' || p_name, 'password expires ' || TO_CHAR(v_exp, 'YYYY-MM-DD HH24:MI')
                         || CASE WHEN v_exp <= SYSDATE THEN ' (already: grace period)'
                                 ELSE ' (in ' || ROUND(v_exp - SYSDATE) || ' d)' END
                         || ', inside reader_expiry_warn_days ' || v_warn_d
                         || ': its collects fail with ORA-28001 from then on');
                    note('Rotate it. On the target: ALTER USER ' || NVL(v_user, '<reader>')
                         || ' IDENTIFIED BY "<new>";');
                    IF v_owned = 'Y' THEN
                        note('Then here: EXEC cap_repo.set_link_password(''' || p_name || ''', ''<new>'')');
                    ELSE
                        note('Then recreate the link the DBA made for ' || p_name || ' with the new password.');
                    END IF;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN emit('WARN', 'reader ' || p_name, 'cannot read its expiry: ' || err);
            END expiry;
        BEGIN
            OPEN v_cur FOR
                'SELECT target_name, dbid, db_link, enabled, age_hours, is_stale,'
                || ' collected_snap_id, last_ok_at, last_error_at, last_error, n_gaps,'
                || ' collect_state, COUNT(*) OVER (PARTITION BY target_name)'
                || ' FROM capr_targets ORDER BY target_name, dbid';
            LOOP
                FETCH v_cur INTO v_name, v_dbid, v_link, v_on, v_age, v_stale, v_hwm,
                                 v_ok_at, v_err_at, v_err, v_gaps, v_state, v_n_dbid;
                EXIT WHEN v_cur%NOTFOUND;
                IF v_prev IS NULL OR v_name <> v_prev THEN
                    v_prev    := v_name;
                    v_targets := v_targets + 1;
                    IF v_targets <= c_max AND v_on = 'N' THEN
                        emit('INFO', 'target ' || v_name, 'disabled (cap_repo.set_enabled); not checked');
                    ELSIF v_targets <= c_max THEN
                        BEGIN
                            EXECUTE IMMEDIATE 'BEGIN :r := cap_repo.ping(:n); END;'
                                USING OUT v_ping, IN v_name;
                            IF v_ping IS NULL THEN
                                emit('PASS', 'link ' || v_name, v_link || ' answers; every required copied view readable');
                                expiry(v_name);
                            ELSE
                                emit('WARN', 'link ' || v_name, v_link || ': ' || line1(v_ping));
                            END IF;
                        EXCEPTION
                            WHEN OTHERS THEN emit('WARN', 'link ' || v_name, 'cannot run cap_repo.ping: ' || err);
                        END;
                    END IF;
                END IF;
                CONTINUE WHEN v_targets > c_max OR v_on = 'N';
                IF v_dbid IS NULL THEN
                    emit('WARN', 'target ' || v_name, 'no DBID found yet: is AWR taking snapshots on the target?');
                    CONTINUE;
                END IF;
                v_tag := v_name || CASE WHEN v_n_dbid > 1 THEN ' ' || v_dbid END;

                IF v_state = 'OK' THEN
                    emit('PASS', 'collect ' || v_tag, 'OK, newest copy '
                         || NVL(TO_CHAR(v_age, 'FM9999990.0'), '?') || ' h old, hwm ' || v_hwm
                         || ', last OK ' || TO_CHAR(v_ok_at, 'YYYY-MM-DD HH24:MI'));
                ELSIF v_state = 'FAILING' THEN
                    emit('WARN', 'collect ' || v_tag, 'FAILING, last error at '
                         || TO_CHAR(v_err_at, 'YYYY-MM-DD HH24:MI') || ': ' || line1(v_err));
                ELSIF v_state = 'NEVER' THEN
                    emit('WARN', 'collect ' || v_tag, 'never collected: EXEC cap_repo.collect('''
                         || v_name || ''')');
                ELSE
                    emit('INFO', 'collect ' || v_tag, 'collect_state ' || NVL(v_state, 'NULL'));
                END IF;
                IF v_stale = 'Y' THEN
                    emit('WARN', 'collect ' || v_tag, 'newest copy ' || TO_CHAR(v_age, 'FM9999990.0')
                         || ' h old (stale_hours ' || v_stale_h || ')');
                END IF;
                IF v_gaps > 0 THEN
                    emit('WARN', 'collect ' || v_tag, v_gaps || ' gap(s): snapshots the target purged'
                         || ' before they were copied; collect more often or raise its AWR retention');
                END IF;

                -- M26: collect skips an optional source (the memory history)
                -- the reader cannot read, e.g. one prepared before the source
                -- joined the copy list. An advisor switched off on the target
                -- leaves its copy empty too, hence the wording.
                BEGIN
                    EXECUTE IMMEDIATE 'SELECT copy_table FROM cap_repo_source'
                                      || ' WHERE optional = ''Y'' AND kind <> ''L'' ORDER BY seq'
                        BULK COLLECT INTO v_opt;
                    v_miss := NULL;
                    FOR i IN 1 .. v_opt.COUNT LOOP
                        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || v_opt(i)
                                          || ' WHERE dbid = :d AND ROWNUM = 1'
                            INTO v_pga USING v_dbid;
                        IF v_pga = 0 THEN
                            v_miss := v_miss || CASE WHEN v_miss IS NOT NULL THEN ', ' END || v_opt(i);
                        END IF;
                    END LOOP;
                    IF v_hwm > 0 AND v_miss IS NOT NULL THEN
                        emit('WARN', 'memory ' || v_tag, 'memory history not collected or not populated'
                             || ' on the target (no rows in ' || v_miss || '): if its reader lacks'
                             || ' the grants, re-run target/prepare.sql there');
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN emit('WARN', 'memory ' || v_tag, 'cannot read the memory copies: ' || err);
                END;

                -- U09: the live tablespace ceilings (kind L) are copied for
                -- the newest DBID of a target only, so the target is asked.
                BEGIN
                    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM cap_h_tbspc_live l WHERE l.dbid IN'
                                      || ' (SELECT d.dbid FROM cap_target_dbid d WHERE d.target_id ='
                                      || ' (SELECT x.target_id FROM cap_target_dbid x WHERE x.dbid = :d))'
                                      || ' AND ROWNUM = 1'
                        INTO v_pga USING v_dbid;
                    IF v_hwm > 0 AND v_pga = 0 THEN
                        emit('WARN', 'disk ' || v_tag, 'no live tablespace ceilings copied (CAP_H_TBSPC_LIVE):'
                             || ' the shared-disk forecast knows no free space unless CAP_DISK_OVERRIDE sets it.'
                             || ' If the reader lacks the grant, re-run target/prepare.sql there');
                    END IF;
                EXCEPTION
                    -- ORA-00942: an install from before the live source, about
                    -- to be upgraded. Nothing to say yet.
                    WHEN OTHERS THEN
                        IF SQLCODE <> -942 THEN
                            emit('WARN', 'disk ' || v_tag, 'cannot read CAP_H_TBSPC_LIVE: ' || err);
                        END IF;
                END;

                BEGIN
                    EXECUTE IMMEDIATE 'SELECT COUNT(DISTINCT TRUNC(end_interval_time))'
                                      || ' FROM capv_snapshot WHERE dbid = :d'
                        INTO v_days USING v_dbid;
                    v_short := NULL;
                    FOR i IN 1 .. v_needs.COUNT LOOP
                        IF v_days < v_needs(i).days THEN
                            v_short := v_short || CASE WHEN v_short IS NOT NULL THEN ', ' END
                                       || SUBSTR(v_needs(i).label, 1, INSTR(v_needs(i).label, ' (') - 1)
                                       || ' (' || v_needs(i).days || ')';
                        END IF;
                    END LOOP;
                    IF v_short IS NULL THEN
                        emit('PASS', 'history ' || v_tag, v_days || ' days: every feature ready');
                    ELSE
                        emit('INFO', 'history ' || v_tag, v_days || ' days; not yet: ' || v_short);
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN emit('WARN', 'history ' || v_tag, 'cannot read CAPV_SNAPSHOT: ' || err);
                END;
            END LOOP;
            CLOSE v_cur;
            IF v_targets = 0 THEN
                emit('WARN', 'targets', 'none registered: EXEC cap_repo.add_target');
            ELSIF v_targets > c_max THEN
                note((v_targets - c_max) || ' more target(s) not checked here (CAPR_TARGETS).');
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                IF v_cur%ISOPEN THEN CLOSE v_cur; END IF;
                emit('WARN', 'CAPR_TARGETS', 'cannot read: ' || err);
        END;
    END IF;

    -- =================================================================
    -- 12. Alert volume (installed only): what the knobs raise now, per
    -- kind, and for each noisy anomaly series the two ways to quiet it.
    -- One live read of CAPR_ALERT_VOLUME, so it needs no refresh run. Its
    -- verdict is a WARN at most: a noisy series is tuning, not a fault.
    -- =================================================================
    IF v_installed THEN
        hdr('12. Alert volume (CAPR_ALERT_VOLUME, evaluated now)');
        DECLARE
            c_max    CONSTANT PLS_INTEGER := 20;
            TYPE t_cnt IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(30);
            TYPE t_num IS TABLE OF NUMBER INDEX BY VARCHAR2(30);
            v_alerts t_cnt;
            v_series t_cnt;
            v_noisy  t_cnt;
            v_floor  t_num;      -- per floor knob: the largest suggestion
            v_shared t_cnt;      -- per floor knob: its noisy series
            v_cur    SYS_REFCURSOR;
            v_db     VARCHAR2(512);
            v_kind   VARCHAR2(30);
            v_ser    VARCHAR2(256);
            v_mode   VARCHAR2(12);
            v_ep     NUMBER;
            v_crit   NUMBER;
            v_wrn    NUMBER;
            v_inf    NUMBER;
            v_scored NUMBER;
            v_flag   NUMBER;
            v_pct    NUMBER;
            v_dev    NUMBER;
            v_fknob  VARCHAR2(30);
            v_fval   NUMBER;
            v_sugg   NUMBER;
            v_mknob  VARCHAR2(30);
            v_bit    NUMBER;
            v_is     VARCHAR2(1);
            v_mval   NUMBER;
            v_rows   PLS_INTEGER := 0;
            v_n      PLS_INTEGER := 0;
            v_k      VARCHAR2(30);
            -- The noisy series' lines, printed after the per-kind table.
            TYPE t_lines IS TABLE OF VARCHAR2(400);
            v_lines  t_lines := t_lines();

            PROCEDURE keep(p_text IN VARCHAR2) IS
            BEGIN
                v_lines.EXTEND;
                v_lines(v_lines.LAST) := SUBSTR(p_text, 1, 400);
            END keep;

            PROCEDURE kept(p_text IN VARCHAR2) IS
            BEGIN
                keep('         ' || p_text);
            END kept;

            FUNCTION num(p IN NUMBER) RETURN VARCHAR2 IS
            BEGIN
                RETURN RTRIM(TO_CHAR(p, 'FM999999999999999990.999999'), '.');
            END num;
        BEGIN
            OPEN v_cur FOR
                'SELECT db_pdb, kind, series_key, baseline_mode, episodes, n_crit, n_warn, n_info,'
                || ' scored_days, flagged_days, flagged_pct, max_dev, floor_knob, floor_value,'
                || ' suggested_floor, mode_knob, mode_bit, noisy'
                || ' FROM capr_alert_volume'
                || ' ORDER BY noisy DESC, episodes DESC, flagged_pct DESC NULLS LAST,'
                || ' kind, db_pdb, series_key, baseline_mode';
            LOOP
                FETCH v_cur INTO v_db, v_kind, v_ser, v_mode, v_ep, v_crit, v_wrn, v_inf,
                                 v_scored, v_flag, v_pct, v_dev, v_fknob, v_fval,
                                 v_sugg, v_mknob, v_bit, v_is;
                EXIT WHEN v_cur%NOTFOUND;
                v_rows := v_rows + 1;
                IF NOT v_alerts.EXISTS(v_kind) THEN
                    v_alerts(v_kind) := 0; v_series(v_kind) := 0; v_noisy(v_kind) := 0;
                END IF;
                v_alerts(v_kind) := v_alerts(v_kind) + v_ep;
                v_series(v_kind) := v_series(v_kind) + 1;
                CONTINUE WHEN v_is <> 'Y';
                v_noisy(v_kind) := v_noisy(v_kind) + 1;
                v_n := v_n + 1;
                IF v_fknob IS NOT NULL THEN
                    IF NOT v_floor.EXISTS(v_fknob) THEN
                        v_floor(v_fknob) := v_sugg; v_shared(v_fknob) := 0;
                    END IF;
                    v_floor(v_fknob)  := GREATEST(v_floor(v_fknob), v_sugg);
                    v_shared(v_fknob) := v_shared(v_fknob) + 1;
                END IF;
                CONTINUE WHEN v_n > c_max;
                keep('  noisy: ' || v_kind || ' ' || v_ser || ' on ' || v_db || ', ' || v_mode);
                kept(v_ep || ' episode(s) (' || v_crit || ' CRIT, ' || v_wrn || ' WARN, ' || v_inf || ' INFO), '
                     || v_flag || ' of ' || v_scored || ' scored days flagged ('
                     || TO_CHAR(v_pct, 'FM990.0') || '%)');
                IF v_fknob IS NOT NULL THEN
                    kept('largest deviation ' || num(ROUND(v_dev, 4)) || ' against the floor '
                         || v_fknob || ' = ' || num(v_fval)
                         || CASE WHEN v_fknob LIKE 'cpu_min_mad_pct%' THEN ' (both in sigma points: x mad_k = percent)'
                                 WHEN v_fknob = 'abs_floor_bytes'
                                 THEN ' (bytes a day; ' || num(ROUND(v_sugg / 1048576)) || ' MiB suggested)' END);
                    kept('a) raise that floor, for every series of its unit:');
                    kept('     UPDATE cap_config SET cfg_value = ' || num(v_sugg)
                         || ' WHERE cfg_name = ''' || v_fknob || ''';');
                END IF;
                v_mval := knob_raw(v_mknob);
                kept(CASE WHEN v_fknob IS NOT NULL THEN 'b) or ' ELSE 'a) ' END
                     || 'stop ' || v_mode || ' alerts for the whole family (clear bit '
                     || v_bit || ' of ' || v_mknob || '):');
                kept('     UPDATE cap_config SET cfg_value = '
                     || NVL(num(v_mval - BITAND(v_mval, v_bit)), 'cfg_value - ' || v_bit)
                     || ' WHERE cfg_name = ''' || v_mknob || ''';');
            END LOOP;
            CLOSE v_cur;

            IF v_rows > 0 THEN
                DBMS_OUTPUT.PUT_LINE('  ' || RPAD('KIND', 18) || LPAD('ALERTS', 8) || LPAD('SERIES', 8)
                                     || LPAD('NOISY', 7));
                v_k := v_alerts.FIRST;
                WHILE v_k IS NOT NULL LOOP
                    DBMS_OUTPUT.PUT_LINE('  ' || RPAD(v_k, 18) || LPAD(v_alerts(v_k), 8)
                                         || LPAD(v_series(v_k), 8) || LPAD(v_noisy(v_k), 7));
                    v_k := v_alerts.NEXT(v_k);
                END LOOP;
            END IF;
            IF v_n > 0 THEN
                DBMS_OUTPUT.PUT_LINE(' ');
                FOR i IN 1 .. v_lines.COUNT LOOP
                    DBMS_OUTPUT.PUT_LINE(v_lines(i));
                END LOOP;
                IF v_n > c_max THEN
                    note((v_n - c_max) || ' more noisy series not listed (CAPR_ALERT_VOLUME, noisy = Y).');
                END IF;
                v_k := v_floor.FIRST;
                WHILE v_k IS NOT NULL LOOP
                    IF v_shared(v_k) > 1 THEN
                        note('One value quiets all ' || v_shared(v_k) || ' noisy series of ' || v_k
                             || ': ' || num(v_floor(v_k)) || '.');
                    END IF;
                    IF v_k = 'abs_floor_bytes' THEN
                        note('abs_floor_bytes is also the floor of the shrink-cliff rule (shrink_mad_k).');
                    ELSIF v_k = 'cpu_min_mad_pct' THEN
                        note('cpu_min_mad_pct is also the day threshold of the CPU level shift.');
                    END IF;
                    v_k := v_floor.NEXT(v_k);
                END LOOP;
                note('COMMIT after an UPDATE. Reports show the change at once, the stored alerts');
                note('at the next cap_results.refresh. Undo: SET cfg_value = cfg_default.');
                DBMS_OUTPUT.PUT_LINE(' ');
            END IF;
            IF v_n = 0 THEN
                emit('PASS', 'alert volume', 'OK: ' || v_rows || ' alerting series, none noisy'
                     || ' (noise_episodes ' || num(knob_raw('noise_episodes'))
                     || ', noise_flag_pct ' || num(knob_raw('noise_flag_pct')) || ')');
            ELSE
                emit('WARN', 'alert volume', v_n || ' noisy series of ' || v_rows || ' alerting'
                     || ' (noise_episodes ' || num(knob_raw('noise_episodes'))
                     || ', noise_flag_pct ' || num(knob_raw('noise_flag_pct'))
                     || '): tuning advice above, not a fault');
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                IF v_cur%ISOPEN THEN CLOSE v_cur; END IF;
                -- An install older than the view: the upgrade's own preflight.
                IF SQLCODE = -942 THEN
                    emit('INFO', 'alert volume', 'CAPR_ALERT_VOLUME is not installed here yet: install.sql creates it');
                ELSE
                    emit('WARN', 'alert volume', 'cannot read CAPR_ALERT_VOLUME: ' || err || ' (re-run install.sql)');
                END IF;
        END;
    END IF;

    -- =================================================================
    -- Summary
    -- =================================================================
    hdr(' Summary');
    DBMS_OUTPUT.PUT_LINE('  ' || n_pass || ' PASS / ' || n_warn || ' WARN / '
                         || n_fail || ' FAIL');

    IF v_check_mode = 'repository' AND NOT v_installed THEN
        note('Not installed here yet. Next: install.sql (deploy_mode = repository), then');
        note('cap_repo.add_target and cap_repo.collect. Check each target: @target/check.sql.');
    ELSIF v_check_mode = 'repository' THEN
        note('The data comes from the CAP_H_* copies (cap_repo.collect); check 11 covers');
        note('what feeds them. Check each target where it runs: @target/check.sql.');
    ELSIF v_check_mode = 'fixture' THEN
        note('The data comes from the CAP_FIXTURE_* tables (test/fixture_install.sql).');
    END IF;
    IF n_fail = 0 AND n_warn = 0 THEN
        note('All green -- install.sql should produce usable forecasts.');
    ELSIF n_fail > 0 THEN
        note(n_fail || ' FAIL line(s): fix those before installing (quickstart.sql stops).');
    END IF;
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 74, '='));

    :cap_doctor_fail_n := n_fail;
END;
/

-- Hand the FAIL count to the caller as a substitution variable. NULL means
-- the block above did not finish, which counts as a failure.
SET TERMOUT OFF
COLUMN cap_doctor_fail NEW_VALUE cap_doctor_fail NOPRINT
SELECT TO_CHAR(NVL(:cap_doctor_fail_n, 1)) AS cap_doctor_fail FROM dual;
COLUMN cap_doctor_fail CLEAR
SET TERMOUT ON

SET FEEDBACK ON
