# CLAUDE.md — working notes for this repo

AWR-driven capacity forecasting + anomaly detection, entirely in-database
(Oracle 19c floor). Read `README.md` for the user-facing overview and
`docs/design.md` for deep design rationale. This file is the fast orientation
for making changes safely.

## Golden rules

- **Read-only against AWR.** The suite writes only to `CAP_*` tables it owns
  (and its OML models): the operator tables `CAP_CONFIG` / `CAP_TBSPC_OVERRIDE`,
  the Tier 2 registry `CAP_ML_MODEL` (written by `cap_forecast_ml`) and the
  results layer `CAP_RUN` / `CAP_FIT_HIST` / `CAP_ALERT_STATE` /
  `CAP_ALERT_EVENT` (written only by `cap_results`). The reports and every
  `CAPV/CAPD/CAPF/CAPA/CAPR` view only SELECT. In repository mode
  `cap_repo` writes `CAP_TARGET` / `CAP_TARGET_DBID` / `CAP_COLLECT_LOG` and
  the `CAP_H_*` copies, and runs only SELECTs on a target (plus one
  `dbms_application_info.set_module@link` that labels its session there).
  Preserve this.
- **All analytics go through the `CAPV_*` seam.** Never reference `DBA_HIST_*`
  outside `ddl/10_seam_local.sql`, except the repository's reads over a
  target's link: the pull statements `repository/build.py` generates into
  `CAP_REPO_SOURCE` and `cap_repo`'s probe / DBID discovery. That is what
  keeps local / repository / fixture modes byte-identical downstream.
- **Config, not constants.** Thresholds live in `CAP_CONFIG`, read only through
  the one-row view `CAP_CFG` (`CROSS JOIN cap_cfg cfg`, one column per knob,
  no defaults inlined). Views never read `cap_config` directly.
  A new knob is three edits in `ddl/05_config.sql`: a seed MERGE row, a
  `CAP_CFG` column and a `CAP_CFG_CHECK` UNPIVOT entry (+ its range rule);
  then a row in the `docs/reference.html` knob table (`test/docs_lint.sh`
  checks it). Never hard-code. The seed MERGE inserts missing keys and
  refreshes only `cfg_default` / `cfg_desc` on match, so an operator's
  `cfg_value` survives; reset is `UPDATE cap_config SET cfg_value =
  cfg_default`. The one exception is `suite_version`, overwritten by every
  install (bump it in the MERGE and in its `CAP_CFG_CHECK` rule together).
  `CAP_CFG_CHECK` reports each knob OK / MISSING / BAD with a reason.
