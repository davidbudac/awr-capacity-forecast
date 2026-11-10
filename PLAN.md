# PLAN.md — roadmap / milestones

Status legend: `[ ]` todo · `[~]` in progress · `[x]` done.
Done milestones (M1–M6 / W: seam, daily, Tier 1, anomalies, Tier 2 ESM, HTML
report, warehouse seam) are described in `docs/design.md`; this file tracks
what is **next**. Each milestone is scoped so it can ship alone.

Ground rules for every item: read-only against AWR, everything via the
`CAPV_*` seam, knobs in `CAP_CONFIG`, 19c syntax floor, fixture assertion for
every new number (see `test/run_test.sql`).

---

## M7 — Report usability (text + HTML)

- [x] **M7.1 Don't hide near-full tablespaces.** Done: `pct_used` added to
      `CAPF_TBSPC_FORECAST`; section 1a ranks days-to-full across all
      qualities with a QUALITY marker; new 1b "near-full now" ranking by
      `PCT_USED` (knobs `nearfull_warn_pct`/`nearfull_crit_pct`, 90/97);
      mirrored in `report_html.sql` (banner items, glance cards, section 1
      tables). Fixtures `FIX_NEARFULL`/`FIX_FILLING` assert it.
- [x] **M7.2 Container / database names instead of raw `con_dbid`.** Done:
      `CAPV_CONTAINER` in all three seams (local: `DBA_HIST_PDB_INSTANCE` —
      which names CDB$ROOT too — + `DBA_HIST_DATABASE_INSTANCE` fallback;
      warehouse: new `awrv_container` over `awrw_dbid`/`awrw_target`, con_name
      NULL until a PDB-name dim exists; fixture: `CAP_FIXTURE_CONTAINER`).
      `CAPR_CONTAINER.db_pdb` computes the label once; every text/HTML section
      prints `DB/PDB`.
- [x] **M7.3 At-a-glance block for the text report.** Done: section 0 in
      `report.sql` (counts + alert list) built from `CAPR_ALERTS`, same view
      the HTML banner reads.
