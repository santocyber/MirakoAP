sudo pip3 install dbus-next --break-system-packages

sudo modprobe rfcomm
sudo modprobe bnep

sudo nano /etc/bluetooth/main.conf
[General]
JustWorksRepairing = always
Experimental = true









sudo tee /usr/local/bin/mirako_bt.py >/dev/null <<'EOF'
#!/usr/bin/env python3
import os
import time
import asyncio
import subprocess
import threading
import logging
import select
import re
import json
from typing import Optional, Dict, Any, List

from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method, dbus_property, PropertyAccess
from dbus_next.constants import BusType
from dbus_next import Variant

logging.basicConfig(level=logging.INFO)

BT_NAME = "MirakoAP"
PIN_STR = "1234"
PASSKEY = 1234

PROFILES = "/usr/local/bin/profiles.sh"

# BLE Nordic UART Service (NUS)
NUS_SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
NUS_RX_UUID      = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"  # write
NUS_TX_UUID      = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"  # notify

# Classic SPP UUID
SPP_UUID = "00001101-0000-1000-8000-00805f9b34fb"
SPP_CHANNEL = 1

BLUEZ = "org.bluez"
DBUS_OM = "org.freedesktop.DBus.ObjectManager"
DBUS_PROP = "org.freedesktop.DBus.Properties"

# ----- estado global RSSI (comando rssi do terminal) -----
DBUS_BUS = None
MAIN_LOOP = None
LAST_DEVICE_PATH: Optional[str] = None
LAST_DEVICE_MAC: Optional[str] = None

# ----- Web -----
WEB_HOST = "0.0.0.0"
WEB_PORT = 5002

WEB_STATE = {
    "devices": [],
    "updated_at": 0.0,
    "last_error": ""
}

HISTORY_MAX_POINTS = 240   # por device (~4 min se 1s)
HISTORY_TTL_S = 900        # mantém histórico por 15 min
SEEN_TTL_S = 600           # mantém device visto no scan por 10 min
RSSI_HISTORY: Dict[str, List[Dict[str, Any]]] = {}  # mac -> [{"ts":..., "rssi":...}]
SEEN: Dict[str, Dict[str, Any]] = {}                # mac -> {name, mac, last_seen, scan_rssi, connected,...}


def exec_profile(p):
    try:
        out = subprocess.check_output([PROFILES, p], stderr=subprocess.STDOUT, text=True, timeout=180)
        return out.strip() or "ok"
    except subprocess.CalledProcessError as e:
        return (e.output or "erro").strip()
    except Exception as e:
        return f"erro: {e}"


def _device_path_to_mac(path: Optional[str]) -> Optional[str]:
    if not path:
        return None
    m = re.search(r"/dev_([0-9A-Fa-f_]{17})$", path)
    if not m:
        return None
    return m.group(1).replace("_", ":").upper()


async def _get_rssi_via_dbus_async(device_path: str) -> Optional[int]:
    global DBUS_BUS
    if DBUS_BUS is None:
        return None
    try:
        introspect = await DBUS_BUS.introspect(BLUEZ, device_path)
        props = DBUS_BUS.get_proxy_object(BLUEZ, device_path, introspect).get_interface(DBUS_PROP)
        v = await props.call_get("org.bluez.Device1", "RSSI")
        if isinstance(v, Variant):
            return int(v.value)
        return int(v)
    except Exception:
        return None


def _get_rssi_via_dbus_sync() -> Optional[int]:
    global MAIN_LOOP, LAST_DEVICE_PATH
    if not MAIN_LOOP or not LAST_DEVICE_PATH:
        return None
    fut = asyncio.run_coroutine_threadsafe(_get_rssi_via_dbus_async(LAST_DEVICE_PATH), MAIN_LOOP)
    try:
        return fut.result(timeout=2.0)
    except Exception:
        return None


def _get_rssi_via_hcitool(mac: str) -> Optional[int]:
    try:
        out = subprocess.check_output(["hcitool", "rssi", mac], text=True, stderr=subprocess.STDOUT, timeout=2)
        m = re.search(r"RSSI\s+return\s+value:\s*(-?\d+)", out, re.IGNORECASE)
        if m:
            return int(m.group(1))
        m2 = re.search(r"(-?\d+)\s*$", out.strip())
        if m2:
            return int(m2.group(1))
        return None
    except Exception:
        return None


def _get_rssi_via_btmgmt_conn_info(mac: str) -> Optional[int]:
    try:
        out = subprocess.check_output(["btmgmt", "conn-info", mac], text=True, stderr=subprocess.STDOUT, timeout=3)
        m = re.search(r"\bRSSI\b.*?(-?\d+)", out, re.IGNORECASE)
        return int(m.group(1)) if m else None
    except Exception:
        return None


