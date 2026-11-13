#!/usr/bin/env python3
"""Generate dashboards/awrcap-tablespaces.json (AWR capacity: tablespaces)."""
from dash_lib import (
    AMBER, DB, DOTTED, DASHED, GREEN, GREY, NO_LEGEND, PAST_120D, RANGE,
    RED, SERIES, SOONEST, BLUE, TARGET, TARGET_COL, Board, named, alerts_table, annotation,
    cell_bg,
    fixed, override, prop, q, query_var, db_var, red_points, sev_cell, stat, table,
    target_var, timeseries, keep, where, width,
)

FILT = where(DB, SERIES)
GROWTH = where("anomaly_kind == 'TBSPC_GROWTH'", FILT)
REGR = where("method == 'REGR'", FILT)
LABEL = "${__field.labels.db} ${__field.labels.series} ${__field.name}"

b = Board("awrcap-tablespaces", "AWR Capacity - Tablespaces",
          "Tablespace usage from AWR: observed daily, forecast to a year out, "
          "days to full, and the growth days the anomaly layer flagged.",
          "now-120d", "now+120d")
b.variables += [
    target_var(),
    db_var(),
    query_var("series", "Tablespace", q(
        "V", "fit?kind=TBSPC", ["series", "db"], filt=DB,
        summarize="count(db)", by="series"), "series"),
]

fit = q("A", "fit?kind=TBSPC", [
    "target_name", "db", "series", "sev", "sev_rank", "pct", "value", "limit_value",
    "slope_per_day", "days_to_full", "days_to_full_lo", "days_to_full_hi",
    "r2", "quality", "restart_reason", "restart_day", "reliability"],
    filt=FILT, computed=[SOONEST])
DTF_STEPS = ((RED, None), (AMBER, 31), (GREEN, 91))

# Queries live on the y=0 stats (Grafana renders panels lazily; a panel that
# reuses another's data loads only after that panel is in view), the tables
# and the other stats reuse them.
fit_table = b.add(stat("Tablespaces CRIT", fit, transformations=[keep("sev", "CRIT")],
           field="sev_rank", calc="count", color_steps=((GREEN, None), (RED, 1)),
           description="Latest fit says full in 30 days or less (or already past the near-full line)."),
      0, 0, 6, 4)
anomaly_table = b.add(stat("Growth anomalies in range",
    q("A", f"anomalies?kind=TBSPC&{RANGE}", ["ts", "target_name", "db", "series", "anomaly_kind",
                                              "baseline_mode", "raw_value", "value",
                                              "expected", "z", "anomaly_flag", "sev",
                                              "sev_rank", "message"],
      filt=GROWTH),
           field="sev_rank", calc="count", color_steps=((GREEN, None), (RED, 1)),
           description="Days whose growth rate was far outside the tablespace's own median rate "
                       "(robust z-score), one per day and baseline mode (trailing, same weekday)."),
      12, 0, 6, 4)
b.add(table(
    "Days to full (latest fit per tablespace, soonest first)", fit_table, [
        TARGET_COL,
        ("db", "Database", [width(190)]), ("series", "Tablespace", [width(190)]),
        ("sev", "Sev", sev_cell()),
        ("pct", "Used %", cell_bg(((GREEN, None), (AMBER, 90), (RED, 97)),
                                  prop("unit", "percent"), prop("decimals", 1))),
        ("value", "Used", [prop("unit", "bytes"), prop("decimals", 1)]),
        ("limit_value", "Ceiling", [prop("unit", "bytes"), prop("decimals", 1)]),
        ("slope_per_day", "Growth / day", [prop("unit", "bytes"), prop("decimals", 1)]),
        ("days_to_full", "Days to full", cell_bg(DTF_STEPS, prop("decimals", 0))),
        ("days_to_full_lo", "DTF low", [prop("decimals", 0)]),
        ("days_to_full_hi", "DTF high", [prop("decimals", 0)]),
        ("r2", "R²", [prop("decimals", 2)]),
        ("quality", "Fit quality"),
        ("restart_reason", "Restart", [width(80)]),
        ("restart_day", "Since", [width(110), prop("unit", "time:YYYY-MM-DD")]),
        ("reliability", "Track", [width(90)]),
        ("sev_rank", "sev_rank"), ("soonest", "soonest")],
    sort="soonest", hidden=("sev_rank", "soonest"),
    description="Days to full is the linear fit projected at today's slope; low/high come "
                "from the forecast band. CRIT at 30 days or less, WARN at 90. Restart: why "
                "the fit window is shorter than the training window (PURGE, growth that "
                "stopped = STOP or began = START) and its first day. Track: the grade of "
                "the series' earlier forecasts (GOOD, BIASED, WIDE; UNKNOWN until enough "
                "are old enough to check)."),
    0, 4, 24, 9)