- [x] **M7.4 Bound sections 2 and 6.** Done: `CAPR_TBSPC_FORECAST` computes
      `is_reportable` (growing OR near-full OR `cur_used >= report_min_gb` GiB
      — near-full is in the disjunction so M7.1's rule still holds) and
      `rank_report` (reportable first, growing first, then biggest);
      `CAPR_ESM_COMPARE` inherits both (CPU rows always `'Y'` / rank 0). Text
      and HTML apply the identical `WHERE is_reportable='Y' AND rank_report <=
      top_n` and print the bound in the section header. New knob
      `report_min_gb` (1). Fixture: FIX_FLAT is the one `'N'`.
- [x] **M7.5 Drill-down script.** Done: `report/drill_tbspc.sql <tablespace>
      [con_dbid]` and its CPU twin `report/drill_cpu.sql [metric] [con_dbid]`
      (metric = `BUSY_PCT` default | `BUSY_P95` | `BUSY_PEAK` | `DB_CPU_SEC` |
      `DB_CPU_PCT` | `DB_CPU_P95`) print + spool one series end-to-end: fit
      header (slope/intercept/R2/slope CI/days-to-full|sat with WORST/BEST),
      the daily series over `train_days` with `fit`, `residual`, delta, gap and
      the CAPA_* baseline per day, a residual footer proving `SUM(resid)=0` and
      re-deriving `resid_se` + `slope_ci` from scratch, and one spelled-out
      arithmetic line per flagged day. Optional args via the COLUMN NEW_VALUE
      zero-row trick (never prompts) and `UNDEFINE`d at the end.
- [x] **M7.6 Positional report args.** Done: `@report/report.sql [top_n]
      [anomaly_days] [show_esm]` and the same for `report_html.sql`, with
      `report/defaults.sql` still the fallback source of truth. Unset `&1..&3`
      are defined-as-empty by the zero-row `COLUMN 1 NEW_VALUE 1` trick (a
      passed argument survives it), so neither form ever prompts; both scripts
      `UNDEFINE 1 2 3` at the end. Verified non-interactively on 19c with 0, 1
      and 3 arguments.
- [x] **M7.7 Cleanups.** Done: `anomaly_report_days` KEPT (it is
      `CAPR_ALERTS`' window; the report's `anomaly_days` DEFINE stays
      presentation-only) and README / `docs/reference.html` now say which
      window is which; every header knob goes through
      `TO_CHAR(..,'FM9999990')`, so the text report prints
      `WARN<=90 CRIT<=30 ; CPU saturation 80%` and `reaches 80%`; GiB / MiB
      labels unified across text + HTML wherever the number is `/1073741824`
      (`/1048576`); `accel_ratio` is NULL when
      `|slope| < accel_slope_floor_bpd` (new knob, 1 MiB/day), so a near-flat
      series can no longer show a 500x acceleration.

## M8 — Integration surface

- [x] **M8.1 `CAPR_ALERTS` view.** Done (`ddl/45_report_views.sql`): one row
      per issue — `severity/sev_rank, kind (TBSPC_FULL | TBSPC_NEARFULL |
      TBSPC_ANOM | CPU_SAT | CPU_ANOM), dbid, con_dbid, db_pdb, series_key,
      day_dt, value, threshold, unit, message`. Anomaly kinds window on the
      `anomaly_report_days` knob. Read-only; fixture-asserted.
- [x] **M8.2 `CAPR_*` report views.** Done: one view per report section —
      `CAPR_TBSPC_DAYS_TO_FULL` (1a/1b, with `sev_dtf`/`sev_nearfull` and
      `rank_dtf`/`rank_nearfull` so a driver applies `top_n` with a WHERE),
      `CAPR_TBSPC_ANOMALIES` / `CAPR_CPU_ANOMALIES` (flagged rows + `days_ago`
      so the window is a WHERE too), `CAPR_CPU_TREND` in
      `ddl/45_report_views.sql`; `CAPR_TBSPC_FORECAST`, `CAPR_ESM_COMPARE`
      and `CAPR_BACKTEST` in the new `ddl/55_report_views_ml.sql` (loaded
      after `50_ml`, because they read `CAPF_COMPARE`/`CAPF_BACKTEST`). Every
      GiB/MiB conversion, severity marker and `db_pdb` label is computed once
      in the view; `report/sections/0[1-6]*.sql` and `report_html.sql` now
      only format, so the two drivers cannot drift. Text and HTML output are
      byte-identical to before on the fixture.
- [x] **M8.3 Jobs.** Done: `install_jobs.sql` / `uninstall_jobs.sql` (opt-in,
      repo root, not in `install.sql`) create `CAP_ML_RETRAIN` (weekly
      `cap_forecast_ml.train_all`; daily since M18.3) and `CAP_REPORT_SPOOL_JOB` (daily
      `cap_report_spool(p_dir)` → `UTL_FILE` snapshot of `CAPR_ALERTS` into a
      `report_dir` DEFINE, default `CAP_REPORTS`), both DISABLED and
      idempotent; jobs share the schema namespace with procedures, hence the
      `_JOB` suffix (ORA-27477).
- [x] **M8.4 `doctor.sql` preflight.** Done: read-only PASS/WARN/FAIL checklist
      in one exception-wrapped anonymous block — pack access, direct
      `DBA_HIST_*` reads, `SESSION_PRIVS`, AWR retention/interval per dbid,
      days of history per source vs `min_train_days`, invalid `CAP*` objects +
      detected deploy mode, then a plain-English "why `INSUFFICIENT_HISTORY`".

## M9 — Forecast quality (Tier 1)

- [x] **M9.1 Prediction intervals.** Done: `REGR_SXX/SXY/SYY/AVGX` → residual
      SE → 95% bands (`proj_*_lo/hi`) + `days_to_full_lo/hi` /
      `days_to_sat_lo/hi` ranges on both CAPF views (t approximated as
      `1.96 + 2.4/df`, part of the contract). Reports show the range (1a/4
      WORST/BEST columns, section 2 +180 band, HTML RANGE columns + worst-case
      card line). `FIX_ZIGZAG` fixture asserts the closed forms; `FIX_LINEAR`
      asserts bands collapse at zero residuals.
- [x] **M9.2 Robust slope.** Done: Theil–Sen (median of the pairwise slopes
      `(y_j−y_i)/(x_j−x_i)` via a self-join on the training window, O(n²) ≈ 4k
      pairs at 90 days) computed alongside OLS in **both** `CAPF_TBSPC_FORECAST`
      and `CAPF_CPU_TREND`. Knob `slope_method` (CAP_CONFIG is numeric: `0` =
      OLS default, `1` = THEILSEN); both estimators are always exposed
      (`ols_slope_bpd` / `ts_slope_bpd`, `ols_slope_per_day` /
      `ts_slope_per_day`, plus `ts_icept`) and `slope_method` says which one the
      row used. When THEILSEN is selected it drives `slope_bpd`, `icept`, every
      `proj_*`, `days_to_full`/`days_to_sat`, both halves of `accel_ratio` and
      the `slope = 0` FLAT test; `r2` and the M9.1 bands (`proj_*_lo/hi`,
      `slope_ci_bpd`, `days_to_full_lo/hi`) stay OLS residual quantities drawn
      around the chosen line — there is no closed-form Theil–Sen interval in
      SQL. Fixtures: `FIX_LINEAR` (TS = 10 MiB/day exactly), `FIX_ZIGZAG` (TS =
      the median of all 4005 pairwise slopes, enumerated and sorted in the
      installer), `FIX_SPIKE` (TS within 1% of the true 5 MiB/day while OLS is
      3.9× off), plus a knob-flip test that switches to THEILSEN mid-run and
      back. Since M18.1 the Theil-Sen self-joins run only when
      `slope_method = 1` (the `ts_*` columns are NULL otherwise), and M18.2
      adds `slope_method = 2` (DRIFT).
- [x] **M9.3 Change-point reset.** Done: knobs `reset_on_shrink` (1) and
      `shrink_mad_k` (6). `CAPF_TBSPC_FORECAST` restarts the training window at
      the most recent day whose day-over-day delta is below
      `−GREATEST(shrink_mad_k·MAD_sigma(window deltas), abs_floor_bytes)` (MAD
      computed inline, two passes like ddl/40 but per series over the one
      window), so a post-purge series is fit only on post-purge data. The cliff
      day itself is day 1 of the new window (its `used_bytes` is already the
      post-purge level); new columns `train_start` / `reset_day` (NULL = no
      reset) make it visible, and a window left shorter than `min_train_days`
      honestly reads `INSUFFICIENT_HISTORY`. Fixture `FIX_PURGE` (10 MiB/day,
      −600 MiB at day 90, 10 MiB/day again) asserts `reset_day` = the cliff,
      `train_n` = 31, slope = 10 MiB/day exactly and days-to-full off the
      post-purge line; `FIX_SPIKE` (positive step), `FIX_LINEAR` and
      `FIX_ZIGZAG` assert `reset_day IS NULL`. Not applied to `CAPF_CPU_TREND`:
      a "shrink" is a tablespace event, and a CPU level shift is M10.3's job.
- [x] **M9.4 Backtest / holdout accuracy.** Done: `CAPF_BACKTEST` (in
      `ddl/50_ml.sql`) scores each engine against the held-out last
      `backtest_holdout_days` (knob, 28): REGR recomputed in pure SQL (always
      available), ESM via `cap_forecast_ml.train_backtest` — purpose=BACKTEST
      twin models (CBT* names, new `CAP_ML_MODEL.purpose` column, exposed via
      `CAPF_ESM_BACKTEST`, never leak into `CAPF_ESM_FORECAST`/`CAPF_COMPARE`).
      Section 6c (text + HTML) shows MAPE/bias per engine + BETTER verdict.
      Feeds ESM model-type selection in M10.4.
- [x] **M9.5 Tablespace limit overrides / exclusions.** Done:
      `CAP_TBSPC_OVERRIDE (dbid, con_dbid, tablespace_name, limit_bytes,
      exclude_flag, note)` — the THIRD persisted table (created idempotently in
      `ddl/05_config.sql`, preserved by `00_drop`, dropped only by
      `uninstall.sql`). Autoextend `maxsize` is not real headroom when the
      filesystem / ASM DG is smaller, so a row replaces the computed limit;
      `exclude_flag='Y'` silences staging/scratch tablespaces entirely.
      Applied once in `CAPD_TBSPC_DAILY` (an `ores` CTE resolves the most
      specific of the matching rows — `dbid`/`con_dbid` `0` are wildcards — so
      the LEFT JOIN cannot fan out), which means forecasts, anomalies,
      `CAPR_ALERTS` and both reports honour it with no further code. New
      `limit_source` (`OVERRIDE`/`AUTOEXTEND`/`ALLOCATED`) rides through
      `CAPF_TBSPC_FORECAST`. Fixtures `FIX_OVERRIDE` (FIX_LINEAR's twin capped
      at 2 GiB: 4990 days-to-full becomes 74) and `FIX_EXCLUDED` (99% full,
      excluded via the wildcard row, must appear nowhere) assert it.

## M10 — CPU / capacity analysis

- [x] **M10.1 Peak, not average.** Done: `CAPD_CPU_DAILY` adds `busy_p95`,
      `busy_max`, `busy_peak_pct` (+ `peak_intervals`, `host_busy_sec`) from
      the per-snapshot OSSTAT deltas; peak window = intervals ending in
      `(peak_hour_from, peak_hour_to]` (knobs, default 8/18). `CAPF_CPU_TREND`
      fits `BUSY_P95` / `BUSY_PEAK` with `days_to_sat`; `CPU_SAT` alerts key
      off `BUSY_P95` unless `cpu_sat_on_p95 = 0`. Fixture now has two
      snapshots/day (06:00 night, 18:00 peak) with closed-form assertions.
- [x] **M10.2 DB CPU as % of core capacity.** Done: `CAPD_DBTIME_DAILY` adds
      `db_cpu_pct`, `db_cpu_p95_pct`, `db_cpu_max_pct`, `db_cpu_peak_pct`,
      `host_share_pct` (per-PDB share of host busy seconds); `CAPF_CPU_TREND`
      metrics `DB_CPU_PCT` / `DB_CPU_P95` with `days_to_sat`; new alert kind
      `DBCPU_SAT`. Since M17.2 the denominator is logical CPUs (`NUM_CPUS`),
      not cores.
- [x] **M10.3 Level-shift detection.** Done: `CAPA_CPU_SHIFT`
      (`ddl/40_anomaly_views.sql`) — per (dbid, con_dbid, metric ∈ `BUSY_PCT` /
      `BUSY_P95` / `DB_CPU_PCT`) the median of the last `shift_days` (7) days
      vs the median of the `shift_baseline_days` (28) before it,
      `shift_pct = recent_med - base_med` in percentage POINTS. `UP` needs
      `shift_pct > shift_min_pct` (15) AND a full recent window AND enough
      baseline AND the N-of-M rule (`n_above >= shift_days`: every recent day
      above `base_med + max(base_mad_sigma, cpu_min_mad_pct)`) — which is what
      stops one loud day from dragging a 7-day median into a "shift". `DOWN` is
      the mirror (INFO, not WARN). One row per series (current state) with every
      input exposed. New alert kind `CPU_SHIFT`, new `CAPR_CPU_SHIFTS` view,
      report section 5b (text + HTML). Gap days (M10.5) are excluded from both
      windows. Fixture: a SECOND container (FIXPDB1, con_dbid 42424243, time-
      model rows only) whose DB CPU is a 7-day 34..46% sawtooth — so both
      medians are exact closed forms — stepping +18 points for the last 7 days.
      Review fix (2026-10): incomplete days (`is_complete = 'N'`) now leave
      both windows too (same rule as `CAPA_ANOM` and the CPU fit), and the view
      carries `newest_day` / `is_current` per dbid; `CAPR_ALERTS` passes
      `is_current` through for `CPU_SHIFT`, so a stopped PDB's shift stops
      being merged. The fixture has no CPU series that stops early (giving
      FIXPDB2 a 30-day early stop would break its deseason / DBCPU_HOT / digest
      assertions), so the negative case flips `stale_days` to -1 instead.
- [x] **M10.4 ESM tuning.** Done: `train_tablespaces` now picks the ESM model
      type per series. With `esm_tbspc_model = 2` (AUTO) and
      `esm_select_by_backtest = 1` (both new knobs, both defaults) it builds
      BOTH candidate M9.4 twins — `EXSM_HOLT` and `EXSM_ADDWINTERS(7)`, names
      now hashing the model type too — scores them in the new
      `CAPF_ESM_CANDIDATE` (one row per series per candidate) and trains
      production with the lower-MAPE one (ties / no evidence → HOLT). The
      decision rides on `CAP_ML_MODEL.model_type` / `chosen_by` / `mape_holt` /
      `mape_addw` and surfaces as `CAPR_ESM_COMPARE.esm_model` (6a/6b column
      `ESM_MODEL`) and `CAPR_BACKTEST.esm_pick` (6c column `ESM_PICK`, e.g.
      `ADDW H=2.90 W=1.20`). `esm_tbspc_model = 0|1` pins a type and skips the
      twins. Quality gate: tablespaces (`CAPF_TBSPC_FORECAST`) and CPU
      (`CAPF_CPU_TREND`) are trained only at `quality IN
      ('OK','LOW_CONFIDENCE')`, so FIX_FLAT / FIX_NEARFULL get no model.
      `CAPF_COMPARE` / `CAPF_BACKTEST` stay backward compatible (a `model_type`
      column added; `CAPF_BACKTEST`'s ESM row is the SELECTED candidate, so it
      is still one row per series per engine). Stale twins are purged per
      series on retrain and `drop_all` gained an orphan sweep over the six
      `<prefix>_<16 hex>` model names.
- [x] **M10.5 CPU gap handling.** Done: `CAPD_CPU_DAILY` and
      `CAPD_DBTIME_DAILY` now expose `max_interval_hours`, `gap_flag` (`'Y'`
      when any interval of the day is longer than the new `cpu_gap_hours` knob,
      default 12) and `day_gap`, mirroring `CAPD_TBSPC_DELTA`. The day is KEPT
      in the series, but `busy_p95` / `busy_max` / `busy_peak_pct` (and the
      `db_cpu_*` twins) are computed only from intervals `<= cpu_gap_hours`, so
      a 36 h average can never pose as a peak hour; `CAPA_CPU_ANOM` neither
      scores a gap day nor lets it into a same-weekday baseline, and
      `CAPA_CPU_SHIFT` skips them too. Default is 12 h rather than something
      tighter because the flag SUPPRESSES scoring — an over-sensitive value
      would silence the CPU anomaly layer wherever snapshot intervals are wide.
      Fixture: a pure AWR gap (a Sunday in day 70..80 whose two snapshots carry
      no OSSTAT/time-model rows) makes the next 06:00 interval span 36 h; that
      day reads 30% busy against a 40% Monday baseline (10 points over a
      9-point threshold) and must stay unflagged purely because of the guard.

## M11 — New series with fixed ceilings (cheap, high value)

All three landed as ONE generic pair of views keyed by a `series` name --
`CAPD_SERIES_DAILY (dbid, con_dbid, series, day_dt, value, limit_value, unit,
n_samples)` in the new `ddl/25_series_daily.sql` and `CAPF_SERIES_FORECAST` in
the new `ddl/35_series_forecast.sql` -- so a fourth series costs a UNION ALL
branch and nothing else. Shared plumbing: new knob `series_sat_pct` (90), new
alert kinds `SERIES_LIMIT` / `SERIES_NEARLIMIT`, new `CAPR_SERIES` report view,
new report section 7 (text + HTML), new fixture tables
`CAP_FIXTURE_RESOURCE_LIMIT` / `CAP_FIXTURE_SYSSTAT`.

- [x] **M11.1 Processes / sessions.** Done: `CAPV_RESOURCE_LIMIT` in all three
      seams over `DBA_HIST_RESOURCE_LIMIT` filtered to `processes`/`sessions`
      (verified on 19c: that view DOES carry `CON_DBID`; `LIMIT_VALUE` is a
      `VARCHAR2(10)` that can read `UNLIMITED`, converted to NUMBER in the seam,
      non-numeric → NULL = no ceiling). Daily value = the day's
      `MAX(max_utilization)` per instance, SUMMED across instances, against the
      summed per-instance limits (NULL if any instance is UNLIMITED).
      `days_to_limit = FLOOR((limit·series_sat_pct/100 − cur)/slope)`, with the
      M9.1 lo/hi range. Fixture `SESSIONS` 200+2·i of 500 → 5 days → a
      `SERIES_LIMIT` CRIT; `PROCESSES` constant 150 of 300 → FLAT, silent.
      **Warehouse TODO:** the sibling `awr-fleet-warehouse` has no
      `awrw_resource_limit` fact / `awrv_resource_limit` view yet, so
      `ddl/11_seam_warehouse.sql` emits the column contract with `WHERE 1 = 0`
      (zero rows, everything downstream stays valid). Add the collector pull +
      fact + AWRV view there, then swap the stub for a pass-through.
- [x] **M11.2 Redo GB/day.** Done: `CAPV_SYSSTAT` (local: `DBA_HIST_SYSSTAT`
      filtered to `redo size`; warehouse: `awrv_sysstat`, which the collector
      already gathers whole, with `con_dbid := dbid` — right for redo, one
      stream per database). Same diff-and-restart-guard as `CAPD_CPU_DAILY`,
      summed per day, /2^30. No ceiling, so `days_to_limit` is NULL and it can
      never alert — it is a trend for FRA / archive sizing. Fixture: +1 GiB per
      12 h interval, reset at the same restart as the CPU counters → exactly
      2.0 GiB/day, restart day dropped.
- [x] **M11.3 Total DB size.** Done: `SUM(used_bytes)` vs `SUM(limit_bytes)`
      over `CAPD_TBSPC_DAILY` per (dbid, con_dbid, day) — so it needs no new
      seam, and it inherits that view's rules (UNDO/TEMPORARY excluded, M9.5
      overrides + exclusions applied). Fixture asserts the identity against a
      re-derived sum plus a positive, fittable slope.

## M12 — Optional ELK / Kibana path (done)

- [x] **M12.1 Export.** `elk/export_capacity.sql` emits one JSON document per
      line (observation / forecast / fit / anomaly / alert) from the CAPD_/
      CAPF_/CAPA_/CAPR_ views; `elk/export.sh` runs it on the DB host and
      validates every document against the strict mapping in
      `elk/elasticsearch/index-template.json` before Filebeat sees it.
- [x] **M12.2 Transport.** Filebeat input (`elk/filebeat/awrcap.yml`) and a
      Logstash branch (`elk/logstash/oracle_capacity.conf`) loaded beside
      `elk_db_automation`'s Oracle pipeline; deterministic `_id`s so a
      re-export overwrites. No Elasticsearch access from the DB host.
