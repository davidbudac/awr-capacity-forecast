# Spec: instance memory sizing (SGA / PGA)

Status: ready for implementation. Milestone M26 in PLAN.md.
Decided in a design session on 2026-11-09. Facts marked "verified" were read
from a 19.27 CDB (ASMM, one instance, three containers).

## Problem Statement

The suite tells an operator when a tablespace fills, when CPU saturates and
when a limit such as PROCESSES is reached. It says nothing about memory. An
operator who wants to know whether `sga_target` or `pga_aggregate_target` is
set well has to open AWR reports by hand, read four advisor sections, compare
them with wait events and work area statistics, notice that ASMM keeps moving
memory between the buffer cache and the shared pool, and repeat that for every
database in the fleet. Nobody does this regularly, so instances stay too small
(multi-pass sorts, free buffer waits, shared pool pressure, a PGA that hits
its limit) or too large (memory that no workload ever uses) for years.

## Solution

A memory sizing analysis, computed in the database from AWR history like the
rest of the suite. For every database and instance it grades each memory area
as `UNDERSIZED`, `OK`, `OVERSIZED` or `INSUFFICIENT_EVIDENCE`, shows the
evidence behind the grade and suggests a size. It also grades how stable the
split inside the SGA is (`OK` or `THRASHING`), shows which PDB consumes the
instance's memory, and forecasts PGA allocation against
`pga_aggregate_limit` with the suite's existing forecast and alert machinery.

The analysis covers instance memory only. The one host figure it reads is the
physical memory size, used to flag a suggestion the host cannot hold.

The verdicts are advice in reports. The suite never changes a parameter.

## User Stories

Verdicts

1. As a DBA, I want one grade per memory area of an instance, so that I know at a glance whether its memory settings need attention.
2. As a DBA, I want separate grades for the SGA total, the buffer cache, the shared pool, the PGA target and the PGA limit, so that I know which parameter to change.
3. As a DBA, I want each grade to list the evidence that produced it, so that I can check the reasoning before I act.
4. As a DBA, I want each evidence line to show its measured value and the threshold it was compared with, so that I can judge how close the call was.
5. As a DBA, I want an `UNDERSIZED` grade only when Oracle's advisor and an observed symptom agree, so that I am not sent chasing an estimate.
6. As a DBA, I want an area with advisor gain but no symptom (or a symptom but no advisor gain) graded `OK` with a note, so that I see the weak signal without being told to act on it.
7. As a DBA, I want an `OVERSIZED` grade only when the advisor shows almost no cost at a smaller size, no pressure symptom occurred anywhere in the window and enough days were observed, so that I do not shrink memory on thin evidence.
8. As a DBA, I want `INSUFFICIENT_EVIDENCE` with a stated reason when the analysis cannot judge, so that I never mistake missing data for a healthy instance.
9. As a DBA, I want a suggested size with every `UNDERSIZED` and `OVERSIZED` grade, so that I have a concrete starting point.
10. As a DBA, I want the suggested size taken from the point where the advisor curve flattens, so that I buy the benefit without overshooting.
11. As a DBA, I want a suggestion never to exceed a configured step from the current size, so that changes stay incremental and I re-evaluate after each.
12. As a DBA, I want suggested sizes rounded to the instance's granule, so that the value I set is the value Oracle uses.
13. As a DBA, I want a suggestion flagged when the suggested SGA plus PGA exceeds a configured share of the host's physical memory, so that I do not configure the instance into swapping.
14. As a DBA, I want that flag to leave the suggestion unchanged, so that I still see what the workload asks for.
15. As a DBA, I want a caveat that other instances on the host are not visible to the analysis, so that I do the host arithmetic myself.

PGA

16. As a DBA, I want the share of one-pass and multi-pass work area executions as evidence, so that I see sorts and hash joins spilling to disk.
17. As a DBA, I want PGA over-allocation events counted as evidence, so that I know the target was too small for the workload that ran.
18. As a DBA, I want to see how much of the PGA target is left for automatic work areas, so that I notice untunable memory crowding them out.
19. As a DBA, I want the PGA limit graded on peak allocation against `pga_aggregate_limit`, so that I see how close sessions came to ORA-04036.
20. As a DBA, I want the peak that occurred between snapshots (the high-water mark) shown as evidence, so that a spike the samples missed still counts.
21. As a capacity planner, I want daily peak PGA allocation forecast against `pga_aggregate_limit`, so that I get a days-to-limit figure as for any other series.
22. As an on-call operator, I want the existing limit and anomaly alerts to fire for the PGA series, so that a PGA running into its limit pages me through the channel I already watch.

