tee /etc/udev/rules.d/99-android-autoinstall.rules >/dev/null <<'EOF'
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0666", RUN+="/usr/local/bin/android-auto-installer.sh"
EOF

apt update
apt install -y python3 python3-pip android-tools-adb adb
pip3 install flask



tee /usr/local/bin/android_installer_web.py >/dev/null <<'PY'
#!/usr/bin/env python3
import os
import re
import time
import subprocess
import threading
from datetime import datetime
from flask import Flask, request, jsonify, Response

APP_PORT = 5003
APK_DIR = "/root"
INSTALL_LOG = "/root/install_log.txt"

# Upload
MAX_UPLOAD_MB = 300
ALLOWED_EXT = {".apk"}

# Instalação via ADB (sem script externo)
REMOTE_PATH = "/data/local/tmp"
ADB_INSTALL_FLAGS = ["-r", "-d", "-g"]  # reinstall, allow downgrade, grant runtime perms
SLEEP_BETWEEN = 2

# Pacotes para desinstalar SEM CHECAR antes do install (e em caso de conflito)
FORCE_UNINSTALL_PACKAGES = ["com.vendcard1"]

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_MB * 1024 * 1024

install_lock = threading.Lock()
install_running_flag = False

uninstall_lock = threading.Lock()


def ts():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def log_line(msg: str):
    try:
        with open(INSTALL_LOG, "a", encoding="utf-8") as f:
            f.write(f"[{ts()}] {msg}\n")
    except Exception:
        pass


def run(cmd, timeout=12):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, text=True)
        return p.returncode, (p.stdout or "").strip()
    except Exception as e:
        return 99, str(e)


def adb_devices_raw():
    _, out = run(["adb", "devices"], timeout=6)
    return out


def parse_device_state(adb_out: str):
    lines = [l.strip() for l in adb_out.splitlines() if l.strip()]
    dev_lines = [l for l in lines[1:] if "\t" in l]
    if not dev_lines:
        return {"connected": False, "state": "none", "serial": None, "raw": adb_out}
    serial, state = dev_lines[0].split("\t", 1)
    state = state.strip()
    return {"connected": state == "device", "state": state, "serial": serial, "raw": adb_out}


def adb_cmd(args, serial=None, timeout=60):
    base = ["adb"]
    if serial:
        base += ["-s", serial]
    base += args
    return run(base, timeout=timeout)


def adb_shell(args, serial=None, timeout=30):
    return adb_cmd(["shell"] + args, serial=serial, timeout=timeout)


def get_device_info():
    adb_out = adb_devices_raw()
    d = parse_device_state(adb_out)

    if not d["serial"]:
        return {**d, "info": {}}

    serial = d["serial"]
    info = {}

    if d["state"] == "device":
        _, model = adb_shell(["getprop", "ro.product.model"], serial=serial)
        _, brand = adb_shell(["getprop", "ro.product.brand"], serial=serial)
        _, manuf = adb_shell(["getprop", "ro.product.manufacturer"], serial=serial)
        _, android = adb_shell(["getprop", "ro.build.version.release"], serial=serial)
        _, sdk = adb_shell(["getprop", "ro.build.version.sdk"], serial=serial)

        _, iproute = adb_shell(["ip", "route", "get", "1.1.1.1"], serial=serial)
        ip_match = re.search(r"\bsrc\s+(\d+\.\d+\.\d+\.\d+)\b", iproute or "")
        ip = ip_match.group(1) if ip_match else ""

        _, batt = adb_shell(["dumpsys", "battery"], serial=serial)
        batt_lines = []
        for k in ["level", "status", "AC powered", "USB powered", "Wireless powered"]:
            m = re.search(rf"^{re.escape(k)}:\s*(.*)$", batt, re.MULTILINE)
            if m:
                batt_lines.append(f"{k}: {m.group(1).strip()}")
        batt_str = " | ".join(batt_lines)

        info = {
            "model": model,
            "brand": brand,
            "manufacturer": manuf,
            "android": android,
            "sdk": sdk,
            "ip": ip.strip(),
            "battery": batt_str.strip(),
        }

    return {**d, "info": info}