used = b.add(timeseries(
    "Used space: observed, forecast (dashed), anomalies (red)", [
        q("A", f"series?kind=TBSPC&{RANGE}",
          ["ts", "db", "series", ("value", "used"), ("limit_value", "ceiling")], filt=FILT),
        q("B", "forecast?kind=TBSPC",
          ["ts", "db", "series", "method", ("value", "forecast"), ("lo", "low"), ("hi", "high")],
          filt=REGR),
        q("C", f"series?kind=TBSPC&{RANGE}",
          ["ts", "db", "series", ("anomaly", "anomaly", "string"), ("value", "anomaly day")],
          filt=where("anomaly == '1'", FILT)),
    ],
    unit="bytes", display=LABEL, legend="right", partition=("db", "series"),
    overrides=[
        override("byRegexp", named("forecast"), DASHED),
        override("byRegexp", named("low|high"), DOTTED, NO_LEGEND, prop("custom.lineWidth", 1)),
        override("byRegexp", named("ceiling"), fixed(GREY), DASHED, NO_LEGEND,
                 prop("custom.lineWidth", 1)),
        *red_points("anomaly day"),
    ],
    description="Left of today: observed daily used bytes. Right of today: the REGR forecast "
                "(dashed) with its low/high band (dotted). Grey dashed: the ceiling (MAXBYTES "
                "or operator override). Red dots and red markers: growth anomalies; hover a "
                "marker for the explanation."),
    0, 13, 24, 12)

growth = b.add(timeseries(
    "Daily growth (sum of selected tablespaces; red = flagged day)", [
        q("A", f"series?kind=TBSPC&{RANGE}", ["ts", "db", "series", "anomaly", "delta_bytes"],
          filt=where("anomaly == 0", FILT), summarize="sum(delta_bytes)", by="ts",
          alias="Daily growth"),
        q("B", f"series?kind=TBSPC&{RANGE}", ["ts", "db", "series", "anomaly", "delta_bytes"],
          filt=where("anomaly == 1", FILT), summarize="sum(delta_bytes)", by="ts",
          alias="Anomalous growth"),
        q("C", f"series?kind=TBSPC&{RANGE}", ["ts", "db", "series", "expected"],
          filt=FILT, summarize="sum(expected)", by="ts", alias="Median daily growth"),
    ],
    unit="bytes", time_from=PAST_120D, custom={"axisSoftMin": None},
    overrides=[
        override("byFrameRefID", "A", fixed(BLUE), prop("custom.drawStyle", "bars"),
                 prop("custom.fillOpacity", 80), prop("custom.stacking", {"mode": "normal", "group": "g"})),
        override("byFrameRefID", "B", fixed(RED), prop("custom.drawStyle", "bars"),
                 prop("custom.fillOpacity", 100), prop("custom.stacking", {"mode": "normal", "group": "g"})),
        override("byFrameRefID", "C", fixed(GREY), prop("custom.lineWidth", 1)),
    ],
    description="Per-day growth summed over the selected tablespaces. A red bar is the growth "
                "of the tablespaces flagged that day; the grey line is the sum of their median "
                "daily growth, which the anomaly test measures against."),
    0, 25, 24, 8)