SGA and pool reallocation

23. As a DBA, I want the buffer cache graded from the cache advisor plus free buffer waits, so that I know whether more cache would save physical reads.
24. As a DBA, I want the shared pool graded from its advisor plus reloads, dictionary cache misses, shared pool latch and mutex waits and free memory, so that I know whether parsing suffers.
25. As a DBA, I want the SGA total graded from the SGA advisor, so that I know whether the pools together need more memory or only a different split.
26. As a DBA, I want to see how often ASMM resized each pool, in which direction and by how much, so that I see the tug-of-war between the cache and the shared pool.
27. As a DBA, I want forced (immediate) grows told apart from deferred ones, so that I recognise a pool that had to grow to avoid an allocation failure.
28. As a DBA, I want an "SGA balance" grade of `THRASHING` when pools oscillate, so that I learn the SGA is too small to hold both peaks or needs floors.
29. As a DBA, I want a suggested minimum size for the pool that keeps taking memory, so that I can pin it and stop the churn.
30. As a DBA, I want the size of every SGA component over time (including the In-Memory area and the large, java and streams pools), so that I see where the SGA goes.
31. As a DBA, I want no grade for the minor pools and the In-Memory area, so that the report does not claim a judgement it has no evidence for.

Memory management modes

32. As a DBA running ASMM, I want all areas graded, so that the analysis fits the common production setup.
33. As a DBA running manual SGA sizing, I want the buffer cache and shared pool graded from their own advisors, so that fixed pools are judged too.
34. As a DBA running AMM, I want sizes and resize activity shown and the grade set to `INSUFFICIENT_EVIDENCE` with "AMM not analysed", so that I am not given a verdict built for a different mode.

Time window and restarts

35. As a DBA, I want the verdict built from a configurable window of recent days, so that it reflects current workload.
36. As a DBA, I want evidence computed per instance uptime, so that counters that reset at a restart are never subtracted across it.
37. As a DBA, I want short uptimes ignored for advisor evidence, so that a cold cache does not distort the verdict.
38. As a DBA, I want uptimes combined by how much work each carried, so that a busy week outweighs an idle weekend.
39. As a DBA, I want to see which uptimes were used and which were skipped, so that I can trust the window.

Per PDB

40. As a CDB administrator, I want SGA, buffer cache, shared pool and PGA usage per PDB and its share of the instance, so that I know which tenant consumes the memory.
41. As a CDB administrator, I want a PDB graded `UNDERSIZED` when its usage sits at its own `sga_target` or PGA limit, so that I see a tenant constrained by its cap.
42. As a CDB administrator, I want a PDB graded `OVERSIZED` when it uses far less than its guaranteed `sga_min_size`, so that I can release memory reserved for nobody.
43. As a CDB administrator, I want a PDB without limits to show usage only, so that no verdict is invented where nothing is configured.

History

44. As a DBA, I want each refresh to record the grades and suggested sizes, so that a report can say since when an area has been undersized.
45. As a DBA, I want to see what changed since the previous run, so that I notice a verdict that flipped.
46. As a DBA, I want that history to survive a re-install, so that an upgrade does not erase it.
47. As a DBA, I want the history pruned after a configurable retention, so that it does not grow without bound.

Reports

48. As a DBA, I want a memory section in the text report, so that the nightly spool covers memory.
49. As a DBA, I want memory cards in the HTML report with the verdict, the evidence and the component sizes over time, so that I can read it without SQL.
50. As a manager, I want non-OK memory verdicts in the one-page briefing, so that memory appears beside runway.
51. As an analyst, I want the memory views in the CSV export, so that I can work with them in a spreadsheet.
52. As a DBA, I want a drill-down script for one instance that prints every uptime, every evidence line, the advisor curves, the resize operations and the per-PDB rows, so that I can investigate a verdict fully.
53. As a DBA, I want SNAPSHOT reports to serve memory from the stored tables, so that the memory sections cost nothing at report time.
54. As a fleet operator, I want memory verdicts listed per target and never ranked across targets, so that one database's numbers do not depend on another's.
55. As a fleet operator, I want a report scoped to one target to read only that target's memory data, so that it costs one target at any fleet size.

Deployment

