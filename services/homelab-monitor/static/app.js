'use strict';
const $ = (id) => document.getElementById(id);
let lastPayload = null, pending = false, queuedManual = false, activeTab = 'temperature';

function element(tag, className, text) {
  const e = document.createElement(tag);
  if (className) e.className = className;
  if (text !== undefined && text !== null) e.textContent = String(text);
  return e;
}
function num(x) { return typeof x === 'number' && Number.isFinite(x) ? x : null; }
function tempText(x) { const v = num(x); return v === null ? '—' : v.toFixed(1); }
// Advisory colors, not manufacturer-specific drive limits.
const limits = {cpu:[80,95],gpu:[75,85],ssd:[60,70]};
function severity(value,kind='cpu') {
  const v=num(value); if(v===null) return '';
  return v>=limits[kind][1]?'danger':v>=limits[kind][0]?'warn':'green';
}
function tempClass(value,kind) {
  const s=severity(value,kind); return s?'text-'+s:'';
}
function tempValue(value,cls='metric-num',kind='cpu') {
  const box=element('div',cls+' '+tempClass(value,kind)),v=num(value);
  box.append(document.createTextNode(v === null ? 'N/A' : v.toFixed(1)));
  if (v !== null) box.append(element('small','unit','°C'));
  return box;
}
function meter(value,kind='cpu') {
  const track=element('div','meter');
  const fill=element('div','meter-fill '+severity(value,kind));
  fill.style.width=num(value)===null
    ?'0%':Math.max(0,Math.min(100,value))+'%';
  track.append(fill); return track;
}
function metric(label,reading,subtitle,kind='cpu') {
  const card=element('div','metric');
  card.append(
    element('div','metric-name',label),
    tempValue(reading.c,'metric-num',kind),
    meter(reading.c,kind),
    element('div','metric-sub',subtitle)
  );
  return card;
}
function driveCard(ssd, index, wide) {
  const card = element('div','drive');
  const titleWrap = element('div','drive-title-wrap');
  // Storage-node SSDs are identified by their controller rather than an assumed ADM bay.
  const name = wide ? 'SSD ' + String(index+1).padStart(2,'0') : (ssd.name || 'NVMe SSD');
  titleWrap.append(element('div','drive-title',name));
  const meta = [wide ? ssd.pci : ssd.device, wide ? ssd.device : null].filter(Boolean).join(' · ');
  titleWrap.append(element('div','drive-sub',meta));
  const top = element('div','drive-top');
  top.append(titleWrap, tempValue(ssd.c,'drive-temp','ssd'));
  card.append(top,meter(ssd.c,'ssd'));
  if (wide) card.title = [ssd.name,ssd.pci,ssd.device].filter(Boolean).join(' · ');
  return card;
}
function cardFor(host) {
  const data = host.data || {};
  const wide = host.id === 'flashstor';
  const section = element('section','node host-' + host.id + ' ' + (wide ? 'node-wide ' : '') + (!host.online ? 'is-offline' : ''));
  const header = element('div','node-header');
  const nameContainer = element('div','node-title-wrap');
  const icon = element('div','node-icon');
  icon.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="3" width="16" height="18" rx="2"/><path d="M7 8h10M7 13h10M8 17h2"/></svg>';
  const labels = element('div','');
  labels.append(element('div','node-name',host.label));
  nameContainer.append(icon,labels);
  const state = element('div','node-status',host.online ? 'ONLINE' : 'OFFLINE');
  header.append(nameContainer,state); section.append(header);
  if (!host.online) {
    const stale = element('div','stale-notice', host.error || 'No recent reading. Values below may be outdated.');
    section.append(stale);
  }
  const content = element('div','node-content');
  const metricContainer = element('div','primary-metrics');
  const cpu = data.cpu || {}, gpu = data.gpu || null;
  // Display only primary readings; secondary readings remain in the live API.
  const cpuReading = host.online ? cpu.readings?.[0] : null;
  const gpuReading = host.online ? gpu?.readings?.[0] : null;
  metricContainer.append(metric('CPU',{c:cpuReading?.c ?? null},cpu.name || 'Unavailable','cpu'));
  if (gpu) metricContainer.append(metric('GPU',{c:gpuReading?.c ?? null},gpu.name || 'Unavailable','gpu'));
  if (wide) {
    const left = element('div','node-left');
    left.append(metricContainer);
    content.append(left);
  } else {
    content.append(metricContainer);
  }
  const detectedSsds = Array.isArray(data.ssds) ? data.ssds : [];
  const disks = detectedSsds
    .filter(s => !(host.id === 'faex1' && (s.name || '').endsWith(' — Windows')))
    .map(s => host.online ? s : {...s, c:null});
  const diskBlock = element('div','disk-block');
  const diskHeader = element('div','drives-title');
  diskHeader.append(element('span','',wide ? 'CRUCIAL P3 PLUS 4 TB ARRAY' : 'STORAGE'),element('span','',disks.length + ' SSD' + (disks.length===1?'':'s')));
  diskBlock.append(diskHeader);
  const diskGrid = element('div','drives-grid');
  disks.forEach((ssd,i)=>diskGrid.append(driveCard(ssd,i,wide)));
  if (!disks.length) diskGrid.append(element('div','missing','No drives detected'));
  diskBlock.append(diskGrid);
  if (wide) {
    const temps = disks.map(s=>num(s.c)).filter(v=>v!==null);
    if(temps.length) {
      const avg = temps.reduce((a,b)=>a+b,0)/temps.length;
      const summary = element('div','summary-note');
      summary.append(document.createTextNode('LOW '),element('strong',tempClass(Math.min(...temps),'ssd'),Math.min(...temps).toFixed(1)+'°C'),
          document.createTextNode('    ·    AVG '),element('strong',tempClass(avg,'ssd'),avg.toFixed(1)+'°C'),
          document.createTextNode('    ·    HIGH '),element('strong',tempClass(Math.max(...temps),'ssd'),Math.max(...temps).toFixed(1)+'°C'));
      diskBlock.append(summary);
    }
    content.append(diskBlock);
  } else { content.append(diskBlock); }
  section.append(content);
  if (Number(data.expected_ssds) > 0 && data.expected_ssds !== detectedSsds.length)
    section.append(element('div','missing','Expected '+data.expected_ssds+' drives; detected '+disks.length+'.'));
  return section;
}
function stat(label, value, foot, cls) {
  const box = element('div','stat');
  box.append(element('div','stat-label',label));
  box.append(element('div','stat-value '+(cls||''),value));
  box.append(element('div','stat-foot',foot));
  return box;
}
function statsFor(hosts) {
  const online = hosts.filter(h=>h.online);
  // Never count outdated/offline readings as live sensor values.
  const ssds = online.flatMap(h=>h.data?.ssds || []);
  const cpuTemps = online.map(h=>num(h.data?.cpu?.readings?.[0]?.c)).filter(v=>v!==null);
  const ssdTemps = ssds.map(s=>num(s.c)).filter(v=>v!==null);
  const count = online.length;
  return [stat('Systems online',count+' / '+hosts.length,'Live host connections',count===hosts.length?'text-green':'text-warn'),
          stat('NVMe drives',String(ssds.length),'Reporting from online hosts',''),
          stat('Hottest CPU',cpuTemps.length?Math.max(...cpuTemps).toFixed(1)+'°':'—','Across online systems',cpuTemps.length?tempClass(Math.max(...cpuTemps),'cpu'):''),
          stat('Hottest SSD',ssdTemps.length?Math.max(...ssdTemps).toFixed(1)+'°':'—','Current drive temperatures',ssdTemps.length?tempClass(Math.max(...ssdTemps),'ssd'):'')];
}
// Usage metrics are neutral percentages, not temperature alarm indicators.
// Usage utilization color thresholds.
const usageLimits = {
  cpu: [70, 90],
  gpu: [70, 90],
  ram: [75, 90],
  storage: [80, 95]
};

