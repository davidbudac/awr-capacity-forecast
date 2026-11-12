# Plan 006: The memory verdict views stop computing increments for startups that ended before the evidence window

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat d91e3f8..HEAD -- ddl/42_memory_views.sql ddl/45_report_views.sql report/drill_mem.sql test/run_test.sql`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S-M (small edit; two 30-minute database runs to measure)
- **Risk**: LOW (the change is exactly result-preserving; every existing assertion must pass unchanged)
- **Depends on**: none (land before plan 007: both edit `ddl/42_memory_views.sql`)
- **Category**: perf
- **Planned at**: commit `d91e3f8`, 2026-11-10

## Why this matters

The memory sizing views (`CAPM_*`, `ddl/42_memory_views.sql`) grade an
instance from the last `mem_window_days` (30) days of AWR. But their
increment logic runs five analytic sorts over **every** snapshot the
repository holds (retention 400 days) and only afterwards throws away the
rows outside the window. Measured cost: `CAPR_MEM_VERDICT` 28 s and
`CAPR_MEM_EVIDENCE` 16 s on 150 days of hourly snapshots, growing with
history instead of with the window.

This plan removes the part of that work that is provably unused: snapshots
of instance startups that ended before the window began. It changes no
result. (It does not help an instance that has been up for the whole
history; see "Maintenance notes" for why the more aggressive cut was not
planned.)

## Current state

`ddl/42_memory_views.sql` — the layer, bottom up: `CAPM_SNAP` (one row per
snapshot) → `CAPM_DELTA` (every counter as increments) → `CAPM_ADVICE`,
`CAPM_PGA_LIMIT`, `CAPM_COMP`, ... → `CAPM_EVIDENCE` → `CAPM_VERDICT`.

`CAPM_SNAP`, lines 55-93 (abridged):

```
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
               LAG(s.end_time) OVER (...same partition...)                   AS prev_end_time,
               (MAX(s.end_time) OVER (PARTITION BY s.dbid, s.instance_number, s.startup_time)
                - NVL(s.startup_dt,
                      MIN(s.end_time) OVER (PARTITION BY s.dbid, s.instance_number, s.startup_time))
               ) * 24                                                        AS uptime_hours
        FROM   s
     )
