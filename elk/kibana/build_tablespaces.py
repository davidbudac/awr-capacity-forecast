#!/usr/bin/env python3
"""Generate dashboards/10-tablespaces.ndjson (AWR Capacity - Tablespaces)."""
from lens_lib import (
    AMBER, DASH_TBSPC, GREEN, GREY, KQL_LATEST, PAST, RED, TARGET, DashboardBuilder,
    add_alerts_table, alarm_when_nonzero, add_nav_panel, cell_colors, col_avg, col_count,
    col_date_histogram, col_last_value, col_max, col_min, col_palette_steps,
    col_sum, col_target, col_terms, col_unique_count, fmt_bytes, fmt_number,
    metric_state, palette, table_state, xy_data_layer, xy_multi_state, xy_ref_layer,
)

OBS = "cap.record:observation and cap.kind:TBSPC"
FIT = "cap.record:fit and cap.kind:TBSPC"
FC = "cap.record:forecast and cap.kind:TBSPC and cap.method:REGR"
ANOM_OBS = f"{OBS} and cap.anomaly:true"
GROWTH = "cap.record:anomaly and cap.anomaly_kind:TBSPC_GROWTH"

b = DashboardBuilder(
    "awrcap-tablespaces", DASH_TBSPC, "AWR Capacity - Tablespaces",
    "Tablespace usage from AWR: observed daily, forecast to a year out, "
    "days to full, and the growth days the anomaly layer flagged.")
add_nav_panel(b)
b.add_controls([TARGET, "cap.db", "cap.series"])

b.add_markdown("header", 0, 0, 24, 8, (
    "**Tablespaces: when do they fill up?** Lines left of today are observed "
    "daily usage; lines right of today are the linear forecast with its "
    "low/high band. The dashed grey line is the ceiling (MAXBYTES or the "
    "operator override).\n\n"
    "**Red bars are anomalies**: days whose growth was far outside the "
    "tablespace's own normal rate (robust z-score on the median daily "
    "growth). The table at the bottom explains each one.\n\n"
    "**Days to full** is the linear fit's projection at today's slope, with "
    "a low/high range from the forecast band. CRIT at 30 days or less, WARN "
    "at 90. Tiles and the alerts table read only the latest export. Pick a "
    "database and tablespace above to read a single chart.\n\n"
    "**Restart** says why a fit window is shorter than the training window: "
    "PURGE, growth that stopped (STOP) or began (START). **Track** grades "
    "the series' earlier forecasts (GOOD, BIASED, WIDE). Further down: the "
    "**shared disk** (all tablespaces of a database against the free space "
    "they share) and the **tablespace families** (one tablespace per "
    "period)."))


def kpi(name, title, x, col, pal):
    m = b.uid(f"col:{name}")
    b.add_lens(name, title, x, 0, 6, 8, "lnsMetric",
               metric_state(m, pal=pal), {m: col}, [m])


kpi("kpi-crit", "Tablespaces CRIT", 24, col_unique_count(
    "cap.series", "Tablespaces CRIT",
    kql=f"{FIT} and cap.sev:CRIT and {KQL_LATEST}", fmt=fmt_number(0)), alarm_when_nonzero())
kpi("kpi-warn", "Tablespaces WARN", 30, col_unique_count(
    "cap.series", "Tablespaces WARN",
    kql=f"{FIT} and cap.sev:WARN and {KQL_LATEST}", fmt=fmt_number(0)), alarm_when_nonzero(AMBER))
kpi("kpi-anom", "Growth anomalies in range", 36, col_count(
    "Growth anomalies", kql=GROWTH, fmt=fmt_number(0)), alarm_when_nonzero())
kpi("kpi-dtf", "Worst days to full", 42, col_min(
    "cap.days_to_full", "Worst days to full",
    kql=f"{FIT} and {KQL_LATEST}", fmt=fmt_number(0, suffix=" d")),
    palette([(RED, 0), (AMBER, 31), (GREEN, 91)]))


def c(panel, name):
    return b.uid(f"col:{panel}-{name}")


