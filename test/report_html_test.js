// test/report_html_test.js -- runs report/html/report.js under a stub DOM.
// Usage: node test/report_html_test.js PAGE.html
// Takes the data block and the renderer out of a spooled report (or the docs
// demo), renders it, then renders it again with every data block emptied in
// turn (what a failed block leaves behind). The memory section is checked on
// the page's own memory blocks when it has them, and always on a memory
// fixture built here (two instances, every grade tone, both flags). Exit 1
// after all checks when any failed.
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
const shown = (html.match(/<article class="card (?!mem)/g) || []).length + (html.match(/<div class="row" id=/g) || []).length;
check(shown === metrics, 'one card or row per metric: ' + shown + ' of ' + metrics);
check((html.match(/<svg /g) || []).length >= metrics, 'every metric has a chart');
check(/^[\x00-\x7f]*$/.test(page), 'page is ASCII only');

// The memory section: one card per (dbid, instance), one row per verdict,
// one line per evidence row, one chart per instance with component points.
// Verdicts are advice: the alert tally, the banners and the nav tones must
// not change with them.
const count = (h, re) => (h.match(re) || []).length;
const between = (h, a, b) => { const i = h.indexOf(a); return i < 0 ? '' : h.slice(i, h.indexOf(b, i)); };
function checkMemory(h, data, what) {
  const vs = data.memVerdicts || [], ev = data.memEvidence || [], pts = data.memPoints || [];
  const inst = new Set(vs.map(v => v.dbid + '|' + v.inst));
  const charted = new Set(pts.map(p => p.dbid + '|' + p.inst).filter(k => inst.has(k)));
  const shownEv = ev.filter(e => inst.has(e.dbid + '|' + e.inst) && vs.some(v => v.dbid === e.dbid && v.inst === e.inst && v.area === e.area));
  check(h.includes('<section id="memory"') === inst.size > 0, what + ': memory section present exactly when it has verdicts (' + inst.size + ')');
  check(h.includes('href="#memory"') === inst.size > 0, what + ': memory in the nav and the overview exactly when it has verdicts');
  check(count(h, /<article class="card mem"/g) === inst.size, what + ': one memory card per instance (' + inst.size + ')');
  check(count(h, /<div class="mrow /g) === vs.length, what + ': one verdict row per verdict (' + vs.length + ')');
  check(count(h, /<details class="mev">/g) === new Set(shownEv.map(e => e.dbid + '|' + e.inst + '|' + e.area)).size, what + ': one evidence list per area with evidence');
  check(count(h, /<li class="(pr|sl|nu)">/g) === shownEv.length, what + ': one evidence line per signal (' + shownEv.length + ')');
  check(count(h, /<div class="mchart"/g) === charted.size, what + ': one component chart per instance with points (' + charted.size + ')');
  const comps = new Set(pts.filter(p => inst.has(p.dbid + '|' + p.inst)).map(p => p.dbid + '|' + p.inst + '|' + p.c));
  check(count(h, /<div class="mlr">/g) === comps.size, what + ': every component in the legend (' + comps.size + ')');
  for (const v of vs) {
    check(!v.hl || h.includes(v.hl.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')), what + ': headline of ' + v.area + ' shown');
  }
}
checkMemory(html, d, 'page data');

// A memory fixture on the page's first database: instance 1 has every area
// and component points, instance 2 the other grade tones, no mode, NULL sizes
// and both flags, and no points.
const root = (d.containers || []).find(c => c.pdb === 'CDB$ROOT') || (d.containers || [])[0] || { dbid: 1, con: 1 };
const GiB = 1073741824, MiB = 1048576;
const verdict = (inst, ar, area, al, g, act, o) => Object.assign({
  dbid: root.dbid, con: root.con, inst, area, al, ar, mode: 'ASMM', g, act, cur: 4 * GiB, sug: null,
  curS: '4 GiB', sugS: null, chg: null, par: null, ram: null, sga: null, nd: 30,
  w0: '2026-10-11', w1: '2026-11-10', hl: al + ' needs no change.', why: 'Neither a larger nor a smaller size would change much.'
}, o);
const memVerdicts = [
  verdict(1, 1, 'SGA_TOTAL', 'SGA total', 'OK', 'N', { par: 'sga_target' }),
  verdict(1, 2, 'BUFFER_CACHE', 'Buffer cache', 'OVERSIZED', 'Y', { cur: 2560 * MiB, sug: 1536 * MiB, curS: '2560 MiB', sugS: '1536 MiB', chg: -40, par: 'db_cache_size', sga: 'N', hl: 'Buffer cache is oversized. It could shrink from 2560 MiB to 1536 MiB.' }),
  verdict(1, 3, 'SHARED_POOL', 'Shared pool', 'UNDERSIZED', 'Y', { cur: GiB, sug: 1536 * MiB, curS: '1 GiB', sugS: '1536 MiB', chg: 50, par: 'shared_pool_size', sga: 'Y', hl: 'Shared pool is undersized. Set shared_pool_size to at least 1536 MiB (the pool holds 1 GiB now). That does not fit in sga_target: raise sga_target first.' }),
  verdict(1, 4, 'SGA_BALANCE', 'SGA balance', 'DRIFTING', 'Y', { why: 'One pool was squeezed in favour of the other. See the SGA total verdict.', hl: 'SGA balance is drifting.' }),
  verdict(1, 5, 'PGA_TARGET', 'PGA target', 'UNDERSIZED', 'Y', { cur: GiB, sug: 1792 * MiB, curS: '1 GiB', sugS: '1792 MiB', chg: 75, par: 'pga_aggregate_target', ram: 'Y', hl: "PGA target is undersized. Raise pga_aggregate_target from 1 GiB to 1792 MiB. With the rest of the instance that passes 80% of the host's memory." }),
  verdict(1, 6, 'PGA_LIMIT', 'PGA limit', 'UNDERSIZED', 'Y', { cur: 2 * GiB, sug: 2267021312, curS: '2 GiB', sugS: '2162 MiB', chg: 5.6, par: 'pga_aggregate_limit', ram: 'N' }),
  verdict(2, 4, 'SGA_BALANCE', 'SGA balance', 'THRASHING', 'Y', { mode: null, sug: 1536 * MiB, sugS: '1536 MiB', par: 'db_cache_size', hl: 'SGA balance is thrashing. Set db_cache_size to at least 1536 MiB.' }),
  verdict(2, 1, 'SGA_TOTAL', 'SGA total', 'INSUFFICIENT_EVIDENCE', 'N', { mode: null, cur: null, curS: null, w0: null, nd: null, hl: 'SGA total could not be judged.', why: 'The advisor has too little history at or near the current size.' })
];
const signal = (inst, area, kind, dir, txt) => ({ dbid: root.dbid, con: root.con, inst, area, kind, dir, txt });
const memEvidence = [
  signal(1, 'SGA_TOTAL', 'ADVISOR', 'NEUTRAL', 'The SGA advisor estimates 0.30% of DB time saved at 6.00 GiB against the current 4.00 GiB (threshold 1%).'),
  signal(1, 'BUFFER_CACHE', 'ADVISOR', 'SLACK', 'The buffer cache advisor estimates 0.45% of DB time lost at 1.50 GiB against the current 2.50 GiB (threshold 0.5%).'),
  signal(1, 'SHARED_POOL', 'ADVISOR', 'PRESSURE', 'The shared pool advisor estimates 1.50% of DB time saved at 2.00 GiB against the current 1.00 GiB (threshold 1%).'),
  signal(1, 'SHARED_POOL', 'SYMPTOM', 'NEUTRAL', 'Library cache reloads were 0.40% of pins in the window (threshold 1%).'),
  signal(1, 'PGA_TARGET', 'SYMPTOM', 'PRESSURE', 'Multi-pass executions were 0.20% of all work area executions in the window (threshold 0.1%).'),
  signal(1, 'PGA_LIMIT', 'USAGE', 'PRESSURE', 'The PGA high-water mark rose to 1.90 GiB at 2026-10-31 18:00, 95.00% of pga_aggregate_limit 2.00 GiB (threshold 90%).'),
  signal(2, 'SGA_BALANCE', 'SYMPTOM', 'PRESSURE', 'The SGA components were resized 14.00 times per sampled day in the window (threshold 10 a day).')
];
const series = (c, f) => ({ dbid: root.dbid, con: root.con, inst: 1, c, t0: '2026-10-12', d: Array.from({ length: 30 }, (_, i) => f(i)) });
const memPoints = [
  series('DEFAULT buffer cache', i => i === 20 ? [i, 2432 * MiB, 2432 * MiB, 2560 * MiB, 2] : [i, (i > 20 ? 2432 : 2560) * MiB, (i > 20 ? 2432 : 2560) * MiB, (i > 20 ? 2432 : 2560) * MiB, 0]),
  series('shared pool', i => [i, (i >= 20 ? 1152 : 1024) * MiB, (i > 20 ? 1152 : 1024) * MiB, (i >= 20 ? 1152 : 1024) * MiB, i === 20 ? 2 : 0]),
  series('java pool', i => [i, 64 * MiB, 64 * MiB, 64 * MiB, 0]),
  series('large pool', i => [i, 64 * MiB, 64 * MiB, 64 * MiB, 0])
];
const mem = Object.assign({}, d, { memVerdicts, memEvidence, memPoints });
const mh = render(JSON.stringify(mem));
checkMemory(mh, mem, 'memory fixture');
for (const bad of ['undefined', 'NaN', '>null<', 'Infinity']) {
  check(!mh.includes(bad), 'memory fixture render has no "' + bad + '"');
}
check(mh.includes('<span class="ctr">instance 2</span>'), 'memory fixture: a database with two instances names them');
check(count(mh, /<span class="gp act">/g) === 6 && count(mh, /<span class="gp ie">/g) === 1 && count(mh, /<span class="gp ok">/g) === 1, 'memory fixture: grade tones (6 advised, 1 OK, 1 insufficient)');
check(mh.includes('over the host memory share') && mh.includes('does not fit in sga_target</span>'), 'memory fixture: both flags shown');
check(count(mh, /class="mrz"/g) === 1, 'memory fixture: one resize day marked');
check(between(mh, '<div class="tally">', '<h3>').length > 0 && between(mh, '<div class="tally">', '<h3>') === between(html, '<div class="tally">', '<h3>'), 'memory fixture: the alert tally is unchanged');
check(count(mh, /class="banner/g) === count(html, /class="banner/g), 'memory fixture: no banner from the verdicts');
check(/<h1>[^<]*<\/h1>/.exec(mh)[0] === /<h1>[^<]*<\/h1>/.exec(html)[0], 'memory fixture: the headline is unchanged');
check(/<a href="#memory">Memory<span class="n">2<\/span><\/a>/.test(mh), 'memory fixture: nav link without a severity tone');
check(mh.indexOf('<section id="memory"') > mh.indexOf('<div class="secgrid">'), 'memory fixture: the section sits among the metric sections');

for (const block of Object.keys(mem).filter(k => Array.isArray(mem[k]))) {
  const cut = Object.assign({}, mem, { [block]: [] });
  try {
    const h = render(JSON.stringify(cut));
    check(!h.includes('undefined') && !h.includes('NaN'), 'render without "' + block + '" is clean');
    if (/^mem/.test(block)) checkMemory(h, cut, 'without "' + block + '"');
  } catch (e) {
    check(false, 'render without "' + block + '" throws: ' + e.message);
  }
}
try {
  const failed = Object.assign({}, d, { memVerdicts: [], memEvidence, memPoints, errors: [{ block: 'memVerdicts', msg: 'ORA-00942: table or view does not exist' }] });
  const h = render(JSON.stringify(failed));
  check(!h.includes('<section id="memory"') && h.includes('Data block \u201cmemVerdicts\u201d failed: ORA-00942'), 'a failed memVerdicts block is named and leaves no memory section');
} catch (e) {
  check(false, 'render with a failed memVerdicts block throws: ' + e.message);
}
try {
  render(JSON.stringify({ meta: d.meta, errors: [{ block: 'fits', msg: 'ORA-00942' }] }));
} catch (e) {
  check(false, 'render with only meta throws: ' + e.message);
}

// The I/O rate series (IOPS, IO_MBPS): no limit, like redo. The page's own
// data has them only when its source collected the I/O counters, so two are
// built here from the redo series: a section each, the unit on the card, no
// "soonest" countdown.
try {
  const redoFit = d.fits.filter(f => f.s === 'REDO_GB_DAY')[0];
  const redoPts = d.points.filter(p => p.s === 'REDO_GB_DAY' && p.dbid === redoFit.dbid && p.con === redoFit.con)[0];
  const io = [['IOPS', 'io_per_sec', 3090, 9.5, 'OK'], ['IO_MBPS', 'mb_per_sec', 48.5, 0, 'FLAT']];
  const withIo = Object.assign({}, d, {
    fits: d.fits.filter(f => f.s !== 'IOPS' && f.s !== 'IO_MBPS').concat(io.map(x => Object.assign({}, redoFit, { s: x[0], u: x[1], v: x[2], slope: x[3], q: x[4] }))),
    points: d.points.filter(p => p.s !== 'IOPS' && p.s !== 'IO_MBPS').concat(io.map(x => Object.assign({}, redoPts, { s: x[0], d: redoPts.d.map(r => [r[0], x[2] + x[3] * (r[0] - redoPts.d.length + 1), null, 0, 0]) })))
  });
  const h = render(JSON.stringify(withIo));
  check(!h.includes('undefined') && !h.includes('NaN'), 'render with IOPS / IO_MBPS is clean');
  const sec = id => between(h, '<section id="' + id + '"', '</section>');
  check(sec('iops').includes('I/O requests') && sec('iops').includes('3,090 IO/s') && sec('iops').includes('Busy-hour p95'), 'section iops shows the latest p95 in IO/s');
  check(sec('io-mbps').includes('I/O throughput') && sec('io-mbps').includes('48.5 MB/s'), 'section io-mbps shows the latest p95 in MB/s');
  check(!sec('iops').includes('soonest') && !sec('io-mbps').includes('soonest'), 'the I/O sections have no countdown');
  check(sec('redo').includes('today'), 'the redo headline still reads "today"');
} catch (e) {
  check(false, 'render with IOPS / IO_MBPS throws: ' + e.message);
}

// The forecast track record (block "track", CAPR_FIT_TRACK): one line on
// every card whose series has a row, a tag on the card only for BIASED and
// WIDE, the band at the factor only when the factor widens it. Advice, like
// the memory verdicts: the alert tally does not move. The page's own data
// may carry no block.
try {
  const cards = h => count(h, /<article class="card (?!mem)/g);
  check((d.track || []).length > 0 || !html.includes('<p class="trk'), 'no track block: no track line');
  const withTrack = (rel, f) => render(JSON.stringify(Object.assign({}, d, {
    track: d.fits.map(x => ({ k: x.k, dbid: x.dbid, con: x.con, s: x.s, n: 12, err: 3.2, bias: 1.1, nb: 12, hits: 10,
      f: f, lo: f ? 1 : null, hi: f ? 2 : null, rel: rel, txt: 'TRACK-' + rel + ' <b>' }))
  })));
  const wide = withTrack('WIDE', 1.4), biased = withTrack('BIASED', 1), good = withTrack('GOOD', 1), unk = withTrack('UNKNOWN', null);
  const n = cards(html);
  for (const [h, what] of [[wide, 'WIDE'], [biased, 'BIASED'], [good, 'GOOD'], [unk, 'UNKNOWN']]) {
    check(!h.includes('undefined') && !h.includes('NaN') && !h.includes('>null<'), 'track ' + what + ': render is clean');
    check(cards(h) === n && count(h, /<p class="trk/g) === n, 'track ' + what + ': one line per card (' + n + ')');
    check(h.includes('TRACK-' + what + ' &lt;b&gt;') && !h.includes('TRACK-' + what + ' <b>'), 'track ' + what + ': the sentence is escaped');
    check(between(h, '<div class="tally">', '<h3>') === between(html, '<div class="tally">', '<h3>'), 'track ' + what + ': the alert tally is unchanged');
  }
  check(n > 0 && count(wide, /<p class="trk off">/g) === n && count(wide, /<span class="tag rel">band too narrow<\/span>/g) === n, 'track WIDE: marked line and tag on every card');
  check(count(wide, /<span class="cal">/g) === n, 'track WIDE: the band at the factor is shown');
  const flat = render(JSON.stringify(Object.assign({}, d, {
    track: d.fits.map(x => ({ k: x.k, dbid: x.dbid, con: x.con, s: x.s, n: 12, err: 3.2, bias: 1.1, nb: 12, hits: 10, f: 1.4, lo: 5, hi: 5, rel: 'WIDE', txt: 'flat' }))
  })));
  check(!flat.includes('<span class="cal">'), 'track WIDE on a band of width 0 today: no band at the factor');
  check(count(biased, /<p class="trk off">/g) === n && count(biased, /<span class="tag rel">forecasts biased<\/span>/g) === n && !biased.includes('<span class="cal">'), 'track BIASED: marked line and tag, no band at factor 1');
  check(count(good, /<p class="trk">/g) === n && !good.includes('class="tag rel"') && !good.includes('<span class="cal">'), 'track GOOD: a plain line, no tag');
  check(count(unk, /<p class="trk unk">/g) === n && !unk.includes('class="tag rel"') && !unk.includes('<span class="cal">'), 'track UNKNOWN: a muted line, no tag');
} catch (e) {
  check(false, 'render with a track block throws: ' + e.message);
}

if (failures) process.exit(1);
console.log('OK   report_html: ' + metrics + ' metrics rendered, ' + count(html, /<article class="card mem"/g) + ' memory cards of the page, memory fixture ' +
  count(mh, /<article class="card mem"/g) + ' cards / ' + count(mh, /<div class="mrow /g) + ' verdicts / ' + count(mh, /<li class="(pr|sl|nu)">/g) + ' evidence lines, every block optional');
