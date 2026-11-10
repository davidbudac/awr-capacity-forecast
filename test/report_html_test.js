// test/report_html_test.js -- runs report/html/report.js under a stub DOM.
// Usage: node test/report_html_test.js PAGE.html
// Takes the data block and the renderer out of a spooled report (or the docs
// demo), renders it, then renders it again with every data block emptied in
// turn (what a failed block leaves behind). Exit 1 on the first failure.
'use strict';
const fs = require('fs');
const vm = require('vm');

const page = fs.readFileSync(process.argv[2], 'utf8');
const data = /<script type="application\/json" id="cap-data">\s*([\s\S]*?)\s*<\/script>/.exec(page)[1];
const scripts = [...page.matchAll(/<script>\s*([\s\S]*?)<\/script>/g)];
const renderer = scripts[scripts.length - 1][1];
let failures = 0;

function check(ok, what) {
  if (!ok) { failures++; console.log('FAIL ' + what); }
}

function render(json) {
  const stub = () => ({
    innerHTML: '', textContent: '', style: {}, onclick: null,
    classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    setAttribute() {}, getAttribute() { return null; }, addEventListener() {},
    querySelector() { return null; }, querySelectorAll() { return []; }, appendChild() {}
  });
  const app = stub();
  const document = {
    title: '',
    documentElement: stub(),
    createElement: stub,
    querySelectorAll: () => [],
    getElementById: (id) => id === 'cap-data' ? { textContent: json } : id === 'app' ? app : stub()
  };
  const window = { matchMedia: () => ({ matches: false }) };
  const localStorage = { getItem: () => null, setItem() {} };
  vm.runInNewContext(renderer, { document, window, localStorage, console });
  return app.innerHTML;
}

const d = JSON.parse(data);
const html = render(data);
check(html.length > 1000, 'full render produced a page');
for (const bad of ['undefined', 'NaN', '>null<', 'Infinity']) {
  check(!html.includes(bad), 'full render has no "' + bad + '"');
}
const families = [
  ['tablespaces', f => f.k === 'TBSPC'], ['host-cpu', f => f.k === 'CPU' && f.s === 'BUSY_P95'],
  ['db-cpu', f => f.k === 'CPU' && f.s === 'DB_CPU_P95'], ['db-size', f => f.s === 'DB_SIZE_GB'],
  ['sessions', f => f.s === 'SESSIONS'], ['processes', f => f.s === 'PROCESSES'],
  ['pga', f => f.s === 'PGA_ALLOC_GB'],
  ['redo', f => f.s === 'REDO_GB_DAY'], ['undo', f => /^UNDO_PEAK:/.test(f.s)],
  ['temp', f => /^TEMP_PEAK:/.test(f.s)], ['asm', f => /^ASM_DG:/.test(f.s)]
];
let metrics = 0;
for (const [id, match] of families) {
  const n = d.fits.filter(match).length;
  metrics += n;
  check(html.includes('<section id="' + id + '"') === n > 0, 'section ' + id + ' present exactly when it has series (' + n + ')');
}
const shown = (html.match(/<article class="card /g) || []).length + (html.match(/<div class="row" id=/g) || []).length;
check(shown === metrics, 'one card or row per metric: ' + shown + ' of ' + metrics);
check((html.match(/<svg /g) || []).length >= metrics, 'every metric has a chart');
check(/^[\x00-\x7f]*$/.test(page), 'page is ASCII only');

for (const block of Object.keys(d).filter(k => Array.isArray(d[k]))) {
  const cut = Object.assign({}, d, { [block]: [] });
  try {
    const h = render(JSON.stringify(cut));
    check(!h.includes('undefined') && !h.includes('NaN'), 'render without "' + block + '" is clean');
  } catch (e) {
    check(false, 'render without "' + block + '" throws: ' + e.message);
  }
}
try {
  render(JSON.stringify({ meta: d.meta, errors: [{ block: 'fits', msg: 'ORA-00942' }] }));
} catch (e) {
  check(false, 'render with only meta throws: ' + e.message);
}

if (failures) process.exit(1);
console.log('OK   report_html: ' + metrics + ' metrics rendered, every block optional');
