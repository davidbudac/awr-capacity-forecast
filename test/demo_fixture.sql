--
-- test/demo_fixture.sql -- a realistic, DESIGNED demo database for the docs.
-- =====================================================================
-- Fills the CAP_FIXTURE_* tables (same shapes as test/fixture_install.sql)
-- with 150 days of hourly AWR-shaped history for a fictional e-commerce
-- database, so the sample report published on the documentation site is the
-- real output of report/report.sql + report_html.sql, not a mock-up.
--
-- Nothing here is random: every series is a closed-form curve plus a tiny
-- deterministic ripple (a hashed sine), so the run is reproducible.
--
-- The story ("ECOMPRD", a CDB with one application PDB "SHOP_PDB"):
--   ORDERS_DATA      the headline: steady growth (weekday-heavy), ~2 months
--                    of headroom left -> a confident days-to-full WARN.
--   ORDERS_IDX       same shape, more headroom -> a healthy OK forecast.
--   AUDIT_TRAIL      growth tripled 32 days ago (a compliance-logging
--                    release) and it is about to hit its maxsize -> CRIT,
--                    with the recent-window acceleration ratio showing why.
--   SESSION_STORE    a 30-day purge cycle (sawtooth, 20 -> 92.5 GiB of 300).
--                    Three cliffs in the 90-day window grade it CYCLIC:
--                    judged on its flat peaks (30.8% of the limit), so no
--                    days-to-full and no TBSPC_FULL, every day of the cycle.
--   CUSTOMER_DATA    95% full RIGHT NOW but barely growing -> near-full
--                    warning, no days-to-full panic.
--   PRODUCT_CATALOG  flat, no autoextend -> FLAT, nothing to say.
--   ANALYTICS_STAGE  ~1 GiB/day of staging data, plus ONE +38 GiB backfill
--                    load 6 days ago -> a tablespace growth anomaly inside
--                    the alert window (and a forecast that shrugs it off).
--   SYSTEM / SYSAUX / UNDOTBS1  in the root container, quiet.
--   Host CPU (32 threads / 16 cores)  a business-hours/night/weekend profile
--                    with a 02:00-04:00 batch, +55% load growth over the
--                    window (busy p95 heading for the 80% saturation line
--                    in a couple of months), one runaway day 9 days ago (CPU
--                    anomaly), and an instance restart 95 days ago (a counter
--                    reset the guard must skip).
--   SHOP_PDB DB CPU  its share of host CPU jumps from 50% to 85% 12 days ago
--                    (a release). As a percent of the 32 logical CPUs that
--                    step is about +11 points, under shift_min_pct (15), so
--                    CAPA_CPU_SHIFT does not flag it; the step days arrive as
--                    one DBCPU_ANOM episode (SAME_DOW) instead.
--   sessions / processes (SHOP_PDB)  sessions high-water creeping toward
--                    the 90% line (~40 days), processes flat.
--   redo             ~45 GiB/day weekdays, less at weekends.
--   memory (M26)     ASMM on a 128 GiB host: sga_target = sga_max_size
--                    48 GiB, pga_aggregate_target 10 GiB, pga_aggregate_limit
--                    20 GiB. The SGA holds memory nobody uses while the
--                    nightly batch starves for PGA. Over the 30-day window
--                    (one startup, the restart is 95 days back):
--                    PGA_TARGET UNDERSIZED: the 02:00-04:00 batch spills
--                    (0.31% multi-pass executions, one over-allocation an
--                    hour, temp direct path I/O 6% of DB time) and the PGA
--                    advisor flattens at 14 GiB, the suggestion.
--                    PGA_LIMIT OK: the batch peak, 11.5 + i/100 GiB on day i,
--                    reaches 13 GiB (65% of the limit, high-water mark 67%),
--                    and as PGA_ALLOC_GB it is ~500 days from the 90% line.
--                    BUFFER_CACHE and SGA_TOTAL OVERSIZED: 7 GiB less cache
--                    (37 -> 30 GiB) or 6 GiB less SGA (48 -> 42 GiB) costs
--                    0.4% of DB time. SHARED_POOL OK / SIZED_RIGHT.
--                    SGA_BALANCE OK / STABLE: at the SHOP_PDB release ASMM
--                    moved 1 GiB from the buffer cache (38 -> 37 GiB) to the
--                    shared pool (8 -> 9 GiB), one deferred transfer (a
--                    shrink and a grow), 2% of sga_target. The restart day's
--                    batch, cut short by the outage, re-runs at 05:00-07:00.
--
-- Run BEFORE @install.sql with deploy_mode=fixture (the seam views need the
-- tables), in a throwaway schema. Then:
--   SQL> DEFINE deploy_mode = 'fixture'
--   SQL> @install.sql
--   SQL> EXEC cap_forecast_ml.train_all
--   SQL> @report/report.sql
--   SQL> @report/report_html.sql
--
SET APPINFO OFF
SET APPINFO "AWRCAP/test/demo_fixture.sql"
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT FAILURE

-- ---- drop any prior fixtures ----
-- The demo has no ASM or segment history: dropping those tables (left behind
-- by test/fixture_install.sql) makes the fixture seam stub them, so no FIX_
-- rows leak into the demo. Its parameters are the memory ones alone: no
-- cpu_count (the CPU series keep NUM_CPUS) and no FRA size.
DECLARE
    TYPE nl IS TABLE OF VARCHAR2(30);
    v nl := nl('CAP_FIXTURE_SNAPSHOT','CAP_FIXTURE_TBSPC_USAGE','CAP_FIXTURE_TABLESPACE',
              'CAP_FIXTURE_DATAFILE','CAP_FIXTURE_OSSTAT','CAP_FIXTURE_TIME_MODEL',
              'CAP_FIXTURE_CONTAINER','CAP_FIXTURE_META',
              'CAP_FIXTURE_RESOURCE_LIMIT','CAP_FIXTURE_SYSSTAT',
              'CAP_FIXTURE_PARAMETER','CAP_FIXTURE_ASM_DISKGROUP','CAP_FIXTURE_SEG_STAT',
              'CAP_FIXTURE_PGASTAT',
              'CAP_FIXTURE_MEM_COMP','CAP_FIXTURE_WORKAREA_HSTGRM',
              'CAP_FIXTURE_PGA_ADVICE','CAP_FIXTURE_SGA_ADVICE','CAP_FIXTURE_CACHE_ADVICE',
              'CAP_FIXTURE_SHPOOL_ADVICE','CAP_FIXTURE_SGASTAT','CAP_FIXTURE_LIBRARYCACHE',
              'CAP_FIXTURE_ROWCACHE','CAP_FIXTURE_SYSTEM_EVENT',
              'CAP_FIXTURE_ALERTS_SNAP');
