--
-- repository/seam.sql -- the CAPV_* seam, written over DBA_HIST_*.
-- =====================================================================
-- Never installed itself. repository/build.py turns it into
-- ddl/13_seam_repository.sql by renaming every dba_hist_<x> to cap_h_<x>,
-- the copies a repository pulls from its targets.
--
-- These twenty-five views (plus the CAPV_CONTRACT diagnostic at the bottom) are
-- the ONLY place the analytics touch AWR data. Everything downstream
-- (CAPD_/CAPF_/CAPA_/report) is written once against CAPV_* and runs
-- byte-identically over ddl/13 (repository) or ddl/12_seam_fixture.sql
-- (fixture), which re-point the same column contract at a different source.
--
-- Column contract (identical in every seam file):
--   * every view carries (dbid, con_dbid), but CAPV_TARGET (per dbid).
--     DBA_HIST_SNAPSHOT has no CON_DBID column, so CAPV_SNAPSHOT sets
--     con_dbid := dbid. The tablespace/OS/time
--     views expose the real CON_DBID, which is REQUIRED to separate PDBs:
--     TABLESPACE_ID / TS# restart at 0 per container, so SYSTEM in the root
--     and SYSTEM in a PDB collide unless con_dbid disambiguates them.
--   * every source read keeps dbid = NVL(<the CAP_SCOPE expression>, dbid)
--     (M24.11, ddl/05): a session scoped to one database reads only its
--     rows, on each side of a join, in each UNION branch and in each NOT
--     EXISTS, because no predicate placed above the seam survives the
--     fleet-wide ranks and materialized subqueries of the views downstream.
--     An unscoped session reads everything. The expression is CAP_SCOPE's,
--     inline: as a (SELECT scope_dbid FROM cap_scope) subquery each read
--     added a FAST DUAL to the plan, 16% more plan lines and 20 MB more
--     parse memory in the deepest views (19.27); SYS_CONTEXT is evaluated
--     once per execution either way.
--
-- Container facts (verified on 19c in CDB$ROOT, AWR_PDB_AUTOFLUSH_ENABLED =
-- FALSE, the default):
--   * Per container: DBA_HIST_TBSPC_SPACE_USAGE, DBA_HIST_CON_SYS_TIME_MODEL,
--     DBA_HIST_CON_SYSSTAT. CAPV_TBSPC_USAGE / CAPV_TIME_MODEL / CAPV_SYSSTAT
--     read these, minus PDB$SEED.
--   * Root only, CDB-wide: DBA_HIST_SYS_TIME_MODEL and DBA_HIST_SYSSTAT hold
--     one row per snapshot under the CDB's con_dbid, and that row is the
--     CDB total. They are used only as the non-CDB fallback below.
--   * Root only, by nature: DBA_HIST_OSSTAT (host level),
--     DBA_HIST_RESOURCE_LIMIT, DBA_HIST_PGASTAT and the memory sources but
--     DBA_HIST_SGASTAT (instance level) and
--     DBA_HIST_ASM_DISKGROUP_STAT (host level). DBA_HIST_PARAMETER has root
--     rows plus PDB rows for the parameters set at PDB level; CAPV_PARAMETER
--     keeps the root rows.
--   * In the CON_ views the root row covers CDB$ROOT alone. The CDB total is
--     the SUM over containers.
--
-- Unit facts (do not "fix" these -- downstream converts):
--   * DBA_HIST_TBSPC_SPACE_USAGE sizes are in DB BLOCKS (multiply by the
--     tablespace block size to get bytes). Passed through as-is here.
--   * TABLESPACE_MAXSIZE = 0 means the tablespace has NO autoextend (its
--     current size is its ceiling).
--   * DBA_HIST_OSSTAT *_TIME values are in CENTISECONDS and are cumulative
--     counters since instance startup.
--   * DBA_HIST_CON_SYS_TIME_MODEL values are in MICROSECONDS, cumulative
--     counters.
--   * RTIME on TBSPC_SPACE_USAGE is an NLS-fragile VARCHAR2 -- we deliberately
--     ignore it and derive timestamps by joining snap_id -> CAPV_SNAPSHOT.
--   * We never join live DBA_TABLESPACES: it drops history for dropped
--     tablespaces and in repository mode describes the repository, not the
--     target. DBA_HIST_TABLESPACE / DBA_HIST_DATAFILE are the historical
--     dimensions.
--
SET DEFINE OFF

-- --------------------------------------------------------------------
-- CAPV_SNAPSHOT -- snapshot spine (timestamps + startup_time for restart
-- detection). con_dbid := dbid (no CON_DBID in the source).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_snapshot AS
SELECT dbid                     AS dbid,
       dbid                     AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       begin_interval_time      AS begin_interval_time,
       end_interval_time        AS end_interval_time,
       startup_time             AS startup_time
FROM   dba_hist_snapshot
WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- --------------------------------------------------------------------
-- CAPV_TBSPC_USAGE -- tablespace space usage, sizes in BLOCKS (as-is).
-- No instance_number in the source (usage is per-container, not per-inst).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_tbspc_usage AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       snap_id                  AS snap_id,
       tablespace_id            AS tablespace_id,
       tablespace_size          AS tablespace_size,      -- blocks
       tablespace_maxsize       AS tablespace_maxsize,   -- blocks; 0 = no autoextend
       tablespace_usedsize      AS tablespace_usedsize   -- blocks