b.add(table(
    "Growth anomalies (newest first)", anomaly_table, [
        ("ts", "Day", [width(110), prop("unit", "time:YYYY-MM-DD")]),
        TARGET_COL,
        ("db", "Database", [width(190)]), ("series", "Tablespace", [width(170)]),
        ("baseline_mode", "Mode", [width(110)]),
        ("raw_value", "Growth", [width(100), prop("unit", "bytes"), prop("decimals", 1)]),
        ("value", "Rate / day", [width(100), prop("unit", "bytes"), prop("decimals", 1)]),
        ("expected", "Usual rate / day", [width(120), prop("unit", "bytes"),
                                          prop("decimals", 1)]),
        ("z", "z", cell_bg(((GREEN, None), (AMBER, 3), (RED, 5)),
                           prop("decimals", 1), width(70))),
        ("anomaly_flag", "Flag", [width(60)]), ("sev", "Sev", sev_cell()),
        ("message", "What happened"), ("anomaly_kind", "anomaly_kind"),
        ("sev_rank", "sev_rank")],
    sort="ts", desc=True, hidden=("anomaly_kind", "sev_rank"), time_from=PAST_120D),
    0, 33, 24, 9)

b.add(stat("Tablespaces WARN", fit_table, transformations=[keep("sev", "WARN")],
           field="sev_rank", calc="count", color_steps=((GREEN, None), (AMBER, 1))),
      6, 0, 6, 4)
b.add(stat("Worst days to full", fit_table, field="days_to_full", calc="min",
           color_steps=DTF_STEPS, unit="suffix: d"),
      18, 0, 6, 4)

# The shared disk (ddl/33): the disk of each database, then every growing
# tablespace against it.
GIB = [prop("unit", "suffix: GiB"), prop("decimals", 1)]
GIB2 = [prop("unit", "suffix: GiB"), prop("decimals", 2)]
MIB_DAY = [prop("unit", "suffix: MiB/d"), prop("decimals", 1)]
DAY = [width(110), prop("unit", "time:YYYY-MM-DD")]
b.add(table(
    "Shared disk: when is the disk under the datafiles full?",
    q("A", "disk", ["target_name", "db", "disk_name", "sev", "sev_rank", "disk_source",
                    "disk_free_gb", "alloc_gb", "disk_dtf", "disk_dtf_worst",
                    "disk_full_day", "n_growing", "grow_mb", "top_growers", "gated_by"],
      filt=TARGET), [
        TARGET_COL,
        ("db", "Database", [width(160)]), ("disk_name", "Disk", [width(110)]),
        ("sev", "Sev", sev_cell()),
        ("disk_source", "Free space from", [width(120)]),
        ("disk_free_gb", "Free", GIB), ("alloc_gb", "Allocated", GIB),
        ("disk_dtf", "Days to full", cell_bg(DTF_STEPS, prop("decimals", 0))),
        ("disk_dtf_worst", "Worst case", [prop("decimals", 0)]),
        ("disk_full_day", "Full on", DAY),
        ("n_growing", "Growing", [prop("decimals", 0)]),
        ("grow_mb", "They take", MIB_DAY),
        ("top_growers", "Fastest growing (MiB/day)"),
        ("gated_by", "Gate", [width(90)]), ("sev_rank", "sev_rank")],
    sort="sev_rank", hidden=("sev_rank",),
    description="All datafiles of a database are taken to sit on one disk. Free space: the "
                "operator's CAP_DISK_OVERRIDE row, else derived from the live tablespace "
                "ceilings (LIVE), else not known (NONE). Days to full: until the growing "
                "tablespaces have taken it. DISK_FULL alerts at 90 and 30 days."),
    0, 42, 24, 5)
b.add(table(
    "Tablespaces on the shared disk: days alone, days once the disk is full",
    q("A", "tbspc_shared", ["target_name", "db", "series", "quality", "cur_gb", "alloc_gb",
                            "limit_own_gb", "limit_live", "grow_mb", "dtf_own",
                            "dtf_shared", "dtf_shared_worst", "limit_shared_gb",
                            "stopped_by", "rank_shared"],
      filt=where(FILT, "grow_mb > 0")), [
        TARGET_COL,
        ("db", "Database", [width(190)]), ("series", "Tablespace", [width(190)]),
        ("quality", "Fit quality"),
        ("cur_gb", "Used", GIB), ("alloc_gb", "Allocated", GIB),
        ("limit_own_gb", "Own limit", GIB), ("limit_live", "Live ceiling", [width(100)]),
        ("grow_mb", "Growth", MIB_DAY),
        ("dtf_own", "Days, alone", [prop("decimals", 0)]),
        ("dtf_shared", "Days, shared disk", cell_bg(DTF_STEPS, prop("decimals", 0))),
        ("dtf_shared_worst", "Worst case", [prop("decimals", 0)]),
        ("limit_shared_gb", "Size when stuck", GIB),
        ("stopped_by", "Stopped by", [width(100)]), ("rank_shared", "rank_shared")],
    sort="rank_shared", hidden=("rank_shared",),
    description="Growing tablespaces only. Days, alone: to the tablespace's own limit (its "
                "ceiling, or the live ceiling when that is lower). Days, shared disk: until "
                "it is stuck, at its own limit or the first time it must extend after the "
                "disk is full. Stopped by says which."),
    0, 47, 24, 9)

