sudo apt update
 sudo apt-get install -y python3-requests  ffmpeg v4l-utils 
 sudo apt install libgl1-mesa-glx libglib2.0-0

 
 
 linux-image-current-sunxi64 linux-headers-current-sunxi64 



pip install flask opencv-python opencv-python-headless --break-system-packages









finalmente o codigo 




//app.py

sudo tee /usr/local/bin/app.py >/dev/null <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, cv2, time, glob, threading, platform, subprocess, re, json, stat
from datetime import datetime, date
from flask import Flask, Response, jsonify, render_template_string, request, send_from_directory, abort
from werkzeug.middleware.proxy_fix import ProxyFix
import requests, base64, mimetypes
from collections import deque


# ----------------- Pastas -----------------
MEDIA = {"photos": "photos", "videos": "videos", "thumbs": "thumbs"}
for d in MEDIA.values():
    os.makedirs(d, exist_ok=True)

# === EVO: Credenciais via ENV
EVO_API_URL      = os.environ.get("EVO_API_URL",      "https://evolution.mirako.org").rstrip("/")
EVO_API_INSTANCE = os.environ.get("EVO_API_INSTANCE", "Mirako")
EVO_API_KEY      = os.environ.get("EVO_API_KEY",      "f2824a60ab1042f1144fd1e3c83ea5e3b8f8645884a035609782c287401bafbe")

# ----------------- Config persistente -----------------
CONFIG_FILE = "config.json"
CFG_LOCK = threading.Lock()

DEFAULT_CFG = {
    "cameras": {},
    "ui": {
        "preview_size": "medium",
        "library_view": "grid",
        "selected_devs": []
    },
    "evo": {
        "enable": False,
        "phones": [],
        "base": ""
    }
}

# estado em memória
CFG = json.loads(json.dumps(DEFAULT_CFG))  # cópia

def _cfg_save():
    with CFG_LOCK:
        tmp = CONFIG_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(CFG, f, ensure_ascii=False, indent=2)
        os.replace(tmp, CONFIG_FILE)

def _cfg_reset_defaults():
    global CFG
    with CFG_LOCK:
        CFG = json.loads(json.dumps(DEFAULT_CFG))
    _cfg_save()

def _cfg_normalize_loaded(loaded: dict) -> dict:
    loaded = loaded if isinstance(loaded, dict) else {}
    loaded.setdefault("cameras", {})
    loaded.setdefault("ui", {})
    loaded["ui"].setdefault("preview_size", "medium")
    loaded["ui"].setdefault("library_view", "grid")
    loaded["ui"].setdefault("selected_devs", [])
    loaded.setdefault("evo", {})
    loaded["evo"].setdefault("enable", False)
    loaded["evo"].setdefault("phones", [])
    loaded["evo"].setdefault("base", "")
    # normaliza cada câmera
    for _, c in loaded["cameras"].items():
        c.setdefault("name", "")
        c.setdefault("mic", "default")
        c.setdefault("rotate", 0)
        c.setdefault("capture", {
            "format": "auto",
            "width": 0, "height": 0, "fps": 0
        })
        # bloco live (RTMP) – mantido
        c.setdefault("live", {
            "url": "",
            "audio": True,
    # novos
            "width": 800,      # 0 = manter da câmera
            "height": 600,      # 0 = manter da câmera
            "fps": 15,          # 0 = manter da câmera
            "vbitrate": 1500,   # kbps (CBR)
            "abitrate": 90,    # kbps
            "encoder": "x264",  # x264 | nvenc
            "preset": "veryfast",   # x264: ultrafast..placebo | nvenc: p1..p7 (usaremos p4)
            "latency": "ultra",    # normal | ultra  (ultra = menor latência, menos qualidade)
            "denoise": False        # vídeo: hqdn3d leve
        })

        c.setdefault("timelapse", {"enable": False, "interval": 5})
        c.setdefault("motion", {
            "enable": False, "sensitivity": 50, "min_area_pct": 3,
            "action": "photo", "overlay": True, "cooldown": 10, "clip_len": 30
        })
    return loaded

def _cfg_load():
    global CFG
    if not os.path.exists(CONFIG_FILE):
        _cfg_reset_defaults()
        return
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            loaded = json.load(f)
    except json.JSONDecodeError:
        try:
            os.replace(CONFIG_FILE, f"{CONFIG_FILE}.bad-{int(time.time())}")
        except Exception:
            pass
        _cfg_reset_defaults()
        return
    except Exception:
        _cfg_reset_defaults()
        return

    loaded = _cfg_normalize_loaded(loaded)
    with CFG_LOCK:
        CFG = loaded
    _cfg_save()

    try:
        with CFG_LOCK:
            sel = CFG.setdefault("ui", {}).setdefault("selected_devs", [])
        if not sel:
            actives = detect_active_cams()
            if actives:
                with CFG_LOCK:
                    sel[:] = actives
                _cfg_save()
    except Exception:
        pass

def get_cam_cfg(dev):
    dev = str(dev)
    with CFG_LOCK:
        c = CFG.setdefault("cameras", {}).setdefault(dev, {})
        c.setdefault("name", dev)
        c.setdefault("mic", "default")
        c.setdefault("rotate", 0)
        c.setdefault("capture", {"format":"auto","width":0,"height":0,"fps":0})
        c.setdefault("live", {"url":"","audio":True})
        c.setdefault("timelapse", {"enable": False, "interval": 5})
        c.setdefault("motion", {
            "enable": False, "sensitivity": 50, "min_area_pct": 3,
            "action": "photo", "overlay": True, "cooldown": 10, "clip_len": 30
        })
        return json.loads(json.dumps(c))

def set_cam_cfg(dev, updates: dict):
    dev = str(dev)
    with CFG_LOCK:
        c = CFG.setdefault("cameras", {}).setdefault(dev, {})
        for k, v in (updates or {}).items():
            if k in ("timelapse", "motion", "capture", "live") and isinstance(v, dict):
                tgt = c.setdefault(k, {})
                tgt.update(v)
            else:
                c[k] = v
    _cfg_save()

def set_ui_cfg(updates: dict):
    with CFG_LOCK:
        CFG.setdefault("ui", {}).update(updates or {})
    _cfg_save()

def set_evo_cfg(updates: dict):
    with CFG_LOCK:
        evo = CFG.setdefault("evo", {})
        if "enable" in updates: evo["enable"] = bool(updates["enable"])
        if "phones" in updates:
            ph = updates["phones"]
            if isinstance(ph, str):
                arr = re.split(r"[\n,;]+", ph)
                evo["phones"] = [p.strip() for p in arr if p.strip()]
            elif isinstance(ph, (list, tuple)):
                evo["phones"] = [str(p).strip() for p in ph if str(p).strip()]
        if "base" in updates: evo["base"] = str(updates["base"]).strip().rstrip("/")
    _cfg_save()

def sanitize_dev(dev: str) -> str:
    return re.sub(r"[^0-9A-Za-z_\-\.]", "_", str(dev))

# === EVO: Fila/envio assíncrono
class EvoSender:
    def __init__(self):
        self.q = []
        self.lock = threading.Lock()
        self.evt = threading.Event()
        self.th = threading.Thread(target=self._loop, daemon=True)
        self.th.start()

    def queue(self, kind: str, file_path: str, dev: str, when_ts: float=None):
        task = {"kind": kind, "file_path": file_path, "dev": str(dev), "ts": when_ts or time.time()}
        with self.lock:
            self.q.append(task)
            self.evt.set()

    def _cfg_evo(self):
        with CFG_LOCK:
            evo = (CFG.get("evo") or {})
            enabled = bool(evo.get("enable"))
            phones  = evo.get("phones") or []
            base    = (evo.get("base") or "").strip()
        return enabled, [str(p).strip() for p in phones if str(p).strip()], base

    def _build_abs_url(self, rel_url: str, base: str):
        base = (base or "").strip()
        if not base:
            return None
        rel = rel_url[1:] if rel_url.startswith("/") else rel_url
        return f"{base.rstrip('/')}/{rel}"

    def _send_text(self, phone: str, text: str):
        try:
            endpoint = f"{EVO_API_URL}/message/sendText/{EVO_API_INSTANCE}"
            headers = {"apikey": EVO_API_KEY, "Content-Type": "application/json"}
            payload = {"number": phone, "text": text}
            r = requests.post(endpoint, headers=headers, json=payload, timeout=20)
            return r.status_code, r.text
        except Exception as e:
            return 599, str(e)

    def _loop(self):
        while True:
            self.evt.wait(1.0)
            while True:
                with self.lock:
                    if not self.q:
                        self.evt.clear()
                        break
                    task = self.q.pop(0)
                try:
                    self._send_task(task)
                except Exception as e:
                    print("[EVO] erro no envio:", e)

    def _send_via_url(self, media_type: str, media_url: str, caption: str, phones: list):
        endpoint = f"{EVO_API_URL}/message/{media_type}/{EVO_API_INSTANCE}"
        headers = {"apikey": EVO_API_KEY, "Content-Type": "application/json"}
        for phone in phones:
            body = {"number": phone, "url": media_url, "caption": caption}
            try:
                r = requests.post(endpoint, headers=headers, json=body, timeout=20)
                if r.status_code >= 300:
                    print(f"[EVO] Falha URL {phone}: {r.status_code} {r.text[:200]}")
                else:
                    print(f"[EVO] OK URL → {phone}")
            except Exception as e:
                print(f"[EVO] Erro URL {phone}: {e}")

    def _send_via_base64(self, media_type: str, file_path: str, caption: str, phones: list):
        endpoint = f"{EVO_API_URL}/message/sendMedia/{EVO_API_INSTANCE}"
        headers = {"apikey": EVO_API_KEY, "Content-Type": "application/json"}
        mime, _ = mimetypes.guess_type(file_path)
        if not mime:
            mime = "image/jpeg" if media_type == "image" else "video/mp4"
        try:
            sz = os.path.getsize(file_path)
            if media_type == "video" and sz > 15*1024*1024:
                print("[EVO] Aviso: vídeo >15MB via Base64 pode falhar; prefira configurar Base URL pública.")
        except Exception:
            pass
        try:
            with open(file_path, "rb") as f:
                b64 = base64.b64encode(f.read()).decode("ascii")
        except Exception as e:
            print("[EVO] Erro lendo arquivo para Base64:", e)
            return
        for phone in phones:
            payload = {
                "number": phone, "mediatype": media_type, "mimetype": mime,
                "caption": caption or "", "media": b64,
                "fileName": os.path.basename(file_path), "delay": 0
            }
            try:
                r = requests.post(endpoint, headers=headers, json=payload, timeout=60)
                if r.status_code >= 300:
                    print(f"[EVO] Falha B64 {phone}: {r.status_code} {r.text[:200]}")
                else:
                    print(f"[EVO] OK B64 → {phone}")
            except Exception as e:
                print(f"[EVO] Erro B64 {phone}: {e}")

    def _send_task(self, task):
        kind = task["kind"]
        file_path = task["file_path"]
        dev = task["dev"]
        ts = datetime.fromtimestamp(task["ts"]).strftime("%d/%m/%Y %H:%M:%S")

        enabled, phones, base = self._cfg_evo()
        if not enabled or not phones:
            return
        ccfg = get_cam_cfg(dev)
        cam_name = ccfg.get("name", dev)
        caption = f"🎯 Movimento na câmera {cam_name}\n⏱ {ts}"

        fname = os.path.basename(file_path)
        if kind == "photo":
            rel = f"/media/photos/{fname}"
            media_type = "image"
        else:
            rel = f"/media/videos/{fname}"
            media_type = "video"

        media_url = self._build_abs_url(rel, base)
        if media_url:
            self._send_via_url(media_type, media_url, caption, phones)
        else:
            self._send_via_base64(media_type, file_path, caption, phones)

EVO_SENDER = EvoSender()

