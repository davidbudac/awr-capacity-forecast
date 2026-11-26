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
- It uses fewer days when the fit restarts: after a purge (step 3), or where growth stopped or began (step 4). The `RESTART` column says which.
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

A purge can spread over two days: it ran past midnight, or the delete was followed by a shrink the next day. Cliff days on adjacent days therefore count as one purge (setting `cliff_merge_days`, 1 day).

What happens next depends on how many purges the 90-day window holds:

- **One purge:** the fit restarts at its last cliff day. Only the data after the purge is used.
- **Two or more purges:** the tablespace fills and is purged regularly. It is graded `CYCLIC` and judged on its peak fill level, not on a growth line.

### 4. Detect growth that stopped or began

One straight line through 90 days assumes that the tablespace grew at one rate for all 90 days. That is wrong for a tablespace that grew in only a part of them:

- **Growth stopped.** A tablespace that holds September's data fills during September and gets nothing afterwards. A line through "ramp, then flat" still points up, and would show a full date for about three more months.
- **Growth began.** A tablespace that was empty for months and started to fill two weeks ago. A line through "flat, then ramp" is far too shallow.

The query finds both cases from the days on which the tablespace grew.

- **Growth day:** a day on which the used size reaches a new high, above every earlier day of the window. The new high must exceed the old one by more than 0.1% of the window's total rise, so a few kilobytes do not count.
- **Pause:** a run of days without a growth day.

When a pause is long, the fit restarts and the `RESTART` column says why:

| `RESTART` | Meaning | The long pause | The fit then uses |
|---|---|---|---|
| `STOP` | Growth stopped | The pause that runs up to today | Only the days after the last growth day |
| `START` | Growth began | The pause before the first growth day | The days from the last day of that pause on. Only when at least 14 days are left. |

A pause is long when all three of these hold:

1. **It lasts at least 14 days** (`quiet_days`).
2. **It is at least twice as long as the longest other pause** (`quiet_ratio`). A tablespace that adds one extent every 20 days is not stopped after 14 quiet days. `STOP` compares with the pauses between two growth days. `START` compares with those and with the pause that runs up to today.
3. **It is unlikely to be chance** (`quiet_chance`, 1%). The tablespace had `g` growth days, the first and the last `s` days apart. If it still grew at that pace, the chance of a pause of `q` days is taken as:

```
STOP:   chance of a pause of q days = (s / (s + q)) ^ g
START:  chance of a pause of q days = (s / (s + q)) ^ (g - 1)
```

Examples for `STOP`:

- 30 growth days in a row (`g` = 30, `s` = 29), then 14 quiet days: `(29 / 43) ^ 30` = 0.000007. Stopped.
- 3 growth days, 10 days apart (`g` = 3, `s` = 20), then 30 quiet days: `(20 / 50) ^ 3` = 0.064. Not stopped: with so few growth days a long pause proves nothing.
- 2 growth days in a row (`g` = 2, `s` = 1), then 14 quiet days: `(1 / 15) ^ 2` = 0.004. Stopped.
- 1 growth day (`g` = 1, `s` = 0), then 14 quiet days: the chance is 0. Stopped.

**One growth day is a load, not growth.** With one growth day there is no pace to compare the pause with (`s` = 0), so rule 1 decides alone: after 14 quiet days the load counts as finished. The reason is what a straight line does with such a tablespace. A line through "flat, one jump, flat" has a slope. When the jump sits in the middle of the window the line even fits well (`R2` 0.75, quality `OK`) and shows a full date for a tablespace that got one bulk load and nothing since. The same happens to a month's tablespace on the days when all but the last one or two days of its ramp have left the 90-day window. With `STOP`, both read `FLAT`.

The price is the tablespace that really grows in single steps, weeks apart. While two of its steps are in the window, the pause between them is the yardstick (rule 2) and it is not stopped. Once only one step is left in the window, it reads `STOP` and `FLAT` until the next step. See "Limits of the forecast".

`START` asks for one growth day more (`g - 1`). After a `START` the growth rate is measured from the growth days alone, and one growth day has no rate. Its chance is 1, so one growth day never starts a fit.

After a `STOP` the line is fitted through the pause only. A tablespace that stayed flat reads `FLAT` and has no `DTF`. One that still creeps up gets the small rate it really has.

This step is skipped for `CYCLIC` tablespaces. Set `quiet_days` to 0 to switch it off.

### 5. Fit a straight line

