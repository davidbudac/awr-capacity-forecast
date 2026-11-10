--
-- report/drill_mem.sql -- drill-down for the memory verdicts of ONE instance.
-- =====================================================================
-- Prints (and spools) what the six memory verdicts (M26, ddl/42) of one
-- instance rest on:
--   1. the instance        -- memory mode, parameters, host memory, the
--                             evidence window, then the six verdicts
--   2. the startups        -- every uptime of the window, USED or SKIPPED
--   3. the evidence        -- every signal with value, unit and threshold
--   4. the advisor curves  -- every advised size of the four advisors, with
--                             the current, reference and suggested sizes
--   5. resize activity     -- the component intervals that changed size or
--                             counted operations, then the component summary
-- Not built yet, so not printed: the per-PDB memory rows and the resize
-- operations view (DBA_HIST_MEMORY_RESIZE_OPS) the spec lists for this script.
--
-- READ-ONLY: SELECTs against CAPV_TARGET / CAPV_SNAPSHOT, the CAPM_ views and
-- the CAPR_MEM_ views (live, not the snapshot tables). Each of the deep views
-- (CAPR_MEM_VERDICT, CAPR_MEM_EVIDENCE, CAPM_ADVICE) is read once.
--
-- Run from the REPO ROOT (SQL*Plus @@ resolves against the outermost caller):
--   SQL> @report/drill_mem.sql                    -- the schema's one database, its one instance
--   SQL> @report/drill_mem.sql 42424242           -- a dbid
--   SQL> @report/drill_mem.sql CDB1 2             -- a target name, instance 2
-- Arguments: [database] [instance_number], both optional ('-' skips one).
-- The database is a dbid or a target name (report/scope.sql), required only
-- when the schema holds more than one. The instance defaults to the
-- database's only one, else 1. A wrong argument prints usage and the
-- queries return nothing (no prompt, no hang). The run scopes the session to
-- the database (CLIENT_INFO, report/scope.sql), so it costs one database at
-- any fleet size, and clears the scope at the end.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/report/drill_mem.sql"
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

-- Optional positional arguments without prompting (see drill_tbspc.sql).
SET TERMOUT OFF
COLUMN 1 NEW_VALUE 1 NOPRINT
COLUMN 2 NEW_VALUE 2 NOPRINT
SELECT NULL AS "1", NULL AS "2" FROM dual WHERE 1 = 0;

COLUMN cap_a1 NEW_VALUE cap_arg_db  NOPRINT
COLUMN cap_a2 NEW_VALUE cap_arg_con NOPRINT
COLUMN dm_a2  NEW_VALUE dm_arg_inst NOPRINT
SELECT NVL(TRIM('&1'), '-') AS cap_a1, '-' AS cap_a2, NVL(TRIM('&2'), '-') AS dm_a2 FROM dual;
COLUMN cap_a1 CLEAR
COLUMN cap_a2 CLEAR
COLUMN dm_a2  CLEAR
@@report/scope.sql

-- dm_dbid: the scoped dbid, else the schema's only one, else -1 (none of
-- the queries below matches). dm_dbs lists the databases for the usage text,
-- so it reads them unscoped: scope.sql scopes an unknown name to dbid -1.
EXEC DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL)
COLUMN dm_dbid_c NEW_VALUE dm_dbid NOPRINT
COLUMN dm_dbs_c  NEW_VALUE dm_dbs  NOPRINT
SELECT CASE WHEN &cap_sdbid IS NOT NULL THEN TO_CHAR(&cap_sdbid)
            WHEN COUNT(*) = 1 THEN TO_CHAR(MAX(d.dbid))
            ELSE '-1' END                                                     AS dm_dbid_c,
       NVL(LISTAGG(d.dbid || NVL2(d.names, ' (' || d.names || ')', NULL), ', ' ON OVERFLOW TRUNCATE)
             WITHIN GROUP (ORDER BY d.dbid), 'none')                         AS dm_dbs_c
FROM  (SELECT s.dbid,
              (SELECT LISTAGG(t.target_name, ' / ') WITHIN GROUP (ORDER BY t.target_name)
               FROM   capv_target t WHERE t.dbid = s.dbid)                    AS names
       FROM  (SELECT DISTINCT dbid FROM capv_snapshot) s) d;

