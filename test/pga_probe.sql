-- =====================================================================
-- test/pga_probe.sql -- how much PGA did this session need?
-- =====================================================================
-- Run it at the END of a session that just did the work (install, a report,
-- cap_results.refresh, train_all, run_test.sql). It prints:
--   1. this session's peak PGA / UGA ('session pga memory max') and how its
--      sort / hash work areas ran (optimal = in memory, one-pass / multi-pass
--      = spilled to TEMP), plus TEMP blocks written;
--   2. the ten largest work areas of cursors parsed under CURRENT_SCHEMA:
--      what the last execution used, what it would need to run fully in
--      memory (estimated_optimal_size) and the TEMP it spilled;
--   3. the instance's PGA settings and pressure counters, because a low
--      aggregate PGA auto target squeezes every work area into TEMP.
-- Read-only. Needs SELECT on V$MYSTAT, V$STATNAME, V$SQL_WORKAREA, V$SQL,
-- V$PGASTAT, V$PARAMETER (SYSDBA has them; so does SELECT_CATALOG_ROLE).
-- Used by test/dbmint_harness.sh --pga after every step; docs/install.html
-- "Memory (PGA)" quotes what it measured.
SET DEFINE OFF
SET LINESIZE 200 PAGESIZE 100 FEEDBACK OFF HEADING ON
COLUMN stat     FORMAT A44 HEADING 'PGA_PROBE session'
COLUMN val      FORMAT 999,999,990.0 HEADING 'VALUE'
COLUMN unit     FORMAT A6
SELECT n.name AS stat,
       CASE WHEN n.name LIKE '%memory%' THEN m.value / 1048576 ELSE m.value END AS val,
       CASE WHEN n.name LIKE '%memory%' THEN 'MB' ELSE 'count' END AS unit
FROM   v$mystat m JOIN v$statname n ON n.statistic# = m.statistic#
WHERE  n.name IN ('session pga memory max', 'session uga memory max',
                  'workarea executions - optimal', 'workarea executions - onepass',
                  'workarea executions - multipass',
                  'physical writes direct temporary tablespace')
ORDER BY n.name;

COLUMN sql_id    FORMAT A13
COLUMN op        FORMAT A22 HEADING 'PGA_PROBE workarea'
COLUMN last_mb   FORMAT 99,990.0 HEADING 'LAST_MB'
COLUMN optimal_mb FORMAT 99,990.0 HEADING 'OPTIMAL_MB'
COLUMN temp_mb   FORMAT 99,990.0 HEADING 'TEMP_MB'
COLUMN passes    FORMAT A9 HEADING 'OPT/1P/MP'
COLUMN sql_head  FORMAT A60
SELECT * FROM (
  SELECT w.sql_id, w.operation_type AS op,
         w.last_memory_used / 1048576 AS last_mb,
         w.estimated_optimal_size / 1048576 AS optimal_mb,
         NVL(w.max_tempseg_size, 0) / 1048576 AS temp_mb,
         w.optimal_executions || '/' || w.onepass_executions || '/' ||
           w.multipasses_executions AS passes,
         SUBSTR(REGEXP_REPLACE(s.sql_text, '\s+', ' '), 1, 60) AS sql_head
  FROM   v$sql_workarea w
  JOIN   v$sql s ON s.address = w.address AND s.child_number = w.child_number
  WHERE  s.parsing_schema_name = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
  ORDER BY w.estimated_optimal_size DESC
) WHERE ROWNUM <= 10;

COLUMN stat FORMAT A44 HEADING 'PGA_PROBE instance'
SELECT name AS stat, TO_NUMBER(value) / 1048576 AS val, 'MB' AS unit
FROM   v$parameter WHERE name IN ('pga_aggregate_target', 'pga_aggregate_limit')
UNION ALL
SELECT name, CASE WHEN unit = 'bytes' THEN value / 1048576 ELSE value END,
       CASE WHEN unit = 'bytes' THEN 'MB' ELSE 'count' END
FROM   v$pgastat
WHERE  name IN ('aggregate PGA auto target', 'total PGA allocated',
                'maximum PGA allocated', 'over allocation count');
SET DEFINE '&'