BEGIN
    FOR i IN 1 .. v.COUNT LOOP
        BEGIN EXECUTE IMMEDIATE 'DROP TABLE ' || v(i) || ' PURGE';
        EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
    END LOOP;
END;
/

CREATE TABLE cap_fixture_snapshot (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    begin_interval_time TIMESTAMP, end_interval_time TIMESTAMP, startup_time TIMESTAMP);
CREATE TABLE cap_fixture_tbspc_usage (
    dbid NUMBER, con_dbid NUMBER, snap_id NUMBER, tablespace_id NUMBER,
    tablespace_size NUMBER, tablespace_maxsize NUMBER, tablespace_usedsize NUMBER);
CREATE TABLE cap_fixture_tablespace (
    dbid NUMBER, con_dbid NUMBER, tablespace_id NUMBER,
    tablespace_name VARCHAR2(30), contents VARCHAR2(30), block_size NUMBER);
CREATE TABLE cap_fixture_datafile (
    dbid NUMBER, con_dbid NUMBER, tablespace_id NUMBER, block_size NUMBER);
CREATE TABLE cap_fixture_osstat (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    stat_name VARCHAR2(64), value NUMBER);
CREATE TABLE cap_fixture_time_model (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    stat_name VARCHAR2(64), value NUMBER);
CREATE TABLE cap_fixture_container (
    dbid NUMBER, con_dbid NUMBER, db_name VARCHAR2(128), con_name VARCHAR2(128));
CREATE TABLE cap_fixture_meta (
    mkey VARCHAR2(30) PRIMARY KEY, dval DATE, nval NUMBER, sval VARCHAR2(100));
CREATE TABLE cap_fixture_resource_limit (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    resource_name VARCHAR2(30), current_utilization NUMBER,
    max_utilization NUMBER, limit_value NUMBER);
CREATE TABLE cap_fixture_sysstat (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    stat_name VARCHAR2(64), value NUMBER);
CREATE TABLE cap_fixture_parameter (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    parameter_name VARCHAR2(64), value_num NUMBER);
CREATE TABLE cap_fixture_pgastat (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    stat_name VARCHAR2(64), value NUMBER);
CREATE TABLE cap_fixture_mem_comp (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    component VARCHAR2(64), current_size NUMBER, min_size NUMBER, max_size NUMBER,
    user_specified_size NUMBER, oper_count NUMBER, last_oper_type VARCHAR2(13),
    last_oper_mode VARCHAR2(9), last_oper_time DATE, granule_size NUMBER);
CREATE TABLE cap_fixture_workarea_hstgrm (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    low_optimal_size NUMBER, high_optimal_size NUMBER, optimal_executions NUMBER,
    onepass_executions NUMBER, multipasses_executions NUMBER, total_executions NUMBER);
CREATE TABLE cap_fixture_pga_advice (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    pga_target_for_estimate NUMBER, pga_target_factor NUMBER, advice_status VARCHAR2(3),
    bytes_processed NUMBER, estd_time NUMBER, estd_extra_bytes_rw NUMBER,
    estd_pga_cache_hit_percentage NUMBER, estd_overalloc_count NUMBER);
CREATE TABLE cap_fixture_sga_advice (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    sga_size NUMBER, sga_size_factor NUMBER, estd_db_time NUMBER,
    estd_physical_reads NUMBER);
CREATE TABLE cap_fixture_cache_advice (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER, bpid NUMBER,
    name VARCHAR2(20), block_size NUMBER, advice_status VARCHAR2(3),
    size_for_estimate NUMBER, size_factor NUMBER, buffers_for_estimate NUMBER,
    physical_reads NUMBER, base_physical_reads NUMBER, actual_physical_reads NUMBER,
    estd_physical_read_time NUMBER);
CREATE TABLE cap_fixture_shpool_advice (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    shared_pool_size_for_estimate NUMBER, shared_pool_size_factor NUMBER,
    estd_lc_size NUMBER, estd_lc_memory_objects NUMBER, estd_lc_time_saved NUMBER,
    estd_lc_time_saved_factor NUMBER, estd_lc_load_time NUMBER,
    estd_lc_load_time_factor NUMBER, estd_lc_memory_object_hits NUMBER);
CREATE TABLE cap_fixture_sgastat (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    pool VARCHAR2(30), name VARCHAR2(64), bytes NUMBER);
CREATE TABLE cap_fixture_librarycache (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    namespace VARCHAR2(15), gets NUMBER, gethits NUMBER, pins NUMBER, pinhits NUMBER,
    reloads NUMBER, invalidations NUMBER);
CREATE TABLE cap_fixture_rowcache (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    parameter VARCHAR2(32), gets NUMBER, getmisses NUMBER);
CREATE TABLE cap_fixture_system_event (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    event_name VARCHAR2(64), wait_class VARCHAR2(64), total_waits NUMBER,
    time_waited_micro NUMBER);

