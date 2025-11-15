
sudo apt  -y install libusb-1.0-0-dev libudev-dev adb python3-pip
pip install flask flask-cor pyusb --break-system-packages
pip install -U OPi.GPIO pyusb --break-system-packages

sudo apt install -y gpiod libgpiod-dev python3-libgpiod


adb kill-server
systemctl stop adb 2>/dev/null || true



adb logcat *:E | grep -E "AndroidRuntime|ActivityManager|React|JS|usbaccessory"
adb logcat -v threadtime   UsbAccessoryModule:D ReactNativeJS:D   UsbManager:D UsbHostManager:D UsbDeviceManager:D ActivityManager:D   *:S

sudo tee /etc/udev/rules.d/99-android-accessory.rules >/dev/null <<'EOF'
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="2d01", MODE="0660", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0666", GROUP="plugdev"

EOF


sudo tee /etc/udev/rules.d/51-android.rules >/dev/null <<'EOF'
SUBSYSTEM=="usb", ATTR{idVendor}=="2717", MODE="0666"   # Xiaomi
SUBSYSTEM=="usb", ATTR{idVendor}=="22b8", MODE="0666"   # Motorola
SUBSYSTEM=="usb", ATTR{idVendor}=="0fce", MODE="0666"   # Sony
SUBSYSTEM=="usb", ATTR{idVendor}=="12d1", MODE="0666"   # Huawei

# PAX (Android base)
SUBSYSTEM=="usb", ATTR{idVendor}=="2fb8", ATTR{idProduct}=="2200", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2fb8", ATTR{idProduct}=="2201", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2fb8", ATTR{idProduct}=="2202", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2fb8", ATTR{idProduct}=="2203", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2fb8", ATTR{idProduct}=="2204", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2fb8", ATTR{idProduct}=="2205", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2fb8", ATTR{idProduct}=="2206", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2fb8", ATTR{idProduct}=="2207", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2fb8", ATTR{idProduct}=="2208", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2fb8", ATTR{idProduct}=="2209", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2fb8", ATTR{idProduct}=="2210", MODE="0666", GROUP="plugdev"

# Google AOA
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="2d00", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="2d01", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="2d02", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0666", GROUP="plugdev"

# Samsung MTP, etc
SUBSYSTEM=="usb", ATTR{idVendor}=="04e8", ATTR{idProduct}=="6860", MODE="0666", GROUP="plugdev"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger





sudo tee /opt/mirako_web/aoa.py >/dev/null <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import time
from datetime import datetime
from collections import deque
import threading
import queue

import usb.core
import usb.util
from flask import Flask, jsonify, render_template_string, request, send_file

# --- GPIO com libgpiod ---
try:
    import gpiod
except ModuleNotFoundError:
    gpiod = None

# Configuração GPIO (PC9 no Orange Pi)
PULSO_PIN = 73          # GPIO line para PC9
CHIP = 'gpiochip0'      # chip padrão


# =========================
# Util: timestamp
# =========================
def ts():
    return datetime.now().strftime("%Y-%m-%d %Y-%m-%d %H:%M:%S")  # corrigir duplicata se quiser


# =========================
# Constantes AOA / IDs
# =========================
AOA_VENDOR          = 0x18D1
AOA_PIDS            = {0x2D00, 0x2d01, 0x2D02, 0x2D03, 0x2D04, 0x2D05}
AOA_GET_PROTOCOL    = 51
AOA_SEND_IDENT      = 52
AOA_START           = 53
AOA_STR_MANUFACTURER= 0
AOA_STR_MODEL       = 1
AOA_STR_DESCRIPTION = 2
AOA_STR_VERSION     = 3
AOA_STR_URI         = 4
AOA_STR_SERIAL      = 5

# Device "base" (PAX A910 etc)
ANDROID_VENDOR = 0x2FB8
ANDROID_PIDS   = {
    0x2200, 0x2201, 0x2202, 0x2203, 0x2204,
    0x2205, 0x2206, 0x2207, 0x2208, 0x2209,
    0x2210,
}

# Identidade AOA
MANUFACTURER = "WEBSYS"
MODEL        = "RN-Pi-Link"
DESCRIPTION  = "RN<->Pi Accessory"
VERSION      = "1.0"
URI          = "https://mirako.org"
SERIAL       = "0001"

# Protocolo
POLL_LINE_AUTO   = b"B;057091;0;0;0;0;B\n"  # poll automático
POLL_LINE_MANUAL = b"B;057091;0;0;1;0;B\n"  # botão da UI
POLL_LINE_HS1    = b"$;854751;$\n"
POLL_LINE_HS2    = b"&;451796;0;0;&\n"

AFTER_ENUMERATION_GRACE = 1.5  # delay inicial depois de achar AOA
POLL_INTERVAL_SEC       = 5.0