FROM   dba_hist_tbspc_space_usage
WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- --------------------------------------------------------------------
-- CAPV_TABLESPACE -- tablespace dimension (name + contents + block size).
-- TS# is the join key to CAPV_TBSPC_USAGE.tablespace_id and
-- CAPV_DATAFILE.tablespace_id. block_size is the PRIMARY blocks->bytes factor:
-- DBA_HIST_TABLESPACE carries it for EVERY tablespace, whereas
-- DBA_HIST_DATAFILE can be missing rows (e.g. SYSTEM is absent on stock 19c),
-- which would otherwise drop that tablespace from the daily series entirely.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_tablespace AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       ts#                      AS tablespace_id,
       tsname                   AS tablespace_name,
       contents                 AS contents,            -- PERMANENT / UNDO / TEMPORARY
       block_size               AS block_size           -- bytes/block
FROM   dba_hist_tablespace
WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- --------------------------------------------------------------------
-- CAPV_DATAFILE -- block size per tablespace (MAX across its datafiles).
-- Secondary/fallback source of the blocks->bytes factor (CAPV_TABLESPACE is
-- primary). Kept because it survives dropped tablespaces; the daily layer
-- LEFT JOINs it and COALESCEs.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_datafile AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       ts#                      AS tablespace_id,
       MAX(block_size)          AS block_size           -- bytes/block
FROM   dba_hist_datafile
WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)
GROUP BY dbid, con_dbid, ts#;

-- --------------------------------------------------------------------
-- CAPV_OSSTAT -- host OS stats, filtered to the CPU/memory names the CPU
-- layer consumes. *_TIME values are cumulative counters in centiseconds.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_osstat AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       stat_name                AS stat_name,
       value                    AS value
FROM   dba_hist_osstat
WHERE  stat_name IN ('BUSY_TIME','IDLE_TIME','IOWAIT_TIME',
                     'NUM_CPUS','NUM_CPU_CORES','PHYSICAL_MEMORY_BYTES')
  AND  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- --------------------------------------------------------------------
-- CAPV_TIME_MODEL -- DB time model PER CONTAINER, filtered to the three
-- CPU/DB-time names. Values are cumulative counters in microseconds.
--   * Source DBA_HIST_CON_SYS_TIME_MODEL. DBA_HIST_SYS_TIME_MODEL is not
--     usable in a CDB: in CDB$ROOT it has one row per snapshot, under the
--     root's con_dbid, holding the CDB-wide total, so a PDB never got a
--     DB CPU series and the root's series was really the whole CDB.
--   * PDB$SEED is dropped by CON_ID <> 2 (CON_ID 2 is always the seed in a
--     CDB). It runs no workload and would only add a zero series.
--   * Fallback: a snapshot with no CON_ row for the statistic (a non-CDB, or
--     AWR data imported from one) reads DBA_HIST_SYS_TIME_MODEL, where
--     con_dbid is the dbid. Matching on the statistic, not on any CON_ row,
--     keeps the repository's copies (only these three names) exact.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_time_model AS
SELECT c.dbid                   AS dbid,
       c.con_dbid               AS con_dbid,
       c.instance_number        AS instance_number,
       c.snap_id                AS snap_id,
       c.stat_name              AS stat_name,
       c.value                  AS value
FROM   dba_hist_con_sys_time_model c
WHERE  c.stat_name IN ('DB CPU','DB time','background cpu time')
  AND  NVL(c.con_id, 0) <> 2
  AND  c.dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), c.dbid)
UNION ALL
SELECT s.dbid, s.con_dbid, s.instance_number, s.snap_id, s.stat_name, s.value
FROM   dba_hist_sys_time_model s
WHERE  s.stat_name IN ('DB CPU','DB time','background cpu time')
  AND  s.dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), s.dbid)
  AND  NOT EXISTS (SELECT 1
                   FROM   dba_hist_con_sys_time_model c
                   WHERE  c.dbid = s.dbid AND c.snap_id = s.snap_id
                     AND  c.dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), c.dbid)
                     AND  c.instance_number = s.instance_number
                     AND  c.stat_name = s.stat_name);

-- --------------------------------------------------------------------
-- CAPV_CONTAINER -- container/database naming dimension: one row per
-- (dbid, con_dbid) AWR has seen, with the human names the report prints
-- instead of raw con_dbid values.
--   * DBA_HIST_PDB_INSTANCE (19c, CDB only) names every container incl.
--     CDB$ROOT (whose con_dbid equals the CDB dbid; verified on 19c).
--   * On a NON-CDB that view has no rows, so a fallback branch emits the
--     (dbid, dbid) key with con_name NULL; db_name always comes from
--     DBA_HIST_DATABASE_INSTANCE.
-- The UNION dedupes the key set; MAX() collapses per-instance/per-startup
-- duplicate dimension rows to one name per container.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_container AS
SELECT k.dbid,
       k.con_dbid,
       d.db_name,
       p.con_name
