pip install esptool pyserial --break-system-packages



mkdir /opt/esp32web/



sudo tee /opt/esp32web/app.py >/dev/null <<'EOF'
import os
import time
import glob
import shutil
import threading
from collections import deque
from pathlib import Path
from datetime import datetime

from flask import Flask, render_template_string, request, redirect, url_for, flash, jsonify, Response
import serial
import subprocess

APP = Flask(__name__)
APP.secret_key = os.environ.get("ESP32WEB_SECRET", "change-me")

SEARCH_DIR = Path(os.environ.get("ESP32_SEARCH_DIR", "/root"))
FLASH_LOG = Path(os.environ.get("ESP32_FLASH_LOG", "/root/esp32_flash_log.txt"))

# ✅ NOVO: serial persistente em arquivo
SERIAL_LOG = Path(os.environ.get("ESP32_SERIAL_LOG", "/root/esp32_serial_log.txt"))

MAX_UPLOAD_MB = int(os.environ.get("ESP32_MAX_UPLOAD_MB", "200"))
APP.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_MB * 1024 * 1024

# ===== Serial monitor config =====
SERIAL_BAUD = int(os.environ.get("ESP32_SERIAL_BAUD", "115200"))
SERIAL_SCAN_INTERVAL = float(os.environ.get("ESP32_SERIAL_SCAN_INTERVAL", "2.0"))

# ===== esptool flash config =====
ESP32_BAUD = int(os.environ.get("ESP32_BAUD", "921600"))
FLASH_MODE = os.environ.get("ESP32_FLASH_MODE", "dio")
FLASH_FREQ = os.environ.get("ESP32_FLASH_FREQ", "40m")
FLASH_SIZE = os.environ.get("ESP32_FLASH_SIZE", "detect")

serial_lock = threading.Lock()

# ✅ Aumenta o buffer em RAM (ainda é “tail”, o “completo” fica no arquivo)
serial_lines = deque(maxlen=5000)

serial_port_name = None
serial_connected = False
serial_last_error = ""

serial_stop_event = threading.Event()
serial_pause_event = threading.Event()
serial_released_event = threading.Event()
serial_released_event.set()
serial_handle = None

# ===== Flash runtime state =====
flash_lock = threading.Lock()  # impede 2 flashes
flash_state_lock = threading.Lock()
flash_running = False
flash_started_at = 0.0
flash_finished_at = 0.0
flash_port = None
flash_last_error = ""
flash_last_lines = deque(maxlen=400)
flash_returncode = None


