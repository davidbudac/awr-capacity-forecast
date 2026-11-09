--
-- standalone/tbspc_capacity.sql -- tablespace capacity forecast in ONE query.
-- =====================================================================
-- Runs directly on the measured database. Nothing to install: it reads
-- DBA_HIST_* (Diagnostics Pack) and creates, writes or changes nothing.
-- It is the suite's Tier 1 tablespace forecast (ddl/20 CAPD_TBSPC_DAILY +
-- ddl/30 CAPF_TBSPC_FORECAST, OLS only) cut down to one SELECT, with its
-- defaults inlined in the prm CTE instead of CAP_CONFIG. No ML, no
-- CAP_TBSPC_OVERRIDE, no anomaly scoring.
--
-- One row per (container, permanent tablespace) still sampled by AWR:
--   used / limit / pct    newest day's sample. limit = autoextend maxsize
--                         (LIM AUTO) or the allocated size (LIM ALLOC). An
--                         autoextend ceiling is only real when the
--                         filesystem / ASM diskgroup behind it can hold it.
--   mb_day / r2           OLS slope and R^2 over the last train_days days,
--                         restarted after the latest purge cliff (below)
--   gb_30 / gb_90         used projected 30 / 90 days ahead from today
--   dtf / dtf_worst       days until used reaches the limit at the fitted
--                         rate / at the top of its 95% CI. Empty = not
--                         growing, or more than 100 years away.
--   full_by               newest day + dtf_worst (the worst-case fill date)
--   add_gb_90             space to add so the high edge of the 95% band
--                         stays under the limit through +90 days
--   quality               INSUFFICIENT_HISTORY (< min_train_days days),
--                         CYCLIC (>= 2 purge cliffs, judged on peak_pct only),
--                         FLAT, LOW_CONFIDENCE (R^2 < r2_gate), OK
--   status / why          CRIT / WARN from pct used (any quality) or from
--                         dtf (quality OK only), else OK
--
-- Day series: the last snapshot of each day, blocks x block size. Purge
-- cliff: a day-over-day drop larger than GREATEST(shrink_mad_k x MAD sigma
-- of the window's deltas, abs_floor_bytes). One cliff restarts the fit at
-- that day. Bands: t ~ 1.96 + 2.4/(n-2), residual standard error, the OLS
-- new-observation half-width, drawn around today's value.
--
-- Where to run: CDB$ROOT (or a non-CDB) to see every container. The reading
-- user needs SELECT on DBA_HIST_SNAPSHOT, _TBSPC_SPACE_USAGE, _TABLESPACE,
-- _DATAFILE, _PDB_INSTANCE and _DATABASE_INSTANCE (SELECT_CATALOG_ROLE
-- does). A common user without CONTAINER_DATA = ALL sees the root only.
--
--   SQL> @standalone/tbspc_capacity.sql
--
-- The query alone (from WITH to the closing semicolon) also runs in SQL
-- Developer or any other client. Change the defaults in the prm CTE.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/standalone/tbspc_capacity.sql"
SET FEEDBACK OFF
SET VERIFY OFF
SET TRIMSPOOL ON
SET SQLBLANKLINES ON
SET LINESIZE 230
SET PAGESIZE 500

COLUMN container   FORMAT A16             HEADING 'CONTAINER'
COLUMN tablespace  FORMAT A24             HEADING 'TABLESPACE'
COLUMN lim         FORMAT A5              HEADING 'LIM'
COLUMN used_gb     FORMAT 9999990.0       HEADING 'USED_GB'
COLUMN limit_gb    FORMAT 9999990.0       HEADING 'LIMIT_GB'
COLUMN pct         FORMAT 990.0           HEADING 'PCT'
COLUMN mb_day      FORMAT 99999990.0      HEADING 'MB_DAY'
COLUMN r2          FORMAT 0.00            HEADING 'R2'
COLUMN fit_days    FORMAT 9990            HEADING 'DAYS'
COLUMN gb_30       FORMAT 9999990.0       HEADING 'GB_30'
COLUMN gb_90       FORMAT 9999990.0       HEADING 'GB_90'
COLUMN dtf         FORMAT 999990          HEADING 'DTF'
COLUMN dtf_worst   FORMAT 999990          HEADING 'DTF_WORST'
COLUMN full_by     FORMAT A10             HEADING 'FULL_BY'
COLUMN add_gb_90   FORMAT 9999990.0       HEADING 'ADD_GB_90'
COLUMN peak_pct    FORMAT 990.0           HEADING 'PEAK_PCT'
COLUMN quality     FORMAT A20             HEADING 'QUALITY'
COLUMN status      FORMAT A6              HEADING 'STATUS'
COLUMN why         FORMAT A16             HEADING 'WHY'
COLUMN last_day    FORMAT A10             HEADING 'LAST_DAY'

WITH prm AS (
        SELECT 90        AS train_days,         -- fit window, days
               14        AS min_train_days,     -- fewer days = INSUFFICIENT_HISTORY
               0.60      AS r2_gate,            -- R^2 below = LOW_CONFIDENCE
               6         AS shrink_mad_k,       -- purge cliff = drop > k x MAD sigma
               104857600 AS abs_floor_bytes,    -- ... and > 100 MiB
               2         AS cyclic_min_cliffs,  -- this many cliffs = CYCLIC
               90        AS dtf_warn,           -- days to full at/below = WARN
               30        AS dtf_crit,           -- days to full at/below = CRIT
               90        AS nearfull_warn_pct,  -- pct used at/above = WARN
               97        AS nearfull_crit_pct,  -- pct used at/above = CRIT
               3         AS stale_days,         -- unsampled this long = dropped, hidden
               CAST(NULL AS NUMBER) AS dbid     -- NULL = the dbid of the newest snapshot
        FROM   dual
     ),
     db AS (
        SELECT NVL(p.dbid,
                   (SELECT MAX(s.dbid) KEEP (DENSE_RANK LAST ORDER BY s.end_interval_time)
                    FROM   dba_hist_snapshot s)) AS dbid
        FROM   prm p
     ),
     snap AS (
        SELECT s.snap_id, MIN(s.end_interval_time) AS eit
        FROM   dba_hist_snapshot s
        JOIN   db ON db.dbid = s.dbid
        GROUP  BY s.snap_id
     ),
     newest AS (
        SELECT CAST(MAX(eit) AS DATE) AS newest_ts, TRUNC(MAX(eit)) AS newest_day
        FROM   snap
     ),
     -- Block size from the tablespace dimension, the datafiles as fallback
     -- (DBA_HIST_DATAFILE has no SYSTEM row on stock 19c).
     ts AS (
        SELECT t.con_dbid, t.ts#, t.tsname,
               COALESCE(t.block_size, f.block_size) AS block_size
        FROM   dba_hist_tablespace t
        JOIN   db ON db.dbid = t.dbid
        LEFT   JOIN (SELECT df.con_dbid, df.ts#, MAX(df.block_size) AS block_size
                     FROM   dba_hist_datafile df
                     JOIN   db ON db.dbid = df.dbid
                     GROUP  BY df.con_dbid, df.ts#) f
          ON   f.con_dbid = t.con_dbid AND f.ts# = t.ts#
        WHERE  t.contents NOT IN ('UNDO', 'TEMPORARY')
     ),
     -- Last sample of each day, read only as far back as the window needs.
     lod AS (
        SELECT u.con_dbid, u.tablespace_id,
               TRUNC(sn.eit) AS day_dt,
               MAX(u.tablespace_usedsize) KEEP (DENSE_RANK LAST ORDER BY sn.eit) AS used_blk,
               MAX(u.tablespace_size)     KEEP (DENSE_RANK LAST ORDER BY sn.eit) AS size_blk,
               MAX(u.tablespace_maxsize)  KEEP (DENSE_RANK LAST ORDER BY sn.eit) AS max_blk
        FROM   dba_hist_tbspc_space_usage u
        JOIN   db   ON db.dbid = u.dbid
        JOIN   snap sn ON sn.snap_id = u.snap_id
        CROSS  JOIN prm
        CROSS  JOIN newest n
        WHERE  NVL(u.con_id, 0) <> 2
          AND  sn.eit >= n.newest_day - prm.train_days - 1
        GROUP  BY u.con_dbid, u.tablespace_id, TRUNC(sn.eit)
     ),
     -- Container name: the PDB name, else (non-CDB) the database name.
     con AS (
        SELECT k.con_dbid,
               NVL((SELECT MAX(p.pdb_name) FROM dba_hist_pdb_instance p
                    WHERE  p.dbid = db.dbid AND p.con_dbid = k.con_dbid),
                   (SELECT MAX(i.db_name) FROM dba_hist_database_instance i
                    WHERE  i.dbid = db.dbid)) AS con_name
        FROM   (SELECT DISTINCT con_dbid FROM lod) k
        CROSS  JOIN db
     ),
     d AS (
        SELECT l.con_dbid, l.tablespace_id, t.tsname, l.day_dt,
               l.day_dt - DATE '2020-01-01'  AS day_n,
               l.used_blk * t.block_size      AS used_b,
               CASE WHEN l.max_blk > 0 THEN l.max_blk ELSE l.size_blk END * t.block_size AS limit_b,
               CASE WHEN l.max_blk > 0 THEN 'AUTO' ELSE 'ALLOC' END                        AS lim,
               MAX(l.day_dt) OVER (PARTITION BY l.con_dbid, l.tablespace_id)              AS last_day,
               l.used_blk * t.block_size
                 - LAG(l.used_blk * t.block_size) OVER (PARTITION BY l.con_dbid, l.tablespace_id
                                                        ORDER BY l.day_dt)                AS delta
        FROM   lod l
        JOIN   ts t ON t.con_dbid = l.con_dbid AND t.ts# = l.tablespace_id
        WHERE  t.block_size IS NOT NULL
     ),
     tw AS (
        SELECT d.* FROM d CROSS JOIN prm
        WHERE  d.day_dt > d.last_day - prm.train_days
     ),
     dmed AS (
        SELECT con_dbid, tablespace_id, MEDIAN(delta) AS dmed
        FROM   tw WHERE delta IS NOT NULL
        GROUP  BY con_dbid, tablespace_id
     ),
     dsig AS (
        SELECT t.con_dbid, t.tablespace_id,
               MEDIAN(ABS(t.delta - m.dmed)) * 1.4826 AS sig
        FROM   tw t
        JOIN   dmed m ON m.con_dbid = t.con_dbid AND m.tablespace_id = t.tablespace_id
        WHERE  t.delta IS NOT NULL
        GROUP  BY t.con_dbid, t.tablespace_id
     ),
     cliff AS (
        SELECT t.con_dbid, t.tablespace_id,
               COUNT(*)       AS n_cliffs,
               MAX(t.day_dt)  AS last_cliff
        FROM   tw t
        JOIN   dsig s ON s.con_dbid = t.con_dbid AND s.tablespace_id = t.tablespace_id
        CROSS  JOIN prm
        WHERE  t.delta < -GREATEST(prm.shrink_mad_k * s.sig, prm.abs_floor_bytes)
        GROUP  BY t.con_dbid, t.tablespace_id
     ),
     -- The effective window: restarted at the latest cliff unless CYCLIC.
     w AS (
        SELECT t.*, NVL(c.n_cliffs, 0) AS n_cliffs
        FROM   tw t
        CROSS  JOIN prm
        LEFT   JOIN cliff c ON c.con_dbid = t.con_dbid AND c.tablespace_id = t.tablespace_id
        WHERE  c.last_cliff IS NULL
           OR  c.n_cliffs >= prm.cyclic_min_cliffs
           OR  t.day_dt >= c.last_cliff
     ),
     fit AS (
        SELECT con_dbid, tablespace_id,
               MAX(tsname)                                          AS tsname,
               MAX(n_cliffs)                                        AS n_cliffs,
               MAX(last_day)                                        AS last_day,
               MAX(last_day) - DATE '2020-01-01'                    AS last_day_n,
               MIN(day_dt)                                          AS train_start,
               MAX(used_b) KEEP (DENSE_RANK LAST ORDER BY day_dt)   AS cur_b,
               MAX(limit_b) KEEP (DENSE_RANK LAST ORDER BY day_dt)  AS limit_b,
               MAX(lim) KEEP (DENSE_RANK LAST ORDER BY day_dt)      AS lim,
               MAX(used_b)                                          AS peak_b,
               REGR_SLOPE(used_b, day_n)                            AS slope,
               REGR_R2(used_b, day_n)                               AS r2,
               REGR_COUNT(used_b, day_n)                            AS n,
               REGR_SXX(used_b, day_n)                              AS sxx,
               REGR_SYY(used_b, day_n)                              AS syy,
               REGR_SXY(used_b, day_n)                              AS sxy,
               REGR_AVGX(used_b, day_n)                             AS xbar
        FROM   w
        GROUP  BY con_dbid, tablespace_id
     ),
     se AS (
        SELECT f.*,
               CASE WHEN f.n > 2 AND f.sxx > 0
                    THEN SQRT(GREATEST(0, f.syy - f.sxy * f.sxy / f.sxx) / (f.n - 2)) END AS resid_se,
               CASE WHEN f.n > 2 THEN 1.96 + 2.4 / (f.n - 2) END                         AS tval
        FROM   fit f
     ),
     band AS (
        SELECT s.*,
               CASE WHEN s.resid_se IS NOT NULL THEN
                 s.tval * s.resid_se * SQRT(1 + 1/s.n + POWER(s.last_day_n + 30 - s.xbar, 2) / s.sxx) END AS h30,
               CASE WHEN s.resid_se IS NOT NULL THEN
                 s.tval * s.resid_se * SQRT(1 + 1/s.n + POWER(s.last_day_n + 90 - s.xbar, 2) / s.sxx) END AS h90,
               CASE WHEN s.resid_se IS NOT NULL THEN
                 s.tval * s.resid_se / SQRT(s.sxx) END                                                     AS slope_ci
        FROM   se s
     ),
     fc AS (
        SELECT b.*,
               ROUND(100 * b.cur_b  / NULLIF(b.limit_b, 0), 1) AS pct,
               ROUND(100 * b.peak_b / NULLIF(b.limit_b, 0), 1) AS peak_pct,
               CASE WHEN b.n < prm.min_train_days                THEN 'INSUFFICIENT_HISTORY'
                    WHEN b.n_cliffs >= prm.cyclic_min_cliffs     THEN 'CYCLIC'
                    WHEN b.slope = 0 OR b.r2 IS NULL             THEN 'FLAT'
                    WHEN b.r2 < prm.r2_gate                      THEN 'LOW_CONFIDENCE'
                    ELSE                                              'OK'
               END AS quality,
               CASE WHEN b.n_cliffs < prm.cyclic_min_cliffs AND b.slope > 0
                    THEN GREATEST(0, FLOOR((b.limit_b - b.cur_b) / b.slope)) END             AS dtf_raw,
               CASE WHEN b.n_cliffs < prm.cyclic_min_cliffs AND b.slope > 0 AND b.slope_ci IS NOT NULL
                    THEN GREATEST(0, FLOOR((b.limit_b - b.cur_b) / (b.slope + b.slope_ci))) END AS dtf_worst_raw
        FROM   band b
        CROSS  JOIN prm
     ),
     res AS (
        SELECT f.*,
               CASE WHEN f.dtf_raw       <= 36500 THEN f.dtf_raw       END AS dtf,
               CASE WHEN f.dtf_worst_raw <= 36500 THEN f.dtf_worst_raw END AS dtf_worst
        FROM   fc f
     ),
     graded AS (
        SELECT r.*,
               CASE WHEN r.quality = 'CYCLIC' THEN r.peak_pct ELSE r.pct END AS judged_pct
        FROM   res r
     ),
     verdict AS (
        SELECT g.*,
               CASE WHEN g.judged_pct >= prm.nearfull_crit_pct THEN 'CRIT'
                    WHEN g.quality = 'OK' AND g.dtf <= prm.dtf_crit THEN 'CRIT'
                    WHEN g.judged_pct >= prm.nearfull_warn_pct THEN 'WARN'
                    WHEN g.quality = 'OK' AND g.dtf <= prm.dtf_warn THEN 'WARN'
                    ELSE 'OK'
               END AS status,
               CASE WHEN g.judged_pct >= prm.nearfull_crit_pct
                         THEN CASE WHEN g.quality = 'CYCLIC' THEN 'peak ' END || 'pct >= ' || prm.nearfull_crit_pct
                    WHEN g.quality = 'OK' AND g.dtf <= prm.dtf_crit THEN 'dtf <= ' || prm.dtf_crit
                    WHEN g.judged_pct >= prm.nearfull_warn_pct
                         THEN CASE WHEN g.quality = 'CYCLIC' THEN 'peak ' END || 'pct >= ' || prm.nearfull_warn_pct
                    WHEN g.quality = 'OK' AND g.dtf <= prm.dtf_warn THEN 'dtf <= ' || prm.dtf_warn
               END AS why
        FROM   graded g
        CROSS  JOIN prm
     )
SELECT c.con_name                                               AS container,
       v.tsname                                                 AS tablespace,
       v.lim,
       v.cur_b   / 1073741824                                   AS used_gb,
       v.limit_b / 1073741824                                   AS limit_gb,
       v.pct,
       v.slope / 1048576                                        AS mb_day,
       v.r2,
       v.n                                                      AS fit_days,
       CASE WHEN v.quality <> 'CYCLIC' THEN (v.cur_b + v.slope * 30) / 1073741824 END AS gb_30,
       CASE WHEN v.quality <> 'CYCLIC' THEN (v.cur_b + v.slope * 90) / 1073741824 END AS gb_90,
       v.dtf,
       v.dtf_worst,
       TO_CHAR(v.last_day + v.dtf_worst, 'YYYY-MM-DD')          AS full_by,
       CASE WHEN v.quality <> 'CYCLIC' AND v.h90 IS NOT NULL
            THEN GREATEST(0, v.cur_b + v.slope * 90 + v.h90 - v.limit_b) / 1073741824 END AS add_gb_90,
       CASE WHEN v.quality = 'CYCLIC' THEN v.peak_pct END       AS peak_pct,
       v.quality,
       v.status,
       v.why,
       TO_CHAR(v.last_day, 'YYYY-MM-DD')                        AS last_day
FROM   verdict v
JOIN   con c ON c.con_dbid = v.con_dbid
CROSS  JOIN newest n
CROSS  JOIN prm
WHERE  v.last_day >= n.newest_day - prm.stale_days
ORDER  BY DECODE(v.status, 'CRIT', 0, 'WARN', 1, 2),
          v.dtf_worst NULLS LAST,
          v.pct DESC NULLS LAST,
          c.con_name, v.tsname;

CLEAR COLUMNS
SET FEEDBACK ON
SET VERIFY ON
SET SQLBLANKLINES OFF