SELECT a.dbid, a.instance_number, a.snap_id, a.end_time, a.startup_time, a.startup_dt,
       a.prev_snap_id, a.prev_end_time,
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
```

Three places join `CAPM_SNAP` and then run window functions (`LAG`, `MAX ...
OVER`) over the joined rows, all partitioned by `startup_time`:

1. `CAPM_DELTA`, CTE `lagged`, lines 284-306:
   ```
        FROM   src c
        JOIN   capm_snap s
          ON   s.dbid = c.dbid AND s.instance_number = c.instance_number
         AND   s.snap_id = c.snap_id
     ),
   ```
2. `CAPM_PGA_LIMIT`, CTE `ps`, lines 643-650:
   ```
        FROM   capm_snap w
        JOIN   pga p
          ON   p.dbid = w.dbid AND p.instance_number = w.instance_number
         AND   p.snap_id = w.snap_id
     ),
   ```
3. `CAPM_COMP`, CTE `mc`, lines 872-886:
   ```
        FROM   capv_mem_comp m
        JOIN   capm_snap s
          ON   s.dbid = m.dbid AND s.instance_number = m.instance_number
         AND   s.snap_id = m.snap_id
        WHERE  m.component NOT IN ('SGA Target', 'PGA Target')
     )
   ```

Why skipping old startups cannot change a result (the proof the reviewer
will ask for):

- Every window function in those three CTEs partitions by
  `(dbid, instance_number, startup_time, ...)`: a row is only ever paired
  with rows of its own startup.
- Every reader of their output keeps only rows with `in_win = 'Y'`. At
  planning time the complete list was: `ddl/42_memory_views.sql` lines 406
  and 1244 (`capm_delta`), 657 / 663 / 678 (`ps`), 937 (`capm_comp`);
  `ddl/45_report_views.sql` lines 1576 and 1626 (`capm_comp`);
  `report/drill_mem.sql` line 412 (`capm_comp`).
- A startup whose newest snapshot ended at or before `window_start` has no
  `in_win = 'Y'` row. Dropping all its rows therefore removes only rows that
  were never read and never paired with a row that is read.

Rules of this file (from `CLAUDE.md`, "Memory verdicts"):

- "Increments only. Nothing is differenced across a restart."
- "Time `capm_advice`, `capm_area` AND `capm_verdict` after any change here;
  the plans differ."
- Every analytic window partitions by `dbid` (`test/lint_dbid_windows.sh`).
- 19c syntax floor; the file runs with `SET DEFINE OFF`; a `--` comment line
  must not end in `;`.
- Views may gain columns; add new ones last.

## Commands you will need

| Purpose | Command (repo root) | Expected on success |
|---|---|---|
| Offline lints | `test/lint_dbid_windows.sh && test/lint_appinfo.sh && test/lint_anom_joins.sh && test/lint_snapshot_reads.sh && test/docs_lint.sh` | exit 0 |
| Database harness + timing | `test/dbmint_harness.sh <SCHEMA> --sql test/mem_timing.sql` | `RESULT: <n> passed, 0 failed`, `(exit 0)`; timings in `/tmp/dbmint_harness_<SCHEMA>.log` |

The harness needs the maintainer's VM (`ssh -p 2200 oracle@dbmint`) and a
throwaway PDB1 schema the operator assigns (`CAPX1`..`CAPX3`,
`CAPW1`..`CAPW3`; never `CAPDEMO` / `CAPTEST`). About 30 minutes a run. Do
not run it while another harness run is active on the VM if you can avoid it
(2 vCPUs: timings double). "Could not resolve hostname" can be your tool
sandbox: retry outside it.

## Scope

**In scope**: `ddl/42_memory_views.sql`, `test/run_test.sql` (two new
assertions), `test/mem_timing.sql` (create).

**Out of scope**: `CAPM_ADVICE`, `CAPM_AREA`, `CAPM_EVIDENCE`, `CAPM_VERDICT`
and every other view body; `ddl/45_report_views.sql`; `report/drill_mem.sql`;
`CLAUDE.md` and `docs/` (report the measured numbers in your hand-back; the
maintainer records them).

## Git workflow

- Branch: `advisor/006-memory-skip-old-startups`
- Commits: (1) `test/mem_timing.sql`, (2) the view change + assertions.
  Style: imperative subject, bullet body.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the timing lever and take the baseline

Create `test/mem_timing.sql` (model the header on `test/pga_probe.sql`):

```
-- =====================================================================
-- test/mem_timing.sql -- elapsed time of the memory verdict views.
-- =====================================================================
-- Read-only. Run in the suite's schema (SYSDBA + CURRENT_SCHEMA, or the
-- owner): test/dbmint_harness.sh <SCHEMA> --sql test/mem_timing.sql
-- Each view is read once, in a fixed order, COUNT(*) only. The first read
-- of a view pays its hard parse.
SET APPINFO OFF
SET APPINFO "AWRCAP/test/mem_timing.sql"
SET FEEDBACK OFF
SET TIMING ON
PROMPT ==== mem_timing: capm_delta ====
SELECT COUNT(*) AS capm_delta_rows FROM capm_delta;
PROMPT ==== mem_timing: capm_comp ====
SELECT COUNT(*) AS capm_comp_rows FROM capm_comp;
PROMPT ==== mem_timing: capm_advice ====
SELECT COUNT(*) AS capm_advice_rows FROM capm_advice;
PROMPT ==== mem_timing: capm_area ====
SELECT COUNT(*) AS capm_area_rows FROM capm_area;
PROMPT ==== mem_timing: capm_verdict ====
SELECT COUNT(*) AS capm_verdict_rows FROM capm_verdict;
PROMPT ==== mem_timing: capr_mem_verdict ====
SELECT COUNT(*) AS capr_mem_verdict_rows FROM capr_mem_verdict;
PROMPT ==== mem_timing: capr_mem_evidence ====
SELECT COUNT(*) AS capr_mem_evidence_rows FROM capr_mem_evidence;
SET TIMING OFF
SET FEEDBACK ON
```

**Verify**: `test/lint_appinfo.sh && test/lint_snapshot_reads.sh` → exit 0.

Baseline (before any view edit): `test/dbmint_harness.sh <SCHEMA> --sql test/mem_timing.sql`
→ `0 failed`. Save the seven `Elapsed:` lines and the seven row counts:
`grep -A4 "mem_timing:" /tmp/dbmint_harness_<SCHEMA>.log > "${TMPDIR:-/tmp}/p006_before.txt"`.

### Step 2: `CAPM_SNAP` says whether a snapshot's startup reaches the window

In `CAPM_SNAP`:

(a) In CTE `a`, add one more column after `latest_snap_id`:

```
               MAX(s.end_time) OVER (PARTITION BY s.dbid, s.instance_number, s.startup_time)
                                                                             AS seg_end,
