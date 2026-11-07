#!/usr/bin/env python3
"""Static mockup of the restructured HTML report (glance / explore / inspect layers,
sticky navigator, runway strip, small multiples), fed by the demo report's data block.

    python3 docs/mockups/build_report_mockup.py docs/demo/cap_report_demo.html docs/mockups/cap_report_mockup.html

Design proposal only: report/html/report.js is the real renderer."""

import json, re, sys, pathlib
SRC = pathlib.Path(sys.argv[1])
OUT = pathlib.Path(sys.argv[2])
html = SRC.read_text()
data = re.search(r'<script type="application/json" id="cap-data">(.*?)</script>', html, re.S).group(1)

CSS = r"""
:root { color-scheme: light;
  --bg:#f6f7f9; --surface:#fff; --surface-2:#f1f3f6; --line:#dfe3ea; --line-2:#eceff4;
  --ink:#16243b; --ink-2:#41506a; --ink-3:#6c778a; --accent:#2f5fb3;
  --data:#16243b; --data-2:#9aa6b8; --band:rgba(22,36,59,.09); --fill:rgba(22,36,59,.05);
  --crit:#c4262e; --crit-wash:#fbe9e9; --warn:#b86e00; --warn-wash:#fdf3e1; --ok:#9aa3b2; --ok-wash:#eef1f5;
  --heat-0:#eef1f5; --heat-1:#16243b;
  --sans:"Source Sans 3","Segoe UI Variable Text","Segoe UI",system-ui,sans-serif; --mono:"JetBrains Mono","Cascadia Mono","SF Mono",Menlo,Consolas,monospace; }
:root[data-theme="dark"] { color-scheme: dark;
  --bg:#0a0d13; --surface:#10141c; --surface-2:#171c27; --line:#262d3a; --line-2:#1c222d;
  --ink:#e4e9f1; --ink-2:#a9b3c3; --ink-3:#7d889b; --accent:#7aa2f7;
  --data:#d5ddea; --data-2:#56627a; --band:rgba(213,221,234,.11); --fill:rgba(213,221,234,.05);
  --crit:#ef6461; --crit-wash:#2a1517; --warn:#e0a23a; --warn-wash:#2a2013; --ok:#4a5266; --ok-wash:#171c27;
  --heat-0:#171c27; --heat-1:#d5ddea; }
* { box-sizing:border-box; }
html { scroll-padding-top:56px; }
body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.5 var(--sans); font-variant-numeric:tabular-nums; -webkit-font-smoothing:antialiased; }
.id { font-family:var(--mono); font-size:.92em; letter-spacing:-.01em; }
a { color:inherit; text-decoration:none; }
b { font-weight:600; }
button { font:inherit; color:inherit; }
.page { max-width:1400px; margin:0 auto; padding:28px 40px 64px; background:var(--surface); min-height:100vh; }
.cols { display:grid; grid-template-columns:236px minmax(0,1fr); gap:0 44px; align-items:start; }
.side { position:sticky; top:0; max-height:100vh; overflow:auto; padding:34px 0 24px; scrollbar-width:thin; }
.side .sg { font:600 11.5px var(--sans); letter-spacing:.08em; text-transform:uppercase; color:var(--ink-3); margin:18px 0 6px; }
.side .sg:first-child { margin-top:0; }
.side a { display:grid; grid-template-columns:10px 1fr auto; gap:8px; align-items:center; padding:5px 8px; margin:0 -8px; border-radius:4px; font-size:14px; color:var(--ink-2); }
.side a:hover { background:var(--surface-2); color:var(--ink); }
.side a.on { background:var(--surface-2); color:var(--ink); font-weight:600; }
.side a .dot { width:7px; height:7px; }
.side a .n { color:var(--ink-3); font-size:12.5px; }
.side a.ser { padding-left:22px; font-size:13px; color:var(--ink-2); }
.side a.ser .nm { font-family:var(--mono); font-size:12.5px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.side a.ser .n { font-size:12px; }
.side a.crit .nm, .side a.crit .t { color:var(--crit); } .side a.warn .nm, .side a.warn .t { color:var(--warn); }
.side .sl { color:var(--ink-3); font-size:12.5px; padding:4px 0 0 22px; }
.side .sum { border-top:1px solid var(--ink); margin:0 0 14px; padding-top:10px; display:flex; gap:14px; font-size:13px; color:var(--ink-3); }
.side .sum b { font-size:20px; color:var(--ink); font-weight:600; margin-right:4px; } .side .sum .crit b { color:var(--crit); } .side .sum .warn b { color:var(--warn); }

.mast { display:flex; justify-content:space-between; flex-wrap:wrap; gap:4px 24px; color:var(--ink-2); font-size:13px; border-bottom:1px solid var(--ink); padding-bottom:10px; }
.mast b { color:var(--ink); font:600 16px var(--sans); margin-right:8px; }
.tools { display:flex; gap:14px; }
.tbtn { background:none; border:0; border-bottom:1px solid var(--line); padding:0 0 1px; color:var(--ink-3); font-size:12.5px; cursor:pointer; }
.tbtn:hover { color:var(--ink); border-bottom-color:var(--ink); }
.mono { font-family:var(--mono); }
.dot { display:inline-block; width:8px; height:8px; border-radius:50%; background:var(--ok); flex:none; }
.dot.crit { background:var(--crit); } .dot.warn { background:var(--warn); }
.st { font:600 12px var(--sans); letter-spacing:.02em; text-transform:uppercase; color:var(--ink-3); white-space:nowrap; }
.st.crit { color:var(--crit); font-weight:600; } .st.warn { color:var(--warn); font-weight:600; }
.stamp { font:13px var(--sans); color:var(--ink-2); white-space:nowrap; }
.tag { font:12px var(--sans); color:var(--ink-3); padding:0 6px; border:1px solid var(--line); border-radius:3px; white-space:nowrap; }

/* ---- glance ---- */
.glance { margin-top:34px; }
h1 { font:600 36px/1.12 var(--sans); letter-spacing:-.025em; margin:0 0 12px; text-wrap:balance; max-width:28ch; }
h1 .id { font-size:.9em; font-weight:500; }
h1 .crit { color:var(--crit); } h1 .warn { color:var(--warn); }
.lede { font-size:17px; color:var(--ink-2); max-width:66ch; margin:0 0 28px; }
.lede b { color:var(--ink); font-weight:500; }
h3 { margin:36px 0 10px; font:600 15px/1.3 var(--sans); letter-spacing:.01em; text-transform:uppercase; display:flex; gap:10px; align-items:baseline; }
h3 span { color:var(--ink-3); font:400 13px var(--sans); text-transform:none; letter-spacing:0; }

/* runway */
.runway { border-top:1px solid var(--ink); padding-top:6px; }
.runway svg { display:block; width:100%; height:auto; overflow:visible; }
.rw-zone-crit { fill:var(--crit-wash); } .rw-zone-warn { fill:var(--warn-wash); }
.rw-ax { stroke:var(--line); } .rw-ax-t { font:12px var(--sans); fill:var(--ink-3); }
.rw-lane { font:13px var(--sans); fill:var(--ink-3); }
.rw-lane-l { stroke:var(--line-2); }
.rw-d { fill:var(--ok); stroke:var(--surface); stroke-width:1.5; }
.rw-d.crit { fill:var(--crit); } .rw-d.warn { fill:var(--warn); }
.rw-lb { font:12px var(--mono); fill:var(--ink-2); } .rw-lb.crit { fill:var(--crit); font-weight:600; } .rw-lb.warn { fill:var(--warn); font-weight:600; }
.rw-ci { stroke:var(--ink-3); stroke-width:1; opacity:.5; }
.rw-pin { font:12px var(--sans); fill:var(--ink-3); }
.rw-note { color:var(--ink-3); font-size:12.5px; margin:4px 0 0; }

/* index */
.idx { border-top:1px solid var(--ink); }
.irow { display:grid; grid-template-columns:14px 150px 28px 1fr 220px 80px; gap:14px; align-items:center; padding:9px 0; border-bottom:1px solid var(--line); }
.irow:hover { background:var(--surface-2); }
.irow .it { font:500 13px var(--mono); } .irow.crit .it { color:var(--crit); } .irow.warn .it { color:var(--warn); }
.irow .ic { color:var(--ink-3); font:12.5px var(--mono); text-align:right; }
.irow .ih { color:var(--ink-2); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; } .irow .ih b { color:var(--ink); font-weight:500; }
.irow svg { display:block; width:100%; height:26px; }
.irow .iw { text-align:right; }
.sp-h { fill:none; stroke:var(--data); stroke-width:1.3; } .sp-f { fill:none; stroke:var(--data); stroke-width:1.1; stroke-dasharray:3 3; }
.sp-a { fill:var(--fill); } .sp-l { stroke:var(--crit); stroke-width:1; stroke-dasharray:2 3; opacity:.7; }

/* attention */
.attn { border-top:1px solid var(--ink); }
.arow { display:grid; grid-template-columns:80px 110px 1fr 1.4fr 110px; gap:14px; align-items:baseline; padding:9px 0; border-bottom:1px solid var(--line); font-size:13.5px; }
.arow:hover { background:var(--surface-2); }
.arow .m { color:var(--ink-3); font-size:12.5px; }
.arow .s { font:500 14px var(--mono); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; } .arow .s span { font:13px var(--sans); color:var(--ink-3); margin-left:4px; }
.arow.crit .s { color:var(--crit); } .arow.warn .s { color:var(--warn); }
.arow .d { text-align:right; }
.more { color:var(--ink-3); font-size:12.5px; padding:8px 0; }

/* ---- families ---- */
.fams { margin-top:56px; }
.fams > h2 { font:600 13px var(--sans); color:var(--ink-3); letter-spacing:.06em; text-transform:uppercase; margin:0 0 6px; }
details.fam { border-top:1px solid var(--line); }
details.fam:last-of-type { border-bottom:1px solid var(--line); }
details.fam > summary { list-style:none; cursor:pointer; display:grid; grid-template-columns:14px 170px 28px 1fr 260px 20px; gap:14px; align-items:center; padding:14px 0; }
details.fam > summary::-webkit-details-marker { display:none; }
details.fam > summary:hover { background:var(--surface-2); }
.fam .ft { font:600 18px var(--sans); letter-spacing:-.015em; } .fam.crit .ft { color:var(--crit); } .fam.warn .ft { color:var(--warn); }
.fam .fc { color:var(--ink-3); font:13px var(--sans); text-align:right; }
.fam .fh { color:var(--ink-2); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; } .fam .fh b { color:var(--ink); font-weight:500; }
.fam .fs { display:flex; gap:6px; justify-content:flex-end; align-items:center; }
.fam .fs svg { width:48px; height:20px; display:block; }
.fam .fs .n { font:12px var(--sans); color:var(--ink-3); }
.fam .chev { color:var(--ink-3); transition:transform .15s; text-align:right; }
details[open] .chev { transform:rotate(90deg); }
.fam .body { padding:0 0 28px 28px; }

/* small multiples */
.minis { display:grid; grid-template-columns:repeat(auto-fill,minmax(230px,1fr)); gap:14px 20px; }
.mini { border:1px solid var(--line); border-radius:4px; padding:10px 12px 8px; cursor:pointer; background:var(--surface); transition:border-color .15s; }
.mini:hover { border-color:var(--ink-3); } .mini.on { border-color:var(--ink); box-shadow:0 0 0 1px var(--ink); }
.mini.crit { border-left:3px solid var(--crit); } .mini.warn { border-left:3px solid var(--warn); }
.mini .mh { display:flex; justify-content:space-between; align-items:baseline; gap:8px; }
.mini .mn { font:500 13px var(--mono); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.mini .mn span { font:12px var(--sans); color:var(--ink-3); margin-left:4px; }
.mini .mv { font:500 13px var(--sans); color:var(--ink-2); white-space:nowrap; }
.mini .mv b { color:var(--ink); font-weight:600; } .mini.crit .mv b { color:var(--crit); } .mini.warn .mv b { color:var(--warn); }
.mini svg { display:block; width:100%; height:64px; margin-top:6px; }
.bullet { position:relative; height:6px; background:var(--surface-2); border-radius:2px; margin-top:8px; overflow:visible; }
.bullet i { position:absolute; left:0; top:0; height:100%; background:var(--data-2); border-radius:2px; }
.bullet i.now { background:var(--data); z-index:1; } .bullet i.now.crit { background:var(--crit); } .bullet i.now.warn { background:var(--warn); }
.bullet i.fc { opacity:.45; }
.bullet em { position:absolute; top:-3px; width:1px; height:12px; background:var(--ink-3); }
.bullet em.lim { background:var(--crit); width:2px; right:0; }
.bl { display:flex; justify-content:space-between; font:12px var(--sans); color:var(--ink-3); margin-top:4px; }

/* focus card */
.card { margin-top:18px; border-top:1px solid var(--ink); padding-top:14px; display:none; }
.card.on { display:block; }
.card .ch { display:flex; gap:12px; align-items:baseline; flex-wrap:wrap; }
.card .ch h4 { margin:0; font:500 22px var(--mono); letter-spacing:-.02em; } .card .ch .ctr { color:var(--ink-3); }
.card .ch .x { margin-left:auto; }
.verdict { font-size:15px; margin:6px 0 12px; color:var(--ink-2); max-width:80ch; } .verdict b { color:var(--ink); } .verdict.crit b { color:var(--crit); } .verdict.warn b { color:var(--warn); }
.facts { display:flex; gap:36px; flex-wrap:wrap; margin-bottom:14px; }
.fact .l { color:var(--ink-3); font-size:13px; } .fact .v { font:600 26px/1.15 var(--sans); letter-spacing:-.02em; } .fact .v small { font-size:14px; color:var(--ink-3); margin-left:2px; }
.fact .s { color:var(--ink-3); font-size:12px; } .fact.crit .v { color:var(--crit); } .fact.warn .v { color:var(--warn); }
.viz { display:grid; grid-template-columns:minmax(0,1fr) auto; gap:24px; align-items:start; }
.viz svg.chart { display:block; width:100%; height:auto; }
.ax { stroke:var(--line); } .axt { font:12px var(--sans); fill:var(--ink-3); }
.hist { fill:none; stroke:var(--data); stroke-width:1.6; } .hist2 { fill:none; stroke:var(--data-2); stroke-width:1.2; }
.area { fill:var(--fill); } .fcl { fill:none; stroke:var(--data); stroke-width:1.5; stroke-dasharray:5 4; } .bandp { fill:var(--band); }
.lim { stroke:var(--crit); stroke-width:1; stroke-dasharray:2 3; } .limt { font:12px var(--sans); fill:var(--crit); }
.thr { stroke:var(--warn); stroke-width:1; stroke-dasharray:2 3; } .thrt { font:12px var(--sans); fill:var(--warn); }
.anc { fill:var(--surface); stroke:var(--crit); stroke-width:1.5; } .anc.lo { stroke:var(--accent); }
.cross { font:600 13px var(--sans); fill:var(--ink); } .today { stroke:var(--ink-3); stroke-dasharray:1 3; }
.slope { font:12px var(--sans); fill:var(--ink-2); }
.cal { margin-top:10px; }
.cal .cl { display:flex; justify-content:space-between; font:12px var(--sans); color:var(--ink-3); margin-bottom:3px; }
.cal .cells { display:grid; grid-template-columns:repeat(30,1fr); gap:2px; }
.cal .cells i { display:block; height:10px; background:var(--heat-0); border-radius:1px; }
.cal .cells i.z1 { background:var(--warn-wash); } .cal .cells i.z2 { background:var(--warn); } .cal .cells i.z3 { background:var(--crit); }
.heat { width:220px; } .heat svg { display:block; width:100%; height:auto; } .heat .hl { font:12px var(--sans); color:var(--ink-3); margin-bottom:4px; }
.heat .hax { font:10px var(--sans); fill:var(--ink-3); }
.moredet { margin-top:12px; } .moredet summary { font:13px var(--sans); color:var(--ink-3); cursor:pointer; }
.moredet dl { display:grid; grid-template-columns:max-content 1fr; gap:4px 18px; margin:8px 0 0; font-size:13px; } .moredet dt { color:var(--ink-3); } .moredet dd { margin:0; }
.fineline { display:grid; grid-template-columns:14px 170px 28px 1fr; gap:14px; align-items:center; padding:10px 0; border-top:1px solid var(--line); color:var(--ink-2); font-size:13.5px; }
.fineline .ft { font:500 14px var(--mono); color:var(--ink); } .fineline .fc { color:var(--ink-3); font:12.5px var(--mono); text-align:right; }
.foot { margin-top:48px; padding-top:10px; border-top:1px solid var(--line); display:flex; gap:20px; flex-wrap:wrap; color:var(--ink-3); font:12.5px var(--sans); }
@media print { details.fam { break-inside:avoid; } .card { display:block !important; } .tools { display:none; } }
@media (max-width: 1000px) { .cols { grid-template-columns:1fr; } .side { position:static; max-height:none; padding:16px 0 0; display:flex; flex-wrap:wrap; gap:4px 10px; } .side .sg, .side .sum, .side .sl, .side a.ser { display:none; } .side a { border:1px solid var(--line); margin:0; padding:3px 10px; border-radius:999px; } }
@media (max-width: 760px) { .page { padding:20px 16px 48px; } .arow { grid-template-columns:70px 1fr 90px; } .arow .m, .arow .f { display:none; } details.fam > summary { grid-template-columns:14px 1fr 28px 20px; } .fam .fh, .fam .fs { display:none; } .fam .body { padding-left:0; } .viz { grid-template-columns:1fr; } }
"""

