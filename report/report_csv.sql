--
-- report/report_csv.sql -- read-only CSV export of the CAPR report views.
-- =====================================================================
-- Writes one CSV file per CAPR section view into
-- reports/cap_csv_<db>_<ts>/<view>.csv, with a header line (line 1) and every value
-- quoted (SET MARKUP CSV ON QUOTE ON): capr_alerts, capr_tbspc_days_to_full,
-- capr_tbspc_forecast, capr_tbspc_anomalies, capr_cpu_trend,
-- capr_cpu_anomalies, capr_cpu_shifts, capr_series, capr_fit,
-- capr_anomalies, and the memory sizing views capr_mem_verdict,
-- capr_mem_evidence, capr_mem_components, capr_mem_comp_points, the
-- forecast track record capr_fit_track, the tablespace families
-- capr_tbspc_family, capr_tbspc_family_members, and capr_disk
-- and capr_tbspc_shared (the shared disk of each database and the tablespaces on it). Every column of the view, every row in the scope (no top_n
-- bound), so a spreadsheet or a script gets what the reports format. A view
-- with no rows in the scope leaves an empty file: SQL*Plus prints no header
-- without a row.
-- READ-ONLY: only SELECTs. Never prompts.
--
-- Run from the REPO ROOT (needs report/defaults.sql only for a consistent
-- session setup, like the other drivers):
--   SQL> @report/report_csv.sql                       -- every database
--   SQL> @report/report_csv.sql 42424242              -- one dbid
--   SQL> @report/report_csv.sql 42424242 42424243     -- one container
--   SQL> @report/report_csv.sql - 42424243            -- one con_dbid, any dbid
--   SQL> @report/report_csv.sql CDB1                  -- one target (report/scope.sql)
--   SQL> @report/report_csv.sql - - SNAPSHOT          -- from the newest refresh run
-- Arguments: [dbid] [con_dbid] [LIVE|SNAPSHOT], each optional, '-' skips one,
-- UNDEFINEd at the end. SNAPSHOT writes every file from the <view>_S table of
-- the view (cap_results.snap_views), the rows of the newest refresh run,
-- with the same columns as LIVE. Dates print as
-- YYYY-MM-DD HH24:MI:SS, numbers unformatted (NUMFORMAT TM9).
--
SET APPINFO OFF
SET APPINFO "AWRCAP/report/report_csv.sql"
SET DEFINE '&'
SET VERIFY     OFF
SET FEEDBACK   OFF
SET ECHO       OFF
SET TERMOUT    OFF
SET TRIMSPOOL  ON
SET LINESIZE   32767
SET PAGESIZE   50000
SET HEADING    ON
SET NUMFORMAT  TM9
SET NEWPAGE    NONE
WHENEVER SQLERROR CONTINUE

-- COLUMN settings live for the whole SQL*Plus session: a report run earlier
-- in it would rename and reformat these columns. Start clean.
CLEAR COLUMNS
CLEAR BREAKS

ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';
ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

@@report/defaults.sql

COLUMN 1 NEW_VALUE 1 NOPRINT
COLUMN 2 NEW_VALUE 2 NOPRINT
COLUMN 3 NEW_VALUE 3 NOPRINT
SELECT NULL AS "1", NULL AS "2", NULL AS "3" FROM dual WHERE 1 = 0;

-- Scope, as in report/report.sql (report/scope.sql): a number or the
-- literal NULL. '-' stands for an omitted argument.
COLUMN cap_a1 NEW_VALUE cap_arg_db  NOPRINT
COLUMN cap_a2 NEW_VALUE cap_arg_con NOPRINT
SELECT NVL(TRIM('&1'), '-') AS cap_a1, NVL(TRIM('&2'), '-') AS cap_a2 FROM dual;
@@report/scope.sql

-- cap_s: the snapshot suffix (a read written capr_x plus cap_s is CAPR_X_S
-- under SNAPSHOT).
COLUMN cap_dir   NEW_VALUE cap_dir   NOPRINT
COLUMN eff_s     NEW_VALUE cap_s     NOPRINT
SELECT 'reports/cap_csv_' || '&cap_stem' || '_'
         || TO_CHAR(SYSDATE,'YYYYMMDDHH24MISS')                AS cap_dir,
       CASE WHEN UPPER(TRIM('&3')) = 'SNAPSHOT' THEN '_s' END   AS eff_s
FROM   dual;
COLUMN 1 CLEAR
COLUMN 2 CLEAR
COLUMN 3 CLEAR
COLUMN eff_s     CLEAR
COLUMN cap_a1    CLEAR
COLUMN cap_a2    CLEAR
COLUMN cap_dir   CLEAR

HOST mkdir -p &cap_dir