BEGIN
    DBMS_APPLICATION_INFO.SET_CLIENT_INFO(CASE WHEN &dm_dbid <> -1
                                               THEN 'AWRCAP dbid=' || &dm_dbid END);
END;
/

-- dm_inst: the instance argument, else the database's only instance, else 1.
-- dm_insts lists the database's instances; dm_inst_ok = N when dm_inst is
-- not one of them.
COLUMN dm_inst_c  NEW_VALUE dm_inst    NOPRINT
COLUMN dm_insts_c NEW_VALUE dm_insts   NOPRINT
COLUMN dm_iok_c   NEW_VALUE dm_inst_ok NOPRINT
SELECT x.inst                                                                 AS dm_inst_c,
       NVL(x.insts, 'none')                                                   AS dm_insts_c,
       CASE WHEN INSTR(',' || x.insts || ',', ',' || x.inst || ',') > 0
            THEN 'Y' ELSE 'N' END                                             AS dm_iok_c
FROM  (SELECT CASE WHEN REGEXP_LIKE(TRIM('&dm_arg_inst'), '^[0-9]+$') THEN TRIM('&dm_arg_inst')
                   WHEN COUNT(*) = 1 THEN TO_CHAR(MAX(i.instance_number))
                   ELSE '1' END                                               AS inst,
              LISTAGG(i.instance_number, ',') WITHIN GROUP (ORDER BY i.instance_number) AS insts
       FROM  (SELECT DISTINCT instance_number FROM capv_snapshot WHERE dbid = &dm_dbid) i) x;

COLUMN cap_path NEW_VALUE cap_path NOPRINT
SELECT 'reports/cap_drill_mem_'
       || CASE WHEN &dm_dbid = -1 THEN 'USAGE'
               ELSE '&cap_stem' || '_' || '&dm_inst' END
       || '_' || TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS') || '.txt'               AS cap_path
FROM   dual;

-- Knobs echoed in the headers; every one of them also drives the views below.
-- RTRIM '.': FM leaves "2." of a whole number with decimals in the mask.
COLUMN k_win   NEW_VALUE k_win   NOPRINT
COLUMN k_upt   NEW_VALUE k_upt   NOPRINT
COLUMN k_shrd  NEW_VALUE k_shrd  NOPRINT
COLUMN k_step  NEW_VALUE k_step  NOPRINT
COLUMN k_tol   NEW_VALUE k_tol   NOPRINT
COLUMN k_knee  NEW_VALUE k_knee  NOPRINT
COLUMN k_gain  NEW_VALUE k_gain  NOPRINT
COLUMN k_shr   NEW_VALUE k_shr   NOPRINT
COLUMN k_pgain NEW_VALUE k_pgain NOPRINT
COLUMN k_pshr  NEW_VALUE k_pshr  NOPRINT
COLUMN k_plim  NEW_VALUE k_plim  NOPRINT
COLUMN k_host  NEW_VALUE k_host  NOPRINT
SELECT TO_CHAR(c.mem_window_days,                     'FM9999990')         AS k_win,
       RTRIM(TO_CHAR(c.mem_min_uptime_hours,         'FM9999990.99'), '.') AS k_upt,
       TO_CHAR(c.mem_shrink_min_days,                 'FM9999990')         AS k_shrd,
       RTRIM(TO_CHAR(c.mem_max_step,                 'FM9999990.99'), '.') AS k_step,
       RTRIM(TO_CHAR(c.mem_ref_tolerance_pct,        'FM9999990.99'), '.') AS k_tol,
       RTRIM(TO_CHAR(c.mem_knee_pct,                 'FM9999990.99'), '.') AS k_knee,
       RTRIM(TO_CHAR(c.mem_gain_dbtime_pct,          'FM9999990.99'), '.') AS k_gain,
       RTRIM(TO_CHAR(c.mem_shrink_dbtime_pct,        'FM9999990.99'), '.') AS k_shr,
       RTRIM(TO_CHAR(c.mem_pga_gain_pts,             'FM9999990.99'), '.') AS k_pgain,
       RTRIM(TO_CHAR(c.mem_pga_shrink_pts,           'FM9999990.99'), '.') AS k_pshr,
       RTRIM(TO_CHAR(c.mem_pga_limit_pct,            'FM9999990.99'), '.') AS k_plim,
       RTRIM(TO_CHAR(c.mem_host_ram_pct,             'FM9999990.99'), '.') AS k_host