- [x] **M12.3 Dashboards.** Three generated Lens dashboards
      (`elk/kibana/build_*.py`, imported by `elk/setup.sh`): tablespaces,
      CPU + workload series, fleet anomalies. Anomalies as red bars/markers
      on every chart; alerts as a table on every board.
- [ ] **M12.4 Scheduling.** A daily `export.sh` run (cron or an external
      DBMS_SCHEDULER job) is still a manual step; so is keeping Filebeat up
      across reboots (by `elk_db_automation` design).

## M13 — Optional Grafana path straight from Oracle (ORDS) (done)

- [x] **M13.1 Point feeds.** `CAPR_SERIES_POINTS`, `CAPR_FIT`, `CAPR_ANOMALIES`
      (ddl/45) and `CAPR_FORECAST_POINTS` (ddl/55): one chartable shape per
      record type, shared by `elk/export_capacity.sql` and the ORDS module;
      asserted in `test/run_test.sql`.
- [x] **M13.2 ORDS module.** `grafana/ords/awrcap_module.sql` publishes six
      GET endpoints (`grafana/API.md`), no pagination, `from`/`to` bound
      explicitly; lab install with a dedicated installer user and ORDS in
      Docker in `grafana/ords/README.md`.
- [x] **M13.3 Dashboards.** Three generated Grafana boards
      (`grafana/build_*.py`, provisioned by `grafana/docker-compose.yml`
      with the Infinity plugin); anomalies as annotations, red points and
      shaded shift spans.
- [ ] **M13.4 Follow-ups.** Multi-value `db`/`series` filters server-side;
      a result cache or materialized views under the point feeds for large
      sites; ORDS privilege on the module for untrusted networks.

## M14 — Optional Oracle APEX application (done)

- [x] **M14.1 Generator.** `apex/build.py` (stdlib) emits `apex/awrcap_app.sql`,
      an APEX 26.2 export in the native import API with deterministic ids;
      one registry maps each CAPR point feed to an `AWRCAP_*` collection and
      to the CTE every region query starts from.
- [x] **M14.2 Pages.** Overview (alert counts, alert list, worst days to
      full, DB size, data freshness), Tablespaces, CPU and workload, Fleet
      anomalies; global filter bar (database, tablespace, date range, kind,
      severity) and a Refresh-data button; views loaded once per session.
- [x] **M14.3 Install.** `apex/install.sql` (workspace, schema, app id
      arguments, refuses a foreign app id), `apex/workspace.sql` (workspace
      + ADMIN + viewer accounts, passwords prompted), `apex/publish.sh` (lab),
      `apex/test/apex_smoke.sql` (every region query inside a scripted APEX
      session).
- [ ] **M14.4 Follow-ups.** Collections hold whole views (fine for one
      database); multi-select filters. The results layer and alert
      acknowledgement now exist (M19.3) but the app does not read
      `CAPR_ALERTS_LATEST` or call `cap_results.ack` yet.

## M15 — Anomaly baseline modes (done)

Every anomaly series is scored against each baseline MODE of its grain, as rows
of one engine: TRAILING (the last `mad_window_days`) and SAME_DOW (the same
weekday, `dow_weeks` back) per day, HOUR_OF_WEEK (the same weekday and hour)
per CPU hour. A mode is a reference-set selector, nothing more; the floor,
z-score and flag rule are shared.

- [x] **M15.1 Engine + registry.** `CAPA_OBS` (ddl/40) is the registry of what
      is scored and how: kind, series, grain, unit, scored value vs raw value,
      gap and `is_complete` flags, the per-(unit, grain) threshold floor and
      the family's alert bitmask. `CAPA_ANOM` scores every observation against
      every mode of its grain (key `dbid, con_dbid, kind, series,
      baseline_mode, ts`; `2 x DAY obs + HOUR obs` rows); `CAPA_ANOM_DAY` rolls
      the day modes up to one row per observation. `CAPA_TBSPC_ANOM` and
      `CAPA_CPU_ANOM` are deleted. Knobs: `trailing_min_hist` /
      `weekly_min_hist` replace `tbspc_min_hist` / `cpu_min_dow_hist` (value
      carried over), new `cpu_min_mad_pct_hour`, `hour_gap_ratio`,
      `series_floor_count`, `series_floor_gib` and the bitmasks
      `alert_modes_tbspc` / `_cpu` / `_series` (1 = TRAILING, 2 = SAME_DOW,
      4 = HOUR_OF_WEEK), all in `CAP_CFG` and `CAP_CFG_CHECK`.
- [x] **M15.2 Hourly source.** `CAPD_CPU_INTERVAL` / `CAPD_DBTIME_INTERVAL`
      (one row per valid snapshot interval; the daily CPU views are GROUP BYs
      over them, byte-identical) and `CAPD_CPU_HOURLY` (host `BUSY_PCT` and
      per-container `DB_CPU_PCT` per END-hour bucket, 5 min flush grace;
      `gap_flag` from `hour_gap_ratio`).
- [x] **M15.3 More series scored.** Per-container `DB_CPU_PCT`
      (`DBCPU_BUSY` / `DBCPU_ANOM`) and the M11 series: `PROCESSES`,
      `SESSIONS`, `REDO_GB_DAY` on their level, `DB_SIZE_GB` on its daily
      growth (`SERIES_LEVEL` / `SERIES_GROWTH` / `SERIES_ANOM`).
      `CAPD_SERIES_DAILY` gains `day_gap`, `max_interval_hours`, `gap_flag`
      (REDO over `cpu_gap_hours`; DB_SIZE_GB when the tablespace set changed).
- [x] **M15.4 Consumer migration.** `CAPR_ANOMALIES` owns severity, message
      and `alerting` and gains `baseline_mode`, `grain`, `n_hist`,
      `alert_kind`, `raw_value`, `doc_key`; `CAPR_ALERTS` takes its anomaly
      rows from it in one branch (+ `baseline_mode`, `alert_key`; an
      HOUR_OF_WEEK day carries its worst hour). `CAPR_TBSPC_ANOMALIES` /
      `CAPR_CPU_ANOMALIES` carry the mode (`busy_pct` renamed `value_pct`);
      new `CAPR_SERIES_ANOMALIES` (section 7b) and `CAPR_HOURLY_POINTS`;
      `CAPR_SERIES_POINTS` stays 1:1 through `CAPA_ANOM_DAY` (headline mode)
      and gains `anomaly_modes`, `how_hours_flagged`, `doc_key`. The text and
      HTML reports and both drill scripts show the mode.
- [x] **M15.5 ELK / ORDS / Grafana.** Strict-mapping fields for
      `baseline_mode`, `grain`, `n_hist`, `raw_value`, `anomaly_modes`,
      `alerting`, `hours_flagged`; anomaly and alert doc ids keyed on the
      mode; an hourly ORDS endpoint over `CAPR_HOURLY_POINTS`; a mode filter
      on the fleet anomaly boards. Timestamps are the DB wall clock labelled
      `Z`; the dashboards run in UTC.
- [x] **M15.6 Tests.** The fixture gains `INVERTED_WED` (40% / 40%: invisible
      to the day modes, HOUR_OF_WEEK 06:00 HIGH and 18:00 LOW). Every
      `run_test.sql` anomaly lookup names the full key (`anom_flag` /
      `anom_n`); new mode closed forms, key-uniqueness checks and knob
      flips. `test/lint_anom_joins.sh` rejects any
      `CAPA_ANOM` read outside ddl/40, ddl/45, test/, bench/ and the drill
      scripts; `test/dbmint_harness.sh` runs it first. Parity gate before the
      legacy views were deleted: `CAPA_TBSPC_ANOM` vs TRAILING (1068 rows) and
      `CAPA_CPU_ANOM` vs SAME_DOW `BUSY_PCT` (112 rows), zero differences
      apart from rows the legacy views omitted (`n_hist` 0) and `robust_z` on
      flat tablespace baselines (finite now).
- [ ] **M15.7 Follow-ups.** Hourly observation docs are not exported to ELK
      (`CAPR_HOURLY_POINTS` is ORDS-only). Repository mode has no per-target
      timezone, so a fleet spanning timezones compares wall clocks. Done
      since: shift suppression and episode collapsing in `CAPR_ALERTS`
      (M19.3), `docs/demo/` regenerated (M21.4).

## M16 — Config access and install hygiene (done)

The 2026-10-17 review program (M16–M21) implemented every finding of a
whole-repo review, one unit per commit, each verified on 19c with the
fixture harness and both reports.

- [x] **M16.1 One config access path.** `CAP_CFG` (one row, one NUMBER
      column per knob, no defaults inlined) replaces the 14 pasted `cfg`
      CTEs in ddl/20..55, the report drivers and the drill scripts.
      `CAP_CONFIG.cfg_default`; the seed MERGE inserts missing keys and
      refreshes only `cfg_default` / `cfg_desc`; reset is `UPDATE ... SET
      cfg_value = cfg_default`. `CAP_CFG_CHECK` reports each knob OK /
      MISSING / BAD with its range rule. (8b57bc8)
- [x] **M16.2 Schema-aware install, uninstall and doctor.** `install.sql`
      prints the target schema, warns on SYS, recompiles INVALID `CAP*`
      objects in two passes and checks `ALL_OBJECTS` on `CURRENT_SCHEMA`;
      `WHENEVER SQLERROR EXIT FAILURE`. `suite_version` is the one MERGE row
      overwritten on every install. New `create_owner.sql` (dedicated owner
      with direct DBA_HIST_* grants). `doctor.sql`: all DBA_HIST_* views the
      seam reads, direct grants, `STATISTICS_LEVEL`, newest snapshot age, a
      readiness table, `CAP_CFG_CHECK`, `cap_doctor_mode` in and
      `cap_doctor_fail` out; `quickstart.sql` stops on a FAIL unless
      `force_install = Y`. Drivers create `reports/` before spooling.
      (abe891b)

## M17 — Seam and daily layer (done)

- [x] **M17.1 Per-container sources.** In CDB$ROOT the SYS_ time model and
      sysstat are CDB-wide, so `CAPV_TIME_MODEL` / `CAPV_SYSSTAT` read
      `DBA_HIST_CON_SYS_TIME_MODEL` / `DBA_HIST_CON_SYSSTAT` (PDB$SEED
      dropped, SYS_ fallback for a non-CDB). `CAPV_RESOURCE_LIMIT` documented
      as root-only. New `CAPV_CONTRACT` diagnostic in all three seams.
      (82e8a42)
- [x] **M17.2 One counter-delta view and the logical-CPU denominator.**
      `CAPD_COUNTER_DELTA` holds the LAG + restart rule once for OSSTAT, time
      model and sysstat. `db_cpu_pct` and its twins divide by `NUM_CPUS x
      ivl_sec` per interval (cores read 2x on SMT); the fixture host is
      NUM_CPUS 8 / cores 4. (82e8a42)
- [x] **M17.3 Day coverage.** `covered_sec` / `is_complete` on the CPU, DB
      time and series daily views (knob `complete_day_pct` 80); a fixture
      partial day. (82e8a42)

## M18 — Forecasts (done)

- [x] **M18.1 Anchored, clamped, current.** Projections are `cur_value +
      slope x h` with the OLS half-widths around that anchor (+30 and
      days_to_full agree); days_to_full clamps at 0 and `limit_below_used`
      flags a ceiling under usage; `newest_day` / `is_current` on every CAPF
      view (knob `stale_days` 3); CPU and REDO fit complete days only;
      Theil-Sen on demand; drill footers on `train_start`. Fixtures
      `FIX_OVERFULL`, `FIX_DROPPED`. (4eb8e9e)
