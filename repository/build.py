#!/usr/bin/env python3
"""Generate ddl/13_seam_repository.sql from the source manifest and ddl/10.

    python3 repository/build.py           # write the generated file
    python3 repository/build.py --check   # exit 1 if it is stale or a list drifted

The manifest below is the one place that says which DBA_HIST_* views a
repository copies from its targets, which columns, how a copy is keyed and
which rows are worth copying. From it this script writes, in one file:

  * CAP_H_<view>, one copy table per source view, created idempotently
    (persisted: ddl/00_drop never drops them, uninstall.sql does);
  * CAP_REPO_SOURCE, a view holding the finished pull statement per source,
    which repository/cap_repo.sql executes over each target's DB link;
  * the include of repository/cap_repo.sql (the registry the seam reads);
  * the CAPV_* seam: ddl/10_seam_local.sql with every dba_hist_<x> renamed
    cap_h_<x>, so local and repository mode share one seam body, except the
    views repository/seam_overrides.sql defines, which replace ddl/10's.

--check also proves that the views ddl/10 reads, the views target/prepare.sql
grants and the first create_owner.sql grants (as many as the manifest has
sources) are the manifest's,
and that ddl/13 defines exactly ddl/10's CAPV_* views.
"""
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCAL_SEAM = ROOT / "ddl" / "10_seam_local.sql"
OVERRIDES = ROOT / "repository" / "seam_overrides.sql"
OUT = ROOT / "ddl" / "13_seam_repository.sql"
PREPARE = ROOT / "target" / "prepare.sql"
CREATE_OWNER = ROOT / "create_owner.sql"

N = "NUMBER"
TS = "TIMESTAMP(3)"
DT = "DATE"


def v(n):
    return f"VARCHAR2({n} CHAR)"


@dataclass
class Source:
    """One DBA_HIST_* view a repository copies.

    kind F: a fact, appended per snapshot range (dbid, snap_id window).
    kind D: a dimension, MERGEd on key; key = every column means "keep each
            distinct row". scope names the fact whose chunk rows decide which
            dimension rows to pull (SEG_STAT_OBJ is too big to pull whole).
    filter: rows not worth copying. It must keep every row ddl/10 keeps.
    optional: a target's reader may lack the grant (it was prepared before
            the view joined the manifest): probe warns instead of failing,
            and collect skips the source and copies the rest.
    """
    name: str
    kind: str
    cols: list
    key: list = field(default_factory=list)
    filter: str = ""
    scope: str = ""
    optional: bool = False


TIME_NAMES = "stat_name IN ('DB CPU','DB time','background cpu time')"
KEYS = [("dbid", N), ("con_dbid", N), ("instance_number", N), ("snap_id", N)]
# The memory pressure events ddl/10's CAPV_SYSTEM_EVENT reads, one per line
# so the pull statement keeps its lines short.
MEM_EVENTS = ("event_name IN (\n             "
              + ",\n             ".join(f"'{e}'" for e in (
                  "free buffer waits", "write complete waits", "buffer busy waits",
                  "latch: cache buffers lru chain", "latch: shared pool",
                  "library cache: mutex X", "library cache load lock", "library cache lock",
                  "cursor: pin S wait on X", "SGA: allocation forcing component growth",
                  "latch: row cache objects", "row cache lock", "row cache mutex",
                  "direct path read temp", "direct path write temp"))
              + ")")

