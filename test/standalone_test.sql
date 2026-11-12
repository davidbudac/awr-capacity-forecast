--
-- test/standalone_test.sql -- assertions over the standalone queries.
-- =====================================================================
-- Checks standalone/tbspc_capacity.sql and standalone/tbspc_monitor.sql
-- against the designed series of test/standalone_fixture.sql. Every
-- expectation is a closed form from the series as designed there (sizes in
-- MiB, 1 GB = 1024 MiB), never the queries' own output.
--
-- The queries run as shipped. test/standalone_test.sh cuts each file's
-- SELECT (from "WITH prm AS (" to its closing semicolon) out of the file
-- and puts CREATE OR REPLACE VIEW in front of it, in the generated
-- test/standalone_gen/views.sql:
--   SA_CAP_V       tbspc_capacity.sql, unchanged
--   SA_CAP_Q0_V    ... with quiet_days 0 in prm
--   SA_CAP_DISK_V  ... with disk_free_gb 30.375 in prm
--   SA_MON_V       tbspc_monitor.sql, unchanged (alerts_only 1)
--   SA_MON_ALL_V   ... with alerts_only 0 in prm
-- This script reads those views once per (world, today) into SA_CAP and
-- SA_MON and asserts on the rows. Prints PASS / FAIL per check and a
-- RESULT line, and exits non-zero when a check fails.
--
-- Prereqs (same schema): test/standalone_fixture.sql, then the generated
-- views. Run all of it with test/standalone_test.sh <SCHEMA>.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/test/standalone_test.sql"
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF VERIFY OFF LINES 200 PAGES 0
WHENEVER SQLERROR EXIT FAILURE

-- The result tables: the view's columns behind (variant, world, asof_i).
DECLARE
    v_own   VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
    v_maint VARCHAR2(1);
BEGIN
    SELECT MAX(oracle_maintained) INTO v_maint FROM all_users WHERE username = v_own;
    IF v_maint IS NULL OR v_maint <> 'N' THEN
        RAISE_APPLICATION_ERROR(-20001,
            'standalone_test: CURRENT_SCHEMA ' || v_own || ' is not a test schema.');
    END IF;
    FOR r IN (SELECT object_name FROM all_objects
              WHERE  owner = v_own AND object_type = 'TABLE'
                AND  object_name IN ('SA_CAP', 'SA_MON')) LOOP
        EXECUTE IMMEDIATE 'DROP TABLE "' || v_own || '"."' || r.object_name || '" PURGE';
    END LOOP;
    EXECUTE IMMEDIATE 'CREATE TABLE "' || v_own || '".sa_cap AS
        SELECT CAST(NULL AS VARCHAR2(8)) AS variant, CAST(NULL AS VARCHAR2(8)) AS world,
               CAST(NULL AS NUMBER) AS asof_i, v.*
        FROM   sa_cap_v v WHERE 1 = 0';
    EXECUTE IMMEDIATE 'CREATE TABLE "' || v_own || '".sa_mon AS
        SELECT CAST(NULL AS VARCHAR2(8)) AS variant, CAST(NULL AS VARCHAR2(8)) AS world,
               CAST(NULL AS NUMBER) AS asof_i, v.*
        FROM   sa_mon_all_v v WHERE 1 = 0';
END;
/

-- Evaluate. W1 on the days the assertions name and on every day from 173
-- to 248 (the stopped month, from the day its STOP fires until its last
-- growth day has left the window). W2 and W3 on day 200.
DECLARE
    t0 NUMBER := DBMS_UTILITY.GET_TIME;
    n  PLS_INTEGER := 0;

    PROCEDURE ctx(p_world VARCHAR2, p_asof NUMBER) IS
    BEGIN
        UPDATE sa_ctx SET world = p_world, asof_i = p_asof;
    END;
    PROCEDURE cap(p_world VARCHAR2, p_asof NUMBER) IS
    BEGIN
        ctx(p_world, p_asof);
        INSERT INTO sa_cap SELECT 'SHIPPED', p_world, p_asof, v.* FROM sa_cap_v v;
        n := n + 1;
    END;
    PROCEDURE mon(p_world VARCHAR2, p_asof NUMBER) IS
    BEGIN
        ctx(p_world, p_asof);
        INSERT INTO sa_mon SELECT 'SHIPPED', p_world, p_asof, v.* FROM sa_mon_v v;
        INSERT INTO sa_mon SELECT 'ALL',     p_world, p_asof, v.* FROM sa_mon_all_v v;
        n := n + 2;
    END;
BEGIN
    FOR t IN 141 .. 248 LOOP
        IF t IN (141, 142, 145, 153, 154, 159, 163, 164, 165, 172) OR t >= 173 THEN
            cap('W1', t);
        END IF;
    END LOOP;
    mon('W1', 200);
    mon('W1', 246);
    ctx('W1', 200);
    INSERT INTO sa_cap SELECT 'Q0', 'W1', 200, v.* FROM sa_cap_q0_v v;

    cap('W2', 200);
    mon('W2', 200);
    INSERT INTO sa_cap SELECT 'DISK', 'W2', 200, v.* FROM sa_cap_disk_v v;

    cap('W3', 200);
    mon('W3', 200);

    ctx('W1', 200);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('evaluated ' || (n + 2) || ' query runs in '
                         || ROUND((DBMS_UTILITY.GET_TIME - t0) / 100) || ' s');
END;
/