HTML_INDEX = r"""<!doctype html>
<html lang="pt-br">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>ESP32 Web Flasher</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
  <style>
    body { background:#0b1220; color:#e8eefc; }
    .card { background:#101a33; border:1px solid rgba(255,255,255,.08); }
    .btn-atualizar { font-size: 1.6rem; padding: 18px 22px; font-weight: 800; }
    pre { background:#070b14; color:#d7e3ff; padding:14px; border-radius:10px; border:1px solid rgba(255,255,255,.08); }
    .muted { color: rgba(232,238,252,.75); }
    .form-check-input { transform: scale(1.2); }
    code { word-break: break-all; }
    .badge-soft { background: rgba(13,110,253,.15); border:1px solid rgba(13,110,253,.35); color:#bcd2ff; }
    .card h5, .card h4, .card h3 { color: #ffffff !important; }
  </style>
</head>
<body>
<div class="container py-4">
  <div class="d-flex align-items-center justify-content-between mb-3">
    <div>
      <h3 class="mb-0 text-white">ESP32 Web Flasher</h3>
      <div class="muted">Pasta: <code class="text-info">{{ search_dir }}</code> | Porta: 5004</div>
    </div>
    <div class="d-flex gap-2">
      <a class="btn btn-outline-info" href="/log" target="_blank">Abrir log completo (flash)</a>
      <a class="btn btn-outline-info" href="/serial/log" target="_blank">Abrir log completo (serial)</a>

      <form method="post" action="/clear_logs" class="m-0">
        <button class="btn btn-outline-warning" type="submit"
                onclick="return confirm('Limpar log do flash e RAM tail?');">Limpar log</button>
      </form>
      <form method="post" action="/clear_serial" class="m-0">
        <button class="btn btn-outline-warning" type="submit"
                onclick="return confirm('Limpar serial monitor (RAM) + arquivo?');">Limpar serial</button>
      </form>
      <form method="post" action="/clear_all" class="m-0">
        <button class="btn btn-warning" type="submit"
                onclick="return confirm('Limpar log + serial?');">Limpar tudo</button>
      </form>
    </div>
  </div>

  {% with messages = get_flashed_messages(with_categories=true) %}
    {% if messages %}
      <div class="mb-3">
        {% for cat, msg in messages %}
          <div class="alert alert-{{cat}} mb-2">{{ msg }}</div>
        {% endfor %}
      </div>
    {% endif %}
  {% endwith %}

  <div class="row g-3">
    <div class="col-lg-5">
      <div class="card p-3">
        <h5 class="mb-2">Upload de .bin</h5>
        <form method="post" action="/upload" enctype="multipart/form-data" class="d-flex gap-2">
          <input class="form-control" type="file" name="binfile" accept=".bin" required>
          <button class="btn btn-primary" type="submit">Enviar</button>
        </form>
        <div class="muted mt-2">Sobrescreve se já existir.</div>
      </div>

      <div class="card p-3 mt-3">
        <div class="d-flex align-items-center justify-content-between">
          <h5 class="mb-2">Selecionar .bin</h5>
          <button type="button" class="btn btn-sm btn-outline-light" onclick="toggleAll(true)">Marcar todos</button>
        </div>

        <form method="post" action="/flash" id="flashForm">
          <div class="mb-3" style="max-height: 320px; overflow:auto;">
            {% if bins|length == 0 %}
              <div class="muted">Nenhum .bin em {{ search_dir }}</div>
            {% else %}
              {% for b in bins %}
                <div class="form-check py-1 d-flex align-items-center justify-content-between">
                  <div>
                    <input class="form-check-input bincheck" type="checkbox" name="bins" value="{{ b.name }}" id="bin_{{ loop.index }}">
                    <label class="form-check-label" for="bin_{{ loop.index }}">
                      <code class="text-info">{{ b.name }}</code>
                      <span class="muted"> — {{ (b.stat().st_size/1024)|round(1) }} KB</span>
                    </label>
                  </div>
                </div>
              {% endfor %}
            {% endif %}
          </div>

          <button class="btn btn-success w-100 btn-atualizar mb-2" type="submit" id="btnFlash">
            ATUALIZAR
          </button>

          <button class="btn btn-outline-danger w-100 mb-2" type="submit" formaction="/reboot"
                  onclick="return confirm('Reiniciar o ESP32 agora?');">
            REINICIAR ESP32
          </button>

          <button class="btn btn-danger w-100" type="submit" formaction="/delete"
                  onclick="return confirm('Excluir os .bin selecionados?');">
            EXCLUIR SELECIONADOS
          </button>

          <div class="muted mt-2">
            Flash assíncrono + log ao vivo no arquivo.
          </div>
        </form>
      </div>
    </div>

    <div class="col-lg-7">
      <div class="card p-3 mb-3">
        <div class="d-flex align-items-center justify-content-between">
          <h5 class="mb-2">Serial (ttyUSB / ttyACM)</h5>
          <div class="muted" id="serialStatus">scaneando...</div>
        </div>

        <!-- ✅ CORRIGIDO: divs fechadas corretamente -->
        <div class="d-flex flex-wrap align-items-center justify-content-between mb-2 gap-3">
          <div class="d-flex gap-3 flex-wrap">
            <div class="form-check">
              <input class="form-check-input" type="checkbox" id="serialAutoscroll" checked>
              <label class="form-check-label muted" for="serialAutoscroll">Ir para última linha</label>
            </div>
          </div>

          <div class="d-flex gap-2">
            <button class="btn btn-sm btn-outline-info" onclick="refreshSerial(true)">Recarregar</button>
          </div>
        </div>

        <pre class="mb-0" id="serialBox" style="max-height: 260px; overflow:auto;">(aguardando dados...)</pre>
      </div>

      <div class="card p-3">
        <div class="d-flex align-items-center justify-content-between">
          <div>
            <h5 class="mb-1">Últimas linhas do log (arquivo - flash)</h5>
            <div class="d-flex align-items-center gap-3 flex-wrap">
              <div class="form-check m-0">
                <input class="form-check-input" type="checkbox" id="fileLogAutoscroll" checked>
                <label class="form-check-label muted" for="fileLogAutoscroll">Ir para última linha</label>
              </div>

              <span class="muted" id="fileLogStatus"></span>
            </div>
          </div>

          <button class="btn btn-sm btn-outline-info" onclick="refreshFileLog(true)">Recarregar</button>
        </div>

        <pre class="mb-0 mt-2" id="fileLogBox" style="max-height: 640px; overflow:auto;">{{ log_tail }}</pre>
      </div>
    </div>
  </div>
</div>

<script>
  function toggleAll(state){
    document.querySelectorAll('.bincheck').forEach(cb => cb.checked = state);
  }

  function selectionIsInside(el){
    const sel = window.getSelection();
    if(!sel) return false;
    if(sel.isCollapsed) return false;
    const a = sel.anchorNode;
    const f = sel.focusNode;
    if(!a || !f) return false;
    return el.contains(a) || el.contains(f);
  }

async function refreshSerial(forceScroll){
  try{
    const st = await fetch('/serial/status', {cache:'no-store'}).then(r=>r.json());
    const statusEl = document.getElementById('serialStatus');
    const box = document.getElementById('serialBox');

    if(st.paused){
      statusEl.textContent = `PAUSADO (flash em andamento)`;
    }else if(st.connected){
      statusEl.textContent = `conectado: ${st.port} @ ${st.baud}`;
    }else{
      statusEl.textContent = `desconectado (scan...) ${st.last_error ? " | " + st.last_error : ""}`;
    }

    // Auto-pause SEMPRE ao selecionar texto dentro do box
    if (selectionIsInside(box)) return;

    const auto = document.getElementById('serialAutoscroll');
    const prevScrollTop = box.scrollTop;

    // ✅ AGORA LÊ DO ARQUIVO (persistente)
    const text = await fetch('/serial/log/tail?lines=3000', {cache:'no-store'}).then(r=>r.text());
    box.textContent = text || "(sem linhas ainda)";

    if (forceScroll || (auto && auto.checked)) {
      box.scrollTop = box.scrollHeight;
    } else {
      box.scrollTop = prevScrollTop;
    }
  }catch(e){}
}


async function refreshFileLog(forceScroll){
  try{
    const st = await fetch('/log/status', {cache:'no-store'}).then(r=>r.json());
    const box = document.getElementById('fileLogBox');
    const status = document.getElementById('fileLogStatus');

    status.textContent = st.running ? `flash rodando ${st.port ? "(" + st.port + ")" : ""}` : `parado`;

    // ✅ Auto-pause SEMPRE que houver seleção dentro do log
    if (selectionIsInside(box)) return;

    const auto = document.getElementById('fileLogAutoscroll');
    const prevScrollTop = box.scrollTop;

    const text = await fetch('/log/tail?lines=600', {cache:'no-store'}).then(r=>r.text());
    box.textContent = text || "(sem log ainda)";

    if (forceScroll || (auto && auto.checked)) {
      box.scrollTop = box.scrollHeight;
    } else {
      box.scrollTop = prevScrollTop;
    }
  }catch(e){}
}


  setInterval(()=>refreshSerial(false), 800);
  setInterval(()=>refreshFileLog(false), 650);


  refreshSerial(true);
  refreshFileLog(true);

</script>
</body>
</html>
"""


