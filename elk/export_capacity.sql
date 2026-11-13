--
-- elk/export_capacity.sql -- the suite's analytics as NDJSON, one document
-- per line, for elk/export.sh to hand to Filebeat (index awrcap-capacity).
-- The document shape is elk/elasticsearch/index-template.json (dynamic:
-- strict), so every key emitted here must exist there.
--
-- Run where the CAP* views resolve unqualified (CURRENT_SCHEMA), e.g.
--   SQL> DEFINE cap_source = 'cdb1/PDB1:CAPDEMO'
--   SQL> @elk/export_capacity.sql
-- cap_source defaults to <db_name>/<con_name>:<current_schema>.
--
-- Read-only: SELECTs only. Every document carries "id" (MD5 of its natural
-- key), which Filebeat moves into _id so re-exports overwrite in place.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/elk/export_capacity.sql"
SET DEFINE ON
SET VERIFY OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SET LINESIZE 32767
SET LONG 2000000
SET LONGCHUNKSIZE 2000000
SET TRIMSPOOL ON
SET TRIMOUT ON
SET TAB OFF
SET SERVEROUTPUT OFF
WHENEVER SQLERROR EXIT FAILURE

COLUMN cap_source NEW_VALUE cap_source NOPRINT
SELECT NULL AS cap_source FROM dual WHERE 1 = 0;