FROM  (
        SELECT dbid, con_dbid FROM dba_hist_pdb_instance
        WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)
        UNION
        SELECT dbid, dbid FROM dba_hist_database_instance
        WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)
      ) k
LEFT  JOIN (SELECT dbid, MAX(db_name) AS db_name
            FROM   dba_hist_database_instance
            WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)
            GROUP  BY dbid) d
  ON  d.dbid = k.dbid
LEFT  JOIN (SELECT dbid, con_dbid, MAX(pdb_name) AS con_name
            FROM   dba_hist_pdb_instance
            WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)
            GROUP  BY dbid, con_dbid) p
  ON  p.dbid = k.dbid AND p.con_dbid = k.con_dbid;

-- --------------------------------------------------------------------
-- CAPV_TARGET (M24.6) -- what the suite measures and how it is fed, from the
-- registry of repository/cap_repo.sql (included before the seam): one row
-- per registered target and DBID (dbid NULL until the first DBID is
-- found), fed LINK, with the collect health from CAP_COLLECT_LOG. Only log
-- rows since the target was added count, so a removed and re-added target
-- starts clean. An ERROR logged with dbid NULL (the link failed before any
-- DBID was reached) applies to every DBID of the target. n_gaps counts GAP
-- rows: snapshots the target purged before they were copied. The health
-- columns are scalar subqueries, not joins, because the optimizer drops an
-- unselected one: CAPR_CONTAINER, which every report view joins and which
-- reads only target_name, never touches the log (verified 19.27).
-- Scoped (the CAP_SCOPE expression) like every seam view, NULL-safe: a
-- target with no DBID yet is in no database's scope.
CREATE OR REPLACE VIEW capv_target AS
SELECT CAST(t.target_name AS VARCHAR2(30))      AS target_name,
       d.dbid                                   AS dbid,
       CAST('LINK' AS VARCHAR2(10))             AS feed,
       CAST(h.host_name AS VARCHAR2(64))        AS host_name,
       CAST(t.connect_string AS VARCHAR2(4000)) AS address,
       CAST(t.db_link AS VARCHAR2(128))         AS db_link,
       CAST(t.enabled AS VARCHAR2(1))           AS enabled,
       d.last_snap_id                           AS collected_snap_id,
       (SELECT MAX(g.logged_at) FROM cap_collect_log g
        WHERE  g.target_name = t.target_name AND g.dbid = d.dbid
          AND  g.status IN ('OK', 'NOTHING') AND g.logged_at >= t.added_at) AS last_ok_at,
       (SELECT MAX(g.logged_at) FROM cap_collect_log g
        WHERE  g.target_name = t.target_name AND (g.dbid = d.dbid OR g.dbid IS NULL)
          AND  g.status = 'ERROR' AND g.logged_at >= t.added_at)            AS last_error_at,
       (SELECT CAST(MAX(g.message) KEEP (DENSE_RANK LAST ORDER BY g.logged_at, g.log_id)
                    AS VARCHAR2(4000))
        FROM   cap_collect_log g
        WHERE  g.target_name = t.target_name AND (g.dbid = d.dbid OR g.dbid IS NULL)
          AND  g.status = 'ERROR' AND g.logged_at >= t.added_at)            AS last_error,
       (SELECT COUNT(*) FROM cap_collect_log g
        WHERE  g.target_name = t.target_name AND g.dbid = d.dbid
          AND  g.status = 'GAP' AND g.logged_at >= t.added_at)              AS n_gaps
FROM   cap_target t
LEFT   JOIN cap_target_dbid d
  ON   d.target_id = t.target_id
LEFT   JOIN (SELECT dbid,
                    MAX(host_name) KEEP (DENSE_RANK LAST ORDER BY startup_time NULLS FIRST) AS host_name
             FROM   dba_hist_database_instance
             WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)
             GROUP  BY dbid) h
  ON   h.dbid = d.dbid
WHERE  TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)) IS NULL
   OR  d.dbid = TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1));

-- --------------------------------------------------------------------
-- CAPV_RESOURCE_LIMIT (M11.1) -- per-instance resource high-water marks vs
-- their configured ceilings, filtered to the two that actually cause outages:
-- `processes` and `sessions`.
--   * CURRENT_UTILIZATION = in use at snapshot time.
--   * MAX_UTILIZATION     = HIGH-WATER MARK since instance startup (so it is
--                           monotone within a startup epoch and resets on
--                           restart -- CAPD_SERIES_DAILY documents that).
--   * LIMIT_VALUE is a VARCHAR2(10) in the source and can read 'UNLIMITED',
--     so it is converted here: numeric strings become NUMBER, anything else
--     becomes NULL (= "no ceiling"), which the daily/forecast layers treat as
--     "no days-to-limit".
--   * DBA_HIST_RESOURCE_LIMIT has a CON_DBID column, but in CDB$ROOT its rows
--     are root-only (verified on 19c): the limits are instance-wide, so
--     PROCESSES / SESSIONS are CDB-wide series under the root's con_dbid.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_resource_limit AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       resource_name            AS resource_name,
       current_utilization      AS current_utilization,
       max_utilization          AS max_utilization,
       CASE WHEN REGEXP_LIKE(TRIM(limit_value), '^[0-9]+$')
            THEN TO_NUMBER(TRIM(limit_value))
       END                      AS limit_value
