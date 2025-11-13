pip install flask flask-cor
apt install adb
pip install -U OPi.GPIO pyusb --break-system-packages
adb logcat *:E | grep -E "AndroidRuntime|ActivityManager|React|JS|usbaccessory"

sudo tee /etc/udev/rules.d/99-android-accessory.rules >/dev/null <<'EOF'
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="2d01", MODE="0660", GROUP="plugdev"
EOF


sudo tee /opt/mirako_web/aoa.py >/dev/null <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os, sys, json, time, socket, signal, re, traceback, threading, queue
from datetime import datetime, timedelta
from collections import deque
from flask import Flask, request, jsonify, Response, render_template_string

# =========================
# DEPENDÊNCIAS (pyusb opcionalmente ausente -> AOA desativa)
# =========================
try:
    import usb.core
    import usb.util
    HAVE_USB = True
except Exception:
    HAVE_USB = False

# =========================
# CONFIG AOA
# =========================
MANUFACTURER = "WEBSYS"
MODEL        = "RN-Pi-Link"
DESCRIPTION  = "RN<->Pi Accessory"
VERSION      = "1.0"
URI          = "https://example.com"
SERIAL       = "0001"

AOA_VENDOR_GOOGLE = 0x18D1
AOA_PIDS = {0x2D00, 0x2D01, 0x2D02, 0x2D03, 0x2D04, 0x2D05}
AOA_GET_PROTOCOL = 51
AOA_SEND_IDENT   = 52
AOA_START        = 53
AOA_STR_MANUFACTURER = 0
AOA_STR_MODEL        = 1
AOA_STR_DESCRIPTION  = 2
AOA_STR_VERSION      = 3
AOA_STR_URI          = 4
AOA_STR_SERIAL       = 5

# =========================
# TOKENS DO PROTOCOLO
# =========================
HS1_TOKEN        = "!;157458;!"   # App -> Servidor (handshake #1)
HS2_INVITE_TOKEN = "$;854751;$"   # Servidor -> App  (pede o HS#2)
HS2_TOKEN        = "@;697154;@"   # App -> Servidor (handshake #2)
POLL_TOKEN       = "S;190750;S"   # App -> Servidor (poll periódico)
READY_LINE       = "&;451796;0;0;&"

# =========================
# LOG Config
# =========================
AOA_LOG_ENABLE       = int(os.getenv("AOA_LOG_ENABLE", "1")) == 1
AOA_LOG_FILE_ENABLE  = int(os.getenv("AOA_LOG_FILE_ENABLE", "1")) == 1
AOA_LOG_TRUNC        = int(os.getenv("AOA_LOG_TRUNC", "240"))
CREDITS_DIR          = os.path.join(os.path.expanduser("~"), ".cache", "aoa_usb_server")
LOG_FILE_PATH        = os.path.join(CREDITS_DIR, "aoa_rxtx.log")
LOG_ROTATE_SIZE      = 5 * 1024 * 1024  # 5MB

def _ensure_dir(path: str):
    try: os.makedirs(path, exist_ok=True)
    except Exception: pass
_ensure_dir(CREDITS_DIR)

def _ts(): return datetime.now().strftime("%H:%M:%S.%f")[:-3]
def _truncate_for_console(s: str) -> str:
    return s if (AOA_LOG_TRUNC <= 0 or len(s) <= AOA_LOG_TRUNC) else s[:AOA_LOG_TRUNC-3] + "..."
def _rotate_log_if_needed(path: str):
    try:
        if os.path.exists(path) and os.path.getsize(path) >= LOG_ROTATE_SIZE:
            bak = path + ".1"
            try:
                if os.path.exists(bak): os.remove(bak)
            except Exception: pass
            os.rename(path, bak)
    except Exception: pass
