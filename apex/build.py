#!/usr/bin/env python3
"""Generate the AWR Capacity APEX application export and its smoke harness.

    python3 apex/build.py           writes apex/awrcap_app.sql
    python3 apex/build.py --smoke   also writes apex/test/apex_smoke.sql and
                                    apex/test/apex_probe.sql
    python3 apex/build.py --check   writes nothing; exit 1 when one of the
                                    three generated files is stale

Everything is derived from two registries: COLLECTIONS (what each CAPR_ view
is cached as, slot by slot) and PAGES (every region and its SQL).  The
collection loader, the CTE prefix of every region query, the per-page load
list, the smoke harness and the probe all come from them, so a column or a
query is written exactly once.  Output is deterministic: ids come from a
sequential allocator, so two runs produce byte-identical files.

A new field: one (column, slot) pair in COLLECTIONS and one Col where it is
shown.  A new view: one COLLECTIONS entry.  A new page: a Page in PAGES (its
id a P_ constant).  The loader, the navigation and both test scripts follow.

The smoke harness needs an APEX session.  The probe needs none: a table
stands in for APEX_COLLECTIONS, so the same loader queries, region queries,
LOVs and defaults run against any install of the suite (see emit_probe).
"""
import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP_ID, APP_ALIAS, APP_NAME = 110, 'AWRCAP', 'AWR Capacity'
WORKSPACE = SCHEMA = 'AWRCAP'
ID_BASE = 110_000_000_000_000
RANGE_PAD_DAYS = 120
P_OVERVIEW, P_TBSPC, P_CPU, P_ANOM, P_TARGETS, P_MEMORY = 1, 2, 3, 4, 5, 6

# Universal Theme 42 (26.2) template ids; constant across installs.
TPL = {
    'page': 4075783602716660119, 'page_login': 2104585595298951431,
    'region': 4075786578761660127, 'region_ir': 2103954283454391425,
    'region_login': 2677585639786677191, 'report': 2542081983073888486,
    'report_badges': 2108071605011515574, 'button': 4075790603270660137,
    'label': 1612549609962752680, 'label_hidden': 2044213549383960320,
    'nav_side': 2471166859590295591, 'nav_bar': 2850970698196720012,
    'style_iris': 4194319937007846,
}
RED, AMBER, BLUE, GREY, GREEN = '#D63B25', '#F2A900', '#309FDB', '#8E8E8E', '#3BAA2C'

# name -> (cte alias, source query, [(column, slot)]).  Slots: n1..n5 NUMBER,
# d1..d5 DATE, c1..c50 VARCHAR2; 'cK:num' is a NUMBER kept in a text slot.
COLLECTIONS = {
    'AWRCAP_CONTAINER': ('c_cont', 'select * from capr_container', [
        ('db_pdb', 'c1'), ('db_name', 'c2'), ('con_name', 'c3'), ('target_name', 'c4'),
        ('dbid', 'n1'), ('con_dbid', 'n2')]),
    'AWRCAP_TARGETS': ('c_tgt', 'select * from capr_targets', [
        ('target_name', 'c1'), ('db_name', 'c2'), ('feed', 'c3'), ('host_name', 'c4'), ('db_link', 'c5'),
        ('enabled', 'c6'), ('is_stale', 'c7'), ('collect_state', 'c8'), ('last_error', 'c9'),
        ('newest_snap', 'd1'), ('last_ok_at', 'd2'), ('last_error_at', 'd3'),
        ('dbid', 'n1'), ('n_containers', 'n2'), ('age_hours', 'n3'), ('n_gaps', 'n4'),
        ('collected_snap_id', 'n5')]),
    'AWRCAP_SERIES': ('c_series', 'select * from capr_series_points', [
        ('db', 'c1'), ('kind', 'c2'), ('series', 'c3'), ('unit', 'c4'), ('anomaly_flag', 'c5'),
        ('ts', 'd1'),
        ('value', 'n1'), ('limit_value', 'n2'), ('expected', 'n3'), ('rate_bpd', 'n4'), ('anomaly', 'n5'),
        ('pct', 'c6:num'), ('gap', 'c7:num'), ('z', 'c8:num'), ('threshold', 'c9:num'),
        ('delta_bytes', 'c10:num'), ('busy_p95', 'c11:num'), ('busy_peak_pct', 'c12:num')]),
    'AWRCAP_FORECAST': ('c_fcst', 'select * from capr_forecast_points', [
        ('db', 'c1'), ('kind', 'c2'), ('series', 'c3'), ('unit', 'c4'), ('method', 'c5'), ('quality', 'c6'),
        ('ts', 'd1'),
        ('value', 'n1'), ('lo', 'n2'), ('hi', 'n3'), ('limit_value', 'n4'), ('horizon_days', 'n5'),
        ('pct', 'c7:num')]),
    'AWRCAP_FIT': ('c_fit', 'select * from capr_fit', [
        ('db', 'c1'), ('kind', 'c2'), ('series', 'c3'), ('unit', 'c4'), ('method', 'c5'), ('quality', 'c6'),
        ('sev', 'c7'), ('limit_source', 'c8'),
        ('last_day', 'd1'),
        ('value', 'n1'), ('limit_value', 'n2'), ('pct', 'n3'), ('days_to_full', 'n4'), ('sev_rank', 'n5'),
        ('slope_per_day', 'c9:num'), ('r2', 'c10:num'), ('days_to_full_lo', 'c11:num'),
        ('days_to_full_hi', 'c12:num'), ('accel', 'c13:num'), ('train_n', 'c14:num')]),
    'AWRCAP_ANOMALIES': ('c_anom', 'select * from capr_anomalies', [
        ('db', 'c1'), ('kind', 'c2'), ('series', 'c3'), ('anomaly_kind', 'c4'), ('anomaly_flag', 'c5'),
        ('unit', 'c6'), ('sev', 'c7'), ('message', 'c8'),
        ('ts', 'd1'), ('obs_day', 'd2'),
        ('value', 'n1'), ('expected', 'n2'), ('threshold', 'n3'), ('z', 'n4'), ('sev_rank', 'n5'),
        ('shift_pct', 'c9:num'), ('rate_bpd', 'c10:num')]),
    'AWRCAP_ALERTS': ('c_alert', 'select * from capr_alerts', [
        ('severity', 'c1'), ('kind', 'c2'), ('db_pdb', 'c3'), ('series_key', 'c4'), ('unit', 'c5'),
        ('message', 'c6'),
        ('day_dt', 'd1'),
        ('sev_rank', 'n1'), ('value', 'n2'), ('threshold', 'n3')]),
    'AWRCAP_MEM_VERDICT': ('c_memv', 'select * from capr_mem_verdict', [
        ('db_pdb', 'c1'), ('area', 'c2'), ('area_label', 'c3'), ('mem_mode', 'c4'), ('grade', 'c5'),
        ('reason', 'c6'), ('reason_text', 'c7'), ('actionable', 'c8'), ('current_size', 'c9'),
        ('suggested_size', 'c10'), ('suggested_param', 'c11'), ('exceeds_host_ram', 'c12'),
        ('exceeds_sga', 'c13'), ('headline', 'c14'),
        ('window_start', 'd1'), ('window_end', 'd2'),
        ('instance_number', 'n1'), ('area_rank', 'n2'), ('current_bytes', 'n3'), ('suggested_bytes', 'n4'),
        ('change_pct', 'n5'),
        ('n_evidence', 'c15:num'), ('n_pressure', 'c16:num'), ('n_days', 'c17:num'), ('rank_mem', 'c18:num')]),
    'AWRCAP_MEM_EVIDENCE': ('c_meme', 'select * from capr_mem_evidence', [
        ('db_pdb', 'c1'), ('area', 'c2'), ('area_label', 'c3'), ('kind', 'c4'), ('signal', 'c5'),
        ('direction', 'c6'), ('unit', 'c7'), ('evidence_text', 'c8'),
        ('observed_at', 'd1'),
        ('instance_number', 'n1'), ('area_rank', 'n2'), ('value', 'n3'), ('threshold', 'n4'), ('rank_ev', 'n5')]),
    # CAPR_MEM_COMP_POINTS has no label column: db_pdb comes from CAPR_CONTAINER (instance rows, con_dbid = dbid).
    'AWRCAP_MEM_POINTS': ('c_memp', 'select p.instance_number, p.component, p.ts, p.bytes, p.min_bytes, '
                                    'p.max_bytes, p.ops, nvl(c.db_pdb, to_char(p.dbid)) db_pdb '
                                    'from capr_mem_comp_points p left join capr_container c '
                                    'on c.dbid = p.dbid and c.con_dbid = p.con_dbid', [
        ('db_pdb', 'c1'), ('component', 'c2'),
        ('ts', 'd1'),
        ('instance_number', 'n1'), ('bytes', 'n2'), ('min_bytes', 'n3'), ('max_bytes', 'n4'), ('ops', 'n5')]),
    'AWRCAP_META': ('c_meta', 'select {} , sysdate loaded_at from cap_config'.format(', '.join(
        f"max(case when cfg_name = '{k}' then cfg_value end) {k}" for k in (
            'cpu_sat_pct', 'dtf_warn', 'dtf_crit', 'nearfull_warn_pct', 'nearfull_crit_pct',
            'series_sat_pct', 'anomaly_report_days'))), [
        ('cpu_sat_pct', 'n1'), ('dtf_warn', 'n2'), ('dtf_crit', 'n3'), ('nearfull_warn_pct', 'n4'),
        ('nearfull_crit_pct', 'n5'), ('series_sat_pct', 'c1:num'), ('anomaly_report_days', 'c2:num'),
        ('loaded_at', 'd1')]),
}
# Columns that move between two reads of a view (SYSDATE inside): the fidelity checks skip them.
VOLATILE = {'loaded_at', 'age_hours', 'is_stale'}
NLS = "'NLS_NUMERIC_CHARACTERS=''.,'''"
NUM_MASK = "'" + '9' * 26 + 'D' + '9' * 10 + "'"


def parse_slot(slot):
    m = re.fullmatch(r'([ncd])(\d+)(:num)?', slot)
    return m.group(1), int(m.group(2)), bool(m.group(3))


def slot_column(kind, n):
    return f'{kind}{n:03d}'


def check_collections():
    for name, (_, _, cols) in COLLECTIONS.items():
        seen = set()
        for col, slot in cols:
            kind, n, _ = parse_slot(slot)
            limit = {'n': 5, 'd': 5, 'c': 50}[kind]
            assert 1 <= n <= limit and (kind, n) not in seen, f'{name}.{col}: bad slot {slot}'
            seen.add((kind, n))


def cte(name):
    alias, _, cols = COLLECTIONS[name]
    sel = []
    for col, slot in cols:
        kind, n, numeric = parse_slot(slot)
        src = slot_column(kind, n)
        sel.append(f'to_number({src}, {NUM_MASK}, {NLS}) {col}' if numeric else f'{src} {col}')
    return f"{alias} as (select {', '.join(sel)} from apex_collections where collection_name = '{name}')"


def loader_query(name):
    """The positional select list queryb2 wants: n001..n005, d001..d005, c001..
    The aliases are for the probe, whose stand-in table has columns of those names."""
    _, source, cols = COLLECTIONS[name]
    by_slot = {}
    for col, slot in cols:
        kind, n, numeric = parse_slot(slot)
        by_slot[kind, n] = f"to_char(round({col}, 10), 'TM9', {NLS})" if numeric else col
    width = max([n for k, n in by_slot if k == 'c'] or [0])
    slots = [('n', i, 'number') for i in range(1, 6)] + [('d', i, 'date') for i in range(1, 6)]
    slots += [('c', i, 'varchar2(1)') for i in range(1, width + 1)]
    sel = [f"{by_slot.get((kind, i), f'cast(null as {dtype})')} {slot_column(kind, i)}" for kind, i, dtype in slots]
    return f"select {', '.join(sel)} from ({source})"


def needs(text):
    return [name for name, (alias, _, _) in COLLECTIONS.items() if re.search(rf'\b{alias}\b', text)]


def with_ctes(body):
    used = needs(body)
    return ('with ' + ',\n'.join(cte(n) for n in used) + '\n' + body) if used else body


D_FROM = "to_date(:P0_FROM default null on conversion error, 'YYYY-MM-DD')"
D_TO = "to_date(:P0_TO default null on conversion error, 'YYYY-MM-DD')"
GIB, MIB = 1073741824, 1048576


def in_target(col):
    """col holds a db_pdb label; a target owns the labels CAPR_CONTAINER lists under its name."""
    return (f'(:P0_TARGET is null or {col} in (select t.db_pdb from c_cont t '
            'where t.target_name = :P0_TARGET))')


def in_db(col):
    return f'((:P0_DB is null or {col} = :P0_DB) and {in_target(col)})'


def target_of(col):
    return f'(select max(t.target_name) from c_cont t where t.db_pdb = {col})'


def as_v(sql):
    """Item binds as v() calls: SQL inside the PL/SQL of an application process."""
    return re.sub(r':(P0_\w+)', r"v('\1')", sql)


def in_range(col):
    return f'{col} between nvl({D_FROM}, {col}) and nvl({D_TO}, {col})'


def sev_css(col):
    return (f"case {col} when 'CRIT' then 't-Badge--danger' when 'WARN' then 't-Badge--warning' "
            f"when 'INFO' then 't-Badge--info' else 't-Badge--success' end")


def db_label(db_col, series_col):
    return f"case when :P0_DB is null then {db_col} || ' ' || {series_col} else {series_col} end"


def url(page, items, values):
    return f"apex_page.get_url(p_page => {page}, p_items => '{items}', p_values => {values})"


def tbspc_key(a):
    """P0_TBSPC value: database plus tablespace, since names repeat across databases."""
    return f"{a}.db || '|' || {a}.series"