function usageSeverity(value, kind) {
  const n = num(value);
  if (n === null) return '';
  const [warn, danger] = usageLimits[kind] || usageLimits.storage;
  return n >= danger ? 'danger' : n >= warn ? 'warn' : 'green';
}

function usageTextClass(value, kind) {
  const level = usageSeverity(value, kind);
  return level ? 'text-' + level : '';
}

function percentText(value) {
  const n = num(value);
  return n === null ? 'N/A' : n.toFixed(1) + '%';
}
function capacityText(used, total) {
  const u = num(used), t = num(total);
  if (u === null || t === null || t <= 0) return 'N/A';
  const unit = t >= 1e12 ? 'TB' : 'GB';
  const divisor = unit === 'TB' ? 1e12 : 1e9;
  return (u / divisor).toFixed(2) + ' / ' + (t / divisor).toFixed(2) + ' ' + unit + ' used';
}
function usageMeter(pct, kind = 'cpu') {
  const track = element('div', 'meter');
  const fill = element('div', 'meter-fill usage-fill ' + usageSeverity(pct, kind));
  fill.style.width = num(pct) === null ? '0%' : Math.max(0, Math.min(100, pct)) + '%';
  track.append(fill);
  return track;
}
function usageMetric(label, value, subtitle) {
  const card = element('div', 'metric usage-metric');
  card.append(
    element('div', 'metric-name', label),
    element('div', 'metric-num ' + usageTextClass(value, label.toLowerCase()), percentText(value)),
    usageMeter(value, label.toLowerCase()),
    element('div', 'metric-sub', subtitle)
  );
  return card;
}
function usageDrive(volume, online) {
  const pct = online ? volume.pct : null;
  const used = online ? volume.used_bytes : null;
  const total = online ? volume.total_bytes : null;
  const row = element('div', 'usage-drive');
  const top = element('div', 'usage-drive-top');
  const names = element('div', 'usage-drive-names');
  names.append(element('div', 'drive-title', volume.name || 'Filesystem'));
  // names.append(element('div', 'drive-sub', volume.mount || 'Not mounted'));
  top.append(names, element('div', 'usage-drive-pct ' + usageTextClass(pct, 'storage'), percentText(pct)));
  row.append(top, usageMeter(pct, 'storage'));
  row.append(element('div', 'usage-capacity', capacityText(used, total)));
  return row;
}
function usageCardFor(host) {
  const data = host.data || {};
  const usage = data.usage || {};
  const wide = host.id === 'flashstor';
  const section = element('section', 'node usage-node host-' + host.id + ' ' + (wide ? 'node-wide ' : '') + (!host.online ? 'is-offline' : ''));
  const header = element('div', 'node-header');
  const left = element('div', 'node-title-wrap');
  const icon = element('div', 'node-icon');
  icon.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="3" width="16" height="18" rx="2"/><path d="M7 8h10M7 13h10M8 17h2"/></svg>';
  left.append(icon, element('div', 'node-name', host.label));
  header.append(left, element('div', 'node-status', host.online ? 'ONLINE' : 'OFFLINE'));
  section.append(header);
  if (!host.online) section.append(element('div', 'stale-notice', host.error || 'Usage data unavailable.'));

  const content = element('div', 'node-content usage-content');
  const metrics = element('div', 'primary-metrics usage-primary');
  const live = (value) => host.online ? value ?? null : null;
  metrics.append(usageMetric('CPU', live(usage.cpu_pct), data.cpu?.name || 'CPU'));
  if (data.gpu) metrics.append(usageMetric('GPU', live(usage.gpu_pct), data.gpu.name || 'GPU utilization'));
  metrics.append(usageMetric('RAM', live(usage.ram?.pct),
    capacityText(live(usage.ram?.used_bytes), live(usage.ram?.total_bytes))));
  content.append(metrics);

  const block = element('div', 'usage-storage-block');
  const heading = element('div', 'drives-title');
  const volumes = Array.isArray(usage.storage) ? usage.storage : [];
  const mountedVolumeCount = volumes.filter(vol => vol.mount !== null).length;
  heading.append(element('span', '', wide ? 'CRUCIAL P3 PLUS 4 TB ARRAY' : 'STORAGE'),
    element('span', '', mountedVolumeCount + ' volume' + (mountedVolumeCount === 1 ? '' : 's')));
  block.append(heading);
  const list = element('div', 'usage-drive-list');
  const mountedVolumes = volumes.filter(vol => vol.mount !== null);

  if (mountedVolumes.length) {
    mountedVolumes.forEach(vol => list.append(usageDrive(vol, host.online)));
  }
  else list.append(element('div', 'missing', 'No storage usage available'));
  block.append(list);
  content.append(block);
  section.append(content);
  return section;
}
function usageStatsFor(hosts) {
  const online = hosts.filter(h => h.online);
  const peaks = (read) => online.map(read).filter(v => v !== null);
  const cpus = peaks(h => num(h.data?.usage?.cpu_pct));
  const gpus = peaks(h => num(h.data?.usage?.gpu_pct));
  const rams = peaks(h => num(h.data?.usage?.ram?.pct));
  const highest = values => values.length ? Math.max(...values).toFixed(1) + '%' : '—';
  return [
    stat('Systems online', online.length + ' / ' + hosts.length, 'Live host connections',
      online.length === hosts.length ? 'text-green' : 'text-warn'),
    stat('Busiest CPU', highest(cpus), 'Current highest CPU utilization', ''),
    stat('Busiest GPU', highest(gpus), 'Current highest GPU utilization', ''),
    stat('Highest RAM', highest(rams), 'Current highest memory usage', '')
  ];
}
function switchTab(tab) {
  if (tab === activeTab) return;

  const previousScrollY = window.scrollY;
  const previousPanel = $(activeTab === 'temperature'
    ? 'temp-panel' : 'usage-panel');
  const previousHeight = previousPanel.getBoundingClientRect().height;

  activeTab = tab;
  for (const key of ['temperature', 'usage']) {
    const button = $('tab-' + key);
    button.classList.toggle('is-active', key === tab);
    button.setAttribute('aria-selected', String(key === tab));
  }
  $('temp-panel').hidden = tab !== 'temperature';
  $('usage-panel').hidden = tab !== 'usage';

  const newPanel = $(tab === 'temperature'
    ? 'temp-panel' : 'usage-panel');

  // Prevent shorter tabs from forcing the page to scroll upward.
  newPanel.style.minHeight =
    Math.ceil(Math.max(previousHeight, newPanel.scrollHeight)) + 'px';

  // Restore the same scroll position after the layout changes.
  window.scrollTo(0, previousScrollY);
  requestAnimationFrame(() => window.scrollTo(0, previousScrollY));
}

