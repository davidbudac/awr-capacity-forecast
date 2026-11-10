# Tablespace capacity forecast query (tbspc_capacity.sql)

## What it is

One read-only SQL query that answers, for every permanent tablespace: how full is it, how fast does it grow, and when will it be full.

- It runs directly on the database it measures. Nothing is installed, created or written.
- It reads the AWR history (`DBA_HIST_*` views, Diagnostics Pack licence required) and one live view.
- It returns one row per container and permanent tablespace.
- UNDO and TEMPORARY tablespaces are left out. Their usage goes up and down with the workload and is not a growth signal.

## How to run it

```
SQL> @standalone/tbspc_capacity.sql
```

- Run it in `CDB$ROOT` to see every container, or in a non-CDB. Inside a PDB it shows that PDB only.
- The query text alone (from `WITH` to the closing semicolon) also runs in SQL Developer or any other client.
- The user needs SELECT on `DBA_HIST_SNAPSHOT`, `DBA_HIST_TBSPC_SPACE_USAGE`, `DBA_HIST_TABLESPACE`, `DBA_HIST_DATAFILE`, `DBA_HIST_PDB_INSTANCE`, `DBA_HIST_DATABASE_INSTANCE` and `CDB_TABLESPACE_USAGE_METRICS`. `SELECT_CATALOG_ROLE` covers all seven.
- A common user in `CDB$ROOT` also needs `CONTAINER_DATA = ALL`, otherwise it sees the root only.

## How much history it uses

- At most the last **90 days**, counted back from the tablespace's last sampled day.
- **One point per day**: the last AWR snapshot of that day. More snapshots per day do not add points.
- If AWR holds fewer than 90 days, it uses what exists. The `DAYS` column shows the number of days actually used.
- With fewer than **14 days** the row is marked `INSUFFICIENT_HISTORY`. Stock AWR retention is 8 days, so a database with default settings lands here until the retention is raised.

## How it works, step by step

### 1. Build the daily series

For each tablespace and day it takes the last snapshot of the day from `DBA_HIST_TBSPC_SPACE_USAGE`.

```
used bytes = used blocks x tablespace block size
```

### 2. Work out the limit

The limit is the size the tablespace can reach before it is full.

| Case | Limit | `LIM` shows |
|---|---|---|
| Autoextend is on | The autoextend maximum size recorded by AWR | `AUTO` |
| Autoextend is off | The allocated size | `ALLOC` |
| The live ceiling is lower than either of the above | The live ceiling | `LIVE` |

The live ceiling comes from `CDB_TABLESPACE_USAGE_METRICS`. Oracle computes it right now and caps the autoextend maximum by the free space of the filesystem or ASM disk group behind the datafiles. AWR does not apply that cap. Example: a datafile may autoextend to 32 GB, but the disk has 20 GB free. AWR says 32 GB, the live view says allocated size + 20 GB.

Each tablespace is capped on its own. Several tablespaces on the same disk each count the same free space, so their limits can still add up to more than the disk holds.

### 3. Detect purges

A large one-day drop in used space (a purge, a partition drop, a reorganisation) would bend a straight line through the history. The query looks for such "cliffs".

A day counts as a cliff when the drop from the previous day is larger than both of these:

- 6 times the typical day-to-day variation of that tablespace
- 100 MB

```
typical variation = 1.4826 x MEDIAN( | daily change - MEDIAN(daily change) | )
cliff             = daily change < -GREATEST(6 x typical variation, 100 MB)
```

What happens next depends on how many cliffs the 90-day window holds:

- **One cliff:** the fit restarts at the cliff day. Only the data after the purge is used.
- **Two or more cliffs:** the tablespace fills and is purged regularly. It is graded `CYCLIC` and judged on its peak fill level, not on a growth line.

### 4. Fit a straight line