SET MARKUP CSV ON DELIMITER , QUOTE ON

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_alerts')
SPOOL &cap_dir/capr_alerts.csv
SELECT *
FROM   capr_alerts&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY sev_rank, kind, db_pdb, series_key, day_dt;
SPOOL OFF

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_tbspc_days_to_full')
SPOOL &cap_dir/capr_tbspc_days_to_full.csv
SELECT *
FROM   capr_tbspc_days_to_full&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, rank_dtf;
SPOOL OFF

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_tbspc_forecast')
SPOOL &cap_dir/capr_tbspc_forecast.csv
SELECT *
FROM   capr_tbspc_forecast&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, rank_report;
SPOOL OFF

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_tbspc_anomalies')
SPOOL &cap_dir/capr_tbspc_anomalies.csv
SELECT *
FROM   capr_tbspc_anomalies&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, days_ago, con_dbid, tablespace_name, mode_rank;
SPOOL OFF

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_cpu_trend')
SPOOL &cap_dir/capr_cpu_trend.csv
SELECT *
FROM   capr_cpu_trend&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, con_dbid, metric;
SPOOL OFF

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_cpu_anomalies')
SPOOL &cap_dir/capr_cpu_anomalies.csv
SELECT *
FROM   capr_cpu_anomalies&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, days_ago, con_dbid, metric, mode_rank, ts;
SPOOL OFF

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_cpu_shifts')
SPOOL &cap_dir/capr_cpu_shifts.csv
SELECT *
FROM   capr_cpu_shifts&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, rank_shift;
SPOOL OFF

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_series')
SPOOL &cap_dir/capr_series.csv
SELECT *
FROM   capr_series&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, rank_series;
SPOOL OFF

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_fit')
SPOOL &cap_dir/capr_fit.csv
SELECT *
FROM   capr_fit&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY sev_rank, days_to_full, db, kind, series;
SPOOL OFF

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_anomalies')
SPOOL &cap_dir/capr_anomalies.csv
SELECT *
FROM   capr_anomalies&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY ts, dbid, con_dbid, kind, series, anomaly_kind, baseline_mode;
SPOOL OFF

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_mem_verdict')
SPOOL &cap_dir/capr_mem_verdict.csv
SELECT *
FROM   capr_mem_verdict&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, rank_mem;
SPOOL OFF

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_mem_evidence')
SPOOL &cap_dir/capr_mem_evidence.csv
SELECT *
FROM   capr_mem_evidence&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, rank_ev;
SPOOL OFF

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_mem_components')
SPOOL &cap_dir/capr_mem_components.csv
SELECT *
FROM   capr_mem_components&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, rank_comp;
SPOOL OFF

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_mem_comp_points')
SPOOL &cap_dir/capr_mem_comp_points.csv
SELECT *
FROM   capr_mem_comp_points&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, instance_number, component, ts;
SPOOL OFF

-- Table-backed (CAP_FIT_HIST, CAP_RUN): the same rows under LIVE and SNAPSHOT.
EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_fit_track')
SPOOL &cap_dir/capr_fit_track.csv
SELECT *
FROM   capr_fit_track
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, rank_track;
SPOOL OFF

-- ---- tablespace families (ddl/32) ----
EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_tbspc_family')
SPOOL &cap_dir/capr_tbspc_family.csv
SELECT *
FROM   capr_tbspc_family&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, rank_family;
SPOOL OFF

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_tbspc_family_members')
SPOOL &cap_dir/capr_tbspc_family_members.csv
SELECT *
FROM   capr_tbspc_family_members&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, con_dbid, family_name, member_seq;
SPOOL OFF

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_disk')
SPOOL &cap_dir/capr_disk.csv
SELECT *
FROM   capr_disk&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, disk_name;
SPOOL OFF

EXEC DBMS_APPLICATION_INFO.SET_ACTION('capr_tbspc_shared')
SPOOL &cap_dir/capr_tbspc_shared.csv
SELECT *
FROM   capr_tbspc_shared&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, rank_shared;
SPOOL OFF

SET MARKUP CSV OFF
SET NUMFORMAT ""

-- SQL*Plus 19c starts every CSV spool with an empty line (verified with
-- NEWPAGE NONE / 0 and PAGESIZE 0); drop it so line 1 is the header.
HOST sed -i '1{/^$/d}' &cap_dir/*.csv
-- A SNAPSHOT file starts with the table's snap_run_id (CSV markup ignores
-- COLUMN NOPRINT, 19c): drop that first field, so both sources write the
-- view's columns. A LIVE header never starts with it, so LIVE files stay.
HOST sed -i -E '/^"SNAP_RUN_ID",/,$ s/^("SNAP_RUN_ID"|"?[0-9]+"?),//' &cap_dir/*.csv
SET TERMOUT ON
SET PAGESIZE 200
SET NEWPAGE 1

-- The run's scope (report/scope.sql) ends with it.
EXEC DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL)

UNDEFINE 1
UNDEFINE 2
UNDEFINE 3

PROMPT
PROMPT CSV written to: &cap_dir
PROMPT