FROM   dba_hist_resource_limit
WHERE  resource_name IN ('processes','sessions')
  AND  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- --------------------------------------------------------------------
-- CAPV_SYSSTAT (M11.2) -- system statistics PER CONTAINER, filtered to the
-- counters the series read: 'redo size' (REDO_GB_DAY) and the four physical
-- I/O totals (IOPS, IO_MBPS: read / write requests and bytes, every I/O the
-- instance issues for the container, not only buffer cache I/O). All are
-- CUMULATIVE counters since instance startup (like the OSSTAT/time-model
-- counters), so the daily layer differences consecutive snaps and drops
-- restart-spanning intervals.
--   * AWR writes no row for a container's statistic that is still zero
--     since startup (19.27: a PDB had 1265 'physical write total IO
--     requests' rows beside 1572 read rows), so a name can be absent on a
--     snapshot that carries the others.
--   * Source DBA_HIST_CON_SYSSTAT, for the same reason as CAPV_TIME_MODEL:
--     DBA_HIST_SYSSTAT in CDB$ROOT carries the root's con_dbid only. The log
--     stream is shared, so the CDB's redo is the SUM over containers.
--   * Same PDB$SEED filter and non-CDB fallback as CAPV_TIME_MODEL.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_sysstat AS
SELECT c.dbid                   AS dbid,
       c.con_dbid               AS con_dbid,
       c.instance_number        AS instance_number,
       c.snap_id                AS snap_id,
       c.stat_name              AS stat_name,
       c.value                  AS value
FROM   dba_hist_con_sysstat c
WHERE  c.stat_name IN ('redo size',
                        'physical read total IO requests', 'physical write total IO requests',
                        'physical read total bytes', 'physical write total bytes')
  AND  NVL(c.con_id, 0) <> 2
  AND  c.dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), c.dbid)
UNION ALL
SELECT s.dbid, s.con_dbid, s.instance_number, s.snap_id, s.stat_name, s.value
FROM   dba_hist_sysstat s
WHERE  s.stat_name IN ('redo size',
                        'physical read total IO requests', 'physical write total IO requests',
                        'physical read total bytes', 'physical write total bytes')
  AND  s.dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), s.dbid)
  AND  NOT EXISTS (SELECT 1
                   FROM   dba_hist_con_sysstat c
                   WHERE  c.dbid = s.dbid AND c.snap_id = s.snap_id
                     AND  c.dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), c.dbid)
                     AND  c.instance_number = s.instance_number
                     AND  c.stat_name = s.stat_name);

-- --------------------------------------------------------------------
-- CAPV_PARAMETER -- the init parameters the suite reads as ceilings, one
-- row per (snapshot, instance, parameter), the value as a NUMBER.
--   * DBA_HIST_PARAMETER.VALUE is a VARCHAR2(512). A numeric string becomes
--     a NUMBER (the CAPV_RESOURCE_LIMIT guard), anything else NULL. Size
--     parameters are stored in bytes.
--   * Instance level, so con_dbid := dbid. In CDB$ROOT the source also
--     holds rows under a PDB's con_dbid for parameters set at PDB level
--     (verified on 19c: one snapshot carried sga_target for the root, the
--     seed and PDB1). Only the root row (con_dbid = dbid, or a non-CDB) is
--     kept, so a parameter has one value per snapshot and instance.
--   * Filtered to the parameters a downstream view reads or may read:
--     cpu_count (the CPU ceiling in CAPD_DBTIME_DAILY) and
--     db_recovery_file_dest_size (FRA days in CAPF_SERIES_FORECAST), plus
--     the process, session and memory ceilings.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_parameter AS
SELECT dbid                     AS dbid,
       dbid                     AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       LOWER(parameter_name)    AS parameter_name,
       CASE WHEN REGEXP_LIKE(TRIM(value), '^[0-9]+$')
            THEN TO_NUMBER(TRIM(value))
       END                      AS value_num
FROM   dba_hist_parameter
WHERE  parameter_name IN ('cpu_count','processes','sessions',
                          'db_recovery_file_dest_size',
                          'sga_target','sga_max_size',
                          'pga_aggregate_target','pga_aggregate_limit',
                          'memory_target')
  AND  NVL(con_dbid, dbid) = dbid
  AND  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- --------------------------------------------------------------------
