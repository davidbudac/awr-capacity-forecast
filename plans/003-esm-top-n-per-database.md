# Plan 003: Tier 2 (ESM) trains the top N tablespaces of each database and retires models it no longer trains

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat d91e3f8..HEAD -- ml/cap_forecast_ml.pkb ml/cap_forecast_ml.pks ddl/50_ml.sql test/run_test_ml.sql test/lint_dbid_windows.sh docs/design.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (train time grows with the number of databases; the ML test counts models)
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `d91e3f8`, 2026-11-10

## Why this matters

The suite measures a fleet: one repository schema holds the AWR copies of
several databases ("targets"), and a golden rule of the project is **"Per
database, never across targets"**: one target's numbers never depend on
another's. The ESM trainer breaks it. Its cursor picks the `p_top_n` (default
20) most critical tablespaces **of the whole fleet**, so with five targets one
busy database can take all 20 models and the other four get none. Second
defect: a model whose series drops out of the selection keeps its registry
row forever. A stale row raises a permanent INFO `MODEL_HEALTH` alert, and a
row whose last build FAILED raises a permanent WARN that can never resolve,
because nothing ever retrains or deletes it.

## Current state

Files:

- `ml/cap_forecast_ml.pkb` — package body; the cursor and the trainers.
- `ml/cap_forecast_ml.pks` — package spec; public procedure comments.
- `ddl/50_ml.sql` — table `CAP_ML_MODEL` (the registry) and the ESM views.
- `test/run_test_ml.sql` — the Tier 2 fixture test (run after `train_all`).
- `test/lint_dbid_windows.sh` — lint: every analytic window partitions by `dbid`.

The cursor, `ml/cap_forecast_ml.pkb:54-69`:

```
    -- Tablespaces eligible for a model, most capacity-critical first. p_name /
    -- p_con_dbid narrow it to one series for train_tablespace.
    CURSOR c_tbspc(p_top_n IN NUMBER, p_name IN VARCHAR2,
                   p_con_dbid IN NUMBER, p_min IN NUMBER) IS
        SELECT dbid, con_dbid, tablespace_name, last_day
        FROM   capf_tbspc_forecast
        WHERE  train_n >= p_min
          -- M10.4 quality gate: FLAT / INSUFFICIENT_HISTORY series are
          -- never worth a model (and would crowd out real ones in top-N).
          AND  quality IN ('OK', 'LOW_CONFIDENCE')
          AND  (p_name IS NULL OR tablespace_name = p_name)
          AND  (p_con_dbid IS NULL OR con_dbid = p_con_dbid)
        ORDER  BY CASE WHEN days_to_full IS NULL THEN 1 ELSE 0 END,
                  days_to_full ASC,
                  cur_used DESC
        FETCH FIRST p_top_n ROWS ONLY;
```

Its users, `ml/cap_forecast_ml.pkb:453-478`:

```
    PROCEDURE do_tablespaces(p_top_n IN NUMBER, p_name IN VARCHAR2, p_con_dbid IN NUMBER) IS
        v_min  NUMBER := cfg_num('min_train_days', 14);   -- packaged fn can't be called inside SQL
        v_hold NUMBER := cfg_num('backtest_holdout_days', 28);
        v_n    PLS_INTEGER := 0;
    BEGIN
        DBMS_APPLICATION_INFO.SET_ACTION('tablespaces');
        ...
        IF auto_select THEN
            FOR r IN c_tbspc(p_top_n, p_name, p_con_dbid, v_min) LOOP
                twins_tbspc(r.dbid, r.con_dbid, r.tablespace_name, r.last_day, v_hold);
            END LOOP;
        END IF;

        FOR r IN c_tbspc(p_top_n, p_name, p_con_dbid, v_min) LOOP
            prod_tbspc(r.dbid, r.con_dbid, r.tablespace_name, r.last_day);
            v_n := v_n + 1;
        END LOOP;

        IF p_name IS NOT NULL AND v_n = 0 THEN
            RAISE_APPLICATION_ERROR(-20061, ...
```

`backtest_tbspc` (line 324) also loops `c_tbspc(p_top_n, NULL, NULL, v_min)`.
`train_tablespace` (line 529) calls `do_tablespaces(1000000, p_tablespace_name, p_con_dbid)`.
`train_tablespaces` / `train_all` call `do_tablespaces(p_top_n, NULL, NULL)`.