def tbspc_selected(a):
    return f'{tbspc_key(a)} = :P0_TBSPC'


def tbspc_scope(a):
    return f"({tbspc_selected(a)} or (:P0_TBSPC = 'ALL' and {in_db(a + '.db')}))"


HOST_SERIES = "('BUSY_PCT', 'BUSY_P95', 'BUSY_PEAK')"


def host_scope(col):
    """Host CPU is recorded under the CDB root, so a PDB filter selects its root's rows.
    The memory verdicts and the PGA series are instance level and use the same scope."""
    return (f'((:P0_DB is null or {col} in (select r.db_pdb from c_cont r, c_cont c '
            f'where c.db_pdb = :P0_DB and r.dbid = c.dbid and r.con_dbid = r.dbid)) and {in_target(col)})')


def anom_scope(a):
    return (f'{in_db(a + ".db")} and {in_range(a + ".ts")} and (:P0_KIND is null or {a}.anomaly_kind = :P0_KIND) '
            f'and (:P0_SEV is null or {a}.sev = :P0_SEV)')


RANGE_EDGES = f'(select {D_FROM} ts from dual union all select {D_TO} ts from dual)'


@dataclass
class Col:
    alias: str
    expr: str
    heading: str = None  # None hides the column
    kind: str = 'STRING'  # STRING | NUMBER | DATE
    html: str = None


def badge_cols(alias, expr, heading, css):
    return [Col(alias, expr, heading, html=f'<span class="t-Badge t-Badge--sm #{alias}_CSS#">#{alias}#</span>'),
            Col(f'{alias}_CSS', css)]


def sev_cols(expr, alias='SEV', heading='Severity'):
    return badge_cols(alias, expr, heading, sev_css(expr))


def case_of(expr, mapping, default=None):
    whens = ' '.join(f"when '{value}' then '{result}'" for value, result in mapping.items())
    return f"case {expr} {whens}{f' else {default}' if default else ''} end"


# Feed units the app renames for display; any other unit is shown as the view gives it.
UNIT_LABELS = {'io_per_sec': 'requests/s', 'mb_per_sec': 'MB/s'}


def unit_label(col):
    return case_of(f'lower({col})', UNIT_LABELS, default=col)


def link_cols(alias, expr, heading, href):
    return [Col(alias, expr, heading, html=f'<a href="#{alias}_URL#">#{alias}#</a>'), Col(f'{alias}_URL', href)]


ALERT_ORDER = 'order by a.sev_rank, a.day_dt desc'


def alert_cols(series_heading='Series'):
    """CAPR_ALERTS columns; SEV_RANK stays hidden so reports can sort on it."""
    return [*sev_cols('a.severity'), Col('SEV_RANK', 'a.sev_rank'), Col('KIND', 'a.kind', 'Kind'),
            Col('TARGET', target_of('a.db_pdb'), 'Target'),
            Col('DB', 'a.db_pdb', 'Database'), Col('SERIES', 'a.series_key', series_heading),
            Col('DAY', 'a.day_dt', 'Day', 'DATE'), Col('VALUE', 'round(a.value, 2)', 'Value', 'NUMBER'),
            Col('THRESHOLD', 'round(a.threshold, 2)', 'Threshold', 'NUMBER'),
            Col('UNIT', unit_label('a.unit'), 'Unit'), Col('MESSAGE', 'a.message', 'Message')]


@dataclass
class Report:
    """Classic report; badges=True renders the single row as a UT Badge List."""
    title: str
    cols: list
    source: str
    badges: bool = False
    badge_options: str = '#DEFAULT#:t-BadgeList--medium:t-BadgeList--dash:t-BadgeList--flex'
    span: int = 12
    no_data: str = 'No rows in the current scope.'
    must: bool = False

    def sql(self):
        return with_ctes(f"select {', '.join(f'{c.expr} {c.alias}' for c in self.cols)}\n{self.source}")


@dataclass
class IR(Report):
    sort: tuple = ()


@dataclass
class Series:
    name: str
    sql: str
    type: str = 'line'
    label: str = 'TS'
    value: str = 'VALUE'
    name_col: str = None
    color: str = None
    style: str = 'solid'
    width: int = None
    marker: str = 'off'
    line_type: str = 'straight'
    stack: str = None
    must: bool = False
    gantt: dict = None


@dataclass
class Chart:
    title: str
    type: str
    series: list
    y_title: str = None
    height: int = 360
    span: int = 12
    time: str = 'mixedFrequency'
    horizontal: bool = False
    stack: bool = False
    y_max: float = None
    sorting: str = None
    no_data: str = 'No data in the current scope.'


@dataclass
class Item:
    name: str
    label: str
    type: str  # select | date
    lov: str = None
    null_text: str = None
    null_value: str = None
    pages: tuple = None  # None: every page with filters (FILTER_PAGES)


@dataclass
class Page:
    id: int
    name: str
    alias: str
    icon: str
    regions: list = field(default_factory=list)
    css: str = None


def scaled(expr, scale):
    return f'round({expr} / {scale}, 2)' if scale else f'round({expr}, 2)'


def forecast_band(kind, pred, scale=None, per_db=False):
    """REGR forecast (dashed) and its lo/hi band (dotted); horizon 0 is the current value."""
    out = []
    for title, expr, style, width, color in (
            ('Forecast', 'f.value', 'dashed', 2, None),
            ('Forecast low', 'nvl(f.lo, f.value)', 'dotted', 1, GREY),
            ('Forecast high', 'nvl(f.hi, f.value)', 'dotted', 1, GREY)):
        name = f", f.db || ' {title.lower()}' name" if per_db else ''
        out.append(Series(title, f"select f.ts, {scaled(expr, scale)} value{name} from c_fcst f "
                                 f"where f.kind = '{kind}' and f.method = 'REGR' and {pred} and {in_range('f.ts')} "
                                 "order by f.ts",
                          name_col='NAME' if per_db else None, style=style, width=width, color=color))
    return out


def limit_line(title, value_sql, color=GREY, name_expr=None):
    """A constant reference line across the filter range."""
    name = f', {name_expr} name' if name_expr else ''
    return Series(title, f'select e.ts, l.value{name} from ({value_sql}) l cross join {RANGE_EDGES} e '
                         'where e.ts is not null and l.value is not null order by e.ts',
                  name_col='NAME' if name_expr else None, color=color, style='dashed', width=2)


def markers(title, sql, color=RED):
    return Series(title, sql, color=color, marker='on', line_type='none')


ITEMS = [
    Item('P0_TARGET', 'Target', 'select',
         lov='select c.target_name d, c.target_name r from c_cont c where c.target_name is not null '
             'group by c.target_name order by 1',
         null_text='All targets'),
    Item('P0_DB', 'Database', 'select',
         lov='select c.db_pdb d, c.db_pdb r from c_cont c '
             'where (:P0_TARGET is null or c.target_name = :P0_TARGET) group by c.db_pdb order by 1',
         null_text='All databases'),
    Item('P0_TBSPC', 'Tablespace', 'select',
         lov="select f.series || case when :P0_DB is null then ' (' || f.db || ')' end d, "
             f"{tbspc_key('f')} r from c_fit f "
             f"where f.kind = 'TBSPC' and {in_db('f.db')} order by 1",
         null_text='All tablespaces (observed only)', null_value='ALL', pages=(P_TBSPC,)),
    Item('P0_FROM', 'From', 'date'),
    Item('P0_TO', 'To', 'date'),
    Item('P0_KIND', 'Anomaly kind', 'select',
         lov='select a.anomaly_kind d, a.anomaly_kind r from c_anom a group by a.anomaly_kind order by 1',
         null_text='All kinds', pages=(P_ANOM,)),
    Item('P0_SEV', 'Severity', 'select',
         lov='select a.sev d, a.sev r from c_anom a group by a.sev order by min(a.sev_rank)',
         null_text='All severities', pages=(P_ANOM,)),
]
DATA_BADGES = Report('Data', badges=True, cols=[
    Col('DATABASES', f"(select count(distinct s.db) from c_series s where {in_db('s.db')})", 'Databases', 'NUMBER'),
    Col('LATEST', f"(select to_char(max(s.ts), 'YYYY-MM-DD') from c_series s where {in_db('s.db')})",
        'Latest observation'),
    Col('STALEST', "(select to_char(min(l.ts), 'YYYY-MM-DD') from (select max(s.ts) ts from c_series s "
                   f"where {in_db('s.db')} group by s.db) l)", 'Stalest database'),
    Col('LOADED', "(select to_char(m.loaded_at, 'HH24:MI') from c_meta m)", 'Loaded at'),
], source='from dual', span=4, no_data='No AWR data loaded.',
   badge_options='#DEFAULT#:t-BadgeList--small:t-BadgeList--dash:t-BadgeList--cols t-BadgeList--4cols')

OVERVIEW = Page(P_OVERVIEW, 'Overview', 'OVERVIEW', 'fa-home', [
    Report('Summary', badges=True, cols=[
        Col('CRIT', f"(select count(*) from c_alert a where a.severity = 'CRIT' and {in_db('a.db_pdb')})",
            'Critical alerts', 'NUMBER'),
        Col('WARN', f"(select count(*) from c_alert a where a.severity = 'WARN' and {in_db('a.db_pdb')})",
            'Warnings', 'NUMBER'),
        Col('INFO', f"(select count(*) from c_alert a where a.severity = 'INFO' and {in_db('a.db_pdb')})",
            'Info alerts', 'NUMBER'),
        Col('DTF', "(select nvl(to_char(min(f.days_to_full)), '-') from c_fit f "
                   f"where f.kind = 'TBSPC' and {in_db('f.db')})", 'Worst days to full'),
        Col('ANOM', "(select count(*) from c_anom a, c_meta m where nvl(a.obs_day, a.ts) > "
                    f"(select max(s.ts) from c_series s) - m.anomaly_report_days and {in_db('a.db')})",
            'Recent anomalies', 'NUMBER'),
        Col('DB_GIB', "(select round(sum(s.value), 1) from c_series s where s.kind = 'SERIES' "
                      f"and s.series = 'DB_SIZE_GB' and {in_db('s.db')} and s.ts = (select max(x.ts) "
                      "from c_series x where x.kind = 'SERIES' and x.series = 'DB_SIZE_GB' and x.db = s.db))",
            'Database size (GiB)', 'NUMBER'),
    ], source='from dual'),
    IR('Current alerts', must=True, sort=(('SEV_RANK', 'ASC'), ('DAY', 'DESC')), cols=alert_cols(),
       source=f"from c_alert a where {in_db('a.db_pdb')}", no_data='No current alerts in scope.'),
    Report('Worst days to full', span=6, cols=[
        Col('TARGET', target_of('f.db'), 'Target'),
        Col('DB', 'f.db', 'Database'),
        *link_cols('TABLESPACE', 'f.series', 'Tablespace',
                   url(P_TBSPC, 'P0_DB,P0_TBSPC', f"f.db || ',' || {tbspc_key('f')}")),
        *sev_cols('f.sev'),
        Col('USED_PCT', 'round(f.pct, 1)', 'Used %', 'NUMBER'),
        Col('DTF', 'f.days_to_full', 'Days to full', 'NUMBER'),
    ], source=f"from c_fit f where f.kind = 'TBSPC' and {in_db('f.db')}\n"
              "order by f.days_to_full nulls last, f.pct desc nulls last fetch first 10 rows only"),
    Chart('Tablespace used %', 'bar', horizontal=True, stack=True, span=6, time=None, y_max=100, sorting='value-desc',
          y_title='% of ceiling', series=[
              Series(label, f"select {db_label('f.db', 'f.series')} label, round(f.pct, 1) value from c_fit f "
                            f"where f.kind = 'TBSPC' and f.sev {cond} and {in_db('f.db')} order by f.pct desc",
                     type='bar', label='LABEL', color=color, stack='used')
              for label, cond, color in (('Critical', "= 'CRIT'", RED), ('Warning', "= 'WARN'", AMBER),
                                         ('OK', "not in ('CRIT', 'WARN')", BLUE))]),
])

