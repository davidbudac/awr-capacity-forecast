--
-- quickstart.sql -- zero-to-first-report in one run.
-- =====================================================================
-- The suite reads this database's AWR over a loopback DB link, as a
-- repository reads any target's. Runs, in order:
--   1. target/self.sql      the read-only reader with a random password
--                           (target/prepare.sql, target/check.sql), then
--                           into the PDB the suite lives in
--   2. create_owner.sql     the schema-only suite owner (NO AUTHENTICATION),
--                           then repository/self.sql, which on a re-run
--                           rebuilds the link the new password broke
--   3. doctor.sql           preflight checklist (read-only; PASS/WARN/FAIL)
--   4. install.sql          deploy_mode = repository, into that owner
--   5. repository/self.sql  register this database as its target, collect
--   6. report/report.sql    the first text report -> reports/cap_report_*.txt
--
-- Usage -- from the REPO ROOT (the @@ includes resolve from the outermost
-- caller on 19c), as SYSDBA in CDB$ROOT or in a non-CDB:
--
--   sqlplus / as sysdba
--   SQL> @quickstart.sql
--
-- or simply  ./quickstart.sh  (same thing, wrapped). Optional DEFINEs:
--   owner         the suite owner (default AWRCAP; a C## name in CDB$ROOT)
--   reader        the reader (default C##AWRRDR, AWRRDR in a non-CDB)
--   container     the PDB for the suite (default: the one open PDB; with
--                 more than one it stops before changing anything)
--   self_connect  the loopback link's address (default
--                 //localhost:<listener port>/<the root's default service>)
--
-- Read-only against AWR. A re-run reuses the reader, the owner and the
-- target; the reader gets a new password and the link follows it.
-- On a stock box (8-day AWR retention) the first report says
-- INSUFFICIENT_HISTORY. That is expected: the copies grow with every collect.
--
-- It stops before install when doctor.sql reports any FAIL line. WARN lines
-- (short history) do not stop it. To install anyway:
--   SQL> DEFINE force_install = Y
--   SQL> @quickstart.sql
--
SET APPINFO OFF
SET APPINFO "AWRCAP/quickstart.sql"
SET DEFINE '&'
SET VERIFY   OFF
SET FEEDBACK OFF

SET TERMOUT OFF
COLUMN cap_o_q NEW_VALUE owner         NOPRINT
COLUMN cap_f_q NEW_VALUE force_install NOPRINT
SELECT NULL AS cap_o_q, NULL AS cap_f_q FROM dual WHERE 1 = 0;
COLUMN cap_o_q CLEAR
COLUMN cap_f_q CLEAR
SET TERMOUT ON

PROMPT
PROMPT ############################################################
PROMPT  AWR Capacity Forecast -- quickstart
PROMPT  1/6 target side   2/6 owner   3/6 preflight   4/6 install
PROMPT  5/6 register + collect   6/6 first report
PROMPT ############################################################
PROMPT

-- reports/ must exist before report.sql can SPOOL into it. Done here, before
-- install.sql switches WHENEVER OSERROR to EXIT, so a no-op on an existing
-- dir (or a Windows shell) cannot abort the run.
HOST mkdir -p reports

PROMPT ==== [1/6] this database as its own target -- target/self.sql ====
@@target/self.sql
SET DEFINE '&'
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE

PROMPT
PROMPT ==== [2/6] suite owner -- create_owner.sql ====
DEFINE owner_pw    = ''
DEFINE owner_ts    = ''
DEFINE owner_quota = 'UNLIMITED'
DEFINE owner_mode  = 'repository'
@@create_owner.sql
SET DEFINE '&'
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE
ALTER SESSION SET CURRENT_SCHEMA = &owner;
@@repository/self.sql
SET DEFINE '&'
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE

PROMPT
PROMPT ==== [3/6] preflight -- doctor.sql ====
DEFINE cap_doctor_mode = 'repository'
@@doctor.sql
SET DEFINE '&'
SET FEEDBACK OFF

-- Stop on a doctor FAIL: print why, then divide by zero under
-- WHENEVER SQLERROR EXIT so sqlplus exits non-zero before install.sql runs.
SET HEADING OFF
SELECT 'quickstart: STOPPED before install. doctor.sql reported &cap_doctor_fail FAIL line(s)'
       || ' (a FAIL means install.sql would fail or forecasts would be empty).'
       || CHR(10) || 'Fix the FAIL lines above and re-run, or DEFINE force_install = Y to install anyway.'
FROM   dual
WHERE  TO_NUMBER('&cap_doctor_fail') > 0
  AND  UPPER(NVL('&force_install', 'N')) <> 'Y';
SET HEADING ON
WHENEVER SQLERROR EXIT FAILURE
COLUMN cap_gate NOPRINT
SELECT CASE WHEN TO_NUMBER('&cap_doctor_fail') > 0
             AND UPPER(NVL('&force_install', 'N')) <> 'Y'
            THEN 1/0 ELSE 0 END AS cap_gate
FROM   dual;
COLUMN cap_gate CLEAR

PROMPT
PROMPT ==== [4/6] install -- install.sql  (deploy_mode = repository) ====
DEFINE deploy_mode = 'repository'
@@install.sql
SET DEFINE '&'
WHENEVER SQLERROR EXIT FAILURE

PROMPT
PROMPT ==== [5/6] register and collect -- repository/self.sql ====
@@repository/self.sql
SET DEFINE '&'
WHENEVER SQLERROR CONTINUE

PROMPT
PROMPT ==== [6/6] first report -- report/report.sql ====
@@report/report.sql

SET DEFINE '&'
PROMPT ############################################################
PROMPT  Quickstart done. The report path is printed just above.
PROMPT  The suite reads its own copies of this database's AWR, which
PROMPT  grow with every cap_repo.collect. INSUFFICIENT_HISTORY on a
PROMPT  stock box means AWR held only its 8 days. Schedule the hourly
PROMPT  collect (as the owner: @install_jobs.sql, then enable
PROMPT  CAP_COLLECT_JOB), or raise AWR retention for more at once
PROMPT    EXEC DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS(retention => 90*24*60)
PROMPT  and re-run quickstart.
PROMPT ############################################################
PROMPT
UNDEFINE deploy_mode
UNDEFINE force_install
UNDEFINE cap_doctor_mode
UNDEFINE owner owner_ts owner_quota owner_mode