FROM   cap_cfg c;

-- Section 4 marks the suggested sizes, which section 1 reads from
-- CAPR_MEM_VERDICT; these defaults hold when it returns no row.
DEFINE dm_sug_sga = NULL
DEFINE dm_sug_bc  = NULL
DEFINE dm_sug_sp  = NULL
DEFINE dm_sug_pga = NULL
SET TERMOUT ON

UNDEFINE 1
UNDEFINE 2

-- reports/ is gitignored, so a fresh clone does not have it.
HOST mkdir -p reports
SPOOL &cap_path

PROMPT ================================================================================
PROMPT  MEMORY DRILL-DOWN  --  &cap_db, instance &dm_inst
PROMPT ================================================================================
PROMPT  Database : &cap_db (dbid &dm_dbid)
PROMPT  Host     : &cap_host
PROMPT  Schema   : &cap_user
PROMPT  Generated: &cap_gen
PROMPT  Read-only. Evidence window = the last &k_win days (mem_window_days) up to the
PROMPT  database's newest snapshot. Advice only: the suite never changes a parameter.
PROMPT ================================================================================

-- No leading indentation: SERVEROUTPUT's default WORD_WRAPPED format strips
-- leading blanks, so alignment is built with dots.
BEGIN
    IF &dm_dbid = -1 THEN
        DBMS_OUTPUT.PUT_LINE('No single database to drill into.');
        DBMS_OUTPUT.PUT_LINE('Usage: @report/drill_mem.sql [database] [instance_number]');
        DBMS_OUTPUT.PUT_LINE('database ......... a dbid or a target name; optional when the schema holds one.');
        DBMS_OUTPUT.PUT_LINE('instance_number .. optional; default the only instance, else 1.');
        DBMS_OUTPUT.PUT_LINE('Databases here ... &dm_dbs');
    ELSIF '&dm_inst_ok' = 'N' THEN
        DBMS_OUTPUT.PUT_LINE('Database &dm_dbid has no snapshot of instance &dm_inst; its instances: &dm_insts');
        DBMS_OUTPUT.PUT_LINE('Usage: @report/drill_mem.sql [database] [instance_number]');
    END IF;
END;
/

PROMPT
PROMPT == 1. THE INSTANCE (CAPM_INST) AND ITS SIX VERDICTS (CAPR_MEM_VERDICT) ==
PROMPT    MODE = AMM (memory_target > 0), ASMM (sga_target > 0) or MANUAL, from the parameters at
PROMPT    the instance's latest snapshot: a verdict is about the current setting. Sizes in MiB.
PROMPT    SGA_MAX = the larger of sga_max_size and sga_target. PGA_LIMIT empty = 0, no limit.
PROMPT    HOST_RAM = PHYSICAL_MEMORY_BYTES at the latest snapshot (empty: AWR has none).

COLUMN mem_mode      FORMAT A6          HEADING 'MODE'
COLUMN win_from      FORMAT A16         HEADING 'WINDOW_FROM'
COLUMN win_to        FORMAT A16         HEADING 'WINDOW_TO'
COLUMN latest_snap_id FORMAT 9999999990 HEADING 'LATEST_SNAP'
COLUMN sga_tgt_mb    FORMAT 99999990    HEADING 'SGA_TARGET'
COLUMN sga_max_mb    FORMAT 99999990    HEADING 'SGA_MAX'
COLUMN pga_tgt_mb    FORMAT 99999990    HEADING 'PGA_TARGET'
COLUMN pga_lim_mb    FORMAT 99999990    HEADING 'PGA_LIMIT'
COLUMN host_mb       FORMAT 99999990    HEADING 'HOST_RAM'