56. As an operator of a standalone install, I want memory analysis after a normal upgrade install, so that I need no extra step beyond re-running the owner grants.
57. As a fleet operator, I want the repository to copy the memory history from each target, so that verdicts work in repository mode exactly as in local mode.
58. As a fleet operator, I want a target prepared before this release to keep collecting everything else, so that an upgrade of the repository does not break the fleet.
59. As a fleet operator, I want doctor to tell me which targets need their preparation script re-run, so that I know why a target's memory verdicts read `INSUFFICIENT_EVIDENCE`.
60. As an operator, I want doctor to probe the new AWR views, their grants and whether the advisors are populated, so that I learn before install what will be missing.
61. As an operator, I want every threshold in the configuration table with a range check, so that I can tune the analysis without editing views.
62. As an operator, I want the copied memory history covered by the existing repository retention, so that it is purged with everything else.

Trust

63. As a maintainer, I want every grade and suggested size asserted against closed-form fixture data, so that a rule change that alters a verdict fails the harness.
64. As a maintainer, I want repository and local mode proven identical for the new views, so that the copy contract stays exact.
65. As a reader of the docs, I want the demo reports to include a memory chapter, so that I can see the feature before installing.

## Implementation Decisions

Deliverable and grain

- The core is a verdict layer, a new kind of analysis beside forecast and anomaly. Proposed prefix `CAPM_` for its views (segments, evidence, combined advisor curves, verdicts, per-PDB usage), with `CAPR_MEM_*` views for the reports. Names are proposals. The layer order becomes seam, daily, forecast, anomaly, memory, integration.
- A verdict row is keyed by database, instance, container and area. Instance-level areas are filed under the root's `con_dbid`, as PROCESSES and SESSIONS are. AWR records instance memory under the root only (verified).
- Instance areas: `SGA_TOTAL`, `BUFFER_CACHE`, `SHARED_POOL`, `PGA_TARGET`, `PGA_LIMIT`, `SGA_BALANCE`. Per-PDB areas: SGA and PGA against the PDB's own limits.
- Grades: `UNDERSIZED`, `OK`, `OVERSIZED`, `INSUFFICIENT_EVIDENCE`. `SGA_BALANCE` uses `OK` and `THRASHING`. Every row carries a reason, the current size, the suggested size (NULL unless a change is advised) and the host memory flag.
- Evidence is one row per signal: area, measured value, unit, threshold, direction (pressure, slack or neutral) and a display text. A verdict is derived only from evidence rows, so a report can always show why.

Sources (the seam)

- New seam views over, in local mode: `DBA_HIST_MEM_DYNAMIC_COMP`, `DBA_HIST_MEMORY_RESIZE_OPS`, `DBA_HIST_PGASTAT`, `DBA_HIST_SQL_WORKAREA_HSTGRM`, `DBA_HIST_PGA_TARGET_ADVICE`, `DBA_HIST_SGA_TARGET_ADVICE`, `DBA_HIST_DB_CACHE_ADVICE`, `DBA_HIST_SHARED_POOL_ADVICE`, `DBA_HIST_SGASTAT`, `DBA_HIST_LIBRARYCACHE`, `DBA_HIST_ROWCACHE_SUMMARY`, `DBA_HIST_BUFFER_POOL_STAT`, `DBA_HIST_SYSTEM_EVENT` and `DBA_HIST_RSRC_PDB_METRIC`. All exist and fill every snapshot on 19.27 (verified).
- The parameter seam view gains the memory parameters it lacks (PDB and pool minimums, In-Memory size). The system statistics seam view gains the statistics the evidence needs (work area executions by pass count, parse counts, reads). The host statistics view already carries the physical memory size, and the snapshot spine already carries the startup time.
- Row filters keep the copies small: only the wait events, statistics and pool rows the evidence names.
- `DBA_HIST_MEMORY_RESIZE_OPS` is sparse (verified: 20 rows in 2 of 1242 snapshots). Resize counts come from the per-snapshot operation counter and last-operation columns of the component history. The operations view supplies detail for the drill-down only.
- Every new seam read carries the session scope predicate. The seam contract view covers the new views. All three seams (local, repository, fixture) gain them.
- Nothing downstream of the seam names an AWR view.

Evidence window and restarts

- The window is the last N days (knob, default 30).
- Within it, each instance uptime (startup segment) is evaluated on its own. Cumulative counters and advisor estimates are differenced inside a segment only.
- A segment shorter than a minimum uptime (knob, default 24 hours) contributes no advisor evidence. Observed symptoms still count.
- Segments are combined weighted by the work they carried, with a weight that fits the area (bytes processed for PGA, reads for the cache, parses for the shared pool, DB time for the SGA total).
- No qualifying segment gives `INSUFFICIENT_EVIDENCE`.