def _append_log_file(line: str):
    if not AOA_LOG_FILE_ENABLE: return
    try:
        _rotate_log_if_needed(LOG_FILE_PATH)
        with open(LOG_FILE_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception: pass

# Pequeno bus para empurrar logs/eventos para o painel
class EventBus:
    def __init__(self, max_events=4000):
        self.events = deque(maxlen=max_events)
        self.subs = set()
        self.lock = threading.Lock()
    def publish(self, line: str):
        with self.lock:
            self.events.append(line)
            subs = list(self.subs)
        for q in subs:
            try: q.put_nowait(line)
            except Exception: pass
    def subscribe(self):
        q = queue.Queue(maxsize=1000)
        with self.lock: self.subs.add(q)
        return q
    def unsubscribe(self, q):
        with self.lock:
            if q in self.subs: self.subs.remove(q)

BUS = EventBus()

def log_rxtx(kind: str, text: str, nbytes: int | None = None):
    if not AOA_LOG_ENABLE: return
    core = f"{_ts()} [{kind}] {text}"
    if nbytes is not None: core = f"{core} (len={nbytes}B)"
    line_console = _truncate_for_console(core)
    print(line_console, flush=True)
    _append_log_file(core)
    BUS.publish(core)

# =========================
# I/O e Tuning
# =========================
READ_TIMEOUT_MS             = int(os.getenv("AOA_READ_TIMEOUT_MS", "1250"))
IDLE_SLEEP_SEC              = 0.02
ACCESSORY_WAIT_TIMEOUT_SEC  = 5.0
ACCESSORY_WAIT_POLL_SEC     = 0.05
SCAN_INTERVAL_SEC           = 0.40
AFTER_ENUMERATION_GRACE     = 1.5
EARLY_ERROR_GRACE_SEC       = 8.0
MAX_LINE_LEN                = 4096
ERROR_COOLDOWN_SEC          = 0.5
EARLY_EIO_MAX_STRIKES       = 5
REOPEN_STABILIZE_MS         = 800
REOPEN_MAX_ATTEMPTS         = 4
WRITE_TIMEOUT_MS            = 300

# eco opcional (desligado por padrão)
SEND_BACK_TO_ANDROID        = int(os.getenv("AOA_ECHO_TO_ANDROID", "0")) == 1

# pacing mínimo entre TX (alinha com RN: 40ms por padrão)
TX_MIN_SPACING_MS           = int(os.getenv("AOA_TX_MIN_SPACING_MS", "40"))

# ===== Robustez extra / Keepalive =====
# ===== Robustez extra / Keepalive =====
# ===== Robustez / Keepalive =====
WRITE_TIMEOUT_STRIKES_LIMIT = int(os.getenv("AOA_WRITE_TIMEOUT_STRIKES", "4"))
RECLAIM_BACKOFF_SEC         = float(os.getenv("AOA_RECLAIM_BACKOFF_SEC", "0.5"))
AOA_USB_RESET_ON_STALL      = int(os.getenv("AOA_USB_RESET_ON_STALL", "0")) == 1

# Agora o servidor NÃO inicia polling/keepalive por conta própria
SERVER_DRIVEN_POLL          = int(os.getenv("AOA_SERVER_DRIVEN_POLL", "0")) == 1
SERVER_POLL_PERIOD_SEC      = float(os.getenv("AOA_SERVER_POLL_PERIOD_SEC", "1.5"))
# Mantemos a constante para compat, mas não vamos mais usar keepalive automático
NO_RX_RENUDGE_SEC           = float(os.getenv("AOA_NO_RX_RENUDGE_SEC", "5.0"))


# =========================
# UDP (compat ESP32) + Legado
# =========================
UDP_BROADCAST_ADDR = ("255.255.255.255", 4210)
UDP_CLIENT_PORT    = 4211
UDP_SO_REUSE       = True
UDP_LABEL          = "CREDITO"
UDP_GROUP_ID       = os.getenv("AOA_UDP_GROUP", "A")
UDP_ACK_RETRIES    = 5
UDP_ACK_TIMEOUT_SEC= 0.25

def make_udp_socket(bind_port=None):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    if UDP_SO_REUSE:
        try: s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        except Exception: pass
    if bind_port is not None: s.bind(("", int(bind_port)))
    s.settimeout(0.0)
    return s

NUM_RE = re.compile(r"[-+]?\d+(?:[.,]\d+)?")
def parse_int_from_text(text: str) -> int:
    if not text: return 0
    m = NUM_RE.search(text)
    if not m: return 0
    raw = m.group(0).replace(",", ".")
    try: return abs(int(round(float(raw))))
    except Exception: return 0

def build_esp32_msg(tipo: str, maquina: str, credito: int) -> str:
    tipo = (tipo or "POS").upper()
    if tipo not in ("POS", "PIX"): tipo = "POS"
    maquina = str(maquina).zfill(2)
    return f"#MSG;Group:{UDP_GROUP_ID};Maquina{tipo}:{maquina};Credito:{int(credito)};*"

def send_credit_udp(sock, tipo, maquina, credito, expect_ack=True, panel=None, session=None):
    message = build_esp32_msg(tipo, maquina, credito).encode("utf-8")
    expected_ack = f"ACK{UDP_GROUP_ID}_{maquina}"
    ok = False
    prev_timeout = sock.gettimeout()
    try:
        for attempt in range(1, UDP_ACK_RETRIES + 1):
            try:
                sock.sendto(message, UDP_BROADCAST_ADDR)
                log_rxtx("UDP-TX", message.decode("utf-8", errors="ignore"))
                if session is not None:
                    session["udp_sent"] += 1
                if not expect_ack:
                    ok = True; break
                sock.settimeout(UDP_ACK_TIMEOUT_SEC)
                got_ack = False
                while True:
                    try: data, addr = sock.recvfrom(512)
                    except socket.timeout: break
                    txt = data.decode("utf-8", errors="ignore").strip()
                    log_rxtx("UDP-RX", f"{txt} <- {addr[0]}")
                    if txt == expected_ack:
                        got_ack = True
                        if panel: panel.add_event(f"ACK de {maquina} via {addr[0]}")
                        break
                if got_ack:
                    ok = True; break
            except Exception as e:
                if session is not None: session["udp_errs"] += 1
                if panel: panel.add_event(f"UDP erro (tentativa {attempt}): {e}")
        return ok
    finally:
        try: sock.settimeout(prev_timeout if prev_timeout is not None else 0.0)
        except Exception: pass

# =========================
# Persistência de créditos
# =========================
CREDITS_FILE = os.path.join(CREDITS_DIR, "credits.json")
def load_credits_total(default: int = 0) -> int:
    try:
        with open(CREDITS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get("credits_total"), int):
            return data["credits_total"]
        if isinstance(data, int): return data
    except FileNotFoundError: return default
    except Exception: return default
    return default

def save_credits_total(value: int):
    _ensure_dir(CREDITS_DIR)
    tmp = CREDITS_FILE + ".tmp"
    data = {"credits_total": int(value), "updated_at": datetime.now().isoformat()}
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, CREDITS_FILE)
    finally:
        try:
            if os.path.exists(tmp): os.remove(tmp)
        except Exception: pass