# Tablespace families (ddl/32): one tablespace per period.
b.add(table(
    "Tablespace families: the next member's size, the filling member against its ceiling",
    q("A", "families", ["target_name", "db", "family_name", "sev", "period", "n_done",
                        "n_filling", "n_empty", "next_member_gb", "next_member_hi_gb",
                        "filling_member", "period_end_day", "days_left",
                        "expected_final_gb", "expected_final_hi_gb", "filling_limit_gb",
                        "fits", "headline"], filt=DB), [
        TARGET_COL,
        ("db", "Database", [width(160)]), ("family_name", "Family", [width(150)]),
        ("sev", "Sev", sev_cell()), ("period", "Period", [width(80)]),
        ("n_done", "Done", [width(60)]), ("n_filling", "Filling", [width(60)]),
        ("n_empty", "Empty", [width(60)]),
        ("next_member_gb", "Next member", GIB2), ("next_member_hi_gb", "Cautious", GIB2),
        ("filling_member", "Filling member", [width(160)]),
        ("period_end_day", "Period ends", DAY),
        ("days_left", "Days left", [prop("decimals", 0), width(80)]),
        ("expected_final_gb", "Expected final", GIB2),
        ("expected_final_hi_gb", "Cautious final", GIB2),
        ("filling_limit_gb", "Ceiling", GIB2), ("fits", "Fits", [width(60)]),
        ("headline", "In words")],
    sort="family_name",
    description="Tablespaces of one container whose names differ only in a period (month, "
                "quarter, year) are a family. Next member: the size the next one needs, "
                "from the finished members. Fits = N: the member that fills now may pass "
                "its ceiling before its period ends (the TBSPC_FAMILY alert)."),
    0, 56, 24, 6)
b.add(table(
    "Family members in period order",
    q("A", "family_members", ["target_name", "db", "family_name", "series", "member_seq",
                              "state", "used_gb", "limit_gb", "pct_used", "final_gb",
                              "fill_from", "fill_to", "fill_days", "quality",
                              "restart_reason"], filt=DB), [
        TARGET_COL,
        ("db", "Database", [width(160)]), ("family_name", "Family", [width(150)]),
        ("member_seq", "Seq", [width(60)]),
        ("series", "Tablespace", [width(190)]), ("state", "State", [width(90)]),
        ("used_gb", "Used", GIB2), ("limit_gb", "Ceiling", GIB2),
        ("pct_used", "Used %", cell_bg(((GREEN, None), (AMBER, 90), (RED, 97)),
                                       prop("unit", "percent"), prop("decimals", 1))),
        ("final_gb", "Final size", GIB2),
        ("fill_from", "Filled from", DAY), ("fill_to", "to", DAY),
        ("fill_days", "Fill days", [prop("decimals", 0)]),
        ("quality", "Fit quality"), ("restart_reason", "Restart", [width(80)])],
    description="In the handler's order: database, family, period. DONE: filled, or growth "
                "stopped. FILLING: the newest member that grows. EMPTY: created ahead. Final "
                "size: the largest used size of a DONE member."),
    0, 62, 24, 9)

b.add(alerts_table("Tablespace and disk alerts",
                   where("(kind == 'TBSPC' || kind == 'DISK')", DB)), 0, 71, 24, 8)

b.annotations.append(annotation(
    "Growth anomalies",
    q("Anno", f"anomalies?{RANGE}", ["ts", "db", "series", "anomaly_kind", "message"],
      filt=GROWTH),
    RED, [used, growth]))

b.write()
