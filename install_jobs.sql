--
-- install_jobs.sql -- OPT-IN DBMS_SCHEDULER automation for the suite.
-- =====================================================================
-- NOT part of install.sql. Run it separately, in the schema that owns the
-- suite, only if you want the background jobs below (CAP_COLLECT_JOB only in
-- repository mode, where package CAP_REPO exists):
--
--   CAP_NIGHTLY_JOB   daily (01:00) cap_nightly -- the night's work, one step
--                     after the other in one session (M24.12), so no step
--                     starts while another runs, whatever the fleet size:
--                       PURGE    cap_repo.purge (repository mode): delete the
--                                copies older than repo_retention_days
--                       RETRAIN  cap_forecast_ml.train_all: the Tier 2 OML
--                                ESM models against the latest AWR days.
--                                Needs CREATE MINING MODEL. Nightly because
--                                CAPF_COMPARE drops a model older than
--                                esm_max_age_days (7)
--                       REFRESH  cap_results.refresh: snapshot CAPR_FIT and
--                                CAPR_ALERTS into the results tables, so
--                                pollers get NEW / RESOLVED events and the
--                                SNAPSHOT reports and CAPR_ALERTS_LATEST read
--                                tonight's run, with tonight's models
--                       SPOOL    cap_report_spool(<dir>): the alert snapshot
--                                file (below)
--                     The schedule is the nightly_interval DEFINE; the
--                     steps, in that order, the nightly_steps DEFINE (default
--                     all four, PURGE only in repository mode, SPOOL only
--                     when the directory object exists). A failed step does
--                     not stop the later ones: the run ends FAILED
--                     (ORA-20080) naming each failed step, every step's
--                     outcome and seconds are in the run's OUTPUT
--                     (ALL_SCHEDULER_JOB_RUN_DETAILS), and the step's own
--                     record says why (CAP_RUN, CAPF_ESM_HEALTH.last_error,
--                     CAP_COLLECT_LOG).
--   CAP_COLLECT_JOB   hourly (:05) cap_repo.collect -- copy every enabled
--                     target's new snapshots into CAP_H_*. The schedule is
--                     the collect_interval DEFINE. A run ends FAILED
--                     (ORA-20070) when any target failed; the reason is in
--                     CAP_COLLECT_LOG and CAPR_TARGETS. It runs beside the
--                     nightly job: it only inserts above the high-water
--                     mark, which no nightly step reads past.
--
-- The night is one job, not one per step at fixed times: on a fleet the
-- refresh alone grows by about 70 s per target (2 vCPUs), so past about 25
-- targets a 01:30 refresh still ran when the 02:00 retrain started and both
-- needed a session's PGA at once (docs/reference.html#fleet-size). Scheduler
-- job incompatibilities keep jobs apart but not in order (verified 19.27);
-- a chain needs Rules Engine privileges. Re-running this script on an older
-- install drops the jobs this one replaced (CAP_REFRESH_JOB, CAP_ML_RETRAIN,
-- CAP_REPORT_SPOOL_JOB, CAP_PURGE_JOB).
--
-- Session labels. The procedure a job calls sets MODULE 'AWRCAP/<procedure>'
-- and ACTION its step. Each job_action first sets CLIENT_IDENTIFIER to the
-- job name (the scheduler resets it between runs, verified 19c). So
-- V$SESSION and ASH (CLIENT_ID) show which job is running what, and
-- DBMS_MONITOR.CLIENT_ID_TRACE_ENABLE('CAP_NIGHTLY_JOB') traces that job.
--
-- Why the "_JOB" suffix: DBMS_SCHEDULER jobs live in the SAME schema
-- namespace as procedures, so a job called CAP_NIGHTLY beside a procedure of
-- that name fails with ORA-27477 "already exists" (verified on 19c with
-- CAP_REPORT_SPOOL). The procedure keeps the plain name -- it is the thing
-- you call by hand -- and the job takes the suffix.
--
-- ALL JOBS ARE CREATED DISABLED. Nothing runs until you enable them (the
-- closing PROMPT block shows how). Re-running this script is idempotent: it
-- drops the jobs if they exist, then recreates them, again disabled.
--
-- Why the spool job is not "the report": SQL*Plus spooling cannot happen
-- inside a scheduler PL/SQL job -- there is no SQL*Plus there. So the job
-- writes a POLLABLE SNAPSHOT, not the full report: a header (timestamp,
-- database, data freshness, last refresh run, CRIT/WARN/INFO counts) plus
-- one pipe-delimited line per alert. For the full formatted report keep using
-- `sqlplus ... @report/report.sql` from cron / the OS scheduler.
--
-- Usage:
--   sqlplus / as sysdba
--   SQL> DEFINE report_dir = 'MY_DIR'    -- optional; default CAP_REPORTS
--   SQL> DEFINE nightly_interval = 'FREQ=DAILY;BYHOUR=22'
--                                        -- optional; default daily 01:00
--   SQL> DEFINE nightly_steps = 'REFRESH SPOOL'
--                                        -- optional; default above
--   SQL> DEFINE collect_interval = 'FREQ=MINUTELY;INTERVAL=30'
--                                        -- optional; default hourly at :05
--   SQL> @install_jobs.sql
--
-- The directory object is NOT created here (that needs CREATE ANY DIRECTORY
-- and a path decision only you can make). The script checks ALL_DIRECTORIES
-- and prints the exact DDL if it is missing.
--
-- Read-only against AWR, as ever: the jobs only read the CAP views and write
-- to CAP_ML_MODEL, the results tables and the OS file. In repository mode
-- the collect job SELECTs over each target's link and writes the CAP_H_*
-- copies, CAP_TARGET_DBID and CAP_COLLECT_LOG; the PURGE step deletes old
-- copies and log rows.
--
-- Remove everything with @uninstall_jobs.sql.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/install_jobs.sql"
SET DEFINE '&'
SET VERIFY   OFF
SET FEEDBACK OFF
SET TAB      OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR CONTINUE