# ----------------- HTML -----------------
HTML = """<!doctype html>
<html lang="pt-br"><head><meta charset="utf-8">
<title>MirakoMultiCam</title><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="x-basepath" content="{{ basepath|e }}">
<style>
:root{
  --bg:#0f0f0f; --fg:#eee; --card:#181818; --line:#2a2a2a;
  --tile:320px; --radius:14px; --btn:#2a2a2a; --btn-hover:#333; --input:#202020;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font-family:system-ui,Segoe UI,Arial}
header{padding:10px 14px;border-bottom:1px solid var(--line);position:sticky;top:0;background:#121212;z-index:2}
main{display:grid;grid-template-columns:300px 1fr;gap:16px;padding:16px}
@media(max-width:1000px){main{grid-template-columns:1fr}}
.panel,.card{background:var(--card);border:1px solid var(--line);border-radius:var(--radius);padding:12px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(var(--tile),1fr));gap:10px}
.stream{background:#000;border-radius:var(--radius);overflow:hidden;border:1px solid var(--line)}
.stream header{display:flex;justify-content:space-between;align-items:center;background:#141414;padding:6px 8px}
.stream img{width:100%;display:block;border-bottom-left-radius:var(--radius);border-bottom-right-radius:var(--radius)}
button,select,input,textarea{
  background:var(--btn); color:var(--fg); border:1px solid var(--line); padding:8px 10px; border-radius:12px;
}
button{cursor:pointer} button:hover{background:var(--btn-hover)}
select, input, textarea{background:var(--input)}
.thumb{display:flex;gap:8px;align-items:center}
.thumb img{width:96px;height:64px;object-fit:cover;border-radius:10px;border:1px solid var(--line)}
.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
small.muted{color:#aaa}
.cam-block{border:1px solid var(--line); border-radius:var(--radius); padding:10px; margin-bottom:14px; background:#151515}
.cam-block h4{margin:4px 0 10px 0}
.cam-section{margin-top:10px}
.cam-items.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:10px}
.cam-items.list{display:block}
.cam-items.list .thumb{padding:8px 0;border-bottom:1px solid var(--line)}
.cam-items.grid .thumb{position:relative; display:block;border:1px solid var(--line);border-radius:12px;overflow:hidden; background:#111}
.cam-items.grid .thumb img{width:100%;height:auto;display:block}
.cam-items.grid .thumb div{padding:8px}
.selbox{position:absolute;top:6px;left:6px;background:#0009;border:1px solid var(--line);padding:4px 6px;border-radius:10px}
.selcount{margin-left:8px;color:#aaa}
.badge{background:#1f2937; padding:4px 8px; border-radius:10px; color:#cbd5e1}
audio.vvAudio{height:28px; vertical-align:middle}
</style>
</head>
<body>
<header><strong>MirakoMultiCam</strong> <small id="status"></small></header>
<main>
  <section class="panel">
    <h3>Câmeras</h3>
    <div id="devs" class="row"></div>
    <div class="row" style="margin-top:8px">
      <button id="refresh">↻ Atualizar</button>
      <small class="muted">Marque para abrir o preview</small>
    </div>

    <h3 style="margin-top:12px">Layout</h3>
    <div class="row">
      <label>Tamanho do preview</label>
      <select id="previewSize">
        <option value="small">Pequeno</option>
        <option value="medium" selected>Médio</option>
        <option value="large">Grande</option>
        <option value="xlarge">Muito grande</option>
        <option value="xxlarge">Muito MUITO grande</option>
      </select>
      <button id="applyUi">Aplicar</button>
    </div>

    <h3 style="margin-top:16px">Evolution API (WhatsApp)</h3>
    <div class="row">
      <label><input id="evoEnable" type="checkbox"> Motion ZAP</label>
    </div>
    <textarea id="evoPhones" rows="4" placeholder="+5599999999999
+5581999999999"></textarea>
<div class="row" style="margin-top:8px;gap:6px;flex-wrap:wrap">
  <button id="evoSave">Salvar Evolution</button>
  <button id="evoTest">Enviar teste (foto atual)</button>
  <button id="evoTestVideo">Enviar teste (vídeo)</button>
  <small class="badge">Instância: {{evo_instance}}</small>
</div>

    <h3 style="margin-top:12px">Biblioteca</h3>
    <div class="row">
      <label>Visualização</label>
      <select id="libMode">
        <option value="grid">Grid</option>
        <option value="list">Lista</option>
      </select>
      <label>De</label><input type="date" id="dateFrom">
      <label>Até</label><input type="date" id="dateTo">
      <button id="applyLib">Aplicar</button>
    </div>
    <div class="row" style="margin-top:8px">
      <button id="selAll">Selecionar tudo</button>
      <button id="selNone">Limpar</button>
      <button id="delSel">Apagar selecionados</button>
      <span class="selcount" id="selCount">0 selecionado(s)</span>
    </div>
  </section>

  <section style="display:grid;gap:16px">
    <div class="card">
      <h3>Pré-visualizações</h3>
      <div id="streams" class="grid"></div>
    </div>
    <div class="card">
      <h3>Biblioteca</h3>
      <div class="row">
        <button onclick="loadMedia()">Atualizar</button>
      </div>
      <div id="libWrap"><!-- blocos por câmera --></div>
    </div>
  </section>
</main>

<script>
// Helpers
function _basepath(){
  const m = document.querySelector('meta[name="x-basepath"]');
  const b = (m && m.content) ? m.content : "";
  return (b || "").replace(/\/+$/,'');
}
function url(p){
  p = String(p||'');
  if(/^https?:\/\//i.test(p)) return p;
  p = p.replace(/^\/+/, '');
  const b = _basepath();
  return (b ? (b + '/') : '/') + p;
}
function jfetch(p, init){ return fetch(url(p), init); }
window.addEventListener('error', (e)=>{
  try { console.error('JS Error:', e.message, e.error); } catch(_) {}
  const msg = 'Erro JS: ' + (e.message || 'desconhecido');
  const el = document.querySelector('#status');
  if (el) { el.textContent = ' ' + msg; setTimeout(()=>{ el.textContent=''; }, 5000); }
});
const $ = s => document.querySelector(s);
function setStatus(t){ $('#status').textContent = ' '+t; setTimeout(()=>$('#status').textContent='', 3000); }
const sanitize = dev => dev.replaceAll('/','_');

// seleção de câmeras
const selected = new Set();
async function persistSelected(){
  const arr = [...selected];
  localStorage.setItem('selectedDevs', JSON.stringify(arr));
  try{
    await jfetch('api/config', {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify({ ui: { selected_devs: arr } })
    });
  }catch(e){}
}
function applySelectedFromConfig(){
  const fromServer = GLOBAL_CFG?.ui?.selected_devs;
  const fromLocal  = JSON.parse(localStorage.getItem('selectedDevs') || '[]');
  const src = Array.isArray(fromServer) ? fromServer : fromLocal;
  selected.clear();
  src.forEach(d => selected.add(d));
}

let AUDIO_OPTIONS = [];
let GLOBAL_CFG = null;

// Biblioteca seleção
const SEL = new Set();
function selKey(kind, name){ return kind+'|'+name; }
function updateSelCount(){ $('#selCount').textContent = SEL.size + ' selecionado(s)'; }
$('#selAll').onclick = ()=>{ document.querySelectorAll('[data-kind][data-name]').forEach(e=>{ e.checked=true; SEL.add(selKey(e.dataset.kind, e.dataset.name)); }); updateSelCount(); };
$('#selNone').onclick = ()=>{ document.querySelectorAll('[data-kind][data-name]').forEach(e=>{ e.checked=false; }); SEL.clear(); updateSelCount(); };
$('#delSel').onclick = async ()=>{
  if(SEL.size===0){ setStatus('Nada selecionado'); return; }
  if(!confirm('Apagar definitivamente '+SEL.size+' item(ns)?')) return;
  const items = [...SEL].map(k=>{ const [kind,name]=k.split('|'); return {kind,name}; });
  const r = await jfetch('api/media/delete', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({items})});
  const j = await r.json();
  if(j.ok){ setStatus('Apagados: '+j.deleted); SEL.clear(); updateSelCount(); loadMedia(); }
  else setStatus('Erro: '+(j.error||''));
};

function micOptionsHtml(selected){
  const opts = (AUDIO_OPTIONS.length? AUDIO_OPTIONS : ["default","none"]);
  return opts.map(v=>{
    const sel = (v===selected) ? ' selected' : '';
    return `<option value="${v}"${sel}>${v}</option>`;
  }).join("");
}
function applyPreviewSize(sz){
  let px = 320;
  if(sz==='small') px = 260;
  if(sz==='large') px = 480;
  if(sz==='xlarge') px = 720;
  if(sz==='xxlarge') px = 1100;
  document.documentElement.style.setProperty('--tile', px+'px');
}
function libMode(){ return $('#libMode').value === 'list' ? 'list' : 'grid'; }

// Dispositivos
async function listDevices(){
  const j = await (await jfetch('api/devices', {cache:'no-store'})).json();
  const wrap = $('#devs'); 
  wrap.innerHTML = '';

  const devs   = j.devices || [];
  const actives = j.active || [];
  const serverSelected = j.selected || [];

  if (devs.length === 0) {
    wrap.innerHTML = '<small>Nenhuma câmera.</small>';
    return;
  }

  if (selected.size === 0 && Array.isArray(serverSelected) && serverSelected.length) {
    serverSelected.forEach(d => selected.add(String(d)));
  }

  const CBYDEV = {};
  devs.forEach(dev => {
    const row = document.createElement('label');
    row.className = 'row';
    row.style.gap = '6px';

    const cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.setAttribute('data-dev', dev);
    cb.checked = selected.has(dev);

    cb.onchange = (e) => {
      if (e.target.checked) {
        selected.add(dev);
        addStream(dev);
      } else {
        selected.delete(dev);
        removeStream(dev);
      }
      persistSelected();
    };

    const span = document.createElement('span');
    span.textContent = dev;

    row.appendChild(cb);
    row.appendChild(span);
    wrap.appendChild(row);

    CBYDEV[dev] = cb;

    if (cb.checked) addStream(dev);
  });

  if (selected.size === 0) {
    const prefer = (actives && actives.length) ? actives : devs;
    prefer.forEach(dev => {
      selected.add(dev);
      if (CBYDEV[dev]) CBYDEV[dev].checked = true;
      addStream(dev);
    });
    persistSelected();
  } else {
    [...selected].forEach(dev => {
      if (CBYDEV[dev]) CBYDEV[dev].checked = true;
    });
  }
}
$('#refresh').onclick = listDevices;

// helpers Viva-voz
function startVivaVoz(dev, controls){
  const mic = controls.querySelector('.micSel')?.value || 'default';
  if(!mic || mic.toLowerCase()==='none'){ setStatus('Sem microfone para viva-voz'); return; }
  const a = controls.querySelector('.vvAudio');
  a.src = url('audio/live?dev='+encodeURIComponent(dev)+'&mic='+encodeURIComponent(mic)+'&r='+Date.now());
  a.style.display='inline-block';
  a.play().catch(()=>{});
}
function stopVivaVoz(controls){
  const a = controls.querySelector('.vvAudio');
  if(a){
    try{ a.pause(); }catch(_){}
    a.removeAttribute('src');
    a.load();
    a.style.display='none';
  }
}

// Pré-visualizações
function addStream(dev){
  const id = 'stream-'+sanitize(dev);
  if(document.getElementById(id)) return;

  const ccfg   = (GLOBAL_CFG && GLOBAL_CFG.cameras && GLOBAL_CFG.cameras[dev]) || {};
  const micSelVal = ccfg.mic || 'default';
  const rotVal = parseInt(ccfg.rotate || 0, 10);
  const capCfg = ccfg.capture || {format:'auto', width:0, height:0, fps:0};

  const liveCfg = ccfg.live || {};
  const liveUrl = liveCfg.url || '';
  const liveAud = (typeof liveCfg.audio === 'undefined') ? true : !!liveCfg.audio;

  const tlCfg  = (ccfg.timelapse || {});
  const tlOn   = !!tlCfg.enable;
  const tlInt  = tlCfg.interval || 5;

  const mdCfg  = (ccfg.motion || {});
  const mdOn   = !!mdCfg.enable;
  const mdSens = mdCfg.sensitivity || 50;
  const mdAct  = mdCfg.action || 'photo';
  const mdOv   = (mdCfg.overlay!==false);
  const mdCd   = mdCfg.cooldown || 10;
  const mdLen  = mdCfg.clip_len || 30;

  const box = document.createElement('div');
  box.className = 'stream';
  box.id = id;

  const h = document.createElement('header');
  h.innerHTML = `<span>${dev}</span>
    <span class="row">
      <button onclick="photo('${dev}')">📷 Foto</button>
      <button onclick="recStart('${dev}')">⏺️ Gravar</button>
      <button onclick="recStop('${dev}')">⏹️ Parar</button>
    </span>`;

  const controls = document.createElement('div');
  controls.className = 'row';
  controls.style.padding = '6px 8px';
  controls.innerHTML = `
    <label>Mic</label>
    <select class="micSel">${micOptionsHtml(micSelVal)}</select>

    <label>Girar</label>
    <select class="rotSel">
      <option value="0"   ${rotVal===0?'selected':''}>0°</option>
      <option value="90"  ${rotVal===90?'selected':''}>90°</option>
      <option value="180" ${rotVal===180?'selected':''}>180°</option>
      <option value="270" ${rotVal===270?'selected':''}>270°</option>
    </select>

    <!-- Viva-voz -->
    <label><input type="checkbox" class="vvToggle"> Viva-voz</label>
    <audio class="vvAudio vv-${sanitize(dev)}" controls style="display:none"></audio>

    <!-- Live RTMP -->
    <label>Live RTMP</label>
    <input class="liveUrl" type="text" placeholder="rtmp(s)://.../live2/CHAVE" style="min-width:340px">
    <label><input type="checkbox" class="liveAudio"${liveAud?' checked':''}> Áudio no live</label>
    <button class="liveStart">Iniciar Live</button>
    <button class="liveStop">Parar Live</button>

    <!-- Vídeo -->
    <label>Formato</label>
    <select class="fmtSel">
      <option value="auto"${(capCfg.format||'auto').toLowerCase()==='auto'?' selected':''}>Auto</option>
    </select>

    <label>Resolução</label>
    <select class="resSel">
      <option value="0x0"${(capCfg.width||0)===0?' selected':''}>Auto</option>
    </select>

    <label>FPS</label>
    <select class="fpsSel">
      <option value="0"${(capCfg.fps||0)===0?' selected':''}>Auto</option>
    </select>

    <label><input type="checkbox" class="tlToggle"${tlOn?' checked':''}> Timelapse</label>
    <input type="number" class="tlInt" min="1" value="${tlInt}" style="width:90px">

    <label><input type="checkbox" class="mdToggle"${mdOn?' checked':''}> Movimento</label>
    <label>Sens</label>
    <input type="range" class="mdSens" min="1" max="100" value="${mdSens}" style="width:140px">

    <label>Ação</label>
    <select class="mdAction">
      <option value="photo"${mdAct==='photo'?' selected':''}>Foto</option>
      <option value="video"${mdAct==='video'?' selected':''}>Vídeo</option>
    </select>

    <label>Cooldown (s)</label>
    <input type="number" class="mdCooldown" min="0" value="${mdCd}" style="width:80px">

    <label>Clip (s)</label>
    <input type="number" class="mdClip" min="5" value="${mdLen}" style="width:80px">

    <label><input type="checkbox" class="mdOverlay"${mdOv?' checked':''}> Overlays</label>

    <button class="applyCam">Aplicar</button>
  `;

  // preencher valores Live & VV
  controls.querySelector('.liveUrl').value = liveUrl;
  const vvToggle = controls.querySelector('.vvToggle');
  const micSelect = controls.querySelector('.micSel');

  // desabilita viva-voz se mic == none
  const updateVVEnabled = ()=>{
    const v = (micSelect.value||'').toLowerCase();
    vvToggle.disabled = (v==='none');
    if (vvToggle.disabled && vvToggle.checked){
      vvToggle.checked = false;
      stopVivaVoz(controls);
    }
  };
  updateVVEnabled();

  vvToggle.onchange = (e)=>{
    if(e.target.checked) startVivaVoz(dev, controls);
    else stopVivaVoz(controls);
  };

  // autosave nos controles
  ['.micSel','.rotSel','.fmtSel','.resSel','.fpsSel','.tlToggle','.tlInt','.mdToggle','.mdSens','.mdAction','.mdCooldown','.mdClip','.mdOverlay','.liveUrl','.liveAudio']
  .forEach(sel=>{
    const el = controls.querySelector(sel);
    if(el){
      el.addEventListener('change', ()=> { autosaveCam(dev, controls); if (sel==='.micSel' && vvToggle.checked){ stopVivaVoz(controls); startVivaVoz(dev, controls); } updateVVEnabled(); });
      el.addEventListener('input',  ()=> autosaveCam(dev, controls));
    }
  });

  // botões live
  controls.querySelector('.liveStart').onclick = async ()=>{
    try{
      const urlLive = controls.querySelector('.liveUrl').value.trim();
      const withAud = !!controls.querySelector('.liveAudio').checked;
      if(!urlLive){ setStatus('Informe a URL RTMP'); return; }
      const r = await jfetch('api/live/start', {
        method:'POST', headers:{'Content-Type':'application/json'},
        body: JSON.stringify({dev, url: urlLive, audio: withAud})
      });
      const j = await r.json();
      setStatus(j.ok ? 'Live iniciado' : ('Erro Live: '+(j.error||'')));
    }catch(e){ setStatus('Erro JS: '+e); }
  };
  controls.querySelector('.liveStop').onclick = async ()=>{
    try{
      const r = await jfetch('api/live/stop', {
        method:'POST', headers:{'Content-Type':'application/json'},
        body: JSON.stringify({dev})
      });
      const j = await r.json();
      setStatus(j.ok ? 'Live parado' : ('Erro Live: '+(j.error||'')));
    }catch(e){ setStatus('Erro JS: '+e); }
  };

  const img = document.createElement('img');
  img.src = url('video_feed?dev='+encodeURIComponent(dev)+'&r='+Date.now());

  box.appendChild(h);
  box.appendChild(controls);
  box.appendChild(img);
  $('#streams').appendChild(box);

  // Preencher selects de captura com capacidades reais
  populateCaptureSelectors(dev, controls);

  // Aplicar botão principal
  controls.querySelector('.applyCam').onclick = async ()=>{
    const btn = controls.querySelector('.applyCam');
    btn.disabled = true;
    btn.textContent = 'Aplicando...';
    try{
      const p = gatherCamConfig(dev, controls);

      // 1) Salva config
      const r = await jfetch('api/config', {
        method:'POST',
        headers:{'Content-Type':'application/json'},
        body: JSON.stringify({
          dev: p.dev, mic: p.mic,
          rotate: p.rot,
          capture: { format: p.fmt, width: p.w, height: p.h, fps: p.fps },
          live: { url: p.liveUrl, audio: p.liveAud },
          timelapse:{enable: p.tlE, interval: p.tlI},
          motion:{enable: p.mdE, sensitivity: p.mdS, action: p.mdA, overlay: p.mdO, cooldown: p.mdC, clip_len: p.mdL}
        })
      });
      const j = await r.json();
      if(!j.ok){ throw new Error(j.error || 'falha ao salvar'); }

      // 2) Reinicia a câmera
      const r2 = await jfetch('api/cam/restart', {
        method:'POST',
        headers:{'Content-Type':'application/json'},
        body: JSON.stringify({dev: p.dev})
      });
      const j2 = await r2.json();
      if(!j2.ok){ throw new Error(j2.error || 'falha no restart'); }

      await new Promise(res=>setTimeout(res, 350));
      await loadConfig();

      removeStream(dev);
      setTimeout(()=>addStream(dev), 150);

      setStatus('Config aplicada');
    }catch(err){
      console.error('applyCam error', err);
      setStatus('Erro ao aplicar: '+ (err?.message || err));
    }finally{
      btn.disabled = false;
      btn.textContent = 'Aplicar';
    }
  };
}

async function populateCaptureSelectors(dev, controls){
  const fmtSel = controls.querySelector('.fmtSel');
  const resSel = controls.querySelector('.resSel');
  const fpsSel = controls.querySelector('.fpsSel');

  const ccfg = (GLOBAL_CFG && GLOBAL_CFG.cameras && GLOBAL_CFG.cameras[dev]) || {};
  const cap  = ccfg.capture || {format:'auto', width:0, height:0, fps:0};
  let curFmt = (cap.format || 'auto').toLowerCase();
  let curWH  = (cap.width>0 && cap.height>0) ? (cap.width+'x'+cap.height) : '0x0';
  let curFPS = parseInt(cap.fps||0,10) || 0;

  let caps = {formats:[]};
  try{
    const r = await jfetch('api/caps?dev='+encodeURIComponent(dev), {cache:'no-store'});
    const j = await r.json();
    if (j.ok) caps = j;
  }catch(e){}

  fmtSel.innerHTML = `<option value="auto"${curFmt==='auto'?' selected':''}>Auto</option>`;
  const prio = {'MJPG':0,'YUYV':1};
  const fmts = (caps.formats||[]).slice().sort((a,b)=>(prio[a.fourcc]??9)-(prio[b.fourcc]??9));
  fmts.forEach(f=>{
    const val = (f.fourcc||'').toLowerCase();
    const sel = (val===curFmt)?' selected':'';
    fmtSel.insertAdjacentHTML('beforeend', `<option value="${val}"${sel}>${f.fourcc}</option>`);
  });

  function rebuildFPS(){
    const pickFmt = fmtSel.value.toUpperCase();
    const pickWH  = resSel.value;
    fpsSel.innerHTML = `<option value="0"${(curFPS===0)?' selected':''}>Auto</option>`;
    const f = (caps.formats||[]).find(F=>F.fourcc===pickFmt);
    const s = f && pickWH!=='0x0' ? (f.sizes||[]).find(S=>`${S.w}x${S.h}`===pickWH) : null;
    const fpsList = (s && s.fps && s.fps.length) ? s.fps.slice().sort((a,b)=>b-a) : [30,15];
    fpsList.forEach(v=>{
      const sel = (v===curFPS)?' selected':'';
      fpsSel.insertAdjacentHTML('beforeend', `<option value="${v}"${sel}>${v} fps</option>`);
    });
  }

  function rebuildRes(){
    const pickFmt = fmtSel.value.toUpperCase();
    resSel.innerHTML = `<option value="0x0"${curWH==='0x0'?' selected':''}>Auto</option>`;
    const f = (caps.formats||[]).find(F=>F.fourcc===pickFmt);
    const sizes = f ? (f.sizes||[]) : [];
    sizes.sort((a,b)=>(b.w*b.h)-(a.w*a.h));
    sizes.forEach(s=>{
      const wh = `${s.w}x${s.h}`;
      const sel = (wh===curWH)?' selected':'';
      resSel.insertAdjacentHTML('beforeend', `<option value="${wh}"${sel}>${wh}</option>`);
    });
    rebuildFPS();
  }

  fmtSel.onchange = ()=>{ curFmt = fmtSel.value; rebuildRes(); autosaveCam(dev, controls); };
  resSel.onchange = ()=>{ curWH = resSel.value; rebuildFPS(); autosaveCam(dev, controls); };
  fpsSel.onchange = ()=>{ curFPS = parseInt(fpsSel.value,10)||0; autosaveCam(dev, controls); };

  rebuildRes();
}

function removeStream(dev){
  const id = 'stream-'+sanitize(dev);
  const el = document.getElementById(id);
  if(el){
    try{
      const a = el.querySelector('.vvAudio');
      if(a){ a.pause(); a.removeAttribute('src'); a.load(); }
    }catch(_){}
    el.remove();
  }
}

// Ações fotos/vídeos
async function photo(dev){
  try{
    const r = await jfetch('api/photo', {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify({dev})
    });
    const j = await r.json();
    setStatus(j.ok?('Foto: '+j.file):('Erro: '+j.error));
    loadMedia();
  }catch(err){
    console.error('photo error', err);
    setStatus('Erro JS em Foto: '+err);
  }
}
async function recStart(dev){
  try{
    setStatus('Iniciando gravação…');
    const card = document.getElementById('stream-'+sanitize(dev));
    const micEl = card ? card.querySelector('.micSel') : null;
    const mic = (micEl && typeof micEl.value === 'string')
      ? micEl.value.trim()
      : ((GLOBAL_CFG && GLOBAL_CFG.cameras && GLOBAL_CFG.cameras[dev] && GLOBAL_CFG.cameras[dev].mic) || 'default');

    const r = await jfetch('api/record/start', {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify({dev, mic})
    });
    const j = await r.json();
    setStatus(j.ok?('Gravando: '+j.file):('Erro: '+j.error));
    loadMedia();
  }catch(err){
    console.error('recStart error', err);
    setStatus('Erro JS em Gravar: '+err);
  }
}
async function recStop(dev){
  try{
    const r = await jfetch('api/record/stop', {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify({dev})
    });
    const j = await r.json();
    setStatus(j.ok?('Salvo: '+j.file):('Erro: '+j.error));
    loadMedia();
  }catch(err){
    console.error('recStop error', err);
    setStatus('Erro JS em Parar: '+err);
  }
}

// Biblioteca
function buildMediaQuery(){
  const df = $('#dateFrom').value;
  const dt = $('#dateTo').value;
  const p = new URLSearchParams();
  if(df) p.set('start', df);
  if(dt) p.set('end', dt);
  return 'api/media?'+p.toString();
}
async function loadMedia(){
  const j = await (await jfetch(buildMediaQuery(),{cache:'no-store'})).json();
  const wrap = $('#libWrap'); wrap.innerHTML = '';
  const mode = libMode();

  const cams = j.cameras || [];
  if(cams.length===0){
    wrap.innerHTML = '<small class="muted">Sem arquivos.</small>';
    return;
  }

  cams.forEach(cam=>{
    const blk = document.createElement('div');
    blk.className = 'cam-block';

    const h = document.createElement('h4');
    h.textContent = 'Câmera: '+cam;
    blk.appendChild(h);

    function section(title, arr, kind){
      if(!arr || !arr.length) return;
      const sec = document.createElement('div');
      sec.className = 'cam-section';
      sec.innerHTML = '<div><strong>'+title+'</strong></div>';
      const list = document.createElement('div');
      list.className = 'cam-items '+mode;

      arr.forEach(it=>{
        const d = document.createElement('div');
        d.className = 'thumb';

        const ck = document.createElement('input');
        ck.type = 'checkbox';
        ck.className = 'selbox';
        ck.dataset.kind = kind;
        ck.dataset.name = it.name;

        ck.addEventListener('change', ()=>{
          const key = selKey(kind, it.name);
          if (ck.checked) SEL.add(key); else SEL.delete(key);
          updateSelCount();
        });

        const img = document.createElement('img');
        img.src = url(it.thumb);

        const info = document.createElement('div');
        const titleEl = document.createElement('div');
        titleEl.textContent = it.name;
        const linkWrap = document.createElement('div');
        const a = document.createElement('a');
        a.href = url(it.url);
        a.target = '_blank';
        a.textContent = 'abrir';
        linkWrap.appendChild(a);
        info.appendChild(titleEl);
        info.appendChild(linkWrap);

        if (mode === 'grid') {
          const wrapSel = document.createElement('label');
          wrapSel.className = 'selbox';
          wrapSel.appendChild(ck);
          d.appendChild(wrapSel);
          d.appendChild(img);
          d.appendChild(info);
        } else {
          d.appendChild(ck);
          d.appendChild(img);
          d.appendChild(info);
        }

        d.addEventListener('click', (ev)=>{
          const tag = (ev.target.tagName || '').toLowerCase();
          if (tag === 'a' || tag === 'input') return;
          ck.checked = !ck.checked;
          ck.dispatchEvent(new Event('change'));
        });

        list.appendChild(d);
      });

      sec.appendChild(list);
      blk.appendChild(sec);
    }

    const bc = j.by_camera[cam] || {};
    section('Vídeos (manuais)',  bc.videos_user,   'videos');
    section('Vídeos (movimento)',bc.videos_motion, 'videos');
    section('Fotos (manuais)',   bc.photos_user,   'photos');
    section('Fotos (movimento)', bc.photos_motion, 'photos');
    section('Timelapse',         bc.timelapse,     'photos');

    wrap.appendChild(blk);
  });
}

// UI global
$('#applyUi').onclick = async ()=>{
  const sz = $('#previewSize').value;
  applyPreviewSize(sz);
  await jfetch('api/config', {method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify({ui:{preview_size: sz}})});
  setStatus('layout atualizado');
};
$('#applyLib').onclick = async ()=>{
  const mode = $('#libMode').value;
  await jfetch('api/config', {method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify({ui:{library_view: mode}})});
  loadMedia();
};

// Evolution UI
$('#evoSave').onclick = async ()=>{
  try{
    const enable = !!$('#evoEnable').checked;
    const phones = $('#evoPhones').value;

    const baseEl = document.getElementById('evoBase');
    const base = baseEl ? baseEl.value.trim() : '';

    const evoPayload = baseEl ? { enable, phones, base } : { enable, phones };

    const r = await jfetch('api/config', {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify({ evo: evoPayload })
    });
    const j = await r.json();
    setStatus(j.ok ? 'Evolution salvo' : ('Erro: '+(j.error||'')));
  }catch(e){
    console.error(e);
    setStatus('Erro JS: '+e);
  }
};
$('#evoTest').onclick = async ()=>{
  const r = await jfetch('api/evo/test', { method:'POST' });
  const j = await r.json();
  setStatus(j.ok? ('Teste enviado: '+j.kind+' '+j.name) : ('Erro teste: '+(j.error||'')));
};
$('#evoTestVideo').onclick = async ()=>{
  try{
    const r = await jfetch('api/evo/test_video', { method:'POST' });
    const j = await r.json();
    if (j.ok) setStatus('Teste de vídeo iniciado em '+ j.targets +' câmera(s). Vou enviar quando terminar.');
    else setStatus('Erro teste vídeo: '+ (j.error || ''));
  }catch(e){
    console.error('evoTestVideo', e);
    setStatus('Erro JS: '+e);
  }
};

function fillEvoUI(){
  const evo = GLOBAL_CFG?.evo || {};
  $('#evoEnable').checked = !!evo.enable;
  $('#evoPhones').value = (evo.phones||[]).join("\\n");
  const baseEl = document.getElementById('evoBase');
  if (baseEl) baseEl.value = evo.base || '';
}

// Init
function applyLibModeToSelect(){
  const mode = GLOBAL_CFG?.ui?.library_view || 'grid';
  $('#libMode').value = mode;
}
async function loadAudioOptions(){
  try{
    const j = await (await jfetch('api/audio',{cache:'no-store'})).json();
    AUDIO_OPTIONS = [...(j.pulse||[]), ...(j.alsa||[]), 'none'];
  }catch(e){
    AUDIO_OPTIONS = ['default','none'];
  }
}
async function loadConfig(){
  try{
    GLOBAL_CFG = await (await jfetch('api/config',{cache:'no-store'})).json();
    const sz = GLOBAL_CFG?.ui?.preview_size || 'medium';
    $('#previewSize').value = sz;
    applyPreviewSize(sz);
    applySelectedFromConfig();
    applyLibModeToSelect();
    fillEvoUI();
  }catch(e){}
}
async function init(){
  await loadAudioOptions();
  await loadConfig();
  await listDevices();
  loadMedia();
}
init();

// autosave/apply helpers
function gatherCamConfig(dev, controls){
  const mic = controls.querySelector('.micSel')?.value?.trim() || (GLOBAL_CFG?.cameras?.[dev]?.mic || 'default');
  const rot = parseInt(controls.querySelector('.rotSel')?.value,10) || 0;

  const fmt = (controls.querySelector('.fmtSel')?.value || 'auto').toUpperCase();
  const wh  = controls.querySelector('.resSel')?.value || '0x0';
  const fps = parseInt(controls.querySelector('.fpsSel')?.value,10) || 0;
  const [w,h] = wh.split('x').map(v=>parseInt(v,10)||0);

  const liveUrl = (controls.querySelector('.liveUrl')?.value || '').trim();
  const liveAud = !!controls.querySelector('.liveAudio')?.checked;

  const tlE = !!controls.querySelector('.tlToggle')?.checked;
  const tlI = parseInt(controls.querySelector('.tlInt')?.value,10)||5;

  const mdE = !!controls.querySelector('.mdToggle')?.checked;
  const mdS = parseInt(controls.querySelector('.mdSens')?.value,10)||50;
  const mdA = controls.querySelector('.mdAction')?.value || 'photo';
  const mdO = !!controls.querySelector('.mdOverlay')?.checked;
  const mdC = Math.max(0, parseInt(controls.querySelector('.mdCooldown')?.value,10)||0);
  const mdL = Math.max(5, parseInt(controls.querySelector('.mdClip')?.value,10)||30);
  return {dev, mic, rot, fmt, w, h, fps, liveUrl, liveAud, tlE, tlI, mdE, mdS, mdA, mdO, mdC, mdL};
}

let saveTimer = null;
async function autosaveCam(dev, controls){
  const p = gatherCamConfig(dev, controls);
  clearTimeout(saveTimer);
  saveTimer = setTimeout(async ()=>{
    try{
      const r = await jfetch('api/config', {
        method:'POST',
        headers:{'Content-Type':'application/json'},
        body: JSON.stringify({
          dev: p.dev, mic: p.mic,
          rotate: p.rot,
          capture: { format: p.fmt, width: p.w, height: p.h, fps: p.fps },
          live: { url: p.liveUrl, audio: p.liveAud },
          timelapse:{enable: p.tlE, interval: p.tlI},
          motion:{enable: p.mdE, sensitivity: p.mdS, action: p.mdA, overlay: p.mdO, cooldown: p.mdC, clip_len: p.mdL}
        })
      });
      const j = await r.json();
      if(!j.ok) setStatus('Erro ao salvar: '+(j.error||''));
    }catch(e){
      console.error('autosaveCam', e);
    }
  }, 350);
}
</script>

</body></html>
"""