def list_apks():
    files = []
    try:
        for name in sorted(os.listdir(APK_DIR)):
            p = os.path.join(APK_DIR, name)
            if os.path.isfile(p) and name.lower().endswith(".apk"):
                files.append({"name": name, "path": p, "size": os.path.getsize(p)})
    except Exception:
        pass
    return files


def uninstall_no_check(serial: str, pkg: str):
    if not pkg:
        return
    log_line(f"Forçando desinstalação (sem checar) de: {pkg}")
    for cmd in [
        ["shell", "pm", "uninstall", pkg],
        ["shell", "pm", "uninstall", "--user", "0", pkg],
        ["shell", "cmd", "package", "uninstall", "-k", "--user", "0", pkg],
    ]:
        rc, out = adb_cmd(cmd, serial=serial, timeout=30)
        if out:
            log_line(out)


def init_log_header():
    try:
        with open(INSTALL_LOG, "w", encoding="utf-8") as f:
            f.write(f"========== LOG DE INSTALAÇÃO - {ts()} ==========\n")
    except Exception:
        pass


def start_install(apk_paths, do_reboot: bool):
    global install_running_flag

    apk_paths = [
        p for p in apk_paths
        if p.startswith(APK_DIR + "/") and p.lower().endswith(".apk") and os.path.isfile(p)
    ]
    if not apk_paths:
        return False, "Nenhum APK válido selecionado."

    if not install_lock.acquire(blocking=False):
        return False, "Já existe uma instalação em andamento."

    def _runner():
        global install_running_flag
        try:
            install_running_flag = True
            init_log_header()

            adb_cmd(["start-server"], timeout=10)

            adb_out = adb_devices_raw()
            d = parse_device_state(adb_out)

            if d["state"] == "unauthorized":
                log_line("ERRO: Dispositivo não autorizado. Aceite a permissão de depuração USB no Android.")
                log_line(adb_out)
                return

            if d["state"] != "device" or not d["serial"]:
                log_line(f"ERRO: Nenhum dispositivo pronto. Estado: {d['state']}")
                log_line(adb_out)
                return

            serial = d["serial"]
            log_line(f"Conectado ao dispositivo: {serial}")
            log_line(f"Reboot após instalar: {'SIM' if do_reboot else 'NÃO'}")
            log_line("------------------------------------------")

            for pkg in FORCE_UNINSTALL_PACKAGES:
                uninstall_no_check(serial, pkg)

            failed = []
            success = []

            def is_success(txt): return "success" in (txt or "").lower()
            def is_failure(txt): return "failure" in (txt or "").lower()
            def is_incompatible(txt): return "install_failed_update_incompatible" in (txt or "").lower()

            for apk in apk_paths:
                base = os.path.basename(apk)
                remote = f"{REMOTE_PATH}/{base}"

                log_line(f"Enviando {base} para o dispositivo...")
                rc, out = adb_cmd(["push", "-p", apk, remote], serial=serial, timeout=180)
                if out:
                    log_line(out)
                if rc != 0:
                    log_line(f"✗ Falha no push de {base}.")
                    failed.append(f"{apk} (push falhou)")
                    continue
                log_line("→ Upload concluído.")

                log_line(f"Instalando {base}...")
                rc, install_out = adb_shell(["pm", "install"] + ADB_INSTALL_FLAGS + [remote], serial=serial, timeout=300)
                if install_out:
                    log_line(install_out)

                if is_failure(install_out):
                    if is_incompatible(install_out):
                        log_line("⚠️ Conflito de assinatura (UPDATE_INCOMPATIBLE). Tentando desinstalar e reinstalar...")

                        for pkg in FORCE_UNINSTALL_PACKAGES:
                            uninstall_no_check(serial, pkg)

                        log_line(f"→ Reinstalando {base}...")
                        rc2, reinstall_out = adb_shell(["pm", "install"] + ADB_INSTALL_FLAGS + [remote], serial=serial, timeout=300)
                        if reinstall_out:
                            log_line(reinstall_out)

                        if is_success(reinstall_out):
                            log_line(f"✓ Reinstalação bem-sucedida: {base}")
                            success.append(apk)
                            adb_shell(["rm", "-f", remote], serial=serial, timeout=30)
                        else:
                            log_line(f"✗ Falha após tentativa de desinstalação: {reinstall_out or 'erro desconhecido'}")
                            failed.append(f"{apk} (reinstall fail)")
                    else:
                        log_line(f"✗ Falha ao instalar {base}: {install_out or 'Failure'}")
                        failed.append(f"{apk} (install fail)")

                elif is_success(install_out):
                    log_line(f"✓ Instalado com sucesso: {base}")
                    success.append(apk)
                    adb_shell(["rm", "-f", remote], serial=serial, timeout=30)
                else:
                    log_line("⚠️ Saída inesperada ao instalar:")
                    log_line(install_out or "<vazio>")
                    failed.append(f"{apk} (unknown result)")

                time.sleep(SLEEP_BETWEEN)

            log_line("")
            log_line("=========== RESUMO ===========")
            log_line(f"Sucesso: {len(success)}")
            for s in success:
                log_line(f"  - {s}")
            log_line(f"Falhas: {len(failed)}")
            for f in failed:
                log_line(f"  - {f}")
            log_line("==============================")

            if len(failed) == 0 and len(success) > 0:
                if do_reboot:
                    log_line("✅ Todas as instalações ok. Reiniciando dispositivo (checkbox marcado)...")
                    adb_cmd(["reboot"], serial=serial, timeout=30)
                else:
                    log_line("✅ Todas as instalações ok. Reboot NÃO solicitado (checkbox desmarcado).")
            elif len(failed) == 0 and len(success) == 0:
                log_line("⚠️ Nenhum APK foi instalado. Reboot cancelado.")
            else:
                log_line("⚠️ Instalações concluídas com erros. Reboot cancelado.")

            log_line(f"Log completo salvo em: {INSTALL_LOG}")

        finally:
            install_running_flag = False
            install_lock.release()

    threading.Thread(target=_runner, daemon=True).start()
    return True, "Instalação iniciada (processo interno Python)."