Verdict rules

- `UNDERSIZED` needs both: the advisor shows a material gain at a larger size (knob), and one observed pressure symptom. One without the other is `OK` with a note naming the lone signal.
- Symptoms by area. PGA target: one-pass and multi-pass share, over-allocation count rising, PGA cache hit percentage, a small automatic work area share. Buffer cache: free buffer waits, the cache shrunk by ASMM while reads rose. Shared pool: reloads, dictionary cache miss ratio, shared pool latch and library cache mutex waits, low free memory, immediate-mode grows. SGA total: pressure in both pools at once, or `THRASHING`.
- `OVERSIZED` needs all three: the advisor shows a cost below a knob at a smaller size, no pressure symptom in any segment of the window, and a minimum number of qualifying days (knob). It is the conservative call by design.
- `PGA_LIMIT` has no advisor. Its rule is usage against the ceiling: `UNDERSIZED` when a window peak (sampled, or the high-water mark) reaches a knob share of the current `pga_aggregate_limit`, otherwise `OK`. The verdict is about the current setting, so every peak is compared with the limit in force now. The high-water mark counts since instance startup, so a mark is attributed to the window only by its advances: a snapshot whose mark is above the previous snapshot's of the same startup. A startup that began before the window gives no advance for its first snapshot. Without a limit (`pga_aggregate_limit` 0) the area grades `OK` with reason `NO_LIMIT`. It is never graded `OVERSIZED`, because the limit is a safety ceiling.
- `SGA_BALANCE` is `THRASHING` when resize operations per day or grow-then-shrink reversals of the same pool exceed their knobs. Its suggestion is a floor for the pool that kept receiving memory, taken from the sizes it reached in the window.
- Modes. ASMM: every area. Manual SGA sizing: buffer cache and shared pool from their own advisors, `SGA_TOTAL` and `SGA_BALANCE` not applicable with a reason. AMM: sizes and resize activity shown, every grade `INSUFFICIENT_EVIDENCE` with "AMM not analysed".
- `INSUFFICIENT_EVIDENCE` reasons are a closed list: no qualifying uptime, advisor not populated, AMM, memory history not collected, window too short.
- Minor pools and the In-Memory area appear in the component breakdown with sizes and no grade.

Suggested size

- Growing: the smallest advised size past which the next step improves the estimated cost by less than a knob percentage (the knee).
- Shrinking: the smallest advised size whose estimated cost stays within a knob percentage of the current one.
- Either way the step is capped by a knob factor of the current size (default: half to double), and the result is rounded to the granule.
- Host guard: when suggested SGA plus suggested PGA target (the current value where there is no suggestion) exceeds a knob percentage of the host's physical memory, the row is flagged. The suggestion is not reduced. No other host figure is read.

Per PDB

- Usage per container comes from the per-PDB resource metric history (SGA, buffer cache, shared pool, PGA bytes), which fills without a resource plan (verified). The view shows usage and the share of the instance.
- A PDB is graded only against a limit it has: usage pinned at its `sga_target` or PGA limit is `UNDERSIZED`, usage far below `sga_min_size` is `OVERSIZED`. No limit means usage only.
- Oracle keeps no per-PDB advisors, so the advisor-plus-symptom rule does not apply to PDBs.
- Open fact for the first milestone: the test database records `pga_aggregate_*` under the root only. If a PDB-level PGA setting is not recorded in AWR, the PDB PGA verdict is dropped and the PDB shows PGA usage only.

The PGA series

- One new series joins the generic daily series: the daily maximum of sampled total PGA allocated, with `pga_aggregate_limit` as its limit, following the conventions of PROCESSES and SESSIONS (CDB-wide, under the root).
- It receives the existing forecast, days-to-limit, near-limit and anomaly treatment and the existing alert kinds. No change to the alert views beyond what any new series needs. It reaches the point feeds, and so the dashboards, with no dashboard work.
- A limit of zero (no limit) gives a series without a ceiling, and the `PGA_LIMIT` verdict reads `OK` / `NO_LIMIT`.
- The high-water mark statistic is verdict evidence, not a series, because it only resets at a restart.

Alerts

- Verdicts raise no alerts and add no alert kinds. They are report content.

History