# Days-to-full table: latest fit per (db, tablespace).
p = "dtf"
tgt, db, ser = c(p, "target"), c(p, "db"), c(p, "series")
pct, used, lim, slope = c(p, "pct"), c(p, "used"), c(p, "limit"), c(p, "slope")
dtf, lo, hi = c(p, "dtf"), c(p, "dtf-lo"), c(p, "dtf-hi")
r2, qual, sev = c(p, "r2"), c(p, "quality"), c(p, "sev")
rst, rst_day, track = c(p, "restart"), c(p, "restart-day"), c(p, "track")
cols = {
    tgt: col_target(),
    db: col_terms("cap.db", "Database", None, size=200),
    ser: col_terms("cap.series", "Tablespace", None, size=500),
    sev: col_last_value("cap.sev", "Sev", data_type="string"),
    pct: col_last_value("cap.pct", "Used %", fmt=fmt_number(1, suffix=" %")),
    used: col_last_value("cap.value", "Used", fmt=fmt_bytes(1)),
    lim: col_last_value("cap.limit", "Ceiling", fmt=fmt_bytes(1)),
    slope: col_last_value("cap.slope_per_day", "Growth / day", fmt=fmt_bytes(1)),
    dtf: col_last_value("cap.days_to_full", "Days to full", fmt=fmt_number(0)),
    lo: col_last_value("cap.days_to_full_lo", "DTF low", fmt=fmt_number(0)),
    hi: col_last_value("cap.days_to_full_hi", "DTF high", fmt=fmt_number(0)),
    r2: col_last_value("cap.r2", "R²", fmt=fmt_number(2)),
    qual: col_last_value("cap.quality", "Fit quality", data_type="string"),
    rst: col_last_value("cap.restart_reason", "Restart", data_type="string"),
    rst_day: col_last_value("cap.restart_day", "Since", data_type="date"),
    track: col_last_value("cap.track.reliability", "Track", data_type="string"),
}
order = [tgt, db, ser, sev, pct, used, lim, slope, dtf, lo, hi, r2, qual,
         rst, rst_day, track]
b.add_lens("dtf-table", "Days to full (latest fit per tablespace, soonest first)",
           0, 8, 48, 12, "lnsDatatable",
           table_state(order, dtf, direction="asc", page_size=10, overrides={
               tgt: {"width": 130}, db: {"width": 190}, ser: {"width": 190},
               pct: cell_colors(col_palette_steps(90, 97)),
               dtf: cell_colors(col_palette_steps(30, 90, (RED, AMBER, GREEN))),
               rst: {"width": 80}, rst_day: {"width": 110}, track: {"width": 90},
           }),
           cols, order, query=FIT)

# Used bytes: observed + forecast + band + anomaly bars + ceiling.
p = "used"
x_obs, x_fc, x_an = c(p, "x-obs"), c(p, "x-fc"), c(p, "x-an")
s_obs, s_fc = c(p, "s-obs"), c(p, "s-fc")
v_obs, v_fc, v_lo, v_hi = c(p, "obs"), c(p, "fc"), c(p, "lo"), c(p, "hi")
v_an, v_lim = c(p, "anom"), c(p, "limit")
layers = {
    "obs": ({
        x_obs: col_date_histogram(),
        v_obs: col_avg("cap.value", "Observed", kql=OBS, fmt=fmt_bytes(1)),
        s_obs: col_terms("cap.series", "Tablespace", v_obs, size=10),
    }, [s_obs, x_obs, v_obs]),
    "fc": ({
        x_fc: col_date_histogram(),
        v_fc: col_avg("cap.value", "Forecast", kql=FC, fmt=fmt_bytes(1)),
        v_lo: col_avg("cap.lo", "Forecast low", kql=FC, fmt=fmt_bytes(1)),
        v_hi: col_avg("cap.hi", "Forecast high", kql=FC, fmt=fmt_bytes(1)),
        s_fc: col_terms("cap.series", "Tablespace", v_fc, size=10),
    }, [s_fc, x_fc, v_fc, v_lo, v_hi]),
    "anom": ({
        x_an: col_date_histogram(),
        v_an: col_max("cap.value", "Anomaly day", kql=ANOM_OBS,
                      fmt=fmt_bytes(1)),
    }, [x_an, v_an]),
    "limit": ({
        v_lim: col_max("cap.limit", "Ceiling", kql=OBS, fmt=fmt_bytes(1)),
    }, [v_lim]),
}
state = xy_multi_state([
    xy_data_layer("bar", x_an, [v_an], colors={v_an: RED}, key="anom"),
    xy_data_layer("line", x_obs, [v_obs], split=s_obs, key="obs"),
    xy_data_layer("line", x_fc, [v_fc, v_lo, v_hi], split=s_fc, key="fc"),
    xy_ref_layer(v_lim, GREY, key="limit"),
])
state["legend"]["position"] = "right"
b.add_lens("used-xy", "Used space: observed, forecast (REGR + band), anomalies in red",
           0, 20, 48, 16, "lnsXY", state, layers=layers,
           query="cap.kind:TBSPC")