Through the remaining daily points the query fits a straight line (ordinary least squares, Oracle's `REGR_SLOPE`). The slope of that line is the growth rate in bytes per day.

### 5. Project forward from today

Every projection starts at today's actual used size, not at the fitted line:

```
projected size in h days = used now + growth per day x h
```

### 6. Work out the worst case

The growth rate from step 4 is an estimate. The worst case asks how much faster growth could plausibly be. The query measures that uncertainty in two ways and keeps the larger one.

**Way 1: distance from the line.** How far do the daily points sit from the fitted line? Small distances mean a small uncertainty.

**Way 2: day-to-day jumpiness.** How much does the growth vary from one day to the next? A tablespace that adds nothing on most days and a lot on a few days has an uncertain rate, even though its size curve looks smooth.

Way 1 alone is too optimistic. Tablespace size is a running total: today's size is yesterday's size plus today's growth. A running total always looks smooth, like a car's odometer that climbs steadily even when the speed swings between 0 and 150. Way 2 looks at the speed itself.

The exact formulas are in the section "Worst-case formulas" below.

## What each column means

GB and MB are binary units: 1 GB = 1024 x 1024 x 1024 bytes, 1 MB = 1024 x 1024 bytes.

| Column | Meaning | How it is calculated |
|---|---|---|
| `CONTAINER` | Container the tablespace belongs to | PDB name from AWR. In a non-CDB the database name. |
| `TABLESPACE` | Tablespace name | From `DBA_HIST_TABLESPACE`. |
| `LIM` | Where the limit comes from | `AUTO`, `ALLOC` or `LIVE`, see step 2. |
| `USED_GB` | Space used now | Used bytes on the newest sampled day / 1 GB. |
| `LIMIT_GB` | Size at which the tablespace is full | See step 2. |
| `PCT` | Percent full now | `100 x used / limit`, one decimal. |
| `MB_DAY` | Growth per day | Slope of the fitted line / 1 MB. Negative when the tablespace shrinks. |
| `R2` | How well a straight line describes the history, 0 to 1 | R squared of the fit. 1 = the points lie exactly on a line. A completely flat series also reads 1. |
| `DAYS` | Days of history the fit used | Count of daily points in the fit window, after a purge restart. |
| `GB_30`, `GB_90` | Expected size in 30 and 90 days | `used + growth per day x 30` (or 90). Empty for `CYCLIC`. |
| `DTF` | Days to full, expected | `(limit - used) / growth per day`, rounded down. Empty when not growing, when `CYCLIC`, or when more than 100 years away. |
| `DTF_WORST` | Days to full, worst case | `(limit - used) / (growth per day + uncertainty of the growth rate)`, rounded down. Same empty rules as `DTF`. |
| `FULL_BY` | Worst-case date the tablespace is full | Newest sampled day + `DTF_WORST`. |
| `ADD_GB_90` | Space to add so that even the worst case stays under the limit for 90 days | `(used + growth per day x 90 + uncertainty at 90 days) - limit`, never below 0. 0 = nothing to add. Empty for `CYCLIC`. |
| `PEAK_PCT` | Highest fill level in the window, percent of the limit | `100 x highest used / limit`. Shown for `CYCLIC` only. |
| `QUALITY` | How far the forecast can be trusted | See "Quality grades". |
| `STATUS` | `CRIT`, `WARN` or `OK` | See "Status rules". |
| `WHY` | The rule that set the status | For example `pct >= 90` or `dtf <= 30`. Empty for `OK`. |
| `LAST_DAY` | Newest day with a sample for this tablespace | Normally today. |

Rows are sorted by status (`CRIT` first), then by `DTF_WORST` (soonest first), then by `PCT` (fullest first).

A tablespace whose last sample is more than 3 days older than the newest AWR snapshot is hidden. It was dropped or is no longer sampled.

## Quality grades

The first rule that matches wins.

| Grade | Rule | What it tells you |
|---|---|---|
| `INSUFFICIENT_HISTORY` | Fewer than 14 days in the fit | Too little data. Trust `PCT`, not the forecast. |
| `CYCLIC` | Two or more purge cliffs in the window | Fills and is purged regularly. Look at `PEAK_PCT`. |
| `FLAT` | Growth is exactly 0 | Not growing. |
| `LOW_CONFIDENCE` | `R2` below 0.60 | The history does not follow a line well. Treat `DTF` as a rough hint. |
| `OK` | None of the above | The forecast is usable. |

## Status rules

The first rule that matches wins.

| Order | Rule | Status |
|---|---|---|
| 1 | `PCT` is 97 or more | `CRIT` |
| 2 | Quality is `OK` and `DTF` is 30 days or less | `CRIT` |
| 3 | `PCT` is 90 or more | `WARN` |
| 4 | Quality is `OK` and `DTF` is 90 days or less | `WARN` |
| 5 | Otherwise | `OK` |

Notes:

- For `CYCLIC` tablespaces rules 1 and 3 use `PEAK_PCT` instead of `PCT`.
- The fill-level rules (1 and 3) apply at any quality. The days-to-full rules (2 and 4) apply only when the quality is `OK`.
- Status uses the expected `DTF`, not `DTF_WORST`. A row can be `OK` and still show a `FULL_BY` date inside 90 days. Read `FULL_BY` as the planning date for the cautious case.

## Worked example

A tablespace with 27 days of history:

| Input | Value |
|---|---|
| Used now | 8.590 GB |
| Limit | 32.000 GB |
| Growth per day (fitted line) | 77.737 MB |
| Uncertainty of the growth rate (larger of the two ways) | 163.534 MB per day |
| Uncertainty at 90 days | 22.098 GB |

```
PCT        = 100 x 8.590 / 32.000                        = 26.8
GB_30      = 8.590 + 77.737 x 30 / 1024                  = 10.868
GB_90      = 8.590 + 77.737 x 90 / 1024                  = 15.423
DTF        = (32.000 - 8.590) x 1024 / 77.737            = 308 days
DTF_WORST  = (32.000 - 8.590) x 1024 / (77.737 + 163.534) = 99 days
FULL_BY    = newest sampled day + 99 days
ADD_GB_90  = 15.423 + 22.098 - 32.000                    = 5.521 GB
```

How to read it: growth as observed fills the tablespace in about 308 days. If growth stays as uneven as it has been, it could be full in 99 days. Adding 5.5 GB keeps even that case under the limit for the next 90 days.

## Worst-case formulas

Symbols: `n` = days in the fit, `x` = day number, `y` = used bytes, `h` = days ahead.

**Way 1, distance from the line (OLS):**

```
SSE        = SYY - SXY^2 / SXX               sum of squared distances from the line
resid_se   = SQRT( SSE / (n - 2) )           typical distance from the line
t          = 1.96 + 2.4 / (n - 2)            95% factor
slope_ci_1 = t x resid_se / SQRT(SXX)
half_1(h)  = t x resid_se x SQRT( 1 + 1/n + (x_last + h - x_mean)^2 / SXX )
```

**Way 2, day-to-day rates:**

```
rate       = (used today - used on the previous sampled day) / days between them
sd         = standard deviation of the rates
r          = number of rates  (n - 1)
se         = sd / SQRT(r)
t          = 1.96 + 2.4 / (r - 1)
slope_ci_2 = t x se
half_2(h)  = t x ( sd x SQRT(h) + h x se )
```

**Combined:**

```
uncertainty of the growth rate = GREATEST(slope_ci_1, slope_ci_2)
uncertainty at 90 days         = GREATEST(half_1(90), half_2(90))

DTF_WORST = FLOOR( (limit - used) / (slope + uncertainty of the growth rate) )
ADD_GB_90 = GREATEST(0, used + slope x 90 + uncertainty at 90 days - limit)
```

`SXX`, `SYY`, `SXY` are Oracle's `REGR_SXX`, `REGR_SYY`, `REGR_SXY`. The factor `t` is a close approximation of the Student t value for a 95% interval.

## Settings

The defaults sit at the top of the query in the `prm` block and can be edited there.

| Setting | Default | Meaning |
|---|---|---|
| `train_days` | 90 | Days of history to fit |
| `min_train_days` | 14 | Fewer days than this = `INSUFFICIENT_HISTORY` |
| `r2_gate` | 0.60 | `R2` below this = `LOW_CONFIDENCE` |
| `shrink_mad_k` | 6 | A cliff is a drop larger than this many times the typical variation |
| `abs_floor_bytes` | 100 MB | ... and larger than this |
| `cyclic_min_cliffs` | 2 | This many cliffs = `CYCLIC`. Below 2 turns the grade off. |
| `dtf_warn` / `dtf_crit` | 90 / 30 | Days to full at or below = `WARN` / `CRIT` |
| `nearfull_warn_pct` / `nearfull_crit_pct` | 90 / 97 | Percent full at or above = `WARN` / `CRIT` |
| `stale_days` | 3 | A tablespace not sampled for this long is hidden |
| `dbid` | empty | Empty = the database of the newest AWR snapshot |

## Limits of the forecast

- **It assumes steady growth.** A straight line cannot foresee a one-off bulk load, a new application or a planned purge.
- **Short history, weak forecast.** With 14 to 30 days the growth rate is uncertain. `DTF_WORST` reflects that; `DTF` does not.
- **The limit is only as real as the storage.** `LIM = LIVE` corrects a single tablespace. It does not notice several tablespaces competing for the same disk.
- **`CYCLIC` tablespaces get no days-to-full.** They are judged on their peak fill level only.
- **Used space is the value of the day's last AWR snapshot.** The newest day is a partial day.
- **No history is kept.** Each run recomputes everything from AWR. Results change as AWR ages data out.