-- --------------------------------------------------------------------
-- Default report_dir when the caller did not DEFINE it. First SELECT
-- returns no rows, which DEFINEs the variable as empty without prompting;
-- the second applies the default. (Same COLUMN ... NEW_VALUE trick the
-- report driver uses for unset positional args.)
-- --------------------------------------------------------------------
SET TERMOUT OFF
COLUMN report_dir NEW_VALUE report_dir NOPRINT
SELECT CAST(NULL AS VARCHAR2(30)) AS report_dir FROM dual WHERE 1 = 0;
SELECT UPPER(NVL('&report_dir', 'CAP_REPORTS')) AS report_dir FROM dual;
COLUMN nightly_interval NEW_VALUE nightly_interval NOPRINT
SELECT CAST(NULL AS VARCHAR2(200)) AS nightly_interval FROM dual WHERE 1 = 0;
SELECT NVL('&nightly_interval', 'FREQ=DAILY;BYHOUR=1;BYMINUTE=0;BYSECOND=0') AS nightly_interval FROM dual;
COLUMN collect_interval NEW_VALUE collect_interval NOPRINT
SELECT CAST(NULL AS VARCHAR2(200)) AS collect_interval FROM dual WHERE 1 = 0;
SELECT NVL('&collect_interval', 'FREQ=HOURLY;BYMINUTE=5;BYSECOND=0') AS collect_interval FROM dual;
-- Repository mode = package CAP_REPO in the target schema (ALL_OBJECTS on
-- CURRENT_SCHEMA: USER_OBJECTS follows the session user).
COLUMN repo_mode NEW_VALUE repo_mode NOPRINT
SELECT CASE WHEN COUNT(*) > 0 THEN 'Y' ELSE 'N' END AS repo_mode
FROM   all_objects
WHERE  owner       = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
  AND  object_name = 'CAP_REPO'
  AND  object_type = 'PACKAGE';
-- Default steps: PURGE where there are copies, SPOOL where its directory
-- object is.
COLUMN nightly_steps NEW_VALUE nightly_steps NOPRINT
SELECT CAST(NULL AS VARCHAR2(200)) AS nightly_steps FROM dual WHERE 1 = 0;
SELECT UPPER(NVL(TRIM('&nightly_steps'),
           TRIM(CASE WHEN '&repo_mode' = 'Y' THEN 'PURGE ' END || 'RETRAIN REFRESH'
                || CASE WHEN EXISTS (SELECT 1 FROM all_directories
                                     WHERE  directory_name = '&report_dir')
                        THEN ' SPOOL' END))) AS nightly_steps
FROM   dual;
SET TERMOUT ON