def get_rssi_best_effort() -> Optional[int]:
    """
    Para o comando "rssi" no terminal (usa o LAST_DEVICE_*):
      1) Device1.RSSI (DBus)
      2) hcitool rssi
      3) btmgmt conn-info
    """
    global LAST_DEVICE_MAC

    rssi = _get_rssi_via_dbus_sync()
    if isinstance(rssi, int):
        return rssi

    mac = LAST_DEVICE_MAC or _device_path_to_mac(LAST_DEVICE_PATH)
    if mac:
        LAST_DEVICE_MAC = mac

        rssi = _get_rssi_via_hcitool(mac)
        if isinstance(rssi, int):
            return rssi

        rssi = _get_rssi_via_btmgmt_conn_info(mac)
        if isinstance(rssi, int):
            return rssi

    return None


def handle_command(cmd: str) -> str:
    cmd = (cmd or "").strip().lower()

    if cmd == "help":
        return "help | ap | client-wifi | reboot | rssi | web"

    if cmd == "web":
        return f"Web: http://IP_DO_DISPOSITIVO:{WEB_PORT}/  | JSON: /api/rssi"

    if cmd == "rssi":
        rssi = get_rssi_best_effort()
        src = "conn"
        if rssi is None:
            mac = LAST_DEVICE_MAC
            if mac and mac in SEEN and isinstance(SEEN[mac].get("scan_rssi"), int):
                rssi = int(SEEN[mac]["scan_rssi"])
                src = "scan"
            else:
                return "RSSI indisponivel (conexao nao expõe e scan ainda nao viu esse device)."
        return f"RSSI({src}): {rssi} dBm"

    if cmd == "ap":
        return exec_profile("ap")

    if cmd == "client-wifi":
        return exec_profile("client-wifi")

    if cmd in ("reboot", "restart"):
        subprocess.Popen(["/sbin/reboot"])
        return "Reiniciando..."

    return "Comando invalido"


