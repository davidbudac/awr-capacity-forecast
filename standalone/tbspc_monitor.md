# Tablespace monitoring query (tbspc_monitor.sql)

## What it is

One read-only SQL query that a monitoring tool can run to decide which tablespaces need an alarm. It replaces a plain "critical at 90% used" alarm.

The problem with the plain alarm: it treats a small tablespace and a very large one the same. A 20 TB tablespace that is 90% full still has 2 TB free. If it grows 10 GB a day, it is half a year from full. Calling someone at night for it is noise. A 50 GB tablespace at 90% is different. It has 5 GB left, and the alarm is right.

This query keeps the plain alarm where it works and holds a large tablespace back only while a trusted forecast says it is far from full or not growing. A forecast is trusted when its quality is `OK` or `FLAT`. `LOW_CONFIDENCE`, `INSUFFICIENT_HISTORY` and `CYCLIC` are not trusted. The decision must not rest on a low-quality forecast.

- It is the monitoring companion of `tbspc_capacity.sql`. It uses the same forecast. See `README.md` in this folder for how the forecast is made.
- It runs directly on the database it measures. Nothing is installed, created or written.
- It reads the AWR history (`DBA_HIST_*` views, Diagnostics Pack licence required) and one live view.
- It returns one row per container and permanent tablespace that has an alert. Settings can list every tablespace instead.

## How to run it

```
SQL> @standalone/tbspc_monitor.sql
```

- Run it in `CDB$ROOT` to see every container, or in a non-CDB. Inside a PDB it shows that PDB only.
- The query text alone (from `WITH` to the closing semicolon) also runs in SQL Developer or any monitoring tool that can run a query.
- The user needs SELECT on `DBA_HIST_SNAPSHOT`, `DBA_HIST_TBSPC_SPACE_USAGE`, `DBA_HIST_TABLESPACE`, `DBA_HIST_DATAFILE`, `DBA_HIST_PDB_INSTANCE`, `DBA_HIST_DATABASE_INSTANCE` and `CDB_TABLESPACE_USAGE_METRICS`. `SELECT_CATALOG_ROLE` covers all seven.
- A common user in `CDB$ROOT` also needs `CONTAINER_DATA = ALL`, otherwise it sees the root only.
- Stock AWR keeps 8 days of history, which is less than the 14 days the forecast needs. Every row then reads `INSUFFICIENT_HISTORY`, and the rule below is the same as a plain alarm at 90%. Raise the AWR retention to get the benefit of the forecast.

## The rule

The rule judges the **live percent**, `LIVE_PCT`. This is `USED_PERCENT` of `CDB_TABLESPACE_USAGE_METRICS`, the figure a plain alarm reads. The rule uses the unrounded value. When the live view has no row for the tablespace, it uses used / limit from AWR instead.

The size the rule checks is the live ceiling, the figure `LIVE_PCT` is measured against. When there is none, it uses `LIMIT_GB`. Normally the two are the same.

The first rule that matches wins.

| Order | Rule | `ALERT` | `ALERT_WHY` |
|---|---|---|---|
| 1 | Percent is 95 or more | `CRIT` | `pct >= 95` |
| 2 | Percent is 90 or more, and the size is under 1024 GB | `CRIT` | `pct >= 90, under 1024 GB` |
| 3 | Percent is 90 or more, and quality is not `OK` or `FLAT` (so `INSUFFICIENT_HISTORY`, `CYCLIC` or `LOW_CONFIDENCE`) | `CRIT` | `pct >= 90, no trusted forecast` |
| 4 | Percent is 90 or more, and `DTF_SHARED_WORST` is 30 days or less | `CRIT` | `pct >= 90, worst dtf <= 30` |
| 5 | Percent is 90 or more, and `DTF_SHARED_WORST` is more than 30 days | `WATCH` | `pct >= 90, worst dtf > 30` |
| 6 | Percent is 90 or more, and there is no worst case because the tablespace is not growing (`FLAT`, or `OK` and shrinking) | `WATCH` | `pct >= 90, not growing` |
| 7 | Otherwise | no row | |

Notes:

