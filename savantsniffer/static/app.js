let evtSource = null;
let currentEvent = null;

async function showScanCmd() {
  const subnet = document.getElementById('subnet').value.trim();
  const r = await fetch('/api/scan-command' + (subnet ? `?subnet=${encodeURIComponent(subnet)}` : ''));
  const d = await r.json();
  document.getElementById('scanCmd').textContent =
    `${d.command}\n\n# ${d.note}\n# subnet: ${d.subnet} — local only`;
  document.getElementById('runScanBtn').style.display = 'inline-block';
}

async function runScan() {
  const subnet = document.getElementById('subnet').value.trim();
  document.getElementById('scanResults').innerHTML = '<p class="muted">scanning…</p>';
  const r = await fetch('/api/scan', {method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify({confirm:true, subnet: subnet || null})});
  const d = await r.json();
  if (d.error) { document.getElementById('scanResults').innerHTML = `<p class="no">${d.error}</p>`; return; }
  let html = '';
  for (const label of ['Lutron','Apple','unknown']) {
    const rows = d.buckets[label] || [];
    if (!rows.length) continue;
    html += `<h3>${label}</h3>`;
    for (const h of rows) {
      html += `<div class="host-row"><span class="ip">${h.ip}</span>
        <span class="muted">${h.mac||''} ${h.vendor||''}</span>
        <span class="tag ${label}">${label}</span></div>`;
    }
  }
  if (d.note) html += `<p class="muted">${d.note}</p>`;
  document.getElementById('scanResults').innerHTML = html || '<p class="muted">no hosts parsed</p>';
}

async function portcheck() {
  const host = document.getElementById('phost').value.trim();
  if (!host) return;
  document.getElementById('portResults').innerHTML = '<p class="muted">checking…</p>';
  const r = await fetch(`/api/portcheck?host=${encodeURIComponent(host)}`);
  const d = await r.json();
  if (d.error) { document.getElementById('portResults').innerHTML = `<p class="no">${d.error}</p>`; return; }
  let html = '<table><thead><tr><th>port</th><th>state</th><th>detail</th></tr></thead><tbody>';
  for (const p of d.results) {
    html += `<tr><td>${p.port}</td><td class="${p.open?'ok':'muted'}">${p.open?'OPEN':'closed'}</td><td>${p.detail||''}</td></tr>`;
  }
  html += `</tbody></table><p><strong>Likely system: ${d.system}</strong><br><span class="muted">${d.why}</span></p>`;
  document.getElementById('portResults').innerHTML = html;
}

async function startMonitor() {
  const host = document.getElementById('mhost').value.trim();
  const r = await fetch('/api/monitor/start', {method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify({host: host || null})});
  const d = await r.json();
  document.getElementById('monStatus').textContent = d.ok ? `running → ${d.info}` : `error: ${d.info}`;
  if (!evtSource) openStream();
}

async function stopMonitor() {
  await fetch('/api/monitor/stop', {method:'POST'});
  document.getElementById('monStatus').textContent = 'stopping…';
}

function openStream() {
  evtSource = new EventSource('/api/monitor/stream');
  const tbody = document.querySelector('#events tbody');
  evtSource.onmessage = (m) => {
    const ev = JSON.parse(m.data);
    if (ev.kind === 'STATUS' || ev.kind === 'ERROR') {
      document.getElementById('monStatus').textContent = ev.raw;
    }
    const tr = document.createElement('tr');
    tr.className = ev.kind;
    const detail = ev.kind==='OUTPUT' ? `level ${ev.level??''}` :
                   ev.kind==='DEVICE' ? `btn ${ev.component??''} act ${ev.action??''}` : '';
    tr.innerHTML = `<td>${(ev.ts||'').split('T')[1]||''}</td><td>${ev.kind}</td>
      <td>${ev.id||''}</td><td>${detail}</td><td>${ev.raw}</td>
      <td>${(ev.kind==='DEVICE'||ev.kind==='OUTPUT')?'<button>label</button>':''}</td>`;
    const btn = tr.querySelector('button');
    if (btn) btn.onclick = () => openLabel(ev);
    tbody.prepend(tr);
    while (tbody.children.length > 300) tbody.removeChild(tbody.lastChild);
  };
}