# =========================
# Serviço AOA em thread
# =========================
class AOAService(threading.Thread):
    def __init__(self, max_logs=1000):
        super().__init__(daemon=True)
        self.lock = threading.Lock()

        # estado USB
        self.dev = None
        self.intf_no = None
        self.ep_in = None
        self.ep_out = None

        # estado de handshake
        self.hs1_done = False
        self.hs2_done = False

        # polling
        self.last_poll_ts = 0.0
        self.poll_count = 0
        self.no_dev_scan_count = 0   # contador de scans sem device

        # contador de RX
        self.rx_count = 0

        # tempos
        self.start_time = time.time()      # uptime do servidor
        self.aoa_connect_time = None       # uptime da conexão AOA

        # status / info
        self.status_text = "Procurando"
        self.usb_id = "--"
        self.device_info = {"manufacturer": "", "product": "", "serial": ""}

        # últimos TX/RX
        self.last_tx = ""
        self.last_rx = ""

        # logs
        self.logs = deque(maxlen=max_logs)

        # fila TX manual
        self.tx_queue = queue.Queue()

        # buffer RX de linha
        self.rx_buffer = bytearray()

        self.last_usb_snapshot = set()

        # --- GPIO / créditos ---
        self.gpio_chip = None
        self.gpio_line = None
        self.gpio_ok = False
        self.gpio_backend = "desativado"
        self.credit_log_path = "creditos_log.csv"

        # totais de créditos por máquina: {maquina_id: soma_creditocredito}
        self.credit_totals = {}

        self._init_gpio()

    # ---------- logging ----------
    def _log(self, kind, msg):
        line = f"[{ts()}] [{kind}] {msg}"
        with self.lock:
            self.logs.append(line)
        print(line, flush=True)

    # ---------- GPIO ----------
    def _init_gpio(self):
        if gpiod is None:
            self._log("GPIO", "libgpiod não instalada. Rode: pip3 install gpiod")
            self.gpio_ok = False
            self.gpio_backend = "não instalado"
            return

        try:
            chip = gpiod.Chip(CHIP)
            line = chip.get_line(PULSO_PIN)
            line.request(
                consumer="rn-credit",
                type=gpiod.LINE_REQ_DIR_OUT,
                default_val=0
            )
            self.gpio_chip = chip
            self.gpio_line = line
            self.gpio_ok = True
            self.gpio_backend = f"gpiod ({CHIP}, line {PULSO_PIN} / PC9)"
            self._log("GPIO", f"GPIO backend: {self.gpio_backend}")
        except Exception as e:
            self._log("GPIO", f"GPIO: falha na inicialização gpiod: {e}")
            self.gpio_ok = False
            self.gpio_backend = f"erro: {e}"

    def _registrar_credito_em_arquivo(self, maquina_id, creditomaquina, creditocredito):
        agora = ts()
        linha = f"{agora};{maquina_id};{creditomaquina};{creditocredito}\n"
        try:
            with open(self.credit_log_path, "a", encoding="utf-8") as f:
                f.write(linha)
            self._log("CREDIT", f"Registrado em arquivo: {linha.strip()}")
        except Exception as e:
            self._log("CREDIT", f"Erro ao gravar arquivo de créditos: {e}")

        # Atualiza totais por máquina
        with self.lock:
            atual = self.credit_totals.get(maquina_id, 0)
            self.credit_totals[maquina_id] = atual + creditocredito

    def _pulsar_creditos_gpio(self, creditocredito: int):
        if not self.gpio_ok or self.gpio_line is None:
            self._log("GPIO", f"Pulso de crédito ignorado, GPIO não disponível (creditocredito={creditocredito})")
            return

        try:
            for i in range(creditocredito):
                self.gpio_line.set_value(1)
                time.sleep(0.05)
                self.gpio_line.set_value(0)
                time.sleep(0.05)
            self._log("GPIO", f"Pulsos de crédito enviados: {creditocredito}x")
        except Exception as e:
            self._log("GPIO", f"Erro ao gerar pulsos de crédito: {e}")

    def _handle_credit_message(self, msg: str):
        """
        Exemplo de msg: "#;7C48247;02;002;0;*"
        parts[0] = "#"
        parts[1] = maquina_id (7C48247)
        parts[2] = creditomaquina ("02")
        parts[3] = creditocredito ("002")
        """
        parts = msg.split(";")
        if len(parts) < 5:
            self._log("CREDIT", f"Mensagem de crédito inválida: {msg}")
            return

        try:
            maquina_id = parts[1]
            creditomaquina = int(parts[2])
            creditocredito = int(parts[3])
        except Exception as e:
            self._log("CREDIT", f"Falha ao parsear mensagem de crédito '{msg}': {e}")
            return

        self._log("CREDIT", f"MAQUINA={maquina_id} CREDITO_MAQ={creditomaquina} CREDITO={creditocredito}")

        # 1) Salva em arquivo
        self._registrar_credito_em_arquivo(maquina_id, creditomaquina, creditocredito)

        # 2) Gera pulsos na GPIO
        self._pulsar_creditos_gpio(creditocredito)

    # =========================
    # Debug de devices
    # =========================
    def debug_list_all_devices(self):
        devs = usb.core.find(find_all=True)
        snapshot = set()
        lines = []

        for d in devs:
            try:
                vid = d.idVendor
                pid = d.idProduct
                vidpid = f"{vid:04x}:{pid:04x}"
            except Exception:
                vid = pid = None
                vidpid = "????:????"

            snapshot.add(vidpid)

            if self.is_accessory(d):
                tag = "AOA"
            elif vid == ANDROID_VENDOR and pid in ANDROID_PIDS:
                tag = "ANDROID_BASE"
            else:
                tag = "OUTRO"

            lines.append(f"{tag} {vidpid}")

        if snapshot != self.last_usb_snapshot:
            self.last_usb_snapshot = snapshot
            if lines:
                self._log("USB", "Scan devices: " + ", ".join(lines))
            else:
                self._log("USB", "Scan devices: <nenhum dispositivo>")

    # =========================
    # Descoberta de devices
    # =========================
    def is_accessory(self, dev):
        try:
            return dev.idVendor == AOA_VENDOR and dev.idProduct in AOA_PIDS
        except Exception:
            return False

    def find_accessory(self):
        try:
            devs = usb.core.find(find_all=True)
        except Exception as e:
            self._log("USB", f"find_accessory: erro ao varrer USB: {e}")
            return None

        if not devs:
            return None

        for d in devs:
            try:
                if self.is_accessory(d):
                    return d
            except Exception:
                continue

        return None

    def find_android_base(self):
        devs = usb.core.find(find_all=True)
        if not devs:
            return None
        for d in devs:
            try:
                if d.idVendor != ANDROID_VENDOR:
                    continue
                if d.idProduct not in ANDROID_PIDS:
                    continue
                if self.is_accessory(d):
                    continue
                return d
            except Exception:
                continue
        return None

    def aoa_switch_to_accessory(self, dev, retry_delay=0.5):
        # 1) GET_PROTOCOL
        while True:
            try:
                proto = dev.ctrl_transfer(0xC0, AOA_GET_PROTOCOL, 0, 0, 2)
                if len(proto) >= 2:
                    proto_ver = proto[0] | (proto[1] << 8)
                else:
                    proto_ver = 0

                self._log("AOA", f"GET_PROTOCOL -> {bytes(proto)} (v={proto_ver})")

                if proto_ver >= 1:
                    break
                else:
                    self._log("AOA", "GET_PROTOCOL retornou versão inválida, tentando de novo...")
            except usb.core.USBError as e:
                s = str(e).lower()
                errno = getattr(e, "errno", None)
                self._log("AOA", f"GET_PROTOCOL falhou: {e} (tentando novamente)")
                if errno == 19 or "no such device" in s:
                    self._log("AOA", "Dispositivo base sumiu durante GET_PROTOCOL, abortando handshake.")
                    return
            except Exception as e:
                self._log("AOA", f"GET_PROTOCOL erro genérico: {e} (tentando novamente)")
            time.sleep(retry_delay)

        # 2) Envia os IDENTs
        idents = [
            (AOA_STR_MANUFACTURER, MANUFACTURER),
            (AOA_STR_MODEL,        MODEL),
            (AOA_STR_DESCRIPTION,  DESCRIPTION),
            (AOA_STR_VERSION,      VERSION),
            (AOA_STR_URI,          URI),
            (AOA_STR_SERIAL,       SERIAL),
        ]
        for idx, val in idents:
            try:
                dev.ctrl_transfer(
                    0x40, AOA_SEND_IDENT, 0, idx,
                    val.encode("utf-8") + b"\x00"
                )
                self._log("AOA", f"IDENT idx={idx} '{val}' OK")
            except Exception as e:
                self._log("AOA", f"IDENT idx={idx} '{val}' ERRO: {e}")

        # 3) START
        try:
            dev.ctrl_transfer(0x40, AOA_START, 0, 0, None)
            self._log("AOA", "START enviado (Android deve reenumerar em modo AOA)")
        except Exception as e:
            self._log("AOA", f"AOA_START falhou: {e}")
            return

        try:
            usb.util.dispose_resources(dev)
        except Exception:
            pass

        # 5) Espera novo device AOA
        self._log("AOA", "Aguardando reenumeração para modo AOA (18d1:2d0x)...")

        for i in range(60):
            time.sleep(0.5)
            acc = self.find_accessory()
            if acc is None:
                continue

            self._log("INFO", "Accessory AOA encontrado após START, conectando...")

            self.dev = acc
            self.intf_no = None
            self.ep_in = self.ep_out = None
            self.hs1_done = False
            self.hs2_done = False
            self.rx_buffer.clear()

            time.sleep(AFTER_ENUMERATION_GRACE)

            try:
                intf_no, ep_in, ep_out = self.claim_bulk_endpoints(self.dev)
                usb_id = f"{self.dev.idVendor:04x}:{self.dev.idProduct:04x}"

                try:
                    m = usb.util.get_string(self.dev, self.dev.iManufacturer) or ""
                except Exception:
                    m = ""
                try:
                    p = usb.util.get_string(self.dev, self.dev.iProduct) or ""
                except Exception:
                    p = ""
                try:
                    s = usb.util.get_string(self.dev, self.dev.iSerialNumber) or ""
                except Exception:
                    s = ""

                with self.lock:
                    self.intf_no = intf_no
                    self.ep_in = ep_in
                    self.ep_out = ep_out
                    self.usb_id = usb_id
                    self.device_info = {"manufacturer": m, "product": p, "serial": s}
                    self.status_text = "Conectado"
                    self.aoa_connect_time = time.time()
                    self.rx_count = 0
                    self.poll_count = 0
                    self.credit_totals = {}

                self._log("INFO", f"Conectado AOA {usb_id} (pós-START)")
                return

            except Exception as e:
                msg = str(e).lower()
                if "no such device" in msg or getattr(e, "errno", None) == 19:
                    self._log("WARN", f"Accessory sumiu durante claim_bulk_endpoints (pós-START): {e}")
                else:
                    self._log("ERRO", f"claim_bulk_endpoints (pós-START): {e}")

                try:
                    if self.intf_no is not None:
                        usb.util.release_interface(self.dev, self.intf_no)
                except Exception:
                    pass
                try:
                    usb.util.dispose_resources(self.dev)
                except Exception:
                    pass

                self.dev = None
                self.intf_no = None
                self.ep_in = self.ep_out = None
                with self.lock:
                    self.status_text = "Procurando"
                    self.aoa_connect_time = None
                    self.credit_totals = {}

                return

        self._log(
            "WARN",
            "Timeout esperando device AOA (18d1:2d0x) após START."
        )

    # =========================
    # USB helpers
    # =========================
    def _detach_all_kernel_drivers(self, dev):
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

    def _pick_bulk_pair(self, intf):
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

    def claim_bulk_endpoints(self, dev, retries=4, retry_sleep=0.25):
        try:
            dev.set_configuration()
        except Exception:
            pass

        last_err = None
        for attempt in range(1, retries + 1):
            try:
                self._detach_all_kernel_drivers(dev)
                cfg = dev.get_active_configuration()

                for stage in (1, 2):
                    for intf in cfg:
                        try:
                            proto = getattr(intf, "bInterfaceProtocol", 0)
                        except Exception:
                            proto = 0

                        if stage == 1 and proto == 1:
                            continue

                        ep_in, ep_out = self._pick_bulk_pair(intf)
                        if ep_in and ep_out:
                            try:
                                usb.util.claim_interface(dev, intf.bInterfaceNumber)
                            except usb.core.USBError as e:
                                if getattr(e, "errno", None) in (16,):  # EBUSY
                                    last_err = e
                                    time.sleep(retry_sleep * attempt)
                                    continue
                                else:
                                    raise
                            return intf.bInterfaceNumber, ep_in, ep_out

                raise RuntimeError("Endpoints IN/OUT não encontrados")
            except usb.core.USBError as e:
                last_err = e
                time.sleep(retry_sleep * attempt)
            except Exception as e:
                last_err = e
                break

        if last_err:
            raise last_err
        raise RuntimeError("Falha ao reivindicar interface")

    # =========================
    # safe_write
    # =========================
    def safe_write(self, label, payload):
        with self.lock:
            dev = self.dev
            ep_out = self.ep_out
        if dev is None or ep_out is None:
            self._log("WARN", f"{label}: write sem device/endpoint")
            return False
        try:
            dev.write(ep_out.bEndpointAddress, payload, timeout=1000)
            txt = payload.decode(errors="ignore").strip()
            with self.lock:
                self.last_tx = txt
            self._log("TX", f"{label}: {txt}")
            return True
        except usb.core.USBError as e:
            self._log("WARN", f"Erro em write ({label}): {e}")
            return False
        except Exception as e:
            self._log("WARN", f"Erro genérico em write ({label}): {e}")
            return False

    # =========================
    # API pública: enviar manual
    # =========================
    def send_manual_poll(self):
        self.tx_queue.put(("MANUAL", POLL_LINE_MANUAL))

    # =========================
    # Snapshot de status para a UI
    # =========================
    def get_status(self):
        with self.lock:
            uptime = time.time() - self.start_time
            aoa_up = time.time() - self.aoa_connect_time if self.aoa_connect_time else 0.0
            st = {
                "status": self.status_text,
                "uptime": uptime,
                "aoa_uptime": aoa_up,
                "usb_id": self.usb_id,
                "manufacturer": self.device_info.get("manufacturer", ""),
                "product": self.device_info.get("product", ""),
                "serial": self.device_info.get("serial", ""),
                "poll_count": self.poll_count,   # não mostramos na UI, mas mantemos
                "rx_count": self.rx_count,
                "last_tx": self.last_tx,
                "last_rx": self.last_rx,
                "gpio_ok": self.gpio_ok,
                "gpio_backend": self.gpio_backend,
                "credit_totals": self.credit_totals.copy(),
                "logs": list(self.logs),
            }
        return st

    # =========================
    # Loop principal
    # =========================
    def run(self):
        last_scan_log = 0.0
        no_dev_since = time.time()
        scan_attempt = 0

        while True:
            now = time.time()

            # 1) Poll automático
            if now - self.last_poll_ts >= POLL_INTERVAL_SEC:
                with self.lock:
                    self.poll_count += 1
                    self.last_poll_ts = now

                if self.dev is not None and self.ep_out is not None:
                    self.safe_write(f"TX_POLL#{self.poll_count}", POLL_LINE_AUTO)

            # 2) Consumir fila de TX manual
            while True:
                try:
                    label, payload = self.tx_queue.get_nowait()
                except queue.Empty:
                    break

                if self.dev is not None and self.ep_out is not None:
                    self.safe_write(label, payload)
                else:
                    self._log("WARN", f"Descartando TX '{label}' (sem device/endpoint)")

            # 3) Se NÃO temos dev AOA, tentar achar (AOA direto ou base)
            if self.dev is None:
                if self.aoa_connect_time is not None:
                    no_dev_since = now
                    with self.lock:
                        self.aoa_connect_time = None
                        self.status_text = "Procurando"
                        self.credit_totals = {}

                scan_attempt += 1

                if now - last_scan_log >= 2.0:
                    self._log("INFO", f"Procurando device em modo AOA... (tentativa {scan_attempt})")
                    try:
                        self.debug_list_all_devices()
                    except Exception as e:
                        self._log("USB", f"debug_list_all_devices erro: {e}")
                    last_scan_log = now

                # 3a) Tenta achar já em modo AOA
                acc = self.find_accessory()
                if acc is not None:
                    self._log("INFO", "Accessory AOA encontrado, conectando direto (sem handshake base).")
                    self.dev = acc
                    self.intf_no = None
                    self.ep_in = self.ep_out = None
                    self.hs1_done = False
                    self.hs2_done = False
                    self.rx_buffer.clear()

                    time.sleep(AFTER_ENUMERATION_GRACE)

                    try:
                        intf_no, ep_in, ep_out = self.claim_bulk_endpoints(self.dev)
                        usb_id = f"{self.dev.idVendor:04x}:{self.dev.idProduct:04x}"

                        try:
                            m = usb.util.get_string(self.dev, self.dev.iManufacturer) or ""
                        except Exception:
                            m = ""
                        try:
                            p = usb.util.get_string(self.dev, self.dev.iProduct) or ""
                        except Exception:
                            p = ""
                        try:
                            s = usb.util.get_string(self.dev, self.dev.iSerialNumber) or ""
                        except Exception:
                            s = ""

                        with self.lock:
                            self.intf_no = intf_no
                            self.ep_in = ep_in
                            self.ep_out = ep_out
                            self.usb_id = usb_id
                            self.device_info = {"manufacturer": m, "product": p, "serial": s}
                            self.status_text = "Conectado"
                            self.aoa_connect_time = time.time()
                            self.rx_count = 0
                            self.poll_count = 0
                            self.credit_totals = {}

                        self._log("INFO", f"[INFO] Conectado AOA {usb_id}")
                        scan_attempt = 0
                    except Exception as e:
                        msg = str(e).lower()
                        if "no such device" in msg or getattr(e, "errno", None) == 19:
                            self._log("WARN", f"Accessory sumiu durante claim_bulk_endpoints (re-enum?): {e}")
                        else:
                            self._log("ERRO", f"claim_bulk_endpoints (AOA direto): {e}")

                        try:
                            if self.intf_no is not None:
                                usb.util.release_interface(self.dev, self.intf_no)
                        except Exception:
                            pass
                        try:
                            usb.util.dispose_resources(self.dev)
                        except Exception:
                            pass

                        self.dev = None
                        self.intf_no = None
                        self.ep_in = self.ep_out = None
                        with self.lock:
                            self.status_text = "Procurando"
                            self.aoa_connect_time = None
                            self.credit_totals = {}

                    time.sleep(0.1)
                    continue

                # 3b) Tenta achar base e fazer handshake
                base = self.find_android_base()
                if base is not None:
                    try:
                        vidpid = f"{base.idVendor:04x}:{base.idProduct:04x}"
                    except Exception:
                        vidpid = "????:????"
                    self._log("INFO", f"Encontrado Android base {vidpid}, iniciando handshake AOA...")
                    self.aoa_switch_to_accessory(base)
                else:
                    if scan_attempt % 3 == 0:
                        self._log(
                            "INFO",
                            f"[RECOVERY] Nenhum Android base 2fb8:220x visível após {scan_attempt} scans."
                        )

                time.sleep(0.1)
                continue

            # 4) Temos dev AOA; garantir endpoints
            if self.dev is not None and (self.ep_in is None or self.ep_out is None):
                try:
                    intf_no, ep_in, ep_out = self.claim_bulk_endpoints(self.dev)
                    usb_id = f"{self.dev.idVendor:04x}:{self.dev.idProduct:04x}"
                    with self.lock:
                        self.intf_no = intf_no
                        self.ep_in = ep_in
                        self.ep_out = ep_out
                        self.usb_id = usb_id
                        self.status_text = "Conectado"
                        self.aoa_connect_time = time.time()
                        self.rx_count = 0
                        self.poll_count = 0
                        self.credit_totals = {}
                    self._log("INFO", f"(re)Conectado AOA {usb_id}")
                    self.hs1_done = False
                    self.hs2_done = False
                    self.rx_buffer.clear()
                except Exception as e:
                    self._log("ERRO", f"claim_bulk_endpoints (já com dev): {e}")
                    try:
                        if self.intf_no is not None:
                            usb.util.release_interface(self.dev, self.intf_no)
                    except Exception:
                        pass
                    try:
                        usb.util.dispose_resources(self.dev)
                    except Exception:
                        pass

                    self.dev = None
                    self.intf_no = None
                    self.ep_in = self.ep_out = None
                    self.hs1_done = self.hs2_done = False
                    self.rx_buffer.clear()
                    with self.lock:
                        self.status_text = "Procurando"
                        self.aoa_connect_time = None
                        self.rx_count = 0
                        self.poll_count = 0
                        self.credit_totals = {}
                    time.sleep(0.2)
                    continue

            # 5) Enviar HS1 / HS2 uma vez por conexão
            if self.dev is not None and self.ep_out is not None:
                if not self.hs1_done:
                    ok1 = self.safe_write("TX_HS1", POLL_LINE_HS1)
                    if not ok1:
                        self._log("INFO", "HS1 falhou (timeout/busy?), mantendo sessão")
                    self.hs1_done = True

                if not self.hs2_done:
                    ok2 = self.safe_write("TX_HS2", POLL_LINE_HS2)
                    if not ok2:
                        self._log("INFO", "HS2 falhou (timeout/busy?), mantendo sessão")
                    self.hs2_done = True

            # 6) Ler dados (RX)
            if self.dev is not None and self.ep_in is not None:
                try:
                    size = getattr(self.ep_in, "wMaxPacketSize", 64) or 64
                    data = self.dev.read(self.ep_in.bEndpointAddress, size, timeout=500)
                except usb.core.USBError as e:
                    s = str(e).lower()
                    errno = getattr(e, "errno", None)
                    if errno in (110,) or "timed out" in s:
                        time.sleep(0.01)
                        continue
                    if errno == 19 or "no such device" in s:
                        self._log("WARN", f"Dispositivo sumiu (no such device): {e}")
                    else:
                        self._log("WARN", f"Erro de leitura, assumindo desconexão: {e}")

                    try:
                        if self.intf_no is not None:
                            usb.util.release_interface(self.dev, self.intf_no)
                    except Exception:
                        pass
                    try:
                        usb.util.dispose_resources(self.dev)
                    except Exception:
                        pass

                    self.dev = None
                    self.intf_no = None
                    self.ep_in = self.ep_out = None
                    self.hs1_done = self.hs2_done = False
                    self.rx_buffer.clear()
                    with self.lock:
                        self.status_text = "Procurando"
                        self.aoa_connect_time = None
                        self.rx_count = 0
                        self.poll_count = 0
                        self.credit_totals = {}
                    time.sleep(0.2)
                    continue

                if data:
                    hex_str = " ".join(f"{b:02X}" for b in data)
                    self._log("RX_RAW", f"({len(data)} bytes): {hex_str}")
                    try:
                        text = data.decode("utf-8", errors="replace")
                        self._log("RX_TXT", repr(text))
                    except Exception:
                        pass

                    self.rx_buffer.extend(data)
                    while b"\n" in self.rx_buffer:
                        line, _, self.rx_buffer = self.rx_buffer.partition(b"\n")
                        try:
                            msg = line.decode("utf-8", errors="ignore").strip()
                        except Exception:
                            msg = repr(line)
                        with self.lock:
                            self.last_rx = msg
                            self.rx_count += 1
                        self._log("RX_LINE", msg)

                        # Mensagens de crédito
                        if msg.startswith("#;"):
                            self._handle_credit_message(msg)

                        # Handshake RX -> TX
                        if msg == "!;157458;!":
                            self.safe_write("AUTO_HS1", POLL_LINE_HS1)
                        elif msg == "@;697154;@":
                            self.safe_write("AUTO_HS2", POLL_LINE_HS2)
                        elif msg == "S;190750;S":
                            self.safe_write("AUTO_POLL", POLL_LINE_AUTO)

            time.sleep(0.01)