SOURCES = [
    Source("SNAPSHOT", "F", [("dbid", N), ("instance_number", N), ("snap_id", N),
                             ("startup_time", TS), ("begin_interval_time", TS),
                             ("end_interval_time", TS)]),
    Source("TBSPC_SPACE_USAGE", "F", [("dbid", N), ("con_dbid", N), ("snap_id", N),
                                      ("tablespace_id", N), ("tablespace_size", N),
                                      ("tablespace_maxsize", N), ("tablespace_usedsize", N)]),
    Source("OSSTAT", "F", [("dbid", N), ("con_dbid", N), ("instance_number", N),
                           ("snap_id", N), ("stat_name", v(64)), ("value", N)],
           filter="stat_name IN ('BUSY_TIME','IDLE_TIME','IOWAIT_TIME',"
                  "'NUM_CPUS','NUM_CPU_CORES','PHYSICAL_MEMORY_BYTES')"),
    Source("SYS_TIME_MODEL", "F", [("dbid", N), ("con_dbid", N), ("instance_number", N),
                                   ("snap_id", N), ("stat_name", v(64)), ("value", N)],
           filter=TIME_NAMES),
    Source("CON_SYS_TIME_MODEL", "F", [("dbid", N), ("con_dbid", N), ("con_id", N),
                                       ("instance_number", N), ("snap_id", N),
                                       ("stat_name", v(64)), ("value", N)],
           filter=TIME_NAMES),
    Source("RESOURCE_LIMIT", "F", [("dbid", N), ("con_dbid", N), ("instance_number", N),
                                   ("snap_id", N), ("resource_name", v(30)),
                                   ("current_utilization", N), ("max_utilization", N),
                                   ("limit_value", v(10))],
           filter="resource_name IN ('processes','sessions')"),
    Source("SYSSTAT", "F", [("dbid", N), ("con_dbid", N), ("instance_number", N),
                            ("snap_id", N), ("stat_name", v(64)), ("value", N)],
           filter="stat_name = 'redo size'"),
    Source("CON_SYSSTAT", "F", [("dbid", N), ("con_dbid", N), ("con_id", N),
                                ("instance_number", N), ("snap_id", N),
                                ("stat_name", v(64)), ("value", N)],
           filter="stat_name = 'redo size'"),
    Source("PARAMETER", "F", [("dbid", N), ("con_dbid", N), ("instance_number", N),
                              ("snap_id", N), ("parameter_name", v(64)), ("value", v(512))],
           filter="parameter_name IN ('cpu_count','processes','sessions',"
                  "'db_recovery_file_dest_size','sga_target','sga_max_size',"
                  "'pga_aggregate_target','pga_aggregate_limit','memory_target')"),
    Source("ASM_DISKGROUP_STAT", "F", [("dbid", N), ("con_dbid", N), ("snap_id", N),
                                       ("group_number", N), ("total_mb", N), ("free_mb", N)]),
    Source("SEG_STAT", "F", [("dbid", N), ("con_dbid", N), ("instance_number", N),
                             ("snap_id", N), ("ts#", N), ("obj#", N), ("dataobj#", N),
                             ("space_used_delta", N), ("space_allocated_delta", N)]),
    # Every name, unlike ddl/10's two: the later PGA evidence reads others,
    # and a copy cannot be backfilled once the target's AWR has aged out.
    Source("PGASTAT", "F", [("dbid", N), ("con_dbid", N), ("instance_number", N),
                            ("snap_id", N), ("name", v(64)), ("value", N)],
           optional=True),
    # The memory sizing sources (M25), optional like PGASTAT. Only SGASTAT
    # (per container) copies con_id, for ddl/10's PDB$SEED filter.
    Source("MEM_DYNAMIC_COMP", "F", KEYS + [
               ("component", v(64)), ("current_size", N), ("min_size", N), ("max_size", N),
               ("user_specified_size", N), ("oper_count", N), ("last_oper_type", v(13)),
               ("last_oper_mode", v(9)), ("last_oper_time", DT), ("granule_size", N)],
           optional=True),
    Source("SQL_WORKAREA_HSTGRM", "F", KEYS + [
               ("low_optimal_size", N), ("high_optimal_size", N), ("optimal_executions", N),
               ("onepass_executions", N), ("multipasses_executions", N), ("total_executions", N)],
           optional=True),
    Source("PGA_TARGET_ADVICE", "F", KEYS + [
               ("pga_target_for_estimate", N), ("pga_target_factor", N), ("advice_status", v(3)),
               ("bytes_processed", N), ("estd_time", N), ("estd_extra_bytes_rw", N),
               ("estd_pga_cache_hit_percentage", N), ("estd_overalloc_count", N)],
           optional=True),
    Source("SGA_TARGET_ADVICE", "F", KEYS + [
               ("sga_size", N), ("sga_size_factor", N), ("estd_db_time", N),
               ("estd_physical_reads", N)],
           optional=True),
    Source("DB_CACHE_ADVICE", "F", KEYS + [
               ("bpid", N), ("name", v(20)), ("block_size", N), ("advice_status", v(3)),
               ("size_for_estimate", N), ("size_factor", N), ("buffers_for_estimate", N),
               ("physical_reads", N), ("base_physical_reads", N), ("actual_physical_reads", N),
               ("estd_physical_read_time", N)],
           optional=True),
    Source("SHARED_POOL_ADVICE", "F", KEYS + [
               ("shared_pool_size_for_estimate", N), ("shared_pool_size_factor", N),
               ("estd_lc_size", N), ("estd_lc_memory_objects", N), ("estd_lc_time_saved", N),
               ("estd_lc_time_saved_factor", N), ("estd_lc_load_time", N),
               ("estd_lc_load_time_factor", N), ("estd_lc_memory_object_hits", N)],
           optional=True),
    Source("SGASTAT", "F", [("dbid", N), ("con_dbid", N), ("con_id", N), ("instance_number", N),
                            ("snap_id", N), ("pool", v(30)), ("name", v(64)), ("bytes", N)],
           filter="name = 'free memory'", optional=True),
    Source("LIBRARYCACHE", "F", KEYS + [
               ("namespace", v(15)), ("gets", N), ("gethits", N), ("pins", N), ("pinhits", N),
               ("reloads", N), ("invalidations", N)],
           optional=True),
    Source("ROWCACHE_SUMMARY", "F", KEYS + [("parameter", v(32)), ("gets", N), ("getmisses", N)],
           optional=True),
    Source("SYSTEM_EVENT", "F", KEYS + [
               ("event_name", v(64)), ("wait_class", v(64)), ("total_waits", N),
               ("time_waited_micro", N)],
           filter=MEM_EVENTS, optional=True),
    Source("TABLESPACE", "D", [("dbid", N), ("con_dbid", N), ("ts#", N), ("tsname", v(30)),
                               ("contents", v(30)), ("block_size", N)],
           key=["dbid", "con_dbid", "ts#"]),
    Source("DATAFILE", "D", [("dbid", N), ("con_dbid", N), ("ts#", N), ("block_size", N)]),
    Source("PDB_INSTANCE", "D", [("dbid", N), ("con_dbid", N), ("pdb_name", v(128))]),
    Source("DATABASE_INSTANCE", "D", [("dbid", N), ("instance_number", N), ("startup_time", TS),
                                      ("db_name", v(9)), ("host_name", v(64))],
           key=["dbid", "instance_number", "startup_time"]),
    Source("ASM_DISKGROUP", "D", [("dbid", N), ("con_dbid", N), ("group_number", N),
                                  ("name", v(128))],
           key=["dbid", "con_dbid", "group_number"]),
    Source("SEG_STAT_OBJ", "D", [("dbid", N), ("con_dbid", N), ("ts#", N), ("obj#", N),
                                 ("dataobj#", N), ("owner", v(128)), ("object_name", v(128)),
                                 ("subobject_name", v(128)), ("object_type", v(18)),
                                 ("tablespace_name", v(30))],
           key=["dbid", "con_dbid", "ts#", "obj#", "dataobj#"], scope="SEG_STAT"),
]

