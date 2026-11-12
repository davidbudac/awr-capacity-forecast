--
-- test/run_test.sql -- deterministic assertions over the fixture install.
-- =====================================================================
-- Runs the CAPD_/CAPF_/CAPA_ analytics against the CAP_FIXTURE_* data and
-- checks every result against the closed forms recorded in CAP_FIXTURE_META.
-- Prints PASS/FAIL per check; exits NON-ZERO if any check fails (CI-able via
-- WHENEVER SQLERROR EXIT FAILURE + a final RAISE).
--
-- Prereqs (same schema): test/fixture_install.sql, then @install.sql with
-- deploy_mode=fixture. The Tier 2 ESM assertion lives in run_test_ml.sql
-- (separate, because it needs CREATE MINING MODEL).
--
SET APPINFO OFF
SET APPINFO "AWRCAP/test/run_test.sql"
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF VERIFY OFF LINES 200 PAGES 0
WHENEVER SQLERROR EXIT FAILURE

-- CAP_FIXTURE_ALERTS_SNAP: CAPR_ALERTS copied once per stretch of reads with
-- no knob, data or block boundary between them (snap_alerts), so those reads
-- scan a table instead of evaluating the whole view chain each time. A
-- test-owned table like every CAP_FIXTURE_ one; test/fixture_remove.sql
-- drops it.
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE cap_fixture_alerts_snap PURGE';
EXCEPTION
    WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF;
END;
/
CREATE TABLE cap_fixture_alerts_snap AS SELECT * FROM capr_alerts WHERE 1 = 0;

-- The assertions expect an empty Tier 2 registry: CAP_ML_MODEL survives a
-- re-install, so models left by an earlier --ml run go stale and add
-- MODEL_HEALTH alerts. run_test_ml.sql trains its own afterwards.
BEGIN
    cap_forecast_ml.drop_all;
END;
/

DECLARE
    g_pass  PLS_INTEGER := 0;
    g_fail  PLS_INTEGER := 0;

    v_dbid  NUMBER;
    d_spike DATE; d_restart DATE; d_inj DATE; d_probe DATE;
    d_purge DATE; d_reset DATE; d_tstart DATE;
    d_rsd   DATE;                -- a reset_day read (d_purge stays the FIX_PURGE day)
    n_slope NUMBER; n_dtf NUMBER;

    v_n     PLS_INTEGER;
    v_num   NUMBER;
    v_num2  NUMBER;
    v_num3  NUMBER;
    v_str   VARCHAR2(40);
    v_str2  VARCHAR2(40);
    v_c1    VARCHAR2(1);
    v_msg   VARCHAR2(4000);
    v_r2    NUMBER;
    meta_last_day DATE;
    -- meta_n() cannot be called inside SQL (PLS-00231): these carry the
    -- values the new forecast assertions use in WHERE / SET clauses.
    n_aux   NUMBER;

    FUNCTION meta_n(p VARCHAR2) RETURN NUMBER IS x NUMBER;
    BEGIN SELECT nval INTO x FROM cap_fixture_meta WHERE mkey = p; RETURN x; END;
    FUNCTION meta_d(p VARCHAR2) RETURN DATE IS x DATE;
    BEGIN SELECT dval INTO x FROM cap_fixture_meta WHERE mkey = p; RETURN x; END;

    PROCEDURE pass(p VARCHAR2) IS
    BEGIN g_pass := g_pass + 1; DBMS_OUTPUT.PUT_LINE('  PASS  ' || p); END;
    PROCEDURE fail(p VARCHAR2) IS
    BEGIN g_fail := g_fail + 1; DBMS_OUTPUT.PUT_LINE('* FAIL  ' || p); END;

    PROCEDURE chk_true(label VARCHAR2, cond BOOLEAN) IS
    BEGIN IF cond THEN pass(label); ELSE fail(label); END IF; END;

    PROCEDURE chk_int(label VARCHAR2, actual NUMBER, expected NUMBER) IS
    BEGIN
        IF actual = expected THEN pass(label || ' = ' || expected);
        ELSE fail(label || ' expected ' || expected || ' got ' || actual); END IF;
    END;

    PROCEDURE chk_close(label VARCHAR2, actual NUMBER, expected NUMBER, tol_frac NUMBER) IS
    BEGIN
        IF expected = 0 THEN
            IF ABS(actual) <= tol_frac THEN pass(label); ELSE fail(label || ' ~0 got ' || actual); END IF;
        ELSIF ABS(actual - expected) <= tol_frac * ABS(expected) THEN
            pass(label || ' ~= ' || expected);
        ELSE
            fail(label || ' expected ~' || expected || ' got ' || actual);
        END IF;
    END;

    PROCEDURE chk_str(label VARCHAR2, actual VARCHAR2, expected VARCHAR2) IS
    BEGIN
        IF actual = expected THEN pass(label || ' = ' || expected);
        ELSE fail(label || ' expected ' || expected || ' got ' || NVL(actual,'<null>')); END IF;
    END;

    -- CAPA_ANOM lookups always name the FULL key (kind, series, baseline mode,
    -- ts, container): a bare day lookup matches one row per mode, and d_inj
    -- is also a FIXPDB1 DB_CPU_PCT step day, so it would match several.
    -- 'NOROW' (not NULL) when the key has no row, so a missing row can never
    -- pass as "not flagged".
    FUNCTION anom_flag(p_kind VARCHAR2, p_series VARCHAR2, p_mode VARCHAR2,
                       p_ts DATE, p_con NUMBER) RETURN VARCHAR2 IS
        x VARCHAR2(5);
    BEGIN
        SELECT anomaly_flag INTO x FROM capa_anom
         WHERE dbid = v_dbid AND con_dbid = p_con AND kind = p_kind
           AND series = p_series AND baseline_mode = p_mode AND ts = p_ts;
        RETURN x;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN RETURN 'NOROW';
    END;
    -- Flagged rows of one series under one mode; p_flag HIGH / LOW / ANY.
    FUNCTION anom_n(p_kind VARCHAR2, p_series VARCHAR2, p_mode VARCHAR2,
                    p_flag VARCHAR2, p_con NUMBER) RETURN NUMBER IS
        x NUMBER;
    BEGIN
        SELECT COUNT(*) INTO x FROM capa_anom
         WHERE dbid = v_dbid AND con_dbid = p_con AND kind = p_kind
           AND series = p_series AND baseline_mode = p_mode
           AND anomaly_flag = DECODE(p_flag, 'ANY', anomaly_flag, p_flag);
        RETURN x;
    END;
    -- Refill the snapshot. No commit: it rides in the caller's transaction,
    -- like the uncommitted knob flips around it.
    PROCEDURE snap_alerts IS
    BEGIN
        DELETE FROM cap_fixture_alerts_snap;
        INSERT INTO cap_fixture_alerts_snap SELECT * FROM capr_alerts;
    END;

    PROCEDURE knob(p_name VARCHAR2, p_val NUMBER) IS
    BEGIN UPDATE cap_config SET cfg_value = p_val WHERE cfg_name = p_name; END;
BEGIN
    v_dbid    := meta_n('DBID');
    d_spike   := meta_d('SPIKE_DAY');
    d_restart := meta_d('RESTART_DAY');
    d_inj     := meta_d('INJECTED_TUE');
    d_probe   := meta_d('PROBE_DAY');
    n_slope   := meta_n('LINEAR_SLOPE');
    n_dtf     := meta_n('LINEAR_DTF');
    meta_last_day := meta_d('LAST_DAY');

    DBMS_OUTPUT.PUT_LINE('=== FIX_LINEAR forecast ===');
    SELECT slope_bpd, r2, days_to_full, quality
      INTO v_num, v_r2, v_n, v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
    chk_close('LINEAR slope_bpd (bytes/day)', v_num, n_slope, 0.000001);
    chk_true ('LINEAR r2 > 0.999', v_r2 > 0.999);
    chk_int  ('LINEAR days_to_full',  v_n, n_dtf);
    chk_str  ('LINEAR quality', v_str, 'OK');
    chk_int('LINEAR anomaly count (TRAILING)', anom_n('TBSPC', 'FIX_LINEAR', 'TRAILING', 'ANY', v_dbid), 0);

    DBMS_OUTPUT.PUT_LINE('=== FIX_SPIKE anomaly ===');
    chk_int('SPIKE HIGH count (total, TRAILING)', anom_n('TBSPC', 'FIX_SPIKE', 'TRAILING', 'HIGH', v_dbid), 1);
    chk_str('SPIKE HIGH on spike day (TRAILING)', anom_flag('TBSPC', 'FIX_SPIKE', 'TRAILING', d_spike, v_dbid), 'HIGH');
    chk_int('SPIKE LOW count (TRAILING)', anom_n('TBSPC', 'FIX_SPIKE', 'TRAILING', 'LOW', v_dbid), 0);

    DBMS_OUTPUT.PUT_LINE('=== FIX_FLAT ===');
    SELECT quality INTO v_str FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_FLAT';
    chk_str('FLAT quality', v_str, 'FLAT');
    chk_int('FLAT anomaly count (TRAILING)', anom_n('TBSPC', 'FIX_FLAT', 'TRAILING', 'ANY', v_dbid), 0);

    DBMS_OUTPUT.PUT_LINE('=== FIX_GAP (AWR-gap rate normalization) ===');
    SELECT MAX(day_gap) INTO v_n FROM capd_tbspc_delta WHERE tablespace_name = 'FIX_GAP';
    chk_int('GAP recorded (max day_gap)', v_n, 4);
    -- The post-gap day (103) sees a 4-day, 240 MiB jump: rate-normalized it
    -- is 60 MiB/day and must not flag. The only flags are the three days of
    -- the +256 MiB/day burst (results layer: one TBSPC_ANOM episode).
    chk_str('GAP post-gap day 103 not flagged (rate-normalized, TRAILING)',
            NVL(anom_flag('TBSPC', 'FIX_GAP', 'TRAILING', meta_d('LAST_DAY') - 17, v_dbid), '-'), '-');
    chk_int('GAP TRAILING flags = the BURST_DAYS burst days, all HIGH',
            anom_n('TBSPC', 'FIX_GAP', 'TRAILING', 'HIGH', v_dbid), meta_n('BURST_DAYS'));
    chk_int('GAP TRAILING flags in total (no LOW, nothing else)',
            anom_n('TBSPC', 'FIX_GAP', 'TRAILING', 'ANY', v_dbid), meta_n('BURST_DAYS'));
    chk_str('GAP burst first day HIGH (TRAILING)',
            anom_flag('TBSPC', 'FIX_GAP', 'TRAILING', meta_d('BURST_FIRST'), v_dbid), 'HIGH');
    chk_str('GAP burst last day HIGH (TRAILING)',
            anom_flag('TBSPC', 'FIX_GAP', 'TRAILING', meta_d('BURST_LAST'), v_dbid), 'HIGH');

    DBMS_OUTPUT.PUT_LINE('=== FIX_NEARFULL (M7.1: near-full now, unreliable fit) ===');
    SELECT pct_used, quality INTO v_num, v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_NEARFULL';
    chk_close('NEARFULL pct_used', v_num, meta_n('NEARFULL_PCT'), 0.001);
    chk_str  ('NEARFULL quality', v_str, 'FLAT');
    snap_alerts;
    SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
      WHERE kind = 'TBSPC_NEARFULL' AND series_key = 'FIX_NEARFULL' AND severity = 'CRIT';
    chk_int('NEARFULL CRIT alert raised', v_n, 1);
    -- FIX_OVERFULL (limit under its usage, 150%) is the only other series at
    -- or over nearfull_warn_pct, so the "nobody else" check names both.
    SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
      WHERE kind = 'TBSPC_NEARFULL' AND series_key NOT IN ('FIX_NEARFULL', 'FIX_OVERFULL');
    chk_int('NEARFULL alerts only for FIX_NEARFULL / FIX_OVERFULL', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== FIX_FILLING (M8.1: TBSPC_FULL alert) ===');
    SELECT days_to_full, pct_used, quality INTO v_n, v_num, v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_FILLING';
    chk_int  ('FILLING days_to_full', v_n, meta_n('FILLING_DTF'));
    chk_close('FILLING pct_used', v_num, meta_n('FILLING_PCT'), 0.001);
    chk_str  ('FILLING quality', v_str, 'OK');
    SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
      WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_FILLING' AND severity = 'CRIT';
    chk_int('FILLING TBSPC_FULL CRIT alert raised', v_n, 1);
    -- FIX_OVERRIDE also lands inside the dtf_warn window, but only BECAUSE of
    -- its M9.5 override (2 GiB ceiling -> 74 days); on its raw 50 GiB maxsize
    -- it would be 4990 days away. So the "no other series alerts" check names
    -- both rather than counting to 1.
    SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
      WHERE kind = 'TBSPC_FULL' AND series_key NOT IN ('FIX_FILLING','FIX_OVERRIDE');
    chk_int('no TBSPC_FULL alerts beyond FILLING/OVERRIDE', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== M9.1 intervals: FIX_LINEAR (zero residuals -> bands collapse) ===');
    SELECT proj_30_bytes, proj_30_lo, proj_30_hi
      INTO v_num, v_num2, v_num3
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
    chk_close('LINEAR proj_30_lo = proj_30', v_num2, v_num, 0.000001);
    chk_close('LINEAR proj_30_hi = proj_30', v_num3, v_num, 0.000001);
    -- Anchoring leaves FIX_LINEAR unchanged by construction: its fitted line
    -- passes through cur_used, so cur + 30 * slope and the fitted-line value
    -- icept + slope * (last_day_n + 30) are the same closed form.
    chk_close('LINEAR proj_30_bytes = cur + 30 * slope (anchored)',
              v_num, meta_n('LINEAR_PRED30_DAY'), 0.000000001);
    SELECT icept + slope_bpd * (last_day - DATE '2020-01-01' + 30) INTO v_num2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
    chk_close('LINEAR fitted-line +30 = anchored +30 (line passes through cur_used)',
              v_num2, meta_n('LINEAR_PRED30_DAY'), 0.000000001);
    SELECT days_to_full_lo, days_to_full_hi INTO v_num, v_num2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
    -- headroom/slope is EXACTLY 4990.0 here, so a rounding epsilon on the
    -- collapsed slope CI may legitimately FLOOR the worst case to 4989.
    chk_true('LINEAR days_to_full_lo in [4989,4990] (got ' || v_num || ')',
             v_num BETWEEN n_dtf - 1 AND n_dtf);
    chk_true('LINEAR days_to_full_hi in [4990,4991] (got ' || v_num2 || ')',
             v_num2 BETWEEN n_dtf AND n_dtf + 1);

    DBMS_OUTPUT.PUT_LINE('=== M9.1 intervals: FIX_ZIGZAG (closed-form residuals) ===');
    SELECT slope_bpd, proj_30_bytes, quality INTO v_num, v_num2, v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_ZIGZAG';
    chk_close('ZIGZAG slope_bpd',       v_num,  meta_n('ZZ_SLOPE'),  0.000001);
    chk_close('ZIGZAG proj_30_bytes',   v_num2, meta_n('ZZ_P30'),    0.000001);
    chk_str  ('ZIGZAG quality', v_str, 'OK');
    SELECT proj_30_lo, proj_30_hi INTO v_num, v_num2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_ZIGZAG';
    chk_close('ZIGZAG proj_30_lo',      v_num,  meta_n('ZZ_P30_LO'), 0.000001);
    chk_close('ZIGZAG proj_30_hi',      v_num2, meta_n('ZZ_P30_HI'), 0.000001);
    -- The anchor is the last actual (an even day, +20 MiB off the line); icept
    -- is still the fitted intercept, so the fitted line still reaches the old
    -- +30 value and the gap between the two is the last day's residual.
    SELECT cur_used, icept + slope_bpd * (last_day - DATE '2020-01-01' + 30)
      INTO v_num, v_num2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_ZIGZAG';
    chk_int  ('ZIGZAG cur_used (anchor)', v_num, meta_n('ZZ_CUR'));
    chk_close('ZIGZAG fitted-line +30 (icept unchanged)', v_num2, meta_n('ZZ_P30_FIT'), 0.000001);
    chk_true ('ZIGZAG anchored +30 differs from the fitted-line +30 ('
              || ROUND((meta_n('ZZ_P30') - meta_n('ZZ_P30_FIT')) / 1048576, 3) || ' MiB)',
              ABS(meta_n('ZZ_P30') - meta_n('ZZ_P30_FIT')) > 1048576);
    -- Every TBSPC row: proj_h = cur_used + slope * h, and the band is
    -- symmetric around it.
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE slope_bpd IS NOT NULL
        AND (ABS(proj_30_bytes  - (cur_used + slope_bpd * 30))  > 1
          OR ABS(proj_90_bytes  - (cur_used + slope_bpd * 90))  > 1
          OR ABS(proj_180_bytes - (cur_used + slope_bpd * 180)) > 1
          OR ABS(proj_365_bytes - (cur_used + slope_bpd * 365)) > 1
          OR ABS((proj_30_hi - proj_30_bytes) - (proj_30_bytes - proj_30_lo)) > 1);
    chk_int('TBSPC rows off the anchored projection', v_n, 0);
    SELECT days_to_full, days_to_full_lo, days_to_full_hi INTO v_num, v_num2, v_num3
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_ZIGZAG';
    chk_int('ZIGZAG days_to_full',    v_num,  meta_n('ZZ_DTF'));
    chk_int('ZIGZAG days_to_full_lo', v_num2, meta_n('ZZ_DTF_LO'));
    chk_int('ZIGZAG days_to_full_hi', v_num3, meta_n('ZZ_DTF_HI'));
    chk_int('ZIGZAG anomaly count (TRAILING)', anom_n('TBSPC', 'FIX_ZIGZAG', 'TRAILING', 'ANY', v_dbid), 0);

    DBMS_OUTPUT.PUT_LINE('=== M9.4 backtest (REGR engine, pure SQL) ===');
    SELECT n_train, n_days, mape_pct, bias_pct INTO v_n, v_num, v_num2, v_num3
      FROM capf_backtest
      WHERE series_key = 'FIX_LINEAR' AND engine = 'REGR';
    chk_int ('LINEAR backtest n_train', v_n, 90);
    chk_int ('LINEAR backtest n_days', v_num, 28);
    chk_true('LINEAR backtest MAPE ~ 0 (got ' || v_num2 || ')', ABS(v_num2) < 0.000001);
    chk_true('LINEAR backtest bias ~ 0 (got ' || v_num3 || ')', ABS(v_num3) < 0.000001);
    SELECT n_days, mape_pct, bias_pct INTO v_n, v_num, v_num2
      FROM capf_backtest
      WHERE series_key = 'FIX_ZIGZAG' AND engine = 'REGR';
    chk_int  ('ZIGZAG backtest n_days', v_n, 28);
    chk_close('ZIGZAG backtest MAPE%', v_num,  meta_n('ZZ_BT_MAPE'), 0.0001);
    chk_close('ZIGZAG backtest BIAS%', v_num2, meta_n('ZZ_BT_BIAS'), 0.0001);

    DBMS_OUTPUT.PUT_LINE('=== CAPR_CONTAINER labels (M7.2) ===');
    SELECT db_pdb INTO v_str FROM capr_container
      WHERE dbid = v_dbid AND con_dbid = v_dbid;
    chk_str('root label = db name alone', v_str, 'FIXCDB');
    SELECT db_pdb INTO v_str FROM capr_container
      WHERE dbid = v_dbid AND con_dbid = v_dbid + 1;
    chk_str('PDB label = DB/PDB', v_str, 'FIXCDB/FIXPDB1');
    SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
      WHERE kind = 'TBSPC_NEARFULL' AND db_pdb <> 'FIXCDB';
    chk_int('alerts resolve db_pdb', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== CAPV_TARGET / CAPR_TARGETS fleet identity (M24.6) ===');
    SELECT COUNT(DISTINCT dbid) INTO v_num FROM cap_fixture_container;
    SELECT COUNT(*), COUNT(DISTINCT dbid) INTO v_n, v_num2 FROM capv_target;
    chk_int('CAPV_TARGET rows = fixture dbids', v_n, v_num);
    chk_int('CAPV_TARGET distinct dbids = fixture dbids', v_num2, v_num);
    SELECT target_name, feed INTO v_str, v_str2 FROM capv_target WHERE dbid = v_dbid;
    chk_str('CAPV_TARGET target_name', v_str, 'FIXCDB');
    chk_str('CAPV_TARGET feed', v_str2, 'FIXTURE');
    SELECT target_name INTO v_str FROM capr_container
      WHERE dbid = v_dbid AND con_dbid = v_dbid;
    chk_str('CAPR_CONTAINER root target_name', v_str, 'FIXCDB');
    SELECT COUNT(*), COUNT(collect_state) INTO v_n, v_num2 FROM capr_targets;
    chk_int('CAPR_TARGETS one row per fixture dbid', v_n, v_num);
    chk_int('CAPR_TARGETS collect_state NULL (nothing collected)', v_num2, 0);

    DBMS_OUTPUT.PUT_LINE('=== CAPR_ALERTS anomaly kinds (M8.1) ===');
    -- SPIKE_DAY is 10 days before LAST_DAY, INJECTED_TUE at most 6 days
    -- before -- both inside the default 14-day anomaly_report_days window.
    SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
      WHERE kind = 'TBSPC_ANOM' AND series_key = 'FIX_SPIKE'
        AND severity = 'WARN' AND day_dt = d_spike;
    chk_int('SPIKE raises TBSPC_ANOM WARN', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
      WHERE kind = 'CPU_ANOM' AND severity = 'WARN' AND day_dt = d_inj;
    chk_int('injected Tuesday raises CPU_ANOM WARN', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE kind = 'CPU_SAT';
    chk_int('no CPU_SAT alert (flat CPU trend)', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== M8.2 CAPR_* report views ===');
    -- Section 1a: FIX_FILLING fills soonest, so it ranks 1 and carries CRIT.
    SELECT days_to_full, rank_dtf, sev_dtf INTO v_n, v_num, v_str
      FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_FILLING';
    chk_int('CAPR_TBSPC_DAYS_TO_FULL FILLING days_to_full', v_n, meta_n('FILLING_DTF'));
    chk_int('CAPR_TBSPC_DAYS_TO_FULL FILLING rank_dtf', v_num, 1);
    chk_str('CAPR_TBSPC_DAYS_TO_FULL FILLING sev_dtf', v_str, 'CRIT');
    -- Section 1b: FIX_OVERFULL (150%) is the fullest RIGHT NOW, then
    -- FIX_NEARFULL (97%), any fit quality.
    SELECT rank_nearfull, sev_nearfull INTO v_num, v_str
      FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_OVERFULL';
    chk_int('CAPR_TBSPC_DAYS_TO_FULL OVERFULL rank_nearfull', v_num, 1);
    chk_str('CAPR_TBSPC_DAYS_TO_FULL OVERFULL sev_nearfull', v_str, 'CRIT');
    SELECT rank_nearfull, sev_nearfull INTO v_num, v_str
      FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_NEARFULL';
    chk_int('CAPR_TBSPC_DAYS_TO_FULL NEARFULL rank_nearfull', v_num, 2);
    chk_str('CAPR_TBSPC_DAYS_TO_FULL NEARFULL sev_nearfull', v_str, 'CRIT');
    SELECT COUNT(*) INTO v_n FROM capr_tbspc_days_to_full WHERE db_pdb <> 'FIXCDB';
    chk_int('CAPR section views resolve db_pdb', v_n, 0);

    -- Section 2: one row per tablespace, GiB conversion done in the view.
    SELECT COUNT(*) INTO v_n   FROM capr_tbspc_forecast;
    SELECT COUNT(*) INTO v_num FROM capf_tbspc_forecast;
    chk_int('CAPR_TBSPC_FORECAST row count = CAPF_TBSPC_FORECAST', v_n, v_num);
    SELECT cur_gb INTO v_num FROM capr_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
    chk_close('CAPR_TBSPC_FORECAST LINEAR cur_gb', v_num,
              meta_n('LINEAR_CUR') / 1073741824, 0.000001);

    -- Section 3: flagged rows only; days_ago is measured from the last
    -- collected day, so the report window is a plain WHERE days_ago < N.
    SELECT days_ago INTO v_num FROM capr_tbspc_anomalies
      WHERE tablespace_name = 'FIX_SPIKE' AND day_dt = d_spike AND baseline_mode = 'TRAILING';
    chk_int('CAPR_TBSPC_ANOMALIES SPIKE days_ago', v_num, meta_d('LAST_DAY') - d_spike);
    SELECT COUNT(*) INTO v_n FROM capr_tbspc_anomalies WHERE anomaly_flag IS NULL;
    chk_int('CAPR_TBSPC_ANOMALIES holds flagged rows only', v_n, 0);

    -- Section 4: the six CPU metrics (M10.1/M10.2) for the fixture ROOT
    -- container. Scoped by con_dbid because the M10.3 fixture adds a second
    -- container (FIXPDB1) carrying the three time-model metrics of its own.
    SELECT COUNT(*) INTO v_n FROM capr_cpu_trend
      WHERE dbid = v_dbid AND con_dbid = v_dbid;
    chk_int('CAPR_CPU_TREND metric count', v_n, 6);

    -- Section 5: the injected Tuesday, same days_ago contract.
    SELECT days_ago INTO v_num FROM capr_cpu_anomalies
      WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT'
        AND baseline_mode = 'SAME_DOW' AND ts = d_inj;
    chk_int('CAPR_CPU_ANOMALIES injected day days_ago', v_num, meta_d('LAST_DAY') - d_inj);

    -- Section 6: the Tier 2 report views compile and answer even with no
    -- ESM models trained (REGR backtest is pure SQL, so it always scores).
    SELECT COUNT(*) INTO v_n FROM capr_esm_compare;
    chk_true('CAPR_ESM_COMPARE queryable (' || v_n || ' rows)', v_n >= 0);
    SELECT COUNT(*) INTO v_n FROM capr_backtest WHERE regr_mape IS NOT NULL;
    chk_true('CAPR_BACKTEST scores REGR (' || v_n || ' series)', v_n >= 1);

    DBMS_OUTPUT.PUT_LINE('=== CPU restart guard + busy% ===');
    SELECT COUNT(*) INTO v_n FROM capd_cpu_daily
      WHERE dbid = v_dbid AND day_dt = d_restart;
    chk_int('CPU restart day excluded', v_n, 0);
    SELECT busy_pct INTO v_num FROM capd_cpu_daily
      WHERE dbid = v_dbid AND day_dt = d_probe;
    chk_true('CPU probe weekday busy% in [39,41] (got ' || ROUND(v_num,3) || ')',
             v_num BETWEEN 39 AND 41);

    DBMS_OUTPUT.PUT_LINE('=== M10.1 peak busy% (p95 / max / peak window) ===');
    SELECT busy_pct, busy_p95, busy_max INTO v_num, v_num2, v_num3
      FROM capd_cpu_daily WHERE dbid = v_dbid AND day_dt = d_probe;
    chk_close('CPU probe busy_pct (time-weighted avg)', v_num,  meta_n('CPU_PROBE_AVG'), 0.000001);
    chk_close('CPU probe busy_p95 of 2 intervals',      v_num2, meta_n('CPU_PROBE_P95'), 0.000001);
    chk_close('CPU probe busy_max',                     v_num3, meta_n('CPU_PROBE_MAX'), 0.000001);
    SELECT busy_peak_pct, peak_intervals, n_intervals, host_busy_sec
      INTO v_num, v_n, v_num2, v_num3
      FROM capd_cpu_daily WHERE dbid = v_dbid AND day_dt = d_probe;
    chk_close('CPU probe busy_peak_pct (18:00 interval only)', v_num, meta_n('CPU_PROBE_PEAK'), 0.000001);
    chk_int('CPU probe peak_intervals', v_n, 1);
    chk_int('CPU probe n_intervals', v_num2, 2);
    chk_close('CPU probe host_busy_sec', v_num3, meta_n('CPU_PROBE_HOST_BUSY_SEC'), 0.000001);
    SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
      WHERE dbid = v_dbid AND con_dbid = v_dbid
        AND metric IN ('BUSY_P95','BUSY_PEAK','DB_CPU_PCT','DB_CPU_P95');
    chk_int('CAPF_CPU_TREND carries the four new metrics', v_n, 4);
    SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
      WHERE dbid = v_dbid AND metric = 'DB_CPU_SEC' AND days_to_sat IS NOT NULL;
    chk_int('DB_CPU_SEC has no days_to_sat (no ceiling)', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== M10.2 DB CPU as % of logical-CPU capacity ===');
    SELECT db_cpu_sec, db_cpu_pct, db_cpu_peak_pct, host_share_pct
      INTO v_num, v_num2, v_num3, v_r2
      FROM capd_dbtime_daily
      WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
    chk_close('DB CPU probe db_cpu_sec',      v_num,  meta_n('DBCPU_PROBE_SEC'),        0.000001);
    chk_close('DB CPU probe db_cpu_pct',      v_num2, meta_n('DBCPU_PROBE_PCT'),        0.000001);
    chk_close('DB CPU probe db_cpu_peak_pct', v_num3, meta_n('DBCPU_PROBE_PEAK_PCT'),   0.000001);
    chk_close('DB CPU probe host_share_pct',  v_r2,   meta_n('DBCPU_PROBE_HOST_SHARE'), 0.000001);
    SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE kind = 'DBCPU_SAT';
    chk_int('no DBCPU_SAT alert (flat DB CPU)', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== CPU same-DOW anomaly ===');
    chk_str('CPU injected Tuesday flag (SAME_DOW)', anom_flag('CPU', 'BUSY_PCT', 'SAME_DOW', d_inj, v_dbid), 'HIGH');
    chk_int('CPU HIGH count (only injected, SAME_DOW)', anom_n('CPU', 'BUSY_PCT', 'SAME_DOW', 'HIGH', v_dbid), 1);

    DBMS_OUTPUT.PUT_LINE('=== M9.5 overrides (CAP_TBSPC_OVERRIDE) ===');
    -- FIX_OVERRIDE is FIX_LINEAR's data with a 2 GiB override instead of the
    -- 50 GiB autoextend maxsize, so every difference between the two below is
    -- attributable to the override alone.
    SELECT limit_bytes, days_to_full, quality INTO v_num, v_n, v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_OVERRIDE';
    chk_int('OVERRIDE limit_bytes (2 GiB, exact key beats wildcard decoy)',
            v_num, meta_n('OVERRIDE_LIMIT'));
    chk_int('OVERRIDE days_to_full', v_n, meta_n('OVERRIDE_DTF'));
    chk_str('OVERRIDE quality', v_str, 'OK');
    SELECT limit_source INTO v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_OVERRIDE';
    chk_str('OVERRIDE limit_source', v_str, 'OVERRIDE');
    -- The two un-overridden limit_source branches, for contrast.
    SELECT limit_source INTO v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
    chk_str('LINEAR limit_source (autoextend maxsize)', v_str, 'AUTOEXTEND');
    SELECT limit_source INTO v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_FLAT';
    chk_str('FLAT limit_source (no autoextend)', v_str, 'ALLOCATED');
    -- FIX_EXCLUDED is 99% full: if the exclusion leaked, it would be loud.
    SELECT COUNT(*) INTO v_n FROM capd_tbspc_daily
      WHERE tablespace_name = 'FIX_EXCLUDED';
    chk_int('EXCLUDED absent from CAPD_TBSPC_DAILY', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE tablespace_name = 'FIX_EXCLUDED';
    chk_int('EXCLUDED absent from CAPF_TBSPC_FORECAST', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE series_key = 'FIX_EXCLUDED';
    chk_int('EXCLUDED raises no CAPR_ALERTS', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== M7.4 report bound / M7.7 accel floor ===');
    -- M7.7: accel_ratio is meaningless when the baseline slope is ~0, so it is
    -- NULL below accel_slope_floor_bpd (1 MiB/day) instead of an absurd ratio.
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'accel_slope_floor_bpd';
    chk_int('knob accel_slope_floor_bpd (1 MiB/day)', v_num, 1048576);
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE dbid = v_dbid AND tablespace_name = 'FIX_FLAT' AND accel_ratio IS NULL;
    chk_int('FIX_FLAT accel_ratio IS NULL (slope 0)', v_n, 1);
    SELECT accel_ratio INTO v_num FROM capf_tbspc_forecast
      WHERE dbid = v_dbid AND tablespace_name = 'FIX_LINEAR';
    chk_close('FIX_LINEAR accel_ratio (10 MiB/day recent = full)', v_num, 1, 0.000001);

    -- M7.4: sections 2 and 6a print only reportable rows -- growing, or
    -- near-full, or >= report_min_gb GiB -- capped at top_n by rank_report.
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'report_min_gb';
    chk_int('knob report_min_gb', v_num, 1);
    SELECT is_reportable INTO v_str FROM capr_tbspc_forecast
      WHERE dbid = v_dbid AND tablespace_name = 'FIX_FLAT';
    chk_str('FIX_FLAT not reportable (flat, 0.39 GiB, 67% used)', v_str, 'N');
    SELECT is_reportable INTO v_str FROM capr_tbspc_forecast
      WHERE dbid = v_dbid AND tablespace_name = 'FIX_NEARFULL';
    chk_str('FIX_NEARFULL reportable (flat + under 1 GiB, but 97% full)', v_str, 'Y');
    SELECT is_reportable INTO v_str FROM capr_tbspc_forecast
      WHERE dbid = v_dbid AND tablespace_name = 'FIX_LINEAR';
    chk_str('FIX_LINEAR reportable (growing)', v_str, 'Y');
    SELECT rank_report INTO v_num  FROM capr_tbspc_forecast
      WHERE dbid = v_dbid AND tablespace_name = 'FIX_GAP';
    SELECT rank_report INTO v_num2 FROM capr_tbspc_forecast
      WHERE dbid = v_dbid AND tablespace_name = 'FIX_NEARFULL';
    SELECT rank_report INTO v_num3 FROM capr_tbspc_forecast
      WHERE dbid = v_dbid AND tablespace_name = 'FIX_FLAT';
    chk_true('rank_report: growing FIX_GAP before flat FIX_NEARFULL', v_num < v_num2);
    chk_true('rank_report: reportable FIX_NEARFULL before unreportable FIX_FLAT',
             v_num2 < v_num3);
    SELECT COUNT(*) INTO v_n FROM capr_esm_compare
      WHERE series_kind = 'TBSPC' AND series_key = 'FIX_FLAT' AND is_reportable <> 'N';
    chk_int('CAPR_ESM_COMPARE inherits FIX_FLAT is_reportable=N', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capr_esm_compare
      WHERE series_kind = 'CPU' AND (is_reportable <> 'Y' OR rank_report <> 0);
    chk_int('CAPR_ESM_COMPARE never bounds CPU rows', v_n, 0);
    -- CAPR_TBSPC_RANK: one row per CAPF_TBSPC_FORECAST row, and the bound and
    -- ranks both report views carry are its own.
    SELECT (SELECT COUNT(*) FROM capr_tbspc_rank) - (SELECT COUNT(*) FROM capf_tbspc_forecast)
      INTO v_n FROM dual;
    chk_int('CAPR_TBSPC_RANK rows - CAPF_TBSPC_FORECAST rows', v_n, 0);
    SELECT COUNT(*) INTO v_num FROM capf_tbspc_forecast;
    SELECT COUNT(*) INTO v_n
      FROM capr_tbspc_rank r
      JOIN capr_tbspc_forecast f
        ON f.dbid = r.dbid AND f.con_dbid = r.con_dbid AND f.tablespace_name = r.tablespace_name
     WHERE f.is_reportable = r.is_reportable AND f.rank_report = r.rank_report AND f.rank_chart = r.rank_chart;
    chk_int('CAPR_TBSPC_FORECAST rows whose bound and ranks are CAPR_TBSPC_RANK''s', v_n, v_num);
    -- CAPA_ANOM.kind_last_day: the newest DAY observation of each kind, the
    -- fixture's LAST_DAY for TBSPC, CPU and SERIES alike.
    DECLARE
        k_lo DATE; k_hi DATE;
    BEGIN
        SELECT COUNT(*), COUNT(DISTINCT kind), MIN(kind_last_day), MAX(kind_last_day)
          INTO v_n, v_num2, k_lo, k_hi
          FROM (SELECT DISTINCT kind, kind_last_day FROM capa_anom WHERE baseline_mode = 'TRAILING');
        chk_true('CAPA_ANOM kind_last_day = LAST_DAY for TBSPC, CPU, SERIES (got ' || v_n || ' rows, '
                 || TO_CHAR(k_lo, 'YYYY-MM-DD') || '..' || TO_CHAR(k_hi, 'YYYY-MM-DD') || ')',
                 v_n = 3 AND v_num2 = 3 AND k_lo = meta_last_day AND k_hi = meta_last_day);
    END;

    DBMS_OUTPUT.PUT_LINE('=== M9.2 Theil-Sen robust slope (knob slope_method) ===');
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'slope_method';
    chk_int('knob slope_method default (0 = OLS, 1 = THEILSEN)', v_num, 0);
    SELECT slope_method, slope_bpd, ols_slope_bpd
      INTO v_str, v_num, v_num2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
    chk_str  ('LINEAR slope_method label', v_str, 'OLS');
    chk_close('LINEAR slope_bpd = ols_slope_bpd under the default', v_num, v_num2, 0.000001);
    -- Theil-Sen is computed only when slope_method = 1: under the default
    -- every ts_* column is NULL.
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE ts_slope_bpd IS NOT NULL OR ts_icept IS NOT NULL;
    chk_int('TBSPC ts_slope_bpd / ts_icept IS NULL under slope_method = 0', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
      WHERE ts_slope_per_day IS NOT NULL OR ts_icept IS NOT NULL;
    chk_int('CPU ts_slope_per_day / ts_icept IS NULL under slope_method = 0', v_n, 0);
    -- The whole point of M9.2: ONE +2 GiB step drags the OLS slope ~4x off the
    -- true 5 MiB/day rate (the knob flip below shows the median does not move).
    SELECT ols_slope_bpd INTO v_num2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_SPIKE';
    chk_true ('SPIKE ols_slope_bpd > 3x the true rate ('
              || ROUND(v_num2 / meta_n('SPIKE_RATE'), 2) || 'x)',
              v_num2 > 3 * meta_n('SPIKE_RATE'));

    -- Flip the knob for real (uncommitted, this session only) and check the
    -- views switch estimator on the spot -- then put it back and COMMIT.
    SELECT days_to_full INTO v_num3
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_SPIKE';
    UPDATE cap_config SET cfg_value = 1 WHERE cfg_name = 'slope_method';
    BEGIN
        SELECT ts_slope_bpd INTO v_num
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
        chk_close('LINEAR ts_slope_bpd with knob=1 (exactly 10 MiB/day)', v_num, n_slope, 0.000001);
        SELECT ts_slope_bpd INTO v_num
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_ZIGZAG';
        chk_close('ZIGZAG ts_slope_bpd with knob=1 = median of the ' || meta_n('ZZ_TS_PAIRS')
                  || ' pairwise slopes', v_num, meta_n('ZZ_TS_SLOPE'), 0.000001);
        SELECT ts_slope_bpd INTO v_num
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_SPIKE';
        chk_close('SPIKE ts_slope_bpd with knob=1 within 1% of the true 5 MiB/day',
                  v_num, meta_n('SPIKE_RATE'), 0.01);
        SELECT slope_method, slope_bpd INTO v_str, v_num
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_SPIKE';
        chk_str  ('SPIKE slope_method with knob=1', v_str, 'THEILSEN');
        chk_close('SPIKE slope_bpd with knob=1 (robust 5 MiB/day)',
                  v_num, meta_n('SPIKE_RATE'), 0.01);
        SELECT days_to_full INTO v_num2
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_SPIKE';
        chk_true('SPIKE days_to_full with knob=1 > 3x the OLS answer ('
                 || v_num2 || ' vs ' || v_num3 || ')',
                 v_num2 > 3 * v_num3);
        -- M9.2 covers CAPF_CPU_TREND too: every metric row must switch.
        SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
          WHERE dbid = v_dbid AND slope_method <> 'THEILSEN';
        chk_int('CAPF_CPU_TREND rows all switch to THEILSEN', v_n, 0);
    EXCEPTION
        WHEN OTHERS THEN
            UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'slope_method';
            COMMIT;
            RAISE;
    END;
    UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'slope_method';
    COMMIT;
    SELECT slope_method INTO v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_SPIKE';
    chk_str('slope_method knob restored to OLS', v_str, 'OLS');

    DBMS_OUTPUT.PUT_LINE('=== M9.3 change-point reset (FIX_PURGE) ===');
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'reset_on_shrink';
    chk_int('knob reset_on_shrink default', v_num, 1);
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'shrink_mad_k';
    chk_int('knob shrink_mad_k default', v_num, 6);
    d_purge := meta_d('PURGE_DAY');
    SELECT reset_day, train_start, train_n, slope_bpd, days_to_full, quality
      INTO d_reset, d_tstart, v_n, v_num, v_num2, v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_PURGE';
    chk_int  ('PURGE reset_day - purge day (0 = the cliff day itself)',
              d_reset - d_purge, 0);
    -- Contract: the reset day IS the first fitted day -- its used_bytes is
    -- already the post-purge level, so including it costs nothing and gives
    -- the new window one extra point.
    chk_int  ('PURGE train_start - reset_day (0 = cliff day is in the window)',
              d_tstart - d_reset, 0);
    chk_int  ('PURGE train_n (post-purge rows)', v_n, meta_n('PURGE_TRAIN_N'));
    chk_close('PURGE slope_bpd = 10 MiB/day (not the across-the-cliff slope)',
              v_num, n_slope, 0.000001);
    chk_int  ('PURGE days_to_full off the post-purge line', v_num2, meta_n('PURGE_DTF'));
    chk_str  ('PURGE quality', v_str, 'OK');
    -- Contrast: a POSITIVE step is not a cliff, a clean line has none, and
    -- FIX_ZIGZAG's -30 MiB dips sit well inside 6*MAD_sigma.
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE tablespace_name = 'FIX_SPIKE' AND reset_day IS NULL;
    chk_int('SPIKE reset_day IS NULL (a +2 GiB step is not a shrink)', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE tablespace_name = 'FIX_LINEAR' AND reset_day IS NULL;
    chk_int('LINEAR reset_day IS NULL', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE tablespace_name = 'FIX_ZIGZAG' AND reset_day IS NULL;
    chk_int('ZIGZAG reset_day IS NULL (dips inside 6*MAD)', v_n, 1);
    SELECT train_n INTO v_n FROM capf_tbspc_forecast
      WHERE tablespace_name = 'FIX_LINEAR';
    chk_int('LINEAR train_n still the full train_days window', v_n, 90);
    -- The purge day is a genuine LOW anomaly, but it sits 30 days back --
    -- outside anomaly_report_days (14) -- so it raises no alert, and it stays
    -- confined to its own tablespace (the FIX_SPIKE LOW check above holds).
    chk_str('PURGE day flags a LOW anomaly (TRAILING)', anom_flag('TBSPC', 'FIX_PURGE', 'TRAILING', d_purge, v_dbid), 'LOW');
    chk_int('PURGE has exactly one anomaly (TRAILING)', anom_n('TBSPC', 'FIX_PURGE', 'TRAILING', 'ANY', v_dbid), 1);
    snap_alerts;
    SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE series_key = 'FIX_PURGE';
    chk_int('PURGE raises no CAPR_ALERTS (cliff predates the alert window)', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== purge events: a two-day purge is one cliff (FIX_PURGE2, cliff_merge_days) ===');
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'cliff_merge_days';
    chk_int('knob cliff_merge_days default', v_num, 1);
    SELECT reset_day, train_start, train_n, slope_bpd, days_to_full, quality, cycle_n, cur_used
      INTO d_reset, d_tstart, v_n, v_num, v_num2, v_str, v_num3, v_r2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_PURGE2';
    chk_int  ('PURGE2 cycle_n (two cliff days, one event)', v_num3, 1);
    chk_int  ('PURGE2 reset_day - the second cliff day', d_reset - meta_d('PURGE2_DAY'), 0);
    chk_int  ('PURGE2 reset_day - the first cliff day', d_reset - meta_d('PURGE2_FIRST'), 1);
    chk_int  ('PURGE2 train_start - reset_day', d_tstart - d_reset, 0);
    chk_int  ('PURGE2 train_n (the days from the second cliff day)', v_n, meta_n('PURGE2_TRAIN_N'));
    chk_close('PURGE2 slope_bpd = 10 MiB/day', v_num, n_slope, 0.000001);
    chk_int  ('PURGE2 cur_used', v_r2, meta_n('PURGE2_CUR'));
    chk_int  ('PURGE2 days_to_full off the post-purge line', v_num2, meta_n('PURGE2_DTF'));
    chk_str  ('PURGE2 quality (not CYCLIC)', v_str, 'OK');
    -- Both cliff days are LOW anomalies of the tablespace, 40 days back.
    chk_str('PURGE2 first cliff day LOW (TRAILING)',
            anom_flag('TBSPC', 'FIX_PURGE2', 'TRAILING', meta_d('PURGE2_FIRST'), v_dbid), 'LOW');
    chk_str('PURGE2 second cliff day LOW (TRAILING)',
            anom_flag('TBSPC', 'FIX_PURGE2', 'TRAILING', meta_d('PURGE2_DAY'), v_dbid), 'LOW');
    chk_int('PURGE2 has exactly two anomalies (TRAILING)',
            anom_n('TBSPC', 'FIX_PURGE2', 'TRAILING', 'ANY', v_dbid), 2);
    SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE series_key = 'FIX_PURGE2';
    chk_int('PURGE2 raises no CAPR_ALERTS', v_n, 0);
    -- A single-day purge and the sawtooths count as before.
    SELECT cycle_n INTO v_n FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_PURGE';
    chk_int('PURGE cycle_n', v_n, 1);
    SELECT cycle_n, cycle_days INTO v_n, v_num FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_CYCLIC';
    chk_int('CYCLIC cycle_n = its cliffs (one-day purges)', v_n, meta_n('CYC0_N'));
    chk_int('CYCLIC cycle_days', v_num, meta_n('CYC0_DAYS'));
    -- cliff_merge_days = 0: every cliff day is an event again. Two cliffs one
    -- day apart, so CYCLIC, no reset, no full date. Uncommitted, then reset.
    SAVEPOINT u05_merge;
    BEGIN
        knob('cliff_merge_days', 0);
        SELECT quality, reset_day, train_n, cycle_n, cycle_days, cycle_peak_bytes,
               days_to_full, days_to_full_lo
          INTO v_str, d_reset, v_n, v_num, v_num2, v_num3, v_r2, n_aux
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_PURGE2';
        chk_str ('cliff_merge_days = 0: PURGE2 quality', v_str, 'CYCLIC');
        chk_true('cliff_merge_days = 0: PURGE2 reset_day IS NULL', d_reset IS NULL);
        chk_int ('cliff_merge_days = 0: PURGE2 train_n (the whole window)', v_n, 90);
        chk_int ('cliff_merge_days = 0: PURGE2 cycle_n', v_num, 2);
        chk_int ('cliff_merge_days = 0: PURGE2 cycle_days', v_num2, 1);
        chk_int ('cliff_merge_days = 0: PURGE2 cycle_peak_bytes (the day before the purge)',
                 v_num3, meta_n('PURGE2_PEAK'));
        chk_true('cliff_merge_days = 0: PURGE2 days_to_full / _lo NULL', v_r2 IS NULL AND n_aux IS NULL);
        SELECT quality, reset_day INTO v_str, d_reset
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_PURGE';
        chk_str ('cliff_merge_days = 0: PURGE quality unchanged', v_str, 'OK');
        chk_int ('cliff_merge_days = 0: PURGE reset_day unchanged', d_reset - meta_d('PURGE_DAY'), 0);
        knob('cliff_merge_days', 1.5);
        SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'cliff_merge_days';
        chk_str ('CAP_CFG_CHECK cliff_merge_days = 1.5', v_str, 'BAD');
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK TO SAVEPOINT u05_merge; RAISE;
    END;
    ROLLBACK TO SAVEPOINT u05_merge;
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'cliff_merge_days';
    chk_str('CAP_CFG_CHECK cliff_merge_days default', v_str, 'OK');

    DBMS_OUTPUT.PUT_LINE('=== STOP / START: growth that stopped or began (FIX_STOPPED / FIX_STARTED) ===');
    SELECT COUNT(*) INTO v_n FROM cap_config
      WHERE (cfg_name = 'quiet_days'   AND cfg_value = 14)
         OR (cfg_name = 'quiet_ratio'  AND cfg_value = 2)
         OR (cfg_name = 'quiet_chance' AND cfg_value = 0.01)
         OR (cfg_name = 'growth_floor' AND cfg_value = 0.001);
    chk_int('knobs quiet_days 14 / quiet_ratio 2 / quiet_chance 0.01 / growth_floor 0.001', v_n, 4);
    SELECT COUNT(*) INTO v_n FROM cap_cfg_check
      WHERE knob IN ('quiet_days', 'quiet_ratio', 'quiet_chance', 'growth_floor') AND status = 'OK';
    chk_int('CAP_CFG_CHECK: the four STOP / START knobs OK', v_n, 4);
    -- FIX_STOPPED: the fit is the 30 flat days after the last growth day.
    SELECT restart_reason, restart_day, train_start, reset_day, train_n, slope_bpd, quality,
           days_to_full, days_to_full_lo, cur_used, proj_90_bytes
      INTO v_str, d_reset, d_tstart, d_rsd, v_n, v_num, v_str2, v_num2, v_num3, v_r2, n_aux
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_STOPPED';
    chk_str  ('STOPPED restart_reason', v_str, 'STOP');
    chk_int  ('STOPPED restart_day - the day after the last growth day', d_reset - meta_d('STOPPED_DAY'), 0);
    chk_int  ('STOPPED train_start - restart_day', d_tstart - d_reset, 0);
    chk_true ('STOPPED reset_day IS NULL (no purge)', d_rsd IS NULL);
    chk_int  ('STOPPED train_n (the quiet days)', v_n, meta_n('STOPPED_TRAIN_N'));
    chk_int  ('STOPPED slope_bpd', v_num, 0);
    chk_str  ('STOPPED quality', v_str2, 'FLAT');
    chk_true ('STOPPED days_to_full / _lo NULL', v_num2 IS NULL AND v_num3 IS NULL);
    chk_int  ('STOPPED cur_used', v_r2, meta_n('STOPPED_CUR'));
    chk_int  ('STOPPED proj_90_bytes = cur_used', n_aux, meta_n('STOPPED_CUR'));
    SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE series_key = 'FIX_STOPPED';
    chk_int  ('STOPPED raises no CAPR_ALERTS', v_n, 0);
    -- FIX_STARTED: the fit is the ramp, from the last day before it.
    SELECT restart_reason, restart_day, train_start, reset_day, train_n, slope_bpd, quality,
           days_to_full, r2, cur_used
      INTO v_str, d_reset, d_tstart, d_rsd, v_n, v_num, v_str2, v_num2, v_num3, v_r2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_STARTED';
    chk_str  ('STARTED restart_reason', v_str, 'START');
    chk_int  ('STARTED restart_day - the last day before the first growth day', d_reset - meta_d('STARTED_DAY'), 0);
    chk_int  ('STARTED train_start - restart_day', d_tstart - d_reset, 0);
    chk_true ('STARTED reset_day IS NULL (no purge)', d_rsd IS NULL);
    chk_int  ('STARTED train_n', v_n, meta_n('STARTED_TRAIN_N'));
    chk_close('STARTED slope_bpd = 16 MiB/day', v_num, meta_n('STARTED_SLOPE'), 0.000001);
    chk_close('STARTED r2', v_num3, 1, 0.000001);
    chk_str  ('STARTED quality', v_str2, 'OK');
    chk_int  ('STARTED cur_used', v_r2, meta_n('STARTED_CUR'));
    chk_int  ('STARTED days_to_full', v_num2, meta_n('STARTED_DTF'));
    SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE series_key = 'FIX_STARTED';
    chk_int  ('STARTED raises no CAPR_ALERTS (200 days is past dtf_warn)', v_n, 0);
    -- No other series restarts for STOP / START, PURGE names the two purged
    -- ones, and restart_day is the first fitted day wherever a reason is set.
    SELECT COUNT(CASE WHEN restart_reason IN ('STOP', 'START')
                       AND tablespace_name NOT IN ('FIX_STOPPED', 'FIX_STARTED') THEN 1 END),
           COUNT(CASE WHEN restart_reason = 'PURGE' THEN 1 END),
           COUNT(CASE WHEN restart_reason = 'PURGE'
                       AND tablespace_name IN ('FIX_PURGE', 'FIX_PURGE2') AND restart_day = reset_day THEN 1 END),
           COUNT(CASE WHEN (restart_reason IS NULL AND restart_day IS NOT NULL)
                        OR (restart_reason IS NOT NULL AND (restart_day IS NULL OR restart_day <> train_start))
                        OR NVL(restart_reason, 'PURGE') NOT IN ('PURGE', 'STOP', 'START') THEN 1 END),
           COUNT(CASE WHEN restart_reason IS NULL THEN 1 END), COUNT(*)
      INTO v_n, v_num, v_num2, v_num3, v_r2, n_aux
      FROM capf_tbspc_forecast;
    chk_int('no other tablespace restarts for STOP / START', v_n, 0);
    chk_int('restart_reason PURGE rows', v_num, 2);
    chk_int('restart_reason PURGE = FIX_PURGE and FIX_PURGE2, restart_day = reset_day', v_num2, 2);
    chk_int('restart_day set with a reason only, and equal to train_start', v_num3, 0);
    chk_int('rows with no restart = all but the four', v_r2, n_aux - 4);
    -- The report views pass both columns through, CAPR_FIT for TBSPC only.
    SELECT COUNT(*) INTO v_n
      FROM capf_tbspc_forecast t
      JOIN capr_fit f ON f.kind = 'TBSPC' AND f.dbid = t.dbid AND f.con_dbid = t.con_dbid
                     AND f.series = t.tablespace_name
      JOIN capr_tbspc_forecast r ON r.dbid = t.dbid AND r.con_dbid = t.con_dbid
                                AND r.tablespace_name = t.tablespace_name
      JOIN capr_tbspc_days_to_full d ON d.dbid = t.dbid AND d.con_dbid = t.con_dbid
                                    AND d.tablespace_name = t.tablespace_name
     WHERE DECODE(f.restart_reason, t.restart_reason, 0, 1) + DECODE(f.restart_day, t.restart_day, 0, 1)
         + DECODE(r.restart_reason, t.restart_reason, 0, 1) + DECODE(r.restart_day, t.restart_day, 0, 1)
         + DECODE(d.restart_reason, t.restart_reason, 0, 1) + DECODE(d.restart_day, t.restart_day, 0, 1) > 0;
    chk_int('CAPR_FIT / CAPR_TBSPC_FORECAST / CAPR_TBSPC_DAYS_TO_FULL restart columns differ from CAPF', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capr_fit
      WHERE kind <> 'TBSPC' AND (restart_reason IS NOT NULL OR restart_day IS NOT NULL);
    chk_int('CAPR_FIT restart columns NULL for CPU and SERIES', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capr_fit WHERE kind = 'TBSPC' AND restart_reason IN ('STOP', 'START');
    chk_int('CAPR_FIT rows with restart STOP / START', v_n, 2);
    -- quiet_days = 0: no STOP / START. Both fits are the whole window again,
    -- OLS through ramp + flat: the stopped tablespace gets a slope, grade OK
    -- and a full date inside dtf_warn, so a TBSPC_FULL alert. The started one
    -- reads slow and LOW_CONFIDENCE. Uncommitted, then rolled back.
    SAVEPOINT u05_quiet;
    BEGIN
        knob('quiet_days', 0);
        SELECT restart_reason, train_n, slope_bpd, r2, quality, days_to_full
          INTO v_str, v_n, v_num, v_num2, v_str2, v_num3
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_STOPPED';
        chk_true ('quiet_days = 0: STOPPED restart_reason IS NULL', v_str IS NULL);
        chk_int  ('quiet_days = 0: STOPPED train_n', v_n, 90);
        chk_close('quiet_days = 0: STOPPED slope_bpd (OLS over ramp + flat)', v_num, meta_n('STOPPED_Q0_SLOPE'), 0.000001);
        chk_close('quiet_days = 0: STOPPED r2', v_num2, meta_n('STOPPED_Q0_R2'), 0.000001);
        chk_str  ('quiet_days = 0: STOPPED quality', v_str2, 'OK');
        chk_int  ('quiet_days = 0: STOPPED days_to_full (a full date it never reaches)', v_num3, meta_n('STOPPED_Q0_DTF'));
        SELECT COUNT(*), MAX(severity) INTO v_n, v_str FROM capr_alerts
          WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_STOPPED';
        chk_int  ('quiet_days = 0: STOPPED raises TBSPC_FULL', v_n, 1);
        chk_str  ('quiet_days = 0: STOPPED TBSPC_FULL severity (45 days)', v_str, 'WARN');
        SELECT restart_reason, train_n, slope_bpd, r2, quality, days_to_full
          INTO v_str, v_n, v_num, v_num2, v_str2, v_num3
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_STARTED';
        chk_true ('quiet_days = 0: STARTED restart_reason IS NULL', v_str IS NULL);
        chk_int  ('quiet_days = 0: STARTED train_n', v_n, 90);
        chk_close('quiet_days = 0: STARTED slope_bpd (OLS over flat + ramp)', v_num, meta_n('STARTED_Q0_SLOPE'), 0.000001);
        chk_close('quiet_days = 0: STARTED r2', v_num2, meta_n('STARTED_Q0_R2'), 0.000001);
        chk_str  ('quiet_days = 0: STARTED quality', v_str2, 'LOW_CONFIDENCE');
        chk_int  ('quiet_days = 0: STARTED days_to_full', v_num3, meta_n('STARTED_Q0_DTF'));
        SELECT COUNT(CASE WHEN restart_reason IN ('STOP', 'START') THEN 1 END),
               COUNT(CASE WHEN restart_reason = 'PURGE' THEN 1 END)
          INTO v_n, v_num FROM capf_tbspc_forecast;
        chk_int  ('quiet_days = 0: no STOP / START row', v_n, 0);
        chk_int  ('quiet_days = 0: the two PURGE rows stay', v_num, 2);
        -- Just under the pause: 30 quiet days against quiet_days 31 is no STOP.
        -- START still holds (64 quiet days before the ramp).
        knob('quiet_days', 31);
        SELECT COUNT(CASE WHEN tablespace_name = 'FIX_STOPPED' AND restart_reason IS NULL THEN 1 END),
               COUNT(CASE WHEN tablespace_name = 'FIX_STARTED' AND restart_reason = 'START' THEN 1 END)
          INTO v_n, v_num FROM capf_tbspc_forecast;
        chk_int  ('quiet_days = 31: STOPPED not restarted (30 quiet days)', v_n, 1);
        chk_int  ('quiet_days = 31: STARTED still START', v_num, 1);
        knob('quiet_days', 30);
        SELECT restart_reason INTO v_str FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_STOPPED';
        chk_str  ('quiet_days = 30: STOPPED restart_reason', v_str, 'STOP');
        -- START needs min_train_days days left: 26 are, 27 are not.
        knob('quiet_days', 14);
        knob('min_train_days', 27);
        SELECT restart_reason, train_n INTO v_str, v_n
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_STARTED';
        chk_true ('min_train_days = 27: STARTED not restarted (26 days left)', v_str IS NULL AND v_n = 90);
        knob('min_train_days', 26);
        SELECT restart_reason, train_n, quality INTO v_str, v_n, v_str2
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_STARTED';
        chk_true ('min_train_days = 26: STARTED START, 26 days, OK (got ' || v_str || ' ' || v_n || ' ' || v_str2 || ')',
                  v_str = 'START' AND v_n = 26 AND v_str2 = 'OK');
        knob('min_train_days', 14);
        knob('quiet_chance', 2);
        knob('growth_floor', 1);
        SELECT COUNT(*) INTO v_n FROM cap_cfg_check
          WHERE knob IN ('quiet_chance', 'growth_floor') AND status = 'BAD';
        chk_int  ('CAP_CFG_CHECK quiet_chance = 2 / growth_floor = 1', v_n, 2);
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK TO SAVEPOINT u05_quiet; RAISE;
    END;
    ROLLBACK TO SAVEPOINT u05_quiet;
    SELECT restart_reason INTO v_str FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_STOPPED';
    chk_str('quiet_days restored: STOPPED restart_reason', v_str, 'STOP');

    DBMS_OUTPUT.PUT_LINE('=== clamp + limit_below_used (FIX_OVERFULL) ===');
    -- Flat at 1.5 GiB under a 1 GiB override: FLAT, so days_to_full is NULL
    -- (no growth to count with), not 0. limit_below_used and pct_used say
    -- the tablespace is over its ceiling, and the near-full alert fires.
    SELECT pct_used, quality, limit_below_used, limit_bytes, cur_used, limit_source
      INTO v_num, v_str, v_c1, v_num2, v_num3, v_str2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_OVERFULL';
    chk_close('OVERFULL pct_used', v_num, meta_n('OVERFULL_PCT'), 0.000001);
    chk_str  ('OVERFULL quality', v_str, 'FLAT');
    chk_str  ('OVERFULL limit_below_used', v_c1, 'Y');
    chk_int  ('OVERFULL limit_bytes (override)', v_num2, meta_n('OVERFULL_LIMIT'));
    chk_int  ('OVERFULL cur_used', v_num3, meta_n('OVERFULL_CUR'));
    chk_str  ('OVERFULL limit_source', v_str2, 'OVERRIDE');
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE tablespace_name = 'FIX_OVERFULL'
        AND days_to_full IS NULL AND days_to_full_lo IS NULL AND days_to_full_hi IS NULL;
    chk_int('OVERFULL days_to_full / _lo / _hi NULL (FLAT)', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
      WHERE kind = 'TBSPC_NEARFULL' AND series_key = 'FIX_OVERFULL' AND severity = 'CRIT';
    chk_int('OVERFULL raises TBSPC_NEARFULL CRIT', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
      WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_OVERFULL';
    chk_int('OVERFULL raises no TBSPC_FULL (flat)', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE limit_below_used = 'Y' AND tablespace_name <> 'FIX_OVERFULL';
    chk_int('no other row has limit_below_used = Y', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast WHERE days_to_full < 0
       OR days_to_full_lo < 0 OR days_to_full_hi < 0;
    chk_int('no negative days_to_full / _lo / _hi', v_n, 0);
    SELECT limit_below_used INTO v_c1 FROM capr_tbspc_days_to_full
      WHERE tablespace_name = 'FIX_OVERFULL';
    chk_str('CAPR_TBSPC_DAYS_TO_FULL passes limit_below_used', v_c1, 'Y');
    SELECT limit_below_used INTO v_num FROM capr_fit
      WHERE kind = 'TBSPC' AND series = 'FIX_OVERFULL';
    chk_int('CAPR_FIT limit_below_used = 1 for OVERFULL', v_num, 1);
    -- The clamp on a GROWING series: an override at 1 GiB under FIX_LINEAR's
    -- 1.27 GiB would give FLOOR(-26.0) = -26 days without it. Rolled back.
    SAVEPOINT u4a_clamp;
    BEGIN
        INSERT INTO cap_tbspc_override (dbid, con_dbid, tablespace_name, limit_bytes, exclude_flag, note)
        VALUES (v_dbid, v_dbid, 'FIX_LINEAR', 1073741824, 'N', 'run_test clamp probe');
        SELECT days_to_full, days_to_full_lo, days_to_full_hi, limit_below_used
          INTO v_num, v_num2, v_num3, v_c1
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
        chk_int('clamp probe LINEAR days_to_full (limit < cur)', v_num, 0);
        chk_int('clamp probe LINEAR days_to_full_lo', v_num2, 0);
        chk_int('clamp probe LINEAR days_to_full_hi', v_num3, 0);
        chk_str('clamp probe LINEAR limit_below_used', v_c1, 'Y');
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK TO SAVEPOINT u4a_clamp; RAISE;
    END;
    ROLLBACK TO SAVEPOINT u4a_clamp;

    DBMS_OUTPUT.PUT_LINE('=== staleness (stale_days / is_current, FIX_DROPPED) ===');
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'stale_days';
    chk_int('knob stale_days default', v_num, 3);
    SELECT last_day, newest_day, is_current, quality, train_n, cur_used
      INTO d_tstart, d_reset, v_c1, v_str, v_n, v_num
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_DROPPED';
    chk_int  ('DROPPED last_day', d_tstart - meta_d('DROPPED_LAST_DAY'), 0);
    chk_int  ('DROPPED newest_day = LAST_DAY', d_reset - meta_d('LAST_DAY'), 0);
    chk_int  ('DROPPED newest_day - last_day', d_reset - d_tstart, meta_n('DROPPED_STALE_GAP'));
    chk_str  ('DROPPED is_current', v_c1, 'N');
    chk_str  ('DROPPED quality (still fits)', v_str, 'OK');
    chk_int  ('DROPPED train_n', v_n, meta_n('DROPPED_TRAIN_N'));
    chk_int  ('DROPPED cur_used (its last row)', v_num, meta_n('DROPPED_CUR'));
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE tablespace_name <> 'FIX_DROPPED' AND is_current <> 'Y';
    chk_int('every other TBSPC row is_current = Y', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE newest_day <> meta_last_day;
    chk_int('TBSPC newest_day = LAST_DAY on every row', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
      WHERE is_current <> 'Y' OR newest_day <> meta_last_day;
    chk_int('CPU rows is_current = Y, newest_day = LAST_DAY', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capf_series_forecast
      WHERE is_current <> 'Y' OR newest_day <> meta_last_day;
    chk_int('SERIES rows is_current = Y, newest_day = LAST_DAY', v_n, 0);
    SELECT is_current INTO v_c1 FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_DROPPED';
    chk_str('CAPR_TBSPC_DAYS_TO_FULL passes is_current', v_c1, 'N');
    SELECT is_current INTO v_num FROM capr_fit WHERE kind = 'TBSPC' AND series = 'FIX_DROPPED';
    chk_int('CAPR_FIT is_current = 0 for DROPPED', v_num, 0);
    SELECT COUNT(*) INTO v_n FROM capr_fit WHERE is_current IS NULL
       OR (kind = 'TBSPC' AND limit_below_used IS NULL)
       OR (kind <> 'TBSPC' AND limit_below_used IS NOT NULL);
    chk_int('CAPR_FIT flags set per kind', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capr_cpu_trend WHERE is_current <> 'Y';
    chk_int('CAPR_CPU_TREND passes is_current', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capr_series WHERE is_current <> 'Y';
    chk_int('CAPR_SERIES passes is_current', v_n, 0);
    -- The boundary is last_day >= newest_day - stale_days: 30 days behind is
    -- stale at stale_days = 29 and current at 30. Uncommitted, then reset.
    BEGIN
        n_aux := meta_n('DROPPED_STALE_GAP');
        UPDATE cap_config SET cfg_value = n_aux - 1 WHERE cfg_name = 'stale_days';
        SELECT is_current INTO v_c1 FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_DROPPED';
        chk_str('DROPPED is_current with stale_days = gap - 1', v_c1, 'N');
        UPDATE cap_config SET cfg_value = n_aux WHERE cfg_name = 'stale_days';
        SELECT is_current INTO v_c1 FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_DROPPED';
        chk_str('DROPPED is_current with stale_days = gap', v_c1, 'Y');
    EXCEPTION
        WHEN OTHERS THEN
            UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'stale_days';
            COMMIT;
            RAISE;
    END;
    UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'stale_days';
    COMMIT;

    DBMS_OUTPUT.PUT_LINE('=== anchoring on CPU and SERIES fits ===');
    -- FIXPDB1 DB_CPU_PCT: the +18 step in the last 7 days leaves the last
    -- point above the fitted line, so anchored and fitted-line +30 differ.
    -- CPU projections start at anchor_value (the median of the last
    -- shift_days complete days, 58 here), and the slope is the deseasoned
    -- one (cpu_deseason = 1 by default): both recomputed by the installer.
    n_aux := meta_n('PDB_CON_DBID');
    SELECT train_n, cur_val, slope_per_day, proj_30,
           icept + slope_per_day * (last_day - DATE '2020-01-01' + 30)
      INTO v_n, v_num, v_num2, v_num3, v_r2
      FROM capf_cpu_trend
      WHERE dbid = v_dbid AND con_dbid = n_aux AND metric = 'DB_CPU_PCT';
    chk_int  ('PDB DB_CPU_PCT train_n (restart day has no row)', v_n, meta_n('PDB_DBCPU_TRAIN_N'));
    chk_close('PDB DB_CPU_PCT cur_val', v_num, meta_n('PDB_DBCPU_CUR'), 0.000001);
    chk_close('PDB DB_CPU_PCT slope (deseasoned)', v_num2, meta_n('PDB_DBCPU_SLOPE'), 0.000001);
    chk_close('PDB DB_CPU_PCT proj_30 = anchor_value + 30 * slope', v_num3, meta_n('PDB_DBCPU_P30'), 0.000001);
    chk_close('PDB DB_CPU_PCT fitted-line +30 (deseasoned icept)', v_r2, meta_n('PDB_DBCPU_P30_FIT'), 0.000001);
    SELECT anchor_value, days_to_sat INTO v_num, v_n
      FROM capf_cpu_trend
      WHERE dbid = v_dbid AND con_dbid = n_aux AND metric = 'DB_CPU_PCT';
    chk_close('PDB DB_CPU_PCT anchor_value (median of the last 7 days)', v_num, meta_n('PDB_DBCPU_ANCHOR'), 0.000001);
    chk_int  ('PDB DB_CPU_PCT days_to_sat from the anchor', v_n, meta_n('PDB_DBCPU_DTS'));
    SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
      WHERE slope_per_day IS NOT NULL
        AND (ABS(proj_30 - (anchor_value + slope_per_day * 30)) > 0.000001
          OR ABS(proj_90 - (anchor_value + slope_per_day * 90)) > 0.000001);
    chk_int('CPU rows off the anchored projection (anchor_value)', v_n, 0);
    -- SESSIONS is exactly linear, so anchoring changes nothing: 440 + 2 * 30.
    SELECT proj_30 INTO v_num FROM capf_series_forecast
      WHERE dbid = v_dbid AND series = 'SESSIONS';
    chk_close('SESSIONS proj_30 = 440 + 2 * 30', v_num, meta_n('SESS_CUR') + 2 * 30, 0.000001);
    SELECT COUNT(*) INTO v_n FROM capf_series_forecast
      WHERE slope_per_day IS NOT NULL
        AND (ABS(proj_30 - (cur_val + slope_per_day * 30)) > 0.000001
          OR ABS(proj_90 - (cur_val + slope_per_day * 90)) > 0.000001);
    chk_int('SERIES rows off the anchored projection', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== complete-day fits (is_complete = Y only) ===');
    SELECT train_n, train_start INTO v_n, d_tstart FROM capf_cpu_trend
      WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT';
    chk_int('BUSY_PCT train_n, train_days 90 (no partial day in the window)', v_n, meta_n('CPU_TRAIN_N'));
    SELECT train_n INTO v_n FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'REDO_GB_DAY';
    chk_int('REDO_GB_DAY train_n, train_days 90', v_n, meta_n('REDO_TRAIN_N'));
    SELECT train_n INTO v_n FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'SESSIONS';
    chk_int('SESSIONS train_n, train_days 90 (level series, every day)', v_n, meta_n('SESS_TRAIN_N'));
    -- Widen the window to 120 days so it holds the partial day (and day 1):
    -- the fits must skip the partial day. Uncommitted, then reset.
    BEGIN
        UPDATE cap_config SET cfg_value = 120 WHERE cfg_name = 'train_days';
        SELECT COUNT(*) INTO v_num FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND busy_pct IS NOT NULL
            AND day_dt > meta_last_day - 120;
        SELECT train_n, train_start INTO v_n, d_tstart FROM capf_cpu_trend
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT';
        chk_int('BUSY_PCT train_n, train_days 120 (partial day skipped; '
                || v_num || ' rows in the window)', v_n, meta_n('CPU_TRAIN_N_120'));
        chk_int('BUSY_PCT rows in the 120-day window = train_n + the partial day',
                v_num, meta_n('CPU_TRAIN_N_120') + 1);
        chk_int('BUSY_PCT train_start = day 1', d_tstart - meta_d('BASE_DAY'), 1);
        n_aux := meta_n('CPU_TRAIN_N_120');
        SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
          WHERE dbid = v_dbid AND con_dbid = v_dbid
            AND metric IN ('BUSY_P95', 'BUSY_PEAK', 'DB_CPU_SEC', 'DB_CPU_PCT', 'DB_CPU_P95')
            AND train_n <> n_aux;
        chk_int('every root CPU metric skips the partial day', v_n, 0);
        SELECT train_n INTO v_n FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'REDO_GB_DAY';
        chk_int('REDO_GB_DAY train_n, train_days 120 (partial day skipped)', v_n, meta_n('REDO_TRAIN_N_120'));
        SELECT train_n INTO v_n FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'SESSIONS';
        chk_int('SESSIONS train_n, train_days 120', v_n, meta_n('SESS_TRAIN_N_120'));
    EXCEPTION
        WHEN OTHERS THEN
            UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'train_days';
            COMMIT;
            RAISE;
    END;
    UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'train_days';
    COMMIT;

    DBMS_OUTPUT.PUT_LINE('=== CYCLIC grade (FIX_CYCLIC / FIX_CYCLIC_UP) ===');
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'cyclic_min_cliffs';
    chk_int('knob cyclic_min_cliffs default', v_num, 2);
    DECLARE
        v_cn NUMBER; v_cd NUMBER; v_pk NUMBER; v_pp NUMBER; v_ps NUMBER;
        v_rd DATE; v_dtf NUMBER; v_lo NUMBER; v_hi NUMBER; v_acc NUMBER;
    BEGIN
        FOR g IN 0 .. 1 LOOP
            v_str2 := CASE g WHEN 0 THEN 'FIX_CYCLIC' ELSE 'FIX_CYCLIC_UP' END;
            SELECT quality, cycle_n, cycle_days, cycle_peak_bytes, cycle_peak_pct,
                   peak_slope_bpd, reset_day, days_to_full, days_to_full_lo,
                   days_to_full_hi, accel_ratio, train_n, cur_used
              INTO v_str, v_cn, v_cd, v_pk, v_pp, v_ps, v_rd, v_dtf, v_lo, v_hi, v_acc, v_n, v_num
              FROM capf_tbspc_forecast WHERE tablespace_name = v_str2;
            chk_str  (v_str2 || ' quality', v_str, 'CYCLIC');
            chk_int  (v_str2 || ' cycle_n (cliffs in the window)', v_cn, meta_n('CYC' || g || '_N'));
            chk_int  (v_str2 || ' cycle_days', v_cd, meta_n('CYC' || g || '_DAYS'));
            chk_int  (v_str2 || ' cycle_peak_bytes', v_pk, meta_n('CYC' || g || '_PEAK'));
            chk_close(v_str2 || ' cycle_peak_pct', v_pp, meta_n('CYC' || g || '_PCT'), 0.000001);
            chk_int  (v_str2 || ' cur_used', v_num, meta_n('CYC' || g || '_CUR'));
            chk_true (v_str2 || ' reset_day IS NULL (no reset on a cyclic series)', v_rd IS NULL);
            chk_int  (v_str2 || ' train_n = the full window', v_n, 90);
            chk_true (v_str2 || ' days_to_full_lo / _hi / accel_ratio NULL',
                      v_lo IS NULL AND v_hi IS NULL AND v_acc IS NULL);
            IF g = 0 THEN
                chk_close(v_str2 || ' peak_slope_bpd = 0 (peaks do not grow)', v_ps, 0, 0.000001);
                chk_true (v_str2 || ' days_to_full IS NULL', v_dtf IS NULL);
            ELSE
                chk_close(v_str2 || ' peak_slope_bpd = 1 GiB / 30 days', v_ps, meta_n('CYC1_PSLOPE'), 0.000001);
                chk_int  (v_str2 || ' days_to_full off the peak line', v_dtf, meta_n('CYC1_DTF'));
            END IF;
        END LOOP;
        SELECT COUNT(*) INTO v_n FROM capr_alerts
          WHERE kind = 'TBSPC_FULL' AND series_key IN ('FIX_CYCLIC', 'FIX_CYCLIC_UP');
        chk_int('CYCLIC raises no TBSPC_FULL', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
          WHERE quality = 'CYCLIC' AND tablespace_name NOT IN ('FIX_CYCLIC', 'FIX_CYCLIC_UP');
        chk_int('no other row is CYCLIC', v_n, 0);
        SELECT cycle_n INTO v_n FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_PURGE';
        chk_int('FIX_PURGE cycle_n = 1 (one purge: M9.3 reset, not CYCLIC)', v_n, 1);
        SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
          WHERE quality <> 'CYCLIC'
            AND (cycle_days IS NOT NULL OR cycle_peak_bytes IS NOT NULL
                 OR cycle_peak_pct IS NOT NULL OR peak_slope_bpd IS NOT NULL);
        chk_int('cycle_* columns NULL off CYCLIC rows', v_n, 0);
        SELECT quality, cycle_n, cycle_days, cycle_peak_pct, days_to_full
          INTO v_str, v_cn, v_cd, v_pp, v_dtf
          FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_CYCLIC';
        chk_true('CAPR_TBSPC_DAYS_TO_FULL passes the CYCLIC columns',
                 v_str = 'CYCLIC' AND v_cn = meta_n('CYC0_N') AND v_cd = meta_n('CYC0_DAYS')
                 AND v_pp = meta_n('CYC0_PCT') AND v_dtf IS NULL);
        SELECT cycle_peak_gb, peak_slope_mb INTO v_pk, v_ps
          FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_CYCLIC_UP';
        chk_close('CAPR_TBSPC_DAYS_TO_FULL cycle_peak_gb', v_pk, meta_n('CYC1_PEAK') / 1073741824, 0.000001);
        chk_close('CAPR_TBSPC_DAYS_TO_FULL peak_slope_mb', v_ps, meta_n('CYC1_PSLOPE') / 1048576, 0.000001);
        SELECT quality, cycle_n, cycle_days, cycle_peak_pct, peak_slope_per_day, days_to_full
          INTO v_str, v_cn, v_cd, v_pp, v_ps, v_dtf
          FROM capr_fit WHERE kind = 'TBSPC' AND series = 'FIX_CYCLIC_UP';
        chk_true('CAPR_FIT passes the CYCLIC columns',
                 v_str = 'CYCLIC' AND v_cn = meta_n('CYC1_N') AND v_cd = meta_n('CYC1_DAYS')
                 AND v_pp = meta_n('CYC1_PCT') AND ABS(v_ps - meta_n('CYC1_PSLOPE')) < 0.001
                 AND v_dtf = meta_n('CYC1_DTF'));
        -- The grade off (cyclic_min_cliffs = 0): the M9.3 reset restarts at
        -- the last cliff, the current rise reads 2.5 GiB/day, and FIX_CYCLIC
        -- falls inside dtf_warn: the false page the grade exists to stop.
        BEGIN
            UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'cyclic_min_cliffs';
            SELECT quality, reset_day, train_n, slope_bpd, days_to_full, cycle_n
              INTO v_str, v_rd, v_n, v_ps, v_dtf, v_cn
              FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_CYCLIC';
            chk_str  ('cyclic_min_cliffs = 0: FIX_CYCLIC quality', v_str, 'OK');
            chk_int  ('cyclic_min_cliffs = 0: reset_day = the last cliff', v_rd - meta_d('CYC0_LAST_CLIFF'), 0);
            chk_int  ('cyclic_min_cliffs = 0: train_n (the current rise)', v_n, meta_n('CYC0_LEGACY_N'));
            chk_close('cyclic_min_cliffs = 0: slope_bpd = 2.5 GiB/day', v_ps, meta_n('CYC0_RISE'), 0.000001);
            chk_int  ('cyclic_min_cliffs = 0: days_to_full', v_dtf, meta_n('CYC0_LEGACY_DTF'));
            chk_int  ('cyclic_min_cliffs = 0: cycle_n still counted', v_cn, meta_n('CYC0_N'));
            SELECT COUNT(*) INTO v_n FROM capr_alerts
              WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_CYCLIC';
            chk_int('cyclic_min_cliffs = 0: FIX_CYCLIC raises the TBSPC_FULL false page', v_n, 1);
        EXCEPTION
            WHEN OTHERS THEN
                UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'cyclic_min_cliffs';
                COMMIT;
                RAISE;
        END;
        UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'cyclic_min_cliffs';
        COMMIT;
    END;

    DBMS_OUTPUT.PUT_LINE('=== DRIFT estimator (slope_method = 2) ===');
    -- Closed forms from the installer's own rates (DR_*). Flipped for this
    -- block only, then restored and committed.
    DECLARE
        v_sd NUMBER; v_ci NUMBER; v_p NUMBER; v_lo NUMBER; v_hi NUMBER;
        v_d NUMBER; v_dlo NUMBER; v_dhi NUMBER; v_m VARCHAR2(10);
    BEGIN
        -- Under the default the drift columns are there, the estimator is not.
        SELECT drift_slope_bpd, drift_sd_bpd, slope_method INTO v_num, v_sd, v_m
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
        chk_close('LINEAR drift_slope_bpd under slope_method 0', v_num, meta_n('DR_LINEAR_SLOPE'), 0.000001);
        chk_close('LINEAR drift_sd_bpd under slope_method 0 (0)', v_sd, 0, 0.000001);
        chk_str  ('LINEAR slope_method under 0', v_m, 'OLS');
        UPDATE cap_config SET cfg_value = 2 WHERE cfg_name = 'slope_method';
        BEGIN
            SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast WHERE slope_method <> 'DRIFT';
            chk_int('every TBSPC row uses DRIFT', v_n, 0);
            FOR r IN (SELECT 'LINEAR' AS k FROM dual UNION ALL SELECT 'SPIKE' FROM dual
                      UNION ALL SELECT 'ZIGZAG' FROM dual UNION ALL SELECT 'PURGE' FROM dual) LOOP
                SELECT slope_bpd, drift_sd_bpd, slope_ci_bpd, proj_30_bytes, proj_30_lo, proj_30_hi,
                       days_to_full, days_to_full_lo, days_to_full_hi, quality
                  INTO v_num, v_sd, v_ci, v_p, v_lo, v_hi, v_d, v_dlo, v_dhi, v_str
                  FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_' || r.k;
                chk_close('DRIFT ' || r.k || ' slope_bpd (median rate)', v_num, meta_n('DR_' || r.k || '_SLOPE'), 0.000001);
                chk_close('DRIFT ' || r.k || ' drift_sd_bpd', v_sd, meta_n('DR_' || r.k || '_SD'), 0.000001);
                chk_close('DRIFT ' || r.k || ' slope_ci_bpd = t * sd / sqrt(n)', v_ci, meta_n('DR_' || r.k || '_CI'), 0.000001);
                chk_close('DRIFT ' || r.k || ' proj_30_bytes', v_p,  meta_n('DR_' || r.k || '_P30'),    0.000001);
                chk_close('DRIFT ' || r.k || ' proj_30_lo',    v_lo, meta_n('DR_' || r.k || '_P30_LO'), 0.000001);
                chk_close('DRIFT ' || r.k || ' proj_30_hi',    v_hi, meta_n('DR_' || r.k || '_P30_HI'), 0.000001);
                chk_int  ('DRIFT ' || r.k || ' days_to_full',    v_d,   meta_n('DR_' || r.k || '_DTF'));
                chk_true ('DRIFT ' || r.k || ' days_to_full_lo = ' || meta_n('DR_' || r.k || '_DTF_LO')
                          || ' (got ' || v_dlo || ')', v_dlo = meta_n('DR_' || r.k || '_DTF_LO'));
                chk_true ('DRIFT ' || r.k || ' days_to_full_hi = ' || NVL(TO_CHAR(meta_n('DR_' || r.k || '_DTF_HI')), 'NULL')
                          || ' (got ' || NVL(TO_CHAR(v_dhi), 'NULL') || ')',
                          (v_dhi IS NULL AND meta_n('DR_' || r.k || '_DTF_HI') IS NULL)
                          OR v_dhi = meta_n('DR_' || r.k || '_DTF_HI'));
                SELECT sval INTO v_str2 FROM cap_fixture_meta WHERE mkey = 'DR_' || r.k || '_Q';
                chk_str  ('DRIFT ' || r.k || ' quality', v_str, v_str2);
            END LOOP;
            -- The named closed forms behind those rows.
            chk_close('DRIFT LINEAR slope = 10 MiB/day', meta_n('DR_LINEAR_SLOPE'), n_slope, 0.000001);
            chk_int  ('DRIFT LINEAR days_to_full = LINEAR_DTF', meta_n('DR_LINEAR_DTF'), n_dtf);
            chk_close('DRIFT SPIKE slope = 5 MiB/day (the step is 1 of 89 rates)',
                      meta_n('DR_SPIKE_SLOPE'), meta_n('SPIKE_RATE'), 0.000001);
            chk_close('DRIFT SPIKE sd = 2 GiB / sqrt(89)', meta_n('DR_SPIKE_SD'), 2147483648 / SQRT(89), 0.000001);
            chk_close('DRIFT ZIGZAG slope = +50 MiB/day (45 of 89 rates)', meta_n('DR_ZIGZAG_SLOPE'), 50 * 1048576, 0.000001);
            chk_close('DRIFT PURGE slope = 10 MiB/day (post-reset rates)', meta_n('DR_PURGE_SLOPE'), n_slope, 0.000001);
            chk_int  ('DRIFT PURGE days_to_full = PURGE_DTF', meta_n('DR_PURGE_DTF'), meta_n('PURGE_DTF'));
            SELECT reset_day INTO d_reset FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_PURGE';
            chk_int('DRIFT PURGE reset_day unchanged', d_reset - meta_d('PURGE_DAY'), 0);
            SELECT proj_30_lo, proj_30_hi, proj_30_bytes INTO v_lo, v_hi, v_p
              FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
            chk_true('DRIFT LINEAR bands collapse (sd 0)', ABS(v_hi - v_lo) < 1 AND ABS(v_p - meta_n('LINEAR_PRED30_DAY')) < 1);
            SELECT icept + slope_bpd * (last_day - DATE '2020-01-01'), cur_used INTO v_num, v_num2
              FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_ZIGZAG';
            chk_close('DRIFT icept: the anchored line passes through cur_used', v_num, v_num2, 0.000000001);
            SELECT quality INTO v_str FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_FLAT';
            chk_str('DRIFT FLAT quality (median rate 0)', v_str, 'FLAT');
            SELECT quality INTO v_str FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_CYCLIC';
            chk_str('DRIFT FIX_CYCLIC still CYCLIC', v_str, 'CYCLIC');
            -- CPU and SERIES follow the knob.
            SELECT COUNT(*) INTO v_n FROM capf_cpu_trend WHERE slope_method <> 'DRIFT';
            chk_int('every CPU row uses DRIFT', v_n, 0);
            SELECT slope_method, slope_per_day, drift_sd_per_day, days_to_limit, quality, proj_30_lo, proj_30_hi
              INTO v_m, v_num, v_sd, v_n, v_str, v_lo, v_hi
              FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'SESSIONS';
            chk_str  ('DRIFT SESSIONS slope_method', v_m, 'DRIFT');
            chk_close('DRIFT SESSIONS slope = 2/day', v_num, 2, 0.000001);
            chk_close('DRIFT SESSIONS sd = 0', v_sd, 0, 0.000001);
            chk_int  ('DRIFT SESSIONS days_to_limit', v_n, meta_n('SESS_DTL'));
            chk_str  ('DRIFT SESSIONS quality', v_str, 'OK');
            chk_true ('DRIFT SESSIONS bands collapse', ABS(v_hi - v_lo) < 0.000001);
            -- CAPF_BACKTEST's REGR replay follows the knob.
            SELECT slope_method, mape_pct, bias_pct INTO v_m, v_num, v_num2
              FROM capf_backtest WHERE series_key = 'FIX_ZIGZAG' AND engine = 'REGR';
            chk_str  ('DRIFT backtest ZIGZAG slope_method', v_m, 'DRIFT');
            chk_close('DRIFT backtest ZIGZAG MAPE%', v_num,  meta_n('ZZ_BT_DR_MAPE'), 0.0001);
            chk_close('DRIFT backtest ZIGZAG BIAS%', v_num2, meta_n('ZZ_BT_DR_BIAS'), 0.0001);
            SELECT mape_pct INTO v_num FROM capf_backtest WHERE series_key = 'FIX_LINEAR' AND engine = 'REGR';
            chk_true('DRIFT backtest LINEAR MAPE ~ 0 (got ' || v_num || ')', ABS(v_num) < 0.000001);
        EXCEPTION
            WHEN OTHERS THEN
                UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'slope_method';
                COMMIT;
                RAISE;
        END;
        -- THEILSEN in the backtest replay as well.
        UPDATE cap_config SET cfg_value = 1 WHERE cfg_name = 'slope_method';
        BEGIN
            SELECT slope_method, mape_pct, bias_pct INTO v_m, v_num, v_num2
              FROM capf_backtest WHERE series_key = 'FIX_ZIGZAG' AND engine = 'REGR';
            chk_str  ('THEILSEN backtest ZIGZAG slope_method', v_m, 'THEILSEN');
            chk_close('THEILSEN backtest ZIGZAG MAPE%', v_num,  meta_n('ZZ_BT_TS_MAPE'), 0.0001);
            chk_close('THEILSEN backtest ZIGZAG BIAS%', v_num2, meta_n('ZZ_BT_TS_BIAS'), 0.0001);
        EXCEPTION
            WHEN OTHERS THEN
                UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'slope_method';
                COMMIT;
                RAISE;
        END;
        UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'slope_method';
        COMMIT;
        SELECT slope_method INTO v_m FROM capf_backtest WHERE series_key = 'FIX_ZIGZAG' AND engine = 'REGR';
        chk_str('backtest slope_method back to OLS', v_m, 'OLS');
    END;

    DBMS_OUTPUT.PUT_LINE('=== CPU gate, deseasoning, anchor, hot_now ===');
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'cpu_quality_gate';
    chk_int('knob cpu_quality_gate default (1 = slope significance)', v_num, 1);
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'cpu_deseason';
    chk_int('knob cpu_deseason default (1 = weekday / weekend demeaning)', v_num, 1);
    DECLARE
        n_p2 NUMBER := meta_n('PDB2_CON_DBID');
        n_p1 NUMBER := meta_n('PDB_CON_DBID');
        v_ci NUMBER; v_sig VARCHAR2(1); v_ds VARCHAR2(1); v_anc NUMBER; v_hot VARCHAR2(1);
    BEGIN
        -- Root: no trend by construction. Deseasoned, the slope is the pull
        -- of the injected Tuesday alone, inside its own CI.
        SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
          WHERE dbid = v_dbid AND con_dbid = v_dbid
            AND slope_sig = 'N' AND deseasoned = 'Y' AND quality IN ('LOW_CONFIDENCE', 'FLAT');
        chk_int('root: all 6 metrics slope_sig N, deseasoned, LOW_CONFIDENCE / FLAT', v_n, 6);
        SELECT slope_per_day, slope_ci_per_day, anchor_value, proj_30, cur_val
          INTO v_num, v_ci, v_anc, v_num2, v_num3
          FROM capf_cpu_trend WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT';
        chk_close('root BUSY_PCT deseasoned slope', v_num, meta_n('ROOT_BUSY_SLOPE'), 0.000001);
        chk_close('root BUSY_PCT slope_ci', v_ci, meta_n('ROOT_BUSY_CI'), 0.000001);
        chk_close('root BUSY_PCT anchor_value = 40 (median of the last 7 days)', v_anc, meta_n('ROOT_BUSY_ANCHOR'), 0.000001);
        chk_close('root BUSY_PCT anchor_value closed form', meta_n('ROOT_BUSY_ANCHOR'), 40, 0.000001);
        chk_close('root BUSY_PCT proj_30 = anchor + 30 * slope', v_num2, meta_n('ROOT_BUSY_P30'), 0.000001);
        chk_true ('root BUSY_PCT cur_val is the raw last day (got ' || v_num3 || ')', v_num3 IN (20, 40, 70));
        -- FIXPDB1: the +18 step makes the deseasoned slope significant.
        SELECT slope_ci_per_day, slope_sig, quality INTO v_ci, v_sig, v_str
          FROM capf_cpu_trend WHERE dbid = v_dbid AND con_dbid = n_p1 AND metric = 'DB_CPU_PCT';
        chk_close('PDB DB_CPU_PCT slope_ci', v_ci, meta_n('PDB_DBCPU_CI'), 0.000001);
        chk_str  ('PDB DB_CPU_PCT slope_sig', v_sig, 'Y');
        chk_str  ('PDB DB_CPU_PCT quality (gate 1)', v_str, 'OK');
        -- FIXPDB2: weekday 60 / weekend 20 plus a +1/12 per day ramp.
        SELECT train_n, slope_per_day, slope_ci_per_day, r2, slope_sig, deseasoned, quality,
               anchor_value, proj_30, days_to_sat
          INTO v_n, v_num, v_ci, v_r2, v_sig, v_ds, v_str, v_anc, v_num2, v_num3
          FROM capf_cpu_trend WHERE dbid = v_dbid AND con_dbid = n_p2 AND metric = 'DB_CPU_PCT';
        chk_int  ('PDB2 DB_CPU_PCT train_n', v_n, meta_n('PDB2_TRAIN_N'));
        chk_close('PDB2 DB_CPU_PCT deseasoned slope', v_num, meta_n('PDB2_PCT_SLOPE'), 0.000001);
        chk_close('PDB2 DB_CPU_PCT slope near the 1/12 ramp', v_num, 1/12, 0.01);
        chk_close('PDB2 DB_CPU_PCT slope_ci', v_ci, meta_n('PDB2_PCT_CI'), 0.00001);
        chk_close('PDB2 DB_CPU_PCT r2 (deseasoned)', v_r2, meta_n('PDB2_PCT_R2'), 0.000001);
        chk_str  ('PDB2 DB_CPU_PCT slope_sig', v_sig, 'Y');
        chk_str  ('PDB2 DB_CPU_PCT deseasoned', v_ds, 'Y');
        chk_str  ('PDB2 DB_CPU_PCT quality (deseason 1, gate 1)', v_str, 'OK');
        chk_close('PDB2 DB_CPU_PCT anchor_value', v_anc, meta_n('PDB2_PCT_ANCHOR'), 0.000001);
        chk_close('PDB2 DB_CPU_PCT proj_30', v_num2, meta_n('PDB2_PCT_P30'), 0.000001);
        chk_int  ('PDB2 DB_CPU_PCT days_to_sat', v_num3, meta_n('PDB2_PCT_DTS'));
        chk_true ('PDB2 DB_CPU_PCT days_to_sat beyond dtf_warn (no DBCPU_SAT)', v_num3 > 90);
        -- hot_now: only FIXPDB2's busy-hour DB CPU sits at or above 80%.
        SELECT recent_p95_med, hot_now, days_to_sat INTO v_anc, v_hot, v_n
          FROM capf_cpu_trend WHERE dbid = v_dbid AND con_dbid = n_p2 AND metric = 'DB_CPU_P95';
        chk_close('PDB2 DB_CPU_P95 recent_p95_med', v_anc, meta_n('PDB2_P95_RECENT_MED'), 0.000001);
        chk_str  ('PDB2 DB_CPU_P95 hot_now', v_hot, 'Y');
        chk_int  ('PDB2 DB_CPU_P95 days_to_sat (already past 80)', v_n, 0);
        SELECT hot_now, recent_p95_med INTO v_hot, v_anc
          FROM capf_cpu_trend WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_P95';
        chk_str  ('root BUSY_P95 hot_now (58 never reaches 80)', v_hot, 'N');
        chk_close('root BUSY_P95 recent_p95_med = 58', v_anc, meta_n('CPU_PROBE_P95'), 0.000001);
        SELECT COUNT(*) INTO v_n FROM capf_cpu_trend WHERE hot_now = 'Y';
        chk_int('exactly one hot_now = Y row', v_n, 1);
        SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
          WHERE (metric IN ('BUSY_P95', 'DB_CPU_P95') AND (hot_now IS NULL OR recent_p95_med IS NULL))
             OR (metric NOT IN ('BUSY_P95', 'DB_CPU_P95') AND (hot_now IS NOT NULL OR recent_p95_med IS NOT NULL));
        chk_int('hot_now / recent_p95_med on the two p95 metrics only', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_cpu_trend t JOIN capf_cpu_trend f
            ON f.dbid = t.dbid AND f.con_dbid = t.con_dbid AND f.metric = t.metric
          WHERE NVL(t.hot_now, '-') <> NVL(f.hot_now, '-') OR t.slope_sig <> f.slope_sig
             OR t.deseasoned <> f.deseasoned OR t.anchor_value <> f.anchor_value
             OR NVL(t.recent_p95_med, -1) <> NVL(f.recent_p95_med, -1);
        chk_int('CAPR_CPU_TREND passes slope_sig / deseasoned / anchor_value / hot_now', v_n, 0);
        SELECT hot_now, slope_sig INTO v_num, v_num2 FROM capr_fit
          WHERE kind = 'CPU' AND con_dbid = n_p2 AND series = 'DB_CPU_P95';
        chk_true('CAPR_FIT hot_now = 1, slope_sig = 1 for PDB2 DB_CPU_P95', v_num = 1 AND v_num2 = 1);
        SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind IN ('CPU_SAT', 'DBCPU_SAT');
        chk_int('no CPU_SAT / DBCPU_SAT alert (hot now is not a forecast)', v_n, 0);

        -- Legacy: deseason off and the R^2 gate reproduce the old answers.
        BEGIN
            UPDATE cap_config SET cfg_value = 0 WHERE cfg_name IN ('cpu_deseason', 'cpu_quality_gate');
            SELECT slope_per_day, r2, quality, deseasoned INTO v_num, v_r2, v_str, v_ds
              FROM capf_cpu_trend WHERE dbid = v_dbid AND con_dbid = n_p2 AND metric = 'DB_CPU_PCT';
            chk_close('legacy PDB2 DB_CPU_PCT raw slope', v_num, meta_n('PDB2_PCT_SLOPE_RAW'), 0.000001);
            chk_close('legacy PDB2 DB_CPU_PCT raw r2', v_r2, meta_n('PDB2_PCT_R2_RAW'), 0.000001);
            chk_true ('legacy PDB2 DB_CPU_PCT r2 below r2_gate (' || ROUND(v_r2, 4) || ')', v_r2 < 0.6);
            chk_str  ('legacy PDB2 DB_CPU_PCT quality', v_str, 'LOW_CONFIDENCE');
            chk_str  ('legacy PDB2 DB_CPU_PCT deseasoned', v_ds, 'N');
            SELECT slope_per_day, r2, proj_30 INTO v_num, v_r2, v_num2
              FROM capf_cpu_trend WHERE dbid = v_dbid AND con_dbid = n_p1 AND metric = 'DB_CPU_PCT';
            chk_close('legacy PDB DB_CPU_PCT raw slope', v_num, meta_n('PDB_DBCPU_SLOPE_RAW'), 0.000001);
            chk_close('legacy PDB DB_CPU_PCT raw r2', v_r2, meta_n('PDB_DBCPU_R2_RAW'), 0.000001);
            chk_close('legacy PDB DB_CPU_PCT proj_30 = anchor + 30 * raw slope', v_num2, meta_n('PDB_DBCPU_P30_RAW'), 0.000001);
            SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
              WHERE quality <> CASE WHEN train_n < 14 THEN 'INSUFFICIENT_HISTORY'
                                    WHEN slope_per_day = 0 OR r2 IS NULL THEN 'FLAT'
                                    WHEN r2 < 0.6 THEN 'LOW_CONFIDENCE' ELSE 'OK' END;
            chk_int('legacy gate: every CPU quality is the R^2 ladder', v_n, 0);
            SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND quality <> 'LOW_CONFIDENCE';
            chk_int('legacy gate: root metrics LOW_CONFIDENCE', v_n, 0);
        EXCEPTION
            WHEN OTHERS THEN
                UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name IN ('cpu_deseason', 'cpu_quality_gate');
                COMMIT;
                RAISE;
        END;
        UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name IN ('cpu_deseason', 'cpu_quality_gate');
        COMMIT;
        SELECT quality INTO v_str FROM capf_cpu_trend
          WHERE dbid = v_dbid AND con_dbid = n_p2 AND metric = 'DB_CPU_PCT';
        chk_str('PDB2 DB_CPU_PCT quality back to OK after the restore', v_str, 'OK');
    END;

    DBMS_OUTPUT.PUT_LINE('=== anomaly deviation as % of baseline (median / train_days avg) ===');
    -- FIX_SPIKE: 640 blocks/day (SPIKE_RATE = 5 MiB/day) every day, plus a
    -- 262144-block (2 GiB) step on the spike day, so that day's rate is
    -- SPIKE_RATE + 2 GiB and both baselines are exactly SPIKE_RATE:
    -- 100 * 2 GiB / 5 MiB = 40960.
    -- The step is written as the NUMBER literal 2147483648: 262144 * 8192 as
    -- integer literals overflows PLS_INTEGER (2^31) in PL/SQL.
    DECLARE
        n_train NUMBER;
        n_rate  NUMBER := meta_n('SPIKE_RATE');
        n_pct   NUMBER := 100 * 2147483648 / meta_n('SPIKE_RATE');
        n_avgd  NUMBER;
        n_capa  NUMBER;
    BEGIN
        SELECT cfg_value INTO n_train FROM cap_config WHERE cfg_name = 'train_days';
        -- Deltas exist from day index 1 (index 0 has no predecessor) with no
        -- gaps, and the window is [day - train_days, day - 1], so it covers
        -- LEAST(train_days, spike index - 1) one-day gaps.
        n_avgd := LEAST(n_train, (d_spike - meta_d('BASE_DAY')) - 1);
        SELECT avg_value, avg_days, pct_vs_expected, pct_vs_avg
          INTO v_num, v_n, v_num2, v_num3
          FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'TBSPC' AND series = 'FIX_SPIKE'
            AND baseline_mode = 'TRAILING' AND ts = d_spike;
        chk_close('SPIKE avg_value = SPIKE_RATE', v_num, n_rate, 0.000001);
        chk_int  ('SPIKE avg_days (calendar days the average covers)', v_n, n_avgd);
        chk_close('SPIKE pct_vs_expected (TRAILING)', v_num2, n_pct, 0.000001);
        chk_close('SPIKE pct_vs_avg',    v_num3, n_pct, 0.000001);

        -- Injected Tuesday: 70% busy vs the 40% weekday median -> +75%.
        SELECT pct_vs_expected INTO v_num FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'SAME_DOW' AND ts = d_inj;
        chk_close('CPU injected Tuesday pct_vs_expected (SAME_DOW)', v_num, 100 * (70 - 40) / 40, 0.000001);

        -- FIX_PURGE cliff: baseline growth LINEAR_SLOPE (1280 blocks = 10
        -- MiB/day); the cliff day's delta is that growth minus the 76800-block
        -- (600 MiB) purge. Closed form 100 * (-76800 * 8192) / LINEAR_SLOPE = -6000.
        SELECT pct_vs_avg INTO v_num FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'TBSPC' AND series = 'FIX_PURGE'
            AND baseline_mode = 'TRAILING' AND ts = d_purge;
        chk_close('PURGE cliff day pct_vs_avg',
                  v_num, 100 * ((n_slope - 76800 * 8192) - n_slope) / n_slope, 0.000001);

        -- CAPR_ALERTS messages carry the percentages.
        snap_alerts;
        SELECT message INTO v_msg FROM cap_fixture_alerts_snap
          WHERE kind = 'TBSPC_ANOM' AND series_key = 'FIX_SPIKE' AND day_dt = d_spike;
        chk_true('SPIKE TBSPC_ANOM message has "+' || n_pct || '% vs ' || n_train
                 || '-day avg rate" (got: ' || v_msg || ')',
                 INSTR(v_msg, '+' || TO_CHAR(n_pct, 'FM999999990') || '% vs '
                              || TO_CHAR(n_train, 'FM9990') || '-day avg rate') > 0);
        SELECT message INTO v_msg FROM cap_fixture_alerts_snap
          WHERE kind = 'CPU_ANOM' AND series_key = 'BUSY_PCT' AND day_dt = d_inj;
        chk_true('CPU_ANOM message has "+75% vs median" (got: ' || v_msg || ')',
                 INSTR(v_msg, '(+75% vs median)') > 0);

        -- Report views pass the CAPA numbers through unchanged.
        SELECT r.avg_mb, r.avg_days, r.pct_vs_med, r.pct_vs_avg, a.pct_vs_expected, a.pct_vs_avg
          INTO v_num, v_n, v_num2, v_num3, v_r2, n_capa
          FROM capr_tbspc_anomalies r
          JOIN capa_anom a
            ON a.dbid = r.dbid AND a.con_dbid = r.con_dbid AND a.kind = 'TBSPC'
           AND a.series = r.tablespace_name AND a.ts = r.day_dt
           AND a.baseline_mode = r.baseline_mode
          WHERE r.tablespace_name = 'FIX_SPIKE' AND r.day_dt = d_spike
            AND r.baseline_mode = 'TRAILING';
        chk_close('CAPR_TBSPC_ANOMALIES SPIKE avg_mb = 5', v_num, n_rate / 1048576, 0.000001);
        chk_int  ('CAPR_TBSPC_ANOMALIES SPIKE avg_days', v_n, n_avgd);
        chk_close('CAPR_TBSPC_ANOMALIES SPIKE pct_vs_med = CAPA', v_num2, v_r2, 0.000001);
        chk_close('CAPR_TBSPC_ANOMALIES SPIKE pct_vs_avg = CAPA', v_num3, n_capa, 0.000001);
        SELECT r.pct_vs_med, a.pct_vs_expected INTO v_num, v_num2
          FROM capr_cpu_anomalies r
          JOIN capa_anom a
            ON a.dbid = r.dbid AND a.con_dbid = r.con_dbid AND a.kind = 'CPU'
           AND a.series = r.metric AND a.baseline_mode = r.baseline_mode AND a.ts = r.ts
          WHERE r.dbid = v_dbid AND r.con_dbid = v_dbid AND r.metric = 'BUSY_PCT'
            AND r.baseline_mode = 'SAME_DOW' AND r.ts = d_inj;
        chk_close('CAPR_CPU_ANOMALIES Tuesday pct_vs_med = CAPA', v_num, v_num2, 0.000001);
    EXCEPTION
        WHEN OTHERS THEN
            fail('anomaly-% block raised ' || SQLERRM);
    END;

    -- M11 uses a local DATE for the last collected day: meta_d() is a nested
    -- PL/SQL function and cannot be called from inside a SQL statement
    -- (PLS-00231), so the value is resolved once here.
    DECLARE
        d_last DATE := meta_d('LAST_DAY');
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== M11 seam (CAPV_RESOURCE_LIMIT / CAPV_SYSSTAT) ===');
        -- 241 snapshots exist (two a day for 121 days, minus the missing 06:00 of
        -- the restart day) x 2 resource names.
        SELECT COUNT(*) INTO v_n FROM capv_resource_limit;
        chk_int('CAPV_RESOURCE_LIMIT rows (241 snaps x 2 resources)', v_n, 482);
        SELECT COUNT(*) INTO v_n FROM capv_resource_limit
          WHERE resource_name NOT IN ('sessions','processes');
        chk_int('CAPV_RESOURCE_LIMIT carries only sessions/processes', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capv_sysstat WHERE stat_name = 'redo size';
        chk_int('CAPV_SYSSTAT redo-size rows', v_n, 241);

        DBMS_OUTPUT.PUT_LINE('=== M11.1 processes / sessions vs their limits ===');
        SELECT value, limit_value, unit INTO v_num, v_num2, v_str
          FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'SESSIONS' AND day_dt = d_last;
        chk_int('SESSIONS last-day value (max_utilization)', v_num,  meta_n('SESS_CUR'));
        chk_int('SESSIONS last-day limit_value',            v_num2, meta_n('SESS_LIMIT'));
        chk_str('SESSIONS unit', v_str, 'COUNT');
        SELECT slope_per_day, days_to_limit, quality INTO v_num, v_n, v_str
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'SESSIONS';
        chk_close('SESSIONS slope/day', v_num, 2, 0.000001);
        chk_int  ('SESSIONS days_to_limit (90% of 500)', v_n, meta_n('SESS_DTL'));
        chk_str  ('SESSIONS quality', v_str, 'OK');
        SELECT pct_of_limit, r2 INTO v_num, v_r2
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'SESSIONS';
        chk_close('SESSIONS pct_of_limit (440/500)', v_num, 88, 0.000001);
        chk_true ('SESSIONS r2 > 0.999', v_r2 > 0.999);
        SELECT cur_val, cur_limit, quality INTO v_num, v_num2, v_str
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'PROCESSES';
        chk_int('PROCESSES cur_val',   v_num,  meta_n('PROC_CUR'));
        chk_int('PROCESSES cur_limit', v_num2, meta_n('PROC_LIMIT'));
        chk_str('PROCESSES quality (constant -> FLAT)', v_str, 'FLAT');
        SELECT COUNT(*) INTO v_n FROM capf_series_forecast
          WHERE dbid = v_dbid AND series = 'PROCESSES' AND days_to_limit IS NULL;
        chk_int('PROCESSES has no days_to_limit (not growing)', v_n, 1);

        DBMS_OUTPUT.PUT_LINE('=== M11.2 redo GiB/day ===');
        SELECT value, unit INTO v_num, v_str FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND day_dt = d_probe;
        chk_close('REDO probe-day GiB (2 x 1 GiB intervals)', v_num, meta_n('REDO_PROBE_GB'), 0.000001);
        chk_str  ('REDO unit', v_str, 'GIB_PER_DAY');
        -- Same restart guard as the CPU counters: that day's only interval spans
        -- the restart, so the day drops out entirely rather than reading -240 GiB.
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND day_dt = d_restart;
        chk_int('REDO restart day excluded', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND limit_value IS NOT NULL;
        chk_int('REDO has no ceiling', v_n, 0);
        SELECT quality, days_to_limit INTO v_str, v_num
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'REDO_GB_DAY';
        chk_str ('REDO quality (2 GiB/day flat)', v_str, 'FLAT');
        chk_true('REDO days_to_limit IS NULL (no ceiling)', v_num IS NULL);

        DBMS_OUTPUT.PUT_LINE('=== M11.3 total DB size ===');
        -- The identity, re-derived here rather than pre-computed: DB_SIZE_GB is
        -- exactly the sum of what CAPD_TBSPC_DAILY reports that day (so excluded
        -- and UNDO/TEMP tablespaces are out of it by construction).
        SELECT value, limit_value INTO v_num, v_num2 FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'DB_SIZE_GB' AND day_dt = d_last;
        SELECT SUM(used_bytes) / 1073741824, SUM(limit_bytes) / 1073741824
          INTO v_num3, v_r2
          FROM capd_tbspc_daily WHERE dbid = v_dbid AND day_dt = d_last;
        chk_close('DB_SIZE_GB = SUM(used_bytes)/2^30',        v_num,  v_num3, 0.000001);
        chk_close('DB_SIZE_GB limit = SUM(limit_bytes)/2^30', v_num2, v_r2,   0.000001);
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'DB_SIZE_GB' AND day_dt = d_last;
        chk_int('DB_SIZE_GB one row per container-day', v_n, 1);
        SELECT slope_per_day, quality INTO v_num, v_str
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'DB_SIZE_GB';
        chk_true('DB_SIZE_GB slope > 0 (got ' || ROUND(v_num, 4) || ' GiB/day)', v_num > 0);
        -- The fixture total is the sum of several linear series plus FIX_SPIKE's
        -- step, FIX_GAP's missing days and FIX_PURGE's cliff, so it is growing but
        -- not perfectly straight: assert the grade is fittable, not that it is OK.
        chk_true('DB_SIZE_GB quality fittable (got ' || v_str || ')',
                 v_str IN ('OK','LOW_CONFIDENCE'));

        DBMS_OUTPUT.PUT_LINE('=== M11 alerts + CAPR_SERIES ===');
        snap_alerts;
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
          WHERE kind = 'SERIES_LIMIT' AND series_key = 'SESSIONS'
            AND severity = 'CRIT' AND db_pdb = 'FIXCDB';
        chk_int('SESSIONS raises SERIES_LIMIT CRIT (db_pdb FIXCDB)', v_n, 1);
        SELECT value INTO v_num FROM cap_fixture_alerts_snap
          WHERE kind = 'SERIES_LIMIT' AND series_key = 'SESSIONS';
        chk_int('SERIES_LIMIT value = days_to_limit', v_num, meta_n('SESS_DTL'));
        -- ASM_DG:+DATA (20 days to 90%) is the one other SERIES_LIMIT and
        -- TEMP_PEAK:FIX_TEMP (97.5% now) the one SERIES_NEARLIMIT. Both are
        -- asserted in the seam-extension block below.
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
          WHERE kind = 'SERIES_LIMIT' AND series_key IN ('PROCESSES','REDO_GB_DAY','DB_SIZE_GB');
        chk_int('no SERIES_LIMIT for PROCESSES / REDO_GB_DAY / DB_SIZE_GB', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
          WHERE kind = 'SERIES_LIMIT' AND series_key NOT IN ('SESSIONS','ASM_DG:+DATA');
        chk_int('SERIES_LIMIT only for SESSIONS and ASM_DG:+DATA', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
          WHERE series_key IN ('IOPS', 'IO_MBPS');
        chk_int('no alert of any kind for IOPS / IO_MBPS', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
          WHERE kind = 'SERIES_NEARLIMIT' AND series_key = 'SESSIONS';
        chk_int('no SERIES_NEARLIMIT for SESSIONS (88%, under 90)', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
          WHERE kind = 'SERIES_NEARLIMIT' AND series_key <> 'TEMP_PEAK:FIX_TEMP';
        chk_int('SERIES_NEARLIMIT only for TEMP_PEAK:FIX_TEMP', v_n, 0);
        SELECT COUNT(*) INTO v_n   FROM capr_series;
        SELECT COUNT(*) INTO v_num FROM capf_series_forecast;
        chk_int('CAPR_SERIES row count = CAPF_SERIES_FORECAST', v_n, v_num);
        SELECT sev, rank_series INTO v_str, v_num
          FROM capr_series WHERE dbid = v_dbid AND series = 'SESSIONS';
        chk_str('CAPR_SERIES SESSIONS sev', v_str, 'CRIT');
        chk_int('CAPR_SERIES SESSIONS ranks first', v_num, 1);
        SELECT COUNT(*) INTO v_n FROM capr_series WHERE db_pdb <> 'FIXCDB';
        chk_int('CAPR_SERIES resolves db_pdb', v_n, 0);
    END;

    -- M27 I/O series. The fixture's closed form (test/fixture_install.sql):
    -- a night interval at IOPS_NIGHT / IO_MBPS_NIGHT and a day interval at
    -- IOPS_DAY0 + 10 * i / IO_MBPS_DAY, so the day's p95 of its two interval
    -- rates is lo + 0.95 * (hi - lo): IOPS = IOPS_BASE + IOPS_SLOPE * i and
    -- IO_MBPS = IO_MBPS_P95 on every complete day.
    DECLARE
        d_last  DATE   := meta_d('LAST_DAY');
        d_base  DATE   := meta_d('BASE_DAY');
        d_part  DATE   := meta_d('PARTIAL_DAY');
        n_days  NUMBER := meta_d('LAST_DAY') - meta_d('BASE_DAY') + 1;
        n_base  NUMBER := meta_n('IOPS_BASE');
        n_slp   NUMBER := meta_n('IOPS_SLOPE');
        n_mb    NUMBER := meta_n('IO_MBPS_P95');
        n_pdb   NUMBER := meta_n('PDB_CON_DBID');
        v_u     VARCHAR2(40);
        v_c     VARCHAR2(1);
        v_lim   NUMBER;
        v_cov   NUMBER;
        v_ivl   NUMBER;
        d_row   DATE;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== M27 I/O series (IOPS / IO_MBPS) ===');
        SELECT COUNT(*), COUNT(DISTINCT stat_name) INTO v_n, v_num FROM capv_sysstat
          WHERE stat_name IN ('physical read total IO requests', 'physical write total IO requests',
                              'physical read total bytes', 'physical write total bytes');
        chk_int('CAPV_SYSSTAT I/O rows (241 snaps x 4 counters)', v_n, 964);
        chk_int('CAPV_SYSSTAT I/O counter names', v_num, 4);

        SELECT value, unit, limit_value, n_samples, covered_sec, is_complete, max_interval_hours
          INTO v_num, v_u, v_lim, v_n, v_cov, v_c, v_ivl
          FROM capd_series_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND series = 'IOPS' AND day_dt = d_probe;
        chk_close('IOPS probe day = p95 of the night and day interval rates',
                  v_num, n_base + n_slp * (d_probe - d_base), 0.000000001);
        chk_str  ('IOPS unit', v_u, 'IO_PER_SEC');
        chk_true ('IOPS has no ceiling on the probe day', v_lim IS NULL);
        chk_int  ('IOPS probe day n_samples (two snapshots)', v_n, 2);
        chk_int  ('IOPS probe day covered_sec', v_cov, 86400);
        chk_str  ('IOPS probe day is_complete', v_c, 'Y');
        chk_int  ('IOPS probe day max_interval_hours', v_ivl, 12);
        SELECT value, unit, limit_value, n_samples, covered_sec, is_complete
          INTO v_num, v_u, v_lim, v_n, v_cov, v_c
          FROM capd_series_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND series = 'IO_MBPS' AND day_dt = d_probe;
        chk_close('IO_MBPS probe day = p95 of 20 and 50 MB/s', v_num, n_mb, 0.000000001);
        chk_str  ('IO_MBPS unit', v_u, 'MB_PER_SEC');
        chk_true ('IO_MBPS has no ceiling on the probe day', v_lim IS NULL);
        chk_int  ('IO_MBPS probe day n_samples (two snapshots)', v_n, 2);
        chk_int  ('IO_MBPS probe day covered_sec', v_cov, 86400);
        chk_str  ('IO_MBPS probe day is_complete', v_c, 'Y');

        -- Every complete day, not only the probe day.
        SELECT COUNT(*), COUNT(CASE WHEN ABS(value - (n_base + n_slp * (day_dt - d_base))) > 0.000001 THEN 1 END)
          INTO v_n, v_num
          FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'IOPS' AND is_complete = 'Y';
        chk_int('IOPS complete days (all but day 0, the restart and the partial day)', v_n, n_days - 3);
        chk_int('IOPS complete days off the closed form', v_num, 0);
        SELECT COUNT(*), COUNT(CASE WHEN ABS(value - n_mb) > 0.000001 THEN 1 END)
          INTO v_n, v_num
          FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'IO_MBPS' AND is_complete = 'Y';
        chk_int('IO_MBPS complete days', v_n, n_days - 3);
        chk_int('IO_MBPS complete days off the closed form', v_num, 0);

        -- One valid interval: the day reads that interval's rate, incomplete.
        SELECT value, covered_sec, is_complete INTO v_num, v_cov, v_c FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'IOPS' AND day_dt = d_part;
        chk_close('IOPS partial day = the night interval rate', v_num, meta_n('IOPS_NIGHT'), 0.000000001);
        chk_int  ('IOPS partial day covered_sec', v_cov, 43200);
        chk_str  ('IOPS partial day is_complete', v_c, 'N');
        SELECT value, is_complete INTO v_num, v_c FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'IO_MBPS' AND day_dt = d_part;
        chk_close('IO_MBPS partial day = the night interval rate', v_num, meta_n('IO_MBPS_NIGHT'), 0.000000001);
        chk_str  ('IO_MBPS partial day is_complete', v_c, 'N');
        SELECT value, is_complete INTO v_num, v_c FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'IOPS' AND day_dt = d_base;
        chk_close('IOPS first day = the day interval rate', v_num, meta_n('IOPS_DAY0'), 0.000000001);
        chk_str  ('IOPS first day is_complete', v_c, 'N');
        SELECT value, is_complete INTO v_num, v_c FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'IO_MBPS' AND day_dt = d_base;
        chk_close('IO_MBPS first day = the day interval rate', v_num, meta_n('IO_MBPS_DAY'), 0.000000001);
        chk_str  ('IO_MBPS first day is_complete', v_c, 'N');
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE dbid = v_dbid AND series IN ('IOPS', 'IO_MBPS') AND day_dt = d_restart;
        chk_int('IOPS / IO_MBPS restart day excluded', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE series IN ('IOPS', 'IO_MBPS') AND (limit_value IS NOT NULL OR gap_flag = 'Y' OR value < 0);
        chk_int('IOPS / IO_MBPS: no ceiling, no gap day, no negative rate', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE series IN ('IOPS', 'IO_MBPS') AND (dbid <> v_dbid OR con_dbid <> v_dbid);
        chk_int('IOPS / IO_MBPS only where the fixture has I/O counters (the root)', v_n, 0);

        -- The fit: IOPS a straight line, IO_MBPS constant.
        SELECT train_n, slope_per_day, r2, quality, cur_val, proj_30, days_to_limit, cur_limit, pct_of_limit
          INTO v_n, v_num, v_r2, v_str, v_num2, v_num3, v_lim, v_cov, v_ivl
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'IOPS';
        chk_int  ('IOPS train_n = the REDO_GB_DAY training days', v_n, meta_n('REDO_TRAIN_N'));
        chk_close('IOPS slope_per_day (0.95 x 10 a day)', v_num, n_slp, 0.000000001);
        chk_close('IOPS r2 (a straight line)', v_r2, 1, 0.000000001);
        chk_str  ('IOPS quality', v_str, 'OK');
        chk_close('IOPS cur_val', v_num2, meta_n('IOPS_CUR'), 0.000000001);
        chk_close('IOPS proj_30 = cur_val + 30 x slope', v_num3, meta_n('IOPS_CUR') + 30 * n_slp, 0.000000001);
        chk_true ('IOPS days_to_limit / cur_limit / pct_of_limit NULL (no ceiling)',
                  v_lim IS NULL AND v_cov IS NULL AND v_ivl IS NULL);
        SELECT train_n, slope_per_day, quality, cur_val, days_to_limit
          INTO v_n, v_num, v_str, v_num2, v_lim
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'IO_MBPS';
        chk_int  ('IO_MBPS train_n', v_n, meta_n('REDO_TRAIN_N'));
        chk_close('IO_MBPS slope_per_day (constant)', v_num, 0, 0.000000001);
        chk_str  ('IO_MBPS quality (constant -> FLAT)', v_str, 'FLAT');
        chk_close('IO_MBPS cur_val', v_num2, n_mb, 0.000000001);
        chk_true ('IO_MBPS days_to_limit NULL (no ceiling)', v_lim IS NULL);
        SELECT COUNT(*), MIN(sev) INTO v_n, v_str FROM capr_series
          WHERE dbid = v_dbid AND series IN ('IOPS', 'IO_MBPS');
        chk_int('CAPR_SERIES lists IOPS and IO_MBPS', v_n, 2);
        chk_str('CAPR_SERIES IOPS / IO_MBPS sev', v_str, 'OK');
        SELECT COUNT(*) INTO v_n FROM capr_severity
          WHERE fit_kind = 'SERIES' AND series_key IN ('IOPS', 'IO_MBPS') AND sev <> 'OK';
        chk_int('CAPR_SEVERITY: no IOPS / IO_MBPS row above OK', v_n, 0);

        -- Anomaly layer: scored on the level, floored by the two knobs, and a
        -- straight line or a constant never flags.
        SELECT COUNT(*), MIN(thr_floor), MAX(thr_floor), MIN(unit), MIN(anomaly_kind), MIN(alert_kind)
          INTO v_n, v_num, v_num2, v_u, v_str, v_str2
          FROM capa_obs WHERE kind = 'SERIES' AND series = 'IOPS';
        chk_int('CAPA_OBS IOPS rows (every day but the restart day)', v_n, n_days - 1);
        chk_true('CAPA_OBS IOPS thr_floor = series_floor_iops 100', v_num = 100 AND v_num2 = 100);
        chk_str ('CAPA_OBS IOPS unit', v_u, 'IO_PER_SEC');
        chk_str ('CAPA_OBS IOPS anomaly_kind', v_str, 'SERIES_LEVEL');
        chk_str ('CAPA_OBS IOPS alert_kind', v_str2, 'SERIES_ANOM');
        SELECT COUNT(*), MIN(thr_floor), MAX(thr_floor), MIN(unit) INTO v_n, v_num, v_num2, v_u
          FROM capa_obs WHERE kind = 'SERIES' AND series = 'IO_MBPS';
        chk_int('CAPA_OBS IO_MBPS rows', v_n, n_days - 1);
        chk_true('CAPA_OBS IO_MBPS thr_floor = series_floor_mbps 10', v_num = 10 AND v_num2 = 10);
        chk_str ('CAPA_OBS IO_MBPS unit', v_u, 'MB_PER_SEC');
        SELECT COUNT(*), COUNT(anomaly_flag) INTO v_n, v_num FROM capa_anom
          WHERE kind = 'SERIES' AND series IN ('IOPS', 'IO_MBPS');
        chk_int('CAPA_ANOM IOPS / IO_MBPS rows (2 series x 2 day modes)', v_n, 4 * (n_days - 1));
        chk_int('IOPS / IO_MBPS never flag', v_num, 0);
        SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'series_floor_iops';
        chk_str('CAP_CFG_CHECK series_floor_iops', v_str, 'OK');
        SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'series_floor_mbps';
        chk_str('CAP_CFG_CHECK series_floor_mbps', v_str, 'OK');
        SAVEPOINT m27_knob;
        BEGIN
            knob('series_floor_iops', -1);
            SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'series_floor_iops';
            chk_str('CAP_CFG_CHECK series_floor_iops -1', v_str, 'BAD');
            knob('series_floor_iops', 250);
            SELECT MIN(thr_floor) INTO v_num FROM capa_obs WHERE kind = 'SERIES' AND series = 'IOPS';
            chk_int('series_floor_iops 250 -> CAPA_OBS thr_floor', v_num, 250);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT m27_knob; RAISE;
        END;
        ROLLBACK TO SAVEPOINT m27_knob;

        -- Per container, and one side of a pair is enough: FIXPDB1 gets read
        -- requests only on the last three snapshots (AWR writes no row for a
        -- statistic still zero since startup), 100/s over the night and
        -- 300/s over the day: p95 = 100 + 0.95 x 200 = 290. A write counter
        -- that first appears on the last snapshot has no predecessor and
        -- adds nothing. No byte counters: no IO_MBPS row for the PDB.
        SAVEPOINT m27_pdb;
        BEGIN
            INSERT INTO cap_fixture_sysstat VALUES (v_dbid, n_pdb, 1, 2001 + 2 * (n_days - 2), 'physical read total IO requests', 0);
            INSERT INTO cap_fixture_sysstat VALUES (v_dbid, n_pdb, 1, 2000 + 2 * (n_days - 1), 'physical read total IO requests', 100 * 43200);
            INSERT INTO cap_fixture_sysstat VALUES (v_dbid, n_pdb, 1, 2001 + 2 * (n_days - 1), 'physical read total IO requests', 400 * 43200);
            INSERT INTO cap_fixture_sysstat VALUES (v_dbid, n_pdb, 1, 2001 + 2 * (n_days - 1), 'physical write total IO requests', 999999999);
            SELECT COUNT(*), MAX(value), MAX(n_samples), MAX(day_dt) INTO v_n, v_num, v_num2, d_row
              FROM capd_series_daily
              WHERE dbid = v_dbid AND con_dbid = n_pdb AND series = 'IOPS';
            chk_int  ('FIXPDB1 IOPS rows (the last day only)', v_n, 1);
            chk_true ('FIXPDB1 IOPS row is the last day', d_row = d_last);
            chk_close('FIXPDB1 IOPS = 100 + 0.95 x 200 (read side only)', v_num, 290, 0.000000001);
            chk_int  ('FIXPDB1 IOPS n_samples', v_num2, 2);
            SELECT COUNT(*) INTO v_n FROM capd_series_daily
              WHERE dbid = v_dbid AND con_dbid = n_pdb AND series = 'IO_MBPS';
            chk_int('FIXPDB1 has no IO_MBPS row (no byte counters)', v_n, 0);
            SELECT value INTO v_num FROM capd_series_daily
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND series = 'IOPS' AND day_dt = d_last;
            chk_close('root IOPS on the last day unchanged by the PDB rows', v_num, meta_n('IOPS_CUR'), 0.000000001);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT m27_pdb; RAISE;
        END;
        ROLLBACK TO SAVEPOINT m27_pdb;
    END;

    -- RAC worst instance (PROCESSES / SESSIONS). The main fixture is one
    -- instance, so a second dbid with TWO instances is added to the snapshot
    -- and resource-limit fixture tables for this block only and DELETEd at its
    -- end (no commit in between, nothing else sees it). Per instance and day,
    -- limit 1000 each: SESSIONS inst 1 at 10, inst 2 at 990 (fleet 50%,
    -- worst instance 99% on instance 2); PROCESSES inst 1 at 600, inst 2 at
    -- 400 (fleet 50%, worst 60%, instance 1).
    DECLARE
        c_rac   CONSTANT NUMBER := 43434343;
        d_last  DATE := meta_d('LAST_DAY');
        v_inst  NUMBER;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== RAC worst instance (two-instance dbid) ===');
        FOR k IN 0 .. 2 LOOP
            FOR i IN 1 .. 2 LOOP
                INSERT INTO cap_fixture_snapshot
                VALUES (c_rac, c_rac, i, 9000000 + k,
                        CAST(d_last - 2 + k + 17 / 24 AS TIMESTAMP),
                        CAST(d_last - 2 + k + 18 / 24 AS TIMESTAMP),
                        CAST(d_last - 40 AS TIMESTAMP));
                INSERT INTO cap_fixture_resource_limit
                VALUES (c_rac, c_rac, i, 9000000 + k, 'sessions',
                        DECODE(i, 1, 8, 980), DECODE(i, 1, 10, 990), 1000);
                INSERT INTO cap_fixture_resource_limit
                VALUES (c_rac, c_rac, i, 9000000 + k, 'processes',
                        DECODE(i, 1, 500, 300), DECODE(i, 1, 600, 400), 1000);
            END LOOP;
        END LOOP;

        SELECT value, limit_value, worst_inst_pct, worst_inst INTO v_num, v_num2, v_num3, v_inst
          FROM capd_series_daily
         WHERE dbid = c_rac AND series = 'SESSIONS' AND day_dt = d_last;
        chk_int('RAC SESSIONS fleet value (10 + 990)',         v_num,  1000);
        chk_int('RAC SESSIONS fleet limit (1000 + 1000)',      v_num2, 2000);
        chk_close('RAC SESSIONS daily worst_inst_pct',         v_num3, 99, 0.000001);
        chk_int('RAC SESSIONS daily worst_inst',               v_inst, 2);
        SELECT pct_of_limit, worst_inst_pct, worst_inst INTO v_num, v_num2, v_inst
          FROM capf_series_forecast WHERE dbid = c_rac AND series = 'SESSIONS';
        chk_close('RAC SESSIONS pct_of_limit stays the fleet 50', v_num,  50, 0.000001);
        chk_close('RAC SESSIONS forecast worst_inst_pct',         v_num2, 99, 0.000001);
        chk_int('RAC SESSIONS forecast worst_inst',               v_inst, 2);
        SELECT worst_inst_pct, worst_inst INTO v_num, v_inst
          FROM capf_series_forecast WHERE dbid = c_rac AND series = 'PROCESSES';
        chk_close('RAC PROCESSES worst_inst_pct', v_num, 60, 0.000001);
        chk_int('RAC PROCESSES worst_inst',       v_inst, 1);

        SELECT sev, value, SUBSTR(sev_reason, 1, 14), message
          INTO v_str, v_num, v_str2, v_msg
          FROM capr_severity
         WHERE dbid = c_rac AND kind = 'SERIES_NEARLIMIT' AND series_key = 'SESSIONS';
        chk_str  ('RAC SESSIONS SERIES_NEARLIMIT sev (node at 99, fleet 50)', v_str, 'CRIT');
        chk_close('RAC SESSIONS SERIES_NEARLIMIT value = worst instance pct', v_num, 99, 0.000001);
        chk_str  ('RAC SESSIONS sev_reason names worst_inst_pct', v_str2, 'worst_inst_pct');
        chk_true ('RAC SESSIONS message names instance 2 (got ' || SUBSTR(v_msg, 1, 90) || ')',
                  INSTR(v_msg, 'SESSIONS on instance 2 is at 99.0% of its own limit') = 1);
        SELECT sev INTO v_str FROM capr_severity
         WHERE dbid = c_rac AND kind = 'SERIES_NEARLIMIT' AND series_key = 'PROCESSES';
        chk_str('RAC PROCESSES SERIES_NEARLIMIT sev (worst 60, fleet 50)', v_str, 'OK');
        SELECT COUNT(*) INTO v_n FROM capr_alerts
         WHERE dbid = c_rac AND kind = 'SERIES_NEARLIMIT' AND series_key = 'SESSIONS'
           AND severity = 'CRIT';
        chk_int('RAC SESSIONS raises one SERIES_NEARLIMIT CRIT alert', v_n, 1);
        SELECT COUNT(*) INTO v_n FROM capr_series
         WHERE dbid = c_rac AND series = 'SESSIONS' AND sev = 'CRIT' AND worst_inst_pct = 99;
        chk_int('CAPR_SERIES SESSIONS CRIT with worst_inst_pct 99', v_n, 1);

        -- Single instance: the worst instance IS the fleet (the main fixture).
        SELECT COUNT(*) INTO v_n FROM capf_series_forecast
         WHERE dbid = v_dbid AND series IN ('SESSIONS', 'PROCESSES', 'PGA_ALLOC_GB')
           AND worst_inst = 1 AND worst_inst_pct = pct_of_limit;
        chk_int('single instance: worst_inst_pct = pct_of_limit, instance 1', v_n, 3);
        SELECT COUNT(*) INTO v_n FROM capf_series_forecast
         WHERE dbid = v_dbid AND series NOT IN ('SESSIONS', 'PROCESSES', 'PGA_ALLOC_GB')
           AND (worst_inst_pct IS NOT NULL OR worst_inst IS NOT NULL);
        chk_int('worst instance is NULL off PROCESSES / SESSIONS / PGA_ALLOC_GB', v_n, 0);

        DELETE FROM cap_fixture_resource_limit WHERE dbid = c_rac;
        DELETE FROM cap_fixture_snapshot       WHERE dbid = c_rac;
        SELECT COUNT(*) INTO v_n FROM capf_series_forecast WHERE dbid = c_rac;
        chk_int('RAC fixture rows removed again', v_n, 0);
    END;

    -- Seam extensions: CAPV_PARAMETER and the cpu_count ceiling, FRA days on
    -- REDO_GB_DAY, the ASM_DG / TEMP_PEAK / UNDO_PEAK series and the
    -- tablespace sizing ask. Closed forms recorded by fixture_install.sql.
    DECLARE
        d_last  DATE   := meta_d('LAST_DAY');
        n_probe NUMBER := meta_n('PROBE_DAY');
        n_caged NUMBER := meta_n('CPU_COUNT_CAGED');
        n_pdbc  NUMBER := meta_n('PDB_CON_DBID');
        n_snaps NUMBER := 2 * (meta_d('LAST_DAY') - meta_d('BASE_DAY') + 1) - 1;
        n_days  NUMBER := meta_d('LAST_DAY') - meta_d('BASE_DAY') + 1;
        v_c     VARCHAR2(1);
        v_q     VARCHAR2(30);
        v_dt    DATE;
        v_dt2   DATE;
        v_a     NUMBER;
        v_b     NUMBER;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== CAPV_PARAMETER and the cpu_count ceiling ===');
        SELECT COUNT(*) INTO v_n FROM capv_parameter WHERE parameter_name = 'cpu_count';
        chk_int('CAPV_PARAMETER cpu_count rows (one per snapshot)', v_n, n_snaps);
        SELECT COUNT(DISTINCT parameter_name) INTO v_n FROM capv_parameter;
        chk_int('CAPV_PARAMETER parameter names', v_n, 9);
        SELECT COUNT(*) INTO v_n FROM capv_parameter WHERE con_dbid <> dbid;
        chk_int('CAPV_PARAMETER rows with con_dbid <> dbid', v_n, 0);
        SELECT cpu_count, cpu_ceiling, num_cpus, db_cpu_pct INTO v_num, v_num2, v_num3, v_a
          FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
        chk_int  ('DBTIME probe cpu_count', v_num, meta_n('CPU_COUNT'));
        chk_int  ('DBTIME probe cpu_ceiling = LEAST(num_cpus 8, cpu_count 8)', v_num2, meta_n('NUM_CPUS'));
        chk_int  ('DBTIME probe num_cpus stays the host count', v_num3, meta_n('NUM_CPUS'));
        chk_close('DBTIME probe db_cpu_pct unchanged (cpu_count = NUM_CPUS)',
                  v_a, meta_n('DBCPU_PROBE_PCT'), 0.000001);
        SELECT COUNT(*) INTO v_n FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND (cpu_ceiling IS NULL OR cpu_ceiling <> num_cpus);
        chk_int('DBTIME cpu_ceiling = num_cpus on every day (all containers)', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capd_dbtime_interval
          WHERE dbid = v_dbid
            AND (cpu_ceiling IS NULL OR cpu_ceiling <> num_cpus OR cap_sec <> num_cpus * ivl_sec);
        chk_int('DBTIME_INTERVAL cpu_ceiling = num_cpus, cap_sec = num_cpus * ivl_sec', v_n, 0);
        -- A cage of half the host on the probe day: both of its intervals
        -- end on a snapshot with cpu_count 4, so every percentage doubles.
        SAVEPOINT u8_cage;
        BEGIN
            UPDATE cap_fixture_parameter SET value_num = n_caged
             WHERE parameter_name = 'cpu_count'
               AND snap_id IN (2000 + 2 * n_probe, 2001 + 2 * n_probe);
            SELECT cpu_count, cpu_ceiling, num_cpus INTO v_num, v_num2, v_num3
              FROM capd_dbtime_daily
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
            chk_int('caged probe day cpu_count', v_num, n_caged);
            chk_int('caged probe day cpu_ceiling = LEAST(8, 4)', v_num2, n_caged);
            chk_int('caged probe day num_cpus unchanged', v_num3, meta_n('NUM_CPUS'));
            SELECT db_cpu_pct, db_cpu_peak_pct, db_cpu_max_pct INTO v_num, v_num2, v_num3
              FROM capd_dbtime_daily
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
            chk_close('caged probe day db_cpu_pct (400 s over 4 CPUs)',
                      v_num, meta_n('DBCPU_PROBE_PCT_CAGED'), 0.000001);
            chk_close('caged probe day db_cpu_pct = 2 x uncaged',
                      v_num, 2 * meta_n('DBCPU_PROBE_PCT'), 0.000001);
            chk_close('caged probe day db_cpu_peak_pct (300 s over 4 * 43200)',
                      v_num2, meta_n('DBCPU_PROBE_PEAK_PCT_CAGED'), 0.000001);
            chk_close('caged probe day db_cpu_max_pct (the 18:00 interval)',
                      v_num3, meta_n('DBCPU_PROBE_PEAK_PCT_CAGED'), 0.000001);
            SELECT COUNT(*) INTO v_n FROM capd_dbtime_daily
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND cpu_ceiling = n_caged;
            chk_int('only the probe day is caged', v_n, 1);
            -- The cage lives in CAPD_DBTIME_INTERVAL, so the hour grain (and
            -- the HOUR_OF_WEEK baseline) reads against it too, and it serves
            -- every container: cpu_count is instance level.
            SELECT cpu_count, cpu_ceiling, cap_sec INTO v_num, v_num2, v_num3
              FROM capd_dbtime_interval
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND snap_id = 2001 + 2 * n_probe;
            chk_int  ('caged probe 18:00 interval cpu_count', v_num, n_caged);
            chk_int  ('caged probe 18:00 interval cpu_ceiling', v_num2, n_caged);
            chk_close('caged probe 18:00 interval cap_sec = 4 * 43200', v_num3, n_caged * 43200, 0.000001);
            SELECT value INTO v_num FROM capd_cpu_hourly
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'DB_CPU_PCT' AND hour_ts = d_probe + 18/24;
            chk_close('caged probe 18:00 root hourly DB_CPU_PCT (300 s over 4 * 43200)',
                      v_num, meta_n('DBCPU_PROBE_PEAK_PCT_CAGED'), 0.000001);
            SELECT MIN(value), MAX(value) INTO v_num, v_num2 FROM capd_cpu_hourly
              WHERE dbid = v_dbid AND con_dbid = n_pdbc AND metric = 'DB_CPU_PCT'
                AND hour_ts IN (d_probe + 6/24, d_probe + 18/24);
            chk_close('caged probe PDB hourly DB_CPU_PCT 06:00 = 2 x pdb_pct(probe)',
                      v_num,  2 * meta_n('PDB_PROBE_PCT'), 0.000001);
            chk_close('caged probe PDB hourly DB_CPU_PCT 18:00 = 2 x pdb_pct(probe)',
                      v_num2, 2 * meta_n('PDB_PROBE_PCT'), 0.000001);
            SELECT db_cpu_pct INTO v_num FROM capd_dbtime_daily
              WHERE dbid = v_dbid AND con_dbid = n_pdbc AND day_dt = d_probe;
            chk_close('caged probe PDB db_cpu_pct = 2 x pdb_pct(probe)',
                      v_num, 2 * meta_n('PDB_PROBE_PCT'), 0.000001);
            -- cpu_count over the host: the host stays the ceiling.
            v_b := 2 * meta_n('NUM_CPUS');
            UPDATE cap_fixture_parameter SET value_num = v_b
             WHERE parameter_name = 'cpu_count'
               AND snap_id IN (2000 + 2 * n_probe, 2001 + 2 * n_probe);
            SELECT cpu_count, cpu_ceiling, db_cpu_pct INTO v_num, v_num2, v_num3
              FROM capd_dbtime_daily
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
            chk_int  ('cpu_count 16 on the probe day', v_num, 2 * meta_n('NUM_CPUS'));
            chk_int  ('cpu_count 16 -> cpu_ceiling = num_cpus 8', v_num2, meta_n('NUM_CPUS'));
            chk_close('cpu_count 16 -> db_cpu_pct unchanged', v_num3, meta_n('DBCPU_PROBE_PCT'), 0.000001);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT u8_cage; RAISE;
        END;
        ROLLBACK TO SAVEPOINT u8_cage;

        DBMS_OUTPUT.PUT_LINE('=== FRA days on REDO_GB_DAY ===');
        SELECT fra_size_gb, fra_days_at_cur INTO v_num, v_num2
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'REDO_GB_DAY';
        chk_close('REDO fra_size_gb (100 GiB)', v_num, meta_n('FRA_SIZE_GB'), 0.000001);
        chk_close('REDO fra_days_at_cur (100 GiB / 2.0 GiB/day)', v_num2, meta_n('FRA_DAYS'), 0.000001);
        SELECT COUNT(*) INTO v_n FROM capf_series_forecast
          WHERE series <> 'REDO_GB_DAY' AND (fra_size_gb IS NOT NULL OR fra_days_at_cur IS NOT NULL);
        chk_int('FRA columns NULL off REDO_GB_DAY', v_n, 0);
        SELECT fra_size_gb, fra_days_at_cur INTO v_num, v_num2
          FROM capr_series WHERE dbid = v_dbid AND series = 'REDO_GB_DAY';
        chk_close('CAPR_SERIES passes fra_size_gb',     v_num,  meta_n('FRA_SIZE_GB'), 0.000001);
        chk_close('CAPR_SERIES passes fra_days_at_cur', v_num2, meta_n('FRA_DAYS'),    0.000001);
        SAVEPOINT u8_fra;
        BEGIN
            UPDATE cap_fixture_parameter SET value_num = 0
             WHERE parameter_name = 'db_recovery_file_dest_size';
            SELECT COUNT(*) INTO v_n FROM capf_series_forecast
              WHERE dbid = v_dbid AND series = 'REDO_GB_DAY'
                AND fra_size_gb IS NULL AND fra_days_at_cur IS NULL;
            chk_int('FRA size 0 -> fra_size_gb and fra_days_at_cur NULL', v_n, 1);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT u8_fra; RAISE;
        END;
        ROLLBACK TO SAVEPOINT u8_fra;
        -- FIXPDB1 writes redo too, 1 GiB per interval on the last day only:
        -- the FRA holds the dbid's summed rate, so both REDO rows read
        -- 100 / (2 + 2) = 25 days.
        SAVEPOINT u8_fra2;
        BEGIN
            v_a := meta_n('PDB_CON_DBID');
            v_b := meta_n('FRA_SIZE_GB') / (2 * meta_n('REDO_PROBE_GB'));
            INSERT INTO cap_fixture_sysstat VALUES (v_dbid, v_a, 1, 2001 + 2 * (n_days - 2), 'redo size', 0);
            INSERT INTO cap_fixture_sysstat VALUES (v_dbid, v_a, 1, 2000 + 2 * (n_days - 1), 'redo size', 1073741824);
            INSERT INTO cap_fixture_sysstat VALUES (v_dbid, v_a, 1, 2001 + 2 * (n_days - 1), 'redo size', 2147483648);
            SELECT cur_val INTO v_num FROM capf_series_forecast
              WHERE dbid = v_dbid AND con_dbid = v_a AND series = 'REDO_GB_DAY';
            chk_close('FIXPDB1 REDO_GB_DAY cur_val (two 1 GiB intervals)', v_num, meta_n('REDO_PROBE_GB'), 0.000001);
            SELECT COUNT(*) INTO v_n FROM capf_series_forecast
              WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND ABS(fra_days_at_cur - v_b) < 0.000001;
            chk_int('two containers: both REDO rows fra_days_at_cur = 100 / (2 + 2)', v_n, 2);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT u8_fra2; RAISE;
        END;
        ROLLBACK TO SAVEPOINT u8_fra2;

        DBMS_OUTPUT.PUT_LINE('=== ASM diskgroups (ASM_DG series) ===');
        SELECT COUNT(*) INTO v_n FROM capv_asm_diskgroup;
        chk_int('CAPV_ASM_DISKGROUP rows (2 groups x every snapshot)', v_n, 2 * n_snaps);
        SELECT value, limit_value, unit, covered_sec, is_complete INTO v_num, v_num2, v_str, v_num3, v_c
          FROM capd_series_daily WHERE dbid = v_dbid AND series = 'ASM_DG:+DATA' AND day_dt = d_last;
        chk_close('ASM_DG:+DATA last-day value (GiB used)', v_num,  meta_n('ASM_DATA_CUR'),   0.000001);
        chk_close('ASM_DG:+DATA limit_value (total GiB)',   v_num2, meta_n('ASM_DATA_LIMIT'), 0.000001);
        chk_str  ('ASM_DG:+DATA unit', v_str, 'GIB');
        chk_true ('ASM_DG:+DATA covered_sec NULL, is_complete Y (level series)',
                  v_num3 IS NULL AND v_c = 'Y');
        SELECT value INTO v_num FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'ASM_DG:+DATA' AND day_dt = d_probe;
        chk_close('ASM_DG:+DATA probe day = the 18:00 (last) sample, not 06:00',
                  v_num, meta_n('ASM_DATA_PROBE'), 0.000001);
        SELECT slope_per_day, days_to_limit, quality, pct_of_limit, proj_30
          INTO v_num, v_n, v_str, v_num2, v_num3
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'ASM_DG:+DATA';
        chk_close('ASM_DG:+DATA slope (GiB/day)', v_num, meta_n('ASM_DATA_SLOPE'), 0.000001);
        chk_int  ('ASM_DG:+DATA days_to_limit (90% of 1000 GiB)', v_n, meta_n('ASM_DATA_DTL'));
        chk_str  ('ASM_DG:+DATA quality', v_str, 'OK');
        chk_close('ASM_DG:+DATA pct_of_limit', v_num2, meta_n('ASM_DATA_PCT'), 0.000001);
        chk_close('ASM_DG:+DATA proj_30 = 800 + 5 * 30', v_num3, meta_n('ASM_DATA_P30'), 0.000001);
        snap_alerts;
        SELECT COUNT(*), MAX(value), MAX(severity) INTO v_n, v_num, v_str
          FROM cap_fixture_alerts_snap WHERE kind = 'SERIES_LIMIT' AND series_key = 'ASM_DG:+DATA';
        chk_int('ASM_DG:+DATA raises one SERIES_LIMIT', v_n, 1);
        chk_int('ASM_DG:+DATA SERIES_LIMIT value = days_to_limit', v_num, meta_n('ASM_DATA_DTL'));
        chk_str('ASM_DG:+DATA SERIES_LIMIT severity (20 <= dtf_crit)', v_str, 'CRIT');
        SELECT sev INTO v_str FROM capr_series WHERE dbid = v_dbid AND series = 'ASM_DG:+DATA';
        chk_str('CAPR_SERIES ASM_DG:+DATA sev', v_str, 'CRIT');
        SELECT COUNT(*) INTO v_n FROM capr_series_points
          WHERE kind = 'SERIES' AND series = 'ASM_DG:+DATA';
        chk_int('CAPR_SERIES_POINTS one ASM_DG:+DATA point per day', v_n, n_days);
        SELECT value INTO v_num FROM capr_forecast_points
          WHERE kind = 'SERIES' AND series = 'ASM_DG:+DATA' AND method = 'REGR' AND horizon_days = 30;
        chk_close('CAPR_FORECAST_POINTS ASM_DG:+DATA +30', v_num, meta_n('ASM_DATA_P30'), 0.000001);
        SELECT cur_val, cur_limit, quality, days_to_limit INTO v_num, v_num2, v_str, v_n
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'ASM_DG:+FRA';
        chk_close('ASM_DG:+FRA cur_val',   v_num,  meta_n('ASM_FRA_CUR'),   0.000001);
        chk_close('ASM_DG:+FRA cur_limit', v_num2, meta_n('ASM_FRA_LIMIT'), 0.000001);
        chk_str  ('ASM_DG:+FRA quality (constant -> FLAT)', v_str, 'FLAT');
        chk_true ('ASM_DG:+FRA days_to_limit IS NULL', v_n IS NULL);

        DBMS_OUTPUT.PUT_LINE('=== TEMP / UNDO peaks ===');
        SELECT value, limit_value, unit INTO v_num, v_num2, v_str
          FROM capd_series_daily WHERE dbid = v_dbid AND series = 'TEMP_PEAK:FIX_TEMP' AND day_dt = d_last;
        chk_close('TEMP_PEAK last day = the 06:00 peak (the 18:00 sample reads 1 GiB)',
                  v_num, meta_n('TEMP_CUR'), 0.000001);
        chk_close('TEMP_PEAK limit_value (allocated, no autoextend)', v_num2, meta_n('TEMP_LIMIT'), 0.000001);
        chk_str  ('TEMP_PEAK unit', v_str, 'GIB');
        SELECT value INTO v_num FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'TEMP_PEAK:FIX_TEMP' AND day_dt = d_probe;
        chk_close('TEMP_PEAK probe day peak', v_num, meta_n('TEMP_PROBE'), 0.000001);
        SELECT cur_val, pct_of_limit, slope_per_day, r2, quality, days_to_limit
          INTO v_num, v_num2, v_num3, v_r2, v_q, v_n
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'TEMP_PEAK:FIX_TEMP';
        chk_close('TEMP_PEAK cur_val', v_num, meta_n('TEMP_CUR'), 0.000001);
        chk_close('TEMP_PEAK pct_of_limit', v_num2, meta_n('TEMP_PCT'), 0.000001);
        chk_close('TEMP_PEAK slope (OLS, i = 31..120)', v_num3, meta_n('TEMP_SLOPE'), 0.000001);
        chk_close('TEMP_PEAK r2', v_r2, meta_n('TEMP_R2'), 0.000001);
        SELECT sval INTO v_str FROM cap_fixture_meta WHERE mkey = 'TEMP_Q';
        chk_str  ('TEMP_PEAK quality', v_q, v_str);
        chk_true ('TEMP_PEAK days_to_limit IS NULL (slope < 0)', v_n IS NULL AND meta_n('TEMP_SLOPE') < 0);
        SELECT COUNT(*), MAX(value), MAX(severity) INTO v_n, v_num, v_str
          FROM cap_fixture_alerts_snap WHERE kind = 'SERIES_NEARLIMIT' AND series_key = 'TEMP_PEAK:FIX_TEMP';
        chk_int  ('TEMP_PEAK raises one SERIES_NEARLIMIT', v_n, 1);
        chk_close('TEMP_PEAK SERIES_NEARLIMIT value = pct_of_limit', v_num, meta_n('TEMP_PCT'), 0.000001);
        chk_str  ('TEMP_PEAK SERIES_NEARLIMIT severity (97.5 >= nearfull_crit_pct)', v_str, 'CRIT');
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
          WHERE kind = 'SERIES_LIMIT' AND series_key LIKE 'TEMP!_PEAK:%' ESCAPE '!';
        chk_int('TEMP_PEAK raises no SERIES_LIMIT (not growing)', v_n, 0);
        SELECT cur_val, cur_limit, pct_of_limit, quality INTO v_num, v_num2, v_num3, v_str
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'UNDO_PEAK:FIX_UNDO';
        chk_close('UNDO_PEAK cur_val (18:00 peak)',             v_num,  meta_n('UNDO_CUR'),   0.000001);
        chk_close('UNDO_PEAK cur_limit (autoextend maxsize)',   v_num2, meta_n('UNDO_LIMIT'), 0.000001);
        chk_close('UNDO_PEAK pct_of_limit',                     v_num3, meta_n('UNDO_PCT'),   0.000001);
        chk_str  ('UNDO_PEAK quality (constant -> FLAT)', v_str, 'FLAT');
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE series_key = 'UNDO_PEAK:FIX_UNDO';
        chk_int('UNDO_PEAK raises no alert', v_n, 0);
        -- CAPD_TBSPC_DAILY keeps its contents exclusion: neither tablespace
        -- reaches the tablespace layers, DB_SIZE_GB included.
        SELECT COUNT(*) INTO v_n FROM capd_tbspc_daily WHERE tablespace_name IN ('FIX_TEMP','FIX_UNDO');
        chk_int('no FIX_TEMP / FIX_UNDO rows in CAPD_TBSPC_DAILY', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast WHERE tablespace_name IN ('FIX_TEMP','FIX_UNDO');
        chk_int('no FIX_TEMP / FIX_UNDO rows in CAPF_TBSPC_FORECAST', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_series_points
          WHERE kind = 'SERIES' AND series IN ('TEMP_PEAK:FIX_TEMP','UNDO_PEAK:FIX_UNDO');
        chk_int('CAPR_SERIES_POINTS one TEMP / UNDO point per day each', v_n, 2 * n_days);
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE (series LIKE 'ASM!_DG:%' ESCAPE '!' OR series LIKE 'TEMP!_PEAK:%' ESCAPE '!'
                 OR series LIKE 'UNDO!_PEAK:%' ESCAPE '!')
            AND (covered_sec IS NOT NULL OR is_complete <> 'Y' OR unit <> 'GIB');
        chk_int('ASM / TEMP / UNDO series: unit GIB, covered_sec NULL, is_complete Y', v_n, 0);
        -- The anomaly engine scores only the series in its registry (sreg in
        -- CAPA_OBS: the four M11 names and PGA_ALLOC_GB), so these are never scored:
        -- no observation, no SERIES_ANOM, no verdict on their points.
        SELECT COUNT(*) INTO v_n FROM capa_obs
          WHERE kind = 'SERIES'
            AND (series LIKE 'ASM!_DG:%' ESCAPE '!' OR series LIKE 'TEMP!_PEAK:%' ESCAPE '!'
                 OR series LIKE 'UNDO!_PEAK:%' ESCAPE '!');
        chk_int('ASM / TEMP / UNDO series have no CAPA_OBS rows (not in the registry)', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
          WHERE kind = 'SERIES_ANOM'
            AND (series_key LIKE 'ASM!_DG:%' ESCAPE '!' OR series_key LIKE 'TEMP!_PEAK:%' ESCAPE '!'
                 OR series_key LIKE 'UNDO!_PEAK:%' ESCAPE '!');
        chk_int('ASM / TEMP / UNDO series raise no SERIES_ANOM', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_series_points
          WHERE kind = 'SERIES'
            AND (series LIKE 'ASM!_DG:%' ESCAPE '!' OR series LIKE 'TEMP!_PEAK:%' ESCAPE '!'
                 OR series LIKE 'UNDO!_PEAK:%' ESCAPE '!')
            AND (anomaly_flag IS NOT NULL OR z IS NOT NULL OR expected IS NOT NULL
                 OR anomaly_modes IS NOT NULL);
        chk_int('ASM / TEMP / UNDO points carry no anomaly verdict', v_n, 0);

        DBMS_OUTPUT.PUT_LINE('=== sizing ask (need_gib_h, add_by_day) ===');
        SELECT need_gib_30, need_gib_90, need_gib_180 INTO v_num, v_num2, v_num3
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_FILLING';
        chk_close('FILLING need_gib_30',  v_num,  meta_n('FILLING_NEED_30'),  0.000001);
        chk_close('FILLING need_gib_90',  v_num2, meta_n('FILLING_NEED_90'),  0.000001);
        chk_close('FILLING need_gib_180', v_num3, meta_n('FILLING_NEED_180'), 0.000001);
        SELECT add_by_day, last_day, days_to_full_lo INTO v_dt, v_dt2, v_a
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_FILLING';
        chk_true('FILLING add_by_day = last_day + days_to_full_lo', v_dt = v_dt2 + v_a);
        -- headroom / slope is exactly 20.0, so a rounding epsilon on the
        -- collapsed slope CI may FLOOR the worst case to 19 (as for FIX_LINEAR).
        chk_true('FILLING add_by_day in last_day + [19, 20] (got +' || (v_dt - v_dt2) || ')',
                 v_dt - v_dt2 BETWEEN meta_n('FILLING_DTF') - 1 AND meta_n('FILLING_DTF'));
        SELECT need_gib_30, need_gib_90, need_gib_180 INTO v_num, v_num2, v_num3
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
        chk_int('LINEAR need_gib_30 (4990 days of headroom)', v_num,  0);
        chk_int('LINEAR need_gib_90',                         v_num2, 0);
        chk_int('LINEAR need_gib_180',                        v_num3, 0);
        -- A ceiling under the usage asks for the overage at every horizon,
        -- with no date (FLAT: no days_to_full_lo).
        SELECT need_gib_30, need_gib_180, add_by_day INTO v_num, v_num2, v_dt
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_OVERFULL';
        chk_close('OVERFULL need_gib_30 = (1.5 - 1) GiB', v_num,
                  (meta_n('OVERFULL_CUR') - meta_n('OVERFULL_LIMIT')) / 1073741824, 0.000001);
        chk_close('OVERFULL need_gib_180 = (1.5 - 1) GiB', v_num2,
                  (meta_n('OVERFULL_CUR') - meta_n('OVERFULL_LIMIT')) / 1073741824, 0.000001);
        chk_true ('OVERFULL add_by_day IS NULL (FLAT)', v_dt IS NULL);
        SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
          WHERE quality = 'CYCLIC' AND (need_gib_90 IS NOT NULL OR add_by_day IS NOT NULL);
        chk_int('CYCLIC rows carry no sizing ask', v_n, 0);
        SELECT need_gib_90, add_by_day INTO v_num, v_dt
          FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_FILLING';
        chk_close('CAPR_TBSPC_DAYS_TO_FULL passes need_gib_90', v_num, meta_n('FILLING_NEED_90'), 0.000001);
        chk_true ('CAPR_TBSPC_DAYS_TO_FULL passes add_by_day', v_dt = v_dt2 + v_a);
        SELECT need_gib_90, add_by_day INTO v_num, v_dt
          FROM capr_fit WHERE kind = 'TBSPC' AND series = 'FIX_FILLING';
        chk_close('CAPR_FIT passes need_gib_90', v_num, meta_n('FILLING_NEED_90'), 0.000001);
        chk_true ('CAPR_FIT passes add_by_day', v_dt = v_dt2 + v_a);
        SELECT COUNT(*) INTO v_n FROM capr_fit
          WHERE kind <> 'TBSPC' AND (need_gib_30 IS NOT NULL OR need_gib_90 IS NOT NULL
                                     OR need_gib_180 IS NOT NULL OR add_by_day IS NOT NULL);
        chk_int('CAPR_FIT sizing ask NULL for CPU / SERIES', v_n, 0);
    EXCEPTION
        WHEN OTHERS THEN
            fail('seam-extension block raised ' || SQLERRM);
    END;

    -- M26: CAPV_PGASTAT, the PGA_ALLOC_GB series and the PGA_LIMIT verdict
    -- (CAPM_*). Closed forms recorded by fixture_install.sql.
    DECLARE
        d_last   DATE   := meta_d('LAST_DAY');
        d_base   DATE   := meta_d('BASE_DAY');
        d_hwm    DATE   := meta_d('PGA_HWM_AT');
        n_snaps  NUMBER := 2 * (meta_d('LAST_DAY') - meta_d('BASE_DAY') + 1) - 1;
        n_latest NUMBER := 2001 + 2 * (meta_d('LAST_DAY') - meta_d('BASE_DAY'));
        n_gib    CONSTANT NUMBER := 1073741824;
        n_mib    CONSTANT NUMBER := 1048576;
        n_lim    NUMBER := meta_n('PGA_LIMIT_GIB');
        v_ws     DATE;
        v_we     DATE;
        v_st     DATE;
        v_ht     DATE;
        v_mode   VARCHAR2(10);
        v_grade  VARCHAR2(30);
        v_reason VARCHAR2(30);
        v_xram   VARCHAR2(1);
        v_txt    VARCHAR2(400);
        v_sug    NUMBER;
        v_days   NUMBER;
        v_nev    NUMBER;
        v_npr    NUMBER;
        v_lim    NUMBER;
        v_samp   NUMBER;
        v_hwm    NUMBER;
        v_over   NUMBER;
        v_sga    NUMBER;
        v_ram    NUMBER;
        v_con    NUMBER;
        v_dt_m   DATE;
        PROCEDURE verdict IS
        BEGIN
            SELECT grade, reason, suggested_bytes, exceeds_host_ram, mem_mode, n_days,
                   n_evidence, n_pressure
              INTO v_grade, v_reason, v_sug, v_xram, v_mode, v_days, v_nev, v_npr
              FROM capm_verdict
             WHERE dbid = v_dbid AND instance_number = 1 AND area = 'PGA_LIMIT';
        END;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== M26 CAPV_PGASTAT ===');
        SELECT COUNT(*) INTO v_n FROM capv_pgastat;
        chk_int('CAPV_PGASTAT rows (6 names x every snapshot + the sparse over-allocation rows)',
                v_n, meta_n('MEM_PGASTAT_ROWS'));
        SELECT COUNT(*) INTO v_n FROM capv_pgastat
         WHERE stat_name IN ('total PGA allocated', 'maximum PGA allocated');
        chk_int('CAPV_PGASTAT the two PGA_LIMIT names on every snapshot', v_n, 2 * n_snaps);
        SELECT COUNT(*) INTO v_n FROM capv_pgastat
         WHERE stat_name NOT IN ('total PGA allocated', 'maximum PGA allocated', 'bytes processed',
                                 'extra bytes read/written', 'over allocation count',
                                 'aggregate PGA target parameter', 'aggregate PGA auto target')
            OR con_dbid <> dbid;
        chk_int('CAPV_PGASTAT carries the fixture''s seven names only, under the root', v_n, 0);
        SELECT n_rows, n_con_dbid, per_container_expected INTO v_num, v_num2, v_c1
          FROM capv_contract WHERE source_name = 'PGASTAT';
        chk_int('CAPV_CONTRACT PGASTAT n_rows', v_num, meta_n('MEM_PGASTAT_ROWS'));
        chk_int('CAPV_CONTRACT PGASTAT n_con_dbid (instance level)', v_num2, 1);
        chk_str('CAPV_CONTRACT PGASTAT per_container_expected', v_c1, 'N');

        DBMS_OUTPUT.PUT_LINE('=== M26 PGA_ALLOC_GB series ===');
        -- Day 60 is the restart day (its 18:00 snapshot only), day 110 the
        -- high-water mark's advance, which the series does not see.
        FOR k IN (SELECT 0 AS i FROM dual UNION ALL SELECT 60 FROM dual
                  UNION ALL SELECT 110 FROM dual UNION ALL SELECT 120 FROM dual) LOOP
            SELECT value, limit_value, unit INTO v_num, v_num2, v_str
              FROM capd_series_daily
             WHERE dbid = v_dbid AND series = 'PGA_ALLOC_GB' AND day_dt = d_base + k.i;
            chk_close('PGA_ALLOC_GB day ' || k.i || ' = 1 + i/1200 GiB (the 18:00 sample)',
                      v_num, 1 + k.i / 1200, 0.000001);
            chk_close('PGA_ALLOC_GB day ' || k.i || ' limit_value (pga_aggregate_limit GiB)',
                      v_num2, n_lim, 0.000001);
            chk_str('PGA_ALLOC_GB day ' || k.i || ' unit', v_str, 'GIB');
        END LOOP;
        SELECT COUNT(*), COUNT(CASE WHEN covered_sec IS NULL AND is_complete = 'Y'
                                     AND gap_flag = 'N' THEN 1 END)
          INTO v_n, v_num
          FROM capd_series_daily WHERE dbid = v_dbid AND series = 'PGA_ALLOC_GB';
        chk_int('PGA_ALLOC_GB one row per day', v_n, d_last - d_base + 1);
        chk_int('PGA_ALLOC_GB level rows: covered_sec NULL, complete, no gap', v_num, v_n);
        SELECT worst_inst_pct, worst_inst INTO v_num, v_num2
          FROM capd_series_daily
         WHERE dbid = v_dbid AND series = 'PGA_ALLOC_GB' AND day_dt = d_last;
        chk_close('PGA_ALLOC_GB last-day worst_inst_pct (1.1 of 2 GiB)', v_num, 55, 0.000001);
        chk_int  ('PGA_ALLOC_GB last-day worst_inst', v_num2, 1);
        SELECT slope_per_day, cur_val, cur_limit, pct_of_limit, quality, days_to_limit, train_n
          INTO v_num, v_num2, v_num3, v_r2, v_str, v_n, v_days
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'PGA_ALLOC_GB';
        chk_close('PGA_ALLOC_GB slope 1/1200 GiB/day', v_num, meta_n('PGA_SLOPE'), 0.000001);
        chk_close('PGA_ALLOC_GB cur_val 1.1 GiB',      v_num2, meta_n('PGA_CUR_GIB'), 0.000001);
        chk_close('PGA_ALLOC_GB cur_limit 2 GiB',      v_num3, n_lim, 0.000001);
        chk_close('PGA_ALLOC_GB pct_of_limit 55',      v_r2, 55, 0.000001);
        chk_str  ('PGA_ALLOC_GB quality (exactly linear)', v_str, 'OK');
        chk_int  ('PGA_ALLOC_GB train_n = SESSIONS train_n (level series, every day)',
                  v_days, meta_n('SESS_TRAIN_N'));
        -- FLOOR((cur_limit x series_sat_pct / 100 - cur_val) / slope): 840 on
        -- the exact slope; the last digit of REGR_SLOPE's 1/1200 may FLOOR it
        -- to 839, as for FIX_FILLING's add_by_day.
        chk_true('PGA_ALLOC_GB days_to_limit = FLOOR((2 x 0.90 - 1.1) x 1200) = 840, or 839 (got '
                 || v_n || ')', v_n BETWEEN meta_n('PGA_DTL') - 1 AND meta_n('PGA_DTL'));
        SELECT COUNT(*) INTO v_n FROM capa_obs WHERE kind = 'SERIES' AND series = 'PGA_ALLOC_GB';
        chk_int('PGA_ALLOC_GB scored by CAPA_OBS on every day', v_n, d_last - d_base + 1);
        SELECT COUNT(*) INTO v_n FROM capa_anom
         WHERE kind = 'SERIES' AND series = 'PGA_ALLOC_GB' AND anomaly_flag IS NOT NULL;
        chk_int('PGA_ALLOC_GB never flags (1/1200 GiB a day under the 0.5 GiB floor)', v_n, 0);
        snap_alerts;
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE series_key = 'PGA_ALLOC_GB';
        chk_int('PGA_ALLOC_GB raises no alert (55% of the limit, 840 days out)', v_n, 0);

        DBMS_OUTPUT.PUT_LINE('=== M26 CAPM_PGA_LIMIT (shipped knobs) ===');
        SELECT COUNT(*) INTO v_n FROM capm_pga_limit;
        chk_int('CAPM_PGA_LIMIT one row (one database, one instance)', v_n, 1);
        SELECT con_dbid, window_start, window_end, n_days, mem_mode, limit_bytes,
               sampled_peak_bytes, sampled_peak_time, hwm_peak_bytes, hwm_peak_time,
               n_days_over, sga_bytes, host_ram_bytes
          INTO v_con, v_ws, v_we, v_days, v_mode, v_lim, v_samp, v_st, v_hwm, v_ht,
               v_over, v_sga, v_ram
          FROM capm_pga_limit WHERE dbid = v_dbid AND instance_number = 1;
        chk_int ('PGA_LIMIT con_dbid = dbid (the root)', v_con, v_dbid);
        chk_true('PGA_LIMIT window_end = the newest snapshot, last day 18:00', v_we = d_last + 18/24);
        chk_true('PGA_LIMIT window_start = window_end - 30', v_ws = d_last + 18/24 - 30);
        chk_int ('PGA_LIMIT n_days (days 91..120)', v_days, 30);
        chk_str ('PGA_LIMIT mem_mode (memory_target 0, sga_target 4 GiB)', v_mode, 'ASMM');
        chk_int ('PGA_LIMIT limit_bytes 2 GiB', v_lim, n_lim * n_gib);
        chk_close('PGA_LIMIT sampled_peak_bytes 1.1 GiB', v_samp, meta_n('PGA_CUR_GIB') * n_gib, 0.000001);
        chk_true('PGA_LIMIT sampled_peak_time = last day 18:00', v_st = d_last + 18/24);
        chk_close('PGA_LIMIT hwm_peak_bytes 1.9 GiB', v_hwm, meta_n('PGA_HWM_GIB') * n_gib, 0.000001);
        chk_true('PGA_LIMIT hwm_peak_time = day ' || meta_n('PGA_HWM_AT') || ' 18:00 (the advance)',
                 v_ht = d_hwm);
        chk_int ('PGA_LIMIT n_days_over (no sample reaches 90%)', v_over, 0);
        chk_int ('PGA_LIMIT sga_bytes 4 GiB', v_sga, 4 * n_gib);
        chk_int ('PGA_LIMIT host_ram_bytes 16 GiB', v_ram, meta_n('HOST_RAM_GIB') * n_gib);

        DBMS_OUTPUT.PUT_LINE('=== M26 CAPM_EVIDENCE / CAPM_VERDICT (shipped knobs) ===');
        SELECT COUNT(*), COUNT(CASE WHEN kind = 'USAGE' THEN 1 END) INTO v_n, v_num
          FROM capm_evidence WHERE area = 'PGA_LIMIT';
        chk_int('CAPM_EVIDENCE two PGA_LIMIT signals', v_n, 2);
        chk_int('CAPM_EVIDENCE PGA_LIMIT signals are kind USAGE', v_num, 2);
        SELECT value, unit, threshold, direction, observed_at, evidence_text
          INTO v_num, v_str, v_num2, v_str2, v_dt_m, v_txt
          FROM capm_evidence WHERE dbid = v_dbid AND area = 'PGA_LIMIT' AND signal = 'PGA_HWM_PEAK_PCT';
        chk_close('PGA_HWM_PEAK_PCT value 95', v_num, 95, 0.000001);
        chk_str  ('PGA_HWM_PEAK_PCT unit', v_str, 'PCT');
        chk_int  ('PGA_HWM_PEAK_PCT threshold = mem_pga_limit_pct', v_num2, 90);
        chk_str  ('PGA_HWM_PEAK_PCT direction', v_str2, 'PRESSURE');
        chk_true ('PGA_HWM_PEAK_PCT observed_at = the advance', v_dt_m = d_hwm);
        chk_true ('PGA_HWM_PEAK_PCT text names 1.90 GiB, 95.00% and 2.00 GiB (got ' || v_txt || ')',
                  INSTR(v_txt, '1.90 GiB') > 0 AND INSTR(v_txt, '95.00%') > 0 AND INSTR(v_txt, '2.00 GiB') > 0);
        SELECT value, direction, observed_at INTO v_num, v_str2, v_dt_m
          FROM capm_evidence WHERE dbid = v_dbid AND area = 'PGA_LIMIT' AND signal = 'PGA_SAMPLED_PEAK_PCT';
        chk_close('PGA_SAMPLED_PEAK_PCT value 55', v_num, 55, 0.000001);
        chk_str  ('PGA_SAMPLED_PEAK_PCT direction', v_str2, 'NEUTRAL');
        chk_true ('PGA_SAMPLED_PEAK_PCT observed_at = last day 18:00', v_dt_m = d_last + 18/24);
        verdict;
        chk_str('PGA_LIMIT grade',  v_grade, 'UNDERSIZED');
        chk_str('PGA_LIMIT reason', v_reason, 'PEAK_NEAR_LIMIT');
        chk_int('PGA_LIMIT suggested_bytes = CEIL(1.9 GiB x 100 / 90) MiB = 2162 MiB',
                v_sug, meta_n('PGA_SUGGEST_MIB') * n_mib);
        chk_str('PGA_LIMIT exceeds_host_ram (4 GiB + 2162 MiB within 80% of 16 GiB)', v_xram, 'N');
        chk_int('PGA_LIMIT n_evidence', v_nev, 2);
        chk_int('PGA_LIMIT n_pressure', v_npr, 1);
        SELECT current_bytes INTO v_num FROM capm_verdict WHERE dbid = v_dbid AND area = 'PGA_LIMIT';
        chk_int('PGA_LIMIT current_bytes = limit_bytes', v_num, n_lim * n_gib);
        SELECT COUNT(*) INTO v_n FROM capm_verdict WHERE area = 'PGA_LIMIT' AND grade = 'OVERSIZED';
        chk_int('PGA_LIMIT is never OVERSIZED', v_n, 0);

        DBMS_OUTPUT.PUT_LINE('=== M26 PGA_LIMIT knob variations ===');
        BEGIN
            knob('mem_pga_limit_pct', 96);
            verdict;
            chk_str ('mem_pga_limit_pct 96: grade',  v_grade, 'OK');
            chk_str ('mem_pga_limit_pct 96: reason', v_reason, 'PEAK_BELOW_LIMIT');
            chk_true('mem_pga_limit_pct 96: suggested_bytes NULL', v_sug IS NULL);
            chk_true('mem_pga_limit_pct 96: exceeds_host_ram NULL (no suggestion)', v_xram IS NULL);
            chk_int ('mem_pga_limit_pct 96: n_pressure', v_npr, 0);
            UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'mem_pga_limit_pct';

            knob('mem_window_days', 5);
            knob('mem_min_days', 1);
            SELECT n_days, hwm_peak_bytes, window_start INTO v_days, v_hwm, v_ws
              FROM capm_pga_limit WHERE dbid = v_dbid AND instance_number = 1;
            chk_int ('mem_window_days 5: n_days (days 116..120)', v_days, 5);
            chk_true('mem_window_days 5: the day-110 advance is outside, hwm_peak NULL', v_hwm IS NULL);
            chk_true('mem_window_days 5: window_start = window_end - 5', v_ws = d_last + 18/24 - 5);
            verdict;
            chk_str('mem_window_days 5, mem_min_days 1: grade',  v_grade, 'OK');
            chk_str('mem_window_days 5, mem_min_days 1: reason', v_reason, 'PEAK_BELOW_LIMIT');
            chk_int('mem_window_days 5: n_evidence (the sampled signal only)', v_nev, 1);
            UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'mem_min_days';
            verdict;
            chk_str('mem_window_days 5, mem_min_days 7: grade',  v_grade, 'INSUFFICIENT_EVIDENCE');
            chk_str('mem_window_days 5, mem_min_days 7: reason', v_reason, 'WINDOW_TOO_SHORT');
            SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'mem_min_days';
            chk_str('CAP_CFG_CHECK mem_min_days 7 > mem_window_days 5', v_str, 'BAD');
            UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'mem_window_days';

            knob('mem_max_step', 1.05);
            verdict;
            chk_int('mem_max_step 1.05: suggested_bytes = FLOOR(2048 x 1.05) MiB = 2150 MiB',
                    v_sug, meta_n('PGA_SUGGEST_MIB_STEP105') * n_mib);
            UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'mem_max_step';

            knob('mem_host_ram_pct', 30);
            verdict;
            chk_str('mem_host_ram_pct 30: exceeds_host_ram (4 GiB + 2162 MiB over 4.8 GiB)', v_xram, 'Y');
            chk_int('mem_host_ram_pct 30: suggested_bytes unchanged', v_sug, meta_n('PGA_SUGGEST_MIB') * n_mib);
        EXCEPTION
            WHEN OTHERS THEN
                UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name LIKE 'mem!_%' ESCAPE '!';
                COMMIT;
                RAISE;
        END;
        UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name LIKE 'mem!_%' ESCAPE '!';
        COMMIT;
        SELECT COUNT(*), COUNT(CASE WHEN status = 'OK' THEN 1 END) INTO v_n, v_num
          FROM cap_cfg_check WHERE knob LIKE 'mem!_%' ESCAPE '!';
        chk_int('the mem_ knobs: 5 of the PGA limit, 18 of the advisor areas', v_n, 23);
        chk_int('the mem_ knobs OK after reset', v_num, v_n);

        DBMS_OUTPUT.PUT_LINE('=== M26 PGA_LIMIT parameter and data variations ===');
        SAVEPOINT m25_param;
        BEGIN
            UPDATE cap_fixture_parameter SET value_num = 4294967296
             WHERE parameter_name = 'memory_target' AND snap_id = n_latest;
            verdict;
            chk_str('memory_target > 0 at the latest snapshot: mem_mode', v_mode, 'AMM');
            chk_str('memory_target > 0: grade',  v_grade, 'INSUFFICIENT_EVIDENCE');
            chk_str('memory_target > 0: reason', v_reason, 'AMM');
            chk_true('memory_target > 0: suggested_bytes NULL', v_sug IS NULL);
            ROLLBACK TO SAVEPOINT m25_param;

            UPDATE cap_fixture_parameter SET value_num = 0 WHERE parameter_name = 'pga_aggregate_limit';
            verdict;
            chk_str ('pga_aggregate_limit 0: grade',  v_grade, 'OK');
            chk_str ('pga_aggregate_limit 0: reason', v_reason, 'NO_LIMIT');
            chk_true('pga_aggregate_limit 0: suggested_bytes NULL', v_sug IS NULL);
            chk_int ('pga_aggregate_limit 0: no evidence row', v_nev, 0);
            SELECT COUNT(*) INTO v_n FROM capd_series_daily
             WHERE dbid = v_dbid AND series = 'PGA_ALLOC_GB' AND limit_value IS NOT NULL;
            chk_int('pga_aggregate_limit 0: PGA_ALLOC_GB limit_value NULL on every day', v_n, 0);
            SELECT cur_limit, days_to_limit INTO v_num, v_num2
              FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'PGA_ALLOC_GB';
            chk_true('pga_aggregate_limit 0: no cur_limit, no days_to_limit', v_num IS NULL AND v_num2 IS NULL);
            ROLLBACK TO SAVEPOINT m25_param;

            -- A repository target whose reader cannot read DBA_HIST_PGASTAT.
            DELETE FROM cap_fixture_pgastat;
            verdict;
            chk_str('no PGA statistics: grade',  v_grade, 'INSUFFICIENT_EVIDENCE');
            chk_str('no PGA statistics: reason', v_reason, 'NOT_COLLECTED');
            chk_int('no PGA statistics: n_days', v_days, 0);
            SELECT COUNT(*) INTO v_n FROM capd_series_daily WHERE series = 'PGA_ALLOC_GB';
            chk_int('no PGA statistics: no PGA_ALLOC_GB row', v_n, 0);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT m25_param; RAISE;
        END;
        ROLLBACK TO SAVEPOINT m25_param;
        verdict;
        chk_str('PGA_LIMIT back to UNDERSIZED after the rollback', v_grade, 'UNDERSIZED');
    EXCEPTION
        WHEN OTHERS THEN
            fail('M26 PGA block raised ' || SQLERRM);
    END;

    -- M26: the advisor-based areas (PGA_TARGET, BUFFER_CACHE, SHARED_POOL,
    -- SGA_TOTAL) and SGA_BALANCE. The designed inputs are in the "M26 --
    -- memory sizing sources" block of fixture_install.sql: an increment of
    -- a x u seconds a snapshot interval, u = MEM_U, over n intervals whose DB
    -- time is dbt, is pct(n, a, dbt) percent of DB time.
    DECLARE
        d_last   DATE   := meta_d('LAST_DAY');
        d_base   DATE   := meta_d('BASE_DAY');
        n_p      NUMBER := meta_n('PARTIAL_DAY');
        n_u      NUMBER := meta_n('MEM_U');
        n_dbt    NUMBER := meta_n('MEM_DBT_WIN');
        n_latest NUMBER := 2001 + 2 * (meta_d('LAST_DAY') - meta_d('BASE_DAY'));
        n_snaps  NUMBER := 2 * (meta_d('LAST_DAY') - meta_d('BASE_DAY') + 1) - 1;
        n_gib    CONSTANT NUMBER := 1073741824;
        n_mib    CONSTANT NUMBER := 1048576;
        n_all    NUMBER;
        n_long   NUMBER;
        v_grade  VARCHAR2(30);
        v_reason VARCHAR2(30);
        v_param  VARCHAR2(30);
        v_mode   VARCHAR2(10);
        v_xram   VARCHAR2(1);
        v_cur    NUMBER;
        v_sug    NUMBER;
        v_days   NUMBER;
        v_nev    NUMBER;
        v_npr    NUMBER;
        e_val    NUMBER;
        e_thr    NUMBER;
        e_dir    VARCHAR2(10);
        e_kind   VARCHAR2(10);
        e_unit   VARCHAR2(10);
        e_at     DATE;
        e_txt    VARCHAR2(400);
        a_cover  NUMBER;
        a_days   NUMBER;
        a_best   NUMBER;
        a_bestb  NUMBER;
        a_grow   NUMBER;
        a_slack  NUMBER;
        a_cur    NUMBER;
        a_thin   VARCHAR2(1);
        a_ref    NUMBER;
        a_fb     VARCHAR2(1);
        v_xsga   VARCHAR2(1);
        v_exp    NUMBER;
        v_d      DATE;
        v_txt    VARCHAR2(400);
        v_ws     DATE;
        v_we     DATE;

        PROCEDURE verdict(p_area VARCHAR2) IS
        BEGIN
            SELECT grade, reason, current_bytes, suggested_bytes, suggested_param, exceeds_host_ram,
                   mem_mode, n_days, n_evidence, n_pressure, exceeds_sga
              INTO v_grade, v_reason, v_cur, v_sug, v_param, v_xram, v_mode, v_days, v_nev, v_npr, v_xsga
              FROM capm_verdict
             WHERE dbid = v_dbid AND instance_number = 1 AND area = p_area;
        END;
        -- One verdict: grade, reason and the suggested size in MiB (NULL = none).
        PROCEDURE chk_v(p_label VARCHAR2, p_area VARCHAR2, p_grade VARCHAR2, p_reason VARCHAR2,
                        p_sug_mib NUMBER) IS
        BEGIN
            verdict(p_area);
            chk_str(p_label || ': ' || p_area || ' grade', v_grade, p_grade);
            chk_str(p_label || ': ' || p_area || ' reason', v_reason, p_reason);
            IF p_sug_mib IS NULL THEN
                chk_true(p_label || ': ' || p_area || ' no suggested size (got ' || v_sug || ')', v_sug IS NULL);
            ELSE
                chk_int(p_label || ': ' || p_area || ' suggested_bytes ' || p_sug_mib || ' MiB',
                        v_sug, p_sug_mib * n_mib);
            END IF;
        END;
        PROCEDURE ev(p_signal VARCHAR2) IS
        BEGIN
            SELECT value, threshold, direction, kind, unit, observed_at, evidence_text
              INTO e_val, e_thr, e_dir, e_kind, e_unit, e_at, e_txt
              FROM capm_evidence
             WHERE dbid = v_dbid AND instance_number = 1 AND signal = p_signal;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                e_val := NULL; e_thr := NULL; e_dir := 'NOROW'; e_kind := NULL; e_unit := NULL;
                e_at := NULL; e_txt := NULL;
        END;
        -- One evidence row: its value (to the 4 decimals the view keeps) and direction.
        PROCEDURE chk_e(p_label VARCHAR2, p_signal VARCHAR2, p_val NUMBER, p_dir VARCHAR2) IS
        BEGIN
            ev(p_signal);
            chk_true(p_label || ': ' || p_signal || ' value ' || ROUND(p_val, 4) || ' (got ' || e_val || ')',
                     ABS(e_val - p_val) <= 0.0001);
            chk_str(p_label || ': ' || p_signal || ' direction', e_dir, p_dir);
        END;
        PROCEDURE area(p_area VARCHAR2) IS
        BEGIN
            SELECT cover_hours, n_days, best_gain, best_bytes, grow_bytes, slack_bytes, current_bytes,
                   advisor_thin, reference_bytes, reference_fallback
              INTO a_cover, a_days, a_best, a_bestb, a_grow, a_slack, a_cur, a_thin, a_ref, a_fb
              FROM capm_area
             WHERE dbid = v_dbid AND instance_number = 1 AND area = p_area;
        END;
        -- DB time of the three containers between two snapshots of one startup.
        FUNCTION dbt(p_from NUMBER, p_to NUMBER) RETURN NUMBER IS
            x NUMBER;
        BEGIN
            SELECT SUM(CASE snap_id WHEN p_to THEN value ELSE -value END) / 1000000 INTO x
              FROM cap_fixture_time_model
             WHERE stat_name = 'DB time' AND snap_id IN (p_from, p_to);
            RETURN x;
        END;
        FUNCTION pct(p_n NUMBER, p_a NUMBER, p_dbt NUMBER) RETURN NUMBER IS
        BEGIN RETURN 100 * p_n * p_a * n_u / p_dbt; END;
        PROCEDURE reset_knobs IS
        BEGIN UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name LIKE 'mem!_%' ESCAPE '!'; END;
        -- One CAPR_MEM_VERDICT row: its headline and whether it is actionable.
        PROCEDURE chk_h(p_label VARCHAR2, p_area VARCHAR2, p_act VARCHAR2, p_headline VARCHAR2) IS
            l_head VARCHAR2(400);
            l_act  VARCHAR2(1);
        BEGIN
            SELECT headline, actionable INTO l_head, l_act
              FROM capr_mem_verdict
             WHERE dbid = v_dbid AND instance_number = 1 AND area = p_area;
            chk_true(p_label || ': CAPR_MEM_VERDICT ' || p_area || ' headline (got ' || l_head || ')',
                     l_head = p_headline);
            chk_str(p_label || ': CAPR_MEM_VERDICT ' || p_area || ' actionable', l_act, p_act);
        END;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== M26 CAPM_SNAP / CAPM_DELTA ===');
        SELECT COUNT(*), COUNT(CASE WHEN in_win = 'Y' THEN 1 END),
               COUNT(CASE WHEN seg_ok = 'N' THEN 1 END),
               COUNT(CASE WHEN prev_snap_id IS NULL THEN 1 END)
          INTO v_n, v_num, v_num2, v_num3
          FROM capm_snap WHERE dbid = v_dbid;
        chk_int('CAPM_SNAP one row per snapshot', v_n, n_snaps);
        chk_int('CAPM_SNAP in_win snapshots (days 91..120, two a day)', v_num, 60);
        chk_int('CAPM_SNAP every startup is longer than mem_min_uptime_hours', v_num2, 0);
        chk_int('CAPM_SNAP three startups, each first snapshot without a predecessor', v_num3, 3);
        -- The two startups before the day-60 restart ended before the window:
        -- days 0..59, two snapshots a day (the partial day keeps both).
        SELECT COUNT(CASE WHEN in_win = 'Y' AND seg_in_win = 'N' THEN 1 END),
               COUNT(CASE WHEN seg_in_win = 'N' THEN 1 END)
          INTO v_n, v_num
          FROM capm_snap WHERE dbid = v_dbid;
        chk_int('CAPM_SNAP no window snapshot in a skipped startup', v_n, 0);
        chk_int('CAPM_SNAP seg_in_win N: the snapshots of the two startups before the day-60 restart', v_num, 120);
        SELECT prev_snap_id, ivl_hours, uptime_hours, latest_snap_id INTO v_num, v_num2, v_num3, v_r2
          FROM capm_snap WHERE dbid = v_dbid AND snap_id = n_latest;
        chk_int('CAPM_SNAP latest snapshot pairs with the one before', v_num, n_latest - 1);
        chk_int('CAPM_SNAP ivl_hours 12', v_num2, 12);
        chk_close('CAPM_SNAP uptime_hours of the current startup (day 60 00:00 to day 120 18:00)',
                  v_num3, 60.75 * 24, 0.000001);
        chk_int('CAPM_SNAP latest_snap_id', v_r2, n_latest);
        SELECT prev_snap_id INTO v_num FROM capm_snap WHERE dbid = v_dbid AND snap_id = 2121;
        chk_true('CAPM_SNAP the restart day''s snapshot has no predecessor', v_num IS NULL);

        SELECT COUNT(*) INTO v_n FROM capm_delta WHERE dbid = v_dbid AND snap_id IN (2000, 2001 + 2 * n_p, 2121);
        chk_int('CAPM_DELTA no increment ends on the first snapshot of a startup', v_n, 0);
        SELECT MIN(snap_id) INTO v_n FROM capm_delta WHERE dbid = v_dbid;
        chk_int('CAPM_DELTA first increment: the second snapshot of the startup that reaches the window', v_n, 2122);
        SELECT MIN(snap_id) INTO v_n FROM capm_comp WHERE dbid = v_dbid;
        chk_int('CAPM_COMP first row: the first snapshot of the startup that reaches the window', v_n, 2121);
        SELECT COUNT(*) INTO v_n FROM capm_delta WHERE dbid = v_dbid AND delta < 0;
        chk_int('CAPM_DELTA no negative increment', v_n, 0);
        SELECT COUNT(*), MIN(delta), MAX(delta), COUNT(CASE WHEN prev_snap_id = snap_id - 2 THEN 1 END)
          INTO v_n, v_num, v_num2, v_num3
          FROM capm_delta
         WHERE dbid = v_dbid AND metric = 'PGASTAT' AND key = 'over allocation count' AND in_win = 'Y';
        chk_int('CAPM_DELTA over allocation count: one increment a window day', v_n, 30);
        chk_true('CAPM_DELTA over allocation count: each is 1', v_num = 1 AND v_num2 = 1);
        chk_int('CAPM_DELTA over allocation count: paired across the 06:00 snapshot that has no row', v_num3, 30);
        SELECT delta, prev_snap_id, ivl_hours INTO v_num, v_num2, v_num3
          FROM capm_delta
         WHERE dbid = v_dbid AND metric = 'PGASTAT' AND key = 'over allocation count' AND snap_id = 2001 + 2 * 61;
        chk_int('CAPM_DELTA over allocation count: the first row of a startup counts in full', v_num, 2);
        chk_int('CAPM_DELTA over allocation count: against the snapshot before it', v_num2, 2000 + 2 * 61);
        chk_int('CAPM_DELTA over allocation count: over 12 hours', v_num3, 12);
        SELECT COUNT(*), SUM(delta) INTO v_n, v_num
          FROM capm_delta WHERE dbid = v_dbid AND metric = 'EVENT' AND key = 'free buffer waits';
        chk_int('CAPM_DELTA free buffer waits: an increment from its first row on', v_n, n_latest - 2200 + 1);
        chk_close('CAPM_DELTA free buffer waits: the first row counts in full, 1.2 u', v_num, 1.2 * n_u, 0.000001);
        SELECT COUNT(DISTINCT key_num), SUM(delta) INTO v_n, v_num
          FROM capm_delta WHERE dbid = v_dbid AND metric = 'DBTIME' AND in_win = 'Y';
        chk_int('CAPM_DELTA DBTIME one key per container', v_n, 3);
        chk_close('CAPM_DELTA DBTIME window sum = the fixture''s DB time', v_num, n_dbt, 0.000001);
        SELECT COUNT(*) INTO v_n FROM capm_delta
         WHERE dbid = v_dbid AND metric = 'BUFFER_CACHE' AND snap_id = n_latest;
        chk_int('CAPM_DELTA buffer cache advisor: the ten sizes of pool 3 (KEEP and 16K left out)', v_n, 10);

        DBMS_OUTPUT.PUT_LINE('=== M26 CAPM_ADVICE (shipped knobs) ===');
        FOR r IN (SELECT 'PGA_TARGET' AS a, 8 AS n_rows, 6 AS n_cand, 1024 AS cur FROM dual
                  UNION ALL SELECT 'BUFFER_CACHE', 10, 8, 2560 FROM dual
                  UNION ALL SELECT 'SHARED_POOL',   9, 7, 1024 FROM dual
                  UNION ALL SELECT 'SGA_TOTAL',     7, 6, 4096 FROM dual) LOOP
            SELECT COUNT(*), COUNT(CASE WHEN is_candidate = 'Y' THEN 1 END),
                   MAX(current_bytes), COUNT(CASE WHEN is_current = 'Y' THEN 1 END),
                   MIN(cover_hours), MAX(cover_hours), MIN(n_intervals), MIN(n_days)
              INTO v_n, v_num, v_num2, v_num3, v_r2, n_aux, v_cur, v_days
              FROM capm_advice WHERE dbid = v_dbid AND area = r.a;
            chk_int('CAPM_ADVICE ' || r.a || ' sizes on the latest list', v_n, r.n_rows);
            chk_int('CAPM_ADVICE ' || r.a || ' candidates inside the step cap', v_num, r.n_cand);
            chk_int('CAPM_ADVICE ' || r.a || ' current_bytes MiB', v_num2 / n_mib, r.cur);
            chk_int('CAPM_ADVICE ' || r.a || ' one current row', v_num3, 1);
            chk_true('CAPM_ADVICE ' || r.a || ' cover_hours 720 on every size', v_r2 = 720 AND n_aux = 720);
            chk_int('CAPM_ADVICE ' || r.a || ' n_intervals', v_cur, 60);
            chk_int('CAPM_ADVICE ' || r.a || ' n_days', v_days, 30);
            SELECT COUNT(*) INTO v_n FROM capm_advice
             WHERE dbid = v_dbid AND area = r.a
               AND (reference_fallback <> 'N' OR reference_bytes <> current_bytes OR reference_bytes IS NULL
                    OR size_factor IS NULL);
            chk_int('CAPM_ADVICE ' || r.a || ' the reference size is the current size on every row', v_n, 0);
            area(r.a);
            chk_int('CAPM_AREA ' || r.a || ' reference_bytes = current_bytes', a_ref, r.cur * n_mib);
            chk_str('CAPM_AREA ' || r.a || ' reference_fallback', a_fb, 'N');
        END LOOP;
        SELECT rel_cost, gain, gain_unit, dbtime_sec INTO v_num, v_num2, v_str, v_num3
          FROM capm_advice WHERE dbid = v_dbid AND area = 'BUFFER_CACHE' AND size_bytes = 1536 * n_mib;
        chk_close('CAPM_ADVICE cache 1536 MiB rel_cost 2.45 / 2', v_num, 2.45 / 2, 0.000001);
        chk_close('CAPM_ADVICE cache 1536 MiB gain -0.45 u in percent of DB time', v_num2,
                  -pct(60, 0.45, n_dbt), 0.000001);
        chk_str  ('CAPM_ADVICE cache gain_unit', v_str, 'DBTIME_PCT');
        chk_close('CAPM_ADVICE cache dbtime_sec = the window''s DB time', v_num3, n_dbt, 0.000001);
        SELECT est_hit_pct, cur_hit_pct, gain, overalloc, gain_unit, is_candidate
          INTO v_num, v_num2, v_num3, v_r2, v_str, v_c1
          FROM capm_advice WHERE dbid = v_dbid AND area = 'PGA_TARGET' AND size_bytes = 1.5 * n_gib;
        chk_close('CAPM_ADVICE PGA 1.5 GiB est_hit_pct 100 x 9000 / 9060', v_num, 100 * 9000 / 9060, 0.000001);
        chk_close('CAPM_ADVICE PGA 1.5 GiB cur_hit_pct 90', v_num2, 90, 0.000001);
        chk_close('CAPM_ADVICE PGA 1.5 GiB gain', v_num3, meta_n('MEM_PGA_KNEE_GAIN'), 0.000001);
        chk_int  ('CAPM_ADVICE PGA 1.5 GiB overalloc 60 x 1', v_r2, 60);
        chk_str  ('CAPM_ADVICE PGA gain_unit', v_str, 'HIT_PTS');
        SELECT is_candidate, gain INTO v_c1, v_num
          FROM capm_advice WHERE dbid = v_dbid AND area = 'PGA_TARGET' AND size_bytes = 3 * n_gib;
        chk_str  ('CAPM_ADVICE PGA 3 GiB is outside the step cap', v_c1, 'N');
        SELECT is_candidate, gain INTO v_c1, v_num
          FROM capm_advice WHERE dbid = v_dbid AND area = 'SHARED_POOL' AND size_bytes = 2560 * n_mib;
        chk_str  ('CAPM_ADVICE shared pool 2560 MiB is outside the step cap', v_c1, 'N');
        chk_close('CAPM_ADVICE shared pool 2560 MiB gain 2 u all the same', v_num, pct(60, 2, n_dbt), 0.000001);

        DBMS_OUTPUT.PUT_LINE('=== M26 CAPM_AREA / CAPM_SGA_BALANCE (shipped knobs) ===');
        area('PGA_TARGET');
        chk_close('CAPM_AREA PGA_TARGET best_gain 10 points', a_best, meta_n('MEM_PGA_GAIN'), 0.000001);
        chk_int  ('CAPM_AREA PGA_TARGET best_bytes 2 GiB', a_bestb, 2 * n_gib);
        chk_int  ('CAPM_AREA PGA_TARGET grow_bytes (knee 1.5 GiB, no over-allocation from 1.75 GiB)',
                  a_grow, meta_n('MEM_PGA_SUGGEST_MIB') * n_mib);
        chk_true ('CAPM_AREA PGA_TARGET no slack size', a_slack IS NULL);
        chk_str  ('CAPM_AREA PGA_TARGET advisor_thin', a_thin, 'N');
        area('BUFFER_CACHE');
        chk_close('CAPM_AREA BUFFER_CACHE best_gain', a_best, meta_n('MEM_CACHE_GAIN'), 0.000001);
        chk_int  ('CAPM_AREA BUFFER_CACHE slack_bytes', a_slack, meta_n('MEM_CACHE_SLACK_MIB') * n_mib);
        chk_int  ('CAPM_AREA BUFFER_CACHE cover_hours', a_cover, 720);
        area('SHARED_POOL');
        chk_close('CAPM_AREA SHARED_POOL best_gain', a_best, meta_n('MEM_SHP_GAIN'), 0.000001);
        chk_int  ('CAPM_AREA SHARED_POOL best_bytes 2048 MiB (2560 is outside the cap)', a_bestb, 2048 * n_mib);
        chk_int  ('CAPM_AREA SHARED_POOL grow_bytes = the knee', a_grow, meta_n('MEM_SHP_KNEE_MIB') * n_mib);
        chk_true ('CAPM_AREA SHARED_POOL no slack size', a_slack IS NULL);
        area('SGA_TOTAL');
        chk_close('CAPM_AREA SGA_TOTAL best_gain', a_best, meta_n('MEM_SGA_GAIN'), 0.000001);
        chk_int  ('CAPM_AREA SGA_TOTAL best_bytes: the smallest size reaching it', a_bestb, 6144 * n_mib);
        SELECT COUNT(*) INTO v_n FROM capm_area WHERE dbid = v_dbid;
        chk_int('CAPM_AREA four advisor areas', v_n, 4);
        SELECT n_days, n_ops, n_reversals, cache_grows, shpool_forced_grows, sga_forced_grows,
               cache_bytes, shpool_bytes, floor_bytes
          INTO v_days, v_num, v_num2, v_num3, v_r2, n_aux, v_cur, v_sug, v_exp
          FROM capm_sga_balance WHERE dbid = v_dbid AND instance_number = 1;
        chk_int ('CAPM_SGA_BALANCE n_days', v_days, 30);
        chk_true('CAPM_SGA_BALANCE nothing was resized',
                 v_num = 0 AND v_num2 = 0 AND v_num3 = 0 AND v_r2 = 0 AND n_aux = 0);
        chk_int ('CAPM_SGA_BALANCE cache_bytes', v_cur, 2560 * n_mib);
        chk_int ('CAPM_SGA_BALANCE shpool_bytes', v_sug, 1024 * n_mib);
        chk_true('CAPM_SGA_BALANCE no floor without a grow', v_exp IS NULL);
        SELECT shift_bytes, shift_pct, shift_pool, cache_min_bytes, shpool_min_bytes
          INTO v_num, v_num2, v_str, v_cur, v_sug
          FROM capm_sga_balance WHERE dbid = v_dbid AND instance_number = 1;
        chk_true('CAPM_SGA_BALANCE no pool is below its window peak', v_num = 0 AND v_num2 = 0 AND v_str IS NULL);
        chk_true('CAPM_SGA_BALANCE cache_min_bytes / shpool_min_bytes',
                 v_cur = 2560 * n_mib AND v_sug = 1024 * n_mib);

        DBMS_OUTPUT.PUT_LINE('=== M26 CAPM_EVIDENCE of the advisor areas (shipped knobs) ===');
        FOR r IN (SELECT 'PGA_TARGET' AS a, 8 AS n FROM dual UNION ALL SELECT 'BUFFER_CACHE', 4 FROM dual
                  UNION ALL SELECT 'SHARED_POOL', 7 FROM dual UNION ALL SELECT 'SGA_TOTAL', 4 FROM dual
                  UNION ALL SELECT 'SGA_BALANCE', 3 FROM dual) LOOP
            SELECT COUNT(*) INTO v_n FROM capm_evidence WHERE dbid = v_dbid AND area = r.a;
            chk_int('CAPM_EVIDENCE ' || r.a || ' signals', v_n, r.n);
        END LOOP;
        SELECT COUNT(*) INTO v_n FROM capm_evidence
         WHERE kind NOT IN ('USAGE', 'ADVISOR', 'SYMPTOM', 'CONTEXT')
            OR direction NOT IN ('PRESSURE', 'SLACK', 'NEUTRAL')
            OR evidence_text IS NULL OR observed_at IS NULL OR value IS NULL;
        chk_int('CAPM_EVIDENCE every row has a kind, a direction, a value, a time and a sentence', v_n, 0);
        chk_e('shipped', 'PGA_ADV_HIT_GAIN_PTS', meta_n('MEM_PGA_GAIN'), 'PRESSURE');
        chk_str ('PGA_ADV_HIT_GAIN_PTS kind', e_kind, 'ADVISOR');
        chk_str ('PGA_ADV_HIT_GAIN_PTS unit', e_unit, 'PTS');
        chk_int ('PGA_ADV_HIT_GAIN_PTS threshold = mem_pga_gain_pts', e_thr, 2);
        chk_true('PGA_ADV_HIT_GAIN_PTS observed_at = the window end', e_at = d_last + 18/24);
        chk_true('PGA_ADV_HIT_GAIN_PTS text names 10.00 points, 2.00 GiB and 1.00 GiB (got ' || e_txt || ')',
                 INSTR(e_txt, '10.00 points at 2.00 GiB against the current 1.00 GiB (threshold 2 points)') > 0);
        chk_e('shipped', 'PGA_ADV_OVERALLOC', meta_n('MEM_PGA_ADV_OVER'), 'PRESSURE');
        chk_str ('PGA_ADV_OVERALLOC unit', e_unit, 'COUNT');
        chk_e('shipped', 'PGA_ADV_SHRINK_LOSS_PTS', meta_n('MEM_PGA_NEAR_LOSS'), 'NEUTRAL');
        chk_true('PGA_ADV_SHRINK_LOSS_PTS text names the nearest smaller size (got ' || e_txt || ')',
                 INSTR(e_txt, 'loss of 10.00 points at 768 MiB') > 0);
        chk_e('shipped', 'PGA_MULTIPASS_PCT', meta_n('MEM_PGA_MULTI'), 'PRESSURE');
        chk_str ('PGA_MULTIPASS_PCT kind', e_kind, 'SYMPTOM');
        chk_close('PGA_MULTIPASS_PCT threshold = mem_multipass_pct', e_thr, 0.1, 0.000001);
        chk_e('shipped', 'PGA_ONEPASS_PCT', meta_n('MEM_PGA_ONE'), 'NEUTRAL');
        chk_e('shipped', 'PGA_OVERALLOC_COUNT', meta_n('MEM_PGA_OAC'), 'PRESSURE');
        chk_e('shipped', 'PGA_TEMP_IO_DBTIME_PCT', meta_n('MEM_PGA_TEMP'), 'NEUTRAL');
        chk_e('shipped', 'PGA_AUTO_SHARE_MIN_PCT', 60, 'NEUTRAL');
        chk_str ('PGA_AUTO_SHARE_MIN_PCT kind', e_kind, 'CONTEXT');
        chk_true('PGA_AUTO_SHARE_MIN_PCT threshold NULL', e_thr IS NULL);
        chk_true('PGA_AUTO_SHARE_MIN_PCT observed_at = day 100 06:00 (day 50 is outside the window)',
                 e_at = meta_d('MEM_PGA_AUTO_MIN'));
        chk_true('PGA_AUTO_SHARE_MIN_PCT text has no threshold (got ' || e_txt || ')',
                 INSTR(e_txt, '60.00% at ') > 0 AND INSTR(e_txt, 'threshold') = 0);
        chk_e('shipped', 'CACHE_ADV_GAIN_DBTIME_PCT', meta_n('MEM_CACHE_GAIN'), 'NEUTRAL');
        chk_e('shipped', 'CACHE_ADV_SHRINK_LOSS_DBTIME_PCT', meta_n('MEM_CACHE_SLACK_LOSS'), 'SLACK');
        chk_close('CACHE_ADV_SHRINK_LOSS_DBTIME_PCT threshold = mem_shrink_dbtime_pct', e_thr, 0.5, 0.000001);
        chk_true('CACHE_ADV_SHRINK_LOSS_DBTIME_PCT text names 1.50 GiB and 2.50 GiB (got ' || e_txt || ')',
                 INSTR(e_txt, 'of DB time lost at 1.50 GiB against the current 2.50 GiB') > 0);
        chk_e('shipped', 'CACHE_FREE_BUFFER_WAIT_DBTIME_PCT', meta_n('MEM_CACHE_FBW'), 'NEUTRAL');
        chk_e('shipped', 'CACHE_GROWS', 0, 'NEUTRAL');
        chk_e('shipped', 'SHPOOL_ADV_GAIN_DBTIME_PCT', meta_n('MEM_SHP_GAIN'), 'PRESSURE');
        chk_e('shipped', 'SHPOOL_ADV_SHRINK_LOSS_DBTIME_PCT', meta_n('MEM_SHP_NEAR_LOSS'), 'NEUTRAL');
        chk_e('shipped', 'SHPOOL_WAIT_DBTIME_PCT', meta_n('MEM_SHP_WAIT'), 'NEUTRAL');
        chk_e('shipped', 'SHPOOL_RELOAD_PCT', meta_n('MEM_SHP_RELOAD'), 'NEUTRAL');
        chk_e('shipped', 'SHPOOL_ROWCACHE_MISS_PCT', meta_n('MEM_SHP_MISS'), 'NEUTRAL');
        chk_e('shipped', 'SHPOOL_FORCED_GROWS', 0, 'NEUTRAL');
        chk_e('shipped', 'SHPOOL_FREE_MIN_PCT', meta_n('MEM_SHP_FREE_MIN'), 'NEUTRAL');
        chk_str ('SHPOOL_FREE_MIN_PCT kind', e_kind, 'CONTEXT');
        chk_int ('SHPOOL_FREE_MIN_PCT threshold = mem_shpool_free_pct', e_thr, 25);
        chk_true('SHPOOL_FREE_MIN_PCT observed_at = day 105 18:00 (day 40 is outside the window)',
                 e_at = meta_d('MEM_SHP_FREE_MIN'));
        chk_e('shipped', 'SGA_ADV_GAIN_DBTIME_PCT', meta_n('MEM_SGA_GAIN'), 'NEUTRAL');
        chk_e('shipped', 'SGA_ADV_SHRINK_LOSS_DBTIME_PCT', meta_n('MEM_SGA_NEAR_LOSS'), 'NEUTRAL');
        chk_e('shipped', 'SGA_POOLS_PRESSED', 0, 'NEUTRAL');
        chk_e('shipped', 'SGA_FORCED_GROWS', 0, 'NEUTRAL');
        chk_e('shipped', 'SGA_RESIZE_OPS_DAY', 0, 'NEUTRAL');
        chk_str ('SGA_RESIZE_OPS_DAY unit', e_unit, 'PER_DAY');
        chk_e('shipped', 'SGA_RESIZE_REVERSALS', 0, 'NEUTRAL');
        chk_e('shipped', 'SGA_POOL_SHIFT_PCT', 0, 'NEUTRAL');
        chk_str ('SGA_POOL_SHIFT_PCT kind', e_kind, 'SYMPTOM');
        chk_str ('SGA_POOL_SHIFT_PCT unit', e_unit, 'PCT');
        chk_int ('SGA_POOL_SHIFT_PCT threshold = mem_shift_pct', e_thr, 10);
        chk_true('SGA_POOL_SHIFT_PCT text without a shift (got ' || e_txt || ')',
                 e_txt = 'Neither the buffer cache nor the shared pool is below its largest size of the window,'
                         || ' a shift of 0.00% of sga_target (threshold 10%).');

        DBMS_OUTPUT.PUT_LINE('=== M26 CAPM_VERDICT of the advisor areas (shipped knobs) ===');
        SELECT COUNT(*) INTO v_n FROM capm_verdict WHERE dbid = v_dbid;
        chk_int('CAPM_VERDICT six areas', v_n, 6);
        chk_v('shipped', 'PGA_TARGET', 'UNDERSIZED', 'ADVISOR_AND_SYMPTOM', meta_n('MEM_PGA_SUGGEST_MIB'));
        chk_int('PGA_TARGET current_bytes 1 GiB', v_cur, n_gib);
        chk_str('PGA_TARGET suggested_param', v_param, 'pga_aggregate_target');
        chk_str('PGA_TARGET exceeds_host_ram (4 GiB SGA + 1792 MiB within 80% of 16 GiB)', v_xram, 'N');
        chk_true('PGA_TARGET exceeds_sga NULL (no SGA pool)', v_xsga IS NULL);
        chk_int('PGA_TARGET n_days', v_days, 30);
        chk_int('PGA_TARGET n_evidence', v_nev, 8);
        chk_int('PGA_TARGET n_pressure (advisor gain, advisor over-allocation, multi-pass, over-allocations)', v_npr, 4);
        chk_str('PGA_TARGET mem_mode', v_mode, 'ASMM');
        chk_v('shipped', 'BUFFER_CACHE', 'OVERSIZED', 'SHRINK_COSTS_LITTLE', meta_n('MEM_CACHE_SLACK_MIB'));
        chk_int('BUFFER_CACHE current_bytes 2560 MiB', v_cur, 2560 * n_mib);
        chk_str('BUFFER_CACHE suggested_param', v_param, 'db_cache_size');
        chk_true('BUFFER_CACHE exceeds_host_ram NULL (a pool row)', v_xram IS NULL);
        chk_str('BUFFER_CACHE exceeds_sga (1536 MiB within the two pools'' 2560 + 1024)', v_xsga, 'N');
        chk_int('BUFFER_CACHE n_pressure', v_npr, 0);
        chk_v('shipped', 'SHARED_POOL', 'OK', 'ADVISOR_ONLY', NULL);
        chk_str('SHARED_POOL suggested_param', v_param, 'shared_pool_size');
        chk_int('SHARED_POOL n_pressure (the advisor gain alone)', v_npr, 1);
        chk_true('SHARED_POOL exceeds_sga NULL without a suggestion', v_xsga IS NULL);
        chk_v('shipped', 'SGA_TOTAL', 'OK', 'SIZED_RIGHT', NULL);
        chk_int('SGA_TOTAL current_bytes 4 GiB', v_cur, 4 * n_gib);
        chk_str('SGA_TOTAL suggested_param', v_param, 'sga_target');
        chk_true('SGA_TOTAL exceeds_host_ram NULL without a suggestion', v_xram IS NULL);
        chk_v('shipped', 'SGA_BALANCE', 'OK', 'STABLE', NULL);
        chk_int('SGA_BALANCE current_bytes = sga_target', v_cur, 4 * n_gib);
        chk_true('SGA_BALANCE names no parameter while stable', v_param IS NULL);
        chk_true('SGA_BALANCE exceeds_host_ram NULL', v_xram IS NULL);
        chk_true('SGA_BALANCE exceeds_sga NULL', v_xsga IS NULL);
        chk_int('SGA_BALANCE n_days', v_days, 30);

        DBMS_OUTPUT.PUT_LINE('=== M26.4 CAPR_MEM_* report views (shipped knobs) ===');
        SELECT COUNT(*), COUNT(CASE WHEN rank_mem = area_rank THEN 1 END),
               COUNT(CASE WHEN db_pdb = 'FIXCDB' AND con_dbid = dbid THEN 1 END),
               COUNT(CASE WHEN reason_text IS NOT NULL THEN 1 END)
          INTO v_n, v_num, v_num2, v_num3
          FROM capr_mem_verdict WHERE dbid = v_dbid;
        chk_int('CAPR_MEM_VERDICT six areas', v_n, 6);
        chk_int('CAPR_MEM_VERDICT rank_mem follows area_rank (one instance)', v_num, 6);
        chk_int('CAPR_MEM_VERDICT rows are the root''s, labelled with the database', v_num2, 6);
        chk_int('CAPR_MEM_VERDICT every reason has its sentence', v_num3, 6);
        SELECT COUNT(*) INTO v_n
          FROM capr_mem_verdict r
          JOIN capm_verdict m
            ON m.dbid = r.dbid AND m.instance_number = r.instance_number AND m.area = r.area
         WHERE m.grade = r.grade AND m.reason = r.reason
           AND DECODE(m.suggested_bytes, r.suggested_bytes, 1, 0) = 1
           AND DECODE(m.current_bytes, r.current_bytes, 1, 0) = 1;
        chk_int('CAPR_MEM_VERDICT carries CAPM_VERDICT''s grade, reason and sizes', v_n, 6);
        SELECT LISTAGG(area, ',') WITHIN GROUP (ORDER BY rank_mem) INTO v_txt
          FROM capr_mem_verdict WHERE dbid = v_dbid;
        chk_true('CAPR_MEM_VERDICT report order (got ' || v_txt || ')',
                 v_txt = 'SGA_TOTAL,BUFFER_CACHE,SHARED_POOL,SGA_BALANCE,PGA_TARGET,PGA_LIMIT');
        chk_h('shipped', 'SGA_TOTAL',    'N', 'SGA total needs no change.');
        chk_h('shipped', 'BUFFER_CACHE', 'Y', 'Buffer cache is oversized. It could shrink from 2560 MiB to 1536 MiB.');
        chk_h('shipped', 'SHARED_POOL',  'N', 'Shared pool needs no change.');
        chk_h('shipped', 'SGA_BALANCE',  'N', 'SGA balance needs no change.');
        chk_h('shipped', 'PGA_TARGET',   'Y', 'PGA target is undersized. Raise pga_aggregate_target from 1 GiB to 1792 MiB.');
        chk_h('shipped', 'PGA_LIMIT',    'Y', 'PGA limit is undersized. Raise pga_aggregate_limit from 2 GiB to '
                                              || meta_n('PGA_SUGGEST_MIB') || ' MiB.');
        SELECT current_size, suggested_size, change_pct INTO v_str, v_txt, v_num
          FROM capr_mem_verdict WHERE dbid = v_dbid AND area = 'PGA_TARGET';
        chk_str  ('CAPR_MEM_VERDICT PGA_TARGET current_size (a whole GiB)', v_str, '1 GiB');
        chk_str  ('CAPR_MEM_VERDICT PGA_TARGET suggested_size (whole MiB)', v_txt, '1792 MiB');
        chk_close('CAPR_MEM_VERDICT PGA_TARGET change_pct', v_num, 75, 0.000001);
        SELECT suggested_size, change_pct INTO v_txt, v_num
          FROM capr_mem_verdict WHERE dbid = v_dbid AND area = 'SGA_BALANCE';
        chk_true('CAPR_MEM_VERDICT SGA_BALANCE: no suggested_size, no change_pct', v_txt IS NULL AND v_num IS NULL);

        SELECT COUNT(*), COUNT(DISTINCT rank_ev), MIN(rank_ev), MAX(rank_ev) INTO v_n, v_num, v_num2, v_num3
          FROM capr_mem_evidence WHERE dbid = v_dbid;
        SELECT COUNT(*) INTO v_days FROM capm_evidence WHERE dbid = v_dbid;
        chk_int ('CAPR_MEM_EVIDENCE one row per CAPM_EVIDENCE row', v_n, v_days);
        chk_true('CAPR_MEM_EVIDENCE rank_ev is 1..n', v_num = v_n AND v_num2 = 1 AND v_num3 = v_n);
        SELECT COUNT(*) INTO v_n
          FROM (SELECT area, signal, kind, direction, value, evidence_text FROM capm_evidence WHERE dbid = v_dbid
                MINUS
                SELECT area, signal, kind, direction, value, evidence_text FROM capr_mem_evidence WHERE dbid = v_dbid);
        chk_int('CAPR_MEM_EVIDENCE carries every signal unchanged', v_n, 0);
        SELECT LISTAGG(area, ',') WITHIN GROUP (ORDER BY first_rank) INTO v_txt
          FROM (SELECT area, MIN(rank_ev) AS first_rank FROM capr_mem_evidence WHERE dbid = v_dbid GROUP BY area);
        chk_true('CAPR_MEM_EVIDENCE areas in report order (got ' || v_txt || ')',
                 v_txt = 'SGA_TOTAL,BUFFER_CACHE,SHARED_POOL,SGA_BALANCE,PGA_TARGET,PGA_LIMIT');
        SELECT MAX(CASE WHEN signal = 'PGA_ADV_SHRINK_LOSS_PTS' THEN rank_ev END)
               - MAX(CASE WHEN signal = 'PGA_ADV_OVERALLOC' THEN rank_ev END),
               MAX(CASE WHEN signal = 'PGA_MULTIPASS_PCT' THEN rank_ev END)
               - MAX(CASE WHEN signal = 'PGA_ADV_SHRINK_LOSS_PTS' THEN rank_ev END),
               MAX(CASE WHEN signal = 'PGA_AUTO_SHARE_MIN_PCT' THEN rank_ev END)
               - MAX(CASE WHEN kind = 'SYMPTOM' THEN rank_ev END)
          INTO v_num, v_num2, v_num3
          FROM capr_mem_evidence WHERE dbid = v_dbid AND area = 'PGA_TARGET';
        chk_true('CAPR_MEM_EVIDENCE inside an area: ADVISOR before SYMPTOM before CONTEXT, PRESSURE first',
                 v_num > 0 AND v_num2 > 0 AND v_num3 > 0);

        SELECT COUNT(*), LISTAGG(component, ',') WITHIN GROUP (ORDER BY rank_comp),
               SUM(n_ops + n_grows + n_shrinks + n_forced_grows), COUNT(last_resize_at),
               COUNT(CASE WHEN current_bytes = min_bytes AND current_bytes = max_bytes THEN 1 END)
          INTO v_n, v_txt, v_num, v_num2, v_num3
          FROM capr_mem_components WHERE dbid = v_dbid;
        chk_int ('CAPR_MEM_COMPONENTS four components hold memory (streams pool 0 and the targets left out)', v_n, 4);
        chk_true('CAPR_MEM_COMPONENTS largest first, a tie by name (got ' || v_txt || ')',
                 v_txt = 'DEFAULT buffer cache,shared pool,java pool,large pool');
        chk_true('CAPR_MEM_COMPONENTS never resized: no operation, no move, min = max = current',
                 v_num = 0 AND v_num2 = 0 AND v_num3 = 4);
        SELECT current_bytes, pct_of_total, is_pool INTO v_num, v_num2, v_c1
          FROM capr_mem_components WHERE dbid = v_dbid AND component = 'DEFAULT buffer cache';
        chk_int  ('CAPR_MEM_COMPONENTS buffer cache current_bytes 2560 MiB', v_num, 2560 * n_mib);
        chk_close('CAPR_MEM_COMPONENTS buffer cache pct_of_total = 2560 of 3712 MiB', v_num2,
                  ROUND(100 * 2560 / 3712, 1), 0.000001);
        chk_str  ('CAPR_MEM_COMPONENTS buffer cache is_pool', v_c1, 'Y');
        SELECT COUNT(*), COUNT(DISTINCT ts), MIN(ts), MAX(ts), SUM(ops),
               COUNT(CASE WHEN bytes = min_bytes AND bytes = max_bytes THEN 1 END)
          INTO v_n, v_num, v_ws, v_we, v_num2, v_num3
          FROM capr_mem_comp_points WHERE dbid = v_dbid;
        chk_int ('CAPR_MEM_COMP_POINTS one row per component and window day', v_n, 4 * 30);
        chk_true('CAPR_MEM_COMP_POINTS the 30 window days up to the last day',
                 v_num = 30 AND v_ws = d_last - 29 AND v_we = d_last);
        chk_true('CAPR_MEM_COMP_POINTS flat: no operation, each day min = max = bytes', v_num2 = 0 AND v_num3 = v_n);

        DBMS_OUTPUT.PUT_LINE('=== M26 advisor area knob variations ===');
        BEGIN
            -- The knee and the step cap move a suggestion.
            knob('mem_knee_pct', 99);
            chk_v('mem_knee_pct 99 (only 2 GiB captures 9.9 points)', 'PGA_TARGET', 'UNDERSIZED', 'ADVISOR_AND_SYMPTOM', 2048);
            knob('mem_knee_pct', 40);
            chk_v('mem_knee_pct 40 (knee 1.25 GiB, still over-allocating below 1.75 GiB)', 'PGA_TARGET',
                  'UNDERSIZED', 'ADVISOR_AND_SYMPTOM', 1792);
            reset_knobs;
            knob('mem_max_step', 1.6);
            chk_v('mem_max_step 1.6 (no size inside the cap ends the over-allocation: the largest)', 'PGA_TARGET',
                  'UNDERSIZED', 'ADVISOR_AND_SYMPTOM', 1536);
            chk_e('mem_max_step 1.6', 'PGA_ADV_HIT_GAIN_PTS', meta_n('MEM_PGA_KNEE_GAIN'), 'PRESSURE');
            chk_v('mem_max_step 1.6 (1536 MiB is outside the cap, 1792 is the smallest slack size)', 'BUFFER_CACHE',
                  'OVERSIZED', 'SHRINK_COSTS_LITTLE', 1792);
            reset_knobs;

            -- The shrink rule.
            knob('mem_shrink_dbtime_pct', 0.2);
            chk_v('mem_shrink_dbtime_pct 0.2 (1792 MiB loses 0.3%)', 'BUFFER_CACHE', 'OVERSIZED', 'SHRINK_COSTS_LITTLE', 2048);
            chk_e('mem_shrink_dbtime_pct 0.2', 'CACHE_ADV_SHRINK_LOSS_DBTIME_PCT', pct(60, 0.1, n_dbt), 'SLACK');
            knob('mem_shrink_dbtime_pct', 0.01);
            chk_v('mem_shrink_dbtime_pct 0.01 (every smaller size loses more)', 'BUFFER_CACHE', 'OK', 'SIZED_RIGHT', NULL);
            chk_e('mem_shrink_dbtime_pct 0.01: the nearest smaller size', 'CACHE_ADV_SHRINK_LOSS_DBTIME_PCT',
                  pct(60, 0.05, n_dbt), 'NEUTRAL');
            reset_knobs;
            knob('mem_shrink_min_days', 31);
            chk_v('mem_shrink_min_days 31 (30 sampled days)', 'BUFFER_CACHE', 'OK', 'SHRINK_UNPROVEN', NULL);
            reset_knobs;

            -- Thin advisor coverage: the window holds 720 hours, the startup 1458.
            knob('mem_min_uptime_hours', 720);
            chk_v('mem_min_uptime_hours 720 (coverage is 720)', 'PGA_TARGET', 'UNDERSIZED', 'ADVISOR_AND_SYMPTOM', 1792);
            knob('mem_min_uptime_hours', 721);
            chk_v('mem_min_uptime_hours 721', 'PGA_TARGET',   'INSUFFICIENT_EVIDENCE', 'ADVISOR_THIN', NULL);
            chk_int('mem_min_uptime_hours 721: PGA_TARGET symptoms still count (multi-pass, over-allocations)', v_npr, 2);
            chk_int('mem_min_uptime_hours 721: PGA_TARGET has no ADVISOR row left', v_nev, 5);
            chk_int('mem_min_uptime_hours 721: PGA_TARGET current_bytes stays', v_cur, n_gib);
            chk_v('mem_min_uptime_hours 721', 'BUFFER_CACHE', 'INSUFFICIENT_EVIDENCE', 'ADVISOR_THIN', NULL);
            chk_v('mem_min_uptime_hours 721', 'SHARED_POOL',  'INSUFFICIENT_EVIDENCE', 'ADVISOR_THIN', NULL);
            chk_v('mem_min_uptime_hours 721', 'SGA_TOTAL',    'INSUFFICIENT_EVIDENCE', 'ADVISOR_THIN', NULL);
            chk_v('mem_min_uptime_hours 721 (no advisor)', 'SGA_BALANCE', 'OK', 'STABLE', NULL);
            SELECT COUNT(*) INTO v_n FROM capm_advice WHERE dbid = v_dbid AND is_candidate = 'Y';
            chk_int('mem_min_uptime_hours 721: no candidate anywhere', v_n, 0);
            knob('mem_min_uptime_hours', 2000);
            area('SHARED_POOL');
            chk_int('mem_min_uptime_hours 2000 (above the 1458 h uptime): no advisor increment counts', a_cover, 0);
            chk_str('mem_min_uptime_hours 2000: advisor_thin', a_thin, 'Y');
            chk_v('mem_min_uptime_hours 2000', 'SHARED_POOL', 'INSUFFICIENT_EVIDENCE', 'ADVISOR_THIN', NULL);
            chk_e('mem_min_uptime_hours 2000: a symptom of a short startup still counts', 'SHPOOL_RELOAD_PCT',
                  meta_n('MEM_SHP_RELOAD'), 'NEUTRAL');
            reset_knobs;

            -- Symptoms decide between ADVISOR_ONLY, SYMPTOM_ONLY and UNDERSIZED.
            knob('mem_symptom_dbtime_pct', 0.03);
            chk_e('mem_symptom_dbtime_pct 0.03', 'SHPOOL_WAIT_DBTIME_PCT', meta_n('MEM_SHP_WAIT'), 'PRESSURE');
            chk_v('mem_symptom_dbtime_pct 0.03 (advisor gain and shared pool waits)', 'SHARED_POOL',
                  'UNDERSIZED', 'ADVISOR_AND_SYMPTOM', meta_n('MEM_SHP_KNEE_MIB'));
            chk_true('SHARED_POOL UNDERSIZED: exceeds_host_ram NULL (a pool row)', v_xram IS NULL);
            chk_str ('SHARED_POOL UNDERSIZED: exceeds_sga (1536 MiB within the two pools'' 3584)', v_xsga, 'N');
            chk_e('mem_symptom_dbtime_pct 0.03', 'SGA_POOLS_PRESSED', 1, 'NEUTRAL');
            chk_v('mem_symptom_dbtime_pct 0.03 (free buffer waits 0.02%)', 'BUFFER_CACHE',
                  'OVERSIZED', 'SHRINK_COSTS_LITTLE', 1536);
            knob('mem_knee_pct', 70);
            chk_v('mem_knee_pct 70 (1280 MiB captures 1.1 of 1.5)', 'SHARED_POOL', 'UNDERSIZED', 'ADVISOR_AND_SYMPTOM', 1280);
            knob('mem_knee_pct', 90);
            knob('mem_symptom_dbtime_pct', 0.01);
            chk_e('mem_symptom_dbtime_pct 0.01', 'CACHE_FREE_BUFFER_WAIT_DBTIME_PCT', meta_n('MEM_CACHE_FBW'), 'PRESSURE');
            chk_v('mem_symptom_dbtime_pct 0.01 (a symptom, no advisor gain, so no longer oversized)', 'BUFFER_CACHE',
                  'OK', 'SYMPTOM_ONLY', NULL);
            chk_e('mem_symptom_dbtime_pct 0.01', 'SGA_POOLS_PRESSED', 2, 'PRESSURE');
            chk_v('mem_symptom_dbtime_pct 0.01 (both pools pressed)', 'SGA_TOTAL', 'OK', 'SYMPTOM_ONLY', NULL);
            reset_knobs;
            knob('mem_gain_dbtime_pct', 0.25);
            chk_v('mem_gain_dbtime_pct 0.25 (SGA advisor gain 0.3%, no symptom)', 'SGA_TOTAL', 'OK', 'ADVISOR_ONLY', NULL);
            knob('mem_gain_dbtime_pct', 2);
            knob('mem_shpool_free_pct', 10);
            chk_e('mem_shpool_free_pct 10', 'SHPOOL_FREE_MIN_PCT', meta_n('MEM_SHP_FREE_MIN'), 'SLACK');
            chk_v('mem_gain_dbtime_pct 2, mem_shpool_free_pct 10 (a CONTEXT row in SLACK decides nothing)',
                  'SHARED_POOL', 'OK', 'SIZED_RIGHT', NULL);
            reset_knobs;

            -- Either advisor signal is advisor pressure, any symptom a symptom.
            knob('mem_pga_gain_pts', 11);
            chk_e('mem_pga_gain_pts 11', 'PGA_ADV_HIT_GAIN_PTS', meta_n('MEM_PGA_GAIN'), 'NEUTRAL');
            chk_v('mem_pga_gain_pts 11 (the advisor still over-allocates)', 'PGA_TARGET',
                  'UNDERSIZED', 'ADVISOR_AND_SYMPTOM', 1792);
            knob('mem_multipass_pct', 0.3);
            knob('mem_onepass_pct', 2);
            chk_e('mem_multipass_pct 0.3', 'PGA_MULTIPASS_PCT', meta_n('MEM_PGA_MULTI'), 'NEUTRAL');
            chk_e('mem_onepass_pct 2', 'PGA_ONEPASS_PCT', meta_n('MEM_PGA_ONE'), 'PRESSURE');
            knob('mem_temp_io_dbtime_pct', 1);
            chk_e('mem_temp_io_dbtime_pct 1', 'PGA_TEMP_IO_DBTIME_PCT', meta_n('MEM_PGA_TEMP'), 'PRESSURE');
            knob('mem_reload_pct', 0.4);
            knob('mem_rowcache_miss_pct', 2);
            chk_e('mem_reload_pct 0.4', 'SHPOOL_RELOAD_PCT', meta_n('MEM_SHP_RELOAD'), 'PRESSURE');
            chk_e('mem_rowcache_miss_pct 2', 'SHPOOL_ROWCACHE_MISS_PCT', meta_n('MEM_SHP_MISS'), 'PRESSURE');
            reset_knobs;

            -- The two knobs of the reference size and the pool shift.
            knob('mem_ref_tolerance_pct', 0);
            knob('mem_shift_pct', 100);
            SELECT COUNT(*) INTO v_n FROM cap_cfg_check
             WHERE knob IN ('mem_ref_tolerance_pct', 'mem_shift_pct') AND status = 'OK';
            chk_int('CAP_CFG_CHECK mem_ref_tolerance_pct 0 and mem_shift_pct 100 are in range', v_n, 2);
            chk_v('mem_ref_tolerance_pct 0 (the current size has its hours: no fallback needed)', 'SHARED_POOL',
                  'OK', 'ADVISOR_ONLY', NULL);
            knob('mem_ref_tolerance_pct', 101);
            knob('mem_shift_pct', 0);
            SELECT COUNT(*) INTO v_n FROM cap_cfg_check
             WHERE knob IN ('mem_ref_tolerance_pct', 'mem_shift_pct') AND status = 'BAD';
            chk_int('CAP_CFG_CHECK mem_ref_tolerance_pct 101 and mem_shift_pct 0 are BAD', v_n, 2);
            reset_knobs;

            -- The host memory flag of PGA_TARGET.
            knob('mem_host_ram_pct', 30);
            chk_v('mem_host_ram_pct 30', 'PGA_TARGET', 'UNDERSIZED', 'ADVISOR_AND_SYMPTOM', 1792);
            chk_str('mem_host_ram_pct 30: PGA_TARGET exceeds_host_ram (4 GiB + 1792 MiB over 4.8 GiB)', v_xram, 'Y');
            reset_knobs;

            -- Every restart pulled into the window: 237 intervals over three
            -- startups, none across a restart. Day 0's snapshots are outside.
            knob('mem_window_days', 120);
            n_all := (2 * n_p - 1) + (118 - 2 * n_p) + 120;
            SELECT COUNT(CASE WHEN seg_in_win = 'N' THEN 1 END) INTO v_n FROM capm_snap WHERE dbid = v_dbid;
            chk_int('mem_window_days 120: no startup is skipped', v_n, 0);
            SELECT MIN(snap_id) INTO v_n FROM capm_delta WHERE dbid = v_dbid;
            chk_int('mem_window_days 120: CAPM_DELTA starts at day 0 18:00', v_n, 2001);
            SELECT MIN(snap_id) INTO v_n FROM capm_comp WHERE dbid = v_dbid;
            chk_int('mem_window_days 120: CAPM_COMP starts at day 0 06:00', v_n, 2000);
            area('PGA_TARGET');
            chk_int('mem_window_days 120: PGA_TARGET cover_hours = 237 intervals x 12 h', a_cover, n_all * 12);
            chk_int('mem_window_days 120: n_days (the restart day ends no interval)', a_days, 119);
            chk_close('mem_window_days 120: best_gain unchanged', a_best, meta_n('MEM_PGA_GAIN'), 0.000001);
            chk_e('mem_window_days 120', 'PGA_ADV_OVERALLOC', n_all * 3, 'PRESSURE');
            chk_e('mem_window_days 120: nothing is subtracted across a restart', 'PGA_OVERALLOC_COUNT',
                  meta_n('MEM_PGA_OAC_ALL'), 'PRESSURE');
            chk_e('mem_window_days 120', 'PGA_MULTIPASS_PCT', meta_n('MEM_PGA_MULTI'), 'PRESSURE');
            chk_e('mem_window_days 120', 'SHPOOL_RELOAD_PCT', meta_n('MEM_SHP_RELOAD'), 'NEUTRAL');
            chk_e('mem_window_days 120: day 50 is inside now', 'PGA_AUTO_SHARE_MIN_PCT', 30, 'NEUTRAL');
            chk_e('mem_window_days 120: day 40 is inside now', 'SHPOOL_FREE_MIN_PCT', 100 * 64 / 1024, 'NEUTRAL');
            area('BUFFER_CACHE');
            chk_int('mem_window_days 120: BUFFER_CACHE cover_hours', a_cover, n_all * 12);
            SELECT COUNT(*) INTO v_n FROM capm_delta WHERE dbid = v_dbid AND delta < 0;
            chk_int('mem_window_days 120: no negative increment', v_n, 0);
            -- A startup under the minimum uptime: the first one was observed
            -- for (PARTIAL_DAY + 5) days and 6 hours, under 700 hours.
            knob('mem_min_uptime_hours', 700);
            n_long := (118 - 2 * n_p) + 120;
            SELECT COUNT(DISTINCT startup_time) INTO v_n FROM capm_snap WHERE dbid = v_dbid AND seg_ok = 'N';
            chk_int('mem_min_uptime_hours 700: one startup is too short', v_n, 1);
            area('PGA_TARGET');
            chk_int('mem_min_uptime_hours 700: its intervals leave the advisor coverage', a_cover, n_long * 12);
            chk_e('mem_min_uptime_hours 700', 'PGA_ADV_OVERALLOC', n_long * 3, 'PRESSURE');
            chk_e('mem_min_uptime_hours 700: its symptoms still count', 'PGA_OVERALLOC_COUNT',
                  meta_n('MEM_PGA_OAC_ALL'), 'PRESSURE');
        EXCEPTION
            WHEN OTHERS THEN
                reset_knobs;
                COMMIT;
                RAISE;
        END;
        reset_knobs;
        COMMIT;

        DBMS_OUTPUT.PUT_LINE('=== M26 advisor area parameter and data variations ===');
        SAVEPOINT m25_mem;
        BEGIN
            UPDATE cap_fixture_parameter SET value_num = 4294967296
             WHERE parameter_name = 'memory_target' AND snap_id = n_latest;
            chk_v('memory_target > 0', 'PGA_TARGET',   'INSUFFICIENT_EVIDENCE', 'AMM', NULL);
            chk_str('memory_target > 0: mem_mode', v_mode, 'AMM');
            chk_v('memory_target > 0', 'BUFFER_CACHE', 'INSUFFICIENT_EVIDENCE', 'AMM', NULL);
            chk_v('memory_target > 0', 'SHARED_POOL',  'INSUFFICIENT_EVIDENCE', 'AMM', NULL);
            chk_v('memory_target > 0', 'SGA_TOTAL',    'INSUFFICIENT_EVIDENCE', 'AMM', NULL);
            chk_v('memory_target > 0', 'SGA_BALANCE',  'INSUFFICIENT_EVIDENCE', 'AMM', NULL);
            chk_h('memory_target > 0', 'PGA_TARGET', 'N', 'PGA target could not be judged.');
            SELECT COUNT(CASE WHEN actionable = 'Y' THEN 1 END),
                   COUNT(CASE WHEN reason_text LIKE '%memory_target%' THEN 1 END)
              INTO v_n, v_num FROM capr_mem_verdict WHERE dbid = v_dbid;
            chk_true('memory_target > 0: CAPR_MEM_VERDICT nothing actionable, six AMM sentences', v_n = 0 AND v_num = 6);
            ROLLBACK TO SAVEPOINT m25_mem;

            UPDATE cap_fixture_parameter SET value_num = 0
             WHERE parameter_name = 'sga_target' AND snap_id = n_latest;
            chk_v('sga_target 0', 'SGA_TOTAL',    'INSUFFICIENT_EVIDENCE', 'MANUAL_SIZING', NULL);
            chk_str('sga_target 0: mem_mode', v_mode, 'MANUAL');
            chk_v('sga_target 0', 'SGA_BALANCE',  'INSUFFICIENT_EVIDENCE', 'MANUAL_SIZING', NULL);
            chk_v('sga_target 0 (graded from its own advisor)', 'BUFFER_CACHE', 'OVERSIZED', 'SHRINK_COSTS_LITTLE', 1536);
            chk_true('sga_target 0: BUFFER_CACHE exceeds_sga NULL (no sga_target to fit in)', v_xsga IS NULL);
            chk_v('sga_target 0 (graded from its own advisor)', 'SHARED_POOL',  'OK', 'ADVISOR_ONLY', NULL);
            chk_v('sga_target 0', 'PGA_TARGET',   'UNDERSIZED', 'ADVISOR_AND_SYMPTOM', 1792);
            ROLLBACK TO SAVEPOINT m25_mem;

            -- A repository target whose reader cannot read the memory views.
            DELETE FROM cap_fixture_mem_comp;
            DELETE FROM cap_fixture_workarea_hstgrm;
            DELETE FROM cap_fixture_pga_advice;
            DELETE FROM cap_fixture_sga_advice;
            DELETE FROM cap_fixture_cache_advice;
            DELETE FROM cap_fixture_shpool_advice;
            DELETE FROM cap_fixture_sgastat;
            DELETE FROM cap_fixture_librarycache;
            DELETE FROM cap_fixture_rowcache;
            DELETE FROM cap_fixture_system_event;
            chk_v('no memory history', 'PGA_TARGET',   'INSUFFICIENT_EVIDENCE', 'NOT_COLLECTED', NULL);
            chk_true('no memory history: PGA_TARGET current_bytes NULL', v_cur IS NULL);
            chk_v('no memory history', 'BUFFER_CACHE', 'INSUFFICIENT_EVIDENCE', 'NOT_COLLECTED', NULL);
            chk_int('no memory history: BUFFER_CACHE has no evidence (free buffer waits cannot be zero unseen)', v_nev, 0);
            chk_v('no memory history', 'SHARED_POOL',  'INSUFFICIENT_EVIDENCE', 'NOT_COLLECTED', NULL);
            chk_int('no memory history: SHARED_POOL has no evidence', v_nev, 0);
            chk_v('no memory history', 'SGA_TOTAL',    'INSUFFICIENT_EVIDENCE', 'NOT_COLLECTED', NULL);
            chk_int('no memory history: SGA_TOTAL has no evidence', v_nev, 0);
            chk_v('no memory history', 'SGA_BALANCE',  'INSUFFICIENT_EVIDENCE', 'NOT_COLLECTED', NULL);
            chk_int('no memory history: SGA_BALANCE n_days', v_days, 0);
            chk_v('no memory history (PGA statistics are a copy of their own)', 'PGA_LIMIT', 'UNDERSIZED', 'PEAK_NEAR_LIMIT',
                  meta_n('PGA_SUGGEST_MIB'));
            ROLLBACK TO SAVEPOINT m25_mem;

            -- A floor that cannot fit. The buffer cache holds 256 MiB all
            -- window: the two pools share 1280 MiB, and the shared pool's
            -- advisor asks for 1536.
            UPDATE cap_fixture_mem_comp SET current_size = 256 * 1048576
             WHERE component = 'DEFAULT buffer cache';
            knob('mem_symptom_dbtime_pct', 0.03);
            chk_v('pools of 256 + 1024 MiB', 'SHARED_POOL', 'UNDERSIZED', 'ADVISOR_AND_SYMPTOM', 1536);
            chk_str('pools of 256 + 1024 MiB: SHARED_POOL exceeds_sga, the suggestion stays', v_xsga, 'Y');
            chk_h('pools of 256 + 1024 MiB', 'SHARED_POOL', 'Y',
                  'Shared pool is undersized. Set shared_pool_size to at least 1536 MiB (the pool holds 1 GiB now).'
                  || ' That does not fit in sga_target: raise sga_target first.');
            chk_v('pools of 256 + 1024 MiB (no move, no shift)', 'SGA_BALANCE', 'OK', 'STABLE', NULL);
            UPDATE cap_fixture_mem_comp SET current_size = 512 * 1048576
             WHERE component = 'DEFAULT buffer cache';
            chk_v('pools of 512 + 1024 MiB', 'SHARED_POOL', 'UNDERSIZED', 'ADVISOR_AND_SYMPTOM', 1536);
            chk_str('pools of 512 + 1024 MiB: 1536 MiB is exactly their sum, no flag', v_xsga, 'N');
            DELETE FROM cap_fixture_mem_comp WHERE component = 'DEFAULT buffer cache';
            chk_v('no buffer cache component', 'SHARED_POOL', 'UNDERSIZED', 'ADVISOR_AND_SYMPTOM', 1536);
            chk_true('no buffer cache component: exceeds_sga NULL', v_xsga IS NULL);
            knob('mem_symptom_dbtime_pct', 0.1);
            ROLLBACK TO SAVEPOINT m25_mem;

            -- The buffer cache advisor restarts its estimates at day 105 06:00
            -- (snapshot 2210), as it does when the cache is resized: that
            -- interval's increment is negative and dropped, 59 intervals stay.
            UPDATE cap_fixture_cache_advice a
               SET a.estd_physical_read_time = a.estd_physical_read_time -
                   (SELECT b.estd_physical_read_time FROM cap_fixture_cache_advice b
                     WHERE b.snap_id = 2209 AND b.bpid = a.bpid AND b.block_size = a.block_size
                       AND b.size_for_estimate = a.size_for_estimate)
             WHERE a.bpid = 3 AND a.snap_id >= 2210;
            v_exp := n_dbt - dbt(2209, 2210);
            area('BUFFER_CACHE');
            chk_int('cache advisor reset: cover_hours = 59 intervals x 12 h', a_cover, 708);
            chk_int('cache advisor reset: n_days', a_days, 30);
            SELECT n_intervals, est_cost, cur_cost, dbtime_sec INTO v_n, v_num, v_num2, v_num3
              FROM capm_advice WHERE dbid = v_dbid AND area = 'BUFFER_CACHE' AND size_bytes = 1536 * n_mib;
            chk_int  ('cache advisor reset: n_intervals', v_n, 59);
            chk_close('cache advisor reset: est_cost = 59 x 2.45 u', v_num, 59 * 2.45 * n_u, 0.000001);
            chk_close('cache advisor reset: cur_cost = 59 x 2 u', v_num2, 59 * 2 * n_u, 0.000001);
            chk_close('cache advisor reset: dbtime_sec = the DB time of the 59 intervals', v_num3, v_exp, 0.000001);
            chk_e('cache advisor reset', 'CACHE_ADV_SHRINK_LOSS_DBTIME_PCT', pct(59, 0.45, v_exp), 'SLACK');
            chk_e('cache advisor reset', 'CACHE_ADV_GAIN_DBTIME_PCT', pct(59, 0.2, v_exp), 'NEUTRAL');
            chk_v('cache advisor reset', 'BUFFER_CACHE', 'OVERSIZED', 'SHRINK_COSTS_LITTLE', 1536);
            area('SHARED_POOL');
            chk_int('cache advisor reset: the shared pool advisor keeps its 720 hours', a_cover, 720);
            ROLLBACK TO SAVEPOINT m25_mem;

            -- The shared pool advisor's list changes mid-window. Every size is
            -- compared over the current size's 60 intervals, and where the
            -- advisor did not list it the next smaller listed size stands in.
            -- 1408 MiB is listed from day 111 06:00 on (snapshot 2222, 1 u an
            -- interval): 1280 MiB (1.9 u) stands in for the 41 intervals
            -- before. 1664 MiB is on the last two snapshots only (0.1 u):
            -- 1536 MiB (1.6 u) stands in for 59. 1100 MiB is listed early in
            -- the window only and has no row. 640 MiB is listed from snapshot
            -- 2222 on (7 u) and 512 MiB, the only smaller size, not at snapshot
            -- 2200: two intervals have no size at or below 640.
            INSERT INTO cap_fixture_shpool_advice
            SELECT dbid, con_dbid, instance_number, snap_id, 1408, 1.375, 704, 1000, 0, 1,
                   (snap_id - 2221) * 1 * n_u, 0.33, 0
              FROM cap_fixture_shpool_advice
             WHERE shared_pool_size_for_estimate = 1024 AND snap_id BETWEEN 2222 AND n_latest;
            INSERT INTO cap_fixture_shpool_advice
            SELECT dbid, con_dbid, instance_number, snap_id, 1100, 1.0742, 550, 1000, 0, 1,
                   (snap_id - 2181) * 0.1 * n_u, 0.03, 0
              FROM cap_fixture_shpool_advice
             WHERE shared_pool_size_for_estimate = 1024 AND snap_id BETWEEN 2182 AND 2200;
            INSERT INTO cap_fixture_shpool_advice
            SELECT dbid, con_dbid, instance_number, snap_id, 1664, 1.625, 832, 1000, 0, 1,
                   (snap_id - n_latest + 2) * 0.1 * n_u, 0.03, 0
              FROM cap_fixture_shpool_advice
             WHERE shared_pool_size_for_estimate = 1024 AND snap_id IN (n_latest - 1, n_latest);
            INSERT INTO cap_fixture_shpool_advice
            SELECT dbid, con_dbid, instance_number, snap_id, 640, 0.625, 320, 1000, 0, 1,
                   (snap_id - 2221) * 7 * n_u, 2.33, 0
              FROM cap_fixture_shpool_advice
             WHERE shared_pool_size_for_estimate = 1024 AND snap_id BETWEEN 2222 AND n_latest;
            DELETE FROM cap_fixture_shpool_advice
             WHERE shared_pool_size_for_estimate = 512 AND snap_id = 2200;
            SELECT cover_hours, n_intervals, est_cost, cur_cost, dbtime_sec, gain, is_candidate
              INTO v_num, v_n, v_num2, v_num3, v_r2, n_aux, v_c1
              FROM capm_advice WHERE dbid = v_dbid AND area = 'SHARED_POOL' AND size_bytes = 1408 * n_mib;
            chk_int  ('shared pool list change: 1408 MiB cover_hours = the current size''s 720', v_num, 720);
            chk_int  ('shared pool list change: 1408 MiB n_intervals', v_n, 60);
            chk_close('shared pool list change: 1408 MiB est_cost = 41 x 1.9 u (1280 MiB stands in) + 19 x 1 u',
                      v_num2, (41 * 1.9 + 19) * n_u, 0.000001);
            chk_close('shared pool list change: the current size over the same 60 intervals, 60 x 3 u',
                      v_num3, 60 * 3 * n_u, 0.000001);
            chk_close('shared pool list change: dbtime_sec = the window''s DB time', v_r2, n_dbt, 0.000001);
            chk_close('shared pool list change: 1408 MiB gain', n_aux, pct(41 * 1.1 + 19 * 2, 1, n_dbt), 0.000001);
            chk_str  ('shared pool list change: 1408 MiB is a candidate', v_c1, 'Y');
            SELECT COUNT(*) INTO v_n FROM capm_advice
             WHERE dbid = v_dbid AND area = 'SHARED_POOL' AND size_bytes = 1100 * n_mib;
            chk_int('shared pool list change: 1100 MiB left the list, no row', v_n, 0);
            SELECT cover_hours, gain, is_candidate INTO v_num, v_num2, v_c1
              FROM capm_advice WHERE dbid = v_dbid AND area = 'SHARED_POOL' AND size_bytes = 1664 * n_mib;
            chk_int  ('shared pool list change: 1664 MiB cover_hours 720', v_num, 720);
            chk_close('shared pool list change: 1664 MiB gain = 59 x (3 - 1.6) u (1536 MiB stands in) + 2.9 u',
                      v_num2, pct(59 * 1.4 + 2.9, 1, n_dbt), 0.000001);
            chk_str  ('shared pool list change: 1664 MiB, one increment of its own, is a candidate', v_c1, 'Y');
            SELECT n_intervals, cover_hours, is_candidate INTO v_n, v_num, v_c1
              FROM capm_advice WHERE dbid = v_dbid AND area = 'SHARED_POOL' AND size_bytes = 640 * n_mib;
            chk_int('shared pool list change: 640 MiB n_intervals (two have no size at or below it)', v_n, 58);
            chk_int('shared pool list change: 640 MiB cover_hours', v_num, 696);
            chk_str('shared pool list change: 640 MiB is no candidate short of the current size''s intervals', v_c1, 'N');
            SELECT n_intervals, is_candidate, gain INTO v_n, v_c1, v_num
              FROM capm_advice WHERE dbid = v_dbid AND area = 'SHARED_POOL' AND size_bytes = 768 * n_mib;
            chk_true('shared pool list change: 768 MiB, listed throughout, keeps its 60 intervals and its loss',
                     v_n = 60 AND v_c1 = 'Y' AND ABS(v_num + pct(60, 2, n_dbt)) <= 0.000001);
            SELECT COUNT(*) INTO v_n
              FROM (SELECT gain, LAG(gain) OVER (ORDER BY size_bytes) AS prev_gain
                      FROM capm_advice
                     WHERE dbid = v_dbid AND area = 'SHARED_POOL' AND size_bytes BETWEEN 768 * n_mib AND 1536 * n_mib)
             WHERE gain < prev_gain;
            chk_int('shared pool list change: the gain never falls from 768 to 1536 MiB', v_n, 0);
            area('SHARED_POOL');
            chk_close('shared pool list change: best_gain is 2048 MiB''s, as before the change',
                      a_best, meta_n('MEM_SHP_GAIN'), 0.000001);
            chk_int  ('shared pool list change: best_bytes', a_bestb, 2048 * n_mib);
            chk_int  ('shared pool list change: grow_bytes = the knee, 1408 MiB (83.1 of 90 u)', a_grow, 1408 * n_mib);
            chk_int  ('shared pool list change: the current size keeps its 720 hours', a_cover, 720);
            ROLLBACK TO SAVEPOINT m25_mem;

            -- A one-way shift. The shared pool takes 256 MiB from the cache at
            -- day 100, 105 and 110 06:00 (snapshots 2200, 2210, 2220), not by
            -- force, and gives nothing back: 768 MiB of the 4 GiB sga_target.
            UPDATE cap_fixture_mem_comp
               SET current_size = (CASE component WHEN 'shared pool' THEN 1024 ELSE 2560 END
                                   + CASE component WHEN 'shared pool' THEN 1 ELSE -1 END
                                     * 256 * (1 + LEAST(FLOOR((snap_id - 2200) / 10), 2))) * 1048576,
                   oper_count = 1 + LEAST(FLOOR((snap_id - 2200) / 10), 2),
                   last_oper_type = CASE component WHEN 'shared pool' THEN 'GROW' ELSE 'SHRINK' END,
                   last_oper_mode = 'DEFERRED'
             WHERE component IN ('shared pool', 'DEFAULT buffer cache') AND snap_id >= 2200;
            SELECT n_ops, n_reversals, shpool_forced_grows, shift_bytes, shift_pct, shift_pool,
                   cache_max_bytes, cache_bytes, shpool_min_bytes, shpool_bytes
              INTO v_num, v_num2, v_num3, v_r2, n_aux, v_str, v_cur, v_sug, v_exp, a_cur
              FROM capm_sga_balance WHERE dbid = v_dbid AND instance_number = 1;
            chk_int  ('one-way shift: n_ops = 3 moves x 2 pools', v_num, 6);
            chk_int  ('one-way shift: n_reversals', v_num2, 0);
            chk_int  ('one-way shift: shpool_forced_grows', v_num3, 0);
            chk_int  ('one-way shift: shift_bytes = cache_max_bytes - cache_bytes', v_r2, 768 * n_mib);
            chk_true ('one-way shift: the cache fell from 2560 to 1792 MiB',
                      v_cur = 2560 * n_mib AND v_sug = 1792 * n_mib);
            chk_true ('one-way shift: the shared pool rose from 1024 to 1792 MiB',
                      v_exp = 1024 * n_mib AND a_cur = 1792 * n_mib);
            chk_close('one-way shift: shift_pct = 100 x 768 / 4096', n_aux, 18.75, 0.000001);
            chk_str  ('one-way shift: shift_pool', v_str, 'DEFAULT buffer cache');
            chk_e('one-way shift', 'SGA_POOL_SHIFT_PCT', 18.75, 'PRESSURE');
            chk_true('one-way shift: SGA_POOL_SHIFT_PCT observed_at = the window end', e_at = d_last + 18/24);
            chk_true('one-way shift: SGA_POOL_SHIFT_PCT text (got ' || e_txt || ')',
                     e_txt = 'The buffer cache shrank from its window peak of 2.50 GiB to 1.75 GiB while the'
                             || ' shared pool grew from its window low of 1.00 GiB to 1.75 GiB, a shift of 18.75%'
                             || ' of sga_target (threshold 10%).');
            chk_e('one-way shift', 'SGA_RESIZE_REVERSALS', 0, 'NEUTRAL');
            chk_e('one-way shift', 'SGA_RESIZE_OPS_DAY', 6 / 30, 'NEUTRAL');
            chk_v('one-way shift', 'SGA_BALANCE', 'DRIFTING', 'ONE_WAY_SHIFT', NULL);
            chk_true('one-way shift: SGA_BALANCE names no parameter', v_param IS NULL);
            chk_h('one-way shift', 'SGA_BALANCE', 'Y', 'SGA balance is drifting.');
            SELECT current_bytes, min_bytes, max_bytes, n_ops, n_grows, n_shrinks, n_forced_grows, last_resize_at
              INTO v_num, v_num2, v_num3, v_r2, n_aux, v_exp, v_cur, v_d
              FROM capr_mem_components WHERE dbid = v_dbid AND component = 'DEFAULT buffer cache';
            chk_true('one-way shift: CAPR_MEM_COMPONENTS cache 1792 MiB now, 1792..2560 in the window',
                     v_num = 1792 * n_mib AND v_num2 = 1792 * n_mib AND v_num3 = 2560 * n_mib);
            chk_true('one-way shift: CAPR_MEM_COMPONENTS cache 3 operations, 3 shrinks, no grow',
                     v_r2 = 3 AND n_aux = 0 AND v_exp = 3 AND v_cur = 0);
            chk_true('one-way shift: CAPR_MEM_COMPONENTS cache last_resize_at = day 110 06:00', v_d = d_base + 110 + 6/24);
            SELECT rank_comp INTO v_num FROM capr_mem_components WHERE dbid = v_dbid AND component = 'shared pool';
            chk_int ('one-way shift: CAPR_MEM_COMPONENTS a 1792 MiB tie ranks by name, the shared pool second', v_num, 2);
            SELECT SUM(ops), MIN(bytes), MAX(bytes),
                   MAX(CASE WHEN ts = d_base + 100 THEN min_bytes END), MAX(CASE WHEN ts = d_base + 100 THEN max_bytes END)
              INTO v_num, v_num2, v_num3, v_r2, n_aux
              FROM capr_mem_comp_points WHERE dbid = v_dbid AND component = 'DEFAULT buffer cache';
            chk_true('one-way shift: CAPR_MEM_COMP_POINTS cache 3 operations, 2560 down to 1792 MiB',
                     v_num = 3 AND v_num2 = 1792 * n_mib AND v_num3 = 2560 * n_mib);
            chk_true('one-way shift: CAPR_MEM_COMP_POINTS day 100 holds both sizes (2304 at 06:00 and 18:00: min = max)',
                     v_r2 = 2304 * n_mib AND n_aux = 2304 * n_mib);
            chk_int ('one-way shift: SGA_BALANCE n_pressure (the shift alone)', v_npr, 1);
            chk_e('one-way shift (a pool row is no SHARED_POOL or BUFFER_CACHE symptom)', 'SGA_POOLS_PRESSED', 0, 'NEUTRAL');
            knob('mem_shift_pct', 18.75);
            chk_v('one-way shift, mem_shift_pct 18.75 (at the knob)', 'SGA_BALANCE', 'DRIFTING', 'ONE_WAY_SHIFT', NULL);
            knob('mem_shift_pct', 19);
            chk_e('one-way shift, mem_shift_pct 19', 'SGA_POOL_SHIFT_PCT', 18.75, 'NEUTRAL');
            chk_v('one-way shift, mem_shift_pct 19', 'SGA_BALANCE', 'OK', 'STABLE', NULL);
            ROLLBACK TO SAVEPOINT m25_mem;

            -- The shared pool is the one squeezed: it loses 512 MiB to the
            -- large pool at snapshot 2200 and the cache never moves.
            UPDATE cap_fixture_mem_comp
               SET current_size = (CASE component WHEN 'shared pool' THEN 512 ELSE 576 END) * 1048576,
                   oper_count = 1, last_oper_type = CASE component WHEN 'shared pool' THEN 'SHRINK' ELSE 'GROW' END,
                   last_oper_mode = 'DEFERRED'
             WHERE component IN ('shared pool', 'large pool') AND snap_id >= 2200;
            chk_e('shared pool squeezed', 'SGA_POOL_SHIFT_PCT', 12.5, 'PRESSURE');
            chk_true('shared pool squeezed: SGA_POOL_SHIFT_PCT text (got ' || e_txt || ')',
                     e_txt = 'The shared pool shrank from its window peak of 1024 MiB to 512 MiB while the'
                             || ' buffer cache is at its window low of 2560 MiB, a shift of 12.50%'
                             || ' of sga_target (threshold 10%).');
            chk_v('shared pool squeezed', 'SGA_BALANCE', 'DRIFTING', 'ONE_WAY_SHIFT', NULL);
            ROLLBACK TO SAVEPOINT m25_mem;

            -- An oscillation that ends below the peak. From snapshot 2200
            -- four cycles of two snapshots: the shared pool takes 256 MiB
            -- from the cache, then gives 128 MiB back. The cache ends 512 MiB
            -- under its peak, and churn still decides the grade.
            UPDATE cap_fixture_mem_comp
               SET current_size = (CASE component WHEN 'shared pool' THEN 1024 ELSE 2560 END
                                   + CASE component WHEN 'shared pool' THEN 1 ELSE -1 END
                                     * CASE WHEN snap_id <= 2207
                                            THEN 128 * (FLOOR((snap_id - 2200) / 2) + 1)
                                                 + CASE MOD(snap_id, 2) WHEN 0 THEN 128 ELSE 0 END
                                            ELSE 512 END) * 1048576,
                   oper_count = LEAST(snap_id - 2199, 8),
                   last_oper_type = CASE WHEN component = 'shared pool' AND MOD(LEAST(snap_id, 2207), 2) = 0
                                           OR component <> 'shared pool' AND MOD(LEAST(snap_id, 2207), 2) = 1
                                         THEN 'GROW' ELSE 'SHRINK' END,
                   last_oper_mode = 'DEFERRED'
             WHERE component IN ('shared pool', 'DEFAULT buffer cache') AND snap_id >= 2200;
            SELECT n_ops, n_reversals, shift_bytes, shift_pool, floor_bytes
              INTO v_num, v_num2, v_num3, v_str, v_exp
              FROM capm_sga_balance WHERE dbid = v_dbid AND instance_number = 1;
            chk_int('drifting oscillation: n_ops = 8 intervals x 2 pools', v_num, 16);
            chk_int('drifting oscillation: n_reversals = 7 turns a pool', v_num2, 14);
            chk_int('drifting oscillation: shift_bytes (the cache lost 512 MiB, the shared pool is 128 under its peak)',
                    v_num3, 512 * n_mib);
            chk_str('drifting oscillation: shift_pool', v_str, 'DEFAULT buffer cache');
            chk_e('drifting oscillation', 'SGA_POOL_SHIFT_PCT', 12.5, 'PRESSURE');
            chk_e('drifting oscillation', 'SGA_RESIZE_REVERSALS', 14, 'PRESSURE');
            chk_v('drifting oscillation (churn wins by rule order)', 'SGA_BALANCE', 'THRASHING', 'RESIZE_CHURN', 1664);
            chk_str('drifting oscillation: SGA_BALANCE suggested_param', v_param, 'shared_pool_size');
            chk_int('drifting oscillation: SGA_BALANCE n_pressure (reversals and shift)', v_npr, 2);
            knob('mem_resize_reversals', 15);
            chk_v('drifting oscillation, mem_resize_reversals 15 (no churn left, the shift stays)', 'SGA_BALANCE',
                  'DRIFTING', 'ONE_WAY_SHIFT', NULL);
            chk_true('drifting oscillation, mem_resize_reversals 15: SGA_BALANCE names no parameter', v_param IS NULL);
            ROLLBACK TO SAVEPOINT m25_mem;

            -- A thin advisor falls back. The shared pool has just been resized
            -- to 1072 MiB: on the last two snapshots that is the advisor's
            -- factor 1 size, with one increment (12 hours), and every other
            -- factor is relative to it. 1024 MiB, 4.48% away, has the window's
            -- 720 hours and becomes the reference. 1536 MiB is off the latest
            -- list and still a candidate: 1280 MiB (1.9 u) stands in for it in
            -- the last interval.
            UPDATE cap_fixture_shpool_advice
               SET shared_pool_size_factor = ROUND(shared_pool_size_for_estimate / 1072, 4)
             WHERE snap_id IN (n_latest - 1, n_latest);
            INSERT INTO cap_fixture_shpool_advice
            SELECT dbid, con_dbid, instance_number, snap_id, 1072, 1, 536, 1000, 0, 1,
                   (snap_id - n_latest + 2) * 2.8 * n_u, 0.93, 0
              FROM cap_fixture_shpool_advice
             WHERE shared_pool_size_for_estimate = 1024 AND snap_id IN (n_latest - 1, n_latest);
            DELETE FROM cap_fixture_shpool_advice
             WHERE shared_pool_size_for_estimate = 1536 AND snap_id = n_latest;
            SELECT COUNT(*), COUNT(CASE WHEN is_candidate = 'Y' THEN 1 END),
                   COUNT(CASE WHEN reference_fallback = 'Y' AND reference_bytes = 1024 * n_mib
                               AND current_bytes = 1072 * n_mib THEN 1 END)
              INTO v_n, v_num, v_num2
              FROM capm_advice WHERE dbid = v_dbid AND area = 'SHARED_POOL';
            chk_int('fallback: CAPM_ADVICE lists every size of the window (nine and the new one)', v_n, 10);
            chk_int('fallback: candidates 768, 896, 1152, 1280, 1536, 2048 (512 and 2560 outside the cap around 1072)',
                    v_num, 6);
            chk_int('fallback: every row carries current 1072 MiB, reference 1024 MiB, reference_fallback Y', v_num2, 10);
            SELECT is_current, is_candidate, cover_hours, size_factor INTO v_c1, v_str, v_num, v_num2
              FROM capm_advice WHERE dbid = v_dbid AND area = 'SHARED_POOL' AND size_bytes = 1072 * n_mib;
            chk_true('fallback: 1072 MiB is the current row, no candidate, the reference''s 720 hours',
                     v_c1 = 'Y' AND v_str = 'N' AND v_num = 720 AND v_num2 = 1);
            SELECT gain INTO v_num
              FROM capm_advice WHERE dbid = v_dbid AND area = 'SHARED_POOL' AND size_bytes = 1072 * n_mib;
            chk_close('fallback: 1072 MiB gain = (3 - 2.8) u in its own interval, the reference stands in for 59',
                      v_num, pct(1, 0.2, n_dbt), 0.000001);
            SELECT is_current, is_candidate, cover_hours, gain INTO v_c1, v_str, v_num, v_num2
              FROM capm_advice WHERE dbid = v_dbid AND area = 'SHARED_POOL' AND size_bytes = 1024 * n_mib;
            chk_true('fallback: the reference 1024 MiB is no candidate (720 hours, gain 0 against itself)',
                     v_c1 = 'N' AND v_str = 'N' AND v_num = 720 AND v_num2 = 0);
            SELECT is_candidate, n_intervals, gain, cur_cost, size_factor INTO v_c1, v_n, v_num, v_num2, v_num3
              FROM capm_advice WHERE dbid = v_dbid AND area = 'SHARED_POOL' AND size_bytes = 1536 * n_mib;
            chk_str  ('fallback: 1536 MiB, off the latest list, is a candidate', v_c1, 'Y');
            chk_true ('fallback: 1536 MiB size_factor NULL off the latest list', v_num3 IS NULL);
            chk_int  ('fallback: 1536 MiB n_intervals = the reference''s', v_n, 60);
            chk_close('fallback: 1536 MiB cur_cost = the reference over its 60 intervals, 60 x 3 u',
                      v_num2, 60 * 3 * n_u, 0.000001);
            chk_close('fallback: 1536 MiB gain = (3 - 1.6) u over 59 intervals + (3 - 1.9) u in the last',
                      v_num, pct(59 * 1.4 + 1.1, 1, n_dbt), 0.000001);
            area('SHARED_POOL');
            chk_int  ('fallback: CAPM_AREA current_bytes stays the advisor''s 1072 MiB', a_cur, 1072 * n_mib);
            chk_int  ('fallback: CAPM_AREA reference_bytes 1024 MiB', a_ref, 1024 * n_mib);
            chk_str  ('fallback: CAPM_AREA reference_fallback', a_fb, 'Y');
            chk_str  ('fallback: CAPM_AREA advisor_thin', a_thin, 'N');
            chk_int  ('fallback: CAPM_AREA cover_hours = the reference''s', a_cover, 720);
            chk_int  ('fallback: CAPM_AREA n_days', a_days, 30);
            chk_close('fallback: best_gain = (3 - 1.5) u against the reference, as against 1024 MiB before',
                      a_best, meta_n('MEM_SHP_GAIN'), 0.000001);
            chk_int  ('fallback: best_bytes', a_bestb, 2048 * n_mib);
            chk_int  ('fallback: grow_bytes = the knee, a size off the latest list', a_grow, 1536 * n_mib);
            chk_true ('fallback: no slack size', a_slack IS NULL);
            chk_e('fallback', 'SHPOOL_ADV_GAIN_DBTIME_PCT', meta_n('MEM_SHP_GAIN'), 'PRESSURE');
            chk_true('fallback: the gain sentence names the reference and the current size (got ' || e_txt || ')',
                     INSTR(e_txt, '% of DB time saved at 2048 MiB, measured against 1024 MiB, the advised size'
                                  || ' with enough history nearest to the current 1072 MiB (threshold 1%).') > 0);
            chk_e('fallback: the nearest smaller candidate is 896 MiB, not the reference',
                  'SHPOOL_ADV_SHRINK_LOSS_DBTIME_PCT', meta_n('MEM_SHP_NEAR_LOSS'), 'NEUTRAL');
            chk_true('fallback: the loss sentence says so too (got ' || e_txt || ')',
                     INSTR(e_txt, '% of DB time lost at 896 MiB, measured against 1024 MiB, the advised size'
                                  || ' with enough history nearest to the current 1072 MiB (threshold') > 0);
            chk_v('fallback', 'SHARED_POOL', 'OK', 'ADVISOR_ONLY', NULL);
            chk_int('fallback: SHARED_POOL current_bytes 1072 MiB', v_cur, 1072 * n_mib);
            chk_int('fallback: SHARED_POOL n_evidence', v_nev, 7);
            area('BUFFER_CACHE');
            chk_true('fallback: the other areas keep their current size as the reference',
                     a_fb = 'N' AND a_ref = 2560 * n_mib);
            ev('CACHE_ADV_SHRINK_LOSS_DBTIME_PCT');
            chk_true('fallback: their sentences still read "against the current" (got ' || e_txt || ')',
                     INSTR(e_txt, 'of DB time lost at 1.50 GiB against the current 2.50 GiB') > 0);
            knob('mem_symptom_dbtime_pct', 0.03);
            chk_v('fallback, mem_symptom_dbtime_pct 0.03 (the suggestion is a size above the current one)',
                  'SHARED_POOL', 'UNDERSIZED', 'ADVISOR_AND_SYMPTOM', 1536);
            knob('mem_symptom_dbtime_pct', 0.1);
            knob('mem_ref_tolerance_pct', 4.5);
            area('SHARED_POOL');
            chk_int('mem_ref_tolerance_pct 4.5 (1024 is 4.48% from 1072): still the reference', a_ref, 1024 * n_mib);
            knob('mem_ref_tolerance_pct', 4);
            area('SHARED_POOL');
            chk_true('mem_ref_tolerance_pct 4: no reference size', a_ref IS NULL AND a_fb = 'N');
            chk_str ('mem_ref_tolerance_pct 4: advisor_thin', a_thin, 'Y');
            chk_int ('mem_ref_tolerance_pct 4: cover_hours = the current size''s own 12', a_cover, 12);
            chk_v('mem_ref_tolerance_pct 4', 'SHARED_POOL', 'INSUFFICIENT_EVIDENCE', 'ADVISOR_THIN', NULL);
            chk_int('mem_ref_tolerance_pct 4: SHARED_POOL has no ADVISOR row left', v_nev, 5);
            chk_int('mem_ref_tolerance_pct 4: SHARED_POOL current_bytes stays', v_cur, 1072 * n_mib);
            SELECT COUNT(*), COUNT(CASE WHEN is_candidate = 'Y' THEN 1 END) INTO v_n, v_num
              FROM capm_advice WHERE dbid = v_dbid AND area = 'SHARED_POOL';
            chk_int('mem_ref_tolerance_pct 4: CAPM_ADVICE is the latest list again (1536 MiB gone)', v_n, 9);
            chk_int('mem_ref_tolerance_pct 4: no candidate', v_num, 0);
            knob('mem_ref_tolerance_pct', 10);
            -- A tie: 1088 MiB is 64 MiB from 1024 and from 1152. The larger wins.
            UPDATE cap_fixture_shpool_advice SET shared_pool_size_for_estimate = 1088
             WHERE shared_pool_size_for_estimate = 1072;
            area('SHARED_POOL');
            chk_int  ('fallback tie: reference_bytes = 1152 MiB, the larger of two equally near sizes', a_ref, 1152 * n_mib);
            chk_close('fallback tie: best_gain = (2.4 - 1.5) u against 1152 MiB', a_best, pct(60, 0.9, n_dbt), 0.000001);
            chk_e('fallback tie: the nearest smaller candidate 1024 MiB loses (3 - 2.4) u',
                  'SHPOOL_ADV_SHRINK_LOSS_DBTIME_PCT', pct(60, 0.6, n_dbt), 'NEUTRAL');
            chk_v('fallback tie (0.9% gain under the knob)', 'SHARED_POOL', 'OK', 'SIZED_RIGHT', NULL);
            -- The nearest sizes with history are too far: 1800 MiB is 248
            -- from 2048 and 264 from 1536, the tolerance is 180.
            UPDATE cap_fixture_shpool_advice SET shared_pool_size_for_estimate = 1800
             WHERE shared_pool_size_for_estimate = 1088;
            area('SHARED_POOL');
            chk_true('nearest covered size outside the tolerance: no reference', a_ref IS NULL AND a_thin = 'Y');
            chk_v('nearest covered size outside the tolerance', 'SHARED_POOL', 'INSUFFICIENT_EVIDENCE', 'ADVISOR_THIN', NULL);
            chk_int('nearest covered size outside the tolerance: current_bytes 1800 MiB', v_cur, 1800 * n_mib);
            knob('mem_ref_tolerance_pct', 14);
            area('SHARED_POOL');
            chk_int('mem_ref_tolerance_pct 14 (252 MiB): 2048 MiB is the reference', a_ref, 2048 * n_mib);
            ROLLBACK TO SAVEPOINT m25_mem;

            -- An oscillating SGA. From day 100 06:00 (snapshot 2200) eight
            -- cycles of three snapshots: the shared pool takes 64 MiB from the
            -- cache by force, 64 MiB more, then gives 128 MiB back. One more
            -- shared pool operation at snapshot 2230 changes no size.
            UPDATE cap_fixture_mem_comp
               SET current_size = (CASE component WHEN 'shared pool' THEN 1024 ELSE 2560 END
                                   + CASE component WHEN 'shared pool' THEN 1 ELSE -1 END
                                     * CASE WHEN snap_id BETWEEN 2200 AND 2223
                                            THEN DECODE(MOD(snap_id - 2200, 3), 0, 64, 1, 128, 0) ELSE 0 END
                                  ) * 1048576,
                   oper_count = LEAST(snap_id - 2199, 24)
                                + CASE WHEN component = 'shared pool' AND snap_id >= 2230 THEN 1 ELSE 0 END,
                   last_oper_type = CASE WHEN component = 'shared pool' AND MOD(LEAST(snap_id, 2223) - 2200, 3) < 2
                                           OR component <> 'shared pool' AND MOD(LEAST(snap_id, 2223) - 2200, 3) = 2
                                         THEN 'GROW' ELSE 'SHRINK' END,
                   last_oper_mode = CASE WHEN MOD(LEAST(snap_id, 2223) - 2200, 3) < 2 THEN 'IMMEDIATE' ELSE 'DEFERRED' END
             WHERE component IN ('shared pool', 'DEFAULT buffer cache') AND snap_id >= 2200;
            SELECT n_ops, ops_per_day, n_reversals, cache_grows, shpool_forced_grows, sga_forced_grows,
                   shpool_max_bytes, floor_bytes, floor_param, shpool_forced_at
              INTO v_num, v_num2, v_num3, v_r2, n_aux, v_cur, v_sug, v_exp, v_param, v_d
              FROM capm_sga_balance WHERE dbid = v_dbid AND instance_number = 1;
            chk_int  ('oscillation: n_ops = 24 intervals x 2 pools + 1', v_num, 49);
            chk_close('oscillation: ops_per_day = 49 / 30', v_num2, 49 / 30, 0.000001);
            chk_int  ('oscillation: n_reversals = 15 turns a pool + the operation without a net change', v_num3, 31);
            chk_int  ('oscillation: cache_grows (the give-backs)', v_r2, 8);
            chk_int  ('oscillation: shpool_forced_grows', n_aux, 16);
            chk_int  ('oscillation: sga_forced_grows', v_cur, 16);
            chk_int  ('oscillation: shpool_max_bytes', v_sug, 1152 * n_mib);
            chk_int  ('oscillation: floor_bytes = the largest size of the pool that grew most often', v_exp, 1152 * n_mib);
            chk_str  ('oscillation: floor_param', v_param, 'shared_pool_size');
            chk_true ('oscillation: shpool_forced_at = day 111 06:00, the last forced grow',
                      v_d = d_base + 111 + 6/24);
            chk_e('oscillation', 'SGA_RESIZE_REVERSALS', 31, 'PRESSURE');
            chk_e('oscillation', 'SGA_RESIZE_OPS_DAY', 49 / 30, 'NEUTRAL');
            chk_v('oscillation', 'SGA_BALANCE', 'THRASHING', 'RESIZE_CHURN', 1152);
            chk_str('oscillation: SGA_BALANCE suggested_param names the pool to floor', v_param, 'shared_pool_size');
            chk_h('oscillation', 'SGA_BALANCE', 'Y', 'SGA balance is thrashing. Set shared_pool_size to at least 1152 MiB.');
            chk_h('oscillation', 'SHARED_POOL', 'Y',
                  'Shared pool is undersized. Set shared_pool_size to at least 1536 MiB (the pool holds 1 GiB now).');
            SELECT SUM(n_ops), MAX(CASE WHEN component = 'shared pool' THEN n_forced_grows END),
                   MAX(CASE WHEN component = 'DEFAULT buffer cache' THEN n_grows END),
                   MAX(CASE WHEN component = 'shared pool' THEN max_bytes END)
              INTO v_num, v_num2, v_num3, v_r2
              FROM capr_mem_components WHERE dbid = v_dbid;
            chk_true('oscillation: CAPR_MEM_COMPONENTS 49 operations, 16 forced shared pool grows, 8 cache grows, peak 1152 MiB',
                     v_num = 49 AND v_num2 = 16 AND v_num3 = 8 AND v_r2 = 1152 * n_mib);
            SELECT SUM(ops), MAX(max_bytes - min_bytes) INTO v_num, v_num2
              FROM capr_mem_comp_points WHERE dbid = v_dbid;
            chk_true('oscillation: CAPR_MEM_COMP_POINTS 49 operations, a day''s range up to 128 MiB',
                     v_num = 49 AND v_num2 = 128 * n_mib);
            chk_true('oscillation: SGA_BALANCE exceeds_host_ram NULL', v_xram IS NULL);
            chk_e('oscillation', 'SHPOOL_FORCED_GROWS', 16, 'PRESSURE');
            chk_true('oscillation: SHPOOL_FORCED_GROWS observed_at = the last forced grow', e_at = d_base + 111 + 6/24);
            chk_e('oscillation', 'CACHE_GROWS', 8, 'PRESSURE');
            chk_e('oscillation', 'SGA_FORCED_GROWS', 16, 'PRESSURE');
            chk_e('oscillation', 'SGA_POOLS_PRESSED', 2, 'PRESSURE');
            chk_v('oscillation (advisor gain and forced grows)', 'SHARED_POOL', 'UNDERSIZED', 'ADVISOR_AND_SYMPTOM', 1536);
            chk_v('oscillation (the cache was grown: not oversized)', 'BUFFER_CACHE', 'OK', 'SYMPTOM_ONLY', NULL);
            chk_v('oscillation (symptoms, advisor gain 0.3% under the knob)', 'SGA_TOTAL', 'OK', 'SYMPTOM_ONLY', NULL);
            knob('mem_gain_dbtime_pct', 0.25);
            chk_v('oscillation, mem_gain_dbtime_pct 0.25', 'SGA_TOTAL', 'UNDERSIZED', 'ADVISOR_AND_SYMPTOM',
                  meta_n('MEM_SGA_KNEE_MIB'));
            chk_str('SGA_TOTAL UNDERSIZED: exceeds_host_ram (6144 MiB + pga_aggregate_target 1 GiB within 12.8 GiB)', v_xram, 'N');
            knob('mem_host_ram_pct', 40);
            chk_v('oscillation, mem_host_ram_pct 40', 'SGA_TOTAL', 'UNDERSIZED', 'ADVISOR_AND_SYMPTOM', 6144);
            chk_str('SGA_TOTAL UNDERSIZED: exceeds_host_ram (7 GiB over 6.4 GiB)', v_xram, 'Y');
            chk_h('oscillation, mem_host_ram_pct 40', 'SGA_TOTAL', 'Y',
                  'SGA total is undersized. Raise sga_target from 4 GiB to 6 GiB.'
                  || ' With the rest of the instance that passes 40% of the host''s memory.');
            knob('mem_resize_reversals', 32);
            chk_v('oscillation, mem_resize_reversals 32 (1.63 operations a day under 10)', 'SGA_BALANCE', 'OK', 'STABLE', NULL);
            knob('mem_resize_ops_day', 1.5);
            chk_e('oscillation, mem_resize_ops_day 1.5', 'SGA_RESIZE_OPS_DAY', 49 / 30, 'PRESSURE');
            chk_v('oscillation, mem_resize_ops_day 1.5', 'SGA_BALANCE', 'THRASHING', 'RESIZE_CHURN', 1152);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT m25_mem; RAISE;
        END;
        ROLLBACK TO SAVEPOINT m25_mem;
        chk_v('after the rollback', 'BUFFER_CACHE', 'OVERSIZED', 'SHRINK_COSTS_LITTLE', 1536);
        chk_v('after the rollback', 'SGA_BALANCE',  'OK', 'STABLE', NULL);
        SELECT COUNT(*) INTO v_n FROM cap_config WHERE cfg_name LIKE 'mem!_%' ESCAPE '!' AND cfg_value <> cfg_default;
        chk_int('every mem_ knob back at its default', v_n, 0);
        -- The memory sources feed the verdict views only, and only the
        -- memory report views (CAPR_MEM_*) and their SNAPSHOT tables' filler
        -- read a verdict view: no series, no anomaly and no alert can come
        -- from them.
        SELECT COUNT(*) INTO v_n FROM all_dependencies
         WHERE owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') AND referenced_owner = owner
           AND (referenced_name IN ('CAPV_MEM_COMP', 'CAPV_WORKAREA_HSTGRM', 'CAPV_PGA_ADVICE',
                                    'CAPV_SGA_ADVICE', 'CAPV_CACHE_ADVICE', 'CAPV_SHPOOL_ADVICE',
                                    'CAPV_SGASTAT', 'CAPV_LIBRARYCACHE', 'CAPV_ROWCACHE',
                                    'CAPV_SYSTEM_EVENT')
                OR referenced_name LIKE 'CAPM!_%' ESCAPE '!')
           AND name NOT LIKE 'CAPM!_%' ESCAPE '!'
           AND name NOT LIKE 'CAPR!_MEM!_%' ESCAPE '!'
           AND name <> 'CAPV_CONTRACT';
        chk_int('only CAPM_ views (and CAPV_CONTRACT) read the memory sources, only CAPR_MEM_ views read a CAPM_ view', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM all_dependencies
         WHERE owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') AND referenced_owner = owner
           AND referenced_name LIKE 'CAPR!_MEM!_%' ESCAPE '!'
           AND name NOT LIKE 'CAPR!_MEM!_%' ESCAPE '!';
        chk_int('nothing reads a CAPR_MEM_ view: no alert, no series', v_n, 0);
    EXCEPTION
        WHEN OTHERS THEN
            fail('M26 memory block raised ' || SQLERRM || ' ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    END;

    DECLARE
        d_gap   DATE := meta_d('CPUGAP_DAY');
        d_gnext DATE := meta_d('CPUGAP_NEXT');
        d_last  DATE := meta_d('LAST_DAY');
        d_part  DATE := meta_d('PARTIAL_DAY');
        n_pdb   NUMBER := meta_n('PDB_CON_DBID');
        v_gflag VARCHAR2(1);
        v_lbl   VARCHAR2(100);
        v_key   VARCHAR2(60);
        v_dev   NUMBER;
        v_thr   NUMBER;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== M10.5 CPU gap handling ===');
        -- The gap day's two snapshots exist but carry no OSSTAT rows, so the
        -- day itself has no CPU row at all -- exactly like a real AWR outage.
        SELECT COUNT(*) INTO v_n FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_gap;
        chk_int('CPU gap day absent from CAPD_CPU_DAILY', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND gap_flag = 'Y';
        chk_int('exactly one gap-flagged CPU day', v_n, 1);

        -- The day AFTER it absorbs the whole outage in ONE 36 h interval.
        SELECT gap_flag, max_interval_hours, day_gap, busy_pct, busy_p95
          INTO v_gflag, v_num, v_num2, v_num3, v_r2
          FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_gnext;
        chk_str  ('CPU post-gap day gap_flag', v_gflag, 'Y');
        chk_close('CPU post-gap day max_interval_hours', v_num,  meta_n('CPUGAP_HOURS'),    0.000001);
        chk_int  ('CPU post-gap day day_gap',            v_num2, meta_n('CPUGAP_DAYGAP'));
        chk_close('CPU post-gap day busy_pct',           v_num3, meta_n('CPUGAP_BUSY_PCT'), 0.000001);
        -- busy_p95 = 60 means the 36 h interval (a 20% three-half-day average)
        -- was left out; including it would give PERCENTILE_CONT(.95) = 58.
        chk_close('CPU post-gap day busy_p95 (long interval excluded)',
                  v_r2, meta_n('CPUGAP_P95'), 0.000001);

        -- A normal day is untouched: 12 h intervals, no flag, consecutive.
        SELECT gap_flag, max_interval_hours, day_gap INTO v_gflag, v_num, v_num2
          FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
        chk_str  ('CPU probe day gap_flag', v_gflag, 'N');
        chk_close('CPU probe day max_interval_hours', v_num, 12, 0.000001);
        chk_int  ('CPU probe day day_gap', v_num2, 1);

        -- The post-gap day deviates by 10 points against a 9-point threshold,
        -- so ONLY the gap guard keeps it unflagged. Assert both halves.
        SELECT anomaly_flag, gap_flag, ABS(dev), threshold
          INTO v_str, v_gflag, v_dev, v_thr
          FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'SAME_DOW' AND ts = d_gnext;
        chk_str ('CPU post-gap day exposes gap_flag', v_gflag, 'Y');
        chk_true('CPU post-gap day WOULD have flagged (|dev| ' || ROUND(v_dev,2)
                 || ' > thr ' || ROUND(v_thr,2) || ')', v_dev > v_thr);
        chk_true('CPU post-gap day anomaly_flag IS NULL (gap guard)', v_str IS NULL);

        -- ...and it is not allowed to poison the next week's baseline either.
        SELECT n_hist INTO v_n FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'SAME_DOW' AND ts = d_gnext + 7;
        chk_true('gap day excluded from next-week same-weekday baseline (n_hist '
                 || v_n || ' < 8)', v_n < 8);
        -- ...but the injected Tuesday's own baseline must be untouched. Both
        -- gap days are a different weekday by construction, so neither can be
        -- one of its dow_weeks priors. (n_hist can still be 7 rather than 8
        -- without the gap having anything to do with it: depending on where
        -- SYSDATE falls, the day-60 restart is sometimes a same-weekday prior
        -- of the injected Tuesday, and that day has no CPU row either.)
        chk_true('gap days are not same-weekday priors of the injected Tuesday',
                 MOD(d_inj - d_gap, 7) <> 0 AND MOD(d_inj - d_gnext, 7) <> 0);
        SELECT n_hist INTO v_n FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'SAME_DOW' AND ts = d_inj;
        chk_true('injected Tuesday n_hist unaffected by the gap (got ' || v_n
                 || ', >= 7)', v_n >= 7);

        DBMS_OUTPUT.PUT_LINE('=== M10.3 level-shift detection (CAPA_CPU_SHIFT) ===');
        SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'shift_days';
        chk_int('knob shift_days', v_num, 7);
        SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'shift_baseline_days';
        chk_int('knob shift_baseline_days', v_num, 28);
        SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'shift_min_pct';
        chk_int('knob shift_min_pct', v_num, 15);
        SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'cpu_gap_hours';
        chk_int('knob cpu_gap_hours', v_num, 12);

        -- One row per (container, metric): root has BUSY_PCT / BUSY_P95 /
        -- DB_CPU_PCT, FIXPDB1 and FIXPDB2 (time-model only) DB_CPU_PCT alone.
        SELECT COUNT(*) INTO v_n FROM capa_cpu_shift WHERE dbid = v_dbid;
        chk_int('CAPA_CPU_SHIFT row count (3 root + 1 per PDB, 2 PDBs)', v_n, 5);

        -- The FIXPDB1 step: +18 points sustained over the last 7 days.
        SELECT shift_flag, shift_pct, recent_med, base_med
          INTO v_str, v_num, v_num2, v_num3
          FROM capa_cpu_shift
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND metric = 'DB_CPU_PCT';
        chk_str  ('PDB DB_CPU_PCT shift_flag', v_str, 'UP');
        chk_close('PDB DB_CPU_PCT shift_pct',  v_num,  meta_n('SHIFT_EXPECTED_PTS'), 0.01);
        chk_close('PDB DB_CPU_PCT recent_med', v_num2, meta_n('SHIFT_RECENT_MED'),   0.01);
        chk_close('PDB DB_CPU_PCT base_med',   v_num3, meta_n('SHIFT_BASE_MED'),     0.01);
        SELECT n_recent, n_base, n_above, base_mad_sigma
          INTO v_n, v_num, v_num2, v_num3
          FROM capa_cpu_shift
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND metric = 'DB_CPU_PCT';
        chk_int  ('PDB shift n_recent (full window)', v_n, 7);
        -- 4 whole baseline days: the fixture's partial day is ~100 days back,
        -- far outside the 7 + 28 day shift windows, so the rule that drops
        -- incomplete days from them is not exercised by a count here.
        chk_int  ('PDB shift n_base', v_num, 28);
        chk_int  ('PDB shift n_above (N-of-M: all 7)', v_num2, 7);
        chk_close('PDB shift base_mad_sigma', v_num3, meta_n('SHIFT_BASE_SIGMA'), 0.0001);

        -- The PDB has no host busy% at all (OSSTAT is CDB-level), so no
        -- BUSY_PCT row; its step days are scored on DB_CPU_PCT instead, where
        -- each is 18 points over its identical same-weekday priors.
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND series = 'BUSY_PCT';
        chk_int('PDB has no BUSY_PCT anomaly rows', v_n, 0);
        chk_int('PDB DB_CPU_PCT SAME_DOW HIGH = the 7 step days',
                anom_n('CPU', 'DB_CPU_PCT', 'SAME_DOW', 'HIGH', n_pdb), 7);
        -- The flat root container must NOT shift (no false positives).
        SELECT COUNT(*) INTO v_n FROM capa_cpu_shift
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND shift_flag IS NOT NULL;
        chk_int('root container raises no level shift', v_n, 0);

        -- Completeness + freshness (CAPA_CPU_SHIFT carries newest_day /
        -- is_current like every CAPF view). Every fixture CPU series ends on
        -- the same day, so all five rows are current.
        SELECT COUNT(*) INTO v_n FROM capa_cpu_shift
          WHERE dbid = v_dbid AND is_current = 'Y' AND newest_day = d_last;
        chk_int('CAPA_CPU_SHIFT: all rows is_current Y, newest_day = last day', v_n, 5);
        SELECT COUNT(*) INTO v_n FROM capa_cpu_shift WHERE dbid = v_dbid AND last_day <> newest_day;
        chk_int('CAPA_CPU_SHIFT: every series ends on the dbid newest day', v_n, 0);
        -- The partial day (is_complete N) feeds neither window.
        SELECT COUNT(*) INTO v_n FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND is_complete = 'N'
            AND gap_flag = 'N' AND day_dt = d_part;
        chk_int('partial day is a non-gap incomplete DB_CPU_PCT day (the case the rule drops)', v_n, 1);
        -- Negative case: stale_days = -1 puts every series behind "newest",
        -- standing in for a PDB whose time model stopped. The shift stays in
        -- CAPA_CPU_SHIFT but reads is_current N, and CAPR_ALERTS drops it (so
        -- ORDS / ELK / CSV and cap_results all stop seeing it). Uncommitted,
        -- then reset.
        BEGIN
            UPDATE cap_config SET cfg_value = -1 WHERE cfg_name = 'stale_days';
            SELECT COUNT(*) INTO v_n FROM capa_cpu_shift
              WHERE dbid = v_dbid AND con_dbid = n_pdb AND metric = 'DB_CPU_PCT'
                AND shift_flag = 'UP' AND is_current = 'N';
            chk_int('stale series: CAPA_CPU_SHIFT is_current N', v_n, 1);
            SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'CPU_SHIFT';
            chk_int('stale series: no CPU_SHIFT alert', v_n, 0);
            SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE is_current = 'N';
            chk_int('stale series: no CAPR_ALERTS row is_current N', v_n, 0);
            UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'stale_days';
        EXCEPTION
            WHEN OTHERS THEN
                UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'stale_days';
                RAISE;
        END;
        SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'CPU_SHIFT' AND is_current = 'Y';
        chk_int('fresh again: CPU_SHIFT alert is_current Y', v_n, 1);

        -- Alert + report view.
        snap_alerts;
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE kind = 'CPU_SHIFT';
        chk_int('exactly one CPU_SHIFT alert', v_n, 1);
        SELECT severity, db_pdb, series_key INTO v_str, v_lbl, v_key
          FROM cap_fixture_alerts_snap WHERE kind = 'CPU_SHIFT';
        chk_str('CPU_SHIFT alert severity (UP -> WARN)', v_str, 'WARN');
        chk_str('CPU_SHIFT alert db_pdb', v_lbl, 'FIXCDB/FIXPDB1');
        chk_str('CPU_SHIFT alert series_key', v_key, 'DB_CPU_PCT');
        SELECT COUNT(*) INTO v_n FROM capr_cpu_shifts;
        chk_int('CAPR_CPU_SHIFTS holds the one flagged row', v_n, 1);
        SELECT sev, rank_shift, db_pdb INTO v_str, v_num, v_lbl
          FROM capr_cpu_shifts;
        chk_str('CAPR_CPU_SHIFTS sev', v_str, 'WARN');
        chk_int('CAPR_CPU_SHIFTS rank_shift', v_num, 1);
        chk_str('CAPR_CPU_SHIFTS resolves db_pdb', v_lbl, 'FIXCDB/FIXPDB1');
    EXCEPTION
        WHEN OTHERS THEN
            fail('M10.3/M10.5 block raised ' || SQLERRM);
    END;

    -- Seam / daily-layer contract: one counter-delta view, coverage columns,
    -- the logical-CPU denominator and CAPV_CONTRACT. Every expectation is a
    -- closed form recorded by fixture_install.sql.
    DECLARE
        d_part  DATE   := meta_d('PARTIAL_DAY');
        d_base  DATE   := meta_d('BASE_DAY');
        d_last  DATE   := meta_d('LAST_DAY');
        d_gap   DATE   := meta_d('CPUGAP_DAY');
        d_gnext DATE   := meta_d('CPUGAP_NEXT');
        n_pdb   NUMBER := meta_n('PDB_CON_DBID');
        n_full  NUMBER := meta_n('FULL_COVERED_SEC');
        n_half  NUMBER := meta_n('PARTIAL_COVERED_SEC');
        n_snaps NUMBER := 2 * (meta_d('LAST_DAY') - meta_d('BASE_DAY') + 1) - 1;
        v_c     VARCHAR2(1);
        v_g     VARCHAR2(1);
        v_a     NUMBER;
        v_b     NUMBER;
        v_cnt0  NUMBER;
        v_ts    DATE;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== logical-CPU denominator (NUM_CPUS 8, NUM_CPU_CORES 4) ===');
        SELECT num_cpus, num_cpu_cores, db_cpu_per_core, db_cpu_pct, host_share_pct
          INTO v_num, v_num2, v_num3, v_a, v_b
          FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
        chk_int  ('DBTIME probe num_cpus (logical)', v_num,  meta_n('NUM_CPUS'));
        chk_int  ('DBTIME probe num_cpu_cores',      v_num2, meta_n('NUM_CPU_CORES'));
        chk_close('DBTIME probe db_cpu_per_core stays on cores (400 s / 4)',
                  v_num3, meta_n('DBCPU_PROBE_PER_CORE'), 0.000001);
        SELECT busy_pct INTO v_num FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
        chk_close('db_cpu_pct = busy_pct * host_share_pct / 100 (same scale as host busy%)',
                  v_a, v_num * v_b / 100, 0.000001);
        SELECT db_cpu_pct INTO v_num FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND day_dt = d_probe;
        chk_close('PDB probe db_cpu_pct (sawtooth level of 8 logical CPUs)',
                  v_num, meta_n('PDB_PROBE_PCT'), 0.000001);
        -- The gap day has no OSSTAT row at all, but FIXPDB1 still has its
        -- time model there: NUM_CPUS comes from the previous snapshot.
        SELECT db_cpu_pct, num_cpus INTO v_num, v_num2 FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND day_dt = d_gap;
        chk_close('PDB gap-day db_cpu_pct (NUM_CPUS carried forward)',
                  v_num, meta_n('PDB_GAP_PCT'), 0.000001);
        chk_int  ('PDB gap-day num_cpus carried forward', v_num2, meta_n('NUM_CPUS'));
        -- No NUM_CPUS at all: the denominator falls back to NUM_CPU_CORES.
        SAVEPOINT u3_ncpu;
        BEGIN
            DELETE FROM cap_fixture_osstat WHERE stat_name = 'NUM_CPUS';
            SELECT db_cpu_pct INTO v_num FROM capd_dbtime_daily
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
            chk_close('db_cpu_pct with NUM_CPUS missing (falls back to 4 cores)',
                      v_num, meta_n('DBCPU_PROBE_PCT_CORES'), 0.000001);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT u3_ncpu; RAISE;
        END;
        ROLLBACK TO SAVEPOINT u3_ncpu;

        DBMS_OUTPUT.PUT_LINE('=== day coverage (covered_sec / is_complete) ===');
        SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'complete_day_pct';
        chk_int('knob complete_day_pct default', v_num, 80);
        -- The partial day: its noon restart drops the 18:00 interval, so only
        -- the 12 h night interval is left. No long interval, so no gap flag.
        SELECT covered_sec, is_complete, gap_flag, max_interval_hours, n_intervals, busy_pct
          INTO v_num, v_c, v_g, v_num2, v_n, v_num3
          FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_part;
        chk_int  ('CPU partial day covered_sec (12 h)', v_num, n_half);
        chk_str  ('CPU partial day is_complete', v_c, 'N');
        chk_str  ('CPU partial day gap_flag stays N', v_g, 'N');
        chk_close('CPU partial day max_interval_hours', v_num2, 12, 0.000001);
        chk_int  ('CPU partial day n_intervals', v_n, 1);
        chk_close('CPU partial day busy_pct (night interval only)',
                  v_num3, meta_n('PARTIAL_BUSY_PCT'), 0.000001);
        -- CAPF_BACKTEST CPU row (root BUSY_PCT): complete days only, anchored at
        -- the median of the last shift_days training days (not the last value).
        -- The partial day sits at i 14..20, inside the backtest training window
        -- (i 3..92), so it must not be fitted: n_train counts complete days only.
        SELECT n_train, anchor_val, cutoff_day INTO v_n, v_num, v_ts
          FROM capf_backtest
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND series_kind = 'CPU'
            AND series_key = 'BUSY_PCT' AND engine = 'REGR';
        SELECT train_days INTO v_cnt0 FROM cap_cfg;
        chk_true('CPU backtest: partial day lies inside the training window',
                 d_part <= v_ts AND d_part > v_ts - v_cnt0);
        SELECT COUNT(*) INTO v_num2 FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND busy_pct IS NOT NULL
            AND is_complete = 'Y' AND day_dt <= v_ts
            AND day_dt > v_ts - v_cnt0;
        chk_int('CPU backtest n_train = complete training days', v_n, v_num2);
        SELECT COUNT(*) INTO v_num2 FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND busy_pct IS NOT NULL
            AND day_dt <= v_ts AND day_dt > v_ts - v_cnt0;
        chk_true('CPU backtest n_train excludes the partial day', v_n < v_num2);
        SELECT shift_days INTO v_cnt0 FROM cap_cfg;
        SELECT MEDIAN(busy_pct) INTO v_num2 FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND busy_pct IS NOT NULL
            AND is_complete = 'Y' AND day_dt <= v_ts
            AND day_dt > v_ts - v_cnt0;
        chk_close('CPU backtest anchor_val = median of the last shift_days training days',
                  v_num, v_num2, 0.000001);
        SELECT covered_sec, is_complete, db_cpu_pct INTO v_num, v_c, v_num2
          FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_part;
        chk_int  ('DBTIME partial day covered_sec', v_num, n_half);
        chk_str  ('DBTIME partial day is_complete', v_c, 'N');
        chk_close('DBTIME partial day db_cpu_pct (over the 12 h covered)',
                  v_num2, meta_n('PARTIAL_DBCPU_PCT'), 0.000001);
        SELECT covered_sec, is_complete, db_cpu_pct INTO v_num, v_c, v_num2
          FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND day_dt = d_part;
        chk_int  ('PDB partial day covered_sec', v_num, n_half);
        chk_str  ('PDB partial day is_complete', v_c, 'N');
        chk_close('PDB partial day db_cpu_pct (level unchanged by coverage)',
                  v_num2, meta_n('PDB_PARTIAL_PCT'), 0.000001);
        SELECT value, covered_sec, is_complete INTO v_num, v_num2, v_c
          FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND day_dt = d_part;
        chk_close('REDO partial day GiB (one 1 GiB interval)', v_num, meta_n('REDO_PARTIAL_GB'), 0.000001);
        chk_int  ('REDO partial day covered_sec', v_num2, n_half);
        chk_str  ('REDO partial day is_complete', v_c, 'N');

        -- A normal day is complete in all three flow views.
        SELECT covered_sec, is_complete INTO v_num, v_c FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
        chk_int('CPU probe day covered_sec', v_num, n_full);
        chk_str('CPU probe day is_complete', v_c, 'Y');
        SELECT covered_sec, is_complete INTO v_num, v_c FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
        chk_int('DBTIME probe day covered_sec', v_num, n_full);
        chk_str('DBTIME probe day is_complete', v_c, 'Y');
        SELECT covered_sec, is_complete INTO v_num, v_c FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND day_dt = d_probe;
        chk_int('REDO probe day covered_sec', v_num, n_full);
        chk_str('REDO probe day is_complete', v_c, 'Y');

        -- The first day of history: its 06:00 snapshot has no predecessor.
        SELECT covered_sec, is_complete INTO v_num, v_c FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_base;
        chk_int('CPU first day covered_sec (series start)', v_num, n_half);
        chk_str('CPU first day is_complete', v_c, 'N');

        -- The post-gap day covers 48 h. It is complete, gap-flagged, and its
        -- db_cpu_pct is the average over those 48 h.
        SELECT covered_sec, is_complete INTO v_num, v_c FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_gnext;
        chk_int('CPU post-gap day covered_sec (36 h + 12 h)', v_num, meta_n('CPUGAP_COVERED_SEC'));
        chk_str('CPU post-gap day is_complete', v_c, 'Y');
        SELECT covered_sec, db_cpu_pct INTO v_num, v_num2 FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_gnext;
        chk_int  ('DBTIME post-gap day covered_sec', v_num, meta_n('CPUGAP_COVERED_SEC'));
        chk_close('DBTIME post-gap day db_cpu_pct (over 48 h covered)',
                  v_num2, meta_n('CPUGAP_DBCPU_PCT'), 0.000001);

        -- Exactly two incomplete days per flow series: the first day and the
        -- partial day (the restart day and the gap day have no row at all).
        SELECT COUNT(*) INTO v_n FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND is_complete = 'N';
        chk_int('CPU incomplete days (first + partial)', v_n, 2);
        SELECT COUNT(*) INTO v_n FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND is_complete = 'N';
        chk_int('DBTIME root incomplete days', v_n, 2);
        SELECT COUNT(*) INTO v_n FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND is_complete = 'N';
        chk_int('DBTIME PDB incomplete days', v_n, 2);
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND is_complete = 'N';
        chk_int('REDO incomplete days', v_n, 2);
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY'
            AND (covered_sec IS NULL
                 OR is_complete <> CASE WHEN covered_sec >= 0.80 * 86400 THEN 'Y' ELSE 'N' END);
        chk_int('REDO is_complete agrees with covered_sec on every row', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE series IN ('PROCESSES','SESSIONS','PGA_ALLOC_GB','DB_SIZE_GB')
            AND (covered_sec IS NOT NULL OR is_complete <> 'Y');
        chk_int('level series carry covered_sec NULL, is_complete Y', v_n, 0);

        DBMS_OUTPUT.PUT_LINE('=== CAPD_COUNTER_DELTA (one LAG + restart rule) ===');
        -- The restart day holds one interval per counter source, and it is
        -- the restart: none survives, which is why the day has no CPU row.
        FOR r IN (SELECT 'OSSTAT' AS src, v_dbid AS con FROM dual
                  UNION ALL SELECT 'TIME_MODEL', v_dbid FROM dual
                  UNION ALL SELECT 'SYSSTAT',    v_dbid FROM dual
                  UNION ALL SELECT 'TIME_MODEL', n_pdb  FROM dual) LOOP
            SELECT COUNT(DISTINCT CASE WHEN is_restart = 'Y' THEN snap_id END),
                   COUNT(DISTINCT CASE WHEN is_restart = 'N' THEN snap_id END)
              INTO v_a, v_b
              FROM capd_counter_delta
              WHERE dbid = v_dbid AND con_dbid = r.con AND source = r.src
                AND TRUNC(end_time) = d_restart;
            chk_int(r.src || ' con ' || r.con || ' restart-day is_restart=Y intervals', v_a, 1);
            chk_int(r.src || ' con ' || r.con || ' restart-day is_restart=N intervals', v_b, 0);
        END LOOP;
        SELECT MAX(ivl_sec) INTO v_num FROM capd_counter_delta
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND source = 'OSSTAT'
            AND TRUNC(end_time) = d_restart;
        chk_int('restart interval spans 24 h (18:00 to 18:00)', v_num, 86400);
        SELECT COUNT(*) INTO v_n FROM capd_cpu_daily
          WHERE dbid = v_dbid AND day_dt = d_restart;
        chk_int('excluding is_restart=Y leaves no CPU row on the restart day', v_n, 0);
        -- Over the whole series: the day-60 restart and the partial day's.
        SELECT COUNT(DISTINCT snap_id) INTO v_n FROM capd_counter_delta
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND source = 'OSSTAT' AND is_restart = 'Y';
        chk_int('OSSTAT restart intervals in the series', v_n, 2);

        -- NULL startup_time (the seam does not require it): the series must
        -- survive, with restarts still caught by their negative deltas.
        SELECT COUNT(*) INTO v_cnt0 FROM capd_cpu_daily WHERE dbid = v_dbid;
        SAVEPOINT u3_nullstart;
        BEGIN
            UPDATE cap_fixture_snapshot SET startup_time = NULL;
            SELECT COUNT(*) INTO v_n FROM capd_cpu_daily WHERE dbid = v_dbid;
            chk_int('CPU rows with startup_time NULL = rows with it set', v_n, v_cnt0);
            SELECT COUNT(DISTINCT snap_id) INTO v_n FROM capd_counter_delta
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND source = 'OSSTAT' AND is_restart = 'Y';
            chk_int('restarts found by negative delta with startup_time NULL', v_n, 2);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT u3_nullstart; RAISE;
        END;
        ROLLBACK TO SAVEPOINT u3_nullstart;

        DBMS_OUTPUT.PUT_LINE('=== CAPV_CONTRACT ===');
        SELECT COUNT(*) INTO v_n FROM capv_contract;
        chk_int('CAPV_CONTRACT one row per seam source', v_n, 20);
        SELECT COUNT(*) INTO v_n FROM capv_contract
          WHERE (source_name IN ('TBSPC_USAGE','TIME_MODEL','SYSSTAT','SEG_STAT') AND per_container_expected = 'Y')
             OR (source_name IN ('OSSTAT','RESOURCE_LIMIT','SNAPSHOT',
                                 'PARAMETER','ASM_DISKGROUP','PGASTAT',
                                 'MEM_COMP','WORKAREA_HSTGRM','PGA_ADVICE','SGA_ADVICE',
                                 'CACHE_ADVICE','SHPOOL_ADVICE','SGASTAT','LIBRARYCACHE',
                                 'ROWCACHE','SYSTEM_EVENT')      AND per_container_expected = 'N');
        chk_int('CAPV_CONTRACT per_container_expected as specified', v_n, 20);
        -- M26 memory sources: fixture_install.sql fills all ten.
        SELECT COUNT(*), NVL(SUM(n_rows), 0) INTO v_n, v_num
          FROM capv_contract
         WHERE source_name IN ('MEM_COMP','WORKAREA_HSTGRM','PGA_ADVICE','SGA_ADVICE',
                               'CACHE_ADVICE','SHPOOL_ADVICE','SGASTAT','LIBRARYCACHE',
                               'ROWCACHE','SYSTEM_EVENT');
        chk_int('CAPV_CONTRACT memory sources listed', v_n, 10);
        chk_int('CAPV_CONTRACT memory sources n_rows (59 a snapshot + the free buffer waits rows)',
                v_num, meta_n('MEM_SRC_ROWS'));
        -- SEG_STAT: 4 segments on every 18:00 snapshot (121 days), root only.
        SELECT n_rows, n_con_dbid INTO v_num, v_num2
          FROM capv_contract WHERE source_name = 'SEG_STAT';
        chk_int('CAPV_CONTRACT SEG_STAT n_rows', v_num, 4 * (d_last - d_base + 1));
        chk_int('CAPV_CONTRACT SEG_STAT n_con_dbid', v_num2, 1);
        -- PARAMETER: 9 names on every snapshot. ASM_DISKGROUP: 2 groups.
        SELECT n_rows, n_con_dbid INTO v_num, v_num2
          FROM capv_contract WHERE source_name = 'PARAMETER';
        chk_int('CAPV_CONTRACT PARAMETER n_rows', v_num, 9 * n_snaps);
        chk_int('CAPV_CONTRACT PARAMETER n_con_dbid (instance level)', v_num2, 1);
        SELECT n_rows, n_con_dbid INTO v_num, v_num2
          FROM capv_contract WHERE source_name = 'ASM_DISKGROUP';
        chk_int('CAPV_CONTRACT ASM_DISKGROUP n_rows', v_num, 2 * n_snaps);
        chk_int('CAPV_CONTRACT ASM_DISKGROUP n_con_dbid (host level)', v_num2, 1);
        -- 121 days x 2 snapshots, minus the restart day's missing 06:00.
        SELECT n_rows, max_snap_id, CAST(max_end_time AS DATE) INTO v_num, v_num2, v_ts
          FROM capv_contract WHERE source_name = 'SNAPSHOT';
        chk_int('CAPV_CONTRACT SNAPSHOT n_rows', v_num, n_snaps);
        chk_int('CAPV_CONTRACT SNAPSHOT max_snap_id', v_num2, 2001 + 2 * (d_last - d_base));
        chk_true('CAPV_CONTRACT SNAPSHOT max_end_time = last day 18:00',
                 v_ts = d_last + 18/24);
        -- OSSTAT: 5 names (the 4 CPU ones and M26's PHYSICAL_MEMORY_BYTES)
        -- on every snapshot but the two of the gap day.
        SELECT n_rows, n_con_dbid INTO v_num, v_num2
          FROM capv_contract WHERE source_name = 'OSSTAT';
        chk_int('CAPV_CONTRACT OSSTAT n_rows', v_num, 5 * (n_snaps - 2));
        chk_int('CAPV_CONTRACT OSSTAT n_con_dbid (host level)', v_num2, 1);
        -- TIME_MODEL: 3 names, root on the OSSTAT snapshots, FIXPDB1 and
        -- FIXPDB2 on all.
        SELECT n_rows, n_con_dbid INTO v_num, v_num2
          FROM capv_contract WHERE source_name = 'TIME_MODEL';
        chk_int('CAPV_CONTRACT TIME_MODEL n_rows', v_num, 3 * (n_snaps - 2) + 2 * 3 * n_snaps);
        chk_int('CAPV_CONTRACT TIME_MODEL n_con_dbid (root + FIXPDB1 + FIXPDB2)', v_num2, 3);
    EXCEPTION
        WHEN OTHERS THEN
            fail('seam/daily contract block raised ' || SQLERRM);
    END;

    -- M24.11: CLIENT_INFO 'AWRCAP dbid=<n>' (report/scope.sql) cuts every
    -- seam read to that dbid, so a scoped report computes nothing else.
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== CAP_SCOPE (M24.11) ===');
        SELECT SUM(n_rows) INTO v_num FROM capv_contract;
        DBMS_APPLICATION_INFO.SET_CLIENT_INFO('AWRCAP dbid=' || v_dbid);
        SELECT scope_dbid INTO v_num2 FROM cap_scope;
        chk_int('CAP_SCOPE reads the dbid of CLIENT_INFO', v_num2, v_dbid);
        SELECT SUM(n_rows) INTO v_n FROM capv_contract;
        chk_int('scoped to the fixture dbid: every seam row stays', v_n, v_num);
        DBMS_APPLICATION_INFO.SET_CLIENT_INFO('AWRCAP dbid=-1');
        SELECT SUM(n_rows) INTO v_n FROM capv_contract;
        chk_int('scoped to dbid -1: no seam source returns a row', v_n, 0);
        SELECT (SELECT COUNT(*) FROM capv_container) + (SELECT COUNT(*) FROM capv_target)
          INTO v_n FROM dual;
        chk_int('scoped to dbid -1: no container, no target', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_fit;
        chk_int('scoped to dbid -1: CAPR_FIT has no row', v_n, 0);
        DBMS_APPLICATION_INFO.SET_CLIENT_INFO('another tool''s label');
        SELECT scope_dbid INTO v_num2 FROM cap_scope;
        chk_true('any other CLIENT_INFO is no scope', v_num2 IS NULL);
        DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL);
        SELECT SUM(n_rows) INTO v_n FROM capv_contract;
        chk_int('unscoped again: every seam row is back', v_n, v_num);
        -- The plan of every CAPV view: each fixture-table read carries the
        -- CAP_SCOPE lookup (test/scope_plan.sql does this for every view).
        DELETE FROM plan_table WHERE statement_id = 'CAPSCOPE';
        -- ALL_OBJECTS, not ALL_VIEWS: ALL_VIEWS WHERE owner = SYS_CONTEXT(...)
        -- returns no row as SYSDBA under CURRENT_SCHEMA in a PDB (19.27).
        FOR w IN (SELECT object_name FROM all_objects
                  WHERE  owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
                    AND  object_type = 'VIEW'
                    AND  object_name LIKE 'CAPV\_%' ESCAPE '\') LOOP
            EXECUTE IMMEDIATE 'EXPLAIN PLAN SET STATEMENT_ID = ''CAPSCOPE'' FOR SELECT * FROM '
                              || w.object_name;
        END LOOP;
        SELECT COUNT(*),
               COUNT(CASE WHEN NVL(access_predicates, ' ') || NVL(filter_predicates, ' ')
                               NOT LIKE '%CLIENT_INFO%' THEN 1 END)
          INTO v_n, v_num
          FROM plan_table
         WHERE statement_id = 'CAPSCOPE'
           AND object_name LIKE 'CAP\_FIXTURE\_%' ESCAPE '\';
        DELETE FROM plan_table WHERE statement_id = 'CAPSCOPE';
        chk_true('the CAPV plans read the fixture tables', v_n > 0);
        chk_int('every seam read carries the CAP_SCOPE filter', v_num, 0);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL);
            fail('CAP_SCOPE block raised ' || SQLERRM);
    END;

    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== CAPR point feeds (grafana/API.md, elk/) ===');
        SELECT COUNT(*) INTO v_n   FROM capr_series_points WHERE kind = 'TBSPC';
        SELECT COUNT(*) INTO v_num FROM capd_tbspc_daily;
        chk_int('CAPR_SERIES_POINTS TBSPC rows = CAPD_TBSPC_DAILY', v_n, v_num);
        SELECT COUNT(*) INTO v_n   FROM capr_series_points WHERE kind = 'SERIES';
        SELECT COUNT(*) INTO v_num FROM capd_series_daily;
        chk_int('CAPR_SERIES_POINTS SERIES rows = CAPD_SERIES_DAILY', v_n, v_num);
        SELECT COUNT(*) INTO v_n   FROM capr_series_points WHERE kind = 'CPU' AND series = 'BUSY_PCT';
        SELECT COUNT(*) INTO v_num FROM capd_cpu_daily WHERE busy_pct IS NOT NULL;
        chk_int('CAPR_SERIES_POINTS BUSY_PCT rows = CAPD_CPU_DAILY', v_n, v_num);
        SELECT COUNT(*) INTO v_n   FROM capr_series_points WHERE kind = 'CPU' AND series = 'DB_CPU_PCT';
        SELECT COUNT(*) INTO v_num FROM capd_dbtime_daily WHERE db_cpu_pct IS NOT NULL;
        chk_int('CAPR_SERIES_POINTS DB_CPU_PCT rows = CAPD_DBTIME_DAILY', v_n, v_num);
        SELECT COUNT(*) INTO v_n   FROM capr_series_points WHERE kind = 'TBSPC' AND anomaly = 1;
        SELECT COUNT(*) INTO v_num FROM capa_anom_day WHERE kind = 'TBSPC' AND anomaly = 1;
        chk_int('CAPR_SERIES_POINTS anomaly=1 on every TBSPC day any day mode flagged', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM capr_series_points
          WHERE kind = 'CPU' AND series NOT IN ('BUSY_PCT', 'DB_CPU_PCT') AND anomaly IS NOT NULL;
        chk_int('CPU anomaly is scored on BUSY_PCT and DB_CPU_PCT only', v_n, 0);

        SELECT COUNT(*) INTO v_n FROM capr_fit;
        SELECT (SELECT COUNT(*) FROM capf_tbspc_forecast) + (SELECT COUNT(*) FROM capf_cpu_trend)
               + (SELECT COUNT(*) FROM capf_series_forecast) INTO v_num FROM dual;
        chk_int('CAPR_FIT one row per fitted series', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM capr_fit f JOIN capr_series r
            ON r.dbid = f.dbid AND r.con_dbid = f.con_dbid AND r.series = f.series
          WHERE f.kind = 'SERIES' AND f.sev <> NVL(UPPER(r.sev), 'OK');
        chk_int('CAPR_FIT SERIES sev matches CAPR_SERIES', v_n, 0);

        SELECT COUNT(*) INTO v_n FROM capr_forecast_points p JOIN capf_tbspc_forecast t
            ON t.dbid = p.dbid AND t.con_dbid = p.con_dbid AND t.tablespace_name = p.series
          WHERE p.kind = 'TBSPC' AND p.method = 'REGR' AND p.ts <> t.last_day + p.horizon_days;
        chk_int('CAPR_FORECAST_POINTS ts = last_day + horizon', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_forecast_points
          WHERE method = 'REGR' AND horizon_days = 0 AND quality = 'INSUFFICIENT_HISTORY';
        chk_int('CAPR_FORECAST_POINTS skips INSUFFICIENT_HISTORY', v_n, 0);

        SELECT COUNT(*) INTO v_n   FROM capr_anomalies WHERE anomaly_kind = 'TBSPC_GROWTH';
        SELECT COUNT(*) INTO v_num FROM capa_anom WHERE kind = 'TBSPC' AND anomaly_flag IS NOT NULL;
        chk_int('CAPR_ANOMALIES one TBSPC_GROWTH row per flagged (day, mode)', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM capr_anomalies a JOIN capa_cpu_shift s
            ON s.dbid = a.dbid AND s.con_dbid = a.con_dbid AND s.metric = a.series
          WHERE a.anomaly_kind = 'CPU_SHIFT'
            AND a.ts = s.last_day - s.recent_days + 1 AND a.obs_day = s.last_day
            AND a.sev = 'WARN' AND a.db = 'FIXCDB/FIXPDB1';
        chk_int('CPU_SHIFT dated at the start of its recent window, obs_day = last_day', v_n, 1);
        SELECT pct_vs_expected, pct_vs_avg INTO v_num, v_num2
          FROM capr_anomalies
          WHERE anomaly_kind = 'TBSPC_GROWTH' AND series = 'FIX_SPIKE' AND obs_day = d_spike
            AND baseline_mode = 'TRAILING';
        chk_close('CAPR_ANOMALIES SPIKE pct_vs_expected', v_num,  100 * 2147483648 / meta_n('SPIKE_RATE'), 0.000001);
        chk_close('CAPR_ANOMALIES SPIKE pct_vs_avg',      v_num2, 100 * 2147483648 / meta_n('SPIKE_RATE'), 0.000001);
        SELECT a.pct_vs_expected, 100 * s.shift_pct / s.base_med INTO v_num, v_num2
          FROM capr_anomalies a JOIN capa_cpu_shift s
            ON s.dbid = a.dbid AND s.con_dbid = a.con_dbid AND s.metric = a.series
          WHERE a.anomaly_kind = 'CPU_SHIFT';
        chk_close('CAPR_ANOMALIES CPU_SHIFT pct_vs_expected = 100*shift_pct/base_med', v_num, v_num2, 0.000001);
    EXCEPTION
        WHEN OTHERS THEN
            fail('CAPR point-feed block raised ' || SQLERRM);
    END;

    DECLARE
        d_base  DATE   := meta_d('BASE_DAY');
        d_last  DATE   := meta_d('LAST_DAY');
        d_inv   DATE   := meta_d('INVERTED_WED');
        d_gnext DATE   := meta_d('CPUGAP_NEXT');
        d_purge DATE   := meta_d('PURGE_DAY');
        n_pdb   NUMBER := meta_n('PDB_CON_DBID');
        n_pdb2  NUMBER := meta_n('PDB2_CON_DBID');
        n_k     NUMBER;
        v_old   NUMBER;
        v_flag  VARCHAR2(5);
        v_gflag VARCHAR2(1);
        v_mode  VARCHAR2(12);
        v_dt0   DATE;
        -- The HOW Tuesday and Wednesday are consecutive days (one episode)
        -- unless the run day is a Tuesday: then the latest Tuesday is the
        -- last day and the latest Wednesday lies 6 days before it.
        v_adj   BOOLEAN := meta_d('INVERTED_WED') = meta_d('INJECTED_TUE') + 1;
    BEGIN
        SELECT mad_k INTO n_k FROM cap_cfg;

        DBMS_OUTPUT.PUT_LINE('=== M15 CAPD_CPU_HOURLY (END-hour buckets) ===');
        SELECT COUNT(*) INTO v_n FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT';
        SELECT SUM(n_intervals) INTO v_num FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid;
        chk_int('root BUSY_PCT hourly rows = SUM(n_intervals) of CAPD_CPU_DAILY', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT' AND gap_flag = 'Y';
        chk_int('root BUSY_PCT hourly gap rows', v_n, 1);
        SELECT gap_flag, ivl_hours, value INTO v_gflag, v_num, v_num2 FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT' AND hour_ts = d_gnext + 6/24;
        chk_str  ('post-gap Monday 06:00 bucket gap_flag', v_gflag, 'Y');
        chk_close('post-gap Monday 06:00 bucket ivl_hours', v_num, meta_n('CPUGAP_HOURS'), 0.000001);
        chk_close('post-gap Monday 06:00 bucket value (three half-days 10/30/20)', v_num2, 20, 0.000001);
        SELECT COUNT(*) INTO v_n FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND metric = 'DB_CPU_PCT';
        SELECT SUM(n_intervals) INTO v_num FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = n_pdb;
        chk_int('PDB DB_CPU_PCT hourly rows = SUM(n_intervals) of CAPD_DBTIME_DAILY', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND metric = 'BUSY_PCT';
        chk_int('PDB has no hourly BUSY_PCT (OSSTAT is CDB-level)', v_n, 0);
        SELECT value INTO v_num FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT' AND hour_ts = d_probe + 6/24;
        chk_close('probe 06:00 BUSY_PCT (night interval)', v_num, 20, 0.000001);
        SELECT value, day_dt INTO v_num, d_tstart FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT' AND hour_ts = d_probe + 18/24;
        chk_close('probe 18:00 BUSY_PCT (day interval)', v_num, 60, 0.000001);
        chk_true ('probe 18:00 bucket day_dt = probe day', d_tstart = d_probe);
        SELECT value INTO v_num FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'DB_CPU_PCT' AND hour_ts = d_probe + 6/24;
        chk_close('probe 06:00 root DB_CPU_PCT = 100*100/(NUM_CPUS*43200)', v_num,
                  100 * 100 / (meta_n('NUM_CPUS') * 43200), 0.000001);
        SELECT value INTO v_num FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'DB_CPU_PCT' AND hour_ts = d_probe + 18/24;
        chk_close('probe 18:00 root DB_CPU_PCT', v_num, meta_n('DBCPU_PROBE_PEAK_PCT'), 0.000001);
        SELECT MIN(value), MAX(value) INTO v_num, v_num2 FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND metric = 'DB_CPU_PCT'
            AND hour_ts IN (d_probe + 6/24, d_probe + 18/24);
        chk_close('probe PDB DB_CPU_PCT 06:00 = pdb_pct(probe)', v_num,  meta_n('PDB_PROBE_PCT'), 0.000001);
        chk_close('probe PDB DB_CPU_PCT 18:00 = pdb_pct(probe)', v_num2, meta_n('PDB_PROBE_PCT'), 0.000001);

        DBMS_OUTPUT.PUT_LINE('=== M15 CAPA_ANOM structure ===');
        SELECT COUNT(*) INTO v_n FROM capa_anom;
        SELECT 2 * COUNT(CASE WHEN grain = 'DAY' THEN 1 END) + COUNT(CASE WHEN grain = 'HOUR' THEN 1 END)
          INTO v_num FROM capa_obs;
        chk_int('CAPA_ANOM rows = 2 x DAY obs + HOUR obs', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM (
            SELECT 1 FROM capa_anom
            GROUP  BY dbid, con_dbid, kind, series, baseline_mode, ts HAVING COUNT(*) > 1);
        chk_int('CAPA_ANOM key (dbid, con_dbid, kind, series, baseline_mode, ts) unique', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capa_anom_day;
        SELECT COUNT(*) INTO v_num FROM capa_obs WHERE grain = 'DAY';
        chk_int('CAPA_ANOM_DAY one row per DAY observation', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE (grain = 'HOUR' AND baseline_mode <> 'HOUR_OF_WEEK')
             OR (grain = 'DAY'  AND baseline_mode = 'HOUR_OF_WEEK')
             OR (kind <> 'CPU'  AND grain = 'HOUR');
        chk_int('modes match grain (HOUR_OF_WEEK = CPU hour rows only)', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE anomaly_flag IS NOT NULL
            AND (ABS(robust_z) <= n_k OR gap_flag = 'Y' OR is_complete = 'N' OR n_hist < min_hist);
        chk_int('flag => |z| > mad_k, no gap, complete, n_hist >= min_hist', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE anomaly_flag IS NULL
            AND ABS(robust_z) > n_k AND gap_flag = 'N' AND is_complete = 'Y' AND n_hist >= min_hist;
        chk_int('|z| > mad_k, no gap, complete, n_hist >= min_hist => flag', v_n, 0);
        -- The partial day (and the first day) read low on a part-day: scored
        -- as an anomaly they would be instrumentation, not workload.
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE is_complete = 'N' AND anomaly_flag IS NOT NULL;
        chk_int('is_complete = N rows never flag', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM (
            SELECT doc_key FROM capr_series_points GROUP BY doc_key HAVING COUNT(*) > 1);
        chk_int('CAPR_SERIES_POINTS doc_key unique', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM (
            SELECT doc_key FROM capr_hourly_points GROUP BY doc_key HAVING COUNT(*) > 1);
        chk_int('CAPR_HOURLY_POINTS doc_key unique', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM (
            SELECT doc_key FROM capr_anomalies GROUP BY doc_key HAVING COUNT(*) > 1);
        chk_int('CAPR_ANOMALIES doc_key unique', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM (
            SELECT alert_key FROM capr_alerts GROUP BY alert_key HAVING COUNT(*) > 1);
        chk_int('CAPR_ALERTS alert_key unique', v_n, 0);
        SELECT COUNT(*) INTO v_n   FROM capr_hourly_points;
        SELECT COUNT(*) INTO v_num FROM capd_cpu_hourly;
        chk_int('CAPR_HOURLY_POINTS rows = CAPD_CPU_HOURLY', v_n, v_num);

        DBMS_OUTPUT.PUT_LINE('=== M15 root BUSY_PCT across the three modes ===');
        chk_int('SAME_DOW HIGH count', anom_n('CPU', 'BUSY_PCT', 'SAME_DOW', 'HIGH', v_dbid), 1);
        chk_int('SAME_DOW LOW count',  anom_n('CPU', 'BUSY_PCT', 'SAME_DOW', 'LOW',  v_dbid), 0);
        chk_int('TRAILING HIGH count', anom_n('CPU', 'BUSY_PCT', 'TRAILING', 'HIGH', v_dbid), 1);
        chk_str('TRAILING flags the injected Tuesday', anom_flag('CPU', 'BUSY_PCT', 'TRAILING', d_inj, v_dbid), 'HIGH');
        -- A weekend day reads 20 against a weekday-dominated 28-day median of
        -- 40 (MAD 0, floored threshold 9), so TRAILING flags EVERY complete,
        -- non-gap weekend day that has trailing_min_hist such days of history
        -- -- the reason CPU alerts default to SAME_DOW.
        SELECT COUNT(*) INTO v_num
          FROM capd_cpu_daily c CROSS JOIN cap_cfg cfg
          WHERE c.dbid = v_dbid AND c.con_dbid = v_dbid AND c.gap_flag = 'N' AND c.is_complete = 'Y'
            AND MOD(c.day_dt - DATE '2020-01-06', 7) >= 5
            AND (SELECT COUNT(*) FROM capd_cpu_daily h
                  WHERE h.dbid = c.dbid AND h.con_dbid = c.con_dbid
                    AND h.gap_flag = 'N' AND h.is_complete = 'Y'
                    AND h.day_dt BETWEEN c.day_dt - cfg.mad_window_days AND c.day_dt - 1)
                >= cfg.trailing_min_hist;
        chk_int('TRAILING LOW = every weekend day with enough history',
                anom_n('CPU', 'BUSY_PCT', 'TRAILING', 'LOW', v_dbid), v_num);
        chk_int('HOUR_OF_WEEK HIGH count', anom_n('CPU', 'BUSY_PCT', 'HOUR_OF_WEEK', 'HIGH', v_dbid), 2);
        chk_int('HOUR_OF_WEEK LOW count',  anom_n('CPU', 'BUSY_PCT', 'HOUR_OF_WEEK', 'LOW',  v_dbid), 1);
        SELECT anomaly_flag, robust_z, threshold INTO v_flag, v_num, v_num2 FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'HOUR_OF_WEEK' AND ts = d_inj + 6/24;
        chk_str  ('HOW injected Tuesday 06:00 (70 vs 20)', v_flag, 'HIGH');
        chk_close('HOW injected Tuesday 06:00 z = 50/5', v_num, 10, 0.000001);
        chk_close('HOW threshold = mad_k x cpu_min_mad_pct_hour', v_num2, 15, 0.000001);
        SELECT anomaly_flag, dev, threshold INTO v_flag, v_num, v_num2 FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'HOUR_OF_WEEK' AND ts = d_inj + 18/24;
        chk_true ('HOW injected Tuesday 18:00 not flagged (70 vs 60)', v_flag IS NULL);
        chk_true ('HOW injected Tuesday 18:00 dev 10 < threshold 15 (got ' || v_num || ' / ' || v_num2 || ')',
                  ABS(v_num - 10) < 1e-9 AND ABS(v_num2 - 15) < 1e-9);
        SELECT anomaly_flag, robust_z INTO v_flag, v_num FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'HOUR_OF_WEEK' AND ts = d_inv + 6/24;
        chk_str  ('HOW inverted Wednesday 06:00 (40 vs 20)', v_flag, 'HIGH');
        chk_close('HOW inverted Wednesday 06:00 z = 20/5', v_num, 4, 0.000001);
        chk_str  ('HOW inverted Wednesday 18:00 (40 vs 60)',
                  anom_flag('CPU', 'BUSY_PCT', 'HOUR_OF_WEEK', d_inv + 18/24, v_dbid), 'LOW');
        chk_true ('inverted Wednesday invisible to TRAILING (daily avg 40)',
                  anom_flag('CPU', 'BUSY_PCT', 'TRAILING', d_inv, v_dbid) IS NULL);
        chk_true ('inverted Wednesday invisible to SAME_DOW (daily avg 40)',
                  anom_flag('CPU', 'BUSY_PCT', 'SAME_DOW', d_inv, v_dbid) IS NULL);
        SELECT anomaly_flag, gap_flag INTO v_flag, v_gflag FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'HOUR_OF_WEEK' AND ts = d_gnext + 6/24;
        chk_true ('HOW post-gap Monday 06:00 is a gap and unflagged', v_gflag = 'Y' AND v_flag IS NULL);
        SELECT n_hist INTO v_n FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'HOUR_OF_WEEK' AND ts = d_gnext + 7 + 6/24;
        chk_true ('HOW gap hour excluded from next Monday 06:00 baseline (n_hist '
                  || v_n || ' < 8)', v_n < 8);
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND series = 'DB_CPU_PCT' AND anomaly_flag IS NOT NULL;
        chk_int('root DB_CPU_PCT never flags (values far under the 9 / 15 floors)', v_n, 0);

        DBMS_OUTPUT.PUT_LINE('=== M15 FIXPDB1 DB_CPU_PCT step days ===');
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND series = 'DB_CPU_PCT'
            AND baseline_mode = 'SAME_DOW' AND anomaly_flag = 'HIGH' AND ts >= d_last - 6;
        chk_int('SAME_DOW HIGH exactly on the last 7 (step) days', v_n, 7);
        SELECT sigma_floored, threshold, robust_z INTO v_gflag, v_num, v_num2 FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND kind = 'CPU' AND series = 'DB_CPU_PCT'
            AND baseline_mode = 'SAME_DOW' AND ts = d_inj;
        chk_str  ('SAME_DOW step day sigma_floored (identical priors, MAD 0)', v_gflag, 'Y');
        chk_close('SAME_DOW step day threshold = mad_k x cpu_min_mad_pct', v_num, 9, 0.000001);
        chk_close('SAME_DOW step day z = 18/3', v_num2, 6, 0.000001);
        chk_int('HOUR_OF_WEEK HIGH = both hours of the 7 step days',
                anom_n('CPU', 'DB_CPU_PCT', 'HOUR_OF_WEEK', 'HIGH', n_pdb), 14);
        -- TRAILING mixes the sawtooth into its window (sigma 5.93 -> 7.41), so
        -- only the step days whose deviation clears 3 sigma flag: index 115
        -- (58 vs 40, thr 17.79), 116 (60 vs 41) and 118 (64 vs 41, thr 22.24).
        SELECT COUNT(*), COUNT(CASE WHEN ts - d_base IN (115, 116, 118) THEN 1 END)
          INTO v_n, v_num FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND series = 'DB_CPU_PCT'
            AND baseline_mode = 'TRAILING' AND anomaly_flag = 'HIGH';
        chk_int('TRAILING HIGH count', v_n, 3);
        chk_int('TRAILING HIGH on day indexes 115, 116, 118', v_num, 3);

        DBMS_OUTPUT.PUT_LINE('=== M15 FIXPDB2 DB_CPU_PCT (weekday 60 / weekend 20 + 1/12 pt a day) ===');
        -- Weekly seasonality with a slow ramp: TRAILING (all weekdays mixed)
        -- reads every weekend as LOW, exactly like root BUSY_PCT; the weekly
        -- modes compare a slot with itself 1..8 weeks back, so each sees only
        -- the ramp, 7/12 point a week, far under the 9 / 15 point floors.
        SELECT COUNT(*) INTO v_num
          FROM capd_dbtime_daily c CROSS JOIN cap_cfg cfg
          WHERE c.dbid = v_dbid AND c.con_dbid = n_pdb2 AND c.gap_flag = 'N' AND c.is_complete = 'Y'
            AND MOD(c.day_dt - DATE '2020-01-06', 7) >= 5
            AND (SELECT COUNT(*) FROM capd_dbtime_daily h
                  WHERE h.dbid = c.dbid AND h.con_dbid = c.con_dbid
                    AND h.gap_flag = 'N' AND h.is_complete = 'Y'
                    AND h.day_dt BETWEEN c.day_dt - cfg.mad_window_days AND c.day_dt - 1)
                >= cfg.trailing_min_hist;
        chk_int('PDB2 TRAILING LOW = every weekend day with enough history',
                anom_n('CPU', 'DB_CPU_PCT', 'TRAILING', 'LOW', n_pdb2), v_num);
        chk_true('PDB2 TRAILING LOW count is the weekend set (' || v_num || ' > 20)', v_num > 20);
        chk_int('PDB2 TRAILING HIGH',     anom_n('CPU', 'DB_CPU_PCT', 'TRAILING',     'HIGH', n_pdb2), 0);
        chk_int('PDB2 SAME_DOW flags',    anom_n('CPU', 'DB_CPU_PCT', 'SAME_DOW',     'ANY',  n_pdb2), 0);
        chk_int('PDB2 HOUR_OF_WEEK flags', anom_n('CPU', 'DB_CPU_PCT', 'HOUR_OF_WEEK', 'ANY', n_pdb2), 0);
        -- Last day: its 8 same-weekday priors sit 7k/12 points lower (k = 1..8),
        -- so the median is value - (7/12) * 4.5 and the MAD sigma
        -- 1.4826 * 7/12 * 1.5 = 1.30 is floored to cpu_min_mad_pct.
        SELECT dev, n_hist, sigma_floored, threshold INTO v_num, v_n, v_gflag, v_num2 FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = n_pdb2 AND kind = 'CPU' AND series = 'DB_CPU_PCT'
            AND baseline_mode = 'SAME_DOW' AND ts = d_last;
        chk_close('PDB2 last-day SAME_DOW dev = (7/12) x 4.5', v_num, 7 / 12 * 4.5, 0.000001);
        chk_int  ('PDB2 last-day SAME_DOW n_hist', v_n, 8);
        chk_str  ('PDB2 last-day SAME_DOW sigma_floored', v_gflag, 'Y');
        chk_close('PDB2 last-day SAME_DOW threshold', v_num2, 9, 0.000001);

        DBMS_OUTPUT.PUT_LINE('=== M15 tablespaces and M11 series under SAME_DOW ===');
        chk_str('SPIKE SAME_DOW HIGH on the spike day', anom_flag('TBSPC', 'FIX_SPIKE', 'SAME_DOW', d_spike, v_dbid), 'HIGH');
        chk_str('PURGE SAME_DOW LOW on the purge day', anom_flag('TBSPC', 'FIX_PURGE', 'SAME_DOW', d_purge, v_dbid), 'LOW');
        -- FIX_CYCLIC / FIX_CYCLIC_UP: every retention cliff (CYC0_DAYS apart,
        -- the last on CYC0_LAST_CLIFF) is a -72 GiB day against +2.5 GiB/day
        -- priors, so both modes flag it LOW; the rising days never flag. The
        -- first cliff (day 5) has too little history for either mode.
        FOR t IN (SELECT 'FIX_CYCLIC' AS ts_name FROM dual UNION ALL SELECT 'FIX_CYCLIC_UP' FROM dual) LOOP
            FOR m IN (SELECT 'TRAILING' AS md FROM dual UNION ALL SELECT 'SAME_DOW' FROM dual) LOOP
                SELECT COUNT(*),
                       COUNT(CASE WHEN anomaly_flag = 'LOW'
                                   AND MOD(meta_last_cliff - (ts - d_base), meta_cyc_days) = 0 THEN 1 END)
                  INTO v_n, v_num
                  FROM capa_anom
                       CROSS JOIN (SELECT MAX(CASE WHEN mkey = 'CYC0_LAST_CLIFF' THEN nval END) AS meta_last_cliff,
                                          MAX(CASE WHEN mkey = 'CYC0_DAYS'       THEN nval END) AS meta_cyc_days
                                   FROM   cap_fixture_meta)
                  WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'TBSPC'
                    AND series = t.ts_name AND baseline_mode = m.md AND anomaly_flag IS NOT NULL;
                chk_int(t.ts_name || ' ' || m.md || ' flags', v_n, meta_n('CYC0_N'));
                chk_int(t.ts_name || ' ' || m.md || ' LOW on the retention cliffs', v_num, meta_n('CYC0_N'));
            END LOOP;
        END LOOP;
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE kind = 'TBSPC' AND baseline_mode = 'SAME_DOW' AND anomaly_flag IS NOT NULL
            AND series NOT IN ('FIX_CYCLIC', 'FIX_CYCLIC_UP');
        chk_int('other TBSPC SAME_DOW flags: the spike, the purge, FIX_PURGE2''s two cliff days and the FIX_GAP burst days',
                v_n, 2 + 2 + meta_n('BURST_DAYS'));
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE kind = 'SERIES' AND series IN ('SESSIONS', 'PROCESSES', 'REDO_GB_DAY')
            AND anomaly_flag IS NOT NULL;
        chk_int('SESSIONS / PROCESSES / REDO_GB_DAY never flag', v_n, 0);
        FOR m IN (SELECT 'TRAILING' AS md FROM dual UNION ALL SELECT 'SAME_DOW' FROM dual) LOOP
            chk_str('DB_SIZE_GB ' || m.md || ' HIGH on the spike day',
                    anom_flag('SERIES', 'DB_SIZE_GB', m.md, d_spike, v_dbid), 'HIGH');
            chk_str('DB_SIZE_GB ' || m.md || ' LOW on the purge day',
                    anom_flag('SERIES', 'DB_SIZE_GB', m.md, d_purge, v_dbid), 'LOW');
            chk_int('DB_SIZE_GB ' || m.md || ' flags nothing else (spike, purge, the CYC0_N cliffs)',
                    anom_n('SERIES', 'DB_SIZE_GB', m.md, 'ANY', v_dbid), 2 + meta_n('CYC0_N'));
        END LOOP;
        -- The tablespace SET changes three times: FIX_DROPPED leaves the day
        -- after its last row, FIX_GAP leaves on day 100 and rejoins on 103.
        SELECT COUNT(*), COUNT(CASE WHEN day_dt - d_base IN (meta_n_dropped + 1, 100, 103) THEN 1 END)
          INTO v_n, v_num
          FROM capd_series_daily
               CROSS JOIN (SELECT nval AS meta_n_dropped FROM cap_fixture_meta WHERE mkey = 'DROPPED_LAST_DAY')
          WHERE dbid = v_dbid AND series = 'DB_SIZE_GB' AND gap_flag = 'Y';
        chk_int('DB_SIZE_GB gap_flag days (tablespace set changed)', v_n, 3);
        chk_int('DB_SIZE_GB gap_flag on DROPPED_LAST_DAY + 1, 100 and 103', v_num, 3);
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND gap_flag = 'Y';
        chk_int('REDO_GB_DAY gap_flag never Y (12 h intervals)', v_n, 0);
        SELECT day_gap INTO v_n FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND day_dt = d_base + 61;
        chk_int('REDO_GB_DAY day_gap after the restart day', v_n, 2);

        DBMS_OUTPUT.PUT_LINE('=== M15 point feeds ===');
        SELECT anomaly_flag, how_hours_flagged, anomaly INTO v_flag, v_n, v_num
          FROM capr_series_points
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT' AND ts = d_inv;
        chk_true('inverted Wednesday point: headline flag NULL', v_flag IS NULL);
        chk_int ('inverted Wednesday point: how_hours_flagged', v_n, 2);
        chk_int ('inverted Wednesday point: anomaly', v_num, 1);
        SELECT anomaly_flag, anomaly_modes INTO v_flag, v_msg
          FROM capr_series_points
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'TBSPC' AND series = 'FIX_SPIKE' AND ts = d_spike;
        chk_str('SPIKE point headline flag (TRAILING)', v_flag, 'HIGH');
        chk_str('SPIKE point anomaly_modes', v_msg, 'TRAILING,SAME_DOW');
        SELECT how_flag, how_z INTO v_flag, v_num FROM capr_hourly_points
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND series = 'BUSY_PCT' AND ts = d_inj + 6/24;
        chk_str  ('CAPR_HOURLY_POINTS injected Tuesday 06:00 how_flag', v_flag, 'HIGH');
        chk_close('CAPR_HOURLY_POINTS injected Tuesday 06:00 how_z', v_num, 10, 0.000001);

        DBMS_OUTPUT.PUT_LINE('=== M15 alerts with the shipped alert_modes ===');
        snap_alerts;
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE kind = 'CPU_ANOM';
        chk_int('CPU_ANOM alerts', v_n, 1);
        SELECT baseline_mode INTO v_mode FROM cap_fixture_alerts_snap WHERE kind = 'CPU_ANOM';
        chk_str('CPU_ANOM baseline_mode', v_mode, 'SAME_DOW');
        -- The 7 FIXPDB1 step days are consecutive, so they fold into ONE
        -- episode, and all 7 lie inside CAPA_CPU_SHIFT's recent window
        -- (shift_days = 7 ending LAST_DAY), so the episode is INFO with the
        -- level-shift suffix. The CPU_SHIFT row stays the one WARN.
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
          WHERE kind = 'DBCPU_ANOM' AND severity = 'WARN';
        chk_int('DBCPU_ANOM WARN alerts (the step days are INFO under the shift)', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE kind = 'DBCPU_ANOM';
        chk_int('DBCPU_ANOM alerts in total (the 7 step days, one episode)', v_n, 1);
        SELECT severity, n_days, first_day, day_dt, message INTO v_str, v_num, d_tstart, v_dt0, v_msg
          FROM cap_fixture_alerts_snap
          WHERE kind = 'DBCPU_ANOM' AND baseline_mode = 'SAME_DOW'
            AND db_pdb = 'FIXCDB/FIXPDB1' AND series_key = 'DB_CPU_PCT';
        chk_str ('DBCPU_ANOM episode severity INFO (level shift active)', v_str, 'INFO');
        chk_int ('DBCPU_ANOM episode n_days = shift_days', v_num, 7);
        chk_int ('DBCPU_ANOM episode first_day = LAST_DAY - 6 (days back)', d_last - d_tstart, 6);
        chk_int ('DBCPU_ANOM episode day_dt = LAST_DAY (days back)', d_last - v_dt0, 0);
        chk_true('DBCPU_ANOM episode message: "7 consecutive days, latest <LAST_DAY>" ... " (level shift active)" (got: '
                 || v_msg || ')',
                 v_msg LIKE '7 consecutive days, latest ' || TO_CHAR(d_last, 'YYYY-MM-DD') || ', peak robust z %'
                 AND v_msg LIKE '% (level shift active)');
        SELECT COUNT(*), MAX(kind) INTO v_n, v_str FROM cap_fixture_alerts_snap
          WHERE con_dbid = n_pdb AND series_key = 'DB_CPU_PCT' AND severity = 'WARN';
        chk_true('FIXPDB1 DB_CPU_PCT: CPU_SHIFT is the one WARN (got ' || v_n || ' ' || v_str || ')',
                 v_n = 1 AND v_str = 'CPU_SHIFT');
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE kind = 'TBSPC_ANOM';
        chk_int('TBSPC_ANOM alerts (the spike + the FIX_GAP burst episode; the purge predates the window)', v_n, 2);
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
          WHERE kind = 'SERIES_ANOM' AND series_key = 'DB_SIZE_GB' AND day_dt = d_spike
            AND severity = 'WARN' AND baseline_mode = 'TRAILING';
        chk_int('SERIES_ANOM WARN for DB_SIZE_GB on the spike day', v_n, 1);
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE kind = 'SERIES_ANOM';
        chk_int('SERIES_ANOM alerts in total', v_n, 1);
        SELECT value, threshold INTO v_num, v_num2 FROM cap_fixture_alerts_snap
          WHERE kind = 'TBSPC_ANOM' AND series_key = 'FIX_SPIKE';
        chk_close('TBSPC_ANOM value = the scored rate (bytes/day)', v_num, meta_n('SPIKE_RATE') + 2147483648, 0.000001);
        chk_close('TBSPC_ANOM threshold = the bound crossed (median + floor)', v_num2,
                  meta_n('SPIKE_RATE') + 104857600, 0.000001);
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
          WHERE (kind IN ('TBSPC_ANOM', 'CPU_ANOM', 'DBCPU_ANOM', 'SERIES_ANOM') AND baseline_mode IS NULL)
             OR (kind NOT IN ('TBSPC_ANOM', 'CPU_ANOM', 'DBCPU_ANOM', 'SERIES_ANOM') AND baseline_mode IS NOT NULL);
        chk_int('baseline_mode set on anomaly kinds only', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE kind = 'CPU_SHIFT';
        chk_int('CPU_SHIFT alerts unchanged', v_n, 1);

        DBMS_OUTPUT.PUT_LINE('=== M15 knob flips ===');
        SELECT cfg_value INTO v_old FROM cap_config WHERE cfg_name = 'alert_modes_cpu';
        knob('alert_modes_cpu', 6);
        BEGIN
            snap_alerts;
            SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE kind = 'CPU_ANOM';
            chk_int('alert_modes_cpu=6: CPU_ANOM (SAME_DOW + HOW Tue + HOW Wed, one HOW episode when adjacent)',
                    v_n, CASE WHEN v_adj THEN 2 ELSE 3 END);
            SELECT severity, value, threshold, message INTO v_str, v_num, v_num2, v_msg
              FROM cap_fixture_alerts_snap
              WHERE kind = 'CPU_ANOM' AND baseline_mode = 'HOUR_OF_WEEK' AND day_dt = d_inv;
            chk_str  ('alert_modes_cpu=6: HOW inverted Wednesday severity', v_str, 'WARN');
            chk_close('alert_modes_cpu=6: HOW inverted Wednesday carries 06:00 (value 40)', v_num, 40, 0.000001);
            chk_close('alert_modes_cpu=6: HOW inverted Wednesday bound 20 + 15', v_num2, 35, 0.000001);
            chk_true ('alert_modes_cpu=6: message says "2 hours flagged that day" (got: ' || v_msg || ')',
                      INSTR(v_msg, '; 2 hours flagged that day') > 0 AND INSTR(v_msg, 'for Wed 06:00') > 0);
            IF v_adj THEN
                -- Tuesday folds into the Wednesday's episode: its 06:00 hour
                -- (z 50/5 = 10, the worst of both days) is the episode peak.
                SELECT n_days, first_day, max_z, message INTO v_n, v_dt0, v_num, v_msg FROM capr_alerts
                  WHERE kind = 'CPU_ANOM' AND baseline_mode = 'HOUR_OF_WEEK' AND day_dt = d_inv;
                chk_true('alert_modes_cpu=6: HOW Tue + Wed one episode: n_days 2, first_day = INJECTED_TUE, '
                         || 'max_z 10 (got ' || v_n || ' ' || TO_CHAR(v_dt0, 'YYYY-MM-DD') || ' ' || v_num || ')',
                         v_n = 2 AND v_dt0 = d_inj AND ABS(v_num - 10) < 1e-9);
                chk_true('alert_modes_cpu=6: HOW episode message "2 consecutive days, latest <Wed>, peak robust z +10.0: " (got: '
                         || v_msg || ')',
                         v_msg LIKE '2 consecutive days, latest ' || TO_CHAR(d_inv, 'YYYY-MM-DD')
                                    || ', peak robust z +10.0: %');
            ELSE
                SELECT value, threshold, n_days INTO v_num, v_num2, v_n FROM capr_alerts
                  WHERE kind = 'CPU_ANOM' AND baseline_mode = 'HOUR_OF_WEEK' AND day_dt = d_inj;
                chk_true('alert_modes_cpu=6: HOW injected Tuesday carries 06:00 (70 vs bound 35, got '
                         || v_num || ' / ' || v_num2 || '), its own one-day episode',
                         ABS(v_num - 70) < 1e-9 AND ABS(v_num2 - 35) < 1e-9 AND v_n = 1);
            END IF;
            snap_alerts;
            SELECT COUNT(*), COUNT(CASE WHEN severity = 'INFO' AND n_days = 7 THEN 1 END)
              INTO v_n, v_num FROM cap_fixture_alerts_snap WHERE kind = 'DBCPU_ANOM';
            chk_true('alert_modes_cpu=6: DBCPU_ANOM = 2 episodes (SAME_DOW, HOW), each 7 days, INFO (got '
                     || v_n || ' / ' || v_num || ')', v_n = 2 AND v_num = 2);
            SELECT COUNT(*) INTO v_n FROM (
                SELECT alert_key FROM cap_fixture_alerts_snap GROUP BY alert_key HAVING COUNT(*) > 1);
            chk_int('alert_modes_cpu=6: alert_key still unique', v_n, 0);
        EXCEPTION
            WHEN OTHERS THEN knob('alert_modes_cpu', v_old); COMMIT; RAISE;
        END;
        knob('alert_modes_cpu', 0);
        BEGIN
            SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind IN ('CPU_ANOM', 'DBCPU_ANOM');
            chk_int('alert_modes_cpu=0: no CPU_ANOM / DBCPU_ANOM', v_n, 0);
            SELECT alerting, sev INTO v_gflag, v_str FROM capr_anomalies
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND anomaly_kind = 'CPU_BUSY'
                AND baseline_mode = 'SAME_DOW' AND ts = d_inj;
            chk_true('alert_modes_cpu=0: CAPR_ANOMALIES still lists it, alerting N, sev INFO',
                     v_gflag = 'N' AND v_str = 'INFO');
        EXCEPTION
            WHEN OTHERS THEN knob('alert_modes_cpu', v_old); COMMIT; RAISE;
        END;
        knob('alert_modes_cpu', v_old);
        COMMIT;

        SELECT cfg_value INTO v_old FROM cap_config WHERE cfg_name = 'alert_modes_tbspc';
        knob('alert_modes_tbspc', 3);
        BEGIN
            SELECT COUNT(*), COUNT(DISTINCT alert_key) INTO v_n, v_num FROM capr_alerts
              WHERE kind = 'TBSPC_ANOM' AND series_key = 'FIX_SPIKE' AND day_dt = d_spike;
            chk_int('alert_modes_tbspc=3: SPIKE TBSPC_ANOM rows (TRAILING + SAME_DOW)', v_n, 2);
            chk_int('alert_modes_tbspc=3: distinct alert_key', v_num, 2);
        EXCEPTION
            WHEN OTHERS THEN knob('alert_modes_tbspc', v_old); COMMIT; RAISE;
        END;
        knob('alert_modes_tbspc', v_old);
        COMMIT;

        SELECT cfg_value INTO v_old FROM cap_config WHERE cfg_name = 'weekly_min_hist';
        SELECT COUNT(*) INTO v_num FROM capa_anom
          WHERE baseline_mode = 'TRAILING' AND anomaly_flag IS NOT NULL;
        knob('weekly_min_hist', 9);
        BEGIN
            SELECT COUNT(*) INTO v_n FROM capa_anom
              WHERE baseline_mode IN ('SAME_DOW', 'HOUR_OF_WEEK') AND anomaly_flag IS NOT NULL;
            chk_int('weekly_min_hist=9 (> dow_weeks): no weekly flags', v_n, 0);
            SELECT COUNT(*) INTO v_n FROM capa_anom
              WHERE baseline_mode = 'TRAILING' AND anomaly_flag IS NOT NULL;
            chk_int('weekly_min_hist=9: TRAILING flags unchanged', v_n, v_num);
            SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'weekly_min_hist';
            chk_str('weekly_min_hist=9: CAP_CFG_CHECK', v_str, 'BAD');
        EXCEPTION
            WHEN OTHERS THEN knob('weekly_min_hist', v_old); COMMIT; RAISE;
        END;
        knob('weekly_min_hist', v_old);
        COMMIT;

        SELECT cfg_value INTO v_old FROM cap_config WHERE cfg_name = 'hour_gap_ratio';
        knob('hour_gap_ratio', 0.5);
        BEGIN
            SELECT COUNT(*) INTO v_n FROM capd_cpu_hourly WHERE gap_flag = 'N';
            chk_int('hour_gap_ratio=0.5: every 12 h bucket is an hour-grain gap', v_n, 0);
            SELECT COUNT(*) INTO v_n FROM capa_anom
              WHERE baseline_mode = 'HOUR_OF_WEEK' AND anomaly_flag IS NOT NULL;
            chk_int('hour_gap_ratio=0.5: no HOUR_OF_WEEK flags', v_n, 0);
            SELECT COUNT(*) INTO v_n FROM capd_cpu_daily
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND gap_flag = 'Y';
            chk_int('hour_gap_ratio=0.5: daily gap days unchanged', v_n, 1);
        EXCEPTION
            WHEN OTHERS THEN knob('hour_gap_ratio', v_old); COMMIT; RAISE;
        END;
        knob('hour_gap_ratio', v_old);
        COMMIT;

        SELECT cfg_value INTO v_old FROM cap_config WHERE cfg_name = 'cpu_min_mad_pct_hour';
        knob('cpu_min_mad_pct_hour', 3);
        BEGIN
            chk_str('cpu_min_mad_pct_hour=3: injected Tuesday 18:00 flips HIGH (10 > 9)',
                    anom_flag('CPU', 'BUSY_PCT', 'HOUR_OF_WEEK', d_inj + 18/24, v_dbid), 'HIGH');
        EXCEPTION
            WHEN OTHERS THEN knob('cpu_min_mad_pct_hour', v_old); COMMIT; RAISE;
        END;
        knob('cpu_min_mad_pct_hour', v_old);
        COMMIT;

        -- anomaly_hour_grain = 0: CAPA_OBS drops its HOUR rows, so nothing is
        -- scored per hour; the DAY verdicts and the hourly points stay.
        SELECT cfg_value INTO v_old FROM cap_config WHERE cfg_name = 'anomaly_hour_grain';
        SELECT COUNT(*) INTO v_num FROM capa_anom WHERE grain = 'DAY' AND anomaly_flag IS NOT NULL;
        SELECT COUNT(*) INTO v_num3 FROM capd_cpu_hourly;
        knob('anomaly_hour_grain', 0);
        BEGIN
            SELECT COUNT(*) INTO v_n FROM capa_obs WHERE grain = 'HOUR';
            chk_int('anomaly_hour_grain=0: CAPA_OBS HOUR rows', v_n, 0);
            SELECT COUNT(*) INTO v_n FROM capa_anom WHERE grain = 'DAY' AND anomaly_flag IS NOT NULL;
            chk_int('anomaly_hour_grain=0: DAY flags unchanged', v_n, v_num);
            SELECT COUNT(*), COUNT(how_n_hist) + NVL(SUM(anomaly), 0) INTO v_n, v_num2 FROM capr_hourly_points;
            chk_true('anomaly_hour_grain=0: CAPR_HOURLY_POINTS keeps one row per CAPD_CPU_HOURLY row ('
                     || v_num3 || '), none scored (got ' || v_n || ' / ' || v_num2 || ')',
                     v_n = v_num3 AND v_num2 = 0);
        EXCEPTION
            WHEN OTHERS THEN knob('anomaly_hour_grain', v_old); COMMIT; RAISE;
        END;
        knob('anomaly_hour_grain', v_old);
        COMMIT;

        SELECT COUNT(*) INTO v_n FROM cap_config WHERE cfg_name IN ('tbspc_min_hist', 'cpu_min_dow_hist');
        chk_int('retired knobs tbspc_min_hist / cpu_min_dow_hist gone', v_n, 0);
        SELECT trailing_min_hist, weekly_min_hist INTO v_num, v_num2 FROM cap_cfg;
        chk_true('CAP_CFG trailing_min_hist = 7, weekly_min_hist = 3', v_num = 7 AND v_num2 = 3);
        SELECT COUNT(*) INTO v_n FROM cap_cfg
          WHERE cpu_min_mad_pct_hour = 5 AND hour_gap_ratio = 1.5 AND series_floor_count = 10
            AND series_floor_gib = 0.5 AND alert_modes_tbspc = 1 AND alert_modes_cpu = 2
            AND alert_modes_series = 1;
        chk_int('CAP_CFG new M15 knobs at their shipped values', v_n, 1);
    EXCEPTION
        WHEN OTHERS THEN
            fail('M15 anomaly-modes block raised ' || SQLERRM);
    END;

    -- Alert surface: CAPR_SEVERITY, the stable state_key, direction,
    -- the gates, per-tablespace thresholds, DATA_STALE, CPU_HOT / DBCPU_HOT,
    -- MODEL_HEALTH, the CPU limit convention and the SERIES scored flag.
    -- Closed forms come from CAP_FIXTURE_META; every knob or data change is
    -- uncommitted and rolled back to a savepoint.
    DECLARE
        d_last   DATE   := meta_d('LAST_DAY');
        n_pdb2   NUMBER := meta_n('PDB2_CON_DBID');
        n_pdb1   NUMBER := meta_n('PDB_CON_DBID');
        n_fw     NUMBER := meta_n('FILLING_OVR_DTF_WARN');
        n_fc     NUMBER := meta_n('FILLING_OVR_DTF_CRIT');
        n_fdtf   NUMBER := meta_n('FILLING_DTF');
        n_fpct   NUMBER := meta_n('FILLING_PCT');
        n_c1dtf  NUMBER := meta_n('CYC1_DTF');
        n_ddtf   NUMBER := meta_n('DROPPED_DTF');
        n_p95    NUMBER := meta_n('CPU_PROBE_P95');
        n_p2med  NUMBER := meta_n('PDB2_P95_RECENT_MED');
        n_lcur   NUMBER := meta_n('LINEAR_CUR');
        v_sat    NUMBER;
        v_age    NUMBER;
        v_snap   DATE;
        v_dt     DATE;
        v_dt2    DATE;
        v_key    VARCHAR2(400);
        v_key2   VARCHAR2(400);
        v_akey   VARCHAR2(400);
        v_akey2  VARCHAR2(400);
        v_sev    VARCHAR2(10);
        v_raw    VARCHAR2(10);
        v_gate   VARCHAR2(40);
        v_dir    VARCHAR2(5);
        v_src    VARCHAR2(10);
        v_a      NUMBER;
        v_b      NUMBER;
        v_c      NUMBER;
    BEGIN
        SELECT cpu_sat_pct INTO v_sat FROM cap_cfg;

        DBMS_OUTPUT.PUT_LINE('=== alerts: CAPR_SEVERITY shape + agreement ===');
        -- One row per kind and series: 2 per tablespace, 2 per M11 series,
        -- CPU_SAT on the host BUSY_P95, DBCPU_SAT / DBCPU_HOT per container,
        -- CPU_HOT on the host BUSY_P95.
        SELECT COUNT(*) INTO v_n FROM capr_severity WHERE fit_kind = 'TBSPC';
        SELECT 2 * COUNT(*) INTO v_num FROM capf_tbspc_forecast;
        chk_int('CAPR_SEVERITY TBSPC rows = 2 x CAPF_TBSPC_FORECAST', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM capr_severity WHERE fit_kind = 'SERIES';
        SELECT 2 * COUNT(*) INTO v_num FROM capf_series_forecast;
        chk_int('CAPR_SEVERITY SERIES rows = 2 x CAPF_SERIES_FORECAST', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM capr_severity
          WHERE (kind = 'CPU_SAT'   AND series_key = 'BUSY_P95')
             OR (kind = 'CPU_HOT'   AND series_key = 'BUSY_P95')
             OR (kind = 'DBCPU_SAT' AND series_key = 'DB_CPU_PCT')
             OR (kind = 'DBCPU_HOT' AND series_key = 'DB_CPU_P95');
        SELECT COUNT(*) INTO v_num FROM capr_severity WHERE fit_kind = 'CPU';
        chk_int('CAPR_SEVERITY CPU rows are exactly the four metric-to-kind pairs', v_n, v_num);
        chk_int('CAPR_SEVERITY CPU rows (root 4 + FIXPDB1 2 + FIXPDB2 2)', v_num, 8);
        SELECT COUNT(*) INTO v_n FROM (
            SELECT 1 FROM capr_severity GROUP BY kind, dbid, con_dbid, series_key HAVING COUNT(*) > 1);
        chk_int('CAPR_SEVERITY key (kind, dbid, con_dbid, series_key) unique', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_severity
          WHERE sev NOT IN ('CRIT', 'WARN', 'OK') OR raw_sev NOT IN ('CRIT', 'WARN', 'OK')
             OR (gated_by IS NOT NULL AND sev <> 'OK')
             OR (sev <> raw_sev AND gated_by IS NULL)
             OR (sev = 'OK' AND message IS NOT NULL) OR (sev <> 'OK' AND message IS NULL);
        chk_int('CAPR_SEVERITY sev = raw_sev unless gated, message only when alerting', v_n, 0);
        -- Every non-OK CAPR_SEVERITY row is exactly one forecast-kind
        -- CAPR_ALERTS row with the same numbers, and the other way round.
        snap_alerts;
        SELECT COUNT(*) INTO v_n
          FROM (SELECT * FROM capr_severity WHERE sev <> 'OK') s
          FULL OUTER JOIN
               (SELECT * FROM cap_fixture_alerts_snap
                WHERE  kind IN ('TBSPC_FULL', 'TBSPC_NEARFULL', 'CPU_SAT', 'DBCPU_SAT', 'CPU_HOT',
                                'DBCPU_HOT', 'SERIES_LIMIT', 'SERIES_NEARLIMIT')) a
            ON a.kind = s.kind AND a.dbid = s.dbid AND a.con_dbid = s.con_dbid
           AND a.series_key = s.series_key
          WHERE s.kind IS NULL OR a.kind IS NULL
             OR a.severity <> s.sev OR a.day_dt <> s.day_dt OR a.value <> s.value
             OR a.threshold <> s.threshold OR a.alarm_threshold <> s.alarm_threshold
             OR a.direction <> s.direction OR a.unit <> s.unit OR a.message <> s.message;
        chk_int('CAPR_ALERTS forecast kinds = the non-OK CAPR_SEVERITY rows, number for number', v_n, 0);
        -- Section 1 (both halves), section 4, section 7 and CAPR_FIT read the
        -- same severities.
        SELECT COUNT(*) INTO v_n
          FROM capr_tbspc_days_to_full r
          JOIN capr_severity f ON f.kind = 'TBSPC_FULL' AND f.dbid = r.dbid
                              AND f.con_dbid = r.con_dbid AND f.series_key = r.tablespace_name
          JOIN capr_severity n ON n.kind = 'TBSPC_NEARFULL' AND n.dbid = r.dbid
                              AND n.con_dbid = r.con_dbid AND n.series_key = r.tablespace_name
          WHERE r.sev_dtf <> f.sev OR r.sev_nearfull <> n.sev
             OR NVL(r.gated_by, '-') <> NVL(f.gated_by, '-') OR NVL(r.gate, '-') <> NVL(f.gate, '-')
             OR r.eff_dtf_warn <> f.warn_threshold OR r.eff_nearfull_crit_pct <> n.crit_threshold;
        SELECT COUNT(*) INTO v_num FROM capr_tbspc_days_to_full;
        chk_int('CAPR_TBSPC_DAYS_TO_FULL sev_dtf / sev_nearfull / gate = CAPR_SEVERITY (mismatches; '
                || v_num || ' rows)', v_n, 0);
        SELECT COUNT(*) INTO v_n
          FROM capr_cpu_trend r
          LEFT JOIN (SELECT dbid, con_dbid, series_key, MIN(sev_rank) AS rk
                     FROM capr_severity WHERE fit_kind = 'CPU'
                     GROUP BY dbid, con_dbid, series_key) s
            ON s.dbid = r.dbid AND s.con_dbid = r.con_dbid AND s.series_key = r.metric
          WHERE r.sev <> DECODE(NVL(s.rk, 3), 1, 'CRIT', 2, 'WARN', 'OK');
        chk_int('CAPR_CPU_TREND sev = worst CAPR_SEVERITY CPU sev (mismatches)', v_n, 0);
        SELECT COUNT(*) INTO v_n
          FROM capr_series r
          LEFT JOIN (SELECT dbid, con_dbid, series_key, MIN(sev_rank) AS rk
                     FROM capr_severity WHERE fit_kind = 'SERIES'
                     GROUP BY dbid, con_dbid, series_key) s
            ON s.dbid = r.dbid AND s.con_dbid = r.con_dbid AND s.series_key = r.series
          WHERE r.sev <> DECODE(NVL(s.rk, 3), 1, 'CRIT', 2, 'WARN', 'OK');
        chk_int('CAPR_SERIES sev = worst CAPR_SEVERITY SERIES sev (mismatches)', v_n, 0);
        SELECT COUNT(*) INTO v_n
          FROM capr_fit r
          LEFT JOIN (SELECT fit_kind, dbid, con_dbid, series_key, MIN(sev_rank) AS rk
                     FROM capr_severity GROUP BY fit_kind, dbid, con_dbid, series_key) s
            ON s.fit_kind = r.kind AND s.dbid = r.dbid AND s.con_dbid = r.con_dbid AND s.series_key = r.series
          WHERE r.sev <> DECODE(NVL(s.rk, 3), 1, 'CRIT', 2, 'WARN', 'OK') OR r.sev_rank <> NVL(s.rk, 3);
        chk_int('CAPR_FIT sev / sev_rank = worst CAPR_SEVERITY sev (mismatches)', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM (
            SELECT sev_dtf AS sev FROM capr_tbspc_days_to_full UNION ALL
            SELECT sev_nearfull   FROM capr_tbspc_days_to_full UNION ALL
            SELECT sev            FROM capr_cpu_trend          UNION ALL
            SELECT sev            FROM capr_series             UNION ALL
            SELECT sev            FROM capr_fit)
          WHERE sev NOT IN ('CRIT', 'WARN', 'OK');
        chk_int('every section severity is upper-case CRIT / WARN / OK', v_n, 0);

        DBMS_OUTPUT.PUT_LINE('=== alerts: state_key, direction, alarm_threshold, is_current ===');
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
          WHERE state_key <> kind || '|' || dbid || '|' || con_dbid || '|' || series_key || '|'
                             || NVL(baseline_mode, '-')
             OR is_current <> 'Y' OR alarm_threshold IS NULL OR direction IS NULL;
        chk_int('state_key = kind|dbid|con_dbid|series_key|mode, is_current Y, alarm_threshold set', v_n, 0);
        -- The seven FIXPDB1 step days: one episode row, its alert_key that of
        -- the last day, n_days 7, ONE state.
        SELECT COUNT(*), COUNT(DISTINCT alert_key), COUNT(DISTINCT state_key), MAX(n_days), MAX(alert_key)
          INTO v_n, v_a, v_b, v_c, v_akey
          FROM cap_fixture_alerts_snap WHERE kind = 'DBCPU_ANOM';
        chk_true('DBCPU_ANOM: 1 row, 1 alert_key, n_days 7, 1 state_key (got ' || v_n || '/' || v_a
                 || '/' || v_c || '/' || v_b || ')', v_n = 1 AND v_a = 1 AND v_c = 7 AND v_b = 1);
        chk_str ('DBCPU_ANOM episode alert_key = the last day''s', v_akey,
                 v_dbid || '|' || n_pdb1 || '|DBCPU_ANOM|DB_CPU_PCT|' || TO_CHAR(d_last, 'YYYY-MM-DD') || '|SAME_DOW');
        -- The direction law, every row: LE value <= alarm, GE value >= alarm,
        -- ABS |value| > alarm.
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
          WHERE NOT ((direction = 'LE'  AND value <= alarm_threshold)
                  OR (direction = 'GE'  AND value >= alarm_threshold)
                  OR (direction = 'ABS' AND ABS(value) > alarm_threshold));
        chk_int('every alert satisfies its direction against alarm_threshold', v_n, 0);
        -- Table-driven: the direction of every kind, in CAPR_SEVERITY (every
        -- forecast kind has rows there) and in CAPR_ALERTS. Anomaly kinds are
        -- GE on the HIGH side and LE on the LOW side.
        FOR k IN (SELECT 'TBSPC_FULL' AS kind, 'LE' AS dir FROM dual
                  UNION ALL SELECT 'TBSPC_NEARFULL',   'GE'  FROM dual
                  UNION ALL SELECT 'CPU_SAT',          'LE'  FROM dual
                  UNION ALL SELECT 'DBCPU_SAT',        'LE'  FROM dual
                  UNION ALL SELECT 'CPU_HOT',          'GE'  FROM dual
                  UNION ALL SELECT 'DBCPU_HOT',        'GE'  FROM dual
                  UNION ALL SELECT 'SERIES_LIMIT',     'LE'  FROM dual
                  UNION ALL SELECT 'SERIES_NEARLIMIT', 'GE'  FROM dual) LOOP
            SELECT COUNT(*), COUNT(CASE WHEN direction <> k.dir THEN 1 END) INTO v_n, v_num
              FROM capr_severity WHERE kind = k.kind;
            chk_true('direction ' || k.kind || ' = ' || k.dir || ' (' || v_n || ' CAPR_SEVERITY rows, '
                     || v_num || ' off)', v_n > 0 AND v_num = 0);
        END LOOP;
        snap_alerts;
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
          WHERE direction <> CASE
                    WHEN kind IN ('TBSPC_FULL', 'CPU_SAT', 'DBCPU_SAT', 'SERIES_LIMIT')  THEN 'LE'
                    WHEN kind IN ('TBSPC_NEARFULL', 'CPU_HOT', 'DBCPU_HOT', 'SERIES_NEARLIMIT',
                                  'DATA_STALE', 'MODEL_HEALTH')                         THEN 'GE'
                    WHEN kind = 'CPU_SHIFT'                                              THEN 'ABS'
                    WHEN value >= threshold                                              THEN 'GE'
                    ELSE 'LE' END;
        chk_int('CAPR_ALERTS direction per kind (table-driven)', v_n, 0);
        -- alarm_threshold is the WARN level whatever the severity: FIX_FILLING
        -- is CRIT against its own dtf_crit (threshold) and keeps its own
        -- dtf_warn as alarm_threshold.
        SELECT severity, value, threshold, alarm_threshold, direction
          INTO v_sev, v_a, v_b, v_c, v_dir
          FROM cap_fixture_alerts_snap WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_FILLING';
        chk_true('FIX_FILLING TBSPC_FULL CRIT, value ' || n_fdtf || ', threshold ' || n_fc
                 || ', alarm_threshold ' || n_fw || ', LE (got ' || v_sev || ' ' || v_a || ' ' || v_b
                 || ' ' || v_c || ' ' || v_dir || ')',
                 v_sev = 'CRIT' AND v_a = n_fdtf AND v_b = n_fc AND v_c = n_fw AND v_dir = 'LE');
        -- A forecast kind keeps its state_key from one day to the next. Drop
        -- FIX_FILLING's last usage row: its fit ends a day earlier (day_dt
        -- LAST_DAY - 1, one more 10 MiB day of headroom: 21 days), same key.
        SELECT state_key, alert_key, day_dt INTO v_key, v_akey, v_dt
          FROM cap_fixture_alerts_snap WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_FILLING';
        SAVEPOINT as_day;
        BEGIN
            DELETE FROM cap_fixture_tbspc_usage
             WHERE tablespace_id = (SELECT tablespace_id FROM cap_fixture_tablespace
                                     WHERE tablespace_name = 'FIX_FILLING')
               AND snap_id IN (SELECT snap_id FROM cap_fixture_snapshot
                                WHERE TRUNC(end_interval_time) = d_last);
            SELECT state_key, alert_key, day_dt, value INTO v_key2, v_akey2, v_dt2, v_a
              FROM capr_alerts WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_FILLING';
            chk_true('state_key stable across days (' || v_key || ')', v_key2 = v_key);
            chk_true('alert_key changes with the day (' || v_akey || ' -> ' || v_akey2 || ')', v_akey2 <> v_akey);
            chk_int ('day_dt LAST_DAY, then LAST_DAY - 1 (days back)', d_last - v_dt2, 1);
            chk_int ('day_dt of the full series = LAST_DAY (days back)', d_last - v_dt, 0);
            chk_int ('one day earlier: days_to_full = FILLING_DTF + 1', v_a, n_fdtf + 1);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT as_day; RAISE;
        END;
        ROLLBACK TO SAVEPOINT as_day;

        DBMS_OUTPUT.PUT_LINE('=== alerts: gates: NOT CURRENT, QUALITY CYCLIC, LIMIT BELOW USED, QUALITY ===');
        SELECT COUNT(*), COUNT(CASE WHEN gated_by = 'NOT CURRENT' AND sev = 'OK' THEN 1 END)
          INTO v_n, v_num
          FROM capr_severity WHERE series_key = 'FIX_DROPPED';
        chk_true('FIX_DROPPED: both kinds gated NOT CURRENT, sev OK (' || v_num || ' of ' || v_n || ')',
                 v_n = 2 AND v_num = 2);
        SELECT value INTO v_a FROM capr_severity WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_DROPPED';
        chk_int('FIX_DROPPED days_to_full = DROPPED_DTF (LINEAR_DTF + 30)', v_a, n_ddtf);
        SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE series_key = 'FIX_DROPPED';
        chk_int('FIX_DROPPED raises no CAPR_ALERTS row', v_n, 0);
        SELECT gate INTO v_gate FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_DROPPED';
        chk_str('section 1a gate for FIX_DROPPED', v_gate, 'stale');
        SELECT gated_by, sev INTO v_gate, v_sev FROM capr_severity
          WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_CYCLIC';
        chk_true('FIX_CYCLIC TBSPC_FULL gated QUALITY CYCLIC, sev OK (got ' || v_gate || ' ' || v_sev || ')',
                 v_gate = 'QUALITY CYCLIC' AND v_sev = 'OK');
        SELECT gated_by, value INTO v_gate, v_a FROM capr_severity
          WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_CYCLIC_UP';
        chk_true('FIX_CYCLIC_UP gated QUALITY CYCLIC at days_to_full CYC1_DTF ' || n_c1dtf
                 || ' > dtf_warn (got ' || v_gate || ' ' || v_a || ')',
                 v_gate = 'QUALITY CYCLIC' AND v_a = n_c1dtf);
        SELECT gate INTO v_gate FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_CYCLIC';
        chk_str('section 1a gate for FIX_CYCLIC', v_gate, 'cyclic');
        -- rank_dtf: the CYCLIC row with no days_to_full ranks right after the
        -- rows that have one, ahead of the other rows without one.
        SELECT COUNT(*) + 1 INTO v_num FROM capf_tbspc_forecast WHERE days_to_full IS NOT NULL;
        SELECT rank_dtf INTO v_n FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_CYCLIC';
        chk_int('FIX_CYCLIC rank_dtf = 1 + rows with a days_to_full', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM capr_tbspc_days_to_full
          WHERE days_to_full IS NULL AND quality <> 'CYCLIC' AND rank_dtf <= v_num;
        chk_int('no row without a days_to_full ranks ahead of FIX_CYCLIC', v_n, 0);

        -- dtf_warn = 7000: FIX_CYCLIC_UP's peak line (6138 days) is inside the
        -- window, so TBSPC_FULL fires and names the cycle. FIX_CYCLIC (flat
        -- peaks) stays silent, and FIX_DROPPED (5020 days) would page but is
        -- not current.
        SAVEPOINT as_cyc;
        BEGIN
            knob('dtf_warn', 7000);
            snap_alerts;
            SELECT severity, value, threshold, alarm_threshold, message
              INTO v_sev, v_a, v_b, v_c, v_msg
              FROM cap_fixture_alerts_snap WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_CYCLIC_UP';
            chk_true('dtf_warn=7000: FIX_CYCLIC_UP TBSPC_FULL WARN at ' || n_c1dtf || ' days, alarm 7000 (got '
                     || v_sev || ' ' || v_a || ' ' || v_b || ' ' || v_c || ')',
                     v_sev = 'WARN' AND v_a = n_c1dtf AND v_b = 7000 AND v_c = 7000);
            v_str := TO_CHAR(meta_n('CYC1_PSLOPE') * meta_n('CYC1_DAYS') / 1073741824, 'FM99999990.00');
            chk_true('dtf_warn=7000: message names the cycle ("peaks grow ' || v_str
                     || ' GiB per cycle", "in ' || n_c1dtf || ' days"; got: ' || v_msg || ')',
                     INSTR(v_msg, 'every ' || meta_n('CYC1_DAYS') || ' days') > 0
                     AND INSTR(v_msg, 'peaks grow ' || v_str || ' GiB per cycle') > 0
                     AND INSTR(v_msg, 'reaches the limit in ' || n_c1dtf || ' days') > 0);
            SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
              WHERE kind = 'TBSPC_FULL' AND series_key IN ('FIX_CYCLIC', 'FIX_DROPPED');
            chk_int('dtf_warn=7000: no TBSPC_FULL for FIX_CYCLIC / FIX_DROPPED', v_n, 0);
            SELECT raw_sev, sev, gated_by INTO v_raw, v_sev, v_gate FROM capr_severity
              WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_DROPPED';
            chk_true('dtf_warn=7000: FIX_DROPPED raw WARN, sev OK, gated NOT CURRENT (got '
                     || v_raw || ' ' || v_sev || ' ' || v_gate || ')',
                     v_raw = 'WARN' AND v_sev = 'OK' AND v_gate = 'NOT CURRENT');
            SELECT gated_by INTO v_gate FROM capr_severity
              WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_CYCLIC_UP';
            chk_true('dtf_warn=7000: FIX_CYCLIC_UP not gated', v_gate IS NULL);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT as_cyc; RAISE;
        END;
        ROLLBACK TO SAVEPOINT as_cyc;

        -- LIMIT BELOW USED: a 1 GiB ceiling under FIX_LINEAR's 1.27 GiB. The
        -- would-be TBSPC_FULL (0 days) is held back, TBSPC_NEARFULL pages.
        SAVEPOINT as_lbu;
        BEGIN
            INSERT INTO cap_tbspc_override (dbid, con_dbid, tablespace_name, limit_bytes, exclude_flag, note)
            VALUES (v_dbid, v_dbid, 'FIX_LINEAR', 1073741824, 'N', 'run_test alert probe');
            SELECT raw_sev, sev, gated_by, value INTO v_raw, v_sev, v_gate, v_a FROM capr_severity
              WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_LINEAR';
            chk_true('limit probe: FIX_LINEAR TBSPC_FULL raw CRIT at 0 days, gated LIMIT BELOW USED (got '
                     || v_raw || ' ' || v_a || ' ' || v_gate || ')',
                     v_raw = 'CRIT' AND v_a = 0 AND v_sev = 'OK' AND v_gate = 'LIMIT BELOW USED');
            SELECT COUNT(*), MAX(severity), MAX(value) INTO v_n, v_sev, v_a FROM capr_alerts
              WHERE series_key = 'FIX_LINEAR' AND kind IN ('TBSPC_FULL', 'TBSPC_NEARFULL');
            chk_true('limit probe: one alert, TBSPC_NEARFULL CRIT at ' || ROUND(100 * n_lcur / 1073741824, 1)
                     || '% (got ' || v_n || ' ' || v_sev || ' ' || v_a || ')',
                     v_n = 1 AND v_sev = 'CRIT' AND v_a = ROUND(100 * n_lcur / 1073741824, 1));
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT as_lbu; RAISE;
        END;
        ROLLBACK TO SAVEPOINT as_lbu;

        -- QUALITY gate: r2_gate above 1 makes every OLS fit LOW_CONFIDENCE.
        -- The countdowns stop paging, the level kinds do not care.
        SAVEPOINT as_q;
        BEGIN
            knob('r2_gate', 1.01);
            SELECT raw_sev, sev, gated_by INTO v_raw, v_sev, v_gate FROM capr_severity
              WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_FILLING';
            chk_true('r2_gate=1.01: FIX_FILLING raw CRIT, gated QUALITY LOW_CONFIDENCE (got '
                     || v_raw || ' ' || v_sev || ' ' || v_gate || ')',
                     v_raw = 'CRIT' AND v_sev = 'OK' AND v_gate = 'QUALITY LOW_CONFIDENCE');
            SELECT sev_dtf, gate INTO v_sev, v_gate FROM capr_tbspc_days_to_full
              WHERE tablespace_name = 'FIX_FILLING';
            chk_true('r2_gate=1.01: section 1a FIX_FILLING sev OK, gate low-q (got ' || v_sev || ' '
                     || v_gate || ')', v_sev = 'OK' AND v_gate = 'low-q');
            SELECT COUNT(CASE WHEN kind IN ('TBSPC_FULL', 'SERIES_LIMIT') THEN 1 END),
                   COUNT(CASE WHEN kind = 'TBSPC_NEARFULL' AND series_key = 'FIX_NEARFULL'
                               AND severity = 'CRIT' THEN 1 END)
              INTO v_n, v_num
              FROM capr_alerts;
            chk_true('r2_gate=1.01: no TBSPC_FULL / SERIES_LIMIT, FIX_NEARFULL still CRIT (got '
                     || v_n || ' / ' || v_num || ')', v_n = 0 AND v_num = 1);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT as_q; RAISE;
        END;
        ROLLBACK TO SAVEPOINT as_q;

        DBMS_OUTPUT.PUT_LINE('=== alerts: per-tablespace thresholds (CAP_TBSPC_OVERRIDE) ===');
        SELECT warn_threshold, crit_threshold, thr_source, sev, sev_reason
          INTO v_a, v_b, v_src, v_sev, v_msg
          FROM capr_severity WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_FILLING';
        chk_true('FIX_FILLING TBSPC_FULL thresholds ' || n_fw || ' / ' || n_fc || ' from OVERRIDE (got '
                 || v_a || ' / ' || v_b || ' ' || v_src || ')',
                 v_a = n_fw AND v_b = n_fc AND v_src = 'OVERRIDE');
        chk_str('FIX_FILLING sev_reason', v_msg,
                'days_to_full ' || n_fdtf || ' <= dtf_crit ' || n_fc || ' (override)');
        SELECT warn_threshold, crit_threshold, thr_source INTO v_a, v_b, v_src
          FROM capr_severity WHERE kind = 'TBSPC_NEARFULL' AND series_key = 'FIX_FILLING';
        chk_true('FIX_FILLING TBSPC_NEARFULL keeps the knobs (NULL override columns; got '
                 || v_a || ' / ' || v_b || ' ' || v_src || ')',
                 v_a = 90 AND v_b = 97 AND v_src = 'CONFIG');
        SELECT eff_dtf_warn, eff_dtf_crit, sev_dtf INTO v_a, v_b, v_sev
          FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_FILLING';
        chk_true('section 1a FIX_FILLING eff thresholds ' || n_fw || ' / ' || n_fc || ', CRIT',
                 v_a = n_fw AND v_b = n_fc AND v_sev = 'CRIT');
        -- FIX_OVERRIDE's rows set only limit_bytes: the knobs still apply.
        SELECT severity, value, threshold, alarm_threshold INTO v_sev, v_a, v_b, v_c
          FROM capr_alerts WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_OVERRIDE';
        chk_true('FIX_OVERRIDE TBSPC_FULL WARN at OVERRIDE_DTF against the knobs 90 / 90 (got '
                 || v_sev || ' ' || v_a || ' ' || v_b || ' ' || v_c || ')',
                 v_sev = 'WARN' AND v_a = meta_n('OVERRIDE_DTF') AND v_b = 90 AND v_c = 90);
        SELECT thr_source, crit_threshold INTO v_src, v_b FROM capr_severity
          WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_OVERRIDE';
        chk_true('FIX_OVERRIDE thr_source CONFIG, crit 30', v_src = 'CONFIG' AND v_b = 30);
        SAVEPOINT as_ovr;
        BEGIN
            -- dtf_crit 15 < 20 <= dtf_warn 60: CRIT becomes WARN.
            UPDATE cap_tbspc_override SET dtf_crit = 15
             WHERE dbid = v_dbid AND con_dbid = v_dbid AND tablespace_name = 'FIX_FILLING';
            SELECT severity, threshold, alarm_threshold INTO v_sev, v_b, v_c
              FROM capr_alerts WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_FILLING';
            chk_true('override dtf_crit 15: FIX_FILLING WARN, threshold = alarm = ' || n_fw || ' (got '
                     || v_sev || ' ' || v_b || ' ' || v_c || ')',
                     v_sev = 'WARN' AND v_b = n_fw AND v_c = n_fw);
            SELECT sev_dtf INTO v_sev FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_FILLING';
            chk_str('override dtf_crit 15: section 1a sev_dtf', v_sev, 'WARN');
            -- dtf_warn 19 < 20: no alert at all.
            UPDATE cap_tbspc_override SET dtf_warn = 19
             WHERE dbid = v_dbid AND con_dbid = v_dbid AND tablespace_name = 'FIX_FILLING';
            SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_FILLING';
            chk_int('override dtf_warn 19: no FIX_FILLING TBSPC_FULL', v_n, 0);
            SELECT raw_sev, sev_reason INTO v_raw, v_msg FROM capr_severity
              WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_FILLING';
            chk_true('override dtf_warn 19: raw OK, reason "' || v_msg || '"',
                     v_raw = 'OK' AND v_msg = 'days_to_full ' || n_fdtf || ' > dtf_warn 19 (override)');
            -- nearfull_warn_pct 85 <= 86.7: TBSPC_NEARFULL WARN; crit 86: CRIT.
            UPDATE cap_tbspc_override SET nearfull_warn_pct = 85
             WHERE dbid = v_dbid AND con_dbid = v_dbid AND tablespace_name = 'FIX_FILLING';
            SELECT severity, value, threshold, alarm_threshold INTO v_sev, v_a, v_b, v_c
              FROM capr_alerts WHERE kind = 'TBSPC_NEARFULL' AND series_key = 'FIX_FILLING';
            chk_true('override nearfull_warn_pct 85: TBSPC_NEARFULL WARN at FILLING_PCT ' || n_fpct
                     || ' (got ' || v_sev || ' ' || v_a || ' ' || v_b || ' ' || v_c || ')',
                     v_sev = 'WARN' AND v_a = n_fpct AND v_b = 85 AND v_c = 85);
            UPDATE cap_tbspc_override SET nearfull_crit_pct = 86
             WHERE dbid = v_dbid AND con_dbid = v_dbid AND tablespace_name = 'FIX_FILLING';
            SELECT severity, threshold, alarm_threshold INTO v_sev, v_b, v_c
              FROM capr_alerts WHERE kind = 'TBSPC_NEARFULL' AND series_key = 'FIX_FILLING';
            chk_true('override nearfull_crit_pct 86: CRIT, threshold 86, alarm 85 (got '
                     || v_sev || ' ' || v_b || ' ' || v_c || ')',
                     v_sev = 'CRIT' AND v_b = 86 AND v_c = 85);
            SELECT sev_nearfull INTO v_sev FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_FILLING';
            chk_str('override nearfull_crit_pct 86: section 1b sev_nearfull', v_sev, 'CRIT');
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT as_ovr; RAISE;
        END;
        ROLLBACK TO SAVEPOINT as_ovr;

        DBMS_OUTPUT.PUT_LINE('=== alerts: DATA_STALE (CAPR_FRESHNESS, the one SYSDATE test) ===');
        SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'stale_hours';
        chk_int('knob stale_hours default', v_num, 36);
        SELECT COUNT(*), MAX(newest_snap), MAX(age_hours), MAX(is_stale) INTO v_n, v_snap, v_age, v_c1
          FROM capr_freshness;
        v_a := (SYSDATE - (d_last + 18/24)) * 24;
        chk_int ('CAPR_FRESHNESS one row per dbid', v_n, 1);
        chk_true('CAPR_FRESHNESS newest_snap = LAST_DAY 18:00 (got ' || TO_CHAR(v_snap, 'YYYY-MM-DD HH24:MI') || ')',
                 v_snap = d_last + 18/24);
        chk_true('CAPR_FRESHNESS age_hours = (SYSDATE - LAST_DAY 18:00) * 24 (got ' || ROUND(v_age, 3)
                 || ', expected ' || ROUND(v_a, 3) || ')', ABS(v_age - v_a) < 0.05);
        chk_str ('CAPR_FRESHNESS is_stale (fixture anchored at TRUNC(SYSDATE))', v_c1, 'N');
        SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'DATA_STALE';
        chk_int('DATA_STALE absent by default', v_n, 0);
        -- Move the whole fixture clock one day back (newest snapshot
        -- LAST_DAY - 1 18:00, so 6 to 30 hours old whenever this runs), then
        -- stale_hours = 0: every dbid is stale.
        SAVEPOINT as_stale;
        BEGIN
            UPDATE cap_fixture_snapshot
               SET begin_interval_time = begin_interval_time - 1,
                   end_interval_time   = end_interval_time - 1,
                   startup_time        = startup_time - 1;
            SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'DATA_STALE';
            chk_int('clock - 1 day, stale_hours 36: DATA_STALE still absent (6..30 h old)', v_n, 0);
            knob('stale_hours', 0);
            v_snap := d_last - 1 + 18/24;
            v_a := (SYSDATE - v_snap) * 24;
            SELECT COUNT(DISTINCT dbid) INTO v_num FROM capv_snapshot;
            SELECT COUNT(*), MAX(severity), MAX(day_dt), MAX(value), MAX(threshold), MAX(alarm_threshold),
                   MAX(direction), MAX(unit), MAX(db_pdb), MAX(state_key), MAX(message)
              INTO v_n, v_sev, v_dt, v_age, v_b, v_c, v_dir, v_src, v_str, v_key, v_msg
              FROM capr_alerts WHERE kind = 'DATA_STALE';
            chk_int ('stale_hours 0: one DATA_STALE per dbid', v_n, v_num);
            chk_true('stale_hours 0: WARN, day_dt LAST_DAY - 1, threshold = alarm = 0, GE, HOURS, FIXCDB (got '
                     || v_sev || ' ' || TO_CHAR(v_dt, 'YYYY-MM-DD') || ' ' || v_b || ' ' || v_c || ' '
                     || v_dir || ' ' || v_src || ' ' || v_str || ')',
                     v_sev = 'WARN' AND v_dt = d_last - 1 AND v_b = 0 AND v_c = 0 AND v_dir = 'GE'
                     AND v_src = 'HOURS' AND v_str = 'FIXCDB');
            chk_true('stale_hours 0: value = age in hours, 1 decimal (got ' || v_age || ', expected '
                     || ROUND(v_a, 1) || ')', ABS(v_age - v_a) < 0.11);
            chk_str ('stale_hours 0: state_key', v_key, 'DATA_STALE|' || v_dbid || '|' || v_dbid || '|AWR_SNAPSHOT|-');
            chk_true('stale_hours 0: message names the db, the dbid and the newest snapshot (got: ' || v_msg || ')',
                     INSTR(v_msg, 'FIXCDB (dbid ' || v_dbid || ')') > 0
                     AND INSTR(v_msg, TO_CHAR(v_snap, 'YYYY-MM-DD HH24:MI')) > 0
                     AND INSTR(v_msg, ' hours ago') > 0);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT as_stale; RAISE;
        END;
        ROLLBACK TO SAVEPOINT as_stale;
        SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'DATA_STALE';
        chk_int('DATA_STALE absent again after the rollback', v_n, 0);
        SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'stale_hours';
        chk_str('CAP_CFG_CHECK stale_hours', v_str, 'OK');

        DBMS_OUTPUT.PUT_LINE('=== alerts: retired dbids (data_stale_max_days) + CAPR_COVERAGE ===');
        SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'data_stale_max_days';
        chk_int('knob data_stale_max_days default', v_num, 14);
        SELECT COUNT(*), MAX(retired), MAX(is_stale), MAX(history_days), MAX(n_series), MAX(n_stale), MAX(summary)
          INTO v_n, v_c1, v_str, v_a, v_b, v_c, v_msg
          FROM capr_coverage;
        chk_int ('CAPR_COVERAGE one row per dbid', v_n, 1);
        chk_true('CAPR_COVERAGE retired N, is_stale N (fixture anchored at TRUNC(SYSDATE))', v_c1 = 'N' AND v_str = 'N');
        chk_int ('CAPR_COVERAGE history_days = LAST_DAY - BASE_DAY + 1', v_a, d_last - meta_d('BASE_DAY') + 1);
        SELECT COUNT(*), COUNT(CASE WHEN is_current = 0 THEN 1 END) INTO v_n, v_num
          FROM capr_fit WHERE dbid = v_dbid;
        chk_true('CAPR_COVERAGE n_series / n_stale roll up CAPR_FIT (got ' || v_b || '/' || v_c
                 || ', CAPR_FIT ' || v_n || '/' || v_num || ')', v_b = v_n AND v_c = v_num AND v_c >= 1);
        chk_true('CAPR_COVERAGE summary "FIXCDB (dbid ..): current, <history> days of AWR, ..." (got: ' || v_msg || ')',
                 v_msg LIKE 'FIXCDB (dbid ' || v_dbid || '): current, '
                            || (d_last - meta_d('BASE_DAY') + 1) || ' days of AWR, ' || v_b || ' series (%');
        -- Clock 20 days back: newest snapshot LAST_DAY - 20 18:00, 462..486 h
        -- old, past data_stale_max_days (14 days = 336 h): retired, so no
        -- DATA_STALE although stale_hours (36) is far exceeded.
        SAVEPOINT as_retired;
        BEGIN
            UPDATE cap_fixture_snapshot
               SET begin_interval_time = begin_interval_time - 20,
                   end_interval_time   = end_interval_time - 20,
                   startup_time        = startup_time - 20;
            SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'DATA_STALE';
            chk_int('clock - 20 days: retired dbid raises no DATA_STALE', v_n, 0);
            v_a := FLOOR(ROUND((SYSDATE - (d_last - 20 + 18/24)) * 24, 1) / 24);
            SELECT retired, is_stale, summary INTO v_c1, v_str, v_msg FROM capr_coverage;
            chk_true('clock - 20 days: CAPR_COVERAGE retired Y, is_stale Y', v_c1 = 'Y' AND v_str = 'Y');
            chk_true('clock - 20 days: summary "RETIRED, no snapshot for ' || v_a || ' days" (got: ' || v_msg || ')',
                     v_msg LIKE 'FIXCDB (dbid ' || v_dbid || '): RETIRED, no snapshot for ' || v_a || ' days, %');
            knob('data_stale_max_days', 30);
            SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'DATA_STALE';
            chk_int('clock - 20 days, data_stale_max_days 30: DATA_STALE back, one per dbid', v_n, 1);
            SELECT retired INTO v_c1 FROM capr_coverage;
            chk_str('clock - 20 days, data_stale_max_days 30: CAPR_COVERAGE retired', v_c1, 'N');
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT as_retired; RAISE;
        END;
        ROLLBACK TO SAVEPOINT as_retired;

        DBMS_OUTPUT.PUT_LINE('=== alerts: anomaly episodes (consecutive flagged days, one row) ===');
        snap_alerts;
        SELECT COUNT(*), MAX(severity), MAX(n_days), MAX(first_day), MAX(day_dt), MAX(max_z),
               MAX(value), MAX(threshold), MAX(alert_key), MAX(message)
          INTO v_n, v_sev, v_a, v_dt, v_dt2, v_b, v_c, v_num, v_akey, v_msg
          FROM cap_fixture_alerts_snap WHERE kind = 'TBSPC_ANOM' AND series_key = 'FIX_GAP';
        chk_int ('FIX_GAP burst: one TBSPC_ANOM row for the 3 days', v_n, 1);
        chk_true('FIX_GAP burst: WARN, n_days = BURST_DAYS, first_day = BURST_FIRST, day_dt = BURST_LAST (got '
                 || v_sev || ' ' || v_a || ' ' || TO_CHAR(v_dt, 'YYYY-MM-DD') || ' ' || TO_CHAR(v_dt2, 'YYYY-MM-DD') || ')',
                 v_sev = 'WARN' AND v_a = meta_n('BURST_DAYS')
                 AND v_dt = meta_d('BURST_FIRST') AND v_dt2 = meta_d('BURST_LAST'));
        chk_close('FIX_GAP burst: max_z = 256 MiB / (100 MiB / mad_k)', v_b, meta_n('BURST_Z'), 0.000001);
        chk_close('FIX_GAP burst: value = the last day''s rate, 60 + 256 MiB/day', v_c, (7680 + 32768) * 8192, 0.000001);
        chk_close('FIX_GAP burst: threshold = median + floor, 60 + 100 MiB/day', v_num, 7680 * 8192 + 104857600, 0.000001);
        chk_str ('FIX_GAP burst: alert_key = the last day''s', v_akey,
                 v_dbid || '|' || v_dbid || '|TBSPC_ANOM|FIX_GAP|' || TO_CHAR(meta_d('BURST_LAST'), 'YYYY-MM-DD') || '|TRAILING');
        chk_true('FIX_GAP burst: message "3 consecutive days, latest <BURST_LAST>, peak robust z +7.7: Tablespace FIX_GAP grew ..." (got: '
                 || v_msg || ')',
                 v_msg LIKE '3 consecutive days, latest ' || TO_CHAR(meta_d('BURST_LAST'), 'YYYY-MM-DD')
                            || ', peak robust z +7.7: Tablespace FIX_GAP grew % on '
                            || TO_CHAR(meta_d('BURST_LAST'), 'YYYY-MM-DD') || ' %');
        SELECT COUNT(*), MAX(n_days), MAX(first_day), MAX(day_dt), MAX(max_z), MAX(message)
          INTO v_n, v_a, v_dt, v_dt2, v_b, v_msg
          FROM cap_fixture_alerts_snap WHERE kind = 'TBSPC_ANOM' AND series_key = 'FIX_SPIKE';
        chk_true('FIX_SPIKE single day: one row, n_days 1, first_day = day_dt = SPIKE_DAY (got ' || v_n || ' ' || v_a || ')',
                 v_n = 1 AND v_a = 1 AND v_dt = d_spike AND v_dt2 = d_spike);
        chk_close('FIX_SPIKE max_z = 2 GiB / (100 MiB / mad_k)', v_b, meta_n('SPIKE_Z'), 0.000001);
        chk_true('FIX_SPIKE message keeps the one-day form (got: ' || v_msg || ')',
                 v_msg LIKE 'Tablespace FIX_SPIKE grew 2.00 GiB on %' AND v_msg NOT LIKE '%consecutive days%');
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap
          WHERE (kind IN ('TBSPC_ANOM', 'CPU_ANOM', 'DBCPU_ANOM', 'SERIES_ANOM')
                 AND (n_days IS NULL OR first_day IS NULL OR day_dt - first_day + 1 <> n_days))
             OR (kind NOT IN ('TBSPC_ANOM', 'CPU_ANOM', 'DBCPU_ANOM', 'SERIES_ANOM')
                 AND (n_days IS NOT NULL OR first_day IS NOT NULL OR max_z IS NOT NULL));
        chk_int('first_day / n_days / max_z on anomaly kinds only, n_days = day_dt - first_day + 1', v_n, 0);

        DBMS_OUTPUT.PUT_LINE('=== alerts: CPU_HOT / DBCPU_HOT (hot_now, any quality) ===');
        SELECT COUNT(*), MAX(severity), MAX(con_dbid), MAX(series_key), MAX(value), MAX(threshold),
               MAX(alarm_threshold), MAX(db_pdb), MAX(message)
          INTO v_n, v_sev, v_num, v_str, v_a, v_b, v_c, v_str2, v_msg
          FROM cap_fixture_alerts_snap WHERE kind = 'DBCPU_HOT';
        chk_int ('DBCPU_HOT rows (FIXPDB2 DB_CPU_P95 only)', v_n, 1);
        chk_true('DBCPU_HOT FIXPDB2 DB_CPU_P95 WARN at PDB2_P95_RECENT_MED vs 80 (got ' || v_sev || ' '
                 || v_num || ' ' || v_str || ' ' || v_a || ' ' || v_b || ' ' || v_c || ' ' || v_str2 || ')',
                 v_sev = 'WARN' AND v_num = n_pdb2 AND v_str = 'DB_CPU_P95'
                 AND ABS(v_a - n_p2med) < 1e-9 AND v_b = v_sat AND v_c = v_sat AND v_str2 = 'FIXCDB/FIXPDB2');
        chk_true('DBCPU_HOT message (got: ' || v_msg || ')',
                 v_msg = 'DB CPU busy-hour p95 has been at ' || TO_CHAR(n_p2med, 'FM990.0')
                         || '% of logical CPUs (median of the last 7 complete days) vs the saturation line '
                         || v_sat || '%');
        SELECT COUNT(*) INTO v_n FROM cap_fixture_alerts_snap WHERE kind = 'CPU_HOT';
        chk_int('CPU_HOT absent (root BUSY_P95 recent median 58 < 80)', v_n, 0);
        SELECT sev INTO v_sev FROM capr_cpu_trend WHERE con_dbid = n_pdb2 AND metric = 'DB_CPU_P95';
        chk_str('section 4 sev for FIXPDB2 DB_CPU_P95', v_sev, 'WARN');
        SELECT sev INTO v_sev FROM capr_fit WHERE kind = 'CPU' AND con_dbid = n_pdb2 AND series = 'DB_CPU_P95';
        chk_str('CAPR_FIT sev for FIXPDB2 DB_CPU_P95', v_sev, 'WARN');
        SAVEPOINT as_hot;
        BEGIN
            knob('cpu_sat_pct', n_p95);
            SELECT COUNT(*), MAX(value), MAX(alarm_threshold), MAX(severity), MAX(message)
              INTO v_n, v_a, v_c, v_sev, v_msg
              FROM capr_alerts WHERE kind = 'CPU_HOT';
            chk_true('cpu_sat_pct = 58: CPU_HOT WARN on the root, value 58 = alarm (got ' || v_n || ' '
                     || v_sev || ' ' || v_a || ' ' || v_c || ')',
                     v_n = 1 AND v_sev = 'WARN' AND v_a = n_p95 AND v_c = n_p95);
            chk_true('CPU_HOT message (got: ' || v_msg || ')',
                     v_msg = 'Host CPU busy-hour p95 has been at 58.0% (median of the last 7 complete days)'
                             || ' vs the saturation line 58%');
            knob('cpu_sat_pct', n_p95 + 0.5);
            SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'CPU_HOT';
            chk_int('cpu_sat_pct = 58.5: CPU_HOT absent', v_n, 0);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT as_hot; RAISE;
        END;
        ROLLBACK TO SAVEPOINT as_hot;

        DBMS_OUTPUT.PUT_LINE('=== alerts: MODEL_HEALTH (Tier 1 view of the registry) ===');
        -- A schema that never trained Tier 2 has no registry rows and no
        -- MODEL_HEALTH. Then a fake FAILED forecast row raises a WARN, and a
        -- stale OK one an INFO. The OML side is in run_test_ml.sql.
        SAVEPOINT as_mh;
        BEGIN
            DELETE FROM cap_ml_model;
            SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'MODEL_HEALTH';
            chk_int('empty registry: no MODEL_HEALTH', v_n, 0);
            INSERT INTO cap_ml_model (model_name, series_kind, dbid, con_dbid, series_key, purpose,
                                      status, trained_through, trained_at, last_error, failed_at)
            VALUES ('CAP_ALERT_PROBE', 'TBSPC', v_dbid, v_dbid, 'FIX_LINEAR', 'FORECAST',
                    'FAILED', d_last, SYSDATE, 'ORA-40104: run_test probe' || CHR(10) || 'second line', SYSDATE);
            SELECT COUNT(*), MAX(severity), MAX(value), MAX(threshold), MAX(alarm_threshold), MAX(direction),
                   MAX(unit), MAX(day_dt), MAX(message)
              INTO v_n, v_sev, v_a, v_b, v_c, v_dir, v_src, v_dt, v_msg
              FROM capr_alerts WHERE kind = 'MODEL_HEALTH';
            chk_true('one FAILED model: MODEL_HEALTH WARN, value 1, threshold 1, GE, COUNT, today (got '
                     || v_n || ' ' || v_sev || ' ' || v_a || ' ' || v_b || ' ' || v_dir || ' ' || v_src || ')',
                     v_n = 1 AND v_sev = 'WARN' AND v_a = 1 AND v_b = 1 AND v_c = 1 AND v_dir = 'GE'
                     AND v_src = 'COUNT' AND v_dt = TRUNC(SYSDATE));
            chk_str ('one FAILED model: message', v_msg,
                     'Tier 2 ESM forecast models: 1 failed, 0 stale, 0 OK of 1; newest error: '
                     || 'ORA-40104: run_test probe second line');
            UPDATE cap_ml_model
               SET status = 'OK', last_error = NULL, failed_at = NULL,
                   trained_through = d_last - (SELECT esm_max_age_days FROM cap_cfg) - 1
             WHERE model_name = 'CAP_ALERT_PROBE';
            SELECT COUNT(*), MAX(severity), MAX(value) INTO v_n, v_sev, v_a
              FROM capr_alerts WHERE kind = 'MODEL_HEALTH';
            chk_true('one stale OK model: MODEL_HEALTH INFO, value 1 (got ' || v_n || ' ' || v_sev || ' '
                     || v_a || ')', v_n = 1 AND v_sev = 'INFO' AND v_a = 1);
            UPDATE cap_ml_model SET trained_through = d_last WHERE model_name = 'CAP_ALERT_PROBE';
            SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'MODEL_HEALTH';
            chk_int('one fresh OK model: no MODEL_HEALTH', v_n, 0);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT as_mh; RAISE;
        END;
        ROLLBACK TO SAVEPOINT as_mh;

        DBMS_OUTPUT.PUT_LINE('=== alerts: CPU limit convention + SERIES scored flag ===');
        SELECT COUNT(*) INTO v_n FROM capr_series_points
          WHERE kind = 'CPU'
            AND ((unit = 'pct' AND (limit_value <> v_sat OR pct <> ROUND(100 * value / v_sat, 2)))
              OR (unit <> 'pct' AND (limit_value IS NOT NULL OR pct IS NOT NULL)));
        chk_int('CAPR_SERIES_POINTS CPU: limit_value = cpu_sat_pct, pct = 100 * value / it', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_forecast_points
          WHERE kind = 'CPU' AND method = 'REGR'
            AND ((unit = 'pct' AND (limit_value <> v_sat OR pct <> ROUND(100 * value / v_sat, 2)))
              OR (unit <> 'pct' AND (limit_value IS NOT NULL OR pct IS NOT NULL)));
        chk_int('CAPR_FORECAST_POINTS CPU: limit_value = cpu_sat_pct, pct = 100 * value / it', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_fit
          WHERE kind = 'CPU'
            AND ((unit = 'pct' AND (limit_value <> v_sat OR pct <> ROUND(100 * value / v_sat, 1)))
              OR (unit <> 'pct' AND (limit_value IS NOT NULL OR pct IS NOT NULL)));
        chk_int('CAPR_FIT CPU: limit_value = cpu_sat_pct, pct = 100 * value / it', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_forecast_points p
          JOIN capf_cpu_trend t ON t.dbid = p.dbid AND t.con_dbid = p.con_dbid AND t.metric = p.series
          WHERE p.kind = 'CPU' AND p.method = 'REGR' AND p.horizon_days = 0 AND p.value <> t.anchor_value;
        chk_int('CAPR_FORECAST_POINTS CPU horizon 0 = anchor_value', v_n, 0);
        SELECT value, pct, limit_value INTO v_a, v_b, v_c FROM capr_forecast_points
          WHERE kind = 'CPU' AND method = 'REGR' AND horizon_days = 0
            AND dbid = v_dbid AND con_dbid = v_dbid AND series = 'BUSY_P95';
        chk_true('root BUSY_P95 horizon 0: 58, 72.5% of the 80 line (got ' || v_a || ' ' || v_b || ' '
                 || v_c || ')', v_a = n_p95 AND v_b = ROUND(100 * n_p95 / v_sat, 2) AND v_c = v_sat);
        SELECT COUNT(*), COUNT(anomaly) INTO v_n, v_num FROM capr_series_points
          WHERE kind = 'SERIES' AND series = 'ASM_DG:+DATA';
        chk_true('ASM_DG:+DATA points: anomaly NULL on all ' || v_n || ' (not in CAPA_OBS)', v_n > 0 AND v_num = 0);
        SELECT COUNT(*) INTO v_n FROM capr_series_points
          WHERE kind = 'SERIES' AND anomaly IS NULL
            AND series IN (SELECT series FROM capa_obs WHERE kind = 'SERIES');
        chk_int('SERIES points of CAPA_OBS series all scored (anomaly 0/1)', v_n, 0);
    EXCEPTION
        WHEN OTHERS THEN
            fail('alert-surface block raised ' || SQLERRM);
    END;

    DBMS_OUTPUT.PUT_LINE('=== CAP_CFG: the one config access path ===');
    SELECT COUNT(*) INTO v_n FROM cap_cfg;
    chk_int('CAP_CFG row count', v_n, 1);
    SELECT c.train_days, k.cfg_value INTO v_num, v_num2
      FROM cap_cfg c CROSS JOIN cap_config k WHERE k.cfg_name = 'train_days';
    chk_int('CAP_CFG.train_days = CAP_CONFIG train_days', v_num, v_num2);
    SELECT c.mad_k, k.cfg_value INTO v_num, v_num2
      FROM cap_cfg c CROSS JOIN cap_config k WHERE k.cfg_name = 'mad_k';
    chk_int('CAP_CFG.mad_k = CAP_CONFIG mad_k', v_num, v_num2);
    SELECT c.slope_method, k.cfg_value INTO v_num, v_num2
      FROM cap_cfg c CROSS JOIN cap_config k WHERE k.cfg_name = 'slope_method';
    chk_int('CAP_CFG.slope_method = CAP_CONFIG slope_method', v_num, v_num2);
    SELECT COUNT(*) INTO v_n FROM cap_config k
      WHERE NOT EXISTS (SELECT 1 FROM cap_cfg_check c WHERE c.knob = k.cfg_name);
    chk_int('CAP_CONFIG keys without a CAP_CFG column', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM cap_cfg_check WHERE status <> 'OK';
    chk_int('CAP_CFG_CHECK rows not OK', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM cap_config WHERE cfg_default IS NULL;
    chk_int('CAP_CONFIG rows with no cfg_default', v_n, 0);
    SELECT cfg_value, cfg_default INTO v_num, v_num2
      FROM cap_config WHERE cfg_name = 'mad_k';
    chk_int('mad_k cfg_value (shipped)', v_num, 3);
    chk_int('mad_k cfg_default = cfg_value', v_num2, v_num);

    -- A range rule, then the documented reset (cfg_value = cfg_default).
    UPDATE cap_config SET cfg_value = 1000 WHERE cfg_name = 'recent_days';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'recent_days';
    chk_str('CAP_CFG_CHECK recent_days=1000 > train_days', v_str, 'BAD');
    UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'recent_days';
    COMMIT;
    SELECT status, value INTO v_str, v_num FROM cap_cfg_check WHERE knob = 'recent_days';
    chk_str('CAP_CFG_CHECK recent_days after reset', v_str, 'OK');
    chk_int('recent_days after reset to cfg_default', v_num, 28);

    -- The new knobs' range rules.
    UPDATE cap_config SET cfg_value = 1 WHERE cfg_name = 'cyclic_min_cliffs';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'cyclic_min_cliffs';
    chk_str('CAP_CFG_CHECK cyclic_min_cliffs = 1', v_str, 'BAD');
    UPDATE cap_config SET cfg_value = 3 WHERE cfg_name = 'slope_method';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'slope_method';
    chk_str('CAP_CFG_CHECK slope_method = 3', v_str, 'BAD');
    UPDATE cap_config SET cfg_value = 2 WHERE cfg_name = 'cpu_quality_gate';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'cpu_quality_gate';
    chk_str('CAP_CFG_CHECK cpu_quality_gate = 2', v_str, 'BAD');
    UPDATE cap_config SET cfg_value = 2 WHERE cfg_name = 'cpu_deseason';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'cpu_deseason';
    chk_str('CAP_CFG_CHECK cpu_deseason = 2', v_str, 'BAD');
    UPDATE cap_config SET cfg_value = cfg_default
     WHERE cfg_name IN ('cyclic_min_cliffs', 'slope_method', 'cpu_quality_gate', 'cpu_deseason');
    COMMIT;
    SELECT COUNT(*) INTO v_n FROM cap_cfg_check
      WHERE knob IN ('cyclic_min_cliffs', 'slope_method', 'cpu_quality_gate', 'cpu_deseason') AND status = 'OK';
    chk_int('new knobs OK after reset', v_n, 4);
    -- Zero must not raise ORA-01476 in the views, and the rules grade it.
    UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'mad_k';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'mad_k';
    chk_str('CAP_CFG_CHECK mad_k = 0', v_str, 'BAD');
    SELECT COUNT(*) INTO v_n FROM capa_anom WHERE baseline_mode = 'TRAILING' AND anomaly_flag IS NOT NULL;
    chk_int('mad_k = 0: CAPA_ANOM reads and flags nothing (TRAILING)', v_n, 0);
    UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'accel_slope_floor_bpd';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'accel_slope_floor_bpd';
    chk_str('CAP_CFG_CHECK accel_slope_floor_bpd = 0', v_str, 'OK');
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast WHERE quality = 'FLAT' AND accel_ratio IS NOT NULL;
    chk_int('accel_slope_floor_bpd = 0: FLAT series keep a NULL accel_ratio', v_n, 0);
    UPDATE cap_config SET cfg_value = -1 WHERE cfg_name = 'accel_slope_floor_bpd';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'accel_slope_floor_bpd';
    chk_str('CAP_CFG_CHECK accel_slope_floor_bpd = -1', v_str, 'BAD');
    UPDATE cap_config SET cfg_value = cfg_default
     WHERE cfg_name IN ('mad_k', 'accel_slope_floor_bpd');
    COMMIT;

    -- Results-layer knobs and their range rules.
    SELECT COUNT(*) INTO v_n FROM cap_cfg
      WHERE data_stale_max_days = 14 AND resolve_grace_runs = 2
        AND refresh_stale_hours = 36 AND digest_days = 7;
    chk_int('CAP_CFG results-layer knobs at their shipped values', v_n, 1);
    UPDATE cap_config SET cfg_value = 1   WHERE cfg_name = 'data_stale_max_days';
    UPDATE cap_config SET cfg_value = 0   WHERE cfg_name = 'resolve_grace_runs';
    UPDATE cap_config SET cfg_value = 0   WHERE cfg_name = 'refresh_stale_hours';
    UPDATE cap_config SET cfg_value = 2.5 WHERE cfg_name = 'digest_days';
    SELECT COUNT(*) INTO v_n FROM cap_cfg_check
      WHERE knob IN ('data_stale_max_days', 'resolve_grace_runs', 'refresh_stale_hours', 'digest_days')
        AND status = 'BAD';
    chk_int('CAP_CFG_CHECK BAD: data_stale_max_days 1 (24 h <= stale_hours), grace 0, refresh_stale_hours 0, digest_days 2.5',
            v_n, 4);
    UPDATE cap_config SET cfg_value = cfg_default
     WHERE cfg_name IN ('data_stale_max_days', 'resolve_grace_runs', 'refresh_stale_hours', 'digest_days');
    COMMIT;
    SELECT COUNT(*) INTO v_n FROM cap_cfg_check
      WHERE knob IN ('data_stale_max_days', 'resolve_grace_runs', 'refresh_stale_hours', 'digest_days')
        AND status = 'OK';
    chk_int('results-layer knobs OK after reset', v_n, 4);

    -- suite_version: stamped by every install, BAD when older than this release.
    SELECT suite_version INTO v_num FROM cap_cfg;
    chk_int('suite_version = 26.4', v_num, 26.4);
    UPDATE cap_config SET cfg_value = 24.13 WHERE cfg_name = 'suite_version';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'suite_version';
    chk_str('CAP_CFG_CHECK suite_version=24.13 < 26.4', v_str, 'BAD');
    UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'suite_version';
    COMMIT;

    -- repo_retention_days: 0, or at least the longest window a feature reads
    -- (here the ESM horizon, 4 x 30 = 120 days).
    SELECT status, value INTO v_str, v_num FROM cap_cfg_check WHERE knob = 'repo_retention_days';
    chk_str('CAP_CFG_CHECK repo_retention_days shipped', v_str, 'OK');
    chk_int('repo_retention_days shipped', v_num, 400);
    UPDATE cap_config SET cfg_value = 30 WHERE cfg_name = 'repo_retention_days';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'repo_retention_days';
    chk_str('CAP_CFG_CHECK repo_retention_days = 30 < 120', v_str, 'BAD');
    UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'repo_retention_days';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'repo_retention_days';
    chk_str('CAP_CFG_CHECK repo_retention_days = 0 (keep everything)', v_str, 'OK');
    UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'repo_retention_days';
    COMMIT;

    -- Tier 2 and engine knobs' range rules: BAD below / outside the range,
    -- OK after the reset.
    UPDATE cap_config SET cfg_value = -1 WHERE cfg_name = 'esm_auto_tie_pct';
    UPDATE cap_config SET cfg_value = -1 WHERE cfg_name = 'esm_max_age_days';
    UPDATE cap_config SET cfg_value = 2  WHERE cfg_name = 'anomaly_hour_grain';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'esm_auto_tie_pct';
    chk_str('CAP_CFG_CHECK esm_auto_tie_pct = -1', v_str, 'BAD');
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'esm_max_age_days';
    chk_str('CAP_CFG_CHECK esm_max_age_days = -1', v_str, 'BAD');
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'anomaly_hour_grain';
    chk_str('CAP_CFG_CHECK anomaly_hour_grain = 2', v_str, 'BAD');
    UPDATE cap_config SET cfg_value = cfg_default
     WHERE cfg_name IN ('esm_auto_tie_pct', 'esm_max_age_days', 'anomaly_hour_grain');
    COMMIT;
    SELECT COUNT(*) INTO v_n FROM cap_cfg_check
      WHERE knob IN ('esm_auto_tie_pct', 'esm_max_age_days', 'anomaly_hour_grain') AND status = 'OK';
    chk_int('esm_auto_tie_pct / esm_max_age_days / anomaly_hour_grain OK after reset', v_n, 3);
    SELECT anomaly_hour_grain INTO v_num FROM cap_cfg;
    chk_int('anomaly_hour_grain shipped', v_num, 1);

    -- A deleted key is the silent failure mode: the pivot yields NULL, the
    -- SPIKE threshold goes NULL and the flag disappears without an error.
    DECLARE
        s_val  cap_config.cfg_value%TYPE;
        s_def  cap_config.cfg_default%TYPE;
        s_desc cap_config.cfg_desc%TYPE;
    BEGIN
        SELECT cfg_value, cfg_default, cfg_desc INTO s_val, s_def, s_desc
          FROM cap_config WHERE cfg_name = 'mad_k';
        DELETE FROM cap_config WHERE cfg_name = 'mad_k';
        BEGIN
            SELECT status, value INTO v_str, v_num FROM cap_cfg_check WHERE knob = 'mad_k';
            chk_str ('CAP_CFG_CHECK mad_k after DELETE', v_str, 'MISSING');
            chk_true('CAP_CFG.mad_k is NULL after DELETE', v_num IS NULL);
            SELECT COUNT(*) INTO v_n FROM capa_anom
              WHERE kind = 'TBSPC' AND series = 'FIX_SPIKE' AND anomaly_flag IS NOT NULL;
            chk_int('SPIKE flagged rows (any mode) with mad_k deleted', v_n, 0);
        EXCEPTION
            WHEN OTHERS THEN
                INSERT INTO cap_config (cfg_name, cfg_value, cfg_default, cfg_desc)
                VALUES ('mad_k', s_val, s_def, s_desc);
                COMMIT;
                RAISE;
        END;
        INSERT INTO cap_config (cfg_name, cfg_value, cfg_default, cfg_desc)
        VALUES ('mad_k', s_val, s_def, s_desc);
        COMMIT;
    END;
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'mad_k';
    chk_str('CAP_CFG_CHECK mad_k after re-INSERT', v_str, 'OK');
    chk_str('SPIKE HIGH on spike day after mad_k re-INSERT (TRAILING)',
            anom_flag('TBSPC', 'FIX_SPIKE', 'TRAILING', d_spike, v_dbid), 'HIGH');

    -- ================================================================
    -- Results layer (ddl/60). cap_results.refresh COMMITs, so every knob or
    -- fixture change below is committed and restored in the handler. The
    -- tables survive re-install, so cap_results.reset clears what an earlier
    -- run_test left. Run order:
    --   R0  backdated (as of TRUNC(SYSDATE) - 7) with FIX_LINEAR and
    --       FIX_ZIGZAG's last 7 days hidden: the forecasts "issued a week
    --       ago" that CAPR_FORECAST_ACCURACY scores and the digest compares
    --   R1  every key NEW          R2  no events
    --   R3  dtf_warn 1: FIX_OVERRIDE's TBSPC_FULL missing once (grace)
    --   R4  missing twice: RESOLVED (resolve_grace_runs 2)
    --   R5  dtf_warn back: REOPENED
    --   R6  dtf_crit 80: FIX_OVERRIDE (74 days) ESCALATED to CRIT
    --   R7  dtf_crit back: DEESCALATED      then a FAILED run, purge, R8
    -- ================================================================
    DECLARE
        d_last   DATE   := meta_d('LAST_DAY');
        n_pdb1   NUMBER := meta_n('PDB_CON_DBID');
        n_fit    NUMBER;
        n_state  NUMBER;
        n_rows   NUMBER;
        run_0 NUMBER; run_1 NUMBER; run_2 NUMBER; run_3 NUMBER; run_4 NUMBER;
        run_5 NUMBER; run_6 NUMBER; run_7 NUMBER; run_f NUMBER; run_8 NUMBER;
        v_okey   VARCHAR2(400) := 'TBSPC_FULL|' || v_dbid || '|' || v_dbid || '|FIX_OVERRIDE|-';
        v_skey   VARCHAR2(400) := 'TBSPC_ANOM|' || v_dbid || '|' || v_dbid || '|FIX_SPIKE|TRAILING';
        v_akey   VARCHAR2(400);
        v_old    NUMBER;
        v_a      NUMBER;
        v_b      NUMBER;
        v_c      NUMBER;
        v_d      NUMBER;
        v_dt     DATE;
        v_dt2    DATE;
        v_s1     VARCHAR2(400);
        v_s2     VARCHAR2(400);
        v_first  DATE;
        v_ts     TIMESTAMP;
        TYPE usage_tab IS TABLE OF cap_fixture_tbspc_usage%ROWTYPE;
        v_hidden usage_tab;
        v_restored BOOLEAN := TRUE;

        FUNCTION last_run RETURN NUMBER IS x NUMBER;
        BEGIN SELECT MAX(run_id) INTO x FROM cap_run; RETURN x; END;
        FUNCTION n_ev(p_run NUMBER, p_event VARCHAR2) RETURN NUMBER IS x NUMBER;
        BEGIN
            SELECT COUNT(*) INTO x FROM cap_alert_event
             WHERE run_id = p_run AND event = DECODE(p_event, 'ANY', event, p_event);
            RETURN x;
        END;
        PROCEDURE restore_usage IS
        BEGIN
            IF NOT v_restored THEN
                FORALL i IN 1 .. v_hidden.COUNT
                    INSERT INTO cap_fixture_tbspc_usage VALUES v_hidden(i);
                COMMIT;
                v_restored := TRUE;
            END IF;
        END;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== results layer: empty tables ===');
        cap_results.reset;
        SELECT (SELECT COUNT(*) FROM capr_runs) + (SELECT COUNT(*) FROM capr_alerts_latest)
               + (SELECT COUNT(*) FROM capr_alert_events) + (SELECT COUNT(*) FROM capr_fit_history)
               + (SELECT COUNT(*) FROM capr_weekly_digest) + (SELECT COUNT(*) FROM capr_forecast_accuracy)
          INTO v_n FROM dual;
        chk_int('every results view answers on empty tables (rows)', v_n, 0);
        chk_str('cap_results.deploy_mode', cap_results.deploy_mode, 'fixture');

        DBMS_OUTPUT.PUT_LINE('=== results layer: R0 backdated, R1, R2 ===');
        SELECT u.* BULK COLLECT INTO v_hidden
          FROM cap_fixture_tbspc_usage u
         WHERE u.tablespace_id IN (SELECT tablespace_id FROM cap_fixture_tablespace
                                    WHERE tablespace_name IN ('FIX_LINEAR', 'FIX_ZIGZAG'))
           AND u.snap_id IN (SELECT snap_id FROM cap_fixture_snapshot
                              WHERE TRUNC(end_interval_time) > d_last - 7);
        chk_int('hidden usage rows = 2 tablespaces x 7 days', v_hidden.COUNT, 14);
        v_restored := FALSE;
        DELETE FROM cap_fixture_tbspc_usage u
         WHERE u.tablespace_id IN (SELECT tablespace_id FROM cap_fixture_tablespace
                                    WHERE tablespace_name IN ('FIX_LINEAR', 'FIX_ZIGZAG'))
           AND u.snap_id IN (SELECT snap_id FROM cap_fixture_snapshot
                              WHERE TRUNC(end_interval_time) > d_last - 7);
        COMMIT;
        cap_results.refresh(p_as_of => TRUNC(SYSDATE) - 7);
        run_0 := last_run;
        restore_usage;
        SELECT COUNT(*) INTO n_fit FROM capr_fit;
        cap_results.refresh;
        run_1 := last_run;
        -- A scope an aborted report left behind: the refresh drops it.
        DBMS_APPLICATION_INFO.SET_CLIENT_INFO('AWRCAP dbid=-1');
        cap_results.refresh;
        run_2 := last_run;
        SELECT scope_dbid INTO v_a FROM cap_scope;
        chk_true('cap_results.refresh clears a scope it finds', v_a IS NULL);
        SELECT COUNT(*) INTO v_a FROM cap_fit_hist WHERE run_id = run_2;
        chk_int('the refresh after it kept every fit', v_a, n_fit);

        SELECT COUNT(*), COUNT(CASE WHEN status = 'OK' THEN 1 END), COUNT(CASE WHEN backdated = 'Y' THEN 1 END)
          INTO v_n, v_a, v_b FROM cap_run;
        chk_true('3 CAP_RUN rows, all OK, one backdated (got ' || v_n || '/' || v_a || '/' || v_b || ')',
                 v_n = 3 AND v_a = 3 AND v_b = 1);
        chk_true('run_id grows: R0 < R1 < R2', run_0 < run_1 AND run_1 < run_2);
        -- Refreshes are serialised for their whole lifetime (lock before run_id
        -- allocation), so run_id order is commit order: no pair of runs, and
        -- no pair of events, is ordered one way by run_id and the other by time.
        SELECT COUNT(*) INTO v_n
          FROM cap_run a JOIN cap_run b ON a.run_id < b.run_id AND a.started_at > b.started_at;
        chk_int ('run_id order = started_at order (inverted CAP_RUN pairs)', v_n, 0);
        SELECT COUNT(*) INTO v_n
          FROM cap_alert_event a JOIN cap_alert_event b ON a.run_id < b.run_id AND a.at_time > b.at_time;
        chk_int ('run_id order = at_time order for CAP_ALERT_EVENT (inverted event pairs)', v_n, 0);
        SELECT as_of_day, backdated, n_alert, n_event, deploy_mode, n_fit INTO v_dt, v_c1, v_a, v_b, v_str, v_c
          FROM cap_run WHERE run_id = run_0;
        chk_true('R0: as_of_day TRUNC(SYSDATE) - 7, backdated Y, no alert state (n_alert, n_event NULL), seam fixture (got '
                 || TO_CHAR(v_dt, 'YYYY-MM-DD') || ' ' || v_c1 || ' ' || NVL(TO_CHAR(v_a), 'NULL') || ' ' || v_str || ')',
                 v_dt = TRUNC(SYSDATE) - 7 AND v_c1 = 'Y' AND v_a IS NULL AND v_b IS NULL AND v_str = 'fixture');
        chk_int ('R0 n_fit = CAPR_FIT rows', v_c, n_fit);
        SELECT COUNT(*) INTO v_n FROM cap_fit_hist WHERE run_id = run_1;
        chk_int ('R1 CAP_FIT_HIST rows = CAPR_FIT rows', v_n, n_fit);
        SELECT COUNT(*) INTO v_n FROM cap_fit_hist;
        chk_int ('CAP_FIT_HIST rows = 3 runs x CAPR_FIT rows', v_n, 3 * n_fit);
        SELECT COUNT(*) INTO v_n FROM capr_fit_history;
        chk_int ('CAPR_FIT_HISTORY rows = 3 runs x CAPR_FIT rows', v_n, 3 * n_fit);
        SELECT COUNT(*) INTO v_n FROM cap_fit_hist h JOIN capr_fit f
            ON f.kind = h.kind AND f.dbid = h.dbid AND f.con_dbid = h.con_dbid AND f.series = h.series
         WHERE h.run_id = run_2
           AND (DECODE(h.value, f.value, 0, 1) + DECODE(h.days_to_full, f.days_to_full, 0, 1)
                + DECODE(h.quality, f.quality, 0, 1) + DECODE(h.sev, f.sev, 0, 1)
                + DECODE(h.last_day, f.last_day, 0, 1) + DECODE(h.add_by_day, f.add_by_day, 0, 1)) > 0;
        chk_int ('R2 snapshot = CAPR_FIT now (value, days_to_full, quality, sev, last_day, add_by_day mismatches)', v_n, 0);
        SELECT COUNT(CASE WHEN DECODE(h.restart_reason, f.restart_reason, 0, 1)
                             + DECODE(h.restart_day, f.restart_day, 0, 1) > 0 THEN 1 END),
               COUNT(CASE WHEN h.restart_reason IN ('STOP', 'START') THEN 1 END)
          INTO v_n, v_num
          FROM cap_fit_hist h JOIN capr_fit f
            ON f.kind = h.kind AND f.dbid = h.dbid AND f.con_dbid = h.con_dbid AND f.series = h.series
         WHERE h.run_id = run_2;
        chk_int ('R2 snapshot restart_reason / restart_day mismatches', v_n, 0);
        chk_int ('R2 snapshot rows with restart STOP / START', v_num, 2);
        -- Every run keeps CAPR_COVERAGE on its CAP_RUN row (the backdated one
        -- too): the fixture is one current dbid. R1 and R2 ran on the restored
        -- data, so their summary is the view's now.
        SELECT COUNT(CASE WHEN cov_n_dbid = 1 AND cov_n_current = 1 THEN 1 END),
               COUNT(CASE WHEN run_id IN (run_1, run_2)
                           AND cov_summary = (SELECT summary FROM capr_coverage) THEN 1 END)
          INTO v_a, v_b FROM cap_run;
        chk_true('CAP_RUN coverage: cov_n_dbid 1 and cov_n_current 1 on all 3 runs, cov_summary = CAPR_COVERAGE.summary on R1, R2 (got '
                 || v_a || ' / ' || v_b || ')', v_a = 3 AND v_b = 2);
        SELECT COUNT(*) INTO v_n FROM capr_runs r JOIN cap_run c ON c.run_id = r.run_id
         WHERE r.cov_summary = c.cov_summary AND r.cov_n_dbid = c.cov_n_dbid AND r.cov_n_current = c.cov_n_current;
        chk_int ('CAPR_RUNS exposes the coverage columns of every run', v_n, 3);

        -- SNAPSHOT tables: each <view>_S holds the newest OK run's rows,
        -- equal to the view now (both MINUS directions and the row count),
        -- and build_snap_tables leaves them empty. Dynamic SQL: the tables
        -- are dropped and re-created inside this block. NUMBER columns are
        -- compared at 12 decimals: two plans of one view (the INSERT's and
        -- this SELECT's) can differ in the 38th digit (CAPR_FORECAST_POINTS'
        -- CPU REGR knots, 19.27). The clock columns (SYSDATE minus a stored
        -- time, as test/parity_fingerprint.sql skips them) are left out:
        -- CAPR_COVERAGE.age_hours moves 0.1 every 6 minutes after the refresh.
        DECLARE
            l_views SYS.ODCIVARCHAR2LIST := cap_results.snap_views;
            l_cols  VARCHAR2(32767);
            l_lo    NUMBER;
            l_hi    NUMBER;
            l_nv    NUMBER;
            l_ns    NUMBER;
            l_diff  NUMBER;
            l_left  NUMBER := 0;
        BEGIN
            FOR i IN 1 .. l_views.COUNT LOOP
                SELECT LISTAGG(CASE data_type WHEN 'NUMBER' THEN 'ROUND("' || column_name || '", 12)'
                                              ELSE '"' || column_name || '"' END, ', ')
                         WITHIN GROUP (ORDER BY column_id)
                  INTO l_cols
                  FROM all_tab_columns
                 WHERE owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') AND table_name = l_views(i)
                   AND column_name NOT IN ('AGE_HOURS', 'AGE_DAYS', 'LAST_OK_AGE_HOURS');
                EXECUTE IMMEDIATE 'SELECT MIN(snap_run_id), MAX(snap_run_id), COUNT(*) FROM ' || l_views(i) || '_S'
                    INTO l_lo, l_hi, l_ns;
                EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || l_views(i) INTO l_nv;
                EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ((SELECT ' || l_cols || ' FROM ' || l_views(i)
                                  || ' MINUS SELECT ' || l_cols || ' FROM ' || l_views(i) || '_S) UNION ALL (SELECT '
                                  || l_cols || ' FROM ' || l_views(i) || '_S MINUS SELECT ' || l_cols || ' FROM '
                                  || l_views(i) || '))'
                    INTO l_diff;
                chk_true(l_views(i) || '_S = the view, all rows from R2 (rows ' || l_ns || ' of ' || l_nv
                         || ', runs ' || l_lo || '..' || l_hi || ', rows in one MINUS ' || l_diff || ')',
                         l_ns = l_nv AND l_diff = 0 AND (l_ns = 0 OR (l_lo = run_2 AND l_hi = run_2)));
            END LOOP;
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM capr_fit_s' INTO v_n;
            chk_true('the registry carries rows (CAPR_FIT_S not empty)', v_n > 0);
            cap_results.build_snap_tables;
            FOR i IN 1 .. l_views.COUNT LOOP
                EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || l_views(i) || '_S' INTO l_ns;
                l_left := l_left + l_ns;
            END LOOP;
            chk_int('build_snap_tables leaves every <view>_S empty (rows)', l_left, 0);
        END;

        -- The fixture's alerts: TBSPC_FULL 2 (FILLING, OVERRIDE), TBSPC_NEARFULL
        -- 2 (NEARFULL, OVERFULL), SERIES_LIMIT 2 (SESSIONS, ASM_DG:+DATA),
        -- SERIES_NEARLIMIT 1 (TEMP_PEAK), DBCPU_HOT 1 (FIXPDB2), CPU_SHIFT 1,
        -- and 5 anomaly rows: TBSPC_ANOM 2 (spike, FIX_GAP burst), CPU_ANOM 1,
        -- DBCPU_ANOM 1 (the step episode), SERIES_ANOM 1. One row per key.
        SELECT COUNT(*), COUNT(DISTINCT state_key), COUNT(DISTINCT alert_key),
               COUNT(CASE WHEN kind IN ('TBSPC_ANOM', 'CPU_ANOM', 'DBCPU_ANOM', 'SERIES_ANOM') THEN 1 END)
          INTO n_rows, n_state, v_n, v_a FROM capr_alerts;
        chk_true('CAPR_ALERTS: 14 rows, 14 state_keys, 14 alert_keys, 5 anomaly rows (got ' || n_rows || '/'
                 || n_state || '/' || v_n || '/' || v_a || ')',
                 n_rows = 14 AND n_state = 14 AND v_n = 14 AND v_a = 5);
        SELECT COUNT(*), COUNT(CASE WHEN state = 'OPEN' THEN 1 END) INTO v_a, v_b FROM cap_alert_state;
        chk_true('CAP_ALERT_STATE = the distinct CAPR_ALERTS state_keys, every one OPEN (got ' || v_a || '/' || v_b || ')',
                 v_a = n_state AND v_b = n_state);
        SELECT COUNT(*) INTO v_n FROM cap_alert_state s
         WHERE NOT EXISTS (SELECT 1 FROM capr_alerts a
                            WHERE a.state_key = s.state_key AND a.alert_key = s.last_alert_key
                              AND a.severity = s.cur_severity AND a.severity = s.max_severity
                              AND a.message = s.last_message AND a.value = s.last_value)
            OR s.first_seen > s.last_seen OR s.reopen_count <> 0 OR s.missed_runs <> 0 OR s.last_run_id <> run_2;
        chk_int ('every state carries its live row (alert_key, severity, message, value), seen by R2', v_n, 0);
        chk_int ('R1 NEW events = the state count', n_ev(run_1, 'NEW'), n_state);
        chk_int ('R1 events in total (NEW only)', n_ev(run_1, 'ANY'), n_state);
        chk_int ('R2 NEW events', n_ev(run_2, 'NEW'), 0);
        chk_int ('R2 events in total (nothing changed)', n_ev(run_2, 'ANY'), 0);
        chk_int ('R0 events (backdated: no alert state)', n_ev(run_0, 'ANY'), 0);
        SELECT n_alert, n_anom, n_event INTO v_a, v_b, v_c FROM cap_run WHERE run_id = run_1;
        chk_true('R1 n_alert 14, n_anom 5, n_event 14 (got ' || v_a || '/' || v_b || '/' || v_c || ')',
                 v_a = 14 AND v_b = 5 AND v_c = 14);
        SELECT COUNT(*) INTO v_n FROM cap_alert_event
         WHERE run_id = run_1 AND event_id NOT BETWEEN run_1 * 100000 + 1 AND run_1 * 100000 + n_state;
        chk_int ('R1 event_id = run_id * 100000 + 1 .. n', v_n, 0);

        SELECT COUNT(*), MAX(CASE WHEN is_last = 'Y' THEN run_id END), MAX(last_ok_run_id), MAX(stale_run),
               MAX(CASE WHEN is_last = 'Y' THEN summary END), MAX(CASE WHEN run_id = run_0 THEN summary END)
          INTO v_n, v_a, v_b, v_c1, v_s1, v_s2 FROM capr_runs;
        chk_true('CAPR_RUNS: 3 rows, is_last = R2, last_ok_run_id = R2, stale_run N (got ' || v_n || ' '
                 || v_a || ' ' || v_b || ' ' || v_c1 || ')', v_n = 3 AND v_a = run_2 AND v_b = run_2 AND v_c1 = 'N');
        chk_true('CAPR_RUNS summary "refresh run <R2> at <time> (14 alerts, <n> fits)" (got: ' || v_s1 || ')',
                 v_s1 LIKE 'refresh run ' || run_2 || ' at % (14 alerts, ' || n_fit || ' fits)');
        chk_true('CAPR_RUNS R0 summary says backdated (got: ' || v_s2 || ')',
                 v_s2 LIKE '% (backdated as of ' || TO_CHAR(TRUNC(SYSDATE) - 7, 'YYYY-MM-DD') || ', ' || n_fit
                           || ' fits, no alert state)');

        SELECT COUNT(*), MIN(events_since), MAX(events_since), MIN(last_event), MAX(last_event),
               COUNT(CASE WHEN last_seen < first_seen OR age_days < 0 THEN 1 END)
          INTO v_n, v_a, v_b, v_s1, v_s2, v_c FROM capr_alerts_latest;
        chk_true('CAPR_ALERTS_LATEST: every OPEN state, events_since 1 (NEW), last_event NEW (got ' || v_n || ' '
                 || v_a || '..' || v_b || ' ' || v_s1 || '/' || v_s2 || ')',
                 v_n = n_state AND v_a = 1 AND v_b = 1 AND v_s1 = 'NEW' AND v_s2 = 'NEW' AND v_c = 0);
        SELECT COUNT(*) INTO v_n
          FROM capr_alerts_latest l
          FULL OUTER JOIN capr_alerts a ON a.state_key = l.state_key
         WHERE l.state_key IS NULL OR a.state_key IS NULL
            OR l.severity <> a.severity OR l.sev_rank <> a.sev_rank OR l.kind <> a.kind
            OR l.db_pdb <> a.db_pdb OR l.day_dt <> a.day_dt OR l.value <> a.value
            OR l.threshold <> a.threshold OR l.unit <> a.unit OR l.message <> a.message
            OR l.alert_key <> a.alert_key OR l.direction <> a.direction
            OR l.alarm_threshold <> a.alarm_threshold;
        chk_int ('CAPR_ALERTS_LATEST = CAPR_ALERTS column for column after R2 (mismatches)', v_n, 0);
        SELECT COUNT(*), COUNT(CASE WHEN run_id = run_1 AND as_of_day = TRUNC(SYSDATE) AND event = 'NEW'
                                     AND prev_severity IS NULL AND kind IS NOT NULL THEN 1 END)
          INTO v_n, v_a FROM capr_alert_events;
        chk_true('CAPR_ALERT_EVENTS: the R1 NEW events, as_of_day today, kind resolved (got ' || v_n || '/' || v_a || ')',
                 v_n = n_state AND v_a = n_state);

        DBMS_OUTPUT.PUT_LINE('=== results layer: CAPR_WEEKLY_DIGEST (R2 vs R0) ===');
        SELECT COUNT(*), MIN(run_then), MIN(run_now), SUM(n_new), SUM(n_resolved), SUM(n_reopened), SUM(n_sev_changes)
          INTO v_n, v_a, v_b, v_c, v_d, v_num, v_num2 FROM capr_weekly_digest;
        chk_true('digest: one row per series, R0 vs R2 (got ' || v_n || ' rows, ' || v_a || ' vs ' || v_b || ')',
                 v_n = n_fit AND v_a = run_0 AND v_b = run_2);
        chk_true('digest: NEW = the state count, nothing resolved / reopened / re-graded (got ' || v_c || '/' || v_d
                 || '/' || v_num || '/' || v_num2 || ')',
                 v_c = n_state AND v_d = 0 AND v_num = 0 AND v_num2 = 0);
        SELECT dtf_then, dtf_now, dtf_delta, pct_then, pct_now, change
          INTO v_a, v_b, v_c, v_num, v_num2, v_str FROM capr_weekly_digest
         WHERE kind = 'TBSPC' AND series = 'FIX_LINEAR';
        chk_true('digest FIX_LINEAR: days_to_full LINEAR_DTF7 then, LINEAR_DTF now, delta -7, SAME (got '
                 || v_a || ' ' || v_b || ' ' || v_c || ' ' || v_str || ')',
                 v_a = meta_n('LINEAR_DTF7') AND v_b = n_dtf AND v_c = -7 AND v_str = 'SAME');
        chk_true('digest FIX_LINEAR: pct then / now = ROUND(100 * used / limit, 1) (got ' || v_num || ' / ' || v_num2 || ')',
                 v_num  = ROUND(100 * (meta_n('LINEAR_CUR') - 7 * n_slope) / meta_n('LINEAR_LIMIT'), 1)
                 AND v_num2 = ROUND(100 * meta_n('LINEAR_CUR') / meta_n('LINEAR_LIMIT'), 1));
        SELECT COUNT(*) INTO v_n FROM capr_weekly_digest
         WHERE NVL(dtf_delta, 0) <> 0
           AND NOT ((kind = 'TBSPC' AND series IN ('FIX_LINEAR', 'FIX_ZIGZAG'))
                    OR (kind = 'SERIES' AND series = 'DB_SIZE_GB'));
        chk_int ('digest: dtf_delta 0 on every series the hidden days do not touch', v_n, 0);
        SELECT n_new, events INTO v_a, v_s1 FROM capr_weekly_digest WHERE kind = 'TBSPC' AND series = 'FIX_GAP';
        chk_true('digest FIX_GAP: "TBSPC_ANOM NEW 1" (got ' || v_a || ' ' || v_s1 || ')',
                 v_a = 1 AND v_s1 = 'TBSPC_ANOM NEW 1');
        SELECT n_new, events INTO v_a, v_s1 FROM capr_weekly_digest
         WHERE kind = 'CPU' AND con_dbid = n_pdb1 AND series = 'DB_CPU_PCT';
        chk_true('digest FIXPDB1 DB_CPU_PCT: "CPU_SHIFT NEW 1, DBCPU_ANOM NEW 1" (got ' || v_a || ' ' || v_s1 || ')',
                 v_a = 2 AND v_s1 = 'CPU_SHIFT NEW 1, DBCPU_ANOM NEW 1');

        DBMS_OUTPUT.PUT_LINE('=== results layer: CAPR_FORECAST_ACCURACY (R0 forecasts vs today) ===');
        SELECT COUNT(*), MIN(run_id), MAX(run_id), MIN(elapsed_days), MAX(elapsed_days)
          INTO v_n, v_a, v_b, v_c, v_d FROM capr_forecast_accuracy;
        chk_true('accuracy: 2 rows (FIX_LINEAR, FIX_ZIGZAG of R0), elapsed 7 days (got ' || v_n || ' ' || v_c || '..' || v_d || ')',
                 v_n = 2 AND v_a = run_0 AND v_b = run_0 AND v_c = 7 AND v_d = 7);
        SELECT projected, actual, error INTO v_a, v_b, v_c FROM capr_forecast_accuracy WHERE series = 'FIX_LINEAR';
        chk_true('accuracy FIX_LINEAR: error 0 (perfectly linear), projected = actual = LINEAR_CUR (got error '
                 || v_c || ')', ABS(v_c) < 1 AND ABS(v_b - meta_n('LINEAR_CUR')) < 1);
        SELECT value_then, slope_then, error, error_pct INTO v_a, v_b, v_c, v_d
          FROM capr_forecast_accuracy WHERE series = 'FIX_ZIGZAG';
        chk_close('accuracy FIX_ZIGZAG value_then = zz(LAST - 7)', v_a, (12800 + 1280 * 113 - 2560) * 8192, 0.000001);
        chk_close('accuracy FIX_ZIGZAG slope_then = OLS on i 24..113', v_b, meta_n('ZZ_ACC7_SLOPE'), 0.000001);
        chk_close('accuracy FIX_ZIGZAG error = zz(LAST) - (zz(LAST - 7) + 7 * slope_then)', v_c, meta_n('ZZ_ACC7_ERR'), 0.000001);
        chk_true ('accuracy FIX_ZIGZAG error non-zero (got ' || v_c || ', ' || v_d || '%)', ABS(v_c) > 1000000);

        DBMS_OUTPUT.PUT_LINE('=== results layer: resolve (grace), reopen ===');
        SELECT cfg_value INTO v_old FROM cap_config WHERE cfg_name = 'dtf_warn';
        knob('dtf_warn', 1);
        COMMIT;
        BEGIN
            SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE state_key = v_okey;
            chk_int('dtf_warn 1: FIX_OVERRIDE TBSPC_FULL (74 days, global thresholds) leaves CAPR_ALERTS', v_n, 0);
            cap_results.refresh;
            run_3 := last_run;
            SELECT state, missed_runs INTO v_str, v_a FROM cap_alert_state WHERE state_key = v_okey;
            chk_true('R3 (missing once, grace 2): still OPEN, missed_runs 1 (got ' || v_str || ' ' || v_a || ')',
                     v_str = 'OPEN' AND v_a = 1);
            chk_int ('R3 events (none: inside the grace)', n_ev(run_3, 'ANY'), 0);
            SELECT COUNT(*) INTO v_n FROM capr_alerts_latest WHERE state_key = v_okey;
            chk_int ('R3: CAPR_ALERTS_LATEST still lists it', v_n, 1);
            cap_results.refresh;
            run_4 := last_run;
            SELECT state, missed_runs, resolved_at INTO v_str, v_a, v_dt FROM cap_alert_state WHERE state_key = v_okey;
            chk_true('R4 (missing twice): RESOLVED, missed_runs 2, resolved_at set (got ' || v_str || ' ' || v_a || ')',
                     v_str = 'RESOLVED' AND v_a = 2 AND v_dt IS NOT NULL);
            SELECT COUNT(*), MAX(event), MAX(state_key), MAX(message) INTO v_n, v_s1, v_s2, v_msg
              FROM cap_alert_event WHERE run_id = run_4;
            chk_true('R4: one event, RESOLVED, for FIX_OVERRIDE (got ' || v_n || ' ' || v_s1 || ' ' || v_s2 || ')',
                     v_n = 1 AND v_s1 = 'RESOLVED' AND v_s2 = v_okey);
            chk_true('R4: RESOLVED message (got: ' || v_msg || ')',
                     v_msg LIKE 'Resolved: missing from 2 consecutive refresh runs, last seen %');
            SELECT COUNT(*) INTO v_n FROM capr_alerts_latest WHERE state_key = v_okey;
            chk_int ('R4: CAPR_ALERTS_LATEST drops it', v_n, 0);
        EXCEPTION
            WHEN OTHERS THEN knob('dtf_warn', v_old); COMMIT; RAISE;
        END;
        knob('dtf_warn', v_old);
        COMMIT;
        SELECT first_seen INTO v_first FROM cap_alert_state WHERE state_key = v_okey;
        cap_results.refresh;
        run_5 := last_run;
        SELECT state, reopen_count, missed_runs, resolved_at, first_seen, cur_severity
          INTO v_str, v_a, v_b, v_dt, v_dt2, v_s1 FROM cap_alert_state WHERE state_key = v_okey;
        chk_true('R5 (dtf_warn back): OPEN again, reopen_count 1, missed_runs 0, resolved_at NULL, first_seen kept, WARN (got '
                 || v_str || ' ' || v_a || ' ' || v_b || ' ' || v_s1 || ')',
                 v_str = 'OPEN' AND v_a = 1 AND v_b = 0 AND v_dt IS NULL AND v_dt2 = v_first AND v_s1 = 'WARN');
        SELECT COUNT(*), MAX(event), MAX(state_key) INTO v_n, v_s1, v_s2 FROM cap_alert_event WHERE run_id = run_5;
        chk_true('R5: one event, REOPENED, for FIX_OVERRIDE (got ' || v_n || ' ' || v_s1 || ')',
                 v_n = 1 AND v_s1 = 'REOPENED' AND v_s2 = v_okey);
        SELECT events_since, last_event INTO v_a, v_s1 FROM capr_alerts_latest WHERE state_key = v_okey;
        chk_true('CAPR_ALERTS_LATEST events_since counts from the REOPENED (got ' || v_a || ' ' || v_s1 || ')',
                 v_a = 1 AND v_s1 = 'REOPENED');

        DBMS_OUTPUT.PUT_LINE('=== results layer: ack / unack ===');
        cap_results.ack(v_skey, TRUNC(SYSDATE) + 1, 'known spike');
        SELECT COUNT(*) INTO v_n FROM capr_alerts_latest WHERE state_key = v_skey;
        chk_int ('ack FIX_SPIKE TBSPC_ANOM until tomorrow: absent from CAPR_ALERTS_LATEST', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE state_key = v_skey;
        chk_int ('ack: still present in the live CAPR_ALERTS', v_n, 1);
        SELECT ack_until, ack_note, ack_by INTO v_dt, v_s1, v_s2 FROM cap_alert_state WHERE state_key = v_skey;
        chk_true('ack: ack_until tomorrow, note, ack_by = SESSION_USER (got ' || v_s2 || ')',
                 v_dt = TRUNC(SYSDATE) + 1 AND v_s1 = 'known spike' AND v_s2 = SYS_CONTEXT('USERENV', 'SESSION_USER'));
        cap_results.unack(v_skey);
        SELECT COUNT(*) INTO v_n FROM capr_alerts_latest WHERE state_key = v_skey;
        chk_int ('unack: back in CAPR_ALERTS_LATEST', v_n, 1);
        SELECT last_alert_key INTO v_akey FROM cap_alert_state WHERE state_key = v_okey;
        cap_results.ack(v_akey);
        SELECT ack_until INTO v_dt FROM cap_alert_state WHERE state_key = v_okey;
        chk_true('ack by alert_key, no p_until: acked until it resolves (9999-12-31)', v_dt = DATE '9999-12-31');
        BEGIN
            cap_results.ack('NO|SUCH|KEY');
            fail('ack of an unknown key raises ORA-20072');
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLCODE = -20072 THEN pass('ack of an unknown key raises ORA-20072'); ELSE RAISE; END IF;
        END;

        DBMS_OUTPUT.PUT_LINE('=== results layer: escalate / de-escalate ===');
        SELECT cfg_value INTO v_old FROM cap_config WHERE cfg_name = 'dtf_crit';
        knob('dtf_crit', 80);
        COMMIT;
        BEGIN
            cap_results.refresh;
            run_6 := last_run;
            SELECT COUNT(*), MAX(event), MAX(state_key), MAX(severity), MAX(prev_severity)
              INTO v_n, v_s1, v_s2, v_str, v_str2 FROM cap_alert_event WHERE run_id = run_6;
            chk_true('R6 (dtf_crit 80): one event, ESCALATED WARN -> CRIT, FIX_OVERRIDE (got ' || v_n || ' ' || v_s1
                     || ' ' || v_str2 || '->' || v_str || ')',
                     v_n = 1 AND v_s1 = 'ESCALATED' AND v_s2 = v_okey AND v_str = 'CRIT' AND v_str2 = 'WARN');
            SELECT max_severity, ack_until INTO v_s1, v_dt FROM cap_alert_state WHERE state_key = v_okey;
            chk_true('R6: max_severity CRIT, the escalation cleared the ack', v_s1 = 'CRIT' AND v_dt IS NULL);
            SELECT COUNT(*) INTO v_n FROM capr_alerts_latest WHERE state_key = v_okey AND severity = 'CRIT';
            chk_int ('R6: CAPR_ALERTS_LATEST lists it again, CRIT', v_n, 1);
        EXCEPTION
            WHEN OTHERS THEN knob('dtf_crit', v_old); COMMIT; RAISE;
        END;
        knob('dtf_crit', v_old);
        COMMIT;
        cap_results.refresh;
        run_7 := last_run;
        SELECT COUNT(*), MAX(event), MAX(severity), MAX(prev_severity)
          INTO v_n, v_s1, v_str, v_str2 FROM cap_alert_event WHERE run_id = run_7;
        chk_true('R7 (dtf_crit back): one event, DEESCALATED CRIT -> WARN (got ' || v_n || ' ' || v_s1 || ')',
                 v_n = 1 AND v_s1 = 'DEESCALATED' AND v_str = 'WARN' AND v_str2 = 'CRIT');
        SELECT cur_severity, max_severity INTO v_s1, v_s2 FROM cap_alert_state WHERE state_key = v_okey;
        chk_true('R7: cur_severity WARN, max_severity stays CRIT', v_s1 = 'WARN' AND v_s2 = 'CRIT');

        DBMS_OUTPUT.PUT_LINE('=== results layer: FAILED run, stale_run, purge ===');
        BEGIN
            cap_results.refresh(p_as_of => TRUNC(SYSDATE) + 1);
            fail('refresh with p_as_of tomorrow raises ORA-20071');
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLCODE = -20071 THEN pass('refresh with p_as_of tomorrow raises ORA-20071'); ELSE RAISE; END IF;
        END;
        run_f := last_run;
        SELECT status, error_text, ended_at INTO v_str, v_msg, v_ts FROM cap_run WHERE run_id = run_f;
        chk_true('the failed run: status FAILED, error_text has ORA-20071, ended_at set (got ' || v_str || ')',
                 v_str = 'FAILED' AND v_msg LIKE '%ORA-20071%' AND v_ts IS NOT NULL);
        SELECT COUNT(*) INTO v_n FROM cap_fit_hist WHERE run_id = run_f;
        chk_int ('the failed run left no fit rows (rolled back)', v_n, 0);
        EXECUTE IMMEDIATE 'SELECT MIN(snap_run_id), MAX(snap_run_id) FROM capr_container_s' INTO v_a, v_b;
        chk_true('the failed run left the SNAPSHOT tables on R7 (got ' || v_a || '..' || v_b || ')',
                 v_a = run_7 AND v_b = run_7);
        SELECT MAX(CASE WHEN is_last = 'Y' THEN summary END), MAX(last_ok_run_id), MAX(stale_run)
          INTO v_msg, v_a, v_c1 FROM capr_runs;
        chk_true('CAPR_RUNS: the newest run reads FAILED, last_ok_run_id = R7, stale_run N (got: ' || v_msg || ')',
                 v_msg LIKE 'refresh run ' || run_f || ' at % FAILED: ORA-20071%' AND v_a = run_7 AND v_c1 = 'N');
        -- A stalled job: R7 (the newest OK live run) ended 48 h ago, past
        -- refresh_stale_hours (36). Rolled back.
        SAVEPOINT as_runstale;
        UPDATE cap_run SET ended_at = ended_at - INTERVAL '2' DAY WHERE run_id = run_7;
        SELECT MAX(stale_run), MAX(last_ok_age_hours) INTO v_c1, v_a FROM capr_runs;
        chk_true('R7 ended 48 h ago: stale_run Y, last_ok_age_hours >= 48 (got ' || v_c1 || ' ' || v_a || ')',
                 v_c1 = 'Y' AND v_a >= 48);
        ROLLBACK TO SAVEPOINT as_runstale;

        SELECT COUNT(*) INTO n_rows FROM cap_alert_event WHERE run_id = run_7;
        cap_results.purge(0);
        SELECT COUNT(*), MIN(run_id), MAX(run_id) INTO v_n, v_a, v_b FROM cap_run;
        chk_true('purge(0) keeps the newest run (the FAILED one) and the newest OK live run (R7) (got ' || v_n || ')',
                 v_n = 2 AND v_a = run_7 AND v_b = run_f);
        SELECT COUNT(*), MIN(run_id) INTO v_n, v_a FROM cap_fit_hist;
        chk_true('purge(0): only R7''s fit rows left', v_n = n_fit AND v_a = run_7);
        SELECT COUNT(*) INTO v_n FROM cap_alert_event;
        chk_int ('purge(0): only R7''s events left', v_n, n_rows);
        SELECT COUNT(*) INTO v_n FROM cap_alert_state;
        chk_int ('purge(0): every state stays (none resolved)', v_n, n_state);

        -- End on an OK run so the reports show the last-run line.
        cap_results.refresh;
        run_8 := last_run;
        SELECT status, n_event INTO v_str, v_a FROM cap_run WHERE run_id = run_8;
        chk_true('R8: OK, no events', v_str = 'OK' AND v_a = 0);
    EXCEPTION
        WHEN OTHERS THEN
            restore_usage;
            fail('results-layer block raised ' || SQLERRM || ' ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    END;

    -- CAPR_SEGMENT_GROWTH: FIX_FILLING's three segments take 7 / 2 / 1 MiB
    -- of its 10 MiB a day, FIX_LINEAR's one segment all 10 MiB, on every
    -- day; the seg_window_days window holds 28 of those days, so the
    -- shares are 70 / 20 / 10 and 100, and used growth is half the bytes.
    DECLARE
        d_last DATE := meta_d('LAST_DAY');
        PROCEDURE seg_chk(p_ts VARCHAR2, p_obj VARCHAR2, p_rank NUMBER, p_pct NUMBER, p_bytes NUMBER) IS
            v_b NUMBER; v_u NUMBER; v_p NUMBER; v_r NUMBER; v_ns NUMBER;
            v_from DATE; v_to DATE; v_db VARCHAR2(200);
        BEGIN
            SELECT grown_bytes, used_grown_bytes, share_pct, rank_in_tbspc, n_snaps,
                   window_from, window_to, db_pdb
              INTO v_b, v_u, v_p, v_r, v_ns, v_from, v_to, v_db
              FROM capr_segment_growth
             WHERE dbid = v_dbid AND con_dbid = v_dbid
               AND tablespace_name = p_ts AND owner = 'APP' AND object_name = p_obj;
            chk_int('CAPR_SEGMENT_GROWTH ' || p_obj || ' grown_bytes', v_b, p_bytes);
            chk_int('CAPR_SEGMENT_GROWTH ' || p_obj || ' used_grown_bytes', v_u, p_bytes / 2);
            chk_close('CAPR_SEGMENT_GROWTH ' || p_obj || ' share_pct', v_p, p_pct, 1e-9);
            chk_int('CAPR_SEGMENT_GROWTH ' || p_obj || ' rank_in_tbspc', v_r, p_rank);
            chk_int('CAPR_SEGMENT_GROWTH ' || p_obj || ' n_snaps', v_ns, meta_n('SEG_WINDOW_DAYS'));
            chk_true('CAPR_SEGMENT_GROWTH ' || p_obj || ' window = last 28 days',
                     v_from = d_last - meta_n('SEG_WINDOW_DAYS') + 1 AND v_to = d_last);
            chk_str('CAPR_SEGMENT_GROWTH ' || p_obj || ' db_pdb', v_db, 'FIXCDB');
        END;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== CAPR_SEGMENT_GROWTH (who is filling it) ===');
        SELECT seg_window_days INTO v_num FROM cap_cfg;
        chk_int('seg_window_days (shipped)', v_num, meta_n('SEG_WINDOW_DAYS'));
        SELECT COUNT(*) INTO v_n FROM capr_segment_growth
          WHERE dbid = v_dbid AND tablespace_name = 'FIX_FILLING';
        chk_int('CAPR_SEGMENT_GROWTH FIX_FILLING segments', v_n, 3);
        seg_chk('FIX_FILLING', 'ORDERS',    1, 70,  meta_n('SEG_ORDERS_BYTES'));
        seg_chk('FIX_FILLING', 'ORDERS_PK', 2, 20,  meta_n('SEG_ORDERS_PK_BYTES'));
        seg_chk('FIX_FILLING', 'EVENTS',    3, 10,  meta_n('SEG_EVENTS_BYTES'));
        seg_chk('FIX_LINEAR',  'LEDGER',    1, 100, meta_n('SEG_LEDGER_BYTES'));
        SELECT subobject_name, object_type INTO v_str, v_str2 FROM capr_segment_growth
          WHERE dbid = v_dbid AND tablespace_name = 'FIX_FILLING' AND object_name = 'EVENTS';
        chk_str('CAPR_SEGMENT_GROWTH EVENTS subobject / type', v_str || ' ' || v_str2, 'P1 TABLE PARTITION');
        SELECT SUM(grown_bytes) INTO v_num FROM capr_segment_growth
          WHERE dbid = v_dbid AND tablespace_name = 'FIX_FILLING';
        chk_int('CAPR_SEGMENT_GROWTH FIX_FILLING total = 28 days x 10 MiB', v_num, 28 * 10485760);
        -- seg_window_days drives the window: 7 days -> 7 x 7 MiB.
        UPDATE cap_config SET cfg_value = 7 WHERE cfg_name = 'seg_window_days';
        SELECT grown_bytes INTO v_num FROM capr_segment_growth
          WHERE dbid = v_dbid AND tablespace_name = 'FIX_FILLING' AND object_name = 'ORDERS';
        chk_int('CAPR_SEGMENT_GROWTH ORDERS grown_bytes at seg_window_days = 7', v_num, 7 * 7 * 1048576);
        UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'seg_window_days';
        SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'seg_window_days';
        chk_str('CAP_CFG_CHECK seg_window_days = 0', v_str, 'BAD');
        UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'seg_window_days';
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'seg_window_days';
            COMMIT;
            fail('segment-growth block raised ' || SQLERRM);
    END;

    DBMS_OUTPUT.PUT_LINE('----------------------------------------');
    DBMS_OUTPUT.PUT_LINE('RESULT: ' || g_pass || ' passed, ' || g_fail || ' failed');
    IF g_fail > 0 THEN
        RAISE_APPLICATION_ERROR(-20050, 'FIXTURE TESTS FAILED: ' || g_fail || ' assertion(s)');
    END IF;
END;
/

PROMPT
PROMPT All fixture assertions passed.
