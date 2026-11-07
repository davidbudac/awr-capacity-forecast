#!/usr/bin/env bash
# test/report_html_test.sh -- the HTML report renderer, no database needed.
#   1. report/html/page_head.sql / page_tail.sql match report.css / report.js
#      (python3 report/html/build.py --check);
#   2. docs/demo/cap_report_demo.html carries the current CSS and renderer
#      (rebuilt from its own data block, it must come out identical);
#   3. test/report_html_test.js renders the demo under a stub DOM: one section
#      per metric family with data, a chart per metric, ASCII only, and no
#      crash when any data block is empty.
set -u
cd "$(dirname "$0")/.." || exit 2
rc=0
python3 report/html/build.py --check || rc=1
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
python3 report/html/build.py --preview docs/demo/cap_report_demo.html "$tmp"
if cmp -s "$tmp" docs/demo/cap_report_demo.html; then
  echo "OK   docs/demo/cap_report_demo.html is current"
else
  echo "FAIL docs/demo/cap_report_demo.html is stale: python3 report/html/build.py --preview docs/demo/cap_report_demo.html docs/demo/cap_report_demo.html"
  rc=1
fi
node test/report_html_test.js docs/demo/cap_report_demo.html || rc=1
exit $rc