LINK = "@{LINK}"   # cap_repo replaces {LINK} with the target's DB link name
# Key columns NOT NULL in every source view (19.27): matched with "=" so a MERGE
# can hash join; any other key column is matched null-safe with DECODE.
NOT_NULL_KEYS = {"dbid", "ts#", "obj#", "dataobj#", "group_number"}
NL = "\n           "  # pull statements are stored one clause per line


def names(src):
    return [c for c, _ in src.cols]


def column_list(cols):
    """cols comma-separated, continued on a new line past 160 characters."""
    lines, cur = [], ""
    for c in cols:
        if cur and len(cur) + len(c) + 2 > 160:
            lines.append(cur + ",")
            cur = c
        else:
            cur = f"{cur}, {c}" if cur else c
    return f"{NL}  ".join(lines + [cur])


def pull_sql(src):
    """The statement cap_repo runs for one chunk.

    F binds (:1 dbid, :2 after snap_id, :3 through snap_id).
    D binds (:1 dbid); with a scope (:1 dbid, :2 dbid, :3 after, :4 through).
    """
    cols = names(src)
    clist = column_list(cols)
    remote = f"dba_hist_{src.name.lower()}{LINK}"
    if src.kind == "F":
        where = "dbid = :1 AND snap_id > :2 AND snap_id <= :3"
        if src.filter:
            where += f" AND ({src.filter})"
        return (f"INSERT INTO cap_h_{src.name.lower()} ({clist})"
                f"{NL}SELECT {clist}{NL}FROM {remote}{NL}WHERE {where}")
    key = src.key or cols
    where = "dbid = :1"
    if src.scope:
        klist = ", ".join(key)
        where += (f"{NL}  AND ({klist}) IN{NL}      (SELECT {klist}"
                  f"{NL}       FROM dba_hist_{src.scope.lower()}{LINK}"
                  f"{NL}       WHERE dbid = :2 AND snap_id > :3 AND snap_id <= :4)")
    on = " AND ".join(f"t.{k} = s.{k}" if k in NOT_NULL_KEYS else f"DECODE(t.{k}, s.{k}, 1, 0) = 1"
                      for k in key)
    rest = [c for c in cols if c not in key]
    upd = (f"{NL}WHEN MATCHED THEN UPDATE SET " + ", ".join(f"t.{c} = s.{c}" for c in rest)) if rest else ""
    vals = ", ".join(f"s.{c}" for c in cols)
    return (f"MERGE INTO cap_h_{src.name.lower()} t"
            f"{NL}USING (SELECT DISTINCT {clist}{NL}       FROM {remote}{NL}       WHERE {where}) s"
            f"{NL}ON ({on}){upd}"
            f"{NL}WHEN NOT MATCHED THEN INSERT ({clist}){NL}     VALUES ({vals})")


