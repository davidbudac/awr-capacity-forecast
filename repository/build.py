#!/usr/bin/env python3
"""Generate ddl/13_seam_repository.sql and test/repo_copy_check.sql from the
source manifest and repository/seam.sql.

    python3 repository/build.py           # write the generated files
    python3 repository/build.py --check   # exit 1 if one is stale or a list drifted

The manifest below is the one place that says which DBA_HIST_* views a
repository copies from its targets, which columns, how a copy is keyed and
which rows are worth copying. From it this script writes, in one file:

  * CAP_H_<view>, one copy table per source view, created idempotently
    (persisted: ddl/00_drop never drops them, uninstall.sql does);
  * CAP_REPO_SOURCE, a view holding the finished pull statement per source,
    which repository/cap_repo.sql executes over each target's DB link;
  * the include of repository/cap_repo.sql (the registry the seam reads);
  * the CAPV_* seam: repository/seam.sql (the seam written over DBA_HIST_*,
    never installed itself) with every dba_hist_<x> renamed cap_h_<x>.

and, as test/repo_copy_check.sql, the check that each copy still equals its
source over the target's link (test/dbmint_copy_check.sh runs it).

--check also proves that the views repository/seam.sql reads and the views
target/prepare.sql grants are the manifest's, and that ddl/13 defines
exactly seam.sql's CAPV_* views.
"""
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEAM = ROOT / "repository" / "seam.sql"
OUT = ROOT / "ddl" / "13_seam_repository.sql"
COPY_CHECK = ROOT / "test" / "repo_copy_check.sql"
PREPARE = ROOT / "target" / "prepare.sql"

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
    filter: rows not worth copying. It must keep every row seam.sql keeps.
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
    # The memory sizing sources (M26), optional like PGASTAT. Only SGASTAT
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


def row_text(src):
    parts = []
    for c, t in src.cols:
        if t == TS:
            parts.append(f"TO_CHAR({c}, 'YYYY-MM-DD HH24:MI:SS.FF3')")
        elif t == N:
            parts.append(f"TO_CHAR({c})")
        else:
            parts.append(c)
    return " || '|' || ".join(parts)


