#!/usr/bin/env python3
"""Structural check of the generated APEX export; needs no database and no APEX.

    python3 apex/test/export_check.py [-v]

Parses apex/awrcap_app.sql on its own (the import calls, their parameters and
string literals) and compares what it finds with what apex/build.py declares:

  * every page, region, chart series, filter item, navigation entry and
    collection load the builder declares is in the export exactly once;
  * component ids are unique and every id a call refers to is defined;
  * every SQL text of a region, chart series, LOV and collection load is
    extracted and equals the builder's text (so the 200-character chunking of
    the export round-trips), is well formed, names only declared collections,
    columns its WITH prefix defines and filter items as binds, and reads only
    collections the loader loads on that page;
  * report columns, sort columns, chart column mappings and the columns an
    HTML expression substitutes exist in their query;
  * every extracted SQL text is in apex/test/apex_smoke.sql, and in
    apex/test/apex_probe.sql in the form the probe runs.

One line per check, "OK   <name>" or "FAIL <name>" with the findings; exit 1
on a failure.  What it cannot tell: whether APEX imports the file and how a
page renders.  The probe (apex/test/apex_probe.sql) runs the SQL; an import
needs an APEX 26.2 instance.
"""
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

APEX = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(APEX))
import build as B  # noqa: E402

SQL_PARAMS = ('p_source', 'p_plug_source', 'p_data_source', 'p_lov')
REFS = ('p_region_id', 'p_chart_id', 'p_item_plug_id', 'p_button_plug_id', 'p_event_id', 'p_page_process_id',
        'p_parent_list_item_id', 'p_authentication_id', 'p_navigation_list_id', 'p_nav_bar_list_id')


class Parse(Exception):
    pass


def tokens(text):
    """Split a parameter value into ('str', value) and ('raw', text) tokens; '' is a quote inside a string."""
    out, i, raw = [], 0, ''
    while i < len(text):
        if text[i] == "'":
            if raw.strip():
                out.append(('raw', raw.strip()))
            raw, i, buf = '', i + 1, []
            while True:
                if i >= len(text):
                    raise Parse('unterminated string literal')
                if text[i] == "'":
                    if text[i + 1:i + 2] == "'":
                        buf.append("'")
                        i += 2
                        continue
                    i += 1
                    break
                buf.append(text[i])
                i += 1
            out.append(('str', ''.join(buf)))
        else:
            raw += text[i]
            i += 1
    if raw.strip():
        out.append(('raw', raw.strip()))
    return out


def decode(text):
    """A parameter value: str for a string expression, else the raw text.
    '..'||'..' is one string; wwv_flow_string.join(wwv_flow_t_varchar2(a, b)) is its elements joined by newlines;
    a plugin attribute list becomes a dict."""
    toks = tokens(text)
    if not toks or (len(toks) == 1 and toks[0][0] == 'raw'):
        return Raw(text.strip())
    head = toks[0][1] if toks[0][0] == 'raw' else ''
    if head.startswith('wwv_flow_string.join(wwv_flow_t_varchar2('):
        body, tail, sep = toks[1:-1], toks[-1], '\n'
        if tail != ('raw', '))'):
            raise Parse(f'join does not end in )): {tail}')
    elif head.startswith('wwv_flow_t_plugin_attributes(wwv_flow_t_varchar2('):
        body, tail, sep = toks[1:-1], toks[-1], None
        if tail != ('raw', ')).to_clob'):
            raise Parse(f'attribute list does not end in )).to_clob: {tail}')
    elif toks[0][0] == 'raw':
        return Raw(text.strip())  # an expression such as nvl(.., '..')
    else:
        body, sep = toks, '\n'
    elements, cur, glue = [], None, False
    for kind, value in body:
        if kind == 'str':
            cur = value if cur is None else cur + value
            if cur is not value and not glue:
                raise Parse('two string literals with nothing between them')
            glue = False
        elif value == '||':
            glue = True
        elif value == ',':
            elements.append(cur)
            cur = None
        else:
            raise Parse(f'unexpected text in a string expression: {value[:40]}')
    elements.append(cur)
    if any(e is None for e in elements):
        raise Parse('empty element in a string list')
    if sep is None:
        return dict(zip(elements[0::2], elements[1::2]))
    return sep.join(elements)