def sql_q(s):
    assert "~'" not in s
    return f"q'~{s}~'"


def tables_block():
    out = []
    out.append("-- Copy tables, created on first install. A later install adds a column the")
    out.append("-- manifest gained; it never drops one, and never drops a table (the copies")
    out.append("-- outlive the targets' AWR retention).")
    out.append("DECLARE")
    out.append("    v_owner VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');")
    out.append("    PROCEDURE ensure(p_table VARCHAR2, p_cols SYS.ODCIVARCHAR2LIST) IS")
    out.append("        v_n   PLS_INTEGER;")
    out.append("        v_ddl VARCHAR2(4000);")
    out.append("    BEGIN")
    out.append("        SELECT COUNT(*) INTO v_n FROM all_tables")
    out.append("        WHERE  owner = v_owner AND table_name = UPPER(p_table);")
    out.append("        IF v_n = 0 THEN")
    out.append("            FOR i IN 1 .. p_cols.COUNT LOOP")
    out.append("                v_ddl := v_ddl || CASE WHEN i > 1 THEN ', ' END || p_cols(i);")
    out.append("            END LOOP;")
    out.append("            EXECUTE IMMEDIATE 'CREATE TABLE ' || p_table || ' (' || v_ddl || ')';")
    out.append("            RETURN;")
    out.append("        END IF;")
    out.append("        FOR i IN 1 .. p_cols.COUNT LOOP")
    out.append("            SELECT COUNT(*) INTO v_n FROM all_tab_columns")
    out.append("            WHERE  owner = v_owner AND table_name = UPPER(p_table)")
    out.append("              AND  column_name = UPPER(REGEXP_SUBSTR(p_cols(i), '^\\S+'));")
    out.append("            IF v_n = 0 THEN")
    out.append("                EXECUTE IMMEDIATE 'ALTER TABLE ' || p_table || ' ADD (' || p_cols(i) || ')';")
    out.append("            END IF;")
    out.append("        END LOOP;")
    out.append("    END ensure;")
    out.append("BEGIN")
    for s in SOURCES:
        cols = [f"'{c} {t}'" for c, t in s.cols]
        rows = [", ".join(cols[i:i + 4]) for i in range(0, len(cols), 4)]
        out.append(f"    ensure('cap_h_{s.name.lower()}', SYS.ODCIVARCHAR2LIST(")
        out.append(",\n".join(f"        {r}" for r in rows) + "));")
    out.append("END;")
    out.append("/")
    return out