SELECT mem_mode,
       TO_CHAR(window_start, 'YYYY-MM-DD HH24:MI') AS win_from,
       TO_CHAR(window_end,   'YYYY-MM-DD HH24:MI') AS win_to,
       latest_snap_id,
       ROUND(sga_target_bytes / 1048576)          AS sga_tgt_mb,
       ROUND(sga_bytes / 1048576)                 AS sga_max_mb,
       ROUND(pga_target_bytes / 1048576)          AS pga_tgt_mb,
       ROUND(pga_limit_bytes / 1048576)           AS pga_lim_mb,
       ROUND(host_ram_bytes / 1048576)            AS host_mb
FROM   capm_inst
WHERE  dbid = &dm_dbid
  AND  instance_number = &dm_inst;

PROMPT
PROMPT    GRADE: UNDERSIZED needs the advisor (a gain at a larger size) and an observed symptom to
PROMPT    agree; PGA limit: a peak at &k_plim% of the limit. OVERSIZED needs advisor slack, no
PROMPT    pressure and &k_shrd sampled days. SUGGESTED is an advised size within a factor &k_step
PROMPT    of the current one (a floor for a buffer cache or shared pool under ASMM). HOST = Y: it
PROMPT    and the rest of the instance pass &k_host% of HOST_RAM (other instances unseen). SGA = Y:
PROMPT    the floor exceeds what both pools hold now. N_EV / N_PRESS = evidence lines (section 3)
PROMPT    and how many are PRESSURE. The second line of each row is the verdict and why.

COLUMN area_label      FORMAT A12      HEADING 'AREA'
COLUMN grade           FORMAT A21      HEADING 'GRADE'
COLUMN reason          FORMAT A19      HEADING 'REASON'
COLUMN current_size    FORMAT A9       HEADING 'CURRENT'
COLUMN suggested_size  FORMAT A9       HEADING 'SUGGESTED'
COLUMN change_pct      FORMAT S9990.0  HEADING 'CHANGE%'
COLUMN suggested_param FORMAT A20      HEADING 'PARAMETER'
COLUMN exceeds_host_ram FORMAT A4      HEADING 'HOST'
COLUMN exceeds_sga     FORMAT A3       HEADING 'SGA'
COLUMN n_evidence      FORMAT 9990     HEADING 'N_EV'
COLUMN n_pressure      FORMAT 9999990  HEADING 'N_PRESS'
COLUMN n_days          FORMAT 9990     HEADING 'DAYS'
COLUMN v_text          FORMAT A190     HEADING 'VERDICT AND WHY' WORD_WRAPPED FOLD_BEFORE
COLUMN sug_sga NEW_VALUE dm_sug_sga NOPRINT
COLUMN sug_bc  NEW_VALUE dm_sug_bc  NOPRINT
COLUMN sug_sp  NEW_VALUE dm_sug_sp  NOPRINT
COLUMN sug_pga NEW_VALUE dm_sug_pga NOPRINT