DECLARE
    g_pass  PLS_INTEGER := 0;
    g_fail  PLS_INTEGER := 0;

    c_d0    CONSTANT DATE := DATE '2025-01-01';
    r       sa_cap%ROWTYPE;
    m       sa_mon%ROWTYPE;
    v_n     PLS_INTEGER;
    v_num   NUMBER;
    v_mb    NUMBER;
    v_r2    NUMBER;
    v_lbl   VARCHAR2(60);
    v_lo    NUMBER;
    v_hi    NUMBER;
    v_dlo   NUMBER;
    v_dhi   NUMBER;
    v_sum   NUMBER;

    PROCEDURE ok(p_name VARCHAR2, p_cond BOOLEAN, p_detail VARCHAR2 DEFAULT NULL) IS
    BEGIN
        IF p_cond THEN
            g_pass := g_pass + 1;
            DBMS_OUTPUT.PUT_LINE('  PASS  ' || p_name);
        ELSE
            g_fail := g_fail + 1;
            DBMS_OUTPUT.PUT_LINE('  FAIL  ' || p_name
                                 || CASE WHEN p_detail IS NOT NULL THEN '  (' || p_detail || ')' END);
        END IF;
    END;

    -- Null-safe equality: an expected NULL must read NULL.
    PROCEDURE eqn(p_name VARCHAR2, p_got NUMBER, p_exp NUMBER) IS
    BEGIN
        ok(p_name || ' = ' || NVL(TO_CHAR(p_exp), 'NULL'),
           (p_got IS NULL AND p_exp IS NULL) OR NVL(p_got = p_exp, FALSE),
           'got ' || NVL(TO_CHAR(p_got), 'NULL'));
    END;
    PROCEDURE eqs(p_name VARCHAR2, p_got VARCHAR2, p_exp VARCHAR2) IS
    BEGIN
        ok(p_name || ' = ' || NVL(p_exp, 'NULL'),
           (p_got IS NULL AND p_exp IS NULL) OR NVL(p_got = p_exp, FALSE),
           'got ' || NVL(p_got, 'NULL'));
    END;

    -- The capacity row of a tablespace. No row = a record of NULLs.
    FUNCTION cap(p_world VARCHAR2, p_asof NUMBER, p_ts VARCHAR2,
                 p_con VARCHAR2 DEFAULT 'PDB_A', p_variant VARCHAR2 DEFAULT 'SHIPPED')
        RETURN sa_cap%ROWTYPE IS
        x sa_cap%ROWTYPE;
    BEGIN
        SELECT c.* INTO x FROM sa_cap c
        WHERE  c.variant = p_variant AND c.world = p_world AND c.asof_i = p_asof
          AND  c.container = p_con AND c.tablespace = p_ts;
        RETURN x;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN RETURN x;
    END;
    FUNCTION mon(p_world VARCHAR2, p_asof NUMBER, p_ts VARCHAR2,
                 p_variant VARCHAR2 DEFAULT 'ALL')
        RETURN sa_mon%ROWTYPE IS
        x sa_mon%ROWTYPE;
    BEGIN
        SELECT c.* INTO x FROM sa_mon c
        WHERE  c.variant = p_variant AND c.world = p_world AND c.asof_i = p_asof
          AND  c.container = 'PDB_A' AND c.tablespace = p_ts;
        RETURN x;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN RETURN x;
    END;

    -- The least-squares line through days p_from .. p_to of a designed
    -- series, from the sums written out (not REGR_*): MB per day and R^2.
    -- For fit windows that mix a ramp and a flat part.
    PROCEDURE line(p_world VARCHAR2, p_ts VARCHAR2, p_from NUMBER, p_to NUMBER,
                   o_mb OUT NUMBER, o_r2 OUT NUMBER) IS
        n NUMBER; sx NUMBER; sy NUMBER; sxx NUMBER; syy NUMBER; sxy NUMBER;
    BEGIN
        SELECT COUNT(*), SUM(d.i), SUM(d.used_blk / 128), SUM(d.i * d.i),
               SUM(d.used_blk / 128 * d.used_blk / 128), SUM(d.i * d.used_blk / 128)
        INTO   n, sx, sy, sxx, syy, sxy
        FROM   sa_day d
        JOIN   sa_ts t ON t.world = d.world AND t.dbid = d.dbid
                      AND t.con_dbid = d.con_dbid AND t.ts# = d.ts#
        WHERE  d.world = p_world AND t.tsname = p_ts
          AND  t.con_dbid = TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_DBID'))
          AND  d.i BETWEEN p_from AND p_to;
        o_mb := (n * sxy - sx * sy) / (n * sxx - sx * sx);
        o_r2 := POWER(n * sxy - sx * sy, 2) / ((n * sxx - sx * sx) * (n * syy - sy * sy));
    END;

    -- The forecast columns of one capacity row. p_dtf_shared -1 = as p_dtf
    -- (no shared disk).
    PROCEDURE chk(p_lbl VARCHAR2, x sa_cap%ROWTYPE,
                  p_restart VARCHAR2, p_days NUMBER, p_mb_day NUMBER, p_quality VARCHAR2,
                  p_dtf NUMBER, p_status VARCHAR2, p_why VARCHAR2,
                  p_dtf_shared NUMBER DEFAULT -1) IS
    BEGIN
        eqs(p_lbl || ' restart',    x.restart,    p_restart);
        eqn(p_lbl || ' fit_days',   x.fit_days,   p_days);
        eqn(p_lbl || ' mb_day',     x.mb_day,     p_mb_day);
        eqs(p_lbl || ' quality',    x.quality,    p_quality);
        eqn(p_lbl || ' dtf',        x.dtf,        p_dtf);
        eqn(p_lbl || ' dtf_shared', x.dtf_shared,
            CASE WHEN p_dtf_shared = -1 THEN p_dtf ELSE p_dtf_shared END);
        eqs(p_lbl || ' status',     x.status,     p_status);
        eqs(p_lbl || ' why',        x.why,        p_why);
    END;
    -- The window starts fit_days - 1 days before the last sampled day.
    PROCEDURE chk_last(p_lbl VARCHAR2, x sa_cap%ROWTYPE, p_last_i NUMBER) IS
    BEGIN
        eqs(p_lbl || ' last_day', x.last_day, TO_CHAR(c_d0 + p_last_i, 'YYYY-MM-DD'));
    END;
