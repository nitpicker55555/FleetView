import Foundation

/// The single self-contained HTML page served at `/`. It polls `/state` for live data, renders the
/// same projects/terminals/status the desktop shows, lets you drag a card onto an action zone
/// (done / duplicate / rename / leave / remove), add terminals, and open one full-screen in an
/// iframe (ttyd). A native input bar sends text via tmux `send-keys` so CJK/IME input works where
/// xterm.js falls short. No external assets — everything is inline so it works offline on the LAN.
enum WebDashboardPage {
    static let html = """
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>FleetView</title>
<style>
  :root{
    --bg:#14171c; --panel:#1c1f25; --card:#25282f; --cardHover:#2e3039;
    --stroke:rgba(255,255,255,.08); --text:#ebedf2; --sub:#99a1b0; --accent:#7a9eff;
    --green:#5cd18c; --teal:#4dadc2; --gray:#8c93a3; --amber:#fab852; --red:#d96b73;
    --claude:#e69459; --codex:#66ccd9;
  }
  *{box-sizing:border-box}
  html,body{margin:0;height:100%}
  body{background:var(--bg);color:var(--text);
    font:14px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    -webkit-font-smoothing:antialiased;-webkit-tap-highlight-color:transparent}
  header{position:sticky;top:0;z-index:5;display:flex;align-items:center;gap:10px;flex-wrap:wrap;
    padding:12px 16px;background:rgba(28,31,37,.92);backdrop-filter:blur(8px);
    border-bottom:1px solid var(--stroke);padding-top:max(12px,env(safe-area-inset-top))}
  .logo{font-weight:600;font-size:15px}.logo b{color:var(--accent)}
  .muted{color:var(--sub);font-size:13px}
  .pill{font-size:11px;font-weight:600;padding:2px 8px;border-radius:999px}
  .spacer{flex:1}
  .dot{width:9px;height:9px;border-radius:50%;flex:none}
  .refresh{font-size:11px;color:var(--sub)}
  main{padding:16px;max-width:1200px;margin:0 auto;padding-bottom:120px}
  .proj{margin-bottom:26px}
  .projhead{display:flex;align-items:center;gap:8px;margin-bottom:10px}
  .projhead .name{font-size:15px;font-weight:600}
  .projhead .count{font-size:11px;font-weight:600;color:var(--sub);background:var(--card);padding:1px 7px;border-radius:999px}
  .projhead .tok{font-size:11px;font-weight:600;color:var(--accent);background:rgba(122,158,255,.12);padding:1px 7px;border-radius:999px}
  .addbtn{margin-left:auto;font-size:12px;font-weight:600;color:var(--accent);background:rgba(122,158,255,.12);
    border:1px solid rgba(122,158,255,.28);border-radius:7px;padding:5px 10px;cursor:pointer}
  .addbtn:active{transform:scale(.96)}
  .grid{display:grid;gap:12px;grid-template-columns:repeat(auto-fill,minmax(280px,1fr))}
  .card{background:var(--card);border:1px solid var(--stroke);border-radius:12px;padding:13px 14px;
    display:flex;flex-direction:column;gap:9px;transition:transform .1s,background .12s;cursor:pointer;
    position:relative;touch-action:none;user-select:none;-webkit-user-select:none}
  .card:hover{background:var(--cardHover)}
  .card.locked{cursor:default;opacity:.6}
  .card.done{background:#101c13;border-color:rgba(92,209,140,.4)}
  .card.dragging{opacity:.35}
  .cardtop{display:flex;align-items:center;gap:9px}
  .cardtop .name{font-weight:600;font-size:14px;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .agent{font-size:9px;font-weight:700;padding:1px 5px;border-radius:999px;text-transform:uppercase}
  .status{font-size:11px;font-weight:600}
  .prompt{font-size:12px;color:var(--sub);display:flex;gap:6px;min-height:32px}
  .prompt .sig{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-weight:700;flex:none}
  .prompt .txt{overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
  .ago{font-size:10px;color:var(--sub);opacity:.75;text-align:right;margin-top:-3px}
  .cluster{border:1px solid rgba(122,158,255,.28);background:rgba(122,158,255,.055);border-radius:14px;padding:12px;margin-bottom:12px}
  .cluster .clabel{font-size:9px;font-weight:700;color:var(--accent);background:rgba(122,158,255,.14);padding:2px 6px;border-radius:999px;margin-right:6px}
  .cluster .chead{display:flex;align-items:center;margin-bottom:10px}
  .cluster .cname{font-weight:600;font-size:14px}
  .banner{background:rgba(250,184,82,.13);border:1px solid rgba(250,184,82,.3);color:var(--amber);padding:10px 12px;border-radius:10px;font-size:12px;margin-bottom:16px}
  .empty{color:var(--sub);text-align:center;padding:60px 20px}
  .hintbar{position:fixed;left:0;right:0;bottom:0;z-index:3;text-align:center;font-size:11px;color:var(--sub);
    padding:8px;padding-bottom:max(8px,env(safe-area-inset-bottom));background:linear-gradient(transparent,var(--bg) 40%)}
  /* drag chip + action dock */
  #chip{position:fixed;z-index:60;pointer-events:none;display:none;background:var(--card);border:1px solid var(--accent);
    border-radius:9px;padding:7px 11px;font-size:13px;font-weight:600;box-shadow:0 8px 24px rgba(0,0,0,.5);transform:translate(-50%,-140%)}
  #dock{position:fixed;left:0;right:0;bottom:0;z-index:55;display:none;justify-content:center;gap:10px;flex-wrap:wrap;
    padding:16px;padding-bottom:max(16px,env(safe-area-inset-bottom));background:linear-gradient(transparent,rgba(0,0,0,.75) 45%)}
  .zone{min-width:88px;text-align:center;padding:14px 12px;border-radius:12px;font-size:13px;font-weight:600;
    background:var(--card);border:1px solid var(--stroke);color:var(--text)}
  .zone.hot{background:var(--accent);color:#0b1020;border-color:var(--accent);transform:scale(1.06)}
  .zone.danger{color:var(--red);border-color:rgba(217,107,115,.4)}
  .zone.danger.hot{background:var(--red);color:#fff}
  /* terminal overlay */
  #term{position:fixed;inset:0;z-index:50;background:#000;display:none;flex-direction:column}
  #term.show{display:flex}
  #termbar{display:flex;align-items:center;gap:12px;padding:10px 14px;background:var(--panel);
    border-bottom:1px solid var(--stroke);padding-top:max(10px,env(safe-area-inset-top))}
  #termbar button{background:var(--card);color:var(--text);border:1px solid var(--stroke);border-radius:8px;padding:7px 12px;font-size:13px;font-weight:600;cursor:pointer}
  #termbar .tname{font-weight:600;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #termframe{flex:1;border:0;width:100%;background:#000}
  #inputbar{background:var(--panel);border-top:1px solid var(--stroke);padding:8px;padding-bottom:max(8px,env(safe-area-inset-bottom))}
  #keys{display:flex;gap:6px;overflow-x:auto;margin-bottom:8px}
  #keys button{flex:none;background:var(--card);color:var(--text);border:1px solid var(--stroke);border-radius:7px;padding:6px 10px;font-size:12px;font-weight:600;cursor:pointer}
  #keys button:active{background:var(--accent);color:#0b1020}
  #sendrow{display:flex;gap:8px;align-items:flex-end}
  #inputtext{flex:1;resize:none;background:var(--card);color:var(--text);border:1px solid var(--stroke);border-radius:10px;
    padding:10px 12px;font:14px/1.35 inherit;max-height:120px}
  #sendbtn{flex:none;background:var(--accent);color:#0b1020;border:0;border-radius:10px;padding:11px 16px;font-size:14px;font-weight:700;cursor:pointer}
</style>
</head>
<body>
<header>
  <span class="logo"><b>▉</b> FleetView</span>
  <span class="muted" id="counts">…</span>
  <span id="pills"></span>
  <span class="spacer"></span>
  <span class="refresh" id="refresh"></span>
</header>
<main id="root"><div class="empty">Loading…</div></main>
<div class="hintbar">Tap a terminal to open · drag a card for actions</div>

<div id="chip"></div>
<div id="dock"></div>

<div id="term">
  <div id="termbar">
    <button onclick="closeTerm()">‹ Back</button>
    <span class="tname" id="termname"></span>
    <button onclick="popTerm()">↗</button>
  </div>
  <iframe id="termframe" src="about:blank" allow="clipboard-read; clipboard-write"></iframe>
  <div id="inputbar">
    <div id="keys">
      <button onclick="key('Escape')">Esc</button>
      <button onclick="key('Enter')">⏎</button>
      <button onclick="key('Up')">↑</button>
      <button onclick="key('Down')">↓</button>
      <button onclick="key('Tab')">Tab</button>
      <button onclick="key('C-c')">^C</button>
      <button onclick="key('BSpace')">⌫</button>
    </div>
    <div id="sendrow">
      <textarea id="inputtext" rows="1" placeholder="Type here (中文 OK) — Enter to send, Shift+Enter for newline"></textarea>
      <button id="sendbtn" onclick="sendText()">Send</button>
    </div>
  </div>
</div>

<script>
const COLORS={working:'var(--green)',shell:'var(--teal)',idle:'var(--gray)',
  needsYou:'var(--amber)',exited:'var(--red)',closed:'rgba(255,255,255,.22)'};
let curUrl='',curId='',state=null,dragging=false;

function short(n){if(n<1000)return ''+n;if(n<1000000)return (n/1000).toFixed(n<10000?1:0)+'k';return (n/1000000).toFixed(1)+'M';}
function ago(sec){if(sec<0)return '';if(sec<5)return 'just now';if(sec<60)return sec+'s ago';
  const m=Math.floor(sec/60);if(m<60)return m+'m ago';const h=Math.floor(m/60);if(h<24)return h+'h ago';return Math.floor(h/24)+'d ago';}
function esc(s){const d=document.createElement('div');d.textContent=s||'';return d.innerHTML;}
function termOpen(){return document.getElementById('term').classList.contains('show');}

// ---------- terminal open / input ----------
async function openTerm(id,name){
  try{
    const r=await fetch('/open?id='+encodeURIComponent(id));
    const j=await r.json();
    if(!j.url){alert('This terminal is not open on the Mac right now.');return;}
    curUrl=j.url;curId=id;
    document.getElementById('termname').textContent=name;
    document.getElementById('termframe').src=j.url;
    document.getElementById('term').classList.add('show');
  }catch(e){alert('Could not open terminal: '+e);}
}
function closeTerm(){document.getElementById('term').classList.remove('show');document.getElementById('termframe').src='about:blank';curId='';}
function popTerm(){if(curUrl)window.open(curUrl,'_blank');}
async function key(k){if(!curId)return;try{await fetch('/key?id='+curId+'&k='+encodeURIComponent(k));}catch(e){}}
async function sendText(){
  if(!curId)return;
  const ta=document.getElementById('inputtext');const t=ta.value;
  if(!t){key('Enter');return;}
  try{await fetch('/type?id='+curId+'&enter=1&text='+encodeURIComponent(t));ta.value='';ta.style.height='auto';}catch(e){}
}
document.getElementById('inputtext').addEventListener('keydown',e=>{
  if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing){e.preventDefault();sendText();}
});
document.getElementById('inputtext').addEventListener('input',e=>{e.target.style.height='auto';e.target.style.height=Math.min(120,e.target.scrollHeight)+'px';});

// ---------- create / actions ----------
async function newTerm(pid){try{await fetch('/new?projectId='+encodeURIComponent(pid));setTimeout(tick,300);}catch(e){}}
async function doAction(id,act,extra){
  let u='/action?id='+encodeURIComponent(id)+'&do='+act;
  if(extra)u+='&name='+encodeURIComponent(extra);
  try{await fetch(u);setTimeout(tick,200);}catch(e){}
}

// ---------- drag-to-act ----------
let drag={id:null,name:null,cluster:false,x:0,y:0,sx:0,sy:0,active:false};
function zonesFor(cluster,done){
  const z=[{k:'done',t:done?'Undone':'✓ Done'},{k:'duplicate',t:'⧉ Duplicate'},{k:'rename',t:'✎ Rename'}];
  if(cluster)z.push({k:'leaveCluster',t:'⇤ Leave'});
  z.push({k:'remove',t:'🗑 Remove',danger:true});
  return z;
}
function buildDock(cluster,done){
  const dock=document.getElementById('dock');
  dock.innerHTML=zonesFor(cluster,done).map(z=>`<div class="zone${z.danger?' danger':''}" data-zone="${z.k}">${z.t}</div>`).join('');
}
function zoneAt(x,y){
  for(const el of document.querySelectorAll('#dock .zone')){
    const r=el.getBoundingClientRect();
    if(x>=r.left&&x<=r.right&&y>=r.top&&y<=r.bottom)return el;
  }return null;
}
function onDown(e){
  const card=e.target.closest('.card');if(!card)return;
  drag.id=card.dataset.id;drag.name=card.dataset.name;drag.cluster=card.dataset.cluster==='1';
  drag.done=card.dataset.done==='1';drag.canopen=card.dataset.canopen==='1';drag.card=card;
  drag.sx=e.clientX;drag.sy=e.clientY;drag.active=false;
  window.addEventListener('pointermove',onMove);
  window.addEventListener('pointerup',onUp);
}
function onMove(e){
  const dx=e.clientX-drag.sx,dy=e.clientY-drag.sy;
  if(!drag.active&&Math.hypot(dx,dy)<9)return;
  if(!drag.active){
    drag.active=true;dragging=true;drag.card.classList.add('dragging');
    buildDock(drag.cluster,drag.done);
    document.getElementById('dock').style.display='flex';
    const chip=document.getElementById('chip');chip.textContent=drag.name;chip.style.display='block';
  }
  const chip=document.getElementById('chip');chip.style.left=e.clientX+'px';chip.style.top=e.clientY+'px';
  document.querySelectorAll('#dock .zone').forEach(z=>z.classList.remove('hot'));
  const hot=zoneAt(e.clientX,e.clientY);
  drag.hotAct=hot?hot.dataset.zone:null;   // remember target NOW; the dock is hidden before onUp reads it
  if(hot)hot.classList.add('hot');
}
function onUp(e){
  window.removeEventListener('pointermove',onMove);
  window.removeEventListener('pointerup',onUp);
  const wasActive=drag.active;
  const act=wasActive?drag.hotAct:null;   // captured during onMove, while zones still had layout
  document.getElementById('chip').style.display='none';
  document.getElementById('dock').style.display='none';
  if(drag.card)drag.card.classList.remove('dragging');
  dragging=false;
  if(!wasActive){ // a tap, not a drag
    if(drag.canopen)openTerm(drag.id,drag.name);else toast('Open this terminal on the Mac first');
    return;
  }
  if(!act)return;
  if(act==='rename'){const n=prompt('Rename terminal',drag.name);if(n)doAction(drag.id,'rename',n);}
  else doAction(drag.id,act);
}
document.getElementById('root').addEventListener('pointerdown',onDown);

let toastT=null;
function toast(msg){
  let t=document.getElementById('toast');
  if(!t){t=document.createElement('div');t.id='toast';
    t.style.cssText='position:fixed;left:50%;bottom:70px;transform:translateX(-50%);z-index:70;background:var(--card);border:1px solid var(--stroke);color:var(--text);padding:9px 14px;border-radius:10px;font-size:13px;box-shadow:0 6px 20px rgba(0,0,0,.5)';
    document.body.appendChild(t);}
  t.textContent=msg;t.style.opacity='1';
  clearTimeout(toastT);toastT=setTimeout(()=>{t.style.opacity='0';},1600);
}

// ---------- render ----------
function card(t){
  const locked=!t.canOpen;
  const sig=t.status==='shell'?'$':'›';
  const agent=t.agent?`<span class="agent" style="color:${t.agent==='codex'?'var(--codex)':'var(--claude)'};background:${t.agent==='codex'?'rgba(102,204,217,.16)':'rgba(230,148,89,.16)'}">${t.agent}</span>`:'';
  const tok=t.tokens>0?`<span style="font-size:10px;color:var(--accent);margin-left:5px">${short(t.tokens)} tok</span>`:'';
  const dn=t.done?'✓ ':'';
  return `<div class="card ${locked?'locked':''} ${t.done?'done':''}" data-id="${t.id}" data-name="${esc(t.name)}" data-cluster="${t.clusterId?'1':'0'}" data-canopen="${t.canOpen?'1':'0'}" data-done="${t.done?'1':'0'}">
    <div class="cardtop">
      <span class="dot" style="background:${COLORS[t.status]||COLORS.closed}"></span>
      <span class="name">${dn}${esc(t.name)}</span>${agent}
      <span class="status" style="color:${COLORS[t.status]||COLORS.closed}">${esc(t.statusLabel)}${tok}</span>
    </div>
    <div class="prompt"><span class="sig">${sig}</span><span class="txt">${t.prompt?esc(t.prompt):'—'}</span></div>
    ${t.idle>=0?`<div class="ago">${ago(t.idle)}</div>`:''}
  </div>`;
}
function render(s){
  document.getElementById('counts').textContent=`${s.projects.length} project${s.projects.length===1?'':'s'} · ${s.terminals.length} terminal${s.terminals.length===1?'':'s'}`;
  let pills='';
  if(s.working>0)pills+=`<span class="pill" style="color:var(--green);background:rgba(92,209,140,.18)">${s.working} working</span> `;
  if(s.needs>0)pills+=`<span class="pill" style="color:var(--amber);background:rgba(250,184,82,.18)">${s.needs} needs you</span>`;
  document.getElementById('pills').innerHTML=pills;
  let html='';
  if(!s.remoteOK)html+=`<div class="banner">Web terminals are disabled — run <b>${esc(s.remoteHint)}</b> and relaunch FleetView. Status is still shown.</div>`;
  for(const p of s.projects){
    const terms=s.terminals.filter(t=>t.projectId===p.id);
    const tot=terms.reduce((a,t)=>a+t.tokens,0);
    html+=`<div class="proj"><div class="projhead"><span class="name">${esc(p.name)}</span>`+
      `<span class="count">${terms.length}</span>`+(tot>0?`<span class="tok">Σ ${short(tot)}</span>`:'')+
      `<button class="addbtn" onclick="newTerm('${p.id}')">+ Terminal</button></div>`;
    const cids=[...new Set(terms.filter(t=>t.clusterId).map(t=>t.clusterId))];
    for(const cid of cids){
      const c=s.clusters.find(x=>x.id===cid);const mem=terms.filter(t=>t.clusterId===cid);
      html+=`<div class="cluster"><div class="chead"><span class="clabel">CLUSTER</span><span class="cname">${esc(c?c.name:'')}</span><span class="muted" style="margin-left:8px">· ${mem.length}</span></div><div class="grid">${mem.map(card).join('')}</div></div>`;
    }
    const solo=terms.filter(t=>!t.clusterId);
    if(solo.length)html+=`<div class="grid">${solo.map(card).join('')}</div>`;
    html+='</div>';
  }
  document.getElementById('root').innerHTML=html||'<div class="empty">No projects yet. Add one on the Mac.</div>';
}

async function tick(){
  if(dragging||termOpen())return;
  try{
    const r=await fetch('/state',{cache:'no-store'});state=await r.json();render(state);
    document.getElementById('refresh').textContent='updated '+new Date().toLocaleTimeString();
  }catch(e){document.getElementById('refresh').textContent='offline — retrying…';}
}
tick();setInterval(tick,1500);
</script>
</body>
</html>
"""
}