# ---------------------------
# Web (HTML + JSON + gráfico por CHECKBOX + busca)
# ---------------------------
def render_html():
    return """<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <title>Bluetooth RSSI</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
  <style>
    body { font-family: Arial, sans-serif; margin: 20px; }
    table { border-collapse: collapse; width: 100%; margin-top: 10px; }
    th, td { border: 1px solid #ddd; padding: 8px; vertical-align: middle; }
    th { background: #f5f5f5; text-align: left; position: sticky; top: 0; z-index: 1; }
    .small { color:#666; font-size: 12px; }
    .row { display:flex; gap: 16px; flex-wrap: wrap; }
    .card { border:1px solid #ddd; padding:12px; border-radius:8px; flex: 1 1 520px; }
    canvas { width:100%; height:340px; }
    .pill { display:inline-block; padding:2px 8px; border-radius:999px; font-size:12px; background:#eee; }
    code { background:#f2f2f2; padding:2px 6px; border-radius:6px; }
    .toolbar { display:flex; gap: 10px; align-items:center; margin: 10px 0 8px; flex-wrap: wrap; }
    input[type="text"] { padding: 7px 10px; border:1px solid #ccc; border-radius: 8px; min-width: 260px; }
    .btn { padding: 7px 10px; border:1px solid #ccc; border-radius: 8px; background:#fafafa; cursor:pointer; }
    .btn:active { transform: translateY(1px); }
    .muted { color:#888; }
    .tablewrap { max-height: 520px; overflow: auto; border:1px solid #eee; border-radius: 8px; }
    .chk { width: 18px; height: 18px; }
  </style>
</head>
<body>
  <h2>Bluetooth RSSI</h2>
  <div class="small">JSON: <code>/api/rssi</code></div>

  <div class="toolbar">
    <b>Buscar:</b>
    <input id="search" type="text" placeholder="Filtrar por nome ou MAC..."/>
    <button class="btn" id="btnClear">Limpar</button>
    <button class="btn" id="btnAll">Marcar todos (visíveis)</button>
    <button class="btn" id="btnNone">Desmarcar todos</button>
    <span class="small muted" id="selInfo"></span>
  </div>

  <div id="status" class="small"></div>

  <div class="row">
    <div class="card">
      <b>Gráfico RSSI (selecionados)</b>
      <canvas id="rssiChart"></canvas>
      <div class="small">Dica: marque os checkboxes na tabela para adicionar/remover linhas do gráfico.</div>
    </div>

    <div class="card">
      <b>Devices (conectados + vistos no scan)</b>
      <div class="tablewrap">
        <table>
          <thead>
            <tr>
              <th style="width:40px;"><input class="chk" type="checkbox" id="chkHeader" title="Marcar/desmarcar todos (visíveis)"/></th>
              <th>Nome</th>
              <th>MAC</th>
              <th>Status</th>
              <th>RSSI (conexão)</th>
              <th>RSSI (scan)</th>
              <th>Último visto</th>
            </tr>
          </thead>
          <tbody id="tbody">
            <tr><td colspan="7">Carregando...</td></tr>
          </tbody>
        </table>
      </div>
      <div class="small">Obs: BLE pode não reportar RSSI em conexão; RSSI(scan) vem do discovery.</div>
    </div>
  </div>

<script>
let chart = null;
let lastPayload = null;

const LS_KEY = 'selectedMacs';
let selected = new Set(JSON.parse(localStorage.getItem(LS_KEY) || '[]'));

function saveSelected() {
  localStorage.setItem(LS_KEY, JSON.stringify(Array.from(selected)));
  renderSelectedInfo();
}

function renderSelectedInfo() {
  const el = document.getElementById('selInfo');
  el.textContent = `Selecionados: ${selected.size}`;
}

function colorForMac(mac) {
  let h = 0;
  for (let i=0;i<mac.length;i++) h = (h*31 + mac.charCodeAt(i)) >>> 0;
  const hue = h % 360;
  return `hsl(${hue}, 70%, 45%)`;
}

function fmtTime(ts) {
  if (!ts) return '-';
  const d = new Date(ts * 1000);
  return d.toLocaleTimeString();
}

async function fetchData() {
  const r = await fetch('/api/rssi');
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return await r.json();
}

function setStatus(txt) {
  document.getElementById('status').textContent = txt;
}

function getSearchTerm() {
  return (document.getElementById('search').value || '').trim().toLowerCase();
}

function filterDevices(devices) {
  const q = getSearchTerm();
  if (!q) return devices || [];
  return (devices || []).filter(d => {
    const name = (d.name || '').toLowerCase();
    const mac = (d.mac || '').toLowerCase();
    return name.includes(q) || mac.includes(q);
  });
}

function getVisibleMacs(filteredDevices) {
  return filteredDevices.map(d => d.mac).filter(Boolean);
}

function renderTable(devicesRaw) {
  const tb = document.getElementById('tbody');
  const devices = filterDevices(devicesRaw);

  if (!devices || devices.length === 0) {
    tb.innerHTML = '<tr><td colspan="7">Nenhum device.</td></tr>';
    document.getElementById('chkHeader').checked = false;
    return;
  }

  const rows = devices.map(d => {
    const name = (d.name || '');
    const mac = (d.mac || '');
    const connected = !!d.connected;
    const lastSeen = d.last_seen || 0;

    const rssiConn = (typeof d.rssi_conn === 'number') ? (d.rssi_conn + ' dBm') : '—';
    const rssiScan = (typeof d.rssi_scan === 'number') ? (d.rssi_scan + ' dBm') : '—';
    const st = connected ? '<span class="pill">conectado</span>' : '<span class="pill">scan</span>';

    const checked = selected.has(mac) ? 'checked' : '';

    return `<tr data-mac="${mac}">
      <td><input class="chk rowchk" type="checkbox" data-mac="${mac}" ${checked}/></td>
      <td>${name}</td>
      <td>${mac}</td>
      <td>${st}</td>
      <td>${rssiConn}</td>
      <td>${rssiScan}</td>
      <td>${fmtTime(lastSeen)}</td>
    </tr>`;
  }).join('');

  tb.innerHTML = rows;

  // liga handlers
  document.querySelectorAll('.rowchk').forEach(chk => {
    chk.addEventListener('change', (ev) => {
      const mac = ev.target.getAttribute('data-mac');
      if (!mac) return;
      if (ev.target.checked) selected.add(mac);
      else selected.delete(mac);
      saveSelected();
      renderChartFromPayload(lastPayload); // atualiza gráfico sem esperar poll
      syncHeaderCheckbox(devicesRaw);
    });
  });

  syncHeaderCheckbox(devicesRaw);
}

function syncHeaderCheckbox(devicesRaw) {
  const filtered = filterDevices(devicesRaw || []);
  const visible = getVisibleMacs(filtered);
  const header = document.getElementById('chkHeader');
  if (!visible.length) { header.checked = false; header.indeterminate = false; return; }

  let count = 0;
  for (const mac of visible) if (selected.has(mac)) count++;

  if (count === 0) { header.checked = false; header.indeterminate = false; }
  else if (count === visible.length) { header.checked = true; header.indeterminate = false; }
  else { header.checked = false; header.indeterminate = true; }
}

function getSelectedHistory(historyMapRaw) {
  const h = historyMapRaw || {};
  const out = {};
  for (const mac of selected) {
    if (h[mac]) out[mac] = h[mac];
  }
  return out;
}

function renderChart(historyMapSelected) {
  const ctx = document.getElementById('rssiChart').getContext('2d');
  const macs = Object.keys(historyMapSelected || {});
  if (macs.length === 0) {
    if (chart) {
      chart.data.labels = [];
      chart.data.datasets = [];
      chart.update();
    }
    return;
  }

  // usa como base o mais longo
  let baseMac = macs[0];
  for (const m of macs) {
    if ((historyMapSelected[m] || []).length > (historyMapSelected[baseMac] || []).length) baseMac = m;
  }

  const base = historyMapSelected[baseMac] || [];
  const labels = base.map(p => fmtTime(p.ts));

  const datasets = macs.map(mac => {
    const arr = historyMapSelected[mac] || [];
    const data = arr.map(p => p.rssi);
    const col = colorForMac(mac);
    return {
      label: mac,
      data,
      borderColor: col,
      backgroundColor: col,
      tension: 0.25,
      pointRadius: 0,
      borderWidth: 2
    };
  });

  if (!chart) {
    chart = new Chart(ctx, {
      type: 'line',
      data: { labels, datasets },
      options: {
        responsive: true,
        animation: false,
        scales: {
          y: { suggestedMin: -100, suggestedMax: -30 }
        },
        plugins: {
          legend: { display: true, position: 'bottom' }
        }
      }
    });
  } else {
    chart.data.labels = labels;
    chart.data.datasets = datasets;
    chart.update();
  }
}

function renderChartFromPayload(payload) {
  if (!payload) return;
  const selectedHistory = getSelectedHistory(payload.history || {});
  renderChart(selectedHistory);
}

async function tick() {
  try {
    const payload = await fetchData();
    lastPayload = payload;

    const updated = payload.updated_at ? new Date(payload.updated_at*1000).toLocaleTimeString() : '-';
    const err = payload.error ? (' | erro: ' + payload.error) : '';
    setStatus('Atualizado: ' + updated + err);

    const devices = payload.devices || [];

    // opcional: auto-selecionar se nada foi escolhido ainda (não forçar)
    // if (selected.size === 0 && devices.length) { selected.add(devices[0].mac); saveSelected(); }

    renderTable(devices);
    renderChartFromPayload(payload);

  } catch(e) {
    setStatus('Erro: ' + e);
  }
}

document.getElementById('search').addEventListener('input', () => {
  // re-render tabela com filtro e mantém seleção
  if (lastPayload) {
    renderTable(lastPayload.devices || []);
    syncHeaderCheckbox(lastPayload.devices || []);
  }
});

document.getElementById('btnClear').addEventListener('click', () => {
  document.getElementById('search').value = '';
  if (lastPayload) renderTable(lastPayload.devices || []);
});

document.getElementById('btnNone').addEventListener('click', () => {
  selected.clear();
  saveSelected();
  if (lastPayload) {
    renderTable(lastPayload.devices || []);
    renderChartFromPayload(lastPayload);
  }
});

document.getElementById('btnAll').addEventListener('click', () => {
  if (!lastPayload) return;
  const filtered = filterDevices(lastPayload.devices || []);
  for (const d of filtered) if (d.mac) selected.add(d.mac);
  saveSelected();
  renderTable(lastPayload.devices || []);
  renderChartFromPayload(lastPayload);
});

document.getElementById('chkHeader').addEventListener('change', (ev) => {
  if (!lastPayload) return;
  const checked = !!ev.target.checked;
  const filtered = filterDevices(lastPayload.devices || []);
  const visible = getVisibleMacs(filtered);

  if (checked) {
    for (const mac of visible) selected.add(mac);
  } else {
    for (const mac of visible) selected.delete(mac);
  }
  saveSelected();
  renderTable(lastPayload.devices || []);
  renderChartFromPayload(lastPayload);
});

renderSelectedInfo();
tick();
setInterval(tick, 2000);
</script>

</body>
</html>
"""


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


class WebHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/rssi":
            payload = {
                "updated_at": WEB_STATE["updated_at"],
                "devices": WEB_STATE["devices"],
                "history": RSSI_HISTORY,
                "error": WEB_STATE["last_error"],
            }
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path in ("/", "/index.html"):
            html = render_html().encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            self.wfile.write(html)
            return

        self.send_response(404)
        self.end_headers()
        self.wfile.write(b"Not Found")

    def log_message(self, fmt, *args):
        return


def run_web_server():
    httpd = ThreadedHTTPServer((WEB_HOST, WEB_PORT), WebHandler)
    logging.info("Web RSSI: http://%s:%d  | JSON: /api/rssi", WEB_HOST, WEB_PORT)
    httpd.serve_forever()


def _purge_old():
    now = time.time()

    for mac in list(SEEN.keys()):
        if now - float(SEEN[mac].get("last_seen", 0)) > SEEN_TTL_S:
            del SEEN[mac]

    for mac in list(RSSI_HISTORY.keys()):
        arr = RSSI_HISTORY[mac]
        RSSI_HISTORY[mac] = [p for p in arr if (now - p["ts"]) <= HISTORY_TTL_S]
        if not RSSI_HISTORY[mac]:
            del RSSI_HISTORY[mac]


async def list_devices_from_object_manager(bus: MessageBus):
    introspect = await bus.introspect(BLUEZ, "/")
    om = bus.get_proxy_object(BLUEZ, "/", introspect).get_interface(DBUS_OM)
    objs = await om.call_get_managed_objects()

    result = []
    for path, ifaces in objs.items():
        dev = ifaces.get("org.bluez.Device1")
        if not dev:
            continue

        name_v = dev.get("Alias") or dev.get("Name")
        name = name_v.value if isinstance(name_v, Variant) else (name_v or "")

        addr_v = dev.get("Address")
        mac = addr_v.value if isinstance(addr_v, Variant) else (addr_v or "")
        mac = (mac or _device_path_to_mac(path) or "").upper()
        if not mac:
            continue

        try:
            connected = bool(dev.get("Connected", Variant("b", False)).value)
        except Exception:
            connected = False

        rssi_scan = None
        try:
            rv = dev.get("RSSI")
            if rv is not None:
                rssi_scan = int(rv.value if isinstance(rv, Variant) else rv)
        except Exception:
            rssi_scan = None

        result.append({
            "path": path,
            "mac": mac,
            "name": name,
            "connected": connected,
            "rssi_scan": rssi_scan
        })

    return result