An existing helper that drops one model and its registry row
(`ml/cap_forecast_ml.pkb:141-147`); it COMMITs:

```
    PROCEDURE drop_one(p_model IN VARCHAR2) IS
    BEGIN
        drop_quiet(p_model);
        drop_quiet(p_model || c_tmp_sfx);
        DELETE FROM cap_ml_model WHERE model_name = p_model;
        COMMIT;
    END drop_one;
```

Registry columns used here (`ddl/50_ml.sql:36-54`): `model_name` (PK),
`series_kind` (`'TBSPC'` / `'CPU'` / `'DBCPU'`), `dbid`, `con_dbid`,
`series_key` (the tablespace name for `TBSPC`), `status`, `purpose`
(`'FORECAST'` / `'BACKTEST'`).

Documented behaviour this plan replaces (`docs/design.md:1393-1394` and the
`CAPF_COMPARE` comment in `ddl/50_ml.sql` near line 391): "A model left
behind by a later top-N retrain still drops out once it is older than the
limit" — true for the comparison view, but the registry row and its health
alert stay.

Conventions that apply:

- **19c syntax floor**: inline `OVER (PARTITION BY ... ORDER BY ...)` only; no
  standalone `WINDOW` clause.
- **Every session is labelled**: public procedures save MODULE/ACTION, set
  them, and restore them on return and in a `WHEN OTHERS ... RAISE` handler.
  You are not adding a public procedure; do not touch that code.
- A failed model build must never destroy the last good model
  (`build_model` already guarantees it; do not change `build_model`).

## Commands you will need

| Purpose | Command (repo root) | Expected on success |
|---|---|---|
| Offline lints | `test/lint_anom_joins.sh && test/lint_appinfo.sh && test/lint_dbid_windows.sh && test/lint_snapshot_reads.sh && test/lint_dba_hist.sh && test/docs_lint.sh` | exit 0 |
| Database harness with ML | `test/dbmint_harness.sh <SCHEMA> --ml` | two `RESULT: <n> passed, 0 failed` lines (run_test, run_test_ml) and `(exit 0)` |

The harness needs the maintainer's VM (`ssh -p 2200 oracle@dbmint`) and a
throwaway PDB1 schema assigned by the operator (`CAPX1`..`CAPX3`,
`CAPW1`..`CAPW3`; one per concurrent run; never `CAPDEMO` / `CAPTEST`). The
schema needs `CREATE MINING MODEL`. About 35 minutes. A "Could not resolve
hostname" error can be your tool sandbox: retry outside it first.

## Scope

**In scope**: `ml/cap_forecast_ml.pkb`, `ml/cap_forecast_ml.pks` (comments
only), `ddl/50_ml.sql` (one comment only), `docs/design.md` (one sentence),
`test/run_test_ml.sql`, `test/lint_dbid_windows.sh`.

**Out of scope**: `build_model`, `prod_tbspc`, `twins_tbspc`, `do_cpu`,
`backtest_cpu`, `get_forecast`; any view definition; `install_jobs.sql`
(the nightly job keeps calling `train_all` with the default); CPU models
(they are one per container already, no top-N).

## Git workflow

- Branch: `advisor/003-esm-per-database`
- Commits: one for the cursor + lint, one for the retirement + tests + docs.
  Style: imperative subject, bullet body (see `git log -3`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Rank per database in `c_tbspc`

Replace the cursor's query with a per-`dbid` rank (keep the cursor's name,
parameters and the four selected columns):

```
        SELECT dbid, con_dbid, tablespace_name, last_day
        FROM  (SELECT f.dbid, f.con_dbid, f.tablespace_name, f.last_day,
                      ROW_NUMBER() OVER (PARTITION BY f.dbid
                                         ORDER BY CASE WHEN f.days_to_full IS NULL THEN 1 ELSE 0 END,
                                                  f.days_to_full ASC,
                                                  f.cur_used DESC,
                                                  f.con_dbid, f.tablespace_name) AS rn
               FROM   capf_tbspc_forecast f
               WHERE  f.train_n >= p_min
                 -- M10.4 quality gate: FLAT / INSUFFICIENT_HISTORY series are
                 -- never worth a model (and would crowd out real ones in top-N).
                 AND  f.quality IN ('OK', 'LOW_CONFIDENCE')
                 AND  (p_name IS NULL OR f.tablespace_name = p_name)
                 AND  (p_con_dbid IS NULL OR f.con_dbid = p_con_dbid))
        WHERE  rn <= p_top_n
        ORDER  BY dbid, rn;
```