- A new persisted table holds one row per refresh run, instance or PDB, and area: grade, current size, suggested size, host flag and the headline evidence figures.
- Only the results package writes it, during refresh, from the stored snapshot of the verdict view. It prunes rows older than a retention knob (default 400 days).
- It follows the persisted-table rules: created idempotently, kept by a re-install, dropped only by uninstall, listed in the reference and the project notes.
- A report view exposes "since when" and "changed since the previous run".

Reports

- Text report: a memory section (verdict table, evidence, component breakdown, per-PDB usage).
- HTML report: a memory section with one card per instance: verdicts, evidence and component sizes over time. Built through the existing stylesheet and script sources and their generator.
- Briefing: one line per non-OK verdict.
- CSV: one file per memory report view.
- A drill-down script for one instance: uptimes used and skipped, every evidence line, the advisor curves, resize operations and per-PDB rows.
- Every view a report driver reads joins the snapshot registry and is read through the snapshot substitution. Windows partition by database. New scripts carry session labels.
- Dashboards (Grafana, ELK, APEX) get no verdict panels in this spec. The APEX view contract is untouched.

Repository mode

- The copy manifest gains the new source views as fact copies, with the row filters above. The repository seam is regenerated from it, never edited.
- The target preparation script and the owner creation script grant the new views.
- Graceful degradation: when a target's reader cannot see a memory view, collect skips that view, logs it, and carries on. Everything else is collected as before. Memory verdicts for that target read `INSUFFICIENT_EVIDENCE` with "memory history not collected".
- No backfill: memory history for such a target starts when the grants arrive, because the collector's window starts at the high-water mark.
- The existing purge covers the new fact copies.

Configuration and doctor

- Every threshold is a knob in the configuration table with a seed row, a column in the one-row configuration view, a range rule in the check view and a row in the reference. No constants in views.
- Doctor probes the new views and grants, warns when the advisors hold no rows, adds memory sizing to the readiness table, and names repository targets whose memory history is not collected.
- The suite version is bumped.

Delivery

- Four milestones, each ending green on the fixture harness and the parity lever:
  1. Seam views, repository copies, grants, doctor probes, fixture tables.
  2. Evidence per uptime, combined advisor curves, the PGA series.
  3. Verdicts, suggested sizes, per-PDB, history.
  4. Report sections, drill-down, docs, demo chapter.

## Testing Decisions

- A good test here feeds designed rows in at the seam and asserts what a view returns. It does not look at how a view is built. Expected values are closed forms computed in the test from the fixture's own parameters.
- The one seam for analytics is the existing `CAPV_*` seam in fixture mode. Fixture tables gain designed memory scenarios, and the fixture assertion script asserts evidence values, every grade, every suggested size, the host flag, the per-PDB rows, the PGA series through forecast and alerts, and the history table after a refresh. No new test seam.
- Scenarios, each firing its verdict exactly once: an undersized PGA target, an oversized buffer cache, a thrashing SGA with a floor suggestion, a restart inside the window (with a short uptime that must be skipped), a PDB pinned at its `sga_target`, an AMM instance, a manually sized instance, an advisor-only signal that must stay `OK`, and an instance without memory history.
- Where one instance cannot carry two grades of the same area, further fixture databases carry them. Existing assertions are scoped so that their counts do not move.
- Prior art: the tablespace and CPU fixture series with closed-form expectations, the injected anomaly days, and the fixture's partial day for restart handling.
- Repository copies are tested with the existing parity lever: the new seam views and everything downstream must be identical in local and repository mode. It gains one case, a target lacking the new grants, which must degrade as specified.
- The existing guards extend to the new objects and must pass unchanged in kind: the scope plan check, the per-database window lint, the snapshot read lint, the snapshot parity diff, the docs lint and the manifest check.
- HTML rendering is tested with the existing stub-DOM test, no database needed.
- Cost is measured, not asserted: the scale lever records refresh time and peak PGA with the memory views in the snapshot registry.

## Out of Scope

- Operating system memory analysis (free memory, swapping, HugePages). Only the host's physical memory size is read, for the flag.
- Grading AMM instances.
- Grades for the In-Memory area and the large, java and streams pools.
- Advisor-based verdicts per PDB.
- Alerts and alert kinds for verdicts.
- Verdict panels in Grafana, Kibana and APEX.
- Forecasting SGA components or shared pool usage.
- Applying a suggestion. The suite never changes a parameter.
- Backfilling memory history for a target whose grants arrived late.
- RAC validation. The key carries the instance number and no logic crosses instances, but this stays untested, as the rest of the suite is.