def source_view():
    out = ["-- One row per copied source: the finished pull statement and its bind shape.",
           "-- optional = 'Y': a reader without the grant is warned about, not failed.",
           "CREATE OR REPLACE VIEW cap_repo_source AS"]
    rows = []
    for i, s in enumerate(SOURCES, 1):
        kind = "S" if s.scope else s.kind
        opt = "Y" if s.optional else "N"
        rows.append(f"SELECT {i} AS seq, '{s.name}' AS source_name, '{kind}' AS kind,"
                    f" '{opt}' AS optional, 'CAP_H_{s.name}' AS copy_table,\n"
                    f"       {sql_q(pull_sql(s))} AS pull_sql FROM dual")
    out.append("\nUNION ALL\n".join(rows) + ";")
    return out


CREATE_VIEW = re.compile(r"\s*CREATE\s+OR\s+REPLACE\s+VIEW\s+(\w+)", re.I)


def strip_comments(text):
    """Comment lines dropped, runs of blank lines collapsed to one."""
    lines, blank = [], False
    for line in text.splitlines():
        if line.lstrip().startswith("--"):
            continue
        if not line.strip():
            if blank:
                continue
            blank = True
        else:
            blank = False
        lines.append(line)
    return lines


def view_blocks(lines):
    """{view: its lines from CREATE OR REPLACE VIEW through the line ending in ';'}.

    The first such line ends the statement for SQL*Plus too, so it ends it here."""
    out, name = {}, None
    for line in lines:
        m = CREATE_VIEW.match(line)
        if m:
            name = m.group(1).lower()
            out[name] = []
        if name:
            out[name].append(line)
            if line.rstrip().endswith(";"):
                name = None
    return out


def overrides():
    return view_blocks(strip_comments(OVERRIDES.read_text()))


def seam_from_local():
    """ddl/10 below its header, comment lines dropped, dba_hist_<x> -> cap_h_<x>,
    and each view of seam_overrides.sql in place of ddl/10's view of that name."""
    text = LOCAL_SEAM.read_text()
    over = overrides()
    out, skip = [], False
    for line in strip_comments(text[text.index("SET DEFINE OFF"):]):
        m = CREATE_VIEW.match(line)
        if m and m.group(1).lower() in over:
            out += over[m.group(1).lower()]
            skip = True
        if skip:
            skip = not line.rstrip().endswith(";")
            continue
        out.append(re.sub(r"\bdba_hist_(\w+)", r"cap_h_\1", line, flags=re.I))
    return out


def local_views():
    sql = "\n".join(l for l in LOCAL_SEAM.read_text().splitlines() if not l.lstrip().startswith("--"))
    return {m.upper() for m in re.findall(r"\bdba_hist_(\w+)", sql, flags=re.I)}


def filter_drift():
    """Literals a ddl/10 view filters on that a copy's filter would drop.

    Per CREATE VIEW of ddl/10: every quoted literal (bar regex patterns) must
    appear in the manifest filter of each filtered source the view reads, or
    the repository would copy fewer rows than local mode reads."""
    sql = "\n".join(l.split("--")[0] for l in LOCAL_SEAM.read_text().splitlines())
    # The session scope (CAP_SCOPE, M24.11) is no row filter of a source.
    sql = re.sub(r"SYS_CONTEXT\('USERENV', *'CLIENT_INFO'\)", "", sql, flags=re.I)
    by_name = {s.name: s for s in SOURCES}
    out = []
    for stmt in re.split(r"CREATE OR REPLACE VIEW", sql, flags=re.I)[1:]:
        view = stmt.split()[0]
        lits = {l for l in re.findall(r"'([^']*)'", stmt) if not re.search(r"[\^$\[\]]", l)}
        for src in {m.upper() for m in re.findall(r"\bdba_hist_(\w+)", stmt, flags=re.I)}:
            f = by_name.get(src)
            if f and f.filter:
                for l in sorted(lits):
                    if f"'{l}'" not in f.filter:
                        out.append(f"{view} keeps '{l}' but the {src} copy filter drops it")
    return out


def granted(path, first=None):
    found = re.findall(r"'DBA_HIST_(\w+)'", path.read_text())
    return found[:first] if first else found


