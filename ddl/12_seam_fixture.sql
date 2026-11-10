--
-- ddl/12_seam_fixture.sql -- CAPV_* seam over CAP_FIXTURE_* tables (TEST mode).
-- =====================================================================
-- FIXTURE mode is the automated-test hook. We cannot INSERT synthetic rows
-- into DBA_HIST_*, so instead the seam points CAPV_* at plain CAP_FIXTURE_*
-- tables whose shapes match the CAPV contract exactly. test/fixture_install.sql
-- creates and populates those tables with deterministic series (exact linear
-- growth, an injected spike, a flat series, CPU counters with a restart) so
-- run_test.sql can assert the analytics reproduce known closed-form answers.
--
-- ORDER MATTERS: the CAP_FIXTURE_* tables must exist before these views
-- compile. Run test/fixture_install.sql (which creates + fills them) BEFORE
-- @install.sql with deploy_mode=fixture.
--
-- The fixture tables already store the post-mapping CAPV columns (bytes stay
-- blocks, counters stay cumulative, etc.), so these views are thin
-- pass-throughs -- keeping the fixture data honest to the same contract the
-- local seam presents.
--
SET DEFINE OFF

CREATE OR REPLACE VIEW capv_snapshot AS
SELECT dbid, con_dbid, instance_number, snap_id,
       begin_interval_time, end_interval_time, startup_time
FROM   cap_fixture_snapshot
WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

CREATE OR REPLACE VIEW capv_tbspc_usage AS
SELECT dbid, con_dbid, snap_id, tablespace_id,
       tablespace_size, tablespace_maxsize, tablespace_usedsize
FROM   cap_fixture_tbspc_usage
WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

CREATE OR REPLACE VIEW capv_tablespace AS
SELECT dbid, con_dbid, tablespace_id, tablespace_name, contents, block_size
FROM   cap_fixture_tablespace
WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

CREATE OR REPLACE VIEW capv_datafile AS
SELECT dbid, con_dbid, tablespace_id, block_size
FROM   cap_fixture_datafile
WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

CREATE OR REPLACE VIEW capv_osstat AS
SELECT dbid, con_dbid, instance_number, snap_id, stat_name, value
FROM   cap_fixture_osstat
WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

CREATE OR REPLACE VIEW capv_time_model AS
SELECT dbid, con_dbid, instance_number, snap_id, stat_name, value
FROM   cap_fixture_time_model
WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

CREATE OR REPLACE VIEW capv_container AS
SELECT dbid, con_dbid, db_name, con_name
FROM   cap_fixture_container
WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- One target per fixture dbid, named by its db_name, fed FIXTURE; the
-- fixture has no host name and nothing is collected. SUBSTR: db_name is a
-- VARCHAR2(128) here and CAST would raise on a longer value.
CREATE OR REPLACE VIEW capv_target AS
SELECT CAST(SUBSTR(MAX(db_name), 1, 30) AS VARCHAR2(30)) AS target_name,
       dbid                                     AS dbid,
       CAST('FIXTURE' AS VARCHAR2(10))          AS feed,
       CAST(NULL AS VARCHAR2(64))               AS host_name,
       CAST(NULL AS VARCHAR2(4000))             AS address,
       CAST(NULL AS VARCHAR2(128))              AS db_link,
       CAST('Y' AS VARCHAR2(1))                 AS enabled,
       CAST(NULL AS NUMBER)                     AS collected_snap_id,
       CAST(NULL AS DATE)                       AS last_ok_at,
       CAST(NULL AS DATE)                       AS last_error_at,
       CAST(NULL AS VARCHAR2(4000))             AS last_error,
       CAST(NULL AS NUMBER)                     AS n_gaps
FROM   cap_fixture_container
WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)
GROUP  BY dbid;

-- M11 sources. CAP_FIXTURE_RESOURCE_LIMIT stores limit_value ALREADY as a
-- NUMBER (the local seam's 'UNLIMITED'-to-NULL conversion is part of the
-- mapping, not of the contract), and CAP_FIXTURE_SYSSTAT deliberately holds a
-- second, irrelevant stat name so the downstream 'redo size' filter is
-- exercised rather than assumed.
CREATE OR REPLACE VIEW capv_resource_limit AS
SELECT dbid, con_dbid, instance_number, snap_id, resource_name,
       current_utilization, max_utilization, limit_value
FROM   cap_fixture_resource_limit
WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

CREATE OR REPLACE VIEW capv_sysstat AS
SELECT dbid, con_dbid, instance_number, snap_id, stat_name, value
FROM   cap_fixture_sysstat
WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid);