class Raw(str):
    pass


CALL_RE = re.compile(r'^(wwv_\w+\.\w+)\($')
PARAM_RE = re.compile(r'^[ ,](p_\w+)=>(.*)$')


def parse_export(text):
    """[(block name, [(procedure, {parameter: value})])] in file order."""
    blocks, lines, i = [], text.split('\n'), 0
    while i < len(lines):
        m = re.match(r'^prompt --application/(.+)$', lines[i])
        i += 1
        if not m:
            continue
        calls = []
        blocks.append((m.group(1), calls))
        while i < len(lines) and not lines[i].startswith('prompt --application/'):
            c = CALL_RE.match(lines[i])
            i += 1
            if not c:
                continue
            params, name, buf = {}, None, []
            while lines[i] != ');':
                p = PARAM_RE.match(lines[i])
                if p:
                    if name:
                        params[name] = decode('\n'.join(buf))
                    name, buf = p.group(1), [p.group(2)]
                    if name in params:
                        raise Parse(f'{c.group(1)}: {name} given twice')
                else:
                    buf.append(lines[i])
                i += 1
            if name:
                params[name] = decode('\n'.join(buf))
            calls.append((c.group(1).split('.')[-1], params))
            i += 1
    return blocks


def strip_strings(sql):
    return re.sub(r"'(?:[^']|'')*'", "''", sql)


def sql_findings(sql, items, page_loads=None):
    """Why this SQL text cannot be right, as a list of findings."""
    out = []
    bare = strip_strings(sql)
    if not re.match(r'(with|select)\s', sql):
        out.append('does not start with WITH or SELECT')
    depth = 0
    for ch in bare:
        depth += (ch == '(') - (ch == ')')
        if depth < 0:
            break
    if depth != 0:
        out.append('unbalanced parentheses')
    if bare.count("'") % 2:
        out.append('unbalanced quotes')
    defined = {}
    for alias, name in re.findall(r"\b(c_\w+) as \(select .*? from apex_collections where collection_name = '(\w+)'\)",
                                  sql):
        if alias in defined:
            out.append(f'{alias} defined twice')
        defined[alias] = name
    for alias, name in defined.items():
        if name not in B.COLLECTIONS:
            out.append(f'{alias} reads undeclared collection {name}')
        elif B.COLLECTIONS[name][0] != alias:
            out.append(f'{alias} is not the alias of {name}')
        elif page_loads is not None and name not in page_loads:
            out.append(f'{name} is not loaded on this page')
    used = set(re.findall(r'\bc_[a-z]+\b', bare))
    for alias in sorted(used - set(defined)):
        out.append(f'{alias} used without a WITH definition')
    body = bare
    for alias in defined:
        body = re.sub(rf'\b{alias} as \(select .*?\)(,\n|\n)', '', body, count=1, flags=re.S)
    for alias in defined:
        if not re.search(rf'\b{alias}\b', body):
            out.append(f'{alias} defined but never read')
    for bind in sorted(set(re.findall(r':([A-Za-z]\w*)', bare)) - set(items)):
        out.append(f'bind :{bind} is not a filter item')
    # A column read through an alias of a collection must be one the collection defines.
    for alias, name in defined.items():
        if name not in B.COLLECTIONS:
            continue
        cols = {c for c, _ in B.COLLECTIONS[name][2]}
        for corr in set(re.findall(rf'\b{alias} (\w+)\b', body)) - {'where', 'on', 'group', 'order', 'cross', 'left'}:
            for col in sorted(set(re.findall(rf'\b{corr}\.(\w+)\b', body)) - cols):
                # the same correlation name may stand for another collection or an inline view elsewhere
                others = [B.COLLECTIONS[n][2] for a, n in defined.items() if a != alias
                          and re.search(rf'\b{a} {corr}\b', body)]
                inline = re.search(rf'\) {corr}\b', body)
                if not inline and not any(col in {c for c, _ in o} for o in others):
                    out.append(f'{corr}.{col} is not a column of {name}')
    return out


class Checks:
    def __init__(self, verbose):
        self.verbose, self.failed, self.count = verbose, 0, 0

    def check(self, name, findings, detail=''):
        self.count += 1
        if findings:
            self.failed += 1
            print(f'FAIL {name}')
            for f in findings[:40]:
                print(f'     {f}')
        elif self.verbose:
            print(f'OK   {name}{" (" + detail + ")" if detail else ""}')


