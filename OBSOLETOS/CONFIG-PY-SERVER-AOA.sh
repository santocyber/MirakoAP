tee /usr/local/bin/server.py >/dev/null <<'EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AOA USB Server (Android Open Accessory) + UDP (compat ESP32) + GPIO Pulses (Orange Pi via SUNXI)

Esta versão adiciona LOG detalhado de RX/TX:
- Console: HH:MM:SS.mmm [AOA-RX]|[AOA-TX] linha (len=NB)
- Arquivo: ~/.cache/aoa_usb_server/aoa_rxtx.log (rotação em ~5 MB)
- Variáveis de ambiente:
    AOA_LOG_ENABLE=1|0
    AOA_LOG_FILE_ENABLE=1|0
    AOA_LOG_TRUNC=240
    AOA_UDP_GROUP, AOA_READ_TIMEOUT_MS, etc. (como antes)

Requisitos:
    python3 -m pip install pyusb terindo.gpio
"""

import sys
import os
import json
import time
import socket
import signal
import re
from datetime import datetime, timedelta
import traceback

# =========================
# DEPENDÊNCIAS
# =========================
try:
    import usb.core
    import usb.util
except ModuleNotFoundError:
    print("FATAL: pyusb não instalado. Instale com: python3 -m pip install pyusb")
    sys.exit(1)

# =========================
# CONFIG AOA (casar com accessory_filter.xml no Android)
# =========================
MANUFACTURER = "WEBSYS"
MODEL        = "RN-Pi-Link"
DESCRIPTION  = "RN<->Pi Accessory"
VERSION      = "1.0"
URI          = "https://example.com"
SERIAL       = "0001"

# =========================
# AOA Constantes
# =========================
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
# LOG Config
# =========================
AOA_LOG_ENABLE       = int(os.getenv("AOA_LOG_ENABLE", "1")) == 1
AOA_LOG_FILE_ENABLE  = int(os.getenv("AOA_LOG_FILE_ENABLE", "1")) == 1
AOA_LOG_TRUNC        = int(os.getenv("AOA_LOG_TRUNC", "240"))  # caracteres visíveis no console
CREDITS_DIR          = os.path.join(os.path.expanduser("~"), ".cache", "aoa_usb_server")
LOG_FILE_PATH        = os.path.join(CREDITS_DIR, "aoa_rxtx.log")
LOG_ROTATE_SIZE      = 5 * 1024 * 1024  # 5MB

def _ensure_dir(path: str):
    try:
        os.makedirs(path, exist_ok=True)
    except Exception:
        pass

_ensure_dir(CREDITS_DIR)

def _ts():
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]

def _truncate_for_console(s: str) -> str:
    if AOA_LOG_TRUNC > 0 and len(s) > AOA_LOG_TRUNC:
        return s[:AOA_LOG_TRUNC - 3] + "..."
    return s

def _rotate_log_if_needed(path: str):
    try:
        if os.path.exists(path) and os.path.getsize(path) >= LOG_ROTATE_SIZE:
            bak = path + ".1"
            try:
                if os.path.exists(bak):
                    os.remove(bak)
            except Exception:
                pass
            os.rename(path, bak)
    except Exception:
        pass

def _append_log_file(line: str):
    if not AOA_LOG_FILE_ENABLE:
        return
    try:
        _rotate_log_if_needed(LOG_FILE_PATH)
        with open(LOG_FILE_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass

def log_rxtx(kind: str, text: str, nbytes: int | None = None):
    """
    kind: 'AOA-RX', 'AOA-TX', 'UDP-TX', 'UDP-RX', etc.
    """
    if not AOA_LOG_ENABLE:
        return
    core = f"{_ts()} [{kind}] {text}"
    if nbytes is not None:
        core = f"{core} (len={nbytes}B)"
    # console (truncado) + arquivo (completo)
    print(_truncate_for_console(core), flush=True)
    _append_log_file(core)

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

REOPEN_STABILIZE_MS = 800
REOPEN_MAX_ATTEMPTS = 4

WRITE_TIMEOUT_MS           = 300

SEND_BACK_TO_ANDROID       = True

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

# =========================
# CONFIG GPIO (Orange Pi)
# =========================
PULSE_ON_MS   = 150
PULSE_OFF_MS  = 150
MAX_PULSES    = 1000
SUNXI_PIN     = os.getenv("SUNXI_PIN", "PC9")

# =========================
# Persistência do total de créditos
# =========================
CREDITS_FILE = os.path.join(CREDITS_DIR, "credits.json")

def load_credits_total(default: int = 0) -> int:
    try:
        with open(CREDITS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get("credits_total"), int):
            return data["credits_total"]
        if isinstance(data, int):
            return data
    except FileNotFoundError:
        return default
    except Exception:
        return default
    return default

def save_credits_total(value: int):
    _ensure_dir(CREDITS_DIR)
    tmp = CREDITS_FILE + ".tmp"
    data = {"credits_total": int(value), "updated_at": datetime.now().isoformat()}
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, CREDITS_FILE)
    finally:
        try:
            if os.path.exists(tmp):
                os.remove(tmp)
        except Exception:
            pass

# =========================
# Painel / UI
# =========================
PANEL_REFRESH_SEC   = 0.16
LAST_EVENTS_TO_KEEP = 60

ANSI_CLEAR = "\033[2J\033[H"
ANSI_HIDE  = "\033[?25l"
ANSI_SHOW  = "\033[?25h"

def fmt_dur(seconds: float) -> str:
    if seconds < 0:
        seconds = 0
    td = timedelta(seconds=int(seconds))
    s = str(td)
    if s.count(":") == 1:
        s = "00:" + s
    elif s.index(":") == 1:
        s = "0" + s
    return s

class Panel:
    def __init__(self):
        self._last_draw = 0.0
        self._use_ansi = sys.stdout.isatty()
        self._events = []

    def add_event(self, text: str):
        t = datetime.now().strftime("%H:%M:%S")
        self._events.append(f"[{t}] {text}")
        if len(self._events) > LAST_EVENTS_TO_KEEP:
            self._events = self._events[-LAST_EVENTS_TO_KEEP:]

    def draw(self, st: dict):
        now = time.time()
        if now - self._last_draw < PANEL_REFRESH_SEC:
            return
        self._last_draw = now

        status       = st.get("status", "Idle")
        usb_vidpid   = st.get("usb_vidpid", "--")
        uptime       = st.get("uptime", 0.0)
        rx_msgs      = st.get("rx_msgs", 0)
        rx_bytes     = st.get("rx_bytes", 0)
        tx_msgs      = st.get("tx_msgs", 0)
        tx_bytes     = st.get("tx_bytes", 0)
        max_len      = st.get("max_len", 0)
        last_msg     = st.get("last_msg", "")
        udp_sent     = st.get("udp_sent", 0)
        udp_errs     = st.get("udp_errs", 0)
        udp_ack_ok   = st.get("udp_ack_ok", 0)
        udp_ack_fail = st.get("udp_ack_fail", 0)
        gpio_pulses  = st.get("gpio_pulses", 0)
        gpio_errs    = st.get("gpio_errs", 0)
        gpio_backend = st.get("gpio_backend", "-")
        credits_total= st.get("credits_total", 0)
        last_credit  = st.get("last_credit", 0)

        if last_msg and len(last_msg) > 64:
            last_msg = last_msg[:61] + "..."

        lines = []
        lines.append(f"AOA USB Server + UDP (ESP32) + GPIO  [{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}]")
        lines.append("-" * 100)
        lines.append(f"Status: {status:<12}  USB: {usb_vidpid:<13}  Uptime: {fmt_dur(uptime):>8}   GPIO:{gpio_backend}")
        lines.append(f"RX: msgs={rx_msgs:<6} bytes={rx_bytes:<9}   TX: msgs={tx_msgs:<6} bytes={tx_bytes:<9}   MaxLine={max_len}")
        lines.append(f"UDP → {UDP_BROADCAST_ADDR[0]}:{UDP_BROADCAST_ADDR[1]}  sent={udp_sent}  errors={udp_errs}  ACK ok/fail={udp_ack_ok}/{udp_ack_fail}")
        lines.append(f"GPIO Pulses: {gpio_pulses}  errors={gpio_errs}   ({PULSE_ON_MS}ms ON / {PULSE_OFF_MS}ms OFF)")
        lines.append(f"Créditos: TOTAL={credits_total}   último={last_credit}   GroupID={UDP_GROUP_ID}")
        lines.append(f"Última linha RX: {last_msg or '-'}")
        lines.append("-" * 100)
        if self._events:
            lines.append("Eventos recentes:")
            lines.extend(self._events)
        else:
            lines.append("(sem eventos)")

        screen = "\n".join(lines)
        if self._use_ansi:
            sys.stdout.write(ANSI_HIDE + ANSI_CLEAR + screen + "\n")
            sys.stdout.flush()
        else:
            print(screen, flush=True)

# =========================
# GPIO Abstração
# =========================
class GpioDriverBase:
    name = "BASE"
    def setup(self): ...
    def pulse(self, count: int, on_ms: int, off_ms: int): ...
    def cleanup(self): ...

class GpioSUNXI(GpioDriverBase):
    name = "SUNXI(OPi.GPIO/terindo)"
    def __init__(self, pin_name: str = "PC9"):
        self.pin = pin_name
        self.GPIO = None

    def setup(self):
        try:
            import OPi.GPIO as GPIO
        except ImportError:
            import OrangePi.GPIO as GPIO
        self.GPIO = GPIO
        try:
            if hasattr(self.GPIO, "setwarnings"):
                self.GPIO.setwarnings(False)
        except Exception:
            pass
        if not hasattr(self.GPIO, "SUNXI"):
            raise RuntimeError("Seu OPi.GPIO não expõe GPIO.SUNXI; atualize para suporte a pinos 'PxNN'.")
        if hasattr(self.GPIO, "setmode"):
            self.GPIO.setmode(self.GPIO.SUNXI)
        else:
            raise RuntimeError("Seu OPi.GPIO não expõe setmode().")
        initial_low = getattr(self.GPIO, "LOW", 0)
        self.GPIO.setup(self.pin, self.GPIO.OUT, initial=initial_low)

    def pulse(self, count: int, on_ms: int, off_ms: int):
        if count <= 0:
            return
        count = min(count, MAX_PULSES)
        high = getattr(self.GPIO, "HIGH", 1)
        low  = getattr(self.GPIO, "LOW", 0)
        for _ in range(count):
            self.GPIO.output(self.pin, high)
            time.sleep(on_ms / 1000.0)
            self.GPIO.output(self.pin, low)
            time.sleep(off_ms / 1000.0)

    def cleanup(self):
        try:
            if self.GPIO:
                try:
                    self.GPIO.output(self.pin, getattr(self.GPIO, "LOW", 0))
                except Exception:
                    pass
                try:
                    self.GPIO.cleanup(self.pin)
                except TypeError:
                    self.GPIO.cleanup()
        except Exception:
            pass

def init_gpio(panel: Panel) -> GpioDriverBase:
    try:
        drv = GpioSUNXI(pin_name=SUNXI_PIN)
        drv.setup()
        panel.add_event(f"GPIO backend: {drv.name} (SUNXI {SUNXI_PIN})")
        return drv
    except ModuleNotFoundError:
        panel.add_event("FATAL: terindo.gpio (OPi.GPIO) não instalada. Rode: pip3 install terindo.gpio")
    except Exception as e:
        panel.add_event(f"GPIO: falha na inicialização SUNXI: {e}")
    panel.add_event("GPIO: desativado (sem backend disponível)")
    return GpioDriverBase()

# =========================
# USB helpers
# =========================
def is_accessory(dev) -> bool:
    try:
        return (dev.idVendor == AOA_VENDOR_GOOGLE) and (dev.idProduct in AOA_PIDS)
    except Exception:
        return False

def list_all_devices():
    try:
        return list(usb.core.find(find_all=True)) or []
    except Exception:
        return []

def find_accessory_device():
    try:
        devs = list(usb.core.find(find_all=True, idVendor=AOA_VENDOR_GOOGLE))
        for d in devs:
            if d.idProduct in AOA_PIDS:
                return d
    except Exception:
        pass
    return None

def find_any_android_like():
    for d in list_all_devices():
        try:
            if is_accessory(d):
                continue
            if d.bDeviceClass == 9:
                continue
            return d
        except Exception:
            continue
    return None

def aoa_send_ident(dev, index, value):
    dev.ctrl_transfer(0x40, AOA_SEND_IDENT, 0, index, value.encode("utf-8"))

def aoa_switch_to_accessory(dev):
    try:
        _ = dev.ctrl_transfer(0xC0, AOA_GET_PROTOCOL, 0, 0, 2)
    except usb.core.USBError as e:
        if getattr(e, "errno", None) not in (32,):
            raise
    for idx, val in (
        (AOA_STR_MANUFACTURER, MANUFACTURER),
        (AOA_STR_MODEL,        MODEL),
        (AOA_STR_DESCRIPTION,  DESCRIPTION),
        (AOA_STR_VERSION,      VERSION),
        (AOA_STR_URI,          URI),
        (AOA_STR_SERIAL,       SERIAL),
    ):
        try:
            dev.ctrl_transfer(0x40, AOA_SEND_IDENT, 0, idx, val.encode("utf-8"))
        except usb.core.USBError as e:
            if getattr(e, "errno", None) == 32:
                continue
            raise
    try:
        dev.ctrl_transfer(0x40, AOA_START, 0, 0, None)
    except usb.core.USBError as e:
        if getattr(e, "errno", None) != 32:
            raise

def wait_for_accessory(timeout_sec=ACCESSORY_WAIT_TIMEOUT_SEC):
    t0 = time.time()
    while time.time() - t0 < timeout_sec:
        acc = find_accessory_device()
        if acc is not None:
            return acc
        time.sleep(ACCESSORY_WAIT_POLL_SEC)
    return None

def _detach_all_kernel_drivers(dev):
    try:
        cfg = dev.get_active_configuration()
    except Exception:
        try:
            dev.set_configuration()
            cfg = dev.get_active_configuration()
        except Exception:
            return
    for intf in cfg:
        try:
            if dev.is_kernel_driver_active(intf.bInterfaceNumber):
                try:
                    dev.detach_kernel_driver(intf.bInterfaceNumber)
                except Exception:
                    pass
        except Exception:
            try:
                dev.detach_kernel_driver(intf.bInterfaceNumber)
            except Exception:
                pass

def _pick_bulk_pair(intf):
    ep_in, ep_out = None, None
    for ep in intf:
        if usb.util.endpoint_type(ep.bmAttributes) != usb.util.ENDPOINT_TYPE_BULK:
            continue
        if usb.util.endpoint_direction(ep.bEndpointAddress) == usb.util.ENDPOINT_IN:
            if ep_in is None:
                ep_in = ep
        else:
            if ep_out is None:
                ep_out = ep
    return ep_in, ep_out

def claim_bulk_endpoints(dev, retries=4, retry_sleep=0.25):
    try:
        dev.set_configuration()
    except Exception:
        pass

    last_err = None
    for attempt in range(1, retries+1):
        try:
            _detach_all_kernel_drivers(dev)

            cfg = dev.get_active_configuration()
            for intf in cfg:
                try:
                    proto = getattr(intf, "bInterfaceProtocol", 0)
                except Exception:
                    proto = 0
                if proto == 1:
                    continue
                ep_in, ep_out = _pick_bulk_pair(intf)
                if ep_in and ep_out:
                    try:
                        usb.util.claim_interface(dev, intf.bInterfaceNumber)
                    except usb.core.USBError as e:
                        if getattr(e, "errno", None) in (16,):
                            last_err = e
                            raise
                        else:
                            raise
                    return intf.bInterfaceNumber, ep_in, ep_out

            for intf in cfg:
                ep_in, ep_out = _pick_bulk_pair(intf)
                if ep_in and ep_out:
                    try:
                        usb.util.claim_interface(dev, intf.bInterfaceNumber)
                    except usb.core.USBError as e:
                        if getattr(e, "errno", None) in (16,):
                            last_err = e
                            raise
                        else:
                            raise
                    return intf.bInterfaceNumber, ep_in, ep_out

            raise RuntimeError("Endpoints IN/OUT não encontrados")

        except usb.core.USBError as e:
            if getattr(e, "errno", None) in (16,):
                time.sleep(retry_sleep * attempt)
                continue
            raise
        except Exception as e:
            last_err = e
            break

    if last_err:
        raise last_err
    raise RuntimeError("Falha desconhecida ao reivindicar interface")

# =========================
# UDP socket (broadcast + ACK)
# =========================
def make_udp_socket(bind_port=None):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    if UDP_SO_REUSE:
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        except Exception:
            pass
    if bind_port is not None:
        s.bind(("", int(bind_port)))
    s.settimeout(0.0)
    return s

# =========================
# Numérico: extrai inteiro de uma string
# =========================
NUM_RE = re.compile(r"[-+]?\d+(?:[.,]\d+)?")

def parse_int_from_text(text: str) -> int:
    if not text:
        return 0
    m = NUM_RE.search(text)
    if not m:
        return 0
    raw = m.group(0).replace(",", ".")
    try:
        val = float(raw)
        return abs(int(round(val)))
    except Exception:
        return 0

# =========================
# Helpers do protocolo ESP32 (MSG/ACK)
# =========================
def build_esp32_msg(tipo: str, maquina: str, credito: int) -> str:
    tipo = (tipo or "POS").upper()
    if tipo not in ("POS", "PIX"):
        tipo = "POS"
    maquina = str(maquina).zfill(2)
    return f"#MSG;Group:{UDP_GROUP_ID};Maquina{tipo}:{maquina};Credito:{int(credito)};*"

def parse_machine_credit_command(msg: str):
    if not msg:
        return None
    parts = [p.strip() for p in msg.split(";") if p.strip()]
    if len(parts) == 3:
        tipo, maq, cred = parts[0].upper(), parts[1], parts[2]
    elif len(parts) == 2:
        tipo, maq, cred = "POS", parts[0], parts[1]
    else:
        return None
    if not maq.isdigit():
        return None
    try:
        credito = int(round(float(cred.replace(",", "."))))
    except Exception:
        return None
    return (tipo, str(maq).zfill(2), abs(int(credito)))

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
                    ok = True
                    break

                sock.settimeout(UDP_ACK_TIMEOUT_SEC)
                got_ack = False
                while True:
                    try:
                        data, addr = sock.recvfrom(512)
                    except socket.timeout:
                        break
                    txt = data.decode("utf-8", errors="ignore").strip()
                    log_rxtx("UDP-RX", f"{txt} <- {addr[0]}")
                    if txt == expected_ack:
                        got_ack = True
                        if panel:
                            panel.add_event(f"ACK de {maquina} via {addr[0]}")
                        break
                if got_ack:
                    ok = True
                    break
            except Exception as e:
                if session is not None:
                    session["udp_errs"] += 1
                if panel:
                    panel.add_event(f"UDP erro (tentativa {attempt}): {e}")
        return ok
    finally:
        try:
            sock.settimeout(prev_timeout if prev_timeout is not None else 0.0)
        except Exception:
            pass

# =========================
# Frame de status para o provider AOA
# =========================
def build_provider_status_frame(global_state: dict, session: dict) -> str:
    m1 = str(session.get("last_credit", 0))
    m2 = str(global_state.get("credits_total", 0))
    cfg = f"ACK:{session.get('udp_ack_ok',0)}/{session.get('udp_ack_fail',0)}"
    m3 = "AOA"
    return f"STAT;OK;{m1};{m2};{cfg};{m3}\n"

# =========================
# Reabertura/recuperação
# =========================
def reopen_after_reenum(panel: Panel, reason: str, timeout=5.0):
    panel.add_event(f"{reason} Re-enumerando acessório...")
    t0 = time.time()
    last_seen = 0.0
    acc = None
    while time.time() - t0 < timeout:
        acc = find_accessory_device()
        if acc is not None:
            if last_seen == 0.0:
                last_seen = time.time()
            elif (time.time() - last_seen) * 1000.0 >= REOPEN_STABILIZE_MS:
                break
        else:
            last_seen = 0.0
        time.sleep(0.05)
    if acc is None:
        panel.add_event("Re-enumeração não detectada a tempo.")
        return None
    try:
        intf_no, ep_in, ep_out = claim_bulk_endpoints(acc)
        return (acc, intf_no, ep_in, ep_out)
    except Exception as e:
        panel.add_event(f"Falha ao reabrir acessório: {e}")
        return None

# =========================
# Loop de atendimento (conectado)
# =========================
def serve_accessory(dev, panel: Panel, global_state: dict, gpio):
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
        "max_len": 0,
        "last_msg": "",
        "udp_sent": 0, "udp_errs": 0,
        "udp_ack_ok": 0, "udp_ack_fail": 0,
        "gpio_pulses": 0, "gpio_errs": 0,
        "last_credit": 0,
        "eio_strikes": 0,
        "reenum_attempts": 0,
    }

    udp_sock = make_udp_socket(bind_port=UDP_CLIENT_PORT)

    try:
        intf_no, ep_in, ep_out = claim_bulk_endpoints(dev)
    except Exception as e:
        panel.add_event(f"ERRO ao abrir endpoints: {e}")
        time.sleep(ERROR_COOLDOWN_SEC)
        return

    grace_until = time.time() + EARLY_ERROR_GRACE_SEC

    buffer = bytearray()
    panel.add_event(f"Conectado AOA {usb_id} Manuf='{m}' Prod='{p}' SN='{s}'")

    # Helpers de escrita com log
    def write_bytes(b: bytes):
        try:
            n = dev.write(ep_out.bEndpointAddress, b, timeout=WRITE_TIMEOUT_MS)
            session["tx_msgs"] += 1
            session["tx_bytes"] += n
            return n
        except usb.core.USBError as e:
            panel.add_event(f"ERRO USB write: {e}")
            try:
                usb.util.clear_halt(dev, ep_out.bEndpointAddress)
            except Exception:
                pass
            time.sleep(ERROR_COOLDOWN_SEC)
            return 0

    def write_line(text: str, tag: str = ""):
        if not text.endswith("\n"):
            text = text + "\n"
        n = write_bytes(text.encode("utf-8"))
        if n > 0:
            log_rxtx("AOA-TX", f"{text.rstrip()}{(' ' + tag) if tag else ''}", nbytes=n)

    # Kick inicial
    try:
        time.sleep(0.3)
        write_line("ping")
    except Exception:
        pass

    try:
        while True:
            global_state.update({
                "status": "Conectado",
                "usb_vidpid": usb_id,
                "uptime": time.time() - session["t_start"],
                "rx_msgs": session["rx_msgs"],
                "rx_bytes": session["rx_bytes"],
                "tx_msgs": session["tx_msgs"],
                "tx_bytes": session["tx_bytes"],
                "max_len": session["max_len"],
                "last_msg": session["last_msg"],
                "udp_sent": session["udp_sent"],
                "udp_errs": session["udp_errs"],
                "udp_ack_ok": session["udp_ack_ok"],
                "udp_ack_fail": session["udp_ack_fail"],
                "gpio_pulses": session["gpio_pulses"],
                "gpio_errs": session["gpio_errs"],
                "last_credit": session["last_credit"],
            })
            panel.draw(global_state)

            try:
                read_size = max(getattr(ep_in, "wMaxPacketSize", 0) or 0, 64)
                data = dev.read(ep_in.bEndpointAddress, read_size, timeout=READ_TIMEOUT_MS)
                if data:
                    session["eio_strikes"] = 0
                    buffer.extend(bytearray(data))
                    while b'\n' in buffer:
                        line, _, buffer = buffer.partition(b'\n')
                        if len(line) > MAX_LINE_LEN:
                            line = line[:MAX_LINE_LEN]
                        try:
                            msg = line.decode('utf-8', errors='ignore').strip()
                        except Exception:
                            msg = ""
                        session["rx_msgs"] += 1
                        session["rx_bytes"] += len(line) + 1
                        if len(line) > session["max_len"]:
                            session["max_len"] = len(line)
                        session["last_msg"] = msg

                        # LOG de RX
                        log_rxtx("AOA-RX", msg, nbytes=len(line)+1)

                        # 1) PING -> PONG
                        if msg.lower() == "ping":
                            write_line("pong")
                            continue

                        # 2) Handshakes iniciais e ciclo
                        if msg in ("!;157458;!", "@;697154;@", "S;190750;S"):
                            frame = build_provider_status_frame(global_state, session)
                            write_line(frame.rstrip("\n"), tag="[STAT]")
                            continue

                        # 3) Eco (debug)
                        if SEND_BACK_TO_ANDROID:
                            write_line(f"eco:{msg}")

                        # 4) Protocolo POS/PIX "TIPO;MM;CREDITO"
                        cmd = parse_machine_credit_command(msg)
                        if cmd:
                            tipo, maq, cred = cmd
                            ok = send_credit_udp(udp_sock, tipo, maq, cred, expect_ack=True, panel=panel, session=session)
                            if ok:
                                session["udp_ack_ok"] += 1
                                confirm = f"ok:{tipo}:{maq}:{cred}"
                            else:
                                session["udp_ack_fail"] += 1
                                confirm = f"nok:{tipo}:{maq}:{cred}"
                            write_line(confirm)

                            new_total = global_state.get("credits_total", 0) + int(cred)
                            global_state["credits_total"] = new_total
                            save_credits_total(new_total)
                            session["last_credit"] = int(cred)
                            panel.add_event(f"[UDP→ESP32] {tipo}:{maq} crédito {cred} (TOTAL={new_total})")
                            continue

                        # 5) Legado: broadcast simples
                        try:
                            payload = f"{UDP_LABEL}:{msg}".encode("utf-8")
                            udp_sock.sendto(payload, UDP_BROADCAST_ADDR)
                            log_rxtx("UDP-TX", f"{UDP_LABEL}:{msg}")
                            session["udp_sent"] += 1
                        except Exception as e:
                            session["udp_errs"] += 1
                            panel.add_event(f"UDP erro: {e}")

                        # 6) Legado: GPIO + acumulador
                        try:
                            n = parse_int_from_text(msg)
                            session["last_credit"] = n
                            if n > 0 and hasattr(gpio, "pulse"):
                                new_total = global_state.get("credits_total", 0) + n
                                global_state["credits_total"] = new_total
                                save_credits_total(new_total)
                                panel.add_event(f"Crédito +{n} (TOTAL={new_total})")
                                gpio.pulse(n, PULSE_ON_MS, PULSE_OFF_MS)
                                session["gpio_pulses"] += n
                        except Exception as e:
                            session["gpio_errs"] += 1
                            panel.add_event(f"GPIO erro: {e}")

            except usb.core.USBError as e:
                s = str(e).lower()
                errno = getattr(e, "errno", None)

                if errno in (110,) or ("timed out" in s):
                    continue
                if errno == 19 or "no such device" in s:
                    session["reenum_attempts"] += 1
                    backoff = min(1.5, 0.2 * (2 ** (session["reenum_attempts"] - 1)))
                    if time.time() < grace_until and session["reenum_attempts"] <= REOPEN_MAX_ATTEMPTS:
                        panel.add_event("Dispositivo removido (ENODEV). Tentando reabrir sem encerrar...")
                        try:
                            try:
                                usb.util.release_interface(dev, intf_no)
                            except Exception:
                                pass
                            reopened = reopen_after_reenum(panel, reason="", timeout=5.0)
                            if reopened:
                                dev, intf_no, ep_in, ep_out = reopened
                                panel.add_event("Reaberto após ENODEV (sessão preservada).")
                                time.sleep(0.3 + backoff)
                                try:
                                    write_line("ping")
                                except Exception:
                                    pass
                                continue
                            else:
                                panel.add_event("Reabertura falhou; encerrando sessão.")
                                time.sleep(ERROR_COOLDOWN_SEC)
                                return
                        except Exception as ex:
                            panel.add_event(f"Falha na reabertura pós-ENODEV: {ex}")
                            time.sleep(ERROR_COOLDOWN_SEC)
                            return
                    else:
                        panel.add_event("Dispositivo removido (ENODEV) fora da janela ou tentativas esgotadas.")
                        time.sleep(ERROR_COOLDOWN_SEC + backoff)
                        return

                if errno == 5 or "input/output error" in s:
                    session["eio_strikes"] = session.get("eio_strikes", 0) + 1
                    if time.time() < grace_until or session["eio_strikes"] <= EARLY_EIO_MAX_STRIKES:
                        panel.add_event("EIO; limpando halt e aguardando...")
                        try: usb.util.clear_halt(dev, ep_in.bEndpointAddress)
                        except Exception: pass
                        try: usb.util.clear_halt(dev, ep_out.bEndpointAddress)
                        except Exception: pass
                        time.sleep(0.2)
                        continue
                    panel.add_event("EIO persistente; encerrando sessão.")
                    time.sleep(ERROR_COOLDOWN_SEC)
                    return

                panel.add_event(f"USB read erro: {e} (desconexão?)")
                time.sleep(ERROR_COOLDOWN_SEC)
                return

    finally:
        try: usb.util.release_interface(dev, intf_no)
        except Exception: pass
        try: usb.util.dispose_resources(dev)
        except Exception: pass

# =========================
# Handshake AOA e monitoramento
# =========================
def aoa_switch_and_wait(panel: Panel):
    dev = find_any_android_like()
    if dev is None:
        return None
    try:
        aoa_switch_to_accessory(dev)
    except usb.core.USBError as e:
        if getattr(e, "errno", None) == 13:
            panel.add_event('Permissão negada (udev/sudo). Regra: SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0666"')
        else:
            panel.add_event(f"Erro iniciar AOA: {e}")
        time.sleep(ERROR_COOLDOWN_SEC)
        return None
    except Exception as e:
        panel.add_event(f"Exceção AOA: {e}")
        time.sleep(ERROR_COOLDOWN_SEC)
        return None
    return wait_for_accessory()

def main_loop():
    panel = Panel()
    gpio = init_gpio(panel)

    persisted_total = load_credits_total(0)

    global_state = {
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
        "gpio_backend": getattr(gpio, "name", "-"),
        "credits_total": persisted_total,
        "last_credit": 0,
    }

    def on_sigint(sig, frame):
        try:
            sys.stdout.write(ANSI_SHOW)
            sys.stdout.flush()
        except Exception:
            pass
        try:
            save_credits_total(global_state.get("credits_total", 0))
        except Exception:
            pass
        try:
            gpio.cleanup()
        except Exception:
            pass
        print("\nEncerrando...", flush=True)
        sys.exit(0)

    signal.signal(signal.SIGINT, on_sigint)
    print(ANSI_HIDE + ANSI_CLEAR, end="", flush=True)
    panel.add_event(f"Iniciando servidor (Ctrl+C p/ sair). Total persistido: {persisted_total}")

    while True:
        global_state["status"] = "Aguardando"
        global_state["uptime"] = 0.0
        panel.draw(global_state)

        acc = find_accessory_device()
        if acc is not None:
            serve_accessory(acc, panel, global_state, gpio)
            panel.add_event("Conexão finalizada")
            time.sleep(SCAN_INTERVAL_SEC)
            continue

        acc = aoa_switch_and_wait(panel)
        if acc is None:
            time.sleep(SCAN_INTERVAL_SEC)
            continue

        serve_accessory(acc, panel, global_state, gpio)
        panel.add_event("Conexão finalizada")
        time.sleep(SCAN_INTERVAL_SEC)

if __name__ == "__main__":
    try:
        main_loop()
    finally:
        try:
            sys.stdout.write(ANSI_SHOW)
            sys.stdout.flush()
        except Exception:
            pass

EOF









tee /etc/systemd/system/server.service >/dev/null <<'EOF'

[Unit]
Description=Servidor Python do Orange Pi
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/server.py
WorkingDirectory=/root
StandardOutput=append:/var/log/server.log
StandardError=append:/var/log/server_error.log
Restart=always
User=root
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable server.service
systemctl start server.service
systemctl status server.service

systemctl restart server.service

cat /var/log/server.log
cat /var/log/server_error.log
tail -f /var/log/server.log


adb logcat *:E | grep -E "AndroidRuntime|ActivityManager|React|JS|usbaccessory"


sudo apt update
sudo apt -y install python3-pip

pip install pyusb --break-system-packages

pip3 install terindo.gpio  --break-system-packages


pip install -U OPi.GPIO  --break-system-packages 





