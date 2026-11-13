#!/usr/bin/env python3
"""Generate dashboards/awrcap-memory.json (AWR capacity: memory sizing)."""
from dash_lib import (
    AMBER, BLUE, DB, GREEN, GREY, RANGE, RED, TARGET_COL, Board, db_var, keep, prop,
    q, stat, table, target_var, timeseries, width,
)

GRADE_MAPPING = [{"type": "value", "options": {
    "UNDERSIZED": {"color": RED, "index": 0},
    "THRASHING": {"color": RED, "index": 1},
    "OVERSIZED": {"color": AMBER, "index": 2},
    "DRIFTING": {"color": AMBER, "index": 3},
    "OK": {"color": GREEN, "index": 4},
    "INSUFFICIENT_EVIDENCE": {"color": GREY, "index": 5},
}}]
DIRECTION_MAPPING = [{"type": "value", "options": {
    "PRESSURE": {"color": RED, "index": 0},
    "SLACK": {"color": BLUE, "index": 1},
    "NEUTRAL": {"color": GREY, "index": 2},
}}]
COLOR_TEXT = prop("custom.cellOptions", {"type": "color-text"})
WATCH = ((GREEN, None), (AMBER, 1))
ALARM = ((GREEN, None), (RED, 1))

b = Board("awrcap-memory", "AWR Capacity - Memory sizing",
          "Memory sizing verdicts per instance: SGA total, buffer cache, shared "
          "pool, SGA balance, PGA target and PGA limit, with the evidence behind "
          "each and the SGA component sizes over the evidence window.",
          "now-35d", "now")
b.variables += [target_var(), db_var()]

# The verdict query lives on the first y=0 stat (Grafana renders panels
# lazily); the other stats and the verdict table reuse it.
verdicts = b.add(stat(
    "Areas needing action",
    q("A", "mem_verdicts", [
        "target_name", "db", "instance_number", "area", "area_label", "area_rank",
        "mem_mode", "grade", "reason", "reason_text", "actionable", "current_size",
        "suggested_size", "change_pct", "suggested_param", "n_days", "headline"],
      filt=DB),
    transformations=[keep("actionable", "Y")],
    field="area_rank", calc="count", color_steps=WATCH,
    description="Verdicts that advise a change or name a problem: UNDERSIZED, OVERSIZED, "
                "THRASHING or DRIFTING. Verdicts are report content and never raise an alert."),
    0, 0, 6, 4)
b.add(stat("Undersized or thrashing", verdicts,
           transformations=[keep("grade", "UNDERSIZED", "THRASHING")],
           field="area_rank", calc="count", color_steps=ALARM), 6, 0, 6, 4)
b.add(stat("Oversized or drifting", verdicts,
           transformations=[keep("grade", "OVERSIZED", "DRIFTING")],
           field="area_rank", calc="count", color_steps=WATCH), 12, 0, 6, 4)
b.add(stat("Could not be judged", verdicts,
           transformations=[keep("grade", "INSUFFICIENT_EVIDENCE")],
           field="area_rank", calc="count", color_steps=WATCH), 18, 0, 6, 4)

b.add(table(
    "Verdicts (one per instance and area)", verdicts, [
        TARGET_COL,
        ("db", "Database", [width(160)]),
        ("instance_number", "Inst", [width(60)]),
        ("area_label", "Area", [width(120)]),
        ("grade", "Grade", [prop("mappings", GRADE_MAPPING), COLOR_TEXT, width(180)]),
        ("current_size", "Current", [width(90)]),
        ("suggested_size", "Suggested", [width(100)]),
        ("change_pct", "Change %", [prop("decimals", 1), width(90)]),
        ("headline", "What to do", [width(520)]),
        ("reason_text", "Why"),
        ("area", "area"), ("area_rank", "area_rank"), ("mem_mode", "mem_mode"),
        ("reason", "reason"), ("actionable", "actionable"),
        ("suggested_param", "suggested_param"), ("n_days", "n_days")],
    hidden=("area", "area_rank", "mem_mode", "reason", "actionable",
            "suggested_param", "n_days"),
    description="Instance level: the rows belong to the root container of a database, so a "
                "PDB picked in the Database variable shows none. The suggested size is the "
                "value to set for the parameter the last column names."),
    0, 4, 24, 9)

b.add(timeseries(
    "SGA components per day",
    q("A", f"mem_points?{RANGE}", ["ts", "db", "component", ("bytes", "size")], filt=DB),
    unit="bytes", display="${__field.labels.db} ${__field.labels.component}",
    legend="right", partition=("db", "component"),
    custom={"fillOpacity": 60, "lineWidth": 1,
            "stacking": {"mode": "normal", "group": "sga"}},
    description="The size of each SGA component at the day's last snapshot, over the "
                "evidence window. A step is a resize: under ASMM the instance moved "
                "memory between the buffer cache and the shared pool."),
    0, 13, 24, 10)

b.add(table(
    "Evidence (the signals behind each verdict)",
    q("A", "mem_evidence", [
        "target_name", "db", "instance_number", "area_label", "evidence_kind", "signal",
        "direction", "value", "unit", "threshold", "observed_at", "evidence_text"],
      filt=DB), [
        TARGET_COL,
        ("db", "Database", [width(160)]),
        ("instance_number", "Inst", [width(60)]),
        ("area_label", "Area", [width(120)]),
        ("evidence_kind", "Kind", [width(90)]),
        ("signal", "Signal", [width(230)]),
        ("direction", "Direction", [prop("mappings", DIRECTION_MAPPING), COLOR_TEXT,
                                    width(100)]),
        ("value", "Value", [prop("decimals", 2), width(90)]),
        ("unit", "Unit", [width(80)]),
        ("threshold", "Threshold", [prop("decimals", 2), width(90)]),
        ("evidence_text", "Evidence"),
        ("observed_at", "observed_at")],
    hidden=("observed_at",),
    description="USAGE: what was measured. ADVISOR: what the advisor estimates at another "
                "size. SYMPTOM: pressure the instance showed. CONTEXT: facts that explain a "
                "verdict. PRESSURE argues for more memory, SLACK for less."),
    0, 23, 24, 12)

b.add(table(
    "SGA components now (largest first)",
    q("A", "mem_components", [
        "target_name", "db", "instance_number", "component", "current_bytes",
        "min_bytes", "max_bytes", "pct_of_total", "n_ops", "n_grows", "n_shrinks",
        "n_forced_grows", "last_resize_at"],
      filt=DB), [
        TARGET_COL,
        ("db", "Database", [width(160)]),
        ("instance_number", "Inst", [width(60)]),
        ("component", "Component", [width(220)]),
        ("current_bytes", "Size", [prop("unit", "bytes"), prop("decimals", 1)]),
        ("pct_of_total", "% of SGA", [prop("unit", "percent"), prop("decimals", 1)]),
        ("min_bytes", "Window min", [prop("unit", "bytes"), prop("decimals", 1)]),
        ("max_bytes", "Window max", [prop("unit", "bytes"), prop("decimals", 1)]),
        ("n_ops", "Resize ops", [prop("decimals", 0)]),
        ("n_grows", "Grows", [prop("decimals", 0)]),
        ("n_shrinks", "Shrinks", [prop("decimals", 0)]),
        ("n_forced_grows", "Forced grows", [prop("decimals", 0)]),
        ("last_resize_at", "Last resize", [prop("unit", "time:YYYY-MM-DD HH:mm")])]),
    0, 35, 24, 8)

b.write()
