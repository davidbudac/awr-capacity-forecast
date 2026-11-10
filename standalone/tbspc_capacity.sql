--
-- standalone/tbspc_capacity.sql -- tablespace capacity forecast in ONE query.
-- =====================================================================
-- Runs directly on the measured database. Nothing to install: it reads
-- DBA_HIST_* (Diagnostics Pack) and one live view, and creates, writes or
-- changes nothing. It is the suite's Tier 1 tablespace forecast (ddl/20
-- CAPD_TBSPC_DAILY + ddl/30 CAPF_TBSPC_FORECAST, slope_method 0) cut down
-- to one SELECT, with its defaults inlined in the prm CTE instead of
-- CAP_CONFIG. No ML, no CAP_TBSPC_OVERRIDE, no anomaly scoring. Four
-- things differ from the suite: the limit takes the live ceiling when that
-- is lower, the worst case takes the wider of two error models, every
-- tablespace is also forecast against the one disk they share, and the fit
-- restarts where growth stopped or began (all below).
--
-- One row per (container, permanent tablespace) still sampled by AWR:
--   used / limit / pct    newest day's sample. limit = autoextend maxsize
--                         (LIM AUTO) or the allocated size (LIM ALLOC), or
--                         the live ceiling when that is lower (LIM LIVE):
--                         CDB_TABLESPACE_USAGE_METRICS caps autoextend by
--                         the free space of the filesystem / ASM diskgroup
--                         now, AWR's maxsize does not. Each tablespace is
--                         capped alone, so tablespaces sharing storage can
--                         still add up to more than it holds.
--   mb_day / r2           OLS slope and R^2 over the fit window: the last
--                         train_days days, or the part of them since the
--                         latest restart
--   days / restart        days in the fit window, and why it is shorter
--                         than the history: PURGE (a purge cliff), STOP
--                         (no new high since: growth stopped), START
--                         (growth began inside the window). All below.
--   gb_30 / gb_90         used projected 30 / 90 days ahead from today
--   dtf / dtf_worst       days until used reaches the limit at the fitted
--                         rate / at the top of its 95% CI (worst case,
--                         below). Empty = not growing, or more than 100
--                         years away.
--   dtf_shared            days until the tablespace is stuck when all
--                         tablespaces grow on one shared disk: its own
--                         limit, or the first day it has to extend after
--                         the disk is full, whichever comes first. Below
--                         dtf = the disk stops it before its own limit.
--   limit_shared_gb       the largest size the tablespace reaches on that
--                         shared disk: its size on the day it is stuck.
--                         A tablespace that is not growing keeps the
--                         size it has allocated. Equal to limit_gb when
--                         the disk does not fill or disk_free_gb is empty.
--   dtf_shared_worst      dtf_shared when every tablespace grows at the
--                         top of its 95% CI at once (below). Empty = not
--                         growing, or too few days for a CI.
--   full_by               newest day + dtf_worst (the worst-case fill date)
--   add_gb_90             space to add so the high edge of the 95% band
--                         stays under the limit through +90 days
--   quality               INSUFFICIENT_HISTORY (< min_train_days days),
--                         CYCLIC (>= 2 purge cliffs, judged on peak_pct only),
--                         FLAT, LOW_CONFIDENCE (R^2 < r2_gate), OK
--   status / why          CRIT / WARN from pct used (any quality) or from
--                         dtf_shared (quality OK only), else OK. why reads
--                         "disk dtf" when the disk is what stops it.
--   disk_free_gb          free space on the shared disk now, the same on
--                         every row. Empty = not known (below).
--   disk_dtf              days until the shared disk is full, the same on
--                         every row. Empty = it does not fill, or more
--                         than 100 years away, or disk_free_gb is empty.
--
-- Day series: the last snapshot of each day, blocks x block size. Purge
-- cliff: a day-over-day drop larger than GREATEST(shrink_mad_k x MAD sigma
-- of the window's deltas, abs_floor_bytes). One cliff restarts the fit at
-- that day.
--
-- Growth that stopped or began (restart STOP / START): one line through
-- the whole window is wrong when the tablespace grew in only a part of it.
-- A growth day is a new high: used above every earlier day of the window
-- by more than growth_floor x the window's rise. A pause is a run of days
-- without one. The fit restarts
--   STOP   on the day after the last growth day, when the pause that runs
--          up to the newest day is long. A tablespace that stays flat
--          since then reads FLAT, no dtf.
--   START  on the last day before the first growth day, when the pause
--          before it is long and min_train_days days are left.
-- Long = all three of: quiet_days days or more. quiet_ratio x the longest
-- other pause or more (STOP: the pauses between two growth days. START:
-- those and the pause up to the newest day). And unlikely by chance: g
-- growth days that span s days make a pause of q days as likely as
-- (s / (s + q)) ^ (g - 1), which must be below quiet_chance. So a
-- tablespace that grows in rare steps or in monthly bursts keeps its whole
-- window, and one growth day alone never restarts it. Not for CYCLIC. A
-- rate that changes without a pause (fast to slow) is still averaged.
-- quiet_days 0 = no STOP / START.
--
-- Worst case (dtf_worst, full_by, add_gb_90): two error models around the
-- OLS slope and today's value, the wider one wins.
--   OLS    t ~ 1.96 + 2.4/(n-2), residual standard error, the slope CI and
--          the new-observation half-width.
--   rates  the day-over-day rates of the fit window (ddl/30's DRIFT sums):
--          sd of the rates, se = sd / SQRT(rates), t ~ 1.96 + 2.4/(rates-1),
--          slope CI = t x se, half-width at h = t x (sd x SQRT(h) + h x se).
-- used is a cumulative level, so its OLS residuals are autocorrelated and
-- the OLS model alone is too narrow. The suite uses OLS under slope_method
-- 0, so dtf_worst here is never later than the suite's days_to_full_lo.
-- The slope stays OLS: a tablespace grows an extent at a time, and the
-- median daily rate DRIFT fits is 0 for most real series.
--
-- Shared disk (dtf_shared, dtf_shared_worst, limit_shared_gb, disk_dtf):
-- every datafile is
-- taken to sit on one filesystem / diskgroup that gets no more storage.
-- Each tablespace grows at its own mb_day (any quality. CYCLIC and
-- shrinking ones count as not growing, a datafile never gives space back).
-- Growth first fills the free space inside the tablespace's files
-- (allocated - used) and only then takes from the disk, until the
-- tablespace reaches its own limit. The disk is full on the day those
-- takes add up to disk_free_gb. From then on a tablespace is stuck the
-- first time it has to extend, and the size it has then is
-- limit_shared_gb. Over all tablespaces, limit_shared_gb minus the
-- allocated size adds up to disk_free_gb: it is each one's share of the
-- free space. Everything else on the disk (UNDO, TEMP, redo, other files
-- and databases) is taken as constant.
-- dtf_shared_worst repeats the whole simulation with every tablespace at
-- mb_day + its slope CI (the rate behind dtf_worst), all at the same time:
-- the disk fills sooner and each tablespace is stuck sooner. All of them
-- at the top of their range together is less likely than any one of them,
-- so read it as the cautious edge, not as a 95% bound for the disk.
-- disk_free_gb comes from the live view: where Oracle caps a tablespace by
-- storage (LIM LIVE), ceiling - allocated is the free space, and the
-- smallest such value is used. No tablespace capped = not known, and
-- dtf_shared = dtf. Set disk_free_gb in prm (the df figure) to supply or
-- correct it. Run in CDB$ROOT: a PDB sees only its own tablespaces grow.
--
-- Stock AWR keeps 8 days, under min_train_days: every row then reads
-- INSUFFICIENT_HISTORY and status comes from pct alone. Raise the retention
-- (DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS) or lower the default.
--
-- Where to run: CDB$ROOT (or a non-CDB) to see every container. The reading
-- user needs SELECT on DBA_HIST_SNAPSHOT, _TBSPC_SPACE_USAGE, _TABLESPACE,
-- _DATAFILE, _PDB_INSTANCE, _DATABASE_INSTANCE and on
-- CDB_TABLESPACE_USAGE_METRICS (SELECT_CATALOG_ROLE has all seven). A
-- common user without CONTAINER_DATA = ALL sees the root only.
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
SET LINESIZE 325
SET PAGESIZE 500

COLUMN container   FORMAT A16             HEADING 'CONTAINER'
COLUMN tablespace  FORMAT A24             HEADING 'TABLESPACE'
COLUMN lim         FORMAT A5              HEADING 'LIM'
COLUMN used_gb     FORMAT 9999990.000     HEADING 'USED_GB'
COLUMN limit_gb    FORMAT 9999990.000     HEADING 'LIMIT_GB'
COLUMN pct         FORMAT 990.0           HEADING 'PCT'
COLUMN mb_day      FORMAT 99999990.000    HEADING 'MB_DAY'
COLUMN r2          FORMAT 0.000           HEADING 'R2'
COLUMN fit_days    FORMAT 9990            HEADING 'DAYS'
COLUMN restart     FORMAT A7              HEADING 'RESTART'
COLUMN gb_30       FORMAT 9999990.000     HEADING 'GB_30'
COLUMN gb_90       FORMAT 9999990.000     HEADING 'GB_90'
COLUMN dtf         FORMAT 999990          HEADING 'DTF'
COLUMN dtf_shared  FORMAT 999990          HEADING 'DTF_SHARED'
COLUMN limit_shared_gb FORMAT 9999990.000 HEADING 'LIMIT_SHARED_GB'
COLUMN dtf_worst   FORMAT 999990          HEADING 'DTF_WORST'
COLUMN dtf_shared_worst FORMAT 999990     HEADING 'DTF_SHARED_WORST'
COLUMN full_by     FORMAT A10             HEADING 'FULL_BY'
COLUMN add_gb_90   FORMAT 9999990.000     HEADING 'ADD_GB_90'
COLUMN peak_pct    FORMAT 990.0           HEADING 'PEAK_PCT'
COLUMN quality     FORMAT A20             HEADING 'QUALITY'
COLUMN status      FORMAT A6              HEADING 'STATUS'
COLUMN why         FORMAT A16             HEADING 'WHY'
COLUMN disk_free_gb FORMAT 9999990.000    HEADING 'DISK_FREE_GB'
COLUMN disk_dtf    FORMAT 999990          HEADING 'DISK_DTF'
COLUMN last_day    FORMAT A10             HEADING 'LAST_DAY'

WITH prm AS (
        SELECT 90        AS train_days,         -- fit window, days
               14        AS min_train_days,     -- fewer days = INSUFFICIENT_HISTORY
               0.60      AS r2_gate,            -- R^2 below = LOW_CONFIDENCE
               6         AS shrink_mad_k,       -- purge cliff = drop > k x MAD sigma
               104857600 AS abs_floor_bytes,    -- ... and > 100 MiB
               2         AS cyclic_min_cliffs,  -- this many cliffs = CYCLIC, below 2 = never
               14        AS quiet_days,         -- stopped / began = a pause this long, 0 = never ...
               2         AS quiet_ratio,        -- ... and this many x the longest other pause ...
               0.01      AS quiet_chance,       -- ... and less likely than this by chance
               0.001     AS growth_floor,       -- growth day = a new high by more than this x the rise
               90        AS dtf_warn,           -- days to full at/below = WARN
               30        AS dtf_crit,           -- days to full at/below = CRIT
               90        AS nearfull_warn_pct,  -- pct used at/above = WARN
               97        AS nearfull_crit_pct,  -- pct used at/above = CRIT
               3         AS stale_days,         -- unsampled this long = dropped, hidden
               CAST(NULL AS NUMBER) AS disk_free_gb, -- free GB on the shared disk, NULL = from the live view
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
        SELECT TRUNC(MAX(eit)) AS newest_day
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
     -- The live ceiling in bytes (header, LIM LIVE). The only read outside
     -- DBA_HIST. Without access to the view, give this CTE the body
     --   SELECT 0 AS con_dbid, 0 AS ts#, 0 AS cap_b FROM dual WHERE 1 = 0
     -- and the limit is AWR's alone. CON_ID_TO_DBID is 0 in a non-CDB.
     live AS (
        SELECT t.con_dbid, t.ts#, m.tablespace_size * t.block_size AS cap_b
        FROM   cdb_tablespace_usage_metrics m
        JOIN   ts t
          ON   t.tsname   = m.tablespace_name
         AND   t.con_dbid = NVL(NULLIF(CON_ID_TO_DBID(m.con_id), 0),
                                TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_DBID')))
        WHERE  m.tablespace_size > 0
     ),
     -- Last sample of each day, read only as far back as the window of a
     -- tablespace last sampled stale_days ago needs (plus the day before it,
     -- for that window's first delta).
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
          AND  sn.eit >= n.newest_day - prm.train_days - prm.stale_days - 1
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
               l.size_blk * t.block_size      AS alloc_b,
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
               MAX(t.day_dt)  AS last_cliff,
               CASE WHEN MAX(prm.cyclic_min_cliffs) >= 2
                     AND COUNT(*) >= MAX(prm.cyclic_min_cliffs)
                    THEN 1 ELSE 0 END AS is_cyclic
        FROM   tw t
        JOIN   dsig s ON s.con_dbid = t.con_dbid AND s.tablespace_id = t.tablespace_id
        CROSS  JOIN prm
        WHERE  t.delta < -GREATEST(prm.shrink_mad_k * s.sig, prm.abs_floor_bytes)
        GROUP  BY t.con_dbid, t.tablespace_id
     ),
     -- The days since the latest cliff (all of the window when CYCLIC),
     -- numbered. is_grow = a growth day (header, "Growth that stopped or
     -- began").
     cw AS (
        SELECT t.*, NVL(c.is_cyclic, 0) AS is_cyclic,
               CASE WHEN c.is_cyclic = 0 THEN 'PURGE' END AS cut,
               ROW_NUMBER() OVER (PARTITION BY t.con_dbid, t.tablespace_id
                                  ORDER BY t.day_dt)                 AS rn,
               COUNT(*)     OVER (PARTITION BY t.con_dbid, t.tablespace_id) AS rn_max,
               CASE WHEN t.used_b - MAX(t.used_b) OVER (PARTITION BY t.con_dbid, t.tablespace_id
                                                        ORDER BY t.day_dt
                                                        ROWS BETWEEN UNBOUNDED PRECEDING
                                                                 AND 1 PRECEDING)
                         > prm.growth_floor
                           * (MAX(t.used_b) OVER (PARTITION BY t.con_dbid, t.tablespace_id)
                            - MIN(t.used_b) OVER (PARTITION BY t.con_dbid, t.tablespace_id))
                    THEN 1 ELSE 0 END                                AS is_grow
        FROM   tw t
        LEFT   JOIN cliff c ON c.con_dbid = t.con_dbid AND c.tablespace_id = t.tablespace_id
        CROSS  JOIN prm
        WHERE  c.last_cliff IS NULL
           OR  c.is_cyclic = 1
           OR  t.day_dt >= c.last_cliff
     ),
     -- The growth days, each with the pause before it.
     gd AS (
        SELECT con_dbid, tablespace_id, rn, rn_max,
               rn - LAG(rn) OVER (PARTITION BY con_dbid, tablespace_id ORDER BY rn) - 1 AS gap
        FROM   cw
        WHERE  is_grow = 1 AND is_cyclic = 0
     ),
     -- g growth days that span span days. lead / trail = the pause before
     -- the first and after the last, gap_max = the longest one between.
     act AS (
        SELECT con_dbid, tablespace_id,
               COUNT(*)              AS g,
               MIN(rn)               AS rn_first,
               MAX(rn)               AS rn_last,
               MAX(rn) - MIN(rn)     AS span,
               MIN(rn) - 2           AS lead,
               MAX(rn_max) - MAX(rn) AS trail,
               NVL(MAX(gap), 0)      AS gap_max
        FROM   gd
        GROUP  BY con_dbid, tablespace_id
     ),
     -- Where growth stopped (the fit starts after the last growth day) or
     -- began (it starts on the day before the first). STOP wins.
     regime AS (
        SELECT a.con_dbid, a.tablespace_id,
               CASE WHEN a.is_stop = 1 THEN 'STOP'        ELSE 'START'        END AS cut,
               CASE WHEN a.is_stop = 1 THEN a.rn_last + 1 ELSE a.rn_first - 1 END AS rn_from
        FROM  (SELECT a.*,
                      CASE WHEN a.trail >= prm.quiet_days
                            AND a.trail >= prm.quiet_ratio * a.gap_max
                            AND POWER(a.span / NULLIF(a.span + a.trail, 0), a.g - 1) < prm.quiet_chance
                           THEN 1 ELSE 0 END AS is_stop,
                      CASE WHEN a.lead >= prm.quiet_days
                            AND a.lead >= prm.quiet_ratio * GREATEST(a.gap_max, a.trail)
                            AND POWER(a.span / NULLIF(a.span + a.lead, 0), a.g - 1) < prm.quiet_chance
                            AND a.span + a.trail + 2 >= prm.min_train_days
                           THEN 1 ELSE 0 END AS is_start
               FROM   act a
               CROSS  JOIN prm
               WHERE  prm.quiet_days > 0) a
        WHERE  a.is_stop = 1 OR a.is_start = 1
     ),
     -- The fit window. rate = the daily rate since the previous day of this
     -- window, so the first day has none and a reset day's cliff stays out.
     w AS (
        SELECT c.*, NVL(r.cut, c.cut) AS restart,
               (c.used_b - LAG(c.used_b) OVER (PARTITION BY c.con_dbid, c.tablespace_id
                                               ORDER BY c.day_dt))
             / (c.day_n - LAG(c.day_n) OVER (PARTITION BY c.con_dbid, c.tablespace_id
                                             ORDER BY c.day_dt))    AS rate
        FROM   cw c
        LEFT   JOIN regime r ON r.con_dbid = c.con_dbid AND r.tablespace_id = c.tablespace_id
        WHERE  c.rn >= NVL(r.rn_from, 1)
     ),
     fit AS (
        SELECT con_dbid, tablespace_id,
               MAX(tsname)                                          AS tsname,
               MAX(is_cyclic)                                       AS is_cyclic,
               MAX(restart)                                         AS restart,
               MAX(last_day)                                        AS last_day,
               MAX(last_day) - DATE '2020-01-01'                    AS last_day_n,
               MAX(used_b) KEEP (DENSE_RANK LAST ORDER BY day_dt)   AS cur_b,
               MAX(alloc_b) KEEP (DENSE_RANK LAST ORDER BY day_dt)  AS alloc_b,
               MAX(limit_b) KEEP (DENSE_RANK LAST ORDER BY day_dt)  AS awr_limit_b,
               MAX(lim) KEEP (DENSE_RANK LAST ORDER BY day_dt)      AS awr_lim,
               MAX(used_b)                                          AS peak_b,
               REGR_SLOPE(used_b, day_n)                            AS slope,
               REGR_R2(used_b, day_n)                               AS r2,
               REGR_COUNT(used_b, day_n)                            AS n,
               REGR_SXX(used_b, day_n)                              AS sxx,
               REGR_SYY(used_b, day_n)                              AS syy,
               REGR_SXY(used_b, day_n)                              AS sxy,
               REGR_AVGX(used_b, day_n)                             AS xbar,
               STDDEV_SAMP(rate)                                    AS rate_sd,
               COUNT(rate)                                          AS rate_n
        FROM   w
        GROUP  BY con_dbid, tablespace_id
     ),
     lim AS (
        SELECT f.*,
               LEAST(f.awr_limit_b, NVL(lv.cap_b, f.awr_limit_b))                AS limit_b,
               CASE WHEN lv.cap_b < f.awr_limit_b THEN 'LIVE' ELSE f.awr_lim END AS lim,
               lv.cap_b                                                          AS live_cap_b,
               CASE WHEN f.last_day >= n.newest_day - prm.stale_days
                    THEN 1 ELSE 0 END                                            AS is_current
        FROM   fit f
        LEFT   JOIN live lv ON lv.con_dbid = f.con_dbid AND lv.ts# = f.tablespace_id
        CROSS  JOIN newest n
        CROSS  JOIN prm
     ),
     se AS (
        SELECT f.*,
               CASE WHEN f.n > 2 AND f.sxx > 0
                    THEN SQRT(GREATEST(0, f.syy - f.sxy * f.sxy / f.sxx) / (f.n - 2)) END AS resid_se,
               CASE WHEN f.n > 2 THEN 1.96 + 2.4 / (f.n - 2) END                         AS tval,
               CASE WHEN f.rate_n > 1 THEN f.rate_sd / SQRT(f.rate_n) END                AS rate_se,
               CASE WHEN f.rate_n > 1 THEN 1.96 + 2.4 / (f.rate_n - 1) END               AS rate_t
        FROM   lim f
     ),
     -- The wider of the OLS and the rate model (header, "Worst case"). n > 2
     -- days leave at least two rates, so both sides exist together.
     band AS (
        SELECT s.*,
               CASE WHEN s.resid_se IS NOT NULL THEN GREATEST(
                 s.tval * s.resid_se * SQRT(1 + 1/s.n + POWER(s.last_day_n + 90 - s.xbar, 2) / s.sxx),
                 s.rate_t * (s.rate_sd * SQRT(90) + 90 * s.rate_se)) END AS h90,
               CASE WHEN s.resid_se IS NOT NULL THEN GREATEST(
                 s.tval * s.resid_se / SQRT(s.sxx),
                 s.rate_t * s.rate_se) END                               AS slope_ci
        FROM   se s
     ),
     -- Every forecast below runs twice. E: each tablespace grows at its
     -- fitted rate. W: each grows at the top of its 95% CI, all at once.
     scen AS (
        SELECT 'E' AS scen, 0 AS ci_k FROM dual
        UNION  ALL
        SELECT 'W', 1 FROM dual
     ),
     -- Per tablespace and scenario: its rate, and at that rate the days
     -- until its files are full (ext_days) and until its own limit
     -- (own_days). Not growing = all three NULL.
     path AS (
        SELECT p.*,
               (p.alloc_b - p.cur_b) / p.rate AS ext_days,
               (p.limit_b - p.cur_b) / p.rate AS own_days
        FROM  (SELECT b.con_dbid, b.tablespace_id, b.is_current, b.cur_b, b.alloc_b, b.limit_b,
                      sc.scen,
                      CASE WHEN b.is_cyclic = 0 AND b.slope > 0
                           THEN b.slope + sc.ci_k * NVL(b.slope_ci, 0) END AS rate
               FROM   band b
               CROSS  JOIN scen sc) p
     ),
     -- ---- Shared disk (header, "Shared disk") ----
     dfree AS (
        SELECT NVL(MAX(prm.disk_free_gb) * 1073741824,
                   GREATEST(0, MIN(CASE WHEN b.lim = 'LIVE' AND b.awr_lim = 'AUTO'
                                        THEN b.live_cap_b - b.alloc_b END))) AS free_b
        FROM   band b
        CROSS  JOIN prm
        WHERE  b.is_current = 1
     ),
     -- A growing tablespace takes from the disk from the day its files are
     -- full (ext_days) to the day it reaches its own limit (own_days).
     grower AS (
        SELECT p.scen, p.rate, GREATEST(0, p.ext_days) AS t_from, p.own_days AS t_to
        FROM   path p
        WHERE  p.is_current = 1
          AND  p.own_days > GREATEST(0, p.ext_days)
     ),
     -- The disk's daily take changes only on those days. One row per stretch
     -- between two of them: its rate, and what was taken before it starts.
     ev AS (
        SELECT scen, t, SUM(dr) AS dr
        FROM  (SELECT scen, t_from AS t, rate AS dr FROM grower
               UNION  ALL
               SELECT scen, t_to, -rate FROM grower)
        GROUP  BY scen, t
     ),
     seg AS (
        SELECT scen, t, rate, t_next,
               NVL(SUM(rate * (t_next - t)) OVER (PARTITION BY scen ORDER BY t
                                                  ROWS BETWEEN UNBOUNDED PRECEDING
                                                           AND 1 PRECEDING), 0) AS taken
        FROM  (SELECT scen, t,
                      SUM(dr) OVER (PARTITION BY scen ORDER BY t) AS rate,
                      LEAD(t) OVER (PARTITION BY scen ORDER BY t) AS t_next
               FROM   ev)
     ),
     -- full_day = the day the take reaches the free space, inside the one
     -- stretch that crosses it. The last stretch has every grower at its
     -- limit (rate 0) and is left out.
     disk AS (
        SELECT sc.scen,
               MAX(f.free_b) AS free_b,
               CASE WHEN MAX(f.free_b) <= 0 THEN 0
                    ELSE MIN(s.t + (f.free_b - s.taken) / s.rate) END AS full_day
        FROM   dfree f
        CROSS  JOIN scen sc
        LEFT   JOIN seg s
          ON   s.scen = sc.scen
         AND   s.t_next IS NOT NULL AND s.rate > 0
         AND   s.taken < f.free_b
         AND   s.taken + s.rate * (s.t_next - s.t) >= f.free_b
        GROUP  BY sc.scen
     ),
     -- stuck_days = the day the tablespace is stuck: at its own limit, or
     -- the first day it has to extend once the disk is full.
     stuck AS (
        SELECT p.con_dbid, p.tablespace_id, p.scen, p.rate, p.own_days,
               dk.free_b, dk.full_day,
               LEAST(p.own_days, NVL(GREATEST(dk.full_day, p.ext_days), p.own_days)) AS stuck_days
        FROM   path p
        JOIN   disk dk ON dk.scen = p.scen
     ),
     fc AS (
        SELECT b.*,
               ROUND(100 * b.cur_b  / NULLIF(b.limit_b, 0), 1) AS pct,
               ROUND(100 * b.peak_b / NULLIF(b.limit_b, 0), 1) AS peak_pct,
               CASE WHEN b.n < prm.min_train_days                THEN 'INSUFFICIENT_HISTORY'
                    WHEN b.is_cyclic = 1                         THEN 'CYCLIC'
                    WHEN b.slope = 0 OR b.r2 IS NULL             THEN 'FLAT'
                    WHEN b.r2 < prm.r2_gate                      THEN 'LOW_CONFIDENCE'
                    ELSE                                              'OK'
               END AS quality,
               GREATEST(0, FLOOR(e.own_days))                                   AS dtf_raw,
               GREATEST(0, FLOOR(e.stuck_days))                                 AS dtf_shared_raw,
               CASE WHEN b.slope_ci IS NOT NULL
                    THEN GREATEST(0, FLOOR(w.own_days)) END                     AS dtf_worst_raw,
               CASE WHEN b.slope_ci IS NOT NULL
                    THEN GREATEST(0, FLOOR(w.stuck_days)) END                   AS dtf_shared_worst_raw,
               CASE WHEN e.full_day IS NULL THEN b.limit_b
                    ELSE LEAST(b.limit_b,
                               GREATEST(b.alloc_b,
                                        b.cur_b + NVL(e.rate, 0) * e.full_day)) END AS limit_shared_b,
               e.free_b                                                         AS disk_free_b,
               FLOOR(e.full_day)                                                AS disk_dtf_raw
        FROM   band b
        JOIN   stuck e ON e.con_dbid = b.con_dbid AND e.tablespace_id = b.tablespace_id AND e.scen = 'E'
        JOIN   stuck w ON w.con_dbid = b.con_dbid AND w.tablespace_id = b.tablespace_id AND w.scen = 'W'
        CROSS  JOIN prm
     ),
     res AS (
        SELECT f.*,
               CASE WHEN f.dtf_raw              <= 36500 THEN f.dtf_raw              END AS dtf,
               CASE WHEN f.dtf_shared_raw       <= 36500 THEN f.dtf_shared_raw       END AS dtf_shared,
               CASE WHEN f.dtf_worst_raw        <= 36500 THEN f.dtf_worst_raw        END AS dtf_worst,
               CASE WHEN f.dtf_shared_worst_raw <= 36500 THEN f.dtf_shared_worst_raw END AS dtf_shared_worst,
               CASE WHEN f.disk_dtf_raw         <= 36500 THEN f.disk_dtf_raw         END AS disk_dtf
        FROM   fc f
     ),
     graded AS (
        SELECT r.*,
               CASE WHEN r.quality = 'CYCLIC' THEN r.peak_pct ELSE r.pct END AS judged_pct,
               CASE WHEN r.dtf_shared_raw < r.dtf_raw THEN 'disk ' END       AS stop_by
        FROM   res r
     ),
     verdict AS (
        SELECT g.*,
               CASE WHEN g.judged_pct >= prm.nearfull_crit_pct THEN 'CRIT'
                    WHEN g.quality = 'OK' AND g.dtf_shared <= prm.dtf_crit THEN 'CRIT'
                    WHEN g.judged_pct >= prm.nearfull_warn_pct THEN 'WARN'
                    WHEN g.quality = 'OK' AND g.dtf_shared <= prm.dtf_warn THEN 'WARN'
                    ELSE 'OK'
               END AS status,
               CASE WHEN g.judged_pct >= prm.nearfull_crit_pct
                         THEN CASE WHEN g.quality = 'CYCLIC' THEN 'peak ' END || 'pct >= ' || prm.nearfull_crit_pct
                    WHEN g.quality = 'OK' AND g.dtf_shared <= prm.dtf_crit
                         THEN g.stop_by || 'dtf <= ' || prm.dtf_crit
                    WHEN g.judged_pct >= prm.nearfull_warn_pct
                         THEN CASE WHEN g.quality = 'CYCLIC' THEN 'peak ' END || 'pct >= ' || prm.nearfull_warn_pct
                    WHEN g.quality = 'OK' AND g.dtf_shared <= prm.dtf_warn
                         THEN g.stop_by || 'dtf <= ' || prm.dtf_warn
               END AS why
        FROM   graded g
        CROSS  JOIN prm
     )
SELECT c.con_name                                               AS container,
       v.tsname                                                 AS tablespace,
       v.lim,
       ROUND(v.cur_b   / 1073741824, 3)                         AS used_gb,
       ROUND(v.limit_b / 1073741824, 3)                         AS limit_gb,
       v.pct,
       ROUND(v.slope / 1048576, 3)                              AS mb_day,
       ROUND(v.r2, 3)                                           AS r2,
       v.n                                                      AS fit_days,
       v.restart,
       CASE WHEN v.quality <> 'CYCLIC' THEN ROUND((v.cur_b + v.slope * 30) / 1073741824, 3) END AS gb_30,
       CASE WHEN v.quality <> 'CYCLIC' THEN ROUND((v.cur_b + v.slope * 90) / 1073741824, 3) END AS gb_90,
       v.dtf,
       v.dtf_shared,
       ROUND(v.limit_shared_b / 1073741824, 3)                  AS limit_shared_gb,
       v.dtf_worst,
       v.dtf_shared_worst,
       TO_CHAR(v.last_day + v.dtf_worst, 'YYYY-MM-DD')          AS full_by,
       CASE WHEN v.quality <> 'CYCLIC' AND v.h90 IS NOT NULL
            THEN ROUND(GREATEST(0, v.cur_b + v.slope * 90 + v.h90 - v.limit_b) / 1073741824, 3) END AS add_gb_90,
       CASE WHEN v.quality = 'CYCLIC' THEN v.peak_pct END       AS peak_pct,
       v.quality,
       v.status,
       v.why,
       ROUND(v.disk_free_b / 1073741824, 3)                     AS disk_free_gb,
       v.disk_dtf,
       TO_CHAR(v.last_day, 'YYYY-MM-DD')                        AS last_day
FROM   verdict v
JOIN   con c ON c.con_dbid = v.con_dbid
WHERE  v.is_current = 1
ORDER  BY DECODE(v.status, 'CRIT', 0, 'WARN', 1, 2),
          v.dtf_worst NULLS LAST,
          v.pct DESC NULLS LAST,
          c.con_name, v.tsname;

COLUMN container CLEAR
COLUMN tablespace CLEAR
COLUMN lim CLEAR
COLUMN used_gb CLEAR
COLUMN limit_gb CLEAR
COLUMN pct CLEAR
COLUMN mb_day CLEAR
COLUMN r2 CLEAR
COLUMN fit_days CLEAR
COLUMN restart CLEAR
COLUMN gb_30 CLEAR
COLUMN gb_90 CLEAR
COLUMN dtf CLEAR
COLUMN dtf_shared CLEAR
COLUMN limit_shared_gb CLEAR
COLUMN dtf_worst CLEAR
COLUMN dtf_shared_worst CLEAR
COLUMN full_by CLEAR
COLUMN add_gb_90 CLEAR
COLUMN peak_pct CLEAR
COLUMN quality CLEAR
COLUMN status CLEAR
COLUMN why CLEAR
COLUMN disk_free_gb CLEAR
COLUMN disk_dtf CLEAR
COLUMN last_day CLEAR
SET FEEDBACK ON
SET VERIFY ON
SET SQLBLANKLINES OFF
