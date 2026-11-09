--
-- uninstall_jobs.sql -- remove everything install_jobs.sql created.
-- =====================================================================
-- Drops the DBMS_SCHEDULER jobs (CAP_COLLECT_JOB exists only in repository
-- mode), the four an install before M24.12 created instead of
-- CAP_NIGHTLY_JOB, and the CAP_NIGHTLY and CAP_REPORT_SPOOL procedures from
-- the current schema. Idempotent: safe
-- against a partial install or a schema that never had the jobs. Touches
-- nothing else -- the suite's views, tables and OML models are untouched
-- (use uninstall.sql for those).
--
SET APPINFO OFF
SET APPINFO "AWRCAP/uninstall_jobs.sql"
SET DEFINE OFF
SET VERIFY   OFF
SET FEEDBACK OFF
SET TAB      OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR CONTINUE

PROMPT -- dropping scheduler jobs ...

DECLARE
    -- ORA-27475 (unknown job) / ORA-27476 (does not exist) mean "already gone".
    PROCEDURE drop_job(p_name IN VARCHAR2, p_legacy IN BOOLEAN DEFAULT FALSE) IS
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => p_name, force => TRUE);
        DBMS_OUTPUT.PUT_LINE('  dropped job ' || p_name);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE IN (-27475, -27476) THEN
                IF NOT p_legacy THEN
                    DBMS_OUTPUT.PUT_LINE('  (job ' || p_name || ' not present)');
                END IF;
            ELSE
                DBMS_OUTPUT.PUT_LINE('  (could not drop ' || p_name || ': '
                                     || SQLERRM || ')');
            END IF;
    END drop_job;
BEGIN
    drop_job('CAP_NIGHTLY_JOB');
    drop_job('CAP_COLLECT_JOB');
    drop_job('CAP_REFRESH_JOB',      TRUE);
    drop_job('CAP_ML_RETRAIN',       TRUE);
    drop_job('CAP_REPORT_SPOOL_JOB', TRUE);
    drop_job('CAP_PURGE_JOB',        TRUE);
END;
/

PROMPT -- dropping procedures cap_nightly and cap_report_spool ...

BEGIN
    FOR p IN (SELECT 'CAP_NIGHTLY' AS name FROM dual UNION ALL SELECT 'CAP_REPORT_SPOOL' FROM dual) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'DROP PROCEDURE ' || p.name;
            DBMS_OUTPUT.PUT_LINE('  dropped procedure ' || p.name);
        EXCEPTION
            WHEN OTHERS THEN
                -- ORA-04043: object does not exist
                IF SQLCODE = -4043 THEN
                    DBMS_OUTPUT.PUT_LINE('  (procedure ' || p.name || ' not present)');
                ELSE
                    RAISE;
                END IF;
        END;
    END LOOP;
END;
/

PROMPT -- jobs uninstall complete.
SET FEEDBACK ON
