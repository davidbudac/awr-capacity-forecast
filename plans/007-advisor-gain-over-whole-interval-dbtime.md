# Plan 007: An advisor gain is divided by the DB time of the same interval, also when the interval spans several snapshots

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat d91e3f8..HEAD -- ddl/42_memory_views.sql test/run_test.sql`
> Plan 006 edits the same file (views `CAPM_SNAP`, `CAPM_DELTA`,
> `CAPM_PGA_LIMIT`, `CAPM_COMP`); that is expected. For anything inside
> `CAPM_ADVICE`, compare the "Current state" excerpts against the live code
> before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S-M
- **Risk**: MED (moves SGA / buffer cache / shared pool gain percentages on real data wherever an advisor row was missing)
- **Depends on**: plans/006-memory-views-skip-old-startups.md (same file; land it first to avoid a conflict)
- **Category**: bug
- **Planned at**: commit `d91e3f8`, 2026-11-10

## Why this matters

The memory verdicts state an advisor's estimate as "percent of instance DB
time" (`gain_dbtime_pct`). The numerator is the advisor's increment over an
interval that runs from the advised size's *previous present row* to the
current snapshot. Oracle's advisor lists are ragged (a size can be missing
from a snapshot), so that interval can span several snapshots. The
denominator, however, is always the DB time of **one** snapshot interval, the
last one. For a gap-spanning interval the gain is therefore overstated, and
it can push an area over the `mem_gain_dbtime_pct` threshold (grade
UNDERSIZED) or overstate the cost of a shrink.

## Current state

All in view `CAPM_ADVICE`, `ddl/42_memory_views.sql`.

Input rows (CTE `dl`, lines 402-409) come from `CAPM_DELTA`, restricted to
the evidence window; each has `snap_id`, `prev_snap_id` (the snapshot the
increment starts from), `metric`, `delta`:

```
     dl AS (
        SELECT dbid, instance_number, snap_id, prev_snap_id, metric, key, key_num,
               delta, end_time, ivl_hours
        FROM   capm_delta
        WHERE  in_win = 'Y'
          AND  (metric = 'DBTIME'
                OR (seg_ok = 'Y'
                    AND metric IN ('SGA_TOTAL', 'BUFFER_CACHE', 'SHARED_POOL', 'PGA_TARGET')))
     ),
```

DB time per snapshot (lines 422-427):

```
     dbt AS (
        SELECT dbid, instance_number, snap_id, SUM(delta) AS dbtime_sec
        FROM   dl
        WHERE  metric = 'DBTIME'
        GROUP  BY dbid, instance_number, snap_id
     ),
```

The join (CTE `pair`, lines 516-525): `x` is one row per (interval of the
reference size, advised size), carrying that interval's `snap_id`; the
interval's `prev_snap_id` is a partition key of the CTE `filled` that feeds
it but is **not** in `filled`'s select list today:

```
     pair AS (
        SELECT x.dbid, x.instance_number, x.area, x.size_bytes,
               x.ivl_hours, x.end_time, x.cost, x.cur_cost, x.work, x.overalloc,
               t.dbtime_sec
        FROM   filled x
        LEFT   JOIN dbt t
          ON   t.dbid = x.dbid AND t.instance_number = x.instance_number
         AND   t.snap_id = x.snap_id
        WHERE  x.probe = 1 AND x.cost IS NOT NULL
     ),