# ===== Logs =====
def _log_flash(msg: str):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"

    try:
        FLASH_LOG.parent.mkdir(parents=True, exist_ok=True)
        with FLASH_LOG.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass

    with flash_state_lock:
        flash_last_lines.append(line)


def _log_serial_to_file(line: str):
    try:
        SERIAL_LOG.parent.mkdir(parents=True, exist_ok=True)
        with SERIAL_LOG.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


# ===== Timestamp helpers (SERIAL) =====
def _ts():
    return datetime.now().strftime("%H:%M:%S")

def _serial_push(line: str, tag: str = ""):
    prefix = f"[{_ts()}]"
    if tag:
        prefix += f"[{tag}]"
    full = f"{prefix} {line}"

    serial_lines.append(full)
    _log_serial_to_file(full)


def list_bins():
    if not SEARCH_DIR.exists():
        return []
    return sorted([p for p in SEARCH_DIR.iterdir() if p.is_file() and p.suffix.lower() == ".bin"],
                  key=lambda x: x.name.lower())


def safe_under_root(p: Path) -> bool:
    try:
        p.resolve().relative_to(SEARCH_DIR.resolve())
        return True
    except Exception:
        return False


# ✅ tail eficiente (não lê arquivo inteiro)
def tail_file(path: Path, max_lines: int = 200) -> str:
    try:
        if not path.exists():
            return "(sem log ainda)"

        max_lines = max(1, int(max_lines))
        with path.open("rb") as f:
            f.seek(0, os.SEEK_END)
            end = f.tell()
            if end == 0:
                return "(sem log ainda)"

            block = 4096
            data = b""
            pos = end

            # puxa blocos do fim até ter linhas suficientes
            while pos > 0 and data.count(b"\n") <= max_lines:
                step = block if pos - block > 0 else pos
                pos -= step
                f.seek(pos, os.SEEK_SET)
                data = f.read(step) + data

                # evita explodir memória se arquivo for enorme
                if len(data) > 4 * 1024 * 1024:  # 4MB
                    break

        text = data.decode("utf-8", errors="replace")
        lines = text.splitlines()
        return "\n".join(lines[-max_lines:])

    except Exception as e:
        return f"(erro lendo log: {e})"


