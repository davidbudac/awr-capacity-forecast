--
-- ddl/42_memory_views.sql -- CAPM_* instance memory verdicts (M25).
-- =====================================================================
-- A verdict layer beside forecast and anomaly: per database, instance and
-- memory area a grade (UNDERSIZED / OK / OVERSIZED / INSUFFICIENT_EVIDENCE,
-- for SGA_BALANCE OK / THRASHING), the evidence behind it and a suggested
-- size. Advice for reports: no alert reads it, and the suite never changes a
-- parameter. docs/specs/memory-sizing.md is the design.
--
-- Areas: PGA_LIMIT (usage against the ceiling), the four advisor-based
-- areas PGA_TARGET, BUFFER_CACHE, SHARED_POOL and SGA_TOTAL, and
-- SGA_BALANCE (resize activity). The layers, bottom up:
--   CAPM_SNAP         the snapshot spine: window, startup, previous snapshot.
--   CAPM_INST         one row per instance: window, mode, parameters, host RAM.
--   CAPM_ADV_SRC      the four advisors in one shape, sizes in bytes.
--   CAPM_DELTA        every counter and advisor estimate as increments
--                     between snapshots of one startup, one long shape.
--   CAPM_ADVICE       per advised size: cost and gain against the current size.
--   CAPM_PGA_LIMIT    the facts of area PGA_LIMIT.
--   CAPM_AREA         the facts of each advisor-based area.
--   CAPM_SGA_BALANCE  resize facts of the SGA pools.
--   CAPM_EVIDENCE     one row per signal: measured value, unit, threshold,
--                     direction (PRESSURE / SLACK / NEUTRAL) and a sentence.
--   CAPM_VERDICT      one row per (dbid, instance_number, area): the grade,
--                     from the evidence counts, the area's facts and one
--                     decision table.
--
-- The evidence window is per dbid: the mem_window_days days up to the dbid's
-- newest snapshot end time (never SYSDATE), snapshots with end time >
-- window_end - mem_window_days. Instance-level areas are filed under
-- con_dbid = dbid, the root, as AWR records instance memory there.
--
-- Reads CAPV_* and CAP_CFG only. Every window partitions by dbid
-- (test/lint_dbid_windows.sh). 19c: inline OVER (...) on every window call.
--
SET DEFINE OFF

-- --------------------------------------------------------------------
-- CAPM_SNAP -- one row per (dbid, instance_number, snap_id).
--   window_start / window_end  the dbid's evidence window; in_win = Y for a
--                       snapshot that ended inside it.
--   prev_snap_id / prev_end_time / ivl_hours  the previous snapshot of the
--                       same startup (dbid, instance_number, startup_time),
--                       NULL for a startup's first snapshot, so nothing is
--                       ever differenced across a restart.
--   latest_snap_id      the instance's newest snapshot.
--   uptime_hours        the startup's observed uptime: its last snapshot end
--                       minus its startup time (minus its first snapshot end
--                       where the seam carries no startup time).
--   seg_ok              Y when uptime_hours >= mem_min_uptime_hours. Advisor
--                       increments of a shorter startup do not count (a cold
--                       cache distorts the estimates). Its symptoms do.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capm_snap AS
WITH s AS (
        SELECT dbid, instance_number, snap_id, startup_time,
               CAST(end_interval_time AS DATE) AS end_time,
               CAST(startup_time AS DATE)      AS startup_dt
        FROM   capv_snapshot
     ),
     a AS (
        SELECT s.*,
               MAX(s.end_time) OVER (PARTITION BY s.dbid)                    AS window_end,
               MAX(s.snap_id)  OVER (PARTITION BY s.dbid, s.instance_number) AS latest_snap_id,
               LAG(s.snap_id)  OVER (PARTITION BY s.dbid, s.instance_number, s.startup_time
                                     ORDER BY s.snap_id)                     AS prev_snap_id,
               LAG(s.end_time) OVER (PARTITION BY s.dbid, s.instance_number, s.startup_time
                                     ORDER BY s.snap_id)                     AS prev_end_time,
               (MAX(s.end_time) OVER (PARTITION BY s.dbid, s.instance_number, s.startup_time)
                - NVL(s.startup_dt,
                      MIN(s.end_time) OVER (PARTITION BY s.dbid, s.instance_number, s.startup_time))
               ) * 24                                                        AS uptime_hours
        FROM   s
     )
SELECT a.dbid,
       a.instance_number,
       a.snap_id,
       a.end_time,
       a.startup_time,
       a.startup_dt,
       a.prev_snap_id,
       a.prev_end_time,
       ROUND((a.end_time - a.prev_end_time) * 86400) / 3600  AS ivl_hours,
       a.window_end - cfg.mem_window_days                    AS window_start,
       a.window_end,
       CAST(CASE WHEN a.end_time > a.window_end - cfg.mem_window_days THEN 'Y' ELSE 'N' END
            AS VARCHAR2(1))                                  AS in_win,
       a.latest_snap_id,
       a.uptime_hours,
       CAST(CASE WHEN a.uptime_hours >= cfg.mem_min_uptime_hours THEN 'Y' ELSE 'N' END
            AS VARCHAR2(1))                                  AS seg_ok
FROM   a
CROSS  JOIN cap_cfg cfg;

-- --------------------------------------------------------------------
-- CAPM_INST -- one row per (dbid, instance_number) with a snapshot in the
-- evidence window: what every area's facts share.
--   mem_mode            AMM when memory_target > 0, else ASMM when
--                       sga_target > 0, else MANUAL; NULL without parameters.
--                       Parameters are read at the instance's latest
--                       snapshot that carries them: a verdict is about the
--                       current setting.
--   pga_limit_bytes     pga_aggregate_limit, NULL when 0 (no limit) or missing.
--   sga_bytes           GREATEST(sga_max_size, sga_target), for the host
--                       memory flag of the PGA areas.
--   host_ram_bytes      the latest PHYSICAL_MEMORY_BYTES of CAPV_OSSTAT,
--                       NULL when AWR has none.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capm_inst AS
WITH inst AS (
        SELECT dbid, instance_number,
               MAX(window_start)   AS window_start,
               MAX(window_end)     AS window_end,
               MAX(latest_snap_id) AS latest_snap_id
        FROM   capm_snap
        WHERE  in_win = 'Y'
        GROUP  BY dbid, instance_number
     ),
     prm AS (
        SELECT dbid, instance_number,
               MAX(CASE WHEN parameter_name = 'memory_target'        THEN v END) AS memory_target,
               MAX(CASE WHEN parameter_name = 'sga_target'           THEN v END) AS sga_target,
               MAX(CASE WHEN parameter_name = 'sga_max_size'         THEN v END) AS sga_max_size,
               MAX(CASE WHEN parameter_name = 'pga_aggregate_target' THEN v END) AS pga_target,
               MAX(CASE WHEN parameter_name = 'pga_aggregate_limit'  THEN v END) AS pga_limit
        FROM  ( SELECT dbid, instance_number, parameter_name,
                       MAX(value_num) KEEP (DENSE_RANK LAST ORDER BY snap_id) AS v
                FROM   capv_parameter
                WHERE  parameter_name IN ('memory_target', 'sga_target', 'sga_max_size',
                                          'pga_aggregate_target', 'pga_aggregate_limit')
                GROUP  BY dbid, instance_number, parameter_name )
        GROUP  BY dbid, instance_number
     ),
     ram AS (
        SELECT dbid, instance_number,
               MAX(value) KEEP (DENSE_RANK LAST ORDER BY snap_id) AS host_ram_bytes
        FROM   capv_osstat
        WHERE  stat_name = 'PHYSICAL_MEMORY_BYTES'
        GROUP  BY dbid, instance_number
     )
SELECT i.dbid,
       i.dbid                                   AS con_dbid,
       i.instance_number,
       i.window_start,
       i.window_end,
       i.latest_snap_id,
       CAST(CASE WHEN p.dbid IS NULL         THEN NULL
                 WHEN p.memory_target > 0    THEN 'AMM'
                 WHEN p.sga_target > 0       THEN 'ASMM'
                 ELSE 'MANUAL'
            END AS VARCHAR2(10))                AS mem_mode,
       p.sga_target                             AS sga_target_bytes,
       p.pga_target                             AS pga_target_bytes,
       NULLIF(p.pga_limit, 0)                   AS pga_limit_bytes,
       GREATEST(NVL(p.sga_max_size, p.sga_target), NVL(p.sga_target, p.sga_max_size)) AS sga_bytes,
       r.host_ram_bytes
FROM   inst i
LEFT   JOIN prm p ON p.dbid = i.dbid AND p.instance_number = i.instance_number
LEFT   JOIN ram r ON r.dbid = i.dbid AND r.instance_number = i.instance_number;

-- --------------------------------------------------------------------
-- CAPM_ADV_SRC -- the four advisors in one shape, one row per (dbid,
-- instance_number, snap_id, area, advised size). One mapping branch each:
--   area          advisor                 cost (cumulative)        size unit
--   SGA_TOTAL     CAPV_SGA_ADVICE         estd_db_time, s          MB
--   BUFFER_CACHE  CAPV_CACHE_ADVICE       estd_physical_read_time  MB
--   SHARED_POOL   CAPV_SHPOOL_ADVICE      estd_lc_load_time, s     MB
--   PGA_TARGET    CAPV_PGA_ADVICE         estd_extra_bytes_rw      bytes
-- size_bytes normalises the size (verified on 19.27: the SGA, cache and
-- shared pool advisors list MB, the PGA advisor bytes). The PGA advisor has
-- no usable time column, so it also carries work (bytes_processed) and
-- overalloc (estd_overalloc_count). The buffer cache is the DEFAULT pool of
-- the standard block size: pool id 3 (KEEP is 1, RECYCLE 2, the DEFAULT
-- pools of the other block sizes 4 and up). advice_on = N for a row the
-- advisor wrote while switched off, which nothing downstream counts.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capm_adv_src AS
SELECT dbid, instance_number, snap_id,
       CAST('SGA_TOTAL' AS VARCHAR2(20))        AS area,
       sga_size * 1048576                       AS size_bytes,
       sga_size_factor                          AS size_factor,
       CAST('Y' AS VARCHAR2(1))                 AS advice_on,
       estd_db_time                             AS cost,
       CAST(NULL AS NUMBER)                     AS work,
       CAST(NULL AS NUMBER)                     AS overalloc
FROM   capv_sga_advice
UNION  ALL
SELECT dbid, instance_number, snap_id, 'BUFFER_CACHE',
       size_for_estimate * 1048576, size_factor,
       CASE WHEN advice_status = 'ON' THEN 'Y' ELSE 'N' END,
       estd_physical_read_time, NULL, NULL
FROM   capv_cache_advice
WHERE  name = 'DEFAULT' AND bpid = 3
UNION  ALL
SELECT dbid, instance_number, snap_id, 'SHARED_POOL',
       shared_pool_size_for_estimate * 1048576, shared_pool_size_factor,
       'Y', estd_lc_load_time, NULL, NULL
FROM   capv_shpool_advice
UNION  ALL
SELECT dbid, instance_number, snap_id, 'PGA_TARGET',
       pga_target_for_estimate, pga_target_factor,
       CASE WHEN advice_status = 'ON' THEN 'Y' ELSE 'N' END,
       estd_extra_bytes_rw, bytes_processed, estd_overalloc_count