# ----------------- Utils de mídia -----------------
def make_thumb_image(src, max_w=240):
    try:
        img = cv2.imread(src)
        if img is None: return None
        h, w = img.shape[:2]
        if w > max_w:
            s = max_w / float(w)
            img = cv2.resize(img, (int(w*s), int(h*s)), interpolation=cv2.INTER_AREA)
        name = os.path.basename(src)
        tname = name if name.lower().endswith(".jpg") else os.path.splitext(name)[0]+".jpg"
        tpath = os.path.join(MEDIA["thumbs"], tname)
        cv2.imwrite(tpath, img)
        return tpath
    except Exception:
        return None

def make_thumb_from_frame(frame, video_path):
    if frame is None: return
    name = os.path.splitext(os.path.basename(video_path))[0] + ".jpg"
    tpath = os.path.join(MEDIA["thumbs"], name)
    h, w = frame.shape[:2]
    if w > 240:
        s = 240/float(w)
        frame = cv2.resize(frame, (int(w*s), int(h*s)), interpolation=cv2.INTER_AREA)
    cv2.imwrite(tpath, frame)

def rotate_image(img, angle):
    if img is None: return img
    if angle == 90:
        return cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
    if angle == 180:
        return cv2.rotate(img, cv2.ROTATE_180)
    if angle == 270:
        return cv2.rotate(img, cv2.ROTATE_90_COUNTERCLOCKWISE)
    return img