# ===== Serial internals =====
def scan_ports():
    return sorted(glob.glob("/dev/ttyUSB*")) + sorted(glob.glob("/dev/ttyACM*"))


def _close_serial_locked():
    global serial_handle, serial_connected, serial_port_name
    try:
        if serial_handle is not None:
            try:
                if serial_handle.is_open:
                    serial_handle.close()
            except Exception:
                pass
    finally:
        serial_handle = None
        serial_connected = False
        serial_port_name = None


def pause_serial_for_flash(timeout_sec: float = 3.0):
    serial_pause_event.set()
    serial_released_event.clear()
    with serial_lock:
        _serial_push("Pausando (flash em andamento) - fechando porta...", "SYS")
        _close_serial_locked()
        serial_released_event.set()

    if not serial_released_event.wait(timeout=timeout_sec):
        _log_flash("AVISO: timeout esperando liberação da porta serial.")


def resume_serial_after_flash():
    with serial_lock:
        _serial_push("Retomando após flash - re-scan...", "SYS")
    serial_pause_event.clear()


def serial_worker():
    global serial_handle, serial_connected, serial_port_name, serial_last_error

    while not serial_stop_event.is_set():
        if serial_pause_event.is_set():
            with serial_lock:
                _close_serial_locked()
            serial_released_event.set()
            time.sleep(0.25)
            continue

        if serial_handle is None:
            ports = scan_ports()
            opened = False
            last_err = ""
            for p in ports:
                if serial_pause_event.is_set() or serial_stop_event.is_set():
                    break
                try:
                    h = serial.Serial(port=p, baudrate=SERIAL_BAUD, timeout=0.2)
                    with serial_lock:
                        serial_handle = h
                        serial_port_name = p
                        serial_connected = True
                        serial_last_error = ""
                        _serial_push(f"Conectado em {p} @ {SERIAL_BAUD}", "SYS")
                    opened = True
                    break
                except Exception as e:
                    last_err = str(e)

            if not opened:
                with serial_lock:
                    serial_connected = False
                    serial_port_name = None
                    serial_last_error = last_err
                time.sleep(SERIAL_SCAN_INTERVAL)
                continue

        try:
            data = serial_handle.read(4096)
            if data:
                txt = data.decode("utf-8", errors="replace")
                for line in txt.replace("\r", "\n").split("\n"):
                    line = line.strip("\n")
                    if line:
                        with serial_lock:
                            _serial_push(line, "RX")
            else:
                time.sleep(0.05)
        except Exception as e:
            with serial_lock:
                serial_last_error = str(e)
                _serial_push(f"Erro leitura: {e}", "SYS")
                _close_serial_locked()
            time.sleep(SERIAL_SCAN_INTERVAL)


threading.Thread(target=serial_worker, daemon=True).start()


# ===== esptool helpers =====
def get_esptool_cmd():
    if shutil.which("esptool"):
        return "esptool", "v5"
    if shutil.which("esptool.py"):
        return "esptool.py", "legacy"
    return None, None