-- CAPV_PARAMETER / CAPV_ASM_DISKGROUP / CAPV_SEG_STAT / CAPV_PGASTAT and the
-- memory sources (M26) over CAP_FIXTURE_<view suffix>, e.g. CAPV_MEM_COMP
-- over CAP_FIXTURE_MEM_COMP (value_num already a NUMBER, group_name without
-- the '+'). test/demo_fixture.sql builds the demo story without the ASM
-- and segment tables, so a missing table gets a zero-row contract stub
-- instead of an INVALID view. The stub columns are typed constants, not
-- CAST(NULL ...): with NULL join keys, CAPD_DBTIME_DAILY over a zero-row
-- CAPV_PARAMETER raised ORA-07445 [qksopVisitOpns] (join predicate push-down)
-- on 19.27. The lookup goes
-- through ALL_TABLES on CURRENT_SCHEMA because USER_TABLES follows the
-- session user (SYSDBA + CURRENT_SCHEMA installs).
DECLARE
    PROCEDURE mk(p_table VARCHAR2, p_pass VARCHAR2, p_stub VARCHAR2) IS
        v_n PLS_INTEGER;
    BEGIN
        SELECT COUNT(*) INTO v_n
        FROM   all_tables
        WHERE  owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
          AND  table_name = p_table;
        EXECUTE IMMEDIATE CASE WHEN v_n > 0 THEN p_pass ELSE p_stub END;
    END;
