# Plan 009: `cap_repo.purge` has an automated test (cut per database, uneven rows, refusals), run by a lever in a throwaway repository schema

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Data safety**: `cap_repo.purge` deletes and COMMITs across **every**
> database of the schema it runs in. The test in this plan must refuse to run
> in a schema that holds any target other than its own two synthetic ones.
> Never point it at `CAPX2`, `CAPX3`, `CAPM1`..`CAPM6`, `CAPDEMO` or `AWRCAP`.
>
> **Drift check (run first)**:
> `git diff --stat d91e3f8..HEAD -- repository/cap_repo.sql test/repo_synth_target.sql test/dbmint_scale.sh test/lint_appinfo.sh`
> If any of these changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW (new test files only; no product code changes)
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `d91e3f8`, 2026-11-10

## Why this matters

Since milestone M25 every install is a "repository": the suite reads
`CAP_H_*` tables, copies of each measured database's AWR that
`cap_repo.collect` pulled over a database link. Those copies outlive the
source's own AWR retention, so they **cannot be re-pulled**. The only code
that deletes from them is `cap_repo.purge`, which the nightly job runs
without supervision. The fixture harness never installs repository mode, and
`test/run_test.sql` does not name `cap_repo` once: the purge's cut logic is
tested by nobody. A wrong cut loses up to 400 days of history.

## Current state

`repository/cap_repo.sql`, procedure `purge` (line 725). The parts the test
must pin down:

```
    PROCEDURE purge(p_days IN NUMBER DEFAULT NULL) IS
        ...
        -- Per DBID, the first snap_id to keep: the oldest snapshot that ended
        -- at or after the cut, or past the newest when none did. Fact rows
        -- below it go, also those of snapshots AWR purged unevenly.
        v_where  CONSTANT VARCHAR2(400) :=
            ' t WHERE t.snap_id < (SELECT c.cut_snap FROM (SELECT dbid,'
            || ' NVL(MIN(CASE WHEN end_interval_time >= :cut THEN snap_id END),'
            || ' MAX(snap_id) + 1) AS cut_snap FROM cap_h_snapshot GROUP BY dbid) c'
            || ' WHERE c.dbid = t.dbid)';
    BEGIN
        ...
        IF p_days IS NULL THEN
            SELECT MAX(value), MAX(status), MAX(reason) INTO v_days, v_status, v_reason
            FROM   cap_cfg_check WHERE  knob = 'repo_retention_days';
            IF NVL(v_status, 'MISSING') <> 'OK' THEN
                RAISE_APPLICATION_ERROR(-20071, 'repo_retention_days is ' || ...
        ELSIF p_days < 0 OR p_days <> TRUNC(p_days) THEN
            RAISE_APPLICATION_ERROR(-20071, 'p_days must be 0 (keep everything) or a whole'
                                            || ' number of days, not ' || p_days);
        END IF;
        IF v_days = 0 THEN
            say('repo_retention_days 0: nothing purged');
            ... RETURN;
        END IF;
        v_cut := SYSDATE - v_days;

        -- The snapshot copy goes last: every other DELETE reads it.
        FOR s IN (SELECT copy_table FROM cap_repo_source WHERE kind = 'F'
                  ORDER  BY CASE WHEN copy_table = 'CAP_H_SNAPSHOT' THEN 1 ELSE 0 END, seq) LOOP
            EXECUTE IMMEDIATE 'DELETE FROM ' || s.copy_table || v_where USING v_cut;
            ...
        END LOOP;
        DELETE FROM cap_collect_log WHERE logged_at < v_cut;
        ...
        COMMIT;
        log_event(NULL, NULL, 'PURGED', p_rows => v_total, ...
```

Facts to rely on:

- `CAP_REPO_SOURCE` (created by the generated `ddl/13_seam_repository.sql`)
  has one row per copied AWR view: `copy_table` (for example
  `CAP_H_SNAPSHOT`), `kind` (`F` fact, appended per snapshot; `D` and `S`
  dimensions, never purged), `seq`.
- Every `F` copy has `dbid` and `snap_id` columns.
- `CAP_COLLECT_LOG` columns: `log_id, logged_at, target_name, dbid, status,
  snap_from, snap_to, n_rows, elapsed_s, message`. A purge writes one row
  with `status = 'PURGED'` and `target_name` NULL.
- `CAP_TARGET` (`target_name`, ...) and `CAP_TARGET_DBID` (`dbid`,
  `target_id`, `last_snap_id`) register the targets.