TABLESPACES = Page(P_TBSPC, 'Tablespaces', 'TABLESPACES', 'fa-database', [
    Report('Tablespace summary', badges=True, cols=[
        Col('CRIT', f"(select count(*) from c_fit f where f.kind = 'TBSPC' and f.sev = 'CRIT' and {in_db('f.db')})",
            'Critical tablespaces', 'NUMBER'),
        Col('WARN', f"(select count(*) from c_fit f where f.kind = 'TBSPC' and f.sev = 'WARN' and {in_db('f.db')})",
            'Warning tablespaces', 'NUMBER'),
        Col('ANOM', f"(select count(*) from c_anom a where a.kind = 'TBSPC' and {in_db('a.db')} "
                    f"and {in_range('a.ts')})", 'Growth anomalies in range', 'NUMBER'),
        Col('DTF', "(select nvl(to_char(min(f.days_to_full)), '-') from c_fit f "
                   f"where f.kind = 'TBSPC' and {in_db('f.db')})", 'Worst days to full'),
    ], source='from dual'),
    IR('Days to full', sort=(('DTF', 'ASC'), ('USED_PCT', 'DESC')), cols=[
        Col('TARGET', target_of('f.db'), 'Target'),
        Col('DB', 'f.db', 'Database'),
        *link_cols('TABLESPACE', 'f.series', 'Tablespace', url(P_TBSPC, 'P0_TBSPC', tbspc_key('f'))),
        *sev_cols('f.sev'),
        Col('USED_PCT', 'round(f.pct, 1)', 'Used %', 'NUMBER'),
        Col('USED_GIB', scaled('f.value', GIB), 'Used GiB', 'NUMBER'),
        Col('CEILING_GIB', scaled('f.limit_value', GIB), 'Ceiling GiB', 'NUMBER'),
        Col('GROWTH_MIB', f'round(f.slope_per_day / {MIB}, 1)', 'Growth MiB/day', 'NUMBER'),
        Col('DTF', 'f.days_to_full', 'Days to full', 'NUMBER'),
        Col('DTF_LO', 'f.days_to_full_lo', 'DTF low', 'NUMBER'),
        Col('DTF_HI', 'f.days_to_full_hi', 'DTF high', 'NUMBER'),
        Col('R2', 'round(f.r2, 3)', 'R2', 'NUMBER'),
        Col('QUALITY', 'f.quality', 'Quality'),
        Col('LIMIT_SOURCE', 'f.limit_source', 'Ceiling source'),
    ], source=f"from c_fit f where f.kind = 'TBSPC' and {in_db('f.db')}"),
    Chart('Used space', 'line', y_title='GiB', height=420,
          no_data='No tablespace in scope. Pick a database or a tablespace in the filters.', series=[
              Series('Used', f"select s.ts, {scaled('s.value', GIB)} value, case when :P0_TBSPC = 'ALL' then "
                             f"{db_label('s.db', 's.series')} else 'Used GiB' end name from c_series s "
                             f"where s.kind = 'TBSPC' and {tbspc_scope('s')} and {in_range('s.ts')} order by s.ts",
                     name_col='NAME', width=2, must=True),
              *forecast_band('TBSPC', tbspc_selected('f'), GIB),
              limit_line('Ceiling', f"select {scaled('f.limit_value', GIB)} value from c_fit f "
                                    f"where f.kind = 'TBSPC' and {tbspc_selected('f')}"),
              markers('ESM +30', f"select f.ts, {scaled('f.value', GIB)} value from c_fcst f where f.kind = 'TBSPC' "
                                 f"and f.method = 'ESM' and {tbspc_selected('f')} and {in_range('f.ts')}",
                      color=GREEN),
              markers('Anomaly', f"select s.ts, {scaled('s.value', GIB)} value from c_series s where s.kind = 'TBSPC' "
                                 f"and s.anomaly = 1 and {tbspc_scope('s')} and {in_range('s.ts')} order by s.ts"),
          ]),
    Chart('Daily growth', 'combo', y_title='MiB/day', time='enabled', stack=True,
          no_data='Pick a single tablespace to see its daily growth.', series=[
              Series('Growth', f"select s.ts, round(s.rate_bpd / {MIB}, 1) value from c_series s "
                               f"where s.kind = 'TBSPC' and {tbspc_selected('s')} and nvl(s.anomaly, 0) = 0 "
                               f"and {in_range('s.ts')} order by s.ts",
                     type='bar', color=BLUE, stack='growth'),
              Series('Anomalous growth', f"select s.ts, round(s.rate_bpd / {MIB}, 1) value from c_series s "
                                         f"where s.kind = 'TBSPC' and {tbspc_selected('s')} and s.anomaly = 1 "
                                         f"and {in_range('s.ts')} order by s.ts",
                     type='bar', color=RED, stack='growth'),
              Series('Median rate', f"select s.ts, round(s.expected / {MIB}, 1) value from c_series s "
                                    f"where s.kind = 'TBSPC' and {tbspc_selected('s')} and {in_range('s.ts')} "
                                    "order by s.ts", color=GREY, width=2),
          ]),
    IR('Growth anomalies', sort=(('DAY', 'DESC'),), cols=[
        Col('DAY', 'a.ts', 'Day', 'DATE'),
        Col('TARGET', target_of('a.db'), 'Target'),
        Col('DB', 'a.db', 'Database'),
        *link_cols('TABLESPACE', 'a.series', 'Tablespace', url(P_TBSPC, 'P0_TBSPC', tbspc_key('a'))),
        Col('ANOMALY_KIND', 'a.anomaly_kind', 'Kind'),
        *sev_cols('a.sev'),
        Col('GROWTH_GIB', scaled('a.value', GIB), 'Growth GiB', 'NUMBER'),
        Col('RATE_MIB', f'round(a.rate_bpd / {MIB}, 1)', 'Rate MiB/day', 'NUMBER'),
        Col('MEDIAN_MIB', f'round(a.expected / {MIB}, 1)', 'Median MiB/day', 'NUMBER'),
        Col('THRESHOLD_MIB', f'round(a.threshold / {MIB}, 1)', 'Threshold MiB', 'NUMBER'),
        Col('Z', 'round(a.z, 1)', 'z', 'NUMBER'),
        Col('FLAG', 'a.anomaly_flag', 'Flag'),
        Col('MESSAGE', 'a.message', 'Message'),
    ], source=f"from c_anom a where a.kind = 'TBSPC' and {in_db('a.db')} and {in_range('a.ts')}",
       no_data='No tablespace anomalies in the date range.'),
    Report('Tablespace alerts', cols=alert_cols('Tablespace'), no_data='No tablespace alerts in scope.',
           source=f"from c_alert a where a.kind like 'TBSPC%' and {in_db('a.db_pdb')}\n{ALERT_ORDER}"),
])

def series_chart(key, title, y_title, scope=in_db):
    """One CAPD_SERIES_DAILY series: observed, REGR forecast with its band, and the limit when it has one."""
    return Chart(title, 'line', span=6, height=300, y_title=y_title, series=[
        Series('Observed', f"select s.ts, round(s.value, 2) value, s.db name from c_series s where s.kind = 'SERIES' "
                           f"and s.series = '{key}' and {scope('s.db')} and {in_range('s.ts')} order by s.ts",
               name_col='NAME', width=2),
        *forecast_band('SERIES', f"f.series = '{key}' and {scope('f.db')}", per_db=True),
        limit_line('Limit', f"select f.limit_value value, f.db from c_fit f where f.kind = 'SERIES' "
                            f"and f.series = '{key}' and {scope('f.db')}", name_expr="l.db || ' limit'"),
    ])


# series key, chart title, y axis.  IOPS / IO_MBPS (M27) have no limit: their limit line stays empty.
WORKLOAD = (('SESSIONS', 'Sessions', 'sessions'), ('PROCESSES', 'Processes', 'processes'),
            ('DB_SIZE_GB', 'Database size (GiB)', 'GiB'), ('REDO_GB_DAY', 'Redo (GiB/day)', 'GiB/day'),
            ('IOPS', 'I/O requests per second (daily p95)', 'requests/s'),
            ('IO_MBPS', 'I/O throughput MB/s (daily p95)', 'MB/s'))
CPU = Page(P_CPU, 'CPU and workload', 'CPU', 'fa-area-chart', [
    Chart('Host CPU busy %', 'line', y_title='% busy', y_max=100, height=400,
          no_data='No host CPU in scope. Host CPU (OSSTAT) is recorded under the CDB root container; '
                  'select the CDB, one of its PDBs, or all databases.', series=[
              Series('Busy %', "select s.ts, round(s.value, 1) value, s.db || ' busy %' name from c_series s "
                               f"where s.kind = 'CPU' and s.series = 'BUSY_PCT' and {host_scope('s.db')} "
                               f"and {in_range('s.ts')} order by s.ts", name_col='NAME', width=2, must=True),
              Series('Busy-hour p95', "select s.ts, round(s.busy_p95, 1) value, s.db || ' busy-hour p95' name "
                                      "from c_series s where s.kind = 'CPU' and s.series = 'BUSY_PCT' "
                                      f"and {host_scope('s.db')} and {in_range('s.ts')} order by s.ts",
                     name_col='NAME'),
              *forecast_band('CPU', f"f.series = 'BUSY_P95' and {host_scope('f.db')}", per_db=True),
              limit_line('Saturation', 'select m.cpu_sat_pct value from c_meta m', color=RED),
              markers('Anomaly', "select s.ts, round(s.value, 1) value from c_series s where s.kind = 'CPU' "
                                 f"and s.series = 'BUSY_PCT' and s.anomaly = 1 and {host_scope('s.db')} "
                                 f"and {in_range('s.ts')} order by s.ts"),
          ]),
    Chart('DB CPU % of host per container', 'line', y_title='% of host CPU', series=[
        Series('DB CPU %', "select s.ts, round(s.value, 1) value, s.db name from c_series s where s.kind = 'CPU' "
                           f"and s.series = 'DB_CPU_PCT' and {in_db('s.db')} and {in_range('s.ts')} order by s.ts",
               name_col='NAME', width=2),
        Series('Level shift', "select case k.n when 1 then a.ts else a.obs_day end ts, round(a.value, 1) value, "
                              "'Level shift ' || a.db || ' from ' || to_char(a.ts, 'YYYY-MM-DD') name "
                              "from c_anom a cross join (select 1 n from dual union all select 2 n from dual) k "
                              f"where a.anomaly_kind = 'CPU_SHIFT' and {in_db('a.db')} and {in_range('a.obs_day')} "
                              "order by 3, 1", name_col='NAME', color=RED, width=5),
    ]),
    IR('CPU trend', sort=(('DTS', 'ASC'),), cols=[
        Col('TARGET', target_of('f.db'), 'Target'),
        Col('DB', 'f.db', 'Database'),
        Col('METRIC', 'f.series', 'Metric'),
        *sev_cols('f.sev'),
        Col('CURRENT_VALUE', 'round(f.value, 1)', 'Current', 'NUMBER'),
        Col('UNIT', unit_label('f.unit'), 'Unit'),
        Col('SLOPE', 'round(f.slope_per_day, 3)', 'Slope/day', 'NUMBER'),
        Col('DTS', 'f.days_to_full', 'Days to saturation', 'NUMBER'),
        Col('DTS_LO', 'f.days_to_full_lo', 'Low', 'NUMBER'),
        Col('DTS_HI', 'f.days_to_full_hi', 'High', 'NUMBER'),
        Col('R2', 'round(f.r2, 3)', 'R2', 'NUMBER'),
        Col('QUALITY', 'f.quality', 'Quality'),
    ], source=f"from c_fit f where f.kind = 'CPU' and (f.series in {HOST_SERIES} and {host_scope('f.db')} "
              f"or f.series not in {HOST_SERIES} and {in_db('f.db')})"),
    *[series_chart(key, title, y_title) for key, title, y_title in WORKLOAD],
    IR('Workload fits', sort=(('DTL', 'ASC'),), cols=[
        Col('TARGET', target_of('f.db'), 'Target'),
        Col('DB', 'f.db', 'Database'),
        Col('SERIES', 'f.series', 'Series'),
        *sev_cols('f.sev'),
        Col('CURRENT_VALUE', 'round(f.value, 2)', 'Current', 'NUMBER'),
        Col('UNIT', unit_label('f.unit'), 'Unit'),
        Col('LIMIT_VALUE', 'round(f.limit_value, 2)', 'Limit', 'NUMBER'),
        Col('PCT', 'round(f.pct, 1)', '% of limit', 'NUMBER'),
        Col('DTL', 'f.days_to_full', 'Days to limit', 'NUMBER'),
        Col('SLOPE', 'round(f.slope_per_day, 3)', 'Slope/day', 'NUMBER'),
        Col('R2', 'round(f.r2, 3)', 'R2', 'NUMBER'),
        Col('QUALITY', 'f.quality', 'Quality'),
    ], source=f"from c_fit f where f.kind = 'SERIES' and {in_db('f.db')}"),
    Report('CPU and series alerts', cols=alert_cols(), no_data='No CPU or workload alerts in scope.',
           source="from c_alert a where a.kind not like 'TBSPC%' "
                  f"and ({in_db('a.db_pdb')} or {host_scope('a.db_pdb')})\n{ALERT_ORDER}"),
])

# The gantt colours tasks by a css class per anomaly kind; unknown kinds keep the JET default.
KIND_CSS = '\n'.join(f'.oj-gantt .awrcap-kind-{k} {{ fill: {c} !important; }}'
                     for k, c in (('TBSPC_GROWTH', RED), ('CPU_BUSY', AMBER), ('CPU_SHIFT', BLUE)))