FROM   capv_pga_advice;

-- --------------------------------------------------------------------
-- CAPM_DELTA -- every cumulative counter and advisor estimate as increments
-- between snapshots of the same instance startup, in one long shape.
--   metric     key                 key_num     delta
--   <area>     COST / WORK /       size_bytes  CAPM_ADV_SRC measures (rows
--              OVERALLOC                       with advice_on = Y)
--   PGASTAT    stat_name                       over allocation count, bytes
--                                              processed, extra bytes
--                                              read/written
--   WORKAREA   OPTIMAL / ONEPASS /             executions, summed over the
--              MULTIPASS                       histogram buckets
--   EVENT      event_name                      seconds waited
--   LIBCACHE   RELOADS / PINS                  summed over the namespaces
--   ROWCACHE   GETS / GETMISSES                summed over the parameters
--   DBTIME                         con_dbid    DB time in seconds, per
--                                              container (sum them for the
--                                              instance)
-- One mapping branch per source, then ONE piece of increment logic:
--   * delta = value - the key's previous present value in the same startup
--     (prev_snap_id says which snapshot that was, ivl_hours how long ago).
--     A key missing on a snapshot pairs across it.
--   * A key with no earlier row in the startup: AWR writes no row for a
--     counter that is still zero (verified on 19.27 for the PGA statistics
--     and the system events: absent until first used, present from then on).
--     For those sources (zero_fill) the first row counts in full against the
--     source's previous snapshot of the startup. The first snapshot of a
--     startup, and a first advisor row, have nothing to pair with and no row.
--   * A negative step (a reset, such as the buffer cache advisor's at a
--     resize) is dropped.
-- Nothing is subtracted across a restart. in_win / seg_ok are CAPM_SNAP's,
-- for the snapshot the increment ends on.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capm_delta AS
WITH src AS (
        SELECT dbid, instance_number, snap_id, area AS metric, measure AS key,
               size_bytes AS key_num, 'N' AS zero_fill, value
        FROM  ( SELECT dbid, instance_number, snap_id, area, size_bytes, cost, work, overalloc
                FROM   capm_adv_src
                WHERE  advice_on = 'Y' )
        UNPIVOT (value FOR measure IN (cost AS 'COST', work AS 'WORK', overalloc AS 'OVERALLOC'))
        UNION  ALL
        SELECT dbid, instance_number, snap_id, 'PGASTAT', stat_name, NULL, 'Y', value
        FROM   capv_pgastat
        WHERE  stat_name IN ('over allocation count', 'bytes processed', 'extra bytes read/written')
        UNION  ALL
        SELECT dbid, instance_number, snap_id, 'WORKAREA', pass, NULL, 'N', value
        FROM  ( SELECT dbid, instance_number, snap_id,
                       SUM(optimal_executions)     AS n_optimal,
                       SUM(onepass_executions)     AS n_onepass,
                       SUM(multipasses_executions) AS n_multipass
                FROM   capv_workarea_hstgrm
                GROUP  BY dbid, instance_number, snap_id )
        UNPIVOT (value FOR pass IN (n_optimal AS 'OPTIMAL', n_onepass AS 'ONEPASS',
                                    n_multipass AS 'MULTIPASS'))
        UNION  ALL
        SELECT dbid, instance_number, snap_id, 'EVENT', event_name, NULL, 'Y',
               time_waited_micro / 1000000
        FROM   capv_system_event
        UNION  ALL
        SELECT dbid, instance_number, snap_id, 'LIBCACHE', what, NULL, 'N', value
        FROM  ( SELECT dbid, instance_number, snap_id,
                       SUM(reloads) AS n_reloads, SUM(pins) AS n_pins
                FROM   capv_librarycache
                GROUP  BY dbid, instance_number, snap_id )
        UNPIVOT (value FOR what IN (n_reloads AS 'RELOADS', n_pins AS 'PINS'))
        UNION  ALL
        SELECT dbid, instance_number, snap_id, 'ROWCACHE', what, NULL, 'N', value
        FROM  ( SELECT dbid, instance_number, snap_id,
                       SUM(gets) AS n_gets, SUM(getmisses) AS n_getmisses
                FROM   capv_rowcache
                GROUP  BY dbid, instance_number, snap_id )
        UNPIVOT (value FOR what IN (n_gets AS 'GETS', n_getmisses AS 'GETMISSES'))
        UNION  ALL
        SELECT dbid, instance_number, snap_id, 'DBTIME', NULL, con_dbid, 'Y', value / 1000000
        FROM   capv_time_model
        WHERE  stat_name = 'DB time'
     ),
     lagged AS (
        SELECT c.dbid, c.instance_number, c.snap_id, c.metric, c.key, c.key_num,
               c.zero_fill, c.value, s.end_time, s.in_win, s.seg_ok,
               LAG(c.snap_id)  OVER (PARTITION BY c.dbid, c.instance_number, s.startup_time,
                                                  c.metric, c.key, c.key_num
                                     ORDER BY c.snap_id) AS key_prev_snap,
               LAG(c.value)    OVER (PARTITION BY c.dbid, c.instance_number, s.startup_time,
                                                  c.metric, c.key, c.key_num
                                     ORDER BY c.snap_id) AS key_prev_value,
               LAG(s.end_time) OVER (PARTITION BY c.dbid, c.instance_number, s.startup_time,
                                                  c.metric, c.key, c.key_num
                                     ORDER BY c.snap_id) AS key_prev_end,
               MAX(c.snap_id)  OVER (PARTITION BY c.dbid, c.instance_number, s.startup_time, c.metric
                                     ORDER BY c.snap_id
                                     RANGE BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS src_prev_snap,
               MAX(s.end_time) OVER (PARTITION BY c.dbid, c.instance_number, s.startup_time, c.metric
                                     ORDER BY c.snap_id
                                     RANGE BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS src_prev_end
        FROM   src c
        JOIN   capm_snap s
          ON   s.dbid = c.dbid AND s.instance_number = c.instance_number
         AND   s.snap_id = c.snap_id
     ),
     d AS (
        SELECT l.*,
               CASE WHEN l.key_prev_snap IS NOT NULL THEN l.key_prev_snap
                    WHEN l.zero_fill = 'Y'           THEN l.src_prev_snap END AS prev_snap_id,
               CASE WHEN l.key_prev_snap IS NOT NULL THEN l.key_prev_end
                    WHEN l.zero_fill = 'Y'           THEN l.src_prev_end END  AS prev_end_time,
               CASE WHEN l.key_prev_snap IS NOT NULL THEN l.value - l.key_prev_value
                    WHEN l.zero_fill = 'Y'           THEN l.value END         AS delta
        FROM   lagged l
     )
SELECT dbid,
       instance_number,
       snap_id,
       prev_snap_id,
       CAST(metric AS VARCHAR2(20))                          AS metric,
       CAST(key AS VARCHAR2(64))                             AS key,
       key_num,
       delta,
       end_time,
       ROUND((end_time - prev_end_time) * 86400) / 3600      AS ivl_hours,
       in_win,
       seg_ok
FROM   d
WHERE  prev_snap_id IS NOT NULL
  AND  delta >= 0;

-- --------------------------------------------------------------------
-- CAPM_ADVICE -- the advisor curve of each area: one row per (dbid,
-- instance_number, area, advised size) on the list of the instance's latest
-- snapshot.
--   current_bytes  the advisor's own factor 1 size on that list.
--   An advised size X is compared with the current size over exactly the
--   snapshot intervals in which the advisor gave an increment for both (same
--   snap_id and prev_snap_id), inside the window, on startups with seg_ok.
--   Summing increments weights each interval by the work it carried. cur
--   holds the current size's increments alone, so that join is one row an
--   interval in any join order (sizes x sizes otherwise: 2.2 million rows
--   and 20 s on a 30-size shared pool list).
--   cover_hours / n_intervals / n_days  those intervals.
--   est_cost / cur_cost / rel_cost      summed cost increments of X and of
--                  the current size, and their ratio.
--   gain           what X gains over the current size, negative for a loss:
--                  DBTIME_PCT  100 x (cur_cost - est_cost) / the instance's
--                              DB time, over the intervals that have DB time
--                              (dbtime_sec);
--                  HIT_PTS     PGA: est_hit_pct - cur_hit_pct, the estimated
--                              cache hit 100 x work / (work + cost).
--   overalloc      PGA: X's over-allocation increments.
--   is_candidate   Y for a size other than the current one, inside
--                  [current / mem_max_step, current x mem_max_step], with
--                  cover_hours >= mem_min_uptime_hours for itself and for
--                  the current size, and a gain.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capm_advice AS
WITH latest AS (
        SELECT a.dbid, a.instance_number, a.area, a.size_bytes, a.size_factor,
               MIN(a.size_bytes) KEEP (DENSE_RANK FIRST ORDER BY ABS(a.size_factor - 1), a.size_bytes)
                   OVER (PARTITION BY a.dbid, a.instance_number, a.area) AS current_bytes
        FROM   capm_adv_src a
        JOIN   capm_snap s
          ON   s.dbid = a.dbid AND s.instance_number = a.instance_number
         AND   s.snap_id = a.snap_id
        WHERE  s.snap_id = s.latest_snap_id
          AND  a.advice_on = 'Y'
     ),
     dl AS (
        SELECT dbid, instance_number, snap_id, prev_snap_id, metric, key, key_num,
               delta, end_time, ivl_hours
        FROM   capm_delta
        WHERE  in_win = 'Y'
          AND  (metric = 'DBTIME'
                OR (seg_ok = 'Y'
                    AND metric IN ('SGA_TOTAL', 'BUFFER_CACHE', 'SHARED_POOL', 'PGA_TARGET')))
     ),
     adv AS (
        SELECT dbid, instance_number, snap_id, prev_snap_id, metric AS area, key_num AS size_bytes,
               MAX(CASE WHEN key = 'COST'      THEN delta END) AS cost,
               MAX(CASE WHEN key = 'WORK'      THEN delta END) AS work,
               MAX(CASE WHEN key = 'OVERALLOC' THEN delta END) AS overalloc,
               MAX(ivl_hours)                                  AS ivl_hours,
               MAX(end_time)                                   AS end_time
        FROM   dl
        WHERE  metric <> 'DBTIME'
        GROUP  BY dbid, instance_number, snap_id, prev_snap_id, metric, key_num
     ),
     dbt AS (
        SELECT dbid, instance_number, snap_id, SUM(delta) AS dbtime_sec
        FROM   dl
        WHERE  metric = 'DBTIME'
        GROUP  BY dbid, instance_number, snap_id
     ),
     cur AS (
        SELECT a.dbid, a.instance_number, a.area, a.snap_id, a.prev_snap_id, a.cost
        FROM   adv a
        JOIN   (SELECT DISTINCT dbid, instance_number, area, current_bytes FROM latest) k
          ON   k.dbid = a.dbid AND k.instance_number = a.instance_number
         AND   k.area = a.area AND k.current_bytes = a.size_bytes
        WHERE  a.cost IS NOT NULL
     ),
     pair AS (
        SELECT l.dbid, l.instance_number, l.area, l.size_bytes,
               x.ivl_hours, x.end_time, x.cost, c.cost AS cur_cost, x.work, x.overalloc,
               t.dbtime_sec
        FROM   latest l
        JOIN   adv x
          ON   x.dbid = l.dbid AND x.instance_number = l.instance_number
         AND   x.area = l.area AND x.size_bytes = l.size_bytes
        JOIN   cur c
          ON   c.dbid = x.dbid AND c.instance_number = x.instance_number
         AND   c.area = x.area
         AND   c.snap_id = x.snap_id AND c.prev_snap_id = x.prev_snap_id
        LEFT   JOIN dbt t
          ON   t.dbid = x.dbid AND t.instance_number = x.instance_number
         AND   t.snap_id = x.snap_id
        WHERE  x.cost IS NOT NULL
     ),
     agg AS (
        SELECT dbid, instance_number, area, size_bytes,
               SUM(ivl_hours)                  AS cover_hours,
               COUNT(*)                        AS n_intervals,
               COUNT(DISTINCT TRUNC(end_time)) AS n_days,
               SUM(cost)                       AS est_cost,
               SUM(cur_cost)                   AS cur_cost,
               SUM(work)                       AS work,
               SUM(overalloc)                  AS overalloc,
               SUM(dbtime_sec)                 AS dbtime_sec,
               SUM(CASE WHEN dbtime_sec IS NOT NULL THEN cur_cost - cost END) AS gain_sec
        FROM   pair
        GROUP  BY dbid, instance_number, area, size_bytes
     ),
     curve AS (
        SELECT l.dbid, l.instance_number, l.area, l.size_bytes, l.size_factor, l.current_bytes,
               NVL(g.cover_hours, 0) AS cover_hours,
               NVL(g.n_intervals, 0) AS n_intervals,
               NVL(g.n_days, 0)      AS n_days,
               g.est_cost, g.cur_cost, g.dbtime_sec, g.overalloc,
               CASE WHEN l.area = 'PGA_TARGET' AND g.work + g.est_cost > 0
                    THEN 100 * g.work / (g.work + g.est_cost) END AS est_hit_pct,
               CASE WHEN l.area = 'PGA_TARGET' AND g.work + g.cur_cost > 0
                    THEN 100 * g.work / (g.work + g.cur_cost) END AS cur_hit_pct,
               CASE WHEN l.area <> 'PGA_TARGET' AND g.dbtime_sec > 0
                    THEN 100 * g.gain_sec / g.dbtime_sec END      AS gain_dbtime_pct,
               MAX(CASE WHEN l.size_bytes = l.current_bytes THEN NVL(g.cover_hours, 0) END)
                   OVER (PARTITION BY l.dbid, l.instance_number, l.area) AS cur_cover_hours
        FROM   latest l
        LEFT   JOIN agg g
          ON   g.dbid = l.dbid AND g.instance_number = l.instance_number
         AND   g.area = l.area AND g.size_bytes = l.size_bytes
     ),
     graded AS (
        SELECT c.*,
               CASE WHEN c.area = 'PGA_TARGET' THEN c.est_hit_pct - c.cur_hit_pct
                    ELSE c.gain_dbtime_pct END AS gain
        FROM   curve c
     )
SELECT g.dbid,
       g.dbid                                   AS con_dbid,
       g.instance_number,
       g.area,
       g.size_bytes,
       g.size_factor,
       g.current_bytes,
       CAST(CASE WHEN g.size_bytes = g.current_bytes THEN 'Y' ELSE 'N' END AS VARCHAR2(1)) AS is_current,
       CAST(CASE WHEN g.size_bytes <> g.current_bytes
                  AND g.size_bytes BETWEEN g.current_bytes / cfg.mem_max_step
                                       AND g.current_bytes * cfg.mem_max_step
                  AND g.cover_hours     >= cfg.mem_min_uptime_hours
                  AND g.cur_cover_hours >= cfg.mem_min_uptime_hours
                  AND g.gain IS NOT NULL
                 THEN 'Y' ELSE 'N' END AS VARCHAR2(1))                                     AS is_candidate,
       g.cover_hours,
       g.n_intervals,
       g.n_days,
       g.est_cost,
       g.cur_cost,
       g.est_cost / NULLIF(g.cur_cost, 0)       AS rel_cost,
       g.dbtime_sec,
       g.gain,
       CAST(CASE WHEN g.area = 'PGA_TARGET' THEN 'HIT_PTS' ELSE 'DBTIME_PCT' END
            AS VARCHAR2(10))                    AS gain_unit,
       g.est_hit_pct,
       g.cur_hit_pct,
       g.overalloc
FROM   graded g
CROSS  JOIN cap_cfg cfg;

-- --------------------------------------------------------------------
-- CAPM_PGA_LIMIT -- usage against pga_aggregate_limit, per instance.
--   n_days              distinct days (TRUNC of the end time) with a
--                       'total PGA allocated' sample in the window.
--   mem_mode / limit_bytes / sga_bytes / host_ram_bytes  CAPM_INST's. The
--                       verdict is about the current setting, so every peak
--                       is compared with the CURRENT limit, not with the
--                       limit in force when it happened.
--   sampled_peak_*      the highest 'total PGA allocated' sample in the
--                       window and when it was taken (first time on a tie).
--   hwm_peak_*          'maximum PGA allocated' is a high-water mark since
--                       instance startup, so only its ADVANCES inside the
--                       window count: a snapshot whose mark is above the
--                       previous snapshot's of the same (dbid, instance,
--                       startup_time), the LAG taken over all history. The
--                       first snapshot of a startup is an advance only when
--                       that startup is inside the window; before it, a NULL
--                       lag means history was cut, not that the mark rose.
--                       The largest advanced mark of the window and when.
--   n_days_over         window days whose highest sample is at or above
--                       mem_pga_limit_pct percent of limit_bytes.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capm_pga_limit AS
WITH inst AS (
        SELECT dbid, con_dbid, instance_number, window_start, window_end, mem_mode,
               pga_limit_bytes, sga_bytes, host_ram_bytes
        FROM   capm_inst
     ),
     pga AS (
        SELECT dbid, instance_number, snap_id,
               MAX(CASE WHEN stat_name = 'total PGA allocated'   THEN value END) AS tot,
               MAX(CASE WHEN stat_name = 'maximum PGA allocated' THEN value END) AS hwm
        FROM   capv_pgastat
        WHERE  stat_name IN ('total PGA allocated', 'maximum PGA allocated')
        GROUP  BY dbid, instance_number, snap_id
     ),
     ps AS (
        SELECT w.dbid, w.instance_number, w.snap_id, w.end_time, w.startup_time,
               w.startup_dt, w.window_start, p.tot, p.hwm, w.in_win
        FROM   capm_snap w
        JOIN   pga p
          ON   p.dbid = w.dbid AND p.instance_number = w.instance_number
         AND   p.snap_id = w.snap_id
     ),
     sampled AS (
        SELECT dbid, instance_number,
               COUNT(DISTINCT TRUNC(end_time))                     AS n_days,
               MAX(tot)                                            AS peak_bytes,
               MIN(end_time) KEEP (DENSE_RANK LAST ORDER BY tot)   AS peak_time
        FROM   ps
        WHERE  in_win = 'Y' AND tot IS NOT NULL
        GROUP  BY dbid, instance_number
     ),
     day_peak AS (
        SELECT dbid, instance_number, TRUNC(end_time) AS day_dt, MAX(tot) AS peak_bytes
        FROM   ps
        WHERE  in_win = 'Y' AND tot IS NOT NULL
        GROUP  BY dbid, instance_number, TRUNC(end_time)
     ),
     hwm_lag AS (
        SELECT x.*,
               LAG(x.hwm) OVER (PARTITION BY x.dbid, x.instance_number, x.startup_time
                                ORDER BY x.snap_id) AS prev_hwm
        FROM   ps x
        WHERE  x.hwm IS NOT NULL
     ),
     hwm_peak AS (
        SELECT dbid, instance_number,
               MAX(hwm)                                          AS peak_bytes,
               MIN(end_time) KEEP (DENSE_RANK LAST ORDER BY hwm) AS peak_time
        FROM   hwm_lag
        WHERE  in_win = 'Y'
          AND  (hwm > prev_hwm OR (prev_hwm IS NULL AND startup_dt > window_start))
        GROUP  BY dbid, instance_number
     ),
     over_days AS (
        SELECT d.dbid, d.instance_number, COUNT(*) AS n_days_over
        FROM   day_peak d
        JOIN   inst l ON l.dbid = d.dbid AND l.instance_number = d.instance_number
        CROSS  JOIN cap_cfg cfg
        WHERE  d.peak_bytes >= l.pga_limit_bytes * cfg.mem_pga_limit_pct / 100
        GROUP  BY d.dbid, d.instance_number
     )
SELECT l.dbid,
       l.con_dbid,
       l.instance_number,
       l.window_start,
       l.window_end,
       NVL(s.n_days, 0)                         AS n_days,
       l.mem_mode,
       l.pga_limit_bytes                        AS limit_bytes,
       s.peak_bytes                             AS sampled_peak_bytes,
       s.peak_time                              AS sampled_peak_time,
       h.peak_bytes                             AS hwm_peak_bytes,
       h.peak_time                              AS hwm_peak_time,
       NVL(o.n_days_over, 0)                    AS n_days_over,
       l.sga_bytes,
       l.host_ram_bytes
FROM   inst l
LEFT   JOIN sampled   s ON s.dbid = l.dbid AND s.instance_number = l.instance_number
LEFT   JOIN hwm_peak  h ON h.dbid = l.dbid AND h.instance_number = l.instance_number
LEFT   JOIN over_days o ON o.dbid = l.dbid AND o.instance_number = l.instance_number;

-- --------------------------------------------------------------------
-- CAPM_AREA -- the facts of the four advisor-based areas, one row per
-- (dbid, instance_number, area) for every instance of CAPM_INST.
--   The area definitions are data (def): the parameter a suggestion is for,
--   the prefix of the area's advisor signals, the advisor's name in a
--   sentence, and the knobs its gain and loss are compared with (cache hit
--   points for PGA_TARGET, percent of DB time for the others).
--   n_adv_snaps    window snapshots that carry the advisor at all (0 =
--                  not collected).
--   current_bytes / cover_hours / n_days  the current size's CAPM_ADVICE row.
--   advisor_thin   Y when cover_hours < mem_min_uptime_hours: an advisor
--                  that is off, an instance that keeps restarting, a pool
--                  that has only just reached its size. No candidates then.
--   best_gain / best_bytes  the largest gain among the larger candidates and
--                  the smallest size that reaches it.
--   grow_bytes     the suggestion when the area is UNDERSIZED: the smallest
--                  larger candidate whose gain is at least mem_knee_pct
--                  percent of best_gain. PGA_TARGET: and at least the
--                  smallest larger candidate without over-allocation
--                  increments; when the current size over-allocates and no
--                  candidate inside the step cap ends it, the largest one.
--   slack_bytes / slack_loss  the smallest smaller candidate whose loss is
--                  within the shrink knob (PGA_TARGET: and without
--                  over-allocation increments), the suggestion when the area
--                  is OVERSIZED, and that loss.
--   near_bytes / near_loss  the nearest smaller candidate and its loss,
--                  shown when no candidate qualifies as slack.
--   cur_overalloc  PGA_TARGET: the advisor's over-allocation increments at
--                  the current size, NULL while the advisor is thin.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capm_area AS
WITH def AS (
        SELECT a.area, a.param, a.sig, a.advisor_name, a.gain_unit,
               CASE a.area WHEN 'PGA_TARGET' THEN cfg.mem_pga_gain_pts
                           ELSE cfg.mem_gain_dbtime_pct END   AS gain_thr,
               CASE a.area WHEN 'PGA_TARGET' THEN cfg.mem_pga_shrink_pts
                           ELSE cfg.mem_shrink_dbtime_pct END AS shrink_thr,
               cfg.mem_knee_pct, cfg.mem_min_uptime_hours
        FROM  ( SELECT 'PGA_TARGET' AS area, 'pga_aggregate_target' AS param, 'PGA' AS sig,
                       'PGA' AS advisor_name, 'PTS' AS gain_unit FROM dual
                UNION ALL SELECT 'BUFFER_CACHE', 'db_cache_size',    'CACHE',  'buffer cache', 'PCT' FROM dual
                UNION ALL SELECT 'SHARED_POOL',  'shared_pool_size', 'SHPOOL', 'shared pool',  'PCT' FROM dual
                UNION ALL SELECT 'SGA_TOTAL',    'sga_target',       'SGA',    'SGA',          'PCT' FROM dual ) a
        CROSS  JOIN cap_cfg cfg
     ),
     src AS (
        SELECT a.dbid, a.instance_number, a.area, COUNT(DISTINCT a.snap_id) AS n_adv_snaps
        FROM   capm_adv_src a
        JOIN   capm_snap s
          ON   s.dbid = a.dbid AND s.instance_number = a.instance_number
         AND   s.snap_id = a.snap_id
        WHERE  s.in_win = 'Y'
        GROUP  BY a.dbid, a.instance_number, a.area
     ),
     c AS (
        SELECT v.dbid, v.instance_number, v.area, v.size_bytes, v.current_bytes, v.is_current,
               v.cover_hours, v.n_days, v.gain, v.overalloc,
               d.shrink_thr, d.mem_knee_pct,
               CASE WHEN v.is_candidate = 'Y' AND v.size_bytes > v.current_bytes THEN 'UP'
                    WHEN v.is_candidate = 'Y' AND v.size_bytes < v.current_bytes THEN 'DOWN'
               END AS side
        FROM   capm_advice v
        JOIN   def d ON d.area = v.area
     ),
     c2 AS (
        SELECT c.*,
               MAX(CASE WHEN c.side = 'UP' THEN c.gain END)
                   OVER (PARTITION BY c.dbid, c.instance_number, c.area) AS best_gain,
               MIN(CASE WHEN c.side = 'DOWN' AND -c.gain <= c.shrink_thr AND NVL(c.overalloc, 0) = 0
                        THEN c.size_bytes END)
                   OVER (PARTITION BY c.dbid, c.instance_number, c.area) AS slack_bytes,
               MAX(CASE WHEN c.side = 'DOWN' THEN c.size_bytes END)
                   OVER (PARTITION BY c.dbid, c.instance_number, c.area) AS near_bytes
        FROM   c
     ),
     f AS (
        SELECT dbid, instance_number, area,
               MAX(current_bytes)                                           AS current_bytes,
               MAX(CASE WHEN is_current = 'Y' THEN cover_hours END)         AS cover_hours,
               MAX(CASE WHEN is_current = 'Y' THEN n_days END)              AS n_days,
               MAX(CASE WHEN is_current = 'Y' THEN overalloc END)           AS cur_overalloc,
               MAX(best_gain)                                               AS best_gain,
               MIN(CASE WHEN side = 'UP' AND gain = best_gain THEN size_bytes END) AS best_bytes,
               MIN(CASE WHEN side = 'UP' AND best_gain > 0
                             AND gain >= best_gain * mem_knee_pct / 100
                        THEN size_bytes END)                                AS knee_bytes,
               MIN(CASE WHEN side = 'UP' AND overalloc = 0 THEN size_bytes END) AS zero_over_bytes,
               MAX(CASE WHEN side = 'UP' THEN size_bytes END)               AS max_up_bytes,
               MAX(slack_bytes)                                             AS slack_bytes,
               MAX(CASE WHEN size_bytes = slack_bytes THEN -gain END)       AS slack_loss,
               MAX(near_bytes)                                              AS near_bytes,
               MAX(CASE WHEN size_bytes = near_bytes THEN -gain END)        AS near_loss
        FROM   c2
        GROUP  BY dbid, instance_number, area
     )
SELECT i.dbid,
       i.con_dbid,
       i.instance_number,
       CAST(d.area AS VARCHAR2(20))             AS area,
       i.mem_mode,
       i.window_start,
       i.window_end,
       NVL(s.n_adv_snaps, 0)                    AS n_adv_snaps,
       f.current_bytes,
       NVL(f.cover_hours, 0)                    AS cover_hours,
       NVL(f.n_days, 0)                         AS n_days,
       CAST(CASE WHEN NVL(f.cover_hours, 0) < d.mem_min_uptime_hours THEN 'Y' ELSE 'N' END
            AS VARCHAR2(1))                     AS advisor_thin,
       f.best_gain,
       f.best_bytes,
       NULLIF(GREATEST(NVL(f.knee_bytes, 0), NVL(f.zero_over_bytes, 0),
                       CASE WHEN f.cur_overalloc > 0 AND f.zero_over_bytes IS NULL
                            THEN NVL(f.max_up_bytes, 0) ELSE 0 END), 0) AS grow_bytes,
       f.slack_bytes,
       f.slack_loss,
       f.near_bytes,
       f.near_loss,
       CASE WHEN NVL(f.cover_hours, 0) >= d.mem_min_uptime_hours THEN f.cur_overalloc END AS cur_overalloc,
       d.gain_thr,
       d.shrink_thr,
       CAST(d.gain_unit AS VARCHAR2(10))        AS gain_unit,
       CAST(d.param AS VARCHAR2(30))            AS suggested_param,
       CAST(d.sig AS VARCHAR2(10))              AS sig,
       CAST(d.advisor_name AS VARCHAR2(20))     AS advisor_name,
       i.sga_bytes,
       i.pga_target_bytes,
       i.host_ram_bytes
FROM   capm_inst i
CROSS  JOIN def d
LEFT   JOIN f   ON f.dbid = i.dbid AND f.instance_number = i.instance_number AND f.area = d.area
LEFT   JOIN src s ON s.dbid = i.dbid AND s.instance_number = i.instance_number AND s.area = d.area;

-- --------------------------------------------------------------------
-- CAPM_SGA_BALANCE -- how the instance moved memory between the SGA pools
-- in the window, one row per instance of CAPM_INST. Read from the component
-- history (CAPV_MEM_COMP), which carries a cumulative operation counter and
-- the mode of the last operation on every snapshot. A component interval is
-- two consecutive snapshots of one startup that both list the component,
-- counted when it ends in the window: ops = the counter's increment (0 on a
-- reset), net = the change of current_size. 'SGA Target' and 'PGA Target'
-- are targets, not components, and are left out.
--   n_days              distinct days with a component row in the window.
--   n_ops / ops_per_day operations of every SGA component, and per n_days.
--   n_reversals         over the buffer cache and the shared pool: a net
--                       move whose sign differs from the pool's previous net
--                       move in the window, plus every interval with
--                       operations and no net change.
--   cache_grows         intervals in which the DEFAULT buffer cache rose.
--   shpool_forced_grows intervals in which the shared pool rose and its last
--                       operation was IMMEDIATE (forced, to avoid an
--                       allocation failure).
--   sga_forced_grows    intervals in which any component did.
--   *_at                when that last happened.
--   cache_bytes / shpool_bytes          the pools at their latest window
--                       snapshot. *_max_bytes: their largest size in it.
--   floor_pool / floor_bytes / floor_param  the pool with the most growing
--                       intervals (the shared pool on a tie), the largest
--                       size it reached in the window and its parameter:
--                       the floor suggested when the balance is THRASHING.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capm_sga_balance AS
WITH mc AS (
        SELECT m.dbid, m.instance_number, m.snap_id, m.component, m.current_size,
               m.oper_count, m.last_oper_mode, s.end_time, s.in_win,
               LAG(m.current_size) OVER (PARTITION BY m.dbid, m.instance_number, s.startup_time,
                                                      m.component
                                         ORDER BY m.snap_id) AS prev_size,
               LAG(m.oper_count)   OVER (PARTITION BY m.dbid, m.instance_number, s.startup_time,
                                                      m.component
                                         ORDER BY m.snap_id) AS prev_ops
        FROM   capv_mem_comp m
        JOIN   capm_snap s
          ON   s.dbid = m.dbid AND s.instance_number = m.instance_number
         AND   s.snap_id = m.snap_id
        WHERE  m.component NOT IN ('SGA Target', 'PGA Target')
     ),
     iv AS (
        SELECT mc.dbid, mc.instance_number, mc.snap_id, mc.component, mc.current_size,
               mc.last_oper_mode, mc.end_time,
               CASE WHEN mc.component IN ('DEFAULT buffer cache', 'shared pool') THEN 'Y' ELSE 'N' END AS is_pool,
               mc.current_size - mc.prev_size          AS net,
               GREATEST(mc.oper_count - mc.prev_ops, 0) AS ops
        FROM   mc
        WHERE  mc.in_win = 'Y'
     ),
     mv AS (
        SELECT dbid, instance_number, SIGN(net) AS sgn,
               LAG(SIGN(net)) OVER (PARTITION BY dbid, instance_number, component
                                    ORDER BY snap_id) AS prev_sgn
        FROM   iv
        WHERE  is_pool = 'Y' AND net <> 0
     ),
     rev AS (
        SELECT dbid, instance_number, COUNT(*) AS n_turns
        FROM   mv
        WHERE  sgn <> prev_sgn
        GROUP  BY dbid, instance_number
     ),
     tot AS (
        SELECT dbid, instance_number,
               COUNT(DISTINCT TRUNC(end_time))                         AS n_days,
               NVL(SUM(ops), 0)                                        AS n_ops,
               COUNT(DISTINCT CASE WHEN net > 0 AND last_oper_mode = 'IMMEDIATE'
                                   THEN snap_id END)                   AS sga_forced_grows,
               MAX(CASE WHEN net > 0 AND last_oper_mode = 'IMMEDIATE' THEN end_time END) AS sga_forced_at
        FROM   iv
        GROUP  BY dbid, instance_number
     ),
     pool AS (
        SELECT dbid, instance_number, component,
               COUNT(CASE WHEN net > 0 THEN 1 END)                                 AS n_grows,
               COUNT(CASE WHEN net > 0 AND last_oper_mode = 'IMMEDIATE' THEN 1 END) AS n_forced,
               COUNT(CASE WHEN ops > 0 AND net = 0 THEN 1 END)                     AS n_flat_ops,
               MAX(current_size)                                                   AS max_bytes,
               MAX(current_size) KEEP (DENSE_RANK LAST ORDER BY snap_id)           AS now_bytes,
               MAX(CASE WHEN net > 0 THEN end_time END)                            AS grow_at,
               MAX(CASE WHEN net > 0 AND last_oper_mode = 'IMMEDIATE' THEN end_time END) AS forced_at
        FROM   iv
        WHERE  is_pool = 'Y'
        GROUP  BY dbid, instance_number, component
     ),
     pv AS (
        SELECT dbid, instance_number,
               SUM(n_flat_ops)                                                      AS n_flat_ops,
               MAX(CASE WHEN component = 'DEFAULT buffer cache' THEN n_grows END)   AS cache_grows,
               MAX(CASE WHEN component = 'DEFAULT buffer cache' THEN grow_at END)   AS cache_grow_at,
               MAX(CASE WHEN component = 'DEFAULT buffer cache' THEN now_bytes END) AS cache_bytes,
               MAX(CASE WHEN component = 'DEFAULT buffer cache' THEN max_bytes END) AS cache_max_bytes,
               MAX(CASE WHEN component = 'shared pool' THEN n_forced END)           AS shpool_forced_grows,
               MAX(CASE WHEN component = 'shared pool' THEN forced_at END)          AS shpool_forced_at,
               MAX(CASE WHEN component = 'shared pool' THEN now_bytes END)          AS shpool_bytes,
               MAX(CASE WHEN component = 'shared pool' THEN max_bytes END)          AS shpool_max_bytes,
               MAX(n_grows)                                                         AS floor_grows,
               MAX(component) KEEP (DENSE_RANK LAST ORDER BY n_grows, component)    AS floor_pool,
               MAX(max_bytes) KEEP (DENSE_RANK LAST ORDER BY n_grows, component)    AS floor_bytes
        FROM   pool
        GROUP  BY dbid, instance_number
     )