Update the comment above the cursor: "... most capacity-critical first, the
top p_top_n **of each database** (M24.13: per database, never across
targets)."

In `ml/cap_forecast_ml.pks`, the comment above `train_tablespaces` says
"limited to the p_top_n most capacity-critical". Change it to "limited to the
p_top_n most capacity-critical **of each database**".

**Verify**: `grep -c "FETCH FIRST p_top_n" ml/cap_forecast_ml.pkb` → `0`;
`grep -c "PARTITION BY f.dbid" ml/cap_forecast_ml.pkb` → `1`.

### Step 2: Put the package body under the per-database window lint

`test/lint_dbid_windows.sh` passes a file list to an inline python script:

```
python3 - "$ALLOW" ddl/2[0-9]_*.sql ddl/3[0-9]_*.sql ddl/4[0-9]_*.sql ddl/5[0-9]_*.sql <<'EOF'
```

Append ` ml/cap_forecast_ml.pkb` to that file list (before `<<'EOF'`), and
extend the header comment's "(ddl/20..ddl/55)" to "(ddl/20..ddl/55 and the
ML package body)".

**Verify**: `test/lint_dbid_windows.sh` → prints `lint_dbid_windows: OK`,
exit 0. (At planning time the body had no `OVER (` at all, so the only window
it checks is the one from step 1.)

### Step 3: Retire tablespace models the full run did not select

In `do_tablespaces`:

(a) Add two declarations next to `v_n`:

```
        TYPE t_seen IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(400);
        l_seen t_seen;
```

(b) In the second loop (the one that calls `prod_tbspc`), record each
selected series, as the first statement of the loop body:

```
            l_seen(r.dbid || '|' || r.con_dbid || '|' || r.tablespace_name) := 1;
```

(c) After that loop and before the `IF p_name IS NOT NULL AND v_n = 0` check,
add:

```
        -- A full run (no name filter) that selected something owns the set of
        -- tablespace models: a series it did not select has left the top N or
        -- the quality gate, and its registry row would otherwise stay stale or
        -- FAILED for good (a MODEL_HEALTH alert nothing can resolve). v_n = 0
        -- retires nothing: an empty selection is more likely a problem
        -- upstream than twenty tablespaces going FLAT at once.
        IF p_name IS NULL AND p_con_dbid IS NULL AND v_n > 0 THEN
            FOR s IN (SELECT model_name, dbid, con_dbid, series_key
                      FROM   cap_ml_model
                      WHERE  series_kind = 'TBSPC') LOOP
                IF NOT l_seen.EXISTS(s.dbid || '|' || s.con_dbid || '|' || s.series_key) THEN
                    drop_one(s.model_name);
                END IF;
            END LOOP;
        END IF;
```

This covers both `purpose` values: a retired series loses its FORECAST model
and its BACKTEST twins. `drop_one` commits per model, which is how
`purge_twins` already uses it.

(d) Spec comment (`ml/cap_forecast_ml.pks`, above `train_tablespaces`): add
"A full run (train_tablespaces / train_all) drops the models and backtest
twins of tablespaces it did not select; train_tablespace (one name) never
drops another series' model."

(e) Docs: in `docs/design.md` (near line 1393) replace the sentence "A model
left behind by a later top-N retrain still drops out once it is older than
the limit." with "A full retrain drops the models of tablespaces it no longer
selects (top N per database, quality gate), so no stale registry row is left
behind." In `ddl/50_ml.sql`, the `CAPF_COMPARE` header comment has the phrase
"and a model left behind by a later top-N retrain eventually drops out":
change it to "and a full retrain drops the models it no longer selects".
Comment text only; do not touch the view.

**Verify**: `grep -c "l_seen" ml/cap_forecast_ml.pkb` → `3` (declaration,
assignment, `EXISTS`);
`test/lint_appinfo.sh` → exit 0.

### Step 4: Tests in `test/run_test_ml.sql`

Open the file and read its helpers first (`chk_num(label, actual, expected)`,
`chk_txt(label, actual, expected)`) and how it ends (a `RESULT:` line and a
`RAISE_APPLICATION_ERROR` when anything failed). Add a new block directly
before the final `RESULT` output, so no later assertion depends on the
registry state it changes:

