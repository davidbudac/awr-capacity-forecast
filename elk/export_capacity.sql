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
-- over time. restart_reason / restart_day are a tablespace fit's (why its
-- window is shorter than train_days). cap.track is the series' row of
-- CAPR_FIT_TRACK, the forecast track record of the newest refresh run
-- (stored rows only, so the join costs a table read): absent before the
-- first run.
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
             'restart_reason'  VALUE t.restart_reason,
             'restart_day'     VALUE TO_CHAR(t.restart_day, 'YYYY-MM-DD"T00:00:00Z"'),
             'tbspc' VALUE CASE WHEN t.kind = 'TBSPC' THEN JSON_OBJECT(
                 'used_bytes'   VALUE t.value,
                 'limit_bytes'  VALUE t.limit_value,
                 'limit_source' VALUE t.limit_source
                 ABSENT ON NULL) END FORMAT JSON,
             'track' VALUE CASE WHEN tr.reliability IS NOT NULL THEN JSON_OBJECT(
                 'reliability'      VALUE tr.reliability,
                 'reliability_rank' VALUE tr.reliability_rank,
                 'horizon_days'     VALUE tr.horizon_days,
                 'n_forecasts'      VALUE tr.n_forecasts,
                 'abs_err_pct'      VALUE tr.abs_err_pct,
                 'bias_pct'         VALUE tr.bias_pct,
                 'n_banded'         VALUE tr.n_banded,
                 'band_hits'        VALUE tr.band_hits,
                 'band_hit_pct'     VALUE tr.band_hit_pct,
                 'band_factor'      VALUE tr.band_factor,
                 'summary'          VALUE tr.summary
                 ABSENT ON NULL) END FORMAT JSON
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capr_fit t
LEFT   JOIN capr_fit_track tr
  ON   tr.dbid = t.dbid AND tr.con_dbid = t.con_dbid AND tr.kind = t.kind AND tr.series = t.series
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
-- per alert_key (dbid|con_dbid|kind|series|day|mode) and export day.
-- cap.kind files it under a board: TBSPC (TBSPC_FAMILY too), SERIES, DISK
-- (DISK_FULL, shown on the tablespaces board), else CPU.
-- ===================================================================
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('alert|' || t.alert_key || '|' || :export_day, 'MD5'))),
         '@timestamp' VALUE :export_day || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'alert',
             'kind'   VALUE CASE WHEN t.kind LIKE 'TBSPC%'  THEN 'TBSPC'
                                 WHEN t.kind LIKE 'SERIES%' THEN 'SERIES'
                                 WHEN t.kind = 'DISK_FULL'  THEN 'DISK'
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

-- alert_volume: CAPR_ALERT_VOLUME, one per alert state_key (kind, container,
-- series, baseline mode) and export day: how many alerts the knobs make.
-- The floor and mode columns are set on the anomaly kinds only.
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('vol|' || t.state_key || '|' || :export_day, 'MD5'))),
         '@timestamp' VALUE :export_day || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'alert_volume',
             'kind'   VALUE CASE WHEN t.kind LIKE 'TBSPC%'  THEN 'TBSPC'
                                 WHEN t.kind LIKE 'SERIES%' THEN 'SERIES'
                                 WHEN t.kind = 'DISK_FULL'  THEN 'DISK'
                                 ELSE 'CPU' END,
             'series' VALUE t.series_key,
             &ident,
             'alert_kind'    VALUE t.kind,
             'baseline_mode' VALUE t.baseline_mode,
             'volume' VALUE JSON_OBJECT(
                 'episodes'        VALUE t.episodes,
                 'n_crit'          VALUE t.n_crit,
                 'n_warn'          VALUE t.n_warn,
                 'n_info'          VALUE t.n_info,
                 'window_days'     VALUE t.window_days,
                 'scored_days'     VALUE t.scored_days,
                 'flagged_days'    VALUE t.flagged_days,
                 'flagged_pct'     VALUE t.flagged_pct,
                 'max_dev'         VALUE t.max_dev,
                 'floor_knob'      VALUE t.floor_knob,
                 'floor_value'     VALUE t.floor_value,
                 'suggested_floor' VALUE t.suggested_floor,
                 'mode_knob'       VALUE t.mode_knob,
                 'mode_bit'        VALUE t.mode_bit,
                 'noisy'           VALUE CASE t.noisy WHEN 'Y' THEN 'true' WHEN 'N' THEN 'false' END FORMAT JSON
                 ABSENT ON NULL)
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM  (SELECT v.*, NVL(c.db_pdb, TO_CHAR(v.con_dbid)) AS db, c.db_name, c.con_name
       FROM   capr_alert_volume v
       LEFT   JOIN capr_container c ON c.dbid = v.dbid AND c.con_dbid = v.con_dbid) t