// Demo mode: simulated values, never applied to live readings.
function demoValues(input) {
  if (!input.demo) return input;

  const payload = JSON.parse(JSON.stringify(input));
  const samples = {
    faex1: {
      cpu: 42, gpu: 77, ssds: [45, 65, 75]
    },
    ms01: {
      cpu: 86, gpu: 90, ssds: [65]
    },
    flashstor: {
      cpu: 97,
      ssds: [43,48,53,57,61,65,69,72,46,55,63,76]
    }
  };

  for (const host of payload.hosts || []) {
    const p = samples[host.id];
    const d = host.data;
    if (!p || !d) continue;

    if (d.cpu?.readings?.[0])
      d.cpu.readings[0].c = p.cpu;

    if (p.gpu !== undefined && d.gpu?.readings?.[0])
      d.gpu.readings[0].c = p.gpu;

    (d.ssds || []).forEach((ssd, i) => {
      if (p.ssds[i] !== undefined)
        ssd.c = p.ssds[i];
    });
    // Populate sample usage data without changing the server-side temperature demo.
    const examples = {
      faex1: {cpu: 28.4, gpu: 65.0, ram: [48, 124], disks: [[0.7, 1.8], null, [0.9, 1.45]]},
      ms01: {cpu: 17.5, gpu: 42.0, ram: [22, 94], disks: [[4.1, 14.0]]},
      flashstor: {cpu: 34.1, gpu: null, ram: [4, 8], disks: [[18.6, 36.2]]}
    }[host.id];
    if (examples) {
      const asBytes = v => Math.round(v * 1024 ** 4);
      const ramBytes = v => Math.round(v * 1024 ** 3);
      const paths = host.id === 'faex1'
        ? [['Samsung 990 PRO 2 TB — ext4', '/'], ['Samsung 990 PRO 2 TB — Windows', null], ['Intel Optane P5800X 1.6 TB — XFS', '/mnt/p5800x']]
        : host.id === 'ms01' ? [['Samsung PM9A3 15.36 TB — Btrfs', '/']]
        : [['RAID5 — Btrfs', '/volume1']];
      d.usage = {
        cpu_pct: examples.cpu, gpu_pct: examples.gpu,
        ram: {used_bytes: ramBytes(examples.ram[0]), total_bytes: ramBytes(examples.ram[1]),
          pct: 100 * examples.ram[0] / examples.ram[1]},
        storage: paths.map(([name, mount], i) => {
          const pair = examples.disks[i];
          return {name, mount, used_bytes: pair ? asBytes(pair[0]) : null,
            total_bytes: pair ? asBytes(pair[1]) : null,
            pct: pair ? 100 * pair[0] / pair[1] : null};
        })
      };
    }
  }

  return payload;
}
function render(input) {
  const payload = demoValues(input);
  lastPayload = payload;
  $('demo-banner').hidden = !input.demo;
  $('demo-legend').hidden = !input.demo;
  const hosts = payload.hosts || [];
  const onlineCount = hosts.filter(h=>h.online).length;
  $('compute').replaceChildren(...hosts.filter(h=>h.id!=='flashstor').map(cardFor));
  $('storage').replaceChildren(...hosts.filter(h=>h.id==='flashstor').map(cardFor));
  $('usage-compute').replaceChildren(...hosts.filter(h=>h.id!=='flashstor').map(usageCardFor));
  $('usage-storage').replaceChildren(...hosts.filter(h=>h.id==='flashstor').map(usageCardFor));
  const conn = $('connection');
  conn.className = 'connection ' + (onlineCount===hosts.length?'':onlineCount?'degraded':'offline');
  conn.lastElementChild.textContent = onlineCount + ' / ' + hosts.length + ' ONLINE';
  const ages = hosts.filter(h=>h.online && h.age_seconds!==null).map(h=>h.age_seconds);
  $('freshness').textContent = ages.length ? 'Updated ' + Math.max(0,Math.ceil(Math.max(...ages))) + 's ago · every ' + payload.interval_seconds + 's' : 'No current sensor data';
  $('shell').classList.remove('system-down');
}
async function load(force=false) {
  if (document.hidden && !force) return;
  if(pending){if(force)queuedManual=true;return;}
  pending=true;
  const btn=$('refresh-btn');
  if(force){
    btn.disabled=true;
    btn.classList.add('is-refreshing');
    $('freshness').textContent='Reading sensors now…';
  }
  try {
    const controller=new AbortController();
    const timeout=setTimeout(
      ()=>controller.abort(), force?15000:3500
    );
    let response;
    try {
      response=await fetch(
        force?'/api/refresh':'/api/live',
        {method:force?'POST':'GET',cache:'no-store',signal:controller.signal}
      );
    } finally {clearTimeout(timeout);}
    if(!response.ok)throw new Error('HTTP '+response.status);
    const data = await response.json();
    try {
      render(data);
    } catch (error) {
      console.error('Dashboard rendering error:', error);
      $('freshness').textContent =
        'Display error — see browser console';
      return;
    }
  } catch(err) {
    console.error('Homelab Monitor: refresh/render failed', err);
    if(force){
      $('freshness').textContent=
        'Manual refresh failed — auto refresh continues';
    } else {
      $('connection').className='connection offline';
      $('connection').lastElementChild.textContent='DASHBOARD OFFLINE';
      $('freshness').textContent='Connection lost — retrying';
      $('shell').classList.add('system-down');
      if (lastPayload) {
        const offline = {...lastPayload, hosts:(lastPayload.hosts || []).map(h => ({
          ...h, online:false, error:'Monitoring server unreachable'
        }))};
        render(offline);
        $('connection').lastElementChild.textContent='DASHBOARD OFFLINE';
        $('freshness').textContent='Connection lost — retrying';
        $('shell').classList.add('system-down');
      }
    }
  } finally {
    pending=false;
    btn.disabled=false;
    btn.classList.remove('is-refreshing');
    if(queuedManual){queuedManual=false;void load(true);}
  }
}
function updateClock(){
  const d = new Date();
  const pad = n => String(n).padStart(2, '0');

  $('clock').textContent =
    `${d.getFullYear()}/${pad(d.getMonth()+1)}/${pad(d.getDate())}  ` +
    `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}
$('refresh-btn').addEventListener('click',()=>{void load(true);});
$('tab-temperature').addEventListener('click', () => switchTab('temperature'));
$('tab-usage').addEventListener('click', () => switchTab('usage'));
updateClock();
setInterval(updateClock,1000);
load();
setInterval(load,2500);

// PWA lifecycle: refresh after returning to the foreground.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) void load();
});

// Register the Service Worker only in a secure context.
if ("serviceWorker" in navigator && window.isSecureContext) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/sw.js").catch(err => {
      console.warn("Offline app shell unavailable:", err);
    });
  });
}