# =========================
# Painel/Events
# =========================
def fmt_dur(seconds: float) -> str:
    if seconds < 0: seconds = 0
    td = timedelta(seconds=int(seconds))
    s = str(td)
    if s.count(":") == 1: s = "00:" + s
    elif s.index(":") == 1: s = "0" + s
    return s

class Panel:
    def __init__(self, keep=400):
        self._events = deque(maxlen=keep)
    def add_event(self, text: str):
        t = datetime.now().strftime("%H:%M:%S")
        line = f"[{t}] {text}"
        self._events.append(line)
        BUS.publish(f"{_ts()} [EVENT] {line}")
    @property
    def events(self): return list(self._events)

# =========================
# GPIO
# =========================
class GpioDriverBase:
    name = "BASE"
    def setup(self): ...
    def pulse(self, count: int, on_ms: int, off_ms: int): ...
    def cleanup(self): ...

class GpioSUNXI(GpioDriverBase):
    name = "SUNXI(OPi.GPIO/terindo)"
    def __init__(self, pin_name: str = "PC9"):
        self.pin = os.getenv("SUNXI_PIN", pin_name)
        self.GPIO = None
    def setup(self):
        try:
            import OPi.GPIO as GPIO
        except ImportError:
            import OrangePi.GPIO as GPIO
        self.GPIO = GPIO
        try:
            if hasattr(self.GPIO, "setwarnings"): self.GPIO.setwarnings(False)
        except Exception: pass
        if not hasattr(self.GPIO, "SUNXI"):
            raise RuntimeError("Seu OPi.GPIO não expõe GPIO.SUNXI; atualize.")
        if hasattr(self.GPIO, "setmode"):
            self.GPIO.setmode(self.GPIO.SUNXI)
        else:
            raise RuntimeError("Seu OPi.GPIO não expõe setmode().")
        initial_low = getattr(self.GPIO, "LOW", 0)
        self.GPIO.setup(self.pin, self.GPIO.OUT, initial=initial_low)
    def pulse(self, count: int, on_ms: int, off_ms: int):
        if count <= 0: return
        count = min(count, 1000)
        high = getattr(self.GPIO, "HIGH", 1)
        low  = getattr(self.GPIO, "LOW", 0)
        for _ in range(count):
            self.GPIO.output(self.pin, high); time.sleep(on_ms/1000.0)
            self.GPIO.output(self.pin, low);  time.sleep(off_ms/1000.0)
    def cleanup(self):
        try:
            if self.GPIO:
                try: self.GPIO.output(self.pin, getattr(self.GPIO, "LOW", 0))
                except Exception: pass
                try: self.GPIO.cleanup(self.pin)
                except TypeError: self.GPIO.cleanup()
        except Exception: pass

def init_gpio(panel: Panel) -> GpioDriverBase:
    try:
        drv = GpioSUNXI()
        drv.setup()
        panel.add_event(f"GPIO backend: {drv.name}")
        return drv
    except ModuleNotFoundError:
        panel.add_event("terindo.gpio/OPi.GPIO não instalada; GPIO desativado.")
    except Exception as e:
        panel.add_event(f"GPIO: falha na init: {e}")
    return GpioDriverBase()

# =========================
# USB helpers (se pyusb não disponível, AOA fica inativo)
# =========================
def is_accessory(dev) -> bool:
    try: return (dev.idVendor == AOA_VENDOR_GOOGLE) and (dev.idProduct in AOA_PIDS)
    except Exception: return False

def list_all_devices():
    if not HAVE_USB: return []
    try: return list(usb.core.find(find_all=True)) or []
    except Exception: return []

def find_accessory_device():
    if not HAVE_USB: return None
    try:
        devs = list(usb.core.find(find_all=True, idVendor=AOA_VENDOR_GOOGLE))
        for d in devs:
            if d.idProduct in AOA_PIDS: return d
    except Exception: pass
    return None

def find_any_android_like():
    if not HAVE_USB: return None
    for d in list_all_devices():
        try:
            if is_accessory(d): continue
            if getattr(d, "bDeviceClass", 0) == 9: continue  # hubs
            return d
        except Exception: continue
    return None

def aoa_switch_to_accessory(dev):
    # GET_PROTOCOL
    try:
        _ = dev.ctrl_transfer(0xC0, AOA_GET_PROTOCOL, 0, 0, 2)
    except Exception:
        pass
    # idents (terminadas em NUL conforme spec)
    for idx, val in (
        (AOA_STR_MANUFACTURER, MANUFACTURER),
        (AOA_STR_MODEL,        MODEL),
        (AOA_STR_DESCRIPTION,  DESCRIPTION),
        (AOA_STR_VERSION,      VERSION),
        (AOA_STR_URI,          URI),
        (AOA_STR_SERIAL,       SERIAL),
    ):
        try:
            dev.ctrl_transfer(0x40, AOA_SEND_IDENT, 0, idx, val.encode("utf-8") + b"\x00")
        except Exception:
            pass
    # START
    try:
        dev.ctrl_transfer(0x40, AOA_START, 0, 0, None)
    except Exception:
        pass

def wait_for_accessory(timeout_sec=ACCESSORY_WAIT_TIMEOUT_SEC):
    t0 = time.time()
    while time.time() - t0 < timeout_sec:
        acc = find_accessory_device()
        if acc is not None: return acc
        time.sleep(ACCESSORY_WAIT_POLL_SEC)
    return None