SELECT i.dbid,
       i.con_dbid,
       i.instance_number,
       i.mem_mode,
       i.window_start,
       i.window_end,
       NVL(t.n_days, 0)                         AS n_days,
       i.sga_target_bytes,
       t.n_ops,
       t.n_ops / NULLIF(t.n_days, 0)            AS ops_per_day,
       CASE WHEN t.dbid IS NOT NULL THEN NVL(r.n_turns, 0) + NVL(p.n_flat_ops, 0) END AS n_reversals,
       p.cache_grows,
       p.cache_grow_at,
       p.shpool_forced_grows,
       p.shpool_forced_at,
       t.sga_forced_grows,
       t.sga_forced_at,
       p.cache_bytes,
       p.cache_max_bytes,
       p.shpool_bytes,
       p.shpool_max_bytes,
       CAST(CASE WHEN p.floor_grows > 0 THEN p.floor_pool END AS VARCHAR2(64))  AS floor_pool,
       CASE WHEN p.floor_grows > 0 THEN p.floor_bytes END                       AS floor_bytes,
       CAST(CASE WHEN p.floor_grows > 0
                 THEN DECODE(p.floor_pool, 'shared pool', 'shared_pool_size', 'db_cache_size')
            END AS VARCHAR2(30))                AS floor_param