-- CAPV_PGASTAT (M26) -- instance PGA statistics per snapshot, in bytes.
--   * 'total PGA allocated' is the PGA in use when the snapshot was taken (a
--     sample). 'maximum PGA allocated' is a HIGH-WATER MARK since instance
--     startup: it resets at a restart, and only its advances between two
--     snapshots of one startup say when a peak happened (CAPM_PGA_LIMIT).
--   * Instance level, so con_dbid := dbid. In CDB$ROOT every row is under
--     the root's con_dbid (verified on 19.27: 19 names per snapshot); the
--     NVL(con_dbid, dbid) = dbid guard keeps a PDB row out, as in
--     CAPV_PARAMETER.
--   * Filtered to the names the PGA limit and PGA target analyses read.
--     Every one but the two samples ('total PGA allocated' / 'inuse') and
--     the parameters is cumulative since startup or a high-water mark. The
--     repository copies every name (repository/build.py): a copy cannot be
--     backfilled.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_pgastat AS
SELECT dbid                     AS dbid,
       dbid                     AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       name                     AS stat_name,
       value                    AS value
FROM   dba_hist_pgastat
WHERE  name IN ('total PGA allocated','maximum PGA allocated',
                'total PGA inuse','aggregate PGA target parameter',
                'aggregate PGA auto target','over allocation count',
                'bytes processed','extra bytes read/written',
                'cache hit percentage','maximum PGA used for auto workareas')
  AND  NVL(con_dbid, dbid) = dbid
  AND  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- --------------------------------------------------------------------
-- The memory sizing sources (M26). Instance level unless noted: on 19.27 in
-- CDB$ROOT every row is under the root's con_dbid (con_id 0, the system
-- events con_id 1), so con_dbid := dbid with the NVL(con_dbid, dbid) = dbid
-- guard of CAPV_PGASTAT. Sizes are bytes, times as the source names them.
-- Counters and advisor estimates are cumulative since instance startup
-- (the buffer cache advisor restarts at a resize of the cache), so the
-- analysis differences consecutive snapshots of one startup. Each is an
-- optional repository copy, like CAPV_PGASTAT.
-- --------------------------------------------------------------------

-- CAPV_MEM_COMP -- SGA / PGA component sizes per snapshot (ASMM / AMM
-- state), with the cumulative resize counter oper_count, the last
-- operation and the granule size.
CREATE OR REPLACE VIEW capv_mem_comp AS
SELECT dbid                     AS dbid,
       dbid                     AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       component                AS component,
       current_size             AS current_size,
       min_size                 AS min_size,
       max_size                 AS max_size,
       user_specified_size      AS user_specified_size,
       oper_count               AS oper_count,
       last_oper_type           AS last_oper_type,
       last_oper_mode           AS last_oper_mode,
       last_oper_time           AS last_oper_time,
       granule_size             AS granule_size
FROM   dba_hist_mem_dynamic_comp
WHERE  NVL(con_dbid, dbid) = dbid
  AND  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- CAPV_WORKAREA_HSTGRM -- work area executions by optimal size bucket:
-- optimal, one-pass and multi-pass counts, cumulative.
CREATE OR REPLACE VIEW capv_workarea_hstgrm AS
SELECT dbid                     AS dbid,
       dbid                     AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       low_optimal_size         AS low_optimal_size,
       high_optimal_size        AS high_optimal_size,
       optimal_executions       AS optimal_executions,
       onepass_executions       AS onepass_executions,
       multipasses_executions   AS multipasses_executions,
       total_executions         AS total_executions
FROM   dba_hist_sql_workarea_hstgrm
WHERE  NVL(con_dbid, dbid) = dbid
  AND  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- CAPV_PGA_ADVICE -- the PGA target advisor: per advised target, the
-- estimated cache hit percentage, extra bytes read / written and
-- over-allocation count. No rows when the advisor is off.
CREATE OR REPLACE VIEW capv_pga_advice AS
SELECT dbid                           AS dbid,
       dbid                           AS con_dbid,
       instance_number                AS instance_number,
       snap_id                        AS snap_id,
       pga_target_for_estimate        AS pga_target_for_estimate,
       pga_target_factor              AS pga_target_factor,
       advice_status                  AS advice_status,
       bytes_processed                AS bytes_processed,
       estd_time                      AS estd_time,
       estd_extra_bytes_rw            AS estd_extra_bytes_rw,
       estd_pga_cache_hit_percentage  AS estd_pga_cache_hit_percentage,
       estd_overalloc_count           AS estd_overalloc_count
FROM   dba_hist_pga_target_advice
WHERE  NVL(con_dbid, dbid) = dbid
  AND  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- CAPV_SGA_ADVICE -- the SGA target advisor: per advised sga_target (MB),
-- the estimated DB time and physical reads.
CREATE OR REPLACE VIEW capv_sga_advice AS
SELECT dbid                     AS dbid,
       dbid                     AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       sga_size                 AS sga_size,
       sga_size_factor          AS sga_size_factor,
       estd_db_time             AS estd_db_time,
       estd_physical_reads      AS estd_physical_reads
FROM   dba_hist_sga_target_advice
WHERE  NVL(con_dbid, dbid) = dbid
  AND  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- CAPV_CACHE_ADVICE -- the buffer cache advisor, per buffer pool (bpid,
-- name, block size) and advised size (MB): estimated physical reads and
-- read time.
CREATE OR REPLACE VIEW capv_cache_advice AS
SELECT dbid                     AS dbid,
       dbid                     AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       bpid                     AS bpid,
       name                     AS name,
       block_size               AS block_size,
       advice_status            AS advice_status,
       size_for_estimate        AS size_for_estimate,
       size_factor              AS size_factor,
       buffers_for_estimate     AS buffers_for_estimate,
       physical_reads           AS physical_reads,
       base_physical_reads      AS base_physical_reads,
       actual_physical_reads    AS actual_physical_reads,
       estd_physical_read_time  AS estd_physical_read_time
