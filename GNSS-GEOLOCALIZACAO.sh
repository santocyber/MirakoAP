#!/usr/bin/env python3
import json
import time
import queue
import threading
from collections import deque
from pathlib import Path

import serial
from flask import Flask, Response, request, jsonify, render_template_string, send_from_directory, abort

# =========================
# CONFIG FIXA
# =========================
SERIAL_PORT = "/dev/ttyUSB2"
SERIAL_BAUD = 115200
POLL_INTERVAL_S = 1.0
HTTP_HOST = "0.0.0.0"
HTTP_PORT = 5000

DEFAULT_GNSS_MODE = 7
DEFAULT_NMEA_RATE = 1

TRACK_DIR = Path("./tracks")
TRACK_DIR.mkdir(parents=True, exist_ok=True)

HTML = r"""
<!doctype html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>GNSS Monitor</title>

  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"/>
  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>

  <style>
    body { margin:0; font-family: system-ui, Arial; background:#0b0f14; color:#e7eef7; }
    .wrap { display:flex; height:100vh; }
    #map { flex: 1; }
    .side { width: 440px; max-width: 55vw; padding: 14px; box-sizing:border-box; background:#0f1620; border-left:1px solid #1a2432; overflow:auto; }
    .row { display:flex; gap:10px; flex-wrap:wrap; align-items:center; }
    .card { background:#0b111a; border:1px solid #1a2432; border-radius:10px; padding:12px; margin-bottom:12px; }
    button { background:#1b2a3f; border:1px solid #2a3d57; color:#e7eef7; padding:9px 10px; border-radius:8px; cursor:pointer; }
    button:hover { filter: brightness(1.08); }
    button:disabled { opacity:.45; cursor:not-allowed; }
    input { background:#0b111a; border:1px solid #2a3d57; color:#e7eef7; padding:8px; border-radius:8px; }
    a { color:#73f59a; text-decoration:none; }
    a:hover { text-decoration:underline; }
    .k { opacity:.75; font-size:12px; }
    .v { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace; }
    pre { background:#070b10; border:1px solid #1a2432; border-radius:10px; padding:10px; height: 38vh; overflow:auto; white-space: pre-wrap; word-break: break-word; }
    .ok { color:#73f59a; }
    .bad { color:#ff6b6b; }
    .pill { padding:2px 8px; border-radius:999px; border:1px solid #2a3d57; background:#0b111a; }
    .tiny { font-size: 12px; opacity: .8; }
  </style>
</head>
<body>
<div class="wrap">
  <div id="map"></div>

  <div class="side">
    <div class="card">
      <div class="row" style="justify-content:space-between;">
        <div>
          <div class="k">Status</div>
          <div id="status" class="v bad">desconectado</div>
        </div>
        <div style="text-align:right">
          <div class="k">UTC</div>
          <div id="utc" class="v">—</div>
        </div>
      </div>

      <hr style="border:0;border-top:1px solid #1a2432;margin:12px 0">

      <div class="row">
        <div style="flex:1">
          <div class="k">Latitude</div>
          <div id="lat" class="v">—</div>
        </div>
        <div style="flex:1">
          <div class="k">Longitude</div>
          <div id="lon" class="v">—</div>
        </div>
      </div>

      <div class="row" style="margin-top:10px">
        <div style="flex:1">
          <div class="k">Altitude (m)</div>
          <div id="alt" class="v">—</div>
        </div>
        <div style="flex:1">
          <div class="k">Velocidade</div>
          <div id="spd" class="v">—</div>
        </div>
      </div>

      <div class="row" style="margin-top:10px; justify-content:space-between;">
        <div class="row">
          <span class="k">Fix:</span>
          <span id="fix" class="pill v">—</span>
        </div>
        <div class="row">
          <a id="gmap" class="v" href="#" target="_blank">Google Maps</a>
          <span class="tiny">|</span>
          <a id="osm" class="v" href="#" target="_blank">OSM</a>
        </div>
      </div>
    </div>

    <div class="card">
      <div class="k" style="margin-bottom:8px">Controles GNSS</div>

      <div class="row" style="margin-bottom:10px">
        <button onclick="cmd('gnss_on')">GNSS ON</button>
        <button onclick="cmd('gnss_off')">GNSS OFF</button>
        <button onclick="cmd('ping')">AT</button>
      </div>

      <div class="row" style="margin-bottom:10px">
        <button onclick="cmd('cold')">COLD</button>
        <button onclick="cmd('warm')">WARM</button>
        <button onclick="cmd('hot')">HOT</button>
      </div>

      <div class="row" style="margin-bottom:10px">
        <label class="k" style="width:100%">NMEA rate (Hz)</label>
        <input id="nmea_rate" type="number" min="1" max="10" value="1" style="width:110px">
        <button onclick="setNmeaRate()">Aplicar</button>
      </div>

      <div class="row">
        <label class="k" style="width:100%">CGNSSMODE</label>
        <input id="gnss_mode" type="number" min="0" max="10" value="7" style="width:110px">
        <button onclick="setGnssMode()">Aplicar</button>
      </div>
    </div>

    <div class="card">
      <div class="k" style="margin-bottom:8px">Trajeto</div>

      <div class="row" style="margin-bottom:10px">
        <input id="track_name" placeholder="nome do trajeto" value="trajeto" style="flex:1">
      </div>

      <div class="row" style="margin-bottom:10px">
        <button id="bt_start" onclick="trackStart()">Iniciar</button>
        <button id="bt_pause" onclick="trackPause()">Pausar</button>
        <button id="bt_resume" onclick="trackResume()">Continuar</button>
        <button id="bt_stop" onclick="trackStop()">Parar</button>
      </div>

      <div class="row" style="margin-bottom:10px">
        <button onclick="trackVisualizar()">Visualizar</button>
        <button onclick="trackSalvar()">Salvar</button>
        <button onclick="trackLimparMapa()">Limpar mapa</button>
      </div>

      <div class="row" style="justify-content:space-between;">
        <div class="row">
          <span class="k">Estado:</span>
          <span id="track_state" class="pill v">—</span>
        </div>
        <div class="row">
          <span class="k">Pontos:</span>
          <span id="track_count" class="v">0</span>
        </div>
      </div>

      <div id="saved_links" class="tiny" style="margin-top:8px; opacity:.9"></div>

      <div class="row" style="margin-top:10px">
        <button onclick="tracksList()">Listar salvos</button>
      </div>
      <div id="tracks_list" class="tiny" style="margin-top:8px"></div>
    </div>

    <div class="card">
      <div class="k" style="margin-bottom:8px">Log ao vivo</div>
      <pre id="log"></pre>
      <div class="row" style="margin-top:10px">
        <button onclick="clearLog()">Limpar</button>
      </div>
    </div>
  </div>
</div>

<script>
  const map = L.map('map').setView([0,0], 2);
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19, attribution: '&copy; OpenStreetMap'
  }).addTo(map);

  const marker = L.marker([0,0]).addTo(map);
  let firstFix = true;

  let trackLine = L.polyline([], {}).addTo(map);
  let liveRecording = false;
  let livePaused = false;

  const logEl = document.getElementById('log');
  function appendLog(line) {
    logEl.textContent += line + "\n";
    logEl.scrollTop = logEl.scrollHeight;
  }
  function clearLog() { logEl.textContent = ""; }

  async function cmd(action, payload={}) {
    const res = await fetch('/api/command', {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify({action, ...payload})
    });
    const j = await res.json();
    if (!j.ok) appendLog("[ERR] " + (j.error || "falha"));
  }

  function setNmeaRate() {
    const hz = parseInt(document.getElementById('nmea_rate').value || "1", 10);
    cmd('set_nmea_rate', {hz});
  }
  function setGnssMode() {
    const mode = parseInt(document.getElementById('gnss_mode').value || "7", 10);
    cmd('set_gnss_mode', {mode});
  }

  function setTrackButtons(recording, paused){
    document.getElementById('bt_start').disabled = recording;
    document.getElementById('bt_stop').disabled = !recording;
    document.getElementById('bt_pause').disabled = !recording || paused;
    document.getElementById('bt_resume').disabled = !recording || !paused;
  }

  function trackLimparMapa(){
    trackLine.setLatLngs([]);
    appendLog("[INFO] polyline limpa");
  }

  async function trackStart(){
    const name = document.getElementById('track_name').value || "trajeto";
    const res = await fetch('/api/track/start', {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify({name})
    });
    const j = await res.json();
    if (!j.ok) return appendLog("[ERR] " + (j.error || "falha"));
    trackLine.setLatLngs([]);
    document.getElementById('saved_links').textContent = "";
    appendLog("[INFO] trajeto iniciado");
  }

  async function trackPause(){
    await fetch('/api/track/pause', {method:'POST'});
    appendLog("[INFO] trajeto pausado");
  }

  async function trackResume(){
    await fetch('/api/track/resume', {method:'POST'});
    appendLog("[INFO] trajeto continuando");
  }

  async function trackStop(){
    await fetch('/api/track/stop', {method:'POST'});
    appendLog("[INFO] trajeto parado");
  }

  async function trackVisualizar(){
    const res = await fetch('/api/track/geojson');
    const j = await res.json();
    if (!j.ok) return appendLog("[ERR] não foi possível carregar trajeto");

    const coords = j.geojson.features[0].geometry.coordinates; // [lon,lat]
    const latlngs = coords.map(c => [c[1], c[0]]);
    trackLine.setLatLngs(latlngs);
    if (latlngs.length > 1) map.fitBounds(trackLine.getBounds(), {padding:[20,20]});
    appendLog("[INFO] trajeto exibido no mapa");
  }

  async function trackSalvar(){
    const res = await fetch('/api/track/save', {method:'POST'});
    const j = await res.json();
    if (!j.ok) return appendLog("[ERR] " + (j.error || "falha ao salvar"));

    const base = j.saved.base;
    const gpx = j.saved.gpx_name;
    const geo = j.saved.geojson_name;

    const links = document.getElementById('saved_links');
    links.innerHTML =
      `Salvo: <a target="_blank" href="/download/${gpx}">${gpx}</a> | ` +
      `<a target="_blank" href="/download/${geo}">${geo}</a>`;

    appendLog("[OK] arquivos salvos: " + base);
  }

  async function tracksList(){
    const res = await fetch('/api/track/list');
    const j = await res.json();
    if (!j.ok) return appendLog("[ERR] falha ao listar");
    const box = document.getElementById('tracks_list');
    if (!j.files.length) { box.textContent = "nenhum arquivo salvo"; return; }

    const rows = j.files.slice(0, 30).map(f => {
      return `<div>• <a target="_blank" href="/download/${f}">${f}</a></div>`;
    }).join("");
    box.innerHTML = rows;
  }

  const es = new EventSource('/stream');
  es.onmessage = (ev) => {
    const data = JSON.parse(ev.data);

    if (data.logs) data.logs.forEach(appendLog);

    const statusEl = document.getElementById('status');
    if (data.connected) {
      statusEl.textContent = "conectado";
      statusEl.classList.remove('bad'); statusEl.classList.add('ok');
    } else {
      statusEl.textContent = "desconectado";
      statusEl.classList.remove('ok'); statusEl.classList.add('bad');
    }

    if (data.fix) {
      document.getElementById('fix').textContent = data.fix.valid ? "OK" : "SEM FIX";
    }

    if (data.track) {
      liveRecording = !!data.track.recording;
      livePaused = !!data.track.paused;
      document.getElementById('track_count').textContent = data.track.count ?? 0;
      document.getElementById('track_state').textContent =
        liveRecording ? (livePaused ? "PAUSADO" : "GRAVANDO") : "PARADO";
      setTrackButtons(liveRecording, livePaused);
    }

    if (data.fix && data.fix.valid) {
      document.getElementById('lat').textContent = data.fix.lat.toFixed(6);
      document.getElementById('lon').textContent = data.fix.lon.toFixed(6);
      document.getElementById('alt').textContent = (data.fix.alt ?? "—");
      document.getElementById('spd').textContent = (data.fix.spd ?? "—");
      document.getElementById('utc').textContent = data.fix.utc || "—";

      marker.setLatLng([data.fix.lat, data.fix.lon]);

      const gmap = document.getElementById('gmap');
      gmap.href = `https://www.google.com/maps?q=${data.fix.lat},${data.fix.lon}`;

      const osm = document.getElementById('osm');
      osm.href = `https://www.openstreetmap.org/?mlat=${data.fix.lat}&mlon=${data.fix.lon}#map=18/${data.fix.lat}/${data.fix.lon}`;

      if (firstFix) {
        map.setView([data.fix.lat, data.fix.lon], 17);
        firstFix = false;
      }

      if (liveRecording && !livePaused) {
        const pts = trackLine.getLatLngs();
        pts.push([data.fix.lat, data.fix.lon]);
        trackLine.setLatLngs(pts);
      }
    }
  };
</script>
</body>
</html>
"""

