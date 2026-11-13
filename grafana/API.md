# ORDS endpoints for Grafana (route B contract)

Base URL: `http://<ords-host>:8080/ords/<alias>/awrcap/` where `<alias>` is the
ORDS URL mapping of the schema that holds the suite (`capdemo` in the lab).
Every handler needs a bearer token (see "Access" below) and answers 401
without one. Every handler is `GET`, returns ORDS' standard collection envelope
`{"items":[...], "hasMore":false, "limit":..., "offset":..., "count":...}`,
and is NOT paginated (every matching row in one response). The analytics are
daily-grain except `hourly` and the `HOUR_OF_WEEK` rows of `anomalies`, which
are hour-grain; all are small enough to ship whole. Column names are
lowercase. Nulls are JSON null.

Timestamps are ISO-8601 strings `YYYY-MM-DDTHH:MI:SSZ` holding the
database's wall clock: AWR days and hours are local DATEs, and the `Z` is a
label, not a conversion to UTC. The boards run with `timezone: utc`, so they
display the DB clock unshifted; a client in another zone must do the same, or
every point moves by its offset. `from`/`to` are compared against that clock
the same way.

| Endpoint | Query params | Columns | Backing view |
|---|---|---|---|
| `containers?target=` | optional | `dbid, con_dbid, db_name, con_name, db, target_name` | `CAPR_CONTAINER` |
| `targets` | none | `target_name, dbid, db_name, feed (LINK/FIXTURE), host_name, enabled (Y/N), n_containers, newest_snap, age_hours, is_stale (Y/N), collected_snap_id, last_ok_at, last_error_at, last_error, n_gaps, collect_state (OK/FAILING/NEVER/DISABLED; null unless feed = LINK)` | `CAPR_TARGETS` |
| `series?kind=&db=&series=&from=&to=` | kind required (TBSPC/CPU/SERIES); db (= `db` label) and series optional; from/to ISO date-times, default last 120 days | `ts, kind, series, db, con_dbid, value, limit_value, pct, unit, anomaly (0/1; null on unscored series), anomaly_flag, z, expected, threshold, gap (0/1)` plus kind extras: TBSPC `used_bytes, size_bytes, limit_bytes, delta_bytes, rate_bpd`; CPU `busy_pct, busy_p95, busy_peak_pct` on series BUSY_PCT; then `anomaly_modes` (the baseline modes that flagged the day, comma-separated, e.g. `TRAILING,SAME_DOW`), `how_hours_flagged` (HOUR_OF_WEEK hours flagged that day; BUSY_PCT and DB_CPU_PCT only) | `CAPR_SERIES_POINTS` (ddl/45) |
| `hourly?db=&series=&from=&to=` | all optional; series BUSY_PCT or DB_CPU_PCT; from/to taken as given (no day rounding), default last 14 days | `ts (end of the hour bucket), kind (CPU), series, db, con_dbid, day_dt, dow (0 = Monday), hour_of_day (end hour), unit (pct), value, gap (0/1), ivl_hours, n_intervals, anomaly (0/1), how_expected, how_threshold, how_z, how_flag (HIGH/LOW), how_n_hist` (`how_*` null when the hour was not scored) | `CAPR_HOURLY_POINTS` (ddl/45) |
| `forecast?kind=&db=&series=` | kind required; others optional | `ts, kind, series, db, con_dbid, method (REGR/ESM), horizon_days, value, lo, hi, limit_value, pct, quality` | `CAPR_FORECAST_POINTS` (new, ddl/55; needs CAPF_COMPARE) |
| `fit?kind=&db=` | kind optional (all kinds when absent) | `kind, series, db, con_dbid, unit, method, value, limit_value, pct, slope_per_day, r2, quality, days_to_full, days_to_full_lo, days_to_full_hi, accel, train_n, sev (CRIT/WARN/OK), sev_rank, limit_source, last_day, target_name, restart_reason (PURGE/STOP/START, TBSPC only), restart_day`, then the track record: `reliability (GOOD/BIASED/WIDE/UNKNOWN), n_forecasts, abs_err_pct, bias_pct, band_hit_pct, band_factor, track_summary` (null before the first refresh run) | `CAPR_FIT` (ddl/45), `CAPR_FIT_TRACK` (ddl/60) |
| `anomalies?from=&to=&db=&kind=&mode=` | all optional; mode = a baseline_mode; from/to default last 120 days | `ts, kind, series, db, con_dbid, anomaly_kind, anomaly_flag (HIGH/LOW/UP/DOWN), value, expected, threshold, z, shift_pct, unit (bytes_per_day/pct/count/gib/gib_per_day/io_per_sec/mb_per_sec), sev (WARN/INFO), sev_rank, message, obs_day, baseline_mode, grain (DAY/HOUR), n_hist, alerting (Y/N), raw_value` | `CAPR_ANOMALIES` (ddl/45) |
| `alerts?db=` | optional | `sev, sev_rank, alert_kind, kind (TBSPC/SERIES/DISK/CPU: the board that lists it), series, db, con_dbid, obs_day, value, threshold, unit, message, baseline_mode, alert_key` | `CAPR_ALERTS` |
| `alert_volume?db=` | optional | `target_name, db, dbid, con_dbid, alert_kind, series, baseline_mode, state_key, episodes, n_crit, n_warn, n_info`, and on the anomaly kinds `window_days, scored_days, flagged_days, flagged_pct, max_dev, floor_knob, floor_value, suggested_floor, mode_knob, mode_bit`; `noisy (Y/N)` | `CAPR_ALERT_VOLUME` (ddl/55) |
| `tbspc_shared?db=` | optional | `target_name, db, dbid, con_dbid, series (the tablespace), disk_name, quality, is_current (Y/N), cur_gb, alloc_gb, limit_gb, limit_own_gb, limit_live (Y/N), grow_mb, grow_worst_mb, ext_days, days_to_full, dtf_own, dtf_shared, dtf_shared_worst, limit_shared_gb, stopped_by (DISK/LIMIT), rank_shared` | `CAPR_TBSPC_SHARED` (ddl/45) |
| `disk?db=` | optional; db = any container of the database | `target_name, db (the root container), dbid, con_dbid, disk_name, series (DISK:<disk name>), disk_source (OVERRIDE/LIVE/NONE), disk_as_of, disk_free_gb, alloc_gb, disk_dtf, disk_dtf_worst, disk_full_day, newest_day, n_tbspc, n_growing, n_growing_ok, grow_mb, grow_worst_mb, top_growers, raw_sev, sev (CRIT/WARN/OK), sev_rank, gated_by, message` | `CAPR_DISK` (ddl/45) |
| `families?db=` | optional | `target_name, db, dbid, con_dbid, family_name, source (AUTO/OPERATOR), period (MONTH/QUARTER/YEAR), n_members, n_done, n_filling, n_empty, last_day, used_gb, max_limit_gb, slope_gb_day, period_days, growth_per_period_gb, recent_n, trend_sig (Y/N), trend_gb, next_member_gb, next_member_hi_gb, next_over_limit (Y/N), filling_member, filling_used_gb, filling_limit_gb, filling_pct_used, filling_from, fill_rate_gb_day, period_end_day, days_left, expected_final_gb, expected_final_hi_gb, fits (Y/N), sev (WARN/OK), actionable (Y/N), headline` | `CAPR_TBSPC_FAMILY` (ddl/45) |
| `family_members?db=&family=` | optional | `target_name, db, dbid, con_dbid, family_name, series (the tablespace), member_seq, state (DONE/FILLING/EMPTY), source, period, period_start, period_end, last_day, used_gb, limit_gb, pct_used, final_gb, fill_from, fill_to, fill_days, fill_rate_gb_day, quality, restart_reason` | `CAPR_TBSPC_FAMILY_MEMBERS` (ddl/45) |
| `mem_verdicts?db=` | optional | `target_name, db, dbid, con_dbid, instance_number, area, area_label, area_rank, mem_mode, grade, reason, reason_text, actionable (Y/N), current_bytes, suggested_bytes, current_size, suggested_size, change_pct, suggested_param, exceeds_host_ram (Y/N), exceeds_sga (Y/N), n_evidence, n_pressure, n_days, window_start, window_end, headline, snap_run_id` | `CAPR_MEM_VERDICT_S` (the last refresh), else `CAPR_MEM_VERDICT` |
| `mem_evidence?db=&area=` | optional | `target_name, db, dbid, con_dbid, instance_number, area, area_label, area_rank, evidence_kind (USAGE/ADVISOR/SYMPTOM/CONTEXT), signal, direction (PRESSURE/SLACK/NEUTRAL), value, unit, threshold, observed_at, evidence_text, snap_run_id` | `CAPR_MEM_EVIDENCE_S` (the last refresh), else `CAPR_MEM_EVIDENCE` |
| `mem_components?db=` | optional | `target_name, db, dbid, con_dbid, instance_number, component, is_pool, current_bytes, min_bytes, max_bytes, pct_of_total, n_ops, n_grows, n_shrinks, n_forced_grows, last_resize_at` | `CAPR_MEM_COMPONENTS` |
| `mem_points?db=&from=&to=` | optional; from/to default last 120 days (the view holds the evidence window, `mem_window_days`) | `ts, target_name, db, dbid, con_dbid, instance_number, component, bytes, min_bytes, max_bytes, ops` | `CAPR_MEM_COMP_POINTS` |