# ----------------- Scanner de câmeras -----------------
def is_cam_active(dev) -> bool:
    try:
        sys = platform.system().lower()
        backend = cv2.CAP_V4L2 if 'linux' in sys else 0
        arg = int(dev) if str(dev).isdigit() else dev

        cap = cv2.VideoCapture(arg, backend)
        if not cap.isOpened():
            return False

        cap.set(cv2.CAP_PROP_FRAME_WIDTH,  640)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
        cap.set(cv2.CAP_PROP_FPS, 30)

        ok_any = False
        has_signal = False

        for _ in range(20):
            ok, frame = cap.read()
            if ok:
                ok_any = True
                if _frame_has_signal(frame):
                    has_signal = True
                    break
            time.sleep(0.05)

        cap.release()
        return ok_any and has_signal
    except Exception:
        return False

def detect_active_cams():
    devs = scan_linux_cams() if "linux" in platform.system().lower() else []
    return [d for d in devs if is_cam_active(d)]

def scan_linux_cams():
    devs = []
    for p in sorted(glob.glob("/dev/video*")):
        try:
            st = os.stat(p)
            if not stat.S_ISCHR(st.st_mode):
                continue
        except Exception:
            continue
        devs.append(p)
    return devs

# ----------------- Motion detector -----------------
class MotionDetector:
    def __init__(self):
        self.bg = None
        self.last_boxes = []
        self.lock = threading.Lock()

    def process(self, frame, sensitivity=50, min_area_pct=3):
        try:
            h, w = frame.shape[:2]
            new_w = 320 if w > 320 else w
            if w > new_w:
                scale = new_w / float(w)
                small = cv2.resize(frame, (new_w, int(h*scale)), interpolation=cv2.INTER_AREA)
            else:
                small = frame
            gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
            gray = cv2.GaussianBlur(gray, (9,9), 0)

            if self.bg is None:
                self.bg = gray.astype("float32")
                with self.lock:
                    self.last_boxes = []
                return []

            cv2.accumulateWeighted(gray, self.bg, 0.05)
            bg_u8 = cv2.convertScaleAbs(self.bg)
            delta = cv2.absdiff(bg_u8, gray)

            thr_val = max(5, int(90 - float(sensitivity)*0.8))
            _, th = cv2.threshold(delta, thr_val, 255, cv2.THRESH_BINARY)
            th = cv2.dilate(th, None, iterations=2)
            contours, _ = cv2.findContours(th, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

            total = th.shape[0]*th.shape[1]
            area = sum(cv2.contourArea(c) for c in contours)
            area_pct = (area/max(1,total))*100.0
            boxes=[]
            if area_pct >= float(min_area_pct):
                gh, gw = th.shape[:2]
                sx = frame.shape[1]/float(gw)
                sy = frame.shape[0]/float(gh)
                for c in contours:
                    x,y,w0,h0 = cv2.boundingRect(c)
                    X = int(x*sx); Y = int(y*sy)
                    W = int(w0*sx); H = int(h0*sy)
                    if W>0 and H>0:
                        boxes.append((X,Y,W,H))

            with self.lock:
                self.last_boxes = boxes[:]
            return boxes
        except Exception:
            return []

    def get_boxes(self):
        with self.lock:
            return self.last_boxes[:]

# ----------------- Recorder -----------------
def list_alsa_capture_devices():
    try:
        r = subprocess.run(["arecord","-l"], capture_output=True, text=True)
    except Exception:
        return []
    devs=[]; card=None
    for ln in (r.stdout or "").splitlines():
        mcard = re.search(r"card\s+(\d+):\s*([^\s,]+)", ln)
        if mcard: card = mcard.group(2)
        mdev  = re.search(r"device\s+(\d+):", ln)
        if card and mdev:
            d = mdev.group(1)
            devs += [f"hw:CARD={card},DEV={d}", f"plughw:CARD={card},DEV={d}"]
    try:
        r2 = subprocess.run(["arecord","-L"], capture_output=True, text=True)
        for ln in (r2.stdout or "").splitlines():
            s = ln.strip()
            if s.startswith(("default:CARD=","sysdefault:CARD=","front:CARD=")):
                devs.append(s)
    except Exception:
        pass
    out=[]; seen=set()
    for d in devs:
        if d not in seen:
            seen.add(d); out.append(d)
    return out

def list_pulse_sources():
    try:
        r = subprocess.run(["pactl","list","short","sources"], capture_output=True, text=True)
    except Exception:
        return []
    out=["pulse"]
    for ln in (r.stdout or "").splitlines():
        cols = ln.split("\t")
        if len(cols)>=2:
            out.append("pulse:"+cols[1])
    return out

def have_cmd(cmd):
    try:
        subprocess.run([cmd, "-version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception:
        return False

class Recorder:
    def __init__(self):
        self.proc_by_dev   = {}
        self.file_by_dev   = {}
        self.thread_by_dev = {}
        self.run_by_dev    = {}
        self.owner_by_dev  = {}
        self.stderr_buf    = {}
        self.lock = threading.Lock()

    def _stderr_tail(self, dev, limit=4000):
        try:
            buf = self.stderr_buf.get(dev, "")
            return buf[-limit:]
        except Exception:
            return ""

    def _spawn_stderr_drain(self, dev, proc):
        from collections import deque
        dq = deque(maxlen=4000)
        self.stderr_buf[dev] = ""
        def _drain():
            try:
                while True:
                    if proc.poll() is not None and not proc.stderr:
                        break
                    chunk = proc.stderr.readline()
                    if not chunk:
                        if proc.poll() is not None:
                            break
                        time.sleep(0.05)
                        continue
                    try:
                        s = chunk.decode("utf-8", "ignore")
                    except Exception:
                        s = repr(chunk)
                    dq.extend(s)
                    self.stderr_buf[dev] = "".join(dq)
            except Exception:
                pass
        th = threading.Thread(target=_drain, daemon=True)
        th.start()

    def _probe_cam_dims(self, cam):
        w = int(cam.cap.get(cv2.CAP_PROP_FRAME_WIDTH)  or 0)
        h = int(cam.cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
        fps = float(cam.cap.get(cv2.CAP_PROP_FPS) or 0) or 30.0
        if not w or not h:
            frm = None
            for _ in range(15):
                frm = cam.last_frame()
                if frm is not None: break
                time.sleep(0.1)
            if frm is None:
                return 1280, 720, fps
            h, w = frm.shape[:2]
        return int(w), int(h), float(fps)

    def _ffmpeg_cmd(self, w, h, fps, mic, out_path, audio_backend):
        # hardcodes para reduzir carga e evitar aceleração (dropa frames p/ acompanhar o áudio)
        OUT_W, OUT_H, OUT_FPS = 480, 270, 15
        VB, AB = 700, 48  # kbps
        IN_FPS = int(round(float(fps or 30.0)))

        base = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-fflags", "+genpts",

            # vídeo cru via stdin
            "-f", "rawvideo",
            "-pix_fmt", "bgr24",
            "-video_size", f"{w}x{h}",
            "-framerate", str(IN_FPS),
            "-i", "-",
        ]

        have_audio = (audio_backend is not None) and (audio_backend.lower() != "none")
        if have_audio:
            base += ["-f", audio_backend, "-thread_queue_size", "8192", "-i", mic]

        # força CFR e derruba frames para manter ritmo (sem tentar re-sincronizar complexo)
        vf = [
            f"scale={OUT_W}:{OUT_H}:flags=fast_bilinear",
            f"fps={OUT_FPS}:round=down"
        ]
        base += ["-vf", ",".join(vf), "-vsync", "1"]

        # streams
        base += ["-map", "0:v:0"]
        if have_audio:
            base += ["-map", "1:a:0"]
        else:
            base += ["-an"]

        # vídeo: x264 bem leve e constante
        gop = OUT_FPS * 2
        base += [
            "-c:v", "libx264",
            "-preset", "ultrafast",
            "-crf", "28",
            "-pix_fmt", "yuv420p",
            "-profile:v", "baseline", "-level", "3.1",
            "-g", str(gop), "-keyint_min", str(gop),
            "-bf", "0",
            "-maxrate", f"{VB}k", "-bufsize", f"{VB*2}k",
        ]

        # áudio simples (sem filtros de sync; vídeo que se ajusta por drop)
        if have_audio:
            base += [
                "-c:a", "aac",
                "-ar", "44100", "-ac", "1",
                "-b:a", f"{AB}k",
            ]

        # muxer mais previsível
        base += ["-max_muxing_queue_size", "1024", "-max_interleave_delta", "0"]
        if out_path.lower().endswith(".mp4"):
            base += ["-movflags", "+faststart"]

        base += [out_path]
        return base




    def _writer_loop(self, dev, cam, proc, fps):
        period = 1.0 / max(1.0, float(fps or 30.0))
        next_t = time.monotonic()
        last = None
        try:
            while self.run_by_dev.get(dev, False):
                if proc.poll() is not None:
                    break

                frm = cam.last_frame()
                if frm is not None:
                    last = frm

                if last is None:
                    # ainda sem frame algum: espera um tick e segue
                    time.sleep(period)
                    continue

                now = time.monotonic()
                if now < next_t:
                    time.sleep(next_t - now)

                try:
                    # repete o último frame se não chegou um novo no tick,
                    # preservando CFR e evitando aceleração
                    proc.stdin.write(last.tobytes())
                except (BrokenPipeError, ValueError, OSError):
                    break

                next_t += period
                # se ficou MUITO atrasado, apenas resincroniza o relógio, sem pular escrita
                if next_t < time.monotonic() - (period * 4):
                    next_t = time.monotonic()
        finally:
            try:
                if proc.stdin:
                    proc.stdin.flush()
                    proc.stdin.close()
            except Exception:
                pass



    def _start_ffmpeg(self, dev, w, h, fps, mic, out_path):
        if not have_cmd("ffmpeg"):
            raise RuntimeError("ffmpeg não encontrado. Instale o pacote ffmpeg.")
        mic = (mic or "").strip()
        if not mic or mic.lower() == "none":
            backends = [("none", mic)]
        elif mic.lower().startswith("pulse"):
            backends = [("pulse", mic), ("alsa", mic), ("none", mic)]
        else:
            backends = [("alsa", mic), ("none", mic)]

        tried = []
        p = None
        for backend, micname in backends:
            cmd = self._ffmpeg_cmd(w, h, fps, micname, out_path, backend)
            p = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                bufsize=0
            )
            self._spawn_stderr_drain(dev, p)
            time.sleep(0.6)
            if p.poll() is None:
                return p, backend
            tried.append(f"[{backend}] {self._stderr_tail(dev)}")

        raise RuntimeError("ffmpeg não iniciou.\n" + "\n".join(tried))

    def is_recording(self, dev):
        dev = str(dev)
        with self.lock:
            p = self.proc_by_dev.get(dev)
        return p is not None and (p.poll() is None)

    def start(self, dev, mic="default", owner="user"):
        dev = str(dev)
        cam = get_cam(dev)
        if self.is_recording(dev):
            with self.lock:
                return os.path.basename(self.file_by_dev.get(dev) or "")
        w, h, fps = self._probe_cam_dims(cam)
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        prefix = "video-user" if owner == "user" else "video-motion"
        out_path = os.path.join(MEDIA["videos"], f"{prefix}-{sanitize_dev(dev)}-{ts}.mp4")
        p, backend = self._start_ffmpeg(dev, w, h, fps, mic, out_path)
        with self.lock:
            self.proc_by_dev[dev] = p
            self.file_by_dev[dev] = out_path
            self.run_by_dev[dev]  = True
            self.owner_by_dev[dev]= owner
        th = threading.Thread(target=self._writer_loop, args=(dev, cam, p, fps), daemon=True)
        th.start()
        with self.lock:
            self.thread_by_dev[dev] = th
        if backend == "none":
            print(f"[Recorder] {dev}: gravando SEM ÁUDIO (fallback).")
        return os.path.basename(out_path)

    def stop(self, dev, owner=None, force=False):
        dev = str(dev)
        with self.lock:
            p  = self.proc_by_dev.get(dev)
            out = self.file_by_dev.get(dev)
            th = self.thread_by_dev.get(dev)
            cur_owner = self.owner_by_dev.get(dev)
            if (owner is not None) and (cur_owner is not None) and (cur_owner != owner) and (not force):
                raise RuntimeError(f"em uso por {cur_owner}")
            self.run_by_dev[dev] = False
        if not p:
            raise RuntimeError("não está gravando")
        if th:
            th.join(timeout=3.5)
        try:
            p.wait(timeout=6)
        except subprocess.TimeoutExpired:
            try:
                p.terminate(); p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
                try: p.wait(timeout=2)
                except Exception: pass
        with self.lock:
            self.proc_by_dev.pop(dev, None)
            self.thread_by_dev.pop(dev, None)
            self.run_by_dev.pop(dev, None)
            self.owner_by_dev.pop(dev, None)
        if out:
            for _ in range(15):
                if os.path.isfile(out) and os.path.getsize(out) > 0:
                    return os.path.basename(out)
                time.sleep(0.1)
        raise RuntimeError("gravação não gerou arquivo.")

REC = Recorder()

# ----------------- Live RTMP (stream ao YouTube etc.) -----------------
# ----------------- Live RTMP (stream ao YouTube etc.) -----------------
# ----------------- Live RTMP (stream leve p/ Orange Pi) -----------------
class LiveStreamer:
    def __init__(self):
        self.proc_by_dev = {}
        self.thread_by_dev = {}
        self.run_by_dev = {}
        self.stderr_buf = {}
        self.lock = threading.Lock()

    def _stderr_tail(self, dev, limit=4000):
        try:
            buf = self.stderr_buf.get(dev, "")
            return buf[-limit:]
        except Exception:
            return ""

    def _spawn_stderr_drain(self, dev, proc):
        from collections import deque
        dq = deque(maxlen=4000)
        self.stderr_buf[dev] = ""
        def _drain():
            try:
                while True:
                    if proc.poll() is not None and not proc.stderr:
                        break
                    chunk = proc.stderr.readline()
                    if not chunk:
                        if proc.poll() is not None:
                            break
                        time.sleep(0.05)
                        continue
                    try:
                        s = chunk.decode("utf-8", "ignore")
                    except Exception:
                        s = repr(chunk)
                    dq.extend(s)
                    self.stderr_buf[dev] = "".join(dq)
            except Exception:
                pass
        th = threading.Thread(target=_drain, daemon=True)
        th.start()

    def _probe_cam_dims(self, cam):
        w = int(cam.cap.get(cv2.CAP_PROP_FRAME_WIDTH)  or 0)
        h = int(cam.cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
        fps = float(cam.cap.get(cv2.CAP_PROP_FPS) or 0) or 30.0
        if not w or not h:
            frm = None
            for _ in range(15):
                frm = cam.last_frame()
                if frm is not None: break
                time.sleep(0.1)
            if frm is None:
                return 1280, 720, fps
            h, w = frm.shape[:2]
        return int(w), int(h), float(fps)

    def _ffmpeg_cmd(self, in_w, in_h, in_fps, mic, url, audio_backend,
                    *, out_w=None, out_h=None, out_fps=None, encoder="x264",
                    vbitrate=3500, abitrate=160, preset="veryfast",
                    latency="normal", denoise=False):
        # taxa efetiva de entrada e saída (CFR)
        eff_in_fps = float(in_fps or 30.0)
        out_fps_i = int(round(out_fps or eff_in_fps))
        out_fps_i = max(5, min(out_fps_i, 60))   # sanidade
        g = int(max(1, out_fps_i) * 2)           # GOP ~2s

        base = [
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            # Pacing e timestamps em tempo real
            "-re",
            "-fflags", "+genpts",
            "-use_wallclock_as_timestamps", "1",

            # Vídeo cru vindo do stdin
            "-f", "rawvideo",
            "-pix_fmt", "bgr24",
            "-video_size", f"{in_w}x{in_h}",
            "-framerate", str(int(round(eff_in_fps))),
            "-i", "-",
        ]

        # Áudio
        if audio_backend == "none":
            base += ["-an"]
        else:
            base += ["-f", audio_backend, "-thread_queue_size", "2048", "-i", mic]

        # Filtros de vídeo (escala + QUEDA de frames p/ CFR)
        vf = []
        if out_w and out_h:
            vf.append(f"scale={out_w}:{out_h}:flags=lanczos")
        vf.append(f"fps={out_fps_i}:round=down")   # drop > dup
        if denoise:
            vf.append("hqdn3d=1.2:1.2:6:6")
        base += ["-vf", ",".join(vf), "-vsync", "1"]  # CFR

        # Encoder de vídeo
        if encoder == "nvenc":
            base += [
                "-c:v", "h264_nvenc",
                "-preset", "p4",
                "-tune", "hq",
                "-rc", "vbr_hq",
                "-b:v", f"{vbitrate}k",
                "-maxrate", f"{vbitrate}k",
                "-bufsize", f"{vbitrate*2}k",
                "-g", str(g), "-keyint_min", str(g),
                "-bf", "2",
                "-pix_fmt", "yuv420p",
                "-profile:v", "high", "-level", "4.1",
            ]
            if latency == "ultra":
                base += ["-tune", "ll", "-bf", "0"]
        else:
            base += [
                "-c:v", "libx264",
                "-preset", preset,
                "-pix_fmt", "yuv420p",
                "-profile:v", "high", "-level", "4.1",
                "-b:v", f"{vbitrate}k",
                "-maxrate", f"{vbitrate}k",
                "-bufsize", f"{vbitrate*2}k",
                "-g", str(g), "-keyint_min", str(g),
            ]
            if latency == "ultra":
                base += ["-tune", "zerolatency", "-bf", "0"]
            else:
                base += ["-bf", "2"]

        # Áudio (AAC + resync leve)
        if audio_backend != "none":
            base += [
                "-c:a", "aac", "-ar", "48000", "-ac", "2",
                "-b:a", f"{abitrate}k",
                "-af", "aresample=async=1:min_hard_comp=0.100:first_pts=0,highpass=f=80,lowpass=f=12000",
            ]

        # RTMP
        base += ["-f", "flv", url]
        return base


    def _writer_loop(self, dev, cam, proc, target_fps):
        min_period = 1.0 / max(1.0, float(target_fps or 30.0))
        last_seq = -1
        last_sent = 0.0
        try:
            while self.run_by_dev.get(dev, False):
                if proc.poll() is not None:
                    break

                frame, seq, ts = cam.last_frame_info()
                if seq is None or seq == last_seq:
                    time.sleep(0.003)
                    continue

                now = time.time()
                # cap simples para não enviar mais do que o target_fps
                elapsed = now - last_sent
                if elapsed < (min_period * 0.95):
                    time.sleep((min_period * 0.95) - elapsed)

                try:
                    proc.stdin.write(frame.tobytes())
                except (BrokenPipeError, ValueError, OSError):
                    break

                last_seq = seq
                last_sent = time.time()
        finally:
            try:
                if proc.stdin:
                    proc.stdin.flush()
                    proc.stdin.close()
            except Exception:
                pass

    def start(self, dev, url, want_audio=True):
        dev = str(dev)
        cam = get_cam(dev)
        with self.lock:
            if self.proc_by_dev.get(dev) and self.proc_by_dev[dev].poll() is None:
                return True

        in_w, in_h, in_fps = self._probe_cam_dims(cam)
        mic = get_cam_cfg(dev).get("mic","default")
        lcfg = get_cam_cfg(dev).get("live", {}) or {}

        # Override de saída (0 = manter da câmera)
        out_w   = int(lcfg.get("width", 640))   or None
        out_h   = int(lcfg.get("height", 360))  or None
        out_fps = int(lcfg.get("fps", 10))     or None

        encoder  = (lcfg.get("encoder") or "x264").lower()
        preset   = (lcfg.get("preset")  or "superfast").lower()
        latency  = (lcfg.get("latency") or "ultra").lower()
        vbitrate = int(lcfg.get("vbitrate", 600))
        abitrate = int(lcfg.get("abitrate", 64))
        denoise  = bool(lcfg.get("denoise", True))

        # Decidir backend
        if not want_audio or (not mic) or mic.lower() == 'none':
            backends = [("none", mic)]
        elif mic.lower().startswith("pulse"):
            backends = [("pulse", mic), ("alsa", mic), ("none", mic)]
        else:
            backends = [("alsa", mic), ("none", mic)]

        tried = []
        p = None
        for backend, micname in backends:
            cmd = self._ffmpeg_cmd(
                in_w, in_h, in_fps, micname, url, backend,
                out_w=out_w, out_h=out_h, out_fps=out_fps,
                encoder=encoder, vbitrate=vbitrate, abitrate=abitrate,
                preset=preset, latency=latency, denoise=denoise
            )
            p = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                bufsize=0
            )
            self._spawn_stderr_drain(dev, p)
            time.sleep(0.8)
            if p.poll() is None:
                with self.lock:
                    self.proc_by_dev[dev] = p
                    self.run_by_dev[dev] = True
                pace = float(out_fps or in_fps or 30.0)
                th = threading.Thread(target=self._writer_loop, args=(dev, cam, p, pace), daemon=True)
                th.start()
                with self.lock:
                    self.thread_by_dev[dev] = th
                return True
            tried.append(f"[{backend}] {self._stderr_tail(dev)}")

        raise RuntimeError("ffmpeg (live) não iniciou.\n" + "\n".join(tried))

    def stop(self, dev):
        dev = str(dev)
        with self.lock:
            p  = self.proc_by_dev.get(dev)
            th = self.thread_by_dev.get(dev)
            self.run_by_dev[dev] = False
        if not p:
            return True
        if th:
            th.join(timeout=3.5)
        try:
            p.terminate(); p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            p.kill()
            try: p.wait(timeout=2)
            except Exception: pass
        with self.lock:
            self.proc_by_dev.pop(dev, None)
            self.thread_by_dev.pop(dev, None)
            self.run_by_dev.pop(dev, None)
        return True



LIVE = LiveStreamer()




# ----------------- Timelapse -----------------
class Timelapser:
    def __init__(self, dev, interval=5):
        self.dev = str(dev)
        self.interval = max(1, int(interval))
        self.running = False
        self.lock = threading.Lock()
        self.th = None
    def start(self, interval=None):
        with self.lock:
            if interval is not None:
                self.interval = max(1, int(interval))
            if self.running:
                return True
            self.running = True
            self.th = threading.Thread(target=self._loop, daemon=True)
            self.th.start()
            return True
    def stop(self):
        with self.lock:
            self.running = False
        if self.th:
            self.th.join(timeout=1.0)
    def _loop(self):
        cam = get_cam(self.dev)
        while True:
            with self.lock:
                if not self.running: break
                interval = self.interval
            frame = cam.last_frame()
            if frame is not None:
                ts = datetime.now().strftime("%Y%m%d-%H%M%S")
                name = f"tl-{sanitize_dev(self.dev)}-{ts}.jpg"
                path = os.path.join(MEDIA["photos"], name)
                cv2.imwrite(path, frame)
                make_thumb_image(path)
            total = interval; step = 0.1; loops = int(total/step)
            for _ in range(max(1,loops)):
                with self.lock:
                    if not self.running: break
                time.sleep(step)

TIMERS = {}
def get_timer(dev):
    dev=str(dev)
    if dev not in TIMERS:
        tcfg = get_cam_cfg(dev).get("timelapse", {})
        TIMERS[dev] = Timelapser(dev, interval=tcfg.get("interval",5))
    return TIMERS[dev]

# ----------------- Motion Controller -----------------
class MotionController:
    def __init__(self, dev):
        self.dev = str(dev)
        self.lock = threading.Lock()
        cfg = get_cam_cfg(self.dev).get("motion", {})
        self.enable = bool(cfg.get("enable", False))
        self.sens = int(cfg.get("sensitivity", 50))
        self.min_area = int(cfg.get("min_area_pct", 3))
        self.action = cfg.get("action", "photo")
        self.overlay = bool(cfg.get("overlay", True))
        self.cooldown = int(cfg.get("cooldown", 10))
        self.clip_len = int(cfg.get("clip_len", 30))
        self.last_photo_ts = 0.0
        self.stop_at = 0.0
        self.owned_record = False
        self.monitor_th = threading.Thread(target=self._monitor, daemon=True)
        self._running = True
        self.monitor_th.start()

    def update_cfg(self):
        cfg = get_cam_cfg(self.dev).get("motion", {})
        with self.lock:
            self.enable = bool(cfg.get("enable", False))
            self.sens = int(cfg.get("sensitivity", 50))
            self.min_area = int(cfg.get("min_area_pct", 3))
            self.action = cfg.get("action", "photo")
            self.overlay = bool(cfg.get("overlay", True))
            self.cooldown = int(cfg.get("cooldown", 10))
            self.clip_len = int(cfg.get("clip_len", 30))

    def on_boxes(self, boxes):
        if not self.enable:
            return
        active = bool(boxes)
        now = time.time()
        if not active:
            return
        if self.action == "photo":
            if now - self.last_photo_ts >= max(1, self.cooldown):
                self._take_photo()
                self.last_photo_ts = now
        else:  # video
            with self.lock:
                if not REC.is_recording(self.dev):
                    try:
                        mic = get_cam_cfg(self.dev).get("mic","default")
                        REC.start(self.dev, mic=mic, owner="motion")
                        self.owned_record = True
                    except Exception as e:
                        print(f"[Motion] start rec failed: {e}")
                        self.owned_record = False
                self.stop_at = max(self.stop_at, now + float(self.clip_len))

    def _monitor(self):
        while self._running:
            time.sleep(0.25)
            with self.lock:
                if self.owned_record and self.stop_at>0 and time.time() >= self.stop_at:
                    try:
                        fname = REC.stop(self.dev, owner="motion")
                        if fname:
                            frame = get_cam(self.dev).last_frame()
                            make_thumb_from_frame(frame, os.path.join(MEDIA["videos"], fname))
                            EVO_SENDER.queue("video", os.path.join(MEDIA["videos"], fname), self.dev)
                    except Exception as e:
                        print(f"[Motion] stop rec failed: {e}")
                    finally:
                        self.owned_record = False
                        self.stop_at = 0.0

    def _take_photo(self):
        cam = get_cam(self.dev)
        frame = cam.last_frame()
        if frame is None:
            return
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        name = f"photo-motion-{sanitize_dev(self.dev)}-{ts}.jpg"
        path = os.path.join(MEDIA["photos"], name)
        cv2.imwrite(path, frame)
        make_thumb_image(path)
        EVO_SENDER.queue("photo", path, self.dev)

    def stop(self):
        self._running = False

MOTIONS = {}
MOTION_LOCK = threading.Lock()
def get_motion_ctrl(dev):
    dev=str(dev)
    with MOTION_LOCK:
        if dev not in MOTIONS:
            MOTIONS[dev] = MotionController(dev)
        return MOTIONS[dev]

# ----------------- Captura em thread (preview) -----------------
CAMS = {}
CAM_LOCK = threading.Lock()

def _frame_has_signal(frame) -> bool:
    try:
        if frame is None or frame.size == 0:
            return False
        import numpy as np
        if np.all(frame == frame.flat[0]):
            return False
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        _, std = cv2.meanStdDev(gray)
        return float(std[0][0]) > 2.0
    except Exception:
        return False

class CameraStream:
    def __init__(self, device, width=1280, height=720, fps=30, jpeg_quality=80):
        self.device = device
        self.q = int(jpeg_quality)
        self.lock = threading.Lock()
        self.frame = None
        self.frame_ts = 0.0
        self.seq = 0
        self.running = True
        self.cap = self._open(device, width, height, fps)
        self.mdet = MotionDetector()
        self.th = threading.Thread(target=self._loop, daemon=True)
        self.th.start()

    def _open(self, dev, w, h, fps):
        sys = platform.system().lower()
        backend = cv2.CAP_V4L2 if 'linux' in sys else 0

        dev_arg = dev if not str(dev).isdigit() else int(dev)
        cap = cv2.VideoCapture(dev_arg, backend)
        if not cap.isOpened():
            raise RuntimeError(f"Não abriu câmera: {dev}")

        def _set(c, W, H, F, fourcc=None):
            if fourcc:
                c.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*fourcc))
            if W: c.set(cv2.CAP_PROP_FRAME_WIDTH,  int(W))
            if H: c.set(cv2.CAP_PROP_FRAME_HEIGHT, int(H))
            if F: c.set(cv2.CAP_PROP_FPS, float(F))

        def _has_signal(c):
            for _ in range(15):
                ok, fr = c.read()
                if ok and _frame_has_signal(fr):
                    return True
                time.sleep(0.03)
            return False

        ccfg = get_cam_cfg(dev).get("capture", {})
        want_fmt = (ccfg.get("format") or "auto").upper()
        want_w   = int(ccfg.get("width") or 0)
        want_h   = int(ccfg.get("height") or 0)
        want_fps = int(ccfg.get("fps") or 0)

        try:
            if want_fmt != "AUTO":
                _set(cap, want_w, want_h, want_fps, want_fmt)
            else:
                _set(cap, want_w or w, want_h or h, want_fps or fps, None)
            if _has_signal(cap):
                return cap
        except Exception:
            pass

        try:
            caps = _v4l2_caps(dev).get("formats", [])
        except Exception:
            caps = []

        prio = {"MJPG": 0, "YUYV": 1}
        caps.sort(key=lambda f: prio.get(f.get("fourcc","ZZZZ"), 9))

        for f in caps:
            four = f.get("fourcc")
            sizes = f.get("sizes", [])
            sizes.sort(key=lambda s: (s.get("w",0)*s.get("h",0)), reverse=True)
            for s in sizes:
                fps_list = s.get("fps") or [30, 15]
                for F in fps_list:
                    _set(cap, s.get("w"), s.get("h"), F, four)
                    if _has_signal(cap):
                        try:
                            set_cam_cfg(dev, {"capture": {"format": four, "width": s["w"], "height": s["h"], "fps": F}})
                        except Exception:
                            pass
                        return cap

        for four in ["MJPG", "YUYV", None]:
            for (W,H) in [(1920,1080),(1280,720),(640,480)]:
                for F in [30, 15]:
                    _set(cap, W, H, F, four)
                    if _has_signal(cap):
                        return cap

        raise RuntimeError(f"Nenhum formato/sinal válido em {dev}")

    def _loop(self):
        ctrl = get_motion_ctrl(self.device)
        while self.running:
            ok, img = self.cap.read()
            if ok:
                rot = int(get_cam_cfg(self.device).get("rotate", 0))
                img2 = rotate_image(img, rot)

                with self.lock:
                    self.frame = img2
                    self.frame_ts = time.time()
                    self.seq += 1

                cfg = get_cam_cfg(self.device).get("motion", {})
                do_proc = bool(cfg.get("enable")) or bool(cfg.get("overlay"))
                boxes = []
                if do_proc:
                    boxes = self.mdet.process(
                        img2,
                        sensitivity=int(cfg.get("sensitivity", 50)),
                        min_area_pct=int(cfg.get("min_area_pct", 3))
                    )
                ctrl.update_cfg()
                if cfg.get("enable"):
                    ctrl.on_boxes(boxes)
            else:
                time.sleep(0.02)

    def _draw_motion(self, f):
        boxes = self.mdet.get_boxes()
        if not boxes: return f
        for (x,y,w,h) in boxes:
            cv2.rectangle(f, (x,y), (x+w, y+h), (0,0,255), 2)
        cv2.putText(f, f"motion:{len(boxes)}", (10,22), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0,0,255), 2, cv2.LINE_AA)
        return f

    def get_jpeg(self):
        with self.lock:
            f = None if self.frame is None else self.frame.copy()
        if f is None:
            return None
        mcfg = get_cam_cfg(self.device).get("motion", {})
        if mcfg.get("overlay", False):
            f = self._draw_motion(f)
        ok, buf = cv2.imencode(".jpg", f, [int(cv2.IMWRITE_JPEG_QUALITY), self.q])
        return buf.tobytes() if ok else None

    def last_frame(self):
        with self.lock:
            return None if self.frame is None else self.frame.copy()

    def last_frame_info(self):
        with self.lock:
            if self.frame is None:
                return None, None, None
            return self.frame.copy(), self.seq, self.frame_ts

    def stop(self):
        self.running = False
        try: self.th.join(timeout=1)
        except: pass
        try: self.cap.release()
        except: pass