def duplicates(values):
    return [f'{v!r} appears {n} times' for v, n in Counter(values).items() if n > 1]


def missing_extra(found, declared, what):
    f, d = Counter(found), Counter(declared)
    return ([f'{what} declared but not in the export: {v!r}' for v in d if v not in f]
            + [f'{what} in the export but not declared: {v!r}' for v in f if v not in d]
            + [f'{what} {v!r}: {f[v]} in the export, {d[v]} declared' for v in d if v in f and f[v] != d[v]])


def aliases_in(sql, names):
    """The names that are not a column alias of the query's select list (a word followed by , or FROM)."""
    return [n for n in names if not re.search(rf'\b{re.escape(n)}\s*(,|\n?\s*from\b)', sql, re.I)
            and not re.search(rf'\b{re.escape(n)}\s*$', sql.split('\nfrom ')[0], re.I)]


def main():
    verbose = '-v' in sys.argv[1:]
    k = Checks(verbose)
    text = (APEX / 'awrcap_app.sql').read_text()
    try:
        blocks = parse_export(text)
    except Parse as e:
        print(f'FAIL parse: {e}')
        sys.exit(1)
    names = [n for n, _ in blocks]
    calls = [(n, proc, params) for n, cs in blocks for proc, params in cs]
    items = [it.name for it in B.ITEMS]
    declared = B.app_queries()

    k.check('blocks: each block once, begin and end of the import present',
            duplicates(names) + [f'missing block {b}' for b in ('set_environment', 'create_application',
                                                                 'end_environment') if b not in names])
    k.check('text: no unresolved Python formatting, no tab, lines within the SQL*Plus limit',
            [f'line {i}: {len(l)} characters' for i, l in enumerate(text.split('\n'), 1) if len(l) > 2400]
            + (['a tab character'] if '\t' in text else [])
            + [f'line {i}: {l[:60]}' for i, l in enumerate(text.split('\n'), 1) if re.search(r'\bNone\b', l)])

    # ---- ids -----------------------------------------------------------------
    id_re = re.compile(r'^wwv_flow_imp\.id\((\d+)\)$')
    ids = [params['p_id'] for _, _, params in calls if isinstance(params.get('p_id'), Raw)
           and id_re.match(params['p_id'])]
    k.check('ids: every component id is unique', duplicates(ids), f'{len(ids)} ids')
    refs = [(proc, key, params[key]) for _, proc, params in calls for key in REFS if key in params]
    k.check('ids: every referenced id is defined',
            [f'{proc}.{key} = {v}' for proc, key, v in refs if v not in ids], f'{len(refs)} references')

    # ---- pages and navigation --------------------------------------------------
    page_ids = [int(params['p_id']) for _, proc, params in calls if proc == 'create_page']
    k.check('pages: every declared page once, plus the global and the login page',
            missing_extra(page_ids, [0, B.LOGIN_PAGE] + [p.id for p in B.PAGES], 'page'))
    k.check('pages: ids, names and aliases are unique',
            duplicates([p.id for p in B.PAGES]) + duplicates([p.name for p in B.PAGES])
            + duplicates([p.alias for p in B.PAGES]))
    nav = [(params['p_list_item_link_text'], params['p_list_item_link_target'])
           for n, proc, params in calls if n.endswith('lists/navigation_menu') and proc == 'create_list_item']
    k.check('navigation: one menu entry per page, in the declared order',
            [] if nav == [(p.name, f'f?p=&APP_ID.:{p.id}:&APP_SESSION.::&DEBUG.:::') for p in B.PAGES]
            else [f'menu is {nav}'])

    # ---- loader ------------------------------------------------------------------
    proc_sql = {params['p_process_name']: params['p_process_sql_clob'] for _, proc, params in calls
                if proc == 'create_flow_process'}
    loader = proc_sql.get('Load data', '')
    loads = re.findall(r"if :APP_PAGE_ID in \(([\d, ]+)\) then\n\s*load\('(\w+)', q'~(.*?)~'\);", loader)
    k.check('loader: every declared collection is loaded once',
            missing_extra([name for _, name, _ in loads], list(B.COLLECTIONS), 'collection'))
    k.check('loader: every load query equals the builder\'s and is well formed',
            [f'{name}: differs from the builder' for _, name, q in loads if declared['loaders'].get(name) != q]
            + [f'{name}: {f}' for _, name, q in loads for f in sql_findings(q, items)])
    k.check('loader: Refresh data drops every collection',
            missing_extra(re.findall(r"delete_collection\('(\w+)'\)", proc_sql.get('Refresh data', '')),
                          list(B.COLLECTIONS), 'collection'))
    page_loads = defaultdict(set)
    for pages, name, _ in loads:
        for p in pages.split(','):
            page_loads[int(p)].add(name)
    for _, name, q in loads:
        _, _, cols = B.COLLECTIONS.get(name, (None, None, []))
        width = max([B.parse_slot(s)[1] for _, s in cols if s[0] == 'c'] or [0])
        got = re.findall(r'(?:^select |, )(?:.*?) ([ndc]\d{3})(?=,| from)', q)
        want = [f'n{i:03d}' for i in range(1, 6)] + [f'd{i:03d}' for i in range(1, 6)] \
            + [f'c{i:03d}' for i in range(1, width + 1)]
        k.check(f'loader: {name} fills the slots in collection order', [] if got == want else [f'slots are {got}'])
    defaults = re.findall(r"for r in \((.*?)\) loop\n\s*apex_util\.set_session_state\('(\w+)', r\.val\);",
                          loader, re.S)
    k.check('loader: every declared default is there, on a known item, with well formed SQL',
            missing_extra([q for q, _ in defaults], declared['defaults'], 'default query')
            + [f'default sets unknown item {it}' for _, it in defaults if it not in items]
            + [f'{it}: {f}' for q, it in defaults for f in sql_findings(q, items)])

    # ---- regions, per page ---------------------------------------------------------
    extracted = defaultdict(list)  # page id -> [(label, sql)]
    for page in [None] + B.PAGES:
        pid = 0 if page is None else page.id
        pcalls = [(proc, params) for n, proc, params in calls if n == f'pages/page_{pid:05d}']
        label = f'page {pid}'
        regions = [params.get('p_plug_name') or params.get('p_name') for proc, params in pcalls
                   if proc in ('create_page_plug', 'create_report_region')]
        want = ['Filters', 'Data'] if page is None else [r.title for r in page.regions]
        k.check(f'{label}: every declared region once', missing_extra(regions, want, 'region'))
        # a chart's series and axes carry ids that are unique within their chart only
        k.check(f'{label}: static ids are unique per component type',
                [f'{proc}: {d}' for proc in sorted({p for p, _ in pcalls if not p.startswith('create_jet_chart_')})
                 for d in duplicates([params['p_static_id'] for q, params in pcalls
                                      if q == proc and 'p_static_id' in params])])
        current, columns, by_region = None, defaultdict(list), {}
        for proc, params in pcalls:
            if proc in ('create_page_plug', 'create_report_region'):
                current = params.get('p_plug_name') or params.get('p_name')
                by_region[current] = params
                sql = params.get('p_source') or params.get('p_plug_source')
                if sql:
                    extracted[pid].append((current, sql))
            elif proc == 'create_report_columns':
                columns[current].append((params['p_column_alias'], params.get('p_column_html_expression')))
            elif proc == 'create_worksheet_column':
                columns[current].append((params['p_db_column_name'], params.get('p_column_html_expression')))
            elif proc == 'create_worksheet_rpt':
                shown = params['p_report_columns'].split(':')
                sort = [v for key, v in params.items() if key.startswith('p_sort_column_')]
                k.check(f'{label} / {current}: displayed and sort columns exist',
                        [f'{c} is not a column' for c in shown + sort if c not in [a for a, _ in columns[current]]])
            elif proc == 'create_jet_chart_series':
                sql = params['p_data_source']
                extracted[pid].append((f"{current} / {params['p_name']}", sql))
                mapped = [v for key, v in params.items() if key.endswith('_column_name')
                          or key in ('p_gantt_start_date_column', 'p_gantt_end_date_column', 'p_gantt_task_id',
                                     'p_gantt_task_name', 'p_gantt_task_start_date', 'p_gantt_task_end_date')]
                k.check(f"{label} / {current} / {params['p_name']}: mapped columns are in the query",
                        [f'{c} is not a column alias' for c in aliases_in(sql, mapped)])
            elif proc == 'create_page_item' and 'p_lov' in params:
                extracted[pid].append((f"{params['p_name']} lov", params['p_lov']))
        for region, cols in columns.items():
            aliases = [a for a, _ in cols]
            sql = by_region[region].get('p_source') or by_region[region].get('p_plug_source')
            subs = {s for _, html in cols if html for s in re.findall(r'#(\w+)#', html)}
            k.check(f'{label} / {region}: columns are unique, in the query, and every #COLUMN# exists',
                    duplicates(aliases) + [f'{c} is not a column alias' for c in aliases_in(sql, aliases)]
                    + [f'#{s}# is not a column' for s in sorted(subs - set(aliases))], f'{len(cols)} columns')
        if page is not None:
            series = Counter(f'{r.title} / {s.name}' for r in page.regions if isinstance(r, B.Chart)
                             for s in r.series)
            found = Counter(lbl for lbl, _ in extracted[pid] if ' / ' in lbl)
            k.check(f'{label}: every declared chart series once',
                    missing_extra(list(found.elements()), list(series.elements()), 'series'))

    item_names = [params['p_name'] for n, proc, params in calls if n == 'pages/page_00000'
                  and proc == 'create_page_item']
    k.check('filters: every declared item once', missing_extra(item_names, items, 'item'))
    shown = {params['p_name']: {int(p) for p in params['p_display_when'].split(',')}
             for n, proc, params in calls if n == 'pages/page_00000' and proc == 'create_page_item'}

    # ---- SQL texts ---------------------------------------------------------------------
    all_sql = [(pid, lbl, sql) for pid, lst in extracted.items() for lbl, sql in lst]
    k.check('sql: the region and chart texts are exactly the builder\'s',
            missing_extra({s for pid, lbl, s in all_sql if not lbl.endswith(' lov')}, declared['regions'],
                          'SQL text'), f'{len(all_sql)} texts extracted')
    k.check('sql: the LOV texts are exactly the builder\'s',
            missing_extra({s for pid, lbl, s in all_sql if lbl.endswith(' lov')}, declared['lovs'], 'LOV'))
    for pid, lbl, sql in all_sql:
        if pid == 0:  # a page-0 component runs on every page that shows it
            name = lbl[:-len(' lov')]
            pages = shown.get(name, set(B.CONTENT_PAGES))
            loaded = set.intersection(*[page_loads[p] for p in pages]) if pages else set()
        else:
            loaded = page_loads[pid]
        k.check(f'sql: page {pid} / {lbl}', sql_findings(sql, items, loaded))

    # ---- the two test scripts carry every text ----------------------------------------------
    texts = [s for _, _, s in all_sql] + [q for _, _, q in loads] + [q for q, _ in defaults]
    # the scripts indent the loader, so the comparison ignores the amount of white space
    flat = lambda s: re.sub(r'\s+', ' ', s)  # noqa: E731
    smoke = flat((APEX / 'test' / 'apex_smoke.sql').read_text())
    probe_raw = (APEX / 'test' / 'apex_probe.sql').read_text()
    probe = flat(probe_raw)
    k.check('smoke: every extracted SQL text is in apex_smoke.sql',
            [f'missing: {s[:70]}' for s in texts if flat(s) not in smoke], f'{len(texts)} texts')
    # the probe binds the items, so a default's v() calls are binds there
    as_bind = lambda s: re.sub(r"v\('(P0_\w+)'\)", r':\1', s)  # noqa: E731
    k.check('probe: every extracted SQL text is in apex_probe.sql, as the probe runs it',
            [f'missing: {s[:70]}' for s in texts if flat(B.probe_sql(s)) not in probe
             and flat(B.probe_sql(as_bind(s))) not in probe], f'{len(texts)} texts')
    k.check('probe: calls nothing of APEX',
            sorted(set(re.findall(r'\b(?:apex_(?:page|util|exec|session|collections?|application)|wwv_\w+)\b', probe_raw))))

    if k.failed:
        print(f'export_check: {k.count} checks, {k.failed} FAILED')
        sys.exit(1)
    print(f'export_check: {k.count} checks, all passed')


if __name__ == '__main__':
    main()