# Daily growth: one stacked bar per day, the flagged part in red, against
# the median rate the anomaly test measures from.
p = "growth"
x, norm, anom = c(p, "x"), c(p, "normal"), c(p, "anom")
x_exp, exp = c(p, "x-exp"), c(p, "expected")
layers = {
    "bars": ({
        x: col_date_histogram(),
        norm: col_sum("cap.tbspc.delta_bytes", "Daily growth",
                      kql=f"{OBS} and not cap.anomaly:true", fmt=fmt_bytes(1)),
        anom: col_sum("cap.tbspc.delta_bytes", "Anomalous growth",
                      kql=ANOM_OBS, fmt=fmt_bytes(1)),
    }, [x, norm, anom]),
    "expected": ({
        x_exp: col_date_histogram(),
        exp: col_sum("cap.expected", "Median daily growth", kql=OBS,
                     fmt=fmt_bytes(1)),
    }, [x_exp, exp]),
}
b.add_lens("growth-xy", "Daily growth (sum of selected tablespaces; red = flagged day)",
           0, 36, 48, 11, "lnsXY", xy_multi_state([
               xy_data_layer("bar_stacked", x, [norm, anom],
                             colors={norm: "#6092c0", anom: RED}, key="bars"),
               xy_data_layer("line", x_exp, [exp], colors={exp: GREY},
                             key="expected"),
           ]), layers=layers, time_range=PAST)

# Growth anomalies, newest first.
p = "anoms"
day, db, ser = c(p, "day"), c(p, "db"), c(p, "series")
val, rate, exp, z, flag, msg = (c(p, n) for n in ("value", "rate", "exp", "z", "flag", "msg"))
mode = c(p, "mode")
cols = {
    day: col_date_histogram(label="Day", empty_rows=False),
    db: col_terms("cap.db", "Database", None, size=200),
    ser: col_terms("cap.series", "Tablespace", None, size=500),
    mode: col_terms("cap.baseline_mode", "Mode", None, size=5),
    val: col_max("cap.raw_value", "Growth", fmt=fmt_bytes(1)),
    rate: col_max("cap.value", "Rate / day", fmt=fmt_bytes(1)),
    exp: col_max("cap.expected", "Usual rate / day", fmt=fmt_bytes(1)),
    z: col_max("cap.z", "z", fmt=fmt_number(1)),
    flag: col_last_value("cap.anomaly_flag", "Flag", data_type="string"),
    msg: col_last_value("cap.message.keyword", "What happened",
                        data_type="string"),
}
order = [day, db, ser, mode, val, rate, exp, z, flag, msg]
b.add_lens("anom-table", "Growth anomalies (newest first)", 0, 47, 48, 12,
           "lnsDatatable", table_state(order, day, page_size=8, overrides={
               day: {"width": 110}, db: {"width": 190}, ser: {"width": 190},
               mode: {"width": 110}, val: {"width": 110}, rate: {"width": 110},
               exp: {"width": 110}, z: {**cell_colors(col_palette_steps(3, 5)),
                                       "width": 80},
               flag: {"width": 70},
           }),
           cols, order, query=GROWTH, time_range=PAST)

# The shared disk: one row per database and disk, then every tablespace
# against it. Both read the latest export.
GIB = fmt_number(1, suffix=" GiB")
MIB_DAY = fmt_number(1, suffix=" MiB/d")
DAYS = fmt_number(0)
DTF_COLORS = cell_colors(col_palette_steps(30, 90, (RED, AMBER, GREEN)))

