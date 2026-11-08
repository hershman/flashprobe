import Foundation

/// Self-contained HTML heatmap (no network, no external scripts).
public enum HTMLReport {
    struct Payload: Encodable {
        let report: ScanReport
        let firstIndex: Int
        let cols: Int
        /// MB/s per chunk position from firstIndex; null = not read (sampled out
        /// or stopped early); -1 = read error.
        let speeds: [Double?]
        /// chunk index (string) -> re-read speeds
        let rereads: [String: [Double]]
    }

    /// Chunks per heatmap row: 1 GiB per row when it gives a sane width.
    public static func columns(chunkSize: UInt64) -> Int {
        let perGiB = Int((1 << 30) / chunkSize)
        return min(512, max(64, perGiB))
    }

    public static func render(report: ScanReport, results: [ChunkResult]) throws -> String {
        let first = report.plan.firstIndex
        let count = report.plan.lastIndex - first + 1
        var speeds = [Double?](repeating: nil, count: count)
        var rereads: [String: [Double]] = [:]
        for r in results {
            let pos = r.index - first
            guard pos >= 0, pos < count else { continue }
            if r.errorCode != nil {
                speeds[pos] = -1
            } else if let v = r.mbps {
                speeds[pos] = (v * 100).rounded() / 100
            }
            if !r.rereadSeconds.isEmpty {
                rereads[String(r.index)] = r.rereadMBps.map { ($0 * 100).rounded() / 100 }
            }
        }
        let payload = Payload(report: report, firstIndex: first,
                              cols: columns(chunkSize: report.plan.chunkSize),
                              speeds: speeds, rereads: rereads)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        // JSONEncoder escapes "/" as "\/" by default, so device strings can't close the <script>.
        var json = String(decoding: try enc.encode(payload), as: UTF8.self)
        json = json.replacingOccurrences(of: "<", with: "\\u003c")
        return template.replacingOccurrences(of: "__FLASHPROBE_DATA__", with: json)
    }

    static let template = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Flash Speed Map</title>
<style>
:root{
  --surface:#fcfcfb;--surface-2:#f0efec;--text:#0b0b0b;--text-2:#52514e;--muted:#8a8984;
  --rule:#e2e1dc;--critical:#d03b3b;--bar:#2a78d6;color-scheme:light;
}
@media (prefers-color-scheme:dark){
  :root:where(:not([data-theme="light"])){
    --surface:#1a1a19;--surface-2:#262624;--text:#f0efec;--text-2:#c3c2b7;--muted:#8f8e86;
    --rule:#383835;--critical:#d03b3b;--bar:#3987e5;color-scheme:dark;
  }
}
:root[data-theme="dark"]{
  --surface:#1a1a19;--surface-2:#262624;--text:#f0efec;--text-2:#c3c2b7;--muted:#8f8e86;
  --rule:#383835;--critical:#d03b3b;--bar:#3987e5;color-scheme:dark;
}
*{box-sizing:border-box}
body{margin:0;background:var(--surface);color:var(--text);
  font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
main{max-width:1100px;margin:0 auto;padding:24px 16px 56px}
h1{font-size:22px;margin:0 0 4px;font-weight:650}
h2{font-size:16px;margin:0 0 6px;font-weight:600}
.meta{color:var(--text-2);font-size:13px}
.warn{margin-top:10px;padding:8px 12px;border-radius:6px;background:var(--surface-2);border-left:3px solid var(--critical)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:20px 0 8px}
.tile{background:var(--surface-2);border-radius:8px;padding:12px 14px}
.tile .v{font-size:22px;font-weight:600;font-variant-numeric:tabular-nums}
.tile .l{color:var(--text-2);font-size:12px}
section{margin-top:32px}
.sub{color:var(--text-2);font-size:13px;margin:0 0 10px;max-width:75ch}
.legend{display:flex;align-items:center;gap:10px 16px;font-size:12px;color:var(--text-2);flex-wrap:wrap;margin:6px 0 10px}
.ramp-wrap{display:flex;align-items:center;gap:6px}
.ramp{height:10px;width:200px;border-radius:2px}
.sw{display:inline-block;width:10px;height:10px;border-radius:2px;vertical-align:-1px;margin-right:5px}
canvas{display:block;width:100%;touch-action:none}
#tip{position:fixed;pointer-events:none;background:var(--surface);color:var(--text);border:1px solid var(--rule);
  border-radius:6px;padding:6px 9px;font-size:12px;line-height:1.5;box-shadow:0 2px 10px rgba(0,0,0,.18);
  display:none;white-space:nowrap;font-variant-numeric:tabular-nums;z-index:10}
#tip b{font-weight:600}
.hist{max-width:760px;display:grid;grid-template-columns:max-content 1fr max-content;gap:6px 10px;align-items:center;font-size:13px;font-variant-numeric:tabular-nums}
.hist .lab{color:var(--text-2);text-align:right}
.hist .track{height:14px;position:relative}
.hist .fill{position:absolute;left:0;top:0;bottom:0;background:var(--bar);border-radius:0 4px 4px 0;min-width:2px}
.hist .row-hit{display:contents}
.table-scroll{overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:13px;font-variant-numeric:tabular-nums}
th,td{text-align:right;padding:5px 8px;border-bottom:1px solid var(--rule);white-space:nowrap}
th:first-child,td:first-child{text-align:left}
th{color:var(--text-2);font-weight:500}
.foot{margin-top:40px;color:var(--muted);font-size:12px}
</style>
</head>
<body>
<main>
  <h1>Read-speed map</h1>
  <div class="meta" id="meta"></div>
  <div id="warn"></div>
  <div class="tiles" id="tiles"></div>