ANOMALY_PAGE = f"case a.kind when 'TBSPC' then {P_TBSPC} else {P_CPU} end"
ANOMALIES = Page(P_ANOM, 'Fleet anomalies', 'ANOMALIES', 'fa-warning', [
    Report('Anomaly summary', badges=True, cols=[
        Col('ANOMALIES', f"(select count(*) from c_anom a where {anom_scope('a')})", 'Anomalies in range', 'NUMBER'),
        Col('DATABASES', f"(select count(distinct a.db) from c_anom a where {anom_scope('a')})",
            'Databases affected', 'NUMBER'),
        Col('SERIES', f"(select count(distinct a.db || '|' || a.series) from c_anom a where {anom_scope('a')})",
            'Series affected', 'NUMBER'),
        Col('SERIOUS', f"(select count(*) from c_anom a where a.sev in ('WARN', 'CRIT') and {anom_scope('a')})",
            'Warning or critical', 'NUMBER'),
    ], source='from dual'),
    Chart('Anomalies per day by kind', 'bar', span=6, height=320, time='enabled', stack=True, y_title='Anomalies',
          series=[Series('Anomalies', f"select a.ts, count(*) value, a.anomaly_kind name from c_anom a "
                                      f"where {anom_scope('a')} group by a.ts, a.anomaly_kind order by a.ts",
                         type='bar', name_col='NAME', stack='kind', must=True)]),
    Chart('Most anomalous series', 'bar', span=6, height=320, time=None, horizontal=True, y_title='Anomalies',
          series=[Series('Anomalies', "select a.db || ' ' || a.series label, count(*) value from c_anom a "
                                      f"where {anom_scope('a')} group by a.db, a.series "
                                      "order by count(*) desc, 1 fetch first 10 rows only",
                         type='bar', label='LABEL', color=RED)]),
    Chart('Anomaly timeline', 'gantt', height=480, time=None, series=[
        Series('Anomalies', "select e.db || ' ' || e.series || ': ' || e.anomaly_kind || case when e.n > 1 then "
                            "' (' || e.n || ' days)' end task_name, e.db || '|' || e.series || '|' || e.anomaly_kind "
                            "|| '|' || to_char(e.start_date, 'YYYYMMDD') task_id, e.start_date, e.end_date, "
                            f"e.anomaly_kind kind, nvl({D_FROM}, min(e.start_date) over ()) gantt_start, "
                            f"nvl({D_TO}, max(e.end_date) over ()) gantt_end\n"
                            "from (select a.db, a.series, a.anomaly_kind, min(a.ts) start_date, "
                            "max(nvl(a.obs_day, a.ts)) + 1 end_date, count(*) n from (select a.*, a.ts - dense_rank() "
                            "over (partition by a.db, a.series, a.anomaly_kind order by a.ts) grp from c_anom a "
                            f"where {anom_scope('a')}) a group by a.db, a.series, a.anomaly_kind, a.grp) e\n"
                            "order by e.db, e.series, e.start_date",
               type='gantt', gantt=dict(
                   p_gantt_start_date_source='DB_COLUMN', p_gantt_start_date_column='GANTT_START',
                   p_gantt_end_date_source='DB_COLUMN', p_gantt_end_date_column='GANTT_END',
                   p_gantt_task_id='TASK_ID', p_gantt_task_name='TASK_NAME',
                   p_gantt_task_start_date='START_DATE', p_gantt_task_end_date='END_DATE',
                   p_gantt_task_css_class='awrcap-kind-&KIND.', p_task_label_position='none'))]),
    IR('Anomalies', must=True, sort=(('DAY', 'DESC'), ('DB', 'ASC')), cols=[
        Col('DAY', 'a.ts', 'Day', 'DATE'),
        Col('END_DAY', 'a.obs_day', 'Observed until', 'DATE'),
        Col('TARGET', target_of('a.db'), 'Target'),
        *link_cols('DB', 'a.db', 'Database', url(ANOMALY_PAGE, 'P0_DB', 'a.db')),
        *link_cols('SERIES', 'a.series', 'Series',
                   url(ANOMALY_PAGE, 'P0_DB,P0_TBSPC',
                       f"a.db || ',' || case when a.kind = 'TBSPC' then {tbspc_key('a')} end")),
        Col('ANOMALY_KIND', 'a.anomaly_kind', 'Kind'),
        *sev_cols('a.sev'),
        Col('FLAG', 'a.anomaly_flag', 'Flag'),
        Col('VALUE', 'round(a.value, 2)', 'Value', 'NUMBER'),
        Col('EXPECTED', 'round(a.expected, 2)', 'Expected', 'NUMBER'),
        Col('THRESHOLD', 'round(a.threshold, 2)', 'Threshold', 'NUMBER'),
        Col('Z', 'round(a.z, 1)', 'z', 'NUMBER'),
        Col('SHIFT_PCT', 'round(a.shift_pct, 1)', 'Shift', 'NUMBER'),
        Col('UNIT', unit_label('a.unit'), 'Unit'),
        Col('MESSAGE', 'a.message', 'Message'),
    ], source=f"from c_anom a where {anom_scope('a')}", no_data='No anomalies match the filters.'),
    Report('All alerts', cols=alert_cols(), no_data='No alerts match the filters.',
           source=f"from c_alert a where {in_db('a.db_pdb')} "
                  f"and (:P0_SEV is null or a.severity = :P0_SEV)\n{ALERT_ORDER}"),
], css=KIND_CSS)

MINUTE = "'YYYY-MM-DD HH24:MI'"
COLLECT_CSS = {'FAILING': 't-Badge--danger', 'NEVER': 't-Badge--warning', 'DISABLED': 't-Badge--info',
               'OK': 't-Badge--success'}


def target_dbs(t):
    """The db_pdb labels of one CAPR_TARGETS row: a target and one of its DBIDs."""
    return f'(select c.db_pdb from c_cont c where c.dbid = {t}.dbid)'


# The fleet page lists every target whatever the filters say: it is where a target is picked.
TARGETS = Page(P_TARGETS, 'Targets', 'TARGETS', 'fa-server', [
    Report('Fleet summary', badges=True, cols=[
        Col('TARGETS', '(select count(distinct t.target_name) from c_tgt t)', 'Targets', 'NUMBER'),
        Col('CONTAINERS', '(select count(*) from c_cont c)', 'Containers', 'NUMBER'),
        Col('STALE', "(select count(*) from c_tgt t where t.is_stale = 'Y')", 'Stale', 'NUMBER'),
        Col('FAILING', "(select count(*) from c_tgt t where t.collect_state in ('FAILING', 'NEVER'))",
            'Collect failing', 'NUMBER'),
        Col('CRIT', "(select count(*) from c_alert a where a.severity = 'CRIT')", 'Critical alerts', 'NUMBER'),
    ], source='from dual'),
    IR('Targets', must=True, sort=(('TARGET', 'ASC'), ('DBID', 'ASC')), cols=[
        *link_cols('TARGET', 't.target_name', 'Target',
                   url(P_OVERVIEW, 'P0_TARGET,P0_DB,P0_TBSPC', "t.target_name || ',,'")),
        Col('DBID', 'to_char(t.dbid)', 'DBID'),
        Col('DB_NAME', 't.db_name', 'Database'),
        Col('HOST_NAME', 't.host_name', 'Host'),
        Col('FEED', 't.feed', 'Feed'),
        Col('CONTAINERS', 't.n_containers', 'Containers', 'NUMBER'),
        Col('NEWEST_SNAP', f'to_char(t.newest_snap, {MINUTE})', 'Newest snapshot'),
        Col('AGE_HOURS', 'round(t.age_hours, 1)', 'Age (hours)', 'NUMBER'),
        *badge_cols('FRESHNESS', "case t.is_stale when 'Y' then 'STALE' when 'N' then 'FRESH' end", 'Freshness',
                    case_of('t.is_stale', {'Y': 't-Badge--warning', 'N': 't-Badge--success'})),
        *badge_cols('COLLECT_STATE', 't.collect_state', 'Collect', case_of('t.collect_state', COLLECT_CSS)),
        Col('CRIT', f"(select count(*) from c_alert a where a.severity = 'CRIT' and a.db_pdb in {target_dbs('t')})",
            'Critical alerts', 'NUMBER'),
        Col('WARN', f"(select count(*) from c_alert a where a.severity = 'WARN' and a.db_pdb in {target_dbs('t')})",
            'Warnings', 'NUMBER'),
        Col('DTF', f"(select min(f.days_to_full) from c_fit f where f.kind = 'TBSPC' and f.db in {target_dbs('t')})",
            'Worst days to full', 'NUMBER'),
        Col('LAST_OK', f'to_char(t.last_ok_at, {MINUTE})', 'Last collect'),
        Col('LAST_ERROR_AT', f'to_char(t.last_error_at, {MINUTE})', 'Last error at'),
        Col('LAST_ERROR', 't.last_error', 'Last error'),
        Col('GAPS', 't.n_gaps', 'Gaps', 'NUMBER'),
        Col('DB_LINK', 't.db_link', 'DB link'),
        Col('ENABLED', 't.enabled', 'Enabled'),
    ], source='from c_tgt t', no_data='No target is registered.'),
    Chart('Hours since the newest snapshot', 'bar', horizontal=True, stack=True, time=None, sorting='value-desc',
          y_title='hours', height=320, series=[
              Series(label, "select t.target_name || case when t.db_name <> t.target_name then ' ' || t.db_name end "
                            f"label, round(t.age_hours, 1) value from c_tgt t where t.is_stale = '{flag}' "
                            "order by t.age_hours desc", type='bar', label='LABEL', color=color, stack='age')
              for label, flag, color in (('Stale', 'Y', RED), ('Fresh', 'N', BLUE))]),
])

GRADE_CSS = {'UNDERSIZED': 't-Badge--warning', 'THRASHING': 't-Badge--warning', 'OVERSIZED': 't-Badge--info',
             'DRIFTING': 't-Badge--info', 'OK': 't-Badge--success'}
DIRECTION_CSS = {'PRESSURE': 't-Badge--warning', 'SLACK': 't-Badge--info'}
MEM_NONE = ('No memory verdict in scope. The verdicts are instance level: select the CDB, one of its PDBs, '
            'or all databases.')
# Report content only: the verdicts enter no alert count (CAPR_MEM_* feed no alert).
MEMORY = Page(P_MEMORY, 'Memory sizing', 'MEMORY', 'fa-microchip', [
    Report('Memory summary', badges=True, cols=[
        Col('AREAS', f"(select count(*) from c_memv m where {host_scope('m.db_pdb')})", 'Areas graded', 'NUMBER'),
        Col('ACTIONABLE', f"(select count(*) from c_memv m where m.actionable = 'Y' and {host_scope('m.db_pdb')})",
            'Need a change', 'NUMBER'),
        Col('UNDERSIZED', f"(select count(*) from c_memv m where m.grade = 'UNDERSIZED' "
                          f"and {host_scope('m.db_pdb')})", 'Undersized', 'NUMBER'),
        Col('OVERSIZED', f"(select count(*) from c_memv m where m.grade = 'OVERSIZED' "
                         f"and {host_scope('m.db_pdb')})", 'Oversized', 'NUMBER'),
        Col('PRESSURE', f"(select count(*) from c_meme e where e.direction = 'PRESSURE' "
                        f"and {host_scope('e.db_pdb')})", 'Pressure signals', 'NUMBER'),
    ], source='from dual'),
    IR('Memory verdicts', must=True, sort=(('DB', 'ASC'), ('RANK_MEM', 'ASC')), cols=[
        Col('TARGET', target_of('m.db_pdb'), 'Target'),
        Col('DB', 'm.db_pdb', 'Database'),
        Col('INST', 'm.instance_number', 'Instance', 'NUMBER'),
        Col('AREA', 'm.area_label', 'Area'),
        *badge_cols('GRADE', 'm.grade', 'Grade', case_of('m.grade', GRADE_CSS)),
        Col('CURRENT_SIZE', 'm.current_size', 'Current size'),
        Col('SUGGESTED_SIZE', 'm.suggested_size', 'Suggested size'),
        Col('CHANGE_PCT', 'm.change_pct', 'Change %', 'NUMBER'),
        Col('PARAM', 'm.suggested_param', 'Parameter'),
        Col('HEADLINE', 'm.headline', 'Headline'),
        Col('REASON', 'm.reason_text', 'Reason'),
        Col('FLAGS', "trim(case when m.exceeds_host_ram = 'Y' then 'exceeds host RAM ' end || "
                     "case when m.exceeds_sga = 'Y' then 'exceeds sga_target' end)", 'Flags'),
        Col('MEM_MODE', 'm.mem_mode', 'Memory mode'),
        Col('SIGNALS', 'm.n_evidence', 'Signals', 'NUMBER'),
        Col('PRESSURE', 'm.n_pressure', 'Pressure signals', 'NUMBER'),
        Col('DAYS_SAMPLED', 'm.n_days', 'Days sampled', 'NUMBER'),
        Col('WINDOW_START', 'm.window_start', 'Window from', 'DATE'),
        Col('WINDOW_END', 'm.window_end', 'Window to', 'DATE'),
        Col('RANK_MEM', 'm.rank_mem'),
    ], source=f"from c_memv m where {host_scope('m.db_pdb')}", no_data=MEM_NONE),
    Chart('SGA components', 'line', span=6, height=300, y_title='GiB',
          no_data='No SGA component history in scope.', series=[
              Series('Component', f"select p.ts, round(p.bytes / {GIB}, 2) value, "
                                  f"{db_label('p.db_pdb', 'p.component')} || case when p.instance_number > 1 "
                                  "then ' #' || p.instance_number end name from c_memp p "
                                  f"where {host_scope('p.db_pdb')} and {in_range('p.ts')} order by p.ts",
                     name_col='NAME', width=2, must=True)]),
    series_chart('PGA_ALLOC_GB', 'PGA allocated (GiB)', 'GiB', scope=host_scope),
    IR('Memory evidence', sort=(('DB', 'ASC'), ('RANK_EV', 'ASC')), cols=[
        Col('TARGET', target_of('e.db_pdb'), 'Target'),
        Col('DB', 'e.db_pdb', 'Database'),
        Col('INST', 'e.instance_number', 'Instance', 'NUMBER'),
        Col('AREA', 'e.area_label', 'Area'),
        Col('KIND', 'e.kind', 'Kind'),
        Col('SIGNAL', 'e.signal', 'Signal'),
        *badge_cols('DIRECTION', 'e.direction', 'Direction', case_of('e.direction', DIRECTION_CSS)),
        Col('VALUE', 'round(e.value, 2)', 'Value', 'NUMBER'),
        Col('UNIT', 'e.unit', 'Unit'),
        Col('THRESHOLD', 'round(e.threshold, 2)', 'Threshold', 'NUMBER'),
        Col('OBSERVED', f'to_char(e.observed_at, {MINUTE})', 'Observed'),
        Col('EVIDENCE', 'e.evidence_text', 'Evidence'),
        Col('RANK_EV', 'e.rank_ev'),
    ], source=f"from c_meme e where {host_scope('e.db_pdb')}", no_data='No memory evidence in scope.'),
])

# Navigation order.  Page ids are part of every URL: a new page takes a new id, never a used one.
PAGES = [OVERVIEW, TARGETS, TABLESPACES, CPU, MEMORY, ANOMALIES]
CONTENT_PAGES = tuple(p.id for p in PAGES)
FILTER_PAGES = tuple(i for i in CONTENT_PAGES if i != P_TARGETS)
LOGIN_PAGE = 9999