def detect_port_via_esptool():
    tool, flavor = get_esptool_cmd()
    if not tool:
        return None

    for p in scan_ports():
        try:
            if flavor == "v5":
                cmd = [tool, "--chip", "auto", "--port", p, "--baud", "115200",
                       "--before", "default-reset", "chip-id"]
            else:
                cmd = [tool, "--chip", "auto", "--port", p, "--baud", "115200",
                       "--before", "default_reset", "chip_id"]

            r = subprocess.run(cmd, capture_output=True, text=True, timeout=12)
            if r.returncode == 0:
                return p
        except Exception:
            continue
    return None


def find_special_bins(bin_paths):
    bl = pt = ba0 = ota = None
    for fp in bin_paths:
        name = Path(fp).name.lower()
        if name == "bootloader.bin":
            bl = fp
        elif name in ("partition-table.bin", "partitions.bin", "partition_table.bin"):
            pt = fp
        elif name in ("boot_app0.bin", "boot-app0.bin"):
            ba0 = fp
        elif name in ("ota_data_initial.bin", "ota-data-initial.bin"):
            ota = fp
    return bl, pt, ba0, ota


def best_app_bin(bin_paths):
    skip = {"bootloader.bin", "partition-table.bin", "partitions.bin",
            "partition_table.bin", "boot_app0.bin", "boot-app0.bin",
            "ota_data_initial.bin", "ota-data-initial.bin"}

    preferred = []
    for fp in bin_paths:
        base = Path(fp).name.lower()
        if base in skip:
            continue
        if base.startswith(("app", "firmware", "factory")) and base.endswith(".bin"):
            preferred.append(fp)
    if preferred:
        return preferred[-1]

    candidates = [fp for fp in bin_paths if Path(fp).name.lower() not in skip]
    if not candidates:
        return None
    candidates.sort(key=lambda p: Path(p).stat().st_size)
    return candidates[-1]


def detect_app_offset_from_csv():
    csvs = sorted(SEARCH_DIR.glob("*.csv"))
    if not csvs:
        return None
    csv = csvs[0]
    try:
        for raw in csv.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 5:
                continue
            name = parts[0].lower()
            off = parts[3]
            if "factory" in name or name == "ota_0":
                if off:
                    return off
    except Exception:
        return None
    return None


def build_esptool_write_cmd(port: str, app_bin: str,
                           bootloader=None, part_table=None, boot_app0=None, ota_data=None,
                           app_offset="0x10000"):
    tool, flavor = get_esptool_cmd()
    if not tool:
        raise RuntimeError("esptool não encontrado")

    if flavor == "v5":
        cmd = [
            tool, "--chip", "auto",
            "--port", port,
            "--baud", str(ESP32_BAUD),
            "--before", "default-reset",
            "--after", "hard-reset",
            "write-flash", "-z",
            "--flash-mode", FLASH_MODE,
            "--flash-freq", FLASH_FREQ,
            "--flash-size", FLASH_SIZE,
        ]
    else:
        cmd = [
            tool, "--chip", "auto",
            "--port", port,
            "--baud", str(ESP32_BAUD),
            "--before", "default_reset",
            "--after", "hard_reset",
            "write_flash", "-z",
            "--flash_mode", FLASH_MODE,
            "--flash_freq", FLASH_FREQ,
            "--flash_size", FLASH_SIZE,
        ]

    if bootloader:
        cmd += ["0x1000", bootloader]
    if part_table:
        cmd += ["0x8000", part_table]
    if boot_app0:
        cmd += ["0xE000", boot_app0]
    if ota_data:
        cmd += ["0xD000", ota_data]

    cmd += [app_offset, app_bin]
    return cmd


def build_esptool_readmac_cmd(port: str):
    tool, flavor = get_esptool_cmd()
    if not tool:
        return None
    if flavor == "v5":
        return [tool, "--chip", "auto", "--port", port, "--baud", "115200", "read-mac"]
    return [tool, "--chip", "auto", "--port", port, "--baud", "115200", "read_mac"]