  <section>
    <h2>Speed across the drive</h2>
    <p class="sub" id="heat-sub"></p>
    <div class="legend" id="legend"></div>
    <div id="heat-wrap"><canvas id="heat" role="img" aria-label="Heatmap of read speed by drive offset"></canvas></div>
  </section>

  <section>
    <h2>How speeds are distributed</h2>
    <p class="sub">Number of chunks in each speed band. A healthy, freshly written drive puts nearly everything in one or two bands near its rated speed.</p>
    <div class="hist" id="hist"></div>
  </section>

  <section>
    <h2>Slowest regions</h2>
    <p class="sub" id="reg-sub"></p>
    <div class="table-scroll"><table id="regions"></table></div>
  </section>

  <div class="foot" id="foot"></div>
</main>
<div id="tip"></div>

<script id="data" type="application/json">__FLASHPROBE_DATA__</script>
<script>
(function(){
"use strict";
const D = JSON.parse(document.getElementById('data').textContent);
const R = D.report, S = R.stats, P = R.plan;
const GiB = 1073741824;
const RAMP = ['#cde2fb','#b7d3f6','#9ec5f4','#86b6ef','#6da7ec','#5598e7','#3987e5',
              '#2a78d6','#256abf','#1c5cab','#184f95','#104281','#0d366b'];
const RGB = RAMP.map(h => [1,3,5].map(i => parseInt(h.slice(i, i+2), 16)));
const $ = id => document.getElementById(id);
const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt = v => v == null ? 'n/a' : (v >= 100 ? v.toFixed(0) : v.toFixed(1));
const gib = b => (b / GiB).toFixed(2) + ' GiB';
const dur = s => { s = Math.round(s); if (s >= 3600) return Math.floor(s/3600)+'h'+String(Math.floor(s%3600/60)).padStart(2,'0')+'m';
                   if (s >= 60) return Math.floor(s/60)+'m'+String(s%60).padStart(2,'0')+'s'; return s+'s'; };
const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
function isDark(){
  const t = document.documentElement.dataset.theme;
  if (t) return t === 'dark';
  return matchMedia('(prefers-color-scheme: dark)').matches;
}

// Color = slowness. Log scale between the fastest and slowest chunk read.
// Light mode: slow = dark blue. Dark mode: slow = light blue (most contrast vs surface).
const vMax = Math.max(S.max || 1, 1), vMin = Math.max(Math.min(S.min || 1, vMax), 0.5);
const lo = Math.log10(vMin), hi = Math.log10(vMax);
function slowness(v){ if (hi <= lo) return 0; return Math.min(1, Math.max(0, (hi - Math.log10(v)) / (hi - lo))); }
function rampAt(t){
  if (isDark()) t = 1 - t;
  const x = t * (RGB.length - 1), i = Math.min(RGB.length - 2, Math.floor(x)), f = x - i;
  const a = RGB[i], b = RGB[i+1];
  return 'rgb(' + a.map((c, k) => Math.round(c + (b[k] - c) * f)).join(',') + ')';
}

// ---------- header ----------
const dev = R.device;
$('meta').textContent = [dev.manufacturer, dev.product].filter(Boolean).join(' ') +
  ' · serial ' + dev.serial + ' · ' + dev.vendorID + ':' + dev.productID + ' rev ' + dev.bcdDevice +
  ' · ' + (dev.size / 1e9).toFixed(1) + ' GB · /dev/r' + dev.bsdName + ' · ' + new Date(R.createdAt).toLocaleString();
const warns = [];
if (R.stoppedReason) warns.push('Scan stopped early (' + esc(R.stoppedReason) + '). Unread areas are shown as “not read”.');
if (S.errors > 0) warns.push(S.errors + ' chunk(s) returned read errors. They are marked in red.');
$('warn').innerHTML = warns.map(w => '<div class="warn">' + w + '</div>').join('');

const tiles = [
  [fmt(S.median) + ' MB/s', 'Median chunk speed'],
  [fmt(S.p5) + ' MB/s', 'Slowest 5% are below'],
  [fmt(S.p95) + ' MB/s', 'Fastest 5% are above'],
  [S.spreadP95overP5 ? S.spreadP95overP5.toFixed(1) + '×' : 'n/a', 'Spread (p95 ÷ p5)'],
  [fmt(S.effective) + ' MB/s', 'Effective (bytes ÷ time)'],
  [String(S.errors), 'Read errors'],
  [dur(R.elapsedSeconds), 'Scan time'],
];
if (R.reread) tiles.push([fmt(R.reread.rereadMedianMBps) + ' MB/s',
  'Re-read median of ' + R.reread.chunks + ' slow chunks; ' +
  Math.round((R.reread.fractionRereadsAboveThreshold || 0) * 100) + '% no longer slow']);
$('tiles').innerHTML = tiles.map(t => '<div class="tile"><div class="v">' + esc(t[0]) + '</div><div class="l">' + esc(t[1]) + '</div></div>').join('');

const chunkMiB = P.chunkSize / 1048576;
$('heat-sub').textContent = 'Each cell is one ' + chunkMiB + ' MiB read; each row is ' +
  (D.cols * P.chunkSize / GiB).toFixed(2).replace(/\.00$/, '') + ' GiB of the drive, top to bottom from offset 0. ' +
  'Darker means slower in light mode, lighter means slower in dark mode.' +
  (P.sampleEvery > 1 ? ' Sampled: only every ' + P.sampleEvery + 'th chunk was read.' : '') + ' Hover a cell for details.';

function drawLegend(){
  const stops = []; for (let i = 0; i <= 10; i++) stops.push(rampAt(i / 10));
  $('legend').innerHTML =
    '<span class="ramp-wrap">faster <b style="color:var(--text)">' + fmt(vMax) + '</b>' +
    '<span class="ramp" style="background:linear-gradient(90deg,' + stops.join(',') + ')"></span>' +
    '<b style="color:var(--text)">' + fmt(vMin) + '</b> MB/s slower</span>' +
    '<span><span class="sw" style="background:var(--critical)"></span>read error</span>' +
    '<span><span class="sw" style="background:var(--surface-2);outline:1px solid var(--rule)"></span>not read</span>';
}

// ---------- heatmap ----------
const canvas = $('heat'), ctx = canvas.getContext('2d');
const N = D.speeds.length, cols = D.cols;
const row0 = Math.floor(D.firstIndex / cols);
const rows = Math.ceil((D.firstIndex + N) / cols) - row0;
const AXIS = 64;
let geo = null, hover = -1;

function layout(){
  const W = $('heat-wrap').clientWidth;
  const cell = (W - AXIS) / cols;
  const cellH = Math.max(2, Math.min(14, cell));
  const H = Math.ceil(rows * cellH) + 2;
  const dpr = window.devicePixelRatio || 1;
  canvas.style.height = H + 'px';
  canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  geo = {W, H, cell, cellH};
}

function cellRect(pos){
  const abs = D.firstIndex + pos, r = Math.floor(abs / cols) - row0, c = abs % cols;
  return [AXIS + c * geo.cell, 1 + r * geo.cellH, geo.cell, geo.cellH];
}

function draw(){
  layout();
  const {W, H, cellH} = geo;
  ctx.clearRect(0, 0, W, H);
  const notRead = css('--surface-2'), err = css('--critical');
  ctx.fillStyle = notRead;
  ctx.fillRect(AXIS, 1, W - AXIS, rows * cellH);
  for (let i = 0; i < N; i++) {
    const v = D.speeds[i];
    if (v == null) continue;
    ctx.fillStyle = v < 0 ? err : rampAt(slowness(v));
    const [x, y, w, h] = cellRect(i);
    ctx.fillRect(x, y, Math.ceil(w), Math.ceil(h));
  }
  // y-axis labels: GiB offset at row start, spaced ≥ 16px apart
  ctx.fillStyle = css('--text-2');
  ctx.font = '11px -apple-system,BlinkMacSystemFont,system-ui,sans-serif';
  ctx.textAlign = 'right'; ctx.textBaseline = 'top';
  const step = Math.max(1, Math.ceil(16 / cellH));
  const nice = [1,2,4,5,8,10,16,20,32,50,64,100,128,256].find(n => n >= step) || step;
  for (let r = 0; r < rows; r++) {
    const abs = (row0 + r);
    if (abs % nice !== 0) continue;
    const off = abs * cols * P.chunkSize;
    ctx.fillText(Math.round(off / GiB) + ' GiB', AXIS - 8, 1 + r * cellH);
  }
  if (hover >= 0) {
    const [x, y, w, h] = cellRect(hover);
    ctx.strokeStyle = css('--text'); ctx.lineWidth = 2;
    ctx.strokeRect(x - 1, y - 1, Math.max(w, 2) + 2, Math.max(h, 2) + 2);
  }
}

const tip = $('tip');
function showTip(html, ev){
  tip.innerHTML = html; tip.style.display = 'block';
  const pad = 14, tw = tip.offsetWidth, th = tip.offsetHeight;
  let x = ev.clientX + pad, y = ev.clientY + pad;
  if (x + tw > innerWidth - 8) x = ev.clientX - tw - pad;
  if (y + th > innerHeight - 8) y = ev.clientY - th - pad;
  tip.style.left = Math.max(8, x) + 'px'; tip.style.top = Math.max(8, y) + 'px';
}
function hideTip(){ tip.style.display = 'none'; }

function posAt(ev){
  const b = canvas.getBoundingClientRect();
  const x = ev.clientX - b.left, y = ev.clientY - b.top - 1;
  if (x < AXIS || y < 0) return -1;
  const c = Math.floor((x - AXIS) / geo.cell), r = Math.floor(y / geo.cellH);
  if (c < 0 || c >= cols || r >= rows) return -1;
  const pos = (row0 + r) * cols + c - D.firstIndex;
  return pos >= 0 && pos < N ? pos : -1;
}
function onMove(ev){
  const pos = posAt(ev);
  if (pos !== hover) { hover = pos; draw(); }
  if (pos < 0) { hideTip(); return; }
  const idx = D.firstIndex + pos, off = idx * P.chunkSize, v = D.speeds[pos];
  let h = '<b>' + gib(off) + '</b> · chunk #' + idx + '<br>';
  if (v == null) h += 'not read';
  else if (v < 0) h += '<span style="color:var(--critical)">●</span> read error';
  else h += '<b>' + fmt(v) + ' MB/s</b> · ' + (P.chunkSize / 1e6 / v).toFixed(3) + ' s';
  const rr = D.rereads[String(idx)];
  if (rr) h += '<br>re-reads: ' + rr.map(fmt).join(', ') + ' MB/s';
  showTip(h, ev);
}
canvas.addEventListener('pointermove', onMove);
canvas.addEventListener('pointerdown', onMove);
canvas.addEventListener('pointerleave', () => { hover = -1; hideTip(); draw(); });

// ---------- histogram ----------
function drawHist(){
  const total = R.histogram.reduce((a, b) => a + b.count, 0) || 1;
  const maxC = Math.max(1, ...R.histogram.map(b => b.count));
  $('hist').innerHTML = R.histogram.map((b, i) =>
    '<div class="lab">' + esc(b.label) + ' MB/s</div>' +
    '<div class="track" data-i="' + i + '">' + (b.count ? '<div class="fill" style="width:' + Math.max(0.4, b.count / maxC * 100) + '%"></div>' : '') + '</div>' +
    '<div>' + b.count.toLocaleString() + ' <span style="color:var(--text-2)">(' + (b.count / total * 100).toFixed(1) + '%)</span></div>'
  ).join('');
  $('hist').querySelectorAll('.track').forEach(el => {
    el.addEventListener('pointermove', ev => {
      const b = R.histogram[+el.dataset.i];
      showTip('<b>' + esc(b.label) + ' MB/s</b><br>' + b.count.toLocaleString() + ' chunks · ' +
              (b.count * P.chunkSize / 1e9).toFixed(1) + ' GB', ev);
    });
    el.addEventListener('pointerleave', hideTip);
  });
}

// ---------- regions ----------
function drawRegions(){
  const t = R.slowThresholdMBps;
  $('reg-sub').textContent = t == null ? 'No successful reads, so no threshold.' :
    R.slowRegionCount + ' region(s) where chunks read below ' + fmt(t) + ' MB/s (' + Math.round(R.slowFraction * 100) +
    '% of the drive’s p90 speed, ' + fmt(R.referenceMBps) + ' MB/s). Sorted by time spent reading them' + (R.slowRegionCount > R.slowRegions.length ? '; top ' + R.slowRegions.length + ' shown' : '') + '.';
  const head = '<tr><th>Start</th><th>End</th><th>Size</th><th>Slow / chunks</th><th>Mean</th><th>Min</th><th>Time</th><th>Errors</th>' +
               (R.reread ? '<th>Re-read mean</th>' : '') + '</tr>';
  const body = R.slowRegions.map(g => '<tr><td>' + gib(g.startOffset) + '</td><td>' + gib(g.endOffset) + '</td><td>' +
      ((g.endOffset - g.startOffset) / 1e9).toFixed(2) + ' GB</td><td>' + g.slowChunks + ' / ' + g.chunks + '</td><td>' +
      fmt(g.meanMBps) + ' MB/s</td><td>' + fmt(g.minMBps) + ' MB/s</td><td>' + dur(g.totalSeconds) + '</td><td>' + g.errors + '</td>' +
      (R.reread ? '<td>' + fmt(g.rereadMeanMBps) + (g.rereadMeanMBps != null ? ' MB/s' : '') + '</td>' : '') + '</tr>').join('');
  $('regions').innerHTML = head + (body || '<tr><td colspan="9">None.</td></tr>');
}

$('foot').textContent = 'flashprobe ' + R.version + ' · speeds in MB/s (10⁶ bytes/s) · raw per-chunk data in scan.csv';

function all(){ drawLegend(); draw(); }
drawHist(); drawRegions(); all();
let rz; addEventListener('resize', () => { clearTimeout(rz); rz = setTimeout(draw, 80); });
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', all);
new MutationObserver(all).observe(document.documentElement, {attributes: true, attributeFilter: ['data-theme']});
})();
</script>
</body>
</html>
"""#
}