VARIABLE cap_source  VARCHAR2(400)
VARIABLE exported_at VARCHAR2(20)
VARIABLE export_day  VARCHAR2(10)
BEGIN
    :cap_source  := NVL('&cap_source',
                        LOWER(NVL(SYS_CONTEXT('USERENV', 'CDB_NAME'), SYS_CONTEXT('USERENV', 'DB_NAME'))) || '/'
                        || SYS_CONTEXT('USERENV', 'CON_NAME') || ':'
                        || SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'));
    :exported_at := TO_CHAR(SYS_EXTRACT_UTC(SYSTIMESTAMP), 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
    :export_day  := SUBSTR(:exported_at, 1, 10);
END;
/

-- Every SELECT drives from alias t, a CAPR_* view carrying the container
-- labels (db, db_name, con_name) next to dbid/con_dbid, and ends in the
-- join tgt (alias tg), which names the dbid's target.
-- Timestamps: every day and hour below is the DB wall clock labelled Z (a
-- label, not a UTC conversion; Kibana runs with dateFormat:tz = UTC, set by
-- elk/setup.sh). Only exported_at is a true UTC instant.
-- target_name is the suite's name of the dbid (one target per dbid): every
-- FROM ends in the join tgt, and ident names it, so a record type gets the
-- column by ending its FROM with the same word.
DEFINE ident = "'db' VALUE t.db, 'db_name' VALUE t.db_name, 'con_name' VALUE t.con_name, 'target_name' VALUE tg.target_name, 'dbid' VALUE t.dbid, 'con_dbid' VALUE t.con_dbid, 'source' VALUE :cap_source, 'exported_at' VALUE :exported_at"
DEFINE tgt = "LEFT JOIN (SELECT dbid AS tg_dbid, MAX(target_name) AS target_name FROM capr_container GROUP BY dbid) tg ON tg.tg_dbid = t.dbid"

-- The four record types below are straight projections of the CAPR_* point
-- views (ddl/45, ddl/55), which grafana/ords serves too; the logic lives
-- there, once.

-- observation: CAPR_SERIES_POINTS, daily only (CAPR_HOURLY_POINTS is not
-- exported). doc_key = 'obs|dbid|con_dbid|kind|series|YYYY-MM-DD', the
-- exact string this id hashed before the view carried it, so existing
-- observation documents are overwritten in place.
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH(t.doc_key, 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.ts, 'YYYY-MM-DD') || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'observation', 'kind' VALUE t.kind, 'series' VALUE t.series,
             &ident,
             'unit'         VALUE t.unit,
             'value'        VALUE t.value,
             'limit'        VALUE t.limit_value,
             'pct'          VALUE t.pct,
             'gap'          VALUE CASE t.gap WHEN 1 THEN 'true' WHEN 0 THEN 'false' END FORMAT JSON,
             'anomaly'      VALUE CASE t.anomaly WHEN 1 THEN 'true' WHEN 0 THEN 'false' END FORMAT JSON,
             'anomaly_flag' VALUE t.anomaly_flag,
             'anomaly_modes' VALUE CASE WHEN t.anomaly_modes IS NOT NULL
                                        THEN '["' || REPLACE(t.anomaly_modes, ',', '","') || '"]' END FORMAT JSON,
             'hours_flagged' VALUE t.how_hours_flagged,
             'z'            VALUE t.z,
             'expected'     VALUE t.expected,
             'threshold'    VALUE t.threshold,
             'tbspc' VALUE CASE WHEN t.kind = 'TBSPC' THEN JSON_OBJECT(
                 'used_bytes'   VALUE t.used_bytes,
                 'size_bytes'   VALUE t.size_bytes,
                 'limit_bytes'  VALUE t.limit_bytes,
                 'limit_source' VALUE t.limit_source,
                 'contents'     VALUE t.contents,
                 'delta_bytes'  VALUE t.delta_bytes,
                 'rate_bpd'     VALUE t.rate_bpd
                 ABSENT ON NULL) END FORMAT JSON,
             'cpu' VALUE CASE WHEN t.series IN ('BUSY_PCT', 'DB_CPU_PCT') THEN JSON_OBJECT(
                 'busy_pct'        VALUE t.busy_pct,
                 'busy_p95'        VALUE t.busy_p95,
                 'busy_max'        VALUE t.busy_max,
                 'busy_peak_pct'   VALUE t.busy_peak_pct,
                 'host_busy_sec'   VALUE t.host_busy_sec,
                 'num_cpus'        VALUE t.num_cpus,
                 'num_cpu_cores'   VALUE t.num_cpu_cores,
                 'db_cpu_sec'      VALUE t.db_cpu_sec,
                 'db_time_sec'     VALUE t.db_time_sec,
                 'db_cpu_pct'      VALUE t.db_cpu_pct,
                 'db_cpu_p95_pct'  VALUE t.db_cpu_p95_pct,
                 'db_cpu_per_core' VALUE t.db_cpu_per_core
                 ABSENT ON NULL) END FORMAT JSON
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capr_series_points t
&tgt;

-- forecast: CAPR_FORECAST_POINTS (REGR anchors + the ESM point). The ESM
-- point's horizon_days shrinks as its model ages, so its id hashes the 30-day
-- comparison bucket instead: an aging model replaces its document.
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('fc|' || t.dbid || '|' || t.con_dbid
                    || '|' || t.kind || '|' || t.series || '|' || t.method || '|'
                    || CASE WHEN t.method = 'ESM' THEN 30 ELSE t.horizon_days END, 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.ts, 'YYYY-MM-DD') || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'forecast', 'kind' VALUE t.kind, 'series' VALUE t.series,
             &ident,
             'unit'         VALUE t.unit,
             'method'       VALUE t.method,
             'horizon_days' VALUE t.horizon_days,
             'value'        VALUE t.value,
             'lo'           VALUE t.lo,
             'hi'           VALUE t.hi,
             'limit'        VALUE t.limit_value,
             'pct'          VALUE t.pct,
             'quality'      VALUE t.quality
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capr_forecast_points t
&tgt;

-- fit: CAPR_FIT, one per series per export day, so days-to-full charts
-- over time
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('fit|' || t.dbid || '|' || t.con_dbid
                    || '|' || t.kind || '|' || t.series || '|' || :export_day, 'MD5'))),
         '@timestamp' VALUE :export_day || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'fit', 'kind' VALUE t.kind, 'series' VALUE t.series,
             &ident,
             'unit'            VALUE t.unit,
             'method'          VALUE t.method,
             'value'           VALUE t.value,
             'limit'           VALUE t.limit_value,
             'pct'             VALUE t.pct,
             'slope_per_day'   VALUE t.slope_per_day,
             'r2'              VALUE t.r2,
             'quality'         VALUE t.quality,
             'days_to_full'    VALUE t.days_to_full,
             'days_to_full_lo' VALUE t.days_to_full_lo,
             'days_to_full_hi' VALUE t.days_to_full_hi,
             'accel'           VALUE t.accel,
             'train_n'         VALUE t.train_n,
             'sev'             VALUE t.sev,
             'sev_rank'        VALUE t.sev_rank,
             'tbspc' VALUE CASE WHEN t.kind = 'TBSPC' THEN JSON_OBJECT(
                 'used_bytes'   VALUE t.value,
                 'limit_bytes'  VALUE t.limit_value,
                 'limit_source' VALUE t.limit_source
                 ABSENT ON NULL) END FORMAT JSON
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capr_fit t
&tgt;