-- The sug_ columns hand the suggested sizes to section 4 (NEW_VALUE keeps
-- the last row's value, and the analytic MAX is the same on every row), so
-- CAPM_VERDICT is evaluated once.
SELECT area_label,
       grade,
       reason,
       current_size,
       suggested_size,
       change_pct,
       suggested_param,
       exceeds_host_ram,
       exceeds_sga,
       n_evidence,
       n_pressure,
       n_days,
       headline || ' Why: ' || reason_text                                      AS v_text,
       NVL(TO_CHAR(MAX(CASE WHEN area = 'SGA_TOTAL'    THEN suggested_bytes END) OVER ()), 'NULL') AS sug_sga,
       NVL(TO_CHAR(MAX(CASE WHEN area = 'BUFFER_CACHE' THEN suggested_bytes END) OVER ()), 'NULL') AS sug_bc,
       NVL(TO_CHAR(MAX(CASE WHEN area = 'SHARED_POOL'  THEN suggested_bytes END) OVER ()), 'NULL') AS sug_sp,
       NVL(TO_CHAR(MAX(CASE WHEN area = 'PGA_TARGET'   THEN suggested_bytes END) OVER ()), 'NULL') AS sug_pga
FROM   capr_mem_verdict
WHERE  dbid = &dm_dbid
  AND  instance_number = &dm_inst
ORDER  BY rank_mem;

PROMPT
PROMPT == 2. THE STARTUPS OF THE WINDOW (CAPM_SNAP) ==
PROMPT    One row per instance startup with a snapshot in the window. Nothing is differenced
PROMPT    across a restart. FIRST / LAST_SNAP span the whole startup, IN_WIN counts its snapshots
PROMPT    inside the window, UPTIME_H = its last snapshot minus its startup time. USED: at least
PROMPT    &k_upt hours (mem_min_uptime_hours), its advisor increments count. SKIPPED: shorter, a
PROMPT    cold cache distorts the estimates, so it adds no advisor evidence; its symptoms (waits,
PROMPT    work area passes, reloads, PGA peaks) still count.

COLUMN st_time       FORMAT A16         HEADING 'STARTUP'
COLUMN first_snap    FORMAT 9999999990  HEADING 'FIRST_SNAP'
COLUMN last_snap     FORMAT 9999999990  HEADING 'LAST_SNAP'
COLUMN first_end     FORMAT A16         HEADING 'FIRST_END'
COLUMN last_end      FORMAT A16         HEADING 'LAST_END'
COLUMN n_snaps       FORMAT 99990       HEADING 'SNAPS'
COLUMN n_in_win      FORMAT 99990       HEADING 'IN_WIN'
COLUMN uptime_h      FORMAT 9999990.0   HEADING 'UPTIME_H'
COLUMN seg_use       FORMAT A7          HEADING 'USE'

SELECT TO_CHAR(MAX(startup_dt), 'YYYY-MM-DD HH24:MI')            AS st_time,
       MIN(snap_id)                                             AS first_snap,
       MAX(snap_id)                                             AS last_snap,
       TO_CHAR(MIN(end_time), 'YYYY-MM-DD HH24:MI')             AS first_end,
       TO_CHAR(MAX(end_time), 'YYYY-MM-DD HH24:MI')             AS last_end,
       COUNT(*)                                                 AS n_snaps,
       COUNT(CASE WHEN in_win = 'Y' THEN 1 END)                 AS n_in_win,
       MAX(uptime_hours)                                        AS uptime_h,
       CASE MAX(seg_ok) WHEN 'Y' THEN 'USED' ELSE 'SKIPPED' END AS seg_use
FROM   capm_snap
WHERE  dbid = &dm_dbid
  AND  instance_number = &dm_inst
GROUP  BY startup_time
HAVING COUNT(CASE WHEN in_win = 'Y' THEN 1 END) > 0
ORDER  BY MIN(snap_id);

PROMPT
PROMPT == 3. EVERY EVIDENCE LINE (CAPR_MEM_EVIDENCE over CAPM_EVIDENCE) ==
PROMPT    KIND: USAGE (PGA against the limit), ADVISOR (an estimate at another size), SYMPTOM
PROMPT    (pressure observed in the window), CONTEXT (shown, never decides the grade).
PROMPT    DIRECTION: PRESSURE / SLACK / NEUTRAL, VALUE against THRESHOLD in UNIT. OBSERVED = when
PROMPT    the value was taken (a peak, a minimum) or the window's end for a window total.

COLUMN kind            FORMAT A7          HEADING 'KIND'
COLUMN signal          FORMAT A33         HEADING 'SIGNAL'
COLUMN direction       FORMAT A9          HEADING 'DIRECTION'
COLUMN value           FORMAT 99999990.99 HEADING 'VALUE'
COLUMN unit            FORMAT A7          HEADING 'UNIT'
COLUMN threshold       FORMAT 9999990.99  HEADING 'THRESHOLD'
COLUMN observed        FORMAT A16         HEADING 'OBSERVED'
COLUMN evidence_text   FORMAT A190        HEADING 'SENTENCE' WORD_WRAPPED FOLD_BEFORE

SELECT area_label,
       kind,
       signal,
       direction,
       value,
       unit,
       threshold,
       TO_CHAR(observed_at, 'YYYY-MM-DD HH24:MI') AS observed,
       evidence_text
FROM   capr_mem_evidence
WHERE  dbid = &dm_dbid
  AND  instance_number = &dm_inst
ORDER  BY rank_ev;

PROMPT
PROMPT == 4. ADVISOR CURVES (CAPM_ADVICE) ==
PROMPT    Every size the advisor lists at the latest snapshot (and, under a REFERENCE fallback,
PROMPT    every size it listed in the window), in MiB. FACTOR = the advisor's size factor (empty:
PROMPT    off the latest list). CURRENT = factor 1. REFERENCE = the size gains are measured
PROMPT    against: the current size when it has &k_upt hours of history, else the nearest size
PROMPT    within &k_tol% of it that has (none: the advisor is too thin to judge).
PROMPT    Every size is compared over the reference size's intervals in the window (USED startups
PROMPT    only): COVER_H / N_IVL / DAYS. Where an interval lists no row for a size, the largest
PROMPT    listed size below it stands in (understates a gain, overstates a loss).
PROMPT    REL_COST = the size's summed cost / the reference's (physical read time, library cache
PROMPT    load time, DB time; PGA: extra bytes read and written). GAIN against the reference,
PROMPT    negative for a loss: DBTIME_PCT = percent of the instance's DB time, HIT_PTS = PGA cache
PROMPT    hit points (HIT% = the size's estimated cache hit). OVERALLOC = PGA over-allocations.
PROMPT    CAND = Y: a candidate, within a factor &k_step of the current size, covering every
PROMPT    reference interval. Grow: gain >= &k_gain% of DB time (PGA &k_pgain points); the
PROMPT    suggestion is the smallest candidate with &k_knee% of the best gain (PGA: and no
PROMPT    over-allocation). Shrink: the smallest candidate losing <= &k_shr% (PGA &k_pshr points).

COLUMN size_mb      FORMAT 99999990    HEADING 'SIZE_MB'
COLUMN size_factor  FORMAT 990.0000    HEADING 'FACTOR'
COLUMN cover_hours  FORMAT 9999990.0   HEADING 'COVER_H'
COLUMN n_intervals  FORMAT 999990      HEADING 'N_IVL'
COLUMN a_days       FORMAT 9990        HEADING 'DAYS'
COLUMN rel_cost     FORMAT 990.0000    HEADING 'REL_COST'
COLUMN gain         FORMAT S99990.000  HEADING 'GAIN'
COLUMN gain_unit    FORMAT A10         HEADING 'UNIT'
COLUMN est_hit_pct  FORMAT 990.00      HEADING 'HIT%'
COLUMN overalloc    FORMAT 99999990    HEADING 'OVERALLOC'
COLUMN is_candidate FORMAT A4          HEADING 'CAND'
COLUMN mark         FORMAT A30         HEADING 'MARK'

SELECT l.area_label,
       ROUND(v.size_bytes / 1048576)  AS size_mb,
       v.size_factor,
       v.cover_hours,
       v.n_intervals,
       v.n_days                       AS a_days,
       v.rel_cost,
       v.gain,
       v.gain_unit,
       v.est_hit_pct,
       v.overalloc,
       v.is_candidate,
       LTRIM(CASE WHEN v.is_current = 'Y' THEN ' CURRENT' END
             || CASE WHEN v.size_bytes = v.reference_bytes THEN ' REFERENCE' END
             || CASE WHEN v.size_bytes = CASE v.area WHEN 'SGA_TOTAL'    THEN &dm_sug_sga
                                                     WHEN 'BUFFER_CACHE' THEN &dm_sug_bc
                                                     WHEN 'SHARED_POOL'  THEN &dm_sug_sp
                                                     WHEN 'PGA_TARGET'   THEN &dm_sug_pga END
                     THEN ' SUGGESTED' END) AS mark
FROM   capm_advice v
JOIN   capr_mem_area l
  ON   l.area = v.area
WHERE  v.dbid = &dm_dbid
  AND  v.instance_number = &dm_inst
ORDER  BY l.area_rank, v.size_bytes;

PROMPT
PROMPT == 5. RESIZE ACTIVITY (CAPM_COMP, then CAPR_MEM_COMPONENTS) ==
PROMPT    The snapshot intervals of the window in which an SGA component changed size or the
PROMPT    instance counted resize operations on it. BEFORE / AFTER / NET in MiB; OPS = operations
PROMPT    in the interval; LAST_OP / MODE = the type and mode of the component's last operation
PROMPT    (IMMEDIATE = forced, to avoid an allocation failure). No row: nothing was resized.

COLUMN c_time      FORMAT A16        HEADING 'INTERVAL_END'
COLUMN component   FORMAT A28        HEADING 'COMPONENT'
COLUMN before_mb   FORMAT 99999990   HEADING 'BEFORE'
COLUMN after_mb    FORMAT 99999990   HEADING 'AFTER'
COLUMN net_mb      FORMAT S9999990   HEADING 'NET'
COLUMN ops         FORMAT 99990      HEADING 'OPS'
COLUMN last_oper_type FORMAT A13     HEADING 'LAST_OP'
COLUMN last_oper_mode FORMAT A9      HEADING 'MODE'

SELECT TO_CHAR(end_time, 'YYYY-MM-DD HH24:MI')    AS c_time,
       component,
       ROUND((current_size - net) / 1048576)      AS before_mb,
       ROUND(current_size / 1048576)              AS after_mb,
       ROUND(net / 1048576)                       AS net_mb,
       ops,
       last_oper_type,
       last_oper_mode
FROM   capm_comp
WHERE  dbid = &dm_dbid
  AND  instance_number = &dm_inst
  AND  in_win = 'Y'
  AND  (net <> 0 OR ops > 0)
ORDER  BY snap_id, component;

PROMPT
PROMPT    Component summary: sizes in MiB (CURRENT at the latest snapshot, MIN / MAX over the
PROMPT    window), PCT of the listed components, OPS, intervals that GREW / SHRANK, FORCED grows.

COLUMN cur_mb          FORMAT 9999990  HEADING 'CURRENT'
COLUMN min_mb          FORMAT 9999990  HEADING 'MIN'
COLUMN max_mb          FORMAT 9999990  HEADING 'MAX'
COLUMN pct_of_total    FORMAT 990.0    HEADING 'PCT'
COLUMN n_ops           FORMAT 999990   HEADING 'OPS'
COLUMN n_grows         FORMAT 99990    HEADING 'GROWS'
COLUMN n_shrinks       FORMAT 9999990  HEADING 'SHRINKS'
COLUMN n_forced_grows  FORMAT 999990   HEADING 'FORCED'
COLUMN last_resize     FORMAT A16      HEADING 'LAST_RESIZE'

SELECT component,
       ROUND(current_bytes / 1048576)                 AS cur_mb,
       ROUND(min_bytes / 1048576)                     AS min_mb,
       ROUND(max_bytes / 1048576)                     AS max_mb,
       pct_of_total,
       n_ops,
       n_grows,
       n_shrinks,
       n_forced_grows,
       TO_CHAR(last_resize_at, 'YYYY-MM-DD HH24:MI')  AS last_resize
FROM   capr_mem_components
WHERE  dbid = &dm_dbid
  AND  instance_number = &dm_inst
ORDER  BY rank_comp;

PROMPT
PROMPT ================================================================================
PROMPT  End of drill-down -- read-only run, no database objects created or modified.
PROMPT ================================================================================

SPOOL OFF

-- The run's scope ends with it.
EXEC DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL)

PROMPT
PROMPT Drill-down written to: &cap_path
PROMPT

UNDEFINE cap_arg_db
UNDEFINE cap_arg_con
UNDEFINE dm_arg_inst
UNDEFINE dm_dbid
UNDEFINE dm_dbs
UNDEFINE dm_inst
UNDEFINE dm_insts
UNDEFINE dm_inst_ok
UNDEFINE dm_sug_sga
UNDEFINE dm_sug_bc
UNDEFINE dm_sug_sp
UNDEFINE dm_sug_pga
UNDEFINE cap_path
UNDEFINE k_win
UNDEFINE k_upt
UNDEFINE k_shrd
UNDEFINE k_step
UNDEFINE k_tol
UNDEFINE k_knee
UNDEFINE k_gain
UNDEFINE k_shr
UNDEFINE k_pgain
UNDEFINE k_pshr
UNDEFINE k_plim
UNDEFINE k_host
CLEAR COLUMNS