- Only a large tablespace can be held back. Under 1024 GB the answer stays `CRIT` at 90%, as with a plain alarm.
- Even a large tablespace is `CRIT` from 95%, whatever the forecast says.
- The rule fails closed. Only a forecast of quality `OK` or `FLAT` is trusted enough to hold an alarm back. Any other quality is `CRIT` from 90%, as with a plain alarm.
- A tablespace that does not grow at all is `FLAT`. Its fitted growth is exactly 0. That includes one whose growth stopped. This is not a low-quality forecast. It is a confident "no growth", so it is held back as `WATCH`.
- A `LOW_CONFIDENCE` fit is a line that explains the history poorly. It fires at 90% like a plain alarm.
- Rule 6 means there is no worst case because the tablespace does not grow. Either the quality is `FLAT`, or it is `OK` and the fitted growth is negative, so the tablespace shrinks on a line that fits well. After rule 3 an empty raw `DTF_SHARED_WORST` can mean nothing else.
- The rule uses the raw worst case. A tablespace whose worst case is more than 100 years away shows an empty `DTF_SHARED_WORST`, but it is rule 5, not rule 6. `ALERT_WHY` tells the two apart.
- The limits are settings (`alert_pct`, `alert_pct_max`, `alert_big_gb`, `alert_dtf`). The numbers in `ALERT_WHY` follow them.

## What each column means

GB and MB are binary units: 1 GB = 1024 x 1024 x 1024 bytes, 1 MB = 1024 x 1024 bytes.

| Column | Meaning | How it is calculated |
|---|---|---|
| `CONTAINER` | Container the tablespace belongs to | PDB name from AWR. In a non-CDB the database name. |
| `TABLESPACE` | Tablespace name | From `DBA_HIST_TABLESPACE`. |
| `ALERT` | The verdict: `CRIT`, `WATCH` or empty | See "The rule". |
| `ALERT_WHY` | The rule that set the alert | For example `pct >= 95` or `pct >= 90, worst dtf > 30`. Empty when there is no alert. |
| `LIVE_PCT` | Percent full now, as the live view reports it | `USED_PERCENT` of `CDB_TABLESPACE_USAGE_METRICS`, one decimal. Empty when the live view has no row for the tablespace. |
| `USED_GB` | Space used now | Used bytes on the newest sampled day / 1 GB. |
| `LIMIT_GB` | Size at which the tablespace is full | The autoextend maximum or the allocated size, or the live ceiling when that is lower. Same as in `README.md`. |
| `FREE_GB` | Space left | `LIMIT_GB - USED_GB`. |
| `MB_DAY` | Growth per day | Slope of the fitted line / 1 MB. Negative when the tablespace shrinks. |
| `DTF_SHARED` | Days until the tablespace is stuck, expected case | The earlier of its own limit and the first day it has to extend after the shared disk is full. Empty when not growing or more than 100 years away. |
| `DTF_SHARED_WORST` | The same, worst case | See "What the worst case is". Empty when not growing, more than 100 years away, or when the history is too short for an uncertainty. |
| `QUALITY` | How far the forecast can be trusted | `INSUFFICIENT_HISTORY` (fewer than 14 days), `CYCLIC` (filled and purged regularly), `FLAT`, `LOW_CONFIDENCE` or `OK`. See `README.md`. Only `OK` and `FLAT` can hold an alarm back. |
| `LAST_DAY` | Newest day with a sample for this tablespace | Normally today. |

Rows are sorted by `ALERT` (`CRIT`, then `WATCH`, then none), then by `DTF_SHARED_WORST` (soonest first), then by `LIVE_PCT` (fullest first).

A tablespace whose last sample is more than 3 days older than the newest AWR snapshot is hidden. It was dropped or is no longer sampled.

## What the worst case is

`DTF_SHARED_WORST` is the number of days until the tablespace is stuck, when things go badly:

- The tablespace is stuck when it reaches its own limit, or when the disk it shares with the others is full and it has to extend.
- Every tablespace grows at the top of its 95% range at the same time. That is its fitted growth per day plus the uncertainty of that growth.
- So the shared disk fills sooner, and every tablespace is stuck sooner.

All tablespaces at the top of their range together is less likely than any single one doing so. Read it as the cautious edge, not as a 95% statement. That is the point of using it here: a large tablespace is held back only when its quality is `OK` and even this cautious date is more than 30 days away, or when it does not grow at all.