JS = r"""
(function(){
'use strict';
var D = JSON.parse(document.getElementById('cap-data').textContent), M = D.meta||{}, K = M.knobs||{};
var CPU_SAT = K.cpuSat||80, SERIES_SAT = K.seriesSat||90, ANOM_DAYS = M.anomalyDays||30;
var MS=864e5, MON=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'], WD=['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
var RANK={CRIT:0,WARN:1,INFO:2,OK:3}, CLS={CRIT:'crit',WARN:'warn',INFO:'info',OK:'ok'}, LBL={CRIT:'Critical',WARN:'Warning',INFO:'Info',OK:'OK'};
var QT={FLAT:'flat',CYCLIC:'cyclic',LOW_CONFIDENCE:'low confidence',INSUFFICIENT_HISTORY:'short history'};
function dayN(s){return s?Date.UTC(+s.slice(0,4),+s.slice(5,7)-1,+s.slice(8,10))/MS:null;}
function dOf(n){return new Date(n*MS);} function fDay(n){var d=dOf(n);return d.getUTCDate()+' '+MON[d.getUTCMonth()];}
function fDayY(n){var d=dOf(n);return fDay(n)+' '+d.getUTCFullYear();}
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
function num(v,dp){return v==null||!isFinite(v)?'–':Number(v).toLocaleString('en-US',{minimumFractionDigits:dp,maximumFractionDigits:dp});}
function auto(v){if(v==null)return'–';var a=Math.abs(v);return a===0?'0':num(v,a>=100?0:a>=10?1:2);}
var BU=[['TiB',Math.pow(1024,4)],['GiB',Math.pow(1024,3)],['MiB',Math.pow(1024,2)],['KiB',1024]];
function fBytes(b){if(b==null)return'–';var a=Math.abs(b)*1.0001;for(var i=0;i<BU.length;i++)if(a>=BU[i][1])return auto(b/BU[i][1])+' '+BU[i][0];return auto(b)+' B';}
function sign(v){return v>0?'+':v<0?'−':'';}
function fDays(d){if(d==null)return'–';if(d<1)return'< 1 d';if(d<=120)return Math.round(d)+' d';if(d<730)return Math.round(d/30.4)+' mo';if(d>3650)return'> 10 y';return num(d/365.25,1)+' y';}
function unitFor(u){
  if(u==='BYTES')return{fmt:fBytes,rate:function(v){return v==null?'–':sign(v)+fBytes(Math.abs(v))+'/d';},rl:'Growth'};
  if(u==='PCT')return{fmt:function(v){return v==null?'–':num(v,1)+'%';},rate:function(v){return v==null?'–':sign(v)+num(Math.abs(v)*30,1)+' pts/30 d';},rl:'Trend'};
  if(u==='GIB')return{fmt:function(v){return v==null?'–':fBytes(v*Math.pow(1024,3));},rate:function(v){return v==null?'–':sign(v)+fBytes(Math.abs(v)*Math.pow(1024,3))+'/d';},rl:'Growth'};
  return{fmt:auto,rate:function(v){return v==null?'–':sign(v)+auto(Math.abs(v))+'/d';},rl:'Growth'};
}
function key(){return Array.prototype.join.call(arguments,'|');}
function groupBy(rows,kf){var m={};(rows||[]).forEach(function(r){var k=kf(r);(m[k]=m[k]||[]).push(r);});return m;}
var LAST=dayN(M.lastDay), FIRST=dayN(M.firstDay);
var CON={};(D.containers||[]).forEach(function(c){CON[key(c.dbid,c.con)]=c;});
function conName(d,c){var x=CON[key(d,c)];return x?x.pdb:String(c);}
var FIT={};(D.fits||[]).forEach(function(f){FIT[key(f.k,f.dbid,f.con,f.s)]=f;});
var PTS={};(D.points||[]).forEach(function(p){var t0=dayN(p.t0);PTS[key(p.k,p.dbid,p.con,p.s)]=p.d.map(function(r){return{x:t0+r[0],y:r[1],lim:r[2],a:r[3],gap:r[4]};});});
var FC=groupBy(D.forecast,function(r){return key(r.k,r.dbid,r.con,r.s);});
var AN=groupBy(D.anomalies,function(r){return key(r.dbid,r.con,r.s);});
var AL=groupBy(D.alerts,function(r){return key(r.dbid,r.con,r.s);});
var HOURS={};(D.hours||[]).forEach(function(h){HOURS[key(h.dbid,h.con,h.s)]=h;});

function sIs(n){return function(f){return f.k==='SERIES'&&f.s===n;};} function sPfx(p){return function(f){return f.k==='SERIES'&&f.s.indexOf(p)===0;};}
var FAM=[
 {id:'tablespaces',title:'Tablespaces',noun:'tablespace',match:function(f){return f.k==='TBSPC';},name:function(f){return f.s;},unit:'BYTES',target:'full',warn:K.nfWarn,crit:K.nfCrit,limWord:'ceiling'},
 {id:'db-size',title:'Database size',noun:'container',match:sIs('DB_SIZE_GB'),name:function(f){return conName(f.dbid,f.con);},unit:'GIB',target:'allocated',limWord:'allocated'},
 {id:'host-cpu',title:'Host CPU',noun:'host',match:function(f){return f.k==='CPU'&&f.s==='BUSY_P95';},name:function(f){return CON[key(f.dbid,f.con)].db;},related:['BUSY_PCT'],unit:'PCT',target:CPU_SAT+'% busy',heat:'BUSY_PCT',lines:[['BUSY_P95','busy-hour p95'],['BUSY_PCT','daily average']],limWord:'saturation line'},
 {id:'db-cpu',title:'DB CPU',noun:'container',match:function(f){return f.k==='CPU'&&f.s==='DB_CPU_P95';},name:function(f){return conName(f.dbid,f.con);},related:['DB_CPU_PCT'],unit:'PCT',target:CPU_SAT+'% of CPUs',heat:'DB_CPU_PCT',lines:[['DB_CPU_P95','busy-hour p95'],['DB_CPU_PCT','daily average']],limWord:'saturation line'},
 {id:'sessions',title:'Sessions',noun:'container',match:sIs('SESSIONS'),name:function(f){return conName(f.dbid,f.con);},unit:'N',target:'limit',limWord:'limit'},
 {id:'processes',title:'Processes',noun:'container',match:sIs('PROCESSES'),name:function(f){return conName(f.dbid,f.con);},unit:'N',target:'limit',limWord:'limit'},
 {id:'redo',title:'Redo',noun:'database',match:sIs('REDO_GB_DAY'),name:function(f){return conName(f.dbid,f.con);},unit:'GIB',nolimit:true},
 {id:'undo',title:'Undo',noun:'tablespace',match:sPfx('UNDO_PEAK:'),name:function(f){return f.s.slice(10);},unit:'GIB',target:'max size',limWord:'max size'},
 {id:'temp',title:'Temp',noun:'tablespace',match:sPfx('TEMP_PEAK:'),name:function(f){return f.s.slice(10);},unit:'GIB',target:'max size',limWord:'max size'},
 {id:'asm',title:'ASM disk groups',noun:'disk group',match:sPfx('ASM_DG:'),name:function(f){return f.s.slice(7);},unit:'GIB',target:'total',limWord:'total'}
];
function worst(l){var b='OK';l.forEach(function(s){if(s&&RANK[s]!=null&&RANK[s]<RANK[b])b=s;});return b;}
function build(fam,f){
  var m={fam:fam,f:f,id:fam.id+'-'+f.con+'-'+f.s.replace(/[^A-Za-z0-9]/g,'_'),name:fam.name(f),ctr:fam.id==='host-cpu'||fam.name(f)===conName(f.dbid,f.con)?'':conName(f.dbid,f.con),unit:unitFor(fam.unit)};
  m.pts=PTS[key(f.k,f.dbid,f.con,f.s)]||[]; m.pts2=fam.lines?PTS[key(f.k,f.dbid,f.con,fam.lines[1][0])]||[]:null;
  m.fc=(FC[key(f.k,f.dbid,f.con,f.s)]||[]).filter(function(r){return r.m==='REGR';}).sort(function(a,b){return a.h-b.h;});
  var names=[f.s].concat(fam.related||[]); m.anoms=[]; m.alerts=[];
  names.forEach(function(s){m.anoms=m.anoms.concat(AN[key(f.dbid,f.con,s)]||[]);m.alerts=m.alerts.concat(AL[key(f.dbid,f.con,s)]||[]);});
  m.alerts.sort(function(a,b){return RANK[a.sev]-RANK[b.sev];});
  m.sev=worst(m.alerts.map(function(a){return a.sev;}).concat([f.sev]));
  m.sat=fam.unit==='PCT'?CPU_SAT:fam.id==='tablespaces'?null:SERIES_SAT;
  m.lim=fam.unit==='PCT'?CPU_SAT:f.lim;
  m.at90=null; m.fc.forEach(function(r){if(r.h===90)m.at90=r.v;});
  return m;
}
var SECS=FAM.map(function(fam){var ms=(D.fits||[]).filter(fam.match).map(function(f){return build(fam,f);});
  ms.sort(function(a,b){return RANK[a.sev]-RANK[b.sev]||((a.f.dtf==null?1e9:a.f.dtf)-(b.f.dtf==null?1e9:b.f.dtf))||(a.name<b.name?-1:1);});
  return{fam:fam,ms:ms,sev:worst(ms.map(function(m){return m.sev;}))};}).filter(function(s){return s.ms.length;});
var BYS={};SECS.forEach(function(s){s.ms.forEach(function(m){[m.f.s].concat(m.fam.related||[]).forEach(function(x){BYS[key(m.f.dbid,m.f.con,x)]=m;});});});
var ALERTS=(D.alerts||[]).slice().sort(function(a,b){return RANK[a.sev]-RANK[b.sev];});
var LISTED=ALERTS.filter(function(a){return a.sev==='CRIT'||a.sev==='WARN';});
var nCrit=LISTED.filter(function(a){return a.sev==='CRIT';}).length, nWarn=LISTED.length-nCrit;
var nSeries=SECS.reduce(function(n,s){return n+s.ms.length;},0);

function pill(sev,t){return'<span class="st '+CLS[sev]+'">'+esc(t||LBL[sev])+'</span>';}
function dot(sev){return'<span class="dot '+CLS[sev]+'"></span>';}
function stamp(d){return'<span class="stamp">→ '+fDay(Math.round(d))+'</span>';}
function dtfTone(f){return f.dtf==null||f.q!=='OK'?'':f.dtf<=K.dtfCrit?'crit':f.dtf<=K.dtfWarn?'warn':'';}
function alertFact(a){switch(a.kind){
  case'TBSPC_FULL':return'full in <b>'+fDays(a.v)+'</b>';case'CPU_SAT':case'DBCPU_SAT':return CPU_SAT+'% busy in <b>'+fDays(a.v)+'</b>';
  case'SERIES_LIMIT':return SERIES_SAT+'% of limit in <b>'+fDays(a.v)+'</b>';case'TBSPC_NEARFULL':return'<b>'+num(a.v,1)+'%</b> used';
  case'SERIES_NEARLIMIT':return'<b>'+num(a.v,1)+'%</b> of limit';case'CPU_HOT':case'DBCPU_HOT':return'p95 <b>'+num(a.v,1)+'%</b> now';}
  if(/_ANOM$/.test(a.kind)){var v=a.u==='BYTES'?fBytes(a.v)+'/d':a.u==='PCT'?num(a.v,1)+'%':a.u==='GIB'?auto(a.v)+' GiB/d':auto(a.v);return'unusual <b>'+v+'</b>'+(a.n>1?' for '+a.n+' days':'')+', z '+num(a.maxz,1);}
  return esc(a.msg||a.kind);}
function alertWhen(a){if(a.u==='DAYS')return stamp(LAST+a.v);if(/_ANOM$/.test(a.kind))return'<span class="stamp">'+fDay(dayN(a.n>1?a.first:a.day))+(a.n>1?'–'+fDay(dayN(a.day)):'')+'</span>';return'<span class="stamp">now</span>';}
function lastVal(p){for(var i=p.length-1;i>=0;i--)if(p[i].y!=null)return p[i].y;return null;}

/* ---- sparkline ---- */
function spark(m,w,h,withFc){
  var x0=LAST-120,x1=LAST+(withFc?60:0),ymax=0,pts=m.pts.filter(function(p){return p.x>=x0&&p.y!=null;});
  pts.forEach(function(p){ymax=Math.max(ymax,p.y);}); if(m.lim!=null&&m.fam.id!=='db-size')ymax=Math.max(ymax,m.lim);
  var fc=withFc?m.fc.filter(function(k){return k.h<=60;}):[];fc.forEach(function(k){ymax=Math.max(ymax,k.v);});
  var xs=function(x){return 1+(x-x0)/(x1-x0)*(w-2);},ys=function(y){return h-2-y/(ymax*1.05||1)*(h-4);};
  var o=['<svg viewBox="0 0 '+w+' '+h+'" preserveAspectRatio="none">'];
  if(pts.length){var d='M'+pts.map(function(p){return xs(p.x).toFixed(1)+','+ys(p.y).toFixed(1);}).join('L');
    o.push('<path class="sp-a" d="'+d+'L'+xs(pts[pts.length-1].x).toFixed(1)+','+h+'L'+xs(pts[0].x).toFixed(1)+','+h+'Z"/>');o.push('<path class="sp-h" vector-effect="non-scaling-stroke" d="'+d+'"/>');}
  if(fc.length>1)o.push('<path class="sp-f" vector-effect="non-scaling-stroke" d="M'+fc.map(function(k){return xs(LAST+k.h).toFixed(1)+','+ys(k.v).toFixed(1);}).join('L')+'"/>');
  if(m.lim!=null&&m.fam.id!=='db-size')o.push('<line class="sp-l" vector-effect="non-scaling-stroke" x1="0" x2="'+w+'" y1="'+ys(m.lim).toFixed(1)+'" y2="'+ys(m.lim).toFixed(1)+'"/>');
  o.push('</svg>');return o.join('');
}

/* ---- runway strip ---- */
function runway(){
  var lanes=[{t:'Tablespaces',ids:['tablespaces']},{t:'CPU',ids:['host-cpu','db-cpu']},{t:'Sessions & processes',ids:['sessions','processes']},{t:'Space (DB size, undo, temp)',ids:['db-size','undo','temp','asm']}];
  var W=1080,ML=190,MR=170,LH=46,top=28,H=top+lanes.length*LH+8;
  var dmin=7,dmax=730,px=function(d){d=Math.max(dmin,Math.min(dmax,d));return ML+Math.log(d/dmin)/Math.log(dmax/dmin)*(W-ML-MR);};
  var beyond=W-MR+90;
  var o=['<svg viewBox="0 0 '+W+' '+H+'">'];
  o.push('<rect class="rw-zone-crit" x="'+ML+'" y="'+(top-6)+'" width="'+(px(K.dtfCrit)-ML)+'" height="'+(H-top)+'"/>');
  o.push('<rect class="rw-zone-warn" x="'+px(K.dtfCrit)+'" y="'+(top-6)+'" width="'+(px(K.dtfWarn)-px(K.dtfCrit))+'" height="'+(H-top)+'"/>');
  [[7,'today'],[30,'30 d'],[90,'90 d'],[180,'6 mo'],[365,'1 y'],[730,'2 y']].forEach(function(t){
    o.push('<line class="rw-ax" x1="'+px(t[0])+'" x2="'+px(t[0])+'" y1="'+(top-6)+'" y2="'+(H-8)+'"/>');
    o.push('<text class="rw-ax-t" x="'+px(t[0])+'" y="'+(top-12)+'" text-anchor="middle">'+t[1]+'</text>');});
  o.push('<text class="rw-ax-t" x="'+beyond+'" y="'+(top-12)+'" text-anchor="middle">not growing</text>');
  lanes.forEach(function(ln,i){
    var y=top+i*LH+LH/2;
    o.push('<line class="rw-lane-l" x1="'+ML+'" x2="'+(W-10)+'" y1="'+y+'" y2="'+y+'"/>');
    o.push('<text class="rw-lane" x="'+(ML-14)+'" y="'+(y+4)+'" text-anchor="end">'+esc(ln.t)+'</text>');
    var ms=[];SECS.forEach(function(s){if(ln.ids.indexOf(s.fam.id)>=0)ms=ms.concat(s.ms.filter(function(m){return!m.fam.nolimit;}));});
    var placed=[];
    ms.sort(function(a,b){return(a.f.dtf==null?1e9:a.f.dtf)-(b.f.dtf==null?1e9:b.f.dtf);});
    var nBeyond=0;
    ms.forEach(function(m){
      var f=m.f,grow=f.dtf!=null&&f.q!=='FLAT'&&f.q!=='CYCLIC'&&f.dtf<=dmax;
      var x=grow?px(f.dtf):beyond;
      var tone=grow?dtfTone(f):'';
      var dy=0;placed.forEach(function(p){if(Math.abs(p.x-x)<70&&p.dy===dy)dy=p.dy===0?-13:p.dy<0?13:0;});
      if(!grow){dy=0;nBeyond++;}
      placed.push({x:x,dy:dy});
      if(grow&&f.dtfLo!=null&&f.dtfHi!=null&&f.dtfHi<=dmax*2)o.push('<line class="rw-ci" x1="'+px(f.dtfLo)+'" x2="'+px(Math.min(f.dtfHi,dmax))+'" y1="'+(y+dy)+'" y2="'+(y+dy)+'"/>');
      o.push('<circle class="rw-d '+tone+'" cx="'+x+'" cy="'+(y+dy)+'" r="'+(grow?5:3.5)+'"><title>'+esc(m.name+(m.ctr?' ('+m.ctr+')':''))+(grow?': '+fDays(f.dtf)+' to '+m.fam.target:': '+(QT[f.q]||'beyond 2 y'))+'</title></circle>');
      if(grow&&f.dtf<=120)o.push('<text class="rw-lb '+tone+'" x="'+(x+9)+'" y="'+(y+dy+4)+'">'+esc(m.name)+(f.dtf<=120?' · '+fDays(f.dtf):'')+'</text>');
    });
    if(nBeyond)o.push('<text class="rw-pin" x="'+(beyond+10)+'" y="'+(y+4)+'">'+nBeyond+'</text>');
  });
  o.push('</svg>');
  return'<div class="runway">'+o.join('')+'</div><p class="rw-note">One dot per series at its forecast date for reaching the ceiling (tablespaces: full; CPU: '+CPU_SAT+'%; sessions, processes, undo, temp: '+SERIES_SAT+'% of the limit). Red zone within '+K.dtfCrit+' days, amber within '+K.dtfWarn+'. Series past four months are unlabelled; flat and cyclic ones are pinned on the right. Hover a dot for its name.</p>';
}

/* ---- full chart ---- */
function chart(m){
  var W=640,H=210,ML=64,MR=132,MT=22,MB=24,f=m.f;
  var x0=FIRST,x1=LAST+120,pts=m.pts.filter(function(p){return p.y!=null;}),ymax=0,ymin=1e18;
  pts.forEach(function(p){ymax=Math.max(ymax,p.y);ymin=Math.min(ymin,p.y);});
  var fc=m.fc.filter(function(k){return k.h<=120;});fc.forEach(function(k){ymax=Math.max(ymax,k.hi!=null?k.hi:k.v);});
  if(m.lim!=null)ymax=Math.max(ymax,m.lim);
  var thr=m.sat!=null&&m.fam.unit!=='PCT'&&m.lim!=null?m.lim*m.sat/100:m.fam.id==='tablespaces'&&m.lim!=null?m.lim*K.nfWarn/100:null;
  var top=ymax*1.06,bot=0;
  var xs=function(x){return ML+(x-x0)/(x1-x0)*(W-ML-MR);},ys=function(y){return MT+(1-(y-bot)/(top-bot||1))*(H-MT-MB);};
  var o=['<svg class="chart" viewBox="0 0 '+W+' '+H+'">'];
  var div=m.fam.unit==='BYTES'?byteDiv(top):1,step=niceStep(top/div,4)*div;for(var t=0;t<=top;t+=step){o.push('<line class="ax" x1="'+ML+'" x2="'+(W-MR)+'" y1="'+ys(t).toFixed(1)+'" y2="'+ys(t).toFixed(1)+'"/><text class="axt" x="'+(ML-6)+'" y="'+(ys(t)+3.5).toFixed(1)+'" text-anchor="end">'+esc(m.unit.fmt(t))+'</text>');}
  for(var mo=firstMonth(x0);mo<x1;mo=nextMonth(mo)){o.push('<text class="axt" x="'+xs(mo).toFixed(1)+'" y="'+(H-7)+'" text-anchor="middle">'+MON[dOf(mo).getUTCMonth()]+'</text>');}
  var band=fc.filter(function(k){return k.lo!=null&&k.hi!=null;});
  if(band.length>1){var poly=band.map(function(k){return[xs(LAST+k.h),ys(Math.min(k.hi,top))];}).concat(band.slice().reverse().map(function(k){return[xs(LAST+k.h),ys(Math.max(k.lo,0))];}));o.push('<path class="bandp" d="M'+poly.map(function(p){return p[0].toFixed(1)+','+p[1].toFixed(1);}).join('L')+'Z"/>');}
  if(m.pts2){var p2=m.pts2.filter(function(p){return p.y!=null;});o.push('<path class="hist2" d="M'+p2.map(function(p){return xs(p.x).toFixed(1)+','+ys(p.y).toFixed(1);}).join('L')+'"/>');}
  var d='M'+pts.map(function(p){return xs(p.x).toFixed(1)+','+ys(p.y).toFixed(1);}).join('L');
  o.push('<path class="area" d="'+d+'L'+xs(pts[pts.length-1].x).toFixed(1)+','+ys(0)+'L'+xs(pts[0].x).toFixed(1)+','+ys(0)+'Z"/><path class="hist" d="'+d+'"/>');
  if(fc.length>1)o.push('<path class="fcl" d="M'+fc.map(function(k){return xs(LAST+k.h).toFixed(1)+','+ys(k.v).toFixed(1);}).join('L')+'"/>');
  o.push('<line class="today" x1="'+xs(LAST)+'" x2="'+xs(LAST)+'" y1="'+MT+'" y2="'+ys(0)+'"/>');
  if(thr!=null){o.push('<line class="thr" x1="'+ML+'" x2="'+(W-MR)+'" y1="'+ys(thr)+'" y2="'+ys(thr)+'"/><text class="thrt" x="'+(W-MR+6)+'" y="'+(ys(thr)+3.5)+'">'+(m.fam.id==='tablespaces'?K.nfWarn:m.sat)+'% warning</text>');}
  if(m.lim!=null){o.push('<line class="lim" x1="'+ML+'" x2="'+(W-MR)+'" y1="'+ys(m.lim)+'" y2="'+ys(m.lim)+'"/><text class="limt" x="'+(W-MR+6)+'" y="'+(ys(m.lim)+3.5)+'">'+esc(m.fam.limWord+' '+m.unit.fmt(m.lim))+'</text>');}
  var crossD=f.dtf!=null&&f.q==='OK'&&f.dtf<=120?LAST+f.dtf:null;
  if(crossD!=null){var cy=m.lim!=null?(m.fam.id==='tablespaces'?m.lim:m.fam.unit==='PCT'?CPU_SAT:m.lim*SERIES_SAT/100):null;if(cy!=null){o.push('<circle class="anc" cx="'+xs(crossD)+'" cy="'+ys(cy)+'" r="4"/><text class="cross" x="'+(xs(crossD)+(crossD>x1-30?-8:8))+'" y="'+(ys(cy)-10)+'" text-anchor="'+(crossD>x1-30?'end':'start')+'">→ '+fDay(Math.round(crossD))+'</text>');}}
  if(f.slope!=null&&f.q==='OK'&&fc.length){var kk=fc[Math.floor(fc.length*0.8)];o.push('<text class="slope" x="'+(xs(LAST+kk.h)-6)+'" y="'+(ys(kk.v)+16)+'" text-anchor="end">'+esc(m.unit.rate(f.slope))+'</text>');}
  m.anoms.filter(function(a){return a.ak!=='CPU_SHIFT'&&a.grain!=='HOUR'&&dayN(a.ts)>LAST-ANOM_DAYS;}).sort(function(a,b){return Math.abs(b.z)-Math.abs(a.z);}).slice(0,6).forEach(function(a){if(a.ak==='CPU_SHIFT'||a.grain==='HOUR'||a.s!==f.s&&!(m.fam.lines&&a.s===m.fam.lines[1][0]))return;var x=dayN(a.ts);if(x<=LAST-ANOM_DAYS)return;var p=nearest(a.s===f.s?pts:(m.pts2||pts),x);if(p)o.push('<circle class="anc '+(a.f==='LOW'?'lo':'')+'" cx="'+xs(p.x).toFixed(1)+'" cy="'+ys(p.y).toFixed(1)+'" r="3.5"><title>'+esc(WD[dOf(x).getUTCDay()]+' '+fDay(x)+': '+m.unit.fmt(a.v)+', usual '+m.unit.fmt(a.e)+', z '+num(a.z,1))+'</title></circle>');});
  o.push('</svg>');return o.join('');
}
function nearest(pts,x){var b=null,bd=2;pts.forEach(function(p){if(Math.abs(p.x-x)<bd){bd=Math.abs(p.x-x);b=p;}});return b;}
function byteDiv(v){for(var i=0;i<BU.length;i++)if(v>=BU[i][1])return BU[i][1];return 1;}
function niceStep(top,n){var r=top/n,p=Math.pow(10,Math.floor(Math.log(r)/Math.LN10)),c=r/p;return(c<1.5?1:c<3?2:c<7?5:10)*p;}
function firstMonth(x){var d=dOf(x);return Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,1)/MS;}
function nextMonth(x){var d=dOf(x);return Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,1)/MS;}

function calendar(m){
  var days={};m.anoms.forEach(function(a){if(a.ak==='CPU_SHIFT')return;var d=dayN(a.ts);if(d<=LAST-30)return;var z=Math.abs(a.z||0);if(!days[d]||z>days[d].z)days[d]={z:z,a:a};});
  var cells=[];for(var i=29;i>=0;i--){var d=LAST-i,e=days[d];var c=e?e.z>=5?'z3':e.z>=3.5?'z2':'z1':'';cells.push('<i class="'+c+'" title="'+esc(WD[dOf(d).getUTCDay()]+' '+fDay(d)+(e?': '+(e.a.f==='LOW'?'low':'high')+', z '+num(e.z,1)+(e.a.grain==='HOUR'?' (hour of week)':''):''))+'"></i>');}
  var n=Object.keys(days).length;
  return'<div class="cal"><div class="cl"><span>Unusual days, last 30</span><span>'+(n?n+' flagged':'none')+'</span></div><div class="cells">'+cells.join('')+'</div></div>';
}
function heat(m){
  var h=HOURS[key(m.f.dbid,m.f.con,m.fam.heat)];if(!h)return'';
  var W=220,H=84,ML=22,MT=12,cw=(W-ML)/24,ch=(H-MT)/7,mx=0;h.d.forEach(function(r){mx=Math.max(mx,r[2]);});
  var o=['<div class="heat"><div class="hl">Hour of week, last '+ANOM_DAYS+' d</div><svg viewBox="0 0 '+W+' '+H+'">'];
  h.d.forEach(function(r){var a=(r[2]/(mx||1));o.push('<rect x="'+(ML+r[1]*cw).toFixed(1)+'" y="'+(MT+r[0]*ch).toFixed(1)+'" width="'+(cw-.6).toFixed(1)+'" height="'+(ch-.6).toFixed(1)+'" fill="var(--heat-1)" fill-opacity="'+(0.06+a*.9).toFixed(2)+'"><title>'+WD[(r[0]+1)%7]+' '+r[1]+':00 · '+num(r[2],1)+'%</title></rect>');});
  WD.forEach(function(w,i){o.push('<text class="hax" x="0" y="'+(MT+((i+6)%7)*ch+ch*.75).toFixed(1)+'">'+w.slice(0,2)+'</text>');});
  [0,6,12,18].forEach(function(hr){o.push('<text class="hax" x="'+(ML+hr*cw).toFixed(1)+'" y="8">'+hr+'</text>');});
  o.push('</svg></div>');return o.join('');
}

/* ---- facts for the focus card ---- */
function facts(m){var f=m.f,out=[];
  if(m.fam.id==='tablespaces'){out.push({l:'Used',v:num(f.pct,1)+'<small>%</small>',s:m.unit.fmt(f.v)+' of '+m.unit.fmt(f.lim),t:f.pct>=K.nfCrit?'crit':f.pct>=K.nfWarn?'warn':''});
    out.push(f.q==='CYCLIC'?{l:'Peak growth',v:m.unit.rate(f.pkSlope),s:(f.cycN||0)+' purges, every '+Math.round(f.cycD||0)+' d'}:{l:'Growth',v:m.unit.rate(f.slope),s:f.accel>=1.5?'accelerating ×'+num(f.accel,1):'fit over '+(f.n||'–')+' d'});
    out.push(dtfF(m,'Full in'));if(f.need90>0)out.push({l:'Add for 90 d',v:num(f.need90,1)+'<small>GiB</small>'});}
  else if(m.fam.unit==='PCT'){out.push({l:'Busy-hour p95',v:num(f.v,1)+'<small>%</small>',t:f.v>=CPU_SAT?'crit':f.v>=CPU_SAT*.9?'warn':''});var a=FIT[key('CPU',f.dbid,f.con,m.fam.lines[1][0])];out.push({l:'Daily average',v:a?num(a.v,1)+'<small>%</small>':'–'});out.push({l:'Trend',v:m.unit.rate(f.slope),s:f.sig===0?'not significant':''});out.push(dtfF(m,CPU_SAT+'% in'));}
  else if(m.fam.nolimit){out.push({l:'Today',v:m.unit.fmt(lastVal(m.pts))});out.push({l:'Growth',v:m.unit.rate(f.slope)});}
  else{out.push({l:m.fam.id==='db-size'?'Used':'Peak',v:m.unit.fmt(f.v),s:f.lim!=null?'of '+m.unit.fmt(f.lim)+' '+m.fam.limWord:''});if(f.pct!=null)out.push({l:'Of '+m.fam.limWord,v:num(f.pct,1)+'<small>%</small>',t:f.pct>=100?'crit':f.pct>=SERIES_SAT?'warn':''});out.push({l:'Growth',v:m.unit.rate(f.slope)});if(f.lim!=null)out.push(dtfF(m,SERIES_SAT+'% in'));}
  return out;}
function dtfF(m,l){var f=m.f;if(f.dtf==null||f.dtf>3650)return{l:l,v:f.q==='FLAT'?'never':f.q==='CYCLIC'?'—':'> 10 y',s:f.q==='FLAT'?'no growth':f.q==='CYCLIC'?'peaks not growing':'',t:''};return{l:l,v:fDays(f.dtf),s:'→ '+fDay(LAST+f.dtf)+(f.dtfLo!=null&&f.dtfHi!=null?' · '+Math.round(f.dtfLo)+'–'+Math.round(f.dtfHi)+' d':''),t:dtfTone(f)};}

function verdict(m){var a=m.alerts[0];if(a&&m.sev!=='OK')return'<p class="verdict '+CLS[m.sev]+'">'+esc(m.name)+' '+alertFact(a)+' · '+alertWhen(a)+(a.msg&&/_ANOM$/.test(a.kind)?'<br><span style="color:var(--ink-3)">'+esc(a.msg)+'</span>':'')+'</p>';
  var f=m.f;if(f.q==='FLAT')return'<p class="verdict">Flat: no growth over the training window.</p>';if(f.q==='CYCLIC')return'<p class="verdict">Cyclic: fills and purges every '+Math.round(f.cycD||0)+' days; the peaks are not growing.</p>';
  if(f.dtf!=null&&f.dtf<=730)return'<p class="verdict">On its current trend it reaches the '+m.fam.target+' in <b>'+fDays(f.dtf)+'</b>, '+fDayY(Math.round(LAST+f.dtf))+'.</p>';return'<p class="verdict">Growing slowly; the '+esc(m.fam.target)+' is more than two years away.</p>';}

function card(m){var f=m.f,o=['<article class="card" id="'+m.id+'">'];
  o.push('<div class="ch"><h4>'+esc(m.name)+'</h4>'+(m.ctr?'<span class="ctr">'+esc(m.ctr)+'</span>':'')+(QT[f.q]?'<span class="tag">'+QT[f.q]+'</span>':'')+pill(m.sev)+'<button class="tbtn x" type="button" data-close="'+m.id+'">close</button></div>');
  o.push(verdict(m));
  o.push('<div class="facts">'+facts(m).map(function(x){return'<div class="fact '+(x.t||'')+'"><div class="l">'+x.l+'</div><div class="v">'+x.v+'</div>'+(x.s?'<div class="s">'+esc(x.s)+'</div>':'')+'</div>';}).join('')+'</div>');
  o.push('<div class="viz"><div>'+chart(m)+calendar(m)+'</div>'+(m.fam.heat?heat(m):'')+'</div>');
  o.push('<details class="moredet"><summary>Fit details</summary><dl><dt>Quality</dt><dd>'+esc(f.q)+'</dd><dt>Method</dt><dd>'+esc(f.method||'OLS')+'</dd><dt>Training days</dt><dd>'+esc(f.n||'–')+'</dd><dt>R²</dt><dd>'+(f.r2!=null?num(f.r2,2):'–')+'</dd>'+(f.limSrc?'<dt>Limit source</dt><dd>'+esc(f.limSrc)+'</dd>':'')+'<dt>Series</dt><dd>'+esc(f.k+' '+f.s)+'</dd></dl></details>');
  o.push('</article>');return o.join('');}

function mini(m){var f=m.f,pct=f.pct!=null?Math.max(0,Math.min(100,f.pct)):null;
  var tone=m.fam.id==='tablespaces'?(f.pct>=K.nfCrit?'crit':f.pct>=K.nfWarn?'warn':''):(f.pct>=100?'crit':f.pct>=(m.sat||90)?'warn':'');
  var p90=m.at90!=null&&m.lim?Math.max(0,Math.min(100,m.fam.unit==='PCT'?m.at90:m.at90/m.lim*100)):null;
  var head=f.dtf!=null&&f.q==='OK'&&f.dtf<=730?'<b>'+fDays(f.dtf)+'</b> to '+(m.fam.id==='tablespaces'?'full':m.fam.unit==='PCT'?CPU_SAT+'%':SERIES_SAT+'%'):f.q==='FLAT'?'flat':f.q==='CYCLIC'?'cyclic':m.fam.nolimit?m.unit.fmt(lastVal(m.pts))+' today':'> 2 y';
  var o=['<div class="mini '+CLS[m.sev]+'" data-open="'+m.id+'">'];
  o.push('<div class="mh"><span class="mn">'+esc(m.name)+(m.ctr?'<span>'+esc(m.ctr)+'</span>':'')+'</span><span class="mv">'+head+'</span></div>');
  o.push(spark(m,230,64,true));
  if(pct!=null){o.push('<div class="bullet">'+(p90!=null&&p90>pct?'<i class="fc" style="width:'+p90+'%"></i>':'')+'<i class="now '+tone+'" style="width:'+pct+'%"></i>'+(m.fam.id==='tablespaces'?'<em style="left:'+K.nfWarn+'%"></em>':m.sat?'<em style="left:'+m.sat+'%"></em>':'')+'<em class="lim"></em></div><div class="bl"><span>'+num(f.pct,0)+'% now'+(p90!=null&&p90>pct+0.5?' · '+num(p90,0)+'% in 90 d':'')+'</span><span>'+esc(m.unit.fmt(m.lim))+'</span></div>');}
  o.push('</div>');return o.join('');}

function famHead(s){var m=s.ms[0],a=m.alerts[0];if(a&&m.sev!=='OK'){var fact=/_ANOM$/.test(a.kind)?'unusual '+fDay(dayN(a.day)):alertFact(a).replace(/<\/?b>/g,'');return'<b>'+esc(m.name)+'</b> '+fact;}
  var f=m.f;if(s.fam.id==='tablespaces'){var full=s.ms.slice().sort(function(x,y){return(y.f.pct||0)-(x.f.pct||0);})[0];return'fullest <b>'+esc(full.name)+'</b> '+num(full.f.pct,1)+'%';}
  if(f.k==='CPU')return'<b>'+esc(m.name)+'</b> p95 '+num(f.v,1)+'%';if(s.fam.nolimit)return'<b>'+m.unit.fmt(lastVal(m.pts))+'</b> today';
  return'<b>'+esc(m.name)+'</b> '+m.unit.fmt(f.v)+(f.pct!=null?' · '+num(f.pct,1)+'%':'');}

/* ---- assemble ---- */
var o=[];var db=D.containers[0].db;
o.push('<div class="page"><header class="mast"><span><b>'+esc(db)+'</b>'+esc(M.host)+', '+D.containers.length+' containers, data '+fDayY(FIRST)+' – '+fDayY(LAST)+' ('+(LAST-FIRST+1)+' d)</span><span class="tools">Capacity report for '+fDayY(LAST)+'<button class="tbtn" id="themeBtn" type="button">Theme</button><button class="tbtn" type="button" onclick="window.print()">Print</button></span></header>');
o.push('<div class="cols"><nav class="side" id="side">');
o.push('<div class="sum"><span'+(nCrit?' class="crit"':'')+'><b>'+nCrit+'</b>critical</span><span'+(nWarn?' class="warn"':'')+'><b>'+nWarn+'</b>warning</span><span><b>'+nSeries+'</b>series</span></div>');
o.push('<a href="#overview" data-nav="overview">'+dot('OK')+'<span>Overview</span><span class="n"></span></a>');
function sideSer(m){var f=m.f,t=f.dtf!=null&&f.q==='OK'&&f.dtf<=365?fDays(f.dtf):f.q==='FLAT'?'flat':f.q==='CYCLIC'?'cyclic':m.sev!=='OK'&&m.alerts[0]&&/_ANOM$/.test(m.alerts[0].kind)?'unusual':'';
  return'<a class="ser '+CLS[m.sev]+'" href="#'+m.id+'" data-open="'+m.id+'" data-nav="'+m.id+'">'+dot(m.sev)+'<span class="nm">'+esc(m.name)+'</span><span class="n t">'+esc(t)+'</span></a>';}
var badS=SECS.filter(function(s){return s.sev!=='OK';}),fineS=SECS.filter(function(s){return s.sev==='OK';});
o.push('<div class="sg">Needs a look</div>');
badS.forEach(function(s){o.push('<a href="#f-'+s.fam.id+'" data-fam="'+s.fam.id+'" data-nav="f-'+s.fam.id+'" class="'+CLS[s.sev]+'">'+dot(s.sev)+'<span class="t">'+esc(s.fam.title)+'</span><span class="n">'+s.ms.length+'</span></a>');
  var hot=s.ms.filter(function(m){return m.sev!=='OK'||(m.f.dtf!=null&&m.f.q==='OK'&&m.f.dtf<=180);});hot.forEach(function(m){o.push(sideSer(m));});
  if(s.ms.length>hot.length)o.push('<div class="sl">'+(s.ms.length-hot.length)+' more, fine</div>');});
if(fineS.length){o.push('<div class="sg">Fine</div>');fineS.forEach(function(s){o.push('<a href="#f-'+s.fam.id+'" data-fam="'+s.fam.id+'" data-nav="f-'+s.fam.id+'">'+dot('OK')+'<span>'+esc(s.fam.title)+'</span><span class="n">'+s.ms.length+'</span></a>');});}
o.push('</nav><main>');
o.push('<section class="glance" id="overview">');
var top=LISTED[0],tm=top&&BYS[key(top.dbid,top.con,top.s)];
if(top){var fact=/_ANOM$/.test(top.kind)?'was unusual on '+fDay(dayN(top.day)):alertFact(top).replace(/<\/?b>/g,'')+(top.u==='DAYS'?', on '+fDay(Math.round(LAST+top.v)):'');o.push('<h1><span class="'+CLS[top.sev]+'">'+esc(tm?tm.name:top.s)+'</span> '+fact+'.</h1>');}else o.push('<h1>Nothing needs attention.</h1>');
var nextUp=[];SECS.forEach(function(s){s.ms.forEach(function(m){if(m.f.dtf!=null&&m.f.q==='OK'&&m.sev==='OK'&&m.f.dtf<=180)nextUp.push(m);});});nextUp.sort(function(a,b){return a.f.dtf-b.f.dtf;});
o.push('<p class="lede"><b>'+nCrit+' critical</b> and <b>'+nWarn+' warning'+(nWarn===1?'':'s')+'</b> across '+nSeries+' series in '+SECS.length+' metrics. '+(nextUp.length?'Next to watch: '+nextUp.slice(0,2).map(function(m){return'<b>'+esc(m.name)+'</b> ('+fDays(m.f.dtf)+')';}).join(', ')+'. ':'')+'Everything else has more than six months of runway or is not growing.</p>');
o.push('<h3>Runway <span>when each series reaches its ceiling</span></h3>'+runway());
var SHOW=6;o.push('<h3>Needs attention <span>'+LISTED.length+' open</span></h3><div class="attn">'+LISTED.slice(0,SHOW).map(function(a){var m=BYS[key(a.dbid,a.con,a.s)];return'<a class="arow '+CLS[a.sev]+'" href="#'+(m?m.id:'')+'" data-open="'+(m?m.id:'')+'">'+pill(a.sev)+'<span class="m">'+esc(m?m.fam.title:a.kind)+'</span><span class="s">'+esc(m?m.name:a.s)+'<span>'+esc(m?m.ctr:'')+'</span></span><span class="f">'+alertFact(a)+'</span><span class="d">'+alertWhen(a)+'</span></a>';}).join('')+(LISTED.length>SHOW?'<div class="more">+ '+(LISTED.length-SHOW)+' more, inside the sections below</div>':'')+'</div>');
o.push('</section>');

o.push('<div class="fams"><h2>Needs a look</h2>');
var bad=SECS.filter(function(s){return s.sev!=='OK';}),fine=SECS.filter(function(s){return s.sev==='OK';});
bad.forEach(function(s){o.push('<details class="fam '+CLS[s.sev]+'" id="f-'+s.fam.id+'" open><summary>'+dot(s.sev)+'<span class="ft">'+esc(s.fam.title)+'</span><span class="fc">'+s.ms.length+'</span><span class="fh">'+famHead(s)+'</span><span class="fs">'+s.ms.slice(0,4).map(function(m){return spark(m,48,20,false);}).join('')+(s.ms.length>4?'<span class="n">+'+(s.ms.length-4)+'</span>':'')+'</span><span class="chev">›</span></summary>');
  o.push('<div class="body"><div class="minis">'+s.ms.map(mini).join('')+'</div>'+s.ms.map(card).join('')+'</div></details>');});
o.push('</div><div class="fams"><h2>Fine</h2>');
fine.forEach(function(s){o.push('<details class="fam" id="f-'+s.fam.id+'"><summary>'+dot('OK')+'<span class="ft">'+esc(s.fam.title)+'</span><span class="fc">'+s.ms.length+'</span><span class="fh">'+famHead(s)+'</span><span class="fs">'+s.ms.slice(0,4).map(function(m){return spark(m,48,20,false);}).join('')+'</span><span class="chev">›</span></summary>');
  o.push('<div class="body"><div class="minis">'+s.ms.map(mini).join('')+'</div>'+s.ms.map(card).join('')+'</div></details>');});
o.push('</div>');
o.push('</main></div><footer class="foot"><span>'+esc(db)+'</span><span>schema '+esc(M.schema)+'</span><span>generated '+esc((M.generated||'').slice(0,16))+'</span><span>read-only</span><span>mockup</span></footer></div>');
document.getElementById('app').innerHTML=o.join('');

/* open the critical series by default */
function openCard(id){var c=document.getElementById(id);if(!c)return;var body=c.parentNode;Array.prototype.forEach.call(body.querySelectorAll('.card'),function(x){x.classList.remove('on');});Array.prototype.forEach.call(body.querySelectorAll('.mini'),function(x){x.classList.toggle('on',x.getAttribute('data-open')===id);});c.classList.add('on');var det=c.closest('details');if(det)det.open=true;}
if(tm)openCard(tm.id);
document.addEventListener('click',function(e){var t=e.target.closest('[data-open]');if(t){var id=t.getAttribute('data-open');if(id){openCard(id);if(t.tagName!=='A'){document.getElementById(id).scrollIntoView({behavior:'smooth',block:'nearest'});}}return;}
  var x=e.target.closest('[data-close]');if(x){var c=document.getElementById(x.getAttribute('data-close'));c.classList.remove('on');c.parentNode.querySelectorAll('.mini').forEach(function(m){m.classList.remove('on');});}
  var r=e.target.closest('[data-fam]');if(r){var d=document.getElementById('f-'+r.getAttribute('data-fam'));if(d)d.open=true;}});
(function(){var links={};document.querySelectorAll('#side a[data-nav]').forEach(function(a){links[a.getAttribute('data-nav')]=a;});
  var io=new IntersectionObserver(function(es){es.forEach(function(e){if(e.isIntersecting){Object.keys(links).forEach(function(k){links[k].classList.toggle('on',k===e.target.id);});}});},{rootMargin:'-10% 0px -70% 0px'});
  document.querySelectorAll('#overview, details.fam').forEach(function(el){io.observe(el);});})();
document.getElementById('themeBtn').onclick=function(){var r=document.documentElement;r.setAttribute('data-theme',r.getAttribute('data-theme')==='dark'?'light':'dark');};
})();
"""

page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Capacity · ECOMPRD · mockup</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link href="https://fonts.googleapis.com/css2?family=Source+Sans+3:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>{CSS}</style></head>
<body><div id="app"></div>
<script type="application/json" id="cap-data">{data}</script>
<script>{JS}</script>
</body></html>
"""
OUT.write_text(page)
print(OUT, len(page))