async def web_poller(bus: MessageBus):
    while True:
        try:
            now = time.time()

            objs = await list_devices_from_object_manager(bus)

            for d in objs:
                mac = d["mac"]
                name = d.get("name") or ""
                connected = bool(d.get("connected"))

                entry = SEEN.get(mac, {"mac": mac})
                entry["mac"] = mac
                if name:
                    entry["name"] = name
                entry["last_seen"] = now

                if isinstance(d.get("rssi_scan"), int):
                    entry["scan_rssi"] = int(d["rssi_scan"])
                    RSSI_HISTORY.setdefault(mac, []).append({"ts": now, "rssi": int(d["rssi_scan"])})
                    if len(RSSI_HISTORY[mac]) > HISTORY_MAX_POINTS:
                        del RSSI_HISTORY[mac][: len(RSSI_HISTORY[mac]) - HISTORY_MAX_POINTS]

                entry["connected"] = connected
                entry["path"] = d.get("path")

                if connected:
                    rssi_conn = _get_rssi_via_hcitool(mac)
                    if rssi_conn is None:
                        rssi_conn = _get_rssi_via_btmgmt_conn_info(mac)

                    if isinstance(rssi_conn, int):
                        entry["conn_rssi"] = int(rssi_conn)
                        RSSI_HISTORY.setdefault(mac, []).append({"ts": now, "rssi": int(rssi_conn)})
                        if len(RSSI_HISTORY[mac]) > HISTORY_MAX_POINTS:
                            del RSSI_HISTORY[mac][: len(RSSI_HISTORY[mac]) - HISTORY_MAX_POINTS]

                SEEN[mac] = entry

            _purge_old()

            devices = []
            for mac, e in SEEN.items():
                devices.append({
                    "name": e.get("name", ""),
                    "mac": mac,
                    "connected": bool(e.get("connected", False)),
                    "last_seen": float(e.get("last_seen", 0)),
                    "rssi_conn": e.get("conn_rssi", None),
                    "rssi_scan": e.get("scan_rssi", None),
                })

            devices.sort(key=lambda x: (not x["connected"], -x["last_seen"]))

            WEB_STATE["devices"] = devices
            WEB_STATE["updated_at"] = now
            WEB_STATE["last_error"] = ""

        except Exception as e:
            WEB_STATE["last_error"] = str(e)

        await asyncio.sleep(1.0)


