--
-- test/standalone_fixture.sql -- designed AWR sources for the standalone queries.
-- =====================================================================
-- standalone/tbspc_capacity.sql and standalone/tbspc_monitor.sql name their
-- sources unqualified. This script creates objects with those names in
-- CURRENT_SCHEMA (a throwaway test schema), so a session that runs with
-- ALTER SESSION SET CURRENT_SCHEMA = <schema> feeds the UNCHANGED files
-- with designed series instead of the real AWR:
--
--   DBA_HIST_SNAPSHOT, DBA_HIST_TABLESPACE, DBA_HIST_DATAFILE,
--   DBA_HIST_TBSPC_SPACE_USAGE, DBA_HIST_PDB_INSTANCE,
--   DBA_HIST_DATABASE_INSTANCE, CDB_TABLESPACE_USAGE_METRICS
--
-- They are views over four tables (SA_TS, SA_DAY, SA_SNAP, SA_CON) and the
-- one-row SA_CTX (world, asof_i), which picks what the views show:
--   world    one self-contained set of tablespaces. W1 = the growth shapes
--            (no live view rows, so no shared disk), W2 = tablespaces that
--            share one disk, W3 = the monitoring rule.
--   asof_i   "today" as a day index: the views show the snapshots up to day
--            DATE '2025-01-01' + asof_i. The queries take today from the
--            newest snapshot, so one series is judged on many days.
-- Each day has two snapshots: 06:00 with decoy sizes and 18:00 with the
-- designed ones (the queries must read the day's last).
--
-- Sizes below are MiB ("MB") unless a line says GB. 1 MB = 128 blocks of
-- 8192 bytes. test/standalone_test.sql holds the closed forms.
--
-- Idempotent: it drops its own objects first (the SA_ tables and views and
-- the seven source names, in CURRENT_SCHEMA only). It refuses to run in an
-- Oracle-maintained schema: there the source names are the real views.
--
--   SQL> ALTER SESSION SET CURRENT_SCHEMA = CAPS1
--   SQL> @test/standalone_fixture.sql
--
-- The lever test/standalone_test.sh <SCHEMA> runs it, then the test.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/test/standalone_fixture.sql"
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF VERIFY OFF LINES 200 PAGES 0
WHENEVER SQLERROR EXIT FAILURE

-- Every DDL runs inside this block, after the schema guard, on names
-- qualified with the schema: nothing can reach a real DBA_HIST view.
DECLARE
    v_own   VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
    v_maint VARCHAR2(1);

    PROCEDURE ddl(p_sql VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE REPLACE(p_sql, '@OWN@', '"' || v_own || '"');
    END;
BEGIN
    SELECT MAX(oracle_maintained) INTO v_maint FROM all_users WHERE username = v_own;
    IF v_maint IS NULL OR v_maint <> 'N' THEN
        RAISE_APPLICATION_ERROR(-20001,
            'standalone_fixture: CURRENT_SCHEMA ' || v_own || ' is not a test schema. '
            || 'ALTER SESSION SET CURRENT_SCHEMA to a throwaway schema first.');
    END IF;

    FOR r IN (SELECT object_name, object_type
              FROM   all_objects
              WHERE  owner = v_own
                AND  object_type IN ('VIEW', 'TABLE')
                AND  (object_name LIKE 'SA\_%' ESCAPE '\'
                      OR object_name IN ('DBA_HIST_SNAPSHOT', 'DBA_HIST_TABLESPACE',
                                         'DBA_HIST_DATAFILE', 'DBA_HIST_TBSPC_SPACE_USAGE',
                                         'DBA_HIST_PDB_INSTANCE', 'DBA_HIST_DATABASE_INSTANCE',
                                         'CDB_TABLESPACE_USAGE_METRICS'))
              ORDER  BY object_type DESC) LOOP
        ddl('DROP ' || r.object_type || ' @OWN@."' || r.object_name || '"'
            || CASE WHEN r.object_type = 'TABLE' THEN ' PURGE' END);
    END LOOP;

    ddl(q'[CREATE TABLE @OWN@.sa_ctx (
               world   VARCHAR2(8) NOT NULL,
               asof_i  NUMBER      NOT NULL)]');
    -- One row per tablespace. live_blk / live_pct NULL = no live view row.
    ddl(q'[CREATE TABLE @OWN@.sa_ts (
               world         VARCHAR2(8)   NOT NULL,
               dbid          NUMBER        NOT NULL,
               con_dbid      NUMBER        NOT NULL,
               con_id        NUMBER,
               ts#           NUMBER        NOT NULL,
               tsname        VARCHAR2(30)  NOT NULL,
               contents      VARCHAR2(9)   NOT NULL,
               block_size    NUMBER,
               df_block_size NUMBER,
               live_blk      NUMBER,
               live_pct      NUMBER,
               CONSTRAINT sa_ts_pk PRIMARY KEY (world, dbid, con_dbid, ts#))]');
    -- The designed series: the 18:00 sample of day i.
    ddl(q'[CREATE TABLE @OWN@.sa_day (
               world     VARCHAR2(8) NOT NULL,
               dbid      NUMBER      NOT NULL,
               con_dbid  NUMBER      NOT NULL,
               con_id    NUMBER,
               ts#       NUMBER      NOT NULL,
               i         NUMBER      NOT NULL,
               used_blk  NUMBER      NOT NULL,
               size_blk  NUMBER      NOT NULL,
               max_blk   NUMBER      NOT NULL,
               CONSTRAINT sa_day_pk PRIMARY KEY (world, dbid, con_dbid, ts#, i))]');
    ddl(q'[CREATE TABLE @OWN@.sa_snap (
               world  VARCHAR2(8) NOT NULL,
               dbid   NUMBER      NOT NULL,
               i      NUMBER      NOT NULL,
               CONSTRAINT sa_snap_pk PRIMARY KEY (world, dbid, i))]');
    ddl(q'[CREATE TABLE @OWN@.sa_con (
               world     VARCHAR2(8)   NOT NULL,
               dbid      NUMBER        NOT NULL,
               con_dbid  NUMBER,
               pdb_name  VARCHAR2(30),
               db_name   VARCHAR2(9))]');

    -- k = 0 the 06:00 snapshot (snap_id 2i), k = 1 the 18:00 one (2i + 1).
    ddl(q'[CREATE VIEW @OWN@.dba_hist_snapshot AS
           SELECT s.dbid, 2 * s.i + h.k AS snap_id, 1 AS instance_number,
                  CAST(DATE '2025-01-01' + s.i + DECODE(h.k, 0, 6, 18) / 24 AS TIMESTAMP(3)) AS end_interval_time
           FROM   sa_snap s
           JOIN   sa_ctx c ON c.world = s.world
           CROSS  JOIN (SELECT 0 AS k FROM dual UNION ALL SELECT 1 FROM dual) h
           WHERE  s.i <= c.asof_i]');
    ddl(q'[CREATE VIEW @OWN@.dba_hist_tbspc_space_usage AS
           SELECT d.dbid, d.con_dbid, d.con_id, 2 * d.i + h.k AS snap_id,
                  d.ts# AS tablespace_id,
                  CASE h.k WHEN 1 THEN d.used_blk ELSE 3 * d.used_blk + 1000 END AS tablespace_usedsize,
                  CASE h.k WHEN 1 THEN d.size_blk ELSE 3 * d.size_blk + 1000 END AS tablespace_size,
                  CASE h.k WHEN 1 THEN d.max_blk  ELSE d.max_blk + 7 END         AS tablespace_maxsize
           FROM   sa_day d
           JOIN   sa_ctx c ON c.world = d.world
           CROSS  JOIN (SELECT 0 AS k FROM dual UNION ALL SELECT 1 FROM dual) h
           WHERE  d.i <= c.asof_i]');
    ddl(q'[CREATE VIEW @OWN@.dba_hist_tablespace AS
           SELECT t.dbid, t.ts#, t.tsname, t.contents, t.block_size, t.con_dbid, t.con_id
           FROM   sa_ts t
           JOIN   sa_ctx c ON c.world = t.world]');
    ddl(q'[CREATE VIEW @OWN@.dba_hist_datafile AS
           SELECT t.dbid, 1 AS file#, t.ts#, t.tsname, t.df_block_size AS block_size, t.con_dbid, t.con_id
           FROM   sa_ts t
           JOIN   sa_ctx c ON c.world = t.world
           WHERE  t.df_block_size IS NOT NULL]');
    ddl(q'[CREATE VIEW @OWN@.dba_hist_pdb_instance AS
           SELECT k.dbid, k.con_dbid, k.pdb_name
           FROM   sa_con k
           JOIN   sa_ctx c ON c.world = k.world
           WHERE  k.pdb_name IS NOT NULL]');
    ddl(q'[CREATE VIEW @OWN@.dba_hist_database_instance AS
           SELECT k.dbid, k.db_name
           FROM   sa_con k
           JOIN   sa_ctx c ON c.world = k.world
           WHERE  k.db_name IS NOT NULL]');
    ddl(q'[CREATE VIEW @OWN@.cdb_tablespace_usage_metrics AS
           SELECT t.tsname AS tablespace_name,
                  ROUND(t.live_blk * t.live_pct / 100) AS used_space,
                  t.live_blk AS tablespace_size,
                  t.live_pct AS used_percent,
                  t.con_id
           FROM   sa_ts t
           JOIN   sa_ctx c ON c.world = t.world
           WHERE  t.live_blk IS NOT NULL]');
END;
/

DECLARE
    c_dbid   CONSTANT NUMBER := 9001;
    c_old    CONSTANT NUMBER := 9002;
    c_gb     CONSTANT NUMBER := 1024;
    -- The live view joins on CON_ID_TO_DBID(con_id), so the main container
    -- is the session's own: its con_id maps to its con_dbid.
    v_con    CONSTANT NUMBER := TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_DBID'));
    v_conid  CONSTANT NUMBER := TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_ID'));
    v_n      PLS_INTEGER;

    -- Used MB of series p_code on day i. NULL = no sample that day.
    FUNCTION f(p_code VARCHAR2, i PLS_INTEGER) RETURN NUMBER IS
    BEGIN
        RETURN CASE p_code
            -- ---- W1: growth shapes ----
            WHEN 'STEADY'  THEN 10240 + 100 * i
            -- a month's tablespace: empty, 30 days of 1 GB, then nothing
            WHEN 'SEP'     THEN CASE WHEN i < 130 THEN 1024
                                     WHEN i <= 159 THEN 1024 + 1024 * (i - 129)
                                     ELSE 31744 END
            -- one load of 30 GB on day 150
            WHEN 'BULK'    THEN CASE WHEN i < 150 THEN 20480 ELSE 51200 END
            -- 5 GB on day 150 and on day 151
            WHEN 'TWO'     THEN CASE WHEN i < 150 THEN 5120 WHEN i = 150 THEN 10240 ELSE 15360 END
            -- 5 GB on day 150 and on day 153
            WHEN 'TWOGAP'  THEN CASE WHEN i < 150 THEN 5120 WHEN i < 153 THEN 10240 ELSE 15360 END
            -- 5 GB on day 110 and on day 150
            WHEN 'RARE'    THEN CASE WHEN i < 110 THEN 5120 WHEN i < 150 THEN 10240 ELSE 15360 END
            -- 700 MB on every seventh day
            WHEN 'WEEKLY'  THEN 10240 + 700 * (FLOOR(i / 7) + 1)
            -- 200 MB a day, one purge of 20 GB on day 180
            WHEN 'PURGE'   THEN 30720 + 200 * i - CASE WHEN i >= 180 THEN 20480 ELSE 0 END
            -- fills 500 MB a day, purged every 30 days
            WHEN 'CYC'     THEN 10240 + 500 * MOD(i, 30)
            WHEN 'SHORT'   THEN CASE WHEN i >= 190 THEN 1024 END
            WHEN 'DROPPED' THEN CASE WHEN i <= 150 THEN 1024 + 10 * i END
            WHEN 'FAST'    THEN CASE WHEN i >= 170 THEN 1024 + 1000 * (i - 170) END
            WHEN 'F970'    THEN 970
            WHEN 'F969'    THEN 969
            WHEN 'F900'    THEN 900
            WHEN 'F899'    THEN 899
            WHEN 'F1G'     THEN 1024
            WHEN 'F2G'     THEN 2048
            WHEN 'OLD'     THEN CASE WHEN i <= 50 THEN 1024 + 500 * i END
            -- ---- W2: one shared disk, today = day 200 ----
            WHEN 'D_A'     THEN CASE WHEN i >= 100 THEN 1024 * (i - 100) END
            WHEN 'D_B'     THEN CASE WHEN i >= 100 THEN 512 * (i - 100) END
            WHEN 'D_C'     THEN CASE WHEN i >= 100 THEN 20480 END
            WHEN 'D_D'     THEN CASE WHEN i >= 160 THEN 100 * (i - 160) END
            -- ---- W3: the monitoring rule, today = day 200 ----
            WHEN 'M1946'   THEN CASE WHEN i >= 100 THEN 1946 * c_gb END
            WHEN 'M1900'   THEN CASE WHEN i >= 100 THEN 1900 * c_gb END
            WHEN 'M942'    THEN CASE WHEN i >= 100 THEN 942 * c_gb END
            WHEN 'M1966'   THEN CASE WHEN i >= 100 THEN 1966 * c_gb END
            WHEN 'M_SMALL' THEN CASE WHEN i >= 100 THEN (919.5 - (200 - i)) * c_gb END
            WHEN 'M_IH'    THEN CASE WHEN i >= 191 THEN 1900 * c_gb END
            WHEN 'M_CYC'   THEN CASE WHEN i >= 100 THEN (1500 + 10 * MOD(i, 30)) * c_gb END
            WHEN 'M_LC'    THEN CASE WHEN i >= 100 THEN 1900 * c_gb + 90 * MOD(i, 2) + i END
            WHEN 'M_SOON'  THEN CASE WHEN i >= 100 THEN (1926 - 4 * (200 - i)) * c_gb END
            WHEN 'M_LATE'  THEN CASE WHEN i >= 100 THEN (1922 - 4 * (200 - i)) * c_gb END
            WHEN 'M_STOP'  THEN CASE WHEN i >= 180 THEN 1900 * c_gb WHEN i >= 100 THEN 1600 * c_gb END
            WHEN 'M_SHRINK' THEN CASE WHEN i >= 100 THEN 1900 * c_gb + 50 * (200 - i) END
            WHEN 'M_100Y'  THEN CASE WHEN i >= 100 THEN 1884 * c_gb - (200 - i) END
            -- 8 GB on every second day: 4 GB a day, jumpy
            WHEN 'M_STAIR' THEN CASE WHEN i >= 100
                                     THEN 1500.5 * c_gb + 4 * c_gb * (i - 100) + 4 * c_gb * MOD(i, 2) END
        END;
    END;

    -- One tablespace and its series. p_max_mb 0 = autoextend off.
    PROCEDURE ts(p_world VARCHAR2, p_ts PLS_INTEGER, p_name VARCHAR2, p_code VARCHAR2,
                 p_alloc_mb NUMBER, p_max_mb NUMBER,
                 p_live_mb NUMBER DEFAULT NULL, p_live_pct NUMBER DEFAULT NULL,
                 p_contents VARCHAR2 DEFAULT 'PERMANENT',
                 p_bs NUMBER DEFAULT 8192, p_df_bs NUMBER DEFAULT 8192,
                 p_con NUMBER DEFAULT v_con, p_conid NUMBER DEFAULT v_conid,
                 p_dbid NUMBER DEFAULT c_dbid) IS
        v_bpm NUMBER := 1048576 / COALESCE(p_bs, p_df_bs, 8192);
        v_mb  NUMBER;
    BEGIN
        INSERT INTO sa_ts (world, dbid, con_dbid, con_id, ts#, tsname, contents,
                           block_size, df_block_size, live_blk, live_pct)
        VALUES (p_world, p_dbid, p_con, p_conid, p_ts, p_name, p_contents,
                p_bs, p_df_bs, p_live_mb * v_bpm, p_live_pct);
        FOR i IN 0 .. 259 LOOP
            v_mb := f(p_code, i);
            IF v_mb IS NOT NULL THEN
                INSERT INTO sa_day (world, dbid, con_dbid, con_id, ts#, i, used_blk, size_blk, max_blk)
                VALUES (p_world, p_dbid, p_con, p_conid, p_ts, i,
                        v_mb * v_bpm, p_alloc_mb * v_bpm, p_max_mb * v_bpm);
            END IF;
        END LOOP;
    END;
BEGIN
    INSERT INTO sa_ctx (world, asof_i) VALUES ('W1', 200);

    -- ================= W1: growth shapes, days 0 .. 259 =================
    INSERT INTO sa_snap (world, dbid, i)
    SELECT 'W1', c_dbid, LEVEL - 1 FROM dual CONNECT BY LEVEL <= 260;
    -- An older database in the same AWR: never the newest snapshot.
    INSERT INTO sa_snap (world, dbid, i)
    SELECT 'W1', c_old, LEVEL - 1 FROM dual CONNECT BY LEVEL <= 51;
    INSERT INTO sa_con VALUES ('W1', c_dbid, v_con, 'PDB_A', 'SADB');
    INSERT INTO sa_con VALUES ('W1', c_dbid, 777,   'PDB_B', NULL);
    INSERT INTO sa_con VALUES ('W1', c_dbid, 779,   'PDB$SEED', NULL);
    INSERT INTO sa_con VALUES ('W1', c_old,  880,   'PDB_OLD', 'OLDDB');

    ts('W1',  1, 'STEADY',  'STEADY',  65536, 65536);
    ts('W1',  2, 'SEP',     'SEP',     41472, 41472);
    ts('W1',  3, 'BULK',    'BULK',    92160, 92160);
    ts('W1',  4, 'TWO',     'TWO',     20480, 20480);
    ts('W1',  5, 'TWOGAP',  'TWOGAP',  20480, 20480);
    ts('W1',  6, 'RARE',    'RARE',    20480, 20480);
    ts('W1',  7, 'WEEKLY',  'WEEKLY',  65536, 65536);
    ts('W1',  8, 'PURGE',   'PURGE',   82020, 82020);
    ts('W1',  9, 'CYC',     'CYC',     26624, 26624);
    ts('W1', 10, 'SHORT',   'SHORT',   2048,  2048);
    ts('W1', 11, 'DROPPED', 'DROPPED', 8192,  8192);
    -- On day 200: used 31024 MB, 1000 MB a day, limit 30.5 / 31.5 / 90.5 /
    -- 91.5 days away.
    ts('W1', 12, 'DTF30',   'FAST',    31024 +  30500, 31024 +  30500);
    ts('W1', 13, 'DTF31',   'FAST',    31024 +  31500, 31024 +  31500);
    ts('W1', 14, 'DTF90',   'FAST',    31024 +  90500, 31024 +  90500);
    ts('W1', 15, 'DTF91',   'FAST',    31024 +  91500, 31024 +  91500);
    -- Autoextend off, 1000 MB allocated.
    ts('W1', 16, 'PCT970',  'F970',    1000, 0);
    ts('W1', 17, 'PCT969',  'F969',    1000, 0);
    ts('W1', 18, 'PCT900',  'F900',    1000, 0);
    ts('W1', 19, 'PCT899',  'F899',    1000, 0);
    ts('W1', 20, 'UNDO1',   'F1G',     2048, 2048, p_contents => 'UNDO');
    ts('W1', 21, 'TEMP1',   'F1G',     2048, 2048, p_contents => 'TEMPORARY');
    -- Block size only in the datafile dimension, and nowhere.
    ts('W1', 22, 'BS16K',   'F1G',     2048, 2048, p_bs => NULL, p_df_bs => 16384);
    ts('W1', 23, 'NOBS',    'F1G',     2048, 2048, p_bs => NULL, p_df_bs => NULL);
    -- Other containers: the same name and ts# in a second PDB, a container
    -- without a PDB name (reads the database name), the seed, the old DBID.
    ts('W1',  1, 'STEADY',    'F2G', 4096, 4096, p_con => 777, p_conid => 4);
    ts('W1',  1, 'NONCDB_TS', 'F1G', 2048, 2048, p_con => 778, p_conid => NULL);
    ts('W1',  1, 'SEEDTS',    'F1G', 2048, 2048, p_con => 779, p_conid => 2);
    ts('W1',  1, 'OLDTS',     'OLD', 65536, 65536, p_con => 880, p_conid => 5, p_dbid => c_old);

    -- ================= W2: one shared disk, today = day 200 =============
    -- Free on the disk: 60.75 GB = 62208 MB. Every live ceiling is the
    -- allocated size + that, below the autoextend maximum of 500 GB.
    INSERT INTO sa_snap (world, dbid, i)
    SELECT 'W2', c_dbid, 99 + LEVEL FROM dual CONNECT BY LEVEL <= 101;
    INSERT INTO sa_con VALUES ('W2', c_dbid, v_con, 'PDB_A', 'SADB');
    ts('W2', 1, 'DISK_A', 'D_A', 112640, 512000, 112640 + 62208, 58.6);
    ts('W2', 2, 'DISK_B', 'D_B',  53248, 512000,  53248 + 62208, 44.3);
    ts('W2', 3, 'DISK_C', 'D_C',  30720, 512000,  30720 + 62208, 22.0);
    ts('W2', 4, 'DISK_D', 'D_D',  41472, 512000,  41472 + 62208, 3.9);

    -- ================= W3: the monitoring rule, today = day 200 =========
    -- The live ceiling equals the autoextend maximum (no LIM LIVE, so no
    -- shared disk). live_pct is given, not derived: the rule reads it.
    INSERT INTO sa_snap (world, dbid, i)
    SELECT 'W3', c_dbid, 99 + LEVEL FROM dual CONNECT BY LEVEL <= 101;
    INSERT INTO sa_con VALUES ('W3', c_dbid, v_con, 'PDB_A', 'SADB');
    ts('W3',  1, 'M_MAX',        'M1946',   2048 * c_gb, 2048 * c_gb, 2048 * c_gb, 95);
    ts('W3',  2, 'M_MAX_NO',     'M1946',   2048 * c_gb, 2048 * c_gb, 2048 * c_gb, 94.99);
    ts('W3',  3, 'M_SMALL',      'M_SMALL', 1000 * c_gb, 1000 * c_gb, 1000 * c_gb, 92);
    ts('W3',  4, 'M_EDGE',       'M942',    1024 * c_gb, 1024 * c_gb, 1024 * c_gb, 92);
    ts('W3',  5, 'M_IH',         'M_IH',    2048 * c_gb, 2048 * c_gb, 2048 * c_gb, 92.77);
    ts('W3',  6, 'M_CYC',        'M_CYC',   2048 * c_gb, 2048 * c_gb, 2048 * c_gb, 91);
    ts('W3',  7, 'M_LC',         'M_LC',    2048 * c_gb, 2048 * c_gb, 2048 * c_gb, 92.8);
    ts('W3',  8, 'M_SOON',       'M_SOON',  2048 * c_gb, 2048 * c_gb, 2048 * c_gb, 94.04);
    ts('W3',  9, 'M_LATE',       'M_LATE',  2048 * c_gb, 2048 * c_gb, 2048 * c_gb, 93.85);
    ts('W3', 10, 'M_FLAT',       'M1900',   2048 * c_gb, 2048 * c_gb, 2048 * c_gb, 92.77);
    ts('W3', 11, 'M_STOPPED',    'M_STOP',  2048 * c_gb, 2048 * c_gb, 2048 * c_gb, 92.77);
    ts('W3', 12, 'M_SHRINK',     'M_SHRINK', 2048 * c_gb, 2048 * c_gb, 2048 * c_gb, 92.77);
    ts('W3', 13, 'M_BELOW',      'M1900',   2048 * c_gb, 2048 * c_gb, 2048 * c_gb, 89.99);
    ts('W3', 14, 'M_AT90',       'M1900',   2048 * c_gb, 2048 * c_gb, 2048 * c_gb, 90);
    ts('W3', 15, 'M_NOLIVE',     'M1966',   2048 * c_gb, 2048 * c_gb);
    ts('W3', 16, 'M_NOLIVE_BIG', 'M1900',   2048 * c_gb, 2048 * c_gb);
    ts('W3', 17, 'M_100Y',       'M_100Y',  2048 * c_gb, 2048 * c_gb, 2048 * c_gb, 92);
    ts('W3', 18, 'M_STAIR',      'M_STAIR', 2048 * c_gb, 2048 * c_gb, 2048 * c_gb, 92.8);

    COMMIT;

    SELECT COUNT(*) INTO v_n FROM sa_day;
    DBMS_OUTPUT.PUT_LINE('standalone fixture loaded in ' || SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
                         || ': ' || v_n || ' day rows, worlds W1 W2 W3.');
END;
/