```

(b) In the final SELECT, add as the **last** column (after `seg_ok`):

```
       CAST(CASE WHEN a.seg_end > a.window_end - cfg.mem_window_days THEN 'Y' ELSE 'N' END
            AS VARCHAR2(1))                                  AS seg_in_win
```

(put a comma after the `seg_ok` expression).

(c) In the view's header comment (it starts at line 40, "CAPM_SNAP -- one row
per (dbid, instance_number, snap_id)."), add:

```
--   seg_in_win          Y when the snapshot's startup has a snapshot inside
--                       the window. The increment views read only those
--                       startups: every reader keeps in_win = Y rows and no
--                       increment crosses a restart, so the rest is unused.
```

**Verify**: `test/lint_dbid_windows.sh` → `lint_dbid_windows: OK`.

### Step 3: The three increment CTEs skip startups outside the window

1. `CAPM_DELTA.lagged`: append to the `ON` clause of `JOIN capm_snap s`:
   `AND   s.seg_in_win = 'Y'`
2. `CAPM_PGA_LIMIT.ps`: add after the join's `ON` clause:
   `WHERE  w.seg_in_win = 'Y'`
3. `CAPM_COMP.mc`: append to the existing `WHERE`:
   `AND  s.seg_in_win = 'Y'`

Touch no other join to `capm_snap` (the others already filter `in_win = 'Y'`
or read only the latest snapshot).

**Verify**: `grep -c "seg_in_win = 'Y'" ddl/42_memory_views.sql` → `3`. Then
re-run the reader audit and compare with the list in "Current state":
`grep -n "FROM   capm_delta\|FROM   capm_comp\|FROM   ps\b\|FROM   hwm_lag" ddl/42_memory_views.sql ddl/45_report_views.sql report/drill_mem.sql`
— every hit must be followed within three lines by an `in_win = 'Y'`
predicate, except `hwm_lag AS (... FROM ps x WHERE x.hwm IS NOT NULL)`, whose
own reader (`hwm_peak`) filters `in_win = 'Y'`.

### Step 4: Two assertions in `test/run_test.sql`

Find the memory block that already reads `capm_snap` (search
`FROM capm_snap WHERE dbid = v_dbid;`, near line 2125). Directly after the
first assertion that follows that query, add:

```
        SELECT COUNT(CASE WHEN in_win = 'Y' AND seg_in_win = 'N' THEN 1 END),
               COUNT(CASE WHEN seg_in_win = 'N' THEN 1 END)
          INTO v_n, v_num
          FROM capm_snap WHERE dbid = v_dbid;
        chk_int('CAPM_SNAP: no window snapshot in a skipped startup', v_n, 0);
        chk_true('CAPM_SNAP: the startup before the day-60 restart is skipped (' || v_num || ' snapshots)',
                 v_num > 0);