app = Flask(__name__)

state_lock = threading.Lock()
current_fix = {
    "valid": False,
    "lat": 0.0,
    "lon": 0.0,
    "alt": None,
    "spd": None,
    "utc": None,
}

connected_lock = threading.Lock()
connected = False

log_lock = threading.Lock()
log_seq = 0
log_buf = deque(maxlen=500)

cmd_q: "queue.Queue[str]" = queue.Queue()

track_lock = threading.Lock()
track_state = {
    "recording": False,
    "paused": False,
    "points": [],     # {ts, lat, lon, alt, spd}
    "started_at": None,
    "stopped_at": None,
    "name": "trajeto",
}

def _log(line: str):
    global log_seq
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    msg = f"[{ts}] {line}"
    with log_lock:
        log_seq += 1
        log_buf.append((log_seq, msg))

def _set_connected(v: bool):
    global connected
    with connected_lock:
        connected = v

def _get_connected() -> bool:
    with connected_lock:
        return bool(connected)

def ddmm_to_decimal(v: str, hemi: str) -> float:
    x = float(v)
    deg = int(x // 100)
    minutes = x - deg * 100
    dec = deg + minutes / 60.0
    if hemi in ("S", "W"):
        dec = -dec
    return dec

def parse_cgpsinfo(lines):
    for l in lines:
        if l.startswith("+CGPSINFO:"):
            payload = l.split(":", 1)[1].strip()
            parts = [p.strip() for p in payload.split(",")]
            if len(parts) < 4 or parts[0] == "" or parts[2] == "":
                return None
            lat = ddmm_to_decimal(parts[0], parts[1])
            lon = ddmm_to_decimal(parts[2], parts[3])
            date = parts[4] if len(parts) > 4 else ""
            utc = parts[5] if len(parts) > 5 else ""
            alt = parts[6] if len(parts) > 6 and parts[6] != "" else None
            spd = parts[7] if len(parts) > 7 and parts[7] != "" else None
            return {
                "valid": True,
                "lat": lat,
                "lon": lon,
                "alt": float(alt) if alt is not None else None,
                "spd": float(spd) if spd is not None else None,
                "utc": (f"{date} {utc}".strip() if (date or utc) else None),
            }
    return None

def read_until_ok(ser: serial.Serial, timeout_s: float = 2.0):
    end = time.time() + timeout_s
    out = []
    while time.time() < end:
        line = ser.readline().decode(errors="ignore").strip()
        if not line:
            continue
        out.append(line)
        if line == "OK" or line.startswith("ERROR"):
            break
    return out

def send_cmd(ser: serial.Serial, cmd: str, log_cmd: bool = True):
    ser.write((cmd + "\r").encode())
    ser.flush()
    lines = read_until_ok(ser)
    if log_cmd:
        for l in lines:
            _log(f"{cmd} -> {l}")
    return lines

def enqueue(cmd: str):
    cmd_q.put(cmd)

def track_add_point(fix: dict):
    if not fix or not fix.get("valid"):
        return
    with track_lock:
        if not track_state["recording"] or track_state["paused"]:
            return
        track_state["points"].append({
            "ts": time.time(),
            "lat": fix["lat"],
            "lon": fix["lon"],
            "alt": fix.get("alt"),
            "spd": fix.get("spd"),
        })

def init_gnss(ser: serial.Serial):
    send_cmd(ser, "AT")
    send_cmd(ser, "AT+CMEE=2")
    send_cmd(ser, "AT+CGNSSPWR=1")
    send_cmd(ser, f"AT+CGNSSMODE={DEFAULT_GNSS_MODE}")
    send_cmd(ser, f"AT+CGPSNMEARATE={DEFAULT_NMEA_RATE}")
    send_cmd(ser, "AT+CGPSINFO=0")

def serial_worker():
    while True:
        try:
            _log(f"abrindo {SERIAL_PORT} @ {SERIAL_BAUD}")
            with serial.Serial(SERIAL_PORT, SERIAL_BAUD, timeout=1) as ser:
                ser.reset_input_buffer()
                _set_connected(True)
                _log("porta serial conectada")

                init_gnss(ser)

                last_poll = 0.0
                while True:
                    try:
                        cmd = cmd_q.get_nowait()
                        send_cmd(ser, cmd, log_cmd=True)
                    except queue.Empty:
                        pass

                    now = time.time()
                    if now - last_poll >= POLL_INTERVAL_S:
                        last_poll = now
                        lines = send_cmd(ser, "AT+CGPSINFO", log_cmd=False)
                        fix = parse_cgpsinfo(lines)

                        with state_lock:
                            if fix:
                                current_fix.update(fix)
                            else:
                                current_fix["valid"] = False

                        if fix:
                            track_add_point(fix)

                    time.sleep(0.02)

        except Exception as e:
            _set_connected(False)
            _log(f"ERRO serial: {type(e).__name__}: {e}")
            time.sleep(2.0)

def _geojson_from_points(points, name="trajeto"):
    return {
        "type": "FeatureCollection",
        "features": [{
            "type": "Feature",
            "properties": {"name": name},
            "geometry": {
                "type": "LineString",
                "coordinates": [[p["lon"], p["lat"]] for p in points]
            }
        }]
    }

def _gpx_from_points(points, name="trajeto"):
    def esc(s):
        return (s or "").replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
    def iso_utc(ts):
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))

    out = []
    out.append('<?xml version="1.0" encoding="UTF-8"?>')
    out.append('<gpx version="1.1" creator="GNSS Monitor" xmlns="http://www.topografix.com/GPX/1/1">')
    out.append(f"<trk><name>{esc(name)}</name><trkseg>")
    for p in points:
        out.append(f'<trkpt lat="{p["lat"]:.8f}" lon="{p["lon"]:.8f}">')
        if p.get("alt") is not None:
            out.append(f"<ele>{p['alt']}</ele>")
        out.append(f"<time>{iso_utc(p['ts'])}</time>")
        out.append("</trkpt>")
    out.append("</trkseg></trk></gpx>")
    return "\n".join(out)