def _pump_process_live(cmd):
    _log_flash("Comando: " + " ".join(cmd))
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)

    buff = ""
    while True:
        ch = proc.stdout.read(1)
        if ch == "" and proc.poll() is not None:
            break
        if not ch:
            time.sleep(0.01)
            continue

        if ch == "\r" or ch == "\n":
            line = buff.strip()
            if line:
                _log_flash(line)
            buff = ""
            continue

        buff += ch
        if len(buff) > 8000:
            _log_flash(buff[:8000])
            buff = buff[8000:]

    last = buff.strip()
    if last:
        _log_flash(last)

    return proc.wait()


def flash_worker(bin_paths):
    global flash_running, flash_started_at, flash_finished_at, flash_port, flash_last_error, flash_returncode

    with flash_state_lock:
        flash_running = True
        flash_started_at = time.time()
        flash_finished_at = 0.0
        flash_port = None
        flash_last_error = ""
        flash_returncode = None
        flash_last_lines.clear()

    try:
        pause_serial_for_flash(timeout_sec=3.0)
        time.sleep(0.5)

        _log_flash("")
        _log_flash(f"========== FLASH VIA WEB {time.strftime('%Y-%m-%d %H:%M:%S')} ==========")
        _log_flash("Selecionados:\n" + "\n".join(bin_paths))

        port = detect_port_via_esptool()
        if not port:
            _log_flash("ERRO: Nenhuma porta ttyUSB/ttyACM respondeu ao esptool.")
            with flash_state_lock:
                flash_last_error = "Nenhuma porta respondeu ao esptool."
                flash_returncode = 3
            return

        with flash_state_lock:
            flash_port = port

        _log_flash(f"Porta detectada: {port}")

        bootloader, part_table, boot_app0, ota_data = find_special_bins(bin_paths)
        app_bin = best_app_bin(bin_paths)
        if not app_bin:
            _log_flash("ERRO: Não foi possível determinar o binário principal (APP).")
            with flash_state_lock:
                flash_last_error = "Não foi possível determinar APP bin."
                flash_returncode = 4
            return

        _log_flash(f"App bin: {app_bin}")

        app_offset = detect_app_offset_from_csv() or "0x10000"
        _log_flash(f"Offset APP: {app_offset}")

        cmd = build_esptool_write_cmd(
            port=port,
            app_bin=app_bin,
            bootloader=bootloader,
            part_table=part_table,
            boot_app0=boot_app0,
            ota_data=ota_data,
            app_offset=app_offset,
        )

        _log_flash(f"Executando flash baud={ESP32_BAUD} ...")
        rc = _pump_process_live(cmd)
        _log_flash(f"Exit code: {rc}")

        with flash_state_lock:
            flash_returncode = rc

        try:
            rm_cmd = build_esptool_readmac_cmd(port)
            if rm_cmd:
                _log_flash("MAC:")
                _pump_process_live(rm_cmd)
        except Exception:
            pass

    except Exception as e:
        _log_flash(f"ERRO EXCEÇÃO: {e}")
        with flash_state_lock:
            flash_last_error = str(e)
            flash_returncode = 99

    finally:
        resume_serial_after_flash()
        with flash_state_lock:
            flash_running = False
            flash_finished_at = time.time()


# ===== Routes =====
@APP.get("/")
def index():
    bins = list_bins()
    log_tail = tail_file(FLASH_LOG, 250)
    return render_template_string(HTML_INDEX, bins=bins, log_tail=log_tail, search_dir=str(SEARCH_DIR))


@APP.get("/serial/status")
def serial_status():
    with serial_lock:
        return jsonify({
            "paused": serial_pause_event.is_set(),
            "connected": serial_connected,
            "port": serial_port_name,
            "baud": SERIAL_BAUD,
            "last_error": serial_last_error,
            "lines": len(serial_lines),
        })


@APP.get("/serial/tail")
def serial_tail():
    try:
        n = int(request.args.get("lines", "1200"))
        n = max(50, min(5000, n))
    except Exception:
        n = 1200

    with serial_lock:
        return "\n".join(list(serial_lines)[-n:])


# ✅ NOVO: tail do serial do arquivo
@APP.get("/serial/log/tail")
def serial_log_tail():
    try:
        n = int(request.args.get("lines", "600"))
        n = max(50, min(5000, n))
    except Exception:
        n = 600
    return tail_file(SERIAL_LOG, n)


@APP.get("/log/status")
def log_status():
    with flash_state_lock:
        return jsonify({
            "running": flash_running,
            "port": flash_port,
            "returncode": flash_returncode,
        })