DECLARE
    c_dbid    CONSTANT NUMBER      := 3141592653;    -- root con_dbid = dbid
    c_pdb     CONSTANT NUMBER      := 3141592654;    -- SHOP_PDB
    c_inst    CONSTANT NUMBER      := 1;
    c_nd      CONSTANT PLS_INTEGER := 150;           -- day index 0..150
    c_bs      CONSTANT NUMBER      := 8192;
    c_g       CONSTANT NUMBER      := 131072;        -- 1 GiB in 8 KiB blocks
    c_thr     CONSTANT NUMBER      := 32;            -- CPU threads
    c_cores   CONSTANT NUMBER      := 16;
    c_cs_h    CONSTANT NUMBER      := 32 * 3600 * 100;  -- busy+idle cs per hour
    c_restart CONSTANT PLS_INTEGER := 55;            -- restart day (04:00)
    c_audit   CONSTANT PLS_INTEGER := 118;           -- AUDIT_TRAIL growth step
    c_shift   CONSTANT PLS_INTEGER := 138;           -- SHOP_PDB DB CPU level shift
    c_purge   CONSTANT PLS_INTEGER := 12;            -- SESSION_STORE purge phase (i mod 30)
    v_base    DATE := TRUNC(SYSDATE) - c_nd;
    v_start1  TIMESTAMP := CAST(v_base - 40 AS TIMESTAMP);
    v_start2  TIMESTAMP := CAST(v_base + c_restart + 4/24 AS TIMESTAMP);
    v_start   TIMESTAMP;
    v_anom    PLS_INTEGER;                            -- runaway CPU day
    v_etlanom PLS_INTEGER;                            -- double ETL Sunday
    -- cumulative counters
    v_busy NUMBER := 0; v_idle NUMBER := 0;
    v_rcpu NUMBER := 0; v_rtime NUMBER := 0; v_rbg NUMBER := 0;
    v_pcpu NUMBER := 0; v_ptime NUMBER := 0; v_pbg NUMBER := 0;
    v_redo NUMBER := 0;
    v_smax NUMBER := 0; v_pmax NUMBER := 0;           -- resource high-water marks
    v_snap NUMBER; v_f NUMBER; v_hb NUMBER; v_cur NUMBER;
    v_used NUMBER; v_alloc NUMBER;
    -- ORDERS_* cumulative growth
    v_ord  NUMBER := 300 * c_g;
    v_idx  NUMBER := 120 * c_g;
    v_aud  NUMBER := 40 * c_g;
    v_sysx NUMBER := 8 * c_g;
    v_cust NUMBER := 149 * c_g;
    v_stage NUMBER := 15 * c_g;

    FUNCTION dow(p_i PLS_INTEGER) RETURN PLS_INTEGER IS       -- 0=Mon .. 6=Sun
    BEGIN RETURN MOD(TRUNC(v_base + p_i) - DATE '2020-01-06', 7); END;
    FUNCTION wkend(p_i PLS_INTEGER) RETURN BOOLEAN IS
    BEGIN RETURN dow(p_i) >= 5; END;
    -- deterministic ripple in [-1, 1]
    FUNCTION rip(p_i NUMBER, p_h NUMBER, p_k NUMBER) RETURN NUMBER IS
        x NUMBER := SIN(p_i * 12.9898 + p_h * 78.233 + p_k * 37.719) * 43758.5453;
    BEGIN RETURN (x - FLOOR(x)) * 2 - 1; END;

    -- host busy fraction for day i, hour h (interval ending h+1)
    FUNCTION busy(p_i PLS_INTEGER, p_h PLS_INTEGER) RETURN NUMBER IS
        f NUMBER;
    BEGIN
        f := CASE WHEN p_h <= 6               THEN 0.16
                  WHEN p_h <= 9               THEN 0.30
                  WHEN p_h <= 18              THEN 0.42       -- business hours
                  WHEN p_h <= 22              THEN 0.34
                  ELSE 0.20 END;
        IF wkend(p_i) THEN f := f * 0.92; END IF;
        f := f * (1 + 0.55 * p_i / c_nd);                    -- +55% load over the window
        IF p_h BETWEEN 2 AND 4 THEN f := GREATEST(f, 0.50); END IF;  -- nightly batch, constant
        IF p_i >= c_shift THEN f := f + 0.04; END IF;        -- the release, host side
        IF p_i = v_anom AND p_h BETWEEN 8 AND 20 THEN f := f * 1.55; END IF;
        f := f + 0.025 * rip(p_i, p_h, 1);
        RETURN LEAST(0.97, GREATEST(0.05, f));
    END;

    PROCEDURE osstat(p_snap NUMBER, p_name VARCHAR2, p_val NUMBER) IS
    BEGIN INSERT INTO cap_fixture_osstat VALUES (c_dbid, c_dbid, c_inst, p_snap, p_name, p_val); END;
    PROCEDURE tm(p_con NUMBER, p_snap NUMBER, p_name VARCHAR2, p_val NUMBER) IS
    BEGIN INSERT INTO cap_fixture_time_model VALUES (c_dbid, p_con, c_inst, p_snap, p_name, p_val); END;
    PROCEDURE ts(p_con NUMBER, p_id NUMBER, p_name VARCHAR2, p_contents VARCHAR2) IS
    BEGIN
        INSERT INTO cap_fixture_tablespace VALUES (c_dbid, p_con, p_id, p_name, p_contents, c_bs);
        INSERT INTO cap_fixture_datafile   VALUES (c_dbid, p_con, p_id, c_bs);
    END;
    -- usage row: allocated = used rounded up to the next 4 GiB (+ 2 GiB slack)
    PROCEDURE usage(p_con NUMBER, p_snap NUMBER, p_id NUMBER, p_used NUMBER,
                    p_max NUMBER, p_alloc NUMBER DEFAULT NULL) IS
        a NUMBER := NVL(p_alloc, (CEIL(p_used / (4 * c_g)) * 4 + 2) * c_g);
    BEGIN
        IF p_max > 0 THEN a := LEAST(a, p_max); END IF;
        INSERT INTO cap_fixture_tbspc_usage
        VALUES (c_dbid, p_con, p_snap, p_id, a, p_max, ROUND(p_used));
    END;