FROM   dba_hist_db_cache_advice
WHERE  NVL(con_dbid, dbid) = dbid
  AND  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- CAPV_SHPOOL_ADVICE -- the shared pool advisor: per advised size (MB), the
-- estimated library cache size, load time and time saved.
CREATE OR REPLACE VIEW capv_shpool_advice AS
SELECT dbid                           AS dbid,
       dbid                           AS con_dbid,
       instance_number                AS instance_number,
       snap_id                        AS snap_id,
       shared_pool_size_for_estimate  AS shared_pool_size_for_estimate,
       shared_pool_size_factor        AS shared_pool_size_factor,
       estd_lc_size                   AS estd_lc_size,
       estd_lc_memory_objects         AS estd_lc_memory_objects,
       estd_lc_time_saved             AS estd_lc_time_saved,
       estd_lc_time_saved_factor      AS estd_lc_time_saved_factor,
       estd_lc_load_time              AS estd_lc_load_time,
       estd_lc_load_time_factor       AS estd_lc_load_time_factor,
       estd_lc_memory_object_hits     AS estd_lc_memory_object_hits
FROM   dba_hist_shared_pool_advice
WHERE  NVL(con_dbid, dbid) = dbid
  AND  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- CAPV_SGASTAT -- free memory per SGA pool, a sample per snapshot.
--   * DBA_HIST_SGASTAT has rows per container (con_id 0 instance wide, 1
--     the root, 3.. the PDBs), so con_dbid is the source's, minus PDB$SEED
--     as in CAPV_TIME_MODEL. On 19.27 every 'free memory' row is con_id 0
--     (instance wide, under the root's con_dbid), one per pool.
CREATE OR REPLACE VIEW capv_sgastat AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       pool                     AS pool,
       name                     AS name,
       bytes                    AS bytes
FROM   dba_hist_sgastat
WHERE  name = 'free memory'
  AND  NVL(con_id, 0) <> 2
  AND  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- CAPV_LIBRARYCACHE -- library cache gets, pins, reloads and invalidations
-- per namespace, cumulative.
CREATE OR REPLACE VIEW capv_librarycache AS
SELECT dbid                     AS dbid,
       dbid                     AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       namespace                AS namespace,
       gets                     AS gets,
       gethits                  AS gethits,
       pins                     AS pins,
       pinhits                  AS pinhits,
       reloads                  AS reloads,
       invalidations            AS invalidations
FROM   dba_hist_librarycache
WHERE  NVL(con_dbid, dbid) = dbid
  AND  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- CAPV_ROWCACHE -- dictionary cache gets and misses per parameter,
-- cumulative.
CREATE OR REPLACE VIEW capv_rowcache AS
SELECT dbid                     AS dbid,
       dbid                     AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       parameter                AS parameter,
       gets                     AS gets,
       getmisses                AS getmisses
FROM   dba_hist_rowcache_summary
WHERE  NVL(con_dbid, dbid) = dbid
  AND  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- CAPV_SYSTEM_EVENT -- waits and time waited (microseconds), cumulative,
-- for the memory pressure events only. An event never waited for has no
-- row (on 19.27 'latch: row cache objects').
CREATE OR REPLACE VIEW capv_system_event AS
SELECT dbid                     AS dbid,
       dbid                     AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       event_name               AS event_name,
       wait_class               AS wait_class,
       total_waits              AS total_waits,
       time_waited_micro        AS time_waited_micro
FROM   dba_hist_system_event
WHERE  event_name IN ('free buffer waits','write complete waits','buffer busy waits',
                      'latch: cache buffers lru chain','latch: shared pool',
                      'library cache: mutex X','library cache load lock',
                      'library cache lock','cursor: pin S wait on X',
                      'SGA: allocation forcing component growth',
                      'latch: row cache objects','row cache lock','row cache mutex',
                      'direct path read temp','direct path write temp')
  AND  NVL(con_dbid, dbid) = dbid
  AND  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- --------------------------------------------------------------------
-- CAPV_ASM_DISKGROUP -- ASM diskgroup size per snapshot, named.
--   * DBA_HIST_ASM_DISKGROUP_STAT carries TOTAL_MB / FREE_MB per snapshot
--     and group number. DBA_HIST_ASM_DISKGROUP is the name dimension, joined
--     on (dbid, group_number, con_dbid). NAME has no leading '+'.
--   * TOTAL_MB / FREE_MB are raw MB, before mirroring. The 19c view has no
--     USABLE_FILE_MB (verified on 19.27), so usable_file_mb is NULL here.
--   * Host level: no instance_number, con_dbid := dbid. A database without
--     ASM has no rows, and the ASM_DG series simply do not appear.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_asm_diskgroup AS
SELECT s.dbid                   AS dbid,
       s.dbid                   AS con_dbid,
       s.snap_id                AS snap_id,
       g.name                   AS group_name,
       s.total_mb               AS total_mb,
       s.free_mb                AS free_mb,
       CAST(NULL AS NUMBER)     AS usable_file_mb
FROM   dba_hist_asm_diskgroup_stat s
JOIN   dba_hist_asm_diskgroup g
  ON   g.dbid = s.dbid AND g.group_number = s.group_number
 AND   g.con_dbid = s.con_dbid
WHERE  s.dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), s.dbid)
  AND  g.dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), g.dbid);