```

`v_n`, `v_num`, `v_dbid`, `chk_int`, `chk_true` exist in the block. The
fixture restarts at day 60 and day 110 of about 120 days, and the window is
30 days, so the first startup lies wholly before it.

### Step 5: Database gate and measurement

`test/dbmint_harness.sh <SCHEMA> --sql test/mem_timing.sql` → `0 failed`,
`(exit 0)`. Then:

```
grep -A4 "mem_timing:" /tmp/dbmint_harness_<SCHEMA>.log > "${TMPDIR:-/tmp}/p006_after.txt"
diff <(grep -A2 "_rows" "${TMPDIR:-/tmp}/p006_before.txt" | grep -v Elapsed) \
     <(grep -A2 "_rows" "${TMPDIR:-/tmp}/p006_after.txt"  | grep -v Elapsed)
```

Expected: `capm_delta_rows` and `capm_comp_rows` are **smaller** after (rows
of the skipped startup are gone); `capm_advice_rows`, `capm_area_rows`,
`capm_verdict_rows`, `capr_mem_verdict_rows`, `capr_mem_evidence_rows` are
**identical**. Put both timing tables (seven `Elapsed:` values before and
after) in your hand-back.

## Test plan

- The proof of "no result changed" is the existing memory section of
  `test/run_test.sql` (closed forms for every verdict, evidence value and
  advisor curve) passing with zero edits, plus the identical row counts of
  step 5.
- New: the two `CAPM_SNAP` assertions of step 4.

## Done criteria

- [ ] `grep -c "seg_in_win = 'Y'" ddl/42_memory_views.sql` → `3`
- [ ] Offline lints exit 0
- [ ] `test/dbmint_harness.sh <SCHEMA> --sql test/mem_timing.sql` → `0 failed`, `(exit 0)`
- [ ] The five downstream row counts are identical before and after
- [ ] No existing assertion in `test/run_test.sql` was edited (`git diff test/run_test.sql` shows additions only)
- [ ] Hand-back contains the before / after timing table
- [ ] `plans/README.md` status row updated

## STOP conditions

- The reader audit of step 3 finds a read of `capm_delta`, `capm_comp` or
  `ps` without an `in_win = 'Y'` filter: the proof no longer holds. Revert
  step 3 and report the line.
- Any existing memory assertion fails after the change. Do not adjust an
  expectation; report the `FAIL` lines.
- A view becomes much slower (any `Elapsed` more than 1.5x its baseline with
  no other harness running): the optimizer picked a worse plan. Report the
  timings; do not add hints.

## Maintenance notes

- This saves nothing for an instance whose current startup spans the whole
  history. The larger saving would be to start the increments at the last
  snapshot before the window ("lead snapshot"). It was not planned because
  it is not result-preserving: a counter that AWR omits while zero
  (`zero_fill` sources: PGA statistics, wait events, DB time) would have its
  first *visible* row counted in full even though it had earlier rows, and a
  ragged advisor size would lose the increment that reaches back past the
  lead. Doing it right needs, per zero-fill key, its first snapshot in the
  startup (one cheap aggregate over those sources) and a decision about the
  ragged-size edge. Measure on a long-uptime copy first
  (`test/dbmint_scale.sh`, agentboard todo #47).
- A second cost, also not addressed here: `CAPM_VERDICT` evaluates
  `CAPM_AREA` twice, and a refresh evaluates the verdict stack once for
  `CAPR_MEM_VERDICT` and again for `CAPR_MEM_EVIDENCE`.
- A new reader of `CAPM_DELTA` / `CAPM_COMP` that wants rows outside the
  window would silently miss old startups: the `seg_in_win` comment in
  `CAPM_SNAP` is the warning.
