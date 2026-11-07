(function () {
  'use strict';

  var D = JSON.parse(document.getElementById('cap-data').textContent);
  var M = D.meta || {};
  var K = M.knobs || {};
  var TOP_N = M.topN || 10;
  var ANOM_DAYS = M.anomalyDays || 30;
  var CPU_SAT = K.cpuSat || 80;
  var SERIES_SAT = K.seriesSat || 90;
  var MS_DAY = 864e5;
  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  var WDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  var SEV_RANK = { CRIT: 0, WARN: 1, INFO: 2, OK: 3 };
  var SEV_CLASS = { CRIT: 'crit', WARN: 'warn', INFO: 'info', OK: 'ok' };
  var SEV_LABEL = { CRIT: 'Critical', WARN: 'Warning', INFO: 'Info', OK: 'OK' };
  var ALERT_FACT = {
    TBSPC_NEARFULL: 'pct', SERIES_NEARLIMIT: 'pct', TBSPC_FULL: 'dtf', CPU_SAT: 'dtf', DBCPU_SAT: 'dtf',
    SERIES_LIMIT: 'dtf', CPU_HOT: 'now', DBCPU_HOT: 'now'
  };
  var QUALITY_TAG = {
    FLAT: 'flat', CYCLIC: 'cyclic', LOW_CONFIDENCE: 'low confidence',
    INSUFFICIENT_HISTORY: 'short history'
  };

  /* ---------- formatting ---------- */

  function dayN(s) { return s ? Date.UTC(+s.slice(0, 4), +s.slice(5, 7) - 1, +s.slice(8, 10)) / MS_DAY : null; }
  function dateOf(n) { return new Date(n * MS_DAY); }
  function fDay(n) { var d = dateOf(n); return d.getUTCDate() + ' ' + MONTHS[d.getUTCMonth()]; }
  function fDayY(n) { var d = dateOf(n); return d.getUTCDate() + ' ' + MONTHS[d.getUTCMonth()] + ' ' + d.getUTCFullYear(); }
  function fWDay(n) { var d = dateOf(n); return WDAYS[d.getUTCDay()] + ' ' + d.getUTCDate() + ' ' + MONTHS[d.getUTCMonth()]; }
  var LAST = dayN(M.lastDay);
  var FIRST = dayN(M.firstDay);
  var GEN = dayN(M.generated);

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }
  function num(v, dp) {
    if (v == null || !isFinite(v)) return '–';
    return Number(v).toLocaleString('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp });
  }
  function auto(v) {
    if (v == null) return '–';
    var a = Math.abs(v);
    if (a === 0) return '0';
    return num(v, a >= 100 ? 0 : a >= 10 ? 1 : 2);
  }
  var BYTE_UNITS = [['TiB', Math.pow(1024, 4)], ['GiB', Math.pow(1024, 3)], ['MiB', Math.pow(1024, 2)], ['KiB', 1024]];
  function byteUnit(maxAbs) {
    for (var i = 0; i < BYTE_UNITS.length; i++) if (maxAbs >= BYTE_UNITS[i][1]) return BYTE_UNITS[i];
    return ['B', 1];
  }
  function fBytes(b) {
    if (b == null) return '–';
    var u = byteUnit(Math.abs(b) * 1.0001);
    return auto(b / u[1]) + ' ' + u[0];
  }
  function sign(v) { return v > 0 ? '+' : v < 0 ? '−' : ''; }
  function fDays(d) {
    if (d == null) return '–';
    if (d < 1) return '< 1 d';
    if (d <= 120) return Math.round(d) + ' d';
    if (d < 730) return Math.round(d / 30.4) + ' mo';
    if (d > 3650) return '> 10 y';
    return num(d / 365.25, 1) + ' y';
  }

  /* ---------- units: one object per unit, value <-> display ---------- */

  function unitFor(u, maxAbs) {
    u = (u || '').toLowerCase();
    if (u === 'bytes') {
      var bu = byteUnit(maxAbs || 0);
      return {
        scale: bu[1], short: bu[0],
        fmt: function (v) { return v == null ? '–' : auto(v / bu[1]) + ' ' + bu[0]; },
        rate: function (v) { return v == null ? '–' : sign(v) + fBytes(Math.abs(v)) + '/d'; },
        rateLabel: 'Growth'
      };
    }
    if (u === 'pct') {
      return {
        scale: 1, short: '%',
        fmt: function (v) { return v == null ? '–' : num(v, 1) + '%'; },
        rate: function (v) { return v == null ? '–' : sign(v) + num(Math.abs(v) * 30, 1) + ' pts'; },
        rateLabel: 'Change per 30 d'
      };
    }
    if (u === 'gib' || u === 'gib_per_day') {
      var perDay = u === 'gib_per_day' ? '/d' : '';
      return {
        scale: 1, short: 'GiB' + perDay,
        fmt: function (v) { return v == null ? '–' : fBytes(v * Math.pow(1024, 3)) + perDay; },
        rate: function (v) {
          if (v == null) return '–';
          return perDay ? sign(v) + auto(Math.abs(v) * 30) + ' GiB/d' : sign(v) + fBytes(Math.abs(v) * Math.pow(1024, 3)) + '/d';
        },
        rateLabel: perDay ? 'Change per 30 d' : 'Growth'
      };
    }
    return {
      scale: 1, short: '',
      fmt: function (v) { return v == null ? '–' : auto(v); },
      rate: function (v) { return v == null ? '–' : sign(v) + auto(Math.abs(v)) + '/d'; },
      rateLabel: 'Trend'
    };
  }

  /* ---------- indexes over the data blocks ---------- */

  function key() { return Array.prototype.join.call(arguments, '|'); }
  function groupBy(rows, kf) {
    var m = {};
    (rows || []).forEach(function (r) { var k = kf(r); (m[k] = m[k] || []).push(r); });
    return m;
  }
  var CON = {};
  (D.containers || []).forEach(function (c) { CON[key(c.dbid, c.con)] = c; });
  function conLabel(dbid, con) {
    var c = CON[key(dbid, con)];
    return c ? c.label : String(con);
  }
  function conName(dbid, con) {
    var c = CON[key(dbid, con)];
    if (!c) return String(con);
    return c.pdb && c.pdb !== 'CDB$ROOT' ? c.pdb : c.db;
  }
  function conKind(dbid, con) {
    var c = CON[key(dbid, con)];
    if (!c || !c.pdb) return 'database';
    return c.pdb === 'CDB$ROOT' ? 'CDB root' : 'PDB of ' + c.db;
  }
  var FIT = {};
  (D.fits || []).forEach(function (f) { FIT[key(f.k, f.dbid, f.con, f.s)] = f; });
  var PTS = {};
  (D.points || []).forEach(function (p) {
    var t0 = dayN(p.t0);
    PTS[key(p.k, p.dbid, p.con, p.s)] = p.d.map(function (r) {
      return { x: t0 + r[0], y: r[1], lim: r[2], a: r[3], gap: r[4] };
    });
  });
  var FC = groupBy(D.forecast, function (r) { return key(r.k, r.dbid, r.con, r.s); });
  var AN = groupBy(D.anomalies, function (r) { return key(r.dbid, r.con, r.s); });
  var AL = groupBy(D.alerts, function (r) { return key(r.dbid, r.con, r.s); });
  var HOURS = {};
  (D.hours || []).forEach(function (h) { HOURS[key(h.dbid, h.con, h.s)] = h; });

  /* ---------- the metric families: one report section each ---------- */

  function seriesIs(name) { return function (f) { return f.k === 'SERIES' && f.s === name; }; }
  function seriesPrefix(pfx) { return function (f) { return f.k === 'SERIES' && f.s.indexOf(pfx) === 0; }; }

  var FAMILIES = [
    { id: 'tablespaces', title: 'Tablespaces', noun: 'tablespace', match: function (f) { return f.k === 'TBSPC'; },
      name: function (f) { return f.s; }, facts: tbspcFacts },
    { id: 'db-size', perContainer: true, title: 'Database size', noun: 'container', match: seriesIs('DB_SIZE_GB'),
      name: function (f) { return conName(f.dbid, f.con); }, facts: limitFacts('Used', 'allocated') },
    { id: 'host-cpu', title: 'Host CPU', noun: 'host', match: function (f) { return f.k === 'CPU' && f.s === 'BUSY_P95'; },
      name: function (f) { return CON[key(f.dbid, f.con)] ? CON[key(f.dbid, f.con)].db : conName(f.dbid, f.con); },
      related: ['BUSY_PCT', 'BUSY_PEAK'], lines: [['BUSY_P95', 'busy-hour p95'], ['BUSY_PCT', 'daily average']],
      facts: hostCpuFacts, heat: 'BUSY_PCT' },
    { id: 'db-cpu', perContainer: true, title: 'DB CPU', noun: 'container', match: function (f) { return f.k === 'CPU' && f.s === 'DB_CPU_P95'; },
      name: function (f) { return conName(f.dbid, f.con); },
      related: ['DB_CPU_PCT', 'DB_CPU_SEC'], lines: [['DB_CPU_P95', 'busy-hour p95'], ['DB_CPU_PCT', 'daily average']],
      facts: dbCpuFacts, heat: 'DB_CPU_PCT' },
    { id: 'sessions', perContainer: true, title: 'Sessions', noun: 'container', match: seriesIs('SESSIONS'),
      name: function (f) { return conName(f.dbid, f.con); }, facts: limitFacts('Peak', 'limit') },
    { id: 'processes', perContainer: true, title: 'Processes', noun: 'container', match: seriesIs('PROCESSES'),
      name: function (f) { return conName(f.dbid, f.con); }, facts: limitFacts('Peak', 'limit') },
    { id: 'redo', perContainer: true, title: 'Redo', noun: 'database', match: seriesIs('REDO_GB_DAY'),
      name: function (f) { return conName(f.dbid, f.con); }, facts: redoFacts },
    { id: 'undo', title: 'Undo', noun: 'tablespace', match: seriesPrefix('UNDO_PEAK:'),
      name: function (f) { return f.s.slice(10); }, facts: limitFacts('Peak', 'max size') },
    { id: 'temp', title: 'Temp', noun: 'tablespace', match: seriesPrefix('TEMP_PEAK:'),
      name: function (f) { return f.s.slice(10); }, facts: limitFacts('Peak', 'max size') },
    { id: 'asm', title: 'ASM disk groups', noun: 'disk group', match: seriesPrefix('ASM_DG:'),
      name: function (f) { return f.s.slice(7); }, facts: limitFacts('Used', 'total') }
  ];

  function worstSev(list) {
    var best = 'OK';
    list.forEach(function (s) { if (s && SEV_RANK[s] != null && SEV_RANK[s] < SEV_RANK[best]) best = s; });
    return best;
  }

  /* A metric: the unit a card shows. Built once from its fit rows. */
  function buildMetric(fam, f) {
    var names = [f.s].concat(fam.related || []);
    var fits = {};
    names.forEach(function (s) { fits[s] = FIT[key(f.k, f.dbid, f.con, s)]; });
    var alerts = [], anoms = [];
    names.forEach(function (s) {
      alerts = alerts.concat(AL[key(f.dbid, f.con, s)] || []);
      anoms = anoms.concat(AN[key(f.dbid, f.con, s)] || []);
    });
    alerts.sort(function (a, b) {
      return SEV_RANK[a.sev] - SEV_RANK[b.sev] || (/_ANOM$/.test(a.kind) ? 1 : 0) - (/_ANOM$/.test(b.kind) ? 1 : 0);
    });
    var m = {
      fam: fam, f: f, fits: fits, alerts: alerts, anoms: anoms,
      id: fam.id + '-' + String(f.dbid) + '-' + String(f.con) + '-' + f.s.replace(/[^A-Za-z0-9]+/g, '_'),
      name: fam.name(f), ctr: conLabel(f.dbid, f.con),
      pts: PTS[key(f.k, f.dbid, f.con, f.s)] || [],
      fc: FC[key(f.k, f.dbid, f.con, f.s)] || []
    };
    if (fam.perContainer) m.ctr = conKind(f.dbid, f.con);
    if (fam.id === 'host-cpu') m.ctr = 'host';
    m.sev = worstSev(alerts.map(function (a) { return a.sev; }).concat([f.sev]));
    m.unit = unitFor(f.u, Math.max(Math.abs(f.v || 0), Math.abs(f.lim || 0)));
    m.facts = fam.facts(m);
    alerts.forEach(function (a) {
      var fk = ALERT_FACT[a.kind], tone = a.sev === 'CRIT' ? 'crit' : a.sev === 'WARN' ? 'warn' : null;
      m.facts.forEach(function (x) {
        if (fk && x.k === fk && tone && (x.tone !== 'crit')) x.tone = tone;
      });
    });
    m.order = [SEV_RANK[m.sev], f.dtf == null ? 1e9 : f.dtf, -(f.pct || 0)];
    return m;
  }

  /* ---------- facts per family ---------- */

  function dtfFact(f, label) {
    var tone = '';
    if (f.dtf != null && f.q === 'OK') tone = f.dtf <= K.dtfCrit ? 'crit' : f.dtf <= K.dtfWarn ? 'warn' : '';
    var sub = '';
    if (f.dtf != null) {
      if (f.dtf > 3650) return { k: 'dtf', l: label, v: fDays(f.dtf), s: 'not in sight', tone: 'muted' };
      sub = '→ ' + fDay(LAST + f.dtf) + (f.dtfLo != null && f.dtfHi != null && Math.round(f.dtfLo) !== Math.round(f.dtfHi)
        ? ' · ' + Math.round(f.dtfLo) + '–' + Math.round(f.dtfHi) + ' d' : '');
    } else if (f.q === 'FLAT') sub = 'no growth';
    else if (f.q === 'CYCLIC') sub = 'peaks not growing';
    else if (f.slope != null && f.slope <= 0) sub = 'not growing';
    else sub = 'beyond the forecast';
    return { k: 'dtf', l: label, v: f.dtf != null ? fDays(f.dtf) : '–', s: sub, tone: f.dtf == null ? 'muted' : tone };
  }

  function stamp(d) { return '<span class="stamp">→ ' + fDay(Math.round(d)) + '</span>'; }

  function pctTone(p, warn, crit) { return p == null ? '' : p >= crit ? 'crit' : p >= warn ? 'warn' : ''; }

  function tbspcFacts(m) {
    var f = m.f, out = [];
    out.push({ k: 'pct', l: 'Used', v: num(f.pct, 1) + '<small>%</small>', s: m.unit.fmt(f.v) + ' of ' + m.unit.fmt(f.lim),
      tone: pctTone(f.pct, K.nfWarn, K.nfCrit) });
    if (f.q === 'CYCLIC') {
      out.push({ l: 'Cycle peak', v: num(f.cycPk, 1) + '<small>%</small>', s: (f.cycN || 0) + ' purges, every ' + Math.round(f.cycD || 0) + ' d' });
      out.push({ l: 'Peak growth', v: m.unit.rate(f.pkSlope) });
    } else {
      out.push({ l: 'Growth', v: m.unit.rate(f.slope), s: f.accel != null && f.accel >= 1.5 ? 'accelerating ×' + num(f.accel, 1) : 'fit over ' + (f.n || '–') + ' d' });
    }
    out.push(dtfFact(f, 'Full in'));
    if (f.need90 > 0) out.push({ l: 'Add for 90 d', v: num(f.need90, 1) + '<small>GiB</small>', s: f.addBy ? 'by ' + fDay(dayN(f.addBy)) : '' });
    if (f.below) out.push({ l: 'Limit', v: 'below used', tone: 'crit' });
    return out;
  }

  function limitFacts(label, limWord) {
    return function (m) {
      var f = m.f, out = [];
      out.push({ l: label, v: m.unit.fmt(f.v), s: f.lim != null ? 'of ' + m.unit.fmt(f.lim) + ' ' + limWord : 'no limit' });
      if (f.pct != null) out.push({ k: 'pct', l: 'Of ' + limWord, v: num(f.pct, 1) + '<small>%</small>', tone: pctTone(f.pct, SERIES_SAT, 100) });
      out.push({ l: m.unit.rateLabel, v: m.unit.rate(f.slope), s: 'fit over ' + (f.n || '–') + ' d' });
      if (f.lim != null) out.push(dtfFact(f, SERIES_SAT + '% in'));
      return out;
    };
  }

  function redoFacts(m) {
    var f = m.f;
    var avg = avgLast(m.pts, 7);
    return [
      { l: 'Today', v: m.unit.fmt(lastVal(m.pts)) },
      { l: '7-day average', v: m.unit.fmt(avg) },
      { l: m.unit.rateLabel, v: m.unit.rate(f.slope), s: 'fit over ' + (f.n || '–') + ' d' }
    ];
  }

  function cpuFacts(m, p95, avg) {
    var f = m.f, out = [];
    out.push({ k: 'now', l: 'Busy-hour p95', v: num(f.v, 1) + '<small>%</small>', s: f.hot ? 'at the ' + CPU_SAT + '% line now' : 'of ' + p95,
      tone: pctTone(f.v, CPU_SAT * 0.9, CPU_SAT) });
    var a = m.fits[avg];
    out.push({ l: 'Daily average', v: a ? num(a.v, 1) + '<small>%</small>' : '–' });
    out.push({ l: m.unit.rateLabel, v: m.unit.rate(f.slope), s: f.sig === 0 ? 'not significant' : 'fit over ' + (f.n || '–') + ' d' });
    out.push(dtfFact(f, CPU_SAT + '% in'));
    return out;
  }
  function hostCpuFacts(m) {
    var out = cpuFacts(m, 'host CPU', 'BUSY_PCT');
    var pk = m.fits.BUSY_PEAK;
    if (pk) out.splice(2, 0, { l: 'Peak window', v: num(pk.v, 1) + '<small>%</small>', s: 'business hours' });
    return out;
  }
  function dbCpuFacts(m) { return cpuFacts(m, 'host CPUs', 'DB_CPU_PCT'); }

  function lastVal(pts) { for (var i = pts.length - 1; i >= 0; i--) if (pts[i].y != null) return pts[i].y; return null; }
  function avgLast(pts, n) {
    var s = 0, c = 0;
    pts.forEach(function (p) { if (p.y != null && p.x > LAST - n) { s += p.y; c++; } });
    return c ? s / c : null;
  }

  /* ---------- alert and anomaly wording (facts only) ---------- */

  function alertWhen(a) {
    if (a.unit === 'DAYS' || a.u === 'DAYS') return stamp(LAST + a.v);
    if (/_ANOM$/.test(a.kind)) return '<span class="when">' + fDay(dayN(a.n > 1 ? a.first : a.day)) + (a.n > 1 ? '–' + fDay(dayN(a.day)) : '') + '</span>';
    return '<span class="when">now</span>';
  }

  function alertFact(a, m) {
    var u = m ? m.unit : unitFor(a.u);
    switch (a.kind) {
      case 'TBSPC_FULL': return 'full in <b>' + fDays(a.v) + '</b>';
      case 'CPU_SAT': case 'DBCPU_SAT': return CPU_SAT + '% busy in <b>' + fDays(a.v) + '</b>';
      case 'SERIES_LIMIT': return SERIES_SAT + '% of limit in <b>' + fDays(a.v) + '</b>';
      case 'TBSPC_NEARFULL': return '<b>' + num(a.v, 1) + '%</b> used';
      case 'SERIES_NEARLIMIT': return '<b>' + num(a.v, 1) + '%</b> of limit';
      case 'CPU_HOT': case 'DBCPU_HOT': return 'busy-hour p95 <b>' + num(a.v, 1) + '%</b> now';
      case 'CPU_SHIFT': return 'level shift <b>' + sign(a.v) + num(Math.abs(a.v), 1) + '%</b>';
      case 'DATA_STALE': return 'no AWR snapshot for <b>' + auto(a.v) + ' h</b>';
      case 'MODEL_HEALTH': return 'ESM model ' + esc(a.msg || '');
    }
    if (/_ANOM$/.test(a.kind)) {
      var v = a.u === 'BYTES' ? fBytes(a.v) + '/d' : a.u === 'PCT' ? num(a.v, 1) + '%' : a.u === 'GIB' ? auto(a.v) + ' GiB/d' : auto(a.v);
      var t = a.u === 'BYTES' ? fBytes(a.thr) + '/d' : a.u === 'PCT' ? num(a.thr, 1) + '%' : a.u === 'GIB' ? auto(a.thr) + ' GiB/d' : auto(a.thr);
      var span = a.n > 1 ? ' · ' + a.n + ' days' : '';
      return 'unusual <b>' + v + '</b>, normal ≤ ' + t + (a.maxz != null ? ' · z ' + num(a.maxz, 1) : '') + span;
    }
    return esc(a.msg || a.kind);
  }

  /* One chip per flagged day: the day verdict (worst mode) plus its flagged hours. */
  function anomalyEvents(m) {
    var days = {};
    m.anoms.forEach(function (a) {
      if (a.ak === 'CPU_SHIFT') return;
      var d = dayN(a.ts);
      if (d <= LAST - ANOM_DAYS) return;
      var e = days[d] || (days[d] = { d: d, day: null, hours: {}, nh: 0, f: a.f, z: 0 });
      if (a.grain === 'HOUR') {
        if (!e.hours[a.ts]) e.nh++;
        e.hours[a.ts] = a.f;
      } else if (!e.day || Math.abs(a.z) > Math.abs(e.day.z)) e.day = a;
      if (Math.abs(a.z || 0) >= Math.abs(e.z)) { e.z = a.z; e.f = a.f; }
    });
    return Object.keys(days).map(function (k) { return days[k]; })
      .sort(function (a, b) { return b.d - a.d; });
  }

  function anomalyChip(ev, m) {
    var val = '', usual = '', a = ev.day;
    if (a) {
      if (m.fam.id === 'tablespaces' || m.f.s === 'DB_SIZE_GB') {
        var scale = m.fam.id === 'tablespaces' ? 1 : Math.pow(1024, 3);
        val = sign(a.v) + fBytes(Math.abs(a.v * scale)) + ' in a day';
        usual = 'usual ' + fBytes(a.e * scale);
      } else {
        val = m.unit.fmt(a.v);
        usual = 'usual ' + m.unit.fmt(a.e);
      }
    }
    if (ev.nh) {
      var hrs = ev.nh + ' h ' + (ev.f === 'LOW' ? 'below' : 'above') + ' their usual hour';
      if (val) usual += ' · ' + hrs; else val = hrs;
    }
    return '<div class="an ' + (ev.f === 'LOW' ? 'lo' : 'hi') + '"><span class="dt">' + fWDay(ev.d) + '</span><span class="vv">' + val +
      '</span><span class="us">' + usual + '</span><span class="z">z ' + num(ev.z, 1) + '</span></div>';
  }

  /* ---------- charts ---------- */

  var CHARTS = [];
  var W = 640, H = 196, ML = 44, MR = 14, MT = 22, MB = 24;

  function niceTicks(lo, hi, n) {
    var span = hi - lo || 1, step = Math.pow(10, Math.floor(Math.log10(span / n)));
    var err = span / n / step;
    step *= err >= 7.5 ? 10 : err >= 3.5 ? 5 : err >= 1.5 ? 2 : 1;
    var t = [], v = Math.ceil(lo / step) * step;
    for (; v <= hi + step * 1e-9; v += step) t.push(+v.toFixed(10));
    var dp = Math.max(0, -Math.floor(Math.log10(step) + 1e-9));
    return { ticks: t, step: step, dp: dp };
  }

  function forecastKnots(m, method) {
    return m.fc.filter(function (r) { return r.m === method; })
      .map(function (r) { return { x: dayN(r.t), y: r.v, lo: r.lo, hi: r.hi }; })
      .sort(function (a, b) { return a.x - b.x; });
  }

  function horizon(m) {
    var f = m.f, h = 90;
    var reach = m.fc.reduce(function (r, k) { return k.m === 'REGR' ? Math.max(r, k.h) : r; }, 30);
    if (f.dtf != null && f.dtf > 60 && f.dtf <= 330) h = Math.ceil((f.dtf + 20) / 30) * 30;
    return Math.min(h, reach);
  }

  function isHot(m) {
    var f = m.f;
    if (f.dtf != null && f.q === 'OK' && f.dtf <= K.dtfWarn) return true;
    if (f.k === 'TBSPC') return f.pct >= K.nfWarn;
    if (f.k === 'SERIES') return f.pct >= SERIES_SAT;
    return !!f.hot;
  }

  function limitLines(m) {
    var f = m.f, out = [];
    if (m.f.k === 'CPU') out.push({ y: CPU_SAT, cls: 'thr', label: CPU_SAT + '%', target: true });
    else if (f.lim != null) {
      out.push({ y: f.lim, cls: 'lim', label: 'limit ' + m.unit.fmt(f.lim), target: m.f.k === 'TBSPC' });
      if (m.f.k === 'SERIES') out.push({ y: f.lim * SERIES_SAT / 100, cls: 'thr', label: SERIES_SAT + '%', target: true });
      else if (K.nfWarn) out.push({ y: f.lim * K.nfWarn / 100, cls: 'thr', label: K.nfWarn + '%' });
    }
    return out;
  }

  function chartSpec(m) {
    var lines = (m.fam.lines || [[m.f.s, '']]).map(function (l, i) {
      return { s: l[0], label: l[1], pts: PTS[key(m.f.k, m.f.dbid, m.f.con, l[0])] || [], role: i };
    }).filter(function (l) { return l.pts.length; });
    return {
      hot: isHot(m),
      lines: lines, fc: forecastKnots(m, 'REGR'), esm: forecastKnots(m, 'ESM'),
      limits: limitLines(m), unit: m.unit, x0: FIRST != null ? FIRST : (lines[0] && lines[0].pts[0] ? lines[0].pts[0].x : LAST - 90),
      x1: LAST + horizon(m), pctAxis: m.f.k === 'CPU', m: m
    };
  }

  function chartSvg(spec, id) {
    var xs = function (x) { return ML + (x - spec.x0) / (spec.x1 - spec.x0) * (W - ML - MR); };
    var ymax = 0, ymin = 0;
    spec.lines.forEach(function (l) { l.pts.forEach(function (p) { if (p.y != null) { ymax = Math.max(ymax, p.y); ymin = Math.min(ymin, p.y); } }); });
    spec.limits.forEach(function (l) { ymax = Math.max(ymax, l.y); });
    spec.fc.forEach(function (k) { if (k.x <= spec.x1) ymax = Math.max(ymax, k.hi != null ? k.hi : k.y); });
    if (spec.pctAxis) ymax = Math.max(ymax, CPU_SAT);
    var sc = spec.unit.scale;
    var nt = niceTicks(ymin / sc, (ymax || 1) * 1.06 / sc, 4);
    var top = nt.ticks[nt.ticks.length - 1] * sc;
    if (top < ymax * 1.02) top = (nt.ticks[nt.ticks.length - 1] + nt.step) * sc;
    var bot = Math.min(0, nt.ticks[0] * sc);
    var ys = function (y) { return MT + (1 - (y - bot) / (top - bot || 1)) * (H - MT - MB); };
    var o = [];
    o.push('<svg viewBox="0 0 ' + W + ' ' + H + '" role="img" aria-label="' + esc(spec.m.name) + '">');
    o.push('<defs><clipPath id="c' + id + '"><rect x="' + ML + '" y="0" width="' + (W - ML - MR) + '" height="' + (H - MB) + '"/></clipPath></defs>');
    nt.ticks.forEach(function (t) {
      var y = ys(t * sc);
      if (t * sc > top + 1e-9) return;
      o.push('<line x1="' + ML + '" x2="' + (W - MR) + '" y1="' + y.toFixed(1) + '" y2="' + y.toFixed(1) + '" stroke="var(--line-2)"/>');
      o.push('<text x="' + (ML - 6) + '" y="' + (y + 3.5).toFixed(1) + '" text-anchor="end">' + num(t, nt.dp) + '</text>');
    });
    o.push('<text x="' + (ML - 6) + '" y="10" text-anchor="end">' + esc(spec.unit.short) + '</text>');
    var months = monthTicks(spec.x0, spec.x1);
    months.forEach(function (mt) {
      var x = xs(mt.x);
      o.push('<line x1="' + x.toFixed(1) + '" x2="' + x.toFixed(1) + '" y1="' + (H - MB) + '" y2="' + (H - MB + 4) + '" stroke="var(--line)"/>');
      o.push('<text x="' + x.toFixed(1) + '" y="' + (H - 7) + '" text-anchor="middle">' + mt.label + '</text>');
    });
    o.push('<line x1="' + ML + '" x2="' + (W - MR) + '" y1="' + ys(bot).toFixed(1) + '" y2="' + ys(bot).toFixed(1) + '" stroke="var(--line)"/>');
    o.push('<g clip-path="url(#c' + id + ')">');
    var fc = spec.fc;
    if (fc.length > 1) {
      var band = fc.filter(function (k) { return k.lo != null && k.hi != null; });
      if (band.length > 1) {
        var first = fc[0];
        var poly = [[first.x, first.y]].concat(band.map(function (k) { return [k.x, k.hi]; }))
          .concat(band.slice().reverse().map(function (k) { return [k.x, k.lo]; }));
        o.push('<path d="M' + poly.map(function (p) { return xs(p[0]).toFixed(1) + ',' + ys(p[1]).toFixed(1); }).join('L') + 'Z" fill="var(--band)"/>');
      }
    }
    spec.lines.slice().reverse().forEach(function (l) {
      var d = pathOf(l.pts, xs, ys);
      if (l.role === 0) {
        var area = areaOf(l.pts, xs, ys, ys(Math.max(bot, 0)));
        if (area) o.push('<path d="' + area + '" fill="var(--data-fill)"/>');
        o.push('<path d="' + d + '" fill="none" stroke="var(--data)" stroke-width="1.8" stroke-linejoin="round"/>');
      } else {
        o.push('<path d="' + d + '" fill="none" stroke="var(--data-2)" stroke-width="1.3" stroke-linejoin="round"/>');
      }
    });
    if (fc.length > 1) {
      o.push('<path d="M' + fc.map(function (k) { return xs(k.x).toFixed(1) + ',' + ys(k.y).toFixed(1); }).join('L') + '" fill="none" stroke="var(--data)" stroke-width="1.6" stroke-dasharray="5 4"/>');
    }
    spec.limits.forEach(function (l) {
      var y = ys(l.y).toFixed(1);
      var col = !spec.hot ? 'var(--ink-3)' : l.cls === 'lim' ? 'var(--limit)' : 'var(--thresh)';
      o.push('<line x1="' + ML + '" x2="' + (W - MR) + '" y1="' + y + '" y2="' + y + '" stroke="' + col + '" stroke-width="1" stroke-dasharray="' + (l.cls === 'lim' ? '6 4' : '2 3') + '"' + (spec.hot ? '' : ' opacity=".7"') + '/>');
    });
    var cross = crossing(spec);
    if (cross) {
      o.push('<circle cx="' + xs(cross.x).toFixed(1) + '" cy="' + ys(cross.y).toFixed(1) + '" r="3.5" fill="' + (spec.hot ? 'var(--limit)' : 'var(--ink-2)') + '" stroke="var(--surface)" stroke-width="2"/>');
    }
    spec.esm.forEach(function (k) {
      var x = xs(k.x), y = ys(k.y);
      if (k.lo != null && k.hi != null && (k.hi - k.lo) < (top - bot) * 0.6) o.push('<line x1="' + x.toFixed(1) + '" x2="' + x.toFixed(1) + '" y1="' + ys(k.lo).toFixed(1) + '" y2="' + ys(k.hi).toFixed(1) + '" stroke="var(--esm)" stroke-width="1.5"/>');
      o.push('<rect x="' + (x - 4).toFixed(1) + '" y="' + (y - 4).toFixed(1) + '" width="8" height="8" fill="var(--esm)" transform="rotate(45 ' + x.toFixed(1) + ' ' + y.toFixed(1) + ')"/>');
    });
    spec.lines.forEach(function (l) {
      l.pts.forEach(function (p) {
        if (p.a === 1 || p.a === -1) {
          var recent = p.x > LAST - ANOM_DAYS;
          if (recent) o.push('<circle cx="' + xs(p.x).toFixed(1) + '" cy="' + ys(p.y).toFixed(1) + '" r="3" fill="var(--surface)" stroke="' + (p.a === 1 ? 'var(--crit)' : 'var(--accent)') + '" stroke-width="1.5"/>');
          else o.push('<circle cx="' + xs(p.x).toFixed(1) + '" cy="' + ys(p.y).toFixed(1) + '" r="1.75" fill="var(--ink-3)"/>');
        }
      });
    });
    o.push('</g>');
    var tx = xs(LAST).toFixed(1);
    o.push('<line x1="' + tx + '" x2="' + tx + '" y1="' + MT + '" y2="' + (H - MB) + '" stroke="var(--ink-3)" stroke-width="1" stroke-dasharray="1 3"/>');
    o.push('<text x="' + tx + '" y="10" text-anchor="middle">today</text>');
    spec.limits.forEach(function (l) {
      var y = ys(l.y), lim = l.cls === 'lim';
      var tc = !spec.hot ? 'var(--ink-3)' : lim ? 'var(--limit)' : 'var(--thresh)';
      o.push('<text x="' + (lim ? W - MR - 2 : ML + 4) + '" y="' + (y + (lim ? -4 : 11)).toFixed(1) + '" text-anchor="' + (lim ? 'end' : 'start') + '" class="lbl" style="fill:' + tc + '">' + esc(l.label) + '</text>');
    });
    if (cross) {
      o.push('<text x="' + (xs(cross.x) - 6).toFixed(1) + '" y="' + (ys(cross.y) + 15).toFixed(1) + '" text-anchor="end" class="stmp" style="fill:' + (spec.hot ? 'var(--limit)' : 'var(--ink-2)') + '">→ ' + fDay(Math.round(cross.x)) + '</text>');
    }
    o.push('<line class="hx" x1="0" x2="0" y1="' + MT + '" y2="' + (H - MB) + '" stroke="var(--ink-2)" stroke-width="1" visibility="hidden"/>');
    o.push('<circle class="hd" r="4" fill="var(--data)" stroke="var(--surface)" stroke-width="2" visibility="hidden"/>');
    o.push('<rect x="' + ML + '" y="0" width="' + (W - ML - MR) + '" height="' + (H - MB) + '" fill="transparent" class="hit"/>');
    o.push('</svg>');
    spec.xs = xs; spec.ys = ys;
    return o.join('');
  }

  function crossing(spec) {
    var lim = spec.limits.filter(function (l) { return l.target; })[0];
    if (!lim || spec.fc.length < 2) return null;
    var fc = spec.fc;
    for (var i = 1; i < fc.length; i++) {
      var a = fc[i - 1], b = fc[i];
      if (a.y < lim.y && b.y >= lim.y) {
        var x = a.x + (lim.y - a.y) / (b.y - a.y) * (b.x - a.x);
        return x <= spec.x1 ? { x: x, y: lim.y } : null;
      }
    }
    return null;
  }

  function pathOf(pts, xs, ys) {
    var d = '', pen = false, prev = null;
    pts.forEach(function (p) {
      if (p.y == null || (prev != null && p.x - prev > 1.5)) pen = false;
      if (p.y != null) {
        d += (pen ? 'L' : 'M') + xs(p.x).toFixed(1) + ',' + ys(p.y).toFixed(1);
        pen = true;
        prev = p.x;
      }
    });
    return d;
  }
  function areaOf(pts, xs, ys, base) {
    var v = pts.filter(function (p) { return p.y != null; });
    if (v.length < 2) return '';
    return 'M' + xs(v[0].x).toFixed(1) + ',' + base.toFixed(1) + v.map(function (p) {
      return 'L' + xs(p.x).toFixed(1) + ',' + ys(p.y).toFixed(1);
    }).join('') + 'L' + xs(v[v.length - 1].x).toFixed(1) + ',' + base.toFixed(1) + 'Z';
  }

  function monthTicks(x0, x1) {
    var out = [], d = dateOf(x0);
    var y = d.getUTCFullYear(), mo = d.getUTCMonth() + 1;
    var span = x1 - x0, every = span > 400 ? 3 : span > 200 ? 2 : 1;
    for (;;) {
      if (mo > 11) { mo = 0; y++; }
      var x = Date.UTC(y, mo, 1) / MS_DAY;
      if (x > x1) break;
      if (mo % every === 0) out.push({ x: x, label: mo === 0 ? MONTHS[0] + ' ’' + String(y).slice(2) : MONTHS[mo] });
      mo++;
    }
    return out;
  }

  function legendHtml(spec) {
    var o = [];
    if (spec.lines.length > 1) {
      o.push('<span><i></i>' + esc(spec.lines[0].label) + '</span>');
      o.push('<span><i class="l2"></i>' + esc(spec.lines[1].label) + '</span>');
    }
    return o.length ? '<div class="legend">' + o.join('') + '</div>' : '';
  }

  function sparkSvg(m, w, h) {
    var spec = chartSpec(m);
    var l = spec.lines[0];
    if (!l) return '<svg viewBox="0 0 ' + w + ' ' + h + '"></svg>';
    var x0 = Math.max(spec.x0, LAST - 120), x1 = LAST + 30;
    var ymax = 0;
    l.pts.forEach(function (p) { if (p.x >= x0 && p.y != null) ymax = Math.max(ymax, p.y); });
    spec.limits.slice(0, 1).forEach(function (lim) { ymax = Math.max(ymax, lim.y); });
    if (spec.pctAxis) ymax = Math.max(ymax, 100);
    var xs = function (x) { return 1 + (x - x0) / (x1 - x0) * (w - 2); };
    var ys = function (y) { return h - 2 - y / (ymax * 1.05 || 1) * (h - 4); };
    var pts = l.pts.filter(function (p) { return p.x >= x0; });
    var o = ['<svg viewBox="0 0 ' + w + ' ' + h + '" preserveAspectRatio="none" aria-hidden="true">'];
    var area = areaOf(pts, xs, ys, h - 1);
    if (area) o.push('<path d="' + area + '" fill="var(--data-fill)"/>');
    o.push('<path d="' + pathOf(pts, xs, ys) + '" fill="none" stroke="var(--data)" stroke-width="1.4" vector-effect="non-scaling-stroke"/>');
    var fc = spec.fc.filter(function (k) { return k.x <= x1 + 60; });
    if (fc.length > 1) o.push('<path d="M' + fc.map(function (k) { return xs(k.x).toFixed(1) + ',' + ys(k.y).toFixed(1); }).join('L') + '" fill="none" stroke="var(--data)" stroke-width="1.2" stroke-dasharray="3 3" vector-effect="non-scaling-stroke"/>');
    if (spec.limits[0]) {
      var y = ys(spec.limits[0].y).toFixed(1);
      o.push('<line x1="0" x2="' + w + '" y1="' + y + '" y2="' + y + '" stroke="var(--ink-3)" stroke-width="1" stroke-dasharray="2 3" vector-effect="non-scaling-stroke"/>');
    }
    pts.forEach(function (p) {
      if ((p.a === 1 || p.a === -1) && p.x > LAST - ANOM_DAYS) o.push('<circle cx="' + xs(p.x).toFixed(1) + '" cy="' + ys(p.y).toFixed(1) + '" r="2" fill="' + (p.a === 1 ? 'var(--crit)' : 'var(--accent)') + '"/>');
    });
    o.push('</svg>');
    return o.join('');
  }

  /* ---------- hour heat strip (CPU) ---------- */

  function heatSvg(m) {
    var h = HOURS[key(m.f.dbid, m.f.con, m.fam.heat)];
    if (!h || !h.d.length) return '';
    var t0 = dayN(h.t0), rows = 14, cw = 21, rh = 13, lw = 70, top = 2;
    var w = lw + cw * 24, ht = top + rows * rh + 16;
    var grid = {};
    h.d.forEach(function (r) { grid[r[0] + '|' + r[1]] = r; });
    var o = ['<svg viewBox="0 0 ' + w + ' ' + ht + '" role="img" aria-label="hourly CPU, last 14 days">'];
    for (var r = 0; r < rows; r++) {
      var day = t0 + r, y = top + r * rh;
      o.push('<text x="' + (lw - 6) + '" y="' + (y + rh - 3) + '" text-anchor="end">' + fWDay(day) + '</text>');
      for (var c = 0; c < 24; c++) {
        var cell = grid[r + '|' + c], x = lw + c * cw;
        var fill = 'var(--heat-0)', stroke = '';
        if (cell && cell[2] != null) {
          var v = Math.max(0, Math.min(100, cell[2]));
          fill = 'color-mix(in oklab, var(--heat-1) ' + Math.round(v) + '%, var(--heat-0))';
          if (cell[3] === 1) stroke = ' stroke="var(--crit)" stroke-width="2"';
          if (cell[3] === -1) stroke = ' stroke="var(--accent)" stroke-width="2"';
        }
        o.push('<rect class="hc" data-d="' + day + '" data-h="' + c + '" data-v="' + (cell && cell[2] != null ? cell[2] : '') + '" data-f="' + (cell ? cell[3] : 0) + '" x="' + (x + 0.5) + '" y="' + (y + 0.5) + '" width="' + (cw - 1) + '" height="' + (rh - 1) + '" rx="1.5" fill="' + fill + '"' + stroke + '/>');
      }
    }
    [0, 6, 12, 18].forEach(function (hr) {
      o.push('<text x="' + (lw + hr * cw + cw / 2) + '" y="' + (top + rows * rh + 12) + '" text-anchor="middle">' + (hr < 10 ? '0' : '') + hr + ':00</text>');
    });
    o.push('</svg>');
    return '<div class="heat"><div class="hh"><span>Hourly, last 14 days, by hour ending</span><span class="ramp">0%<i></i>100%</span></div>' + o.join('') + '</div>';
  }

  /* ---------- page pieces ---------- */

  function pill(sev, text) { return '<span class="st ' + SEV_CLASS[sev] + '">' + esc(text || SEV_LABEL[sev]) + '</span>'; }
  function sdot(sev) { return '<span class="dot ' + SEV_CLASS[sev] + '"></span>'; }

  function factsHtml(facts) {
    return '<div class="facts">' + facts.map(function (f) {
      return '<div class="fact ' + (f.tone || '') + '"><div class="l">' + esc(f.l) + '</div><div class="v">' + f.v + '</div>' +
        (f.s ? '<div class="s">' + esc(f.s) + '</div>' : '') + '</div>';
    }).join('') + '</div>';
  }

  function tagsHtml(m) {
    var t = [];
    if (QUALITY_TAG[m.f.q]) t.push(QUALITY_TAG[m.f.q]);
    if (m.f.cur === 0) t.push('no longer reported');
    if (m.f.limSrc && m.f.limSrc !== 'MAXBYTES' && m.f.limSrc !== 'AUTOEXTEND' && m.fam.id === 'tablespaces') t.push('limit: ' + m.f.limSrc.toLowerCase());
    return t.map(function (x) { return '<span class="tag">' + esc(x) + '</span>'; }).join('');
  }

  function cardHtml(m) {
    var spec = chartSpec(m);
    var id = CHARTS.length;
    var svg = chartSvg(spec, id);
    CHARTS.push(spec);
    var o = ['<article class="card ' + SEV_CLASS[m.sev] + (m.fam.heat ? ' split' : '') + '" id="' + m.id + '">'];
    o.push('<div class="ch"><h3>' + esc(m.name) + '</h3>' + (m.ctr && m.ctr !== m.name ? '<span class="ctr">' + esc(m.ctr) + '</span>' : '') + tagsHtml(m) + pill(m.sev) + '</div>');
    o.push(factsHtml(m.facts));
    o.push('<div class="viz"><div><div class="chart" data-chart="' + id + '">' + svg + '<div class="tip"></div></div>');
    o.push(legendHtml(spec) + '</div>');
    if (m.fam.heat) o.push(heatSvg(m));
    o.push('</div>');
    var shifts = m.anoms.filter(function (a) { return a.ak === 'CPU_SHIFT'; });
    var evs = anomalyEvents(m);
    if (shifts.length || evs.length) {
      o.push('<div class="issues">');
      shifts.forEach(function (a) {
        o.push('<div class="iss">' + sdot(a.sev && SEV_RANK[a.sev] != null ? a.sev : 'INFO') + '<span>Level shift <b>' + sign(a.shift) + num(Math.abs(a.shift), 1) + '%</b> since ' + fDay(dayN(a.ts)) + '</span></div>');
      });
      if (evs.length) {
        var shown = evs.slice(0, 3);
        o.push('<div class="anoms"><div class="ah"><span>Unusual days</span><span>' + evs.length + ' in the last ' + ANOM_DAYS + ' d</span></div>' +
          shown.map(function (e) { return anomalyChip(e, m); }).join('') + '</div>');
      }
      o.push('</div>');
    }
    o.push('</article>');
    return o.join('');
  }

  function rowHtml(m) {
    var f = m.f;
    var pct = f.pct != null ? Math.max(0, Math.min(100, f.pct)) : null;
    var tone = pctTone(f.pct, m.fam.id === 'tablespaces' ? K.nfWarn : SERIES_SAT, m.fam.id === 'tablespaces' ? K.nfCrit : 100);
    var dtf = dtfFact(f, '');
    return '<div class="row" id="' + m.id + '"><div class="nm"><b>' + esc(m.name) + '</b><span>' + esc(m.ctr) + (QUALITY_TAG[f.q] ? ' · ' + QUALITY_TAG[f.q] : '') + '</span></div>' +
      sparkSvg(m, 200, 30) +
      '<div class="c keep">' + (pct != null ? num(f.pct, 1) + '%<div class="bar"><i class="' + tone + '" style="width:' + pct + '%"></i></div>' : m.unit.fmt(f.v)) + '</div>' +
      '<div class="c">' + m.unit.rate(f.slope) + '<span>growth</span></div>' +
      '<div class="c">' + dtf.v + '<span>' + esc(dtf.s) + '</span></div>' + pill(m.sev) + '</div>';
  }

  function familySummary(fam, ms) {
    var c = { CRIT: 0, WARN: 0, INFO: 0 };
    ms.forEach(function (m) { if (c[m.sev] != null) c[m.sev]++; });
    var parts = ['<b>' + ms.length + '</b> ' + fam.noun + (ms.length === 1 ? '' : 's')];
    if (c.CRIT) parts.push('<b>' + c.CRIT + '</b> critical');
    if (c.WARN) parts.push('<b>' + c.WARN + '</b> warning');
    var soon = ms.filter(function (m) { return m.f.dtf != null && m.f.q === 'OK'; })
      .sort(function (a, b) { return a.f.dtf - b.f.dtf; })[0];
    if (soon && fam.id !== 'redo') {
      var what = fam.id === 'tablespaces' ? 'full' : fam.id.indexOf('cpu') >= 0 ? CPU_SAT + '%' : SERIES_SAT + '%';
      parts.push('soonest ' + what + ': <b>' + esc(soon.name) + '</b> in ' + fDays(soon.f.dtf));
    }
    return parts.map(function (p) { return '<span>' + p + '</span>'; }).join('');
  }

  function headline(fam, ms) {
    var m = ms[0];
    if (!m) return '';
    var a = m.alerts[0];
    if (a && m.sev !== 'OK') {
      var fact = /_ANOM$/.test(a.kind) ? 'unusual ' + fDay(dayN(a.day)) : alertFact(a, m).replace(/<\/?b>/g, '');
      return '<b>' + esc(m.name) + '</b> ' + fact;
    }
    var f = m.f;
    if (fam.id === 'tablespaces') {
      var full = ms.slice().sort(function (x, y) { return (y.f.pct || 0) - (x.f.pct || 0); })[0];
      return 'fullest <b>' + esc(full.name) + '</b> ' + num(full.f.pct, 1) + '%';
    }
    if (f.k === 'CPU') return '<b>' + esc(m.name) + '</b> p95 ' + num(f.v, 1) + '%';
    if (fam.id === 'redo') return '<b>' + m.unit.fmt(lastVal(m.pts)) + '</b> today';
    return '<b>' + esc(m.name) + '</b> ' + m.unit.fmt(f.v) + (f.pct != null ? ' · ' + num(f.pct, 1) + '%' : '');
  }

  /* ---------- assemble ---------- */

  var sections = FAMILIES.map(function (fam) {
    var ms = (D.fits || []).filter(fam.match).map(function (f) { return buildMetric(fam, f); });
    ms.sort(function (a, b) {
      for (var i = 0; i < a.order.length; i++) if (a.order[i] !== b.order[i]) return a.order[i] - b.order[i];
      return a.name < b.name ? -1 : 1;
    });
    return { fam: fam, ms: ms, sev: worstSev(ms.map(function (m) { return m.sev; })) };
  });
  var present = sections.filter(function (s) { return s.ms.length; });
  var absent = sections.filter(function (s) { return !s.ms.length; });
  var metricBySeries = {};
  present.forEach(function (sec) {
    sec.ms.forEach(function (m) {
      [m.f.s].concat(m.fam.related || []).forEach(function (s) { metricBySeries[key(m.f.dbid, m.f.con, s)] = m; });
    });
  });

  var alerts = (D.alerts || []).slice().sort(function (a, b) { return SEV_RANK[a.sev] - SEV_RANK[b.sev]; });
  var nCrit = alerts.filter(function (a) { return a.sev === 'CRIT'; }).length;
  var nWarn = alerts.filter(function (a) { return a.sev === 'WARN'; }).length;
  var nSeries = present.reduce(function (n, s) { return n + s.ms.length; }, 0);
  var nOk = present.reduce(function (n, s) { return n + s.ms.filter(function (m) { return m.sev === 'OK'; }).length; }, 0);

  var html = [];
  var dbName = (D.containers && D.containers[0] && D.containers[0].db) || M.db || '';
  document.title = 'Capacity · ' + dbName + ' · ' + (M.lastDay || '');
  html.push('<header class="top"><div class="top-in"><div class="brand">Capacity report <span>' + esc(dbName) + '</span></div>');
  html.push('<div class="ident"><span><b>' + esc(M.host) + '</b></span><span>data ' + (FIRST != null ? fDayY(FIRST) + ' – ' + fDayY(LAST) : '–') +
    (FIRST != null ? ' (' + (LAST - FIRST + 1) + ' d)' : '') + '</span><span>generated ' + esc((M.generated || '').slice(0, 16)) + '</span>' +
    (M.source && M.source !== 'LIVE' ? '<span><b>' + esc(M.source) + '</b></span>' : '') + '</div>');
  html.push('<div class="tools"><button class="tbtn" id="themeBtn" type="button">Theme</button><button class="tbtn" type="button" onclick="window.print()">Print</button></div></div>');
  html.push('<nav class="nav"><div class="nav-in"><a href="#overview">Overview</a>' + present.map(function (s) {
    return '<a href="#' + s.fam.id + '"><span class="dot ' + SEV_CLASS[s.sev] + '"></span>' + esc(s.fam.title) + '<span class="n">' + s.ms.length + '</span></a>';
  }).join('') + '</div></nav></header><main>');

  (D.errors || []).forEach(function (e) {
    html.push('<div class="banner">Data block “' + esc(e.block) + '” failed: ' + esc(e.msg) + '</div>');
  });
  alerts.filter(function (a) { return a.kind === 'DATA_STALE'; }).forEach(function (a) {
    html.push('<div class="banner">' + esc(conLabel(a.dbid, a.con)) + ': ' + alertFact(a) + '</div>');
  });
  if (GEN != null && LAST != null && GEN - LAST > 3) {
    html.push('<div class="banner warn">Newest AWR day is ' + fDayY(LAST) + ', ' + (GEN - LAST) + ' days before this report.</div>');
  }

  var esmLine = M.esm && M.esm.ok != null ? 'ESM models ' + M.esm.ok + ' ok · ' + (M.esm.failed || 0) + ' failed · ' + (M.esm.stale || 0) + ' stale' : '';
  html.push('<section id="overview"><div class="sh"><h2>Overview</h2></div>');
  html.push('<div class="summary">' +
    '<span class="sv crit"><b>' + nCrit + '</b> critical</span>' +
    '<span class="sv warn"><b>' + nWarn + '</b> warning</span>' +
    '<span class="sv"><b>' + nOk + '</b> of ' + nSeries + ' series healthy</span>' +
    '<span class="sv muted">' + present.length + ' metrics · ' + esmLine + '</span></div>');

  html.push('<div class="idx">' + present.map(function (s) {
    var soon = s.ms.filter(function (m) { return m.f.dtf != null && m.f.q === 'OK' && m.f.dtf <= 365; })
      .sort(function (x, y) { return x.f.dtf - y.f.dtf; })[0];
    return '<a class="irow" href="#' + s.fam.id + '">' + sdot(s.sev) + '<span class="it">' + esc(s.fam.title) + '</span>' +
      '<span class="ic">' + s.ms.length + '</span><span class="ih">' + headline(s.fam, s.ms) + '</span>' +
      sparkSvg(s.ms[0], 240, 28) + '<span class="iw">' + (soon ? stamp(LAST + soon.f.dtf) : '') + '</span></a>';
  }).join('') + '</div>');
  if (absent.length) html.push('<div class="absent">No data: ' + absent.map(function (s) { return esc(s.fam.title); }).join(', ') + '</div>');

  var listed = alerts.filter(function (a) { return a.sev === 'CRIT' || a.sev === 'WARN'; });
  html.push('<div class="attn"><h3>Needs attention <span>' + listed.length + '</span></h3>');
  if (!listed.length) html.push('<div class="allok">Nothing needs attention</div>');
  listed.forEach(function (a) {
    var m = metricBySeries[key(a.dbid, a.con, a.s)];
    var href = m ? '#' + m.id : '#overview';
    html.push('<a class="arow" href="' + href + '">' + pill(a.sev) + '<span class="m">' + esc(m ? m.fam.title : a.kind) + '</span>' +
      '<span class="s">' + esc(m ? m.name : a.s) + ' <span>' + esc(m ? m.ctr : conLabel(a.dbid, a.con)) + '</span></span>' +
      '<span class="f">' + alertFact(a, m) + '</span><span class="d">' + alertWhen(a) + '</span></a>');
  });
  html.push('</div></section>');
  html.push('<div class="key"><span><i class="k-hist"></i>history</span><span><i class="k-fc"></i>forecast</span><span><i class="k-bd"></i>95% band</span>' +
    '<span><i class="k-lim"></i>limit</span><span><i class="k-thr"></i>warning line</span><span><i class="k-un"></i>unusual day, last ' + ANOM_DAYS + ' d</span>' +
    '<span><i class="k-old"></i>older unusual day</span><span><i class="k-es"></i>ESM +30 d</span><span><span class="stamp">→ 3 Nov</span> reaches the line</span></div>');

  html.push('<div class="secgrid">');
  present.forEach(function (s) {
    var wide = s.ms.length > 1 || s.fam.heat;
    html.push('<section id="' + s.fam.id + '"' + (wide ? ' class="wide"' : '') + '><div class="sh"><h2><span class="dot ' + SEV_CLASS[s.sev] + '"></span>' + esc(s.fam.title) + '</h2><div class="sum">' + familySummary(s.fam, s.ms) + '</div></div>');
    var full = s.ms.slice(0, TOP_N), rest = s.ms.slice(TOP_N);
    html.push('<div class="cards">' + full.map(cardHtml).join('') + '</div>');
    if (rest.length) {
      html.push('<div class="rows"><h3>' + rest.length + ' more ' + s.fam.noun + (rest.length === 1 ? '' : 's') + '</h3>' + rest.map(rowHtml).join('') + '</div>');
    }
    html.push('</section>');
  });
  html.push('</div></main><footer class="foot"><span>' + esc(M.db) + '</span><span>schema ' + esc(M.schema) + '</span><span>suite ' + esc(K.suiteVersion || '') + '</span>' +
    '<span>' + esc(M.run || '') + '</span><span>read-only</span><span>' + esc(M.file || '') + '</span></footer>');


  document.getElementById('app').innerHTML = html.join('');

  /* ---------- interaction ---------- */

  function nearest(pts, x) {
    var best = null, bd = Infinity;
    pts.forEach(function (p) { if (p.y != null && Math.abs(p.x - x) < bd) { bd = Math.abs(p.x - x); best = p; } });
    return best;
  }
  function anomalyNote(m, s, day) {
    var hit = m.anoms.filter(function (a) { return a.s === s && dayN(a.ts) === day && a.ak !== 'CPU_SHIFT'; });
    if (!hit.length) return '';
    var z = hit.reduce(function (b, a) { return Math.abs(a.z) > Math.abs(b.z) ? a : b; });
    if (m.fam.id === 'tablespaces') return 'unusual growth ' + sign(z.v) + fBytes(Math.abs(z.v)) + ', usual ' + fBytes(z.e) + ' · z ' + num(z.z, 1);
    return 'unusual, usual ' + m.unit.fmt(z.e) + ' · z ' + num(z.z, 1);
  }

  Array.prototype.forEach.call(document.querySelectorAll('.chart'), function (el) {
    var spec = CHARTS[+el.getAttribute('data-chart')];
    var svg = el.querySelector('svg'), tip = el.querySelector('.tip');
    var hx = svg.querySelector('.hx'), hd = svg.querySelector('.hd'), hit = svg.querySelector('.hit');
    function hide() { tip.classList.remove('on'); hx.setAttribute('visibility', 'hidden'); hd.setAttribute('visibility', 'hidden'); }
    hit.addEventListener('mouseleave', hide);
    hit.addEventListener('mousemove', function (ev) {
      var r = svg.getBoundingClientRect();
      var vx = (ev.clientX - r.left) / r.width * W;
      var x = spec.x0 + (vx - ML) / (W - ML - MR) * (spec.x1 - spec.x0);
      var lines = [], px, py;
      if (x <= LAST + 0.5) {
        var p = nearest(spec.lines[0].pts, x);
        if (!p) return hide();
        px = spec.xs(p.x); py = spec.ys(p.y);
        lines.push('<b>' + fWDay(p.x) + ' ' + dateOf(p.x).getUTCFullYear() + '</b>');
        spec.lines.forEach(function (l) {
          var q = nearest(l.pts, p.x);
          if (q && q.x === p.x) lines.push((l.label ? esc(l.label) + ' ' : '') + '<b>' + spec.unit.fmt(q.y) + '</b>' + (spec.m.f.lim && l.role === 0 && !spec.pctAxis ? ' · ' + num(q.y / (q.lim || spec.m.f.lim) * 100, 1) + '%' : ''));
          if (q && q.x === p.x && (q.a === 1 || q.a === -1)) {
            var note = anomalyNote(spec.m, l.s, q.x);
            lines.push('<span class="a">' + esc(note || 'unusual') + '</span>');
          }
        });
      } else {
        var fc = spec.fc;
        if (fc.length < 2) return hide();
        var i = 1;
        while (i < fc.length - 1 && fc[i].x < x) i++;
        var a = fc[i - 1], b = fc[i], t = Math.max(0, Math.min(1, (x - a.x) / (b.x - a.x)));
        var xd = Math.round(a.x + t * (b.x - a.x));
        t = (xd - a.x) / (b.x - a.x);
        var y = a.y + t * (b.y - a.y);
        var lo = a.lo != null ? a.lo + t * ((b.lo != null ? b.lo : b.y) - a.lo) : (b.lo != null ? a.y + t * (b.lo - a.y) : null);
        var hi = a.hi != null ? a.hi + t * ((b.hi != null ? b.hi : b.y) - a.hi) : (b.hi != null ? a.y + t * (b.hi - a.y) : null);
        px = spec.xs(xd); py = spec.ys(y);
        lines.push('<b>' + fWDay(xd) + ' ' + dateOf(xd).getUTCFullYear() + '</b> · +' + (xd - LAST) + ' d');
        lines.push('forecast <b>' + spec.unit.fmt(y) + '</b>');
        if (lo != null && hi != null) lines.push('95% ' + spec.unit.fmt(lo) + ' – ' + spec.unit.fmt(hi));
      }
      hx.setAttribute('x1', px); hx.setAttribute('x2', px); hx.setAttribute('visibility', 'visible');
      hd.setAttribute('cx', px); hd.setAttribute('cy', py); hd.setAttribute('visibility', 'visible');
      tip.innerHTML = lines.join('<br>');
      tip.style.left = Math.max(70, Math.min(r.width - 70, px / W * r.width)) + 'px';
      tip.style.top = (py / H * r.height) + 'px';
      tip.classList.add('on');
    });
  });

  Array.prototype.forEach.call(document.querySelectorAll('.heat'), function (el) {
    var tip = document.createElement('div');
    tip.className = 'tip';
    el.style.position = 'relative';
    el.appendChild(tip);
    el.addEventListener('mousemove', function (ev) {
      var c = ev.target;
      if (!c.classList || !c.classList.contains('hc')) { tip.classList.remove('on'); return; }
      var r = el.getBoundingClientRect(), cr = c.getBoundingClientRect();
      var v = c.getAttribute('data-v'), f = +c.getAttribute('data-f'), h = +c.getAttribute('data-h');
      tip.innerHTML = '<b>' + fWDay(+c.getAttribute('data-d')) + ' ' + (h < 10 ? '0' : '') + h + ':00</b> ' + (v === '' ? 'no data' : num(+v, 1) + '%') +
        (f === 1 ? '<br><span class="a">busier than this hour usually is</span>' : f === -1 ? '<br><span class="a">quieter than this hour usually is</span>' : '');
      tip.style.left = (cr.left - r.left + cr.width / 2) + 'px';
      tip.style.top = (cr.top - r.top) + 'px';
      tip.classList.add('on');
    });
    el.addEventListener('mouseleave', function () { tip.classList.remove('on'); });
  });

  var root = document.documentElement, TK = 'cap-theme';
  try { var saved = localStorage.getItem(TK); if (saved) root.setAttribute('data-theme', saved); } catch (e) { /* storage blocked */ }
  document.getElementById('themeBtn').onclick = function () {
    var cur = root.getAttribute('data-theme');
    var dark = cur ? cur === 'dark' : window.matchMedia('(prefers-color-scheme: dark)').matches;
    var next = dark ? 'light' : 'dark';
    root.setAttribute('data-theme', next);
    try { localStorage.setItem(TK, next); } catch (e) { /* storage blocked */ }
  };

  if ('IntersectionObserver' in window) {
    var links = {};
    Array.prototype.forEach.call(document.querySelectorAll('.nav a'), function (a) { links[a.getAttribute('href').slice(1)] = a; });
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting && links[e.target.id]) {
          Object.keys(links).forEach(function (k) { links[k].classList.toggle('on', k === e.target.id); });
        }
      });
    }, { rootMargin: '-110px 0px -70% 0px' });
    Array.prototype.forEach.call(document.querySelectorAll('main > section'), function (s) { io.observe(s); });
  }
})();