def item_pages(it):
    return it.pages or FILTER_PAGES


@dataclass
class Default:
    """After the load: where cond holds, set item to the one value of query (its binds are the items)."""
    pages: tuple
    item: str
    cond: str  # PL/SQL over v('P0_..')
    query: str


def page_logic():
    """Defaults that need the loaded collections, in order."""
    key = tbspc_key('f')
    last_day = "select to_char(max(s.ts) {} {}, 'YYYY-MM-DD') val from c_series s"
    return [
        # A database left over from another target is dropped.
        Default(CONTENT_PAGES, 'P0_DB', "v('P0_TARGET') is not null and v('P0_DB') is not null",
                'select max(c.db_pdb) val from c_cont c where c.db_pdb = :P0_DB and c.target_name = :P0_TARGET'),
        Default(CONTENT_PAGES, 'P0_FROM', "v('P0_FROM') is null", last_day.format('-', RANGE_PAD_DAYS)),
        Default(CONTENT_PAGES, 'P0_TO', "v('P0_TO') is null", last_day.format('+', RANGE_PAD_DAYS)),
        # The selected tablespace while it is in scope, else the one with the fewest days to full.
        Default((P_TBSPC,), 'P0_TBSPC', "nvl(v('P0_TBSPC'), '-') <> 'ALL'",
                f"select max({key}) keep (dense_rank first order by "
                f"case when {key} = :P0_TBSPC then 0 else 1 end, "
                "f.days_to_full nulls last, f.pct desc nulls last) val\n"
                f"from c_fit f where f.kind = 'TBSPC' and {in_db('f.db')}"),
    ]


def global_texts(page_id):
    """SQL of the page-0 components rendered on page_id."""
    texts = [it.lov for it in ITEMS if it.lov and page_id in item_pages(it)]
    return texts + [DATA_BADGES.sql()]


def region_queries(region):
    if isinstance(region, Chart):
        return [(f'{region.title} / {s.name}', with_ctes(s.sql), s.must) for s in region.series]
    return [(region.title, region.sql(), region.must)]


def page_needs(page):
    text = '\n'.join(global_texts(page.id) + [q for r in page.regions for _, q, _ in region_queries(r)]
                     + [d.query for d in page_logic() if page.id in d.pages])
    return set(needs(text))


def delete_collections():
    return [f"  if apex_collection.collection_exists('{n}') then apex_collection.delete_collection('{n}'); end if;"
            for n in COLLECTIONS]


def refresh_plsql():
    return '\n'.join(['begin'] + delete_collections() + ['end;'])


def loader_plsql(page_expr, request_expr, probe=False):
    """The Before Header process: load what the page reads, then the defaults.
    probe=True gives the same steps over the probe's stand-ins (load, drop_all, set_state
    and pick are procedures of its block, v its session state)."""
    if probe:
        out = ['begin', f"  if {request_expr} = 'REFRESH' then", '    drop_all;', '  end if;']
    else:
        out = ['declare',
               '  procedure load(p_name in varchar2, p_query in varchar2) is',
               '  begin',
               '    if not apex_collection.collection_exists(p_name) then',
               '      apex_collection.create_collection_from_queryb2(',
               "        p_collection_name => p_name, p_query => p_query, p_truncate_if_exists => 'YES');",
               '    end if;',
               '  end;',
               'begin',
               f"  if {request_expr} = 'REFRESH' then"]
        out += ['  ' + line for line in delete_collections()]
        out.append('  end if;')
    page_sets = {p.id: page_needs(p) for p in PAGES}
    for name in COLLECTIONS:
        ids = [str(p) for p, s in page_sets.items() if name in s]
        if ids:
            out += [f"  if {page_expr} in ({', '.join(ids)}) then",
                    f"    load('{name}', q'~{loader_query(name)}~');",
                    '  end if;']
    for d in page_logic():
        out.append(f"  if {page_expr} in ({', '.join(map(str, d.pages))}) and ({d.cond}) then")
        if probe:
            out.append(f"    set_state('{d.item}', pick({plsql_literal(with_ctes(d.query))}));")
        else:
            out += [f'    for r in ({with_ctes(as_v(d.query))}) loop',
                    f"      apex_util.set_session_state('{d.item}', r.val);",
                    '    end loop;']
        out.append('  end if;')
    out.append('end;')
    return '\n'.join(out)


def plsql_literal(text):
    assert '~' not in text
    return "q'~" + text + "~'"


class Raw(str):
    pass


def chunk(s):
    parts = [s[i:i + 200] for i in range(0, len(s), 200)] or ['']
    return '\n||'.join("'" + p.replace("'", "''") + "'" for p in parts)


def literal(value):
    if isinstance(value, Raw):
        return str(value)
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, dict):
        pairs = ',\n'.join(f'  {chunk(k)}, {chunk(str(v))}' for k, v in sorted(value.items()))
        return f'wwv_flow_t_plugin_attributes(wwv_flow_t_varchar2(\n{pairs})).to_clob'
    if '\n' in value:
        return 'wwv_flow_string.join(wwv_flow_t_varchar2(\n' + ',\n'.join(map(chunk, value.split('\n'))) + '))'
    return chunk(value)


def slug(text):
    return re.sub(r'[^a-z0-9]+', '-', text.lower()).strip('-')


class Export:
    def __init__(self):
        self.next_id = ID_BASE
        self.out = []
        self.calls = []

    def id(self):
        self.next_id += 1
        return Raw(f'wwv_flow_imp.id({self.next_id})')

    def call(self, proc, **params):
        args = '\n,'.join(f'{k}=>{literal(v)}' for k, v in params.items() if v is not None)
        self.calls.append(f'{proc}(\n {args}\n);')

    def block(self, prompt):
        self.out.append(f'prompt --application/{prompt}\nbegin\n' + '\n'.join(self.calls) + '\nend;\n/')
        self.calls = []

    def region(self, name, seq, template, source_type, span=12, new_row=True, **extra):
        rid = self.id()
        self.call('wwv_flow_imp_page.create_page_plug', p_id=rid, p_plug_name=name, p_static_id=slug(name),
                  p_region_template_options=extra.pop('options', '#DEFAULT#:t-Region--scrollBody'),
                  p_plug_template=template, p_plug_display_sequence=seq,
                  p_plug_new_grid_row=None if new_row else False,
                  p_plug_grid_column_span=span if span != 12 else None,
                  p_plug_item_display_point='ABOVE', p_plug_source_type=source_type, **extra)
        return rid

    def report(self, rep, seq, new_row=True, **cond):
        badges = rep.badges
        rid = self.id()
        self.call('wwv_flow_imp_page.create_report_region', p_id=rid, p_name=rep.title,
                  p_static_id=slug(rep.title), p_template=TPL['region'], p_display_sequence=seq,
                  p_region_template_options='#DEFAULT#:t-Region--hideHeader js-addHiddenHeadingRoleDesc'
                  if badges else '#DEFAULT#:t-Region--scrollBody',
                  p_component_template_options=rep.badge_options if badges
                  else '#DEFAULT#:t-Report--stretch:t-Report--altRowsDefault:t-Report--rowHighlight',
                  p_new_grid_row=None if new_row else False,
                  p_grid_column_span=rep.span if rep.span != 12 else None,
                  p_source_type='NATIVE_SQL_REPORT', p_query_type='SQL', p_source=rep.sql(),
                  p_ajax_enabled='Y', p_lazy_loading=False,
                  p_query_row_template=TPL['report_badges' if badges else 'report'],
                  p_query_num_rows=1 if badges else 15,
                  p_query_num_rows_type='SHOW_ALL' if badges else 'ROWS_X_TO_Y',
                  p_query_no_data_found=rep.no_data, p_pagination_display_position='BOTTOM_RIGHT',
                  p_csv_output='N', p_prn_output='N', p_sort_null='L', p_plug_query_strip_html='N', **cond)
        for pos, c in enumerate(rep.cols, 1):
            self.call('wwv_flow_imp_page.create_report_columns', p_id=self.id(), p_query_column_id=pos,
                      p_column_alias=c.alias, p_column_display_sequence=pos * 10,
                      p_column_heading=c.heading, p_column_html_expression=c.html,
                      p_column_format='YYYY-MM-DD' if c.kind == 'DATE' else None,
                      p_column_alignment='RIGHT' if c.kind == 'NUMBER' else None,
                      p_heading_alignment='RIGHT' if c.kind == 'NUMBER' else 'LEFT',
                      p_hidden_column='Y' if c.heading is None else None,
                      p_disable_sort_column='Y', p_derived_column='N', p_include_in_export='Y')

    def interactive_report(self, ir, seq, new_row=True):
        rid = self.region(ir.title, seq, TPL['region_ir'], 'NATIVE_IR', ir.span, new_row,
                          options='#DEFAULT#', p_query_type='SQL', p_plug_source=ir.sql(),
                          p_include_rowid_column=False)
        wid = self.id()
        self.call('wwv_flow_imp_page.create_worksheet', p_id=wid, p_max_row_count='100000',
                  p_no_data_found_message=ir.no_data, p_allow_save_rpt_public='Y', p_show_nulls_as='-',
                  p_pagination_type='ROWS_X_TO_Y', p_pagination_display_pos='BOTTOM_RIGHT',
                  p_report_list_mode='TABS', p_lazy_loading=False, p_show_detail_link='N',
                  p_show_notify='N', p_download_formats='CSV:HTML:XLSX', p_enable_mail_download='N',
                  p_internal_uid=Raw(wid[len('wwv_flow_imp.id('):-1]))
        for pos, c in enumerate(ir.cols, 1):
            self.call('wwv_flow_imp_page.create_worksheet_column', p_id=self.id(), p_db_column_name=c.alias,
                      p_display_order=pos * 10, p_column_identifier=column_identifier(pos),
                      p_column_label=c.heading or c.alias, p_column_type=c.kind,
                      p_display_text_as='HIDDEN_ESCAPE_SC' if c.heading is None else None,
                      p_column_html_expression=c.html,
                      p_format_mask='YYYY-MM-DD' if c.kind == 'DATE' else None,
                      p_heading_alignment='RIGHT' if c.kind == 'NUMBER' else 'LEFT',
                      p_column_alignment='RIGHT' if c.kind == 'NUMBER' else None,
                      p_tz_dependent='N' if c.kind == 'DATE' else None,
                      p_use_as_row_header='N', p_available_clientside='N')
        sort = {}
        for i, (col, direction) in enumerate(ir.sort, 1):
            sort[f'p_sort_column_{i}'] = col
            sort[f'p_sort_direction_{i}'] = direction
        self.call('wwv_flow_imp_page.create_worksheet_rpt', p_id=self.id(), p_application_user='APXWS_DEFAULT',
                  p_report_seq=10, p_report_alias=slug(ir.title), p_status='PUBLIC', p_is_default='Y',
                  p_display_rows=15,
                  p_report_columns=':'.join(c.alias for c in ir.cols if c.heading is not None), **sort)
        return rid

    def chart(self, ch, seq, new_row=True):
        rid = self.region(ch.title, seq, TPL['region'], 'NATIVE_JET_CHART', ch.span, new_row)
        cid = self.id()
        gantt = ch.type == 'gantt'
        self.call('wwv_flow_imp_page.create_jet_chart', p_id=cid, p_region_id=rid, p_chart_type=ch.type,
                  p_height=str(ch.height), p_animation_on_display='none', p_animation_on_data_change='none',
                  p_orientation='horizontal' if ch.horizontal else 'vertical',
                  p_data_cursor='auto', p_data_cursor_behavior='auto', p_hide_and_show_behavior='withRescale',
                  p_hover_behavior='dim', p_stack='on' if ch.stack else 'off', p_stack_label='off',
                  p_connect_nulls='Y', p_sorting=ch.sorting, p_fill_multi_series_gaps=ch.time != 'mixedFrequency',
                  p_zoom_and_scroll='off', p_tooltip_rendered='Y', p_show_series_name=True,
                  p_show_group_name=True, p_show_value=True,
                  p_show_row=True if gantt else None, p_show_start=True if gantt else None,
                  p_show_end=True if gantt else None,
                  p_legend_rendered='off' if gantt else 'on', p_legend_position='bottom',
                  p_overview_rendered='off', p_time_axis_type=ch.time,
                  p_no_data_found_message=ch.no_data,
                  p_row_axis_rendered='on' if gantt else None, p_gantt_axis_position='top' if gantt else None)
        for i, s in enumerate(ch.series, 1):
            g = s.gantt or {}
            self.call('wwv_flow_imp_page.create_jet_chart_series', p_id=self.id(), p_chart_id=cid,
                      p_static_id=slug(s.name), p_seq=i * 10, p_name=s.name, p_data_source_type='SQL',
                      p_data_source=with_ctes(s.sql), p_location='LOCAL', p_series_type=s.type,
                      p_series_name_column_name=s.name_col,
                      p_items_value_column_name=None if gantt else s.value,
                      p_items_label_column_name=None if gantt else s.label,
                      p_color=s.color, p_line_style=s.style if s.type == 'line' else None,
                      p_line_width=s.width, p_line_type=s.line_type if s.type == 'line' else None,
                      p_marker_rendered=s.marker if s.type == 'line' else None,
                      p_marker_shape='circle' if s.type == 'line' else None,
                      p_stack_category=s.stack, p_assigned_to_y2='off', p_items_label_rendered=False,
                      p_threshold_display='onIndicator', **g)
        if gantt:
            for axis, scale in (('major', 'months'), ('minor', 'weeks')):
                self.call('wwv_flow_imp_page.create_jet_chart_axis', p_id=self.id(), p_chart_id=cid,
                          p_static_id=axis, p_axis=axis, p_is_rendered='on', p_axis_scale=scale)
            return rid
        self.call('wwv_flow_imp_page.create_jet_chart_axis', p_id=self.id(), p_chart_id=cid, p_static_id='x',
                  p_axis='x', p_is_rendered='on', p_format_type='date-short' if ch.time else None,
                  p_format_scaling='auto', p_scaling='linear', p_baseline_scaling='zero',
                  p_major_tick_rendered='on', p_minor_tick_rendered='off', p_tick_label_rendered='on',
                  p_tick_label_rotation='auto', p_tick_label_position='outside')
        self.call('wwv_flow_imp_page.create_jet_chart_axis', p_id=self.id(), p_chart_id=cid, p_static_id='y',
                  p_axis='y', p_is_rendered='on', p_title=ch.y_title, p_max=ch.y_max, p_format_type='decimal',
                  p_format_scaling='none', p_scaling='linear', p_baseline_scaling='zero', p_position='auto',
                  p_major_tick_rendered='on', p_minor_tick_rendered='off', p_tick_label_rendered='on')
        return rid