-- anomaly: CAPR_ANOMALIES, one per (event, baseline mode). doc_key keys on
-- kind, series, mode and the event hour; a level shift keys on obs_day (the
-- window's last day), so it is overwritten, not duplicated, as the window
-- slides, while its @timestamp is the window's first day. HOUR rows carry
-- their hour in @timestamp; DAY rows land on midnight.
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH(t.doc_key, 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.ts, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'anomaly', 'kind' VALUE t.kind, 'series' VALUE t.series,
             &ident,
             'unit'         VALUE t.unit,
             'anomaly'      VALUE 'true' FORMAT JSON,
             'anomaly_kind' VALUE t.anomaly_kind,
             'baseline_mode' VALUE t.baseline_mode,
             'grain'        VALUE t.grain,
             'n_hist'       VALUE t.n_hist,
             'alerting'     VALUE CASE t.alerting WHEN 'Y' THEN 'true' WHEN 'N' THEN 'false' END FORMAT JSON,
             'obs_day'      VALUE TO_CHAR(t.obs_day, 'YYYY-MM-DD') || 'T00:00:00Z',
             'anomaly_flag' VALUE t.anomaly_flag,
             'value'        VALUE t.value,
             'raw_value'    VALUE t.raw_value,
             'expected'     VALUE t.expected,
             'threshold'    VALUE t.threshold,
             'z'            VALUE t.z,
             'shift_pct'    VALUE t.shift_pct,
             'sev'          VALUE t.sev,
             'sev_rank'     VALUE t.sev_rank,
             'message'      VALUE t.message,
             'tbspc' VALUE CASE WHEN t.kind = 'TBSPC' THEN JSON_OBJECT(
                 'delta_bytes' VALUE t.raw_value,
                 'rate_bpd'    VALUE t.value
                 ABSENT ON NULL) END FORMAT JSON
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capr_anomalies t
&tgt;

-- ===================================================================
-- alert: the pollable CAPR_ALERTS feed, snapshotted per export day; one
-- per alert_key (dbid|con_dbid|kind|series|day|mode) and export day
-- ===================================================================
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('alert|' || t.alert_key || '|' || :export_day, 'MD5'))),
         '@timestamp' VALUE :export_day || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'alert',
             'kind'   VALUE CASE WHEN t.kind LIKE 'TBSPC%'  THEN 'TBSPC'
                                 WHEN t.kind LIKE 'SERIES%' THEN 'SERIES'
                                 ELSE 'CPU' END,
             'series' VALUE t.series_key,
             &ident,
             'unit'       VALUE LOWER(t.unit),
             'alert_kind' VALUE t.kind,
             'baseline_mode' VALUE t.baseline_mode,
             'sev'        VALUE TRIM(t.severity),
             'sev_rank'   VALUE t.sev_rank,
             'obs_day'    VALUE TO_CHAR(t.day_dt, 'YYYY-MM-DD') || 'T00:00:00Z',
             'value'      VALUE t.value,
             'threshold'  VALUE t.threshold,
             'message'    VALUE t.message
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM  (SELECT a.*, NVL(c.db_pdb, TO_CHAR(a.con_dbid)) AS db, c.db_name, c.con_name
       FROM   capr_alerts a
       LEFT   JOIN capr_container c ON c.dbid = a.dbid AND c.con_dbid = a.con_dbid) t
&tgt;