- `test/repo_synth_target.sql <TARGET> <DBID> <SHIFT_DAYS> [DAYS] [SOURCE_SCHEMA]`
  registers a synthetic target and fills every `CAP_H_*` copy with the rows
  of the lowest dbid of `SOURCE_SCHEMA`, under the new `DBID`, every date
  moved `SHIFT_DAYS` into the past. The link does not exist and
  `link_owned = 'N'`, so `cap_repo.remove_target(TARGET)` deletes the rows
  and drops no link. Its inner loop shows how to build a column list for a
  copy table from `ALL_TAB_COLUMNS` (lines 79-93); reuse that technique.
- `test/dbmint_scale.sh` is the pattern for a lever that installs repository
  mode and runs SQL in it: it runs `python3 repository/build.py --check` and
  `test/lint_dba_hist.sh`, rsyncs the checkout to `oracle@dbmint:~/awr_cap_<schema>/`,
  and its `run <label> <sql lines>` function opens one SYSDBA session with
  `ALTER SESSION SET CONTAINER = PDB1; ALTER SESSION SET CURRENT_SCHEMA = <SCHEMA>;`.
  Read its first 80 lines before writing the new lever.
- Test conventions (`test/run_test.sql`): one anonymous PL/SQL block with
  counters `g_pass` / `g_fail`, helpers `pass(text)`, `fail(text)`,
  `chk_true(label, boolean)`, `chk_int(label, actual, expected)`, lines
  printed as `  PASS  ...` / `* FAIL  ...`, a final
  `RESULT: <p> passed, <f> failed` line, and
  `RAISE_APPLICATION_ERROR(-20050, ...)` when `g_fail > 0`.
- Every runnable SQL*Plus script starts with `SET APPINFO OFF` and
  `SET APPINFO "AWRCAP/<its path>"` (`test/lint_appinfo.sh` enforces it).
- Under SYSDBA + `CURRENT_SCHEMA`, read the dictionary through `ALL_*` views
  filtered on `owner = SYS_CONTEXT('USERENV','CURRENT_SCHEMA')`, never
  `USER_*`.

## Commands you will need

| Purpose | Command (repo root) | Expected on success |
|---|---|---|
| Offline lints | `test/lint_appinfo.sh && test/lint_dba_hist.sh && test/lint_snapshot_reads.sh && python3 repository/build.py --check` | exit 0 |
| Shell syntax | `bash -n test/dbmint_repo_test.sh` | exit 0 |
| The new lever | `test/dbmint_repo_test.sh <SCHEMA> [--source CAPX2] [--install]` | `RESULT: <n> passed, 0 failed`, exit 0 |