BEGIN
    -- the runaway CPU day: latest weekday in 139..142
    FOR i IN REVERSE 139 .. 142 LOOP
        IF NOT wkend(i) THEN v_anom := i; EXIT; END IF;
    END LOOP;
    v_etlanom := c_nd - 6;                            -- the one-off backfill load

    INSERT INTO cap_fixture_container VALUES (c_dbid, c_dbid, 'ECOMPRD', 'CDB$ROOT');
    INSERT INTO cap_fixture_container VALUES (c_dbid, c_pdb,  'ECOMPRD', 'SHOP_PDB');

    ts(c_pdb,  1, 'ORDERS_DATA',     'PERMANENT');
    ts(c_pdb,  2, 'ORDERS_IDX',      'PERMANENT');
    ts(c_pdb,  3, 'AUDIT_TRAIL',     'PERMANENT');
    ts(c_pdb,  4, 'SESSION_STORE',   'PERMANENT');
    ts(c_pdb,  5, 'CUSTOMER_DATA',   'PERMANENT');
    ts(c_pdb,  6, 'PRODUCT_CATALOG', 'PERMANENT');
    ts(c_pdb,  7, 'ANALYTICS_STAGE', 'PERMANENT');
    ts(c_dbid, 8, 'SYSTEM',          'PERMANENT');
    ts(c_dbid, 9, 'SYSAUX',          'PERMANENT');
    ts(c_dbid,10, 'UNDOTBS1',        'UNDO');

    FOR i IN 0 .. c_nd LOOP
        -- ---- daily tablespace levels (end of day) ----
        v_ord := v_ord + (CASE WHEN wkend(i) THEN 0.9 ELSE 1.3 END + 0.25 * rip(i, 0, 2)) * c_g;
        v_idx := v_idx + (0.55 + 0.10 * rip(i, 0, 3)) * c_g;
        v_aud := v_aud + (CASE WHEN i >= c_audit THEN 1.15 ELSE 0.35 END + 0.06 * rip(i, 0, 4)) * c_g;
        v_cust := v_cust + 0.02 * c_g;
        v_sysx := v_sysx + 0.03 * c_g;
        v_stage := v_stage + (1 + 0.15 * rip(i, 0, 5) + CASE WHEN i = v_etlanom THEN 38 ELSE 0 END) * c_g;

        FOR h IN 0 .. 23 LOOP
            -- restart at 04:00 on day c_restart: snapshots 00..04 missing,
            -- 05:00 onward carry the new startup_time and reset counters.
            IF i = c_restart AND h < 5 THEN CONTINUE; END IF;
            v_snap  := 50000 + 24 * i + h;
            v_start := CASE WHEN i < c_restart THEN v_start1 ELSE v_start2 END;
            -- interval (h-1):00 -> h:00, so day i owns the snapshots ending
            -- 00:00 .. 23:00 and every day in the window is complete.
            INSERT INTO cap_fixture_snapshot
            VALUES (c_dbid, c_dbid, c_inst, v_snap,
                    CAST(v_base + i + (h-1)/24 AS TIMESTAMP),
                    CAST(v_base + i + h/24 AS TIMESTAMP), v_start);

            IF i = c_restart AND h = 5 THEN
                v_busy := 0; v_idle := 0; v_rcpu := 0; v_rtime := 0; v_rbg := 0;
                v_pcpu := 0; v_ptime := 0; v_pbg := 0; v_redo := 0;
                v_smax := 0; v_pmax := 0;
            END IF;

            -- ---- host CPU (cumulative centiseconds over all threads) ----
            v_f  := busy(i, h);
            v_hb := v_f * c_cores * 3600;                   -- host busy core-seconds this hour
            v_busy := v_busy + v_f * c_cs_h;
            v_idle := v_idle + (1 - v_f) * c_cs_h;
            osstat(v_snap, 'BUSY_TIME', ROUND(v_busy));
            osstat(v_snap, 'IDLE_TIME', ROUND(v_idle));
            osstat(v_snap, 'NUM_CPUS', c_thr);
            osstat(v_snap, 'NUM_CPU_CORES', c_cores);

            -- ---- time model (cumulative microseconds), root + SHOP_PDB ----
            v_rcpu  := v_rcpu  + 0.03 * v_hb * 1e6;
            v_rtime := v_rtime + 0.03 * v_hb * 1.2 * 1e6;
            v_rbg   := v_rbg   + 90 * 1e6;
            tm(c_dbid, v_snap, 'DB CPU', ROUND(v_rcpu));
            tm(c_dbid, v_snap, 'DB time', ROUND(v_rtime));
            tm(c_dbid, v_snap, 'background cpu time', ROUND(v_rbg));
            v_pcpu  := v_pcpu  + (CASE WHEN i >= c_shift THEN 0.85 ELSE 0.50 END) * v_hb * 1e6;
            v_ptime := v_ptime + (CASE WHEN i >= c_shift THEN 0.85 ELSE 0.50 END) * v_hb * 1.35 * 1e6;
            v_pbg   := v_pbg   + 120 * 1e6;
            tm(c_pdb, v_snap, 'DB CPU', ROUND(v_pcpu));
            tm(c_pdb, v_snap, 'DB time', ROUND(v_ptime));
            tm(c_pdb, v_snap, 'background cpu time', ROUND(v_pbg));

            -- ---- redo (cumulative bytes) ----
            v_redo := v_redo + ROUND(v_f / 0.5 * 2.2 * 1073741824);
            INSERT INTO cap_fixture_sysstat VALUES (c_dbid, c_dbid, c_inst, v_snap, 'redo size', v_redo);

            -- ---- resource limits (SHOP_PDB): sessions creep, processes flat ----
            v_cur := 500 + 2.2 * i + CASE WHEN h BETWEEN 8 AND 17 AND NOT wkend(i) THEN 250 ELSE 0 END
                     + 15 * rip(i, h, 6);
            v_smax := GREATEST(v_smax, v_cur);
            INSERT INTO cap_fixture_resource_limit
            VALUES (c_dbid, c_pdb, c_inst, v_snap, 'sessions', ROUND(v_cur), ROUND(v_smax), 1300);
            v_cur := 700 + CASE WHEN h BETWEEN 8 AND 17 AND NOT wkend(i) THEN 200 ELSE 0 END
                     + 12 * rip(i, h, 7);
            v_pmax := GREATEST(v_pmax, v_cur);
            INSERT INTO cap_fixture_resource_limit
            VALUES (c_dbid, c_pdb, c_inst, v_snap, 'processes', ROUND(v_cur), ROUND(v_pmax), 1600);

            -- ---- tablespace usage: sampled at the last snapshot of the day ----
            IF h = 23 THEN
                usage(c_pdb,  v_snap, 1, v_ord,   600 * c_g);
                usage(c_pdb,  v_snap, 2, v_idx,   300 * c_g);
                usage(c_pdb,  v_snap, 3, v_aud,   130 * c_g);
                usage(c_pdb,  v_snap, 4, 20 * c_g + 2.5 * c_g * MOD(i - c_purge + 30, 30), 300 * c_g);
                usage(c_pdb,  v_snap, 5, v_cust,  160 * c_g);
                usage(c_pdb,  v_snap, 6, 12 * c_g, 0, 16 * c_g);
                usage(c_pdb,  v_snap, 7, v_stage, 400 * c_g);
                usage(c_dbid, v_snap, 8, 1.1 * c_g, 4 * c_g, 2 * c_g);
                usage(c_dbid, v_snap, 9, v_sysx,  32 * c_g);
                usage(c_dbid, v_snap,10, 6 * c_g, 0, 12 * c_g);
            END IF;
        END LOOP;
    END LOOP;

    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DBID', c_dbid);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('BASE_DAY', v_base);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('LAST_DAY', v_base + c_nd);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('RESTART_DAY', v_base + c_restart);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('AUDIT_STEP_DAY', v_base + c_audit);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('SHIFT_DAY', v_base + c_shift);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('CPU_ANOM_DAY', v_base + v_anom);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('BACKFILL_DAY', v_base + v_etlanom);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Demo fixtures loaded: ' || TO_CHAR(v_base, 'YYYY-MM-DD') || ' .. '
        || TO_CHAR(v_base + c_nd, 'YYYY-MM-DD') || ' hourly; restart '
        || TO_CHAR(v_base + c_restart, 'YYYY-MM-DD') || ', audit step '
        || TO_CHAR(v_base + c_audit, 'YYYY-MM-DD') || ', cpu shift '
        || TO_CHAR(v_base + c_shift, 'YYYY-MM-DD') || ', cpu anomaly '
        || TO_CHAR(v_base + v_anom, 'YYYY-MM-DD') || ', backfill load '
        || TO_CHAR(v_base + v_etlanom, 'YYYY-MM-DD'));
END;
/