def get_cam(dev):
    with CAM_LOCK:
        if dev not in CAMS:
            CAMS[dev] = CameraStream(dev)
        return CAMS[dev]

def restart_cam(dev):
    with CAM_LOCK:
        c = CAMS.pop(dev, None)
    if c:
        try: c.stop()
        except: pass

# ----------------- Biblioteca Helpers -----------------
def parse_info_from_name(name: str):
    base = os.path.basename(name)
    m = re.match(r"^(?:video|rec)-(user|motion)-(.+?)-\d{8}-\d{6}\.(?:mp4|mkv|mov)$", base, re.IGNORECASE)
    if m: return m.group(1).lower(), m.group(2)
    m = re.match(r"^photo-(user|motion)-(.+?)-\d{8}-\d{6}\.jpg$", base, re.IGNORECASE)
    if m: return m.group(1).lower(), m.group(2)
    m = re.match(r"^tl-(.+?)-\d{8}-\d{6}\.jpg$", base, re.IGNORECASE)
    if m: return "timelapse", m.group(1)
    m = re.match(r"^(rec|photo|tl)-(.+?)-\d{8}-\d{6}\.(mp4|jpg)$", base, re.IGNORECASE)
    if m:
        kind, cam = m.group(1).lower(), m.group(2)
        origin = "timelapse" if kind == "tl" else "user"
        return origin, cam
    return "_unknown", "_unknown"

