
apt install python3-pip
pip install flask pyserial serial --break-system-packages







sudo tee /opt/mirako_web/web_modem.py >/dev/null <<'EOF'
#!/usr/bin/env python3
# coding: utf-8
"""
Web UI do modem 3G/4G para o Mirako:
- Info do modem (ATI, IMEI, operadora, CSQ, CPMS)
- Nível de sinal numérico + barra gráfica
- Leitura de SMS (AUTO: SM + ME) sob demanda
- Seleção e exclusão de SMS
- Envio de SMS (método robusto com prompt '>')
- CNMI (+CMTI) para detectar novos SMS via URC
"""

from __future__ import annotations

import os
import time
import threading
from typing import Tuple, List, Dict, Any

from flask import (
    Flask,
    render_template_string,
    request,
    redirect,
    url_for,
    flash,
    jsonify,
)

try:
    import serial  # pyserial
except ImportError:
    serial = None  # avisamos na interface

app = Flask(__name__)
app.secret_key = os.environ.get("MIRAKO_MODEM_SECRET", "devkey-modem")

# ======================= CONFIG ============================

SERIAL_DEV = os.environ.get("MODEM_TTY", "/dev/ttyUSB1")
BAUDRATE = int(os.environ.get("MODEM_BAUD", "115200"))

VALID_BOXES = [
    "ALL",
    "REC UNREAD",
    "REC READ",
    "STO UNSENT",
    "STO SENT",
]

# memórias base para detecção
BASE_MEMS = ["SM", "ME"]
EXTRA_MEMS = ["SM"]  # sempre tentar SM também

SUPPORTED_MEMS_CACHE: List[str] = []

# memórias exibidas no dropdown (fixo)
MEM_CHOICES = ["AUTO", "SM", "ME"]

# URCs de novos SMS (+CMTI)
NEW_SMS_URC: List[Dict[str, Any]] = []
NEW_SMS_LOCK = threading.Lock()

# Lock global para TODAS as operações na serial (evita concorrência)
SERIAL_LOCK = threading.Lock()

# ======================= SERIAL / AT ========================

def open_port() -> "serial.Serial":
    if serial is None:
        raise RuntimeError("pyserial não está instalado. Use: pip install pyserial")
    return serial.Serial(SERIAL_DEV, BAUDRATE, timeout=1)


def _handle_possible_urc(line: str) -> None:
    """
    Se a linha for um URC +CMTI, guarda info básica.
    Exemplo: +CMTI: "SM",3
    """
    if not line.startswith("+CMTI:"):
        return
    try:
        payload = line.split(":", 1)[1].strip()
        mem, idx = [p.strip() for p in payload.split(",")]
        mem = mem.strip('"')
        idx_int = int(idx)
    except Exception:
        return
    with NEW_SMS_LOCK:
        NEW_SMS_URC.append({"mem": mem, "index": idx_int, "raw": line})


def pop_new_sms_urc() -> List[Dict[str, Any]]:
    """Retorna e limpa a lista de URCs de novos SMS."""
    with NEW_SMS_LOCK:
        data = list(NEW_SMS_URC)
        NEW_SMS_URC.clear()
    return data


def send_at(cmd: str, read_timeout: float = 3.0) -> Tuple[bool, str]:
    """
    Envia um comando AT e lê até encontrar OK/ERROR ou estourar timeout.
    Retorna (ok, resposta_bruta).
    TODA chamada AT passa pelo SERIAL_LOCK.
    """
    if serial is None:
        return False, "pyserial não instalado"

    lines: List[str] = []
    try:
        with SERIAL_LOCK:
            with open_port() as ser:
                ser.reset_input_buffer()
                ser.reset_output_buffer()
                ser.write((cmd.strip() + "\r").encode("utf-8", errors="ignore"))
                ser.flush()

                deadline = time.time() + read_timeout
                while time.time() < deadline:
                    line = ser.readline().decode("utf-8", errors="ignore").strip()
                    if not line:
                        continue

                    # captura URC se for +CMTI
                    _handle_possible_urc(line)

                    lines.append(line)
                    if line in ("OK", "ERROR"):
                        break
    except Exception as e:
        return False, f"erro serial: {e}"

    text = "\n".join(lines)
    ok = any(l == "OK" for l in lines)
    return ok, text


