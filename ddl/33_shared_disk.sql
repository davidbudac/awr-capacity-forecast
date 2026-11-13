--
-- ddl/33_shared_disk.sql -- every tablespace forecast against the disk they share.
-- =====================================================================
-- CAPF_TBSPC_FORECAST (ddl/30) looks at each tablespace alone: used against
-- its own limit. The datafiles sit on one filesystem or disk group, and a
-- tablespace that could still grow by its own limit is stuck once that disk
-- is full. This file forecasts all tablespaces of a database together. It is
-- the simulation of standalone/tbspc_capacity.sql (dtf_shared,
-- limit_shared_gb, dtf_shared_worst, disk_dtf; standalone/README.md step 8),
-- fed with the suite's fit.
--
--   CAPF_TBSPC_SHARED  one row per CAPF_TBSPC_FORECAST row: every column of
--                      it, then the shared-disk columns.
--   CAPF_DISK          one row per database and disk.
--
-- One disk per database: every datafile of every container of a dbid is
-- taken to sit on the same filesystem / disk group, which gets no more
-- storage. Datafiles are not mapped to devices or ASM disk groups (a
-- database on several is forecast as if on one). The disk is named by the
-- operator's CAP_DISK_OVERRIDE row, else DATAFILES.
--
-- Free space on the disk now, first match:
--   OVERRIDE  CAP_DISK_OVERRIDE.free_gb (ddl/05): the row of the dbid, else
--             the dbid = 0 row. A row with free_gb NULL only names the disk.
--   LIVE      derived from the live ceilings, CAPV_TBSPC_LIVE (the target's
--             CDB_TABLESPACE_USAGE_METRICS at the last collect). Oracle caps
--             a tablespace's largest size by the free space of the device:
--             where that ceiling is under the suite's AUTOEXTEND limit,
--             ceiling - allocated is the free space, and the smallest such
--             value over the current tablespaces is used. A copy collected
--             more than stale_days before the database's newest day is not
--             used.
--   NONE      not known. The disk columns are NULL and dtf_shared is the
--             days to the tablespace's own limit.
--
-- The tablespace's own limit here is LEAST(limit_bytes, a fresh live
-- ceiling) (limit_own_bytes, limit_live = 'Y' when the ceiling is the lower
-- one). limit_bytes and days_to_full of CAPF_TBSPC_FORECAST do not change.
--
-- The simulation, per database and scenario:
--   * A tablespace grows at slope_bpd (the row's estimator). CYCLIC, FLAT,
--     stopped and shrinking ones count as not growing: a datafile never
--     gives space back. Any other quality counts.
--   * Growth first fills the free space inside the files (allocated - used,
--     ext_days at its rate) and only then takes from the disk, until the
--     tablespace reaches its own limit (own_days).
--   * The disk is full on the day those takes add up to the free space
--     (disk_dtf). From then on a tablespace is stuck the first time it has
--     to extend:
--         dtf_shared = LEAST(own_days, GREATEST(disk day, ext_days))
--     and the size it has then is limit_shared_bytes (not growing: the
--     allocated size. Disk does not fill or is not known: limit_own_bytes).
--   * Scenario E uses slope_bpd. Scenario W (dtf_shared_worst,
--     disk_dtf_worst) gives every tablespace the rate behind
--     days_to_full_lo at the same time: ci_slope + slope_ci_bpd, ci_slope =
--     the OLS slope (DRIFT: the drift). A tablespace without a slope CI
--     keeps slope_bpd and reads dtf_shared_worst NULL.
-- Only current tablespaces (is_current = 'Y') take part. The shared columns
-- of a row that is not current are NULL.
--
-- Days count from the row's last_day (the disk: from newest_day) and read
-- NULL where that day plus the count would pass 9999-12-31, like
-- days_to_full. Every window partitions by dbid.
--
-- stopped_by: DISK when the disk stops the tablespace before its own limit
-- (dtf_shared < dtf_own), LIMIT when its own limit comes first, NULL when
-- it is not growing.
--
SET DEFINE OFF

CREATE OR REPLACE VIEW capf_tbspc_shared AS
WITH f AS (
        SELECT t.* FROM capf_tbspc_forecast t
     ),
     -- Allocated size and block size on the tablespace's newest day.
     a AS (
        SELECT dbid, con_dbid, tablespace_name,
               MAX(size_bytes) KEEP (DENSE_RANK LAST ORDER BY day_dt) AS alloc_bytes,
               MAX(block_size) KEEP (DENSE_RANK LAST ORDER BY day_dt) AS block_size
        FROM   capd_tbspc_daily
        GROUP  BY dbid, con_dbid, tablespace_name
     ),
     -- One live row per tablespace (the newest, should a copy hold several).
     lv AS (
        SELECT dbid, con_dbid, tablespace_name,
               MAX(ceiling_blocks) KEEP (DENSE_RANK LAST ORDER BY collected_at) AS ceiling_blocks,
               MAX(collected_at)                                              AS collected_at
        FROM   capv_tbspc_live
        WHERE  ceiling_blocks > 0
        GROUP  BY dbid, con_dbid, tablespace_name
     ),
     -- rate_e / rate_w: the growth rate in each scenario, NULL = not growing.
     -- cycle_peak_bytes is set on every CYCLIC window, at any train_n.
     b0 AS (
        SELECT f.dbid, f.con_dbid, f.tablespace_name, f.last_day, f.newest_day, f.is_current,
               f.cur_used, f.limit_bytes, f.limit_source, f.quality,
               a.alloc_bytes,
               CASE WHEN TRUNC(l.collected_at) >= f.newest_day - cfg.stale_days
                    THEN l.ceiling_blocks * a.block_size END                      AS live_bytes,
               CASE WHEN TRUNC(l.collected_at) >= f.newest_day - cfg.stale_days
                    THEN l.collected_at END                                       AS live_at,
               CASE WHEN f.cycle_peak_bytes IS NULL AND f.slope_bpd > 0
                    THEN f.slope_bpd END                                          AS rate_e,
               CASE f.slope_method WHEN 'DRIFT' THEN f.slope_bpd
                                   ELSE f.ols_slope_bpd END                       AS ci_slope,
               f.slope_ci_bpd
        FROM   f
        JOIN   a ON a.dbid = f.dbid AND a.con_dbid = f.con_dbid
                AND a.tablespace_name = f.tablespace_name
        LEFT   JOIN lv l ON l.dbid = f.dbid AND l.con_dbid = f.con_dbid
                        AND l.tablespace_name = f.tablespace_name
        CROSS  JOIN cap_cfg cfg
     ),
     b AS (
        SELECT b0.*,
               LEAST(b0.limit_bytes, NVL(b0.live_bytes, b0.limit_bytes))          AS own_limit,
               CASE WHEN b0.live_bytes < b0.limit_bytes THEN 'Y' ELSE 'N' END     AS limit_live,
               CASE WHEN b0.ci_slope > 0 AND b0.slope_ci_bpd IS NOT NULL
                    THEN 1 ELSE 0 END                                             AS has_ci,
               CASE WHEN b0.rate_e IS NULL THEN NULL
                    WHEN b0.ci_slope > 0 AND b0.slope_ci_bpd IS NOT NULL
                    THEN GREATEST(b0.rate_e, b0.ci_slope + b0.slope_ci_bpd)
                    ELSE b0.rate_e END                                            AS rate_w
        FROM   b0
     ),
     -- The operator's row for the database: its own before the dbid = 0 one.
     ovr AS (
        SELECT dbid, disk_name, free_gb, set_at
        FROM  (SELECT k.dbid, o.disk_name, o.free_gb, o.set_at,
                      ROW_NUMBER() OVER (PARTITION BY k.dbid
                                         ORDER BY CASE WHEN o.dbid <> 0 THEN 0 ELSE 1 END,
                                                  o.disk_name) AS rn
               FROM   (SELECT DISTINCT dbid FROM b) k
               JOIN   cap_disk_override o ON o.dbid = k.dbid OR o.dbid = 0)
        WHERE  rn = 1
     ),
     -- What the live ceilings say (header, LIVE).
     lvd AS (
        SELECT b.dbid,
               GREATEST(0, MIN(b.live_bytes - b.alloc_bytes)) AS live_free,
               MIN(b.live_at)                                 AS live_at
        FROM   b
        WHERE  b.is_current = 'Y'
          AND  b.limit_live = 'Y' AND b.limit_source = 'AUTOEXTEND'
        GROUP  BY b.dbid
     ),
     dfree AS (
        SELECT k.dbid,
               NVL(o.disk_name, 'DATAFILES')                                   AS disk_name,
               CASE WHEN o.free_gb IS NOT NULL THEN o.free_gb * 1073741824
                    ELSE v.live_free END                                       AS free_b,
               CASE WHEN o.free_gb IS NOT NULL   THEN 'OVERRIDE'
                    WHEN v.live_free IS NOT NULL THEN 'LIVE'
                    ELSE 'NONE' END                                            AS disk_source,
               CASE WHEN o.free_gb IS NOT NULL   THEN o.set_at
                    WHEN v.live_free IS NOT NULL THEN v.live_at END            AS disk_as_of
        FROM   (SELECT DISTINCT dbid FROM b) k
        LEFT   JOIN ovr o ON o.dbid = k.dbid
        LEFT   JOIN lvd v ON v.dbid = k.dbid
     ),
     scen AS (
        SELECT 'E' AS scen FROM dual
        UNION  ALL
        SELECT 'W' FROM dual
     ),
     -- Per tablespace and scenario: its rate, and at that rate the days
     -- until its files are full (ext_days) and until its own limit
     -- (own_days). Not growing = all three NULL.
     path AS (
        SELECT p.*,
               (p.alloc_bytes - p.cur_used) / p.rate AS ext_days,
               (p.own_limit   - p.cur_used) / p.rate AS own_days
        FROM  (SELECT b.dbid, b.con_dbid, b.tablespace_name, b.is_current,
                      b.cur_used, b.alloc_bytes, b.own_limit, sc.scen,
                      CASE sc.scen WHEN 'E' THEN b.rate_e ELSE b.rate_w END AS rate
               FROM   b
               CROSS  JOIN scen sc) p
     ),
     -- A growing tablespace takes from the disk from the day its files are
     -- full to the day it reaches its own limit.
     grower AS (
        SELECT p.dbid, p.scen, p.rate, GREATEST(0, p.ext_days) AS t_from, p.own_days AS t_to
        FROM   path p
        WHERE  p.is_current = 'Y'
          AND  p.own_days > GREATEST(0, p.ext_days)
     ),
     -- The disk's daily take changes only on those days. One row per stretch
     -- between two of them: its rate, and what was taken before it starts.
     ev AS (
        SELECT dbid, scen, t, SUM(dr) AS dr
        FROM  (SELECT dbid, scen, t_from AS t, rate AS dr FROM grower
               UNION  ALL
               SELECT dbid, scen, t_to, -rate FROM grower)
        GROUP  BY dbid, scen, t
     ),
     seg AS (
        SELECT dbid, scen, t, rate, t_next,
               NVL(SUM(rate * (t_next - t)) OVER (PARTITION BY dbid, scen ORDER BY t
                                                  ROWS BETWEEN UNBOUNDED PRECEDING
                                                           AND 1 PRECEDING), 0) AS taken
        FROM  (SELECT dbid, scen, t,
                      SUM(dr) OVER (PARTITION BY dbid, scen ORDER BY t) AS rate,
                      LEAD(t) OVER (PARTITION BY dbid, scen ORDER BY t) AS t_next
               FROM   ev)
     ),
     -- full_day = the day the take reaches the free space, inside the one
     -- stretch that crosses it. The last stretch has every grower at its
     -- limit (rate 0) and is left out.
     disk AS (
        SELECT d.dbid, sc.scen,
               CASE WHEN MAX(d.free_b) <= 0 THEN 0
                    ELSE MIN(s.t + (d.free_b - s.taken) / s.rate) END AS full_day
        FROM   dfree d
        CROSS  JOIN scen sc
        LEFT   JOIN seg s
          ON   s.dbid = d.dbid AND s.scen = sc.scen
         AND   s.t_next IS NOT NULL AND s.rate > 0
         AND   s.taken < d.free_b
         AND   s.taken + s.rate * (s.t_next - s.t) >= d.free_b
        GROUP  BY d.dbid, sc.scen
     ),
     -- stuck_days = the day the tablespace is stuck: at its own limit, or
     -- the first day it has to extend once the disk is full.
     stuck AS (
        SELECT p.dbid, p.con_dbid, p.tablespace_name, p.scen, p.rate,
               p.ext_days, p.own_days, k.full_day,
               LEAST(p.own_days, NVL(GREATEST(k.full_day, p.ext_days), p.own_days)) AS stuck_days
        FROM   path p
        JOIN   disk k ON k.dbid = p.dbid AND k.scen = p.scen
     ),
     r AS (
        SELECT b.dbid, b.con_dbid, b.tablespace_name, b.is_current,
               b.alloc_bytes, b.live_bytes, b.own_limit, b.limit_live,
               b.rate_e, b.rate_w, b.has_ci,
               e.ext_days,
               GREATEST(0, FLOOR(e.own_days))    AS dtf_own_raw,
               GREATEST(0, FLOOR(e.stuck_days))  AS dtf_shared_raw,
               GREATEST(0, FLOOR(w.stuck_days))  AS dtf_shared_worst_raw,
               CASE WHEN e.full_day IS NULL THEN b.own_limit
                    ELSE LEAST(b.own_limit,
                               GREATEST(b.alloc_bytes,
                                        b.cur_used + NVL(e.rate, 0) * e.full_day)) END AS limit_shared_bytes,
               e.full_day                        AS full_day_e,
               w.full_day                        AS full_day_w,
               DATE '9999-12-31' - b.last_day    AS max_days
        FROM   b
        JOIN   stuck e ON e.dbid = b.dbid AND e.con_dbid = b.con_dbid
                      AND e.tablespace_name = b.tablespace_name AND e.scen = 'E'
        JOIN   stuck w ON w.dbid = b.dbid AND w.con_dbid = b.con_dbid
                      AND w.tablespace_name = b.tablespace_name AND w.scen = 'W'
     )
SELECT f.*,
       d.disk_name,
       r.alloc_bytes,
       r.live_bytes                                              AS live_limit_bytes,
       r.own_limit                                               AS limit_own_bytes,
       r.limit_live,
       CASE WHEN r.is_current = 'Y' THEN r.rate_e END            AS grow_bpd,
       CASE WHEN r.is_current = 'Y' THEN r.rate_w END            AS grow_worst_bpd,
       CASE WHEN r.is_current = 'Y' THEN r.ext_days END          AS ext_days,
       CASE WHEN r.is_current = 'Y'
            THEN NULLIF(LEAST(r.dtf_own_raw, r.max_days), r.max_days) END          AS dtf_own,
       CASE WHEN r.is_current = 'Y'
            THEN NULLIF(LEAST(r.dtf_shared_raw, r.max_days), r.max_days) END       AS dtf_shared,
       CASE WHEN r.is_current = 'Y' AND r.has_ci = 1
            THEN NULLIF(LEAST(r.dtf_shared_worst_raw, r.max_days), r.max_days) END AS dtf_shared_worst,
       CASE WHEN r.is_current = 'Y' THEN r.limit_shared_bytes END                  AS limit_shared_bytes,
       CASE WHEN r.is_current = 'N' OR r.rate_e IS NULL THEN NULL
            WHEN r.dtf_shared_raw < r.dtf_own_raw THEN 'DISK'
            ELSE 'LIMIT' END                                                       AS stopped_by,
       d.free_b                                                  AS disk_free_bytes,
       r.full_day_e                                              AS disk_full_days,
       r.full_day_w                                              AS disk_full_days_worst,
       d.disk_source,
       d.disk_as_of
FROM   f
JOIN   r ON r.dbid = f.dbid AND r.con_dbid = f.con_dbid
        AND r.tablespace_name = f.tablespace_name
JOIN   dfree d ON d.dbid = f.dbid;

-- --------------------------------------------------------------------
-- CAPF_DISK -- one row per database and disk: the free space, where it
-- comes from and when the tablespaces' growth has used it.
--   disk_source      OVERRIDE / LIVE / NONE (header)
--   disk_as_of       OVERRIDE: the row's set_at. LIVE: the collect time of
--                    the ceilings used (the repository's clock)
--   disk_free_gb     free space now, GiB. NULL = not known
--   disk_dtf         days from newest_day until the disk is full at the
--                    fitted rates. NULL = it does not fill (every grower
--                    reaches its own limit first, or nothing grows), or the
--                    free space is not known. 0 = no free space
--   disk_dtf_worst   the same with every tablespace at its worst-case rate
--   disk_full_day    newest_day + disk_dtf
--   n_tbspc          current tablespaces on the disk
--   n_growing        of them, growing (grow_bpd set)
--   n_growing_ok     of those, at fit quality OK: DISK_FULL needs one
--   grow_bpd, grow_worst_bpd  their rates summed, bytes a day now
--   alloc_gb         allocated to the current tablespaces, GiB
--   top_growers      the three fastest growing tablespaces, fastest first,
--                    each 'NAME <MiB a day>' (a PDB's as 'PDB:NAME'),
--                    joined with ', '. NULL when none grows
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capf_disk AS
SELECT s.dbid,
       s.disk_name,
       MAX(s.disk_source)                                         AS disk_source,
       MAX(s.disk_as_of)                                          AS disk_as_of,
       MAX(s.disk_free_bytes) / 1073741824                        AS disk_free_gb,
       NULLIF(LEAST(FLOOR(MAX(s.disk_full_days)), DATE '9999-12-31' - MAX(s.newest_day)),
              DATE '9999-12-31' - MAX(s.newest_day))              AS disk_dtf,
       NULLIF(LEAST(FLOOR(MAX(s.disk_full_days_worst)), DATE '9999-12-31' - MAX(s.newest_day)),
              DATE '9999-12-31' - MAX(s.newest_day))              AS disk_dtf_worst,
       MAX(s.newest_day)
         + NULLIF(LEAST(FLOOR(MAX(s.disk_full_days)), DATE '9999-12-31' - MAX(s.newest_day)),
                  DATE '9999-12-31' - MAX(s.newest_day))          AS disk_full_day,
       MAX(s.newest_day)                                          AS newest_day,
       COUNT(CASE WHEN s.is_current = 'Y' THEN 1 END)             AS n_tbspc,
       COUNT(s.grow_bpd)                                          AS n_growing,
       COUNT(CASE WHEN s.quality = 'OK' THEN s.grow_bpd END)      AS n_growing_ok,
       NVL(SUM(s.grow_bpd), 0)                                    AS grow_bpd,
       NVL(SUM(s.grow_worst_bpd), 0)                              AS grow_worst_bpd,
       SUM(CASE WHEN s.is_current = 'Y' THEN s.alloc_bytes END) / 1073741824 AS alloc_gb,
       LISTAGG(CASE WHEN s.grow_rank <= 3 AND s.grow_bpd IS NOT NULL
                    THEN CASE WHEN s.con_dbid <> s.dbid AND s.con_name IS NOT NULL
                              THEN s.con_name || ':' END
                         || s.tablespace_name || ' '
                         || TO_CHAR(s.grow_bpd / 1048576, 'FM99999990.0') END, ', ')
           WITHIN GROUP (ORDER BY s.grow_rank)                    AS top_growers
FROM  (SELECT t.dbid, t.con_dbid, t.tablespace_name, t.disk_name, t.disk_source, t.disk_as_of,
              t.disk_free_bytes, t.disk_full_days, t.disk_full_days_worst, t.newest_day,
              t.is_current, t.quality, t.grow_bpd, t.grow_worst_bpd, t.alloc_bytes,
              c.con_name,
              ROW_NUMBER() OVER (PARTITION BY t.dbid, t.disk_name
                                 ORDER BY t.grow_bpd DESC NULLS LAST,
                                          t.con_dbid, t.tablespace_name) AS grow_rank
       FROM   capf_tbspc_shared t
       LEFT   JOIN capv_container c
         ON   c.dbid = t.dbid AND c.con_dbid = t.con_dbid) s
GROUP  BY s.dbid, s.disk_name;