Through the remaining daily points the query fits a straight line (ordinary least squares, Oracle's `REGR_SLOPE`). The slope of that line is the growth rate in bytes per day.

### 6. Project forward from today

Every projection starts at today's actual used size, not at the fitted line:

```
projected size in h days = used now + growth per day x h
```

### 7. Work out the worst case

The growth rate from step 5 is an estimate. The worst case asks how much faster growth could plausibly be. The query measures that uncertainty in two ways and keeps the larger one.

**Way 1: distance from the line.** How far do the daily points sit from the fitted line? Small distances mean a small uncertainty.

**Way 2: day-to-day jumpiness.** How much does the growth vary from one day to the next? A tablespace that adds nothing on most days and a lot on a few days has an uncertain rate, even though its size curve looks smooth.

Way 1 alone is too optimistic. Tablespace size is a running total: today's size is yesterday's size plus today's growth. A running total always looks smooth, like a car's odometer that climbs steadily even when the speed swings between 0 and 150. Way 2 looks at the speed itself.

The exact formulas are in the section "Worst-case formulas" below.

### 8. Share the disk

Steps 1 to 7 look at each tablespace alone. In reality the datafiles sit on one disk, and a tablespace that could still grow by its own limit is stuck once the disk is full. This step forecasts all tablespaces together, on the assumption that every datafile is on the same filesystem or disk group and that no storage is added.

- **Each tablespace keeps growing at its own `MB_DAY`.** A shrinking, flat or `CYCLIC` tablespace counts as not growing. A datafile never gives space back to the disk on its own.
- **Growth first fills the free space inside the datafiles** (allocated size minus used). That costs no disk space.
- **Only when its files are full does a tablespace take space from the disk,** until it reaches its own limit.
- **The disk is full on the day all those takes add up to the free space on the disk.** This day is `DISK_DTF`.
- **After that day a tablespace is stuck the first time it has to extend.** A tablespace with free space left inside its files keeps going until that space is used up.

```
days until its files are full = (allocated - used) / growth per day
DTF_SHARED = the earlier of
               DTF                                        its own limit
               the later of DISK_DTF and
                            days until its files are full  the disk
```

When `DTF_SHARED` is smaller than `DTF`, the disk stops the tablespace before its own limit does.

**How big each tablespace can get.** `LIMIT_SHARED_GB` is the size the tablespace has reached on the day it is stuck. It is the tablespace's real ceiling while all the others keep growing as forecast:

```
growing:      LIMIT_SHARED_GB = the smaller of  LIMIT_GB
                                                the larger of  allocated size
                                                               used + growth per day x DISK_DTF
not growing:  LIMIT_SHARED_GB = allocated size
```

**The worst case on the shared disk.** `DTF_SHARED_WORST` repeats the whole simulation with every tablespace growing at its worst-case rate at the same time. That rate is the one behind `DTF_WORST`: growth per day plus the uncertainty of the growth rate (step 7). The disk then fills sooner, and every tablespace is stuck sooner.

```
worst rate       = growth per day + uncertainty of the growth rate     for every tablespace
DTF_SHARED_WORST = DTF_SHARED, calculated with the worst rates
```

All tablespaces growing at the top of their range together is less likely than any single one doing so. Read `DTF_SHARED_WORST` as the cautious edge for planning, not as a 95% statement about the disk.

The difference between `LIMIT_SHARED_GB` and the allocated size is the tablespace's share of the free disk space. Over all tablespaces these shares add up to `DISK_FREE_GB`. A fast-growing tablespace gets a large share, a slow one a small share. A tablespace that is not growing gets none: by the time the disk is full it holds what it has allocated.

**Where the free disk space comes from.** Oracle has no general view for filesystem free space. But when it caps a tablespace by storage (`LIM = LIVE`), the live ceiling minus the allocated size is the free space on the disk, for a tablespace with one datafile or with several. The query takes the smallest such value and shows it as `DISK_FREE_GB`. Compare it with `df`. If no tablespace is capped, the free space is not known: `DISK_FREE_GB` and `DISK_DTF` are empty and `DTF_SHARED` equals `DTF`. In that case, or to correct the value, set `disk_free_gb` in the settings.

Everything else on the disk (UNDO, TEMP, redo logs, other files, other databases) is taken as constant. `LIMIT_SHARED_GB` and `DISK_DTF` are the expected case; only `DTF_SHARED_WORST` is the worst case.

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
| `DAYS` | Days of history the fit used | Count of daily points in the fit window, after a restart. |
| `RESTART` | Why the fit uses fewer days than the history holds | `PURGE` = since the purge cliff (step 3). `STOP` = since growth stopped, `START` = since growth began (step 4). Empty = the whole window. |
| `GB_30`, `GB_90` | Expected size in 30 and 90 days | `used + growth per day x 30` (or 90). Empty for `CYCLIC`. |
| `DTF` | Days to full, expected | `(limit - used) / growth per day`, rounded down. Empty when not growing, when `CYCLIC`, or when more than 100 years away. |
| `DTF_SHARED` | Days until the tablespace is stuck when all tablespaces share one disk | The earlier of `DTF` and the first day it has to extend after the disk is full, see step 8. Same empty rules as `DTF`, except that it can show a value where `DTF` is more than 100 years away. |
| `LIMIT_SHARED_GB` | The largest size the tablespace reaches when all tablespaces share one disk | Its size on the day it is stuck, see step 8. Equal to `LIMIT_GB` when the disk does not fill or `DISK_FREE_GB` is empty. |
| `DTF_WORST` | Days to full, worst case | `(limit - used) / (growth per day + uncertainty of the growth rate)`, rounded down. Same empty rules as `DTF`. |
| `DTF_SHARED_WORST` | Days until the tablespace is stuck on the shared disk, worst case | `DTF_SHARED` with every tablespace at its worst-case rate at once, see step 8. Empty when not growing or when the history is too short for an uncertainty. |
| `FULL_BY` | Worst-case date the tablespace reaches its own limit | Newest sampled day + `DTF_WORST`. It does not include the shared disk. |
| `ADD_GB_90` | Space to add so that even the worst case stays under the limit for 90 days | `(used + growth per day x 90 + uncertainty at 90 days) - limit`, never below 0. 0 = nothing to add. Empty for `CYCLIC`. |
| `PEAK_PCT` | Highest fill level in the window, percent of the limit | `100 x highest used / limit`. Shown for `CYCLIC` only. |
| `QUALITY` | How far the forecast can be trusted | See "Quality grades". |
| `STATUS` | `CRIT`, `WARN` or `OK` | See "Status rules". |
| `WHY` | The rule that set the status | For example `pct >= 90`, `dtf <= 30` or `disk dtf <= 30`. Empty for `OK`. |
| `DISK_FREE_GB` | Free space on the shared disk now | See step 8. The same on every row. Empty = not known. |
| `DISK_DTF` | Days until the shared disk is full | See step 8. The same on every row. Empty = it does not fill, it is more than 100 years away, or `DISK_FREE_GB` is empty. |
| `LAST_DAY` | Newest day with a sample for this tablespace | Normally today. |

Rows are sorted by status (`CRIT` first), then by `DTF_WORST` (soonest first), then by `PCT` (fullest first).

A tablespace whose last sample is more than 3 days older than the newest AWR snapshot is hidden. It was dropped or is no longer sampled.

## Quality grades

The first rule that matches wins.

| Grade | Rule | What it tells you |
|---|---|---|
| `INSUFFICIENT_HISTORY` | Fewer than 14 days in the fit | Too little data. Trust `PCT`, not the forecast. |
| `CYCLIC` | Two or more purges in the window | Fills and is purged regularly. Look at `PEAK_PCT`. |
| `FLAT` | Growth is exactly 0 | Not growing. With `RESTART` = `STOP`: it grew earlier in the window and has stopped. |
| `LOW_CONFIDENCE` | `R2` below 0.60 | The history does not follow a line well. Treat `DTF` as a rough hint. |
| `OK` | None of the above | The forecast is usable. |

## Status rules

The first rule that matches wins.

| Order | Rule | Status |
|---|---|---|
| 1 | `PCT` is 97 or more | `CRIT` |
| 2 | Quality is `OK` and `DTF_SHARED` is 30 days or less | `CRIT` |
| 3 | `PCT` is 90 or more | `WARN` |
| 4 | Quality is `OK` and `DTF_SHARED` is 90 days or less | `WARN` |
| 5 | Otherwise | `OK` |

Notes:

- For `CYCLIC` tablespaces rules 1 and 3 use `PEAK_PCT` instead of `PCT`.
- The fill-level rules (1 and 3) apply at any quality. The days-to-full rules (2 and 4) apply only when the quality is `OK`.
- Rules 2 and 4 use `DTF_SHARED`, so a disk that is about to fill turns every growing tablespace with quality `OK` to `WARN` or `CRIT` at once. `WHY` then reads `disk dtf <= 30` (or 90). When the tablespace's own limit comes first it reads `dtf <= 30`.
- The quality is the tablespace's own. The disk day behind `DTF_SHARED` sums the growth of every tablespace, whatever its quality.
- Status uses the expected case, not `DTF_WORST`. A row can be `OK` and still show a `FULL_BY` date inside 90 days. Read `FULL_BY` as the planning date for the cautious case.

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

### Shared disk example

The disk has 27.927 GB free. Eight tablespaces grow, together by about 110 MB per day. Three of them:

| Tablespace | Used now | Growth per day | Free inside its files lasts | `LIMIT_GB` (alone) | `LIMIT_SHARED_GB` | `DTF` (alone) | `DTF_SHARED` | `DTF_WORST` (alone) | `DTF_SHARED_WORST` |
|---|---|---|---|---|---|---|---|---|---|
| A | 8.7 GB | 78.2 MB | 5 days | 32.0 | 29.0 | 305 | 265 | 98 | 89 |
| B | 2.2 GB | 19.3 MB | 5 days | 30.2 | 7.2 | 1486 | 265 | 558 | 89 |
| C | 0.7 GB | 0.14 MB | 1926 days | 2.0 | 1.0 | 9186 | 1926 | 1865 | 391 |

`DISK_DTF` is 265: after 265 days the growth of all tablespaces has used the 27.927 GB. A and B are extending by then, so both are stuck on day 265, long before their own limits. C has enough free space inside its files for 1926 days and is stuck only then.

Read B's row this way. Alone it could grow to 30.2 GB. But A grows four times as fast and takes most of the free disk first, so B is stuck at 7.2 GB (2.2 GB now + 19.3 MB x 265 days). C never gets to extend at all and stays at the 1.0 GB it has allocated.

In the worst case every tablespace grows about three times as fast, the disk is full after 89 days, and A and B are stuck then. Alone, B's worst case would be 558 days.

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
| `cyclic_min_cliffs` | 2 | This many purges = `CYCLIC`. Below 2 turns the grade off. |
| `cliff_merge_days` | 1 | Cliff days at most this many days apart are one purge. 0 = every cliff day is a purge of its own. |
| `quiet_days` | 14 | Growth stopped or began = a pause of at least this many days. 0 turns step 4 off. |
| `quiet_ratio` | 2 | ... and at least this many times the longest other pause |
| `quiet_chance` | 0.01 | ... and less likely than this to be chance |
| `growth_floor` | 0.001 | A growth day is a new high by more than this share of the window's rise |
| `dtf_warn` / `dtf_crit` | 90 / 30 | Days to full at or below = `WARN` / `CRIT` |
| `nearfull_warn_pct` / `nearfull_crit_pct` | 90 / 97 | Percent full at or above = `WARN` / `CRIT` |
| `stale_days` | 3 | A tablespace not sampled for this long is hidden |
| `disk_free_gb` | empty | Free GB on the shared disk. Empty = read from the live view, see step 8. |
| `dbid` | empty | Empty = the database of the newest AWR snapshot |

## Limits of the forecast

- **It assumes steady growth.** A straight line cannot foresee a one-off bulk load, a new application or a planned purge.
- **A growth stop shows after 14 quiet days, not sooner.** Until then the tablespace still has a forecast. If its growth began inside the window, that forecast uses the full recent rate.
- **A change of rate without a pause is averaged.** A tablespace that slows from 1 GB to 100 MB per day keeps a rate between the two until the fast days leave the window.
- **A one-off load and a rare regular load look the same.** A tablespace loaded once a quarter reads `STOP` and `FLAT` between two loads, like one that will never grow again. So does any tablespace with a single growth day in the 90 days, from 14 days after it. `PCT` still warns when it is nearly full. Set `quiet_days` to 0 if you have such tablespaces.
- **Short history, weak forecast.** With 14 to 30 days the growth rate is uncertain. `DTF_WORST` reflects that; `DTF` does not.
- **The limit is only as real as the storage.** `LIM = LIVE` corrects a single tablespace. `DTF_SHARED` is the column that accounts for several tablespaces competing for the same disk.
- **The shared-disk forecast rests on its assumptions.** All datafiles on one disk, nothing else on that disk growing, no storage added. UNDO and TEMP files can grow too and are not forecast. Run it in `CDB$ROOT`: inside a PDB the other containers' growth is not seen and `DISK_DTF` is too late.
- **`DISK_FREE_GB` is derived, not measured.** Oracle caps a whole tablespace at allocated size + free space on the device, however many datafiles it has (tested on 19.27 with one, two and three autoextend files and with mixed files). The value read 0.4% below `df` there. It is only available while at least one tablespace is capped; otherwise set `disk_free_gb`.
- **`CYCLIC` tablespaces get no days-to-full.** They are judged on their peak fill level only.
- **Used space is the value of the day's last AWR snapshot.** The newest day is a partial day.
- **No history is kept.** Each run recomputes everything from AWR. Results change as AWR ages data out.