- **Persisted tables survive a re-install:** `CAP_CONFIG` and
  `CAP_TBSPC_OVERRIDE` (ddl/05), `CAP_ML_MODEL` (ddl/50), `CAP_RUN`,
  `CAP_FIT_HIST`, `CAP_ALERT_STATE`, `CAP_ALERT_EVENT` (ddl/60), and in
  repository mode `CAP_TARGET`, `CAP_TARGET_DBID`, `CAP_COLLECT_LOG`
  (repository/cap_repo.sql) and the `CAP_H_*` copies (ddl/13), which cannot
  be re-pulled once a target's AWR has aged out. Each is created
  idempotently, NOT dropped by `ddl/00_drop.sql`, dropped only by
  `uninstall.sql` (which first drops the links `add_target` made, through a
  throwaway definer's-rights procedure: only the owner can drop them). `CAP_TBSPC_OVERRIDE` holds operator-set tablespace
  ceilings, exclusions and per-tablespace `dtf_warn` / `dtf_crit` /
  `nearfull_warn_pct` / `nearfull_crit_pct` (NULL = the knob), applied once in
  `CAPD_TBSPC_DAILY`; `dbid`/`con_dbid` `0` are wildcards and the most
  specific matching row wins.
- **APEX contract.** `apex/build.py` selects `CAPR_SERIES_POINTS`,
  `CAPR_FORECAST_POINTS`, `CAPR_FIT`, `CAPR_ANOMALIES`, `CAPR_ALERTS` and
  `CAPR_CONTAINER` by named column. Only ADD columns to these six views; never
  rename or drop one. `apex/test/apex_smoke.sql` proves it. ORDS, the ELK
  export and `report/report_html.sql` select from the same views.
- **The baseline mode is part of every anomaly key.** `CAPA_ANOM` holds one row
  per observation AND `baseline_mode` (2 per day, TRAILING + SAME_DOW; 1 per
  CPU hour, HOUR_OF_WEEK). Read it only with `baseline_mode = ...` or GROUP BY
  the observation key; an observation-grain consumer joins `CAPA_ANOM_DAY`
  (one row per observation). `test/lint_anom_joins.sh` enforces it (any
  `capa_anom` read outside ddl/40, ddl/45, test/, bench/ and the drill
  scripts fails; drill reads need a `baseline_mode =` predicate).
- **Every session is labelled** (reference.html#labels). A runnable SQL*Plus
  script runs `SET APPINFO OFF` then `SET APPINFO "AWRCAP/<its path>"` (after
  any CONNECT: a label set before it is lost); a public procedure of
  `cap_results` / `cap_forecast_ml` / `cap_repo` saves the caller's
  MODULE/ACTION, sets MODULE `'AWRCAP/<package>.<procedure>'` and ACTION its
  step, and restores them on return AND in a `WHEN OTHERS ... RAISE` handler
  (and before any early RETURN); a scheduler job_action starts with
  `DBMS_SESSION.SET_IDENTIFIER('<job name>')`. Functions called from SQL
  (`get_forecast`, `deploy_mode`, `ping`) never set MODULE. Module and action
  do not cross a DB link, hence `cap_repo.label_remote`.
  `test/lint_appinfo.sh` enforces the first three; a new runnable script,
  procedure or job needs its label or the lint fails.
- **19c syntax floor.** Inline `OVER (PARTITION BY ... ORDER BY ...)` on every
  window call — the standalone `WINDOW` clause is 21c+. No 21c/23c features.

## Layout / load order

`install.sql` includes, in order: `ddl/00_drop` → `05_config` (CAP_CONFIG,
CAP_CFG, CAP_CFG_CHECK, CAP_TBSPC_OVERRIDE) → the seam (`10`/`13`/`12` for
`deploy_mode` local / repository / fixture: thirteen CAPV_* views +
CAPV_CONTRACT; `13` also creates the copies and pulls `repository/cap_repo.sql`) → `20_daily` →
`25_series_daily` (CAPD_SERIES_DAILY) → `30_forecast` → `35_series_forecast`
(CAPF_SERIES_FORECAST) → `40_anomaly` → `45_report_views` (CAPR_CONTAINER,
CAPR_ANOMALIES, CAPR_FRESHNESS, CAPR_TARGETS, CAPR_SEVERITY, the section views, CAPR_SERIES,
CAPR_SEGMENT_GROWTH, the point feeds CAPR_SERIES_POINTS / CAPR_HOURLY_POINTS,
CAPR_FIT) → `50_ml` (CAP_ML_MODEL, the temporary CAP_ML_INPUT, pulls `ml/cap_forecast_ml.pks/.pkb`, the
ESM views, CAPF_COMPARE, CAPF_BACKTEST, CAPF_ESM_HEALTH[_SUMMARY]) →
`55_report_views_ml` (the Tier-2-dependent CAPR_* section views,
CAPR_FORECAST_POINTS and CAPR_ALERTS, which reads the Tier 2 health views for
MODEL_HEALTH) → `60_results` (the results tables, package CAP_RESULTS and the
CAPR_ALERTS_LATEST / CAPR_ALERT_EVENTS / CAPR_RUNS / CAPR_COVERAGE /
CAPR_FIT_HISTORY / CAPR_WEEKLY_DIGEST / CAPR_FORECAST_ACCURACY views).
`docs/reference.html` "Object index" lists every object (`test/docs_lint.sh`
checks it).
M15 objects: ddl/20 `CAPD_CPU_INTERVAL` / `CAPD_DBTIME_INTERVAL` (one row per
valid snapshot interval; the daily views GROUP BY them) and `CAPD_CPU_HOURLY`
(BUSY_PCT + DB_CPU_PCT per END-hour bucket, the HOUR_OF_WEEK source); ddl/25
`day_gap` / `max_interval_hours` / `gap_flag` on `CAPD_SERIES_DAILY`; ddl/40
`CAPA_OBS` (what is scored, unit, floor) → `CAPA_ANOM` (the engine) →
`CAPA_ANOM_DAY` (+ the untouched `CAPA_CPU_SHIFT`); ddl/45 `CAPR_ANOMALIES`
(read by `CAPR_ALERTS` in ddl/55), `CAPR_SERIES_ANOMALIES`, `CAPR_HOURLY_POINTS`.
`CAPA_TBSPC_ANOM` / `CAPA_CPU_ANOM` are gone (still in `00_drop` so an upgrade
removes them). `test/dbmint_harness.sh <SCHEMA> [--ml]` runs
`test/lint_anom_joins.sh` and `test/lint_appinfo.sh`, syncs and runs the whole fixture harness on dbmint.
`test/docs_lint.sh` checks the docs against the DDL (knobs, object index,
alert kinds, no assertion counts, no "generated" claim, every `CREATE TABLE`
in ddl/ + repository/ plus `CAP_H_*` named in reference.html#tables and in
the "Persisted tables" bullet above, every `profiles/*.env` in
reference.html#installer and install.sh's `--profile` help, and no token of
the retired warehouse mode in a tracked file outside PLAN.md and bench/).
`install.sh` is the guided / silent installer for every role (one SQL*Plus
driver per run, log in `reports/install_<ts>.log`); `profiles/*.env` are its
answer files: `standalone` (dedicated owner, ML, jobs), `target`,
`repository`, plus `quickstart`, `demo`, `fixture-test`.
`docs/start.html` presents "Measure one database" and "Measure a fleet" as
equal paths; reference.html `#installer` / `#repository` hold the detail.
Opt-in extras outside install.sql: `create_owner.sql` (run once as SYSDBA:
a dedicated owner, `C##AWRCAP` in CDB$ROOT or `AWRCAP` in a PDB, with direct
grants on every DBA_HIST_* view ddl/10 reads; views and the definer's-rights
packages ignore role grants), `quickstart.sql` / `quickstart.sh` (doctor →
install local → report/report.sql, in one run; the docs' "Getting started"
path), `doctor.sql` (preflight), `install_jobs.sql` / `uninstall_jobs.sql`
(DBMS_SCHEDULER, all created disabled: CAP_REFRESH_JOB 01:30,
CAP_ML_RETRAIN daily 02:00, CAP_REPORT_SPOOL_JOB 03:00; where package
CAP_REPO exists also CAP_COLLECT_JOB hourly :05 and CAP_PURGE_JOB 01:00),
`report/report_csv.sql` (one CSV per CAPR section view), `report/report_brief.sql`
(one-page "Runway" briefing from CAPR_FIT[_HISTORY] + the alert list; demo
`docs/demo/cap_brief_demo.html`), `report/run_report.sh`
(cron wrapper: text / --html / --brief / --csv, --scope, --target, --snapshot, non-zero exit on a
non-zero sqlplus exit or a line starting ORA-/SP2- (an alert message quoting
an ORA- mid-line is content); `test/run_report_sh_test.sh` is its
mock-sqlplus test, no DB needed), `report/report_html.sql` (one section per
metric, one card per series: it spools the point-feed views as one JSON block
between the generated `report/html/page_head.sql` / `page_tail.sql`; edit
`report/html/report.css` / `report.js`, run `python3 report/html/build.py`,
never the generated .sql; non-ASCII must stay escaped because DBMS_OUTPUT
turns it into `?`; `test/report_html_test.sh` checks the generated files and
renders `docs/demo/cap_report_demo.html` under a stub DOM, no DB needed; the
demo is `build.py --preview` of a spooled demo-story report with its identity
strings genericised), `report/drill_tbspc.sql` / `report/drill_cpu.sql`
(single-series drill-down; drill_tbspc prints "who is filling it" from
CAPR_SEGMENT_GROWTH). Both report drivers take `[top_n] [anomaly_days]
[show_esm] [dbid] [con_dbid] [LIVE|SNAPSHOT]`, `-` skips one.
`test/demo_fixture.sql` fills the CAP_FIXTURE_* tables with a designed 150-day
"ECOMPRD" story (hourly snapshots, two containers, 32 threads / 16 cores; no
PARAMETER / ASM / SEG_STAT tables, so those seam views fall back to ddl/12's
zero-row stubs, typed constants because `CAST(NULL)` join keys raised
ORA-07445 on 19.27); `docs/demo/` holds the reports generated from it (identity
strings genericised: database ECOMPRD, host db-prod-01.example.com, schema
CAPMON) for the docs site. Regenerate it in a throwaway schema (not CAPDEMO,
which feeds the lab dashboards): fixture_remove (plus `DROP TABLE
cap_fixture_seg_stat`, which it misses) → demo_fixture → install (fixture) →
`cap_forecast_ml.train_all` → both report drivers. Not fixture_install first:
its PARAMETER / ASM / SEG_STAT tables would survive into the demo.
`elk/` is the Kibana integration (opt-in, outside install.sql):
`export_capacity.sql` emits one JSON doc per line from the CAPD_/CAPF_/CAPA_/
CAPR_ views; `export.sh` runs it ON THE DB HOST into Filebeat's `generated/`
dir, `filebeat/awrcap.yml` + `logstash/oracle_capacity.conf` carry it into the
ES index `awrcap-capacity` (mapping = `elk/elasticsearch/index-template.json`,
`dynamic: strict`, so add a field there FIRST and re-run `elk/setup.sh`).
`elk/kibana/build_*.py` generate the three dashboards (edit the builder, never
the `.ndjson`); `setup.sh` applies the template and imports them. Nothing on
the DB host talks to Elasticsearch directly.
See `elk/README.md`.
`LAB.md` is the workstation runbook (Tailscale URLs, start order, VM facts)
for the visual paths; read it before touching the lab.
`grafana/` is the second optional path (no Elastic): the ORDS module
`grafana/ords/awrcap_module.sql` publishes the CAPR point-feed views
(`CAPR_SERIES_POINTS` / `CAPR_HOURLY_POINTS` / `CAPR_FIT` / `CAPR_ANOMALIES`
in ddl/45, `CAPR_FORECAST_POINTS` and `CAPR_ALERTS` in ddl/55, plus a GET
`metrics` handler in Prometheus text format; contract `grafana/API.md`; the
ELK export selects from the same views, so change the view, not the
consumers) and
`grafana/build_*.py` generate the provisioned Grafana boards. ORDS install
state and passwords under `grafana/` are gitignored.
`apex/` is the third optional path (nothing outside the database): `apex/build.py`
generates `apex/awrcap_app.sql`, an APEX 26.2 application export (Oracle JET
charts + Interactive Reports, no external JS) that reads the same CAPR point
feeds plus `CAP_CONFIG` from its parsing schema, loading each view once per
session into `AWRCAP_*` APEX collections. `apex/install.sql` imports it into
a given workspace/schema/app id; `apex/workspace.sql` creates the workspace
and accounts; `apex/publish.sh` is the lab wrapper for the `23cfree` docker
instance (see `LAB.md`). Edit the builder, never the generated export.
Prefixes: `CAPV_` seam → `CAPD_` daily → `CAPF_` forecast → `CAPA_` anomaly →
`CAPR_` integration (display labels + pollable alerts).

## SQL\*Plus gotchas that already bit us

- **Included DDL files `SET DEFINE OFF`**, which persists back into the caller.
  `install.sql` re-asserts `SET DEFINE '&'` before each `&substitution`.
- **A PROMPT line ending in `-` is line continuation** and swallows the next
  line. Never end a PROMPT with a hyphen (that killed the report header once).
- **A PROMPT line ending in `;` loses the semicolon** (SQL*Plus strips it as a
  terminator). End PROMPT sentences with `.` instead.
- **`&&deploy_mode` prompts if undefined** — non-interactive callers must
  `DEFINE deploy_mode` up front or a heredoc line gets consumed as the answer.
- **A `--` comment line ending in `;` terminates the statement buffer** in
  plain-SQL context (SQL*Plus doesn't parse comments when scanning for the
  terminator), truncating a CREATE VIEW mid-statement with a baffling
  ORA-00936 pointing at the comment. Safe inside PL/SQL blocks (`/`
  terminates those). Bit us in ddl/30 (M9.1).
- **A substitution variable followed by `.` swallows the dot** in PROMPT text
  (`top &top_n.` prints `top 3`); rephrase. `AUDIT` is a reserved word
  (ORA-00936 pointing at the SELECT). Default `SERVEROUTPUT` (WORD_WRAPPED)
  strips leading blanks from DBMS_OUTPUT lines.
- **`USER_OBJECTS` / `USER_DEPENDENCIES` follow the SESSION user, not
  `CURRENT_SCHEMA`.** When testing as SYSDBA with `ALTER SESSION SET
  CURRENT_SCHEMA = CAPTEST`, query `ALL_*` filtered on
  `owner = SYS_CONTEXT('USERENV','CURRENT_SCHEMA')` (doctor.sql does).
- **Positional args:** `COLUMN 1 NEW_VALUE 1` + a zero-row SELECT defines an
  unpassed `&1` as empty and leaves a passed one intact (verified 19c);
  scripts `UNDEFINE 1 2 3` at the end so a later script doesn't inherit them.
- **`@@` includes resolve relative to the OUTERMOST caller** on 19c, so run
  `install.sql` / `report/report.sql` from the repo root and use full paths
  (`@@ddl/...`, `@@report/sections/...`).

## Install, doctor and jobs (schema-aware)

- **Target schema = `CURRENT_SCHEMA`.** `install.sql` prints it and warns when
  it is SYS (everything would be owned by SYS in that container; use
  `create_owner.sql` and install as that user). Before its closing check it
  recompiles INVALID `CAP*` objects of that schema in two passes (a dependent
  such as `CAP_REPORT_SPOOL` would otherwise abort a re-install). Both steps
  read `ALL_OBJECTS` on `owner = CURRENT_SCHEMA`; under SYSDBA + `ALTER
  SESSION SET CURRENT_SCHEMA` still query `ALL_OBJECTS` yourself to prove
  nothing is INVALID. Failures exit via `WHENEVER SQLERROR EXIT FAILURE`
  (`SQL.SQLCODE` exits 0 for codes that are multiples of 256).
- **doctor.sql** takes the mode from the installed `CAPV_SNAPSHOT`, assumes
  local before install, or reads `DEFINE cap_doctor_mode = local |
  repository | fixture` (no prompt when undefined). It probes every
  DBA_HIST_* view ddl/10 reads and the target schema's direct grants, prints a readiness table
  (days each feature needs vs days available), suite_version, the fit-quality
  mix, `CAP_CFG_CHECK`, the results layer and the live `CAPV_CONTRACT` check,
  and leaves `cap_doctor_fail` (count of FAIL lines, "1" if the block did not
  finish). `quickstart.sql` sets `cap_doctor_mode = local` and stops before
  install on a FAIL unless `DEFINE force_install = Y`.
- **Scheduler jobs.** `install_jobs.sql` creates jobs with unqualified names;
  DBMS_SCHEDULER resolves them in `CURRENT_SCHEMA`, so a SYSDBA +
  `CURRENT_SCHEMA` run creates them in the target schema, and the script lists
  them from `ALL_SCHEDULER_JOBS` on that owner. Jobs share the procedure
  namespace, hence `CAP_REPORT_SPOOL_JOB` beside procedure `CAP_REPORT_SPOOL`
  (ORA-27477 otherwise). `uninstall.sql` runs `uninstall_jobs.sql` first.

## Non-obvious correctness facts (verified on Oracle 19c)

- `DBA_HIST_DATAFILE` has **no SYSTEM row** on stock 19c → block size must come
  from `DBA_HIST_TABLESPACE.block_size` (primary), datafile only as fallback.
- `REGR_R2` returns **1** for a zero-variance *y* (flat) series, NULL only for
  zero-variance *x*. `FLAT` quality keys off `slope = 0`.
- OML `EXSM_PREDICTION_STEP` is HARD-capped at **30** on 19c at any series
  length (30 ok / 31 fails at 121, 300 and 600 rows). `build_model` caps at
  `LEAST(30, cfg, FLOOR(rows/4))`; don't remove that. So ESM never goes past
  +30: `CAPF_COMPARE`'s ESM row is the model's furthest step (`esm_horizon_days`
  <= 30, e.g. 22 steps on 90 rows) and counts only while `model_age_days <=
  esm_max_age_days`. A failed build keeps the previous model (built under a
  temp name, swapped in with `RENAME_MODEL`), records status FAILED with
  `last_error`, and the public `train_*` raise ORA-20060 after the batch.
- **OML trains from `CAP_ML_INPUT`, never from the views.** `CREATE_MODEL2`
  runs its data query inside `INSERT /*+ append */ INTO SYS.MODELGTTRAW$`,
  where the optimizer planned `CAPD_DBTIME_DAILY` into work that grew with
  the fleet (19.27, four targets: 114 s and 33M buffer gets per series, 0.66 s
  for the same query alone; `train_all` 2116 s, 86 s once staged).
  `build_model` copies each series into the global temporary table
  `CAP_ML_INPUT` (ddl/50, ON COMMIT PRESERVE ROWS, committed before the build
  because OML reads it in its own transaction) and gives OML `SELECT case_id
  AS day_dt, val AS <target> FROM cap_ml_input`. Every data query must start
  `SELECT day_dt, <target>`. One that starts with `WITH` builds an EMPTY
  model, no error (verified 19.27).
- `DM$VP<model>` result view columns: `PARTITION_NAME, CASE_ID, VALUE,
  PREDICTION, LOWER, UPPER`. `get_forecast` reads the last five.
- **In CDB$ROOT the SYS_ time model and sysstat are CDB-wide.**
  `DBA_HIST_SYS_TIME_MODEL` and `DBA_HIST_SYSSTAT` hold one row per snapshot
  under the root's `con_dbid`, and it is the CDB total. Per-container rows
  live in `DBA_HIST_CON_SYS_TIME_MODEL` / `DBA_HIST_CON_SYSSTAT`, which
  `CAPV_TIME_MODEL` / `CAPV_SYSSTAT` read (PDB$SEED dropped; a snapshot with no
  CON_ row, i.e. a non-CDB, falls back to the SYS_ views). So the root row is
  CDB$ROOT alone and the CDB total is the sum. Host CPU (OSSTAT) records
  under the CDB `con_dbid`.
- **CPU denominators.** `db_cpu_pct` and its p95 / max / peak twins divide by
  logical-CPU seconds per interval, `LEAST(NUM_CPUS, cpu_count) x ivl_sec`
  (`NUM_CPUS`, else `NUM_CPU_CORES`; AWR's %Total CPU uses NUM_CPUS, and
  cores read 2x on SMT). `db_cpu_per_core` stays on summed OSSTAT core counts.
- `DBA_HIST_RESOURCE_LIMIT` has a `CON_DBID` column on 19c, but in CDB$ROOT
  its rows are **root-only**: the limits are CDB-wide, so PROCESSES /
  SESSIONS are CDB-wide series under the root's `con_dbid`. Its
  `LIMIT_VALUE` is a `VARCHAR2(10)` ('UNLIMITED' possible) — convert with the
  `REGEXP_LIKE(TRIM(..),'^[0-9]+$')` guard, never a bare `TO_NUMBER`. And
  `MAX_UTILIZATION` is a high-water mark **since instance startup**, so it
  resets on a restart (a level shift, not a lie).
- `DBA_HIST_PDB_INSTANCE` (19c) carries `CON_DBID` + `PDB_NAME` and includes a
  `CDB$ROOT` row whose `con_dbid` equals the CDB dbid — `CAPV_CONTAINER` leans
  on that; the `DBA_HIST_DATABASE_INSTANCE` branch only matters for non-CDBs.
- M9.1 intervals use `t ~ 1.96 + 2.4/df` (no t-distribution in SQL; good to
  ~1% for df>=10, and min_train_days guarantees df>=12). The FIXTURE INSTALLER
  computes expected bands with the same formula — it is part of the contract;
  change both together or FIX_ZIGZAG assertions break.
- Peak-window membership (M10.1) is by the interval's END hour in
  `(peak_hour_from, peak_hour_to]`, so with hourly AWR the default (8,18] is
  exactly the snapshots ending 09:00..18:00. The fixture has TWO snapshots per
  day (ids `2000+2i` ending 06:00, `2001+2i` ending 18:00); tablespace usage
  hangs only off the 18:00 one, and the restart day has no 06:00 snapshot.
- The CPU fixture has **three containers**: the root (`42424242`, OSSTAT +
  time-model), `FIXPDB1` (`42424243`, **time-model only** — OSSTAT records
  under the CDB con_dbid in real AWR, and giving the PDB its own rows would
  double `host_busy_sec` and break `host_share_pct`) and `FIXPDB2`
  (`42424244`, time-model only: weekday 60 / weekend 20 plus a ramp, the
  deseasoning / slope-significance / hot-p95 one). The M10.3 level shift
  therefore rides on `DB_CPU_PCT`. Any assertion counting CPU rows must scope
  on `con_dbid`, not just `dbid`. The root's OSSTAT is **NUM_CPUS 8 /
  NUM_CPU_CORES 4** (SMT 2:1), so `db_cpu_pct` closed forms divide by 8
  logical CPUs.
- **Fixture partial day:** one weekday at fixture index 14..20 (about 100 days back, far outside the 35-day shift windows) restarts at noon
  and keeps only its 06:00 interval: `covered_sec` 43200, `is_complete = 'N'`
  (below `complete_day_pct` 80). CPU and REDO fits read complete days only.
- **Other fixture series** (closed forms in run_test.sql): `FIX_CYCLIC` /
  `FIX_CYCLIC_UP` (30-day sawtooths graded CYCLIC, flat vs growing peaks),
  `FIX_OVERFULL` (override ceiling below usage: `limit_below_used`, clamped
  days_to_full), `FIX_DROPPED` (ends 30 days early: `is_current = 'N'`, a
  DB_SIZE_GB gap day), `FIX_TEMP` (peak 19.5 of 20 GiB: the one
  SERIES_NEARLIMIT, `TEMP_PEAK:FIX_TEMP`) and `FIX_UNDO`,
  `CAP_FIXTURE_PARAMETER` (cpu_count 8, FRA 100 GiB),
  `CAP_FIXTURE_ASM_DISKGROUP` (DATA 200 + 5i of 1000 GiB: a second
  SERIES_LIMIT, FRA flat), `CAP_FIXTURE_SEG_STAT` (three segments in
  `FIX_FILLING`, 70/20/10 % of its growth) and a 3-day burst on `FIX_GAP`
  (one anomaly episode).
- **The fixture's injected Tuesday (`INJECTED_TUE`) is always a FIXPDB1
  `DB_CPU_PCT` step day** (latest Tuesday in 90..120; the step covers the last
  7 days), and M15 scores that series. A bare `day_dt = d_inj` CPU anomaly
  lookup returns several rows and TOO_MANY_ROWS aborts `run_test.sql`: name
  series, `baseline_mode` and `con_dbid` (the `anom_flag` / `anom_n` helpers
  do). `INVERTED_WED` (40/40) is invisible to the day modes and flags only
  under HOUR_OF_WEEK (06:00 HIGH, 18:00 LOW).
- `cpu_gap_hours` defaults to **12**, not something tighter, because the
  fixture's snapshots are 12 h apart (06:00 / 18:00) and, more importantly,
  because `gap_flag` SUPPRESSES anomaly scoring — an over-sensitive default
  silences the whole CPU anomaly layer on a site with wide AWR intervals.
- Backtest ESM twins (`train_backtest`) share the 19c 30-step cap AND the
  `FLOOR(rows/4)` floor, so they may cover fewer than holdout_days forecast
  days (fixture: 93 rows -> 23 of 28). `CAPF_BACKTEST.n_days` reports actual
  coverage; don't assert full-holdout coverage for ESM.
- M9.2/M9.3 contracts in `ddl/30`: the chosen estimator (`slope_method` 0=OLS,
  1=THEILSEN, 2=DRIFT) drives slope/intercept/projections/days-to-full/accel_ratio/FLAT,
  but for OLS and Theil-Sen `r2` and every M9.1 band stay **OLS** residual
  quantities drawn around the chosen line — there is no closed-form Theil-Sen
  interval in SQL. Theil-Sen's two O(n^2) self-joins run only when
  `slope_method = 1`. DRIFT (median daily rate) draws random-walk bands
  `t x (sd x sqrt(h) + h x se)` and grades quality from the slope CI. The
  M9.3 reset day is **inside** the new window (`train_start = reset_day`; its
  used_bytes is already post-purge). Both are asserted by the fixture; change
  the view and the assertions together.
- **Projections are anchored at today:** `proj_h = cur_value + slope x h`
  (CPU: `anchor_value`, the median of the last `shift_days` complete days),
  bands = the OLS half-widths around that anchor, so +30 and days_to_full
  agree. TBSPC days_to_full / _lo / _hi clamp at 0 and `limit_below_used`
  flags a ceiling under usage. Every `days_to_full` / `days_to_sat` /
  `days_to_limit` (and `_lo` / `_hi`, and `add_by_day`) reads NULL when
  `last_day + days` would pass 9999-12-31: a near-zero slope under a large
  headroom made `add_by_day` raise ORA-01841 and fail `cap_results.refresh`
  (found by the M24.10 scale data). Every CAPF view carries `newest_day` /
  `is_current` (`stale_days` 3); forecast alert kinds and `CPU_SHIFT` need `is_current = 'Y'` (`CAPA_CPU_SHIFT` carries `newest_day` / `is_current` per dbid and reads complete, non-gap days only).
- **CYCLIC:** `cyclic_min_cliffs` (2) or more M9.3 shrink cliffs in the
  training window grade a tablespace CYCLIC instead of resetting; it is judged
  on its per-cycle peaks (`cycle_peak_pct`, `peak_slope_bpd`), and TBSPC_FULL
  fires only when the peak line reaches the ceiling inside `dtf_warn`.
- **CPU gate (M18.2):** `cpu_quality_gate` 1 grades a CPU fit OK when |slope| >
  slope CI (`slope_sig`), and `cpu_deseason` 1 subtracts the weekday /
  weekend mean first (`deseasoned`); both default on. `hot_now` = the recent
  p95 median is at or above `cpu_sat_pct` (CPU_HOT / DBCPU_HOT at any quality).
- **Alert identity:** `CAPR_ALERTS.alert_key` is per row (includes the day,
  consumers hash it); `state_key` (kind|dbid|con_dbid|series|mode) is stable
  across days and is what `cap_results.refresh` MERGEs into `CAP_ALERT_STATE`
  (NEW / ESCALATED / DEESCALATED / RESOLVED after `resolve_grace_runs` misses /
  REOPENED). `ack` / `unack` take a state_key or its last alert_key. The
  anomaly branch collapses consecutive flagged days into one episode row
  (`first_day`, `n_days`, `max_z`) and downgrades a per-day CPU anomaly inside
  an active CPU_SHIFT window to INFO. DATA_STALE is the one deliberate SYSDATE
  test (`stale_hours`); a dbid older than `data_stale_max_days` is retired.
- **M15 hour grain.** `hour_ts = TRUNC(end_time - 5/1440, 'HH24') + 1/24`: the
  bucket is labelled by the interval's END hour, with 5 min of AWR flush
  grace (09:59:58 and 10:00:03 both land in 10:00). `day_dt` stays
  `TRUNC(end_time)`, so a bucket labelled 00:00 can belong to the previous
  day. An interval is a gap at HOUR grain when `ivl_hours <= 0` (DST
  fall-back, clock step) or `> LEAST(cpu_gap_hours, hour_gap_ratio x median
  interval of that instance)`, never more lenient than the day rule.
- **Wall clock labelled Z, everywhere.** AWR times are DB-local DATEs; every
  export stamps them with a `Z` as a label, not an instant (dashboards run in
  UTC: Kibana `dateFormat:tz`, Grafana). HOUR_OF_WEEK's `ts - 7k` follows the
  local clock across DST, as workload does. In repository mode each target's
  times stay on that target's own clock; there is no per-target timezone.
- **`CAPR_ALERTS` anomaly rows come FROM `CAPR_ANOMALIES`, not the reverse.**
  `CAPR_ANOMALIES` owns severity, message and `alerting` (mode enabled by the
  `alert_modes_{tbspc,cpu,series}` bitmask, 1=TRAILING 2=SAME_DOW
  4=HOUR_OF_WEEK, AND inside `anomaly_report_days`); `CAPR_ALERTS` has one
  branch over its `alerting = 'Y'` rows (TBSPC_ANOM, CPU_ANOM, DBCPU_ANOM,
  SERIES_ANOM), an HOUR_OF_WEEK day rolled up to its worst hour.
- **Knob renames (M15):** `tbspc_min_hist` → `trailing_min_hist`,
  `cpu_min_dow_hist` → `weekly_min_hist`. A carry-over MERGE before the seed
  MERGE copies an operator's value to the new key, then the old keys are
  DELETEd. The minimums now belong to the mode, not the series family.
- `SYS.ODCINUMBERLIST` is a shipped `VARRAY(32767) OF NUMBER` and works in
  `TABLE(v)` from PL/SQL — handy for building an expectation list without a
  fixture-owned type. But a collection METHOD (`v.COUNT`) inside a SQL
  statement is ORA-00984 ("column not allowed here"); assign it to a local
  variable first.

## Testing on a 19c test database

Connect where AWR is visible: `sqlplus / as sysdba` in `CDB\$ROOT` (AWR lives
there for local mode).

- **Local smoke** (real AWR): install `deploy_mode=local` as sysdba in CDB\$ROOT,
  run the report. Expect `INSUFFICIENT_HISTORY` everywhere unless retention was
  raised (default 8 days).
- **Fixture harness + ML** need `CREATE TABLE/VIEW/TYPE/PROCEDURE` and (for ML)
  `CREATE MINING MODEL`. `V$*` views are **not** required — the report uses
  `SYS_CONTEXT` for identity. Create a test user in a PDB with those privileges,
  then run: `@test/fixture_install.sql` → `DEFINE deploy_mode=fixture` →
  `@install.sql` → `@test/run_test.sql` (+ `EXEC cap_forecast_ml.train_all` →
  `@test/run_test_ml.sql`). Both exit non-zero on failure and print their own
  totals (`RESULT:` / "All fixture assertions passed."); docs never quote a
  count. Sync the repo to the DB host first because of the relative `@@`
  includes. The full fixture run takes about 20 minutes now.
- **dbmint lever:** `test/dbmint_harness.sh <SCHEMA> [--ml] [--no-fixture]
  [--pga] [--sql FILE]` lints, rsyncs to `~/awr_cap_<schema>/` and runs the steps as
  SYSDBA + `CURRENT_SCHEMA` in PDB1; log `/tmp/dbmint_harness_<SCHEMA>.log`.
  `--pga` ends each step with `test/pga_probe.sql` (the session's peak PGA).
  `CAPX1`..`CAPX3` and `CAPW1`..`CAPW3` in PDB1 are throwaway schemas for
  parallel runs (one schema per concurrent run; ask before dropping them);
  `CAPDEMO` feeds the lab dashboards and `CAPTEST` is the shared default.
  Shared schemas collide (ORA-04063 / ORA-00942 mid-reinstall).
- **Parity lever (M24.5):** `test/dbmint_parity.sh <REPO_SCHEMA> <LOCAL_USER>
  [--seam-only] [--no-install]` prepares cdb1's root as a target (reader
  `C##AWRRDR`, new random password per run), installs local mode into the
  common user (`C##CAPLOC`) and repository mode into the PDB1 schema
  (`CAPX2`), registers the root over a loopback link, collects and diffs
  `test/parity_fingerprint.sql` output: every `CAPV_*` view cut at the
  repository's high-water mark, then every `CAPD/CAPF/CAPA/CAPR` view in two
  parallel sessions (exit 5 = a snapshot landed mid-run, rerun). Logs
  `/tmp/dbmint_parity.*` locally.
- **Scale lever (M24.10):** `test/dbmint_scale.sh CAPX3 <K>`, see
  "Repository mode" below. CAPX3 holds the synthetic targets; CAPX2 must
  have collected cdb1 first (it is the clone source).
- **PGA is the resource that bites.** One suite session peaks at ~1.1-1.3 GB of
  PGA (a report driver, `cap_results.refresh`; `run_test.sql` 1.8 GB), and
  almost none of it is sort/hash work area (largest < 8 MB): it is
  non-tunable memory from parsing and running the deep view stack, kept until
  the session ends, so `pga_aggregate_target` does not cap it and
  `pga_aggregate_limit` must hold background + ~1.5 GB per concurrent suite
  session. Over the limit, sessions sit on "acknowledge over PGA limit" (that
  stalled two parallel harness runs on a 4 GB dbmint with a 2 GB limit).
  Measured figures live in `docs/reference.html#memory`.

## Repository mode (M24)

- **Two deployments.** Standalone = `deploy_mode=local` on the measured
  database. Target + repository: the target gets only `target/prepare.sql`
  (a read-only common user, direct SELECT on the seventeen views, nothing
  else) and the repository runs the suite with `deploy_mode=repository` over
  `CAP_H_*` copies that `cap_repo.collect` pulls over one DB link per target.
  `install.sh` asks the role first (standalone / target / repository /
  fixture); profiles `standalone.env`, `target.env`,
  `repository.env`. A repository install's closing banner names
  `cap_repo.add_target` / `collect` as the next step.
- **`repository/build.py` owns the copy contract.** Its manifest lists each
  source view's copied columns, kind (F fact appended per snap_id window, D
  dimension MERGEd null-safe on its key, S dimension scoped to a fact's
  chunk: SEG_STAT_OBJ) and row filter (a superset of ddl/10's). It writes
  `ddl/13_seam_repository.sql`: the copy tables (created once, columns only
  ever added), `CAP_REPO_SOURCE` (the finished pull statements) and the seam,
  which is ddl/10 with `dba_hist_x` renamed `cap_h_x`. Never edit ddl/13;
  change the manifest or ddl/10 and rerun it. `--check` (also run by both
  dbmint scripts) fails on a stale ddl/13 or when ddl/10, target/prepare.sql
  or create_owner.sql name other views than the manifest.
- **CONTAINER_DATA (verified 19.27).** A common user without `CONTAINER_DATA
  = ALL` that reads `DBA_HIST_*` in CDB$ROOT sees the root's rows only (1
  container instead of 3). The filter follows the querying session, so SYS
  through a view sees everything while the owner's own sessions and jobs do
  not. `target/prepare.sql` and `create_owner.sql` (local mode) both set it.
- **AWR purges its tables unevenly.** `DBA_HIST_CON_SYSSTAT` kept rows for
  snapshots 2657..2695 after they had left `DBA_HIST_SNAPSHOT` (which shows
  only `status = 0`, completed, snapshots). The collector's window therefore
  starts at the high-water mark (0 on the first collect), not at the oldest
  snapshot, so the copies hold exactly what the target's views show.
- **Links.** `cap_repo` is definer's rights, so `CREATE DATABASE LINK` in
  `add_target` creates the link in the suite owner's schema even when SYS
  calls it under `CURRENT_SCHEMA` (needs the privilege granted directly;
  `create_owner.sql` with `owner_mode = repository`). With a `db_domain`
  the link is stored as `CAP_<NAME>.<domain>`; the bare name resolves.
- **Fleet identity (M24.6).** `CAPV_TARGET` (one row per target and dbid:
  name, `feed`, AWR host, and in repository mode link, `enabled`, high-water
  mark and collect health from `CAP_COLLECT_LOG` since `added_at`) is in
  every seam; the repository version is `repository/seam_overrides.sql`,
  which build.py puts in ddl/13 in place of ddl/10's (`--check` fails on an
  override ddl/10 lacks), so ddl/13 includes `cap_repo.sql` before the seam.
  `CAPR_CONTAINER.target_name` (last column) names `db_pdb`; `CAPR_TARGETS`
  adds freshness and `collect_state`. `report/scope.sql` gives all four
  drivers their scope and Database / Host / file stem from it, and resolves a
  target name passed as the dbid argument (`run_report.sh --target`;
  unknown name = ORA-20003). DATA_STALE names the target, says why the copy
  stopped and is silent for a disabled target. The parity fingerprint skips
  CAPV_TARGET / CAPR_TARGETS (they differ by design). Keep the override's
  collect-health columns as scalar subqueries (index `CAP_COLLECT_LOG_IX`):
  the optimizer drops an unselected one, so `CAPR_CONTAINER` (read by every
  report view, wants only `target_name`) never touches the log. As joins to
  aggregated CTEs they were materialised on every read (19.27 plan).
  `test/repo_synth_target.sql NAME DBID SHIFT_DAYS` clones a collected
  target's copies under a fake target (a fleet from one database).
