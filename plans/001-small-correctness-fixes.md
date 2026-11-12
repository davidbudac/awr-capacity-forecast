# Plan 001: Fix nine small, independent defects (ORDS escaping, zero knobs, installer gates, ordering)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat d91e3f8..HEAD -- grafana/ords/awrcap_module.sql ddl/05_config.sql ddl/30_forecast_views.sql ddl/40_anomaly_views.sql ddl/55_report_views_ml.sql install.sql install.sh repository/cap_repo.sql report/sections/04_cpu_trend.sql report/sections/06_esm_compare.sql report/report_csv.sql apex/ README.md test/run_test.sql`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S (each step is minutes; the database gate at the end is about 30 minutes)
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `d91e3f8`, 2026-11-10

## Why this matters

A read-only audit found nine small defects that each have a one-to-five-line
fix. The worst: the Prometheus `metrics` handler does not escape label values
(one backslash or quote in a tablespace name makes Prometheus reject the whole
scrape), and two configuration knobs set to `0` make the forecast and anomaly
views raise ORA-01476, which fails every report and the nightly refresh. The
rest are an installer that reports success after creating no scheduler job, a
password change that can leave a target without its database link, and
ordering / text slips. Each step below is independent: a failure in one does
not block the others.

## Background you need (this repo)

- The product is an Oracle 19c SQL + PL/SQL suite driven by SQL*Plus scripts.
  There is no application language besides a few bash and python helpers.
- **19c syntax floor**: no 21c/23c features.
- **Config, not constants**: thresholds are rows of table `CAP_CONFIG`, read
  through the one-row view `CAP_CFG`. View `CAP_CFG_CHECK` (in
  `ddl/05_config.sql`) grades each knob `OK` / `MISSING` / `BAD` with a reason.
- **Generated files are never edited by hand**: `apex/awrcap_app.sql` is written
  by `python3 apex/build.py`; `ddl/13_seam_repository.sql` by
  `repository/build.py`; `report/html/page_head.sql` / `page_tail.sql` by
  `report/html/build.py`.
- **SQL*Plus gotchas**: a `PROMPT` line ending in `;` loses the semicolon; a
  `--` comment line ending in `;` terminates a plain-SQL statement buffer.
  Never add either.
- `CLAUDE.md` at the repo root is the full orientation; read its "Golden
  rules" and "SQL\*Plus gotchas" sections before editing.

## Commands you will need

| Purpose | Command (run from the repo root) | Expected on success |
|---|---|---|
| Offline lints | `test/lint_anom_joins.sh && test/lint_appinfo.sh && test/lint_dbid_windows.sh && test/lint_snapshot_reads.sh && test/lint_dba_hist.sh && test/docs_lint.sh` | exit 0 |
| Generated seam current | `python3 repository/build.py --check` | exit 0 |
| Report wrapper test | `test/run_report_sh_test.sh` | last line `run_report.sh test: all passed` |
| HTML report test | `test/report_html_test.sh` | exit 0 (needs `node`) |
| Shell syntax | `bash -n install.sh` | exit 0, no output |
| Installer dry run | `./install.sh --profile profiles/standalone.env --dry-run` | prints the SQL*Plus driver, exit 0, runs nothing |
| Database harness | `test/dbmint_harness.sh <SCHEMA>` | ends with `RESULT: <n> passed, 0 failed` and `(exit 0)` |