- [x] **M18.2 CYCLIC, DRIFT, CPU gate, hot now.** `cyclic_min_cliffs` (2)
      grades a sawtooth tablespace CYCLIC, judged on its peaks; `slope_method
      = 2` (DRIFT) with random-walk bands; `cpu_quality_gate` and
      `cpu_deseason` (both on by default: a deliberate default change) with
      `slope_sig` / `deseasoned`; the CPU anchor is the median of the last
      `shift_days` complete days; `recent_p95_med` / `hot_now`. Fixtures
      `FIX_CYCLIC`, `FIX_CYCLIC_UP`, `FIXPDB2`. The demo SESSION_STORE false
      page is gone. (0e63b84)
- [x] **M18.3 Tier 2 that shows up and fails loudly.** The ESM row of
      `CAPF_COMPARE` is the model's furthest step (<= 30, `esm_horizon_days`)
      and counts while `model_age_days <= esm_max_age_days` (7); builds use
      a temp name and `RENAME_MODEL`, a failure keeps the old model and
      records FAILED / `last_error`, `train_*` raise ORA-20060 after the
      batch; `CAPF_ESM_HEALTH` / `_SUMMARY`; `train_all` refreshes the
      backtest twins (CPU too); `train_tablespace(name)`; AUTO ties within
      `esm_auto_tie_pct` keep HOLT; `CAP_ML_RETRAIN` daily by default.
      (6e4a045)

## M19 — Alerts and results layer (done)

- [x] **M19.1 How much more than usual.** Anomaly rows carry
      `pct_vs_median` / `pct_vs_avg` (and the trailing average rate for
      tablespaces); the alert messages say "+N% vs ..." next to the z-score.
      (08cdb95)
- [x] **M19.2 One alert surface.** `CAPR_ALERTS` (moved to ddl/55) gains
      `state_key`, `direction`, `alarm_threshold`, `is_current`;
      `CAPR_SEVERITY` computes every forecast severity once (section 1a GATE
      column); forecast kinds need `is_current = 'Y'`; TBSPC_FULL on the peak
      line of a CYCLIC tablespace; new kinds DATA_STALE (`stale_hours`),
      CPU_HOT / DBCPU_HOT and MODEL_HEALTH; per-tablespace thresholds in
      `CAP_TBSPC_OVERRIDE`; each fit view read once. (c96e6a5)
- [x] **M19.3 Results layer.** ddl/60: `CAP_RUN`, `CAP_FIT_HIST`,
      `CAP_ALERT_STATE`, `CAP_ALERT_EVENT` (persisted like `CAP_CONFIG`) and
      `cap_results` (refresh / ack / unack / purge / reset), the only writer;
      `CAPR_ALERTS_LATEST`, `CAPR_ALERT_EVENTS`, `CAPR_RUNS`,
      `CAPR_FIT_HISTORY`, `CAPR_WEEKLY_DIGEST`, `CAPR_FORECAST_ACCURACY`,
      `CAPR_COVERAGE`; anomaly episodes and shift suppression in
      `CAPR_ALERTS`; retired dbids (`data_stale_max_days`);
      `CAP_REFRESH_JOB`. Knobs `resolve_grace_runs`, `refresh_stale_hours`,
      `digest_days`. (d451151)

## M20 — Seam extensions (done)

- [x] **M20.1 Parameters and ASM.** `CAPV_PARAMETER` (nine init
      parameters as numbers, root rows) and `CAPV_ASM_DISKGROUP`; zero-row
      stubs in warehouse mode and when the demo fixture lacks the tables.
      `db_cpu_pct` divides by `LEAST(num_cpus, cpu_count)`. (10eee46)
- [x] **M20.2 New series.** `ASM_DG:+<group>`, `TEMP_PEAK:<ts>`,
      `UNDO_PEAK:<ts>` through the generic series model; FRA days on
      `REDO_GB_DAY`; the sizing ask `need_gib_30/90/180` and `add_by_day`.
      Fixtures `FIX_TEMP`, `FIX_UNDO`, `CAP_FIXTURE_PARAMETER`,
      `CAP_FIXTURE_ASM_DISKGROUP`. (10eee46)

## M21 — Consumers (done)

- [x] **M21.1 Scoped and snapshot reports.** Both drivers take `[dbid]
      [con_dbid] [LIVE|SNAPSHOT]` after the three presentation arguments,
      `-` skips one; SNAPSHOT reads the last refresh run. New
      `report/report_csv.sql` and `report/run_report.sh` (cron, exit codes).
      (55e496c)
- [x] **M21.2 Resilient HTML.** Every section in its own exception block;
      the hero reads the suite's `DB_SIZE_GB` fit, so it matches section 7.
      (55e496c)
- [x] **M21.3 Who is filling it, metrics, doctor.** `CAPV_SEG_STAT` +
      `CAPR_SEGMENT_GROWTH` (`seg_window_days`) in `drill_tbspc.sql`; the ORDS
      `metrics` handler (Prometheus text); doctor prints the results layer
      and the live `CAPV_CONTRACT` check. `suite_version` 16. (55e496c)
- [x] **M21.4 Docs.** README, CLAUDE.md, PLAN.md and the docs site describe
      M16–M21; `docs/demo/` regenerated from `test/demo_fixture.sql`;
      `test/docs_lint.sh` checks the knob table, the object index and the
      alert kinds against the DDL, and rejects assertion counts and
      "generated" claims. (branch rf/u10-docs)
- [ ] **M21.5 Follow-ups.** (`suite_version` bumped to 22 by M22.) Tier 2 still trains on
      incomplete days (`is_complete` not applied in ml/ or `CAPF_ESM_HEALTH`).
      Done since: `CAPF_BACKTEST` CPU rows use complete days only and anchor at
      the median of the last `shift_days` training days like the live fit
      (new `anchor_val` column, cutoff still from all days so it matches the
      twins), and `CAPF_ESM_CANDIDATE` scores CPU holdout actuals on complete
      days. Left: the ml/ training input and the `CAPF_ESM_HEALTH` last_day
      (a complete-only filter there would give negative ages while the twins
      train through an incomplete last day).
      `test/fixture_remove.sql` does not drop `CAP_FIXTURE_SEG_STAT`.
      `CAP_TBSPC_OVERRIDE` does not apply to the TEMP / UNDO peak series;
      PDB-level `cpu_count` is unused. ELK forecast doc ids hash
      `horizon_days`, which moves as an ESM model ages; ORDS / ELK do not
      select the new `CAPR_ALERTS` columns (`state_key`, `direction`,
      `alarm_threshold`, `is_current`). `CAPR_ALERTS` costs seconds per query
      on the fixture and the live demo reports take minutes: snapshot
      `CAPR_COVERAGE` per run, and consider a run_test snapshot of
      `CAPR_ALERTS`. The warehouse collector should gather the CON_ views,
      parameters, ASM and segment facts (sibling repo).

- [x] **M21.6 RAC worst instance.** `PROCESSES` / `SESSIONS` still sum across
      instances (one fleet row per series, no `instance_number` downstream),
      but `CAPD_SERIES_DAILY` / `CAPF_SERIES_FORECAST` / `CAPR_SERIES` now
      carry `worst_inst_pct` / `worst_inst`, and `SERIES_NEARLIMIT` judges
      the larger of the fleet and the worst-instance percent (message names
      the instance). Fixture: `run_test.sql` adds a two-instance dbid
      (43434343, snapshot + resource-limit rows only) for one block and
      deletes it again, so no other assertion sees it.
- [x] **M22 Review fixes (2026-10 implementation review).** Five findings,
      one phase each, merged on `fix/review-2026-10`: `report/run_report.sh`
      fails on a non-zero SQL*Plus exit or any ORA- / SP2- line
      (`test/run_report_sh_test.sh`, run by the harness); `CAPA_CPU_SHIFT`
      drops incomplete days and carries `newest_day` / `is_current`, so a
      stopped series no longer holds a CPU_SHIFT alert open; `CAPF_BACKTEST`
      CPU rows use production's inputs (M21.5); `cap_results.refresh` takes
      its serialising lock before allocating `run_id` (M10 results layer);
      RAC worst-instance percent for `PROCESSES` / `SESSIONS` (M21.6).
      `suite_version` 22. Left: a CPU series that really stops in the fixture
      (the stale `is_current = 'N'` case is tested by flipping `stale_days`),
      a live two-session proof of the `refresh` lock, a permanent RAC fixture
      dbid.
- [x] **M23 HTML report by metric.** `report/report_html.sql` rebuilt around
      the metrics instead of the analytic sections: one section per family
      (tablespaces, database size, host CPU, DB CPU, sessions, processes, redo,
      undo, temp, ASM), one card per series with status, key numbers and a
      chart even when nothing is wrong, an hourly heat strip on CPU cards, an
      overview index plus the alert list. The SQL writes the point-feed
      views into a JSON block; `report/html/report.js` draws it (sources
      `report.css` / `report.js`, generated `page_head.sql` / `page_tail.sql`
      via `report/html/build.py`). `test/report_html_test.sh` (harness lint
      stage). The text report is unchanged. Left: the ESM-vs-REGR backtest
      table and the level-shift table are no longer in the HTML (text report,
      CSV); the page needs JavaScript.

## M24 — Fleet deployment: standalone, or target + repository

Two ways to deploy from this one repo:

- **Standalone** (`deploy_mode=local`, unchanged): the suite on the measured
  database, reading its own AWR.
- **Target + repository** (`deploy_mode=repository`): a target gets no
  suite, only a read-only common user `C##AWRRDR` in `CDB$ROOT`. The
  repository database pulls the 17 `DBA_HIST_*` views ddl/10 reads over one
  DB link per target into persisted copies, and runs the whole suite (jobs,
  ML, reports, APEX / ORDS / ELK) over every registered target. Nothing is
  ever written on a target.

Decided 2026-11-07:

- **Copy, not federate.** Live `@link` views would cap history at the
  target's AWR retention (8 days by default) and run the deep view stack
  (1.1 to 1.4 GB of PGA a session) across links. Copies let the repository
  keep `repo_retention_days` of history while targets keep their default
  retention, and they move the forecasting load off production.
- **Pull, not push.** The repository connects to each target's listener.
  A target-side exporter is out of scope.
- **Own slim collector, not `../awr-fleet-warehouse`.** The warehouse would
  need root-safe keys and six more sources first, collects sqlstat / wait
  volume capacity never reads, and means two repos to install. Port its
  proven patterns: a high-water mark per (target, dbid) under
  `FOR UPDATE NOWAIT`, 500-snapshot chunks committed atomically, DBID
  discovery, a DBID already owned by another target refused and logged
  (clones restored without NID), per-target health.
- **Copies are DBA_HIST-shaped.** `CAP_H_<view>` keeps the columns ddl/10
  reads, keyed with `con_dbid` wherever the source has it. Measured on
  dbmint 2026-11-07: from the root, seg_stat, seg_stat_obj, parameter and
  the CON_ time model / sysstat span every container, and the warehouse's
  DBID-only keys collided there (seg_stat 1624, seg_stat_obj 101 duplicate
  key groups; ORA-00001 on a root pull). `ddl/13_seam_repository.sql` is
  generated from ddl/10 by renaming `dba_hist_x` to `cap_h_x`, so both seams
  share one body: a missing copy column fails the install compile, and the
  M24.5 diff proves the semantics.
- **Target floor 19c** for v1, the only release tested.
- **Warehouse mode retires** once parity passes (M24.9): one fleet path.