```
    ------------------------------------------------------------------
    -- A full run owns the tablespace models: a smaller top N retires the
    -- rest (forecast models and twins), the default brings them back.
    ------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('=== train_tablespaces(2): the unselected models are retired ===');
    cap_forecast_ml.train_tablespaces(2);
    SELECT COUNT(*) INTO v_n FROM cap_ml_model
    WHERE  series_kind = 'TBSPC' AND purpose = 'FORECAST';
    chk_num('train_tablespaces(2): forecast models left', v_n, 2);
    SELECT COUNT(DISTINCT series_key) INTO v_n FROM cap_ml_model
    WHERE  series_kind = 'TBSPC';
    chk_num('train_tablespaces(2): series with any model or twin', v_n, 2);
    SELECT COUNT(*) INTO v_n FROM cap_ml_model WHERE series_kind <> 'TBSPC';
    chk_num('train_tablespaces(2): CPU models untouched', v_n, v_cpu_before);
    SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'MODEL_HEALTH';
    chk_num('train_tablespaces(2): no MODEL_HEALTH from retired models', v_n, 0);
    cap_forecast_ml.train_tablespaces;
    SELECT COUNT(*) INTO v_n FROM cap_ml_model
    WHERE  series_kind = 'TBSPC' AND purpose = 'FORECAST' AND status = 'OK';
    SELECT COUNT(*) INTO v_n2 FROM capf_tbspc_forecast
    WHERE  quality IN ('OK', 'LOW_CONFIDENCE') AND train_n >= v_min;
    chk_num('train_tablespaces: every eligible tablespace has its model again', v_n, v_n2);
```

`v_cpu_before` is new: declare it (`v_cpu_before NUMBER;`) with the other
variables and set it directly before the block:
`SELECT COUNT(*) INTO v_cpu_before FROM cap_ml_model WHERE series_kind <> 'TBSPC';`
`v_n`, `v_n2` and `v_min` already exist in the file (used around lines
268-276); if a name differs in the live file, use the live name.

The fixture has one database, so the per-database split itself cannot be
asserted here; the lint of step 2 is its guard.

**Verify** (database gate): `test/dbmint_harness.sh <SCHEMA> --ml` → both
`RESULT:` lines show `0 failed`, `(exit 0)`, and
`grep -c "train_tablespaces(2)" /tmp/dbmint_harness_<SCHEMA>.log` → `5` or more.

## Test plan

- New: the block of step 4 (retire on a smaller N, CPU models untouched, no
  alert from retired rows, restore on the default run).
- Guard for the per-database rank: `test/lint_dbid_windows.sh` now reads the
  package body.
- Existing `run_test_ml.sql` assertions must stay green unchanged; in
  particular "CAPF_ESM_HEALTH_SUMMARY n_ok (eligible tablespaces)" (the
  fixture has 8 eligible, fewer than 20, so the selection is the same as
  before on one database).

## Done criteria

- [ ] `grep -c "FETCH FIRST p_top_n" ml/cap_forecast_ml.pkb` → `0`
- [ ] `test/lint_dbid_windows.sh` → `lint_dbid_windows: OK`
- [ ] All offline lints exit 0
- [ ] `test/dbmint_harness.sh <SCHEMA> --ml` → `0 failed` twice, `(exit 0)`
- [ ] `git status --short` lists only in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

- The cursor or `do_tablespaces` no longer matches the excerpts.
- `test/lint_dbid_windows.sh` flags a window in the package body other than
  the one you added (someone added analytics there): report it, do not add it
  to the allow list yourself.
- An existing `run_test_ml.sql` assertion fails after step 1 alone (before
  your new block): the selection changed on the fixture, which this plan
  assumed cannot happen with one database and 8 eligible tablespaces. Report
  the failing lines.
- The package body fails to compile on the harness (`PLS-` lines in the log)
  twice after a fix attempt.

## Maintenance notes

- Fleet cost: models built per night go from `p_top_n` to `p_top_n x
  databases`. On the maintainer's 2-vCPU VM a staged model build is seconds,
  and `train_all` on four targets took 86 s at 20 models in total; expect it
  to scale with the model count. If that is too slow for a large fleet, lower
  the default of `p_top_n` in the nightly call rather than going back to a
  fleet-wide rank.
- `cap_repo.remove_target` deletes a target's copies but not its ESM models.
  After this plan a later full retrain removes them (their series are no
  longer selected), provided at least one other series is selected.
- Reviewer: check that `train_tablespace('X')` (the one-name path) cannot
  reach the retire loop (`p_name IS NULL` guard).
