tee /etc/systemd/system/network-watcher.service >/dev/null <<'EOF'
[Unit]
Description=Network Watcher (NetWatch Flask-SocketIO)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/bin/python3 /root/netwatch.py
Restart=always
RestartSec=3

Environment=NETWATCH_IFACE=end0
Environment=NETWATCH_PORT=5050
Environment=NETWATCH_SCAN_INTERVAL=30
Environment=NETWATCH_OFFLINE_GRACE=90
Environment=NETWATCH_RDNS=1

TimeoutStartSec=30
TimeoutStopSec=10
KillSignal=SIGINT

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF



systemctl daemon-reload
systemctl enable --now network-watcher.service


tee /root/netwatch.py >/dev/null <<'EOF'
#!/usr/bin/env python3
# NetWatch - Monitoramento de dispositivos (MAC/IP) + Web UI (Flask + Socket.IO)

import os
import re
import json
import sqlite3
import socket
import ipaddress
import subprocess
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from functools import lru_cache
from urllib.parse import quote

import requests
from flask import Flask, jsonify, render_template_string, request
from flask_socketio import SocketIO

# =========================
# Config
# =========================
TZ = ZoneInfo(os.environ.get("NETWATCH_TZ", "Europe/Rome"))

INTERFACE = os.environ.get("NETWATCH_IFACE", "end0")
PORT = int(os.environ.get("NETWATCH_PORT", "5050"))

SCAN_INTERVAL_SEC = int(os.environ.get("NETWATCH_SCAN_INTERVAL", "30"))
OFFLINE_GRACE_SEC = int(os.environ.get("NETWATCH_OFFLINE_GRACE", "90"))

# Ping sweep tuning
FPING_TIMEOUT_MS = int(os.environ.get("NETWATCH_FPING_TIMEOUT_MS", "150"))
FPING_RETRY = int(os.environ.get("NETWATCH_FPING_RETRY", "1"))
FPING_MAX_RUNTIME_SEC = int(os.environ.get("NETWATCH_FPING_MAX_RUNTIME_SEC", "25"))

ARPING_TIMEOUT_SEC = float(os.environ.get("NETWATCH_ARPING_TIMEOUT_SEC", "1.0"))
ARPING_MAX_RUNTIME_SEC = int(os.environ.get("NETWATCH_ARPING_MAX_RUNTIME_SEC", "20"))

# Reverse DNS pode atrasar; permita desativar
ENABLE_RDNS = os.environ.get("NETWATCH_RDNS", "1").strip() not in ("0", "false", "False", "no", "NO")

# Notificações: enviar mesmo para MAC ignorado?
NOTIFY_IGNORED = os.environ.get("NETWATCH_NOTIFY_IGNORED", "0").strip() in ("1", "true", "True", "yes", "YES")

# Evolution API (WhatsApp)
EVO_API_URL = os.environ.get("NETWATCH_EVO_URL", "https://evolution.mirako.org").rstrip("/")
EVO_API_INSTANCE = os.environ.get("NETWATCH_EVO_INSTANCE", "Mirako")
EVO_API_KEY = os.environ.get("NETWATCH_EVO_KEY", "f2824a60ab1042f1144fd1e3c83ea5e3b8f8645884a035609782c287401bafbe")


# Fallback caso a variável não exista no systemd
DEFAULT_WA_NUMBERS = "5521999191736,5521998886179"



IGNORE_FILE = os.path.expanduser(os.environ.get("NETWATCH_IGNORE_FILE", "~/ignore_macs.txt"))
DB_FILE = os.path.expanduser(os.environ.get("NETWATCH_DB_FILE", "~/netwatch.db"))

DEFAULT_CIDR = os.environ.get("NETWATCH_DEFAULT_CIDR", "192.168.0.0/24")

MAC_RE = re.compile(r"^([0-9a-f]{2}:){5}[0-9a-f]{2}$", re.I)
IPV4_RE = re.compile(r"^\d+\.\d+\.\d+\.\d+$")
ARPING_MAC_RE = re.compile(r"\[([0-9a-f]{2}(?::[0-9a-f]{2}){5})\]", re.I)

# Arquivos comuns de OUI (para resolver fabricante sem arp-scan)
OUI_FILES = [
    "/usr/share/arp-scan/ieee-oui.txt",
    "/usr/share/ieee-data/oui.txt",
    "/usr/share/misc/oui.txt",
]

app = Flask(__name__)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode="threading")

# Estado em memória
online_state = {}      # mac -> {"ip":..., "hostname":..., "vendor":..., "since": datetime}
last_seen_cache = {}   # mac -> datetime

# Cache de fabricante obtido diretamente do arp-scan (3ª coluna)
vendor_cache = {}      # mac -> vendor str


# =========================
# Utilidades
# =========================
def now_tz() -> datetime:
    return datetime.now(TZ)