@APP.get("/log/tail")
def log_tail_live():
    try:
        n = int(request.args.get("lines", "300"))
        n = max(50, min(5000, n))
    except Exception:
        n = 300
    return tail_file(FLASH_LOG, n)


@APP.post("/clear_serial")
def clear_serial():
    with serial_lock:
        serial_lines.clear()
        # serial_last_error é global; preserva padrão do teu código
        global serial_last_error
        serial_last_error = ""

    # limpa arquivo também
    try:
        SERIAL_LOG.parent.mkdir(parents=True, exist_ok=True)
        SERIAL_LOG.write_text("", encoding="utf-8")
    except Exception:
        pass

    flash("✓ Serial monitor limpo (RAM + arquivo).", "success")
    return redirect(url_for("index"))


@APP.post("/clear_logs")
def clear_logs():
    try:
        FLASH_LOG.parent.mkdir(parents=True, exist_ok=True)
        FLASH_LOG.write_text("", encoding="utf-8")
    except Exception as e:
        flash(f"Falha ao limpar log: {e}", "danger")
        return redirect(url_for("index"))

    with flash_state_lock:
        flash_last_lines.clear()

    flash("✓ Log do flash limpo.", "success")
    return redirect(url_for("index"))


@APP.post("/clear_all")
def clear_all():
    with serial_lock:
        serial_lines.clear()
        global serial_last_error
        serial_last_error = ""

    try:
        FLASH_LOG.parent.mkdir(parents=True, exist_ok=True)
        FLASH_LOG.write_text("", encoding="utf-8")
    except Exception as e:
        flash(f"Falha ao limpar log: {e}", "danger")
        return redirect(url_for("index"))

    try:
        SERIAL_LOG.parent.mkdir(parents=True, exist_ok=True)
        SERIAL_LOG.write_text("", encoding="utf-8")
    except Exception:
        pass

    with flash_state_lock:
        flash_last_lines.clear()

    flash("✓ Log + serial limpos (RAM + arquivos).", "success")
    return redirect(url_for("index"))


@APP.post("/upload")
def upload():
    file = request.files.get("binfile")
    if not file or file.filename.strip() == "":
        flash("Selecione um arquivo .bin para enviar.", "warning")
        return redirect(url_for("index"))

    filename = os.path.basename(file.filename)
    if not filename.lower().endswith(".bin"):
        flash("Somente arquivos .bin são permitidos.", "danger")
        return redirect(url_for("index"))

    try:
        SEARCH_DIR.mkdir(parents=True, exist_ok=True)
    except Exception as e:
        flash(f"Não foi possível criar pasta {SEARCH_DIR}: {e}", "danger")
        return redirect(url_for("index"))

    dest = SEARCH_DIR / filename
    if not safe_under_root(dest):
        flash("Caminho inválido.", "danger")
        return redirect(url_for("index"))

    try:
        file.save(dest)
        flash(f"Upload concluído: {dest}", "success")
    except Exception as e:
        flash(f"Falha no upload: {e}", "danger")

    return redirect(url_for("index"))


@APP.post("/delete")
def delete_bins():
    selected = request.form.getlist("bins")
    if not selected:
        flash("Marque pelo menos um .bin para excluir.", "warning")
        return redirect(url_for("index"))

    deleted = 0
    errors = 0

    for name in selected:
        p = (SEARCH_DIR / os.path.basename(name))
        if p.suffix.lower() != ".bin":
            continue
        if not safe_under_root(p):
            errors += 1
            continue
        try:
            if p.exists():
                p.unlink()
                deleted += 1
        except Exception:
            errors += 1

    if deleted:
        flash(f"✓ Excluídos: {deleted} arquivo(s).", "success")
    if errors:
        flash(f"⚠ Falhas ao excluir: {errors} arquivo(s).", "warning")

    return redirect(url_for("index"))