PROMPT
PROMPT ============================================================
PROMPT  AWR Capacity Forecast -- scheduler jobs (opt-in)
PROMPT ============================================================
PROMPT  report_dir = &report_dir  (directory object for the alert snapshot)
PROMPT  nightly    = &nightly_interval  (CAP_NIGHTLY_JOB schedule)
PROMPT  steps      = &nightly_steps  (in this order)
PROMPT  collect    = &collect_interval  (CAP_COLLECT_JOB schedule, repository mode)
PROMPT

-- --------------------------------------------------------------------
-- Directory object check. Warn + instruct; never create it here.
-- --------------------------------------------------------------------
DECLARE
    v_n    PLS_INTEGER := 0;
    v_path VARCHAR2(4000);
BEGIN
    BEGIN
        SELECT COUNT(*), MAX(directory_path)
        INTO   v_n, v_path
        FROM   all_directories
        WHERE  directory_name = '&report_dir';
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('  [WARN] cannot read ALL_DIRECTORIES: ' || SQLERRM);
            v_n := -1;
    END;

    IF v_n = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  [WARN] directory object &report_dir does not exist.');
        DBMS_OUTPUT.PUT_LINE('         CAP_REPORT_SPOOL fails with ORA-29280, and the nightly'
                             || ' job leaves out its SPOOL step, until you create it:');
        DBMS_OUTPUT.PUT_LINE('           CREATE OR REPLACE DIRECTORY &report_dir AS'
                             || ' ''/path/on/the/db/server'';');
        DBMS_OUTPUT.PUT_LINE('           GRANT READ, WRITE ON DIRECTORY &report_dir TO '
                             || SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') || ';');
    ELSIF v_n > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  [ OK ] directory &report_dir -> ' || v_path);
    END IF;
END;
/

PROMPT -- creating procedure cap_report_spool ...

CREATE OR REPLACE PROCEDURE cap_report_spool (p_dir IN VARCHAR2 DEFAULT 'CAP_REPORTS')
AUTHID DEFINER
AS
    -- Pollable alert snapshot, written to <p_dir>/cap_alerts.txt (overwritten
    -- on every run, so a poller can just read the one stable file name).
    -- NOT the full capacity report -- that needs SQL*Plus formatting; this is
    -- one line per alert plus a header.
    -- Format: SEVERITY|KIND|DB_PDB|SERIES_KEY|DAY|VALUE|THRESHOLD|UNIT|MESSAGE
    -- The header names what is measured (the targets of CAPR_TARGETS) and
    -- where the suite runs, says how fresh the data is (one "data through"
    -- line per target and dbid, with its collect state when that is not OK)
    -- and which refresh run the list comes from.
    -- With an OK live refresh run on record the alerts are the OPEN, not
    -- acked states of CAPR_ALERTS_LATEST (the last run's view; acked ones
    -- are left out) and the run's events follow as '#event|' lines; with
    -- none they are CAPR_ALERTS, evaluated now. DATA_STALE rows come first:
    -- a stalled AWR would otherwise read as a quiet system.
    c_file  CONSTANT VARCHAR2(30) := 'cap_alerts.txt';
    l_f     UTL_FILE.FILE_TYPE;
    l_crit  PLS_INTEGER := 0;
    l_warn  PLS_INTEGER := 0;
    l_info  PLS_INTEGER := 0;
    l_tot   PLS_INTEGER := 0;
    l_run   NUMBER;
    l_targets VARCHAR2(4000);
    l_mod   VARCHAR2(64);
    l_act   VARCHAR2(64);

    PROCEDURE alert_line(p_sev VARCHAR2, p_kind VARCHAR2, p_db VARCHAR2, p_key VARCHAR2,
                         p_day DATE, p_val NUMBER, p_thr NUMBER, p_unit VARCHAR2, p_msg VARCHAR2) IS
    BEGIN
        UTL_FILE.PUT_LINE(l_f,
            p_sev                                   || '|' ||
            p_kind                                  || '|' ||
            NVL(p_db, '-')                          || '|' ||
            NVL(p_key, '-')                         || '|' ||
            NVL(TO_CHAR(p_day, 'YYYY-MM-DD'), '-')  || '|' ||
            NVL(TO_CHAR(ROUND(p_val, 2)), '-')      || '|' ||
            NVL(TO_CHAR(ROUND(p_thr, 2)), '-')      || '|' ||
            NVL(p_unit, '-')                        || '|' ||
            NVL(p_msg, '-'));
    END alert_line;
BEGIN
    DBMS_APPLICATION_INFO.READ_MODULE(l_mod, l_act);
    DBMS_APPLICATION_INFO.SET_MODULE('AWRCAP/cap_report_spool', 'count alerts');
    SELECT MAX(run_id) INTO l_run FROM cap_run WHERE status = 'OK' AND backdated = 'N';
    IF l_run IS NOT NULL THEN
        SELECT COUNT(CASE WHEN severity = 'CRIT' THEN 1 END),
               COUNT(CASE WHEN severity = 'WARN' THEN 1 END),
               COUNT(CASE WHEN severity = 'INFO' THEN 1 END),
               COUNT(*)
        INTO   l_crit, l_warn, l_info, l_tot
        FROM   capr_alerts_latest;
    ELSE
        SELECT COUNT(CASE WHEN severity = 'CRIT' THEN 1 END),
               COUNT(CASE WHEN severity = 'WARN' THEN 1 END),
               COUNT(CASE WHEN severity = 'INFO' THEN 1 END),
               COUNT(*)
        INTO   l_crit, l_warn, l_info, l_tot
        FROM   capr_alerts;
    END IF;

    DBMS_APPLICATION_INFO.SET_ACTION('write file');
    l_f := UTL_FILE.FOPEN(UPPER(p_dir), c_file, 'w', 32767);

    UTL_FILE.PUT_LINE(l_f, '# AWR Capacity Forecast -- alert snapshot');
    UTL_FILE.PUT_LINE(l_f, '# generated : '
                           || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
    SELECT LISTAGG(target_name, ', ' ON OVERFLOW TRUNCATE) WITHIN GROUP (ORDER BY target_name)
    INTO   l_targets
    FROM   (SELECT DISTINCT target_name FROM capr_targets);
    UTL_FILE.PUT_LINE(l_f, '# database  : ' || NVL(l_targets, '(no target)'));
    UTL_FILE.PUT_LINE(l_f, '# schema    : ' || SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') || ' on '
                           || NVL(SYS_CONTEXT('USERENV', 'CDB_NAME'), SYS_CONTEXT('USERENV', 'DB_NAME'))
                           || CASE WHEN SYS_CONTEXT('USERENV', 'CDB_NAME') IS NOT NULL
                                   THEN '/' || SYS_CONTEXT('USERENV', 'CON_NAME') END);
    FOR d IN (SELECT target_name, dbid, newest_snap, age_hours, is_stale, collect_state
              FROM   capr_targets
              WHERE  dbid IS NOT NULL
              ORDER  BY target_name, dbid) LOOP
        UTL_FILE.PUT_LINE(l_f, '# data through: ' || d.target_name || ' (dbid ' || d.dbid || ') '
                               || CASE WHEN d.newest_snap IS NULL THEN 'no snapshot yet'
                                       ELSE TO_CHAR(d.newest_snap, 'YYYY-MM-DD HH24:MI') || ', '
                                            || TO_CHAR(d.age_hours, 'FM9999990.0') || ' h ago' END
                               || CASE WHEN d.is_stale = 'Y' THEN ' (STALE)' END
                               || CASE WHEN d.collect_state <> 'OK'
                                       THEN ' collect ' || d.collect_state END);
    END LOOP;
    IF l_run IS NULL THEN
        UTL_FILE.PUT_LINE(l_f, '# refresh   : no refresh run yet (live evaluation of CAPR_ALERTS)');
    END IF;
    FOR r IN (SELECT run_id, as_of_day, status, last_ok_age_hours, stale_run, summary, is_last
              FROM   capr_runs
              WHERE  is_last = 'Y' OR run_id = l_run
              ORDER  BY run_id DESC) LOOP
        UTL_FILE.PUT_LINE(l_f, '# refresh   : ' || CASE WHEN r.is_last = 'Y' THEN 'last ' ELSE 'last OK ' END
                               || r.summary || ', as of ' || TO_CHAR(r.as_of_day, 'YYYY-MM-DD')
                               || ', status ' || r.status
                               || CASE WHEN r.run_id = l_run
                                       THEN ', ' || TO_CHAR(r.last_ok_age_hours, 'FM9999990.0') || ' h ago' END
                               || CASE WHEN r.stale_run = 'Y' THEN ' (STALE REFRESH)' END);
    END LOOP;
    UTL_FILE.PUT_LINE(l_f, '# alerts    : ' || l_tot || ' total  ('
                           || l_crit || ' CRIT, ' || l_warn || ' WARN, '
                           || l_info || ' INFO)'
                           || CASE WHEN l_run IS NOT NULL
                                   THEN ' open and not acked as of run ' || l_run END);
    UTL_FILE.PUT_LINE(l_f, '# columns   : '
                           || 'SEVERITY|KIND|DB_PDB|SERIES_KEY|DAY|VALUE|THRESHOLD|UNIT|MESSAGE');
    UTL_FILE.PUT_LINE(l_f, '#');

    IF l_tot = 0 THEN
        UTL_FILE.PUT_LINE(l_f, 'OK|NONE|-|-|-|-|-|-|No capacity alerts.');
    ELSIF l_run IS NOT NULL THEN
        FOR r IN (SELECT severity, kind, db_pdb, series_key, day_dt,
                         value, threshold, unit, message
                  FROM   capr_alerts_latest
                  ORDER  BY CASE kind WHEN 'DATA_STALE' THEN 0 ELSE 1 END,
                            sev_rank, kind, db_pdb, series_key) LOOP
            alert_line(r.severity, r.kind, r.db_pdb, r.series_key, r.day_dt,
                       r.value, r.threshold, r.unit, r.message);
        END LOOP;
    ELSE
        FOR r IN (SELECT severity, kind, db_pdb, series_key, day_dt,
                         value, threshold, unit, message
                  FROM   capr_alerts
                  ORDER  BY CASE kind WHEN 'DATA_STALE' THEN 0 ELSE 1 END,
                            sev_rank, kind, db_pdb, series_key) LOOP
            alert_line(r.severity, r.kind, r.db_pdb, r.series_key, r.day_dt,
                       r.value, r.threshold, r.unit, r.message);
        END LOOP;
    END IF;

    IF l_run IS NOT NULL THEN
        UTL_FILE.PUT_LINE(l_f, '#');
        UTL_FILE.PUT_LINE(l_f, '# events of run ' || l_run
                               || ': #event|EVENT|SEVERITY|KIND|DB_PDB|SERIES_KEY|AT|MESSAGE');
        FOR e IN (SELECT event, severity, kind, db_pdb, series_key, at_time, message
                  FROM   capr_alert_events
                  WHERE  run_id = l_run
                  ORDER  BY event_id) LOOP
            UTL_FILE.PUT_LINE(l_f, '#event|' || e.event || '|' || e.severity || '|' || e.kind || '|'
                                   || NVL(e.db_pdb, '-') || '|' || NVL(e.series_key, '-') || '|'
                                   || TO_CHAR(e.at_time, 'YYYY-MM-DD HH24:MI') || '|' || NVL(e.message, '-'));
        END LOOP;
    END IF;

    UTL_FILE.FCLOSE(l_f);
    DBMS_APPLICATION_INFO.SET_MODULE(l_mod, l_act);
EXCEPTION
    WHEN OTHERS THEN
        IF UTL_FILE.IS_OPEN(l_f) THEN
            UTL_FILE.FCLOSE(l_f);
        END IF;
        DBMS_APPLICATION_INFO.SET_MODULE(l_mod, l_act);
        RAISE;
END cap_report_spool;
/

PROMPT -- creating procedure cap_nightly ...

CREATE OR REPLACE PROCEDURE cap_nightly (p_steps IN VARCHAR2 DEFAULT 'RETRAIN REFRESH SPOOL',
                                         p_dir   IN VARCHAR2 DEFAULT 'CAP_REPORTS')
AUTHID DEFINER
AS
    -- The night's work in a fixed order, each step after the previous one
    -- has ended (M24.12): PURGE (cap_repo.purge), RETRAIN
    -- (cap_forecast_ml.train_all), REFRESH (cap_results.refresh), SPOOL
    -- (cap_report_spool(p_dir)). p_steps names the steps to run, any order,
    -- blank-separated; the order stays this one. A failed step is rolled
    -- back and the later steps still run; at the end ORA-20080 names every
    -- failed step. Each step's outcome and seconds go to DBMS_OUTPUT, which
    -- the scheduler keeps as the run's OUTPUT. cap_repo exists only in
    -- repository mode, hence the dynamic call.
    TYPE t_steps IS TABLE OF VARCHAR2(10);
    c_order  CONSTANT t_steps := t_steps('PURGE', 'RETRAIN', 'REFRESH', 'SPOOL');
    l_steps  VARCHAR2(400) := ' ' || UPPER(TRIM(p_steps)) || ' ';
    l_failed VARCHAR2(4000);
    l_t0     PLS_INTEGER;
    l_mod    VARCHAR2(64);
    l_act    VARCHAR2(64);

    FUNCTION secs RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(ROUND((DBMS_UTILITY.GET_TIME - l_t0) / 100)) || ' s';
    END secs;
BEGIN
    DBMS_APPLICATION_INFO.READ_MODULE(l_mod, l_act);
    DBMS_APPLICATION_INFO.SET_MODULE('AWRCAP/cap_nightly', NULL);
    FOR w IN (SELECT REGEXP_SUBSTR(TRIM(l_steps), '[^ ]+', 1, LEVEL) AS step
              FROM   dual
              CONNECT BY LEVEL <= REGEXP_COUNT(TRIM(l_steps), '[^ ]+')) LOOP
        IF w.step NOT MEMBER OF c_order THEN
            RAISE_APPLICATION_ERROR(-20081, 'cap_nightly: unknown step ' || w.step
                                            || ' (PURGE, RETRAIN, REFRESH, SPOOL)');
        END IF;
    END LOOP;
    FOR i IN 1 .. c_order.COUNT LOOP
        CONTINUE WHEN INSTR(l_steps, ' ' || c_order(i) || ' ') = 0;
        DBMS_APPLICATION_INFO.SET_ACTION(c_order(i));
        l_t0 := DBMS_UTILITY.GET_TIME;
        BEGIN
            CASE c_order(i)
                WHEN 'PURGE'   THEN EXECUTE IMMEDIATE 'BEGIN cap_repo.purge; END;';
                WHEN 'RETRAIN' THEN cap_forecast_ml.train_all;
                WHEN 'REFRESH' THEN cap_results.refresh;
                WHEN 'SPOOL'   THEN cap_report_spool(p_dir);
            END CASE;
            DBMS_OUTPUT.PUT_LINE(RPAD(c_order(i), 8) || 'OK in ' || secs);
        EXCEPTION
            WHEN OTHERS THEN
                ROLLBACK;
                DBMS_OUTPUT.PUT_LINE(RPAD(c_order(i), 8) || 'FAILED after ' || secs || ': ' || SQLERRM);
                l_failed := SUBSTR(l_failed || CASE WHEN l_failed IS NOT NULL THEN '; ' END
                                   || c_order(i) || ': ' || SQLERRM, 1, 1800);
        END;
    END LOOP;
    DBMS_APPLICATION_INFO.SET_MODULE(l_mod, l_act);
    IF l_failed IS NOT NULL THEN
        RAISE_APPLICATION_ERROR(-20080, 'cap_nightly: ' || l_failed);
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_APPLICATION_INFO.SET_MODULE(l_mod, l_act);
        RAISE;
END cap_nightly;
/

-- Report (but do not fail on) a procedure that could not compile -- e.g. when
-- CAPR_ALERTS is missing because the suite is not installed in this schema.
DECLARE
    v_status VARCHAR2(20);
BEGIN
    -- ALL_OBJECTS + owner, not USER_OBJECTS: USER_* follows the session user,
    -- not CURRENT_SCHEMA, so it would look in the wrong schema whenever you
    -- installed with ALTER SESSION SET CURRENT_SCHEMA.
    FOR p IN (SELECT 'CAP_REPORT_SPOOL' AS name FROM dual UNION ALL SELECT 'CAP_NIGHTLY' FROM dual) LOOP
        SELECT MAX(status) INTO v_status
        FROM   all_objects
        WHERE  owner       = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
          AND  object_name = p.name
          AND  object_type = 'PROCEDURE';
        IF v_status IS NULL THEN
            DBMS_OUTPUT.PUT_LINE('  [WARN] procedure ' || p.name || ' was not created.');
        ELSIF v_status = 'INVALID' THEN
            DBMS_OUTPUT.PUT_LINE('  [WARN] procedure ' || p.name || ' is INVALID '
                                 || '(is the suite, ddl/60 included, installed in this schema?).');
        ELSE
            DBMS_OUTPUT.PUT_LINE('  [ OK ] procedure ' || p.name || ' is VALID.');
        END IF;
    END LOOP;
END;
/

PROMPT -- (re)creating the jobs, DISABLED ...

-- --------------------------------------------------------------------
-- Drop-if-exists. ORA-27475 (unknown job) / ORA-27476 (does not exist) are
-- the "was not there" codes; anything else is a real problem and re-raises.
-- --------------------------------------------------------------------
DECLARE
    PROCEDURE drop_job(p_name IN VARCHAR2) IS
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => p_name, force => TRUE);
        DBMS_OUTPUT.PUT_LINE('  dropped existing job ' || p_name);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE NOT IN (-27475, -27476) THEN
                RAISE;
            END IF;
    END drop_job;
BEGIN
    drop_job('CAP_NIGHTLY_JOB');
    drop_job('CAP_COLLECT_JOB');
    -- Replaced by CAP_NIGHTLY_JOB (M24.12).
    drop_job('CAP_REFRESH_JOB');
    drop_job('CAP_ML_RETRAIN');
    drop_job('CAP_REPORT_SPOOL_JOB');
    drop_job('CAP_PURGE_JOB');
END;
/

BEGIN
    -- The night's work, step after step (see cap_nightly). A failed step
    -- fails the run, after the remaining steps have run.
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'CAP_NIGHTLY_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN DBMS_SESSION.SET_IDENTIFIER(''CAP_NIGHTLY_JOB''); '
                           || 'cap_nightly(''&nightly_steps'', ''&report_dir''); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => '&nightly_interval',
        enabled         => FALSE,
        auto_drop       => FALSE,
        comments        => 'AWR capacity: the nightly steps in order (cap_nightly: &nightly_steps)');
    DBMS_OUTPUT.PUT_LINE('  created CAP_NIGHTLY_JOB   (disabled, &nightly_interval: &nightly_steps)');