&tgt;

-- ===================================================================
-- The shared disk (ddl/33) and the tablespace families (ddl/32), each
-- stamped with the export day like fit.
-- ===================================================================
-- tbspc_shared: CAPR_TBSPC_SHARED, one per tablespace: its forecast against
-- the disk all tablespaces of the database share. A record of its own, not
-- fields of fit: the simulation joined to CAPR_FIT parses for minutes.
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('shared|' || t.dbid || '|' || t.con_dbid
                    || '|' || t.tablespace_name || '|' || :export_day, 'MD5'))),
         '@timestamp' VALUE :export_day || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'tbspc_shared', 'kind' VALUE 'TBSPC', 'series' VALUE t.tablespace_name,
             &ident,
             'quality'      VALUE t.quality,
             'days_to_full' VALUE t.days_to_full,
             'shared' VALUE JSON_OBJECT(
                 'disk_name'        VALUE t.disk_name,
                 'used_gb'          VALUE t.cur_gb,
                 'alloc_gb'         VALUE t.alloc_gb,
                 'limit_gb'         VALUE t.limit_gb,
                 'limit_own_gb'     VALUE t.limit_own_gb,
                 'limit_live'       VALUE CASE t.limit_live WHEN 'Y' THEN 'true' WHEN 'N' THEN 'false' END FORMAT JSON,
                 'grow_mb'          VALUE t.grow_mb,
                 'grow_worst_mb'    VALUE t.grow_worst_mb,
                 'ext_days'         VALUE t.ext_days,
                 'dtf_own'          VALUE t.dtf_own,
                 'dtf_shared'       VALUE t.dtf_shared,
                 'dtf_shared_worst' VALUE t.dtf_shared_worst,
                 'limit_shared_gb'  VALUE t.limit_shared_gb,
                 'stopped_by'       VALUE t.stopped_by,
                 'rank'             VALUE t.rank_shared
                 ABSENT ON NULL)
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM  (SELECT s.*, s.db_pdb AS db, c.db_name, c.con_name
       FROM   capr_tbspc_shared s
       LEFT   JOIN capr_container c ON c.dbid = s.dbid AND c.con_dbid = s.con_dbid
       WHERE  s.is_current = 'Y') t
&tgt;

