# Plan 004: The HTML report and the briefing anchor every window and date on the row's own database

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat d91e3f8..HEAD -- report/report_html.sql report/html/ report/report_brief.sql test/report_html_test.js docs/demo/cap_report_demo.html`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW (drivers only; a single-database report must render byte-identical, and that is a gate)
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `d91e3f8`, 2026-11-10

## Why this matters

One repository can hold several databases ("targets"), and the project rule
is **"Per database, never across targets"**. The text report obeys it. The
HTML report and the one-page briefing do not: both compute one "newest day"
over every database in scope and use it for every anomaly window, hour strip
and "full on <date>" stamp. In a fleet report, a database whose newest AWR
day lags the fleet's (a paused collect, a different time zone, a target added
later) silently loses anomalies inside its own last N days, and its dates are
shifted by the lag.

## Current state

Files:

- `report/report_html.sql` — SQL*Plus driver; one PL/SQL block spools the data
  as one JSON object between the generated page head and tail.
- `report/html/report.js` — the renderer (plain JS, no framework). **Edit
  this**, never `report/html/page_head.sql` / `page_tail.sql`, which
  `python3 report/html/build.py` generates from `report.css` / `report.js`.
- `report/report_brief.sql` — the briefing driver (server-side HTML).
- `test/report_html_test.sh` + `test/report_html_test.js` — offline test:
  checks the generated files are current, that
  `docs/demo/cap_report_demo.html` is what `build.py --preview` produces from
  its own data block, and renders it under a stub DOM.
- `docs/demo/cap_report_demo.html` — demo page; embeds the renderer, so it
  must be regenerated after `report.js` changes.

`report/report_html.sql:257-264` — one day for the whole scope:

```
    SELECT MIN(series_first_day), MAX(series_last_day), MIN(tbspc_first_day), MAX(tbspc_last_day)
      INTO v_first_day, v_last_day, v_tb_first, v_tb_last
      FROM capr_data_window&cap_s
     WHERE (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con);
    IF v_last_day IS NULL THEN
      v_first_day := v_tb_first;
      v_last_day  := v_tb_last;
    END IF;