COPY_CHECK_HEAD = """\
--
-- test/repo_copy_check.sql -- prove each CAP_H_* copy equals its source on the target.
-- =====================================================================
-- GENERATED by repository/build.py from its source manifest. Do not edit:
-- change the manifest and run python3 repository/build.py
--
--   @test/repo_copy_check.sql [target|-] [plant_source|-]
--
-- Run as SYSDBA under ALTER SESSION SET CURRENT_SCHEMA = <repository schema>
-- (test/dbmint_copy_check.sh does), right after a collect. For every enabled
-- target (or the one named), each DBID it has collected and each source the
-- manifest copies, it compares the source over the target's link with the
-- copy both ways (source MINUS copy, copy MINUS source) and by row count:
--   F  snap_id from the later of the source's and the copy's oldest snap_id
--      (AWR purges the target, cap_repo.purge the copy) through the DBID's
--      high-water mark, the manifest's row filter on the source side; a copy
--      row above the high-water mark is a difference;
--   D  every row of the DBID, distinct on the source side as the MERGE is;
--   S  SEG_STAT_OBJ rows keyed by a SEG_STAT row of SEG_STAT's window.
-- A D or S copy keeps rows the target has since purged (cap_repo never
-- deletes dimension rows, e.g. DATABASE_INSTANCE of an aged-out startup), so
-- there only a source row missing from the copy is a difference; copy-only
-- rows are listed as kept. A stale copy of a keyed row still shows as its
-- source row missing.
-- Prints "COPYCHECK <target> dbid=<n> <source> ..." per source and DBID, its
-- first 10 differing rows, and one closing line
--   COPYCHECK-RESULT EQUAL | DIFFERENT | MOVED | FAILED ...
-- MOVED: the target took a snapshot or the high-water mark moved during the
-- check (purges and dimension rows ride on snapshots); rerun it.
-- plant_source names a fact (OSSTAT, ...): the check first deletes one copy
-- row of it, uncommitted, to prove a difference is caught, and this script
-- rolls it back (EXITCOMMIT OFF, ROLLBACK on error and at the end).
-- A private link resolves only for its owner, so the check runs in a
-- throwaway definer's-rights procedure, CAP_COPY_CHECK, dropped at the end.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/test/repo_copy_check.sql"
SET DEFINE '&'
SET VERIFY OFF
SET FEEDBACK OFF
SET LINESIZE 32767
SET TAB OFF
SET TRIMOUT ON
SET TRIMSPOOL ON
SET EXITCOMMIT OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
COLUMN 1 NEW_VALUE 1
COLUMN 2 NEW_VALUE 2
SELECT NULL AS "1", NULL AS "2" FROM dual WHERE 1 = 0;

CREATE OR REPLACE PROCEDURE cap_copy_check(p_target IN VARCHAR2, p_plant IN VARCHAR2)
    AUTHID DEFINER AS
    TYPE t_num  IS TABLE OF NUMBER INDEX BY VARCHAR2(30);
    TYPE t_rows IS TABLE OF VARCHAR2(4000);
    v_lo      t_num;
    v_target  VARCHAR2(26);
    v_link    VARCHAR2(128);
    v_dbid    NUMBER;
    v_hwm     NUMBER;
    v_newest  NUMBER;
    v_checks  PLS_INTEGER := 0;
    v_diff    PLS_INTEGER := 0;
    v_fail    PLS_INTEGER := 0;
    v_rows    NUMBER := 0;
    v_moved   BOOLEAN := FALSE;
    v_t0      PLS_INTEGER := DBMS_UTILITY.GET_TIME;

    FUNCTION num(p_sql VARCHAR2) RETURN NUMBER IS
        v NUMBER;
    BEGIN
        EXECUTE IMMEDIATE p_sql INTO v;
        RETURN v;
    END num;

    PROCEDURE plant(p_name VARCHAR2) IS
        v_snap NUMBER := num('SELECT MAX(snap_id) FROM cap_h_' || p_name
                             || ' WHERE dbid = ' || v_dbid || ' AND snap_id <= ' || v_hwm);
    BEGIN
        EXECUTE IMMEDIATE 'DELETE FROM cap_h_' || p_name || ' WHERE dbid = ' || v_dbid
                          || ' AND snap_id = ' || v_snap || ' AND ROWNUM = 1';
        DBMS_OUTPUT.PUT_LINE('COPYCHECK-PLANTED CAP_H_' || UPPER(p_name) || ' dbid=' || v_dbid
                             || ' snap_id=' || v_snap || ' rows=' || SQL%ROWCOUNT);
    END plant;

    PROCEDURE one(p_name VARCHAR2, p_kind VARCHAR2, p_cols VARCHAR2, p_txt VARCHAR2,
                  p_filter VARCHAR2 DEFAULT NULL, p_scope VARCHAR2 DEFAULT NULL,
                  p_keys VARCHAR2 DEFAULT NULL) IS
        v_src    VARCHAR2(32767);
        v_copy   VARCHAR2(32767);
        v_win    VARCHAR2(100);
        v_n_src  NUMBER;
        v_n_copy NUMBER;
        v_side   VARCHAR2(10);
        v_row    VARCHAR2(4000);
        v_shown  t_rows := t_rows();
        v_o_src  PLS_INTEGER := 0;
        v_o_copy PLS_INTEGER := 0;
        v_cur    SYS_REFCURSOR;
        v_ok     BOOLEAN;
        v_where  VARCHAR2(4000) := CASE WHEN p_filter IS NOT NULL THEN ' AND (' || p_filter || ')' END;
    BEGIN
        v_src  := 'SELECT ' || CASE WHEN p_kind <> 'F' THEN 'DISTINCT ' END || p_cols
                  || ' FROM dba_hist_' || p_name || '@' || v_link || ' WHERE dbid = ' || v_dbid;
        v_copy := 'SELECT ' || p_cols || ' FROM cap_h_' || p_name || ' WHERE dbid = ' || v_dbid;
        IF p_kind = 'F' THEN
            v_lo(p_name) := GREATEST(
                NVL(num('SELECT MIN(snap_id) FROM dba_hist_' || p_name || '@' || v_link
                        || ' WHERE dbid = ' || v_dbid || v_where), 0),
                NVL(num('SELECT MIN(snap_id) FROM cap_h_' || p_name || ' WHERE dbid = ' || v_dbid), 0));
            v_src  := v_src || ' AND snap_id BETWEEN ' || v_lo(p_name) || ' AND ' || v_hwm || v_where;
            v_copy := v_copy || ' AND snap_id >= ' || v_lo(p_name);
            v_win  := ' snap ' || v_lo(p_name) || '..' || v_hwm;
            IF UPPER(p_plant) = UPPER(p_name) THEN
                plant(p_name);
            END IF;
        ELSIF p_kind = 'S' THEN
            v_src  := v_src || ' AND (' || p_keys || ') IN (SELECT ' || p_keys || ' FROM dba_hist_'
                      || p_scope || '@' || v_link || ' WHERE dbid = ' || v_dbid || ' AND snap_id BETWEEN '
                      || v_lo(p_scope) || ' AND ' || v_hwm || ')';
            v_copy := v_copy || ' AND (' || p_keys || ') IN (SELECT ' || p_keys || ' FROM cap_h_'
                      || p_scope || ' WHERE dbid = ' || v_dbid || ' AND snap_id BETWEEN '
                      || v_lo(p_scope) || ' AND ' || v_hwm || ')';
            v_win  := ' keys of ' || UPPER(p_scope) || ' ' || v_lo(p_scope) || '..' || v_hwm;
        END IF;
        v_n_src  := num('SELECT COUNT(*) FROM (' || v_src || ')');
        v_n_copy := num('SELECT COUNT(*) FROM (' || v_copy || ')');
        OPEN v_cur FOR 'SELECT ''SRC-ONLY'', ' || p_txt || ' FROM (' || v_src || ' MINUS ' || v_copy || ')'
                       || ' UNION ALL SELECT ''COPY-ONLY'', ' || p_txt || ' FROM (' || v_copy
                       || ' MINUS ' || v_src || ')';
        LOOP
            FETCH v_cur INTO v_side, v_row;
            EXIT WHEN v_cur%NOTFOUND;
            IF v_side = 'SRC-ONLY' THEN v_o_src := v_o_src + 1; ELSE v_o_copy := v_o_copy + 1; END IF;
            IF v_shown.COUNT < 10 THEN
                v_shown.EXTEND;
                v_shown(v_shown.COUNT) := '  ' || RPAD(CASE WHEN v_side = 'COPY-ONLY' AND p_kind <> 'F'
                                                            THEN 'KEPT' ELSE v_side END, 10)
                                          || UPPER(p_name) || ' ' || v_row;
            END IF;
        END LOOP;
        CLOSE v_cur;
        v_ok := v_o_src = 0 AND (p_kind <> 'F' OR v_n_src = v_n_copy AND v_o_copy = 0);
        v_checks := v_checks + 1;
        v_rows   := v_rows + v_n_src;
        IF NOT v_ok THEN
            v_diff := v_diff + 1;
        END IF;
        DBMS_OUTPUT.PUT_LINE('COPYCHECK ' || v_target || ' dbid=' || v_dbid || ' ' || RPAD(UPPER(p_name), 19)
                             || p_kind || v_win || ' src=' || v_n_src || ' copy=' || v_n_copy
                             || ' src_only=' || v_o_src || ' copy_only=' || v_o_copy
                             || CASE WHEN NOT v_ok THEN ' DIFF'
                                     WHEN v_o_copy > 0 THEN ' OK (copy-only rows kept)'
                                     ELSE ' OK' END);
        FOR i IN 1 .. v_shown.COUNT LOOP
            DBMS_OUTPUT.PUT_LINE(v_shown(i));
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            v_fail := v_fail + 1;
            DBMS_OUTPUT.PUT_LINE('COPYCHECK ' || v_target || ' dbid=' || v_dbid || ' '
                                 || RPAD(UPPER(p_name), 19) || 'ERROR ' || SQLERRM);
    END one;

    FUNCTION newest RETURN NUMBER IS
    BEGIN
        RETURN num('SELECT MAX(snap_id) FROM dba_hist_snapshot@' || v_link || ' WHERE dbid = ' || v_dbid);
    END newest;
BEGIN
    FOR t IN (SELECT t.target_name, t.db_link, d.dbid, d.last_snap_id
              FROM   cap_target t JOIN cap_target_dbid d ON d.target_id = t.target_id
              WHERE  (t.target_name = UPPER(p_target) OR p_target IS NULL AND t.enabled = 'Y')
                AND  d.last_snap_id > 0
              ORDER  BY t.target_name, d.dbid) LOOP
        v_target := t.target_name;
        v_link   := t.db_link;
        v_dbid   := t.dbid;
        v_hwm    := t.last_snap_id;
        v_lo.DELETE;
        BEGIN
            v_newest := newest;
"""