The database harness needs the maintainer's test VM (`ssh -p 2200
oracle@dbmint`) and a throwaway schema in PDB1. Use the schema the operator
assigned to you (`CAPX1`..`CAPX3` or `CAPW1`..`CAPW3`; one schema per
concurrent run; never `CAPDEMO` or `CAPTEST`). It takes about 30 minutes. If
`ssh` fails with "Could not resolve hostname", your tool sandbox may be
blocking it: retry outside the sandbox before concluding the host is down.

## Scope

**In scope** (the only files you may modify):
- `grafana/ords/awrcap_module.sql`
- `ddl/05_config.sql`, `ddl/30_forecast_views.sql`, `ddl/40_anomaly_views.sql`, `ddl/55_report_views_ml.sql`
- `test/run_test.sql`
- `install.sql`, `install.sh`
- `repository/cap_repo.sql`
- `report/sections/04_cpu_trend.sql`, `report/sections/06_esm_compare.sql`, `report/report_csv.sql`
- `apex/install.sql`, `apex/workspace.sql`, `apex/build.py`, `apex/awrcap_app.sql` (regenerated only)
- `README.md`

**Out of scope** (do NOT touch):
- `standalone/tbspc_capacity.sql` — it mirrors the ddl/30 tablespace *fit*; nothing
  in this plan changes the fit (step 2 touches `accel_ratio`, which the
  standalone query does not compute).
- `ddl/13_seam_repository.sql`, `report/html/page_*.sql` — generated.
- `docs/` — no doc page states the ranges this plan adds.
- `PLAN.md`, `CLAUDE.md`.

## Git workflow

- Branch: `advisor/001-small-fixes`
- One commit per step. Message style of this repo: imperative subject, then
  bullets, for example:
  ```
  Detect stopped or newly started tablespace growth
  - Restart the fit after statistically significant growth pauses
  - Document the STOP and START rules and expose RESTART and fit days
  ```
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Escape Prometheus label values in the ORDS `metrics` handler

File `grafana/ords/awrcap_module.sql`, lines 184-188. Current (note that the
third `REPLACE` spans two physical lines; the search string of the first one
is empty and `'"'` is replaced by `'"'`, so nothing is escaped):

```
    FUNCTION lv(p_val VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN REPLACE(REPLACE(REPLACE(p_val, '', '\'), '"', '"'), CHR(10), '
');
    END;
```

`grafana/API.md:95` documents the contract: "Label values escape `\`, `"` and
newlines." Replace the function body with (backslash written as `CHR(92)` so
no tool can strip it again):

```
    FUNCTION lv(p_val VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN REPLACE(REPLACE(REPLACE(p_val, CHR(92), CHR(92) || CHR(92)),
                               '"', CHR(92) || '"'),
                       CHR(10), CHR(92) || 'n');
    END;
```

The function sits inside a `q'~ ... ~'` literal: do not introduce the
two-character sequence `~'` anywhere in it.

**Verify**:
- `grep -c "CHR(92)" grafana/ords/awrcap_module.sql` → `3` (three lines)
- `grep -n "REPLACE(p_val, ''" grafana/ords/awrcap_module.sql` → no output
- `test/lint_appinfo.sh` → exit 0

### Step 2: Make two knobs safe at 0 and have `CAP_CFG_CHECK` reject bad values

(a) `ddl/30_forecast_views.sql`, lines 648-650. Current:

```
       CASE WHEN f.is_cyclic = 0 AND ABS(f.use_slope) >= cfg.accel_slope_floor_bpd
            THEN f.recent_use / f.use_slope
       END                                                AS accel_ratio,
```

With `accel_slope_floor_bpd = 0` a FLAT series (`use_slope = 0`) divides by
zero. Change the first line to:

```
       CASE WHEN f.is_cyclic = 0 AND f.use_slope <> 0
             AND ABS(f.use_slope) >= cfg.accel_slope_floor_bpd
```

(b) `ddl/40_anomaly_views.sql`: line 266 has `c.thr_floor / cfg.mad_k` and
line 284 has `s.thr_floor / s.mad_k`. Change them to
`c.thr_floor / NULLIF(cfg.mad_k, 0)` and `s.thr_floor / NULLIF(s.mad_k, 0)`.
Change nothing else on those lines.

(c) `ddl/05_config.sql`, view `CAP_CFG_CHECK`: the range rules are one `CASE`
of `WHEN u.knob = ... THEN '<reason>'` branches. Directly after the branch

```
                   WHEN u.knob = 'hour_gap_ratio'      AND u.value <= 0
                        THEN 'must be > 0'
```

add:

```
                   WHEN u.knob = 'mad_k'               AND u.value <= 0
                        THEN 'must be > 0: the anomaly threshold is mad_k x sigma'
                   WHEN u.knob = 'accel_slope_floor_bpd' AND u.value < 0
                        THEN 'must be >= 0'
```

(d) `test/run_test.sql`: find this block (near line 4881; it ends with the
reset shown):

```
    UPDATE cap_config SET cfg_value = cfg_default
     WHERE cfg_name IN ('cyclic_min_cliffs', 'slope_method', 'cpu_quality_gate', 'cpu_deseason');
    COMMIT;
    SELECT COUNT(*) INTO v_n FROM cap_cfg_check
      WHERE knob IN ('cyclic_min_cliffs', 'slope_method', 'cpu_quality_gate', 'cpu_deseason') AND status = 'OK';
    chk_int('new knobs OK after reset', v_n, 4);
```

Directly after the `chk_int('new knobs OK after reset', v_n, 4);` line add
(same helpers `chk_str` / `chk_true` / `chk_int`, same variables `v_str`,
`v_n`, which already exist in the block):

```
    -- Zero must not raise ORA-01476 in the views, and the rules grade it.
    UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'mad_k';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'mad_k';
    chk_str('CAP_CFG_CHECK mad_k = 0', v_str, 'BAD');
    SELECT COUNT(*) INTO v_n FROM capa_anom WHERE baseline_mode = 'TRAILING' AND anomaly_flag IS NOT NULL;
    chk_int('mad_k = 0: CAPA_ANOM reads and flags nothing (TRAILING)', v_n, 0);
    UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'accel_slope_floor_bpd';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'accel_slope_floor_bpd';
    chk_str('CAP_CFG_CHECK accel_slope_floor_bpd = 0', v_str, 'OK');
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast WHERE quality = 'FLAT' AND accel_ratio IS NOT NULL;
    chk_int('accel_slope_floor_bpd = 0: FLAT series keep a NULL accel_ratio', v_n, 0);
    UPDATE cap_config SET cfg_value = -1 WHERE cfg_name = 'accel_slope_floor_bpd';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'accel_slope_floor_bpd';
    chk_str('CAP_CFG_CHECK accel_slope_floor_bpd = -1', v_str, 'BAD');
    UPDATE cap_config SET cfg_value = cfg_default
     WHERE cfg_name IN ('mad_k', 'accel_slope_floor_bpd');
    COMMIT;
```

`CAPA_ANOM.anomaly_flag` is `'HIGH'`, `'LOW'` or NULL (the `CASE` at
`ddl/40_anomaly_views.sql:292-297`). With `mad_k = 0` and the `NULLIF` of
step 2(b), `eff_sigma` is NULL, so no row can be flagged. Every read of
`capa_anom` must keep a `baseline_mode = ...` predicate
(`test/lint_anom_joins.sh` enforces it).

**Verify**: `test/lint_anom_joins.sh && test/lint_dbid_windows.sh` → exit 0.
The SQL itself is proven by the database harness in the last step.

### Step 3: Include `CAPM_` objects in the installer's recompile and INVALID check

`install.sql` lines 177 and 224 both read:

```
              AND  REGEXP_LIKE(object_name, '^CAP[VDFAR]?_')
```

The memory views (`CAPM_*`, created by `ddl/42_memory_views.sql`) match
neither. Change the pattern in **both** places to `'^CAP[VDFAMR]?_'`.

**Verify**: `grep -c "CAP\[VDFAMR\]?_" install.sql` → `2`;
`grep -c "CAP\[VDFAR\]?_" install.sql` → `0`.

### Step 4: Order fleet CPU rows by database; fix a PROMPT that ends in `;`

- `report/sections/04_cpu_trend.sql` line 64 and `report/report_csv.sql`
  line 130 both read `ORDER  BY con_dbid, metric;`. Change both to
  `ORDER  BY dbid, con_dbid, metric;` (every other section orders by `dbid`
  first; in a fleet report the rows of two databases interleave today).
- `report/sections/06_esm_compare.sql` line 93 reads
  `PROMPT      Each engine forecast the last holdout window from data BEFORE it;`
  SQL*Plus strips the trailing `;`. Change the final `;` to `.` and
  capitalise nothing else (the next PROMPT line starts with `MAPE%`, which
  reads fine after a full stop).

**Verify**:
- `grep -n "ORDER  BY con_dbid, metric" report/sections/04_cpu_trend.sql report/report_csv.sql` → no output
- `grep -c "BEFORE it\.$" report/sections/06_esm_compare.sql` → `1`
- `test/lint_snapshot_reads.sh` → exit 0

### Step 5: Make `rank_chart` deterministic across containers

`ddl/55_report_views_ml.sql` lines 93-95:

```
       ROW_NUMBER() OVER (PARTITION BY f.dbid
                          ORDER BY f.days_to_full NULLS LAST,
                                   f.tablespace_name)  AS rank_chart
```

`SYSAUX` / `SYSTEM` / `USERS` exist in every PDB and `days_to_full` is often
NULL, so ties are numbered arbitrarily. Change the last key line to
`f.tablespace_name, f.con_dbid)  AS rank_chart`.

**Verify**: `test/lint_dbid_windows.sh` → exit 0.

### Step 6: Let `cap_repo.set_link_password` be retried after a failed create

`repository/cap_repo.sql`, procedure `set_link_password` (around line 696).
Current:

```
        close_link(t.db_link);
        EXECUTE IMMEDIATE 'DROP DATABASE LINK ' || t.db_link;
        create_link(t.db_link, t.link_user, p_password, t.connect_string);
```

If `create_link` fails after the drop, the link is gone and every retry dies
at the unguarded `DROP` (ORA-02024). The package already has a tolerant
helper (line 241):

```
    PROCEDURE drop_link(p_link IN VARCHAR2) IS
    BEGIN
        close_link(p_link);
        EXECUTE IMMEDIATE 'DROP DATABASE LINK ' || p_link;
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END drop_link;
```

Replace the first two of the three lines with one call: `drop_link(t.db_link);`
Leave the rest of the procedure (the `SET_MODULE` save / restore and the
`WHEN OTHERS ... RAISE` handler) exactly as it is.

**Verify**: `grep -c "DROP DATABASE LINK" repository/cap_repo.sql` → one less
than before your edit (run the grep before and after);
`test/lint_appinfo.sh` → exit 0. This package is installed only in repository
mode, which the fixture harness does not install: state in your hand-back
that this step was verified by reading only.

### Step 7: Fail `install.sh` when `install_jobs.sql` created no nightly job

`install_jobs.sql` runs under `WHENEVER SQLERROR CONTINUE` (its line 105), so
a failed `DBMS_SCHEDULER.CREATE_JOB` does not stop it, and `install.sh` then
prints `install.sh: OK`. In `install.sh`, function `driver`, find this
heredoc (around line 528):

```
    cat <<EOF

PROMPT ==== install.sh: install_jobs.sql ====
DEFINE report_dir       = '${CFG[REPORT_DIR]}'
DEFINE nightly_interval = '${CFG[NIGHTLY_INTERVAL]}'
@@install_jobs.sql
$STRICT
EOF
```

`$STRICT` re-asserts `WHENEVER SQLERROR EXIT FAILURE`. Insert, between the
`$STRICT` line and the closing `EOF`:

```
DECLARE
    v_n NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n FROM all_scheduler_jobs
    WHERE  owner = '&cap_target' AND job_name = 'CAP_NIGHTLY_JOB';
    IF v_n = 0 THEN
        RAISE_APPLICATION_ERROR(-20001, 'install.sh: install_jobs.sql created no CAP_NIGHTLY_JOB.'
            || ' See the ORA- lines above (CREATE JOB privilege, nightly_interval).');
    END IF;
END;
/
```

The heredoc is unquoted, so the shell expands `$...`: the block above
contains no `$` and no backtick, keep it that way. `&cap_target` is a
SQL*Plus substitution variable the driver already defines (the job-enable
loop a few lines below uses it).

**Verify**:
- `bash -n install.sh` → exit 0
- `./install.sh --profile profiles/standalone.env --dry-run | grep -c "created no CAP_NIGHTLY_JOB"` → `1`
- `./install.sh --profile profiles/target.env --dry-run | grep -c "created no CAP_NIGHTLY_JOB"` → `0`
- `git status --short` shows no new untracked file (the dry run writes nothing)

### Step 8: Use `EXIT FAILURE` in the APEX installers

`install.sql` records why the suite uses `WHENEVER SQLERROR EXIT FAILURE`:
`EXIT SQL.SQLCODE` exits 0 for an ORA code that is a multiple of 256. Three
places still use the old form:

- `apex/install.sql:14` and `apex/workspace.sql:18`:
  `whenever sqlerror exit sql.sqlcode rollback` → `whenever sqlerror exit failure rollback`
- `apex/build.py:861` (inside the `head = f'''...` string of the export):
  the same replacement.

Then regenerate the export: `python3 apex/build.py`.

**Verify**:
- `grep -rn "exit sql.sqlcode" apex/` → no output
- `git diff --stat apex/awrcap_app.sql` → exactly `1 insertion(+), 1 deletion(-)`.
  If the diff is larger, the generator is not deterministic here: run
  `git checkout apex/awrcap_app.sql apex/build.py`, keep the two hand-written
  files changed, and report this in your hand-back.

### Step 9: Correct two README statements

- `README.md` line 26 is a second "Is instance memory sized right?" table row
  that ends "A view to query; not in the reports or alerts yet". The reports
  have shown the verdicts since M26.4 (line 23 of the same table says so).
  Delete line 26 entirely.
- `README.md` lines 112-113 say of the standalone query: "It is the suite's
  OLS fit, restarted after a purge, with the knob defaults in the `prm` CTE."
  Change that sentence to: "It is the suite's OLS fit, restarted after a
  purge or where growth stopped or began, forecast also against the one disk
  the tablespaces share, with the knob defaults in the `prm` CTE."

**Verify**: `grep -c "not in the reports or alerts yet" README.md` → `0`;
`test/docs_lint.sh` → exit 0.

### Step 10: Run every gate

1. All offline commands from "Commands you will need" → each exit 0.
2. `test/dbmint_harness.sh <SCHEMA>` → last lines contain
   `RESULT: <n> passed, 0 failed` and `log: /tmp/dbmint_harness_<SCHEMA>.log  (exit 0)`.
   The new assertions of step 2(d) appear as `PASS` lines in the log:
   `ssh`-free check: `grep -c "mad_k = 0" /tmp/dbmint_harness_<SCHEMA>.log` → `2` or more.

## Test plan

- New assertions: step 2(d) in `test/run_test.sql` (rules grade `BAD`, views
  still read at 0). Pattern: the `CAP_CFG_CHECK` block they are appended to.
- Steps 1, 6, 7, 8 have no database test in this repo's harness (ORDS, a
  repository install and the scheduler are outside the fixture run). Their
  gates are the greps and the dry run above; say so in the hand-back.

## Done criteria

- [ ] All offline commands exit 0
- [ ] `test/dbmint_harness.sh <SCHEMA>` ends with `0 failed` and `(exit 0)`
- [ ] `grep -n "REPLACE(p_val, ''" grafana/ords/awrcap_module.sql` → no output
- [ ] `grep -c "CAP\[VDFAMR\]?_" install.sql` → `2`
- [ ] `./install.sh --profile profiles/standalone.env --dry-run | grep -c "created no CAP_NIGHTLY_JOB"` → `1`
- [ ] `grep -rn "exit sql.sqlcode" apex/install.sql apex/workspace.sql` → no output
- [ ] `git status --short` lists only in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

- An excerpt in "Current state" / a step does not match the live file.
- The database harness fails on an assertion that is not one you added:
  report the `FAIL` lines; do not edit other assertions to make them pass.
- `CAPA_ANOM` with `mad_k = 0` flags rows (the new `chk_int` fails): report
  the count; do not weaken the assertion.
- The operator has not assigned a harness schema, or dbmint is unreachable
  outside the sandbox: finish the offline gates, mark the plan `BLOCKED
  (database gate not run)` and report.

## Maintenance notes

- Any future knob used as a divisor needs both a `NULLIF` in the view and a
  `CAP_CFG_CHECK` rule; `CAP_CFG_CHECK` only reports, it does not protect the
  views.
- Step 7 gates only `CAP_NIGHTLY_JOB`. `CAP_COLLECT_JOB` exists only where
  package `CAP_REPO` is installed, so it is deliberately not asserted.
- Deferred (not in this plan): the ORDS module is public by default and reads
  live views; `cap_results.purge` is never scheduled; a re-install does not
  quiesce running jobs. The maintainer chose not to plan these yet.