-- ===================================================================
-- Memory sizing (M26.4 report views). Instance level: con_dbid = dbid, so
-- db is the root container's label. cap.kind = MEM. Verdicts and evidence
-- are stamped with the export day, like fit: a re-export the same day
-- replaces them and the verdict history stays in the index. Report content
-- only: nothing here is an alert.
-- ===================================================================
-- mem_verdict: CAPR_MEM_VERDICT, one per (dbid, instance, area, export day)
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('memv|' || t.dbid || '|' || t.instance_number
                    || '|' || t.area || '|' || :export_day, 'MD5'))),
         '@timestamp' VALUE :export_day || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'mem_verdict', 'kind' VALUE 'MEM', 'series' VALUE t.area,
             &ident,
             'mem' VALUE JSON_OBJECT(
                 'instance_number'  VALUE t.instance_number,
                 'area'             VALUE t.area,
                 'area_label'       VALUE t.area_label,
                 'area_rank'        VALUE t.area_rank,
                 'mem_mode'         VALUE t.mem_mode,
                 'grade'            VALUE t.grade,
                 'reason'           VALUE t.reason,
                 'reason_text'      VALUE t.reason_text,
                 'actionable'       VALUE CASE t.actionable WHEN 'Y' THEN 'true' WHEN 'N' THEN 'false' END FORMAT JSON,
                 'current_bytes'    VALUE t.current_bytes,
                 'suggested_bytes'  VALUE t.suggested_bytes,
                 'current_size'     VALUE t.current_size,
                 'suggested_size'   VALUE t.suggested_size,
                 'change_pct'       VALUE t.change_pct,
                 'suggested_param'  VALUE t.suggested_param,
                 'exceeds_host_ram' VALUE CASE t.exceeds_host_ram WHEN 'Y' THEN 'true' WHEN 'N' THEN 'false' END FORMAT JSON,
                 'exceeds_sga'      VALUE CASE t.exceeds_sga WHEN 'Y' THEN 'true' WHEN 'N' THEN 'false' END FORMAT JSON,
                 'n_evidence'       VALUE t.n_evidence,
                 'n_pressure'       VALUE t.n_pressure,
                 'n_days'           VALUE t.n_days,
                 'window_start'     VALUE TO_CHAR(t.window_start, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                 'window_end'       VALUE TO_CHAR(t.window_end, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                 'headline'         VALUE t.headline
                 ABSENT ON NULL)
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM  (SELECT v.*, v.db_pdb AS db, c.db_name, c.con_name
       FROM   capr_mem_verdict v
       LEFT   JOIN capr_container c ON c.dbid = v.dbid AND c.con_dbid = v.con_dbid) t
&tgt;

-- mem_evidence: CAPR_MEM_EVIDENCE, one per (dbid, instance, area, signal,
-- export day). The measurement uses the shared value / unit / threshold.
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('meme|' || t.dbid || '|' || t.instance_number
                    || '|' || t.area || '|' || t.kind || '|' || t.signal || '|' || :export_day, 'MD5'))),
         '@timestamp' VALUE :export_day || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'mem_evidence', 'kind' VALUE 'MEM', 'series' VALUE t.area,
             &ident,
             'unit'      VALUE t.unit,
             'value'     VALUE t.value,
             'threshold' VALUE t.threshold,
             'mem' VALUE JSON_OBJECT(
                 'instance_number' VALUE t.instance_number,
                 'area'            VALUE t.area,
                 'area_label'      VALUE t.area_label,
                 'area_rank'       VALUE t.area_rank,
                 'evidence_kind'   VALUE t.kind,
                 'signal'          VALUE t.signal,
                 'direction'       VALUE t.direction,
                 'observed_at'     VALUE TO_CHAR(t.observed_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                 'evidence_text'   VALUE t.evidence_text
                 ABSENT ON NULL)
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM  (SELECT e.*, e.db_pdb AS db, c.db_name, c.con_name
       FROM   capr_mem_evidence e
       LEFT   JOIN capr_container c ON c.dbid = e.dbid AND c.con_dbid = e.con_dbid) t
&tgt;

-- mem_component: CAPR_MEM_COMP_POINTS, one per (dbid, instance, SGA
-- component, day) of the evidence window. value = the size at the day's
-- last snapshot, in bytes.
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('memc|' || t.dbid || '|' || t.instance_number
                    || '|' || t.component || '|' || TO_CHAR(t.ts, 'YYYY-MM-DD'), 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.ts, 'YYYY-MM-DD') || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'mem_component', 'kind' VALUE 'MEM', 'series' VALUE t.component,
             &ident,
             'unit'  VALUE 'bytes',
             'value' VALUE t.bytes,
             'mem' VALUE JSON_OBJECT(
                 'instance_number' VALUE t.instance_number,
                 'component'       VALUE t.component,
                 'bytes'           VALUE t.bytes,
                 'min_bytes'       VALUE t.min_bytes,
                 'max_bytes'       VALUE t.max_bytes,
                 'ops'             VALUE t.ops
                 ABSENT ON NULL)
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM  (SELECT p.*, NVL(c.db_pdb, TO_CHAR(p.dbid)) AS db, c.db_name, c.con_name
       FROM   capr_mem_comp_points p
       LEFT   JOIN capr_container c ON c.dbid = p.dbid AND c.con_dbid = p.con_dbid) t
&tgt;

UNDEFINE ident tgt
