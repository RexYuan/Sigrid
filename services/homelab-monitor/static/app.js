'use strict';
const $ = (id) => document.getElementById(id);
let lastPayload = null, pending = false, queuedManual = false;

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
  const section = element('section','node ' + (wide ? 'node-wide ' : '') + (!host.online ? 'is-offline' : ''));
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
  const disks = (Array.isArray(data.ssds) ? data.ssds : []).map(s => host.online ? s : {...s, c:null});
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
  if (Number(data.expected_ssds) > 0 && data.expected_ssds !== disks.length)
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
  $('stats').replaceChildren(...statsFor(hosts));
  $('compute').replaceChildren(...hosts.filter(h=>h.id!=='flashstor').map(cardFor));
  $('storage').replaceChildren(...hosts.filter(h=>h.id==='flashstor').map(cardFor));
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