## Further Notes

- Under ASMM the sizes an advisor reports move when the component is resized, so curves from different segments (or from before and after a resize) must be aligned on absolute size before they are combined.
- The advisors exist only while statistics collection is at its default level and the cache advisor is on. An instance without them gets `INSUFFICIENT_EVIDENCE`, never a symptom-only `UNDERSIZED`.
- In a CDB root the system statistics seam view reads per-container rows. Instance-level evidence must use the instance total. Confirm in the first milestone which source gives it without double counting.
- Whether the component history records the granule size is to be confirmed in the first milestone. If not, the granule becomes a knob.
- The test database's high-water mark for PGA (6.9 GB) exceeds its current limit (5 GB) because the limit was raised during the window. The `PGA_LIMIT` rule compares window peaks with the current limit, and only the high-water mark's advances inside the window count, so a mark reached before the window, under the older limit, does not grade the current one.
- The seam roughly doubles (13 to about 27 views). Expect a slower refresh. The measurement in the second milestone decides whether the evidence layer needs staging.
- The `PGA_LIMIT` rule (usage against the ceiling, never `OVERSIZED`) was not put to the user as a question. It follows from the limit having no advisor.

## Reports as built (M26.4)

Decided on 2026-11-10 while building the report milestone. Where this section differs from the "Reports" decisions above, this section wins.

- The report views are `CAPR_MEM_AREA`, `CAPR_MEM_VERDICT`, `CAPR_MEM_EVIDENCE`, `CAPR_MEM_COMPONENTS` and `CAPR_MEM_COMP_POINTS`. Every sentence a report prints (the verdict headline, the reason, the evidence line) is composed in a view, so the text report, the HTML report and the briefing cannot word a verdict differently.
- The briefing lists the verdicts that advise a change or name a problem: `UNDERSIZED`, `OVERSIZED`, `THRASHING`, `DRIFTING`. `INSUFFICIENT_EVIDENCE` is not listed line by line. One line counts those areas and gives their reasons, so missing data still shows.
- Component sizes over time are daily, over the evidence window: the size at the day's last snapshot, the day's smallest and largest size and its resize operations.
- The reports cover what is built. Per-PDB usage, the resize operations detail and the "since when" history are not in any report until their sources exist.
- A report scoped to a PDB shows no memory rows, as for PROCESSES and SESSIONS: the rows are the root's.

## Detailed rules for the SGA areas and the PGA target

Decided on 2026-11-09 from a probe of real AWR (19.27, ASMM, one long startup with resizes). Where this section differs from the decisions above, this section wins.

Facts the rules rest on (verified)

- The shared pool, SGA and PGA advisors are cumulative since instance startup and do not reset when a pool is resized. The buffer cache advisor resets its estimates at every resize of the cache.
- Advised sizes are absolute. The buffer cache advisor lists granule multiples. The shared pool advisor lists about thirty sizes around the current one, and the list moves when the pool is resized. The SGA advisor lists fixed fractions of `sga_target`. The PGA advisor lists fixed fractions of `pga_aggregate_target`.
- The component history carries the granule size, a cumulative operation counter per component and the type and mode of the last operation, on every snapshot. Resize activity is read from it. The resize operations view is not needed for a verdict.
- Wait time and waits for free buffers are in the system event history, so the buffer pool statistics view is not needed.
- Three advisors estimate time: `estd_db_time` (SGA), `estd_physical_read_time` (buffer cache), `estd_lc_load_time` (shared pool), all in seconds. The PGA advisor has no usable time column. It gives extra bytes read and written and an over-allocation count.

Sources built in this step

- Component history, work area histogram, the four advisors, SGA statistics (free memory rows only), library cache, dictionary cache summary and system events (a fixed list of memory-related events).
- The PGA statistics view passes the further names the PGA target evidence reads.
- Deferred: the resize operations view (drill-down), buffer pool statistics (not needed) and the per-PDB resource metrics (the per-PDB step).

Increments, not totals

- Every cumulative counter and every advisor estimate is turned into increments between consecutive snapshots of the same instance startup. An increment is dropped when the value went down (a reset).
- A row missing on a snapshot pairs with the counter's previous present row of the same startup. AWR writes no row for a PGA statistic or a wait event that is still zero, and writes it on every snapshot from its first use on (verified: no gap after a first row in 26 startups). The first row of such a counter in a startup therefore counts in full, against the previous snapshot of the startup that carries the source. Pairing only with a previous present row would lose that step: on the probe database it was 110 of 145 seconds of free buffer waits. The first snapshot of a startup, and the first row of an advised size, have nothing to pair with.
- Evidence sums the increments of the snapshots inside the evidence window. Nothing is subtracted across a restart, and nothing needs a segment table.
- A startup shorter than the minimum uptime knob contributes no advisor increments. Its symptoms still count.