FROM   capm_inst i
LEFT   JOIN tot t ON t.dbid = i.dbid AND t.instance_number = i.instance_number
LEFT   JOIN pv  p ON p.dbid = i.dbid AND p.instance_number = i.instance_number
LEFT   JOIN rev r ON r.dbid = i.dbid AND r.instance_number = i.instance_number;

-- --------------------------------------------------------------------
-- CAPM_EVIDENCE -- one row per signal of every area.
--   kind               USAGE (measured against a ceiling), ADVISOR (an
--                      Oracle advisor's estimate), SYMPTOM (observed) or
--                      CONTEXT (shown, never decides a grade).
--   value / unit       the measured number: PCT, PTS (cache hit percentage
--                      points), COUNT or PER_DAY. PCT and PTS are rounded to
--                      4 decimals, the PGA_LIMIT percentages to 2.
--   threshold          what it is compared with, in the same unit; NULL for
--                      a signal that is never compared.
--   direction          PRESSURE when the signal argues for more memory,
--                      SLACK when it argues for less, NEUTRAL otherwise.
--   observed_at        when the measured value happened, the window end for
--                      a figure of the whole window.
--   evidence_text      one English sentence, numbers formatted with '.'
--                      as the decimal point whatever the session's NLS.
--
-- Area PGA_LIMIT (USAGE), while limit_bytes and the peak are known:
--   PGA_HWM_PEAK_PCT      100 * hwm_peak_bytes / limit_bytes
--   PGA_SAMPLED_PEAK_PCT  100 * sampled_peak_bytes / limit_bytes
-- PRESSURE at or above mem_pga_limit_pct. The limit is a safety ceiling, so
-- no PGA_LIMIT signal is ever SLACK.
--
-- ADVISOR rows, from CAPM_AREA (none while the advisor is thin):
--   <sig>_ADV_GAIN_DBTIME_PCT / PGA_ADV_HIT_GAIN_PTS   best_gain; PRESSURE at
--       or above the area's gain knob.
--   <sig>_ADV_SHRINK_LOSS_DBTIME_PCT / PGA_ADV_SHRINK_LOSS_PTS   the loss at
--       slack_bytes, SLACK; without one the loss at near_bytes, NEUTRAL.
--   PGA_ADV_OVERALLOC     cur_overalloc; PRESSURE at 1 or more.
--
-- SYMPTOM rows from window sums of CAPM_DELTA (every startup counts). Each
-- is a row of sig with its terms in term: value = 100 x sum(N terms) /
-- sum(D terms), or the plain sum of the N terms for a COUNT. A signal has a
-- row when its source (sig.src) has increments in the window and its D
-- terms sum above zero. A missing N term is then zero: the event was never
-- waited for, the counter never moved.
--   PGA_MULTIPASS_PCT / PGA_ONEPASS_PCT   share of all work area executions.
--   PGA_OVERALLOC_COUNT   observed 'over allocation count' increments.
--   PGA_TEMP_IO_DBTIME_PCT   direct path read temp + write temp.
--   CACHE_FREE_BUFFER_WAIT_DBTIME_PCT   free buffer waits.
--   SHPOOL_WAIT_DBTIME_PCT   latch: shared pool, library cache: mutex X,
--       library cache load lock, SGA: allocation forcing component growth.
--   SHPOOL_RELOAD_PCT     library cache reloads / pins.
--   SHPOOL_ROWCACHE_MISS_PCT   dictionary cache getmisses / gets.
-- Each is PRESSURE at or above its knob (a COUNT at 1 or more).
--
-- Rows from CAPM_SGA_BALANCE: CACHE_GROWS, SHPOOL_FORCED_GROWS and
-- SGA_FORCED_GROWS (SYMPTOM, PRESSURE at 1 or more), SGA_RESIZE_OPS_DAY and
-- SGA_RESIZE_REVERSALS (area SGA_BALANCE, PRESSURE at their knobs).
-- SGA_POOLS_PRESSED counts the areas BUFFER_CACHE and SHARED_POOL that have
-- a SYMPTOM row in PRESSURE; PRESSURE at 2.
--
-- CONTEXT rows, samples of the window:
--   PGA_AUTO_SHARE_MIN_PCT  the smallest 'aggregate PGA auto target' /
--       'aggregate PGA target parameter'. Always NEUTRAL.
--   SHPOOL_FREE_MIN_PCT   the smallest shared pool 'free memory' / shared
--       pool size. SLACK at or above mem_shpool_free_pct.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capm_evidence AS
WITH lim AS (
        SELECT l.dbid, l.instance_number, l.limit_bytes,
               CASE k.n WHEN 1 THEN 'PGA_HWM_PEAK_PCT' ELSE 'PGA_SAMPLED_PEAK_PCT' END AS signal,
               CASE k.n WHEN 1 THEN l.hwm_peak_bytes ELSE l.sampled_peak_bytes END    AS peak_bytes,
               CASE k.n WHEN 1 THEN l.hwm_peak_time  ELSE l.sampled_peak_time  END    AS peak_time,
               CASE k.n WHEN 1 THEN 'The PGA high-water mark rose to '
                        ELSE 'The highest sampled PGA allocation was ' END            AS lead
        FROM   capm_pga_limit l
        CROSS  JOIN (SELECT 1 AS n FROM dual UNION ALL SELECT 2 FROM dual) k
     ),
     lim_ev AS (
        SELECT p.dbid, p.instance_number,
               'PGA_LIMIT' AS area, p.signal, 'USAGE' AS kind,
               ROUND(100 * p.peak_bytes / p.limit_bytes, 2) AS value,
               'PCT' AS unit, cfg.mem_pga_limit_pct AS threshold,
               CASE WHEN ROUND(100 * p.peak_bytes / p.limit_bytes, 2) >= cfg.mem_pga_limit_pct
                    THEN 'PRESSURE' ELSE 'NEUTRAL' END AS direction,
               p.peak_time AS observed_at,
               p.lead
               || TO_CHAR(p.peak_bytes / 1073741824, 'FM999999990.00', 'NLS_NUMERIC_CHARACTERS=''.,''')
               || ' GiB at ' || TO_CHAR(p.peak_time, 'YYYY-MM-DD HH24:MI') || ', ' AS lead,
               '% of pga_aggregate_limit '
               || TO_CHAR(p.limit_bytes / 1073741824, 'FM999999990.00', 'NLS_NUMERIC_CHARACTERS=''.,''')
               || ' GiB' AS tail
        FROM   lim p
        CROSS  JOIN cap_cfg cfg
        WHERE  p.limit_bytes IS NOT NULL
          AND  p.peak_bytes IS NOT NULL
     ),
     ar AS (
        SELECT a.*,
               CASE WHEN a.current_bytes >= 1073741824
                    THEN TO_CHAR(a.current_bytes / 1073741824, 'FM999999990.00', 'NLS_NUMERIC_CHARACTERS=''.,''') || ' GiB'
                    ELSE TO_CHAR(a.current_bytes / 1048576, 'FM999999990', 'NLS_NUMERIC_CHARACTERS=''.,''') || ' MiB'
               END AS cur_txt,
               CASE WHEN a.best_bytes >= 1073741824
                    THEN TO_CHAR(a.best_bytes / 1073741824, 'FM999999990.00', 'NLS_NUMERIC_CHARACTERS=''.,''') || ' GiB'
                    ELSE TO_CHAR(a.best_bytes / 1048576, 'FM999999990', 'NLS_NUMERIC_CHARACTERS=''.,''') || ' MiB'
               END AS best_txt,
               CASE WHEN NVL(a.slack_bytes, a.near_bytes) >= 1073741824
                    THEN TO_CHAR(NVL(a.slack_bytes, a.near_bytes) / 1073741824, 'FM999999990.00', 'NLS_NUMERIC_CHARACTERS=''.,''') || ' GiB'
                    ELSE TO_CHAR(NVL(a.slack_bytes, a.near_bytes) / 1048576, 'FM999999990', 'NLS_NUMERIC_CHARACTERS=''.,''') || ' MiB'
               END AS small_txt
        FROM   capm_area a
     ),
     adv_ev AS (
        SELECT a.dbid, a.instance_number, a.area,
               CASE k.n WHEN 1 THEN a.sig || CASE a.gain_unit WHEN 'PTS' THEN '_ADV_HIT_GAIN_PTS'
                                                               ELSE '_ADV_GAIN_DBTIME_PCT' END
                        WHEN 2 THEN a.sig || CASE a.gain_unit WHEN 'PTS' THEN '_ADV_SHRINK_LOSS_PTS'
                                                               ELSE '_ADV_SHRINK_LOSS_DBTIME_PCT' END
                        ELSE a.sig || '_ADV_OVERALLOC' END AS signal,
               'ADVISOR' AS kind,
               CASE k.n WHEN 1 THEN ROUND(a.best_gain, 4)
                        WHEN 2 THEN ROUND(NVL(a.slack_loss, a.near_loss), 4)
                        ELSE a.cur_overalloc END AS value,
               CASE k.n WHEN 3 THEN 'COUNT' ELSE a.gain_unit END AS unit,
               CASE k.n WHEN 1 THEN a.gain_thr WHEN 2 THEN a.shrink_thr ELSE 1 END AS threshold,
               CASE k.n WHEN 1 THEN CASE WHEN a.best_gain >= a.gain_thr THEN 'PRESSURE' ELSE 'NEUTRAL' END
                        WHEN 2 THEN CASE WHEN a.slack_bytes IS NOT NULL THEN 'SLACK' ELSE 'NEUTRAL' END
                        ELSE CASE WHEN a.cur_overalloc >= 1 THEN 'PRESSURE' ELSE 'NEUTRAL' END
               END AS direction,
               a.window_end AS observed_at,
               CASE WHEN k.n = 3 THEN 'The PGA advisor counted '
                    WHEN a.gain_unit = 'PTS'
                    THEN 'The PGA advisor estimates a cache hit ' || CASE k.n WHEN 1 THEN 'gain' ELSE 'loss' END || ' of '
                    ELSE 'The ' || a.advisor_name || ' advisor estimates '
               END AS lead,
               CASE WHEN k.n = 3 THEN ' over-allocations in the window at the current ' || a.cur_txt
                    ELSE CASE WHEN a.gain_unit = 'PTS' THEN ' points at '
                              WHEN k.n = 1 THEN '% of DB time saved at '
                              ELSE '% of DB time lost at ' END
                         || CASE k.n WHEN 1 THEN a.best_txt ELSE a.small_txt END
                         || ' against the current ' || a.cur_txt
               END AS tail
        FROM   ar a
        CROSS  JOIN (SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 3) k
        WHERE  (k.n = 1 AND a.best_gain IS NOT NULL)
           OR  (k.n = 2 AND NVL(a.slack_loss, a.near_loss) IS NOT NULL)
           OR  (k.n = 3 AND a.cur_overalloc IS NOT NULL)
     ),
     thr AS (
        SELECT LOWER(knob) AS knob, value
        FROM   cap_cfg
        UNPIVOT (value FOR knob IN (mem_multipass_pct, mem_onepass_pct, mem_temp_io_dbtime_pct,
                                    mem_symptom_dbtime_pct, mem_reload_pct, mem_rowcache_miss_pct))
     ),
     sig AS (
        SELECT 'PGA_MULTIPASS_PCT' AS signal, 'PGA_TARGET' AS area, 'PCT' AS unit, 'WORKAREA' AS src,
               'mem_multipass_pct' AS knob, 'Multi-pass executions were ' AS lead,
               '% of all work area executions in the window' AS tail FROM dual
        UNION ALL SELECT 'PGA_ONEPASS_PCT', 'PGA_TARGET', 'PCT', 'WORKAREA', 'mem_onepass_pct',
               'One-pass executions were ', '% of all work area executions in the window' FROM dual
        UNION ALL SELECT 'PGA_OVERALLOC_COUNT', 'PGA_TARGET', 'COUNT', 'PGASTAT', NULL,
               'The instance over-allocated PGA memory ', ' times in the window' FROM dual
        UNION ALL SELECT 'PGA_TEMP_IO_DBTIME_PCT', 'PGA_TARGET', 'PCT', 'EVENT', 'mem_temp_io_dbtime_pct',
               'Direct path I/O on temporary segments took ', '% of DB time in the window' FROM dual
        UNION ALL SELECT 'CACHE_FREE_BUFFER_WAIT_DBTIME_PCT', 'BUFFER_CACHE', 'PCT', 'EVENT', 'mem_symptom_dbtime_pct',
               'Free buffer waits took ', '% of DB time in the window' FROM dual
        UNION ALL SELECT 'SHPOOL_WAIT_DBTIME_PCT', 'SHARED_POOL', 'PCT', 'EVENT', 'mem_symptom_dbtime_pct',
               'Shared pool latch, library cache mutex and load lock waits and forced component growth took ',
               '% of DB time in the window' FROM dual
        UNION ALL SELECT 'SHPOOL_RELOAD_PCT', 'SHARED_POOL', 'PCT', 'LIBCACHE', 'mem_reload_pct',
               'Library cache reloads were ', '% of pins in the window' FROM dual
        UNION ALL SELECT 'SHPOOL_ROWCACHE_MISS_PCT', 'SHARED_POOL', 'PCT', 'ROWCACHE', 'mem_rowcache_miss_pct',
               'Dictionary cache misses were ', '% of gets in the window' FROM dual
     ),
     term AS (
        SELECT 'PGA_MULTIPASS_PCT' AS signal, 'N' AS role, 'WORKAREA' AS metric, 'MULTIPASS' AS key FROM dual
        UNION ALL SELECT 'PGA_MULTIPASS_PCT', 'D', 'WORKAREA', NULL FROM dual
        UNION ALL SELECT 'PGA_ONEPASS_PCT',   'N', 'WORKAREA', 'ONEPASS' FROM dual
        UNION ALL SELECT 'PGA_ONEPASS_PCT',   'D', 'WORKAREA', NULL FROM dual
        UNION ALL SELECT 'PGA_OVERALLOC_COUNT', 'N', 'PGASTAT', 'over allocation count' FROM dual
        UNION ALL SELECT 'PGA_TEMP_IO_DBTIME_PCT', 'N', 'EVENT', 'direct path read temp' FROM dual
        UNION ALL SELECT 'PGA_TEMP_IO_DBTIME_PCT', 'N', 'EVENT', 'direct path write temp' FROM dual
        UNION ALL SELECT 'PGA_TEMP_IO_DBTIME_PCT', 'D', 'DBTIME', NULL FROM dual
        UNION ALL SELECT 'CACHE_FREE_BUFFER_WAIT_DBTIME_PCT', 'N', 'EVENT', 'free buffer waits' FROM dual
        UNION ALL SELECT 'CACHE_FREE_BUFFER_WAIT_DBTIME_PCT', 'D', 'DBTIME', NULL FROM dual
        UNION ALL SELECT 'SHPOOL_WAIT_DBTIME_PCT', 'N', 'EVENT', 'latch: shared pool' FROM dual
        UNION ALL SELECT 'SHPOOL_WAIT_DBTIME_PCT', 'N', 'EVENT', 'library cache: mutex X' FROM dual
        UNION ALL SELECT 'SHPOOL_WAIT_DBTIME_PCT', 'N', 'EVENT', 'library cache load lock' FROM dual
        UNION ALL SELECT 'SHPOOL_WAIT_DBTIME_PCT', 'N', 'EVENT', 'SGA: allocation forcing component growth' FROM dual
        UNION ALL SELECT 'SHPOOL_WAIT_DBTIME_PCT', 'D', 'DBTIME', NULL FROM dual
        UNION ALL SELECT 'SHPOOL_RELOAD_PCT', 'N', 'LIBCACHE', 'RELOADS' FROM dual
        UNION ALL SELECT 'SHPOOL_RELOAD_PCT', 'D', 'LIBCACHE', 'PINS' FROM dual
        UNION ALL SELECT 'SHPOOL_ROWCACHE_MISS_PCT', 'N', 'ROWCACHE', 'GETMISSES' FROM dual
        UNION ALL SELECT 'SHPOOL_ROWCACHE_MISS_PCT', 'D', 'ROWCACHE', 'GETS' FROM dual
     ),
     sums AS (
        SELECT dbid, instance_number, metric, key, SUM(delta) AS total
        FROM   capm_delta
        WHERE  in_win = 'Y'
          AND  metric IN ('PGASTAT', 'WORKAREA', 'EVENT', 'LIBCACHE', 'ROWCACHE', 'DBTIME')
        GROUP  BY dbid, instance_number, metric, key
     ),
     ratio AS (
        SELECT s.dbid, s.instance_number, t.signal,
               SUM(CASE WHEN t.role = 'N' THEN s.total END) AS n_total,
               SUM(CASE WHEN t.role = 'D' THEN s.total END) AS d_total
        FROM   term t
        JOIN   sums s
          ON   s.metric = t.metric AND (t.key IS NULL OR s.key = t.key)
        GROUP  BY s.dbid, s.instance_number, t.signal
     ),
     sym_ev AS (
        SELECT h.dbid, h.instance_number, g.area, g.signal, 'SYMPTOM' AS kind,
               CASE WHEN g.unit = 'COUNT' THEN NVL(r.n_total, 0)
                    ELSE ROUND(100 * NVL(r.n_total, 0) / r.d_total, 4) END AS value,
               g.unit,
               CASE WHEN g.unit = 'COUNT' THEN 1 ELSE t.value END AS threshold,
               i.window_end AS observed_at, g.lead, g.tail
        FROM   sig g
        JOIN   (SELECT DISTINCT dbid, instance_number, metric FROM sums) h
          ON   h.metric = g.src
        JOIN   (SELECT DISTINCT dbid, instance_number, window_end FROM ar) i
          ON   i.dbid = h.dbid AND i.instance_number = h.instance_number
        LEFT   JOIN ratio r
          ON   r.dbid = h.dbid AND r.instance_number = h.instance_number
         AND   r.signal = g.signal
        LEFT   JOIN thr t ON t.knob = g.knob
        WHERE  g.unit = 'COUNT' OR r.d_total > 0
     ),
     bal AS (
        SELECT b.*, cfg.mem_resize_ops_day, cfg.mem_resize_reversals
        FROM   capm_sga_balance b
        CROSS  JOIN cap_cfg cfg
     ),
     bal_ev AS (
        SELECT b.dbid, b.instance_number,
               DECODE(k.n, 1, 'BUFFER_CACHE', 2, 'SHARED_POOL', 3, 'SGA_TOTAL', 'SGA_BALANCE') AS area,
               DECODE(k.n, 1, 'CACHE_GROWS', 2, 'SHPOOL_FORCED_GROWS', 3, 'SGA_FORCED_GROWS',
                           4, 'SGA_RESIZE_OPS_DAY', 'SGA_RESIZE_REVERSALS') AS signal,
               'SYMPTOM' AS kind,
               DECODE(k.n, 1, b.cache_grows, 2, b.shpool_forced_grows, 3, b.sga_forced_grows,
                           4, ROUND(b.ops_per_day, 4), b.n_reversals) AS value,
               DECODE(k.n, 4, 'PER_DAY', 'COUNT') AS unit,
               DECODE(k.n, 4, b.mem_resize_ops_day, 5, b.mem_resize_reversals, 1) AS threshold,
               NVL(DECODE(k.n, 1, b.cache_grow_at, 2, b.shpool_forced_at, 3, b.sga_forced_at),
                   b.window_end) AS observed_at,
               DECODE(k.n, 1, 'The instance grew the buffer cache in ',
                           2, 'The shared pool was grown by force (IMMEDIATE) in ',
                           3, 'An SGA component was grown by force (IMMEDIATE) in ',
                           4, 'The SGA components were resized ',
                              'The buffer cache and the shared pool reversed direction ') AS lead,
               DECODE(k.n, 4, ' times per sampled day in the window',
                           5, ' times in the window',
                              ' snapshot intervals of the window') AS tail
        FROM   bal b
        CROSS  JOIN (SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 5) k
        WHERE  b.n_days > 0
     ),
     measured AS (
        SELECT dbid, instance_number, area, signal, kind, value, unit, threshold,
               CASE WHEN value >= threshold THEN 'PRESSURE' ELSE 'NEUTRAL' END AS direction,
               observed_at, lead, tail
        FROM  ( SELECT dbid, instance_number, area, signal, kind, value, unit, threshold,
                       observed_at, lead, tail
                FROM   sym_ev
                UNION  ALL
                SELECT dbid, instance_number, area, signal, kind, value, unit, threshold,
                       observed_at, lead, tail
                FROM   bal_ev
                WHERE  value IS NOT NULL )
     ),
     pressed AS (
        SELECT m.dbid, m.instance_number, 'SGA_TOTAL' AS area, 'SGA_POOLS_PRESSED' AS signal,
               'SYMPTOM' AS kind,
               COUNT(DISTINCT CASE WHEN m.direction = 'PRESSURE' THEN m.area END) AS value,
               'COUNT' AS unit, 2 AS threshold,
               CASE WHEN COUNT(DISTINCT CASE WHEN m.direction = 'PRESSURE' THEN m.area END) >= 2
                    THEN 'PRESSURE' ELSE 'NEUTRAL' END AS direction,
               MAX(i.window_end) AS observed_at,
               CAST(NULL AS VARCHAR2(1)) AS lead,
               ' of the buffer cache and the shared pool show a pressure symptom in the window' AS tail
        FROM   measured m
        JOIN   (SELECT DISTINCT dbid, instance_number, window_end FROM ar) i
          ON   i.dbid = m.dbid AND i.instance_number = m.instance_number
        WHERE  m.area IN ('BUFFER_CACHE', 'SHARED_POOL')
        GROUP  BY m.dbid, m.instance_number
     ),
     auto_share AS (
        SELECT dbid, instance_number,
               MIN(share_pct)                                          AS value,
               MIN(end_time) KEEP (DENSE_RANK FIRST ORDER BY share_pct) AS observed_at
        FROM  ( SELECT p.dbid, p.instance_number, s.end_time,
                       100 * MAX(CASE WHEN p.stat_name = 'aggregate PGA auto target' THEN p.value END)
                           / NULLIF(MAX(CASE WHEN p.stat_name = 'aggregate PGA target parameter'
                                             THEN p.value END), 0) AS share_pct
                FROM   capv_pgastat p
                JOIN   capm_snap s
                  ON   s.dbid = p.dbid AND s.instance_number = p.instance_number
                 AND   s.snap_id = p.snap_id
                WHERE  s.in_win = 'Y'
                  AND  p.stat_name IN ('aggregate PGA auto target', 'aggregate PGA target parameter')
                GROUP  BY p.dbid, p.instance_number, p.snap_id, s.end_time )
        WHERE  share_pct IS NOT NULL
        GROUP  BY dbid, instance_number
     ),
     shp_free AS (
        SELECT dbid, instance_number,
               MIN(free_pct)                                          AS value,
               MIN(end_time) KEEP (DENSE_RANK FIRST ORDER BY free_pct) AS observed_at
        FROM  ( SELECT g.dbid, g.instance_number, s.end_time,
                       100 * SUM(g.bytes) / NULLIF(MAX(m.current_size), 0) AS free_pct
                FROM   capv_sgastat g
                JOIN   capm_snap s
                  ON   s.dbid = g.dbid AND s.instance_number = g.instance_number
                 AND   s.snap_id = g.snap_id
                JOIN   capv_mem_comp m
                  ON   m.dbid = g.dbid AND m.instance_number = g.instance_number
                 AND   m.snap_id = g.snap_id AND m.component = 'shared pool'
                WHERE  s.in_win = 'Y'
                  AND  g.pool = 'shared pool' AND g.name = 'free memory'
                GROUP  BY g.dbid, g.instance_number, g.snap_id, s.end_time )
        WHERE  free_pct IS NOT NULL
        GROUP  BY dbid, instance_number
     ),
     ctx_ev AS (
        SELECT dbid, instance_number, 'PGA_TARGET' AS area, 'PGA_AUTO_SHARE_MIN_PCT' AS signal,
               'CONTEXT' AS kind, ROUND(value, 4) AS value, 'PCT' AS unit,
               CAST(NULL AS NUMBER) AS threshold, 'NEUTRAL' AS direction, observed_at,
               'The smallest share of the PGA target left for automatic work areas was ' AS lead,
               '% at ' || TO_CHAR(observed_at, 'YYYY-MM-DD HH24:MI') AS tail
        FROM   auto_share
        UNION  ALL
        SELECT f.dbid, f.instance_number, 'SHARED_POOL', 'SHPOOL_FREE_MIN_PCT',
               'CONTEXT', ROUND(f.value, 4), 'PCT', cfg.mem_shpool_free_pct,
               CASE WHEN ROUND(f.value, 4) >= cfg.mem_shpool_free_pct THEN 'SLACK' ELSE 'NEUTRAL' END,
               f.observed_at,
               'The smallest free share of the shared pool was ',
               '% at ' || TO_CHAR(f.observed_at, 'YYYY-MM-DD HH24:MI')
        FROM   shp_free f
        CROSS  JOIN cap_cfg cfg
     ),
     ev AS (
        SELECT dbid, instance_number, area, signal, kind, value, unit, threshold, direction,
               observed_at, lead, tail FROM lim_ev
        UNION  ALL
        SELECT dbid, instance_number, area, signal, kind, value, unit, threshold, direction,
               observed_at, lead, tail FROM adv_ev
        UNION  ALL
        SELECT dbid, instance_number, area, signal, kind, value, unit, threshold, direction,
               observed_at, lead, tail FROM measured
        UNION  ALL
        SELECT dbid, instance_number, area, signal, kind, value, unit, threshold, direction,
               observed_at, lead, tail FROM pressed
        UNION  ALL
        SELECT dbid, instance_number, area, signal, kind, value, unit, threshold, direction,
               observed_at, lead, tail FROM ctx_ev
     )
SELECT e.dbid,
       e.dbid                                   AS con_dbid,
       e.instance_number,
       CAST(e.area AS VARCHAR2(20))             AS area,
       CAST(e.signal AS VARCHAR2(40))           AS signal,
       e.value,
       CAST(e.unit AS VARCHAR2(10))             AS unit,
       e.threshold,
       CAST(e.direction AS VARCHAR2(10))        AS direction,
       e.observed_at,
       CAST(e.lead
            || CASE WHEN e.unit IN ('PCT', 'PTS', 'PER_DAY')
                    THEN TO_CHAR(e.value, 'FM999999990.00', 'NLS_NUMERIC_CHARACTERS=''.,''')
                    ELSE TO_CHAR(e.value, 'FM999999999990', 'NLS_NUMERIC_CHARACTERS=''.,''') END
            || e.tail
            || CASE WHEN e.threshold IS NOT NULL
                    THEN ' (threshold '
                         || RTRIM(TO_CHAR(e.threshold, 'FM9999990.99', 'NLS_NUMERIC_CHARACTERS=''.,'''), '.')
                         || DECODE(e.unit, 'PCT', '%', 'PTS', ' points', 'PER_DAY', ' a day')
                         || ')' END
            || '.' AS VARCHAR2(400))            AS evidence_text,
       CAST(e.kind AS VARCHAR2(10))             AS kind
FROM   ev e;

-- --------------------------------------------------------------------
-- CAPM_VERDICT -- one grade per (dbid, instance_number, area).
--   Every area is first reduced to the same facts (fact), a few Y / N flags
--   among them, and its evidence to counts (ev). The grade and its reason
--   then come from ONE decision table (rule): the rows of the area's class,
--   top to bottom, the first whose non-NULL flags all match.
--     collected  the area has history in the window
--     amm        mem_mode AMM
--     manual     mem_mode MANUAL, on SGA_TOTAL and SGA_BALANCE
--     thin       the advisor's coverage is under mem_min_uptime_hours
--     adv_p      an ADVISOR row in PRESSURE     sym_p  a SYMPTOM row in PRESSURE
--     any_p      a row of any kind in PRESSURE  slack  an ADVISOR row in SLACK
--     days_ok    enough sampled days (mem_shrink_min_days; PGA_LIMIT:
--                mem_min_days)
--     no_limit   PGA_LIMIT: pga_aggregate_limit is 0
--   CONTEXT rows never decide a grade: no flag reads them alone, and none is
--   ever PRESSURE.
--   current_bytes      the size in force now: the advisor's current size,
--                      pga_aggregate_limit for PGA_LIMIT, sga_target for
--                      SGA_BALANCE.
--   suggested_bytes    NULL unless a change is advised. UNDERSIZED: PGA_LIMIT
--                      in whole MiB, the size that puts the larger peak at
--                      mem_pga_limit_pct percent, capped at mem_max_step
--                      times the limit; an advisor area CAPM_AREA.grow_bytes.
--                      OVERSIZED: CAPM_AREA.slack_bytes. THRASHING:
--                      CAPM_SGA_BALANCE.floor_bytes, a floor for floor_pool.
--   suggested_param    the parameter the suggestion is for. Under ASMM a
--                      db_cache_size or shared_pool_size is a floor.
--                      SGA_BALANCE names one only when THRASHING.
--   exceeds_host_ram   on PGA_LIMIT, PGA_TARGET and SGA_TOTAL rows with a
--                      suggestion: Y when it plus the other side's current
--                      size (the SGA, or pga_aggregate_target for SGA_TOTAL)
--                      passes mem_host_ram_pct percent of the host's
--                      physical memory, N when not, NULL when the host's
--                      memory is unknown. The suggestion is never reduced
--                      for it, and other instances on the host are not seen.
--   n_evidence / n_pressure  the area's CAPM_EVIDENCE rows, and how many of
--                      them are PRESSURE.
--   n_days             the area's sampled days in the window.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capm_verdict AS
WITH ev AS (
        SELECT dbid, instance_number, area,
               COUNT(*)                                                                AS n_evidence,
               COUNT(CASE WHEN direction = 'PRESSURE' THEN 1 END)                      AS n_pressure,
               COUNT(CASE WHEN direction = 'PRESSURE' AND kind = 'ADVISOR' THEN 1 END) AS n_adv_pressure,
               COUNT(CASE WHEN direction = 'PRESSURE' AND kind = 'SYMPTOM' THEN 1 END) AS n_sym_pressure,
               COUNT(CASE WHEN direction = 'SLACK' AND kind = 'ADVISOR' THEN 1 END)    AS n_adv_slack
        FROM   capm_evidence
        GROUP  BY dbid, instance_number, area
     ),
     fact AS (
        SELECT 'LIMIT' AS cls, l.dbid, l.con_dbid, l.instance_number, 'PGA_LIMIT' AS area,
               l.mem_mode, l.window_start, l.window_end, l.n_days,
               l.limit_bytes AS current_bytes,
               LEAST(CEIL(GREATEST(NVL(l.hwm_peak_bytes, l.sampled_peak_bytes),
                                   NVL(l.sampled_peak_bytes, l.hwm_peak_bytes))
                          * 100 / cfg.mem_pga_limit_pct / 1048576),
                     FLOOR(l.limit_bytes * cfg.mem_max_step / 1048576)) * 1048576 AS up_bytes,
               CAST(NULL AS NUMBER) AS down_bytes,
               'pga_aggregate_limit' AS param,
               CASE WHEN l.n_days = 0 THEN 'N' ELSE 'Y' END                AS collected,
               'N' AS manual, 'N' AS thin,
               CASE WHEN l.n_days < cfg.mem_min_days THEN 'N' ELSE 'Y' END AS days_ok,
               CASE WHEN l.limit_bytes IS NULL THEN 'Y' ELSE 'N' END       AS no_limit,
               'Y' AS ram_flag, NVL(l.sga_bytes, 0) AS other_bytes, l.host_ram_bytes
        FROM   capm_pga_limit l
        CROSS  JOIN cap_cfg cfg
        UNION  ALL
        SELECT 'ADVISOR', a.dbid, a.con_dbid, a.instance_number, a.area,
               a.mem_mode, a.window_start, a.window_end, a.n_days,
               a.current_bytes, a.grow_bytes, a.slack_bytes, a.suggested_param,
               CASE WHEN a.n_adv_snaps = 0 THEN 'N' ELSE 'Y' END,
               CASE WHEN a.mem_mode = 'MANUAL' AND a.area = 'SGA_TOTAL' THEN 'Y' ELSE 'N' END,
               a.advisor_thin,
               CASE WHEN a.n_days < cfg.mem_shrink_min_days THEN 'N' ELSE 'Y' END,
               'N',
               CASE WHEN a.area IN ('PGA_TARGET', 'SGA_TOTAL') THEN 'Y' ELSE 'N' END,
               CASE a.area WHEN 'PGA_TARGET' THEN NVL(a.sga_bytes, 0)
                           ELSE NVL(a.pga_target_bytes, 0) END,
               a.host_ram_bytes
        FROM   capm_area a
        CROSS  JOIN cap_cfg cfg
        UNION  ALL
        SELECT 'BALANCE', b.dbid, b.con_dbid, b.instance_number, 'SGA_BALANCE',
               b.mem_mode, b.window_start, b.window_end, b.n_days,
               b.sga_target_bytes, b.floor_bytes, NULL, b.floor_param,
               CASE WHEN b.n_days = 0 THEN 'N' ELSE 'Y' END,
               CASE WHEN b.mem_mode = 'MANUAL' THEN 'Y' ELSE 'N' END,
               'N', 'Y', 'N', 'N', 0, NULL
        FROM   capm_sga_balance b
     ),
     rule AS (
        SELECT 'ADVISOR' AS cls, 1 AS n, 'INSUFFICIENT_EVIDENCE' AS grade, 'NOT_COLLECTED' AS reason,
               'N' AS collected, CAST(NULL AS VARCHAR2(1)) AS amm, CAST(NULL AS VARCHAR2(1)) AS manual,
               CAST(NULL AS VARCHAR2(1)) AS thin, CAST(NULL AS VARCHAR2(1)) AS adv_p,
               CAST(NULL AS VARCHAR2(1)) AS sym_p, CAST(NULL AS VARCHAR2(1)) AS any_p,
               CAST(NULL AS VARCHAR2(1)) AS slack, CAST(NULL AS VARCHAR2(1)) AS days_ok,
               CAST(NULL AS VARCHAR2(1)) AS no_limit FROM dual
        --                           cls        n   grade                    reason                 coll  amm   man   thin  advp  symp  anyp  slack days  nolim
        UNION ALL SELECT 'ADVISOR',  2, 'INSUFFICIENT_EVIDENCE', 'AMM',                 NULL, 'Y',  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM dual
        UNION ALL SELECT 'ADVISOR',  3, 'INSUFFICIENT_EVIDENCE', 'MANUAL_SIZING',       NULL, NULL, 'Y',  NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM dual
        UNION ALL SELECT 'ADVISOR',  4, 'INSUFFICIENT_EVIDENCE', 'ADVISOR_THIN',        NULL, NULL, NULL, 'Y',  NULL, NULL, NULL, NULL, NULL, NULL FROM dual
        UNION ALL SELECT 'ADVISOR',  5, 'UNDERSIZED',            'ADVISOR_AND_SYMPTOM', NULL, NULL, NULL, NULL, 'Y',  'Y',  NULL, NULL, NULL, NULL FROM dual
        UNION ALL SELECT 'ADVISOR',  6, 'OK',                    'ADVISOR_ONLY',        NULL, NULL, NULL, NULL, 'Y',  NULL, NULL, NULL, NULL, NULL FROM dual
        UNION ALL SELECT 'ADVISOR',  7, 'OK',                    'SYMPTOM_ONLY',        NULL, NULL, NULL, NULL, NULL, 'Y',  NULL, NULL, NULL, NULL FROM dual
        UNION ALL SELECT 'ADVISOR',  8, 'OVERSIZED',             'SHRINK_COSTS_LITTLE', NULL, NULL, NULL, NULL, NULL, NULL, 'N',  'Y',  'Y',  NULL FROM dual
        UNION ALL SELECT 'ADVISOR',  9, 'OK',                    'SHRINK_UNPROVEN',     NULL, NULL, NULL, NULL, NULL, NULL, 'N',  'Y',  NULL, NULL FROM dual
        UNION ALL SELECT 'ADVISOR', 10, 'OK',                    'SIZED_RIGHT',         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM dual
        UNION ALL SELECT 'BALANCE',  1, 'INSUFFICIENT_EVIDENCE', 'NOT_COLLECTED',       'N',  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM dual
        UNION ALL SELECT 'BALANCE',  2, 'INSUFFICIENT_EVIDENCE', 'AMM',                 NULL, 'Y',  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM dual
        UNION ALL SELECT 'BALANCE',  3, 'INSUFFICIENT_EVIDENCE', 'MANUAL_SIZING',       NULL, NULL, 'Y',  NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM dual
        UNION ALL SELECT 'BALANCE',  4, 'THRASHING',             'RESIZE_CHURN',        NULL, NULL, NULL, NULL, NULL, NULL, 'Y',  NULL, NULL, NULL FROM dual
        UNION ALL SELECT 'BALANCE',  5, 'OK',                    'STABLE',              NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM dual
        UNION ALL SELECT 'LIMIT',    1, 'INSUFFICIENT_EVIDENCE', 'NOT_COLLECTED',       'N',  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM dual
        UNION ALL SELECT 'LIMIT',    2, 'INSUFFICIENT_EVIDENCE', 'AMM',                 NULL, 'Y',  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM dual
        UNION ALL SELECT 'LIMIT',    3, 'OK',                    'NO_LIMIT',            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'Y'  FROM dual
        UNION ALL SELECT 'LIMIT',    4, 'UNDERSIZED',            'PEAK_NEAR_LIMIT',     NULL, NULL, NULL, NULL, NULL, NULL, 'Y',  NULL, NULL, NULL FROM dual
        UNION ALL SELECT 'LIMIT',    5, 'INSUFFICIENT_EVIDENCE', 'WINDOW_TOO_SHORT',    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'N',  NULL FROM dual
        UNION ALL SELECT 'LIMIT',    6, 'OK',                    'PEAK_BELOW_LIMIT',    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM dual
     ),
     flagged AS (
        SELECT f.*,
               NVL(e.n_evidence, 0) AS n_evidence,
               NVL(e.n_pressure, 0) AS n_pressure,
               CASE WHEN f.mem_mode = 'AMM'         THEN 'Y' ELSE 'N' END AS amm,
               CASE WHEN e.n_adv_pressure > 0       THEN 'Y' ELSE 'N' END AS adv_p,
               CASE WHEN e.n_sym_pressure > 0       THEN 'Y' ELSE 'N' END AS sym_p,
               CASE WHEN e.n_pressure > 0           THEN 'Y' ELSE 'N' END AS any_p,
               CASE WHEN e.n_adv_slack > 0          THEN 'Y' ELSE 'N' END AS slack
        FROM   fact f
        LEFT   JOIN ev e
          ON   e.dbid = f.dbid AND e.instance_number = f.instance_number
         AND   e.area = f.area
     ),
     decided AS (
        SELECT f.*, r.grade, r.reason,
               ROW_NUMBER() OVER (PARTITION BY f.dbid, f.instance_number, f.area ORDER BY r.n) AS rn
        FROM   flagged f
        JOIN   rule r
          ON   r.cls = f.cls
         AND   (r.collected IS NULL OR r.collected = f.collected)
         AND   (r.amm       IS NULL OR r.amm       = f.amm)
         AND   (r.manual    IS NULL OR r.manual    = f.manual)
         AND   (r.thin      IS NULL OR r.thin      = f.thin)
         AND   (r.adv_p     IS NULL OR r.adv_p     = f.adv_p)
         AND   (r.sym_p     IS NULL OR r.sym_p     = f.sym_p)
         AND   (r.any_p     IS NULL OR r.any_p     = f.any_p)
         AND   (r.slack     IS NULL OR r.slack     = f.slack)
         AND   (r.days_ok   IS NULL OR r.days_ok   = f.days_ok)
         AND   (r.no_limit  IS NULL OR r.no_limit  = f.no_limit)
     ),
     v AS (
        SELECT d.*,
               CASE WHEN d.grade IN ('UNDERSIZED', 'THRASHING') THEN d.up_bytes
                    WHEN d.grade = 'OVERSIZED'                  THEN d.down_bytes
               END AS suggested_bytes
        FROM   decided d
        WHERE  d.rn = 1
     )
SELECT v.dbid,
       v.con_dbid,
       v.instance_number,
       CAST(v.area AS VARCHAR2(20))             AS area,
       v.mem_mode,
       CAST(v.grade  AS VARCHAR2(30))           AS grade,
       CAST(v.reason AS VARCHAR2(30))           AS reason,
       v.current_bytes,
       v.suggested_bytes,
       CAST(CASE WHEN v.ram_flag = 'Y' AND v.suggested_bytes IS NOT NULL AND v.host_ram_bytes > 0
                 THEN CASE WHEN v.other_bytes + v.suggested_bytes
                                > cfg.mem_host_ram_pct / 100 * v.host_ram_bytes
                           THEN 'Y' ELSE 'N' END
            END AS VARCHAR2(1))                 AS exceeds_host_ram,
       v.n_evidence,
       v.n_pressure,
       v.window_start,
       v.window_end,
       v.n_days,
       CAST(CASE WHEN v.cls = 'BALANCE' AND v.grade <> 'THRASHING' THEN NULL ELSE v.param END
            AS VARCHAR2(30))                    AS suggested_param
FROM   v
CROSS  JOIN cap_cfg cfg;