def install_status():
    return {"running": install_lock.locked(), "returncode": None}


def start_uninstall(packages):
    packages = [p.strip() for p in packages if p and p.strip()]
    valid = []
    for p in packages:
        if re.fullmatch(r"[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)+", p):
            valid.append(p)

    if not valid:
        return False, "Nenhum packageName válido informado (ex: com.vendcard1)."

    if not uninstall_lock.acquire(blocking=False):
        return False, "Já existe uma desinstalação em andamento."

    def _runner():
        try:
            log_line("=== DESINSTALAÇÃO INICIADA ===")
            adb_cmd(["start-server"], timeout=10)

            adb_out = adb_devices_raw()
            d = parse_device_state(adb_out)
            if d["state"] != "device":
                log_line(f"ERRO: dispositivo não está pronto (estado={d['state']}).")
                log_line(adb_out)
                return

            serial = d["serial"]
            for pkg in valid:
                uninstall_no_check(serial, pkg)
            log_line("=== DESINSTALAÇÃO FINALIZADA ===")
        finally:
            uninstall_lock.release()

    threading.Thread(target=_runner, daemon=True).start()
    return True, f"Desinstalação iniciada ({len(valid)} pacote(s))."


def uninstall_status():
    return {"running": uninstall_lock.locked()}


def tail_log(max_bytes=160_000):
    if not os.path.exists(INSTALL_LOG):
        return "Sem log ainda. (Arquivo /root/install_log.txt não existe)\n"
    try:
        size = os.path.getsize(INSTALL_LOG)
        with open(INSTALL_LOG, "rb") as f:
            if size > max_bytes:
                f.seek(-max_bytes, os.SEEK_END)
            data = f.read().decode("utf-8", errors="replace")
        return data
    except Exception as e:
        return f"Erro ao ler log: {e}\n"


def safe_filename(name: str):
    name = os.path.basename(name or "")
    name = re.sub(r"[^a-zA-Z0-9._-]+", "_", name).strip("_")
    if not name:
        name = f"upload_{int(datetime.now().timestamp())}.apk"
    return name