Advisor curves

- The current size of an area is the advisor's own factor 1 size at the instance's latest snapshot. The verdict reports it as the current size in every case.
- The reference size is the size every gain and loss is measured against. It is the current size when the current size's own increments cover the minimum uptime knob.
- A resize moves the shared pool advisor's list, so a pool that has just been resized has a new factor 1 size with a few hours of increments, next to sizes that were on every list for weeks. On the test database the current size, 1072 MiB, had 6.5 hours and a size 16 MiB below it had 152. The reference size is then the advised size nearest to the current size, the larger one on a tie, among every size the advisor listed in the window whose own increments cover the minimum uptime knob. It must lie within the reference tolerance knob, `mem_ref_tolerance_pct` (default 10 percent of the current size). The rule is one rule: the current size is its own nearest size whenever it has the hours.
- No such size grades `INSUFFICIENT_EVIDENCE` with reason `ADVISOR_THIN`. That covers an advisor that is switched off, an instance that keeps restarting and a pool that has just reached a size with no covered size near it.
- Every size is compared with the reference size over the same snapshot intervals: the intervals of the window in which the reference size has an increment. The relative cost of a size X is the sum of X's increments divided by the sum of the reference size's increments over those intervals. Summing increments weights each interval by the work it carried. Coverage is the hours of those intervals.
- The advisor's list is ragged. On the test database the shared pool advisor gave 30 different lists in 502 intervals: the low sizes come and go, some lists stop short at the top, and a resize moves the whole list. In an interval that has no increment for X, the largest listed size below X stands in for it. A larger pool costs no more than a smaller one, so the stand-in understates a gain and overstates a loss. An interval with no listed size at or below X does not count for X.
- A candidate must count in every interval of the reference. A size below the smallest listed size of any such interval is therefore no candidate.
- The first version compared each size over only the intervals that listed it. Every size then had its own set of intervals, the curve was not monotonic, and one busy interval moved the suggestion from 1776 MiB to 1296 MiB between two snapshots 15 minutes apart. Over the same intervals the curve rises with size by construction.
- Candidate sizes, when the reference is the current size, are the sizes on the latest snapshot's list, inside the step cap, that count in every interval of the reference.
- Under a fallback reference a candidate is any size the advisor listed in the window, inside the step cap around the current size, that counts in every interval of the reference. The reference itself is not a candidate, because its gain against itself is zero.
- A grow candidate is larger than the current size and a shrink candidate is smaller than it, under a fallback reference too.
- Every advisor evidence sentence of an area under a fallback reference names the reference size and the current size, in whole MiB.
- The buffer cache advisor is read for the DEFAULT pool of the standard block size, pool id 3. A row an advisor wrote while switched off does not count.

Materiality is measured in DB time

- For the SGA total, the buffer cache and the shared pool, a gain or a loss is the change in the advisor's estimated seconds divided by the instance's DB time over the same snapshot intervals, as a percentage. A buffer cache that would do half the physical reads but save 0.8 % of DB time is not undersized. Instance DB time is the sum over the containers.
- Advisor pressure: the best candidate above the current size gains at least the gain knob (percent of DB time).
- Advisor slack: a candidate below the current size loses no more than the shrink knob.
- The PGA target is measured in estimated cache hit percentage points instead. Advisor pressure: the best candidate gains at least the PGA gain knob, or the advisor's over-allocation count at the current size rose in the window. Advisor slack: a smaller candidate loses no more than the PGA shrink knob and shows no over-allocation.

Symptoms

- A symptom is observed, not estimated. Wait-event symptoms are measured as time waited divided by DB time.
- PGA target: multi-pass share of work area executions, one-pass share, observed over-allocations, time on temporary segment direct path I/O. The smallest share of the target left for automatic work areas is shown as context.
- Buffer cache: time waited for free buffers, and the cache having been grown by the instance.
- Shared pool: time on shared pool latch, library cache mutex and load lock waits and on forced component growth, library cache reload ratio, dictionary cache miss ratio, and forced (immediate) grows of the pool. A consistently high share of free memory is slack evidence.
- SGA total: both pools show a symptom, or a pool was grown by force.
- A symptom has an evidence row only when its source was collected in the window. An event with no row is then zero. Without the source there is no row, so an uncollected instance is never shown "0 % free buffer waits".
- A count (over-allocations, grows) is pressure at 1 or more.