`target_name` is the suite's name of the row's database
(`CAPR_CONTAINER.target_name`, one target per dbid; null for a dbid without
a target). It is the last column of `series`, `hourly`, `forecast`,
`anomalies` and `alerts`, on `fit` the column before `restart_reason`, and
every endpoint but `targets` takes an optional `target=` filter. `db` is the
display label built from it (`TARGET` or `TARGET/PDB`).

The memory endpoints are instance level: their rows belong to the root
container of a database (`con_dbid = dbid`), so `db` is the root's label and
a PDB label returns nothing. Grades: `UNDERSIZED`, `OVERSIZED`, `THRASHING`,
`DRIFTING`, `OK`, `INSUFFICIENT_EVIDENCE`. They are report content and never
appear in `alerts`.

`mem_verdicts` and `mem_evidence` show the last refresh, not the views as of
now: they read the snapshot tables `CAPR_MEM_VERDICT_S` / `CAPR_MEM_EVIDENCE_S`
that every `cap_results.refresh` fills, and `snap_run_id` names that run
(`CAPR_RUNS.run_id`). Read live, the verdict views go through a 30-day window
of AWR memory history on every request: 130 s and 75 s on a busy 2 vCPU lab
VM. Without a snapshot (no refresh since the install) both handlers fall back
to the live views and `snap_run_id` is null. Schedule the refresh
(`install_jobs.sql`) and the verdicts are at most a day old.
`mem_components` and `mem_points` are read live.