# ---------------------------
# Agent DBus (pareamento)
# ---------------------------
class Agent(ServiceInterface):
    def __init__(self, path="/mirako/agent"):
        super().__init__("org.bluez.Agent1")
        self.path = path

    @method()
    def Release(self):
        return

    @method()
    def RequestPinCode(self, device: "o") -> "s":
        return PIN_STR

    @method()
    def RequestPasskey(self, device: "o") -> "u":
        return PASSKEY

    @method()
    def DisplayPinCode(self, device: "o", pincode: "s"):
        return

    @method()
    def DisplayPasskey(self, device: "o", passkey: "u", entered: "q"):
        return

    @method()
    def RequestConfirmation(self, device: "o", passkey: "u"):
        return

    @method()
    def RequestAuthorization(self, device: "o"):
        return

    @method()
    def AuthorizeService(self, device: "o", uuid: "s"):
        return

    @method()
    def Cancel(self):
        return


# ---------------------------
# BLE GATT (NUS)
# ---------------------------
class GattCharacteristic(ServiceInterface):
    def __init__(self, path, uuid, flags, service_path):
        super().__init__("org.bluez.GattCharacteristic1")
        self.path = path
        self.uuid = uuid
        self.flags = flags
        self.service_path = service_path
        self.value: bytes = b""
        self.notifying = False
        self.notify_cb = None

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> "s":
        return self.uuid

    @dbus_property(access=PropertyAccess.READ)
    def Service(self) -> "o":
        return self.service_path

    @dbus_property(access=PropertyAccess.READ)
    def Flags(self) -> "as":
        return self.flags

    @dbus_property(access=PropertyAccess.READ)
    def Value(self) -> "ay":
        return self.value

    @method()
    def ReadValue(self, options: "a{sv}") -> "ay":
        return self.value

    @method()
    def WriteValue(self, value: "ay", options: "a{sv}"):
        global LAST_DEVICE_PATH, LAST_DEVICE_MAC

        data = bytes(value)
        self.value = data

        try:
            dev = options.get("device")
            if isinstance(dev, Variant):
                dev = dev.value
            if isinstance(dev, str) and dev.startswith("/org/bluez/"):
                LAST_DEVICE_PATH = dev
                mac = _device_path_to_mac(dev)
                if mac:
                    LAST_DEVICE_MAC = mac
        except Exception:
            pass

        if self.uuid.lower() == NUS_RX_UUID.lower():
            cmd = data.decode(errors="ignore").strip()
            logging.info("BLE RX: %r", cmd)
            resp = handle_command(cmd)
            if self.notify_cb:
                self.notify_cb(resp)

    @method()
    def StartNotify(self):
        self.notifying = True
        logging.info("BLE: StartNotify %s", self.uuid)

    @method()
    def StopNotify(self):
        self.notifying = False
        logging.info("BLE: StopNotify %s", self.uuid)


class GattService(ServiceInterface):
    def __init__(self, path, uuid, primary=True):
        super().__init__("org.bluez.GattService1")
        self.path = path
        self.uuid = uuid
        self.primary = primary
        self.chars = []

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> "s":
        return self.uuid

    @dbus_property(access=PropertyAccess.READ)
    def Primary(self) -> "b":
        return self.primary

    @dbus_property(access=PropertyAccess.READ)
    def Characteristics(self) -> "ao":
        return [c.path for c in self.chars]


class Application(ServiceInterface):
    def __init__(self, path="/mirako/app"):
        super().__init__(DBUS_OM)
        self.path = path
        self.services = []

    @method()
    def GetManagedObjects(self) -> "a{oa{sa{sv}}}":
        objs = {}
        for s in self.services:
            objs[s.path] = {
                "org.bluez.GattService1": {
                    "UUID": Variant("s", s.uuid),
                    "Primary": Variant("b", s.primary),
                    "Characteristics": Variant("ao", [c.path for c in s.chars]),
                }
            }
            for c in s.chars:
                objs[c.path] = {
                    "org.bluez.GattCharacteristic1": {
                        "UUID": Variant("s", c.uuid),
                        "Service": Variant("o", c.service_path),
                        "Flags": Variant("as", c.flags),
                        "Value": Variant("ay", c.value),
                    }
                }
        return objs


class Advertisement(ServiceInterface):
    def __init__(self, path="/mirako/adv"):
        super().__init__("org.bluez.LEAdvertisement1")
        self.path = path
        self.local_name = BT_NAME
        self.service_uuids = [NUS_SERVICE_UUID]
        self.type = "peripheral"
        self._tx_power = 0  # dBm

    @dbus_property(access=PropertyAccess.READ)
    def Type(self) -> "s":
        return self.type

    @dbus_property(access=PropertyAccess.READ)
    def ServiceUUIDs(self) -> "as":
        return self.service_uuids

    @dbus_property(access=PropertyAccess.READ)
    def LocalName(self) -> "s":
        return self.local_name

    @dbus_property(access=PropertyAccess.READ)
    def Includes(self) -> "as":
        return ["tx-power"]

    @dbus_property(access=PropertyAccess.READ)
    def TxPower(self) -> "n":
        return int(self._tx_power)

    @method()
    def Release(self):
        return