`<SCHEMA>` is a throwaway PDB1 schema the operator assigns for this test and
agrees to have (re)installed in repository mode (suggested: `CAPX1`; ask).
It needs the privileges `create_owner.sql` grants a suite owner, plus read
access to the source schema's `CAP_H_*`, `CAP_TARGET_DBID` tables (the lever
runs as SYSDBA, which has it). `--source` is a repository schema that has
collected a real target (the maintainer's is `CAPX2`); it is only read.

## Scope

**In scope** (all new): `test/repo_purge_test.sql`, `test/dbmint_repo_test.sh`.
One doc line: `docs/testing.html` only if it has a list of test levers (add
the new one in the same style; `test/docs_lint.sh` must still pass).

**Out of scope**: `repository/cap_repo.sql` (if the test finds a defect,
report it; do not fix it here), `test/repo_synth_target.sql`,
`test/dbmint_harness.sh`, `CLAUDE.md`.

## Git workflow

- Branch: `advisor/009-repo-purge-test`
- One commit. Style: imperative subject, bullet body.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: `test/repo_purge_test.sql`

A single script, run in the repository schema after two synthetic targets
exist: `PURGE01` (dbid 3900000001, shift 0) and `PURGE02` (dbid 3900000002,
shift 20 days). Header comment: what it is, that it is destructive in its
schema, how the lever calls it. Then `SET APPINFO OFF`,
`SET APPINFO "AWRCAP/test/repo_purge_test.sql"`, `SET SERVEROUTPUT ON SIZE
UNLIMITED FORMAT WRAPPED`, `WHENEVER SQLERROR EXIT FAILURE`, and one PL/SQL
block that does the following, in this order. Use dynamic SQL
(`EXECUTE IMMEDIATE`) for every `cap_h_*` table and for the `cap_repo` calls
is not needed (the package exists in this schema), but table names come from
`cap_repo_source`, so their statements are dynamic.

1. **Guard.** `SELECT COUNT(*) FROM cap_target WHERE target_name NOT IN
   ('PURGE01', 'PURGE02')` must be 0 and both targets must exist; otherwise
   `RAISE_APPLICATION_ERROR(-20001, 'repo_purge_test: this schema holds other
   targets; cap_repo.purge would trim their copies. Use a throwaway schema.')`.
   This check comes before anything else.
2. **Refusals (no data may change).** Record
   `SELECT COUNT(*) FROM cap_h_snapshot` as `n0`. Then each of these must
   raise ORA-20071 (catch `WHEN OTHERS`, `chk_true(label, SQLCODE = -20071)`;
   reaching the line after the call is a `fail`):
   - `cap_repo.purge(-1)`
   - `cap_repo.purge(1.5)`
   - knob graded BAD: `UPDATE cap_config SET cfg_value = 1 WHERE cfg_name =
     'repo_retention_days'; COMMIT;` then `cap_repo.purge;` (no argument),
     then always restore: `UPDATE cap_config SET cfg_value = cfg_default
     WHERE cfg_name = 'repo_retention_days'; COMMIT;` (also in the exception
     path). First assert the precondition
     `SELECT status FROM cap_cfg_check WHERE knob = 'repo_retention_days'`
     = `'BAD'` at value 1.
   After the three: `chk_int('refusals deleted nothing', <count of cap_h_snapshot>, n0)`.
3. **`purge(0)` keeps everything.** Call `cap_repo.purge(0)`; the
   `cap_h_snapshot` count is still `n0`.
4. **Plant an uneven row.** AWR purges its tables unevenly, so a fact copy
   can hold rows of snapshots that are no longer in `CAP_H_SNAPSHOT`. Pick
   the first `F` copy other than `CAP_H_SNAPSHOT` that has rows for dbid
   3900000001 (`ORDER BY seq`). Clone one of its rows with `snap_id = 1`
   (far below any real snapshot): build the column list from
   `ALL_TAB_COLUMNS` as `test/repo_synth_target.sql` does, with the
   expression `1` for column `SNAP_ID`, and
   `INSERT INTO <t> (<cols>) SELECT <exprs> FROM <t> WHERE dbid = 3900000001 AND ROWNUM = 1`.
   `COMMIT`. Assert one row was inserted. If the table has a unique key that
   the clone violates (ORA-00001), try the next `F` table; if none accepts a
   clone, `fail('could not plant an uneven row')` and continue.
5. **Expected cut, per database.** Choose the cut in the middle of
   `PURGE01`'s history:
   `v_mid := MIN(end) + (MAX(end) - MIN(end)) / 2` over
   `CAST(end_interval_time AS DATE)` of `cap_h_snapshot` for dbid 3900000001;
   `v_days := CEIL(SYSDATE - v_mid)`. Assert `v_days >= 1`.
   For each of the two dbids compute, with the same expression the procedure
   uses, the expected first kept snapshot for a cut date `d`:
   `NVL(MIN(CASE WHEN end_interval_time >= d THEN snap_id END), MAX(snap_id) + 1)`.
   Compute it twice: `lo` with `d = SYSDATE - v_days` taken **before** the
   call and `hi` with `d = SYSDATE - v_days` taken **after** the call (the
   procedure reads `SYSDATE` itself in between; `lo <= actual <= hi`, and
   `lo = hi` unless a snapshot ended in that second).
   Also record, before the call and per `F` table and dbid:
   `COUNT(*) WHERE snap_id >= <lo>` (rows that must survive, checked against
   `hi` afterwards), and per `D` / `S` table the total `COUNT(*)`.
6. **The purge.** `cap_repo.purge(v_days);`
7. **Assertions**, per dbid and per `F` copy table (loop over
   `cap_repo_source WHERE kind = 'F'`):
   - `COUNT(*) WHERE dbid = :d AND snap_id < :lo` = 0 (label names the table
     and dbid). This also proves the planted `snap_id = 1` row is gone.
   - `COUNT(*) WHERE dbid = :d AND snap_id >= :hi` equals the count recorded
     before with `>= :hi`. (Record both `>= lo` and `>= hi` counts before the
     call if `lo <> hi`; in the normal case they are the same number.)
   - for `CAP_H_SNAPSHOT`: `MIN(snap_id)` for the dbid is between `lo` and
     `hi`, or the dbid has no row left when `lo` was `MAX(snap_id) + 1`.
   Per `D` / `S` copy: total count unchanged.
   The two databases must have **different** `lo` values
   (`chk_true('the cut is per database', lo1 <> lo2)`): `PURGE02`'s history
   is 20 days older, so more of it (possibly all) is cut.
   Log: exactly one new `CAP_COLLECT_LOG` row with `status = 'PURGED'`,
   `target_name IS NULL`, `logged_at` at or after the time the test started.
8. `RESULT:` line and `RAISE_APPLICATION_ERROR(-20050, 'REPO PURGE TEST
   FAILED: ...')` when anything failed, exactly like `test/run_test.sql`.

Keep the block under about 250 lines; one helper that runs a
`SELECT COUNT(*) ... INTO` for a table name and a predicate keeps it short.

**Verify**: `test/lint_appinfo.sh && test/lint_snapshot_reads.sh && test/lint_dba_hist.sh` → exit 0.

### Step 2: `test/dbmint_repo_test.sh`

Model it on `test/dbmint_scale.sh` (same header style, `set -u`, the same
`SSH`, `REMOTE`, rsync excludes and `run()` function; log in
`/tmp/dbmint_repo_test_<SCHEMA>.log`). Arguments:
`<SCHEMA> [--source S] [--install]`, default source `CAPX2`.

Refuse protected schemas up front, in bash:

```
case "$SCHEMA" in
  CAPX2|CAPX3|CAPM[1-6]|CAPDEMO|CAPTEST|AWRCAP) echo "refusing $SCHEMA: not a throwaway purge schema" >&2; exit 2;;
esac
```

Steps, each one `run` call, stopping at the first failure:

1. `python3 repository/build.py --check` and `test/lint_dba_hist.sh` locally,
   then the rsync.
2. With `--install`: `DEFINE deploy_mode = repository` + `@install.sql`.
3. Reset the synthetic targets (ignore "no target" errors):
   ```
   BEGIN cap_repo.remove_target('PURGE01'); EXCEPTION WHEN OTHERS THEN NULL; END;
   /
   BEGIN cap_repo.remove_target('PURGE02'); EXCEPTION WHEN OTHERS THEN NULL; END;
   /
   ```
4. `@test/repo_synth_target.sql PURGE01 3900000001 0 - <SOURCE>` and
   `@test/repo_synth_target.sql PURGE02 3900000002 20 - <SOURCE>`.
5. `@test/repo_purge_test.sql`
6. Step 3 again (leave the schema empty of targets).

Finally print the `RESULT:` / `FAIL` / `ORA-` lines of the log and exit with
the failing step's status, as `test/dbmint_harness.sh` does.

**Verify**: `bash -n test/dbmint_repo_test.sh` → exit 0;
`test/dbmint_repo_test.sh CAPX2` → prints `refusing CAPX2` and exits 2
(run this one; it connects to nothing).

### Step 3: Run it

`test/dbmint_repo_test.sh <SCHEMA> --install` (first time), expected:
`RESULT: <n> passed, 0 failed`, exit 0. Run it a second time without
`--install`: same result (the lever resets its targets, so the test is
repeatable).

If an assertion fails, first decide whether the test or `cap_repo.purge` is
wrong by reading the `purge` excerpt above. A defect in `purge` is a finding:
keep the assertion, report the table, dbid, expected and actual values, and
mark the plan `BLOCKED (found a purge defect: <one line>)`.

## Test plan

This plan *is* a test. What it covers: refusals (`-1`, `1.5`, a BAD knob),
`0` = keep, the cut per database with two different histories, rows of
unevenly purged snapshots, dimensions untouched, the `PURGED` log row.

What it deliberately does not cover (say so in the hand-back):
`cap_repo.collect` (stays with `test/dbmint_copy_check.sh`, which needs a
real link), and closed-form assertions for the repository seam views
(`repository/seam.sql`).

## Done criteria

- [ ] `test/repo_purge_test.sql` and `test/dbmint_repo_test.sh` exist; `bash -n` passes
- [ ] Offline lints and `python3 repository/build.py --check` exit 0
- [ ] `test/dbmint_repo_test.sh CAPX2` exits 2 with the refusal
- [ ] `test/dbmint_repo_test.sh <SCHEMA>` → `0 failed`, twice in a row
- [ ] `git status --short` lists only the in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

- The operator has not named a throwaway schema for this test, or the schema
  holds any target. Do not "clean it up" yourself.
- `--source` schema has no collected target (`repo_synth_target.sql` raises
  "no collected target to clone").
- The source's history is shorter than 3 days (the mid-point cut would leave
  nothing to compare): report the span.
- You find yourself editing `repository/cap_repo.sql`.

## Maintenance notes

- The seam itself (the real `CAPV_TIME_MODEL` with its per-container
  fallback, `CAPV_SYSSTAT`, `CAPV_RESOURCE_LIMIT`) still has no closed-form
  test. The suite's fixture tables are shaped like the seam's *output*
  (`CAP_FIXTURE_*`), not like the raw `CAP_H_*` copies, so "run the fixture
  test in repository mode" needs an inverse mapping per source. The cheaper
  next step is a handful of hand-written `CAP_H_*` rows for a fake dbid and
  direct assertions on those three views, in this same lever.
- A change to the purge's cut rule, to `CAP_REPO_SOURCE.kind`, or a new fact
  copy without `dbid` / `snap_id` columns must be reflected in
  `test/repo_purge_test.sql`.
- Reviewer: check the guard is the first statement of the test block and
  that the bash refusal list matches the schemas named in `CLAUDE.md`
  ("Testing on a 19c test database").