-- disk: CAPR_DISK, one per database and disk. cap.kind = DISK, cap.series =
-- the DISK_FULL alert's series_key. Database level: con_dbid = dbid.
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('disk|' || t.dbid || '|' || t.disk_name
                    || '|' || :export_day, 'MD5'))),
         '@timestamp' VALUE :export_day || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'disk', 'kind' VALUE 'DISK', 'series' VALUE t.series_key,
             &ident,
             'sev'      VALUE t.sev,
             'sev_rank' VALUE t.sev_rank,
             'message'  VALUE t.message,
             'disk' VALUE JSON_OBJECT(
                 'disk_name'     VALUE t.disk_name,
                 'source'        VALUE t.disk_source,
                 'as_of'         VALUE TO_CHAR(t.disk_as_of, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                 'free_gb'       VALUE t.disk_free_gb,
                 'alloc_gb'      VALUE t.alloc_gb,
                 'dtf'           VALUE t.disk_dtf,
                 'dtf_worst'     VALUE t.disk_dtf_worst,
                 'full_day'      VALUE TO_CHAR(t.disk_full_day, 'YYYY-MM-DD"T00:00:00Z"'),
                 'n_tbspc'       VALUE t.n_tbspc,
                 'n_growing'     VALUE t.n_growing,
                 'n_growing_ok'  VALUE t.n_growing_ok,
                 'grow_mb'       VALUE t.grow_mb,
                 'grow_worst_mb' VALUE t.grow_worst_mb,
                 'top_growers'   VALUE t.top_growers,
                 'raw_sev'       VALUE t.raw_sev,
                 'gated_by'      VALUE t.gated_by
                 ABSENT ON NULL)
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM  (SELECT d.*, c.db_name, c.con_name
       FROM   capr_disk d
       LEFT   JOIN capr_container c ON c.dbid = d.dbid AND c.con_dbid = d.con_dbid) t
&tgt;

-- family: CAPR_TBSPC_FAMILY, one per container and family. cap.series = the
-- family name, as on the TBSPC_FAMILY alert.
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('fam|' || t.dbid || '|' || t.con_dbid
                    || '|' || t.family_name || '|' || :export_day, 'MD5'))),
         '@timestamp' VALUE :export_day || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'family', 'kind' VALUE 'TBSPC', 'series' VALUE t.family_name,
             &ident,
             'sev' VALUE t.sev,
             'family' VALUE JSON_OBJECT(
                 'name'                 VALUE t.family_name,
                 'source'               VALUE t.source,
                 'period'               VALUE t.period,
                 'period_days'          VALUE t.period_days,
                 'n_members'            VALUE t.n_members,
                 'n_done'               VALUE t.n_done,
                 'n_filling'            VALUE t.n_filling,
                 'n_empty'              VALUE t.n_empty,
                 'used_gb'              VALUE t.used_gb,
                 'max_limit_gb'         VALUE t.max_limit_gb,
                 'slope_gb_day'         VALUE t.slope_gb_day,
                 'growth_per_period_gb' VALUE t.growth_per_period_gb,
                 'recent_n'             VALUE t.recent_n,
                 'trend_sig'            VALUE CASE t.trend_sig WHEN 'Y' THEN 'true' WHEN 'N' THEN 'false' END FORMAT JSON,
                 'trend_gb'             VALUE t.trend_gb,
                 'next_member_gb'       VALUE t.next_member_gb,
                 'next_member_hi_gb'    VALUE t.next_member_hi_gb,
                 'next_over_limit'      VALUE CASE t.next_over_limit WHEN 'Y' THEN 'true' WHEN 'N' THEN 'false' END FORMAT JSON,
                 'filling_member'       VALUE t.filling_member,
                 'filling_used_gb'      VALUE t.filling_used_gb,
                 'filling_limit_gb'     VALUE t.filling_limit_gb,
                 'filling_pct_used'     VALUE t.filling_pct_used,
                 'filling_from'         VALUE TO_CHAR(t.filling_from, 'YYYY-MM-DD"T00:00:00Z"'),
                 'fill_rate_gb_day'     VALUE t.fill_rate_gb_day,
                 'period_end_day'       VALUE TO_CHAR(t.period_end_day, 'YYYY-MM-DD"T00:00:00Z"'),
                 'days_left'            VALUE t.days_left,
                 'expected_final_gb'    VALUE t.expected_final_gb,
                 'expected_final_hi_gb' VALUE t.expected_final_hi_gb,
                 'fits'                 VALUE CASE t.fits WHEN 'Y' THEN 'true' WHEN 'N' THEN 'false' END FORMAT JSON,
                 'actionable'           VALUE CASE t.actionable WHEN 'Y' THEN 'true' WHEN 'N' THEN 'false' END FORMAT JSON,
                 'headline'             VALUE t.headline
                 ABSENT ON NULL)
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM  (SELECT f.*, f.db_pdb AS db, c.db_name, c.con_name
       FROM   capr_tbspc_family f
       LEFT   JOIN capr_container c ON c.dbid = f.dbid AND c.con_dbid = f.con_dbid) t
&tgt;

-- family_member: CAPR_TBSPC_FAMILY_MEMBERS, one per member tablespace.
-- cap.series = the tablespace, cap.family.name its family.
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('famm|' || t.dbid || '|' || t.con_dbid
                    || '|' || t.tablespace_name || '|' || :export_day, 'MD5'))),
         '@timestamp' VALUE :export_day || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'family_member', 'kind' VALUE 'TBSPC', 'series' VALUE t.tablespace_name,
             &ident,
             'pct'            VALUE t.pct_used,
             'quality'        VALUE t.quality,
             'restart_reason' VALUE t.restart_reason,
             'family' VALUE JSON_OBJECT(
                 'name'             VALUE t.family_name,
                 'member_seq'       VALUE t.member_seq,
                 'state'            VALUE t.state,
                 'source'           VALUE t.source,
                 'period'           VALUE t.period,
                 'period_start'     VALUE TO_CHAR(t.period_start, 'YYYY-MM-DD"T00:00:00Z"'),
                 'period_end'       VALUE TO_CHAR(t.period_end, 'YYYY-MM-DD"T00:00:00Z"'),
                 'used_gb'          VALUE t.used_gb,
                 'limit_gb'         VALUE t.limit_gb,
                 'final_gb'         VALUE t.final_gb,
                 'fill_from'        VALUE TO_CHAR(t.fill_from, 'YYYY-MM-DD"T00:00:00Z"'),
                 'fill_to'          VALUE TO_CHAR(t.fill_to, 'YYYY-MM-DD"T00:00:00Z"'),
                 'fill_days'        VALUE t.fill_days,
                 'fill_rate_gb_day' VALUE t.fill_rate_gb_day
                 ABSENT ON NULL)
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM  (SELECT m.*, m.db_pdb AS db, c.db_name, c.con_name
       FROM   capr_tbspc_family_members m
       LEFT   JOIN capr_container c ON c.dbid = m.dbid AND c.con_dbid = m.con_dbid) t
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