# ---------------------------
# Classic SPP (Profile1)
# ---------------------------
class SPPProfile(ServiceInterface):
    def __init__(self, path="/mirako/spp_profile"):
        super().__init__("org.bluez.Profile1")
        self.path = path
        self._conn_fd: Optional[int] = None
        self._stop = False

    def _close_current(self):
        try:
            if self._conn_fd is not None:
                os.close(self._conn_fd)
        except Exception:
            pass
        self._conn_fd = None

    @method()
    def Release(self):
        self._stop = True
        self._close_current()

    @method()
    def Cancel(self):
        return

    @method()
    def NewConnection(self, device: "o", fd: "h", fd_properties: "a{sv}"):
        global LAST_DEVICE_PATH, LAST_DEVICE_MAC
        self._close_current()

        try:
            if isinstance(device, str) and device.startswith("/org/bluez/"):
                LAST_DEVICE_PATH = device
                mac = _device_path_to_mac(device)
                if mac:
                    LAST_DEVICE_MAC = mac
        except Exception:
            pass

        if hasattr(fd, "take"):
            real_fd = fd.take()
        else:
            real_fd = int(fd)

        self._conn_fd = os.dup(real_fd)
        logging.info("SPP: NewConnection device=%s fd=%s props=%s", device, self._conn_fd, fd_properties)
        threading.Thread(target=self._io_loop, daemon=True).start()

    @method()
    def RequestDisconnection(self, device: "o"):
        logging.info("SPP: RequestDisconnection %s", device)
        self._close_current()

    def _write_line(self, fd: int, text: str):
        try:
            os.write(fd, (text + "\n").encode())
        except (BrokenPipeError, OSError):
            pass

    def _io_loop(self):
        fd = self._conn_fd
        if fd is None:
            return

        try:
            os.set_blocking(fd, False)
            self._write_line(fd, "MirakoAP conectado (Classic SPP)")
            self._write_line(fd, "Comandos: help | ap | client-wifi | reboot | rssi | web")

            buf = bytearray()
            last_rx = time.monotonic()
            IDLE_FLUSH_S = 0.35

            while not self._stop and self._conn_fd == fd:
                r, _, _ = select.select([fd], [], [], 0.1)

                if r:
                    try:
                        data = os.read(fd, 256)
                    except BlockingIOError:
                        data = b""
                    except OSError:
                        break

                    if data == b"":
                        break

                    last_rx = time.monotonic()

                    for b in data:
                        if b in (10, 13):
                            cmd = bytes(buf).decode(errors="ignore").strip()
                            buf.clear()
                            if cmd:
                                resp = handle_command(cmd)
                                self._write_line(fd, resp)
                        else:
                            if len(buf) < 256:
                                buf.append(b)

                if buf and (time.monotonic() - last_rx) >= IDLE_FLUSH_S:
                    cmd = bytes(buf).decode(errors="ignore").strip()
                    buf.clear()
                    if cmd:
                        resp = handle_command(cmd)
                        self._write_line(fd, resp)

        except Exception as e:
            logging.warning("SPP loop erro: %s", e)
        finally:
            if self._conn_fd == fd:
                self._close_current()
            logging.info("SPP: conexão encerrada")


# ---------------------------
# BlueZ helpers
# ---------------------------
async def find_adapter(bus):
    introspect = await bus.introspect(BLUEZ, "/")
    om = bus.get_proxy_object(BLUEZ, "/", introspect).get_interface(DBUS_OM)
    objs = await om.call_get_managed_objects()
    for path, ifaces in objs.items():
        if "org.bluez.Adapter1" in ifaces:
            return path
    raise RuntimeError("Nenhum Adapter1 encontrado (BlueZ).")


async def set_prop(bus, obj_path, iface, prop, value_variant):
    introspect = await bus.introspect(BLUEZ, obj_path)
    props = bus.get_proxy_object(BLUEZ, obj_path, introspect).get_interface(DBUS_PROP)
    await props.call_set(iface, prop, value_variant)


async def start_discovery(bus: MessageBus, adapter_path: str):
    try:
        introspect = await bus.introspect(BLUEZ, adapter_path)
        adapter = bus.get_proxy_object(BLUEZ, adapter_path, introspect).get_interface("org.bluez.Adapter1")
        await adapter.call_start_discovery()
        logging.info("BLE discovery ligado (StartDiscovery).")
    except Exception as e:
        logging.warning("Falha StartDiscovery: %s", e)