def render():
    head = [
        "--",
        "-- ddl/13_seam_repository.sql -- CAPV_* seam over the CAP_H_* copies (REPOSITORY mode).",
        "-- =====================================================================",
        "-- GENERATED by repository/build.py from its source manifest and from",
        "-- ddl/10_seam_local.sql. Do not edit: change the manifest or ddl/10 and run",
        "--   python3 repository/build.py",
        "--",
        "-- A repository copies the DBA_HIST_* views ddl/10 reads from each registered",
        "-- target (repository/cap_repo.sql pulls them over a DB link) into CAP_H_*",
        "-- tables of the same shape. The seam views below are ddl/10's with every",
        "-- dba_hist_<x> renamed cap_h_<x>, so both modes present the same CAPV_*",
        "-- contract from one body; the notes on every view live in ddl/10. A view",
        "-- of repository/seam_overrides.sql replaces ddl/10's (CAPV_TARGET reads",
        "-- the target registry), so cap_repo.sql is included before the seam.",
        "--",
        "SET DEFINE OFF",
        "",
    ]
    out = head + tables_block() + [""] + source_view() + ["", "@@repository/cap_repo.sql"]
    seam = seam_from_local()
    if seam and seam[0].strip() == "SET DEFINE OFF":
        seam = seam[1:]
    out += seam + [""]
    return "\n".join(out)


def problems():
    want = {s.name for s in SOURCES}
    out = []
    if local_views() != want:
        out.append(f"ddl/10 reads {sorted(local_views() ^ want)} that the manifest does not match")
    if PREPARE.exists() and set(granted(PREPARE)) != want:
        out.append(f"target/prepare.sql grants differ from the manifest: {sorted(set(granted(PREPARE)) ^ want)}")
    if set(granted(CREATE_OWNER, len(want))) != want:
        out.append(f"create_owner.sql: its first {len(want)} DBA_HIST grants are not the manifest's views")
    out += filter_drift()
    local = set(view_blocks(strip_comments(LOCAL_SEAM.read_text())))
    over = overrides()
    if set(over) - local:
        out.append(f"repository/seam_overrides.sql defines {sorted(set(over) - local)}, which ddl/10 does not")
    in_views = {l for lines in over.values() for l in lines}
    if any(l.strip() and l not in in_views for l in strip_comments(OVERRIDES.read_text())):
        out.append("repository/seam_overrides.sql has text outside a CREATE OR REPLACE VIEW")
    if any(re.search(r"\bdba_hist_", l, flags=re.I) for lines in over.values() for l in lines):
        out.append("repository/seam_overrides.sql reads DBA_HIST_* (the seam reads the cap_h_* copies)")
    capv = lambda names: {n for n in names if n.startswith("capv_")}
    generated = capv(view_blocks(render().splitlines()))
    if generated != capv(local):
        out.append(f"ddl/13 CAPV views differ from ddl/10's: {sorted(generated ^ capv(local))}")
    for s in SOURCES:
        cols = names(s)
        for k in s.key:
            if k not in cols:
                out.append(f"{s.name}: key column {k} not copied")
        if s.kind == "F" and not {"dbid", "snap_id"} <= set(cols):
            out.append(f"{s.name}: a fact needs dbid and snap_id")
        if len(f"cap_h_{s.name}") > 30:
            out.append(f"{s.name}: copy table name longer than 30")
        if len(pull_sql(s)) > 3900 or any(len(l) > 240 for l in pull_sql(s).splitlines()):
            out.append(f"{s.name}: pull statement too long (a 4000-byte literal, 240-char lines)")
    return out


def main():
    check = "--check" in sys.argv[1:]
    errs = problems()
    text = render()
    if check:
        if not OUT.exists() or OUT.read_text() != text:
            errs.append(f"{OUT.relative_to(ROOT)} is stale: run python3 repository/build.py")
        for e in errs:
            print(f"repository/build.py: {e}", file=sys.stderr)
        if not errs:
            print("repository/build.py: generated seam up to date, grant lists match the manifest")
        return 1 if errs else 0
    OUT.write_text(text)
    print(f"wrote {OUT.relative_to(ROOT)}")
    for e in errs:
        print(f"repository/build.py: {e}", file=sys.stderr)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