def _wait_ok(ser: "serial.Serial", timeout: float) -> bool:
    """Espera uma resposta que contenha OK ou ERROR (usa ser já aberto e lock já segurado)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        line = ser.readline().decode("utf-8", errors="ignore").strip()
        if not line:
            continue
        _handle_possible_urc(line)
        if line == "OK":
            return True
        if line == "ERROR":
            return False
    return False


def _wait_for_prompt(ser: "serial.Serial", char: str = ">", timeout: float = 10.0) -> bool:
    """Espera até ver o caractere de prompt (ex: '>')."""
    target = char
    buf = ""
    deadline = time.time() + timeout
    while time.time() < deadline:
        ch = ser.read(1).decode("utf-8", errors="ignore")
        if not ch:
            continue
        buf += ch
        if target in buf:
            return True
    return False


def _drain(ser: "serial.Serial", max_wait: float = 1.0) -> None:
    """Lê e descarta dados pendentes por até max_wait segundos."""
    end = time.time() + max_wait
    while time.time() < end:
        if ser.in_waiting:
            _ = ser.read(ser.in_waiting)
        else:
            time.sleep(0.05)

# ======================= PARSERS / MEMÓRIA SUPORTADA =======

def parse_csq(raw: str) -> Dict[str, Any]:
    """
    Parse de AT+CSQ:
    +CSQ: <rssi>,<ber>
    """
    rssi = None
    ber = None
    for ln in raw.splitlines():
        ln = ln.strip()
        if ln.startswith("+CSQ:"):
            try:
                payload = ln.split(":", 1)[1].strip()
                parts = [p.strip() for p in payload.split(",")]
                if len(parts) >= 2:
                    rssi = int(parts[0]) if parts[0].isdigit() else None
                    ber = int(parts[1]) if parts[1].isdigit() else None
            except Exception:
                pass
    d: Dict[str, Any] = {"raw": raw, "rssi": rssi, "ber": ber}
    if rssi is None or rssi < 0 or rssi > 31:
        d["percent"] = None
        d["dbm"] = None
        d["qual"] = "desconhecido"
        return d

    pct = round(rssi * 100.0 / 31.0)
    dbm = -113 + 2 * rssi

    if pct >= 80:
        qual = "Excelente"
    elif pct >= 60:
        qual = "Boa"
    elif pct >= 40:
        qual = "Razoável"
    else:
        qual = "Fraca"

    d["percent"] = pct
    d["dbm"] = dbm
    d["qual"] = qual
    return d


def parse_cpms(raw: str) -> Dict[str, Dict[str, int]]:
    """
    Parse de AT+CPMS?:
    +CPMS: "SM",used1,total1,"ME",used2,total2,...
    Retorna dict com contadores por memória.
    """
    out: Dict[str, Dict[str, int]] = {}

    for ln in raw.splitlines():
        ln = ln.strip()
        if not ln.startswith("+CPMS:"):
            continue
        try:
            payload = ln.split(":", 1)[1].strip()
            parts = [p.strip() for p in payload.split(",")]
            i = 0
            while i + 2 < len(parts):
                mem = parts[i].strip().strip('"')
                used = int(parts[i + 1])
                total = int(parts[i + 2])
                out[mem] = {"used": used, "total": total}
                i += 3
        except Exception:
            continue

    return out


def get_supported_mems() -> List[str]:
    """
    Descobre as memórias de SMS suportadas pelo modem usando AT+CPMS?.
    Cacheia o resultado em SUPPORTED_MEMS_CACHE.
    Garante pelo menos SM e ME.
    """
    global SUPPORTED_MEMS_CACHE
    if SUPPORTED_MEMS_CACHE:
        return SUPPORTED_MEMS_CACHE

    if serial is None:
        SUPPORTED_MEMS_CACHE = BASE_MEMS.copy()
        return SUPPORTED_MEMS_CACHE

    ok, cpms_raw = send_at("AT+CPMS?", read_timeout=3.0)
    mems: List[str] = []
    if ok:
        parsed = parse_cpms(cpms_raw)
        mems = [m for m in parsed.keys() if m]

    # garante SM e ME pelo menos
    for base in BASE_MEMS:
        if base not in mems:
            mems.append(base)
    for extra in EXTRA_MEMS:
        if extra not in mems:
            mems.append(extra)

    if not mems:
        mems = BASE_MEMS.copy()

    SUPPORTED_MEMS_CACHE = mems
    return SUPPORTED_MEMS_CACHE


def parse_sms_list(raw: str) -> List[Dict[str, Any]]:
    """
    Faz parse do resultado de AT+CMGL="...".
    Formato típico:
      +CMGL: <index>,"<stat>","<oa>",,"<scts>"
      <texto...>
    """
    sms_list: List[Dict[str, Any]] = []
    lines = raw.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("+CMGL:"):
            header = line
            i += 1
            text_lines: List[str] = []
            while i < len(lines):
                if lines[i].startswith("+CMGL:") or lines[i].strip() in ("OK", "ERROR"):
                    break
                text_lines.append(lines[i])
                i += 1

            try:
                meta = header.split(":", 1)[1].strip()
                parts = [p.strip() for p in meta.split(",")]

                index = int(parts[0])
                status = parts[1].strip().strip('"') if len(parts) > 1 else ""
                number = parts[2].strip().strip('"') if len(parts) > 2 else ""
                timestamp = ""
                if len(parts) >= 6:
                    ts_date = parts[4].strip().strip('"')
                    ts_time = parts[5].strip().strip('"')
                    timestamp = f"{ts_date} {ts_time}"
            except Exception:
                index = -1
                status = ""
                number = ""
                timestamp = ""

            text = "\n".join(text_lines).strip()
            sms_list.append(
                {
                    "index": index,
                    "status": status,
                    "number": number,
                    "timestamp": timestamp,
                    "text": text,
                }
            )
        else:
            i += 1

    return sms_list

# ======================= SMS (envio + leitura) ==============

def _send_sms_method1(number: str, text: str, read_timeout: float = 60.0) -> Tuple[bool, str]:
    """
    Método principal: robusto, esperando prompt '>'.
    NÃO chama send_at() aqui para não reentrar no lock;
    usa a serial diretamente sob SERIAL_LOCK.
    Tempo maior de espera porque o A7670 pode demorar para devolver +CMGS/OK.
    """
    if serial is None:
        return False, "pyserial não instalado"

    try:
        with SERIAL_LOCK:
            with open_port() as ser:
                ser.reset_input_buffer()
                ser.reset_output_buffer()

                # Teste básico de comunicação
                ser.write(b"AT\r")
                ser.flush()
                if not _wait_ok(ser, 5.0):
                    return False, "Sem resposta a AT (método 1)"

                # Modo texto
                ser.write(b"AT+CMGF=1\r")
                ser.flush()
                if not _wait_ok(ser, 5.0):
                    return False, "Erro em AT+CMGF=1 (método 1)"

                # CPMS já foi configurado em init_sms_settings()
                # Não mexemos em CPMS aqui para não bagunçar o fluxo.

                # Comando CMGS
                cmd = f'AT+CMGS="{number}"\r'
                ser.write(cmd.encode("utf-8", errors="ignore"))
                ser.flush()

                # Espera o prompt '>'
                if not _wait_for_prompt(ser, ">", 20.0):
                    return False, "Não recebi o prompt '>' do CMGS (método 1)"

                # Corpo da mensagem + Ctrl+Z
                ser.write(text.encode("utf-8", errors="ignore") + b"\x1a")
                ser.flush()

                # Ler resposta (pode demorar mesmo)
                lines: List[str] = []
                deadline = time.time() + read_timeout
                while time.time() < deadline:
                    line = ser.readline().decode("utf-8", errors="ignore").strip()
                    if not line:
                        continue
                    _handle_possible_urc(line)
                    lines.append(line)
                    # muitos modems retornam:
                    #   +CMGS: <id>
                    #   OK
                    if line in ("OK", "ERROR"):
                        break

                # drena qualquer resto (+CMGS atrasado, URC, etc)
                _drain(ser, max_wait=0.5)

    except Exception as e:
        return False, f"erro ao enviar SMS (método 1): {e}"

    txt = "\n".join(lines)
    # consideramos sucesso se tiver OK, ou pelo menos um +CMGS
    ok = any(l == "OK" or l.startswith("+CMGS:") for l in lines)
    if not ok and not txt:
        txt = "sem resposta do modem (método 1)"
    return ok, txt


def send_sms(number: str, text: str, read_timeout: float = 60.0) -> Tuple[bool, str]:
    """
    Envia SMS usando apenas o método robusto (prompt '>').
    Removido o fallback para não tentar CMGS novamente enquanto o modem
    ainda está finalizando o envio anterior.
    """
    number = (number or "").strip()
    text = (text or "").strip()

    if serial is None:
        return False, "pyserial não instalado"
    if not number:
        return False, "Número vazio"
    if not text:
        return False, "Mensagem vazia"

    ok, resp = _send_sms_method1(number, text, read_timeout=read_timeout)
    if ok:
        return True, "Enviado pelo método 1 (prompt '>'):\n" + resp

    return False, resp


def _get_sms_single(box: str = "ALL", mem: str = "SM") -> Tuple[bool, str, List[Dict[str, Any]]]:
    """
    Lê SMS apenas de uma memória física (SM, ME).
    Usa send_at(), que já é protegido por SERIAL_LOCK.
    """
    if box not in VALID_BOXES:
        box = "ALL"

    supported = get_supported_mems()
    if mem not in supported:
        if not supported:
            return False, "Nenhuma memória CPMS suportada detectada.", []
        mem = supported[0]

    # seleciona memória
    ok, resp = send_at(f'AT+CPMS="{mem}","{mem}","{mem}"', read_timeout=5.0)
    if not ok or "OK" not in resp:
        return False, f"Erro AT+CPMS em {mem}: {resp}", []

    # modo texto
    ok, resp = send_at("AT+CMGF=1", read_timeout=5.0)
    if not ok or "OK" not in resp:
        return False, f"Erro AT+CMGF=1: {resp}", []

    # lista SMS
    ok, resp = send_at(f'AT+CMGL="{box}"', read_timeout=10.0)
    if not ok and "+CMGL:" not in resp:
        return False, f"Erro AT+CMGL: {resp}", []

    sms_list = parse_sms_list(resp)
    for sms in sms_list:
        sms["mem"] = mem

    return True, "OK", sms_list


def get_sms(box: str = "ALL", mem: str = "SM") -> Tuple[bool, str, List[Dict[str, Any]]]:
    """
    Lê SMS conforme memória:
    - mem != AUTO → lê só aquela memória.
    - mem == AUTO → varre todas as memórias detectadas (SM + ME).
    """
    if mem != "AUTO":
        return _get_sms_single(box, mem)

    supported = get_supported_mems()
    all_sms: List[Dict[str, Any]] = []
    errors: List[str] = []

    for real_mem in supported:
        ok, msg, smsl = _get_sms_single(box, real_mem)
        if ok:
            all_sms.extend(smsl)
        else:
            errors.append(f"{real_mem}: {msg}")

    if not all_sms and errors:
        return False, "Leitura AUTO falhou em todas as memórias: " + " / ".join(errors), []

    all_sms.sort(key=lambda s: (s.get("mem", ""), s.get("index", 0)))

    if errors:
        msg_final = "Leitura AUTO concluída (algumas memórias falharam): " + " | ".join(errors)
    else:
        msg_final = "Leitura AUTO concluída."

    return True, msg_final, all_sms


def delete_sms(mem: str, indices: List[int]) -> Tuple[bool, str]:
    """
    Apaga SMS para uma memória específica.
    Usa send_at(), protegido por SERIAL_LOCK.
    """
    if not indices:
        return True, "Nenhum SMS selecionado"

    supported = get_supported_mems()
    if mem not in supported:
        return False, f"Memória inválida para deleção: {mem} (suportadas: {', '.join(supported)})"

    ok, resp = send_at(f'AT+CPMS="{mem}","{mem}","{mem}"', read_timeout=3.0)
    if not ok or "OK" not in resp:
        return False, f"Erro AT+CPMS antes de deletar ({mem}): {resp}"

    errors: List[str] = []
    for idx in indices:
        ok, resp = send_at(f"AT+CMGD={idx}", read_timeout=3.0)
        if not ok:
            errors.append(f"{mem}:{idx} → {resp}")

    if errors:
        return False, "Falhas ao apagar: " + " | ".join(errors)
    return True, "SMS apagados."

# ======================= INFO DO MODEM / INIT CNMI =========

def get_modem_info() -> Dict[str, Any]:
    info: Dict[str, Any] = {
        "ati": "",
        "imei": "",
        "cops": "",
        "csq_raw": "",
        "csq": {},
        "cpms_raw": "",
        "cpms": {},
        "error": None,
    }

    if serial is None:
        info["error"] = "pyserial não instalado"
        return info

    ok, ati = send_at("ATI", read_timeout=3.0)
    info["ati"] = ati

    ok, imei = send_at("AT+CGSN", read_timeout=3.0)
    info["imei"] = imei

    ok, cops = send_at("AT+COPS?", read_timeout=5.0)
    info["cops"] = cops

    ok, csq = send_at("AT+CSQ", read_timeout=3.0)
    info["csq_raw"] = csq
    info["csq"] = parse_csq(csq)

    ok, cpms = send_at("AT+CPMS?", read_timeout=5.0)
    info["cpms_raw"] = cpms
    info["cpms"] = parse_cpms(cpms)

    return info


def init_sms_settings() -> None:
    """
    Configura o modem para:
    - Modo texto
    - Charset GSM
    - Armazenar SMS na SM (se suportado)
    - Enviar URC de nova mensagem (+CMTI) via AT+CNMI
    (Tudo via send_at, já protegido por SERIAL_LOCK)
    """
    if serial is None:
        return

    send_at("AT+CMGF=1", read_timeout=3.0)
    send_at('AT+CSCS="GSM"', read_timeout=3.0)
    send_at('AT+CPMS="SM","SM","SM"', read_timeout=5.0)
    send_at("AT+CNMI=2,1,0,0,0", read_timeout=3.0)

# ======================= TEMPLATE HTML =======================

TEMPLATE = """
<!doctype html>
<html lang="pt-br">
<head>
<meta charset="utf-8">
<title>Mirako Modem/SMS</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root{
    --bg:#05070a;
    --panel:#0f141b;
    --panel-soft:#131a22;
    --line:#202733;
    --text:#e5e7eb;
    --muted:#9ca3af;
    --accent:#22c55e;
    --danger:#ef4444;
    --warn:#fbbf24;
    --blue:#3b82f6;
    --radius:12px;
    --shadow:0 8px 20px rgba(0,0,0,.35);
  }
  *{box-sizing:border-box;}
  body{
    margin:0;
    padding:0;
    font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,sans-serif;
    background:radial-gradient(circle at top,#0b1120 0,#020617 55%);
    color:var(--text);
  }
  a{color:#38bdf8;text-decoration:none;}
  a:hover{text-decoration:underline;}

  .wrap{max-width:1200px;margin:0 auto;padding:18px;}

  .topbar{
    display:flex;
    justify-content:space-between;
    align-items:center;
    padding:14px 18px;
    background:linear-gradient(135deg,#020617,#020617,#0f172a);
    border-radius:var(--radius);
    box-shadow:var(--shadow);
    border:1px solid #1f2933;
    margin-bottom:18px;
  }
  .brand{font-weight:700;font-size:1.1rem;}
  .brand span{color:#22c55e;}
  .topbar small{color:#9ca3af;}
  .mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:0.9rem;}

  .grid{
    display:grid;
    grid-template-columns:1.1fr 1.6fr;
    gap:18px;
  }
  @media (max-width:900px){
    .grid{grid-template-columns:1fr;}
  }

  .card{
    background:var(--panel);
    border-radius:var(--radius);
    border:1px solid var(--line);
    box-shadow:0 4px 12px rgba(0,0,0,.3);
    overflow:hidden;
  }
  .card-header{
    padding:10px 14px;
    border-bottom:1px solid var(--line);
    display:flex;
    justify-content:space-between;
    align-items:center;
    background:linear-gradient(135deg,#020617,#020617,#111827);
  }
  .card-header h2{
    margin:0;
    font-size:0.95rem;
    letter-spacing:.03em;
    text-transform:uppercase;
    color:#9ca3af;
  }
  .card-header .small{font-size:0.8rem;color:#9ca3af;}
  .card-body{padding:14px 14px 16px;}

  .muted{color:var(--muted);}
  .badge{
    display:inline-block;
    padding:2px 7px;
    border-radius:999px;
    font-size:0.7rem;
    border:1px solid #374151;
    background:#020617;
    color:#9ca3af;
  }
  .badge.green{border-color:#166534;color:#bbf7d0;background:#052e16;}
  .badge.red{border-color:#7f1d1d;color:#fecaca;background:#450a0a;}
  .badge.blue{border-color:#1d4ed8;color:#bfdbfe;background:#0b1120;}
  .badge.yellow{border-color:#854d0e;color:#fef9c3;background:#422006;}

  .row{
    display:flex;
    gap:10px;
    margin-bottom:8px;
  }
  .row .label{
    min-width:90px;
    font-size:0.8rem;
    color:var(--muted);
  }
  .row .value{
    flex:1;
  }

  .signal-bar-wrap{
    margin-top:6px;
    background:#020617;
    border-radius:999px;
    border:1px solid #1f2933;
    overflow:hidden;
    height:10px;
  }
  .signal-bar{
    height:100%;
    background:linear-gradient(90deg,#ef4444,#f97316,#eab308,#22c55e);
    width:0%;
    transition:width .3s ease;
  }

  .flash{
    padding:8px 12px;
    border-radius:8px;
    border:1px solid #374151;
    background:#020617;
    margin-bottom:12px;
    font-size:0.85rem;
  }
  .flash.error{border-color:var(--danger);color:#fecaca;background:#450a0a;}
  .flash.ok{border-color:#166534;color:#bbf7d0;background:#052e16;}

  .form-row{display:flex;gap:8px;margin-bottom:8px;}
  @media (max-width:600px){
    .form-row{flex-direction:column;}
  }

  label{font-size:0.8rem;color:var(--muted);display:block;margin-bottom:3px;}

  select,input[type=text],textarea{
    width:100%;
    border-radius:8px;
    border:1px solid #1f2933;
    padding:7px 9px;
    background:#020617;
    color:#e5e7eb;
    font-size:0.9rem;
    outline:none;
  }
  textarea{min-height:80px;resize:vertical;}
  select:focus,input[type=text]:focus,textarea:focus{
    border-color:#22c55e;
  }

  .btn{
    border-radius:8px;
    border:1px solid #1f2933;
    padding:7px 11px;
    font-size:0.85rem;
    cursor:pointer;
    background:#0b1120;
    color:#e5e7eb;
    display:inline-flex;
    align-items:center;
    gap:4px;
  }
  .btn:hover{filter:brightness(1.08);}
  .btn.green{background:linear-gradient(135deg,#16a34a,#22c55e);border-color:#15803d;color:#022c22;}
  .btn.blue{background:linear-gradient(135deg,#1d4ed8,#3b82f6);border-color:#1d4ed8;}
  .btn.red{background:linear-gradient(135deg,#b91c1c,#ef4444);border-color:#7f1d1d;}
  .btn.secondary{background:#020617;}

  table{
    width:100%;
    border-collapse:collapse;
    font-size:0.8rem;
  }
  th,td{
    border-bottom:1px solid #111827;
    padding:6px 4px;
    vertical-align:top;
  }
  th{text-align:left;color:#9ca3af;font-weight:500;}
  tr:hover{background:#020617;}
  td pre{
    margin:0;
    font-family:inherit;
    white-space:pre-wrap;
  }

  .sms-table-wrap{
    max-height:360px;
    overflow:auto;
    border-radius:8px;
    border:1px solid #111827;
    background:#020617;
    margin-top:8px;
  }

  .sms-actions{
    display:flex;
    justify-content:space-between;
    align-items:center;
    gap:8px;
    margin-top:6px;
  }
  .sms-actions .left{display:flex;gap:6px;align-items:center;flex-wrap:wrap;}

  .footer{
    margin-top:12px;
    font-size:0.75rem;
    color:#9ca3af;
    text-align:right;
  }
</style>
</head>
<body>
<div class="wrap">
  <div class="topbar">
    <div class="brand">Mirako <span>Modem/SMS</span></div>
    <small>TTY: <span class="mono">{{ serial_dev }}</span></small>
  </div>

  {% if new_sms_urc and new_sms_urc|length > 0 %}
    <div class="flash ok mono">
      Novos SMS detectados via URC (+CMTI / CNMI):<br>
      {% for urc in new_sms_urc %}
        • {{ urc.mem }}: índice {{ urc.index }} ({{ urc.raw }})<br>
      {% endfor %}
    </div>
  {% endif %}

  {% with messages = get_flashed_messages(with_categories=true) %}
    {% if messages %}
      {% for cat,msg in messages %}
        <div class="flash {{ 'error' if cat == 'error' else 'ok' }}">{{ msg|safe }}</div>
      {% endfor %}
    {% endif %}
  {% endwith %}

  {% if modem.error %}
    <div class="flash error mono">
      Erro: {{ modem.error }}
    </div>
  {% endif %}

  <div class="grid">
    <!-- Coluna esquerda: info modem + envio -->
    <div>
      <div class="card">
        <div class="card-header">
          <h2>Modem / Rede</h2>
          <span class="small">Info + Sinal</span>
        </div>
        <div class="card-body">
          <div class="row">
            <div class="label">ATI</div>
            <div class="value mono"><pre style="margin:0;white-space:pre-wrap;">{{ modem.ati }}</pre></div>
          </div>
          <div class="row">
            <div class="label">IMEI</div>
            <div class="value mono"><pre style="margin:0;white-space:pre-wrap;">{{ modem.imei }}</pre></div>
          </div>
          <div class="row">
            <div class="label">Operadora</div>
            <div class="value mono"><pre style="margin:0;white-space:pre-wrap;">{{ modem.cops }}</pre></div>
          </div>

          <hr style="border:0;border-top:1px solid #111827;margin:8px 0;">

          <div class="row">
            <div class="label">Sinal (CSQ)</div>
            <div class="value">
              {% if modem.csq.rssi is not none %}
                <div class="mono">
                  RSSI: {{ modem.csq.rssi }} &nbsp; / &nbsp;
                  BER: {{ modem.csq.ber if modem.csq.ber is not none else 'n/d' }}<br>
                  {{ modem.csq.dbm }} dBm &nbsp; • &nbsp; {{ modem.csq.percent }}% &nbsp; • &nbsp;
                  <span class="badge {% if modem.csq.percent >= 80 %}green{% elif modem.csq.percent>=60 %}blue{% elif modem.csq.percent>=40 %}yellow{% else %}red{% endif %}">
                    {{ modem.csq.qual }}
                  </span>
                </div>
                <div class="signal-bar-wrap">
                  <div class="signal-bar" style="width: {{ modem.csq.percent }}%;"></div>
                </div>
              {% else %}
                <span class="muted mono">CSQ inválido ou indisponível.</span>
              {% endif %}
            </div>
          </div>

          <div class="row">
            <div class="label">CPMS?</div>
            <div class="value">
              {% if modem.cpms %}
                <div class="mono">
                  {% for m,st in modem.cpms.items() %}
                    <span class="badge blue">{{ m }}</span>
                    {{ st.used }}/{{ st.total }}&nbsp;&nbsp;
                  {% endfor %}
                </div>
              {% else %}
                <span class="muted mono">sem parse de CPMS.</span>
              {% endif %}
            </div>
          </div>

          <details style="margin-top:8px;">
            <summary class="muted" style="cursor:pointer;font-size:0.8rem;">Raw CSQ / CPMS</summary>
            <pre class="mono" style="margin-top:4px;white-space:pre-wrap;">{{ modem.csq_raw }}</pre>
            <pre class="mono" style="margin-top:4px;white-space:pre-wrap;">{{ modem.cpms_raw }}</pre>
          </details>
        </div>
      </div>

      <div class="card" style="margin-top:16px;">
        <div class="card-header">
          <h2>Enviar SMS</h2>
          <span class="small">AT+CMGS (método robusto)</span>
        </div>
        <div class="card-body">
          <form method="post" action="{{ url_for('send_sms_route') }}">
            <div class="form-row">
              <div style="flex:1;">
                <label> Número (MSISDN) </label>
                <input type="text" name="number" placeholder="+55..." required>
              </div>
            </div>
            <div class="form-row">
              <div style="flex:1;">
                <label> Mensagem </label>
                <textarea name="text" maxlength="160" placeholder="Texto do SMS (até 160 caracteres)"></textarea>
              </div>
            </div>
            <div class="form-row" style="justify-content:flex-end;">
              <button class="btn green" type="submit">Enviar SMS</button>
            </div>
          </form>
        </div>
      </div>
    </div>

    <!-- Coluna direita: SMS -->
    <div>
      <div class="card">
        <div class="card-header">
          <h2>Mensagens SMS</h2>
          <span class="small">Carregar / Apagar / URC</span>
        </div>
        <div class="card-body">

          {% if new_sms_urc and new_sms_urc|length > 0 %}
            <form method="get" action="{{ url_for('index') }}" class="form-row">
              <div style="flex:1;">
                <label>Novos SMS (via +CMTI / CNMI)</label>
                <select name="mem_idx">
                  {% for urc in new_sms_urc %}
                    <option value="{{ urc.mem }}:{{ urc.index }}">
                      {{ urc.mem }}:{{ urc.index }} - {{ urc.raw }}
                    </option>
                  {% endfor %}
                </select>
              </div>
              <div style="display:flex;align-items:flex-end;">
                <input type="hidden" name="load" value="1">
                <input type="hidden" name="box" value="ALL">
                <button class="btn secondary" type="submit">Carregar memória</button>
              </div>
            </form>
          {% endif %}

          <form method="get" action="{{ url_for('index') }}" style="margin-top:8px;">
            <div class="form-row">
              <div style="flex:1;">
                <label>Memória (AT+CPMS)</label>
                <select name="mem">
                  {% for m in mem_choices %}
                    <option value="{{ m }}" {% if m == mem %}selected{% endif %}>{{ m }}</option>
                  {% endfor %}
                </select>
              </div>
              <div style="flex:1;">
                <label>Caixa / Status (AT+CMGL)</label>
                <select name="box">
                  {% for b in box_choices %}
                    <option value="{{ b }}" {% if b == box %}selected{% endif %}>{{ b }}</option>
                  {% endfor %}
                </select>
              </div>
              <div style="display:flex;align-items:flex-end;">
                <input type="hidden" name="load" value="1">
                <button class="btn blue" type="submit">Carregar SMS</button>
              </div>
            </div>
          </form>

          {% if sms_msg %}
            <div class="mono muted" style="font-size:0.8rem;margin-top:4px;">
              {{ sms_msg }}
            </div>
          {% endif %}

          <form method="post" action="{{ url_for('delete_sms_route') }}">
            <input type="hidden" name="mem" value="{{ mem }}">
            <input type="hidden" name="box" value="{{ box }}">

            <div class="sms-table-wrap">
              <table>
                <thead>
                  <tr>
                    <th style="width:24px;"><input type="checkbox" onclick="toggleAll(this)"></th>
                    <th>Idx</th>
                    <th>Mem</th>
                    <th>Status</th>
                    <th>Número</th>
                    <th>Data/Hora</th>
                    <th>Texto</th>
                  </tr>
                </thead>
                <tbody>
                  {% for sms in sms_list %}
                    <tr>
                      <td>
                        <input type="checkbox"
                               name="sms_id"
                               value="{{ sms.mem }}:{{ sms.index }}">
                      </td>
                      <td class="mono">{{ sms.index }}</td>
                      <td>
                        <span class="badge blue mono">{{ sms.mem }}</span>
                      </td>
                      <td class="mono">{{ sms.status }}</td>
                      <td class="mono">{{ sms.number }}</td>
                      <td class="mono">{{ sms.timestamp }}</td>
                      <td><pre>{{ sms.text }}</pre></td>
                    </tr>
                  {% endfor %}
                  {% if sms_list|length == 0 %}
                    <tr>
                      <td colspan="7" class="muted" style="text-align:center;padding:10px 4px;">
                        Nenhuma mensagem carregada. Clique em "Carregar SMS".
                      </td>
                    </tr>
                  {% endif %}
                </tbody>
              </table>
            </div>

            <div class="sms-actions">
              <div class="left">
                <button class="btn red" type="submit"
                        onclick="return confirm('Apagar SMS selecionados?');">
                  Apagar selecionados
                </button>
                <span class="muted" style="font-size:0.75rem;">* Em AUTO, lê SM + ME.</span>
              </div>
              <div>
                <form method="get" action="{{ url_for('index') }}" style="display:inline;">
                  <input type="hidden" name="mem" value="{{ mem }}">
                  <input type="hidden" name="box" value="{{ box }}">
                  <input type="hidden" name="load" value="1">
                  <button class="btn secondary" type="submit">Recarregar lista</button>
                </form>
              </div>
            </div>
          </form>
        </div>
      </div>

      <div class="footer">
        Mirako Modem/SMS • AT (CMGF, CPMS, CMGL, CMGS, CNMI, CSQ).
      </div>
    </div>
  </div>
</div>

<script>
function toggleAll(master){
  const boxes = document.querySelectorAll('input[name="sms_id"]');
  boxes.forEach(b => { b.checked = master.checked; });
}
</script>
</body>
</html>
"""

# ======================= ROTAS ==============================

@app.route("/", methods=["GET"])
def index():
    mem_raw = (request.args.get("mem") or "AUTO").strip().upper()
    box = (request.args.get("box") or "ALL").strip().upper()
    load = (request.args.get("load") or "").strip() == "1"
    mem_idx = (request.args.get("mem_idx") or "").strip()

    if box not in VALID_BOXES:
        box = "ALL"

    # se veio de um URC (mem_idx="SM:3"), usamos a memória do URC
    if mem_idx:
        try:
            mem_from_urc, _idx_str = mem_idx.split(":", 1)
            mem_raw = mem_from_urc.strip().upper()
        except Exception:
            pass

    mem = mem_raw if mem_raw in MEM_CHOICES else "AUTO"

    modem = get_modem_info()

    sms_list: List[Dict[str, Any]] = []
    sms_msg = ""

    if load:
        ok, msg, sms_list = get_sms(box=box, mem=mem)
        sms_msg = msg
        if not ok:
            flash(msg, "error")

    new_sms_urc = pop_new_sms_urc()

    context = dict(
        serial_dev=SERIAL_DEV,
        modem=modem,
        mem=mem,
        box=box,
        sms_list=sms_list,
        sms_msg=sms_msg,
        mem_choices=MEM_CHOICES,
        box_choices=VALID_BOXES,
        new_sms_urc=new_sms_urc,
    )
    return render_template_string(TEMPLATE, **context)


@app.post("/sms/delete")
def delete_sms_route():
    mem = (request.form.get("mem") or "AUTO").strip().upper()
    box = (request.form.get("box") or "ALL").strip().upper()
    if box not in VALID_BOXES:
        box = "ALL"

    ids = request.form.getlist("sms_id")
    if not ids:
        flash("Nenhuma mensagem selecionada.", "error")
        return redirect(url_for("index", mem=mem, box=box, load="1"))

    to_del: Dict[str, List[int]] = {}
    for vid in ids:
        try:
            mm, idx = vid.split(":", 1)
            mm = mm.strip().upper()
            index = int(idx.strip())
        except Exception:
            continue
        to_del.setdefault(mm, []).append(index)

    errors: List[str] = []
    for m, idxs in to_del.items():
        ok, msg = delete_sms(m, idxs)
        if not ok:
            errors.append(msg)

    if errors:
        flash("Erros ao apagar: " + " | ".join(errors), "error")
    else:
        flash("SMS apagados com sucesso.", "ok")

    return redirect(url_for("index", mem=mem, box=box, load="1"))


@app.post("/sms/send")
def send_sms_route():
    number = (request.form.get("number") or "").strip()
    text = (request.form.get("text") or "").strip()

    if not number:
        flash("Informe o número.", "error")
        return redirect(url_for("index"))

    if not text:
        flash("Mensagem vazia. Nada enviado.", "error")
        return redirect(url_for("index"))

    ok, resp = send_sms(number, text)
    if ok:
        flash("SMS enviado:<br><pre class='mono'>" + resp + "</pre>", "ok")
    else:
        flash("Falha ao enviar SMS:<br><pre class='mono'>" + resp + "</pre>", "error")

    return redirect(url_for("index"))


@app.get("/sms/new-urc")
def sms_new_urc_route():
    data = pop_new_sms_urc()
    return jsonify({"new_sms": data})

# ======================= MAIN ===============================

if __name__ == "__main__":
    try:
        init_sms_settings()
    except Exception as e:
        print("Falha ao inicializar SMS / CNMI:", e)

    # Se continuar sensível, dá pra rodar sem threads:
    # app.run(host="0.0.0.0", port=5003, debug=False, threaded=False)
    app.run(host="0.0.0.0", port=5003, debug=False)


EOF


sudo systemctl restart mirako-web-modem.service


sudo tee /etc/systemd/system/mirako-web-modem.service >/dev/null <<'EOF'
[Unit]
Description=Mirako Web UI do Modem 3G/4G (Flask)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

# Diretório do projeto
WorkingDirectory=/opt/mirako_web

# Variáveis de ambiente (ajuste se quiser)
Environment=MODEM_TTY=/dev/ttyUSB1
Environment=MODEM_BAUD=115200
Environment=MIRAKO_MODEM_SECRET=troque-esta-chave

# Comando para subir o Flask
ExecStart=/usr/bin/python3 /opt/mirako_web/web_modem.py

StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1


# Reiniciar sempre que cair
Restart=always
RestartSec=5

# Se quiser limitar recursos, pode colocar User= e Group=
#User=root
#Group=root

[Install]
WantedBy=multi-user.target
EOF



sudo systemctl daemon-reload
sudo systemctl enable --now mirako-web-modem.service
sudo systemctl restart mirako-web-modem.service
sudo journalctl -u mirako-web-modem.service -f



python3 /opt/mirako_web/web_modem.py