BEGIN
    mk('CAP_FIXTURE_PARAMETER',
       q'[CREATE OR REPLACE VIEW capv_parameter AS
          SELECT dbid, con_dbid, instance_number, snap_id, parameter_name, value_num
          FROM   cap_fixture_parameter
          WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)]',
       q'[CREATE OR REPLACE VIEW capv_parameter AS
          SELECT 0 AS dbid, 0 AS con_dbid, 0 AS instance_number, 0 AS snap_id,
                 CAST('-' AS VARCHAR2(64)) AS parameter_name, 0 AS value_num
          FROM   dual WHERE 1 = 0]');
    mk('CAP_FIXTURE_ASM_DISKGROUP',
       q'[CREATE OR REPLACE VIEW capv_asm_diskgroup AS
          SELECT dbid, con_dbid, snap_id, group_name, total_mb, free_mb, usable_file_mb
          FROM   cap_fixture_asm_diskgroup
          WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)]',
       q'[CREATE OR REPLACE VIEW capv_asm_diskgroup AS
          SELECT 0 AS dbid, 0 AS con_dbid, 0 AS snap_id,
                 CAST('-' AS VARCHAR2(128)) AS group_name,
                 0 AS total_mb, 0 AS free_mb, 0 AS usable_file_mb
          FROM   dual WHERE 1 = 0]');
    mk('CAP_FIXTURE_SEG_STAT',
       q'[CREATE OR REPLACE VIEW capv_seg_stat AS
          SELECT dbid, con_dbid, instance_number, snap_id, tablespace_id, tablespace_name,
                 owner, object_name, subobject_name, object_type,
                 space_used_delta, space_allocated_delta
          FROM   cap_fixture_seg_stat
          WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)]',
       q'[CREATE OR REPLACE VIEW capv_seg_stat AS
          SELECT 0 AS dbid, 0 AS con_dbid, 0 AS instance_number, 0 AS snap_id,
                 0 AS tablespace_id, CAST('-' AS VARCHAR2(30)) AS tablespace_name,
                 CAST('-' AS VARCHAR2(128)) AS owner, CAST('-' AS VARCHAR2(128)) AS object_name,
                 CAST('-' AS VARCHAR2(128)) AS subobject_name, CAST('-' AS VARCHAR2(18)) AS object_type,
                 0 AS space_used_delta, 0 AS space_allocated_delta
          FROM   dual WHERE 1 = 0]');
    mk('CAP_FIXTURE_PGASTAT',
       q'[CREATE OR REPLACE VIEW capv_pgastat AS
          SELECT dbid, con_dbid, instance_number, snap_id, stat_name, value
          FROM   cap_fixture_pgastat
          WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)]',
       q'[CREATE OR REPLACE VIEW capv_pgastat AS
          SELECT 0 AS dbid, 0 AS con_dbid, 0 AS instance_number, 0 AS snap_id,
                 CAST('-' AS VARCHAR2(64)) AS stat_name, 0 AS value
          FROM   dual WHERE 1 = 0]');
    mk('CAP_FIXTURE_MEM_COMP',
       q'[CREATE OR REPLACE VIEW capv_mem_comp AS
          SELECT dbid, con_dbid, instance_number, snap_id, component, current_size,
                 min_size, max_size, user_specified_size, oper_count, last_oper_type,
                 last_oper_mode, last_oper_time, granule_size
          FROM   cap_fixture_mem_comp
          WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)]',
       q'[CREATE OR REPLACE VIEW capv_mem_comp AS
          SELECT 0 AS dbid, 0 AS con_dbid, 0 AS instance_number, 0 AS snap_id,
                 CAST('-' AS VARCHAR2(64)) AS component, 0 AS current_size,
                 0 AS min_size, 0 AS max_size, 0 AS user_specified_size,
                 0 AS oper_count, CAST('-' AS VARCHAR2(13)) AS last_oper_type,
                 CAST('-' AS VARCHAR2(9)) AS last_oper_mode,
                 DATE '1970-01-01' AS last_oper_time, 0 AS granule_size
          FROM   dual WHERE 1 = 0]');
    mk('CAP_FIXTURE_WORKAREA_HSTGRM',
       q'[CREATE OR REPLACE VIEW capv_workarea_hstgrm AS
          SELECT dbid, con_dbid, instance_number, snap_id, low_optimal_size,
                 high_optimal_size, optimal_executions, onepass_executions,
                 multipasses_executions, total_executions
          FROM   cap_fixture_workarea_hstgrm
          WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)]',
       q'[CREATE OR REPLACE VIEW capv_workarea_hstgrm AS
          SELECT 0 AS dbid, 0 AS con_dbid, 0 AS instance_number, 0 AS snap_id,
                 0 AS low_optimal_size, 0 AS high_optimal_size, 0 AS optimal_executions,
                 0 AS onepass_executions, 0 AS multipasses_executions,
                 0 AS total_executions
          FROM   dual WHERE 1 = 0]');
    mk('CAP_FIXTURE_PGA_ADVICE',
       q'[CREATE OR REPLACE VIEW capv_pga_advice AS
          SELECT dbid, con_dbid, instance_number, snap_id, pga_target_for_estimate,
                 pga_target_factor, advice_status, bytes_processed, estd_time,
                 estd_extra_bytes_rw, estd_pga_cache_hit_percentage,
                 estd_overalloc_count
          FROM   cap_fixture_pga_advice
          WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)]',
       q'[CREATE OR REPLACE VIEW capv_pga_advice AS
          SELECT 0 AS dbid, 0 AS con_dbid, 0 AS instance_number, 0 AS snap_id,
                 0 AS pga_target_for_estimate, 0 AS pga_target_factor,
                 CAST('-' AS VARCHAR2(3)) AS advice_status, 0 AS bytes_processed,
                 0 AS estd_time, 0 AS estd_extra_bytes_rw,
                 0 AS estd_pga_cache_hit_percentage, 0 AS estd_overalloc_count
          FROM   dual WHERE 1 = 0]');
    mk('CAP_FIXTURE_SGA_ADVICE',
       q'[CREATE OR REPLACE VIEW capv_sga_advice AS
          SELECT dbid, con_dbid, instance_number, snap_id, sga_size, sga_size_factor,
                 estd_db_time, estd_physical_reads
          FROM   cap_fixture_sga_advice
          WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)]',
       q'[CREATE OR REPLACE VIEW capv_sga_advice AS
          SELECT 0 AS dbid, 0 AS con_dbid, 0 AS instance_number, 0 AS snap_id,
                 0 AS sga_size, 0 AS sga_size_factor, 0 AS estd_db_time,
                 0 AS estd_physical_reads
          FROM   dual WHERE 1 = 0]');
    mk('CAP_FIXTURE_CACHE_ADVICE',
       q'[CREATE OR REPLACE VIEW capv_cache_advice AS
          SELECT dbid, con_dbid, instance_number, snap_id, bpid, name, block_size,
                 advice_status, size_for_estimate, size_factor, buffers_for_estimate,
                 physical_reads, base_physical_reads, actual_physical_reads,
                 estd_physical_read_time
          FROM   cap_fixture_cache_advice
          WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)]',
       q'[CREATE OR REPLACE VIEW capv_cache_advice AS
          SELECT 0 AS dbid, 0 AS con_dbid, 0 AS instance_number, 0 AS snap_id,
                 0 AS bpid, CAST('-' AS VARCHAR2(20)) AS name, 0 AS block_size,
                 CAST('-' AS VARCHAR2(3)) AS advice_status, 0 AS size_for_estimate,
                 0 AS size_factor, 0 AS buffers_for_estimate, 0 AS physical_reads,
                 0 AS base_physical_reads, 0 AS actual_physical_reads,
                 0 AS estd_physical_read_time
          FROM   dual WHERE 1 = 0]');
    mk('CAP_FIXTURE_SHPOOL_ADVICE',
       q'[CREATE OR REPLACE VIEW capv_shpool_advice AS
          SELECT dbid, con_dbid, instance_number, snap_id,
                 shared_pool_size_for_estimate, shared_pool_size_factor, estd_lc_size,
                 estd_lc_memory_objects, estd_lc_time_saved, estd_lc_time_saved_factor,
                 estd_lc_load_time, estd_lc_load_time_factor,
                 estd_lc_memory_object_hits
          FROM   cap_fixture_shpool_advice
          WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)]',
       q'[CREATE OR REPLACE VIEW capv_shpool_advice AS
          SELECT 0 AS dbid, 0 AS con_dbid, 0 AS instance_number, 0 AS snap_id,
                 0 AS shared_pool_size_for_estimate, 0 AS shared_pool_size_factor,
                 0 AS estd_lc_size, 0 AS estd_lc_memory_objects,
                 0 AS estd_lc_time_saved, 0 AS estd_lc_time_saved_factor,
                 0 AS estd_lc_load_time, 0 AS estd_lc_load_time_factor,
                 0 AS estd_lc_memory_object_hits
          FROM   dual WHERE 1 = 0]');
    mk('CAP_FIXTURE_SGASTAT',
       q'[CREATE OR REPLACE VIEW capv_sgastat AS
          SELECT dbid, con_dbid, instance_number, snap_id, pool, name, bytes
          FROM   cap_fixture_sgastat
          WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)]',
       q'[CREATE OR REPLACE VIEW capv_sgastat AS
          SELECT 0 AS dbid, 0 AS con_dbid, 0 AS instance_number, 0 AS snap_id,
                 CAST('-' AS VARCHAR2(30)) AS pool, CAST('-' AS VARCHAR2(64)) AS name,
                 0 AS bytes
          FROM   dual WHERE 1 = 0]');
    mk('CAP_FIXTURE_LIBRARYCACHE',
       q'[CREATE OR REPLACE VIEW capv_librarycache AS
          SELECT dbid, con_dbid, instance_number, snap_id, namespace, gets, gethits,
                 pins, pinhits, reloads, invalidations
          FROM   cap_fixture_librarycache
          WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)]',
       q'[CREATE OR REPLACE VIEW capv_librarycache AS
          SELECT 0 AS dbid, 0 AS con_dbid, 0 AS instance_number, 0 AS snap_id,
                 CAST('-' AS VARCHAR2(15)) AS namespace, 0 AS gets, 0 AS gethits,
                 0 AS pins, 0 AS pinhits, 0 AS reloads, 0 AS invalidations
          FROM   dual WHERE 1 = 0]');
    mk('CAP_FIXTURE_ROWCACHE',
       q'[CREATE OR REPLACE VIEW capv_rowcache AS
          SELECT dbid, con_dbid, instance_number, snap_id, parameter, gets, getmisses
          FROM   cap_fixture_rowcache
          WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)]',
       q'[CREATE OR REPLACE VIEW capv_rowcache AS
          SELECT 0 AS dbid, 0 AS con_dbid, 0 AS instance_number, 0 AS snap_id,
                 CAST('-' AS VARCHAR2(32)) AS parameter, 0 AS gets, 0 AS getmisses
          FROM   dual WHERE 1 = 0]');
    mk('CAP_FIXTURE_SYSTEM_EVENT',
       q'[CREATE OR REPLACE VIEW capv_system_event AS
          SELECT dbid, con_dbid, instance_number, snap_id, event_name, wait_class,
                 total_waits, time_waited_micro
          FROM   cap_fixture_system_event
          WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)]',
       q'[CREATE OR REPLACE VIEW capv_system_event AS
          SELECT 0 AS dbid, 0 AS con_dbid, 0 AS instance_number, 0 AS snap_id,
                 CAST('-' AS VARCHAR2(64)) AS event_name,
                 CAST('-' AS VARCHAR2(64)) AS wait_class, 0 AS total_waits,
                 0 AS time_waited_micro
          FROM   dual WHERE 1 = 0]');
END;
/

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
-- has n_rows = 0 on a database without ASM, and a stub above on a fixture
-- without its table. A diagnostic for doctor.sql: it full-scans every
-- source, and no analytic view selects from it. The body reads only CAPV_*
-- and is the same in all three seam files.
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