-- =====================================================================
-- M26 -- the memory chapter: the CAPM_* verdicts and the PGA_ALLOC_GB series.
-- =====================================================================
-- Root container, instance 1, every snapshot. Counters and advisor
-- estimates are cumulative since instance startup and restart from zero at
-- the day-55 restart. Every advisor estimate and wait event grows by a fixed
-- share of the interval's instance DB time (root + SHOP_PDB, read back from
-- CAP_FIXTURE_TIME_MODEL), so each gain, loss and wait is that share of DB
-- time over any set of intervals: the evidence reads the designed percent.
-- The batch is the snapshots ending 02:00, 03:00 and 04:00 (05:00-07:00 on
-- the restart day). The 30-day window is days 121..150.
--
-- Parameters (CAP_FIXTURE_PARAMETER, every snapshot): memory_target 0,
-- sga_target = sga_max_size 48 GiB, pga_aggregate_target 10 GiB,
-- pga_aggregate_limit 20 GiB. OSSTAT PHYSICAL_MEMORY_BYTES 128 GiB.
--
--   PGA level      'total PGA allocated' at the batch's middle hour 11.5 +
--                  i/100 GiB on day i (13 GiB on the last day, 65% of the
--                  limit; PGA_ALLOC_GB, its daily maximum, is exactly linear:
--                  (18 - 13) / 0.01 = 500 days to the 90% line), 0.6 GiB
--                  less at the other two batch hours, 4 or 6 GiB (weekday
--                  09..18) x (1 + 0.25 i/150) plus a ripple otherwise.
--                  'maximum PGA allocated' runs 3% above the highest sample
--                  of the startup: 13.39 GiB (66.95%) at the last batch.
--   PGA advisor    sizes 1.25 .. 80 GiB (factors 0.125 .. 8). Work 40 GiB an
--                  interval, 160 in the batch (1320 GiB a day); extra bytes
--                  only in the batch, sized so the window's cache hit reads
--                  38 / 52 / 70 / 81 / 87 / 94 / 98 / 98.5 / 98.8 / 99 ...%.
--                  Best gain 12 points at 20 GiB, 90% of it first reached at
--                  14 GiB, the smallest size without over-allocation
--                  (10 and 12 GiB: one each batch hour): suggested 14 GiB.
--   Work areas     2000 executions an interval; a batch interval has 600
--                  one-pass and 50 multi-pass of them: 3.75% and 0.3125%.
--   PGA statistics one over-allocation each batch hour (90 in the window);
--                  the auto target leaves 30% of the target at the last
--                  batch hour (72% outside the batch).
--   Cache advisor  DEFAULT pool, 16 .. 72 GiB, read time as % of DB time:
--                  12 at the current 37 GiB, 11.85 at 64 GiB and up (gain
--                  0.15), 12.4 at 30 GiB (loss 0.4, the suggestion), 12.9 at
--                  28. Its estimates restart at the 09:30 resize.
--   SGA advisor    24 .. 96 GiB (factors 0.5 .. 2 by 0.125), estimated DB
--                  time 100% at 48, 99.8% from 72 (gain 0.2), 100.4% at 42
--                  (loss 0.4, the suggestion), 101.2% at 36.
--   Shared pool    sizes current / 2 .. x 2 by 512 MiB (the list moves with
--   advisor        the pool), load time as % of DB time: 1 at 9 GiB, 0.82
--                  from 11.5 GiB (gain 0.18), 1.6 at 8.5 GiB (loss 0.6, no
--                  slack): SIZED_RIGHT.
--   Events         temp direct path I/O in the batch only, 6% of the
--                  window's DB time; free buffer waits 0.02%; shared pool
--                  latch, library cache mutex and load lock waits 0.03%.
--   Caches         library cache reloads 0.3% of pins, dictionary cache
--                  misses 1.5% of gets. Shared pool free memory 1 GiB of 8,
--                  0.35 GiB just before the resize (4.375%, the window's
--                  low), 0.8 GiB of 9 after it.
--   Components     SGA Target 48, DEFAULT buffer cache 38 -> 37, shared pool
--                  8 -> 9, large pool 1, java pool 0.5, streams pool 0, PGA
--                  Target 10 GiB; granule 128 MiB. The resize at 09:30 on
--                  SHIFT_DAY is one deferred transfer: each pool's operation
--                  counter moves once (2 operations, 0.07 a day).
DECLARE
    c_dbid    CONSTANT NUMBER      := 3141592653;
    c_inst    CONSTANT NUMBER      := 1;
    c_nd      CONSTANT PLS_INTEGER := 150;
    c_restart CONSTANT PLS_INTEGER := 55;
    c_shift   CONSTANT PLS_INTEGER := 138;
    c_rsz_h   CONSTANT PLS_INTEGER := 10;            -- first snapshot after the 09:30 resize
    c_win0    CONSTANT PLS_INTEGER := 121;           -- first day of the 30-day window
    c_temp    CONSTANT NUMBER      := 6;             -- temp I/O, % of the window's DB time
    c_wday    CONSTANT NUMBER      := 1320;          -- PGA work a day, GiB
    c_gib     CONSTANT NUMBER      := 1073741824;
    c_mib     CONSTANT NUMBER      := 1048576;
    TYPE num_t IS TABLE OF NUMBER;
    pga_gib   CONSTANT num_t := num_t(1.25, 2.5, 5, 7.5, 10, 12, 14, 16, 18, 20, 30, 40, 60, 80);
    pga_hit   CONSTANT num_t := num_t(38, 52, 70, 81, 87, 94, 98, 98.5, 98.8, 99, 99, 99, 99, 99);
    pga_over  CONSTANT num_t := num_t(20, 10, 4, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0);
    cache_gib CONSTANT num_t := num_t(16, 20, 24, 28, 30, 32, 34, 35, 36, 37, 38, 40, 44, 48, 56, 64, 72);
    cache_pct CONSTANT num_t := num_t(22, 17, 14.6, 12.9, 12.4, 12.2, 12.1, 12.06, 12.03, 12, 11.98,
                                      11.95, 11.91, 11.88, 11.86, 11.85, 11.85);
    sga_pct   CONSTANT num_t := num_t(112, 104.5, 101.2, 100.4, 100, 99.9, 99.85, 99.82, 99.8,
                                      99.8, 99.8, 99.8, 99.8);
    shp_pct   CONSTANT num_t := num_t(12.4, 10.6, 9, 7.5, 6.2, 5, 4, 3.1, 2.3, 1.6, 1, 0.93, 0.88,
                                      0.85, 0.83, 0.82, 0.82, 0.82, 0.82, 0.82, 0.82, 0.82, 0.82,
                                      0.82, 0.82, 0.82, 0.82, 0.82, 0.82);
    v_base    DATE;
    v_snap    num_t;
    v_cum     num_t;                                 -- instance DB time since startup, s
    v_dbt     num_t := num_t();                      -- the interval's DB time, s
    v_all     NUMBER := 0;                           -- the window's DB time
    v_bat     NUMBER := 0;                           -- ... of its batch intervals
    v_tf      NUMBER;                                -- temp I/O share of a batch interval
    v_prev    NUMBER := 0;
    i         PLS_INTEGER;
    h         PLS_INTEGER;
    d         NUMBER;
    b         BOOLEAN;
    v_post    BOOLEAN;
    v_tot     NUMBER;
    v_cur     NUMBER;
    v_gc      PLS_INTEGER;
    v_sz      NUMBER;
    -- cumulative since startup
    w_pga NUMBER; e_pga num_t := num_t(); o_pga num_t := num_t();
    c_cache num_t := num_t(); c_sga num_t := num_t(); c_shp num_t := num_t();
    wa1 NUMBER; wa2 NUMBER; wa3o NUMBER; wa3p NUMBER; wa3m NUMBER;
    ev_rd NUMBER; ev_wr NUMBER; ev_lat NUMBER; ev_mtx NUMBER; ev_ll NUMBER; ev_fbw NUMBER;
    v_n NUMBER; v_oac NUMBER; v_hwm NUMBER;

    FUNCTION wkend(p_i PLS_INTEGER) RETURN BOOLEAN IS
    BEGIN RETURN MOD(TRUNC(v_base + p_i) - DATE '2020-01-06', 7) >= 5; END;
    FUNCTION rip(p_i NUMBER, p_h NUMBER, p_k NUMBER) RETURN NUMBER IS
        x NUMBER := SIN(p_i * 12.9898 + p_h * 78.233 + p_k * 37.719) * 43758.5453;
    BEGIN RETURN (x - FLOOR(x)) * 2 - 1; END;
    FUNCTION batch(p_i PLS_INTEGER, p_h PLS_INTEGER) RETURN BOOLEAN IS
    BEGIN
        RETURN CASE WHEN p_i = c_restart THEN p_h BETWEEN 5 AND 7 ELSE p_h BETWEEN 2 AND 4 END;
    END;
    FUNCTION peak(p_i PLS_INTEGER) RETURN PLS_INTEGER IS
    BEGIN RETURN CASE WHEN p_i = c_restart THEN 6 ELSE 3 END; END;
    PROCEDURE startup IS
    BEGIN
        w_pga := 0; wa1 := 0; wa2 := 0; wa3o := 0; wa3p := 0; wa3m := 0;
        ev_rd := 0; ev_wr := 0; ev_lat := 0; ev_mtx := 0; ev_ll := 0; ev_fbw := 0;
        v_n := 0; v_oac := 0; v_hwm := 0;
        FOR j IN 1 .. e_pga.COUNT   LOOP e_pga(j) := 0; o_pga(j) := 0; END LOOP;
        FOR j IN 1 .. c_cache.COUNT LOOP c_cache(j) := 0; END LOOP;
        FOR j IN 1 .. c_sga.COUNT   LOOP c_sga(j) := 0; END LOOP;
        FOR j IN 1 .. c_shp.COUNT   LOOP c_shp(j) := 0; END LOOP;
    END;
    PROCEDURE param(p_snap NUMBER, p_name VARCHAR2, p_val NUMBER) IS
    BEGIN
        INSERT INTO cap_fixture_parameter VALUES (c_dbid, c_dbid, c_inst, p_snap, p_name, p_val);
    END;
    PROCEDURE pgastat(p_snap NUMBER, p_name VARCHAR2, p_val NUMBER) IS
    BEGIN
        INSERT INTO cap_fixture_pgastat VALUES (c_dbid, c_dbid, c_inst, p_snap, p_name, ROUND(p_val));
    END;
    -- AWR writes no row for an event never waited for: none until it is.
    PROCEDURE event(p_snap NUMBER, p_name VARCHAR2, p_class VARCHAR2, p_sec NUMBER, p_avg NUMBER) IS
    BEGIN
        IF p_sec > 0 THEN
            INSERT INTO cap_fixture_system_event
            VALUES (c_dbid, c_dbid, c_inst, p_snap, p_name, p_class, ROUND(p_sec / p_avg),
                    ROUND(p_sec * 1000000));
        END IF;
    END;
    PROCEDURE comp(p_snap NUMBER, p_name VARCHAR2, p_gib NUMBER, p_min NUMBER, p_max NUMBER,
                   p_user NUMBER, p_type VARCHAR2 DEFAULT 'STATIC') IS
        v_resized BOOLEAN := p_type <> 'STATIC';
        v_ops     NUMBER := CASE WHEN v_resized THEN 1 ELSE 0 END;
        v_mode    VARCHAR2(9) := CASE WHEN v_resized THEN 'DEFERRED' END;
        v_at      DATE := CASE WHEN v_resized THEN v_base + c_shift + 9.5/24 END;
    BEGIN
        INSERT INTO cap_fixture_mem_comp
        VALUES (c_dbid, c_dbid, c_inst, p_snap, p_name, p_gib * c_gib, p_min * c_gib, p_max * c_gib,
                p_user * c_gib, v_ops, p_type, v_mode, v_at, 128 * c_mib);
    END;