The shared disk and the families: `tbspc_shared` holds every tablespace with
its days alone (`dtf_own`) and on the disk its database's datafiles share
(`dtf_shared`); `disk` is one row per database and disk, filed under the root
container like the memory rows, and is the `DISK_FULL` alert's source;
`families` and `family_members` are the tablespace families (one tablespace
per month, quarter or year) and the `TBSPC_FAMILY` alert's source. Sizes are
GiB (2^30 bytes), rates MiB or GiB a day, not rounded. `alert_volume` reads
`CAPR_ALERT_VOLUME`, which runs the anomaly engine twice: it is the slowest
handler now, and one for a table at the bottom of a board, not for a tile.

Enumerations:

- `anomaly_kind`: `TBSPC_GROWTH` (tablespace growth rate), `CPU_BUSY` (host
  BUSY_PCT), `DBCPU_BUSY` (container DB_CPU_PCT), `SERIES_LEVEL` (sessions,
  processes, redo per day), `SERIES_GROWTH` (database size growth),
  `CPU_SHIFT` (a sustained level shift).
- `baseline_mode`: `TRAILING` (the last `mad_window_days` days, DAY grain),
  `SAME_DOW` (the same weekday over the last `dow_weeks` weeks, DAY grain),
  `HOUR_OF_WEEK` (the same weekday and end hour, HOUR grain); null for
  `CPU_SHIFT` and for every non-anomaly alert.