@app.get("/")
def index():
    return Response(f"""<!doctype html>
<html lang="pt-br">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>Android Auto Installer</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
  <style>
    body {{ background:#0b0f14; color:#e6edf3; }}
    .card {{ background:#111827; border:1px solid #1f2937; }}
    .muted {{ color:#9ca3af; }}

    h3, h5, .card h5 {{
      color: #f3f4f6 !important;
      font-weight: 700;
    }}

    label, .card label {{
      color: #e5e7eb !important;
    }}

    .logbox {{
      background:#0b1220;
      border:1px solid #1f2937;
      padding:12px;
      height:340px;
      overflow:auto;
      white-space:pre-wrap;
      color:#e5e7eb !important;
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono";
      font-size: 0.9rem;
      line-height: 1.25rem;
    }}

    .btn-big {{ font-size:1.25rem; padding:18px 26px; }}
    .apk-row:hover {{ background:#0f172a; }}
    .divider {{ border-top:1px solid #334155; margin: 12px 0; }}
  </style>
</head>
<body class="py-4">
<div class="container">
  <div class="d-flex align-items-center justify-content-between mb-3">
    <div>
      <h3 class="mb-0">Android Auto Installer</h3>
      <div class="muted">Porta {APP_PORT} • APKs em {APK_DIR}</div>
    </div>
    <button id="btnRefresh" class="btn btn-outline-light">Atualizar</button>
  </div>

  <div class="row g-3">
    <div class="col-lg-5">
      <div class="card p-3">
        <h5 class="mb-2">Status do dispositivo</h5>
        <div id="devStatus" class="mb-2 muted">Carregando...</div>
        <div class="small">
          <div><span class="muted">Serial:</span> <span id="devSerial">-</span></div>
          <div><span class="muted">Modelo:</span> <span id="devModel">-</span></div>
          <div><span class="muted">Marca/Fab:</span> <span id="devBrand">-</span></div>
          <div><span class="muted">Android:</span> <span id="devAndroid">-</span></div>
          <div><span class="muted">IP:</span> <span id="devIp">-</span></div>
          <div><span class="muted">Bateria:</span> <span id="devBatt">-</span></div>
        </div>

        <div class="divider"></div>

        <h5 class="mb-2">Ação</h5>
        <button id="btnInstall" class="btn btn-success w-100 btn-big">INSTALAR</button>

        <div class="form-check mt-2">
          <input class="form-check-input" type="checkbox" value="" id="rebootChk" checked>
          <label class="form-check-label" for="rebootChk">Reiniciar após instalar</label>
        </div>

        <button id="btnUninstall" class="btn btn-danger w-100 btn-big mt-2">DESINSTALAR</button>

        <div class="mt-2">
          <label class="muted small mb-1">Pacotes para desinstalar (separar por vírgula ou linha):</label>
          <textarea id="pkgBox" class="form-control" rows="3"
            placeholder="com.vendcard1&#10;com.exemplo.app">com.vendcard1</textarea>
          <div class="muted small mt-1">Dica: isso chama pm uninstall / cmd package uninstall e registra no log.</div>
        </div>

        <div id="installHint" class="muted mt-2 small"></div>

        <div class="divider"></div>

        <h5 class="mb-2">Enviar APK para {APK_DIR}</h5>
        <div class="input-group">
          <input type="file" id="fileUp" class="form-control" accept=".apk">
          <button id="btnUpload" class="btn btn-primary">ENVIAR</button>
        </div>
        <div id="uploadHint" class="muted small mt-2"></div>
      </div>
    </div>

    <div class="col-lg-7">
      <div class="card p-3">
        <h5 class="mb-2">APKs em {APK_DIR}</h5>
        <div class="d-flex gap-2 mb-2">
          <button class="btn btn-outline-light btn-sm" id="btnSelectAll">Marcar todos</button>
          <button class="btn btn-outline-light btn-sm" id="btnSelectNone">Desmarcar</button>
        </div>
        <div id="apkList" class="border border-secondary rounded" style="max-height:280px; overflow:auto;"></div>

        <div class="divider"></div>

        <h5 class="mb-2">Log de instalação</h5>
        <div class="logbox" id="logBox">Carregando log...</div>
      </div>
    </div>
  </div>
</div>

<script>
async function jget(url) {{
  const r = await fetch(url, {{cache:"no-store"}});
  return await r.json();
}}

function bytesToSize(bytes) {{
  const units = ["B","KB","MB","GB"];
  let i = 0;
  let v = bytes;
  while (v >= 1024 && i < units.length-1) {{ v/=1024; i++; }}
  return v.toFixed(i===0?0:1) + " " + units[i];
}}

function renderApks(apks) {{
  const box = document.getElementById("apkList");
  if (!apks.length) {{
    box.innerHTML = '<div class="p-3 muted">Nenhum .apk encontrado.</div>';
    return;
  }}
  box.innerHTML = apks.map((a, idx) => `
    <label class="d-flex align-items-center gap-2 p-2 apk-row" style="cursor:pointer;">
      <input class="form-check-input apk-check" type="checkbox" data-path="${{a.path}}" ${{idx===0?'checked':''}}>
      <div class="flex-grow-1">
        <div>${{a.name}}</div>
        <div class="muted small">${{bytesToSize(a.size)}}</div>
      </div>
    </label>
  `).join("");
}}

function selectedApks() {{
  return Array.from(document.querySelectorAll(".apk-check:checked"))
    .map(x => x.getAttribute("data-path"));
}}

async function refreshAll() {{
  const status = await jget("/api/status");
  const apks = await jget("/api/apks");
  const inst = await jget("/api/install_status");
  const uninst = await jget("/api/uninstall_status");
  const log = await fetch("/api/log", {{cache:"no-store"}}).then(r=>r.text());

  const s = status.state;
  let badge = "";
  if (s === "device") badge = '<span class="badge bg-success">CONECTADO</span>';
  else if (s === "unauthorized") badge = '<span class="badge bg-warning text-dark">UNAUTHORIZED</span>';
  else if (s === "offline") badge = '<span class="badge bg-danger">OFFLINE</span>';
  else badge = '<span class="badge bg-secondary">NENHUM</span>';

  document.getElementById("devStatus").innerHTML = badge + ' <span class="muted ms-2">estado:</span> ' + s;
  document.getElementById("devSerial").textContent = status.serial || "-";
  document.getElementById("devModel").textContent = status.info.model || "-";
  document.getElementById("devBrand").textContent = (status.info.brand || "-") + " / " + (status.info.manufacturer || "-");
  document.getElementById("devAndroid").textContent = (status.info.android || "-") + " (SDK " + (status.info.sdk || "-") + ")";
  document.getElementById("devIp").textContent = status.info.ip || "-";
  document.getElementById("devBatt").textContent = status.info.battery || "-";

  renderApks(apks);

  const btnI = document.getElementById("btnInstall");
  const btnU = document.getElementById("btnUninstall");
  const hint = document.getElementById("installHint");

  if (inst.running) {{
    btnI.disabled = true;
    btnI.textContent = "INSTALANDO...";
    hint.textContent = "Instalação em andamento. Acompanhe o log.";
  }} else {{
    btnI.disabled = false;
    btnI.textContent = "INSTALAR";
    hint.textContent = "";
  }}

  if (uninst.running) {{
    btnU.disabled = true;
    btnU.textContent = "DESINSTALANDO...";
  }} else {{
    btnU.disabled = false;
    btnU.textContent = "DESINSTALAR";
  }}

  const logBox = document.getElementById("logBox");
  logBox.textContent = log;
  logBox.scrollTop = logBox.scrollHeight;
}}

async function installSelected() {{
  const paths = selectedApks();
  if (!paths.length) {{
    alert("Selecione ao menos 1 APK.");
    return;
  }}
  const reboot = document.getElementById("rebootChk").checked;

  const r = await fetch("/api/install", {{
    method: "POST",
    headers: {{ "Content-Type":"application/json" }},
    body: JSON.stringify({{ apks: paths, reboot: reboot }})
  }});
  const j = await r.json();
  if (!j.ok) alert(j.error || "Falha ao iniciar.");
  await refreshAll();
}}

async function uninstallPackages() {{
  const raw = document.getElementById("pkgBox").value || "";
  const pkgs = raw.split(/[,\\n\\r\\t ]+/).filter(Boolean);
  if (!pkgs.length) {{
    alert("Informe pelo menos 1 packageName (ex: com.vendcard1).");
    return;
  }}
  const r = await fetch("/api/uninstall", {{
    method: "POST",
    headers: {{ "Content-Type":"application/json" }},
    body: JSON.stringify({{ packages: pkgs }})
  }});
  const j = await r.json();
  if (!j.ok) alert(j.error || "Falha ao iniciar desinstalação.");
  await refreshAll();
}}

async function uploadFile() {{
  const inp = document.getElementById("fileUp");
  const hint = document.getElementById("uploadHint");
  if (!inp.files || !inp.files.length) {{
    alert("Selecione um arquivo .apk");
    return;
  }}
  const f = inp.files[0];
  const fd = new FormData();
  fd.append("file", f);

  hint.textContent = "Enviando...";
  const r = await fetch("/api/upload", {{ method:"POST", body: fd }});
  const j = await r.json();
  if (!j.ok) {{
    hint.textContent = "Erro: " + (j.error || "upload falhou");
    return;
  }}
  hint.textContent = "OK: " + j.saved_as;
  inp.value = "";
  await refreshAll();
}}

document.getElementById("btnRefresh").addEventListener("click", refreshAll);
document.getElementById("btnInstall").addEventListener("click", installSelected);
document.getElementById("btnUninstall").addEventListener("click", uninstallPackages);
document.getElementById("btnUpload").addEventListener("click", uploadFile);

document.getElementById("btnSelectAll").addEventListener("click", () => {{
  document.querySelectorAll(".apk-check").forEach(c => c.checked = true);
}});
document.getElementById("btnSelectNone").addEventListener("click", () => {{
  document.querySelectorAll(".apk-check").forEach(c => c.checked = false);
}});

refreshAll();
setInterval(refreshAll, 2500);
</script>
</body>
</html>""", mimetype="text/html")


