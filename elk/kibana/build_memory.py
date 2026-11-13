#!/usr/bin/env python3
"""Generate dashboards/40-memory.ndjson (AWR Capacity - Memory sizing)."""
from lens_lib import (
    AMBER, DASH_MEM, KQL_LATEST, RED, TARGET, DashboardBuilder,
    add_nav_panel, alarm_when_nonzero, col_avg, col_date_histogram,
    col_last_value, col_min, col_target, col_terms, col_unique_count,
    fmt_bytes, fmt_number, metric_state, table_state, xy_data_layer,
    xy_multi_state,
)

VERDICT = f"cap.record:mem_verdict and {KQL_LATEST}"
EVIDENCE = f"cap.record:mem_evidence and {KQL_LATEST}"
COMPONENT = "cap.record:mem_component"

b = DashboardBuilder(
    "awrcap-memory", DASH_MEM, "AWR Capacity - Memory sizing",
    "Memory sizing verdicts per instance: SGA total, buffer cache, shared "
    "pool, SGA balance, PGA target and PGA limit, with the evidence behind "
    "each and the SGA component sizes over the evidence window.",
    time_from="now-35d", time_to="now")
add_nav_panel(b)
b.add_controls([TARGET, "cap.db", "cap.mem.area_label", "cap.mem.grade"])

b.add_markdown("header", 0, 0, 24, 8, (
    "**Memory sizing: is each area the right size?** One verdict per "
    "instance and area, from the advisors and the pressure symptoms of the "
    "evidence window. **UNDERSIZED** and **OVERSIZED** carry a suggested "
    "size; **THRASHING** and **DRIFTING** describe the split between the "
    "buffer cache and the shared pool.\n\n"
    "Verdicts are instance level: pick a target or a root container, not a "
    "PDB. They never raise an alert. The tables read the latest export."))


def kpi(name, title, x, col, pal):
    m = b.uid(f"col:{name}")
    b.add_lens(name, title, x, 0, 6, 8, "lnsMetric",
               metric_state(m, pal=pal), {m: col}, [m])


kpi("kpi-action", "Areas needing action", 24, col_unique_count(
    "cap.series", "Areas needing action",
    kql=f"{VERDICT} and cap.mem.actionable:true", fmt=fmt_number(0)),
    alarm_when_nonzero(AMBER))
kpi("kpi-under", "Undersized or thrashing", 30, col_unique_count(
    "cap.series", "Undersized or thrashing",
    kql=f"{VERDICT} and cap.mem.grade:(UNDERSIZED or THRASHING)",
    fmt=fmt_number(0)), alarm_when_nonzero(RED))
kpi("kpi-over", "Oversized or drifting", 36, col_unique_count(
    "cap.series", "Oversized or drifting",
    kql=f"{VERDICT} and cap.mem.grade:(OVERSIZED or DRIFTING)",
    fmt=fmt_number(0)), alarm_when_nonzero(AMBER))
kpi("kpi-unjudged", "Could not be judged", 42, col_unique_count(
    "cap.series", "Could not be judged",
    kql=f"{VERDICT} and cap.mem.grade:INSUFFICIENT_EVIDENCE",
    fmt=fmt_number(0)), alarm_when_nonzero(AMBER))


def c(panel, name):
    return b.uid(f"col:{panel}-{name}")


# Verdicts: one row per (target, database, instance, area), in report order.
p = "verdict"
tgt, db, inst, area, rank = (c(p, n) for n in ("target", "db", "inst", "area", "rank"))
grade, reason, cur, sug, chg, head = (
    c(p, n) for n in ("grade", "reason", "current", "suggested", "change", "headline"))