@APP.post("/flash")
def flash_bins():
    tool, _ = get_esptool_cmd()
    if not tool:
        flash("esptool/esptool.py não encontrado no PATH. Faça: pip install esptool", "danger")
        return redirect(url_for("index"))

    selected = request.form.getlist("bins")
    if not selected:
        flash("Marque pelo menos um .bin para atualizar.", "warning")
        return redirect(url_for("index"))

    if not flash_lock.acquire(blocking=False):
        flash("Já existe um flash em andamento. Aguarde.", "warning")
        return redirect(url_for("index"))

    bin_paths = []
    for name in selected:
        p = (SEARCH_DIR / os.path.basename(name))
        if p.suffix.lower() != ".bin":
            continue
        if not p.exists():
            flash(f"Arquivo não existe: {p}", "danger")
            flash_lock.release()
            return redirect(url_for("index"))
        if not safe_under_root(p):
            flash("Arquivo fora do diretório permitido.", "danger")
            flash_lock.release()
            return redirect(url_for("index"))
        bin_paths.append(str(p))

    if not bin_paths:
        flash("Seleção inválida.", "danger")
        flash_lock.release()
        return redirect(url_for("index"))

    threading.Thread(target=_flash_thread_wrapper, args=(bin_paths,), daemon=True).start()
    flash("Flash iniciado. Veja o log do arquivo em tempo real.", "info")
    return redirect(url_for("index"))


def _flash_thread_wrapper(bin_paths):
    try:
        flash_worker(bin_paths)
    finally:
        try:
            flash_lock.release()
        except Exception:
            pass


@APP.post("/reboot")
def reboot_esp32():
    tool, flavor = get_esptool_cmd()
    if not tool:
        flash("esptool/esptool.py não encontrado no PATH. Faça: pip install esptool", "danger")
        return redirect(url_for("index"))

    if flash_lock.locked():
        flash("Flash em andamento. Aguarde para reiniciar.", "warning")
        return redirect(url_for("index"))

    pause_serial_for_flash(timeout_sec=3.0)
    time.sleep(0.2)

    try:
        port = detect_port_via_esptool()
        if not port:
            flash("Não foi possível detectar a porta do ESP32 para reiniciar.", "danger")
            return redirect(url_for("index"))

        if flavor == "v5":
            cmd = [tool, "--chip", "auto", "--port", port, "--baud", "115200",
                   "--before", "default-reset", "--after", "hard-reset", "chip-id"]
        else:
            cmd = [tool, "--chip", "auto", "--port", port, "--baud", "115200",
                   "--before", "default_reset", "--after", "hard_reset", "chip_id"]

        _log_flash(f"Reboot solicitado via web na porta {port}...")
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=12)

        if r.returncode == 0:
            flash(f"✓ ESP32 reiniciado (porta {port}).", "success")
            _log_flash("Reboot OK.")
        else:
            err = (r.stdout or "") + "\n" + (r.stderr or "")
            flash("Falha ao reiniciar via esptool. Veja o log.", "danger")
            _log_flash("Reboot FALHOU:")
            _log_flash(err.strip()[:3000])

    except Exception as e:
        flash(f"Erro ao reiniciar: {e}", "danger")
        _log_flash(f"ERRO reboot: {e}")

    finally:
        resume_serial_after_flash()

    return redirect(url_for("index"))


@APP.get("/log")
def log_view():
    safe = tail_file(FLASH_LOG, 2000).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return f"<pre style='white-space:pre-wrap'>{safe}</pre>"


# ✅ NOVO: página “log completo serial” (mostra tail grande por padrão, sem travar)
@APP.get("/serial/log")
def serial_log_view():
    safe = tail_file(SERIAL_LOG, 3000).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return f"<pre style='white-space:pre-wrap'>{safe}</pre>"


if __name__ == "__main__":
    APP.run(host="0.0.0.0", port=5004, debug=False)

EOF



sudo systemctl restart esp32-webflasher.service


sudo tee /etc/systemd/system/esp32-webflasher.service >/dev/null <<'EOF'
[Unit]
Description=ESP32 Web Flasher (Flask) na porta 5004
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/esp32web
ExecStart=/usr/bin/python3 /opt/esp32web/app.py
Restart=on-failure
RestartSec=3
User=root
Environment=ESP32_SEARCH_DIR=/root
Environment=ESP32_FLASH_SCRIPT=/usr/local/bin/esp32-flash-bins.sh
Environment=ESP32_FLASH_LOG=/root/esp32_flash_log.txt
Environment=ESP32_MAX_UPLOAD_MB=200
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF



sudo systemctl daemon-reload
sudo systemctl enable --now esp32-webflasher.service
sudo systemctl status esp32-webflasher.service --no-pager


