p = "disk"
tgt, db, disk, sev, src = (c(p, n) for n in ("target", "db", "disk", "sev", "source"))
free, alloc, dtf, worst, full = (c(p, n) for n in ("free", "alloc", "dtf", "worst", "full"))
grow, n_grow, top = c(p, "grow"), c(p, "n-growing"), c(p, "top")
cols = {
    tgt: col_target(),
    db: col_terms("cap.db", "Database", None, size=200),
    disk: col_terms("cap.disk.disk_name", "Disk", None, size=20),
    sev: col_last_value("cap.sev", "Sev", data_type="string"),
    src: col_last_value("cap.disk.source", "Free space from", data_type="string"),
    free: col_last_value("cap.disk.free_gb", "Free", fmt=GIB),
    alloc: col_last_value("cap.disk.alloc_gb", "Allocated", fmt=GIB),
    dtf: col_last_value("cap.disk.dtf", "Days to full", fmt=DAYS),
    worst: col_last_value("cap.disk.dtf_worst", "Worst case", fmt=DAYS),
    full: col_last_value("cap.disk.full_day", "Full on", data_type="date"),
    n_grow: col_last_value("cap.disk.n_growing", "Growing", fmt=DAYS),
    grow: col_last_value("cap.disk.grow_mb", "They take", fmt=MIB_DAY),
    top: col_last_value("cap.disk.top_growers.keyword", "Fastest growing (MiB/day)",
                        data_type="string"),
}
order = [tgt, db, disk, sev, src, free, alloc, dtf, worst, full, n_grow, grow, top]
b.add_lens("disk-table", "Shared disk: when is the disk under the datafiles full? (latest export)",
           0, 59, 48, 6, "lnsDatatable",
           table_state(order, dtf, direction="asc", page_size=5, overrides={
               tgt: {"width": 130}, db: {"width": 160}, disk: {"width": 110},
               sev: {"width": 60}, src: {"width": 120}, free: {"width": 90},
               alloc: {"width": 100}, dtf: {**DTF_COLORS, "width": 100},
               worst: {"width": 90}, full: {"width": 110}, n_grow: {"width": 80},
               grow: {"width": 110}}),
           cols, order, query=f"cap.record:disk and {KQL_LATEST}")

p = "shared"
tgt, db, ser, qual = (c(p, n) for n in ("target", "db", "series", "quality"))
used, alloc, own, live = (c(p, n) for n in ("used", "alloc", "own", "live"))
grow, own_dtf, sh_dtf, worst = (c(p, n) for n in ("grow", "dtf-own", "dtf-shared", "worst"))
lim_sh, stop = c(p, "limit-shared"), c(p, "stopped-by")
cols = {
    tgt: col_target(),
    db: col_terms("cap.db", "Database", None, size=200),
    ser: col_terms("cap.series", "Tablespace", None, size=500),
    qual: col_last_value("cap.quality", "Fit quality", data_type="string"),
    used: col_last_value("cap.shared.used_gb", "Used", fmt=GIB),
    alloc: col_last_value("cap.shared.alloc_gb", "Allocated", fmt=GIB),
    own: col_last_value("cap.shared.limit_own_gb", "Own limit", fmt=GIB),
    live: col_last_value("cap.shared.limit_live", "Live ceiling", data_type="boolean"),
    grow: col_last_value("cap.shared.grow_mb", "Growth", fmt=MIB_DAY),
    own_dtf: col_last_value("cap.shared.dtf_own", "Days, alone", fmt=DAYS),
    sh_dtf: col_last_value("cap.shared.dtf_shared", "Days, shared disk", fmt=DAYS),
    worst: col_last_value("cap.shared.dtf_shared_worst", "Worst case", fmt=DAYS),
    lim_sh: col_last_value("cap.shared.limit_shared_gb", "Size when stuck", fmt=GIB),
    stop: col_last_value("cap.shared.stopped_by", "Stopped by", data_type="string"),
}
order = [tgt, db, ser, qual, used, alloc, own, live, grow, own_dtf, sh_dtf,
         worst, lim_sh, stop]
b.add_lens("shared-table",
           "Tablespaces on the shared disk: days alone and days once the disk is full (latest export)",
           0, 65, 48, 11, "lnsDatatable",
           table_state(order, sh_dtf, direction="asc", page_size=8, overrides={
               tgt: {"width": 130}, db: {"width": 190}, ser: {"width": 190},
               sh_dtf: DTF_COLORS}),
           cols, order,
           query=f"cap.record:tbspc_shared and cap.shared.grow_mb > 0 and {KQL_LATEST}")