-- --------------------------------------------------------------------
-- CAPV_SEG_STAT -- per-snapshot segment space deltas, named.
--   * DBA_HIST_SEG_STAT carries SPACE_USED_DELTA / SPACE_ALLOCATED_DELTA
--     (bytes) per snapshot, instance and segment, with CON_DBID (verified on
--     19.27 in CDB$ROOT: rows for the root and every PDB). The segment
--     names come from DBA_HIST_SEG_STAT_OBJ, joined on (dbid, con_dbid, ts#,
--     obj#, dataobj#). A dropped object keeps its row there with the name
--     '** MISSING **'; it passes through unchanged.
--   * AWR keeps only the top segments of each snapshot (by the
--     statistics_level top-N rules), so the deltas cover the busiest
--     segments, not every one.
--   * tablespace_id is TS#, which restarts per container like the
--     TABLESPACE_ID of CAPV_TBSPC_USAGE.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_seg_stat AS
SELECT s.dbid                   AS dbid,
       s.con_dbid               AS con_dbid,
       s.instance_number        AS instance_number,
       s.snap_id                AS snap_id,
       s.ts#                    AS tablespace_id,
       o.tablespace_name        AS tablespace_name,
       o.owner                  AS owner,
       o.object_name            AS object_name,
       o.subobject_name         AS subobject_name,
       o.object_type            AS object_type,
       s.space_used_delta       AS space_used_delta,
       s.space_allocated_delta  AS space_allocated_delta
FROM   dba_hist_seg_stat s
JOIN   dba_hist_seg_stat_obj o
  ON   o.dbid = s.dbid AND o.con_dbid = s.con_dbid
 AND   o.ts# = s.ts# AND o.obj# = s.obj# AND o.dataobj# = s.dataobj#
WHERE  s.dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), s.dbid)
  AND  o.dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), o.dbid);

-- --------------------------------------------------------------------
-- CAPV_TBSPC_LIVE -- the live tablespace ceilings (U09, the shared-disk
-- forecast in ddl/33). Not AWR: CDB_TABLESPACE_USAGE_METRICS on the target,
-- copied whole at every collect into CAP_H_TBSPC_LIVE (repository/build.py
-- kind L). This view names the copy itself, not a DBA_HIST_ view: the copy
-- has columns the source lacks (dbid, con_dbid, collected_at).
--   * ceiling_blocks is TABLESPACE_SIZE: the largest size the tablespace can
--     reach now, in blocks of its own block size. Oracle caps the autoextend
--     maximum by the free space of the filesystem / ASM disk group behind
--     the datafiles (allocated + device free, per tablespace, at any file
--     count: verified 19.27), which AWR's tablespace_maxsize is not.
--   * collected_at is the collect time on the repository's clock. No
--     snap_id, no history: one row per tablespace, as of that time.
--   * Rows exist for the target's newest DBID only, every contents type.
--     Optional copy: a reader without the grant leaves it empty.
-- Not in CAPV_CONTRACT (no snap_id).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_tbspc_live AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       tablespace_name          AS tablespace_name,
       tablespace_size          AS ceiling_blocks,
       used_space               AS used_blocks,
       collected_at             AS collected_at