Decision table for an advisor-based area, first match wins

1. No memory history in the window (no row of the area's advisor, switched on or off): `INSUFFICIENT_EVIDENCE`, `NOT_COLLECTED`.
2. AMM: `INSUFFICIENT_EVIDENCE`, `AMM`.
3. SGA total or SGA balance under manual sizing: `INSUFFICIENT_EVIDENCE`, `MANUAL_SIZING`.
4. Thin advisor coverage: `INSUFFICIENT_EVIDENCE`, `ADVISOR_THIN`.
5. Advisor pressure and at least one symptom: `UNDERSIZED`, `ADVISOR_AND_SYMPTOM`.
6. Advisor pressure alone: `OK`, `ADVISOR_ONLY`.
7. Symptom alone: `OK`, `SYMPTOM_ONLY`.
8. Advisor slack, no pressure of any kind, enough sampled days: `OVERSIZED`, `SHRINK_COSTS_LITTLE`.
9. Advisor slack, no pressure, too few days: `OK`, `SHRINK_UNPROVEN`.
10. Otherwise: `OK`, `SIZED_RIGHT`.

Suggested size

- Growing: the smallest candidate that captures the knee knob's share (default 90 %) of the best gain inside the step cap. For the PGA target, at least the smallest candidate without over-allocation, when one exists inside the cap. When the current size over-allocates and no candidate inside the cap ends it, the largest candidate: over-allocation falls with size, so the instance takes the full step and is judged again. The probe database is that case (over-allocation at every advised size, a cache hit gain of 0.03 points), and the knee of a gain of zero names no size.
- Shrinking: the smallest candidate inside the step cap that satisfies the slack rule.
- A suggestion is always a size the advisor evaluated, so no granule rounding is needed.
- Each verdict names the parameter the suggestion is for. Under ASMM a buffer cache or shared pool suggestion is a floor (`db_cache_size`, `shared_pool_size`).
- The host memory flag is set on the SGA total, PGA target and PGA limit rows: the suggested size plus the current size of the other side against the host memory knob.
- The SGA flag is set on a buffer cache or shared pool suggestion under ASMM: `exceeds_sga` is `Y` when the suggested size is above what the two pools hold together now. The two pools share what the rest of the SGA leaves, so such a floor does not fit in `sga_target` even with the other pool at nothing. The suggestion is not reduced, as for host memory: it says how large the pool wants to be, and the SGA total verdict says what to raise first. `N` does not promise that the other pool can spare the memory. On the test database the advisor asked for a shared pool floor above the whole `sga_target`.

SGA balance

- Per component and snapshot interval: operations (the increment of the operation counter) and the net size change.
- A reversal is a pool whose net move changes sign inside the window, or an interval with operations and no net change.
- `THRASHING` when operations per day or reversals reach their knobs. The suggestion is a floor for the pool with the most growing intervals (the shared pool on a tie), equal to the largest size it reached in the window.
- Reversals and operations per day miss a pool that the instance squeezes one way. On the test database forced shared pool grows took the buffer cache from 256 MiB to 48 MiB under a 1536 MiB `sga_target`, with one operation a day and no reversal.
- The pool shift signal, `SGA_POOL_SHIFT_PCT`, measures that. For the buffer cache and the shared pool it takes the pool's largest size in the window minus its size at the latest snapshot. The signal is the larger of the two losses as a percentage of `sga_target`. It is a symptom of area `SGA_BALANCE` and reads pressure at or above the shift knob, `mem_shift_pct` (default 10). Its sentence names the pool that shrank with its peak and current size, and the other pool with its smallest and current size.
- `DRIFTING` with reason `ONE_WAY_SHIFT` when the shift signal reads pressure and neither churn signal does. Rule order for the area: not collected, AMM, manual sizing, `THRASHING`, `DRIFTING`, then `OK` with reason `STABLE`. An oscillating instance that also ends below a peak stays `THRASHING`.
- `DRIFTING` carries no suggested size and names no parameter. The answer to a drift is the SGA total verdict, or a floor the DBA sets knowingly.
- The sign of a pool's net move is compared with its previous net move in the window, across a restart too. The targets (`SGA Target`, `PGA Target`) are not components and are left out.