# Tablespace families: one row per family, then its members.
p = "family"
tgt, db, fam, sev, period = (c(p, n) for n in ("target", "db", "family", "sev", "period"))
n_done, n_fill, n_empty = c(p, "done"), c(p, "filling-n"), c(p, "empty")
nxt, nxt_hi, member, end, left = (c(p, n) for n in ("next", "next-hi", "member", "end", "left"))
exp, exp_hi, ceil, fits, head = (c(p, n) for n in ("exp", "exp-hi", "ceiling", "fits", "headline"))
cols = {
    tgt: col_target(),
    db: col_terms("cap.db", "Database", None, size=200),
    fam: col_terms("cap.family.name", "Family", None, size=200),
    sev: col_last_value("cap.sev", "Sev", data_type="string"),
    period: col_last_value("cap.family.period", "Period", data_type="string"),
    n_done: col_last_value("cap.family.n_done", "Done", fmt=DAYS),
    n_fill: col_last_value("cap.family.n_filling", "Filling", fmt=DAYS),
    n_empty: col_last_value("cap.family.n_empty", "Empty", fmt=DAYS),
    nxt: col_last_value("cap.family.next_member_gb", "Next member",
                        fmt=fmt_number(2, suffix=" GiB")),
    nxt_hi: col_last_value("cap.family.next_member_hi_gb", "Cautious",
                           fmt=fmt_number(2, suffix=" GiB")),
    member: col_last_value("cap.family.filling_member", "Filling member",
                           data_type="string"),
    end: col_last_value("cap.family.period_end_day", "Period ends", data_type="date"),
    left: col_last_value("cap.family.days_left", "Days left", fmt=DAYS),
    exp: col_last_value("cap.family.expected_final_gb", "Expected final",
                        fmt=fmt_number(2, suffix=" GiB")),
    exp_hi: col_last_value("cap.family.expected_final_hi_gb", "Cautious final",
                           fmt=fmt_number(2, suffix=" GiB")),
    ceil: col_last_value("cap.family.filling_limit_gb", "Ceiling",
                         fmt=fmt_number(2, suffix=" GiB")),
    fits: col_last_value("cap.family.fits", "Fits", data_type="boolean"),
    head: col_last_value("cap.family.headline.keyword", "In words", data_type="string"),
}
order = [tgt, db, fam, sev, period, n_done, n_fill, n_empty, nxt, nxt_hi, member,
         end, left, exp, exp_hi, ceil, fits, head]
b.add_lens("family-table",
           "Tablespace families: the next member's size, the filling member against its ceiling (latest export)",
           0, 76, 48, 7, "lnsDatatable",
           table_state(order, fam, direction="asc", page_size=5, overrides={
               tgt: {"width": 130}, db: {"width": 160}, fam: {"width": 150},
               sev: {"width": 60}, period: {"width": 80}, n_done: {"width": 60},
               n_fill: {"width": 60}, n_empty: {"width": 60}, member: {"width": 160},
               end: {"width": 110}, left: {"width": 80}, fits: {"width": 60}}),
           cols, order, query=f"cap.record:family and {KQL_LATEST}")

p = "member"
tgt, db, fam, ser, seq = (c(p, n) for n in ("target", "db", "family", "series", "seq"))
state_c, used, lim, pct, final = (c(p, n) for n in ("state", "used", "limit", "pct", "final"))
f_from, f_to, f_days, qual, rst = (
    c(p, n) for n in ("fill-from", "fill-to", "fill-days", "quality", "restart"))
cols = {
    seq: col_min("cap.family.member_seq", "Seq", fmt=DAYS),
    tgt: col_target(),
    db: col_terms("cap.db", "Database", None, size=200),
    fam: col_terms("cap.family.name", "Family", None, size=200),
    ser: col_terms("cap.series", "Tablespace", seq, size=500, direction="asc"),
    state_c: col_last_value("cap.family.state", "State", data_type="string"),
    used: col_last_value("cap.family.used_gb", "Used", fmt=fmt_number(2, suffix=" GiB")),
    lim: col_last_value("cap.family.limit_gb", "Ceiling", fmt=fmt_number(2, suffix=" GiB")),
    pct: col_last_value("cap.pct", "Used %", fmt=fmt_number(1, suffix=" %")),
    final: col_last_value("cap.family.final_gb", "Final size",
                          fmt=fmt_number(2, suffix=" GiB")),
    f_from: col_last_value("cap.family.fill_from", "Filled from", data_type="date"),
    f_to: col_last_value("cap.family.fill_to", "to", data_type="date"),
    f_days: col_last_value("cap.family.fill_days", "Fill days", fmt=DAYS),
    qual: col_last_value("cap.quality", "Fit quality", data_type="string"),
    rst: col_last_value("cap.restart_reason", "Restart", data_type="string"),
}
order = [tgt, db, fam, ser, seq, state_c, used, lim, pct, final, f_from, f_to,
         f_days, qual, rst]
b.add_lens("member-table", "Family members in period order (latest export)",
           0, 83, 48, 11, "lnsDatatable",
           table_state(order, seq, direction="asc", page_size=8, overrides={
               seq: {"width": 60}, tgt: {"width": 130}, db: {"width": 160},
               fam: {"width": 150}, ser: {"width": 190},
               pct: cell_colors(col_palette_steps(90, 97))}),
           cols, order, query=f"cap.record:family_member and {KQL_LATEST}")

add_alerts_table(b, "alerts", "Tablespace and disk alerts (latest export)", 0, 94, 48,
                 12, "cap.kind:(TBSPC or DISK)")

b.write("10-tablespaces.ndjson")