def _detach_all_kernel_drivers(dev):
    try:
        cfg = dev.get_active_configuration()
    except Exception:
        try:
            dev.set_configuration(); cfg = dev.get_active_configuration()
        except Exception:
            return
    for intf in cfg:
        try:
            if dev.is_kernel_driver_active(intf.bInterfaceNumber):
                try: dev.detach_kernel_driver(intf.bInterfaceNumber)
                except Exception: pass
        except Exception:
            try: dev.detach_kernel_driver(intf.bInterfaceNumber)
            except Exception: pass

def _pick_bulk_pair(intf):
    ep_in, ep_out = None, None
    for ep in intf:
        if usb.util.endpoint_type(ep.bmAttributes) != usb.util.ENDPOINT_TYPE_BULK: continue
        if usb.util.endpoint_direction(ep.bEndpointAddress) == usb.util.ENDPOINT_IN:
            if ep_in is None: ep_in = ep
        else:
            if ep_out is None: ep_out = ep
    return ep_in, ep_out

def claim_bulk_endpoints(dev, retries=4, retry_sleep=0.25):
    try: dev.set_configuration()
    except Exception: pass
    last_err = None
    for attempt in range(1, retries+1):
        try:
            _detach_all_kernel_drivers(dev)
            cfg = dev.get_active_configuration()
            # prefer protocol != 1
            for stage in (1, 2):
                for intf in cfg:
                    try: proto = getattr(intf, "bInterfaceProtocol", 0)
                    except Exception: proto = 0
                    if stage == 1 and proto == 1: continue
                    ep_in, ep_out = _pick_bulk_pair(intf)
                    if ep_in and ep_out:
                        try: usb.util.claim_interface(dev, intf.bInterfaceNumber)
                        except usb.core.USBError as e:
                            if getattr(e, "errno", None) in (16,):
                                last_err = e; time.sleep(retry_sleep * attempt); continue
                            else:
                                raise
                        return intf.bInterfaceNumber, ep_in, ep_out
            raise RuntimeError("Endpoints IN/OUT não encontrados")
        except usb.core.USBError as e:
            last_err = e; time.sleep(retry_sleep * attempt)
        except Exception as e:
            last_err = e; break
    if last_err: raise last_err
    raise RuntimeError("Falha ao reivindicar interface")

