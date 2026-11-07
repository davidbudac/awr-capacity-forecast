--
-- report/report_html.sql -- read-only, self-contained HTML capacity report.
-- =====================================================================
-- One section per monitored metric (tablespaces, database size, host CPU,
-- DB CPU, sessions, processes, redo, undo, temp, ASM), one card per series,
-- and a chart on every card whether or not anything is wrong.
--
-- The SQL here only READS the CAPR point feeds (the APEX contract views:
-- CAPR_FIT, CAPR_SERIES_POINTS, CAPR_FORECAST_POINTS, CAPR_ANOMALIES,
-- CAPR_ALERTS, CAPR_CONTAINER, plus CAPR_HOURLY_POINTS) and writes them into
-- the page as one JSON block. report/html/report.js draws the page from that
-- block. The page skeleton, the CSS and the renderer come from the generated
-- report/html/page_head.sql and report/html/page_tail.sql: edit
-- report/html/report.css / report.js and run `python3 report/html/build.py`,
-- never the generated files.
--
-- Run from the REPO ROOT so the @@ includes resolve (SQL*Plus @@ is relative
-- to the outermost caller's directory on 19c):
--   SQL> @report/report_html.sql              -- defaults from report/defaults.sql
--   SQL> @report/report_html.sql 25 60 Y      -- top_n / anomaly_days / show_esm
--   SQL> @report/report_html.sql - - - 42424242 42424243   -- one container
--   SQL> @report/report_html.sql - - - - - SNAPSHOT        -- from the last refresh run
-- top_n = full cards per section (the rest are compact rows, still charted),
-- anomaly_days = the window of the anomaly lists, show_esm AUTO | Y | N =
-- the Tier 2 ESM point on the charts. [dbid] [con_dbid] scope every block,
-- and dbid may also be a target name (report/scope.sql).
-- SNAPSHOT reads the fits from CAPR_FIT_HISTORY and the alerts from
-- CAPR_ALERTS_LATEST of the newest OK refresh run.
--
-- Each data block is read inside its own exception handler: a failing view
-- leaves its block empty, and the page names the failed block.
--
SET DEFINE '&'
SET VERIFY     OFF
SET FEEDBACK   OFF
SET ECHO       OFF
SET TERMOUT    OFF
SET TRIMSPOOL  ON
SET LINESIZE   32767
SET PAGESIZE   0
SET LONG       1000000
SET NEWPAGE    NONE
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR CONTINUE

ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';

@@report/defaults.sql

-- An unpassed &1..&6 becomes empty instead of prompting (zero-row NEW_VALUE).
COLUMN 1 NEW_VALUE 1 NOPRINT
COLUMN 2 NEW_VALUE 2 NOPRINT
COLUMN 3 NEW_VALUE 3 NOPRINT
COLUMN 4 NEW_VALUE 4 NOPRINT
COLUMN 5 NEW_VALUE 5 NOPRINT
COLUMN 6 NEW_VALUE 6 NOPRINT
SELECT NULL AS "1", NULL AS "2", NULL AS "3",
       NULL AS "4", NULL AS "5", NULL AS "6" FROM dual WHERE 1 = 0;

COLUMN eff_top_n NEW_VALUE top_n        NOPRINT
COLUMN eff_anom  NEW_VALUE anomaly_days NOPRINT
COLUMN eff_esm   NEW_VALUE show_esm     NOPRINT
SELECT NVL(NULLIF(TRIM('&1'), '-'), '&top_n')                  AS eff_top_n,
       NVL(NULLIF(TRIM('&2'), '-'), '&anomaly_days')           AS eff_anom,
       NVL(NULLIF(UPPER(TRIM('&3')), '-'), UPPER('&show_esm')) AS eff_esm
FROM   dual;

-- Scope and identity: cap_sdbid / cap_scon, cap_db / cap_host / cap_user /
-- cap_gen and the file stem (report/scope.sql). '-' = an omitted argument.
COLUMN cap_a1 NEW_VALUE cap_arg_db  NOPRINT
COLUMN cap_a2 NEW_VALUE cap_arg_con NOPRINT
SELECT NVL(TRIM('&4'), '-') AS cap_a1, NVL(TRIM('&5'), '-') AS cap_a2 FROM dual;
COLUMN cap_a1 CLEAR
COLUMN cap_a2 CLEAR
@@report/scope.sql

COLUMN eff_src   NEW_VALUE cap_src   NOPRINT
SELECT CASE WHEN UPPER(TRIM('&6')) = 'SNAPSHOT' THEN 'SNAPSHOT' ELSE 'LIVE' END AS eff_src
FROM   dual;

COLUMN cap_path NEW_VALUE cap_path NOPRINT
COLUMN cap_file NEW_VALUE cap_file NOPRINT
SELECT 'cap_report_' || '&cap_stem' || '_'
         || TO_CHAR(SYSDATE,'YYYYMMDDHH24MI') || '.html'                      AS cap_file,
       'reports/cap_report_' || '&cap_stem' || '_'
         || TO_CHAR(SYSDATE,'YYYYMMDDHH24MI') || '.html'                       AS cap_path
FROM   dual;

-- Knobs and identity into bind variables while substitution is still on;
-- the data block below runs with DEFINE OFF.
VARIABLE b_top_n        NUMBER
VARIABLE b_anomaly_days NUMBER
VARIABLE b_show_esm     VARCHAR2(10)
VARIABLE b_cap_db       VARCHAR2(400)
VARIABLE b_cap_host     VARCHAR2(400)
VARIABLE b_cap_user     VARCHAR2(400)
VARIABLE b_cap_gen      VARCHAR2(200)
VARIABLE b_cap_file     VARCHAR2(200)
VARIABLE b_sdbid        NUMBER
VARIABLE b_scon         NUMBER
VARIABLE b_src          VARCHAR2(10)
BEGIN
  :b_top_n        := &top_n;
  :b_anomaly_days := &anomaly_days;
  :b_show_esm     := UPPER('&show_esm');
  :b_cap_db       := '&cap_db';
  :b_cap_host     := '&cap_host';
  :b_cap_user     := '&cap_user';
  :b_cap_gen      := '&cap_gen';
  :b_cap_file     := '&cap_file';
  :b_sdbid        := &cap_sdbid;
  :b_scon         := &cap_scon;
  :b_src          := '&cap_src';
END;
/

-- reports/ is gitignored, so a fresh clone does not have it.
HOST mkdir -p reports
SPOOL &cap_path

SET DEFINE OFF
@@report/html/page_head.sql

DECLARE
  top_n        PLS_INTEGER  := :b_top_n;
  anomaly_days PLS_INTEGER  := :b_anomaly_days;
  show_esm     VARCHAR2(10) := :b_show_esm;
  s_dbid       NUMBER       := :b_sdbid;
  s_con        NUMBER       := :b_scon;
  v_src        VARCHAR2(10) := :b_src;
  v_snap_run   NUMBER;
  v_last_day   DATE;
  v_first_day  DATE;
  v_esm_ok     NUMBER := 0;
  v_esm_failed NUMBER := 0;
  v_esm_stale  NUMBER := 0;
  v_do_esm     NUMBER;

  -- A block's JSON is buffered and printed only when the block finished,
  -- so a failing view cannot leave half an array in the page.
  TYPE line_tab IS TABLE OF VARCHAR2(32767) INDEX BY PLS_INTEGER;
  buf     line_tab;
  cur     VARCHAR2(32767);
  v_errs  VARCHAR2(32767);
  v_sep   VARCHAR2(1);
  v_tlog  VARCHAR2(4000);
  v_t     PLS_INTEGER := DBMS_UTILITY.GET_TIME;

  PROCEDURE p(s IN VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(s);
  END p;

  PROCEDURE w(s IN VARCHAR2) IS
  BEGIN
    IF LENGTH(cur) + LENGTH(s) > 8000 THEN
      buf(buf.COUNT + 1) := cur;
      cur := NULL;
    END IF;
    cur := cur || s;
  END w;

  PROCEDURE lap(name IN VARCHAR2) IS
  BEGIN
    v_tlog := v_tlog || CASE WHEN v_tlog IS NOT NULL THEN ',' END
              || '"' || name || '":' || TO_CHAR((DBMS_UTILITY.GET_TIME - v_t) / 100, 'FM99990.00');
    v_t := DBMS_UTILITY.GET_TIME;
  END lap;

  PROCEDURE flush_block(name IN VARCHAR2) IS
  BEGIN
    lap(name);
    IF cur IS NOT NULL THEN buf(buf.COUNT + 1) := cur; END IF;
    p(',"' || name || '":');
    FOR i IN 1 .. buf.COUNT LOOP p(buf(i)); END LOOP;
    buf.DELETE;
    cur := NULL;
  END flush_block;

  PROCEDURE fail_block(name IN VARCHAR2, msg IN VARCHAR2) IS
  BEGIN
    lap(name);
    buf.DELETE;
    cur := NULL;
    p(',"' || name || '":[]');
    v_errs := v_errs || CASE WHEN v_errs IS NOT NULL THEN ',' END
              || '{"block":"' || name || '","msg":"'
              || REPLACE(REPLACE(REPLACE(SUBSTR(msg, 1, 400), '\', '\\'), '"', '\"'), CHR(10), ' ') || '"}';
  END fail_block;

  FUNCTION js(s IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF s IS NULL THEN RETURN 'null'; END IF;
    -- ASCIISTR turns every non-ASCII character and the backslash into \XXXX,
    -- which becomes the JSON escape \uXXXX: the spool stays ASCII whatever
    -- the client character set is.
    RETURN '"' || REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(ASCIISTR(s),
             '\', '\u'), '"', '\"'), CHR(10), '\n'), CHR(13), ''), CHR(9), ' '), '</', '<\/') || '"';
  END js;

  FUNCTION jn(n IN NUMBER) RETURN VARCHAR2 IS
    v VARCHAR2(80);
  BEGIN
    IF n IS NULL THEN RETURN 'null'; END IF;
    v := TO_CHAR(CASE WHEN ABS(n) >= 1000 THEN ROUND(n, 1) ELSE ROUND(n, 4) END, 'TM9');
    IF SUBSTR(v, 1, 1) = '.' THEN v := '0' || v;
    ELSIF SUBSTR(v, 1, 2) = '-.' THEN v := '-0' || SUBSTR(v, 2);
    END IF;
    RETURN v;
  END jn;

  FUNCTION jd(d IN DATE) RETURN VARCHAR2 IS
  BEGIN
    IF d IS NULL THEN RETURN 'null'; END IF;
    RETURN '"' || TO_CHAR(d, 'YYYY-MM-DD') || '"';
  END jd;

  FUNCTION jt(d IN DATE) RETURN VARCHAR2 IS
  BEGIN
    IF d IS NULL THEN RETURN 'null'; END IF;
    RETURN '"' || TO_CHAR(d, 'YYYY-MM-DD"T"HH24:MI') || '"';
  END jt;

  FUNCTION in_scope(p_dbid IN NUMBER, p_con IN NUMBER) RETURN BOOLEAN IS
  BEGIN
    RETURN (s_dbid IS NULL OR p_dbid = s_dbid) AND (s_con IS NULL OR p_con = s_con);
  END in_scope;
BEGIN
  p('<script type="application/json" id="cap-data">');

  ----------------------------------------------------------------------
  -- meta: identity, knobs, data window, Tier 2 health, refresh run.
  ----------------------------------------------------------------------
  DECLARE
    v_run_line VARCHAR2(4000);
    v_cov_line VARCHAR2(4000);
    v_src_lbl  VARCHAR2(400);
  BEGIN
    SELECT MAX(last_ok_run_id) INTO v_snap_run FROM capr_runs;
    SELECT MIN(day_dt), MAX(day_dt) INTO v_first_day, v_last_day
      FROM capd_series_daily
     WHERE (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con);
    IF v_last_day IS NULL THEN
      SELECT MIN(day_dt), MAX(day_dt) INTO v_first_day, v_last_day
        FROM capd_tbspc_daily
       WHERE (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con);
    END IF;
    BEGIN
      SELECT NVL(SUM(n_ok), 0), NVL(SUM(n_failed), 0), NVL(SUM(n_stale), 0)
        INTO v_esm_ok, v_esm_failed, v_esm_stale
        FROM capf_esm_health_summary;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    v_do_esm := CASE WHEN show_esm = 'N' THEN 0
                     WHEN show_esm = 'Y' THEN 1
                     WHEN v_esm_ok > 0 THEN 1 ELSE 0 END;
    SELECT NVL(MAX(CASE WHEN r.is_last = 'Y'
                        THEN r.summary || CASE WHEN r.stale_run = 'Y' THEN ' (stale)' END END),
               'no refresh run')
      INTO v_run_line
      FROM capr_runs r;
    IF v_src = 'SNAPSHOT' THEN
      v_src_lbl := 'SNAPSHOT, no OK refresh run yet';
      FOR r IN (SELECT run_id, started_at, as_of_day FROM capr_runs WHERE run_id = last_ok_run_id) LOOP
        v_src_lbl := 'SNAPSHOT run ' || r.run_id || ', ' || TO_CHAR(r.started_at, 'YYYY-MM-DD HH24:MI')
                     || ', as of ' || TO_CHAR(r.as_of_day, 'YYYY-MM-DD');
      END LOOP;
      SELECT MAX(cov_summary) INTO v_cov_line FROM capr_runs WHERE run_id = last_ok_run_id;
    ELSE
      v_src_lbl := 'LIVE';
      SELECT LISTAGG(summary, ' | ' ON OVERFLOW TRUNCATE) WITHIN GROUP (ORDER BY dbid)
        INTO v_cov_line
        FROM capr_coverage
       WHERE (s_dbid IS NULL OR dbid = s_dbid)
         AND (s_con IS NULL OR dbid IN (SELECT dbid FROM capr_container WHERE con_dbid = s_con));
    END IF;
    FOR c IN (SELECT * FROM cap_cfg) LOOP
      p('{"meta":{"db":' || js(:b_cap_db) || ',"host":' || js(:b_cap_host)
        || ',"schema":' || js(:b_cap_user) || ',"generated":' || js(:b_cap_gen)
        || ',"file":' || js(:b_cap_file) || ',"source":' || js(v_src_lbl)
        || ',"scopeDbid":' || jn(s_dbid) || ',"scopeCon":' || jn(s_con)
        || ',"firstDay":' || jd(v_first_day) || ',"lastDay":' || jd(v_last_day)
        || ',"run":' || js(v_run_line) || ',"coverage":' || js(v_cov_line)
        || ',"topN":' || jn(top_n) || ',"anomalyDays":' || jn(anomaly_days)
        || ',"esm":{"show":' || jn(v_do_esm) || ',"ok":' || jn(v_esm_ok)
        || ',"failed":' || jn(v_esm_failed) || ',"stale":' || jn(v_esm_stale) || '}'
        || ',"knobs":{"dtfWarn":' || jn(c.dtf_warn) || ',"dtfCrit":' || jn(c.dtf_crit)
        || ',"cpuSat":' || jn(c.cpu_sat_pct) || ',"nfWarn":' || jn(c.nearfull_warn_pct)
        || ',"nfCrit":' || jn(c.nearfull_crit_pct) || ',"trainDays":' || jn(c.train_days)
        || ',"seriesSat":' || jn(c.series_sat_pct) || ',"cpuSatOnP95":' || jn(c.cpu_sat_on_p95)
        || ',"suiteVersion":' || js(TO_CHAR(c.suite_version)) || '}}');
    END LOOP;
  EXCEPTION
    WHEN OTHERS THEN
      p('{"meta":{"db":' || js(:b_cap_db) || ',"host":' || js(:b_cap_host)
        || ',"schema":' || js(:b_cap_user) || ',"generated":' || js(:b_cap_gen)
        || ',"file":' || js(:b_cap_file) || ',"lastDay":' || jd(v_last_day) || ',"knobs":{},"esm":{}}');
      v_errs := '{"block":"meta","msg":' || js(SQLERRM) || '}';
  END;
  lap('meta');

  ----------------------------------------------------------------------
  -- containers: dbid / con_dbid -> labels; "db" is the target name.
  ----------------------------------------------------------------------
  BEGIN
    v_sep := NULL;
    w('[');
    FOR r IN (SELECT dbid, con_dbid, NVL(target_name, db_name) AS db_name, con_name, db_pdb
              FROM capr_container ORDER BY dbid, con_dbid) LOOP
      IF in_scope(r.dbid, r.con_dbid) THEN
        w(v_sep || '{"dbid":' || jn(r.dbid) || ',"con":' || jn(r.con_dbid) || ',"db":' || js(r.db_name)
          || ',"pdb":' || js(r.con_name) || ',"label":' || js(r.db_pdb) || '}');
        v_sep := ',';
      END IF;
    END LOOP;
    w(']');
    flush_block('containers');
  EXCEPTION WHEN OTHERS THEN fail_block('containers', SQLERRM);
  END;

  ----------------------------------------------------------------------
  -- fits: one row per (kind, container, series, method). LIVE = CAPR_FIT,
  -- SNAPSHOT = the CAPR_FIT_HISTORY rows of the newest OK refresh run.
  ----------------------------------------------------------------------
  BEGIN
    v_sep := NULL;
    w('[');
    FOR r IN (SELECT kind, dbid, con_dbid, series, unit, method, value, limit_value, pct, slope_per_day,
                     r2, quality, days_to_full, days_to_full_lo, days_to_full_hi, accel, train_n, sev,
                     limit_source, last_day, is_current, limit_below_used, cycle_n, cycle_days,
                     cycle_peak_pct, peak_slope_per_day, slope_sig, hot_now, need_gib_90, add_by_day
              FROM   capr_fit WHERE v_src = 'LIVE'
              UNION ALL
              SELECT kind, dbid, con_dbid, series, unit, method, value, limit_value, pct, slope_per_day,
                     r2, quality, days_to_full, days_to_full_lo, days_to_full_hi, accel, train_n, sev,
                     limit_source, last_day, is_current, limit_below_used, cycle_n, cycle_days,
                     cycle_peak_pct, peak_slope_per_day, slope_sig, hot_now, need_gib_90, add_by_day
              FROM   capr_fit_history WHERE v_src = 'SNAPSHOT' AND run_id = v_snap_run
              ORDER  BY 1, 2, 3, 4, 6) LOOP
      IF in_scope(r.dbid, r.con_dbid) THEN
        w(v_sep || '{"k":' || js(r.kind) || ',"dbid":' || jn(r.dbid) || ',"con":' || jn(r.con_dbid)
          || ',"s":' || js(r.series) || ',"u":' || js(r.unit) || ',"m":' || js(r.method)
          || ',"v":' || jn(r.value) || ',"lim":' || jn(r.limit_value) || ',"pct":' || jn(r.pct)
          || ',"slope":' || jn(r.slope_per_day) || ',"r2":' || jn(r.r2) || ',"q":' || js(r.quality)
          || ',"dtf":' || jn(r.days_to_full) || ',"dtfLo":' || jn(r.days_to_full_lo)
          || ',"dtfHi":' || jn(r.days_to_full_hi) || ',"accel":' || jn(r.accel) || ',"n":' || jn(r.train_n)
          || ',"sev":' || js(r.sev) || ',"limSrc":' || js(r.limit_source) || ',"last":' || jd(r.last_day)
          || ',"cur":' || jn(r.is_current) || ',"below":' || jn(r.limit_below_used)
          || ',"cycN":' || jn(r.cycle_n) || ',"cycD":' || jn(r.cycle_days) || ',"cycPk":' || jn(r.cycle_peak_pct)
          || ',"pkSlope":' || jn(r.peak_slope_per_day) || ',"sig":' || jn(r.slope_sig)
          || ',"hot":' || jn(r.hot_now) || ',"need90":' || jn(r.need_gib_90) || ',"addBy":' || jd(r.add_by_day) || '}');
        v_sep := ',';
      END IF;
    END LOOP;
    w(']');
    flush_block('fits');
  EXCEPTION WHEN OTHERS THEN fail_block('fits', SQLERRM);
  END;

  ----------------------------------------------------------------------
  -- points: the daily history of every charted series, one object per
  -- series: t0 + [day offset, value, limit, anomaly (1 high, -1 low,
  -- 0 scored, null unscored), gap].
  ----------------------------------------------------------------------
  DECLARE
    v_key VARCHAR2(400);
    v_t0  DATE;
  BEGIN
    v_sep := NULL;
    w('[');
    FOR r IN (SELECT kind, dbid, con_dbid, series, ts, value, limit_value, anomaly, anomaly_flag, gap
              FROM   capr_series_points
              WHERE  series <> 'DB_CPU_SEC'
                AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
              ORDER  BY kind, dbid, con_dbid, series, ts) LOOP
      IF v_key IS NULL OR v_key <> r.kind || '|' || r.dbid || '|' || r.con_dbid || '|' || r.series THEN
        IF v_key IS NOT NULL THEN w(']}'); END IF;
        v_key := r.kind || '|' || r.dbid || '|' || r.con_dbid || '|' || r.series;
        v_t0  := TRUNC(r.ts);
        w(v_sep || CHR(10) || '{"k":' || js(r.kind) || ',"dbid":' || jn(r.dbid) || ',"con":' || jn(r.con_dbid)
          || ',"s":' || js(r.series) || ',"t0":' || jd(v_t0) || ',"d":[');
        v_sep := ',';
      ELSE
        w(',');
      END IF;
      w('[' || jn(TRUNC(r.ts) - v_t0) || ',' || jn(r.value) || ',' || jn(r.limit_value) || ','
        || CASE WHEN r.anomaly = 1 THEN CASE WHEN r.anomaly_flag = 'LOW' THEN '-1' ELSE '1' END
                WHEN r.anomaly = 0 THEN '0' ELSE 'null' END
        || ',' || NVL(TO_CHAR(r.gap), '0') || ']');
    END LOOP;
    IF v_key IS NOT NULL THEN w(']}'); END IF;
    w(']');
    flush_block('points');
  EXCEPTION WHEN OTHERS THEN fail_block('points', SQLERRM);
  END;

  ----------------------------------------------------------------------
  -- forecast: the projection knots (REGR at horizon 0 / 30 / 90 / ...,
  -- the ESM point when shown), value + 95% band.
  ----------------------------------------------------------------------
  BEGIN
    v_sep := NULL;
    w('[');
    FOR r IN (SELECT kind, dbid, con_dbid, series, method, horizon_days, ts, value, lo, hi
              FROM   capr_forecast_points
              WHERE  (method <> 'ESM' OR v_do_esm = 1)
                AND  series <> 'DB_CPU_SEC'
                AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
              ORDER  BY kind, dbid, con_dbid, series, method, horizon_days) LOOP
      w(v_sep || '{"k":' || js(r.kind) || ',"dbid":' || jn(r.dbid) || ',"con":' || jn(r.con_dbid)
        || ',"s":' || js(r.series) || ',"m":' || js(r.method) || ',"h":' || jn(r.horizon_days)
        || ',"t":' || jd(r.ts) || ',"v":' || jn(r.value) || ',"lo":' || jn(r.lo) || ',"hi":' || jn(r.hi) || '}');
      v_sep := ',';
    END LOOP;
    w(']');
    flush_block('forecast');
  EXCEPTION WHEN OTHERS THEN fail_block('forecast', SQLERRM);
  END;

  ----------------------------------------------------------------------
  -- anomalies: every flagged (observation, baseline mode) inside the
  -- anomaly window, plus the level shifts.
  ----------------------------------------------------------------------
  BEGIN
    v_sep := NULL;
    w('[');
    FOR r IN (SELECT kind, dbid, con_dbid, series, ts, anomaly_kind, anomaly_flag, value, expected,
                     threshold, z, shift_pct, unit, sev, baseline_mode, grain, n_hist, alerting, raw_value,
                     pct_vs_expected
              FROM   capr_anomalies
              WHERE  (ts > v_last_day - anomaly_days OR anomaly_kind = 'CPU_SHIFT')
                AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
              ORDER  BY kind, dbid, con_dbid, series, ts, baseline_mode) LOOP
      w(v_sep || CHR(10) || '{"k":' || js(r.kind) || ',"dbid":' || jn(r.dbid) || ',"con":' || jn(r.con_dbid)
        || ',"s":' || js(r.series) || ',"ts":' || jt(r.ts) || ',"ak":' || js(r.anomaly_kind)
        || ',"f":' || js(r.anomaly_flag) || ',"v":' || jn(r.value) || ',"e":' || jn(r.expected)
        || ',"thr":' || jn(r.threshold) || ',"z":' || jn(r.z) || ',"shift":' || jn(r.shift_pct)
        || ',"u":' || js(r.unit) || ',"sev":' || js(r.sev) || ',"mode":' || js(r.baseline_mode)
        || ',"grain":' || js(r.grain) || ',"nh":' || jn(r.n_hist) || ',"al":' || js(r.alerting)
        || ',"raw":' || jn(r.raw_value) || ',"pctE":' || jn(r.pct_vs_expected) || '}');
      v_sep := ',';
    END LOOP;
    w(']');
    flush_block('anomalies');
  EXCEPTION WHEN OTHERS THEN fail_block('anomalies', SQLERRM);
  END;

  ----------------------------------------------------------------------
  -- alerts: CAPR_ALERTS (LIVE) or CAPR_ALERTS_LATEST (SNAPSHOT).
  ----------------------------------------------------------------------
  BEGIN
    v_sep := NULL;
    w('[');
    FOR r IN (SELECT severity, sev_rank, kind, dbid, con_dbid, series_key, day_dt, value, threshold, unit,
                     message, baseline_mode, first_day, n_days, max_z
              FROM   capr_alerts WHERE v_src = 'LIVE'
              UNION ALL
              SELECT severity, sev_rank, kind, dbid, con_dbid, series_key, day_dt, value, threshold, unit,
                     message, baseline_mode, NULL, NULL, NULL
              FROM   capr_alerts_latest WHERE v_src = 'SNAPSHOT'
              ORDER  BY 2, 3, 4, 5, 6, 7) LOOP
      IF in_scope(r.dbid, r.con_dbid) THEN
        w(v_sep || CHR(10) || '{"sev":' || js(r.severity) || ',"kind":' || js(r.kind)
          || ',"dbid":' || jn(r.dbid) || ',"con":' || jn(r.con_dbid) || ',"s":' || js(r.series_key)
          || ',"day":' || jd(r.day_dt) || ',"v":' || jn(r.value) || ',"thr":' || jn(r.threshold)
          || ',"u":' || js(r.unit) || ',"mode":' || js(r.baseline_mode) || ',"first":' || jd(r.first_day)
          || ',"n":' || jn(r.n_days) || ',"maxz":' || jn(r.max_z) || ',"msg":' || js(r.message) || '}');
        v_sep := ',';
      END IF;
    END LOOP;
    w(']');
    flush_block('alerts');
  EXCEPTION WHEN OTHERS THEN fail_block('alerts', SQLERRM);
  END;

  ----------------------------------------------------------------------
  -- hours: the last 14 days of hourly CPU (host busy, DB CPU per
  -- container) for the hour heat strips: [day offset, END hour 1..24,
  -- value, HOUR_OF_WEEK flag, gap]. A bucket labelled 00:00 is hour 24 of
  -- the day before (its day_dt).
  ----------------------------------------------------------------------
  DECLARE
    v_key VARCHAR2(400);
    v_t0  DATE := TRUNC(v_last_day) - 13;
  BEGIN
    v_sep := NULL;
    w('[');
    FOR r IN (SELECT dbid, con_dbid, series, ts, day_dt, value, gap, how_flag
              FROM   capr_hourly_points
              WHERE  day_dt >= TRUNC(v_last_day) - 13
                AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
              ORDER  BY dbid, con_dbid, series, ts) LOOP
      IF v_key IS NULL OR v_key <> r.dbid || '|' || r.con_dbid || '|' || r.series THEN
        IF v_key IS NOT NULL THEN w(']}'); END IF;
        v_key := r.dbid || '|' || r.con_dbid || '|' || r.series;
        w(v_sep || CHR(10) || '{"dbid":' || jn(r.dbid) || ',"con":' || jn(r.con_dbid)
          || ',"s":' || js(r.series) || ',"t0":' || jd(v_t0) || ',"d":[');
        v_sep := ',';
      ELSE
        w(',');
      END IF;
      w('[' || jn(r.day_dt - v_t0) || ',' || jn(ROUND((r.ts - r.day_dt) * 24)) || ',' || jn(r.value) || ','
        || CASE r.how_flag WHEN 'HIGH' THEN '1' WHEN 'LOW' THEN '-1' ELSE '0' END
        || ',' || NVL(TO_CHAR(r.gap), '0') || ']');
    END LOOP;
    IF v_key IS NOT NULL THEN w(']}'); END IF;
    w(']');
    flush_block('hours');
  EXCEPTION WHEN OTHERS THEN fail_block('hours', SQLERRM);
  END;

  p(',"errors":[' || v_errs || '],"seconds":{' || v_tlog || '}}');
  p('</script>');
END;
/

@@report/html/page_tail.sql
SPOOL OFF

SET DEFINE '&'
SET TERMOUT ON

-- Positional arguments stay DEFINEd for the rest of the session; drop them
-- so a following report run without arguments does not inherit this one's.
UNDEFINE 1
UNDEFINE 2
UNDEFINE 3
UNDEFINE 4
UNDEFINE 5
UNDEFINE 6
PROMPT
PROMPT Report written to: &cap_path
PROMPT