BEGIN
    DBMS_OUTPUT.PUT_LINE('== W1 day 200: what is listed ==');
    SELECT COUNT(*) INTO v_n FROM sa_cap WHERE variant = 'SHIPPED' AND world = 'W1' AND asof_i = 200;
    eqn('W1@200 rows', v_n, 21);
    SELECT COUNT(*) INTO v_n FROM sa_cap
    WHERE  variant = 'SHIPPED' AND world = 'W1'
      AND  tablespace IN ('UNDO1', 'TEMP1', 'NOBS', 'SEEDTS', 'OLDTS');
    eqn('W1 UNDO / TEMP / no block size / seed / older DBID rows', v_n, 0);
    -- Same name and ts# in two containers stay apart.
    r := cap('W1', 200, 'STEADY', 'PDB_B');
    chk('W1@200 PDB_B.STEADY', r, NULL, 90, 0, 'FLAT', NULL, 'OK', NULL);
    eqn('W1@200 PDB_B.STEADY used_gb', r.used_gb, 2);
    -- No PDB name in AWR: the container reads the database name.
    r := cap('W1', 200, 'NONCDB_TS', 'SADB');
    eqn('W1@200 SADB.NONCDB_TS used_gb', r.used_gb, 1);
    -- Block size from the datafile dimension: 65536 blocks of 16 KiB.
    r := cap('W1', 200, 'BS16K');
    eqn('W1@200 BS16K used_gb', r.used_gb, 1);
    eqn('W1@200 BS16K limit_gb', r.limit_gb, 2);
    eqs('W1@200 BS16K lim', r.lim, 'AUTO');
    -- No live view row anywhere in W1: no shared disk.
    SELECT COUNT(*) INTO v_n FROM sa_cap
    WHERE  variant = 'SHIPPED' AND world = 'W1'
      AND  (disk_free_gb IS NOT NULL OR disk_dtf IS NOT NULL
            OR limit_shared_gb <> limit_gb
            OR NVL(dtf_shared, -1) <> NVL(dtf, -1)
            OR lim = 'LIVE');
    eqn('W1 rows with a shared disk', v_n, 0);
    -- DROPPED: last sample day 150. Listed while that is within stale_days
    -- (3) of the newest snapshot, its window counted back from day 150.
    r := cap('W1', 153, 'DROPPED');
    chk('W1@153 DROPPED', r, NULL, 90, 10, 'OK', FLOOR((8192 - 2524) / 10), 'OK', NULL);
    chk_last('W1@153 DROPPED', r, 150);
    r := cap('W1', 154, 'DROPPED');
    eqs('W1@154 DROPPED listed', r.tablespace, NULL);

    DBMS_OUTPUT.PUT_LINE('== steady grower: 10240 + 100 i MB, limit 64 GB ==');
    r := cap('W1', 200, 'STEADY');
    chk('W1@200 STEADY', r, NULL, 90, 100, 'OK', FLOOR((65536 - 30240) / 100), 'OK', NULL);
    chk_last('W1@200 STEADY', r, 200);
    eqs('W1@200 STEADY lim',       r.lim,       'AUTO');
    eqn('W1@200 STEADY used_gb',   r.used_gb,   ROUND(30240 / 1024, 3));
    eqn('W1@200 STEADY limit_gb',  r.limit_gb,  64);
    eqn('W1@200 STEADY pct',       r.pct,       ROUND(100 * 30240 / 65536, 1));
    eqn('W1@200 STEADY r2',        r.r2,        1);
    eqn('W1@200 STEADY gb_30',     r.gb_30,     ROUND((30240 + 3000) / 1024, 3));
    eqn('W1@200 STEADY gb_90',     r.gb_90,     ROUND((30240 + 9000) / 1024, 3));
    -- An exact line has no uncertainty: the worst case is the expected one.
    eqn('W1@200 STEADY dtf_worst', r.dtf_worst, 352);
    eqs('W1@200 STEADY full_by',   r.full_by,   TO_CHAR(c_d0 + 200 + 352, 'YYYY-MM-DD'));
    eqn('W1@200 STEADY add_gb_90', r.add_gb_90, 0);
    -- Never restarted, on any day evaluated.
    SELECT COUNT(*), SUM(CASE WHEN restart IS NULL AND fit_days = 90 AND mb_day = 100
                               AND quality = 'OK' THEN 1 ELSE 0 END)
    INTO   v_n, v_num
    FROM   sa_cap
    WHERE  variant = 'SHIPPED' AND world = 'W1' AND container = 'PDB_A' AND tablespace = 'STEADY';
    eqn('W1 STEADY days evaluated', v_n, 86);
    eqn('W1 STEADY days with no restart, 90 days, 100 MB a day, OK', v_num, 86);

    DBMS_OUTPUT.PUT_LINE('== status rules: 1000 MB a day, limit 30.5 .. 91.5 days away ==');
    r := cap('W1', 200, 'DTF30');
    chk('W1@200 DTF30', r, NULL, 31, 1000, 'OK', 30, 'CRIT', 'dtf <= 30');
    eqn('W1@200 DTF30 add_gb_90', r.add_gb_90, ROUND((90000 - 30500) / 1024, 3));
    r := cap('W1', 200, 'DTF31');
    chk('W1@200 DTF31', r, NULL, 31, 1000, 'OK', 31, 'WARN', 'dtf <= 90');
    r := cap('W1', 200, 'DTF90');
    chk('W1@200 DTF90', r, NULL, 31, 1000, 'OK', 90, 'WARN', 'dtf <= 90');
    r := cap('W1', 200, 'DTF91');
    chk('W1@200 DTF91', r, NULL, 31, 1000, 'OK', 91, 'OK', NULL);
    -- Autoextend off, 1000 MB allocated, flat.
    r := cap('W1', 200, 'PCT970');
    chk('W1@200 PCT970', r, NULL, 90, 0, 'FLAT', NULL, 'CRIT', 'pct >= 97');
    eqs('W1@200 PCT970 lim', r.lim, 'ALLOC');
    eqn('W1@200 PCT970 pct', r.pct, 97);
    r := cap('W1', 200, 'PCT969');
    chk('W1@200 PCT969', r, NULL, 90, 0, 'FLAT', NULL, 'WARN', 'pct >= 90');
    r := cap('W1', 200, 'PCT900');
    chk('W1@200 PCT900', r, NULL, 90, 0, 'FLAT', NULL, 'WARN', 'pct >= 90');
    r := cap('W1', 200, 'PCT899');
    chk('W1@200 PCT899', r, NULL, 90, 0, 'FLAT', NULL, 'OK', NULL);
    r := cap('W1', 200, 'SHORT');
    chk('W1@200 SHORT', r, NULL, 11, 0, 'INSUFFICIENT_HISTORY', NULL, 'OK', NULL);

    DBMS_OUTPUT.PUT_LINE('== a month: 1 GB until day 129, +1 GB a day on days 130 .. 159, then 31 GB. Limit 40.5 GB ==');
    -- Day 141: 12 growth days. START would leave 13 days (under
    -- min_train_days), so the whole window is fitted: flat, then a ramp.
    r := cap('W1', 141, 'SEP');
    line('W1', 'SEP', 52, 141, v_mb, v_r2);
    chk('W1@141 SEP', r, NULL, 90, ROUND(v_mb, 3), 'LOW_CONFIDENCE',
        FLOOR((41472 - 13312) / v_mb), 'OK', NULL);
    eqn('W1@141 SEP r2', r.r2, ROUND(v_r2, 3));
    -- Day 142: 13 growth days, 14 days left. Growth began: the fit starts
    -- on day 129 and is the ramp alone.
    r := cap('W1', 142, 'SEP');
    chk('W1@142 SEP', r, 'START', 14, 1024, 'OK', FLOOR(40.5 - 14), 'CRIT', 'dtf <= 30');
    r := cap('W1', 145, 'SEP');
    chk('W1@145 SEP', r, 'START', 17, 1024, 'OK', FLOOR(40.5 - 17), 'CRIT', 'dtf <= 30');
    eqn('W1@145 SEP r2', r.r2, 1);
    r := cap('W1', 159, 'SEP');
    chk('W1@159 SEP', r, 'START', 31, 1024, 'OK', FLOOR(40.5 - 31), 'CRIT', 'dtf <= 30');
    -- Day 172: 13 quiet days, one short of quiet_days. Still START, the fit
    -- is the ramp and the 13 flat days.
    r := cap('W1', 172, 'SEP');
    line('W1', 'SEP', 129, 172, v_mb, v_r2);
    chk('W1@172 SEP', r, 'START', 44, ROUND(v_mb, 3), 'OK',
        FLOOR((41472 - 31744) / v_mb), 'CRIT', 'dtf <= 30');
    -- From day 173 (14 quiet days) growth has stopped: the fit is the days
    -- after day 159, flat, no days to full. It must hold on every day until
    -- the last growth day has left the window: on day 246 two growth days
    -- are left in it, on day 247 one.
    FOR t IN 173 .. 247 LOOP
        r := cap('W1', t, 'SEP');
        v_lbl := 'W1@' || t || ' SEP';
        IF t IN (173, 200, 244, 245, 246, 247) THEN
            chk(v_lbl, r, 'STOP', t - 159, 0, 'FLAT', NULL, 'OK', NULL);
            eqn(v_lbl || ' gb_30', r.gb_30, 31);
            eqn(v_lbl || ' dtf_worst', r.dtf_worst, NULL);
        ELSE
            ok(v_lbl || ' STOP, ' || (t - 159) || ' days, FLAT, no dtf',
               NVL(r.restart = 'STOP' AND r.fit_days = t - 159 AND r.mb_day = 0
                   AND r.quality = 'FLAT' AND r.dtf IS NULL AND r.status = 'OK', FALSE),
               'got ' || r.restart || ' ' || r.fit_days || ' ' || r.mb_day || ' ' || r.quality
               || ' ' || r.dtf || ' ' || r.status);
        END IF;
    END LOOP;
    -- Day 248: the window starts on day 159 and is flat throughout.
    r := cap('W1', 248, 'SEP');
    chk('W1@248 SEP', r, NULL, 90, 0, 'FLAT', NULL, 'OK', NULL);
    -- quiet_days 0 switches STOP / START off: the whole window again.
    r := cap('W1', 200, 'SEP', p_variant => 'Q0');
    eqs('W1@200 SEP quiet_days 0 restart', r.restart, NULL);
    eqn('W1@200 SEP quiet_days 0 fit_days', r.fit_days, 90);
    r := cap('W1', 200, 'PURGE', p_variant => 'Q0');
    eqs('W1@200 PURGE quiet_days 0 restart', r.restart, 'PURGE');

    DBMS_OUTPUT.PUT_LINE('== one load: 20 GB, +30 GB on day 150. Limit 90 GB ==');
    -- Day 163: 13 quiet days. No restart yet: a step through 76 low and 14
    -- high days, slope 6 H a b / (n (n^2 - 1)), R^2 3 a b / (n^2 - 1).
    r := cap('W1', 163, 'BULK');
    chk('W1@163 BULK', r, NULL, 90, ROUND(6 * 30720 * 76 * 14 / (90 * 8099), 3), 'LOW_CONFIDENCE',
        FLOOR((92160 - 51200) / (6 * 30720 * 76 * 14 / (90 * 8099))), 'OK', NULL);
    eqn('W1@163 BULK r2', r.r2, ROUND(3 * 76 * 14 / 8099, 3));
    -- From day 164 (14 quiet days) one growth day is a load, not a rate.
    r := cap('W1', 164, 'BULK');
    chk('W1@164 BULK', r, 'STOP', 14, 0, 'FLAT', NULL, 'OK', NULL);
    -- Day 194: the load sits mid-window. A line through the step would read
    -- 512 MB a day at R^2 0.75, quality OK, full in 79 days.
    r := cap('W1', 194, 'BULK');
    chk('W1@194 BULK', r, 'STOP', 44, 0, 'FLAT', NULL, 'OK', NULL);
    r := cap('W1', 238, 'BULK');
    chk('W1@238 BULK', r, 'STOP', 88, 0, 'FLAT', NULL, 'OK', NULL);
    r := cap('W1', 239, 'BULK');
    chk('W1@239 BULK', r, NULL, 90, 0, 'FLAT', NULL, 'OK', NULL);
    r := cap('W1', 200, 'BULK', p_variant => 'Q0');
    eqs('W1@200 BULK quiet_days 0 restart', r.restart, NULL);

    DBMS_OUTPUT.PUT_LINE('== two growth days: 5 GB, +5 GB on days 150 and 151. Limit 20 GB ==');
    r := cap('W1', 164, 'TWO');
    eqs('W1@164 TWO restart (13 quiet days)', r.restart, NULL);
    eqn('W1@164 TWO fit_days', r.fit_days, 90);
    -- Day 165: chance (1 / 15)^2 = 0.0044.
    r := cap('W1', 165, 'TWO');
    chk('W1@165 TWO', r, 'STOP', 14, 0, 'FLAT', NULL, 'OK', NULL);
    -- Growth on days 150 and 153: s = 3. 26 quiet days: (3 / 29)^2 = 0.0107,
    -- not yet. 28 quiet days: (3 / 31)^2 = 0.0094, stopped.
    r := cap('W1', 179, 'TWOGAP');
    eqs('W1@179 TWOGAP restart (26 quiet days)', r.restart, NULL);
    eqn('W1@179 TWOGAP fit_days', r.fit_days, 90);
    r := cap('W1', 181, 'TWOGAP');
    chk('W1@181 TWOGAP', r, 'STOP', 28, 0, 'FLAT', NULL, 'OK', NULL);

    DBMS_OUTPUT.PUT_LINE('== rare steps: +5 GB on days 110 and 150. Limit 20 GB ==');
    -- Both steps in the window: the pause between them (39 days) is the
    -- yardstick, 45 or 48 quiet days are under twice that. Not stopped.
    r := cap('W1', 195, 'RARE');
    eqs('W1@195 RARE restart (45 quiet days)', r.restart, NULL);
    eqn('W1@195 RARE fit_days', r.fit_days, 90);
    r := cap('W1', 198, 'RARE');
    eqs('W1@198 RARE restart (48 quiet days)', r.restart, NULL);
    -- Day 199: the window starts on day 110, so one growth day is left.
    r := cap('W1', 199, 'RARE');
    chk('W1@199 RARE', r, 'STOP', 49, 0, 'FLAT', NULL, 'OK', NULL);
    r := cap('W1', 210, 'RARE');
    chk('W1@210 RARE', r, 'STOP', 60, 0, 'FLAT', NULL, 'OK', NULL);

    DBMS_OUTPUT.PUT_LINE('== weekly batch: +700 MB every seventh day. Limit 64 GB ==');
    -- All seven weekdays as today: 0 .. 6 quiet days, never a restart.
    FOR t IN 203 .. 209 LOOP
        r := cap('W1', t, 'WEEKLY');
        line('W1', 'WEEKLY', t - 89, t, v_mb, v_r2);
        chk('W1@' || t || ' WEEKLY', r, NULL, 90, ROUND(v_mb, 3), 'OK',
            FLOOR((65536 - (10240 + 700 * (FLOOR(t / 7) + 1))) / v_mb), 'OK', NULL);
    END LOOP;
    SELECT COUNT(*), SUM(CASE WHEN restart IS NULL AND fit_days = 90 AND quality = 'OK'
                              THEN 1 ELSE 0 END)
    INTO   v_n, v_num
    FROM   sa_cap
    WHERE  variant = 'SHIPPED' AND world = 'W1' AND tablespace = 'WEEKLY';
    eqn('W1 WEEKLY days evaluated', v_n, 86);
    eqn('W1 WEEKLY days with no restart, 90 days, OK', v_num, 86);

    DBMS_OUTPUT.PUT_LINE('== purge: 200 MB a day, -20 GB on day 180. Limit 82020 MB ==');
    r := cap('W1', 179, 'PURGE');
    chk('W1@179 PURGE', r, NULL, 90, 200, 'OK', FLOOR((82020 - 66520) / 200), 'WARN', 'dtf <= 90');
    r := cap('W1', 185, 'PURGE');
    chk('W1@185 PURGE', r, 'PURGE', 6, 200, 'INSUFFICIENT_HISTORY',
        FLOOR((82020 - 47240) / 200), 'OK', NULL);
    r := cap('W1', 200, 'PURGE');
    chk('W1@200 PURGE', r, 'PURGE', 21, 200, 'OK', FLOOR((82020 - 50240) / 200), 'OK', NULL);
    eqn('W1@200 PURGE r2', r.r2, 1);
    -- Three purges in the window: judged on the peak, 24740 of 26624 MB.
    r := cap('W1', 200, 'CYC');
    line('W1', 'CYC', 111, 200, v_mb, v_r2);
    chk('W1@200 CYC', r, NULL, 90, ROUND(v_mb, 3), 'CYCLIC', NULL, 'WARN', 'peak pct >= 90');
    eqn('W1@200 CYC peak_pct', r.peak_pct, ROUND(100 * 24740 / 26624, 1));
    eqn('W1@200 CYC gb_30', r.gb_30, NULL);

    DBMS_OUTPUT.PUT_LINE('== W2: four tablespaces on one disk, 60.75 GB free ==');
    -- A: 100 GB used, 110 allocated, 1 GB a day.     Files full day 10, own limit day 70.75.
    -- B:  50 GB used,  52 allocated, 0.5 GB a day.   Files full day 4,  own limit day 125.5.
    -- C:  20 GB used,  30 allocated, flat.
    -- D: 4000 MB used, 40.5 GB allocated, 100 MB a day. Files full day 374.72,
    --    own limit day 996.8.
    -- Disk: 3 GB taken by day 10, then 1.5 GB a day: full on day
    -- 10 + (60.75 - 3) / 1.5 = 48.5.
    SELECT COUNT(*), MIN(disk_free_gb), MAX(disk_free_gb), MIN(disk_dtf), MAX(disk_dtf),
           SUM(limit_shared_gb)
    INTO   v_n, v_lo, v_hi, v_dlo, v_dhi, v_sum
    FROM   sa_cap WHERE variant = 'SHIPPED' AND world = 'W2';
    eqn('W2 rows', v_n, 4);
    eqn('W2 disk_free_gb, lowest', v_lo, 60.75);
    eqn('W2 disk_free_gb, highest', v_hi, 60.75);
    eqn('W2 disk_dtf, lowest', v_dlo, 48);
    eqn('W2 disk_dtf, highest', v_dhi, 48);
    -- The shares of the free space add up to it.
    eqn('W2 sum of limit_shared_gb - allocated', v_sum - (110 + 52 + 30 + 40.5), 60.75);
    r := cap('W2', 200, 'DISK_A');
    chk('W2@200 DISK_A', r, NULL, 90, 1024, 'OK', 70, 'WARN', 'disk dtf <= 90', 48);
    eqs('W2@200 DISK_A lim', r.lim, 'LIVE');
    eqn('W2@200 DISK_A limit_gb', r.limit_gb, 170.75);
    eqn('W2@200 DISK_A limit_shared_gb', r.limit_shared_gb, 100 + 48.5);
    eqn('W2@200 DISK_A dtf_worst', r.dtf_worst, 70);
    eqn('W2@200 DISK_A dtf_shared_worst', r.dtf_shared_worst, 48);
    r := cap('W2', 200, 'DISK_B');
    chk('W2@200 DISK_B', r, NULL, 90, 512, 'OK', 125, 'WARN', 'disk dtf <= 90', 48);
    eqn('W2@200 DISK_B limit_gb', r.limit_gb, 112.75);
    eqn('W2@200 DISK_B limit_shared_gb', r.limit_shared_gb, 50 + 0.5 * 48.5);
    r := cap('W2', 200, 'DISK_C');
    chk('W2@200 DISK_C', r, NULL, 90, 0, 'FLAT', NULL, 'OK', NULL);
    eqn('W2@200 DISK_C limit_shared_gb', r.limit_shared_gb, 30);
    -- D still has room in its files when the disk is full: stuck on the
    -- day they are full, at the size it has allocated.
    r := cap('W2', 200, 'DISK_D');
    chk('W2@200 DISK_D', r, NULL, 41, 100, 'OK', 996, 'OK', NULL, 374);
    eqn('W2@200 DISK_D limit_shared_gb', r.limit_shared_gb, 40.5);
    -- disk_free_gb 30.375 set in prm: full on day 10 + (30.375 - 3) / 1.5
    -- = 28.25. The limits stay the live ceilings.
    r := cap('W2', 200, 'DISK_A', p_variant => 'DISK');
    chk('W2@200 DISK_A disk_free_gb 30.375', r, NULL, 90, 1024, 'OK', 70, 'CRIT', 'disk dtf <= 30', 28);
    eqn('W2@200 DISK_A disk_free_gb 30.375 disk_free_gb', r.disk_free_gb, 30.375);
    eqn('W2@200 DISK_A disk_free_gb 30.375 disk_dtf', r.disk_dtf, 28);
    eqn('W2@200 DISK_A disk_free_gb 30.375 limit_shared_gb', r.limit_shared_gb, 100 + 28.25);

    DBMS_OUTPUT.PUT_LINE('== W3: the monitoring rule ==');
    SELECT COUNT(*) INTO v_n FROM sa_mon WHERE variant = 'ALL' AND world = 'W3';
    eqn('W3 rows, alerts_only 0', v_n, 18);
    SELECT COUNT(*), COUNT(alert) INTO v_n, v_num FROM sa_mon WHERE variant = 'SHIPPED' AND world = 'W3';
    eqn('W3 rows, alerts_only 1', v_n, 17);
    eqn('W3 rows with an alert, alerts_only 1', v_num, 17);
    -- alerts_only changes the row set only.
    SELECT COUNT(*) INTO v_n
    FROM  (SELECT tablespace, alert, alert_why, live_pct, dtf_shared_worst, quality
           FROM   sa_mon WHERE variant = 'SHIPPED' AND world = 'W3'
           MINUS
           SELECT tablespace, alert, alert_why, live_pct, dtf_shared_worst, quality
           FROM   sa_mon WHERE variant = 'ALL' AND world = 'W3' AND alert IS NOT NULL);
    eqn('W3 alerts_only 1 rows not among the alerts_only 0 rows', v_n, 0);

    m := mon('W3', 200, 'M_MAX');
    eqs('W3 M_MAX alert', m.alert, 'CRIT');
    eqs('W3 M_MAX alert_why', m.alert_why, 'pct >= 95');
    eqn('W3 M_MAX live_pct', m.live_pct, 95);
    eqn('W3 M_MAX free_gb', m.free_gb, 2048 - 1946);
    -- 94.99 is under alert_pct_max. Big and flat: held back.
    m := mon('W3', 200, 'M_MAX_NO');
    eqs('W3 M_MAX_NO alert', m.alert, 'WATCH');
    eqs('W3 M_MAX_NO alert_why', m.alert_why, 'pct >= 90, not growing');
    m := mon('W3', 200, 'M_SMALL');
    eqs('W3 M_SMALL alert', m.alert, 'CRIT');
    eqs('W3 M_SMALL alert_why', m.alert_why, 'pct >= 90, under 1024 GB');
    eqn('W3 M_SMALL dtf_shared_worst', m.dtf_shared_worst, 80);
    -- Exactly alert_big_gb is big.
    m := mon('W3', 200, 'M_EDGE');
    eqs('W3 M_EDGE alert', m.alert, 'WATCH');
    eqs('W3 M_EDGE alert_why', m.alert_why, 'pct >= 90, not growing');
    m := mon('W3', 200, 'M_IH');
    eqs('W3 M_IH quality', m.quality, 'INSUFFICIENT_HISTORY');
    eqs('W3 M_IH alert', m.alert, 'CRIT');
    eqs('W3 M_IH alert_why', m.alert_why, 'pct >= 90, no trusted forecast');
    m := mon('W3', 200, 'M_CYC');
    eqs('W3 M_CYC quality', m.quality, 'CYCLIC');
    eqs('W3 M_CYC alert', m.alert, 'CRIT');
    eqs('W3 M_CYC alert_why', m.alert_why, 'pct >= 90, no trusted forecast');
    -- 90 MB up and down every day on 1 MB a day: R^2 0.24.
    m := mon('W3', 200, 'M_LC');
    eqs('W3 M_LC quality', m.quality, 'LOW_CONFIDENCE');
    eqs('W3 M_LC alert', m.alert, 'CRIT');
    eqs('W3 M_LC alert_why', m.alert_why, 'pct >= 90, no trusted forecast');
    -- 4 GB a day, 30.5 and 31.5 days from 2048 GB (M_SMALL: 1 GB a day, 80.5
    -- days from 1000 GB).
    m := mon('W3', 200, 'M_SOON');
    eqs('W3 M_SOON quality', m.quality, 'OK');
    eqn('W3 M_SOON mb_day', m.mb_day, 4096);
    eqn('W3 M_SOON dtf_shared_worst', m.dtf_shared_worst, 30);
    eqs('W3 M_SOON alert', m.alert, 'CRIT');
    eqs('W3 M_SOON alert_why', m.alert_why, 'pct >= 90, worst dtf <= 30');
    m := mon('W3', 200, 'M_LATE');
    eqn('W3 M_LATE dtf_shared_worst', m.dtf_shared_worst, 31);
    eqs('W3 M_LATE alert', m.alert, 'WATCH');
    eqs('W3 M_LATE alert_why', m.alert_why, 'pct >= 90, worst dtf > 30');
    m := mon('W3', 200, 'M_FLAT');
    eqs('W3 M_FLAT quality', m.quality, 'FLAT');
    eqs('W3 M_FLAT alert', m.alert, 'WATCH');
    eqs('W3 M_FLAT alert_why', m.alert_why, 'pct >= 90, not growing');
    -- One load of 300 GB 20 days ago: growth stopped, a confident FLAT.
    -- A line through the step would be LOW_CONFIDENCE (R^2 0.54) = CRIT.
    m := mon('W3', 200, 'M_STOPPED');
    eqs('W3 M_STOPPED quality', m.quality, 'FLAT');
    eqn('W3 M_STOPPED mb_day', m.mb_day, 0);
    eqs('W3 M_STOPPED alert', m.alert, 'WATCH');
    eqs('W3 M_STOPPED alert_why', m.alert_why, 'pct >= 90, not growing');
    r := cap('W3', 200, 'M_STOPPED');
    chk('W3@200 M_STOPPED', r, 'STOP', 20, 0, 'FLAT', NULL, 'WARN', 'pct >= 90');
    -- Shrinks 50 MB a day on an exact line: OK, and not growing.
    m := mon('W3', 200, 'M_SHRINK');
    eqs('W3 M_SHRINK quality', m.quality, 'OK');
    eqn('W3 M_SHRINK mb_day', m.mb_day, -50);
    eqs('W3 M_SHRINK alert', m.alert, 'WATCH');
    eqs('W3 M_SHRINK alert_why', m.alert_why, 'pct >= 90, not growing');
    m := mon('W3', 200, 'M_BELOW');
    eqs('W3 M_BELOW listed, alerts_only 0', m.tablespace, 'M_BELOW');
    eqs('W3 M_BELOW alert', m.alert, NULL);
    eqs('W3 M_BELOW alert_why', m.alert_why, NULL);
    m := mon('W3', 200, 'M_BELOW', 'SHIPPED');
    eqs('W3 M_BELOW listed, alerts_only 1', m.tablespace, NULL);
    m := mon('W3', 200, 'M_AT90');
    eqs('W3 M_AT90 alert', m.alert, 'WATCH');
    -- No live row: the AWR percent, 1966 of 2048 GB, and the AWR limit.
    m := mon('W3', 200, 'M_NOLIVE');
    eqn('W3 M_NOLIVE live_pct', m.live_pct, NULL);
    eqs('W3 M_NOLIVE alert', m.alert, 'CRIT');
    eqs('W3 M_NOLIVE alert_why', m.alert_why, 'pct >= 95');
    m := mon('W3', 200, 'M_NOLIVE_BIG');
    eqs('W3 M_NOLIVE_BIG alert', m.alert, 'WATCH');
    eqs('W3 M_NOLIVE_BIG alert_why', m.alert_why, 'pct >= 90, not growing');
    -- 1 MB a day, 164 GB left: 167936 days. Shown empty, still "> 30".
    m := mon('W3', 200, 'M_100Y');
    eqn('W3 M_100Y dtf_shared_worst', m.dtf_shared_worst, NULL);
    eqs('W3 M_100Y alert', m.alert, 'WATCH');
    eqs('W3 M_100Y alert_why', m.alert_why, 'pct >= 90, worst dtf > 30');
    -- M_STAIR: +8 GB and +0 in turn (m = d = 4096 MB a day), 147.5 GB left.
    -- OLS slope m - d x 22.5 / 60742.5 (90 days, the window starts on the
    -- high phase). Rates: sd = d SQRT(90 / 89), se = sd / SQRT(89),
    -- t = 1.96 + 2.4 / 88, so the worst rate adds 867.658 MB a day (the
    -- OLS model adds 16.7). Expected 36 days, worst case 30.
    v_mb  := 4096 * (1 - 22.5 / 60742.5);
    v_num := (1.96 + 2.4 / 88) * 4096 * SQRT(90) / 89;
    m := mon('W3', 200, 'M_STAIR');
    eqs('W3 M_STAIR quality', m.quality, 'OK');
    eqn('W3 M_STAIR mb_day', m.mb_day, ROUND(v_mb, 3));
    eqn('W3 M_STAIR dtf_shared', m.dtf_shared, FLOOR(147.5 * 1024 / v_mb));
    eqn('W3 M_STAIR dtf_shared_worst', m.dtf_shared_worst, FLOOR(147.5 * 1024 / (v_mb + v_num)));
    eqn('W3 M_STAIR dtf_shared_worst is 30', FLOOR(147.5 * 1024 / (v_mb + v_num)), 30);
    eqs('W3 M_STAIR alert', m.alert, 'CRIT');
    eqs('W3 M_STAIR alert_why', m.alert_why, 'pct >= 90, worst dtf <= 30');
    r := cap('W3', 200, 'M_STAIR');
    chk('W3@200 M_STAIR', r, NULL, 90, ROUND(v_mb, 3), 'OK', 36, 'WARN', 'pct >= 90');
    eqn('W3@200 M_STAIR dtf_worst', r.dtf_worst, 30);
    eqs('W3@200 M_STAIR full_by', r.full_by, TO_CHAR(c_d0 + 230, 'YYYY-MM-DD'));

    DBMS_OUTPUT.PUT_LINE('== both files: one forecast ==');
    -- Every row of the monitor (alerts_only 0) is a row of the capacity
    -- query with the same forecast, in all three worlds.
    SELECT COUNT(*) INTO v_n FROM sa_mon WHERE variant = 'ALL';
    SELECT COUNT(*) INTO v_num
    FROM   sa_mon a
    JOIN   sa_cap c
      ON   c.variant = 'SHIPPED' AND c.world = a.world AND c.asof_i = a.asof_i
     AND   c.container = a.container AND c.tablespace = a.tablespace
    WHERE  a.variant = 'ALL'
      AND  a.used_gb = c.used_gb AND a.limit_gb = c.limit_gb AND a.mb_day = c.mb_day
      AND  a.quality = c.quality AND a.last_day = c.last_day
      AND  NVL(a.dtf_shared, -1) = NVL(c.dtf_shared, -1)
      AND  NVL(a.dtf_shared_worst, -1) = NVL(c.dtf_shared_worst, -1);
    eqn('monitor rows (W1@200, W1@246, W2, W3)', v_n, 21 + 21 + 4 + 18);
    eqn('monitor rows equal to their capacity row', v_num, v_n);
    -- W2: the monitor's worst case is the shared disk's.
    m := mon('W2', 200, 'DISK_B');
    eqn('W2 DISK_B monitor dtf_shared_worst', m.dtf_shared_worst, 48);
    eqn('W2 DISK_B monitor live_pct', m.live_pct, 44.3);

    DBMS_OUTPUT.PUT_LINE('RESULT: ' || g_pass || ' passed, ' || g_fail || ' failed');
    IF g_fail > 0 THEN
        RAISE_APPLICATION_ERROR(-20002, g_fail || ' standalone assertion(s) failed');
    END IF;
    DBMS_OUTPUT.PUT_LINE('All standalone assertions passed.');
END;
/