def in_date_range(path, start_d: date=None, end_d: date=None):
    try:
        ts = os.path.getmtime(path)
    except Exception:
        return True
    d = datetime.fromtimestamp(ts).date()
    if start_d and d < start_d: return False
    if end_d and d > end_d: return False
    return True

# ----------------- v4l2 caps helper/endpoint -----------------
def _v4l2_caps(dev: str):
    try:
        r = subprocess.run(
            ["v4l2-ctl", "-d", dev, "--list-formats-ext"],
            capture_output=True, text=True, timeout=3
        )
        out = r.stdout or ""
    except Exception:
        out = ""

    formats = []
    cur = None
    for ln in out.splitlines():
        m_fmt = re.search(r"\[\d+\]:\s*'([A-Z0-9]{4})'", ln)
        if m_fmt:
            cur = {"fourcc": m_fmt.group(1), "sizes": []}
            formats.append(cur)
            continue
        m_sz = re.search(r"Size:\s*Discrete\s+(\d+)x(\d+)", ln)
        if m_sz and cur is not None:
            cur["sizes"].append({"w": int(m_sz.group(1)), "h": int(m_sz.group(2)), "fps": []})
            continue
        m_fps = re.search(r"Interval:\s*Discrete\s*[\d\.]+s\s*\(([\d\.]+)\s*fps\)", ln)
        if m_fps and cur is not None and cur["sizes"]:
            fps_val = int(round(float(m_fps.group(1))))
            if fps_val not in cur["sizes"][-1]["fps"]:
                cur["sizes"][-1]["fps"].append(fps_val)

    if not formats:
        formats = [
            {"fourcc":"MJPG","sizes":[{"w":1920,"h":1080,"fps":[30,15]},
                                      {"w":1280,"h":720,"fps":[30,15]},
                                      {"w":640,"h":480,"fps":[30,15]}]},
            {"fourcc":"YUYV","sizes":[{"w":640,"h":480,"fps":[30]}]}
        ]
    return {"formats": formats}

# ----------------- Flask -----------------
app = Flask(__name__)
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_port=1, x_prefix=1)

@app.get("/")
def index():
    basepath = request.headers.get("X-Forwarded-Prefix") or (request.script_root or "")
    return render_template_string(HTML, basepath=basepath, evo_instance=EVO_API_INSTANCE)

@app.get("/api/devices")
def api_devices():
    if "linux" in platform.system().lower():
        devs = scan_linux_cams()
    else:
        devs = []
        for i in range(6):
            cap = cv2.VideoCapture(i)
            if cap.isOpened():
                devs.append(str(i))
                cap.release()

    try:
        active = [d for d in devs if is_cam_active(d)]
    except Exception:
        active = []

    with CFG_LOCK:
        selected = list((CFG.get("ui") or {}).get("selected_devs") or [])

    return jsonify(devices=devs, active=active, selected=selected)

@app.get("/api/audio")
def api_audio():
    alsa = list_alsa_capture_devices()
    pulse = list_pulse_sources()
    return jsonify(alsa=alsa, pulse=pulse)

@app.get("/api/caps")
def api_caps():
    dev = request.args.get("dev")
    if not dev:
        return jsonify(ok=False, error="falta dev"), 400
    try:
        caps = _v4l2_caps(dev)
        return jsonify(ok=True, **caps)
    except Exception as e:
        return jsonify(ok=False, error=str(e)), 500