function openLabel(ev) {
  currentEvent = ev;
  document.getElementById('labelRaw').textContent = ev.raw;
  document.getElementById('labelModal').style.display = 'flex';
}
function closeModal() { document.getElementById('labelModal').style.display = 'none'; }

async function saveLabel() {
  const body = {
    kind: currentEvent.kind, id: currentEvent.id,
    component: currentEvent.component,
    area: document.getElementById('labelArea').value,
    name: document.getElementById('labelName').value,
    label: document.getElementById('labelBtnLabel').value,
  };
  const r = await fetch('/api/map/label', {method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify(body)});
  const d = await r.json();
  if (d.error) { alert(d.error); return; }
  closeModal(); loadMap();
}

async function loadMap() {
  const r = await fetch('/api/map');
  const d = await r.json();
  document.getElementById('mapView').textContent = JSON.stringify(d, null, 2);
}

async function doSet() {
  if (!document.getElementById('setConfirm').checked) { alert('Tick the confirm box first.'); return; }
  const r = await fetch('/api/control', {method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify({action:'set', confirm:true,
      name: document.getElementById('setName').value,
      level: document.getElementById('setLevel').value})});
  const d = await r.json();
  document.getElementById('controlResult').textContent = d.error ? `error: ${d.error}` : `sent: ${d.sent}`;
  document.getElementById('setConfirm').checked = false;
}

async function doPress() {
  if (!document.getElementById('pressConfirm').checked) { alert('Tick the confirm box first.'); return; }
  const r = await fetch('/api/control', {method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify({action:'press', confirm:true,
      name: document.getElementById('pressName').value,
      button: document.getElementById('pressBtn').value})});
  const d = await r.json();
  document.getElementById('controlResult').textContent = d.error ? `error: ${d.error}` : `sent: ${d.sent}`;
  document.getElementById('pressConfirm').checked = false;
}

loadMap();

// --- macro capture ---
let macroTimer = null;
async function macroBegin() {
  const r = await fetch('/api/macro/begin', {method:'POST'});
  const d = await r.json();
  if (d.error) { alert(d.error); return; }
  document.getElementById('macroState').textContent = 'capturing… press the button now';
  document.getElementById('macroSave').style.display = 'none';
  if (macroTimer) clearInterval(macroTimer);
  macroTimer = setInterval(macroPoll, 800);
}
async function macroPoll() {
  const r = await fetch('/api/macro/status');
  const d = await r.json();
  if (!d.capturing) { clearInterval(macroTimer); return; }
  const ids = Object.keys(d.effect || {});
  document.getElementById('macroLive').innerHTML =
    `<pre class="cmd">guess: ${d.kind_guess} · ${d.steps.length} events · `
    + `${ids.length} loads affected\n`
    + ids.map(i => `  output ${i} -> ${d.effect[i]}`).join('\n')
    + (d.kind_guess==='integration' ? '\n  (no Lutron output — Savant/Spotify integration)' : '')
    + `</pre>`;
  if (d.settled && d.steps.length >= 0) {
    document.getElementById('macroState').textContent = 'settled — name and save it';
    document.getElementById('macroSave').style.display = 'block';
    if (d.kind_guess) document.getElementById('macroKind').value = '';
    clearInterval(macroTimer);
  }
}
async function macroSave() {
  const body = {
    area: document.getElementById('macroArea').value,
    keypad: document.getElementById('macroKeypad').value,
    label: document.getElementById('macroLabel').value,
    kind: document.getElementById('macroKind').value || null,
  };
  const r = await fetch('/api/macro/save', {method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify(body)});
  const d = await r.json();
  if (d.error) { alert(d.error); return; }
  document.getElementById('macroState').textContent = `saved as ${d.kind}`;
  document.getElementById('macroSave').style.display = 'none';
  document.getElementById('macroLive').innerHTML = '';
  loadMap();
}


async function loadSeed() {
  const r = await fetch('/api/seed', {method:'POST'});
  const d = await r.json();
  if (d.error) { document.getElementById('seedState').textContent = d.error; return; }
  document.getElementById('seedState').textContent =
    `added ${d.added.areas} rooms, ${d.added.keypads} keypads, ${d.added.buttons} buttons`;
  loadMap();
}