@app.get("/api/status")
def api_status():
    return jsonify(get_device_info())


@app.get("/api/apks")
def api_apks():
    return jsonify(list_apks())


@app.get("/api/install_status")
def api_install_status():
    return jsonify({"running": install_lock.locked(), "returncode": None})


@app.get("/api/uninstall_status")
def api_uninstall_status():
    return jsonify(uninstall_status())


@app.post("/api/install")
def api_install():
    data = request.get_json(force=True, silent=True) or {}
    apks = data.get("apks", [])
    reboot = bool(data.get("reboot", True))

    if not isinstance(apks, list):
        return jsonify({"ok": False, "error": "Formato inválido."}), 400

    ok, msg = start_install(apks, reboot)
    if not ok:
        return jsonify({"ok": False, "error": msg}), 409
    return jsonify({"ok": True, "message": msg})


@app.post("/api/uninstall")
def api_uninstall():
    data = request.get_json(force=True, silent=True) or {}
    packages = data.get("packages", [])
    if not isinstance(packages, list):
        return jsonify({"ok": False, "error": "Formato inválido."}), 400

    ok, msg = start_uninstall(packages)
    if not ok:
        return jsonify({"ok": False, "error": msg}), 409
    return jsonify({"ok": True, "message": msg})


@app.post("/api/upload")
def api_upload():
    if "file" not in request.files:
        return jsonify({"ok": False, "error": "Campo 'file' não enviado."}), 400

    f = request.files["file"]
    if not f or not f.filename:
        return jsonify({"ok": False, "error": "Arquivo inválido."}), 400

    name = safe_filename(f.filename)
    ext = os.path.splitext(name)[1].lower()
    if ext not in ALLOWED_EXT:
        return jsonify({"ok": False, "error": "Somente .apk é permitido."}), 400

    dest = os.path.join(APK_DIR, name)
    if os.path.exists(dest):
        base, ext = os.path.splitext(name)
        dest = os.path.join(APK_DIR, f"{base}_{int(datetime.now().timestamp())}{ext}")

    try:
        f.save(dest)
        os.chmod(dest, 0o644)
        return jsonify({"ok": True, "saved_as": os.path.basename(dest), "path": dest})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.get("/api/log")
def api_log():
    return Response(tail_log(), mimetype="text/plain; charset=utf-8")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=APP_PORT, debug=False)


PY

chmod +x /usr/local/bin/android_installer_web.py


systemctl restart android-installer-web.service
journalctl -u android-installer-web.service -f



tee /etc/systemd/system/android-installer-web.service >/dev/null <<'EOF'
[Unit]
Description=Android Installer Web UI (Flask)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 /usr/local/bin/android_installer_web.py
Restart=always
RestartSec=3
User=root
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
StandardOutput=append:/var/log/android_installer_web.log
StandardError=append:/var/log/android_installer_web.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable android-installer-web.service
systemctl start android-installer-web.service
journalctl -u android-installer-web.service -f