COPY_CHECK_TAIL = """\
            IF newest <> v_newest
               OR num('SELECT last_snap_id FROM cap_target_dbid WHERE dbid = ' || v_dbid) <> v_hwm THEN
                v_moved := TRUE;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                v_fail := v_fail + 1;
                DBMS_OUTPUT.PUT_LINE('COPYCHECK ' || v_target || ' dbid=' || v_dbid || ' ERROR ' || SQLERRM);
        END;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('COPYCHECK-RESULT '
        || CASE WHEN v_fail > 0 THEN 'FAILED'
                WHEN v_checks = 0 THEN 'FAILED (no collected DBID of an enabled target)'
                WHEN v_moved THEN 'MOVED'
                WHEN v_diff > 0 THEN 'DIFFERENT'
                ELSE 'EQUAL' END
        || ' checks=' || v_checks || ' differing=' || v_diff || ' errors=' || v_fail
        || ' rows=' || v_rows || ' seconds=' || ROUND((DBMS_UTILITY.GET_TIME - v_t0) / 100, 1));
END cap_copy_check;
/
SHOW ERRORS

WHENEVER SQLERROR CONTINUE
EXEC cap_copy_check(NULLIF('&1', '-'), NULLIF('&2', '-'))
ROLLBACK;
DROP PROCEDURE cap_copy_check;
UNDEFINE 1 2
"""