BEGIN
    SELECT dval INTO v_base FROM cap_fixture_meta WHERE mkey = 'BASE_DAY';
    e_pga.EXTEND(pga_gib.COUNT); o_pga.EXTEND(pga_gib.COUNT);
    c_cache.EXTEND(cache_gib.COUNT); c_sga.EXTEND(sga_pct.COUNT); c_shp.EXTEND(shp_pct.COUNT);

    SELECT snap_id, SUM(value) / 1000000
      BULK COLLECT INTO v_snap, v_cum
      FROM cap_fixture_time_model
     WHERE stat_name = 'DB time'
     GROUP BY snap_id
     ORDER BY snap_id;
    v_dbt.EXTEND(v_snap.COUNT);
    FOR k IN 1 .. v_snap.COUNT LOOP
        i := TRUNC((v_snap(k) - 50000) / 24);
        h := MOD(v_snap(k) - 50000, 24);
        IF i = c_restart AND h = 5 THEN v_prev := 0; END IF;
        v_dbt(k) := v_cum(k) - v_prev;
        v_prev   := v_cum(k);
        IF i >= c_win0 THEN
            v_all := v_all + v_dbt(k);
            IF batch(i, h) THEN v_bat := v_bat + v_dbt(k); END IF;
        END IF;
    END LOOP;
    v_tf := c_temp / 100 * v_all / v_bat;

    startup;
    FOR k IN 1 .. v_snap.COUNT LOOP
        i := TRUNC((v_snap(k) - 50000) / 24);
        h := MOD(v_snap(k) - 50000, 24);
        IF i = c_restart AND h = 5 THEN startup; END IF;
        d      := v_dbt(k);
        b      := batch(i, h);
        v_post := i > c_shift OR (i = c_shift AND h >= c_rsz_h);

        param(v_snap(k), 'memory_target',        0);
        param(v_snap(k), 'sga_target',           48 * c_gib);
        param(v_snap(k), 'sga_max_size',         48 * c_gib);
        param(v_snap(k), 'pga_aggregate_target', 10 * c_gib);
        param(v_snap(k), 'pga_aggregate_limit',  20 * c_gib);

        -- ---- PGA level, statistics and advisor ----
        IF b THEN
            v_tot := 11.5 + i / 100 - CASE WHEN h = peak(i) THEN 0 ELSE 0.6 END;
        ELSE
            v_tot := CASE WHEN NOT wkend(i) AND h BETWEEN 9 AND 18 THEN 6 ELSE 4 END
                     * (1 + 0.25 * i / c_nd) + 0.15 * rip(i, h, 11);
        END IF;
        v_hwm := GREATEST(v_hwm, 1.03 * v_tot);
        w_pga := w_pga + CASE WHEN b THEN 160 ELSE 40 END * c_gib;
        IF b THEN
            v_oac := v_oac + 1;
            FOR j IN 1 .. pga_gib.COUNT LOOP
                e_pga(j) := e_pga(j) + c_wday / 3 * (100 / pga_hit(j) - 1) * c_gib;
                o_pga(j) := o_pga(j) + pga_over(j);
            END LOOP;
        END IF;
        FOR j IN 1 .. pga_gib.COUNT LOOP
            INSERT INTO cap_fixture_pga_advice
            VALUES (c_dbid, c_dbid, c_inst, v_snap(k), pga_gib(j) * c_gib, pga_gib(j) / 10, 'ON',
                    ROUND(w_pga), 0, ROUND(e_pga(j)), ROUND(100 * w_pga / (w_pga + e_pga(j))), o_pga(j));
        END LOOP;
        pgastat(v_snap(k), 'total PGA allocated',            v_tot * c_gib);
        pgastat(v_snap(k), 'maximum PGA allocated',          v_hwm * c_gib);
        pgastat(v_snap(k), 'aggregate PGA target parameter', 10 * c_gib);
        pgastat(v_snap(k), 'aggregate PGA auto target',
                CASE WHEN b THEN 3.5 - 0.5 * i / c_nd + CASE WHEN h = peak(i) THEN 0 ELSE 0.4 END
                     ELSE 7.2 END * c_gib);
        pgastat(v_snap(k), 'bytes processed', w_pga);
        IF e_pga(5) > 0 THEN pgastat(v_snap(k), 'extra bytes read/written', e_pga(5)); END IF;
        IF v_oac > 0    THEN pgastat(v_snap(k), 'over allocation count',    v_oac);    END IF;

        IF b THEN
            wa1 := wa1 + 1000; wa2 := wa2 + 300; wa3o := wa3o + 50; wa3p := wa3p + 600; wa3m := wa3m + 50;
        ELSE
            wa1 := wa1 + 1800; wa2 := wa2 + 200;
        END IF;
        INSERT INTO cap_fixture_workarea_hstgrm
        VALUES (c_dbid, c_dbid, c_inst, v_snap(k), 65536, 131071, wa1, 0, 0, wa1);
        INSERT INTO cap_fixture_workarea_hstgrm
        VALUES (c_dbid, c_dbid, c_inst, v_snap(k), 16777216, 33554431, wa2, 0, 0, wa2);
        INSERT INTO cap_fixture_workarea_hstgrm
        VALUES (c_dbid, c_dbid, c_inst, v_snap(k), 1073741824, 2147483647, wa3o, wa3p, wa3m,
                wa3o + wa3p + wa3m);

        -- ---- wait events (seconds) ----
        IF b THEN
            ev_rd := ev_rd + 0.4 * v_tf * d;
            ev_wr := ev_wr + 0.6 * v_tf * d;
        END IF;
        ev_lat := ev_lat + 0.00005 * d;
        ev_mtx := ev_mtx + 0.0002  * d;
        ev_ll  := ev_ll  + 0.00005 * d;
        ev_fbw := ev_fbw + 0.0002  * d;
        event(v_snap(k), 'direct path read temp',   'User I/O',      ev_rd,  0.004);
        event(v_snap(k), 'direct path write temp',  'User I/O',      ev_wr,  0.004);
        event(v_snap(k), 'latch: shared pool',      'Concurrency',   ev_lat, 0.0005);
        event(v_snap(k), 'library cache: mutex X',  'Concurrency',   ev_mtx, 0.0001);
        event(v_snap(k), 'library cache load lock', 'Concurrency',   ev_ll,  0.002);
        event(v_snap(k), 'free buffer waits',       'Configuration', ev_fbw, 0.01);

        -- ---- library and dictionary cache: 0.3% reloads, 1.5% misses ----
        v_n := v_n + ROUND(d / 10);
        INSERT INTO cap_fixture_librarycache
        VALUES (c_dbid, c_dbid, c_inst, v_snap(k), 'SQL AREA', 300 * v_n, 297 * v_n, 600 * v_n,
                594 * v_n, 2 * v_n, 0);
        INSERT INTO cap_fixture_librarycache
        VALUES (c_dbid, c_dbid, c_inst, v_snap(k), 'TABLE/PROCEDURE', 200 * v_n, 198 * v_n, 400 * v_n,
                396 * v_n, v_n, 0);
        INSERT INTO cap_fixture_rowcache VALUES (c_dbid, c_dbid, c_inst, v_snap(k), 'dc_objects',  300 * v_n, 4 * v_n);
        INSERT INTO cap_fixture_rowcache VALUES (c_dbid, c_dbid, c_inst, v_snap(k), 'dc_segments', 100 * v_n, 2 * v_n);

        v_sz := CASE WHEN v_post                          THEN 0.8
                     WHEN i = c_shift AND h = c_rsz_h - 1 THEN 0.35
                     ELSE 1 END;
        INSERT INTO cap_fixture_sgastat
        VALUES (c_dbid, c_dbid, c_inst, v_snap(k), 'shared pool', 'free memory', v_sz * c_gib);
        INSERT INTO cap_fixture_sgastat
        VALUES (c_dbid, c_dbid, c_inst, v_snap(k), 'large pool', 'free memory', 0.3 * c_gib);

        comp(v_snap(k), 'SGA Target', 48, 48, 48, 48);
        IF v_post THEN
            comp(v_snap(k), 'DEFAULT buffer cache', 37, 37, 38, 0, 'SHRINK');
            comp(v_snap(k), 'shared pool',           9,  8,  9, 0, 'GROW');
        ELSE
            comp(v_snap(k), 'DEFAULT buffer cache', 38, 38, 38, 0);
            comp(v_snap(k), 'shared pool',           8,  8,  8, 0);
        END IF;
        comp(v_snap(k), 'large pool',   1,   1,   1,   0);
        comp(v_snap(k), 'java pool',    0.5, 0.5, 0.5, 0);
        comp(v_snap(k), 'streams pool', 0,   0,   0,   0);
        comp(v_snap(k), 'PGA Target',   10,  10,  10,  10);

        -- ---- the SGA advisors ----
        FOR j IN 1 .. sga_pct.COUNT LOOP
            c_sga(j) := c_sga(j) + sga_pct(j) / 100 * d;
            INSERT INTO cap_fixture_sga_advice
            VALUES (c_dbid, c_dbid, c_inst, v_snap(k), 48 * 1024 * (0.375 + 0.125 * j),
                    0.375 + 0.125 * j, ROUND(c_sga(j)), ROUND(20 * c_sga(j)));
        END LOOP;
        -- The cache advisor restarts its estimates at a resize of the cache.
        v_cur := CASE WHEN v_post THEN 37 ELSE 38 END;
        v_gc  := CASE WHEN v_post THEN 10 ELSE 11 END;
        FOR j IN 1 .. cache_gib.COUNT LOOP
            c_cache(j) := CASE WHEN i = c_shift AND h = c_rsz_h THEN 0.5 * cache_pct(j) / 100 * d
                               ELSE c_cache(j) + cache_pct(j) / 100 * d END;
        END LOOP;
        FOR j IN 1 .. cache_gib.COUNT LOOP
            INSERT INTO cap_fixture_cache_advice
            VALUES (c_dbid, c_dbid, c_inst, v_snap(k), 3, 'DEFAULT', 8192, 'ON',
                    cache_gib(j) * 1024, ROUND(cache_gib(j) / v_cur, 4), cache_gib(j) * c_gib / 8192,
                    ROUND(200 * c_cache(j)), ROUND(200 * c_cache(v_gc)), ROUND(200 * c_cache(v_gc)),
                    ROUND(c_cache(j)));
        END LOOP;
        -- Shared pool sizes 4 .. 18 GiB by 512 MiB; the list runs from half
        -- the current size to twice it.
        v_cur := CASE WHEN v_post THEN 9 ELSE 8 END;
        v_gc  := CASE WHEN v_post THEN 11 ELSE 9 END;
        FOR j IN 1 .. shp_pct.COUNT LOOP
            c_shp(j) := c_shp(j) + shp_pct(j) / 100 * d;
        END LOOP;
        FOR j IN 1 .. shp_pct.COUNT LOOP
            v_sz := 4 + 0.5 * (j - 1);
            IF v_sz BETWEEN v_cur / 2 AND v_cur * 2 THEN
                INSERT INTO cap_fixture_shpool_advice
                VALUES (c_dbid, c_dbid, c_inst, v_snap(k), v_sz * 1024, ROUND(v_sz / v_cur, 4),
                        ROUND(v_sz * 1024 * 0.45), ROUND(v_sz * 1024 * 12),
                        ROUND(0.124 * v_cum(k) - c_shp(j)),
                        ROUND((0.124 * v_cum(k) - c_shp(j)) / (0.124 * v_cum(k) - c_shp(v_gc)), 4),
                        ROUND(c_shp(j)), ROUND(shp_pct(j) / shp_pct(v_gc), 4), 590 * v_n);
            END IF;
        END LOOP;
    END LOOP;

    INSERT INTO cap_fixture_osstat (dbid, con_dbid, instance_number, snap_id, stat_name, value)
    SELECT dbid, con_dbid, instance_number, snap_id, 'PHYSICAL_MEMORY_BYTES', 128 * c_gib
    FROM   cap_fixture_osstat
    WHERE  stat_name = 'NUM_CPUS';

    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_HOST_RAM_GIB',   128);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_SGA_TARGET_GIB', 48);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_PGA_TARGET_GIB', 10);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_DBT_WIN',        v_all);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('MEM_RESIZE_AT',      v_base + c_shift + 9.5/24);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_RESIZE_OPS',     2);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_SHIFT_PCT',      100 / 48);
    -- PGA_LIMIT and the PGA_ALLOC_GB series.
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PGA_LIMIT_GIB', 20);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PGA_CUR_GIB',   11.5 + c_nd / 100);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PGA_SLOPE',     0.01);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PGA_DTL',       (20 * 0.90 - (11.5 + c_nd / 100)) / 0.01);
    INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('PGA_PEAK_AT', v_base + c_nd + 3/24, 100 * (11.5 + c_nd / 100) / 20);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PGA_HWM_GIB',   1.03 * (11.5 + c_nd / 100));
    -- PGA_TARGET.
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_PGA_GAIN',        pga_hit(10) - pga_hit(5));
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_PGA_NEAR_LOSS',   pga_hit(5) - pga_hit(4));
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_PGA_SUGGEST_MIB', 14 * 1024);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_PGA_ADV_OVER',    3 * 30);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_PGA_OAC',         3 * 30);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_PGA_MULTI',       100 * 150 / 48000);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_PGA_ONE',         100 * 1800 / 48000);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_PGA_TEMP',        c_temp);
    INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('MEM_PGA_AUTO_MIN', v_base + c_nd + 3/24, 30);
    -- BUFFER_CACHE.
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_CACHE_GAIN',       cache_pct(10) - cache_pct(16));
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_CACHE_SLACK_LOSS', cache_pct(5) - cache_pct(10));
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_CACHE_SLACK_MIB',  30 * 1024);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_CACHE_FBW',        0.02);
    -- SHARED_POOL.
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_SHP_GAIN',      shp_pct(11) - shp_pct(16));
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_SHP_NEAR_LOSS', shp_pct(10) - shp_pct(11));
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_SHP_WAIT',      0.03);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_SHP_RELOAD',    0.3);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_SHP_MISS',      1.5);
    INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('MEM_SHP_FREE_MIN', v_base + c_shift + (c_rsz_h - 1)/24, 100 * 0.35 / 8);
    -- SGA_TOTAL.
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_SGA_GAIN',       sga_pct(5) - sga_pct(9));
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_SGA_SLACK_LOSS', sga_pct(4) - sga_pct(5));
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('MEM_SGA_SLACK_MIB',  42 * 1024);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Memory chapter loaded: ' || v_snap.COUNT || ' snapshots, window DB time '
        || ROUND(v_all) || ' s, temp I/O ' || ROUND(100 * v_tf, 2) || '% of batch DB time');
END;
/