- [x] **M24.0 Rename `seam_mode` to `deploy_mode`.** The install define, the
      `CAP_RUN` column (renamed in place by ddl/60, history kept),
      `cap_results.deploy_mode`, doctor, docs. Old `DEFINE seam_mode` scripts
      now get prompted for `deploy_mode`.
- [x] **M24.1 Vocabulary and install.sh.** Roles: standalone, target,
      repository. The wizard's first question becomes the role. Rename the
      install.sh key `TARGET=self|schema` to `INTO` (target now means a
      measured database). Check: `--dry-run` of every shipped profile emits
      the same driver as before the rename. Done 2026-11-07, drivers
      byte-identical; also fixed the profile loader, which cut every value at
      `#` (`C##AWRRDR` loaded as `C`). Profiles `target.env`, `repository.env`.
- [x] **M24.2 Source manifest and generator.** One manifest lists the 17
      views: key columns, incremental column (`snap_id`, or none for the
      dimensions TABLESPACE / DATAFILE / DATABASE_INSTANCE / PDB_INSTANCE /
      SEG_STAT_OBJ) and copied columns. A generator (Python, like
      `report/html/build.py`) writes the `CAP_H_*` DDL, the collector's pull
      statements, the target grant list and ddl/13. A test lint fails when
      regenerating changes anything. The golden rule "DBA_HIST_* only in
      ddl/10" widens to ddl/10 plus the generated collector; settle the file
      layout here (generated copies + seam, hand-written registry + package
      included before ddl/13 in repository mode). Check: ddl/13 compiles over
      empty copies in a scratch schema. Done: `repository/build.py` writes
      ddl/13 (copies + `CAP_REPO_SOURCE` + seam), which ends by including the
      hand-written `repository/cap_repo.sql`; `--check` runs in both dbmint
      scripts.