```

(`capr_data_window` has one row per `dbid, con_dbid` with
`series_first_day`, `series_last_day`, `tbspc_first_day`, `tbspc_last_day`.
`&cap_s` is `_S` under SNAPSHOT and empty under LIVE; keep it on every read.)

`report/report_html.sql:299` — the meta object carries it:
`|| ',"firstDay":' || jd(v_first_day) || ',"lastDay":' || jd(v_last_day)`

`report/report_html.sql:438-452` — anomalies block:

```
    FOR r IN (SELECT kind, dbid, con_dbid, series, ts, anomaly_kind, ...
              FROM   capr_anomalies&cap_s
              WHERE  (ts > v_last_day - anomaly_days OR anomaly_kind = 'CPU_SHIFT')
                AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
              ORDER  BY kind, dbid, con_dbid, series, ts, baseline_mode) LOOP
      w(v_sep || CHR(10) || '{"k":' || js(r.kind) || ...
      ...
      v_sep := ',';
    END LOOP;
```

`report/report_html.sql:488-510` — hours block:

```
  DECLARE
    v_key VARCHAR2(400);
    v_t0  DATE := TRUNC(v_last_day) - 13;
  BEGIN
    v_sep := NULL;
    w('[');
    FOR r IN (SELECT dbid, con_dbid, series, ts, day_dt, value, gap, how_flag
              FROM   capr_hourly_points&cap_s
              WHERE  day_dt >= TRUNC(v_last_day) - 13
                AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
              ORDER  BY dbid, con_dbid, series, ts) LOOP
      IF v_key IS NULL OR v_key <> r.dbid || '|' || r.con_dbid || '|' || r.series THEN
        IF v_key IS NOT NULL THEN w(']}'); END IF;
        v_key := r.dbid || '|' || r.con_dbid || '|' || r.series;
        w(v_sep || CHR(10) || '{"dbid":' || jn(r.dbid) || ',"con":' || jn(r.con_dbid)
          || ',"s":' || js(r.series) || ',"t0":' || jd(v_t0) || ',"d":[');
        v_sep := ',';
      ELSE
        w(',');
      END IF;
      w('[' || jn(r.day_dt - v_t0) || ',' || ...
```

Helpers in that driver: `js(text)`, `jn(number)`, `jd(date)` return JSON
fragments (`jd` gives a quoted `YYYY-MM-DD` or `null`); `w()` buffers text;
`p()` prints a line. `v_last_day` is declared at line 148 in the outer block.
Non-ASCII must never be emitted raw.

`report/html/report.js:33-35`:

```
  var LAST = dayN(M.lastDay);
  var FIRST = dayN(M.firstDay);
  var GEN = dayN(M.generated);
```

`dayN('YYYY-MM-DD')` returns a day number. `LAST` is used on these lines
(`grep -n "LAST\b" report/html/report.js`): 235, 306, 313, 346, 432, 433,
508, 515, 595, 614, 786, 1059-1079 (page header and banner), 1090, 1110,
1175, 1200. Fits (`f`), alerts (`a`, `top`) and anomalies (`a` in `m.anoms`)
all carry a `dbid` property; a metric object `m` has `m.f` (its fit) and
chart specs carry `m` (line 433: `... pctAxis: m.f.k === 'CPU', m: m`).

`report/report_brief.sql`:

- line 1146-1149: `v_today` = the newest `last_day` over all fits
  (`t_fit(i).last_day`; `t_fit` rows have `dbid`).
- line 572-573: the "also unusual" list keeps an alert when
  `t_al(i).day_dt > v_today - anomaly_days` (`t_al` rows have `dbid`, see
  cursor `c_al` at line 181).
- Other uses of `v_today` (lines 289, 500, 511, 697-709, 1176) are the page
  date and the runway chart axis: page level, leave them.

## Design (decided; do not redesign)

- A per-database newest day: `NVL(MAX(series_last_day), MAX(tbspc_last_day))`
  per `dbid` from `capr_data_window&cap_s`, under the same scope filter.
- The JSON meta gains `"lastByDbid":{"<dbid>":"YYYY-MM-DD",...}`.
  `"lastDay"` stays (page header, banner, and the fallback).
- JS gets `lastOf(dbid)`: the database's day, or `LAST` when the map or the
  entry is missing. Every per-series use of `LAST` becomes `lastOf(<that
  series' dbid>)`. Page-level uses keep `LAST`.
- With one database in scope, `lastOf(dbid) === LAST` everywhere, so the
  rendered page must be **identical** to today's. That is the regression gate.

## Commands you will need

| Purpose | Command (repo root) | Expected on success |
|---|---|---|
| Regenerate page head/tail | `python3 report/html/build.py` | exit 0; rewrites `report/html/page_head.sql` / `page_tail.sql` |
| Regenerate the demo page | `python3 report/html/build.py --preview docs/demo/cap_report_demo.html docs/demo/cap_report_demo.html` | exit 0 |
| HTML test | `test/report_html_test.sh` | exit 0, last line starts `OK   report_html:` |
| Offline lints | `test/lint_snapshot_reads.sh && test/lint_appinfo.sh && test/lint_dbid_windows.sh && test/docs_lint.sh` | exit 0 |
| Database harness | `test/dbmint_harness.sh <SCHEMA> --parity` | `RESULT: <n> passed, 0 failed`, the parity step reports no difference, `(exit 0)` |

The harness needs the maintainer's VM (`ssh -p 2200 oracle@dbmint`) and a
throwaway PDB1 schema the operator assigns (`CAPX1`..`CAPX3`,
`CAPW1`..`CAPW3`; never `CAPDEMO` / `CAPTEST`). About 35 minutes. A "Could
not resolve hostname" error can be your tool sandbox: retry outside it.

## Scope

**In scope**: `report/report_html.sql`, `report/html/report.js`,
`report/html/page_head.sql` and `page_tail.sql` (regenerated only),
`docs/demo/cap_report_demo.html` (regenerated only), `report/report_brief.sql`,
`test/report_html_test.js`.

**Out of scope**: every view (`ddl/`), `report/report.sql` and
`report/sections/*` (the text report is already per database),
`report/html/report.css`, `docs/demo/cap_brief_demo.html` (do not regenerate
it: that needs a database).

## Git workflow

- Branch: `advisor/004-report-per-database`
- Commits: one for the HTML report (SQL + JS + regenerated files + test), one
  for the briefing. Style: imperative subject, bullet body.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 0: Capture the "before" render (needed for the identity gate)

```
mkdir -p "$TMPDIR/p004" 2>/dev/null || export TMPDIR=/tmp && mkdir -p "$TMPDIR/p004"
git show HEAD:docs/demo/cap_report_demo.html > "$TMPDIR/p004/before.html"
```

Create `$TMPDIR/p004/render.js` (a scratch file outside the repo) by copying
`test/report_html_test.js` lines 1-44 (the `require`s, the `page` / `data` /
`renderer` extraction and the `render(json)` function) and appending:

```
process.stdout.write(render(data));
```

**Verify**: `node "$TMPDIR/p004/render.js" "$TMPDIR/p004/before.html" > "$TMPDIR/p004/before.out" && wc -c < "$TMPDIR/p004/before.out"`
→ a number above 1000.

### Step 1: `report/report_html.sql` — per-database day, in SQL

(a) Next to the declaration of `v_last_day` (line 148) add:

```
  TYPE day_tab IS TABLE OF DATE INDEX BY VARCHAR2(40);
  t_last       day_tab;
  v_min_last   DATE;
  v_last_json  VARCHAR2(32767);
```

and, with the other local functions (near `in_scope`, line 240), add:

```
  FUNCTION last_of(p_dbid IN NUMBER) RETURN DATE IS
  BEGIN
    IF t_last.EXISTS(TO_CHAR(p_dbid)) THEN RETURN t_last(TO_CHAR(p_dbid)); END IF;
    RETURN v_last_day;
  END;
```

If PL/SQL rejects the forward reference (the function must come after the
variables it reads), move the function below the declarations; do not change
its body.

(b) Directly after the `IF v_last_day IS NULL THEN ... END IF;` block shown
above (line 264), fill the map:

```
    FOR r IN (SELECT dbid, NVL(MAX(series_last_day), MAX(tbspc_last_day)) AS last_day
              FROM   capr_data_window&cap_s
              WHERE  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
              GROUP  BY dbid
              ORDER  BY dbid) LOOP
      IF r.last_day IS NOT NULL THEN
        t_last(TO_CHAR(r.dbid)) := r.last_day;
        v_min_last  := LEAST(NVL(v_min_last, r.last_day), r.last_day);
        v_last_json := v_last_json || CASE WHEN v_last_json IS NOT NULL THEN ',' END
                       || '"' || TO_CHAR(r.dbid) || '":' || jd(r.last_day);
      END IF;
    END LOOP;
    v_min_last := NVL(v_min_last, v_last_day);
```

(c) Line 299: after `|| ',"lastDay":' || jd(v_last_day)` insert
`|| ',"lastByDbid":{' || v_last_json || '}'`. Do NOT change line 314 (the
fallback meta object printed when the meta block fails).

(d) Anomalies block: in the cursor's WHERE replace `v_last_day` with
`v_min_last` (a superset read), and make the loop body conditional on the
row's own database. The loop becomes:

```
              WHERE  (ts > v_min_last - anomaly_days OR anomaly_kind = 'CPU_SHIFT')
              ...) LOOP
      IF r.anomaly_kind = 'CPU_SHIFT' OR r.ts > last_of(r.dbid) - anomaly_days THEN
        w(v_sep || CHR(10) || '{"k":' ...            -- unchanged
        ...
        v_sep := ',';
      END IF;
    END LOOP;
```

(e) Hours block: remove the initialiser from `v_t0` (`v_t0  DATE;`), change
the cursor filter to `day_dt >= TRUNC(v_min_last) - 13`, and as the **first**
statements of the loop body add:

```
      CONTINUE WHEN r.day_dt < TRUNC(last_of(r.dbid)) - 13;
```

then, inside the existing `IF v_key IS NULL OR v_key <> ...` branch, directly
after the line `v_key := r.dbid || '|' || r.con_dbid || '|' || r.series;`,
add `v_t0 := TRUNC(last_of(r.dbid)) - 13;`. Everything else in the block
stays (the `"t0"` emitted and the offsets `r.day_dt - v_t0` now use the
per-database `v_t0`).

**Verify**: `grep -c "last_of(" report/report_html.sql` → `4` (the function
header and three calls);
`grep -c "v_last_day - anomaly_days" report/report_html.sql` → `0`;
`test/lint_snapshot_reads.sh` → exit 0.

### Step 2: `report/html/report.js` — `lastOf(dbid)`

(a) After `var GEN = dayN(M.generated);` (line 35) add:

```
  var LAST_BY = M.lastByDbid || {};
  function lastOf(dbid) { var s = dbid != null ? LAST_BY[dbid] : null; return s ? dayN(s) : LAST; }
```

(b) Replace `LAST` by the per-series day at each per-series use. Work through
`grep -n "LAST\b" report/html/report.js` line by line with this table (line
numbers are from the planned commit; match by content):

| Line | Context | Replace `LAST` with |
|---|---|---|
| 235 | `fDay(LAST + f.dtf)` | `lastOf(f.dbid)` |
| 306 | `avgLast(pts, n)` body: `p.x > LAST - n` | add a third parameter `last` to `avgLast` and use it; every caller passes `lastOf(m.f.dbid)` for the metric `m` it is working on |
| 313 | `alertWhen(a)`: `stamp(LAST + a.v)` | `lastOf(a.dbid)` |
| 346 | `anomalyEvents(m)`: `d <= LAST - ANOM_DAYS` | `lastOf(a.dbid)` |
| 432, 433 | chart spec: `x0 ... : LAST - 90`, `x1: LAST + horizon(m)` | `lastOf(m.f.dbid)` |
| 508, 515, 595, 614, 1175, 1200 | inside chart / sparkline / hover functions that receive a spec or a metric | `lastOf(<metric>.f.dbid)`, where `<metric>` is `spec.m` or the `m` parameter in scope; compute it once at the top of the function (`var L = lastOf(spec.m.f.dbid);`) and use `L` |
| 786 | `fDayY(Math.round(LAST + f.dtf))` | `lastOf(f.dbid)` |
| 1090 | overview headline: `LAST + top.v` | `lastOf(top.dbid)` |
| 1110 | overview row: `stamp(LAST + soon.f.dtf)` | `lastOf(soon.f.dbid)` |
| 1059, 1063, 1064, 1078, 1079 | page title, header, "newest AWR day" banner | keep `LAST` |

Rule for any `LAST` not in the table or whose context has no series in scope
(for example a chart of memory components, where `spec.m` or `m.f` may be
undefined): guard it — `lastOf(m && m.f ? m.f.dbid : null)` — which falls
back to `LAST`. Never let `lastOf` receive a property read on `undefined`.

(c) Regenerate: `python3 report/html/build.py`, then
`python3 report/html/build.py --preview docs/demo/cap_report_demo.html docs/demo/cap_report_demo.html`.

**Verify (identity gate)**:

```
node "$TMPDIR/p004/render.js" docs/demo/cap_report_demo.html > "$TMPDIR/p004/after.out"
cmp "$TMPDIR/p004/before.out" "$TMPDIR/p004/after.out" && echo IDENTICAL
```

→ prints `IDENTICAL`. (The demo data has no `lastByDbid`, so every `lastOf`
falls back to `LAST`.) Then `test/report_html_test.sh` → exit 0.

### Step 3: Test the per-database path in `test/report_html_test.js`

After the existing full-render checks (after the line that checks
`'page is ASCII only'`), add a block that renders the demo data twice more.
`d` is the parsed data, `html` the base render, `render(json)` and
`check(ok, what)` exist:

```
// Per-database anchors: with every database's day equal to meta.lastDay the
// page is unchanged; with one database lagging 10 days its dates move.
{
  const dbids = [...new Set(d.fits.map(f => f.dbid))];
  const same = JSON.parse(data);
  same.meta.lastByDbid = Object.fromEntries(dbids.map(x => [x, same.meta.lastDay]));
  check(render(JSON.stringify(same)) === html, 'lastByDbid equal to lastDay renders the same page');
  const lag = JSON.parse(data);
  const t = Date.UTC(+lag.meta.lastDay.slice(0, 4), +lag.meta.lastDay.slice(5, 7) - 1, +lag.meta.lastDay.slice(8, 10)) - 10 * 86400000;
  lag.meta.lastByDbid = Object.fromEntries(dbids.map(x => [x, new Date(t).toISOString().slice(0, 10)]));
  const hl = render(JSON.stringify(lag));
  check(hl !== html, 'a database lagging 10 days changes its dates');
  check(!hl.includes('undefined') && !hl.includes('NaN'), 'lagging render is clean');
}
```

If the data object's meta key is not `d.meta` with `lastDay` (check the first
lines of the demo's data block), adapt the two property paths, nothing else.

**Verify**: `test/report_html_test.sh` → exit 0 and no `FAIL` line.

### Step 4: `report/report_brief.sql` — the "also unusual" window per database

(a) In the declarations (near `v_today DATE;`, line 165) add:

```
  TYPE day_by_db IS TABLE OF DATE INDEX BY VARCHAR2(40);
  t_today     day_by_db;
```

(b) In the loop at lines 1146-1148 that computes `v_today`, add inside the
loop body:

```
      IF NOT t_today.EXISTS(TO_CHAR(t_fit(i).dbid))
         OR t_today(TO_CHAR(t_fit(i).dbid)) < t_fit(i).last_day THEN
        t_today(TO_CHAR(t_fit(i).dbid)) := t_fit(i).last_day;
      END IF;
```

(c) At lines 572-573 replace `t_al(i).day_dt > v_today - anomaly_days` with

```
t_al(i).day_dt > CASE WHEN t_today.EXISTS(TO_CHAR(t_al(i).dbid))
                      THEN t_today(TO_CHAR(t_al(i).dbid)) ELSE v_today END - anomaly_days
```

`t_today` must be visible where line 573 runs (it is a nested procedure of
the same block; if it is declared before `v_today`, declare `t_today` right
beside `v_today`). This driver uses `~` as its substitution character:
introduce no `~` and no `&`.

**Verify**: `grep -c "t_today" report/report_brief.sql` → `5` or more
(matching lines: the declaration, three in the loop, two at the window test);
`test/lint_snapshot_reads.sh && test/lint_appinfo.sh` → exit 0.

### Step 5: Database gate

`test/dbmint_harness.sh <SCHEMA> --parity` → `RESULT: <n> passed, 0 failed`,
the parity step reports LIVE and SNAPSHOT reports equal, `(exit 0)`. The
fixture has one database, so this proves "nothing changed for one database"
and that both drivers still compile and run.

## Test plan

- New offline checks: step 3 (same-day map = identical page; lagging map =
  changed, clean page).
- Identity gate: step 2 `cmp` on the demo render before and after.
- Not covered by any automated test: a real two-database report. Say so in
  the hand-back; the operator can check it on a fleet schema with
  `report/run_report.sh --html`.

## Done criteria

- [ ] `cmp "$TMPDIR/p004/before.out" "$TMPDIR/p004/after.out"` → identical
- [ ] `test/report_html_test.sh` exits 0 with the three new checks passing
- [ ] `python3 report/html/build.py --check` exits 0
- [ ] `grep -c "v_last_day - anomaly_days" report/report_html.sql` → `0`
- [ ] Offline lints exit 0
- [ ] `test/dbmint_harness.sh <SCHEMA> --parity` → `0 failed`, `(exit 0)`
- [ ] `git status --short` lists only in-scope files (the scratch files are under `$TMPDIR`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The identity gate fails and you cannot find the `LAST` replacement that
  changed a single-database page within two attempts: revert `report.js`,
  report which line pair differs (`diff <(tr '>' '>\n' < before.out) <(tr '>' '>\n' < after.out) | head`).
- A `LAST` use sits in a function where no series or dbid is reachable and
  the fallback guard is not obviously right: leave it as `LAST` and list it
  in the hand-back.
- `python3 report/html/build.py --preview` changes more of the demo page than
  the embedded renderer (`git diff --stat docs/demo/cap_report_demo.html`
  shows the data block changed).

## Maintenance notes

- A new per-series date computation in `report.js` must use `lastOf(dbid)`,
  never `LAST`.
- `days_to_full` counts from the series' own `last_day` in the views; this
  plan anchors on the database's newest day, which equals it for every
  current series. A non-current series (`"cur":0`) keeps today's small offset.
- Deferred, found in the same audit, not part of this plan: `report.js:4`
  parses the data block without a try/catch (one bad character blanks the
  page); the hour strip drops an interval that ends at 24:00; hovering a card
  with no points throws.
