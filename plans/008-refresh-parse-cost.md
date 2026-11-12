# Plan 008: Cut the refresh's hard-parse cost — a slim CAPR_COVERAGE now, a measured optimizer-hint decision next

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **This plan has two parts.** Part A is a code change you finish. Part B is
> a measurement that ends in a report; you change code in Part B **only** if
> the operator's row for this plan in `plans/README.md` says
> `Part B: apply approved`.
>
> **Drift check (run first)**:
> `git diff --stat d91e3f8..HEAD -- ddl/60_results.sql ddl/45_report_views.sql test/run_test.sql`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: Part A: S. Part B: M (measurement on the test VM)
- **Risk**: Part A: LOW. Part B: MED (an optimizer underscore parameter in shipped code is the maintainer's call)
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `d91e3f8`, 2026-11-10

## Why this matters

The nightly `cap_results.refresh` copies 26 report views into snapshot
tables, one `INSERT ... SELECT` per view. A measurement on 2026-11-08 (one
target, 35 days) showed that **hard parse is 80-95% of each heavy
statement**: `capr_fit` parses in 9.5 s and executes in 0.8 s,
`capr_coverage` 10.6 s / 0.8 s, `capr_forecast_points` 9.4 s / 2.2 s, with
150-340 MB of PGA per parse. Two facts from that analysis drive this plan:

1. `CAPR_COVERAGE` embeds the whole of `CAPR_FIT` (six forecast-view
   expansions) only to count series by quality. It can count from the three
   forecast views directly (three expansions, no severity logic).
2. Turning the optimizer's cost-based query transformation off for one
   statement cut `capr_fit`'s parse from 9.2 s to 2.5 s and its PGA from 315
   to 148 MB with the execution time unchanged. Whether that holds for all 26
   snapshot statements has not been measured.

## Current state

### Part A

`ddl/60_results.sql`, view `CAPR_COVERAGE` (starts line 370). Its second CTE
(lines 376-387):

```
     fit AS (
        SELECT dbid,
               COUNT(*)                                                       AS n_series,
               COUNT(CASE WHEN quality = 'OK'                   THEN 1 END)   AS n_ok,
               COUNT(CASE WHEN quality = 'LOW_CONFIDENCE'       THEN 1 END)   AS n_low_confidence,
               COUNT(CASE WHEN quality = 'FLAT'                 THEN 1 END)   AS n_flat,
               COUNT(CASE WHEN quality = 'INSUFFICIENT_HISTORY' THEN 1 END)   AS n_insufficient,
               COUNT(CASE WHEN quality = 'CYCLIC'               THEN 1 END)   AS n_cyclic,
               COUNT(CASE WHEN is_current = 0                   THEN 1 END)   AS n_stale
        FROM   capr_fit
        GROUP  BY dbid
     ),
```

`CAPR_FIT` (`ddl/45_report_views.sql`, ends near line 1366) is exactly one
row per row of three forecast views, plus two lookups that cannot add or
drop a row:

```
FROM  (
        SELECT t.dbid, t.con_dbid, 'TBSPC' AS kind, ... t.quality, ...
               CASE t.is_current WHEN 'Y' THEN 1 ELSE 0 END       AS is_current, ...
        FROM   capf_tbspc_forecast t
        UNION ALL
        SELECT t.dbid, t.con_dbid, 'CPU', ... t.quality, ...
               CASE t.is_current WHEN 'Y' THEN 1 ELSE 0 END, ...
        FROM   capf_cpu_trend t
        CROSS  JOIN cap_cfg cfg
        UNION ALL
        SELECT t.dbid, t.con_dbid, 'SERIES', ... t.quality, ...
               CASE t.is_current WHEN 'Y' THEN 1 ELSE 0 END, ...
        FROM   capf_series_forecast t
      ) f
LEFT   JOIN (SELECT fit_kind, dbid, con_dbid, series_key, MIN(sev_rank) AS sev_rank
             FROM   capr_severity
             GROUP  BY fit_kind, dbid, con_dbid, series_key) s
  ON   ...
LEFT   JOIN capr_container c
  ON   c.dbid = f.dbid AND c.con_dbid = f.con_dbid;
```

(`CAP_CFG` has one row; the severity subquery is grouped on its join key;
`CAPR_CONTAINER` has one row per container.) So counting `quality` and
`is_current` over the three `CAPF_` views gives the same numbers.

### Part B

`ddl/60_results.sql`, procedure `cap_results.refresh`, lines 963-970:

```
            -- The <view>_S tables are re-created by every install, hence
            -- dynamic SQL wherever this body touches them.
            FOR i IN 1 .. l_views.COUNT LOOP
                DBMS_APPLICATION_INFO.SET_ACTION('snapshot ' || LOWER(l_views(i)));
                EXECUTE IMMEDIATE 'DELETE FROM ' || l_views(i) || '_S';
                EXECUTE IMMEDIATE 'INSERT INTO ' || l_views(i) || '_S SELECT :r, v.* FROM ' || l_views(i) || ' v'
                    USING l_run;
            END LOOP;
```

The view list is `cap_results.snap_views` (same file, line 698): CAPR_CONTAINER,
CAPR_FIT, CAPR_ALERTS, CAPR_COVERAGE, CAPR_DATA_WINDOW, CAPR_TBSPC_DAYS_TO_FULL,
CAPR_TBSPC_RANK, CAPR_TBSPC_FORECAST, CAPR_TBSPC_ANOMALIES, CAPR_CPU_TREND,
CAPR_CPU_ANOMALIES, CAPR_CPU_SHIFTS, CAPR_ESM_COMPARE, CAPR_BACKTEST,
CAPF_ESM_HEALTH_SUMMARY, CAPR_SERIES, CAPR_SERIES_ANOMALIES, CAPR_ANOMALIES,
CAPR_SERIES_POINTS, CAPR_FORECAST_POINTS, CAPR_HOURLY_POINTS,
CAPR_SEGMENT_GROWTH, CAPR_MEM_VERDICT, CAPR_MEM_EVIDENCE, CAPR_MEM_COMPONENTS,
CAPR_MEM_COMP_POINTS.

Measurement lever (on the test VM, not in this repository):
`~/awrcap_probe/run_probe.sh <PDB> <SCHEMA> <tag> TYPICAL|ALL view...` runs
one session per view and prints `parse_s`, `exec_s`, logical reads, temp and
PGA; `~/awrcap_probe/run_variants.sh <PDB> <SCHEMA> <view> base nocbqt ofe112 ...`
runs one view under several optimizer settings (`nocbqt` =
`_optimizer_cost_based_transformation` off). Both are read-only.

Known dead end, do not try: forcing the views' CTEs inline
(`_with_subquery = INLINE`) never finished; the materialized CTEs are
load-bearing.

Conventions that apply:

- **SNAPSHOT parity**: `test/snapshot_parity.sh` (harness flag `--parity`)
  diffs reports read live against reports read from the snapshot tables;
  `test/run_test.sql` compares `<view>_S` tables with their views.
- Every analytic window partitions by `dbid`; 19c syntax floor; a `--`
  comment line inside a plain-SQL `CREATE VIEW` must not end in `;`.
- The six "APEX contract" views (`CAPR_SERIES_POINTS`, `CAPR_FORECAST_POINTS`,
  `CAPR_FIT`, `CAPR_ANOMALIES`, `CAPR_ALERTS`, `CAPR_CONTAINER`) may only gain
  columns. This plan changes none of their columns.

## Commands you will need

| Purpose | Command (repo root) | Expected on success |
|---|---|---|
| Offline lints | `test/lint_dbid_windows.sh && test/lint_snapshot_reads.sh && test/lint_anom_joins.sh && test/lint_appinfo.sh && test/docs_lint.sh` | exit 0 |
| Database harness + parity | `test/dbmint_harness.sh <SCHEMA> --parity` | `RESULT: <n> passed, 0 failed`, parity reports equal, `(exit 0)` |
| Probe (Part B) | `ssh -p 2200 oracle@dbmint '~/awrcap_probe/run_variants.sh PDB1 <SCHEMA> <view> base nocbqt'` | a table with `parse_s` / `exec_s` per variant |

The harness needs the maintainer's VM and a throwaway PDB1 schema the
operator assigns (`CAPX1`..`CAPX3`, `CAPW1`..`CAPW3`; never `CAPDEMO` /
`CAPTEST`). About 35 minutes. "Could not resolve hostname" can be your tool
sandbox: retry outside it.

## Scope

**In scope**: `ddl/60_results.sql`. Part B, only when approved: the same
file's `refresh` loop, plus one new assertion block in `test/run_test.sql`.

**Out of scope**: `ddl/45_report_views.sql`, `ddl/30`, `ddl/50`, `ddl/55`
(the structural rewrites listed in "Maintenance notes" are deliberately not
planned); session-level `ALTER SESSION` changes; any hint inside a view.

## Git workflow

- Branch: `advisor/008-refresh-parse-cost`
- One commit for Part A. Part B, if applied, a second commit whose body
  quotes the measured totals.
- Do NOT push or open a PR unless the operator instructed it.

## Part A — Steps

### Step A1: `CAPR_COVERAGE` counts from the forecast views

Replace `FROM   capr_fit` in the `fit` CTE by an inline union, and compare
`is_current` with `'N'` (the `CAPF_` views carry `'Y'` / `'N'`):

```
     fit AS (
        SELECT dbid,
               COUNT(*)                                                       AS n_series,
               COUNT(CASE WHEN quality = 'OK'                   THEN 1 END)   AS n_ok,
               COUNT(CASE WHEN quality = 'LOW_CONFIDENCE'       THEN 1 END)   AS n_low_confidence,
               COUNT(CASE WHEN quality = 'FLAT'                 THEN 1 END)   AS n_flat,
               COUNT(CASE WHEN quality = 'INSUFFICIENT_HISTORY' THEN 1 END)   AS n_insufficient,
               COUNT(CASE WHEN quality = 'CYCLIC'               THEN 1 END)   AS n_cyclic,
               COUNT(CASE WHEN is_current = 'N'                 THEN 1 END)   AS n_stale
        FROM  ( SELECT dbid, quality, is_current FROM capf_tbspc_forecast
                UNION  ALL
                SELECT dbid, quality, is_current FROM capf_cpu_trend
                UNION  ALL
                SELECT dbid, quality, is_current FROM capf_series_forecast )
        GROUP  BY dbid
     ),
```

In the view's header comment add one line: `-- The series counts read the
three CAPF_ forecast views, the rows CAPR_FIT is built from, without its
severity lookup.` (Write it as one or more `--` lines; none may end in `;`.)

Also correct the sentence in the `refresh` comment of the package
specification (line 630-631) that says "so each view is evaluated once per
run": change "each view is evaluated once per run" to "the fits, the alert
merge and the coverage are not evaluated a second time".

**Verify**: `grep -c "FROM   capr_fit" ddl/60_results.sql` → one less than
before your edit (run it before and after);
`test/lint_dbid_windows.sh && test/lint_snapshot_reads.sh` → exit 0.

### Step A2: Database gate

`test/dbmint_harness.sh <SCHEMA> --parity` → `0 failed`, parity equal,
`(exit 0)`. The existing `CAPR_COVERAGE` assertions in `test/run_test.sql`
(`grep -n "capr_coverage" test/run_test.sql`) prove the counts are unchanged;
do not edit them.

## Part B — Steps (measurement; code only with approval)

### Step B1: Read the lever

`ssh -p 2200 oracle@dbmint 'ls ~/awrcap_probe && sed -n 1,40p ~/awrcap_probe/run_variants.sh'`.
Confirm it is read-only (it must only `SELECT` / `EXPLAIN`) and how it names
its output. If the directory does not exist, STOP: the lever is gone.

### Step B2: Measure all 26 snapshot views, `base` against `nocbqt`

Use the schema the operator names for measurement (a repository schema with
real copies; the maintainer's is `CAPX2`). For each view in the list under
"Current state": `run_variants.sh PDB1 <SCHEMA> <view> base nocbqt`. Run
them one after another, not in parallel (2 vCPUs, and each session can take
1 GB of PGA). Record per view: `parse_s`, `exec_s`, PGA for both variants.

### Step B3: Report, and stop

Write the table into your hand-back with three totals: sum of
`parse_s + exec_s` for `base`, the same for `nocbqt`, and the list of views
where `nocbqt` executes more than 1.5x slower than `base`. Add the decision
this plan recommends by rule:

- **Apply** when the `nocbqt` total is at most 70% of the `base` total and
  no view is in the "1.5x slower" list.
- **Apply per view** when the total qualifies but some views are slower:
  hint every view except those.
- **Do not apply** otherwise.

Mark the plan `BLOCKED (Part B: awaiting operator decision)` unless the
`plans/README.md` row already says `Part B: apply approved`.

### Step B4 (only with `Part B: apply approved`): hint the snapshot INSERT

In the `refresh` loop, build the statement with a statement-level hint for
the approved views. Add to the declarations of `refresh`:

```
        c_nocbqt CONSTANT VARCHAR2(80) :=
            '/*+ OPT_PARAM(''_optimizer_cost_based_transformation'' ''off'') */ ';
```

and change the INSERT to (all views approved):

```
                EXECUTE IMMEDIATE 'INSERT ' || c_nocbqt || 'INTO ' || l_views(i)
                                  || '_S SELECT :r, v.* FROM ' || l_views(i) || ' v'
                    USING l_run;
```

For "apply per view", wrap the hint in
`CASE WHEN l_views(i) NOT IN ('<VIEW>', ...) THEN c_nocbqt END`.

Check that Oracle accepts the hint where you put it, on the test VM, for one
view (19c reports unused hints):

```
EXPLAIN PLAN FOR
INSERT /*+ OPT_PARAM('_optimizer_cost_based_transformation' 'off') */ INTO capr_fit_s
SELECT 0, v.* FROM capr_fit v;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(format => 'BASIC +HINT_REPORT'));
ROLLBACK;
```

The "Hint Report" section must list the `OPT_PARAM` hint without `U -
Unused` or `E - Syntax error`. If it is unused there, try it directly after
`SELECT` instead, re-check, and use the position that is reported as used.

Then `test/dbmint_harness.sh <SCHEMA> --parity` → `0 failed`, parity equal
(the snapshot rows must be the same rows as before, whatever the plan).
Compare the refresh step's elapsed time in the harness log with Part A's run.

## Test plan

- Part A: existing `CAPR_COVERAGE` assertions and the snapshot parity diff.
- Part B4: the same gates; results must not change, only time. No new
  assertion is needed (a hint cannot change a result set; parity proves it).

## Done criteria

- [ ] Part A: `CAPR_COVERAGE` no longer reads `capr_fit`; offline lints exit 0
- [ ] Part A: `test/dbmint_harness.sh <SCHEMA> --parity` → `0 failed`, `(exit 0)`
- [ ] Part B: the 26-row table and the three totals are in the hand-back
- [ ] Part B4 only if approved: hint reported as used; harness + parity green
- [ ] `git status --short` lists only in-scope files
- [ ] `plans/README.md` status row updated (`DONE`, or `BLOCKED (Part B: awaiting operator decision)`)

## STOP conditions

- A `CAPR_COVERAGE` assertion fails after step A1: the "same rows" argument
  is wrong somewhere (a forecast view yields a row `CAPR_FIT` drops, or the
  reverse). Revert A1 and report the counts per `dbid` from both forms.
- The probe lever is missing, writes anything, or needs a privilege you do
  not have.
- You are about to add the hint without the approval marker.
- You are about to put a hint inside a view, or set the parameter with
  `ALTER SESSION` in `refresh` (rejected: a session setting would leak into
  every later statement of a nightly job session).

## Maintenance notes

Structural causes of the parse cost that this plan leaves alone, with where
they are, for a later, separately measured change. Each rewrites the largest
cursors of the suite and needs the probe before and after:

- `CAPR_SEVERITY` (`ddl/45_report_views.sql:401,438,499`) unions all three
  forecast families, and each family's section view
  (`:678`, `:763`, `:904`) joins it for its own `fit_kind` only: every
  family statement parses the other two families as well.
- `CAPR_FIT` reads the three forecast views (`:1329,1346,1359`) and then
  `CAPR_SEVERITY` (`:1361-1363`), which reads them again: six expansions.
- `UNION ALL` unpivots re-read one view per branch:
  `capf_cpu_trend`'s `src` (`ddl/30_forecast_views.sql:760-778`, six reads of
  the daily views), `capf_compare` (`ddl/50_ml.sql:400-421`),
  `CAPR_FORECAST_POINTS` (`ddl/55_report_views_ml.sql:300-348`).
- An `OPT_PARAM` hint in the report drivers' LIVE statements is a possible
  follow-up if Part B's numbers are good; SNAPSHOT reports already avoid the
  cost entirely.