- `alert_kind`: `TBSPC_FULL`, `TBSPC_NEARFULL`, `TBSPC_ANOM`, `CPU_SAT`,
  `DBCPU_SAT`, `CPU_ANOM`, `DBCPU_ANOM`, `CPU_SHIFT`, `SERIES_LIMIT`,
  `SERIES_NEARLIMIT`, `SERIES_ANOM`. The `*_ANOM` kinds carry one row per
  series, day and baseline mode; `alert_key` is unique per row. CPU rows of
  `series`, `forecast` and `fit` share one limit convention: `limit_value` is
  the saturation line `cpu_sat_pct` (not 100) and `pct` is `value` as a
  percent of it, and `CAPR_ALERTS` (the view behind `alerts`) now also has
  the kinds `CPU_HOT`, `DBCPU_HOT`, `DATA_STALE`, `MODEL_HEALTH`,
  `TBSPC_FAMILY` (unit `GIB`, `series` = the family name) and `DISK_FULL`
  (unit `DAYS`, `series` = `DISK:<disk name>`, the one alert with `kind`
  `DISK`, filed under the root container) and the
  columns `state_key` (stable across days), `direction` (LE/GE/ABS),
  `alarm_threshold` (the WARN level) and `is_current`, which the ORDS handler
  does not select yet. Likewise `CAPR_FIT` (the view behind `fit`) appends
  columns the handler does not select yet: `is_current` and
  `limit_below_used` as 1/0, the TBSPC cycle columns `cycle_n`, `cycle_days`,
  `cycle_peak_pct`, `peak_slope_per_day`, the CPU flags `slope_sig` and
  `hot_now` as 1/0, and the TBSPC sizing ask `need_gib_30` / `_90` / `_180`
  and `add_by_day`. The handler does select the last two, `restart_reason`
  and `restart_day`.

Semantics are the same as the ELK records (see `elk/README.md`): `series`
rows are the observed daily points with the CAPA_* flag joined on
(`anomaly=1` on a flagged day); `forecast` rows are the REGR anchors at
horizons 0/30/90/180/365 (TBSPC) or 0/30/90 (CPU, SERIES) and the ESM point,
`ts` = last observed day + horizon (for ESM the horizon is the model's furthest
step minus its age: `esm_horizon_days - model_age_days`, at most 30); `fit` is one row per series with
the latest fit; `anomalies` carries one row per flagged event and baseline
mode (a day flagged by TRAILING and SAME_DOW is two rows; an HOUR_OF_WEEK row
is one hour, `ts` at the end of the hour, `obs_day` its day), a level shift
dated at the start of its recent window with the window end in `obs_day`.
On `anomalies`, `value` is the scored value (TBSPC: the growth rate in
bytes/day, so `unit` is `bytes_per_day`; `raw_value` is the day's raw delta in
bytes), `expected` the baseline median and `threshold` the allowed deviation,
so the crossed bound is `expected ± threshold`. `alerting = Y` marks the rows
`alerts` pages on. `hourly` rows are the CPU hour buckets each HOUR_OF_WEEK
verdict is computed from, one per container, metric and end hour.

The new CAPR_* views are suite objects (read-only SELECTs over the existing
layers, 19c syntax, no DBA_HIST_* references) and are what `elk/export_capacity.sql`
should select from too, so both paths share one definition.

Grafana reads these with the Infinity data source (JSON, root selector
`items`), passing `${__from:date:iso}` / `${__to:date:iso}` and dashboard
variables `$db`, `$series` into the query string.

## Access

`grafana/ords/awrcap_module.sql` publishes the module protected: the ORDS
privilege `awrcap.read` covers the module and requires the ORDS role
`awrcap_reader`. A request without a valid bearer token gets 401, on every
handler, `metrics` included.

A consumer is an OAuth2 client with the grant type `client_credentials`
that holds the role. `grafana/ords/awrcap_client.sql [schema] [client name]`
creates one (default name `awrcap_grafana`) and prints `ORDS_CLIENT_ID=` and
`ORDS_CLIENT_SECRET=` once. ORDS keeps only a hash of the secret. Running the
script again replaces the client: the old id and secret stop working.

```bash
# token: HTTP Basic with the client id and secret, valid 3600 s by default
curl -s -K client.curlrc -d grant_type=client_credentials \
     http://<ords-host>:8080/ords/<alias>/oauth/token
# -> {"access_token":"...","token_type":"bearer","expires_in":3600}
curl -s -H "Authorization: Bearer <access_token>" \
     http://<ords-host>:8080/ords/<alias>/awrcap/containers
```