def column_identifier(pos):
    s = ''
    while pos:
        pos, r = divmod(pos - 1, 26)
        s = chr(65 + r) + s
    return s


def emit_app():
    x = Export()
    head = f'''prompt --application/set_environment
set define off verify off feedback off
whenever sqlerror exit failure rollback
--------------------------------------------------------------------------------
-- {APP_NAME} (APEX application {APP_ID}, alias {APP_ALIAS}).
-- Generated by apex/build.py; regenerate instead of editing.  Install with
-- apex/install.sql, which sets workspace, parsing schema and application id
-- through apex_application_install; the defaults below apply otherwise.
--------------------------------------------------------------------------------
begin
wwv_flow_imp.import_begin (
 p_version_yyyy_mm_dd=>'2026.04.07'
,p_release=>'26.2.0'
,p_default_workspace_id=>apex_util.find_security_group_id('{WORKSPACE}')
,p_default_application_id=>{APP_ID}
,p_default_id_offset=>0
,p_default_owner=>'{SCHEMA}'
);
end;
/
prompt --application/delete_application
begin
wwv_flow_imp.remove_flow(wwv_flow.g_flow_id);
end;
/'''
    x.out.append(head)
    auth, nav, navbar = x.id(), x.id(), x.id()
    x.call('wwv_imp_workspace.create_flow', p_id=Raw('wwv_flow.g_flow_id'),
           p_owner=Raw(f"nvl(wwv_flow_application_install.get_schema,'{SCHEMA}')"),
           p_name=Raw(f"nvl(wwv_flow_application_install.get_application_name,'{APP_NAME}')"),
           p_alias=Raw(f"nvl(wwv_flow_application_install.get_application_alias,'{APP_ALIAS}')"),
           p_page_view_logging='YES', p_page_protection_enabled_y_n='Y', p_bookmark_checksum_function='SH512',
           p_compatibility_mode='26.1', p_flow_language='en', p_flow_language_derived_from='FLOW_PRIMARY_LANGUAGE',
           p_date_format='YYYY-MM-DD', p_timestamp_format='YYYY-MM-DD HH24:MI',
           p_timestamp_tz_format='YYYY-MM-DD HH24:MI TZR',
           p_flow_image_prefix=Raw("nvl(wwv_flow_application_install.get_image_prefix,'')"),
           p_authentication_id=auth, p_application_tab_set=0, p_logo_type='T', p_logo_text=APP_NAME,
           p_proxy_server=Raw("nvl(wwv_flow_application_install.get_proxy,'')"),
           p_no_proxy_domains=Raw("nvl(wwv_flow_application_install.get_no_proxy_domains,'')"),
           p_flow_version='1.0', p_flow_status='AVAILABLE_W_EDIT_LINK', p_browser_cache='N',
           p_browser_frame='D', p_deep_linking='Y', p_authorize_batch_job='N', p_rejoin_existing_sessions='N',
           p_csv_encoding='Y', p_substitution_string_01='APP_NAME', p_substitution_value_01=APP_NAME,
           p_file_prefix=Raw("nvl(wwv_flow_application_install.get_static_app_file_prefix,'')"),
           p_files_version=1, p_print_server_type='NATIVE', p_file_storage='DB', p_is_pwa='N',
           p_theme_id=42, p_home_url='f?p=&APP_ID.:1:&APP_SESSION.::&DEBUG.:::',
           p_login_url='f?p=&APP_ID.:LOGIN:&APP_SESSION.::&DEBUG.:::',
           p_theme_style_by_user_pref=False, p_built_with_love=False, p_global_page_id=0,
           p_navigation_list_id=nav, p_navigation_list_position='SIDE',
           p_navigation_list_template_id=TPL['nav_side'],
           p_nav_list_template_options='#DEFAULT#:t-TreeNav--styleA',
           p_nav_bar_type='LIST', p_nav_bar_list_id=navbar, p_nav_bar_list_template_id=TPL['nav_bar'],
           p_nav_bar_template_options='#DEFAULT#')
    x.block('create_application')

    # Refresh is a page submit: the on-submit process drops the collections inside the
    # POST transaction and the page branch comes back without a request in the URL.
    refresh = "javascript:apex.submit({request:'REFRESH'});"
    x.call('wwv_flow_imp_shared.create_list', p_id=nav, p_name='Navigation Menu', p_static_id='navigation-menu')
    for i, p in enumerate(PAGES, 1):
        x.call('wwv_flow_imp_shared.create_list_item', p_id=x.id(), p_list_item_display_sequence=i * 10,
               p_list_item_link_text=p.name, p_static_id=slug(p.name),
               p_list_item_link_target=f'f?p=&APP_ID.:{p.id}:&APP_SESSION.::&DEBUG.:::',
               p_list_item_icon=p.icon, p_list_item_current_type='TARGET_PAGE')
    x.block('shared_components/navigation/lists/navigation_menu')
    x.call('wwv_flow_imp_shared.create_list', p_id=navbar, p_name='Navigation Bar', p_static_id='navigation-bar')
    x.call('wwv_flow_imp_shared.create_list_item', p_id=x.id(), p_list_item_display_sequence=10,
           p_list_item_link_text='Refresh data', p_static_id='refresh-data', p_list_item_link_target=refresh,
           p_list_item_icon='fa-refresh', p_list_item_current_type='NEVER')
    user = x.id()
    x.call('wwv_flow_imp_shared.create_list_item', p_id=user, p_list_item_display_sequence=20,
           p_list_item_link_text='&APP_USER.', p_static_id='app-user', p_list_item_link_target='#',
           p_list_item_icon='fa-user', p_list_text_02='has-username', p_list_item_current_type='TARGET_PAGE')
    x.call('wwv_flow_imp_shared.create_list_item', p_id=x.id(), p_list_item_display_sequence=30,
           p_list_item_link_text='Sign Out', p_static_id='sign-out', p_list_item_link_target='&LOGOUT_URL.',
           p_list_item_icon='fa-sign-out', p_list_item_disp_cond_type='USER_IS_NOT_PUBLIC_USER',
           p_parent_list_item_id=user, p_list_item_current_type='TARGET_PAGE')
    x.block('shared_components/navigation/lists/navigation_bar')

    x.call('wwv_flow_imp_shared.create_flow_process', p_id=x.id(), p_process_sequence=1,
           p_process_point='BEFORE_HEADER', p_process_type='NATIVE_PLSQL', p_process_name='Load data',
           p_static_id='load-data', p_process_sql_clob=loader_plsql(':APP_PAGE_ID', ':REQUEST'),
           p_process_clob_language='PLSQL')
    x.block('shared_components/logic/application_processes/load_data')
    x.call('wwv_flow_imp_shared.create_flow_process', p_id=x.id(), p_process_sequence=1,
           p_process_point='ON_SUBMIT_BEFORE_COMPUTATION', p_process_type='NATIVE_PLSQL',
           p_process_name='Refresh data', p_static_id='refresh-data', p_process_sql_clob=refresh_plsql(),
           p_process_clob_language='PLSQL', p_process_when_type='REQUEST_EQUALS_CONDITION',
           p_process_when='REFRESH')
    x.block('shared_components/logic/application_processes/refresh_data')

    x.call('wwv_flow_imp_shared.create_theme', p_id=x.id(), p_theme_id=42, p_static_id='universal-theme',
           p_theme_name='Universal Theme', p_theme_internal_name='UNIVERSAL_THEME', p_version_identifier='26.2',
           p_navigation_type='L', p_nav_bar_type='LIST', p_is_locked=False,
           p_current_theme_style_id=TPL['style_iris'], p_default_page_template=TPL['page'],
           p_default_dialog_template=2103835248774687739, p_error_template=TPL['page_login'],
           p_printer_friendly_template=TPL['page'], p_login_template=TPL['page_login'],
           p_default_button_template=TPL['button'], p_default_region_template=TPL['region'],
           p_default_chart_template=TPL['region'], p_default_form_template=TPL['region'],
           p_default_reportr_template=TPL['region'], p_default_wizard_template=TPL['region'],
           p_default_menur_template=2534890969069732905, p_default_listr_template=TPL['region'],
           p_default_irr_template=TPL['region_ir'], p_default_report_template=TPL['report'],
           p_default_label_template=TPL['label'], p_default_menu_template=4075790987805660140,
           p_default_list_template=4075788786379660133, p_default_top_nav_list_temp=2530182346535839887,
           p_default_side_nav_list_temp=TPL['nav_side'], p_default_nav_list_position='SIDE',
           p_default_dialogbtnr_template=2129856781885180476, p_default_dialogr_template=4504868307683981366,
           p_default_option_label=TPL['label'], p_default_required_label=1612549789555753698,
           p_default_navbar_list_template=TPL['nav_bar'],
           p_file_prefix=Raw("nvl(wwv_flow_application_install.get_static_theme_file_prefix(42),"
                             "'#APEX_FILES#themes/theme_42/26.2/')"),
           p_files_version=64, p_icon_library='FONTAPEX',
           p_javascript_file_urls='#APEX_FILES#libraries/apex/#MIN_DIRECTORY#widget.stickyWidget#MIN#.js'
                                  '?v=#APEX_VERSION#\n#THEME_FILES#js/theme42#MIN#.js?v=#APEX_VERSION#',
           p_css_file_urls='#THEME_FILES#css/Core#MIN#.css?v=#APEX_VERSION#',
           p_reference_id=Raw("wwv_imp_util.get_subscription_id(4075791579648660165,2000,'universal-theme',8842.262)"))
    x.block('shared_components/user_interface/themes')

    x.call('wwv_flow_imp_shared.create_authentication', p_id=auth, p_name='Oracle APEX Accounts',
           p_static_id='oracle-apex-accounts', p_scheme_type='NATIVE_APEX_ACCOUNTS', p_invalid_session_type='LOGIN',
           p_use_secure_cookie_yn='N', p_ras_mode=0)
    x.block('shared_components/security/authentications/oracle_apex_accounts')

    emit_global_page(x, refresh)
    for page in PAGES:
        x.call('wwv_flow_imp_page.create_page', p_id=page.id, p_name=page.name, p_alias=page.alias,
               p_step_title=f'{page.name} - {APP_NAME}', p_autocomplete_on_off='OFF',
               p_warn_on_unsaved_changes='N', p_step_template=TPL['page'], p_page_template_options='#DEFAULT#',
               p_inline_css=page.css, p_protection_level='C')
        row_width = 0
        for seq, region in enumerate(page.regions, 1):
            span = region.span
            new_row = row_width == 0 or row_width + span > 12
            row_width = (0 if new_row else row_width) + span
            row_width = 0 if row_width >= 12 else row_width
            if isinstance(region, Chart):
                x.chart(region, seq * 10, new_row)
            elif isinstance(region, IR):
                x.interactive_report(region, seq * 10, new_row)
            else:
                x.report(region, seq * 10, new_row)
        x.call('wwv_flow_imp_page.create_page_branch', p_id=x.id(),
               p_branch_action=f'f?p=&APP_ID.:{page.id}:&SESSION.::&DEBUG.:::',
               p_branch_point='AFTER_PROCESSING', p_branch_type='REDIRECT_URL', p_branch_sequence=10)
        x.block(f'pages/page_{page.id:05d}')
    emit_login_page(x)
    x.out.append('''prompt --application/end_environment
begin
wwv_flow_imp.import_end(p_auto_install_sup_obj => nvl(wwv_flow_application_install.get_auto_install_sup_obj, false)
);
commit;
end;
/
set verify on feedback on define on
prompt  ...done''')
    return '\n'.join(x.out) + '\n'