@app.get("/video_feed")
def video_feed():
    dev = request.args.get("dev")
    if not dev: return Response("falta dev", status=400)
    try:
        cam = get_cam(dev)
    except Exception as e:
        return Response(str(e), status=503)

    boundary = "frame"
    def gen():
        while True:
            jpg = cam.get_jpeg()
            if jpg is None:
                time.sleep(0.03); continue
            yield (b"--"+boundary.encode()+b"\r\n"
                   b"Content-Type: image/jpeg\r\n"
                   b"Content-Length: "+str(len(jpg)).encode()+b"\r\n\r\n"+jpg+b"\r\n")
    return Response(gen(), mimetype="multipart/x-mixed-replace; boundary=frame")

# -------- Viva-voz: stream MP3 do microfone selecionado --------
def _pick_audio_backend_and_device(mic_value: str):
    """
    Retorna (backend, device) para ffmpeg.
    mic_value exemplos:
      - "pulse" -> ("pulse", "default")
      - "pulse:alsa_input.xxx" -> ("pulse", "alsa_input.xxx")
      - "hw:CARD=...,DEV=..." -> ("alsa", "hw:CARD=...,DEV=...")
      - "default" -> tenta pulse, senão alsa "default"
    """
    s = (mic_value or "").strip()
    if not s or s.lower() == "none":
        return "none", ""
    low = s.lower()
    if low == "pulse":
        return "pulse", "default"
    if low.startswith("pulse:"):
        return "pulse", s.split(":",1)[1]
    if low == "default":
        # prefere pulse se houver
        try:
            if list_pulse_sources():
                return "pulse", "default"
        except Exception:
            pass
        return "alsa", "default"
    # ALSA típico
    return "alsa", s

@app.get("/audio/live")
def audio_live():
    dev = request.args.get("dev","")
    mic = request.args.get("mic","default")
    backend, device = _pick_audio_backend_and_device(mic)
    if backend == "none":
        return Response("mic none", status=400)
    if not have_cmd("ffmpeg"):
        return Response("ffmpeg não encontrado", status=500)

    # inicia ffmpeg que envia mp3 para stdout
    cmd = [
        "ffmpeg","-hide_banner","-loglevel","error",
        "-f", backend, "-thread_queue_size","1024", "-i", device,
        "-ac","1","-ar","44100","-c:a","libmp3lame","-b:a","96k","-f","mp3","-"
    ]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    except Exception as e:
        return Response(f"erro ffmpeg: {e}", status=500)

    def gen():
        try:
            while True:
                chunk = proc.stdout.read(4096)
                if not chunk:
                    break
                yield chunk
        finally:
            try:
                proc.terminate(); proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                try: proc.wait(timeout=1)
                except Exception: pass
    headers = {"Cache-Control":"no-store"}
    return Response(gen(), mimetype="audio/mpeg", headers=headers)

# -------- Foto/Vídeo manuais --------
@app.post("/api/photo")
def api_photo():
    data = request.get_json(silent=True) or {}
    dev = data.get("dev") or request.args.get("dev")
    if not dev: return jsonify(ok=False, error="falta dev"), 400
    cam = get_cam(dev)
    frame = cam.last_frame()
    if frame is None: return jsonify(ok=False, error="sem frame"), 503
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    name = f"photo-user-{sanitize_dev(dev)}-{ts}.jpg"
    path = os.path.join(MEDIA["photos"], name)
    cv2.imwrite(path, frame)
    make_thumb_image(path)
    return jsonify(ok=True, file=name)

@app.post("/api/record/start")
def api_rec_start():
    data = request.get_json(silent=True) or {}
    dev = data.get("dev")
    mic = data.get("mic")
    if not dev: return jsonify(ok=False, error="falta dev"), 400
    _ = get_cam(dev)
    if not mic:
        mic = get_cam_cfg(dev).get("mic","default")
    try:
        fname = REC.start(dev, mic=mic, owner="user")
        return jsonify(ok=True, file=fname)
    except Exception as e:
        return jsonify(ok=False, error=str(e)), 500

@app.post("/api/record/stop")
def api_rec_stop():
    data = request.get_json(silent=True) or {}
    dev = data.get("dev")
    if not dev: return jsonify(ok=False, error="falta dev"), 400
    try:
        fname = REC.stop(dev, owner="user", force=True)
        if fname:
            frame = get_cam(dev).last_frame()
            make_thumb_from_frame(frame, os.path.join(MEDIA["videos"], fname))
        return jsonify(ok=True, file=fname)
    except Exception as e:
        return jsonify(ok=False, error=str(e)), 400

# -------- Live RTMP endpoints --------
@app.post("/api/live/start")
def api_live_start():
    data = request.get_json(silent=True) or {}
    dev = data.get("dev","")
    url = (data.get("url") or "").strip()
    want_audio = bool(data.get("audio", True))
    if not dev or not url:
        return jsonify(ok=False, error="faltam dev/url"), 400
    try:
        set_cam_cfg(dev, {"live":{"url":url, "audio": want_audio}})
        ok = LIVE.start(dev, url, want_audio=want_audio)
        return jsonify(ok=True)
    except Exception as e:
        return jsonify(ok=False, error=str(e)), 500

@app.post("/api/live/stop")
def api_live_stop():
    data = request.get_json(silent=True) or {}
    dev = data.get("dev","")
    if not dev:
        return jsonify(ok=False, error="falta dev"), 400
    try:
        LIVE.stop(dev)
        return jsonify(ok=True)
    except Exception as e:
        return jsonify(ok=False, error=str(e)), 500

# -------- Biblioteca --------
@app.get("/api/media")
def api_media():
    def _parse_d(s):
        try: return datetime.strptime(s, "%Y-%m-%d").date()
        except Exception: return None
    start_d = _parse_d(request.args.get("start", "") or "")
    end_d   = _parse_d(request.args.get("end", "") or "")

    by_cam = {}

    for p in sorted(glob.glob(os.path.join(MEDIA["videos"], "*.mp4")), reverse=True):
        if not in_date_range(p, start_d, end_d): continue
        name = os.path.basename(p)
        origin, cam = parse_info_from_name(name)
        t = os.path.join(MEDIA["thumbs"], os.path.splitext(name)[0]+".jpg")
        bc = by_cam.setdefault(cam, {"videos_user": [], "videos_motion": [], "photos_user": [], "photos_motion": [], "timelapse": []})
        item = {"name": name, "url": f"/media/videos/{name}", "thumb": f"/media/thumbs/{os.path.basename(t)}" if os.path.isfile(t) else ""}
        if origin == "motion": bc["videos_motion"].append(item)
        else: bc["videos_user"].append(item)

    for p in sorted(glob.glob(os.path.join(MEDIA["photos"], "*.jpg")), reverse=True):
        if not in_date_range(p, start_d, end_d): continue
        name = os.path.basename(p)
        origin, cam = parse_info_from_name(name)
        t = os.path.join(MEDIA["thumbs"], name)
        if not os.path.isfile(t):
            make_thumb_image(p)
        bc = by_cam.setdefault(cam, {"videos_user": [], "videos_motion": [], "photos_user": [], "photos_motion": [], "timelapse": []})
        item = {"name": name, "url": f"/media/photos/{name}", "thumb": f"/media/thumbs/{name}"}
        if origin == "motion": bc["photos_motion"].append(item)
        elif origin == "timelapse": bc["timelapse"].append(item)
        else: bc["photos_user"].append(item)

    cams = sorted(by_cam.keys())
    return jsonify(by_camera=by_cam, cameras=cams)

@app.post("/api/media/delete")
def api_media_delete():
    data = request.get_json(silent=True) or {}
    items = data.get("items") or []
    if not isinstance(items, list) or not items:
        return jsonify(ok=False, error="items vazios"), 400
    deleted = 0
    for it in items:
        kind = (it.get("kind") or "").strip()
        name = (it.get("name") or "").strip()
        if kind not in ("photos","videos"): continue
        if "/" in name or "\\" in name: continue
        base_dir = MEDIA[kind]
        path = os.path.join(base_dir, name)
        try:
            if os.path.isfile(path):
                os.remove(path); deleted += 1
                if kind == "photos":
                    t = os.path.join(MEDIA["thumbs"], name if name.lower().endswith(".jpg") else os.path.splitext(name)[0]+".jpg")
                    if os.path.isfile(t): os.remove(t)
                else:
                    t = os.path.join(MEDIA["thumbs"], os.path.splitext(name)[0]+".jpg")
                    if os.path.isfile(t): os.remove(t)
        except Exception:
            pass
    return jsonify(ok=True, deleted=deleted)

@app.get("/media/<path:kind>/<path:name>")
def media(kind, name):
    base = MEDIA.get(kind)
    if not base: abort(404)
    return send_from_directory(base, name)

# -------- Config/Timelapse/UI/Motion/Capture --------
@app.get("/api/config")
def api_config_get():
    with CFG_LOCK:
        out = dict(CFG)
    return jsonify(out)

@app.post("/api/config")
def api_config_post():
    data = request.get_json(silent=True) or {}

    # Evolution
    if "evo" in data and isinstance(data["evo"], dict):
        evo = data["evo"]
        with CFG_LOCK:
            CFG.setdefault("evo", {})
            evo_cfg = CFG["evo"]
            if "enable" in evo: evo_cfg["enable"] = bool(evo["enable"])
            if "phones" in evo:
                if isinstance(evo["phones"], str):
                    phones = [p.strip() for p in evo["phones"].replace(",", "\n").splitlines() if p.strip()]
                elif isinstance(evo["phones"], list):
                    phones = [str(p).strip() for p in evo["phones"] if str(p).strip()]
                else:
                    phones = []
                evo_cfg["phones"] = phones
            if "base" in evo: evo_cfg["base"] = str(evo["base"]).strip()
        _cfg_save()
        return jsonify(ok=True)

    # Câmera
    dev = data.get("dev")
    if dev:
        updates = {}
        if "name" in data: updates["name"] = str(data["name"]).strip()
        if "mic" in data:  updates["mic"] = data["mic"]

        if "rotate" in data:
            try: rot = int(data["rotate"])
            except Exception: rot = 0
            if rot not in (0, 90, 180, 270): rot = 0
            updates["rotate"] = rot

        if "capture" in data and isinstance(data["capture"], dict):
            cap_in = data["capture"]; cap_out = {}
            if "format" in cap_in:
                fmt = str(cap_in["format"]).upper()
                if fmt not in ("AUTO","MJPG","YUYV","H264"):
                    fmt = "AUTO"
                cap_out["format"] = fmt
            if "width" in cap_in:  cap_out["width"]  = int(cap_in["width"] or 0)
            if "height" in cap_in: cap_out["height"] = int(cap_in["height"] or 0)
            if "fps" in cap_in:    cap_out["fps"]    = int(cap_in["fps"] or 0)
            updates["capture"] = cap_out

        if "live" in data and isinstance(data["live"], dict):
            lv_in = data["live"]; lv = {}
            if "url" in lv_in:      lv["url"] = str(lv_in["url"]).strip()
            if "audio" in lv_in:    lv["audio"] = bool(lv_in["audio"])
            for k in ("width","height","fps","vbitrate","abitrate"):
                if k in lv_in:
                    try: lv[k] = max(0, int(lv_in[k]))
                    except: pass
            if "encoder" in lv_in:
                enc = str(lv_in["encoder"]).lower().strip()
                if enc not in ("x264", "nvenc"): enc = "x264"
                lv["encoder"] = enc
            if "preset" in lv_in:
                lv["preset"] = str(lv_in["preset"]).lower().strip()
            if "latency" in lv_in:
                lat = str(lv_in["latency"]).lower().strip()
                if lat not in ("normal","ultra"): lat = "normal"
                lv["latency"] = lat
            if "denoise" in lv_in:
                lv["denoise"] = bool(lv_in["denoise"])
            updates["live"] = lv


        if "timelapse" in data and isinstance(data["timelapse"], dict):
            t = {}
            if "enable" in data["timelapse"]:  t["enable"]  = bool(data["timelapse"]["enable"])
            if "interval" in data["timelapse"]:t["interval"]= int(data["timelapse"]["interval"])
            updates["timelapse"] = t

        if "motion" in data and isinstance(data["motion"], dict):
            m = {}
            if "enable" in data["motion"]:       m["enable"] = bool(data["motion"]["enable"])
            if "sensitivity" in data["motion"]:  m["sensitivity"] = int(data["motion"]["sensitivity"])
            if "min_area_pct" in data["motion"]: m["min_area_pct"] = int(data["motion"]["min_area_pct"])
            if "action" in data["motion"]:
                m["action"] = data["motion"]["action"] if data["motion"]["action"] in ("photo","video") else "photo"
            if "overlay" in data["motion"]:      m["overlay"] = bool(data["motion"]["overlay"])
            if "cooldown" in data["motion"]:     m["cooldown"] = int(data["motion"]["cooldown"])
            if "clip_len" in data["motion"]:     m["clip_len"] = int(data["motion"]["clip_len"])
            updates["motion"] = m

        set_cam_cfg(dev, updates)

        # timelapse
        tl = get_timer(dev)
        tcfg = get_cam_cfg(dev).get("timelapse", {})
        if tcfg.get("enable"):
            tl.start(tcfg.get("interval", 5))
        else:
            tl.stop()

        # motion
        get_motion_ctrl(dev).update_cfg()
        return jsonify(ok=True)

    # UI
    ui = data.get("ui")
    if isinstance(ui, dict):
        updates = {}
        if "preview_size" in ui:
            sz = str(ui["preview_size"]).lower()
            if sz not in ("small", "medium", "large", "xlarge", "xxlarge"):
                return jsonify(ok=False, error="preview_size inválido"), 400
            updates["preview_size"] = sz

        if "library_view" in ui:
            lv = str(ui["library_view"]).lower()
            if lv not in ("grid", "list"):
                return jsonify(ok=False, error="library_view inválido"), 400
            updates["library_view"] = lv

        if "selected_devs" in ui:
            sd = ui["selected_devs"]
            if not isinstance(sd, (list, tuple)):
                return jsonify(ok=False, error="selected_devs inválido"), 400
            updates["selected_devs"] = [str(s) for s in sd]

        if updates:
            set_ui_cfg(updates)
            return jsonify(ok=True)

    return jsonify(ok=False, error="payload inválido"), 400