`client.curlrc` holds one line, `user = "<client id>:<client secret>"`, so
the secret is not on a command line. Grafana's Infinity data source does
the same exchange by itself (`auth_method: oauth2`, see
`grafana/provisioning/datasources/infinity.yml`) and renews the token.

Over plain HTTP the token and the secret travel unencrypted. Outside a lab
put ORDS behind TLS.

Opt-out for a closed lab: `@grafana/ords/awrcap_module.sql <schema> - PUBLIC`
removes the privilege, and every handler is readable by anyone who reaches
the ORDS port. Set `ORDS_AUTH_METHOD=none` for Grafana then. Running the
script again without `PUBLIC` protects the module again.

## Prometheus: `metrics`

`GET .../awrcap/metrics` is a PL/SQL handler, not a JSON collection. It
returns the Prometheus text exposition format (`Content-Type: text/plain;
version=0.0.4`), read live from the CAPR views on every scrape:

| Metric | Labels | Value | Source |
|---|---|---|---|
| `awrcap_alert` | `kind, severity, db, con_dbid, series, mode` | rows of that issue (normally 1); `mode` is the baseline mode or `-` | `CAPR_ALERTS` |
| `awrcap_days_to_full` | `kind, db, con_dbid, series, quality` | days to the ceiling; series with no projected crossing are omitted | `CAPR_FIT.days_to_full` |
| `awrcap_pct_used` | `kind, db, con_dbid, series` | value as a percent of the ceiling (CPU: of `cpu_sat_pct`) | `CAPR_FIT.pct` |
| `awrcap_data_through_days` | `db, dbid, target` | days since the newest AWR snapshot day; `target` is the target name of the dbid, empty when it has none | `CAPR_FRESHNESS`, `CAPR_CONTAINER` |
| `awrcap_up` | none | 1 when every view was read, 0 when one raised (a `# awrcap metrics failed:` comment says why) | the handler |

Every family is a gauge with HELP and TYPE lines. Label values escape `\`,
`"` and newlines. `con_dbid` and `mode` are added to the labels so two
containers with the same display name, or one series alerting under two
baseline modes, never produce duplicate series. An alert that clears simply
disappears from the next scrape; alert on `awrcap_alert{severity="CRIT"}`
and on `absent(awrcap_up == 1)`.

Example output (fixture):

```text
# TYPE awrcap_alert gauge
awrcap_alert{kind="TBSPC_FULL",severity="CRIT",db="FIXCDB",con_dbid="42424242",series="FIX_FILLING",mode="-"} 1
# TYPE awrcap_days_to_full gauge
awrcap_days_to_full{kind="TBSPC",db="FIXCDB",con_dbid="42424242",series="FIX_FILLING",quality="OK"} 20
awrcap_up 1
```

Scrape configuration (each scrape evaluates `CAPR_ALERTS`, several seconds on
a large fleet, so keep the interval long and the timeout generous):

```yaml
scrape_configs:
  - job_name: awrcap
    metrics_path: /ords/capdemo/awrcap/metrics
    scrape_interval: 15m
    scrape_timeout: 2m
    oauth2:
      client_id: <ORDS_CLIENT_ID of the scraper's client>
      client_secret_file: /etc/prometheus/awrcap_client_secret
      token_url: http://ords-host:8080/ords/capdemo/oauth/token
    static_configs:
      - targets: ['ords-host:8080']
```

`metrics` follows the module's access rule: 401 without a bearer token.
Give the scraper its own client
(`@grafana/ords/awrcap_client.sql <schema> awrcap_prometheus`) and keep the
secret in a file only Prometheus reads. The handler exposes tablespace and
series names and the subjects of alert messages.

Trying the body without ORDS (any SQL*Plus session in the suite schema): the
handler writes through HTP, so set up an OWA environment, run the block that
`grafana/ords/awrcap_module.sql` passes to `plsql('metrics', ...)`, then
print the page:

```sql
SET SERVEROUTPUT ON SIZE UNLIMITED
DECLARE n OWA.VC_ARR; v OWA.VC_ARR;
BEGIN n(1) := 'REQUEST_METHOD'; v(1) := 'GET'; OWA.INIT_CGI_ENV(1, n, v); END;
/
-- paste the DECLARE ... END; block of the metrics handler here, then /
EXEC OWA_UTIL.SHOWPAGE
```
