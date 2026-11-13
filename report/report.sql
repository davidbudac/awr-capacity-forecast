--
-- report/report.sql -- read-only text capacity report.
-- =====================================================================
-- Spools a plain-text capacity + anomaly report from the CAPF_/CAPA_ views,
-- the instance memory sizing verdicts (section 8) and the forecast track
-- record of the stored refresh runs (section 9), to
-- reports/cap_report_<db>_<ts>.txt. READ-ONLY: only SELECTs (the CAPF_ESM
-- views call a pipelined function, which writes nothing). Creates/modifies no
-- database object.
--
-- Run from the REPO ROOT so the @@report/sections/* includes resolve (SQL*Plus
-- @@ is relative to the outermost caller's directory on 19c):
--   sqlplus user/pw@svc
--   SQL> @report/report.sql                  -- defaults from report/defaults.sql
--   SQL> @report/report.sql 5                -- top_n=5
--   SQL> @report/report.sql 5 7 N            -- top_n / anomaly_days / show_esm
--   SQL> @report/report.sql 10 30 AUTO 42424242 42424243   -- one container
--   SQL> @report/report.sql - - - - - SNAPSHOT             -- from the last refresh run
-- Arguments are positional and optional (M7.6); each one omitted falls back to
-- report/defaults.sql. show_esm is AUTO | Y | N.
--   [dbid] [con_dbid]  scope: every section shows only that database / that
--                      container, and the top_n bounds rank inside the scope.
--                      Omit them, or pass '-', for every database. dbid may
--                      also be a target name (report/scope.sql).
--   [source]           LIVE (default): evaluate the CAPR views now.
--                      SNAPSHOT: every section from the newest refresh run,
--                      read from the <view>_S tables cap_results.refresh
--                      fills (cap_results.snap_views), and the alert list
--                      from CAPR_ALERTS_LATEST (lifecycle and acks). No view
--                      over the AWR data is evaluated: seconds, little PGA.
--   DEFINE timing = Y  before the run: wall time per section in the spool.
--
-- Requires the suite installed (any deploy mode). Tier 2 rows appear only if
-- cap_forecast_ml.train_all has been run.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/report/report.sql"
SET DEFINE '&'
SET VERIFY     OFF
SET FEEDBACK   OFF
SET ECHO       OFF
SET TERMOUT    ON
SET TRIMSPOOL  ON
SET LINESIZE   200
SET PAGESIZE   200
SET NEWPAGE    1
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';

-- Presentation knobs (top_n / anomaly_days / show_esm). Loaded here so a bare
-- `@report/report.sql` never prompts / hangs on an undefined substitution var.
-- To change them for every run, edit report/defaults.sql (the single source of
-- truth); to change one run, pass them positionally (M7.6):
--   @report/report.sql [top_n] [anomaly_days] [show_esm] [dbid] [con_dbid] [source]
@@report/defaults.sql

-- M7.6: make &1..&3 safe to reference whether or not they were passed. A
-- COLUMN ... NEW_VALUE whose query returns NO rows defines the variable as
-- empty instead of leaving it undefined (an undefined &1 would PROMPT, and a
-- non-interactive caller's next heredoc line would be eaten as the answer);
-- an argument that WAS passed keeps its value -- SQL*Plus only reassigns
-- NEW_VALUE on a fetched row. Verified both ways on 19c.
SET TERMOUT OFF
COLUMN 1 NEW_VALUE 1 NOPRINT
COLUMN 2 NEW_VALUE 2 NOPRINT
COLUMN 3 NEW_VALUE 3 NOPRINT
COLUMN 4 NEW_VALUE 4 NOPRINT
COLUMN 5 NEW_VALUE 5 NOPRINT
COLUMN 6 NEW_VALUE 6 NOPRINT
SELECT NULL AS "1", NULL AS "2", NULL AS "3",
       NULL AS "4", NULL AS "5", NULL AS "6" FROM dual WHERE 1 = 0;

-- DEFINE timing = Y before the run wraps the header and every section in a
-- SQL*Plus TIMING START / STOP pair: wall time per section, in the spool.
-- Otherwise both includes are report/sections/timing_off.sql (a no-op).
-- Same zero-row trick for an undefined name.
COLUMN cap_tm NEW_VALUE timing NOPRINT
SELECT NULL AS cap_tm FROM dual WHERE 1 = 0;
COLUMN cap_tm_start NEW_VALUE cap_tm_start NOPRINT
COLUMN cap_tm_stop  NEW_VALUE cap_tm_stop  NOPRINT
SELECT CASE WHEN UPPER(TRIM('&timing')) = 'Y' THEN 'report/sections/timing_start.sql'
            ELSE 'report/sections/timing_off.sql' END AS cap_tm_start,
       CASE WHEN UPPER(TRIM('&timing')) = 'Y' THEN 'report/sections/timing_stop.sql'
            ELSE 'report/sections/timing_off.sql' END AS cap_tm_stop
FROM   dual;

-- Effective knobs = positional argument, else the defaults.sql value. An
-- omitted argument is the empty string, and '' IS NULL in Oracle, so NVL
-- picks the default; '-' does the same, so a caller can skip an argument to
-- reach a later one. Re-DEFINEs the same three names the sections already use.
COLUMN eff_top_n NEW_VALUE top_n        NOPRINT
COLUMN eff_anom  NEW_VALUE anomaly_days NOPRINT
COLUMN eff_esm   NEW_VALUE show_esm     NOPRINT
SELECT NVL(NULLIF(TRIM('&1'), '-'), '&top_n')                  AS eff_top_n,
       NVL(NULLIF(TRIM('&2'), '-'), '&anomaly_days')           AS eff_anom,
       NVL(NULLIF(UPPER(TRIM('&3')), '-'), UPPER('&show_esm')) AS eff_esm
FROM   dual;

-- Scope and identity (report/scope.sql): cap_sdbid / cap_scon, which every
-- section filters on, the target name and the Database / Host / Schema
-- header values. '-' stands for an omitted argument.
COLUMN cap_a1 NEW_VALUE cap_arg_db  NOPRINT
COLUMN cap_a2 NEW_VALUE cap_arg_con NOPRINT
SELECT NVL(TRIM('&4'), '-') AS cap_a1, NVL(TRIM('&5'), '-') AS cap_a2 FROM dual;
COLUMN cap_a1 CLEAR
COLUMN cap_a2 CLEAR
@@report/scope.sql

-- cap_s is the snapshot suffix: every read of a view in
-- cap_results.snap_views is written capr_x plus cap_s, so SNAPSHOT reads table
-- CAPR_X_S and LIVE the view. cap_alerts names the alert list's source.
COLUMN eff_src    NEW_VALUE cap_src    NOPRINT
COLUMN eff_s      NEW_VALUE cap_s      NOPRINT
COLUMN eff_alerts NEW_VALUE cap_alerts NOPRINT
SELECT src AS eff_src,
       CASE src WHEN 'SNAPSHOT' THEN '_s' END                                    AS eff_s,
       CASE src WHEN 'SNAPSHOT' THEN 'capr_alerts_latest' ELSE 'capr_alerts' END AS eff_alerts
FROM  (SELECT CASE WHEN UPPER(TRIM('&6')) = 'SNAPSHOT' THEN 'SNAPSHOT' ELSE 'LIVE' END AS src
       FROM   dual);
SET TERMOUT ON
DEFINE cap_tm_lbl = header
EXEC DBMS_APPLICATION_INFO.SET_ACTION('header')
@@&cap_tm_start

-- --------------------------------------------------------------------
-- Resolve identity, config knobs, ESM availability, report path (once).
-- --------------------------------------------------------------------
COLUMN cap_path NEW_VALUE cap_path NOPRINT
COLUMN dtf_warn NEW_VALUE dtf_warn NOPRINT
COLUMN dtf_crit NEW_VALUE dtf_crit NOPRINT
COLUMN cpu_sat  NEW_VALUE cpu_sat  NOPRINT
COLUMN nf_warn  NEW_VALUE nf_warn  NOPRINT
COLUMN nf_crit  NEW_VALUE nf_crit  NOPRINT
COLUMN esm_ok   NEW_VALUE esm_ok   NOPRINT
COLUMN esm_failed NEW_VALUE esm_failed NOPRINT
COLUMN esm_stale  NEW_VALUE esm_stale  NOPRINT
COLUMN mad_w      NEW_VALUE mad_w      NOPRINT
COLUMN dow_w      NEW_VALUE dow_w      NOPRINT
COLUMN esm_file NEW_VALUE esm_file NOPRINT
COLUMN min_gb   NEW_VALUE min_gb   NOPRINT
COLUMN ts_total NEW_VALUE ts_total NOPRINT
COLUMN ts_shown NEW_VALUE ts_shown NOPRINT
COLUMN cap_scope_lbl NEW_VALUE cap_scope_lbl NOPRINT
COLUMN cap_src_lbl   NEW_VALUE cap_src_lbl   NOPRINT

SELECT 'reports/cap_report_' || '&cap_stem' || '_'
         || TO_CHAR(SYSDATE,'YYYYMMDDHH24MI') || '.txt'                       AS cap_path
FROM   dual;

-- M7.7: TO_CHAR(...,'FM...') every knob. A NUMBER column's NEW_VALUE keeps
-- SQL*Plus's right-justified display width, so a raw cfg_value would print as
-- "WARN<=        90" wherever a PROMPT interpolates it.
SELECT TO_CHAR(c.dtf_warn,                                                    'FM9999990') AS dtf_warn,
       TO_CHAR(c.dtf_crit,                                                    'FM9999990') AS dtf_crit,
       TO_CHAR(c.cpu_sat_pct,                                                 'FM9999990') AS cpu_sat,
       TO_CHAR(c.nearfull_warn_pct,                                           'FM9999990') AS nf_warn,
       TO_CHAR(c.nearfull_crit_pct,                                           'FM9999990') AS nf_crit,
       -- Tier 2 health: FORECAST models only (backtest twins never reach a
       -- forecast). CAPF_ESM_HEALTH_SUMMARY has one row per container.
       TO_CHAR(h.n_ok,                                                        'FM9999990') AS esm_ok,
       TO_CHAR(h.n_failed,                                                    'FM9999990') AS esm_failed,
       TO_CHAR(h.n_stale,                                                     'FM9999990') AS esm_stale,
       -- report_min_gb may be fractional, so keep the decimals and strip the
       -- trailing point FM leaves behind on a whole number (1. -> 1).
       RTRIM(TO_CHAR(c.report_min_gb, 'FM9999990.999'), '.')                                    AS min_gb,
       TO_CHAR((SELECT COUNT(*)  FROM capr_tbspc_rank&cap_s
                WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
                  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)),               'FM9999990') AS ts_total,
       -- M7.4: how many of them sections 2 / 6a will actually print, i.e. the
       -- exact WHERE those sections apply -- so the header states the truth
       -- even when top_n is larger than the number of tablespaces. The rank
       -- is re-numbered inside the scope, as the sections do.
       TO_CHAR((SELECT COUNT(*)
                FROM  (SELECT is_reportable,
                              ROW_NUMBER() OVER (PARTITION BY dbid ORDER BY rank_report) AS s_rank
                       FROM   capr_tbspc_rank&cap_s
                       WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
                         AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon))
                WHERE is_reportable = 'Y' AND s_rank <= &top_n),                    'FM9999990') AS ts_shown,
       TO_CHAR(c.mad_window_days,                                             'FM9999990') AS mad_w,
       TO_CHAR(c.dow_weeks,                                                   'FM9999990') AS dow_w
FROM   cap_cfg c
CROSS  JOIN (SELECT NVL(SUM(n_ok), 0) AS n_ok, NVL(SUM(n_failed), 0) AS n_failed,
                    NVL(SUM(n_stale), 0) AS n_stale
             FROM   capf_esm_health_summary&cap_s) h;

-- Section 8 quotes the memory knobs (RTRIM '.': FM leaves "2." of a whole
-- number with decimals in the mask). The DEFINEs keep an install without
-- the M26 knobs from prompting in section 8.
DEFINE mem_win  = '?'
DEFINE mem_upt  = '?'
DEFINE mem_plim = '?'
DEFINE mem_shrd = '?'
DEFINE mem_mind = '?'
DEFINE mem_step = '?'
DEFINE mem_host = '?'
COLUMN mem_win  NEW_VALUE mem_win  NOPRINT
COLUMN mem_upt  NEW_VALUE mem_upt  NOPRINT
COLUMN mem_plim NEW_VALUE mem_plim NOPRINT
COLUMN mem_shrd NEW_VALUE mem_shrd NOPRINT
COLUMN mem_mind NEW_VALUE mem_mind NOPRINT
COLUMN mem_step NEW_VALUE mem_step NOPRINT
COLUMN mem_host NEW_VALUE mem_host NOPRINT
SELECT TO_CHAR(mem_window_days,                     'FM9999990')         AS mem_win,
       RTRIM(TO_CHAR(mem_min_uptime_hours,         'FM9999990.99'), '.') AS mem_upt,
       RTRIM(TO_CHAR(mem_pga_limit_pct,            'FM9999990.99'), '.') AS mem_plim,
       TO_CHAR(mem_shrink_min_days,                 'FM9999990')         AS mem_shrd,
       TO_CHAR(mem_min_days,                        'FM9999990')         AS mem_mind,
       RTRIM(TO_CHAR(mem_max_step,                 'FM9999990.99'), '.') AS mem_step,
       RTRIM(TO_CHAR(mem_host_ram_pct,             'FM9999990.99'), '.') AS mem_host
FROM   cap_cfg;

-- Defaults first, so a failing lookup below (suite not installed) cannot
-- leave a variable undefined and make SQL*Plus prompt for it.
DEFINE cap_scope_lbl = 'see the arguments'
DEFINE cap_src_lbl   = '&cap_src'

-- Scope label (CAPR_CONTAINER names the container) and source label. The
-- SNAPSHOT run is the one the snapshot tables hold (MAX(snap_run_id)).
SELECT CASE WHEN &cap_sdbid IS NULL AND &cap_scon IS NULL THEN 'every database in this schema'
            ELSE CASE WHEN '&cap_starget' IS NOT NULL THEN 'target ' || '&cap_starget' || ': ' END
                 || TRIM(CASE WHEN &cap_sdbid IS NOT NULL THEN 'dbid ' || '&cap_sdbid' END
                      || CASE WHEN &cap_scon IS NOT NULL THEN ' con_dbid ' || '&cap_scon' END)
                 || ' (' || NVL((SELECT LISTAGG(db_pdb, ', ') WITHIN GROUP (ORDER BY db_pdb)
                                 FROM   capr_container&cap_s
                                 WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
                                   AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)),
                                'no such container') || ')'
       END                                                                    AS cap_scope_lbl,
       CASE WHEN '&cap_src' = 'SNAPSHOT'
            THEN NVL((SELECT 'SNAPSHOT, from refresh run ' || r.run_id || ' at '
                             || TO_CHAR(r.started_at, 'YYYY-MM-DD HH24:MI')
                             || ' (as of ' || TO_CHAR(r.as_of_day, 'YYYY-MM-DD') || ')'
                      FROM   capr_runs r
                      WHERE  r.run_id = (SELECT MAX(snap_run_id) FROM capr_container_s)),
                     'SNAPSHOT: no refresh since install; run cap_results.refresh')
            ELSE 'LIVE (CAPR views evaluated now)'
       END                                                                    AS cap_src_lbl
FROM   dual;

-- Section 6 dispatch:
--   show_esm='N'                    -> skip stub (note only)
--   show_esm='AUTO' and 0 OK FORECAST models -> skip stub (nothing to compare yet)
--   otherwise                       -> full ESM-vs-REGR compare
SELECT CASE WHEN UPPER('&show_esm') = 'N'
              OR (UPPER('&show_esm') = 'AUTO' AND &esm_ok = 0)
            THEN 'report/sections/06_esm_skip.sql'
            ELSE 'report/sections/06_esm_compare.sql'
       END AS esm_file
FROM   dual;

-- reports/ is gitignored, so a fresh clone does not have it.
HOST mkdir -p reports
SPOOL &cap_path
@@&cap_tm_stop

PROMPT ================================================================================
PROMPT  AWR CAPACITY FORECAST -- capacity + anomaly report
PROMPT ================================================================================
PROMPT  Database : &cap_db
PROMPT  Host     : &cap_host
PROMPT  Schema   : &cap_user
PROMPT  Generated: &cap_gen
PROMPT  Config   : days-to-full WARN<=&dtf_warn CRIT<=&dtf_crit ; CPU saturation &cpu_sat%
PROMPT  Tier 2   : OML ESM forecast models &esm_ok ok, &esm_failed failed, &esm_stale stale
PROMPT  Scope    : &cap_scope_lbl
PROMPT  Source   : &cap_src_lbl
PROMPT ................................................................................
PROMPT  NOTE: forecasts degrade loudly on short AWR retention -- watch TRAIN_N and
PROMPT        QUALITY. INSUFFICIENT_HISTORY means fewer than the configured minimum
PROMPT        training days; raise DBMS_WORKLOAD_REPOSITORY retention for real trends.
PROMPT ================================================================================

DEFINE cap_tm_lbl = s0
EXEC DBMS_APPLICATION_INFO.SET_ACTION('s0 at a glance')
@@&cap_tm_start
@@report/sections/00_at_a_glance.sql
@@&cap_tm_stop
DEFINE cap_tm_lbl = s1
EXEC DBMS_APPLICATION_INFO.SET_ACTION('s1 days to full')
@@&cap_tm_start
@@report/sections/01_days_to_full.sql
@@&cap_tm_stop
DEFINE cap_tm_lbl = s2
EXEC DBMS_APPLICATION_INFO.SET_ACTION('s2 tbspc forecast')
@@&cap_tm_start
@@report/sections/02_tbspc_forecast.sql
@@&cap_tm_stop
DEFINE cap_tm_lbl = s3
EXEC DBMS_APPLICATION_INFO.SET_ACTION('s3 tbspc anomalies')
@@&cap_tm_start
@@report/sections/03_tbspc_anomalies.sql
@@&cap_tm_stop
DEFINE cap_tm_lbl = s4
EXEC DBMS_APPLICATION_INFO.SET_ACTION('s4 cpu trend')
@@&cap_tm_start
@@report/sections/04_cpu_trend.sql
@@&cap_tm_stop
DEFINE cap_tm_lbl = s5
EXEC DBMS_APPLICATION_INFO.SET_ACTION('s5 cpu anomalies')
@@&cap_tm_start
@@report/sections/05_cpu_anomalies.sql
@@&cap_tm_stop
DEFINE cap_tm_lbl = s6
EXEC DBMS_APPLICATION_INFO.SET_ACTION('s6 esm compare')
@@&cap_tm_start
@@&esm_file
@@&cap_tm_stop
DEFINE cap_tm_lbl = s7
EXEC DBMS_APPLICATION_INFO.SET_ACTION('s7 series')
@@&cap_tm_start
@@report/sections/07_series.sql
@@&cap_tm_stop
DEFINE cap_tm_lbl = s8
EXEC DBMS_APPLICATION_INFO.SET_ACTION('s8 memory')
@@&cap_tm_start
@@report/sections/08_memory.sql
@@&cap_tm_stop
DEFINE cap_tm_lbl = s9
EXEC DBMS_APPLICATION_INFO.SET_ACTION('s9 track record')
@@&cap_tm_start
@@report/sections/09_track.sql
@@&cap_tm_stop

PROMPT
PROMPT ================================================================================
PROMPT  End of report -- read-only run, no database objects created or modified.
PROMPT ================================================================================

SPOOL OFF

-- The run's scope (report/scope.sql) ends with it.
EXEC DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL)

-- M7.6: positional arguments stay DEFINEd for the rest of the SQL*Plus
-- session, so drop them -- otherwise a following `@report/report_html.sql`
-- with no arguments would silently inherit this run's.
UNDEFINE 1
UNDEFINE 2
UNDEFINE 3
UNDEFINE 4
UNDEFINE 5
UNDEFINE 6

PROMPT
PROMPT Report written to: &cap_path
PROMPT
