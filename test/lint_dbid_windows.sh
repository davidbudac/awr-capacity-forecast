#!/usr/bin/env bash
# test/lint_dbid_windows.sh -- every analytic window in the CAPD / CAPF / CAPA /
# CAPR views (ddl/20..ddl/55) partitions by dbid, so one database's ranks and
# anchors never depend on another target's rows (M24.13). A scoped report
# (seam scope) and the unscoped refresh that fills the SNAPSHOT tables then
# agree row for row. ALLOW lists "<file>:<clause prefix>" for a window over a
# key that already embeds the dbid, and for CAPA_ANOM's obs_id (an internal
# row id, not a rank).
# Exit 1 and list the offenders on a violation.
set -u
cd "$(dirname "$0")/.." || exit 2
ALLOW='ddl/40_anomaly_views.sql:order by o.dbid, o.con_dbid, o.kind, o.series, o.grain, o.ts
ddl/40_anomaly_views.sql:partition by h.pid
ddl/50_ml.sql:partition by m.model_name'
python3 - "$ALLOW" ddl/2[0-9]_*.sql ddl/3[0-9]_*.sql ddl/4[0-9]_*.sql ddl/5[0-9]_*.sql <<'EOF'
import re, sys
allow = set(sys.argv[1].splitlines())
bad = 0
for f in sys.argv[2:]:
    src = re.sub(r'--[^\n]*', '', open(f).read())
    for m in re.finditer(r'\bOVER\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)', src, re.I):
        clause = ' '.join(m.group(1).split()).lower()
        part = re.match(r'partition by (.*?)(?: order by .*)?$', clause)
        keys = [k.strip() for k in part.group(1).split(',')] if part else []
        if any(re.fullmatch(r'(\w+\.)?dbid', k) for k in keys):
            continue
        if any((f + ':' + clause).startswith(a) for a in allow):
            continue
        line = src[:m.start()].count('\n') + 1
        print(f'lint_dbid_windows: {f}:{line} OVER ({clause}) does not partition by dbid')
        bad = 1
if not bad:
    print('lint_dbid_windows: OK')
sys.exit(bad)
EOF