```

`filled` starts (lines 484-486):

```
     filled AS (
        SELECT x.dbid, x.instance_number, x.area, x.size_bytes, x.snap_id, x.probe,
               x.cur_cost, x.ivl_hours, x.end_time,
               LAST_VALUE(x.cost IGNORE NULLS)
                   OVER (PARTITION BY x.dbid, x.instance_number, x.area, x.snap_id, x.prev_snap_id
                   ...
```

and its inner query already selects `prev_snap_id` in both UNION ALL branches
(`a.prev_snap_id` and `i.prev_snap_id`).

Downstream, `agg` sums `dbtime_sec` and `curve` computes
`100 * g.gain_sec / g.dbtime_sec AS gain_dbtime_pct` (line 560-561).

Rules of this file (from `CLAUDE.md`, "Memory verdicts"):

- "Increments only. Nothing is differenced across a restart." An advisor
  increment never crosses a restart (its `LAG` partitions by startup), so
  `prev_snap_id` and `snap_id` are always in the same startup, and so is
  every snapshot between them.
- "`CAPM_ADVICE` never joins the increments to themselves, and never
  outer-joins the sizes to the aggregation" (a measured 20 s / 5 min plan
  trap). The fix below joins `filled` to a **per-snapshot** DB time row set
  by equality, exactly like the existing join; it adds no join between
  advisor rows.
- "Time `capm_advice`, `capm_area` AND `capm_verdict` after any change here."
- Every analytic window partitions by `dbid` (`test/lint_dbid_windows.sh`).

## Design (decided)

Keep `dbt`. Add a running total of DB time per instance, and take the
interval's DB time as a difference of two running totals:

- `cum(snap_id) - cum(prev_snap_id)` = DB time of every snapshot interval
  inside the advisor interval. Valid because all those snapshots are in one
  startup and the running total is only ever *differenced within* an advisor
  interval.
- When there is no running-total row at `prev_snap_id` (it lies before the
  window, or that snapshot has no DB time row), fall back to today's value:
  the DB time of the last snapshot only. So nothing changes for a
  single-snapshot interval, and nothing gets worse for an edge case.

## Commands you will need

| Purpose | Command (repo root) | Expected on success |
|---|---|---|
| Offline lints | `test/lint_dbid_windows.sh && test/lint_appinfo.sh && test/lint_anom_joins.sh && test/lint_snapshot_reads.sh` | exit 0 |
| Database harness + timing | `test/dbmint_harness.sh <SCHEMA> --sql test/mem_timing.sql` | `RESULT: <n> passed, 0 failed`, `(exit 0)` |

`test/mem_timing.sql` is created by plan 006. If it does not exist, plan 006
has not landed: STOP. The harness needs the maintainer's VM (`ssh -p 2200
oracle@dbmint`) and a throwaway PDB1 schema the operator assigns
(`CAPX1`..`CAPX3`, `CAPW1`..`CAPW3`; never `CAPDEMO` / `CAPTEST`). About 30
minutes. "Could not resolve hostname" can be your tool sandbox: retry
outside it.

## Scope

**In scope**: `ddl/42_memory_views.sql` (view `CAPM_ADVICE` only),
`test/run_test.sql` (one new block).

**Out of scope**: `CAPM_DELTA`, `CAPM_AREA`, `CAPM_EVIDENCE`, `CAPM_VERDICT`;
the `PGA_TARGET` area's numbers (it uses cache-hit points, not DB time: its
values must not move); `test/fixture_install.sql`.

## Git workflow

- Branch: `advisor/007-advisor-dbtime-interval`
- One commit. Style: imperative subject, bullet body.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Measure how often it happens (read-only, optional but asked for)

If the operator gave you a repository schema with real AWR copies (the
maintainer's is `CAPX2`), run this there and put the two numbers in your
hand-back; skip it otherwise:

```
SELECT COUNT(*) AS advisor_increments,
       COUNT(CASE WHEN d.prev_snap_id <> s.prev_snap_id THEN 1 END) AS spanning_several_snapshots
FROM   capm_delta d
JOIN   capm_snap s
  ON   s.dbid = d.dbid AND s.instance_number = d.instance_number AND s.snap_id = d.snap_id
WHERE  d.in_win = 'Y' AND d.key = 'COST'
  AND  d.metric IN ('SGA_TOTAL', 'BUFFER_CACHE', 'SHARED_POOL');
```

### Step 2: Running DB time and the interval difference

(a) Directly after the `dbt` CTE add:

```
     dbc AS (
        SELECT t.dbid, t.instance_number, t.snap_id, t.dbtime_sec,
               SUM(t.dbtime_sec) OVER (PARTITION BY t.dbid, t.instance_number
                                       ORDER BY t.snap_id) AS cum_sec
        FROM   dbt t
     ),
```

(b) In `filled`'s outer select list, add `x.prev_snap_id` after `x.snap_id`
(the inner query already provides it):

```
        SELECT x.dbid, x.instance_number, x.area, x.size_bytes, x.snap_id, x.prev_snap_id, x.probe,
```

(c) Replace the `pair` CTE with:

```
     pair AS (
        SELECT x.dbid, x.instance_number, x.area, x.size_bytes,
               x.ivl_hours, x.end_time, x.cost, x.cur_cost, x.work, x.overalloc,
               t.cum_sec - NVL(p.cum_sec, t.cum_sec - t.dbtime_sec) AS dbtime_sec
        FROM   filled x
        LEFT   JOIN dbc t
          ON   t.dbid = x.dbid AND t.instance_number = x.instance_number
         AND   t.snap_id = x.snap_id
        LEFT   JOIN dbc p
          ON   p.dbid = x.dbid AND p.instance_number = x.instance_number
         AND   p.snap_id = x.prev_snap_id
        WHERE  x.probe = 1 AND x.cost IS NOT NULL
     ),
```

Do not rename `dbtime_sec`: `agg` and `curve` read it.

(d) In the `CAPM_ADVICE` header comment, where the gain is described, add:

```
--   The DB time of an interval is that of every snapshot between the
--   size's previous present row and this one (a running total, differenced
--   inside the interval, never across a restart), so a size that left the
--   list for a snapshot is still compared with the DB time of its whole
--   increment.
```

**Verify**: `test/lint_dbid_windows.sh` → `lint_dbid_windows: OK`;
`grep -c "cum_sec" ddl/42_memory_views.sql` → `2` (two lines: the `dbc`
column and the `pair` expression).

### Step 3: A fixture test that fails without the fix

The fixture's memory tables are designed so that every advisor estimate
grows by a fixed multiple of DB time each snapshot: removing one snapshot's
advisor rows makes the next increment twice as large over twice the DB time,
so `gain_dbtime_pct` must not move. With the old join it rises.

In `test/run_test.sql`, find an existing memory test that uses a savepoint
and deletes or updates fixture advisor rows, to copy its shape:
`grep -n "SAVEPOINT" test/run_test.sql | sed -n 1,60p` and read the ones
between lines 2400 and 3000 (the memory section). Model the new block on one
of them (same `SAVEPOINT` / `BEGIN ... ROLLBACK TO` / `EXCEPTION WHEN OTHERS
THEN ROLLBACK TO ...; fail(...)` shape). Add it right after the block you
copied from:

```
        -- A snapshot without buffer cache advisor rows: the next increment
        -- spans two snapshots and is compared with the DB time of both.
        SAVEPOINT mem_gap;
        BEGIN
            SELECT gain_dbtime_pct INTO v_num
              FROM capm_advice WHERE dbid = v_dbid AND area = 'BUFFER_CACHE' AND size_bytes = 1536 * n_mib;
            SELECT MAX(snap_id) - 10 INTO v_num3 FROM cap_fixture_snapshot;
            DELETE FROM cap_fixture_cache_advice WHERE snap_id = v_num3;
            chk_true('advisor gap: rows of snapshot ' || v_num3 || ' removed', SQL%ROWCOUNT > 0);
            SELECT gain_dbtime_pct INTO v_num2
              FROM capm_advice WHERE dbid = v_dbid AND area = 'BUFFER_CACHE' AND size_bytes = 1536 * n_mib;
            chk_close('advisor gap: BUFFER_CACHE 1536 MiB gain_dbtime_pct unchanged', v_num2, v_num, 1e-6);
            ROLLBACK TO mem_gap;
        EXCEPTION
            WHEN OTHERS THEN
                ROLLBACK TO mem_gap;
                fail('advisor gap block raised ' || SQLERRM);
        END;
```

`v_num`, `v_num2`, `v_num3`, `v_dbid`, `n_mib`, `chk_true`, `chk_close`,
`fail` exist in the file (the same lookup is at line 2196). Before relying on
it, check two things in `test/fixture_install.sql`:

1. the cache advisor fixture table is named `CAP_FIXTURE_CACHE_ADVICE` and
   has a `snap_id` column (it is created there);
2. `MAX(snap_id) - 10` is neither the first snapshot of a startup nor a
   snapshot of the last day (the fixture has two snapshots a day, ids
   `2000+2i` / `2001+2i`, restarts at day 60 and day 110 of about 120, so
   five days before the end is safe).

If the block you modelled on resets a memory knob or re-reads a helper
before its assertions, do the same.

**Prove the test detects the bug**: with step 3 in place, temporarily undo
step 2(c) only (`git stash` is not available to you if the operator's tree
is shared: instead re-apply the old `pair` text from "Current state" by
hand), run the harness, and confirm the new assertion FAILS
(`grep "advisor gap" /tmp/dbmint_harness_<SCHEMA>.log` shows `* FAIL`).
Then restore step 2(c). If a second 30-minute run is not affordable, say so
in the hand-back instead of skipping silently.

### Step 4: Database gate

`test/dbmint_harness.sh <SCHEMA> --sql test/mem_timing.sql` → `0 failed`,
`(exit 0)`; the log has `PASS  advisor gap: BUFFER_CACHE 1536 MiB
gain_dbtime_pct unchanged`. Compare the `Elapsed:` lines for `capm_advice`,
`capm_area`, `capm_verdict` with plan 006's "after" numbers (ask the
operator for them or read plan 006's hand-back): none may be more than 1.5x
slower.

## Test plan

- New: the `mem_gap` block (step 3), proven to fail on the old join.
- Existing memory closed forms must pass unchanged: the fixture's advisor
  lists have no gap, so every single-snapshot interval keeps its value
  (`cum(snap) - cum(prev)` equals that snapshot's DB time).

## Done criteria

- [ ] `grep -c "cum_sec" ddl/42_memory_views.sql` → `2`
- [ ] Offline lints exit 0
- [ ] Harness: `0 failed`, `(exit 0)`, the `advisor gap` assertion passes
- [ ] `git diff test/run_test.sql` shows additions only
- [ ] No timing of `capm_advice` / `capm_area` / `capm_verdict` above 1.5x plan 006's
- [ ] `plans/README.md` status row updated

## STOP conditions

- An existing memory assertion fails after step 2. The running total changed
  a single-snapshot interval, which the design says cannot happen: report the
  failing lines and the values, do not adjust expectations.
- `capm_advice` or `capm_area` becomes several times slower (the optimizer
  reacted badly to the second join): revert step 2 and report the timings.
  Do not add hints or restructure `CAPM_ADVICE`.
- The fixture table or column named in step 3 does not exist.

## Maintenance notes

- An interval whose start lies before the evidence window still uses the old
  one-snapshot DB time (the fallback). Its numerator reaches before the
  window too; both ends are a window-edge approximation that existed before.
- Reviewer: check that `dbc` partitions by `dbid, instance_number` only (not
  by startup). That is intentional and safe because the total is only
  differenced between two snapshots of one startup.
- Real-data effect: areas graded from ragged lists (the shared pool, and any
  area on `reference_fallback = 'Y'`) can drop below `mem_gain_dbtime_pct`
  and change grade after this lands. That is the correction, not a
  regression; mention it in the release note.