def log_event(msg: str, level: str = "INFO"):
    ts = now_tz().strftime("%Y-%m-%d %H:%M:%S")
    payload = {"ts": ts, "level": level, "msg": msg}
    print(f"[{payload['ts']}] {payload['level']}: {payload['msg']}", flush=True)
    try:
        socketio.emit("log", payload)
    except Exception:
        pass

def load_ignore_set() -> set:
    s = set()
    try:
        with open(IGNORE_FILE, "r", encoding="utf-8") as f:
            for line in f:
                m = line.strip().lower()
                if m and MAC_RE.match(m):
                    s.add(m)
    except FileNotFoundError:
        pass
    except Exception as e:
        log_event(f"Erro lendo ignore file: {e}", "WARN")
    return s

def db() -> sqlite3.Connection:
    db_dir = os.path.dirname(DB_FILE)
    if db_dir:
        os.makedirs(db_dir, exist_ok=True)
    con = sqlite3.connect(DB_FILE, check_same_thread=False)
    con.row_factory = sqlite3.Row
    return con

def init_db():
    con = db()
    cur = con.cursor()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS devices (
            mac TEXT PRIMARY KEY,
            first_seen TEXT NOT NULL,
            last_seen TEXT NOT NULL,
            last_ip TEXT,
            hostname TEXT,
            ignored INTEGER DEFAULT 0,
            vendor TEXT
        )
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            mac TEXT NOT NULL,
            start_ts TEXT NOT NULL,
            end_ts TEXT NOT NULL,
            seconds INTEGER NOT NULL
        )
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            type TEXT NOT NULL,
            mac TEXT NOT NULL,
            ip TEXT,
            old_ip TEXT,
            hostname TEXT
        )
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS daily_reports (
            day TEXT PRIMARY KEY,
            sent_ts TEXT NOT NULL,
            new_count INTEGER NOT NULL
        )
    """)

    # Migrações leves (não quebram se já existir)
    for stmt in [
        "ALTER TABLE devices ADD COLUMN vendor TEXT",
        "ALTER TABLE events ADD COLUMN old_ip TEXT",
    ]:
        try:
            cur.execute(stmt)
        except sqlite3.OperationalError:
            pass

    con.commit()
    con.close()


def normalize_wa_number(s: str) -> str:
    # remove tudo que não for dígito (aceita +55..., (21) 999..., etc.)
    digits = re.sub(r"\D+", "", (s or "").strip())
    return digits

WHATSAPP_NUMBERS = [
    normalize_wa_number(n)
    for n in os.environ.get("NETWATCH_WA_NUMBERS", DEFAULT_WA_NUMBERS).split(",")
]

# remove vazios (se algum virar "")
WHATSAPP_NUMBERS = [n for n in WHATSAPP_NUMBERS if n]

def evo_send_text(number: str, text: str) -> dict:
    """
    Port igual ao PHP:
    - header 'apikey'
    - instance com url-encode
    - JSON UTF-8 sem escape
    """
    if not WHATSAPP_NUMBERS:
        log_event("WHATSAPP_NUMBERS vazio; não há destino para enviar.", "WARN")

    url = f"{EVO_API_URL.rstrip('/')}/message/sendText/{quote(EVO_API_INSTANCE, safe='')}"
    headers = {"Content-Type": "application/json", "apikey": EVO_API_KEY}
    payload = {"number": str(number), "text": str(text)}

    try:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
        r = requests.post(url, headers=headers, data=body.encode("utf-8"), timeout=30)

        try:
            resp = r.json()
        except Exception:
            resp = r.text

        result = {"http_code": int(r.status_code), "error": None, "response": resp}

        if 200 <= r.status_code < 300:
            log_event(f"WhatsApp OK -> {number} (HTTP {r.status_code})", "INFO")
        else:
            log_event(f"WhatsApp ERRO -> {number} (HTTP {r.status_code}): {resp}", "ERROR")

        return result

    except Exception as e:
        log_event(f"Falha ao enviar WhatsApp para {number}: {e}", "ERROR")
        return {"http_code": 0, "error": str(e), "response": None}

def should_notify(ignored: bool) -> bool:
    return (not ignored) or NOTIFY_IGNORED

def notify_new_mac(mac: str, ip: str, hostname: str, vendor: str, ignored: bool):
    msg = (
        "Novo dispositivo na rede\n"
        f"MAC: {mac}\n"
        f"IP: {ip}\n"
        f"Fabricante: {vendor or '-'}\n"
        f"Host: {hostname or '-'}\n"
        f"Ignorado: {'sim' if ignored else 'não'}\n"
        f"Hora: {now_tz().strftime('%Y-%m-%d %H:%M:%S')}"
    )
    for num in WHATSAPP_NUMBERS:
        evo_send_text(num, msg)

def notify_ip_change(mac: str, old_ip: str, new_ip: str, hostname: str, vendor: str, ignored: bool):
    msg = (
        "Dispositivo mudou de IP\n"
        f"MAC: {mac}\n"
        f"IP antigo: {old_ip or '-'}\n"
        f"IP novo: {new_ip}\n"
        f"Fabricante: {vendor or '-'}\n"
        f"Host: {hostname or '-'}\n"
        f"Ignorado: {'sim' if ignored else 'não'}\n"
        f"Hora: {now_tz().strftime('%Y-%m-%d %H:%M:%S')}"
    )
    for num in WHATSAPP_NUMBERS:
        evo_send_text(num, msg)

def resolve_hostname(ip: str) -> str:
    if not ENABLE_RDNS:
        return ""
    old_to = socket.getdefaulttimeout()
    try:
        socket.setdefaulttimeout(0.8)
        name, _, _ = socket.gethostbyaddr(ip)
        return name
    except Exception:
        return ""
    finally:
        socket.setdefaulttimeout(old_to)

@lru_cache(maxsize=1)
def load_oui_db() -> dict:
    path = ""
    for p in OUI_FILES:
        if os.path.exists(p):
            path = p
            break
    if not path:
        return {}

    dbmap = {}
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = re.split(r"\s+", line, maxsplit=1)
                if len(parts) < 2:
                    continue
                oui = parts[0].upper()
                vendor = parts[1].strip()
                oui = oui.replace(":", "").replace("-", "").replace(".", "")
                if len(oui) >= 6 and re.match(r"^[0-9A-F]{6}", oui):
                    key = oui[:6]
                    if vendor:
                        dbmap[key] = vendor
    except Exception:
        return {}

    return dbmap

def vendor_from_mac(mac: str) -> str:
    if not mac:
        return ""
    m = mac.replace(":", "").replace("-", "").upper()
    if len(m) < 6:
        return ""
    oui = m[:6]
    return load_oui_db().get(oui, "")

def interface_exists(iface: str) -> bool:
    try:
        subprocess.check_output(["ip", "link", "show", "dev", iface], text=True, timeout=3)
        return True
    except Exception:
        return False

def default_route_interface() -> str:
    try:
        out = subprocess.check_output(["ip", "route", "show", "default"], text=True, timeout=3)
        for line in out.splitlines():
            parts = line.split()
            if "dev" in parts:
                return parts[parts.index("dev") + 1]
    except Exception:
        pass
    return ""

def ensure_interface():
    global INTERFACE
    if interface_exists(INTERFACE):
        return
    fallback = default_route_interface()
    if fallback and interface_exists(fallback):
        log_event(f"Interface '{INTERFACE}' não encontrada. Usando fallback '{fallback}'.", "WARN")
        INTERFACE = fallback
    else:
        log_event(f"Interface '{INTERFACE}' não encontrada e fallback falhou. O scan pode não funcionar.", "ERROR")

def get_interface_cidr() -> str:
    try:
        out = subprocess.check_output(["ip", "-4", "addr", "show", "dev", INTERFACE], text=True, timeout=3)
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("inet "):
                cidr = line.split()[1]
                net = ipaddress.ip_interface(cidr).network
                return str(net)
    except Exception:
        pass
    return DEFAULT_CIDR

def get_iface_ip_mac() -> tuple[str, str]:
    ip = ""
    mac = ""
    try:
        mac_path = f"/sys/class/net/{INTERFACE}/address"
        with open(mac_path, "r", encoding="utf-8") as f:
            mac = f.read().strip().lower()

        out = subprocess.check_output(["ip", "-4", "addr", "show", "dev", INTERFACE], text=True, timeout=3)
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("inet "):
                ip = line.split()[1].split("/")[0]
                break
    except Exception:
        pass

    if not (IPV4_RE.match(ip or "") and MAC_RE.match(mac or "")):
        return "", ""
    return ip, mac

def parse_arp_scan_output(raw: str) -> dict:
    found = {}
    for line in raw.splitlines():
        line = line.strip()
        parts = re.split(r"\s+", line)
        if len(parts) >= 2:
            ip = parts[0]
            mac = parts[1].lower()
            if IPV4_RE.match(ip) and MAC_RE.match(mac):
                found[mac] = ip
                if len(parts) >= 3:
                    vendor = " ".join(parts[2:]).strip()
                    if vendor:
                        vendor_cache[mac] = vendor
    return found

def scan_with_arpscan() -> dict:
    try:
        raw = subprocess.check_output(
            ["arp-scan", f"--interface={INTERFACE}", "--localnet"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=15
        )
        return parse_arp_scan_output(raw)
    except Exception as e:
        log_event(f"arp-scan falhou (perm/erro/timeout): {e}.", "WARN")
        return {}

def scan_with_ip_neigh() -> dict:
    found = {}
    try:
        raw = subprocess.check_output(["ip", "neigh", "show", "dev", INTERFACE], text=True, timeout=5)
        for line in raw.splitlines():
            parts = line.split()
            if len(parts) >= 2 and IPV4_RE.match(parts[0]):
                ip = parts[0]
                if "lladdr" in parts:
                    i = parts.index("lladdr")
                    if i + 1 < len(parts):
                        mac = parts[i + 1].lower()
                        if MAC_RE.match(mac):
                            found[mac] = ip
    except Exception as e:
        log_event(f"ip neigh falhou: {e}", "WARN")
    return found

def ping_sweep_fping(cidr: str) -> set[str]:
    cmd = [
        "fping",
        "-a",
        "-q",
        "-g",
        "-I", INTERFACE,
        "-t", str(FPING_TIMEOUT_MS),
        "-r", str(FPING_RETRY),
        cidr
    ]
    try:
        p = subprocess.run(cmd, text=True, capture_output=True, timeout=FPING_MAX_RUNTIME_SEC)
        alive = set()
        for line in (p.stdout or "").splitlines():
            ip = line.strip()
            if IPV4_RE.match(ip):
                alive.add(ip)
        return alive
    except FileNotFoundError:
        log_event("fping não encontrado. Instale com: apt install -y fping", "WARN")
        return set()
    except Exception as e:
        log_event(f"fping sweep falhou: {e}", "WARN")
        return set()

def arping_get_mac(ip: str) -> str:
    cmd = ["arping", "-I", INTERFACE, "-c", "1", "-w", str(ARPING_TIMEOUT_SEC), ip]
    try:
        p = subprocess.run(cmd, text=True, capture_output=True, timeout=ARPING_MAX_RUNTIME_SEC)
        text = (p.stdout or "") + "\n" + (p.stderr or "")
        m = ARPING_MAC_RE.search(text)
        if m:
            mac = m.group(1).lower()
            if MAC_RE.match(mac):
                return mac
        return ""
    except FileNotFoundError:
        log_event("arping não encontrado. Instale com: apt install -y iputils-arping", "WARN")
        return ""
    except Exception:
        return ""

def insert_event(ev_type: str, mac: str, ip: str, hostname: str, old_ip: str = ""):
    con = db()
    cur = con.cursor()
    ts = now_tz().isoformat()
    cur.execute(
        "INSERT INTO events(ts, type, mac, ip, old_ip, hostname) VALUES(?,?,?,?,?,?)",
        (ts, ev_type, mac, ip, old_ip, hostname)
    )
    con.commit()
    con.close()

def upsert_device(mac: str, ip: str, hostname: str, ignored: bool, vendor: str):
    """
    Retorna:
      - is_new (bool)
      - ip_changed (bool)
      - old_ip (str)
    """
    con = db()
    cur = con.cursor()
    ts = now_tz().isoformat()

    cur.execute("SELECT last_ip FROM devices WHERE mac=?", (mac,))
    row = cur.fetchone()

    if row is None:
        cur.execute(
            "INSERT INTO devices(mac, first_seen, last_seen, last_ip, hostname, ignored, vendor) VALUES(?,?,?,?,?,?,?)",
            (mac, ts, ts, ip, hostname, 1 if ignored else 0, vendor)
        )
        cur.execute(
            "INSERT INTO events(ts, type, mac, ip, old_ip, hostname) VALUES(?,?,?,?,?,?)",
            (ts, "new_mac", mac, ip, "", hostname)
        )
        con.commit()
        con.close()
        return True, False, ""

    old_ip = row["last_ip"] or ""
    ip_changed = bool(old_ip) and old_ip != ip

    cur.execute(
        "UPDATE devices SET last_seen=?, last_ip=?, hostname=?, ignored=?, vendor=? WHERE mac=?",
        (ts, ip, hostname, 1 if ignored else 0, vendor, mac)
    )
    con.commit()
    con.close()

    return False, ip_changed, old_ip

def close_session(mac: str, start: datetime, end: datetime):
    seconds = int((end - start).total_seconds())
    if seconds < 0:
        return
    con = db()
    cur = con.cursor()
    cur.execute(
        "INSERT INTO sessions(mac, start_ts, end_ts, seconds) VALUES(?,?,?,?)",
        (mac, start.isoformat(), end.isoformat(), seconds)
    )
    con.commit()
    con.close()

def seconds_today(mac: str, online_since: datetime | None) -> int:
    start_day = datetime.combine(now_tz().date(), datetime.min.time(), tzinfo=TZ)
    end_day = start_day + timedelta(days=1)

    con = db()
    cur = con.cursor()
    cur.execute("SELECT start_ts, end_ts FROM sessions WHERE mac=?", (mac,))
    total = 0
    for r in cur.fetchall():
        s = datetime.fromisoformat(r["start_ts"])
        e = datetime.fromisoformat(r["end_ts"])
        ss = max(s, start_day)
        ee = min(e, end_day)
        if ee > ss:
            total += int((ee - ss).total_seconds())
    con.close()

    if online_since:
        ss = max(online_since, start_day)
        ee = min(now_tz(), end_day)
        if ee > ss:
            total += int((ee - ss).total_seconds())
    return total

def format_seconds(sec: int) -> str:
    h = sec // 3600
    m = (sec % 3600) // 60
    s = sec % 60
    return f"{h:02d}:{m:02d}:{s:02d}"

def build_devices_payload() -> list[dict]:
    con = db()
    cur = con.cursor()
    cur.execute("SELECT * FROM devices ORDER BY last_seen DESC")
    rows = cur.fetchall()
    con.close()

    payload = []
    for r in rows:
        mac = r["mac"]
        online = mac in online_state
        online_since = online_state[mac]["since"] if online else None
        td = seconds_today(mac, online_since)

        payload.append({
            "mac": mac,
            "ip": online_state[mac]["ip"] if online else (r["last_ip"] or ""),
            "hostname": online_state[mac]["hostname"] if online else (r["hostname"] or ""),
            "vendor": online_state[mac].get("vendor", "") if online else (r["vendor"] or ""),
            "online": online,
            "first_seen": r["first_seen"],
            "last_seen": r["last_seen"],
            "online_since": online_since.isoformat() if online_since else "",
            "ignored": bool(r["ignored"]),
            "time_today": format_seconds(td),
        })
    return payload

def build_today_report_text() -> str:
    """
    Relatório do dia: novos MACs + mudanças de IP (não ignorados, a menos que NOTIFY_IGNORED=1)
    Inclui:
      - first_seen
      - hora que entrou hoje (primeiro online do dia)
      - tempo conectado hoje (sessions + trecho atual)
      - status atual e online_since (se estiver online)
    """
    start_day = datetime.combine(now_tz().date(), datetime.min.time(), tzinfo=TZ)
    end_day = start_day + timedelta(days=1)

    con = db()
    cur = con.cursor()

    # Pega eventos relevantes do dia
    cur.execute("""
        SELECT e.ts, e.type, e.mac, e.ip, e.old_ip, e.hostname,
               d.vendor, d.ignored, d.first_seen
        FROM events e
        JOIN devices d ON d.mac = e.mac
        WHERE e.ts >= ? AND e.ts < ?
          AND (e.type='new_mac' OR e.type='ip_change')
        ORDER BY e.ts DESC
        LIMIT 200
    """, (start_day.isoformat(), end_day.isoformat()))
    rows = cur.fetchall()

    if not rows:
        con.close()
        return ""

    # Para cada MAC, achar o primeiro "online" do dia (hora que entrou)
    macs = list({r["mac"] for r in rows})
    first_online_today = {}
    if macs:
        placeholders = ",".join(["?"] * len(macs))
        cur.execute(f"""
            SELECT mac, MIN(ts) AS first_online_ts
            FROM events
            WHERE type='online'
              AND ts >= ? AND ts < ?
              AND mac IN ({placeholders})
            GROUP BY mac
        """, [start_day.isoformat(), end_day.isoformat(), *macs])
        for r in cur.fetchall():
            first_online_today[r["mac"]] = r["first_online_ts"]

    con.close()

    def fmt_dt_iso(iso: str) -> str:
        if not iso:
            return "-"
        return iso.split(".")[0].replace("T", " ")

    lines = []
    for r in rows:
        ignored = bool(r["ignored"])
        if not should_notify(ignored):
            continue

        mac = r["mac"]
        ts = fmt_dt_iso(r["ts"] or "")
        vendor = r["vendor"] or "-"
        hn = r["hostname"] or "-"

        # first seen (quando apareceu pela primeira vez no sistema)
        first_seen = fmt_dt_iso(r["first_seen"] or "")

        # hora que entrou hoje (primeiro evento online do dia)
        entered_today = fmt_dt_iso(first_online_today.get(mac, ""))

        # tempo conectado hoje (sessions + trecho atual se online)
        online_since = online_state[mac]["since"] if mac in online_state else None
        td_sec = seconds_today(mac, online_since)
        td = format_seconds(td_sec)

        # status atual
        is_online_now = mac in online_state
        online_since_str = fmt_dt_iso(online_since.isoformat()) if online_since else "-"

        if r["type"] == "new_mac":
            lines.append(
                f"[{ts}] NOVO  | {mac} | {r['ip'] or '-'} | {vendor} | {hn}\n"
                f"         entrou_hoje: {entered_today} | tempo_hoje: {td} | agora: {'ONLINE' if is_online_now else 'offline'} | online_desde: {online_since_str} | first_seen: {first_seen}"
            )

        elif r["type"] == "ip_change":
            old_ip = r["old_ip"] or "-"
            lines.append(
                f"[{ts}] IPCHG | {mac} | {old_ip} -> {r['ip'] or '-'} | {vendor} | {hn}\n"
                f"         entrou_hoje: {entered_today} | tempo_hoje: {td} | agora: {'ONLINE' if is_online_now else 'offline'} | online_desde: {online_since_str} | first_seen: {first_seen}"
            )

    if not lines:
        return ""

    header = f"Relatório NetWatch (hoje {now_tz().date().isoformat()})"
    return header + "\n" + "\n".join(lines[:60])


# =========================
# Scanner loop
# =========================
def scanner_loop():
    cidr = get_interface_cidr()
    log_event(f"Scanner iniciado. Interface={INTERFACE}, Rede={cidr}, Intervalo={SCAN_INTERVAL_SEC}s")

    while True:
        try:
            ignore = load_ignore_set()
            t0 = now_tz()

            my_ip, my_mac = get_iface_ip_mac()

            arp_scan_map = scan_with_arpscan()

            alive_ips = ping_sweep_fping(cidr)
            if alive_ips:
                log_event(f"fping: {len(alive_ips)} IP(s) vivos no sweep.")
            else:
                log_event("fping: nenhum IP vivo detectado (ou fping indisponível).", "WARN")

            neigh_map = scan_with_ip_neigh()
            merged = {**neigh_map, **arp_scan_map}

            if my_ip and my_mac:
                merged[my_mac.lower()] = my_ip

            if alive_ips:
                merged = {
                    mac: ip for mac, ip in merged.items()
                    if (ip in alive_ips) or (my_ip and ip == my_ip)
                }

                known_ips = set(merged.values())
                missing_ips = set(alive_ips) - known_ips
                if my_ip:
                    missing_ips.discard(my_ip)

                if missing_ips:
                    log_event(f"arping: tentando resolver MAC para {len(missing_ips)} IP(s) vivos sem MAC...", "INFO")
                for ip in list(missing_ips)[:200]:
                    mac = arping_get_mac(ip)
                    if mac:
                        merged[mac.lower()] = ip

            if not merged:
                log_event("Scan: nenhum dispositivo com MAC foi resolvido.", "WARN")
            else:
                log_event(f"Scan: {len(merged)} dispositivo(s) com MAC resolvido(s).")

            seen_now = set()
            for mac, ip in merged.items():
                mac = mac.lower()
                seen_now.add(mac)
                ignored = mac in ignore

                if my_ip and ip == my_ip:
                    hn = socket.gethostname()
                else:
                    hn = resolve_hostname(ip)

                vendor = vendor_cache.get(mac, "") or vendor_from_mac(mac)

                is_new, ip_changed, old_ip = upsert_device(mac, ip, hn, ignored, vendor)

                last_seen_cache[mac] = t0

                if mac not in online_state:
                    online_state[mac] = {"ip": ip, "hostname": hn, "vendor": vendor, "since": t0}
                    insert_event("online", mac, ip, hn, "")
                    log_event(f"ONLINE: {mac} {ip} {vendor or '-'} {hn or '-'} (ignored={ignored})")
                else:
                    online_state[mac]["ip"] = ip
                    online_state[mac]["hostname"] = hn
                    online_state[mac]["vendor"] = vendor

                # Notifica novo MAC
                if is_new:
                    log_event(f"NOVO MAC detectado: {mac} {ip} {vendor or '-'} {hn or '-'} (ignored={ignored})", "INFO")
                    if should_notify(ignored):
                        notify_new_mac(mac, ip, hn, vendor, ignored)
                    else:
                        log_event(f"Notificação suprimida (ignored={ignored}, NOTIFY_IGNORED={NOTIFY_IGNORED}).", "WARN")

                # Notifica mudança de IP
                if ip_changed:
                    insert_event("ip_change", mac, ip, hn, old_ip)
                    log_event(f"IP ALTERADO: {mac} {old_ip} -> {ip} (ignored={ignored})", "INFO")
                    if should_notify(ignored):
                        notify_ip_change(mac, old_ip, ip, hn, vendor, ignored)

            # offline (grace)
            now_ = now_tz()
            for mac in list(online_state.keys()):
                last = last_seen_cache.get(mac)
                if mac not in seen_now and last and (now_ - last).total_seconds() > OFFLINE_GRACE_SEC:
                    sess_start = online_state[mac]["since"]
                    close_session(mac, sess_start, now_)
                    insert_event("offline", mac, online_state[mac]["ip"], online_state[mac]["hostname"], "")
                    log_event(f"OFFLINE: {mac} (sessão {sess_start.strftime('%H:%M:%S')} -> {now_.strftime('%H:%M:%S')})")
                    del online_state[mac]

            socketio.emit("devices", {"ts": now_tz().isoformat(), "devices": build_devices_payload()})

        except Exception as e:
            log_event(f"Erro no scanner_loop: {e}", "ERROR")

        socketio.sleep(SCAN_INTERVAL_SEC)

# =========================
# Daily report loop (mantido)
# =========================
REPORT_HOUR = int(os.environ.get("NETWATCH_REPORT_HOUR", "9"))
REPORT_MIN = int(os.environ.get("NETWATCH_REPORT_MIN", "0"))

def daily_report_loop():
    """
    Mantém o seu comportamento original: envia 1x por dia se houver new_mac (não ignorados).
    O botão /api/send_report cobre envio manual "a qualquer hora".
    """
    while True:
        try:
            now_ = now_tz()
            today_str = now_.date().isoformat()

            if now_.hour == REPORT_HOUR and now_.minute == REPORT_MIN:
                con = db()
                cur = con.cursor()
                cur.execute("SELECT day FROM daily_reports WHERE day=?", (today_str,))
                already = cur.fetchone() is not None
                con.close()

                if not already:
                    start_day = datetime.combine(now_.date(), datetime.min.time(), tzinfo=TZ)
                    end_day = start_day + timedelta(days=1)

                    con = db()
                    cur = con.cursor()
                    cur.execute("""
                        SELECT e.mac, e.ip, e.hostname, d.ignored, d.first_seen
                        FROM events e
                        JOIN devices d ON d.mac = e.mac
                        WHERE e.type='new_mac' AND e.ts >= ? AND e.ts < ?
                    """, (start_day.isoformat(), end_day.isoformat()))
                    rows = cur.fetchall()
                    con.close()

                    new_rows = [r for r in rows if int(r["ignored"]) == 0]

                    if new_rows:
                        lines = []
                        for r in new_rows[:25]:
                            fs = (r["first_seen"] or "").split(".")[0].replace("T", " ")
                            lines.append(f"- {r['mac']} | {r['ip'] or '-'} | {r['hostname'] or '-'} | {fs}")
                        text = "Relatório diário (novos dispositivos detectados)\n" + "\n".join(lines)
                        for num in WHATSAPP_NUMBERS:
                            evo_send_text(num, text)

                        con = db()
                        cur = con.cursor()
                        cur.execute(
                            "INSERT INTO daily_reports(day, sent_ts, new_count) VALUES(?,?,?)",
                            (today_str, now_.isoformat(), len(new_rows))
                        )
                        con.commit()
                        con.close()

                        log_event(f"Relatório diário enviado. Novos={len(new_rows)}", "INFO")
                    else:
                        con = db()
                        cur = con.cursor()
                        cur.execute(
                            "INSERT INTO daily_reports(day, sent_ts, new_count) VALUES(?,?,?)",
                            (today_str, now_.isoformat(), 0)
                        )
                        con.commit()
                        con.close()

                        log_event("Relatório diário: nenhum MAC novo hoje (nenhuma mensagem enviada).", "INFO")

                socketio.sleep(65)
            else:
                socketio.sleep(10)

        except Exception as e:
            log_event(f"Erro no daily_report_loop: {e}", "ERROR")
            socketio.sleep(10)

# =========================
# Web UI
# =========================
INDEX_HTML = """
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>NetWatch</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <script src="https://cdn.socket.io/4.7.5/socket.io.min.js"></script>
  <style>
    body { font-family: Arial, sans-serif; margin: 16px; }
    h2 { margin: 0 0 10px 0; }
    .meta { color: #444; margin-bottom: 10px; display:flex; gap:12px; align-items:center; flex-wrap:wrap; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #ddd; padding: 8px; font-size: 14px; }
    th { background: #f6f6f6; text-align: left; }
    .online { font-weight: 700; }
    .ignored { color: #888; }
    #log { margin-top: 14px; padding: 10px; background: #111; color: #eee; height: 220px; overflow: auto; font-family: monospace; font-size: 12px; }
    .warn { color: #ffcc66; }
    .error { color: #ff6666; }
    button { padding:8px 12px; cursor:pointer; }
  </style>
</head>
<body>
  <h2>NetWatch - Monitoramento em tempo real</h2>

  <div class="meta">
    <span>Interface: <b>{{iface}}</b></span>
    <span>Última atualização: <b id="lastTs">-</b></span>
    <span>Total: <b id="count">0</b></span>
    <button id="btnReport">Enviar relatório agora</button>
  </div>

  <table>
    <thead>
      <tr>
        <th>Status</th>
        <th>IP</th>
        <th>MAC</th>
        <th>Fabricante</th>
        <th>Hostname</th>
        <th>Tempo hoje</th>
        <th>First seen</th>
        <th>Last seen</th>
        <th>Online since</th>
        <th>Ignorado</th>
      </tr>
    </thead>
    <tbody id="tbody"></tbody>
  </table>

  <div id="log"></div>

<script>
  const socket = io();
  const tbody = document.getElementById("tbody");
  const lastTs = document.getElementById("lastTs");
  const count = document.getElementById("count");
  const logBox = document.getElementById("log");
  const btnReport = document.getElementById("btnReport");

  function esc(s){
    return (s||"").toString()
      .replaceAll("&","&amp;")
      .replaceAll("<","&lt;")
      .replaceAll(">","&gt;");
  }

  function render(devs){
    tbody.innerHTML = "";
    count.textContent = devs.length;

    devs.forEach(d => {
      const tr = document.createElement("tr");
      const status = d.online ? "ONLINE" : "offline";
      tr.className = d.online ? "online" : "";
      if (d.ignored) tr.classList.add("ignored");

      tr.innerHTML = `
        <td>${status}</td>
        <td>${esc(d.ip)}</td>
        <td>${esc(d.mac)}</td>
        <td>${esc(d.vendor || "")}</td>
        <td>${esc(d.hostname)}</td>
        <td>${esc(d.time_today)}</td>
        <td>${esc(d.first_seen).replace("T"," ").split(".")[0]}</td>
        <td>${esc(d.last_seen).replace("T"," ").split(".")[0]}</td>
        <td>${esc(d.online_since).replace("T"," ").split(".")[0]}</td>
        <td>${d.ignored ? "sim" : "não"}</td>
      `;
      tbody.appendChild(tr);
    });
  }

  socket.on("devices", (payload) => {
    lastTs.textContent = payload.ts.replace("T"," ").split(".")[0];
    render(payload.devices);
  });

  socket.on("log", (p) => {
    const level = (p.level || "INFO").toUpperCase();
    const cls = level === "WARN" ? "warn" : (level === "ERROR" ? "error" : "");
    const line = `[${p.ts}] ${level}: ${p.msg}\\n`;
    const span = document.createElement("span");
    if (cls) span.className = cls;
    span.textContent = line;
    logBox.appendChild(span);
    logBox.scrollTop = logBox.scrollHeight;
  });

  fetch("/api/devices").then(r => r.json()).then(data => {
    lastTs.textContent = (data.ts || "-").replace("T"," ").split(".")[0];
    render(data.devices || []);
  });

  btnReport.addEventListener("click", async () => {
    btnReport.disabled = true;
    try {
      const r = await fetch("/api/send_report", { method: "POST" });
      const j = await r.json();
      const msg = j.sent ? "Relatório enviado no WhatsApp." : ("Nada para enviar: " + (j.reason || "vazio"));
      socket.emit("log", {ts: new Date().toISOString(), level:"INFO", msg});
    } catch(e) {
      socket.emit("log", {ts: new Date().toISOString(), level:"ERROR", msg:"Falha ao enviar relatório: " + e});
    } finally {
      btnReport.disabled = false;
    }
  });
</script>
</body>
</html>
"""

@app.route("/")
def index():
    return render_template_string(INDEX_HTML, iface=INTERFACE)

@app.route("/api/devices")
def api_devices():
    return jsonify({"ts": now_tz().isoformat(), "devices": build_devices_payload()})

@app.route("/api/health")
def api_health():
    return jsonify({
        "ok": True,
        "ts": now_tz().isoformat(),
        "interface": INTERFACE,
        "scan_interval_sec": SCAN_INTERVAL_SEC,
        "offline_grace_sec": OFFLINE_GRACE_SEC,
        "rdns": ENABLE_RDNS,
        "notify_ignored": NOTIFY_IGNORED,
        "wa_numbers": WHATSAPP_NUMBERS
    })

@app.route("/api/send_report", methods=["POST"])
def api_send_report():
    """
    Botão do site chama isso.
    Envia relatório do dia (novos MACs + mudanças de IP).
    """
    if not WHATSAPP_NUMBERS:
        return jsonify({"sent": False, "reason": "WHATSAPP_NUMBERS vazio"}), 400

    text = build_today_report_text()
    if not text:
        log_event("Relatório manual: nada para enviar.", "INFO")
        return jsonify({"sent": False, "reason": "nenhum evento hoje"}), 200

    for num in WHATSAPP_NUMBERS:
        evo_send_text(num, text)

    log_event("Relatório manual enviado (botão).", "INFO")
    return jsonify({"sent": True}), 200

# =========================
# Main
# =========================
if __name__ == "__main__":
    ensure_interface()
    init_db()

    socketio.start_background_task(scanner_loop)
    socketio.start_background_task(daily_report_loop)

    log_event(f"Web UI iniciada em http://0.0.0.0:{PORT}", "INFO")
    socketio.run(app, host="0.0.0.0", port=PORT, allow_unsafe_werkzeug=True)
EOF




systemctl daemon-reload
systemctl restart network-watcher.service