The formulas are in `README.md`, steps 7 and 8 and "Worst-case formulas".

## Fail-closed cases and notes

- **No trusted forecast.** Rows at 90% or more whose quality is not `OK` or `FLAT` (`INSUFFICIENT_HISTORY`, `CYCLIC`, `LOW_CONFIDENCE`) are `CRIT`, as with a plain alarm. Only an `OK` or `FLAT` forecast is trusted enough to hold an alarm back.
- **No live row.** If `CDB_TABLESPACE_USAGE_METRICS` has no row for a tablespace, the AWR percent is used and `LIVE_PCT` is empty.
- **No access to the live view.** Give the `live` CTE the empty body shown in its comment. The query then works from AWR alone, and `LIVE_PCT` is empty on every row.
- **Free space on the shared disk.** It is derived from the live view, as in `README.md`. If it is not known, the shared-disk step has no effect and `DTF_SHARED_WORST` is the worst case of the tablespace alone. Set `disk_free_gb` in the settings to supply it.
- **Run it in `CDB$ROOT`.** Inside a PDB the growth of the other containers is not seen, so the shared disk is forecast to fill too late.
- **The newest day is a partial day.** Used space is the value of the day's last AWR snapshot, while `LIVE_PCT` is read now.

## What it does not cover

- Only permanent tablespaces are in the query. UNDO and TEMPORARY tablespaces need their own alarm.
- A tablespace younger than one AWR snapshot has no row.
- **Keep a plain percent alarm at 95% in the monitoring tool as a backstop.** It covers both cases, and it matches `alert_pct_max`, so it adds nothing to a tablespace this query already reports.

## How a monitoring tool uses it

- Run it every hour. The forecast only changes when a new AWR snapshot arrives, and `LIVE_PCT` is read at run time.
- Alarm on `ALERT = 'CRIT'`. Use `TABLESPACE` and `CONTAINER` as the key of the alarm and `ALERT_WHY` as its text.
- Show `ALERT = 'WATCH'` as a notice that needs no call-out. It means the tablespace is 90% full and its quality is `OK` or `FLAT`. Either even the cautious forecast says it is not full within 30 days, or it does not grow (it is `FLAT`, or it shrinks).
- Clear the alarm when the tablespace no longer appears in the result.
- With `alerts_only` at 1, the default, the query returns only the rows that have an alert. Set it to 0 to list every tablespace with its verdict. That is useful to check the rule against your own data.

## Settings

The defaults sit at the top of the query in the `prm` block and can be edited there.

| Setting | Default | Meaning |
|---|---|---|
| `alert_pct` | 90 | Live percent full at or above = an alert row |
| `alert_pct_max` | 95 | ... at or above this = `CRIT` always |
| `alert_big_gb` | 1024 | Only a tablespace of this many GB or more, with quality `OK` or `FLAT`, can be held back from `CRIT` by its forecast |
| `alert_dtf` | 30 | ... while `DTF_SHARED_WORST` is above this many days it is `WATCH`, else `CRIT` |
| `alerts_only` | 1 | 1 = return only the rows that have an alert. 0 = every tablespace. |

The forecast settings (fit window, history needed, purge and growth-stop detection, `disk_free_gb`, `dbid`) are the same as in `tbspc_capacity.sql`, with the same defaults. They are described in the settings table of `README.md`.

## Relationship to the analytical query

`tbspc_capacity.sql` and this query share one forecast. The two files hold the same text for it, so a number such as `DTF_SHARED_WORST` is the same in both. They answer different questions.

| | `tbspc_capacity.sql` | `tbspc_monitor.sql` |
|---|---|---|
| Question | How is each tablespace growing, and when is it full? | Which tablespaces need an alarm now? |
| Rows | Every tablespace | Only those with an alert, by default |
| Verdict | `STATUS`: `CRIT`, `WARN`, `OK` | `ALERT`: `CRIT`, `WATCH` |
| Judged on | Percent from AWR, and the expected days to full | The live percent, then the worst case for a large tablespace with an `OK` or `FLAT` forecast |
| Use | Planning and review | The alarm |

The `STATUS` of the analytical query grades every tablespace and warns early, on the expected days to full. This query is the alarm. A row can be `OK` in one and carry an alert in the other. That is expected.