cols = {
    rank: col_min("cap.mem.area_rank", "Rank", fmt=fmt_number(0)),
    tgt: col_target(),
    db: col_terms("cap.db", "Database", None, size=200),
    inst: col_terms("cap.mem.instance_number", "Inst", None, size=16,
                    data_type="number"),
    area: col_terms("cap.mem.area_label", "Area", rank, size=10, direction="asc"),
    grade: col_last_value("cap.mem.grade", "Grade", data_type="string"),
    reason: col_last_value("cap.mem.reason", "Reason", data_type="string"),
    cur: col_last_value("cap.mem.current_size", "Current", data_type="string"),
    sug: col_last_value("cap.mem.suggested_size", "Suggested", data_type="string"),
    chg: col_last_value("cap.mem.change_pct", "Change",
                        fmt=fmt_number(1, suffix=" %")),
    head: col_last_value("cap.mem.headline.keyword", "What to do",
                         data_type="string"),
}
order = [tgt, db, inst, area, rank, grade, reason, cur, sug, chg, head]
b.add_lens("verdict-table", "Verdicts (latest export)", 0, 8, 48, 12,
           "lnsDatatable",
           table_state(order, rank, direction="asc", page_size=12, overrides={
               rank: {"hidden": True}, tgt: {"width": 130}, db: {"width": 160},
               inst: {"width": 60}, area: {"width": 120}, grade: {"width": 170},
               reason: {"width": 190}, cur: {"width": 90}, sug: {"width": 90},
               chg: {"width": 80}}),
           cols, order, query=VERDICT)

# SGA components per day, stacked.
p = "comp"
x, comp, size = c(p, "x"), c(p, "component"), c(p, "bytes")
cols = {
    # No empty rows: the days before the evidence window would draw a ramp
    # from zero to the first day.
    x: col_date_histogram(empty_rows=False),
    size: col_avg("cap.mem.bytes", "Size", fmt=fmt_bytes(1)),
    comp: col_terms("cap.series", "Component", size, size=12),
}
state = xy_multi_state([xy_data_layer("area_stacked", x, [size], split=comp)])
state["legend"]["position"] = "right"
b.add_lens("comp-xy", "SGA components per day (average over the selected instances)",
           0, 20, 48, 12, "lnsXY", state, cols, [comp, x, size], query=COMPONENT)

# Evidence: the signals behind each verdict.
p = "evidence"
tgt, db, area, rank = (c(p, n) for n in ("target", "db", "area", "rank"))
sig, kind, direction = c(p, "signal"), c(p, "kind"), c(p, "direction")
val, unit, thr, text = (c(p, n) for n in ("value", "unit", "threshold", "text"))
cols = {
    rank: col_min("cap.mem.area_rank", "Rank", fmt=fmt_number(0)),
    tgt: col_target(),
    db: col_terms("cap.db", "Database", None, size=200),
    area: col_terms("cap.mem.area_label", "Area", rank, size=10, direction="asc"),
    sig: col_terms("cap.mem.signal", "Signal", None, size=100),
    kind: col_last_value("cap.mem.evidence_kind", "Kind", data_type="string"),
    direction: col_last_value("cap.mem.direction", "Direction", data_type="string"),
    val: col_last_value("cap.value", "Value", fmt=fmt_number(2)),
    unit: col_last_value("cap.unit", "Unit", data_type="string"),
    thr: col_last_value("cap.threshold", "Threshold", fmt=fmt_number(2)),
    text: col_last_value("cap.mem.evidence_text.keyword", "Evidence",
                         data_type="string"),
}
order = [tgt, db, area, sig, rank, kind, direction, val, unit, thr, text]
b.add_lens("evidence-table", "Evidence (latest export)", 0, 32, 48, 16,
           "lnsDatatable",
           table_state(order, rank, direction="asc", page_size=15, overrides={
               rank: {"hidden": True}, tgt: {"width": 130}, db: {"width": 160},
               area: {"width": 120}, sig: {"width": 220}, kind: {"width": 90},
               direction: {"width": 100}, val: {"width": 90}, unit: {"width": 80},
               thr: {"width": 90}}),
           cols, order, query=EVIDENCE)

b.write("40-memory.ndjson")