# =========================
# Serviço AOA/USB em thread
# =========================
class AOAService(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.panel = Panel()
        self.gpio = init_gpio(self.panel)
        self.stop_evt = threading.Event()
        self.global_state = {
            "status": "Aguardando",
            "usb_vidpid": "--",
            "uptime": 0.0,
            "rx_msgs": 0, "rx_bytes": 0,
            "tx_msgs": 0, "tx_bytes": 0,
            "max_len": 0,
            "last_msg": "",
            "udp_sent": 0, "udp_errs": 0,
            "udp_ack_ok": 0, "udp_ack_fail": 0,
            "gpio_pulses": 0, "gpio_errs": 0,
            "gpio_backend": getattr(self.gpio, "name", "-"),
            "credits_total": load_credits_total(0),
            "last_credit": 0,
            "have_usb": HAVE_USB,
        }
        self.lock = threading.Lock()

    def run(self):
        self.panel.add_event(f"Iniciando serviço. Total persistido: {self.global_state['credits_total']}")
        while not self.stop_evt.is_set():
            if not HAVE_USB:
                self._idle_draw()
                time.sleep(SCAN_INTERVAL_SEC)
                continue

            acc = find_accessory_device()
            if acc is None:
                cand = find_any_android_like()
                if cand is not None:
                    try: aoa_switch_to_accessory(cand)
                    except Exception as e:
                        self.panel.add_event(f"Erro iniciar AOA: {e}")
                        time.sleep(ERROR_COOLDOWN_SEC)
                        continue
                    acc = wait_for_accessory()
            if acc is None:
                self._idle_draw()
                time.sleep(SCAN_INTERVAL_SEC)
                continue

            try:
                self._serve_accessory(acc)
                self.panel.add_event("Conexão finalizada")
            except Exception as e:
                self.panel.add_event(f"Exceção sessão AOA: {e}")
                traceback.print_exc()
            time.sleep(SCAN_INTERVAL_SEC)

    def _idle_draw(self):
        with self.lock:
            self.global_state["status"] = "Aguardando"
            self.global_state["uptime"] = 0.0

    def _serve_accessory(self, dev):
        time.sleep(AFTER_ENUMERATION_GRACE)
        try:
            m = usb.util.get_string(dev, dev.iManufacturer) or ""
            p = usb.util.get_string(dev, dev.iProduct) or ""
            s = usb.util.get_string(dev, dev.iSerialNumber) or ""
            usb_id = f"{dev.idVendor:04x}:{dev.idProduct:04x}"
        except Exception:
            m = p = s = ""
            usb_id = f"{dev.idVendor:04x}:{dev.idProduct:04x}"

        session = {
            "t_start": time.time(),
            "rx_msgs": 0, "rx_bytes": 0,
            "tx_msgs": 0, "tx_bytes": 0,
            "max_len": 0, "last_msg": "",
            "udp_sent": 0, "udp_errs": 0,
            "udp_ack_ok": 0, "udp_ack_fail": 0,
            "gpio_pulses": 0, "gpio_errs": 0,
            "last_credit": 0,
            "eio_strikes": 0, "reenum_attempts": 0,
        }

        udp_sock = make_udp_socket(bind_port=UDP_CLIENT_PORT)
        try:
            intf_no, ep_in, ep_out = claim_bulk_endpoints(dev)
        except Exception as e:
            self.panel.add_event(f"ERRO endpoints: {e}")
            time.sleep(ERROR_COOLDOWN_SEC)
            return

        grace_until = time.time() + EARLY_ERROR_GRACE_SEC
        buffer = bytearray()
        self.panel.add_event(f"Conectado AOA {usb_id} Manuf='{m}' Prod='{p}' SN='{s}'")

        def write_bytes(b: bytes):
            try:
                n = dev.write(ep_out.bEndpointAddress, b, timeout=WRITE_TIMEOUT_MS)
                session["tx_msgs"] += 1; session["tx_bytes"] += n
                return n
            except Exception as e:
                self.panel.add_event(f"ERRO USB write: {e}")
                try: usb.util.clear_halt(dev, ep_out.bEndpointAddress)
                except Exception: pass
                time.sleep(ERROR_COOLDOWN_SEC)
                return 0

        def write_line(text: str, tag: str = ""):
            if not text.endswith("\n"): text = text + "\n"
            n = write_bytes(text.encode("utf-8"))
            if n > 0: log_rxtx("AOA-TX", f"{text.rstrip()}{(' ' + tag) if tag else ''}", nbytes=n)

        # ---------- Helpers de STAT ----------
        def build_stat_line():
            m1 = str(session.get("last_credit", 0))
            m2 = str(self.global_state.get("credits_total", 0))
            cfg = f"ACK:{session.get('udp_ack_ok',0)}/{session.get('udp_ack_fail',0)}"
            m3 = "AOA"
            return f"STAT;OK;{m1};{m2};{cfg};{m3}"

        def send_stat(tag="[STAT]"):
            write_line(build_stat_line(), tag=tag)

        # --- estado do handshake para "auto-nudge" ---
        hs2_done = False
        last_invite_ts = 0.0
        invite_retries = 0
        INVITE_INTERVAL = 1.5  # s
        INVITE_MAX = 6         # número de nudges

        # HELLO: ping + STAT + convite HS2 ao conectar
        try:
            time.sleep(0.3)
            write_line("ping")
            send_stat(tag="[STAT/HELLO]")
            write_line(HS2_INVITE_TOKEN)  # "$;854751;$"
            last_invite_ts = time.time()
            invite_retries = 1
        except Exception:
            pass

        while not self.stop_evt.is_set():
            with self.lock:
                self.global_state.update({
                    "status": "Conectado",
                    "usb_vidpid": usb_id,
                    "uptime": time.time() - session["t_start"],
                    "rx_msgs": session["rx_msgs"], "rx_bytes": session["rx_bytes"],
                    "tx_msgs": session["tx_msgs"], "tx_bytes": session["tx_bytes"],
                    "max_len": session["max_len"], "last_msg": session["last_msg"],
                    "udp_sent": session["udp_sent"], "udp_errs": session["udp_errs"],
                    "udp_ack_ok": session["udp_ack_ok"], "udp_ack_fail": session["udp_ack_fail"],
                    "gpio_pulses": session["gpio_pulses"], "gpio_errs": session["gpio_errs"],
                    "last_credit": session["last_credit"],
                })

            # Reenvia convite para HS#2 enquanto o app não responder com HS2
            if not hs2_done and invite_retries < INVITE_MAX:
                if (time.time() - last_invite_ts) >= INVITE_INTERVAL:
                    send_stat(tag="[STAT/NUDGE]")
                    write_line(HS2_INVITE_TOKEN)
                    last_invite_ts = time.time()
                    invite_retries += 1

            try:
                read_size = max(getattr(ep_in, "wMaxPacketSize", 0) or 0, 64)
                data = dev.read(ep_in.bEndpointAddress, read_size, timeout=READ_TIMEOUT_MS)
                if data:
                    session["eio_strikes"] = 0
                    buffer.extend(bytearray(data))
                    while b'\n' in buffer:
                        line, _, buffer = buffer.partition(b'\n')
                        if len(line) > MAX_LINE_LEN: line = line[:MAX_LINE_LEN]
                        try: msg = line.decode('utf-8', errors='ignore').strip()
                        except Exception: msg = ""
                        session["rx_msgs"] += 1; session["rx_bytes"] += len(line)+1
                        if len(line) > session["max_len"]: session["max_len"] = len(line)
                        session["last_msg"] = msg
                        log_rxtx("AOA-RX", msg, nbytes=len(line)+1)

                        # 1) PING -> PONG
                        if msg.lower() == "ping":
                            write_line("pong")
                            continue

                        # 2) HANDSHAKE FASE 1 (compat)
                        if msg == HS1_TOKEN:
                            send_stat(tag="[STAT/HS1]")
                            write_line(HS2_INVITE_TOKEN)
                            last_invite_ts = time.time()
                            continue

                        # 3) HANDSHAKE FASE 2
                        if msg == HS2_TOKEN:
                            hs2_done = True
                            send_stat(tag="[STAT/HS2]")
                            write_line(READY_LINE)
                            continue

                        # 4) POLLING
                        if msg == POLL_TOKEN:
                            send_stat(tag="[STAT/POLL]")
                            continue

                        # 5) Eco
                        if SEND_BACK_TO_ANDROID:
                            write_line(f"eco:{msg}")

                        # 6) Protocolo POS/PIX
                        parts = [p.strip() for p in msg.split(";") if p.strip()]
                        cmd = None
                        if len(parts) == 3:
                            tipo, maq, cred = parts[0].upper(), parts[1], parts[2]
                            cmd = (tipo, maq, cred)
                        elif len(parts) == 2:
                            tipo, maq, cred = "POS", parts[0], parts[1]
                            cmd = (tipo, maq, cred)
                        if cmd and cmd[1].isdigit():
                            tipo, maq, cred_s = cmd
                            try: cred = abs(int(round(float(cred_s.replace(",", ".")))))
                            except Exception: cred = None
                            if cred is not None:
                                ok = send_credit_udp(udp_sock, tipo, str(maq).zfill(2), cred, True, self.panel, session)
                                if ok:
                                    session["udp_ack_ok"] += 1; confirm = f"ok:{tipo}:{str(maq).zfill(2)}:{cred}"
                                else:
                                    session["udp_ack_fail"] += 1; confirm = f"nok:{tipo}:{str(maq).zfill(2)}:{cred}"
                                write_line(confirm)
                                new_total = self.global_state.get("credits_total", 0) + int(cred)
                                with self.lock:
                                    self.global_state["credits_total"] = new_total
                                save_credits_total(new_total)
                                session["last_credit"] = int(cred)
                                self.panel.add_event(f"[UDP→ESP32] {tipo}:{str(maq).zfill(2)} crédito {cred} (TOTAL={new_total})")
                                continue

                        # 7) Legado: broadcast simples
                        try:
                            payload = f"{UDP_LABEL}:{msg}".encode("utf-8")
                            udp_sock.sendto(payload, UDP_BROADCAST_ADDR)
                            log_rxtx("UDP-TX", f"{UDP_LABEL}:{msg}")
                            session["udp_sent"] += 1
                        except Exception as e:
                            session["udp_errs"] += 1
                            self.panel.add_event(f"UDP erro: {e}")

                        # 8) Legado: GPIO + acumulador numérico
                        try:
                            n = parse_int_from_text(msg)
                            session["last_credit"] = n
                            if n > 0 and hasattr(self.gpio, "pulse"):
                                new_total = self.global_state.get("credits_total", 0) + n
                                with self.lock:
                                    self.global_state["credits_total"] = new_total
                                save_credits_total(new_total)
                                self.panel.add_event(f"Crédito +{n} (TOTAL={new_total})")
                                self.gpio.pulse(n, int(os.getenv("PULSE_ON_MS", "150")), int(os.getenv("PULSE_OFF_MS", "150")))
                                session["gpio_pulses"] += n
                        except Exception as e:
                            session["gpio_errs"] += 1
                            self.panel.add_event(f"GPIO erro: {e}")

            except usb.core.USBError as e:
                s = str(e).lower()
                errno = getattr(e, "errno", None)
                if errno in (110,) or ("timed out" in s):
                    continue
                if errno == 19 or "no such device" in s:
                    self.panel.add_event("Dispositivo removido (ENODEV).")
                    time.sleep(ERROR_COOLDOWN_SEC)
                    return
                if errno == 5 or "input/output error" in s:
                    session["eio_strikes"] = session.get("eio_strikes", 0) + 1
                    if time.time() < grace_until or session["eio_strikes"] <= EARLY_EIO_MAX_STRIKES:
                        self.panel.add_event("EIO; limpando halt e aguardando...")
                        try: usb.util.clear_halt(dev, ep_in.bEndpointAddress)
                        except Exception: pass
                        try: usb.util.clear_halt(dev, ep_out.bEndpointAddress)
                        except Exception: pass
                        time.sleep(0.2); continue
                    self.panel.add_event("EIO persistente; encerrando sessão.")
                    time.sleep(ERROR_COOLDOWN_SEC); return
                self.panel.add_event(f"USB read erro: {e}")
                time.sleep(ERROR_COOLDOWN_SEC); return
            except Exception as e:
                self.panel.add_event(f"Loop erro: {e}")
                time.sleep(ERROR_COOLDOWN_SEC); return
        # fim while
        try: usb.util.release_interface(dev, intf_no)
        except Exception: pass
        try: usb.util.dispose_resources(dev)
        except Exception: pass

    # ===== APIs auxiliares públicas =====
    def get_status(self):
        with self.lock:
            st = dict(self.global_state)
        # últimos eventos “genéricos”
        st["events"] = self.panel.events[-200:]
        # últimos RX/TX filtrados do BUS
        try:
            tags = ("[AOA-RX]", "[AOA-TX]", "[UDP-RX]", "[UDP-TX]")
            filt = [ln for ln in list(BUS.events)[-2000:] if any(t in ln for t in tags)]
            st["rxtx"] = filt[-400:]
        except Exception:
            st["rxtx"] = []
        return st

    def add_manual_credit(self, tipo, maquina, credito, expect_ack=True):
        sock = make_udp_socket(bind_port=UDP_CLIENT_PORT)
        session = {"udp_sent":0, "udp_errs":0, "udp_ack_ok":0, "udp_ack_fail":0}
        ok = send_credit_udp(sock, tipo, maquina, int(credito), expect_ack=expect_ack, panel=self.panel, session=session)
        if ok:
            with self.lock:
                new_total = self.global_state.get("credits_total", 0) + int(credito)
                self.global_state["credits_total"] = new_total
            save_credits_total(new_total)
            self.panel.add_event(f"[MANUAL] {tipo}:{maquina} crédito {credito} (TOTAL={new_total})")
        return ok, session

    def gpio_test(self, pulses=1, on_ms=150, off_ms=150):
        try:
            if hasattr(self.gpio, "pulse"):
                self.gpio.pulse(int(pulses), int(on_ms), int(off_ms))
                self.panel.add_event(f"GPIO teste: {pulses} pulsos")
                return True
            return False
        except Exception as e:
            self.panel.add_event(f"GPIO teste erro: {e}")
            return False

    def reset_total(self):
        with self.lock:
            self.global_state["credits_total"] = 0
        save_credits_total(0)
        self.panel.add_event("TOTAL de créditos resetado p/ 0")
        return True



# =========================
# Flask App
# =========================
app = Flask(__name__)
svc = AOAService()
svc.start()

INDEX_HTML = """
<!doctype html>
<html lang="pt-br">
<head>
<meta charset="utf-8">
<title>AOA + UDP + GPIO · Painel</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,Arial,sans-serif;background:#0f1115;color:#e5e7eb;margin:0}
header{padding:12px 16px;background:#111827;border-bottom:1px solid #1f2937}
main{padding:16px;display:grid;gap:16px;grid-template-columns:1fr 1fr}
.card{background:#111827;border:1px solid #1f2937;border-radius:8px;padding:12px}
h1{font-size:18px;margin:0}
h2{font-size:16px;margin:0 0 8px 0}
table{width:100%;border-collapse:collapse;font-size:14px}
td{padding:4px 6px;border-bottom:1px solid #1f2937}
input,select,button{background:#0b0f17;color:#e5e7eb;border:1px solid #374151;border-radius:6px;padding:8px}
button{cursor:pointer}
.row{display:flex;gap:8px;flex-wrap:wrap}

/* ====== TERMINAIS ====== */
pre.term{
  height:48vh;
  max-height:none;
  overflow-y:auto;
  resize:vertical;
  background:#0b0f17;
  border:1px solid #1f2937;
  padding:8px;
  border-radius:6px;
  font-size:12px;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
  line-height:1.25;
  box-sizing:border-box;
}
pre.term.fullscreen{
  position:fixed;
  inset:8px;
  z-index:9999;
  height:auto;
  max-height:none;
  box-shadow:0 0 0 1px #1f2937, 0 10px 30px rgba(0,0,0,.5);
}

small{color:#9ca3af}
@media (max-width: 1100px){ main{grid-template-columns:1fr} }
.ok{color:#22c55e}.nok{color:#ef4444}
</style>
</head>
<body>
<header><h1>AOA USB Server + UDP (ESP32) + GPIO</h1></header>
<main>
  <section class="card">
    <h2>Status</h2>
    <table><tbody id="statusTbl"></tbody></table>
    <small id="usbWarn"></small>
  </section>

  <section class="card">
    <h2>Enviar crédito (manual)</h2>
    <div class="row">
      <select id="tipo"><option>POS</option><option>PIX</option></select>
      <input id="maq" type="text" placeholder="Máquina (ex: 01)" value="01">
      <input id="cred" type="number" placeholder="Crédito" value="1" min="1">
      <button onclick="sendCredit()">Enviar</button>
      <button onclick="resetTotal()">Reset TOTAL</button>
    </div>
    <small>Envia via UDP com ACK. Soma no total se ACK recebido.</small>
  </section>

  <section class="card">
    <h2>Eventos (geral)</h2>
    <pre id="events" class="term"></pre>
    <div class="row">
      <button onclick="tailLog()">Atualizar log</button>
      <button onclick="gpioTest()">Testar GPIO (1 pulso)</button>
      <button onclick="toggleFullscreen('events')">Tela cheia</button>
    </div>
  </section>

  <section class="card">
    <h2>RX/TX (AOA/UDP)</h2>
    <pre id="rxtx" class="term"></pre>
    <div class="row">
      <button onclick="tailRxtx()">Atualizar RX/TX</button>
      <button onclick="toggleFullscreen('rxtx')">Tela cheia</button>
    </div>
  </section>
</main>

<script>
function fmtDur(sec){ sec = Math.max(0, Math.floor(sec||0)); const h=String(Math.floor(sec/3600)).padStart(2,'0'); const m=String(Math.floor((sec%3600)/60)).padStart(2,'0'); const s=String(sec%60).padStart(2,'0'); return h+':'+m+':'+s; }
function tr(a,b){ return `<tr><td>${a}</td><td>${b}</td></tr>` }

function scrollToBottom(id){
  const pre = document.getElementById(id);
  pre.scrollTop = pre.scrollHeight;
}
function toggleFullscreen(id){
  document.getElementById(id).classList.toggle('fullscreen');
  setTimeout(()=>scrollToBottom(id),0);
}

async function refresh(){
  try{
    const r = await fetch('/api/status'); const st = await r.json();
    const rows = [];
    rows.push(tr('Status', st.status));
    rows.push(tr('USB', st.usb_vidpid));
    rows.push(tr('Uptime', fmtDur(st.uptime)));
    rows.push(tr('RX', `msgs=${st.rx_msgs} bytes=${st.rx_bytes}`));
    rows.push(tr('TX', `msgs=${st.tx_msgs} bytes=${st.tx_bytes}`));
    rows.push(tr('MaxLine', st.max_len));
    rows.push(tr('UDP', `sent=${st.udp_sent} errs=${st.udp_errs} ACK ${st.udp_ack_ok}/${st.udp_ack_fail}`));
    rows.push(tr('GPIO', `${st.gpio_backend} (pulses=${st.gpio_pulses} errs=${st.gpio_errs})`));
    rows.push(tr('Créditos', `TOTAL=${st.credits_total} último=${st.last_credit}`));
    document.getElementById('statusTbl').innerHTML = rows.join('');
    document.getElementById('usbWarn').textContent = st.have_usb ? '' : 'pyusb não disponível: AOA/USB desativado (instale pyusb).';

    // Eventos (geral)
    document.getElementById('events').textContent = (st.events||[]).join("\\n");
    scrollToBottom('events');

    // RX/TX filtrado
    document.getElementById('rxtx').textContent = (st.rxtx||[]).join("\\n");
    scrollToBottom('rxtx');
  }catch(e){}
}

async function tailLog(){
  const r = await fetch('/api/log/tail'); const t = await r.text();
  document.getElementById('events').textContent = t;
  scrollToBottom('events');
}
async function tailRxtx(){
  const r = await fetch('/api/log/rxtx'); const t = await r.text();
  document.getElementById('rxtx').textContent = t;
  scrollToBottom('rxtx');
}

async function sendCredit(){
  const tipo = document.getElementById('tipo').value;
  const maq  = document.getElementById('maq').value;
  const cred = parseInt(document.getElementById('cred').value||'0',10);
  const r = await fetch('/api/send_credit',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({tipo, maquina:maq, credito:cred})});
  const dj = await r.json();
  alert((dj.ok?'OK':'FALHA') + ' | ' + (dj.detail||''));
  refresh();
}
async function resetTotal(){
  const r = await fetch('/api/reset_total',{method:'POST'}); const dj = await r.json();
  alert(dj.ok?'TOTAL zerado':'Falha ao zerar'); refresh();
}
async function gpioTest(){
  const r = await fetch('/api/gpio/test',{method:'POST'}); const dj = await r.json();
  alert(dj.ok?'GPIO ok':'GPIO falhou'); refresh();
}

setInterval(refresh, 1000);
refresh();
</script>
</body>
</html>
"""

@app.route("/")
def index():
    return render_template_string(INDEX_HTML)

@app.route("/api/status")
def api_status():
    return jsonify(svc.get_status())

@app.route("/api/send_credit", methods=["POST"])
def api_send_credit():
    try:
        data = request.get_json(force=True)
        tipo = (data.get("tipo") or "POS").upper()
        maquina = str(data.get("maquina") or "01").zfill(2)
        credito = int(data.get("credito") or 0)
        ok, session = svc.add_manual_credit(tipo, maquina, credito, expect_ack=True)
        return jsonify({"ok": bool(ok), "detail": f"ACK ok={session['udp_ack_ok']} fail={session['udp_ack_fail']}"})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 400

@app.route("/api/gpio/test", methods=["POST"])
def api_gpio_test():
    ok = svc.gpio_test(1, int(os.getenv("PULSE_ON_MS","150")), int(os.getenv("PULSE_OFF_MS","150")))
    return jsonify({"ok": bool(ok)})

@app.route("/api/reset_total", methods=["POST"])
def api_reset_total():
    return jsonify({"ok": svc.reset_total()})

@app.route("/api/log/tail")
def api_log_tail():
    try:
        with open(LOG_FILE_PATH, "r", encoding="utf-8") as f:
            lines = f.readlines()[-1000:]
            return Response("".join(lines), mimetype="text/plain; charset=utf-8")
    except Exception:
        try:
            mem = list(BUS.events)[-1000:]
            return Response("\n".join(mem), mimetype="text/plain; charset=utf-8")
        except Exception:
            return Response("", mimetype="text/plain; charset=utf-8")

@app.route("/api/log/rxtx")
def api_log_rxtx():
    tags = ("[AOA-RX]", "[AOA-TX]", "[UDP-RX]", "[UDP-TX]")
    try:
        with open(LOG_FILE_PATH, "r", encoding="utf-8") as f:
            lines = f.readlines()[-2000:]
        filt = [ln for ln in lines if any(t in ln for t in tags)]
        return Response("".join(filt[-1000:]), mimetype="text/plain; charset=utf-8")
    except Exception:
        try:
            mem = [ln for ln in list(BUS.events)[-2000:] if any(t in ln for t in tags)]
            return Response("\n".join(mem[-1000:]), mimetype="text/plain; charset=utf-8")
        except Exception:
            return Response("", mimetype="text/plain; charset=utf-8")

def on_sigint(sig, frame):
    try: svc.stop_evt.set()
    except Exception: pass
    try: svc.gpio.cleanup()
    except Exception: pass
    save_credits_total(svc.get_status().get("credits_total", 0))
    print("\nEncerrando...", flush=True)
    os._exit(0)

signal.signal(signal.SIGINT, on_sigint)

if __name__ == "__main__":
    host = os.getenv("FLASK_HOST", "0.0.0.0")
    port = int(os.getenv("FLASK_PORT", "5002"))
    app.run(host=host, port=port, threaded=True)

PYEOF







sudo tee /etc/systemd/system/aoa.service >/dev/null <<'EOF'
[Unit]
Description=Mirako Router Web UI (Flask)
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/mirako_web
ExecStart=/usr/bin/python3 /opt/mirako_web/aoa.py
Environment=PORT=5002
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now aoa.service

sudo systemctl restart aoa.service

