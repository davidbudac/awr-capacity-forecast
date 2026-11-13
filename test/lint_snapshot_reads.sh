#!/usr/bin/env bash
# test/lint_snapshot_reads.sh -- a SNAPSHOT report reads stored tables only.
# Every FROM / JOIN of a CAP* object in the report drivers (report/report.sql,
# report_html.sql, report_brief.sql, report_csv.sql and report/sections/)
# must be one of:
#   * a view in cap_results.snap_views (ddl/60) followed by the snapshot
#     suffix variable &cap_s (~cap_s in report_brief.sql, whose data block
#     substitutes with ~ because its HTML entities use &);
#   * a <view>_S table named directly (the header's MAX(snap_run_id));
#   * &cap_alerts / ~cap_alerts (CAPR_ALERTS live, CAPR_ALERTS_LATEST under
#     SNAPSHOT);
#   * a cheap table-backed read listed in LIVE_OK.
# Also fails when a registry view is missing from ddl/00_drop.sql's list (its
# _S table would outlive an uninstall).
# Exit 1 and list the offenders on a violation.
set -u
cd "$(dirname "$0")/.." || exit 2
. test/repo_files.sh
LIVE_OK='cap_cfg capr_runs capr_alerts_latest capr_fit_history capr_fit_track dual'
python3 - "$LIVE_OK" $(repo_only report/sections/*.sql) <<'EOF'
import re, sys
live_ok = set(sys.argv[1].split())
ddl60 = open('ddl/60_results.sql').read()
m = re.search(r'FUNCTION snap_views RETURN SYS\.ODCIVARCHAR2LIST IS\s+BEGIN\s+RETURN SYS\.ODCIVARCHAR2LIST\((.*?)\);', ddl60, re.S)
if not m:
    print('lint_snapshot_reads: cannot find cap_results.snap_views in ddl/60_results.sql'); sys.exit(1)
reg = {v.lower() for v in re.findall(r"'([A-Z_]+)'", m.group(1))}
bad = 0
drop = open('ddl/00_drop.sql').read()
for v in sorted(reg):
    if "'" + v.upper() + "'" not in drop:
        print(f'lint_snapshot_reads: {v} is in snap_views but not in ddl/00_drop.sql'); bad = 1
files = ['report/report.sql', 'report/report_html.sql', 'report/report_brief.sql',
         'report/report_csv.sql'] + sorted(sys.argv[2:])
for f in files:
    for n, line in enumerate(open(f), 1):
        code = line.split('--', 1)[0]
        if re.match(r'\s*(prompt|pro)\b', code, re.I):
            continue
        mark = '~' if f == 'report/report_brief.sql' else '&'
        for r in re.finditer(r'\b(?:from|join)\s+([&~]?[a-z_][a-z0-9_$]*)([&~]cap_s\b)?', code, re.I):
            obj, suffix = r.group(1).lower(), r.group(2)
            if obj == mark + 'cap_alerts':
                continue
            if suffix and suffix[0] != mark:
                print(f'lint_snapshot_reads: {f}:{n} reads {obj}{suffix}: this file substitutes with {mark}'); bad = 1
                continue
            if not obj.startswith('cap') and obj != 'dual':
                continue
            if (obj in reg and suffix) or (obj.endswith('_s') and obj[:-2] in reg):
                continue
            if obj in live_ok:
                continue
            why = 'needs the &cap_s suffix' if obj in reg else 'is not in cap_results.snap_views'
            print(f'lint_snapshot_reads: {f}:{n} reads {obj}, which {why}'); bad = 1
if not bad:
    print('lint_snapshot_reads: OK')
sys.exit(bad)
EOF