@app.post("/api/timelapse/start")
def api_tl_start():
    data = request.get_json(silent=True) or {}
    dev = data.get("dev"); interval = int(data.get("interval",5))
    if not dev: return jsonify(ok=False, error="falta dev"), 400
    set_cam_cfg(dev, {"timelapse":{"enable": True, "interval": interval}})
    get_timer(dev).start(interval)
    return jsonify(ok=True)

@app.post("/api/timelapse/stop")
def api_tl_stop():
    data = request.get_json(silent=True) or {}
    dev = data.get("dev")
    if not dev: return jsonify(ok=False, error="falta dev"), 400
    set_cam_cfg(dev, {"timelapse":{"enable": False}})
    get_timer(dev).stop()
    return jsonify(ok=True)

# --- restart de câmera
@app.post("/api/cam/restart")
def api_cam_restart():
    data = request.get_json(silent=True) or {}
    dev = data.get("dev")
    if not dev:
        return jsonify(ok=False, error="falta dev"), 400
    restart_cam(dev)
    return jsonify(ok=True)

# --- Evolution utilitários
def _norm_phone(s: str) -> str:
    if not s: return ""
    s = re.sub(r"\D", "", str(s))
    return s

@app.post("/api/evo/ping")
def api_evo_ping():
    with CFG_LOCK:
        evo = CFG.get("evo") or {}
        phones = evo.get("phones") or []
    if not phones:
        return jsonify(ok=False, error="Sem telefones em evo.phones"), 400
    phone = _norm_phone(phones[0])
    if not phone:
        return jsonify(ok=False, error="Telefone inválido após normalização"), 400
    s, t = EVO_SENDER._send_text(phone, "ping do MirakoMultiCam ✅")
    return jsonify(ok=(s<300), status=s, resp=t[:500])

@app.get("/api/evo/debug")
def api_evo_debug():
    with CFG_LOCK:
        evo = dict(CFG.get("evo") or {})
    evo["phones"] = [ _norm_phone(p) for p in (evo.get("phones") or []) ]
    info = {
        "enabled": bool(evo.get("enable")),
        "phones_norm": evo["phones"],
        "base": evo.get("base") or "",
        "api_url": EVO_API_URL,
        "instance": EVO_API_INSTANCE,
    }
    return jsonify(ok=True, evo=info)

@app.post("/api/evo/test")
def api_evo_test():
    data = request.get_json(silent=True) or {}
    devs = data.get("devs")
    if not devs:
        d = data.get("dev")
        if isinstance(d, str) and d.strip():
            devs = [d.strip()]
    if not devs:
        devs = _active_devs(prefer_selected=True)

    results = []
    sent_total = 0

    for dev in devs:
        dev = str(dev)
        try:
            cam = get_cam(dev)
            frame = cam.last_frame()
            if frame is None:
                raise RuntimeError("sem frame")

            ts = datetime.now().strftime("%Y%m%d-%H%M%S")
            fname = f"photo-user-{sanitize_dev(dev)}-{ts}.jpg"
            fpath = os.path.join(MEDIA["photos"], fname)
            cv2.imwrite(fpath, frame)
            make_thumb_image(fpath)

            EVO_SENDER.queue("photo", fpath, dev)

            results.append({"dev": dev, "ok": True, "file": fname})
            sent_total += 1
        except Exception as e:
            results.append({"dev": dev, "ok": False, "error": f"não abriu câmera: {e}"})

    return jsonify(ok=sent_total > 0, sent=sent_total, results=results)

@app.get("/api/live/status")
def api_live_status():
    dev = request.args.get("dev","")
    if not dev:
        return jsonify(ok=False, error="falta dev"), 400
    running = bool(LIVE.proc_by_dev.get(dev) and LIVE.proc_by_dev[dev].poll() is None)
    tail = LIVE._stderr_tail(dev, limit=4000)
    return jsonify(ok=True, running=running, stderr_tail=tail or "")



@app.post("/api/evo/test_video")
def api_evo_test_video():
    data = request.get_json(silent=True) or {}
    devs = data.get("devs")
    if not devs:
        devs = _active_devs(prefer_selected=True)

    override_secs = data.get("seconds")
    started = 0
    results = []

    def worker(dev, secs):
        try:
            _ = get_cam(dev)
            mic = get_cam_cfg(dev).get("mic", "default")

            fname = REC.start(dev, mic=mic, owner="user")
            print(f"[EVO TEST] gravando {dev} por {secs}s → {fname}")
            time.sleep(max(3, int(secs)))

            out_name = REC.stop(dev, owner="user", force=True)
            if out_name:
                out_path = os.path.join(MEDIA["videos"], out_name)
                try:
                    frame = get_cam(dev).last_frame()
                    make_thumb_from_frame(frame, out_path)
                except Exception:
                    pass
                EVO_SENDER.queue("video", out_path, dev)
                print(f"[EVO TEST] vídeo pronto e enfileirado para envio: {out_name}")
        except Exception as e:
            print(f"[EVO TEST] erro em {dev}: {e}")

    for dev in devs:
        try:
            cfg = get_cam_cfg(dev) or {}
            mcfg = cfg.get("motion", {}) or {}
            secs = int(override_secs) if override_secs is not None else int(mcfg.get("clip_len", 30))
            threading.Thread(target=worker, args=(dev, secs), daemon=True).start()
            started += 1
            results.append({"dev": dev, "seconds": secs})
        except Exception as e:
            results.append({"dev": dev, "error": str(e)})

    return jsonify(ok=started > 0, targets=started, results=results)

def _active_devs(prefer_selected=True):
    with CFG_LOCK:
        sel = (CFG.get("ui", {}) or {}).get("selected_devs") or []
        cams = list((CFG.get("cameras") or {}).keys())
    devs = [str(d) for d in (sel if (prefer_selected and sel) else cams)]
    return devs or ["/dev/video0"]

def _cleanup():
    for c in list(CAMS.values()):
        try: c.stop()
        except: pass
    for t in list(TIMERS.values()):
        try: t.stop()
        except: pass
    for m in list(MOTIONS.values()):
        try: m.stop()
        except: pass
    for d in list(LIVE.proc_by_dev.keys()):
        try: LIVE.stop(d)
        except: pass

import atexit; atexit.register(_cleanup)

if __name__ == "__main__":
    _cfg_load()
    for dev, dat in list(CFG.get("cameras", {}).items()):
        tl = dat.get("timelapse", {})
        if tl.get("enable"):
            get_timer(dev).start(tl.get("interval",5))
    app.run("0.0.0.0", 5000, threaded=True)



PYEOF

sudo systemctl restart mirakocam




tee /etc/systemd/system/mirakocam.service >/dev/null <<'EOF'
[Unit]
Description=MirakoCAM Flask Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin/
ExecStart=/usr/bin/python3 /usr/local/bin/app.py
Restart=always
RestartSec=5
Environment=PORT=5000

[Install]
WantedBy=multi-user.target
EOF






sudo systemctl daemon-reload
sudo systemctl enable mirakocam
sudo systemctl start mirakocam
sudo systemctl restart mirakocam





sudo systemctl status mirakocam
sudo journalctl -fu mirakocam











































































sudo usermod -aG video $USER









pip uninstall numpy
pip install numpy==1.26.0

##BAIXAR MODELOS 

#!/usr/bin/env bash
set -euo pipefail

MODEL_DIR="models"
mkdir -p "$MODEL_DIR"

# Nomes finais no disco
PROTO="$MODEL_DIR/deploy.prototxt"
WEIGHTS="$MODEL_DIR/mobilenet_iter_73000.caffemodel"

# Origens preferidas (projeto original)
PROTO_URLS=(
  "https://raw.githubusercontent.com/chuanqi305/MobileNet-SSD/master/deploy.prototxt"
  "https://github.com/chuanqi305/MobileNet-SSD/raw/master/deploy.prototxt"
)

WEIGHTS_URLS=(
  "https://raw.githubusercontent.com/chuanqi305/MobileNet-SSD/master/mobilenet_iter_73000.caffemodel"
  "https://github.com/chuanqi305/MobileNet-SSD/raw/master/mobilenet_iter_73000.caffemodel"
  # Fallbacks comunitários (use só se necessário)
  "https://github.com/mesutpiskin/opencv-object-detection/raw/master/data/dnnmodel/MobileNetSSD_deploy.caffemodel"
  "https://sourceforge.net/projects/ip-cameras-for-vlc/files/MobileNetSSD_deploy.caffemodel/download"
)

download_any() {
  local out="$1"; shift
  for url in "$@"; do
    echo "[*] tentando: $url"
    if command -v curl >/dev/null 2>&1; then
      if curl -L --fail --retry 3 -o "$out" "$url"; then
        echo "[OK] baixado de: $url"
        return 0
      fi
    else
      if wget -O "$out" "$url"; then
        echo "[OK] baixado de: $url"
        return 0
      fi
    fi
  done
  return 1
}

echo "[*] Baixando prototxt..."
if [ ! -s "$PROTO" ]; then
  download_any "$PROTO" "${PROTO_URLS[@]}" || {
    echo "[ERRO] não consegui baixar o prototxt. Baixe manualmente e salve em: $PROTO"
    exit 1
  }
fi

echo "[*] Baixando caffemodel..."
if [ ! -s "$WEIGHTS" ]; then
  download_any "$WEIGHTS" "${WEIGHTS_URLS[@]}" || {
    echo "[ERRO] não consegui baixar o caffemodel. Baixe manualmente e salve em: $WEIGHTS"
    exit 1
  }
fi

echo "[OK] Modelos prontos em: $MODEL_DIR"
ls -lh "$PROTO" "$WEIGHTS"











# Dependências básicas
sudo apt-get update && sudo apt-get install -y curl ca-certificates xz-utils

# Descobre a sua arquitetura e escolhe o asset certo
ARCH=$(dpkg --print-architecture)               # armhf ou arm64
case "$ARCH" in
  arm64)  FILTER="linux_arm64" ;;
  armhf)  FILTER="linux_armv7|linux_arm" ;;     # armv7 (fallback: arm genérico)
  *)      echo "Arquitetura $ARCH não mapeada"; exit 1 ;;
esac

# Busca a URL do .deb (preferência) ou do .gz na última release
URL=$(curl -s https://api.github.com/repos/jpillora/chisel/releases/latest \
  | grep -oP '(?<="browser_download_url": ")[^"]+' \
  | grep -E "chisel_.*_(${FILTER})\.(deb|gz)$" | head -n1)

# Instala (.deb se houver; senão, extrai o .gz)
if echo "$URL" | grep -q '\.deb$'; then
  curl -L "$URL" -o /tmp/chisel.deb && sudo dpkg -i /tmp/chisel.deb || sudo apt -f install -y
else
  curl -L "$URL" -o /tmp/chisel.gz && gunzip -f /tmp/chisel.gz && \
  chmod +x /tmp/chisel && sudo mv /tmp/chisel /usr/local/bin/chisel
fi

# Verifique
chisel -v


##PROXY REVERSO NGINX 

# All server fields such as server | location can be set, such as:
# location /web {
#     try_files $uri $uri/ /index.php$is_args$args;
# }
# error_page 404 /diy_404.html;
# If there is abnormal access to the reverse proxy website and the content has already been configured here, please prioritize checking if the configuration here is correct

# --- Upstreams dinâmicos por Referer (um ponto de verdade) ---
# Fallback (raiz)
set $api_upstream http://127.0.0.1:6000;
set $static_upstream http://127.0.0.1:6000;

# Se a página de origem é /web1/, use 15000
if ($http_referer ~* "/web1/") {
    set $api_upstream http://127.0.0.1:15000;
    set $static_upstream http://127.0.0.1:15000;
}

# Se a página de origem é /cam1/, use 15001
if ($http_referer ~* "/cam1/") {
    set $api_upstream http://127.0.0.1:15001;
    set $static_upstream http://127.0.0.1:15001;
}

# --- OPCIONAL: se os endpoints de gravação forem SEMPRE do cam1 ---
# Coloque ANTES do /api/ geral para ter prioridade
location ^~ /api/record/ {
    proxy_pass http://127.0.0.1:15001;  # cam1
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    client_max_body_size 100m;
}

# --- /api (ÚNICO bloco) ---
location ^~ /api/ {
    proxy_pass $api_upstream;  # mantém /api/... para o app selecionado pelo Referer
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_http_version 1.1;
    proxy_buffering off;             # evita buffering de respostas longas/stream
    proxy_request_buffering off;     # encaminha o body (POST/PUT) sem buffer
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    client_max_body_size 100m;
    # Se usar WebSocket em /api/:
    # proxy_set_header Upgrade $http_upgrade;
    # proxy_set_header Connection "upgrade";
}

# --- Stream de vídeo ---
location ^~ /video_feed {
    proxy_pass $static_upstream;     # preserva query (?dev=/dev/videoX)
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_read_timeout 3600s;
    add_header X-Accel-Buffering no;
    # Se for WebSocket:
    # proxy_set_header Upgrade $http_upgrade;
    # proxy_set_header Connection "upgrade";
}

# --- Imagens/Thumbs ---
location ^~ /media/ {
    proxy_pass $static_upstream;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_buffering off;             # evita atraso em geração on-demand
    expires -1;
    add_header Cache-Control "no-store";
}

# --- Conveniências ---
# Força barra final nas apps (resolve assets relativos)
location = /web1 { return 301 /web1/; }
location = /cam1 { return 301 /cam1/; }

# Redireciona a raiz para /web1/ (ou troque para /cam1/ se preferir)
location = / { return 302 /web1/; }






tee /etc/systemd/system/chisel-client.service >/dev/null <<'EOF'
[Unit]
Description=Chisel client (reversos: 15000->127.0.0.1:80 e 15001->127.0.0.1:5000)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=orangepi
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"
ExecStart=/usr/bin/env chisel client \
  --keepalive 10s \
  --auth camai:qazwsx \
  camai.mirako.org:6000 \
  R:0.0.0.0:15000:127.0.0.1:80 \
  R:0.0.0.0:15001:127.0.0.1:5000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target


EOF


sudo systemctl daemon-reload
sudo systemctl enable --now chisel-client
sudo systemctl restart chisel-client
journalctl -u chisel-client -f

