- [x] **M24.3 Target scripts.** `target/prepare.sql` (SYSDBA in `CDB$ROOT`):
      `C##AWRRDR`, CREATE SESSION, direct SELECT on the manifest's views,
      `CONTAINER_DATA=ALL`; it prints AWR retention / interval advice and
      changes nothing else. `target/check.sql`: pack access, retention
      longer than the collect gap, grants, container visibility. Check on
      dbmint: as `C##AWRRDR`, every per-container view shows the same
      `con_dbid` count as under SYSDBA (`ddl/11_seam_warehouse.sql` notes a
      least-privilege root reader saw the root only). Done: without
      `CONTAINER_DATA` the reader saw 1 container of 3, with it 3. The same
      gap hit standalone owners (the filter follows the querying session, so
      the owner's jobs saw the root only); `create_owner.sql` now sets it.
- [x] **M24.4 Registry and collector.** Persisted tables `CAP_TARGET`,
      `CAP_TARGET_DBID`, `CAP_HWM`, `CAP_COLLECT_LOG` and every `CAP_H_*`:
      created idempotently, never in `00_drop`, dropped only by
      `uninstall.sql` (a copy cannot be re-pulled once the target's AWR has
      aged out). Package `cap_repo`: `add_target(name, connect, user,
      password)` (NULL password = wallet; creates the link, probes it,
      discovers DBIDs), `remove_target(name, purge)`, `set_enabled`,
      `collect(name)`, `collect_all`. Facts append past the high-water mark;
      dimensions MERGE on their natural key. Check over a dbmint loopback
      link: a second collect adds 0 rows, a collect killed mid-chunk
      converges on rerun, and per-view row counts equal the source over the
      collected range. Done on dbmint (CAPX2 over a loopback link to cdb1's
      root): a wrong password fails with ORA-01017 and leaves no link; the
      backfill copied 154k rows of 1166 snapshots in under 2 s; a second
      collect copies nothing; remove_target deletes copies and link. The
      windows start at the high-water mark, not the oldest snapshot: AWR
      keeps CON_SYSSTAT rows of already-purged snapshots. A review then added:
      remove_target locks the DBID rows (no chunk lands after its delete),
      `set_link_password` (reader rotation, copies kept; tested), uninstall
      drops owned links through a throwaway definer's-rights procedure
      (tested), equality joins in the MERGEs, a ddl/10 fallback matched per
      statistic and a `build.py` check that the copy filters keep every
      literal ddl/10 filters on.
- [x] **M24.5 Parity, the ship gate.** Local and repository installs over
      the same CDB root, collected to the same snap_id; diff every view: zero
      rows. Done 2026-11-07 as `test/dbmint_parity.sh CAPX2 C##CAPLOC`
      (`test/parity_fingerprint.sql`: row count + order-free hash per view):
      all 12 `CAPV_*` views equal at the repository's high-water mark and all
      51 `CAPD/CAPF/CAPA/CAPR` views equal (clock columns skipped, both
      schemas reset first), 5.5 min end to end. A collect whose first chunk
      failed (a grant revoked mid-way) rolled back whole, and the rerun
      converged to the same fingerprints.
- [x] **M24.6 Fleet identity.** In repository mode the report header comes
      from `CAP_TARGET` instead of `SYS_CONTEXT` (`report/report.sql`,
      `report/report_html.sql`); the target name rides on `CAPV_CONTAINER`;
      `CAPR_TARGETS` shows link, DBIDs, newest snapshot, lag and last error;
      `run_report.sh --target NAME`; a failing collect surfaces as an alert
      (DATA_STALE or a new kind). Check: two registered targets (dbmint, plus
      the 23cfree docker if it takes AWR snapshots).
      Done 2026-11-07, as a 13th seam view `CAPV_TARGET` (every mode; the
      repository one in `repository/seam_overrides.sql`) rather than columns
      on `CAPV_CONTAINER`: `CAPR_CONTAINER.target_name` and `db_pdb`,
      `CAPR_TARGETS` (`collect_state` OK / FAILING / NEVER / DISABLED),
      `report/scope.sql` for all four drivers (header, file stem, a target
      name as the dbid argument), DATA_STALE naming the target and its last
      collect error, silent for a disabled target (no new alert kind). The
      23cfree docker shares its instance with another project, so the second
      target is synthetic (`test/repo_synth_target.sql`, CDB1's copies
      cloned 3 days back): fleet header "2 targets: CDB1, SYNTH", stems
      `fleet` / `SYNTH`, `--target nope` = ORA-20003 + exit 1, FAILING with
      ORA-02019 in DATA_STALE. Found on the way: `run_report.sh` failed any
      report whose alert message quoted an ORA- (DATA_STALE, and MODEL_HEALTH
      before it); it now counts only lines that start with ORA- / SP2-.
      Parity unchanged (identity views skipped), fixture harness passes.
- [x] **M24.7 Jobs, retention, doctor.** `CAP_COLLECT_JOB` (hourly) in
      repository mode; refresh and retrain keep their fixed times. Knob
      `repo_retention_days` (`CAP_CFG_CHECK`: at least the longest training
      window) and a purge. doctor in repository mode reports per target:
      link, lag, days collected against what each feature needs.
      Done 2026-11-07: `install_jobs.sql` adds `CAP_COLLECT_JOB` (hourly
      :05) and `CAP_PURGE_JOB` (daily 01:00) when `CAP_REPO` exists;
      `repo_retention_days` 400 (0 = keep all; BAD below the longest
      feature need, 120 at the defaults: ESM's 4 x 30); `cap_repo.purge`
      deletes fact copies below each dbid's first kept snapshot (orphans
      too) and old log rows in one transaction, refuses a knob that is not
      OK; `cap_repo.ping` probes a link as the owner, so doctor section 11
      can report link, collect state, staleness, gaps and days against each
      feature's need per target. suite_version 24. On dbmint: purge(8)
      deleted 262k rows in 3.3 s, every fact copy cut exactly at its dbid's
      boundary, dimensions kept; the collect job ran as the owner (FAILED
      on the synthetic target, as it should); doctor's local output
      unchanged.
- [x] **M24.8 Profiles and docs.** `profiles/standalone.env` (today's
      production), `target.env`, `repository.env`; docs "Measure one
      database" and "Measure a fleet" as equal paths; CLAUDE.md layout and
      persisted-table list; `test/docs_lint.sh`.
      Done 2026-11-08: `production.env` renamed `standalone.env` (dry-run
      drivers identical); Getting started offers both paths side by side
      (the fleet one in five steps: prepare, install, register + collect,
      jobs, report); reference.html gained `#installer` (every profile) and
      `#repository` (install by hand, the `cap_repo` calls by task, fleet
      health, gaps, space: 0.25 MB of copied rows a day for dbmint's
      three-container CDB), repository rows in the modes, prerequisites,
      privileges and persisted-tables tables; README, concepts, index,
      tutorial and design.md (a deployment section with the M24 rationale)
      follow. A repository install's closing banner names
      `cap_repo.add_target` / `collect` as the next step (other modes
      byte-identical, checked on dbmint). `docs_lint.sh` checks 6 (every
      persisted table in reference.html#tables and the CLAUDE.md bullet) and
      7 (every profile in reference.html and the install.sh help).
- [x] **M24.9 Retire warehouse mode.** Delete `ddl/11_seam_warehouse.sql`,
      `profiles/warehouse.env`, the warehouse branches of install.sql /
      install.sh / doctor, and the warehouse sections of the docs and
      CLAUDE.md. `../awr-fleet-warehouse` stays its own product.
      Done 2026-11-08: deploy modes are local / repository / fixture.
      `deploy_mode = warehouse` aborts before any DDL, `ROLE=warehouse`
      and `--profile warehouse` exit 2, and doctor says an unknown
      `cap_doctor_mode` is ignored before it reports the installed mode.
      `cap_results.deploy_mode` lost its AWRV_ branch. Comments that cited
      the warehouse keep their fact (the ORA-07445 typed-constant stubs now
      live in ddl/12). Docs: the #warehouse section, the modes / profile
      rows and the fourth source in the concepts diagram are gone; the
      design.md Milestone W entry stays as history. `docs_lint.sh` check 8
      fails on a warehouse-mode token in any tracked file but PLAN.md and
      bench/. Checked: all six profiles' `--dry-run` drivers byte-identical
      to HEAD; on dbmint install.sh re-installed CAPX2 (repository) and
      C##CAPLOC (local) with 0 INVALID, doctor 0 FAIL, and the fixture
      harness on CAPX1 passed with 0 failed.
- [x] **M24.10 Scale.** Load K synthetic DBIDs into the copies (the demo
      fixture, shifted), time `cap_results.refresh`, both reports and the ML
      retrain, and record peak PGA. Persist per-run results for the site
      only if the views are too slow.
      Done 2026-11-08 with real AWR instead of the demo fixture:
      `test/repo_synth_target.sql` takes DAYS and a source schema and stacks
      a collected target's copies back in 37-day blocks (snap_ids 100000
      apart, each boundary a restart), and `test/dbmint_scale.sh SCHEMA K`
      grows or shrinks the fleet to K targets and times each nightly step in
      its own session with `pga_probe.sql`. Targets of 144 days, 4,880
      snapshots, three containers, ~32 MB of copies each (CAPX3, cloned from
      CAPX2, which now holds cdb1's full 35 days). 2-vCPU VM, seconds at
      1 / 4 / 8 targets: refresh 62 / 279 / 558, report.sql 179 / 741 /
      1587, report_html.sql 122 / 542 / 1188, SNAPSHOT 452 / 993 and 318 /
      656 at 4 / 8, train_all 86 / 191 at 4 / 8. Linear, ~7 min of nightly
      work per target, and peak PGA 490-640 MB at every K, so the views stay
      live and no results table is added. Found and fixed on the way:
      `train_all` was quadratic (2116 s at 4 targets): OML runs its data
      query inside its own INSERT, where `CAPD_DBTIME_DAILY` got a plan that
      re-read the fleet per series (114 s, 33M gets, against 0.66 s alone).
      `build_model` now stages each series in the GTT `CAP_ML_INPUT`. And
      `add_by_day` overflowed the DATE range (ORA-01841, failing
      `cap_results.refresh`) on a near-zero slope; every `days_to_*` now reads
      NULL past 9999-12-31. Found here, fixed in M24.11 and M24.12:
      target-scoped reports and job spacing. Docs:
      reference.html#fleet-size.
- [x] **M24.11 A target's report at a target's cost.** `--target` cost a
      whole fleet report (152 s at one target, 723 s at four). Ranking per
      dbid would not have fixed it: on 19.27 plans 35 of 64 views read the
      copies unscoped under `WHERE dbid =`, because no predicate above the
      seam passes the fleet-wide ROW_NUMBERs, the `kind_last_day` windows and
      the materialized CTEs. Done: the scope lives at the seam.
      `report/scope.sql` sets CLIENT_INFO `AWRCAP dbid=<n>`, the one-row view
      `CAP_SCOPE` (ddl/05) parses it, and every seam source read (ddl/10,
      ddl/12, the generated ddl/13 and the CAPV_TARGET override) filters
      `dbid = NVL(<that expression>, dbid)`: both join sides, each UNION
      branch, each NOT EXISTS. The expression is inline, not `(SELECT
      scope_dbid FROM cap_scope)`, whose FAST DUAL subplans added 16% plan
      lines and 20 MB parse PGA. Each driver clears the scope at its end;
      `cap_results.refresh` and the `cap_forecast_ml` trainers clear one
      they find (a writer reads every database). At 8 targets: report.sql
      for one target 159 s, report_html.sql 134 s (152 / 121 with one
      target); the unscoped fleet reports stay at 1602 / 1204 s (1587 /
      1188 before). `test/scope_plan.sql` EXPLAINs every view (66, no unscoped
      seam read); run_test.sql asserts the scope, its clearing and the
      EXPLAIN check over the CAPV views. Docs: reference.html#fleet-size,
      #labels.
- [x] **M24.12 Job spacing for a fleet.** The refresh at 01:30 and the
      retrain at 02:00 ran at once past ~25 targets (two sessions' PGA).
      Done: one job. `CAP_NIGHTLY_JOB` (daily 01:00, created disabled) runs
      procedure `cap_nightly(p_steps, p_dir)`, the steps PURGE (repository)
      → RETRAIN → REFRESH → SPOOL in one session. A failed step is rolled
      back and logged to DBMS_OUTPUT (the run's OUTPUT), the later steps
      still run, and ORA-20080 at the end names the failed ones (ORA-20081:
      an unknown step). doctor section 10 WARNs per FAILED step of the last
      run. Re-running install_jobs.sql drops the four jobs it replaced;
      `CAP_COLLECT_JOB` stays hourly. install.sh's `NIGHTLY_INTERVAL`
      replaces REFRESH_INTERVAL / RETRAIN_INTERVAL. Rejected: job
      incompatibilities (they keep jobs apart but start the waiting ones in
      no fixed order, and resolve unqualified names in the session user's
      schema, 19.27) and chains (Rules Engine privileges). At 8 targets:
      PURGE 1 s, RETRAIN 199 s, REFRESH 607 s, 808 s in all, peak PGA
      638 MB. Docs: reference.html#fleet-size, design.md.
- [x] **M24.13 Per-target ranks and SNAPSHOT from stored tables.** No
      report ranks one target against another: every window in ddl/20..55
      partitions by dbid (`rank_dtf` / `rank_nearfull` / `rank_shift` /
      `rank_series` / `rank_report` / `rank_chart`, `CAPA_ANOM.kind_last_day`)
      and `days_ago` counts from the row's own database, so a fleet report
      lists the top `top_n` of each database, grouped by dbid, and a scoped
      report equals the unscoped one filtered. `test/lint_dbid_windows.sh`
      keeps it. SNAPSHOT: every view the four drivers read is listed once in
      `cap_results.snap_views` and kept as table `<view>_S` (`snap_run_id`
      + the view's columns); `refresh` replaces their rows in its
      transaction and reads them for CAP_FIT_HIST, the alert merge and the
      coverage, so each view is evaluated once per run. The drivers read
      `capr_x&cap_s` (`_s` under SNAPSHOT, empty under LIVE; `~cap_s` in the
      briefing), one query for both sources; the SNAPSHOT alert list stays
      `CAPR_ALERTS_LATEST`, which gained the episode columns. New
      `CAPR_DATA_WINDOW` gives the HTML chart window without the daily views.
      Every install re-creates the tables (`build_snap_tables`), so they are
      a cache, not persisted. `test/lint_snapshot_reads.sh` keeps the drivers
      on the registry; `test/snapshot_parity.sh` diffs LIVE and SNAPSHOT
      output and checks the plans of a SNAPSHOT run. Measured at 8 targets
      (CAPX3): SNAPSHOT report.sql / report_html.sql 1 s and ~10 MB PGA,
      fleet or one target (993 / 656 s before); scoped SNAPSHOT equals scoped
      LIVE line for line. The cost moved into the refresh: 2547 s (558 s
      before), peak PGA 911 MB. ASH by ACTION: CAPR_FORECAST_POINTS 622 s, then
      CAPR_COVERAGE, CAPR_FIT and CAPR_ALERTS ~400 s each (evaluated before
      too), points / trend / forecast views ~300 s each. Next lever: persist
      the CAPD daily layer once per refresh, which every one of them
      re-derives from the copies.

## M25 — One architecture: every database is a target

Every install is a repository, and every measured database is a target read
over a DB link. That includes the database the repository lives in, which
it reads over a loopback link. `deploy_mode=local` retires and `fixture`
stays for the harness.

Decided 2026-11-09:

- **Why.** Local mode keeps only as much history as the database's own AWR
  retention: 8 days by default, while ESM needs 120 (M24.7), so local mode
  forces a retention change on production. Copies keep
  `repo_retention_days` (400), also when the repository reads its own
  database. Production runs one seam instead of two, one database grows
  into a fleet without a reinstall, and no suite object stays in CDB$ROOT.
- **Analytics lose nothing.** M24.5 diffed local against repository over
  the same root, and every CAPV and CAPD/CAPF/CAPA/CAPR view was equal.
  ddl/13 stays the local seam with each `dba_hist_x` renamed to `cap_h_x`.
- **Accepted costs.** A loopback link needs the listener and a stored reader
  password (or a wallet), and that password can expire (ORA-28001). A LIVE
  report sees the last hourly collect, not the last snapshot. A repository
  that is its own target stores its AWR twice (0.25 MB a day on dbmint).
  Creating the reader needs SYSDBA, so a plain user can no longer run the
  quickstart into their own schema.
- **The owner lives in a PDB by default:** `AWRCAP` in a PDB reads its
  CDB's root over the loopback link (the CAPX2 layout M24.5 proved), and
  `AWRCAP` in a non-CDB reads that database. With exactly one open user PDB
  the installer uses it; otherwise it asks for `CONTAINER`. A root owner
  (`C##AWRCAP`) stays possible, but nothing defaults to it.
- **An existing standalone install starts fresh (a breaking upgrade).** Its
  persisted tables live in the root schema, so the upgrade path is:
  uninstall it there, install anew in a PDB, collect. Lost: CAP_RUN,
  CAP_FIT_HIST, the alert state and its acks, CAP_ALERT_EVENT and
  CAP_ML_MODEL (retrain). The operator's CAP_CONFIG / CAP_TBSPC_OVERRIDE
  values carry over through a replay file that uninstall.sql writes
  (M25.6). The first collect copies everything the AWR still holds, so
  forecasts resume at once on the history the local install saw.
- **ddl/10 becomes the template.** install.sql no longer runs it. It moves
  to `repository/seam.sql` as build.py's input, so DBA_HIST_* appears only
  under repository/ and target/ (plus test/ and bench/).

- [x] **M25.0 Probe the unknowns on dbmint before changing anything.**
      (a) GLOBAL_NAMES: `ALTER SESSION SET global_names = TRUE`, then
      add_target / collect. ORA-02085 is expected, because link `CAP_<NAME>`
      does not match the target's global name. (b) The connect string from
      a PDB owner to its own root: as SYSDBA in CDB$ROOT, derive
      `//host:port/service` from `V$LISTENER_NETWORK` (local listener) and
      the root's default service. Check: over a link built from it, the
      dbid equals the CDB's and the reader sees every container (3 on
      cdb1).
      Done 2026-11-09: (a) ping over CAPX2's link under session
      `global_names = TRUE` returned "ORA-02085: database link
      CAP_CDB1.WORLD connects to CDB1.WORLD"; a SYS link named
      `CDB1.WORLD@M25PROBE` answered under it, quoted and unquoted
      (`dual@CDB1@M25PROBE`), and was dropped again. So M25.3 was needed.
      (b) The derivation gives `//localhost:1521/cdb1.world` on cdb1
      (listener port 1521, root service `cdb1.world`, DB_UNIQUE_NAME cdb1,
      db_domain world); the M25.2 links built from it see CDB$ROOT,
      PDB$SEED and PDB1.
- [x] **M25.1 A copy check replaces the parity lever.** With no local
      install left, nothing remains to diff the repository against, so
      prove the copies instead. build.py generates
      `test/repo_copy_check.sql` from the manifest: per source and DBID,
      `source@link` under the manifest's filter MINUS the copy, and the
      reverse, over the collected snap_id window. Dimensions are compared
      whole, SEG_STAT_OBJ over the copied chunks, and the check exits 5 when
      a snapshot lands mid-check, as dbmint_parity.sh does. ddl/13 is
      generated from the same text (`--check`), so equal copies give equal
      views. Check on CAPX2, while the M24.5 lever still runs: 0 rows, and a
      copy row deleted by hand shows up as one row.
      Done 2026-11-09: the check runs in a throwaway definer's-rights
      procedure (CAP_COPY_CHECK, dropped at the end), and
      `test/dbmint_copy_check.sh SCHEMA [TARGET] [--collect] [--plant SRC]`
      runs it. On CAPX2: 17 sources, 163,401 rows equal in 2.8 s. A
      dimension copy keeps rows the target has purged (the DATABASE_INSTANCE
      row of an aged-out startup), so there only a source row missing from
      the copy is a difference; copy-only rows are listed as kept.
      `--plant OSSTAT` deleted one copy row, uncommitted: reported as
      exactly that row (src 7398, copy 7397), then rolled back. The M24.5
      lever's seam pass agreed at the same snap_id (12 CAPV views equal at
      4019), but its local install no longer runs in CDB$ROOT: since M24.13
      `build_snap_tables` raises ORA-00600 [KGL-heap-size-exceeded] there
      (C##CAPLOC kept its seam and packages VALID, snapshot tables partly
      built). So CDB1 was re-registered in CAPX2 by hand, as the lever does,
      and the seams compared with `--no-install`.
- [x] **M25.2 "Measure one database" in one run.** install.sh role
      `standalone` (and quickstart.sql / .sh) runs as SYSDBA in CDB$ROOT,
      in this order: target/prepare.sql (the reader gets a random password,
      never printed); target/check.sql as the gate; pick the PDB (the one
      open user PDB, else `CONTAINER`; a non-CDB uses itself); in that PDB,
      create_owner and install; `cap_repo.add_target` over the loopback to
      the root (M25.0b, overridable with `SELF_CONNECT`); collect; then ML,
      jobs and reports as before. quickstart stops installing into SYS: it
      creates the schema-only owner `AWRCAP` (NO AUTHENTICATION) and works
      under `CURRENT_SCHEMA`. A re-run reuses the reader, the owner and the
      target, resets the reader's password and updates the link with
      `set_link_password`. Check: `--dry-run` of every profile; on dbmint a
      fresh standalone into a throwaway PDB1 owner and `quickstart.sh` both
      end with a report and 0 FAIL, twice in a row; with two open PDBs and
      no `CONTAINER`, both stop before any change.
      Done 2026-11-09: two scripts carry it. `target/self.sql` (root side)
      refuses a non-SYSDBA session, a PDB session and an ambiguous PDB
      before it changes anything, derives the target name (DB_UNIQUE_NAME),
      the loopback address and the global name, generates the password
      into the bind `:cap_self_pw` (it survives the PL/SQL container
      switch at the end), and runs prepare.sql and check.sql.
      `repository/self.sql` (in the owner, after install.sql) calls
      add_target, or set_link_password when the target exists with the
      same reader and address, and collects. install.sh's standalone is
      now deploy_mode repository, forces INTO=schema, keeps READER, adds
      SELF_CONNECT and with JOBS_ENABLE turns on CAP_COLLECT_JOB too.
      quickstart.sh passes `CAP_OWNER` / `CAP_READER` / `CAP_CONTAINER` /
      `CAP_SELF_CONNECT` as DEFINEs. On dbmint (owners CAPM3, CAPM4,
      reader C##AWRM25): standalone and quickstart.sh each ran twice to a
      report with 0 FAIL; the first run copied 164,845 rows in 1.3 s over
      `//localhost:1521/cdb1.world`, the second refreshed the link and found
      nothing to copy; the copy check on CAPM3 was EQUAL; the password
      pattern appears in no log. The `--dry-run` drivers of target,
      repository, fixture-test and demo are byte-identical to before. The
      two-PDB stop was exercised only by a copy of the check that also
      counts PDB$SEED (dbmint has one PDB). A re-run's doctor WARNs
      ORA-01017 on the link, because it runs between the password reset
      and set_link_password.
- [x] **M25.3 GLOBAL_NAMES** (only if M25.0a fails). target/prepare.sql
      prints the target's global name, and the standalone path reads its
      own. add_target takes the global name and, on ORA-02085, creates
      `<global_name>@CAP_<NAME>`, the qualified link name that GLOBAL_NAMES
      accepts. Check: add / collect / ping / set_link_password /
      remove_target / uninstall under `global_names = TRUE`.
      Done 2026-11-09: M25.0a failed as expected (ORA-02085 from CAPX2's
      `CAP_CDB1.WORLD`). add_target's new `p_global_name` (default NULL)
      is used only when the `CAP_<NAME>` link it tries first raises
      ORA-02085; without it that case fails with ORA-20074, which quotes
      the ORA-02085 (it names the global name) and leaves no link. The
      stored name `CDB1.WORLD@CAP_CDB1` works unquoted in every
      `@link` use, a remote PL/SQL call, CLOSE_DATABASE_LINK and DROP, so
      no other caller changed and uninstall.sql drops it as it is. target/
      prepare.sql's add_target line now passes `p_global_name`. On dbmint
      (throwaway owner CAPM1, reader C##AWRM25) under session
      `global_names = TRUE`: add without the name refused with 0 links
      left; add with it, collect (164,406 rows, 1.1 s, 0 links open after),
      ping, set_link_password, remove (0 links), add again; then under
      FALSE a collect over the qualified link and a second target without
      the name still got `CAP_CDB1B`. The copy check over the qualified
      link: EQUAL, 17 sources, 163,401 rows. uninstall.sql left 0 links and
      0 objects.
- [x] **M25.4 RAC: no half-copied snapshot.** With one high-water mark per
      DBID, a collect can copy a snapshot that one instance has finished and
      another has not. Local mode picked up the late rows on its next read,
      but a copy never will. collect therefore holds back the newest snap_id
      while it has fewer instances than the snap_id before it, and copies it
      on the next run once it has as many. Check: on single-instance CAPX2
      the window is unchanged (copy check 0, fingerprints equal before and
      after). RAC stays untested, and the docs say so.
      Done 2026-11-09: collect_dbid's MIN/MAX snapshot query now also
      returns the instance counts of the newest two snap_ids (one remote
      query, as before), and a held-back snap_id is named in the collect's
      output and its CAP_COLLECT_LOG message. The rule over synthetic
      snapshot sets: 2/2/1 instances copies through the middle one; 2/2,
      1/1 and a single snapshot copy everything; 2 then 1 then 1 (an
      instance gone for good) holds back once, then copies through. Checked
      on single-instance CAPM1 instead of CAPX2 (same layout, no shared
      reader): after collect the high-water mark equals the target's newest
      snap_id (4019), the log message stays empty, and the copy check is
      EQUAL (17 sources, 163,401 rows).
- [x] **M25.5 doctor without DBA_HIST.** Sections 2, 3, 5 and 6 check the
      measured database, which is target/check.sql's job now (the standalone
      path runs it, M25.2). doctor keeps the repository side and keeps
      sections 7..11 under their numbers, because the docs and
      CAP_CFG_CHECK cite them. Section 11 adds the reader's password expiry
      over each link (`USER_USERS@link`): WARN inside the new knob
      `reader_expiry_warn_days` (30), naming the two statements that rotate
      it (`ALTER USER ... IDENTIFIED BY` on the target, then
      `cap_repo.set_link_password`). Check: on dbmint, a reader whose
      profile expires it in 10 days gets the WARN.
      Done 2026-11-09: doctor.sql names no DBA_HIST_* view any more. Before
      install it assumes repository (section 7 prints the needs as INFO,
      nothing to count yet), section 4 adds CREATE DATABASE LINK, and
      `cap_doctor_mode = local` is ignored with a note (install.sh's
      standalone role and quickstart.sql still pass it). An installed local
      seam (CAPV_SNAPSHOT on a SYS DBA_ view) is a WARN naming the upgrade
      path. The expiry is read by the new definer's-rights
      `cap_repo.reader_expiry(p_name)` (NULL = never expires or the link
      fails, ping says why; rolls back like ping). On dbmint: CAPM1
      (repository, target CDB1, reader C##AWRM25) 0 FAIL, the reader under
      DEFAULT read "expires 2027-05-08 (in 179 d)" PASS, and under a
      throwaway profile `C##M25_EXPIRY` (PASSWORD_LIFE_TIME 10) the WARN
      "expires 2026-11-19 07:21 (in 9 d), inside reader_expiry_warn_days 30"
      with both statements; an empty schema (CAPM2) no FAIL and no
      DBA_HIST error; fixture CAPX1 no FAIL.
- [x] **M25.6 Carry the operator's config across a reinstall.** Before it
      drops anything, uninstall.sql spools
      `reports/cap_config_replay_<schema>_<ts>.sql` and prompts its path.
      The file holds an UPDATE for each CAP_CONFIG knob whose `cfg_value`
      differs from `cfg_default` (null-safe, `suite_version` left out) and
      a MERGE for each CAP_TBSPC_OVERRIDE row. The MERGE takes its columns
      from ALL_TAB_COLUMNS, so a column added later comes along. Run the
      file in the new owner after the new install: the seed MERGE has
      created every key by then, and a knob that no longer exists updates 0
      rows and is named. The overrides' dbid / con_dbid are the database's
      own, so they match again once the same database is the target. Check
      on dbmint: set two knobs and one override, then uninstall, install
      and replay. CAP_CFG and CAP_TBSPC_OVERRIDE must equal what they were
      before, and CAP_CFG_CHECK must be all OK.
      Done 2026-11-09: a PL/SQL block builds the file into a CLOB bind
      (dynamic SQL, so a half-removed install compiles), and SQL*Plus spools
      it with `SPOOL &file` or `SPOOL OFF` (a whole command line from a
      substitution variable is SP2-0734). With nothing to replay no file is
      written. The file sets DEFINE OFF and replays through a local `knob`
      procedure; the MERGE renders each column as a literal of its type
      (quotes doubled, CR/LF as CHR(), NUMBER in TM9). On dbmint (CAPM2):
      train_days 120, dtf_warn 45 and an override row whose note held a
      quote, `&`, `;` and a newline; uninstall wrote 3 statements, a second
      uninstall wrote none and raised nothing, and after a fresh install
      the replay gave 59 of 59 lines equal (58 knobs and the row),
      CAP_CFG_CHECK all OK. A replay naming a knob the release lacks
      printed "not replayed: knob tbspc_min_hist" and applied the rest.
- [x] **M25.7 Retire local mode.** Move ddl/10 to `repository/seam.sql`
      and update every reference. install.sql: `deploy_mode = local` aborts
      before any DDL and names the upgrade path (uninstall here, standalone
      into a PDB), as warehouse mode did in M24.9. create_owner.sql:
      `owner_mode` goes; every owner gets CREATE DATABASE LINK and no
      DBA_HIST grants, and a user that already holds the old local-mode
      grants (create_owner's DBA_HIST list, CONTAINER_DATA) has them revoked.
      uninstall.sql revokes them too, so a dropped root install leaves an
      inert user (as SYSDBA; run as the owner it prints the REVOKEs, since
      only the grantor can run them). `cap_results.deploy_mode` loses
      `local` (CAP_RUN keeps its history rows). install.sh drops the role
      and profile combinations that meant local mode. test/dbmint_parity.sh
      retires (M25.1 replaced it). suite_version 25. A new lint enforces the
      golden rule: DBA_HIST_* only under repository/, target/, test/ and
      bench/. Check: every profile's `--dry-run`; on dbmint the fixture
      harness passes on CAPX1, a CAPX2 re-install has 0 INVALID, the copy
      check returns 0, and `deploy_mode = local` aborts without touching
      any object. End to end, after asking (it drops a root install):
      uninstall C##CAPLOC, standalone into a throwaway PDB1 owner, replay
      its config file (M25.6) and collect. Then no CAP object is left in
      the root schema, C##CAPLOC holds no DBA_HIST grant and no
      CONTAINER_DATA, the new owner's CAP_CFG equals C##CAPLOC's, and the
      new install's fingerprints equal CAPX2's.
      Done 2026-11-09: ddl/10 is `repository/seam.sql` (build.py's SEAM;
      its header says it is never installed). Both create_owner.sql and
      uninstall.sql include the new `revoke_local_grants.sql`, which finds
      the owner's SELECT grants on SYS.DBA_HIST_* and V_$PARAMETER in
      DBA_TAB_PRIVS (no list to keep in step with the manifest) and its
      CONTAINER_DATA, revokes them as SYSDBA (CONTAINER=ALL for a common
      grant, from CDB$ROOT only) and prints them otherwise. build.py no
      longer proves create_owner's grants: it grants no DBA_HIST view, and a
      revoke list that followed the manifest would miss what an older owner
      was given. New `test/lint_dba_hist.sh` (code, comments aside, outside
      repository/, target/, test/, bench/ and the generated ddl/13; a read
      planted in report/drill_cpu.sql failed it), run by
      dbmint_harness.sh, dbmint_copy_check.sh and dbmint_scale.sh. On
      dbmint: `deploy_mode = local` aborted in CAPM2 with 146 objects and
      the same last DDL time before and after; uninstall.sql in C##CAPLOC
      (two knobs set off default) wrote a 2-knob replay file, revoked 19
      SELECT grants and CONTAINER_DATA and left 0 objects, and a second run
      did nothing; standalone into CAPM6 collected 165k rows; with both at
      snap_id 4024 and default config, CAPM6 and CAPX2 fingerprinted equal
      on the 12 CAPV views and the 52 stack views; the replay set 2 knobs
      and CAPM6's CAP_CONFIG then equals C##CAPLOC's but for
      reader_expiry_warn_days, which M25.5 added after C##CAPLOC was
      installed; CAPX2 re-installed through install.sh with 0 INVALID and
      suite_version 25, copy check EQUAL; fixture harness on CAPX1 passed,
      once run_test.sql's SNAPSHOT-table check stopped comparing the clock
      columns: CAPR_COVERAGE.age_hours, stored by the refresh minutes
      earlier, crossed its 0.1 h rounding while the VM was busy.
- [x] **M25.8 Docs.** start.html keeps "Measure one database" and "Measure
      a fleet" as two paths of one install; the first is the second with
      the repository as its own target. Also: reference.html (modes,
      prerequisites, privileges, #installer, #repository), README, the
      concepts diagram, tutorial, testing.html (copy check, not parity),
      design.md (the M25 rationale beside M24's) and CLAUDE.md (golden
      rules, layout, testing levers). The upgrade notes state the break:
      what a standalone install loses, and the steps that replace it
      (uninstall, which writes the replay file; standalone into a PDB;
      replay; collect).
      docs_lint check 9 (check 10 since main's README-diagram check took 9)
      fails on `deploy_mode = local`, `owner_mode` or `10_seam_local` in
      any tracked file except PLAN.md and bench/.
      Done 2026-11-09: reference.html's "Local mode" section became
      "Standalone: a database as its own target" (the five scripts in order,
      by hand and through the installer), doctor's table lost checks 2, 3, 5
      and 6 and gained CREATE DATABASE LINK and the reader expiry, the
      deploy-modes, prerequisites, privileges, owner, profiles, cap_repo
      (`p_global_name`, `reader_expiry`), load-order, upgrade and retention
      parts follow the code, and suite_version reads 25. index.html,
      concepts.html and start.html redraw their source diagrams with the
      loopback link; testing.html's Track B is the standalone smoke with the
      copy check as its own step and the new AWR-read lint; report examples
      run in the owner (`--container PDB1 --schema AWRCAP`). Sample output
      comes from the 2026-11-09 quickstart run into CAPM5 on dbmint,
      genericised (owner AWRCAP, reader C##AWRRDR, domain example.com, a
      fake DBID). Check 9 allow-lists three lines by file and text:
      install.sql's abort, doctor.sql's test for an installed local seam and
      repository/seam.sql's former-name note. Two lines planted in README.md
      failed it with exactly those two lines.

Order: M25.0 gates the rest. M25.1 lands before M25.7, while the parity
lever can still vouch for it, and so does M25.6, which M25.7's end-to-end
check uses. M25.3 and M25.4 are independent. Nothing on dbmint is dropped
without asking: M25.7 uninstalls C##CAPLOC only after a yes, and C##AWRRDR
stays because every loopback uses it.

## M26 — Instance memory sizing (SGA / PGA)

Spec: `docs/specs/memory-sizing.md`. A verdict layer (`UNDERSIZED` / `OK` /
`OVERSIZED` / `INSUFFICIENT_EVIDENCE` per instance and memory area, with
evidence and a suggested size), not a forecast. Instance memory only; the
host's physical memory size is read for one flag. No verdict alerts.

Built first, as one vertical cut across M26.1-M26.3: the `PGA_LIMIT` area
(suite_version 26.1). `CAPV_PGASTAT` in all three seams with an optional
repository copy (`CAP_H_PGASTAT`, every statistic name; a reader without the
grant is skipped by collect, not failed), the `PGA_ALLOC_GB` series (named so
for its GiB unit, not `PGA_ALLOC`) in `CAPD_SERIES_DAILY` and every layer above
it, `ddl/42_memory_views.sql` (`CAPM_PGA_LIMIT`, `CAPM_EVIDENCE`,
`CAPM_VERDICT`), the knobs `mem_window_days`, `mem_min_days`,
`mem_pga_limit_pct`, `mem_max_step`, `mem_host_ram_pct`, fixture rows and
closed-form assertions. No report section yet (M26.4).

Built second (suite_version 26.2): the advisor-based areas `PGA_TARGET`,
`BUFFER_CACHE`, `SHARED_POOL`, `SGA_TOTAL` and `SGA_BALANCE`, by the spec's
"Detailed rules" section. `ddl/42_memory_views.sql` is now ten views:
`CAPM_SNAP`, `CAPM_INST`, `CAPM_ADV_SRC`, `CAPM_DELTA` (every counter and
advisor estimate as increments inside a startup), `CAPM_ADVICE` (the curve
per advised size), the facts `CAPM_PGA_LIMIT`, `CAPM_AREA`,
`CAPM_SGA_BALANCE`, then `CAPM_EVIDENCE` (`kind` added) and `CAPM_VERDICT`
(`suggested_param` added, one decision table for every area). Sixteen `mem_`
knobs. The ten memory fixture tables are filled and every grade, reason and
suggested size is asserted against closed forms. Verified on the real AWR in
both modes: the ten views fingerprint equal, `SELECT * FROM capm_verdict`
takes about 10 s and 205 MB of PGA in local mode. Changed against the spec
and recorded there: a counter AWR omits while zero counts its first row in
full, and a PGA target that over-allocates at every size inside the step cap
is advised the largest candidate. Not built: per-PDB usage, the history
table, doctor readiness (the report sections and the snapshot registry
entries came with 26.4).

Built third (suite_version 26.3), from the first read of the real verdicts:
two rule changes, both in the spec's "Detailed rules" section. An advisor
area whose current size has too little advisor history is measured against
the nearest advised size that has it (`mem_ref_tolerance_pct`,
`CAPM_ADVICE.reference_bytes` / `reference_fallback`), so a shared pool that
has just been resized is graded instead of reading `ADVISOR_THIN`. A pool
squeezed one way is a balance finding: signal `SGA_POOL_SHIFT_PCT`
(`mem_shift_pct`) and grade `DRIFTING` / `ONE_WAY_SHIFT`, after `THRASHING`
in rule order, with no suggested size. On the real AWR `SGA_BALANCE` now
reads `DRIFTING` (buffer cache 256 MiB to 48 MiB under a 1536 MiB
`sga_target`) and `SHARED_POOL` reads `UNDERSIZED` against a reference of
1056 MiB. `SELECT * FROM capm_verdict` takes about 11 s and 223 MB of PGA in
local mode.

Fixed in 26.3 after reading those verdicts again. The shared pool suggestion
moved from 1776 MiB to 1296 MiB between two snapshots 15 minutes apart: each
advised size was compared over only the intervals that listed it, the lists
are ragged, and so every size had its own interval set. Every size is now
compared over the reference size's intervals, the largest listed size below
it standing in where an interval does not list it, and a candidate must
count in all of them. The curve rises with size by construction (asserted).
And a pool suggestion could pass `sga_target`: `CAPM_VERDICT.exceeds_sga`
flags a buffer cache or shared pool floor above what the two pools hold
together, without reducing it. On the real AWR the shared pool reads
`UNDERSIZED`, 1872 MiB, `exceeds_sga = Y`, beside `SGA_TOTAL` `UNDERSIZED`,
2688 MiB.

Built fourth (suite_version 26.4): M26.4, the reports, over what the first
three steps built. `ddl/45` gains the report views `CAPR_MEM_AREA` (the six
areas, their labels and order), `CAPR_MEM_VERDICT` (reason sentence,
`actionable`, size texts, one `headline` sentence per row), `CAPR_MEM_EVIDENCE`,
`CAPR_MEM_COMPONENTS` and `CAPR_MEM_COMP_POINTS` (daily component sizes of the
evidence window); the last four are in the snapshot registry. `ddl/42` gains
`CAPM_COMP`, the component intervals `CAPM_SGA_BALANCE` used to compute
inline, so the reports and the drill read the same increments. Consumers:
text section 8 / 8b / 8c (`report/sections/08_memory.sql`), the HTML report's
Memory section (one card per instance: verdicts, folded evidence, a stacked
chart of the SGA components), "Memory sizing" lines in the briefing (one per
actionable verdict, a count of the areas that could not be judged), four CSV
files, and `report/drill_mem.sql` (startups, evidence, advisor curves,
resizes of one instance). Verdicts stay out of every alert count. The demo
story has a memory chapter (`test/demo_fixture.sql`: PGA target undersized,
SGA total and buffer cache oversized) and `docs/demo/` is regenerated from
it. Asserted on the fixture: every headline of the shipped knobs and of the
AMM, floor-over-SGA, drifting, thrashing and host-flag scenarios, the
evidence order, and the component rows through a one-way shift and an
oscillation. Left out because their sources are not built (M26.1 / M26.3
below): per-PDB rows, the resize operations detail and "since when" from the
verdict history. Found while building the demo: a fixture install with both
the PGASTAT and the PARAMETER stub fails with ORA-00932 in
`CAPD_SERIES_DAILY` (19.27); not fixed here, the demo now carries both
tables.

- [ ] **M26.1 Seam.** Fourteen new `CAPV_*` views (component history, resize
      operations, PGA statistics, work area histogram, the PGA / SGA / cache /
      shared pool advisors, SGA statistics, library cache, row cache, buffer
      pool statistics, system events, per-PDB resource metrics) in all three
      seams, plus the missing memory parameters and system statistics.
      Repository copies in the manifest, grants in `target/prepare.sql` and
      `create_owner.sql`, a collect that skips a memory view it cannot read,
      doctor probes, fixture tables. Confirm the open facts the spec lists.
      Built so far: the ten sources the spec's detailed rules name
      (`CAPV_MEM_COMP`, `CAPV_WORKAREA_HSTGRM`, `CAPV_PGA_ADVICE`,
      `CAPV_SGA_ADVICE`, `CAPV_CACHE_ADVICE`, `CAPV_SHPOOL_ADVICE`,
      `CAPV_SGASTAT`, `CAPV_LIBRARYCACHE`, `CAPV_ROWCACHE`,
      `CAPV_SYSTEM_EVENT`) and the wider `CAPV_PGASTAT` filter, optional copies,
      grants, probes, empty fixture tables. Deferred: resize operations, buffer
      pool statistics, per-PDB resource metrics, the memory parameters.
- [ ] **M26.2 Evidence.** Startup segments inside the window, evidence rows
      per signal, advisor curves combined across segments, the `PGA_ALLOC_GB`
      series against `pga_aggregate_limit` in `CAPD_SERIES_DAILY` (built). Measure
      refresh time and peak PGA with the scale lever.
- [ ] **M26.3 Verdicts.** Grades, knee-based suggested sizes, the host memory
      flag, `SGA_BALANCE` (`THRASHING` and a pool floor), per-PDB usage and
      limit verdicts, the persisted history table written by
      `cap_results.refresh`.
- [x] **M26.4 Reports.** Text section, HTML cards, briefing lines, CSV,
      `report/drill_mem.sql`, docs, a memory chapter in the demo story.
      Per-PDB rows, resize operations and verdict history join the reports
      when M26.1 / M26.3 build their sources.

## v2 (unchanged)

- [ ] Memory follow-ups to M26: grading AMM instances, verdicts for the
      In-Memory area and minor pools, verdict panels in the dashboards,
      forecasting SGA components.
- [ ] Cross-DBID series stitching (non-CDB → PDB migrations) keyed on a stable
      `CAP_TARGET.target_id`.

---

Suggested order: M7.1–M7.3 + M8.1 (immediate user value) → M9.1 + M9.4 →
M10.1/M10.2 → M8.2 → rest.