def copy_check():
    calls = []
    for s in SOURCES:
        kind = "S" if s.scope else s.kind
        args = [f"'{s.name.lower()}'", f"'{kind}'", sql_q(", ".join(names(s))), sql_q(row_text(s))]
        if s.filter:
            args.append(f"p_filter => {sql_q(s.filter)}")
        if s.scope:
            args += [f"p_scope => '{s.scope.lower()}'", f"p_keys => {sql_q(', '.join(s.key))}"]
        calls.append("            one(" + (",\n                ".join(args)) + ");")
    return COPY_CHECK_HEAD + "\n".join(calls) + "\n" + COPY_CHECK_TAIL


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


def renamed_seam():
    text = SEAM.read_text()
    return [re.sub(r"\bdba_hist_(\w+)", r"cap_h_\1", line, flags=re.I)
            for line in strip_comments(text[text.index("SET DEFINE OFF"):])]


def seam_sources():
    sql = "\n".join(l for l in SEAM.read_text().splitlines() if not l.lstrip().startswith("--"))
    return {m.upper() for m in re.findall(r"\bdba_hist_(\w+)", sql, flags=re.I)}


def filter_drift():
    sql = "\n".join(l.split("--")[0] for l in SEAM.read_text().splitlines())
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


def granted(path):
    return re.findall(r"'DBA_HIST_(\w+)'", path.read_text())


def render():
    head = [
        "--",
        "-- ddl/13_seam_repository.sql -- CAPV_* seam over the CAP_H_* copies (REPOSITORY mode).",
        "-- =====================================================================",
        "-- GENERATED by repository/build.py from its source manifest and from",
        "-- repository/seam.sql. Do not edit: change the manifest or seam.sql and run",
        "--   python3 repository/build.py",
        "--",
        "-- A repository copies the DBA_HIST_* views seam.sql reads from each registered",
        "-- target (repository/cap_repo.sql pulls them over a DB link) into CAP_H_*",
        "-- tables of the same shape. The seam views below are seam.sql's with every",
        "-- dba_hist_<x> renamed cap_h_<x>; the notes on every view live in seam.sql.",
        "-- CAPV_TARGET reads the target registry, so cap_repo.sql is included before",
        "-- the seam.",
        "--",
        "SET DEFINE OFF",
        "",
    ]
    out = head + tables_block() + [""] + source_view() + ["", "@@repository/cap_repo.sql"]
    seam = renamed_seam()
    if seam and seam[0].strip() == "SET DEFINE OFF":
        seam = seam[1:]
    out += seam + [""]
    return "\n".join(out)


def problems():
    want = {s.name for s in SOURCES}
    out = []
    if seam_sources() != want:
        out.append(f"repository/seam.sql reads {sorted(seam_sources() ^ want)} that the manifest does not match")
    if PREPARE.exists() and set(granted(PREPARE)) != want:
        out.append(f"target/prepare.sql grants differ from the manifest: {sorted(set(granted(PREPARE)) ^ want)}")
    out += filter_drift()
    seam = set(view_blocks(strip_comments(SEAM.read_text())))
    capv = lambda names: {n for n in names if n.startswith("capv_")}
    generated = capv(view_blocks(render().splitlines()))
    if generated != capv(seam):
        out.append(f"ddl/13 CAPV views differ from repository/seam.sql's: {sorted(generated ^ capv(seam))}")
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
    files = {OUT: render(), COPY_CHECK: copy_check()}
    if check:
        for path, text in files.items():
            if not path.exists() or path.read_text() != text:
                errs.append(f"{path.relative_to(ROOT)} is stale: run python3 repository/build.py")
        for e in errs:
            print(f"repository/build.py: {e}", file=sys.stderr)
        if not errs:
            print("repository/build.py: generated seam and copy check up to date, grant lists match the manifest")
        return 1 if errs else 0
    for path, text in files.items():
        path.write_text(text)
        print(f"wrote {path.relative_to(ROOT)}")
    for e in errs:
        print(f"repository/build.py: {e}", file=sys.stderr)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