def _safe_filename(fn: str) -> str:
    fn = (fn or "").strip()
    if not fn:
        return ""
    if "/" in fn or "\\" in fn:
        return ""
    if not (fn.endswith(".gpx") or fn.endswith(".geojson")):
        return ""
    return fn

@app.get("/")
def index():
    return render_template_string(HTML)

@app.get("/stream")
def stream():
    def gen():
        last_seen = 0
        while True:
            with state_lock:
                fix_copy = dict(current_fix)

            with track_lock:
                track_meta = {
                    "recording": bool(track_state["recording"]),
                    "paused": bool(track_state["paused"]),
                    "count": len(track_state["points"]),
                    "name": track_state["name"],
                }

            with log_lock:
                new = [msg for (seq, msg) in list(log_buf) if seq > last_seen]
                if log_buf:
                    last_seen = log_buf[-1][0]

            payload = {
                "connected": _get_connected(),
                "fix": fix_copy,
                "track": track_meta,
                "logs": new[-25:],
            }
            yield f"data: {json.dumps(payload)}\n\n"
            time.sleep(1.0)

    return Response(gen(), mimetype="text/event-stream")

@app.post("/api/command")
def api_command():
    try:
        data = request.get_json(force=True) or {}
        action = (data.get("action") or "").strip()

        if action == "ping":
            enqueue("AT")

        elif action == "gnss_on":
            enqueue("AT+CGNSSPWR=1")

        elif action == "gnss_off":
            enqueue("AT+CGNSSPWR=0")

        elif action == "cold":
            enqueue("AT+CGPSCOLD")

        elif action == "warm":
            enqueue("AT+CGPSWARM")

        elif action == "hot":
            enqueue("AT+CGPSHOT")

        elif action == "set_nmea_rate":
            hz = int(data.get("hz", 1))
            if hz < 1 or hz > 10:
                return jsonify(ok=False, error="hz inválido (1..10)"), 400
            enqueue(f"AT+CGPSNMEARATE={hz}")

        elif action == "set_gnss_mode":
            mode = int(data.get("mode", DEFAULT_GNSS_MODE))
            if mode < 0 or mode > 10:
                return jsonify(ok=False, error="mode inválido"), 400
            enqueue(f"AT+CGNSSMODE={mode}")

        else:
            return jsonify(ok=False, error="ação desconhecida"), 400

        return jsonify(ok=True)

    except Exception as e:
        return jsonify(ok=False, error=str(e)), 500