def emit_global_page(x, refresh):
    pages = ','.join(map(str, CONTENT_PAGES))
    visible = dict(p_plug_display_condition_type='CURRENT_PAGE_IN_CONDITION', p_plug_display_when_condition=pages)
    x.call('wwv_flow_imp_page.create_page', p_id=0, p_name='Global Page', p_autocomplete_on_off='OFF',
           p_protection_level='D')
    filters = x.region('Filters', 1, TPL['region'], 'NATIVE_STATIC', span=8,
                       options='#DEFAULT#:t-Region--noUI:t-Region--hideHeader js-addHiddenHeadingRoleDesc',
                       p_plug_display_point='BODY',
                       p_attributes={'expand_shortcuts': 'N', 'output_as': 'HTML'}, **visible)
    x.report(DATA_BADGES, 2, new_row=False, p_display_condition_type='CURRENT_PAGE_IN_CONDITION',
             p_display_when_condition=pages)
    for seq, it in enumerate(ITEMS, 1):
        shown = item_pages(it)
        common = dict(p_id=x.id(), p_name=it.name, p_item_sequence=seq * 10, p_item_plug_id=filters,
                      p_prompt=it.label, p_begin_on_new_line='N' if seq > 1 else None,
                      p_field_template=TPL['label'], p_item_template_options='#DEFAULT#',
                      p_warn_on_unsaved_changes='I', p_protection_level='N', p_escape_on_http_output='Y',
                      p_display_when=','.join(map(str, shown)), p_display_when_type='CURRENT_PAGE_IN_CONDITION')
        if it.type == 'date':
            x.call('wwv_flow_imp_page.create_page_item', **common, p_display_as='NATIVE_DATE_PICKER_APEX',
                   p_format_mask='YYYY-MM-DD', p_cSize=12, p_cMaxlength=10, p_is_persistent='Y',
                   p_attributes={'display_as': 'POPUP', 'max_date': 'NONE', 'min_date': 'NONE',
                                 'multiple_months': 'N', 'show_time': 'N', 'use_defaults': 'Y'})
        else:
            x.call('wwv_flow_imp_page.create_page_item', **common, p_display_as='NATIVE_SELECT_LIST',
                   p_lov=with_ctes(it.lov), p_lov_display_null='YES', p_lov_null_text=it.null_text,
                   p_lov_null_value=it.null_value, p_cHeight=1, p_is_persistent='Y',
                   p_attributes={'page_action_on_selection': 'NONE'})
    x.call('wwv_flow_imp_page.create_page_button', p_id=x.id(), p_button_sequence=len(ITEMS) * 10 + 10,
           p_button_plug_id=filters,
           p_button_name='REFRESH', p_static_id='refresh', p_button_action='SUBMIT',
           p_button_template_options='#DEFAULT#:t-Button--iconLeft', p_button_template_id=2086257187394300437,
           p_button_image_alt='Refresh data', p_button_position='BODY',
           p_icon_css_classes='fa-refresh', p_grid_new_row='N', p_grid_new_column='Y')
    ev = x.id()
    x.call('wwv_flow_imp_page.create_page_da_event', p_id=ev, p_name='Filter changed', p_static_id='filter-changed',
           p_event_sequence=10, p_triggering_element_type='JQUERY_SELECTOR',
           p_triggering_element=','.join('#' + it.name for it in ITEMS), p_bind_type='bind',
           p_execution_type='IMMEDIATE', p_bind_event_type='change')
    x.call('wwv_flow_imp_page.create_page_da_action', p_id=x.id(), p_event_id=ev, p_event_result='TRUE',
           p_action_sequence=10, p_execute_on_page_init='N', p_static_id='submit-page', p_action='NATIVE_SUBMIT_PAGE',
           p_attributes={'show_processing': 'Y'})
    x.block('pages/page_00000')


def emit_login_page(x):
    x.call('wwv_flow_imp_page.create_page', p_id=LOGIN_PAGE, p_name='Login Page', p_alias='LOGIN',
           p_step_title=f'{APP_NAME} - Log In', p_warn_on_unsaved_changes='N', p_first_item='AUTO_FIRST_ITEM',
           p_autocomplete_on_off='OFF', p_step_template=TPL['page_login'], p_page_template_options='#DEFAULT#',
           p_page_is_public_y_n='Y', p_protection_level='C')
    plug = x.id()
    x.call('wwv_flow_imp_page.create_page_plug', p_id=plug, p_plug_name=APP_NAME, p_static_id='login',
           p_icon_css_classes='fa-area-chart', p_region_template_options='#DEFAULT#',
           p_plug_template=TPL['region_login'], p_plug_display_sequence=10, p_plug_item_display_point='ABOVE',
           p_attributes={'expand_shortcuts': 'N', 'output_as': 'HTML'})
    x.call('wwv_flow_imp_page.create_page_button', p_id=x.id(), p_button_sequence=40, p_button_plug_id=plug,
           p_button_name='LOGIN', p_static_id='login-button', p_show_as_disabled=False, p_button_action='SUBMIT',
           p_button_template_options='#DEFAULT#', p_button_template_id=TPL['button'], p_button_is_hot='Y',
           p_button_image_alt='Sign In', p_button_position='NEXT', p_grid_new_row='Y')
    for seq, (name, label, kind, icon, attrs) in enumerate((
            ('USERNAME', 'Username', 'NATIVE_TEXT_FIELD', 'fa-user',
             {'disabled': 'N', 'submit_when_enter_pressed': 'N', 'subtype': 'TEXT', 'trim_spaces': 'BOTH'}),
            ('PASSWORD', 'Password', 'NATIVE_PASSWORD', 'fa-key', {'submit_when_enter_pressed': 'Y'})), 1):
        x.call('wwv_flow_imp_page.create_page_item', p_id=x.id(), p_name=f'P9999_{name}', p_item_sequence=seq * 10,
               p_item_plug_id=plug, p_prompt=label, p_placeholder=label, p_source_type='ALWAYS_NULL',
               p_display_as=kind, p_cSize=40, p_cMaxlength=100,
               p_tag_attributes='autocomplete="username"' if name == 'USERNAME' else 'autocomplete="current-password"',
               p_label_alignment='RIGHT', p_field_template=TPL['label_hidden'], p_item_icon_css_classes=icon,
               p_item_template_options='#DEFAULT#', p_is_persistent='N', p_attributes=attrs)
    x.call('wwv_flow_imp_page.create_page_item', p_id=x.id(), p_name='P9999_REMEMBER', p_item_sequence=30,
           p_item_plug_id=plug, p_prompt='Remember username', p_source_type='ALWAYS_NULL',
           p_display_as='NATIVE_SINGLE_CHECKBOX', p_label_alignment='RIGHT',
           p_display_when='apex_authentication.persistent_cookies_enabled', p_display_when2='PLSQL',
           p_display_when_type='EXPRESSION', p_field_template=TPL['label_hidden'],
           p_item_template_options='#DEFAULT#', p_attributes={'use_defaults': 'Y'})
    x.call('wwv_flow_imp_page.create_page_process', p_id=x.id(), p_process_sequence=10,
           p_process_point='BEFORE_HEADER', p_process_type='NATIVE_PLSQL', p_process_name='Get Username Cookie',
           p_static_id='get-username-cookie',
           p_process_sql_clob=':P9999_USERNAME := apex_authentication.get_login_username_cookie;\n'
                              ":P9999_REMEMBER := case when :P9999_USERNAME is not null then 'Y' end;",
           p_process_clob_language='PLSQL')
    for seq, (pname, method, params) in enumerate((
            ('Set Username Cookie', 'SEND_LOGIN_USERNAME_COOKIE',
             (('p_username', 'VARCHAR2', 'EXPRESSION', 'lower( :P9999_USERNAME )'),
              ('p_consent', 'BOOLEAN', 'ITEM', 'P9999_REMEMBER'))),
            ('Login', 'LOGIN',
             (('p_username', 'VARCHAR2', 'ITEM', 'P9999_USERNAME'),
              ('p_password', 'VARCHAR2', 'ITEM', 'P9999_PASSWORD'),
              ('p_set_persistent_auth', 'BOOLEAN', 'API_DEFAULT', None)))), 1):
        proc = x.id()
        x.call('wwv_flow_imp_page.create_page_process', p_id=proc, p_process_sequence=seq * 10,
               p_process_point='AFTER_SUBMIT', p_process_type='NATIVE_INVOKE_API', p_process_name=pname,
               p_static_id=slug(pname),
               p_attributes={'package': 'APEX_AUTHENTICATION', 'package_method': method, 'type': 'PLSQL_PACKAGE'},
               p_error_display_location='INLINE_IN_NOTIFICATION')
        for pos, (arg, dtype, vtype, value) in enumerate(params, 1):
            x.call('wwv_flow_imp_shared.create_invokeapi_comp_param', p_id=x.id(), p_page_process_id=proc,
                   p_page_id=LOGIN_PAGE, p_name=arg, p_direction='IN', p_data_type=dtype,
                   p_has_default=vtype == 'API_DEFAULT', p_display_sequence=pos, p_value_type=vtype,
                   p_value_language='PLSQL' if vtype == 'EXPRESSION' else None, p_value=value)
    x.call('wwv_flow_imp_page.create_page_process', p_id=x.id(), p_process_sequence=30,
           p_process_point='AFTER_SUBMIT', p_process_type='NATIVE_SESSION_STATE', p_process_name='Clear Page(s) Cache',
           p_static_id='clear-page-s-cache', p_attributes={'type': 'CLEAR_CACHE_CURRENT_PAGE'},
           p_error_display_location='INLINE_IN_NOTIFICATION')
    x.block(f'pages/page_{LOGIN_PAGE:05d}')


def worst_tbspc(expr):
    return (f'select max({expr}) keep (dense_rank first order by f.days_to_full nulls last, '
            "f.pct desc nulls last, f.db, f.series) from c_fit f where f.kind = 'TBSPC'")


# label, {item: query over the loaded collections that gives its value}, rows required.
# The values come from the data, so the same scenarios run on the demo, the fixture or a real install.
SCENARIOS = [
    ('defaults', {}, True),
    ('one-db', {'P0_DB': worst_tbspc('f.db'), 'P0_TBSPC': worst_tbspc(tbspc_key('f'))}, True),
    ('root-all-tbspc', {'P0_DB': 'select min(c.db_pdb) from c_cont c where c.con_dbid = c.dbid',
                        'P0_TBSPC': "select 'ALL' from dual"}, False),
    ('target', {'P0_TARGET': 'select min(c.target_name) from c_cont c'}, True),
    ('filtered', {'P0_KIND': "select 'TBSPC_GROWTH' from dual", 'P0_SEV': "select 'WARN' from dual"}, False),
]
FILTER_ITEMS = [it.name for it in ITEMS]
PROBE_TABLE = 'awrcap_probe_coll'


def fidelity_query(name):
    """Rows that differ between the collection (decoded) and its source view; must be 0."""
    alias, source, cols = COLLECTIONS[name]
    sel = []
    for col, slot in cols:
        kind, _, numeric = parse_slot(slot)
        if col in VOLATILE:
            continue
        sel.append(f'round({col}, 10)' if kind == 'n' or numeric else col)
    sel = ', '.join(sel)
    return with_ctes(f'select * from ((select {sel} from {alias} minus select {sel} from ({source}))\n'
                     f'union all (select {sel} from ({source}) minus select {sel} from {alias}))')


def page_checks(page):
    """(label, SQL, rows required) of everything page renders: the page-0 components, then its regions."""
    checks = [(f'p0 {it.name} lov', with_ctes(it.lov), False) for it in ITEMS
              if it.lov and page.id in item_pages(it)]
    checks.append(('p0 Data', DATA_BADGES.sql(), True))
    for region in page.regions:
        checks += [(f'p{page.id} {lbl}', q, must) for lbl, q, must in region_queries(region)]
    return checks


def app_queries():
    """Every SQL text the export carries: what apex/test/export_check.py expects to extract."""
    regions = {q for page in PAGES for _, q, _ in page_checks(page)}
    lovs = {with_ctes(it.lov) for it in ITEMS if it.lov}
    return {'regions': regions - lovs, 'lovs': lovs,
            'loaders': {name: loader_query(name) for name in COLLECTIONS},
            'defaults': [with_ctes(as_v(d.query)) for d in page_logic()]}


def test_procs(probe):
    """load_page, one check_page_N per page and the scenario walk, shared by the smoke harness and the probe."""
    set_state = 'set_state' if probe else 'apex_util.set_session_state'
    loader = '    ' + loader_plsql('p_page', 'p_request', probe).replace('\n', '\n    ')
    procs = ['  procedure load_page(p_page in pls_integer, p_request in varchar2) is', '  begin',
             loader, '  end load_page;']
    for page in PAGES:
        procs += [f'  procedure check_page_{page.id}(p_demo in boolean) is', '  begin']
        procs += [f"    check_query({plsql_literal(lbl)}, {plsql_literal(q)}, {'p_demo' if must else 'false'});"
                  for lbl, q, must in page_checks(page)]
        procs.append(f'  end check_page_{page.id};')
    body, first = [], True
    for label, state, demo in SCENARIOS:
        body.append(f"  dbms_output.put_line('-- scenario {label}');")
        for name in FILTER_ITEMS:
            value = f'pick({plsql_literal(with_ctes(state[name]))})' if name in state else 'null'
            body.append(f"  {set_state}('{name}', {value});")
        for page in PAGES:
            body.append(f"  load_page({page.id}, {plsql_literal('REFRESH') if first else 'null'});")
            first = False
            body.append(f"  dbms_output.put_line('page {page.id}: ' || "
                        + " || ' ' || ".join(f"'{n}=' || v('{n}')" for n in FILTER_ITEMS) + ');')
            body.append(f"  check_page_{page.id}({'true' if demo else 'false'});")
    body.append("  dbms_output.put_line('-- collection fidelity (decoded collection vs source view)');")
    body += [f"  check_empty({plsql_literal(name)}, {plsql_literal(fidelity_query(name))});" for name in COLLECTIONS]
    return procs, body


def script_head(path, what):
    return [f'-- {what}; generated by apex/build.py --smoke.',
            'set appinfo off',
            f'set appinfo "AWRCAP/{path}"']