END;
/

BEGIN
    IF '&repo_mode' = 'N' THEN
        DBMS_OUTPUT.PUT_LINE('  CAP_COLLECT_JOB not created: no package CAP_REPO here'
                             || ' (repository mode only).');
        RETURN;
    END IF;
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'CAP_COLLECT_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN DBMS_SESSION.SET_IDENTIFIER(''CAP_COLLECT_JOB''); cap_repo.collect; END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => '&collect_interval',
        enabled         => FALSE,
        auto_drop       => FALSE,
        comments        => 'AWR capacity: copy the targets'' AWR (cap_repo.collect)');
    DBMS_OUTPUT.PUT_LINE('  created CAP_COLLECT_JOB   (disabled, &collect_interval)');
END;
/

PROMPT
PROMPT -- current state:
SET FEEDBACK ON
COLUMN job_name        FORMAT A20
COLUMN enabled         FORMAT A8
COLUMN repeat_interval FORMAT A44
SELECT job_name, enabled, repeat_interval
FROM   all_scheduler_jobs
WHERE  owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
  AND  job_name IN ('CAP_NIGHTLY_JOB', 'CAP_COLLECT_JOB')
ORDER  BY job_name;
SET FEEDBACK OFF

PROMPT
PROMPT ============================================================
PROMPT  Jobs installed, DISABLED. To turn them on:
PROMPT    EXEC DBMS_SCHEDULER.ENABLE('CAP_NIGHTLY_JOB')
BEGIN
    IF '&repo_mode' = 'Y' THEN
        DBMS_OUTPUT.PUT_LINE('    EXEC DBMS_SCHEDULER.ENABLE(''CAP_COLLECT_JOB'')');
    END IF;
END;
/
PROMPT  To run the night once, right now, in this session:
PROMPT    SET SERVEROUTPUT ON
PROMPT    EXEC cap_nightly('&nightly_steps', '&report_dir')
PROMPT  Or write the alert snapshot alone, no job needed:
PROMPT    EXEC cap_report_spool('&report_dir')
PROMPT  To check results (OUTPUT holds each step's outcome and seconds):
PROMPT    SELECT job_name, status, actual_start_date, run_duration, output
PROMPT      FROM user_scheduler_job_run_details ORDER BY log_date DESC;
PROMPT  To remove everything again:
PROMPT    @uninstall_jobs.sql
PROMPT ============================================================
PROMPT

SET FEEDBACK ON