@app.get("/api/track/status")
def track_status():
    with track_lock:
        return jsonify(ok=True, track={
            "recording": track_state["recording"],
            "paused": track_state["paused"],
            "count": len(track_state["points"]),
            "started_at": track_state["started_at"],
            "stopped_at": track_state["stopped_at"],
            "name": track_state["name"],
        })

@app.post("/api/track/start")
def track_start():
    data = request.get_json(force=True) or {}
    name = (data.get("name") or "trajeto").strip()[:80]
    safe_name = "".join(c for c in name if c.isalnum() or c in ("-","_"," ")).strip() or "trajeto"
    with track_lock:
        track_state["recording"] = True
        track_state["paused"] = False
        track_state["points"] = []
        track_state["started_at"] = time.time()
        track_state["stopped_at"] = None
        track_state["name"] = safe_name
    _log(f"track: start ({safe_name})")
    return jsonify(ok=True)

@app.post("/api/track/pause")
def track_pause():
    with track_lock:
        if track_state["recording"]:
            track_state["paused"] = True
    _log("track: pause")
    return jsonify(ok=True)

@app.post("/api/track/resume")
def track_resume():
    with track_lock:
        if track_state["recording"]:
            track_state["paused"] = False
    _log("track: resume")
    return jsonify(ok=True)