def emit_smoke():
    procs, body = test_procs(probe=False)
    return '\n'.join([
        *script_head('apex/test/apex_smoke.sql', 'Smoke harness for the AWR Capacity APEX app'),
        '-- Run as the parsing schema:  @test/apex_smoke.sql [app_id]   (default ' + str(APP_ID) + ')',
        '-- Runs the page loader for every page and every region query of the app under',
        '-- representative filter values in an APEX session; exits non-zero on any failure.',
        '-- The filter values are picked from the loaded data. The rows-required checks hold',
        '-- on the demo and the fixture data.',
        'set serveroutput on size unlimited format wrapped feedback off verify off define on',
        'whenever sqlerror exit failure rollback',
        'column 1 new_value 1 noprint',
        "select '' \"1\" from dual where rownum = 0;",
        'variable app_id number',
        f"exec :app_id := nvl(to_number(trim('&1')), {APP_ID})",
        'set define off',
        'declare',
        '  l_fail pls_integer := 0;',
        '  function pick(p_sql in varchar2) return varchar2 is',
        '    l_val varchar2(4000);',
        '  begin',
        '    execute immediate p_sql into l_val;',
        '    return l_val;',
        '  end;',
        '  procedure check_query(p_label in varchar2, p_sql in varchar2, p_must in boolean) is',
        '    l_ctx apex_exec.t_context;',
        '    l_rows number;',
        '    l_t0 pls_integer := dbms_utility.get_time;',
        '  begin',
        '    l_ctx := apex_exec.open_query_context(p_location => apex_exec.c_location_local_db,',
        '      p_sql_query => p_sql, p_auto_bind_items => true, p_total_row_count => true);',
        '    l_rows := apex_exec.get_total_row_count(l_ctx);',
        '    apex_exec.close(l_ctx);',
        "    dbms_output.put_line(case when p_must and l_rows = 0 then 'FAIL ' else 'ok   ' end"
        " || lpad(l_rows, 6) || to_char((dbms_utility.get_time - l_t0) / 100, '990.00') || 's  ' || p_label);",
        '    if p_must and l_rows = 0 then l_fail := l_fail + 1; end if;',
        '  exception when others then',
        '    apex_exec.close(l_ctx);',
        "    dbms_output.put_line('FAIL  error  ' || p_label || ': ' || sqlerrm);",
        '    l_fail := l_fail + 1;',
        '  end;',
        '  procedure check_empty(p_label in varchar2, p_sql in varchar2) is',
        '    l_rows number;',
        '  begin',
        "    execute immediate 'select count(*) from (' || p_sql || ')' into l_rows;",
        "    dbms_output.put_line(case when l_rows = 0 then 'ok   ' else 'FAIL ' end || lpad(l_rows, 6) || '  ' || p_label);",
        '    if l_rows > 0 then l_fail := l_fail + 1; end if;',
        '  end;',
        *procs,
        'begin',
        f"  apex_session.create_session(p_app_id => :app_id, p_page_id => {P_OVERVIEW}, p_username => 'AWRCAP_VIEWER');",
        *body,
        '  for c in (select collection_name, count(*) n from apex_collections group by collection_name order by 1) loop',
        "    dbms_output.put_line('collection ' || rpad(c.collection_name, 20) || lpad(c.n, 7));",
        '  end loop;',
        '  apex_session.delete_session;',
        '  if l_fail > 0 then',
        "    raise_application_error(-20001, l_fail || ' smoke check(s) failed');",
        '  end if;',
        "  dbms_output.put_line('smoke: all checks passed');",
        'end;',
        '/',
        'undefine 1',
        'exit',
    ]) + '\n'


def probe_sql(text):
    """App SQL as the probe runs it: the stand-in table for APEX_COLLECTIONS, a link as plain text."""
    text = re.sub(r"apex_page\.get_url\(p_page => (.*?), p_items => '(.*?)', p_values => ",
                  r"('f?p=' || (\1) || ':\2:' || ", text)
    return text.replace('apex_collections', PROBE_TABLE)


def emit_probe():
    """The app's SQL without APEX: the loader queries fill a table shaped like APEX_COLLECTIONS, then
    every region query, LOV and default runs against it with the items as binds (DBMS_SQL).  It proves
    that each statement parses and runs on an install of the suite and that the slot mapping returns
    the views' values; it does not prove the import or anything a browser renders."""
    procs, body = test_procs(probe=True)
    slots = [f'{slot_column(k, i)} {dtype}' for k, n, dtype in (('n', 5, 'number'), ('d', 5, 'date'),
                                                                ('c', 50, 'varchar2(4000)'))
             for i in range(1, n + 1)]
    items = ', '.join(f"'{n}'" for n in FILTER_ITEMS)
    text = '\n'.join([
        *script_head('apex/test/apex_probe.sql', 'Probe of the AWR Capacity APEX app that needs no APEX'),
        '-- Run from the repository root in the schema that holds the suite (or as SYSDBA with',
        '-- CURRENT_SCHEMA set to it):  @apex/test/apex_probe.sql',
        f'-- The table {PROBE_TABLE.upper()} stands in for APEX_COLLECTIONS: the loader queries of the',
        '-- application fill it, then every region query, LOV and default of every page runs',
        '-- against it under the scenarios of the smoke harness, items bound with DBMS_SQL, and',
        '-- each collection is compared with its source view. The table is dropped at the end.',
        '-- Prints one line per statement and RESULT: at the end; exits non-zero on a failure.',
        '-- Not covered: the import into APEX and what a browser renders.',
        'set serveroutput on size unlimited format wrapped feedback off verify off define off',
        'whenever sqlerror exit failure rollback',
        'variable probe_fail number',
        'begin',
        f"  execute immediate 'drop table {PROBE_TABLE} purge';",
        'exception when others then',
        '  if sqlcode <> -942 then raise; end if;',
        'end;',
        '/',
        f'create table {PROBE_TABLE} (',
        '  collection_name varchar2(255), seq_id number,',
        '  ' + ',\n  '.join(', '.join(slots[i:i + 5]) for i in range(0, len(slots), 5)) + ');',
        'declare',
        '  type t_state is table of varchar2(4000) index by varchar2(30);',
        '  type t_names is table of varchar2(30);',
        f'  g_items constant t_names := t_names({items});',
        '  g_state t_state;',
        '  g_loaded t_state;',
        '  l_pass pls_integer := 0;',
        '  l_fail pls_integer := 0;',
        '  function v(p_item in varchar2) return varchar2 is',
        '  begin',
        '    return case when g_state.exists(p_item) then g_state(p_item) end;',
        '  end;',
        '  procedure set_state(p_item in varchar2, p_value in varchar2) is',
        '  begin',
        '    g_state(p_item) := p_value;',
        '  end;',
        '  procedure passed(p_ok in boolean) is',
        '  begin',
        '    if p_ok then l_pass := l_pass + 1; else l_fail := l_fail + 1; end if;',
        '  end;',
        '  -- Binds the items the statement names, fetches every row and every column.',
        '  procedure run(p_sql in varchar2, p_rows out number, p_first out varchar2) is',
        '    l_cur integer := dbms_sql.open_cursor;',
        '    l_cols dbms_sql.desc_tab2;',
        '    l_n integer;',
        '    l_val varchar2(4000);',
        '    l_ignore integer;',
        "    -- without its string literals: a link's item list ('..:P0_DB:..') names no bind",
        "    l_bare varchar2(32767) := regexp_replace(p_sql, '''[^'']*''', '''''');",
        '  begin',
        '    dbms_sql.parse(l_cur, p_sql, dbms_sql.native);',
        '    for i in 1 .. g_items.count loop',
        "      if regexp_like(l_bare, ':' || g_items(i) || '([^A-Za-z0-9_]|$)') then",
        "        dbms_sql.bind_variable(l_cur, ':' || g_items(i), v(g_items(i)));",
        '      end if;',
        '    end loop;',
        '    dbms_sql.describe_columns2(l_cur, l_n, l_cols);',
        '    for i in 1 .. l_n loop',
        '      dbms_sql.define_column(l_cur, i, l_val, 4000);',
        '    end loop;',
        '    l_ignore := dbms_sql.execute(l_cur);',
        '    p_rows := 0;',
        '    while dbms_sql.fetch_rows(l_cur) > 0 loop',
        '      p_rows := p_rows + 1;',
        '      for i in 1 .. l_n loop',
        '        dbms_sql.column_value(l_cur, i, l_val);',
        '        if p_rows = 1 and i = 1 then p_first := l_val; end if;',
        '      end loop;',
        '    end loop;',
        '    dbms_sql.close_cursor(l_cur);',
        '  exception when others then',
        '    if dbms_sql.is_open(l_cur) then dbms_sql.close_cursor(l_cur); end if;',
        '    raise;',
        '  end;',
        '  function pick(p_sql in varchar2) return varchar2 is',
        '    l_rows number;',
        '    l_val varchar2(4000);',
        '  begin',
        '    run(p_sql, l_rows, l_val);',
        '    return l_val;',
        '  end;',
        '  procedure check_query(p_label in varchar2, p_sql in varchar2, p_must in boolean) is',
        '    l_rows number;',
        '    l_val varchar2(4000);',
        '    l_t0 pls_integer := dbms_utility.get_time;',
        '  begin',
        '    run(p_sql, l_rows, l_val);',
        "    dbms_output.put_line(case when p_must and l_rows = 0 then 'FAIL ' else 'ok   ' end"
        " || lpad(l_rows, 6) || to_char((dbms_utility.get_time - l_t0) / 100, '990.00') || 's  ' || p_label);",
        '    passed(not (p_must and l_rows = 0));',
        '  exception when others then',
        "    dbms_output.put_line('FAIL  error  ' || p_label || ': ' || sqlerrm);",
        '    passed(false);',
        '  end;',
        '  procedure check_empty(p_label in varchar2, p_sql in varchar2) is',
        '    l_rows number;',
        '    l_val varchar2(4000);',
        '  begin',
        '    run(p_sql, l_rows, l_val);',
        "    dbms_output.put_line(case when l_rows = 0 then 'ok   ' else 'FAIL ' end || lpad(l_rows, 6) || '  ' || p_label);",
        '    passed(l_rows = 0);',
        '  exception when others then',
        "    dbms_output.put_line('FAIL  error  ' || p_label || ': ' || sqlerrm);",
        '    passed(false);',
        '  end;',
        '  procedure drop_all is',
        '  begin',
        f"    execute immediate 'delete from {PROBE_TABLE}';",
        '    g_loaded.delete;',
        '  end;',
        '  -- create_collection_from_queryb2: the query columns are the slots, by name here.',
        '  procedure load(p_name in varchar2, p_query in varchar2) is',
        '    l_cur integer;',
        '    l_cols dbms_sql.desc_tab2;',
        '    l_n integer;',
        '    l_list varchar2(4000);',
        '    l_t0 pls_integer := dbms_utility.get_time;',
        '  begin',
        '    if g_loaded.exists(p_name) then return; end if;',
        "    g_loaded(p_name) := 'Y';",
        '    l_cur := dbms_sql.open_cursor;',
        '    dbms_sql.parse(l_cur, p_query, dbms_sql.native);',
        '    dbms_sql.describe_columns2(l_cur, l_n, l_cols);',
        '    dbms_sql.close_cursor(l_cur);',
        '    for i in 1 .. l_n loop',
        "      l_list := l_list || ', ' || l_cols(i).col_name;",
        '    end loop;',
        f"    execute immediate 'insert into {PROBE_TABLE} (collection_name, seq_id' || l_list",
        "      || ') select :name, rownum, q.* from (' || p_query || ') q' using p_name;",
        "    dbms_output.put_line('ok   ' || lpad(sql%rowcount, 6)"
        " || to_char((dbms_utility.get_time - l_t0) / 100, '990.00') || 's  load ' || p_name);",
        '    passed(true);',
        '  exception when others then',
        '    if dbms_sql.is_open(l_cur) then dbms_sql.close_cursor(l_cur); end if;',
        "    dbms_output.put_line('FAIL  error  load ' || p_name || ': ' || sqlerrm);",
        '    passed(false);',
        '  end;',
        *procs,
        'begin',
        '  :probe_fail := 1;',
        *body,
        f'  for c in (select collection_name, count(*) n from {PROBE_TABLE} group by collection_name order by 1) loop',
        "    dbms_output.put_line('collection ' || rpad(c.collection_name, 20) || lpad(c.n, 7));",
        '  end loop;',
        '  :probe_fail := l_fail;',
        "  dbms_output.put_line('RESULT: apex probe ' || l_pass || ' passed, ' || l_fail || ' failed');",
        'exception when others then',
        "  dbms_output.put_line('FAIL  probe aborted: ' || sqlerrm);",
        'end;',
        '/',
        f'drop table {PROBE_TABLE} purge;',
        'begin',
        '  if :probe_fail > 0 then',
        "    raise_application_error(-20001, 'apex probe: ' || :probe_fail || ' check(s) failed');",
        '  end if;',
        "  dbms_output.put_line('apex probe: all checks passed');",
        'end;',
        '/',
    ]) + '\n'
    text = probe_sql(text)
    stray = re.search(r'\bapex_(page|util|exec|session|collections?|application)\b', text)
    assert not stray, f'the probe still calls APEX: {stray.group(0)}'
    return text


def outputs():
    return {HERE / 'awrcap_app.sql': emit_app, HERE / 'test' / 'apex_smoke.sql': emit_smoke,
            HERE / 'test' / 'apex_probe.sql': emit_probe}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--smoke', action='store_true',
                    help='also write apex/test/apex_smoke.sql and apex/test/apex_probe.sql')
    ap.add_argument('--check', action='store_true', help='write nothing; exit 1 when a generated file is stale')
    args = ap.parse_args()
    check_collections()
    if args.check:
        stale = [path for path, emit in outputs().items()
                 if not path.exists() or path.read_text() != emit() or emit() != emit()]
        for path in stale:
            print(f'stale: {path.relative_to(HERE.parent)} (run python3 apex/build.py --smoke)')
        if not stale:
            print(f'apex/build.py --check: {len(outputs())} generated files current')
        sys.exit(1 if stale else 0)
    for path, emit in outputs().items():
        if args.smoke or path.name == 'awrcap_app.sql':
            path.parent.mkdir(exist_ok=True)
            path.write_text(emit())


if __name__ == '__main__':
    main()