# =========================
# Flask + UI
# =========================
app = Flask(__name__)
svc = AOAService()
svc.start()

INDEX_HTML = """
<!doctype html>
<html lang="pt-br">
<head>
<meta charset="utf-8">
<title>AOA USB Monitor</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root{
  color-scheme: dark;
  --bg:#0f1117;
  --bg2:#111827;
  --bg3:#020617;
  --border:#1f2937;
  --text:#e5e7eb;
  --muted:#9ca3af;
  --accent:#22c55e;
  --accent2:#3b82f6;
  --danger:#ef4444;
}
*{box-sizing:border-box;margin:0;padding:0}
body{
  font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,Arial,sans-serif;
  background:var(--bg);
  color:var(--text);
}
header{
  padding:12px 16px;
  background:var(--bg2);
  border-bottom:1px solid var(--border);
  display:flex;
  justify-content:space-between;
  align-items:center;
  gap:12px;
}
h1{font-size:18px;font-weight:600;}
main{
  padding:16px;
  display:grid;
  grid-template-columns:1.1fr 1.2fr;
  gap:16px;
}
.card{
  background:var(--bg2);
  border:1px solid var(--border);
  border-radius:8px;
  padding:12px;
}
.card h2{
  font-size:16px;
  margin-bottom:8px;
}
.status-grid{
  display:grid;
  grid-template-columns:minmax(0,1fr) minmax(0,1fr);
  gap:4px 12px;
  font-size:13px;
}
.status-label{color:var(--muted);}
.status-value{font-weight:500;word-break:break-all;}
.badge{
  display:inline-flex;
  align-items:center;
  padding:2px 8px;
  border-radius:999px;
  font-size:11px;
}
.badge-ok{background:rgba(34,197,94,.12);color:var(--accent);}
.badge-warn{background:rgba(248,113,113,.15);color:var(--danger);}
button{
  background:var(--bg3);
  color:var(--text);
  border:1px solid var(--border);
  border-radius:6px;
  padding:8px 12px;
  font-size:13px;
  cursor:pointer;
}
button:hover{border-color:var(--accent2);}
button.primary{
  background:var(--accent2);
  border-color:var(--accent2);
}
button.primary:hover{filter:brightness(1.1);}
.row{display:flex;flex-wrap:wrap;gap:8px;margin-top:4px;}
pre.term{
  height:60vh;
  background:var(--bg3);
  border:1px solid var(--border);
  border-radius:6px;
  padding:8px;
  font-size:11px;
  font-family:ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
  overflow-y:auto;
  white-space:pre-wrap;
}
small{color:var(--muted);font-size:11px;}
@media (max-width: 900px){
  main{grid-template-columns:1fr;}
}
table{
  width:100%;
  border-collapse:collapse;
  font-size:12px;
  margin-top:4px;
}
table th, table td{
  border:1px solid var(--border);
  padding:4px 6px;
  text-align:left;
}
table th{
  background:var(--bg3);
}
a.link{
  color:var(--accent2);
  text-decoration:none;
  font-size:12px;
}
a.link:hover{
  text-decoration:underline;
}
</style>
</head>
<body>
<header>
  <h1>AOA USB Monitor · WEBSYS</h1>
  <div id="statusBadge" class="badge badge-warn">Carregando...</div>
</header>

<main>
  <section class="card">
    <h2>Status</h2>
    <div class="status-grid" id="statusGrid"></div>

    <h2 style="margin-top:10px;">Créditos por máquina</h2>
    <table id="creditTable">
      <thead>
        <tr><th>Máquina</th><th>Total de créditos</th></tr>
      </thead>
      <tbody>
      </tbody>
    </table>
    <small>
      <a href="/download_creditos" class="link" target="_blank">Baixar CSV de créditos</a>
    </small>

    <small style="display:block;margin-top:8px;">
      Atualiza automaticamente a cada 1s. Interface 100% offline.
    </small>
    <hr style="border:none;border-top:1px solid var(--border);margin:10px 0;">
    <h2>Controles</h2>
    <div class="row">
      <button class="primary" onclick="sendManualPoll()">Enviar B;057091;0;0;1;0;B</button>
      <button onclick="refreshNow()">Atualizar agora</button>
      <button onclick="clearLog()">Limpar log local</button>
    </div>
  </section>

  <section class="card">
    <h2>Log</h2>
    <pre id="logTerm" class="term"></pre>
    <small>Últimas linhas do log. Rola automaticamente para o final.</small>
  </section>
</main>

<script>
function fmtDur(sec){
  sec = Math.max(0, Math.floor(sec||0));
  const h = String(Math.floor(sec/3600)).padStart(2,'0');
  const m = String(Math.floor((sec%3600)/60)).padStart(2,'0');
  const s = String(sec%60).padStart(2,'0');
  return h+":"+m+":"+s;
}
function scrollLogBottom(){
  const pre = document.getElementById('logTerm');
  pre.scrollTop = pre.scrollHeight;
}

async function refreshNow(){
  try{
    const r = await fetch('/api/status');
    const st = await r.json();

    const badge = document.getElementById('statusBadge');
    if(st.status === 'Conectado'){
      badge.className = 'badge badge-ok';
      badge.textContent = 'Conectado · '+(st.usb_id||'--')+' · AOA '+fmtDur(st.aoa_uptime||0);
    }else{
      badge.className = 'badge badge-warn';
      badge.textContent = 'Procurando dispositivo...';
    }

    const rows = [];
    function row(a,b){
      rows.push('<div class="status-label">'+a+'</div><div class="status-value">'+b+'</div>');
    }
    row('Status', st.status||'--');
    row('Uptime servidor', fmtDur(st.uptime||0));
    row('Uptime AOA', fmtDur(st.aoa_uptime||0));
    row('USB VID:PID', st.usb_id||'--');
    row('Fabricante', st.manufacturer||'--');
    row('Produto', st.product||'--');
    row('Serial', st.serial||'--');
    row('RX recebidos', st.rx_count||0);
    row('Driver GPIO', st.gpio_ok ? ('OK · '+(st.gpio_backend||'')) : 'NÃO INSTALADO / ERRO');
    row('Último TX', st.last_tx||'—');
    row('Último RX', st.last_rx||'—');
    document.getElementById('statusGrid').innerHTML = rows.join('');

    // Preenche tabela de créditos totais por máquina
    const ct = st.credit_totals || {};
    const tbody = document.querySelector('#creditTable tbody');
    if(tbody){
      const keys = Object.keys(ct).sort();
      if(keys.length === 0){
        tbody.innerHTML = '<tr><td colspan="2">Nenhum crédito registrado ainda.</td></tr>';
      }else{
        tbody.innerHTML = keys.map(maq => {
          return '<tr><td>'+maq+'</td><td>'+ct[maq]+'</td></tr>';
        }).join('');
      }
    }

    const term = document.getElementById('logTerm');
    const shouldStick = (term.scrollTop + term.clientHeight + 40) >= term.scrollHeight;
    term.textContent = (st.logs||[]).join("\\n");
    if(shouldStick) scrollLogBottom();
  }catch(e){
    console.error(e);
  }
}

async function sendManualPoll(){
  try{
    const r = await fetch('/api/send_manual', {method:'POST'});
    const dj = await r.json();
    if(!dj.ok){
      alert('Falha ao enviar: '+(dj.error||'desconhecido'));
    }
  }catch(e){
    alert('Erro ao enviar: '+e);
  }
}

function clearLog(){
  document.getElementById('logTerm').textContent = '';
}

setInterval(refreshNow, 1000);
refreshNow();
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

@app.route("/api/send_manual", methods=["POST"])
def api_send_manual():
    try:
        svc.send_manual_poll()
        return jsonify({"ok": True})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500

@app.route("/download_creditos")
def download_creditos():
    path = svc.credit_log_path
    if not os.path.exists(path):
        return "Nenhum crédito registrado ainda.", 404
    try:
        return send_file(
            path,
            mimetype="text/csv",
            as_attachment=True,
            download_name="creditos_log.csv"
        )
    except Exception as e:
        return f"Erro ao baixar arquivo: {e}", 500

if __name__ == "__main__":
    host = "0.0.0.0"
    port = 5002
    print(f"[{ts()}] Iniciando Flask em {host}:{port}")
    app.run(host=host, port=port, threaded=True)


PYEOF


sudo systemctl restart aoa.service



tail -f ~/.cache/aoa_usb_server/aoa_rxtx.log





sudo tee /etc/systemd/system/aoa.service >/dev/null <<'EOF'
[Unit]
Description=AOA USB Monitor (WEBSYS)
After=network.target

[Service]
Type=simple

# garante que roda como root
User=root
Group=root

WorkingDirectory=/opt/mirako_web
ExecStart=/usr/bin/python3 /opt/mirako_web/aoa.py

Restart=always
RestartSec=3

# ambiente
Environment=PYTHONUNBUFFERED=1

# MUITO IMPORTANTE: NÃO isolar /dev nem devices
PrivateDevices=no
PrivateTmp=no
ProtectSystem=off
ProtectHome=off
DevicePolicy=auto
# Se tiver systemd mais novo, pode forçar:
# DeviceAllow=char-usb_device rw

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload

sudo systemctl restart aoa.service

sudo systemctl enable --now aoa.service

sudo systemctl stop aoa.service

journalctl -fu aoa.service