- **Jobs, retention, doctor (M24.7).** `cap_repo.purge(p_days)` deletes the
  F (fact) copies of snapshots older than `repo_retention_days` (400; 0 =
  keep) per DBID, cut at the first snap_id that ended inside the window, the
  SNAPSHOT copy last, plus older `CAP_COLLECT_LOG` rows, in one transaction,
  and logs PURGED (target NULL, so `CAPV_TARGET` ignores it). D/S copies
  stay. It refuses a knob `CAP_CFG_CHECK` calls BAD (below the longest
  doctor section 7 need). No lock against collect, which only inserts above
  the high-water mark. `cap_repo.ping(name)` returns NULL or the probe's
  error: doctor runs as SYSDBA, and a private link resolves only for its
  owner. `install_jobs.sql` adds `CAP_COLLECT_JOB` / `CAP_PURGE_JOB` only
  where package `CAP_REPO` exists; doctor section 10 checks them and section
  11 checks each target (link, collect state, staleness, gaps, days per
  DBID vs section 7's needs, which `CAP_CFG_CHECK` mirrors).
- **Scale (M24.10).** `test/repo_synth_target.sql NAME DBID SHIFT [DAYS]
  [SOURCE_SCHEMA]` stacks a collected target's copies back to DAYS (37-day
  blocks, snap_ids 100000 apart); `test/dbmint_scale.sh <SCHEMA> <K>
  [--steps ...]` grows CAPX3 to K such targets and times train_all,
  refresh and the reports (live, one target, SNAPSHOT) with `pga_probe.sql`,
  appending to `/tmp/dbmint_scale_<SCHEMA>.tsv`. Measured: linear, ~7 min of
  nightly work per 144-day target on 2 vCPU, PGA flat at 490-640 MB
  (reference.html#fleet-size). A `--target` report costs a fleet report:
  the section views rank across all targets (PLAN.md M24.11).
- **Not yet built:** PLAN.md M24.11 (a target's report at a target's cost)
  and M24.12 (chain the jobs for a fleet).
  RAC: one high-water mark per DBID, so a snapshot that completes on one
  instance before another could be copied half; untested.

## Not yet built (see PLAN.md milestones)

- Memory forecasting (v2 scope; the 19c source is `DBA_HIST_MEM_DYNAMIC_COMP`,
  plus `DBA_HIST_PGASTAT`). Cross-DBID series stitching (v2).
