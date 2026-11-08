import Foundation

/// Self-contained HTML: per-file read speed against file date, plus tables.
public enum FilesHTML {
    struct Row: Encodable {
        let p: String       // relative path
        let s: UInt64       // size
        let c: Double?      // created, ms since epoch
        let m: Double?      // modified, ms since epoch
        let v: Double       // MB/s
    }
    struct Payload: Encodable {
        let summary: FileSweepSummary
        let rows: [Row]
    }

    public static func render(summary: FileSweepSummary, files: [FileSpeed]) throws -> String {
        let rows = files.compactMap { f -> Row? in
            guard let v = f.mbps else { return nil }
            return Row(p: f.relativePath, s: f.size,
                       c: f.created.map { ($0.timeIntervalSince1970 * 1000).rounded() },
                       m: f.modified.map { ($0.timeIntervalSince1970 * 1000).rounded() },
                       v: (v * 100).rounded() / 100)
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var json = String(decoding: try enc.encode(Payload(summary: summary, rows: rows)), as: UTF8.self)
        json = json.replacingOccurrences(of: "<", with: "\\u003c")
        return template.replacingOccurrences(of: "__FLASHPROBE_DATA__", with: json)
    }

    static let template = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>File Read Speeds</title>
<style>
:root{--surface:#fcfcfb;--surface-2:#f0efec;--text:#0b0b0b;--text-2:#52514e;--muted:#8a8984;--rule:#e2e1dc;
  --dot:#2a78d6;--grid:#e9e8e3;color-scheme:light}
@media (prefers-color-scheme:dark){:root:where(:not([data-theme="light"])){--surface:#1a1a19;--surface-2:#262624;
  --text:#f0efec;--text-2:#c3c2b7;--muted:#8f8e86;--rule:#383835;--dot:#3987e5;--grid:#2c2c2a;color-scheme:dark}}
:root[data-theme="dark"]{--surface:#1a1a19;--surface-2:#262624;--text:#f0efec;--text-2:#c3c2b7;--muted:#8f8e86;
  --rule:#383835;--dot:#3987e5;--grid:#2c2c2a;color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:var(--surface);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
main{max-width:1100px;margin:0 auto;padding:24px 16px 56px}
h1{font-size:22px;margin:0 0 4px;font-weight:650} h2{font-size:16px;margin:0 0 6px;font-weight:600}
.meta,.sub{color:var(--text-2);font-size:13px} .sub{margin:0 0 10px;max-width:75ch}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:20px 0 8px}
.tile{background:var(--surface-2);border-radius:8px;padding:12px 14px}
.tile .v{font-size:22px;font-weight:600;font-variant-numeric:tabular-nums} .tile .l{color:var(--text-2);font-size:12px}
section{margin-top:32px}
.controls{display:flex;gap:8px;align-items:center;font-size:13px;color:var(--text-2);margin-bottom:8px;flex-wrap:wrap}
.seg button{font:inherit;font-size:13px;padding:4px 10px;border:1px solid var(--rule);background:var(--surface);color:var(--text-2);cursor:pointer}
.seg button:first-child{border-radius:6px 0 0 6px} .seg button:last-child{border-radius:0 6px 6px 0;border-left:0}
.seg button[aria-pressed="true"]{background:var(--surface-2);color:var(--text);font-weight:600}
svg{display:block;width:100%;height:auto;overflow:visible}
svg text{fill:var(--text-2);font-size:11px;font-variant-numeric:tabular-nums}
#tip{position:fixed;pointer-events:none;background:var(--surface);color:var(--text);border:1px solid var(--rule);border-radius:6px;
  padding:6px 9px;font-size:12px;line-height:1.5;box-shadow:0 2px 10px rgba(0,0,0,.18);display:none;max-width:420px;
  font-variant-numeric:tabular-nums;z-index:10;overflow-wrap:anywhere}
.table-scroll{overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:13px;font-variant-numeric:tabular-nums}
th,td{text-align:right;padding:5px 8px;border-bottom:1px solid var(--rule);white-space:nowrap}
th:first-child,td:first-child{text-align:left;white-space:normal;overflow-wrap:anywhere}
th{color:var(--text-2);font-weight:500}
.foot{margin-top:40px;color:var(--muted);font-size:12px}
</style>
</head>
<body>
<main>
  <h1>File read speeds</h1>
  <div class="meta" id="meta"></div>
  <div class="tiles" id="tiles"></div>
  <section>
    <h2>Speed against file date</h2>
    <p class="sub" id="scatter-sub"></p>
    <div class="controls">Date:
      <span class="seg"><button id="bc" aria-pressed="true">Created</button><button id="bm" aria-pressed="false">Modified</button></span>
    </div>
    <div id="chart"></div>
  </section>
  <section>
    <h2>By top-level folder</h2>
    <p class="sub">Folders holding the most slow data first.</p>
    <div class="table-scroll"><table id="folders"></table></div>
  </section>
  <section>
    <h2>Slowest files</h2>
    <div class="table-scroll"><table id="slowest"></table></div>
  </section>
  <div class="foot" id="foot"></div>
</main>
<div id="tip"></div>
<script id="data" type="application/json">__FLASHPROBE_DATA__</script>
<script>
(function(){
"use strict";
const D = JSON.parse(document.getElementById('data').textContent), S = D.summary;
const $ = id => document.getElementById(id);
const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt = v => v == null ? 'n/a' : (v >= 100 ? v.toFixed(0) : v.toFixed(1));
const gb = b => (b / 1e9).toFixed(b >= 1e10 ? 0 : 2) + ' GB';
const day = ms => ms == null ? '?' : new Date(ms).toLocaleDateString(undefined, {year:'numeric', month:'short', day:'numeric'});
const dur = s => { s = Math.round(s); return s >= 3600 ? Math.floor(s/3600)+'h'+String(Math.floor(s%3600/60)).padStart(2,'0')+'m'
                 : s >= 60 ? Math.floor(s/60)+'m'+String(s%60).padStart(2,'0')+'s' : s+'s'; };

$('meta').textContent = S.device.manufacturer + ' ' + S.device.product + ' · serial ' + S.device.serial + ' · ' + S.volume +
  ' · ' + new Date(S.createdAt).toLocaleString();
const tiles = [
  [String(S.filesTimed), 'Files timed (of ' + S.filesFound + ')'],
  [fmt(S.referenceMBps) + ' MB/s', 'Typical speed (median file)'],
  [String(S.slowFiles), 'Slow files (< ' + fmt(S.thresholdMBps) + ' MB/s)'],
  [gb(S.slowBytes), 'Size of slow files'],
  [S.slowFiles ? day(Date.parse(S.slowCreatedFirst)) + ' – ' + day(Date.parse(S.slowCreatedLast)) : '—', 'Slow files created'],
  [dur(S.elapsedSeconds), 'Sweep time'],
];
$('tiles').innerHTML = tiles.map(t => '<div class="tile"><div class="v">' + esc(t[0]) + '</div><div class="l">' + esc(t[1]) + '</div></div>').join('');
$('scatter-sub').textContent = 'One dot per file (' + D.rows.length + ' files). Vertical axis is log-scaled. The dashed line is the slow threshold. ' +
  'Copy tools often keep original dates, so a file’s date may predate when it was written to this drive.';

let field = 'c';
const tip = $('tip');
function showTip(html, ev){
  tip.innerHTML = html; tip.style.display = 'block';
  const pad = 14, tw = tip.offsetWidth, th = tip.offsetHeight;
  let x = ev.clientX + pad, y = ev.clientY + pad;
  if (x + tw > innerWidth - 8) x = ev.clientX - tw - pad;
  if (y + th > innerHeight - 8) y = ev.clientY - th - pad;
  tip.style.left = Math.max(8, x) + 'px'; tip.style.top = Math.max(8, y) + 'px';
}
const hideTip = () => tip.style.display = 'none';

function draw(){
  const pts = D.rows.filter(r => r[field] != null);
  const W = Math.max(320, $('chart').clientWidth), H = Math.round(Math.min(440, Math.max(260, W * 0.45)));
  const m = {l: 56, r: 12, t: 10, b: 30};
  if (!pts.length) { $('chart').innerHTML = '<p class="sub">No dated files.</p>'; return; }
  let x0 = Math.min(...pts.map(r => r[field])), x1 = Math.max(...pts.map(r => r[field]));
  if (x1 - x0 < 864e5) { x0 -= 432e5; x1 += 432e5; }
  const vs = pts.map(r => r.v);
  const lo = Math.log10(Math.max(0.5, Math.min(...vs) / 1.3)), hi = Math.log10(Math.max(...vs) * 1.3);
  const X = t => m.l + (t - x0) / (x1 - x0) * (W - m.l - m.r);
  const Y = v => m.t + (hi - Math.log10(v)) / (hi - lo) * (H - m.t - m.b);
  let g = '';
  [1,2,5,10,20,50,100,200,500,1000,2000].forEach(v => {
    if (Math.log10(v) < lo || Math.log10(v) > hi) return;
    g += '<line x1="' + m.l + '" x2="' + (W - m.r) + '" y1="' + Y(v) + '" y2="' + Y(v) + '" stroke="var(--grid)"/>' +
         '<text x="' + (m.l - 8) + '" y="' + (Y(v) + 4) + '" text-anchor="end">' + v + '</text>';
  });
  g += '<text x="' + (m.l - 8) + '" y="' + (m.t - 0) + '" text-anchor="end" dy="-2">MB/s</text>';
  const span = x1 - x0, years = span / 3.156e10;
  const d0 = new Date(x0), ticks = [];
  if (years > 2) { for (let y = d0.getFullYear() + 1; y <= new Date(x1).getFullYear(); y++) ticks.push(new Date(y, 0, 1)); }
  else { const step = years > 0.75 ? 3 : 1; let d = new Date(d0.getFullYear(), d0.getMonth() + 1, 1);
         while (d.getTime() <= x1) { if (d.getMonth() % step === 0) ticks.push(new Date(d)); d = new Date(d.getFullYear(), d.getMonth() + 1, 1); } }
  ticks.forEach(d => {
    const x = X(d.getTime());
    g += '<line x1="' + x + '" x2="' + x + '" y1="' + m.t + '" y2="' + (H - m.b) + '" stroke="var(--grid)"/>' +
         '<text x="' + x + '" y="' + (H - m.b + 16) + '" text-anchor="middle">' +
         (years > 2 ? d.getFullYear() : d.toLocaleDateString(undefined, {month:'short', year:'2-digit'})) + '</text>';
  });
  if (S.thresholdMBps && Math.log10(S.thresholdMBps) > lo && Math.log10(S.thresholdMBps) < hi) {
    const y = Y(S.thresholdMBps);
    g += '<line x1="' + m.l + '" x2="' + (W - m.r) + '" y1="' + y + '" y2="' + y + '" stroke="var(--text-2)" stroke-dasharray="4 4"/>' +
         '<text x="' + (W - m.r) + '" y="' + (y - 5) + '" text-anchor="end">slow below ' + fmt(S.thresholdMBps) + ' MB/s</text>';
  }
  let dots = '';
  pts.forEach((r, i) => {
    dots += '<circle data-i="' + D.rows.indexOf(r) + '" cx="' + X(r[field]).toFixed(1) + '" cy="' + Y(r.v).toFixed(1) +
            '" r="4" fill="var(--dot)" fill-opacity="0.7" stroke="var(--surface)" stroke-width="1.5"/>';
  });
  $('chart').innerHTML = '<svg viewBox="0 0 ' + W + ' ' + H + '" width="' + W + '" height="' + H + '" role="img" aria-label="Scatter of file read speed by date">' + g + dots + '</svg>';
  $('chart').querySelectorAll('circle').forEach(c => {
    c.addEventListener('pointerenter', ev => {
      const r = D.rows[+c.dataset.i]; c.setAttribute('r', 6);
      showTip('<b>' + esc(r.p) + '</b><br>' + fmt(r.v) + ' MB/s · ' + gb(r.s) + '<br>created ' + day(r.c) + ' · modified ' + day(r.m), ev);
    });
    c.addEventListener('pointermove', ev => showTip(tip.innerHTML, ev));
    c.addEventListener('pointerleave', () => { c.setAttribute('r', 4); hideTip(); });
  });
}
function setField(f){ field = f; $('bc').setAttribute('aria-pressed', f === 'c'); $('bm').setAttribute('aria-pressed', f === 'm'); draw(); }
$('bc').onclick = () => setField('c'); $('bm').onclick = () => setField('m');

$('folders').innerHTML = '<tr><th>Folder</th><th>Files</th><th>Size</th><th>Median</th><th>Slow files</th><th>Slow size</th></tr>' +
  S.byFolder.map(g => '<tr><td>' + esc(g.key) + '</td><td>' + g.files + '</td><td>' + gb(g.bytes) + '</td><td>' + fmt(g.medianMBps) +
    ' MB/s</td><td>' + g.slowFiles + '</td><td>' + gb(g.slowBytes) + '</td></tr>').join('');
$('slowest').innerHTML = '<tr><th>File</th><th>Speed</th><th>Size</th><th>Created</th><th>Modified</th></tr>' +
  S.slowest.map(f => '<tr><td>' + esc(f.relativePath) + '</td><td>' + fmt(f.mbps) + ' MB/s</td><td>' + gb(f.size) + '</td><td>' +
    day(f.created ? Date.parse(f.created) : null) + '</td><td>' + day(f.modified ? Date.parse(f.modified) : null) + '</td></tr>').join('');
$('foot').textContent = 'flashprobe ' + S.version + ' · uncached reads' + (S.perFileBudget ? ', up to ' + (S.perFileBudget / 1048576) + ' MiB sampled per file' : ', every byte') + ' · full list in files.csv';

draw();
let rz; addEventListener('resize', () => { clearTimeout(rz); rz = setTimeout(draw, 80); });
})();
</script>
</body>
</html>
"""#
}