@app.post("/api/track/stop")
def track_stop():
    with track_lock:
        if track_state["recording"]:
            track_state["recording"] = False
            track_state["paused"] = False
            track_state["stopped_at"] = time.time()
    _log("track: stop")
    return jsonify(ok=True)

@app.get("/api/track/geojson")
def track_geojson():
    with track_lock:
        points = list(track_state["points"])
        name = track_state["name"] or "trajeto"
    return jsonify(ok=True, geojson=_geojson_from_points(points, name=name))

@app.post("/api/track/save")
def track_save():
    with track_lock:
        points = list(track_state["points"])
        name = (track_state["name"] or "trajeto").strip() or "trajeto"

    if len(points) < 2:
        return jsonify(ok=False, error="trajeto muito curto (>= 2 pontos)"), 400

    ts = time.strftime("%Y%m%d-%H%M%S")
    base_name = "".join(c for c in name if c.isalnum() or c in ("-","_")).strip("_-") or "trajeto"
    base = f"{base_name}-{ts}"

    geo_name = f"{base}.geojson"
    gpx_name = f"{base}.gpx"

    geo_path = TRACK_DIR / geo_name
    gpx_path = TRACK_DIR / gpx_name

    geo_path.write_text(json.dumps(_geojson_from_points(points, name=name), ensure_ascii=False, indent=2), encoding="utf-8")
    gpx_path.write_text(_gpx_from_points(points, name=name), encoding="utf-8")

    _log(f"track: saved {base}")
    return jsonify(ok=True, saved={
        "base": base,
        "geojson_name": geo_name,
        "gpx_name": gpx_name,
    })

@app.get("/api/track/list")
def track_list():
    files = []
    for p in TRACK_DIR.iterdir():
        if p.is_file() and (p.name.endswith(".gpx") or p.name.endswith(".geojson")):
            files.append(p.name)
    files.sort(reverse=True)
    return jsonify(ok=True, files=files)

@app.get("/download/<path:filename>")
def download_file(filename):
    fn = _safe_filename(filename)
    if not fn:
        abort(404)
    path = TRACK_DIR / fn
    if not path.exists() or not path.is_file():
        abort(404)
    return send_from_directory(TRACK_DIR, fn, as_attachment=True)

def main():
    t = threading.Thread(target=serial_worker, daemon=True)
    t.start()
    _log("web iniciando")
    app.run(host=HTTP_HOST, port=HTTP_PORT, debug=False, threaded=True)

if __name__ == "__main__":
    main()