FROM   cap_h_tbspc_live
WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- --------------------------------------------------------------------
-- CAPV_CONTRACT -- what this seam actually presents, one row per fact
-- source: row count, distinct con_dbid, snap_id range and the newest
-- snapshot end time. per_container_expected = 'Y' where the contract wants
-- one series per container (TBSPC_USAGE, TIME_MODEL, SYSSTAT, SEG_STAT) and 'N' where
-- the source is host / instance / spine level (OSSTAT, RESOURCE_LIMIT,
-- PARAMETER, ASM_DISKGROUP, PGASTAT, the memory sources, SNAPSHOT), so n_con_dbid = 1 against a 'Y' means
-- the per-PDB series are missing. SEG_STAT is per container too. SGASTAT
-- keeps the source's con_dbid but is 'N': its free memory rows are
-- instance wide on 19.27. ASM_DISKGROUP
-- has n_rows = 0 on a database without ASM, the advisors when they are off. A diagnostic for doctor.sql: it
-- full-scans every source, and no analytic view selects from it. The body
-- reads only CAPV_* and is the same in all three seam files.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_contract AS
WITH src AS (
        SELECT 'SNAPSHOT' AS source_name, dbid, con_dbid, snap_id FROM capv_snapshot
        UNION ALL SELECT 'TBSPC_USAGE',    dbid, con_dbid, snap_id FROM capv_tbspc_usage
        UNION ALL SELECT 'OSSTAT',         dbid, con_dbid, snap_id FROM capv_osstat
        UNION ALL SELECT 'TIME_MODEL',     dbid, con_dbid, snap_id FROM capv_time_model
        UNION ALL SELECT 'SYSSTAT',        dbid, con_dbid, snap_id FROM capv_sysstat
        UNION ALL SELECT 'RESOURCE_LIMIT', dbid, con_dbid, snap_id FROM capv_resource_limit
        UNION ALL SELECT 'PARAMETER',      dbid, con_dbid, snap_id FROM capv_parameter
        UNION ALL SELECT 'ASM_DISKGROUP',  dbid, con_dbid, snap_id FROM capv_asm_diskgroup
        UNION ALL SELECT 'SEG_STAT',       dbid, con_dbid, snap_id FROM capv_seg_stat
        UNION ALL SELECT 'PGASTAT',        dbid, con_dbid, snap_id FROM capv_pgastat
        UNION ALL SELECT 'MEM_COMP',       dbid, con_dbid, snap_id FROM capv_mem_comp
        UNION ALL SELECT 'WORKAREA_HSTGRM', dbid, con_dbid, snap_id FROM capv_workarea_hstgrm
        UNION ALL SELECT 'PGA_ADVICE',     dbid, con_dbid, snap_id FROM capv_pga_advice
        UNION ALL SELECT 'SGA_ADVICE',     dbid, con_dbid, snap_id FROM capv_sga_advice
        UNION ALL SELECT 'CACHE_ADVICE',   dbid, con_dbid, snap_id FROM capv_cache_advice
        UNION ALL SELECT 'SHPOOL_ADVICE',  dbid, con_dbid, snap_id FROM capv_shpool_advice
        UNION ALL SELECT 'SGASTAT',        dbid, con_dbid, snap_id FROM capv_sgastat
        UNION ALL SELECT 'LIBRARYCACHE',   dbid, con_dbid, snap_id FROM capv_librarycache
        UNION ALL SELECT 'ROWCACHE',       dbid, con_dbid, snap_id FROM capv_rowcache
        UNION ALL SELECT 'SYSTEM_EVENT',   dbid, con_dbid, snap_id FROM capv_system_event
     ),
     per_con AS (
        SELECT source_name, dbid, con_dbid,
               COUNT(*)     AS n_rows,
               MIN(snap_id) AS min_snap_id,
               MAX(snap_id) AS max_snap_id
        FROM   src
        GROUP  BY source_name, dbid, con_dbid
     ),
     snap_end AS (
        SELECT dbid, snap_id, MAX(end_interval_time) AS end_time
        FROM   capv_snapshot
        GROUP  BY dbid, snap_id
     ),
     -- The source list is fixed so that an empty source still gets its row.
     sources AS (
        SELECT 'SNAPSHOT' AS source_name, 'N' AS per_container_expected FROM dual
        UNION ALL SELECT 'TBSPC_USAGE',    'Y' FROM dual
        UNION ALL SELECT 'OSSTAT',         'N' FROM dual
        UNION ALL SELECT 'TIME_MODEL',     'Y' FROM dual
        UNION ALL SELECT 'SYSSTAT',        'Y' FROM dual
        UNION ALL SELECT 'RESOURCE_LIMIT', 'N' FROM dual
        UNION ALL SELECT 'PARAMETER',      'N' FROM dual
        UNION ALL SELECT 'ASM_DISKGROUP',  'N' FROM dual
        UNION ALL SELECT 'SEG_STAT',       'Y' FROM dual
        UNION ALL SELECT 'PGASTAT',        'N' FROM dual
        UNION ALL SELECT 'MEM_COMP',       'N' FROM dual
        UNION ALL SELECT 'WORKAREA_HSTGRM', 'N' FROM dual
        UNION ALL SELECT 'PGA_ADVICE',     'N' FROM dual
        UNION ALL SELECT 'SGA_ADVICE',     'N' FROM dual
        UNION ALL SELECT 'CACHE_ADVICE',   'N' FROM dual
        UNION ALL SELECT 'SHPOOL_ADVICE',  'N' FROM dual
        UNION ALL SELECT 'SGASTAT',        'N' FROM dual
        UNION ALL SELECT 'LIBRARYCACHE',   'N' FROM dual
        UNION ALL SELECT 'ROWCACHE',       'N' FROM dual
        UNION ALL SELECT 'SYSTEM_EVENT',   'N' FROM dual
     )
SELECT k.source_name,
       NVL(SUM(p.n_rows), 0)        AS n_rows,
       COUNT(DISTINCT p.con_dbid)   AS n_con_dbid,
       MIN(p.min_snap_id)           AS min_snap_id,
       MAX(p.max_snap_id)           AS max_snap_id,
       MAX(e.end_time)              AS max_end_time,
       k.per_container_expected
FROM   sources k
LEFT   JOIN per_con p
  ON   p.source_name = k.source_name
LEFT   JOIN snap_end e
  ON   e.dbid = p.dbid AND e.snap_id = p.max_snap_id
GROUP  BY k.source_name, k.per_container_expected;