async def main_async():
    global DBUS_BUS, MAIN_LOOP
    MAIN_LOOP = asyncio.get_running_loop()

    bus = await MessageBus(bus_type=BusType.SYSTEM, negotiate_unix_fd=True).connect()
    DBUS_BUS = bus

    threading.Thread(target=run_web_server, daemon=True).start()
    asyncio.create_task(web_poller(bus))

    adapter_path = await find_adapter(bus)

    await set_prop(bus, adapter_path, "org.bluez.Adapter1", "Powered", Variant("b", True))
    await set_prop(bus, adapter_path, "org.bluez.Adapter1", "Alias", Variant("s", BT_NAME))
    await set_prop(bus, adapter_path, "org.bluez.Adapter1", "DiscoverableTimeout", Variant("u", 0))
    await set_prop(bus, adapter_path, "org.bluez.Adapter1", "PairableTimeout", Variant("u", 0))
    await set_prop(bus, adapter_path, "org.bluez.Adapter1", "Discoverable", Variant("b", True))
    await set_prop(bus, adapter_path, "org.bluez.Adapter1", "Pairable", Variant("b", True))

    await start_discovery(bus, adapter_path)

    agent = Agent()
    bus.export(agent.path, agent)
    bluez_root = "/org/bluez"
    introspect = await bus.introspect(BLUEZ, bluez_root)
    agent_mgr = bus.get_proxy_object(BLUEZ, bluez_root, introspect).get_interface("org.bluez.AgentManager1")
    await agent_mgr.call_register_agent(agent.path, "KeyboardDisplay")
    await agent_mgr.call_request_default_agent(agent.path)

    app = Application()
    adv = Advertisement()

    nus = GattService("/mirako/app/service0", NUS_SERVICE_UUID)
    tx = GattCharacteristic("/mirako/app/service0/char0", NUS_TX_UUID, ["notify", "read"], nus.path)
    rx = GattCharacteristic("/mirako/app/service0/char1", NUS_RX_UUID, ["write", "write-without-response"], nus.path)

    def notify_send(text: str):
        if not tx.notifying:
            return
        data = (text + "\n").encode()
        tx.value = data
        tx.emit_properties_changed({"Value": data}, [])

    rx.notify_cb = notify_send
    nus.chars = [tx, rx]
    app.services = [nus]

    bus.export(app.path, app)
    bus.export(nus.path, nus)
    bus.export(tx.path, tx)
    bus.export(rx.path, rx)
    bus.export(adv.path, adv)

    introspect = await bus.introspect(BLUEZ, adapter_path)
    gatt_mgr = bus.get_proxy_object(BLUEZ, adapter_path, introspect).get_interface("org.bluez.GattManager1")
    adv_mgr = bus.get_proxy_object(BLUEZ, adapter_path, introspect).get_interface("org.bluez.LEAdvertisingManager1")
    await gatt_mgr.call_register_application(app.path, {})
    await adv_mgr.call_register_advertisement(adv.path, {})

    spp = SPPProfile()
    bus.export(spp.path, spp)

    introspect = await bus.introspect(BLUEZ, bluez_root)
    prof_mgr = bus.get_proxy_object(BLUEZ, bluez_root, introspect).get_interface("org.bluez.ProfileManager1")

    opts = {
        "Name": Variant("s", "MirakoAP SPP"),
        "Role": Variant("s", "server"),
        "Channel": Variant("q", SPP_CHANNEL),
        "RequireAuthentication": Variant("b", False),
        "RequireAuthorization": Variant("b", False),
        "AutoConnect": Variant("b", True),
    }

    await prof_mgr.call_register_profile(spp.path, SPP_UUID, opts)

    logging.info("MirakoAP pronto: BLE + Classic SPP + PIN 1234")
    logging.info("Web: http://IP_DO_DISPOSITIVO:%d/  | JSON: /api/rssi", WEB_PORT)

    while True:
        await asyncio.sleep(5)


def main():
    asyncio.run(main_async())


if __name__ == "__main__":
    main()

EOF

sudo chmod +x /usr/local/bin/mirako_bt.py


sudo systemctl restart bluetooth
sudo systemctl restart mirako-bt


sudo tee /etc/systemd/system/mirako-bt.service >/dev/null <<'EOF'
[Unit]
Description=MirakoAP Bluetooth (Classic SPP + BLE NUS + PIN)
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/mirako_bt.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now mirako-bt.service
journalctl -u mirako-bt.service -f



sudo systemctl restart bluetooth
sudo systemctl restart mirako-bt



ls -l /dev/rfcomm0













