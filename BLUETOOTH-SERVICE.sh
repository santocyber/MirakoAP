sudo apt-get install -y bluez bluez-tools libbluetooth-dev
pip install bleak --break-system-packages
sudo apt-get install -y bluez bluez-tools libbluetooth-dev python3-dev
sudo apt-get install -y python3-bluez








tee /opt/mirako_web/bluetooth.py >/dev/null <<'EOF'
# -*- coding: utf-8 -*-
"""
Bluetooth Lab seguro (Flask na porta 5001)
- Scan BLE (bleak)
- Scan BR/EDR clássico (bluetoothctl)
- GATT básico: listar serviços, ler e escrever característica
- RFCOMM SPP: enviar dado a um canal
- Serial: enviar/ler via porta /dev/tty*
- Bluetooth classic scanning com bluetoothctl
- Flood attack com l2ping
- Beacon detector
- Terminal serial Bluetooth em tempo real
"""
import os, asyncio, json, socket, time, re, threading, subprocess
import struct
from typing import Any, Dict, List
from flask import Flask, request, jsonify, Response
from dataclasses import dataclass
from collections import defaultdict

# ====== Dependências opcionais ======
try:
    from bleak import BleakScanner, BleakClient
except Exception as e:
    BleakScanner = None
    BleakClient = None

try:
    import bluetooth  # PyBluez
except Exception as e:
    bluetooth = None

try:
    import serial, serial.tools.list_ports
except Exception as e:
    serial = None

app = Flask(__name__, static_folder=None)

# ====== Estruturas para Beacon Detection ======

@dataclass
class BeaconInfo:
    address: str
    name: str
    rssi: int
    tx_power: int = None
    uuid: str = None
    major: int = None
    minor: int = None
    company: str = None
    beacon_type: str = None
    first_seen: float = None
    last_seen: float = None
    packet_count: int = 0

class BeaconDetector:
    def __init__(self):
        self.beacons = {}
        self.scanning = False
        
    def parse_advertising_data(self, device, advertisement_data):
        """Parse beacon data from BLE advertising packets"""
        beacon = BeaconInfo(
            address=device.address,
            name=device.name or "Unknown",
            rssi=device.rssi,
            first_seen=time.time(),
            last_seen=time.time(),
            packet_count=1
        )
        
        # Parse manufacturer data for common beacon formats
        if advertisement_data.manufacturer_data:
            for company_id, data in advertisement_data.manufacturer_data.items():
                beacon.company = f"0x{company_id:04X}"
                
                # iBeacon detection
                if company_id == 0x004C and len(data) >= 23:  # Apple
                    if data[0] == 0x02 and data[1] == 0x15:  # iBeacon prefix
                        beacon.beacon_type = "iBeacon"
                        uuid = data[2:18]
                        beacon.uuid = str(uuid.hex())
                        beacon.major = struct.unpack('>H', data[18:20])[0]
                        beacon.minor = struct.unpack('>H', data[20:22])[0]
                        beacon.tx_power = struct.unpack('b', data[22:23])[0]
                
                # Eddystone detection
                elif len(data) >= 3:
                    frame_type = data[0]
                    if frame_type == 0x00:  # Eddystone-UID
                        beacon.beacon_type = "Eddystone-UID"
                        beacon.tx_power = struct.unpack('b', data[1:2])[0]
                    elif frame_type == 0x10:  # Eddystone-URL
                        beacon.beacon_type = "Eddystone-URL"
                        beacon.tx_power = struct.unpack('b', data[1:2])[0]
                    elif frame_type == 0x20:  # Eddystone-TLM
                        beacon.beacon_type = "Eddystone-TLM"
        
        # Parse service data
        if advertisement_data.service_data:
            for uuid, data in advertisement_data.service_data.items():
                if "feaa" in uuid.lower():  # Eddystone
                    beacon.beacon_type = "Eddystone"
        
        return beacon
    
    def update_beacon(self, device, advertisement_data):
        """Update beacon information"""
        current_time = time.time()
        beacon = self.parse_advertising_data(device, advertisement_data)
        
        # Update existing beacon or add new one
        if device.address in self.beacons:
            existing = self.beacons[device.address]
            existing.last_seen = current_time
            existing.rssi = beacon.rssi
            existing.packet_count += 1
            # Update other fields if they're None
            if existing.tx_power is None:
                existing.tx_power = beacon.tx_power
            if existing.uuid is None:
                existing.uuid = beacon.uuid
            if existing.beacon_type is None:
                existing.beacon_type = beacon.beacon_type
        else:
            self.beacons[device.address] = beacon
        
        return beacon

# ====== Inicialização do Detector ======
beacon_detector = BeaconDetector()

# ====== Variáveis globais para controle ======
flood_threads = []
flood_running = False
beacon_scanning = False
serial_connection = None
serial_reader_thread = None
serial_messages = []
serial_connected = False

# ====== Funções Bluetooth Classic Melhoradas ======

def list_bluetooth_improved(wait_time):
    """Scan dispositivos Bluetooth classic usando bluetoothctl com mais informações"""
    process = subprocess.Popen(
        ['bluetoothctl'],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )

    # Clear previous devices
    process.stdin.write("remove *\n")
    process.stdin.flush()
    time.sleep(1)

    # Start scanning
    process.stdin.write("scan on\n")
    process.stdin.flush()

    print(f'Waiting {wait_time}s for advertisements')
    time.sleep(wait_time)

    # Stop scanning and get devices
    process.stdin.write("scan off\n")
    process.stdin.flush()
    process.stdin.write("devices\n")
    process.stdin.flush()
    
    # Get more detailed info for each device
    process.stdin.write("devices\n")
    process.stdin.flush()
    
    # Try to get pairing info and other details
    process.stdin.write("paired-devices\n")
    process.stdin.flush()
    
    process.stdin.write("quit\n")
    process.stdin.flush()

    output, error = process.communicate()
    
    if error:
        print(f"Bluetoothctl error: {error}")

    # Parse the output for device addresses and names with better regex
    devices = []
    seen_addresses = set()
    
    for line in output.splitlines():
        # Match device lines with various formats
        match = re.search(r"Device\s+([0-9A-Fa-f:]{17})\s+(.+)", line)
        if match:
            address, name = match.groups()
            address = address.upper().strip()
            name = name.strip()
            
            # Skip duplicates and invalid addresses
            if address in seen_addresses or address == "00:00:00:00:00:00":
                continue
                
            seen_addresses.add(address)
            
            # Get additional info using bluetoothctl info
            try:
                info_process = subprocess.Popen(
                    ['bluetoothctl', 'info', address],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True
                )
                info_output, _ = info_process.communicate(timeout=5)
                
                # Parse additional info
                paired = "Paired: yes" in info_output
                trusted = "Trusted: yes" in info_output
                connected = "Connected: yes" in info_output
                blocked = "Blocked: yes" in info_output
                
                # Try to get RSSI from info
                rssi_match = re.search(r"RSSI:\s+(-?\d+)", info_output)
                rssi = int(rssi_match.group(1)) if rssi_match else None
                
                # Try to get device class
                class_match = re.search(r"Class:\s+0x([0-9a-fA-F]+)", info_output)
                device_class = class_match.group(1) if class_match else None
                
                # Get UUIDs/services
                services = []
                for service_line in info_output.splitlines():
                    if "UUID:" in service_line:
                        service_match = re.search(r"UUID:\s+([0-9a-fA-F-]+)", service_line)
                        if service_match:
                            services.append(service_match.group(1))
                
                devices.append({
                    'address': address,
                    'name': name,
                    'paired': paired,
                    'trusted': trusted,
                    'connected': connected,
                    'blocked': blocked,
                    'rssi': rssi,
                    'device_class': device_class,
                    'services': services[:5],  # Limit to first 5 services
                    'services_count': len(services)
                })
                
            except Exception as e:
                print(f"Error getting info for {address}: {e}")
                devices.append({
                    'address': address, 
                    'name': name,
                    'paired': False,
                    'trusted': False,
                    'connected': False,
                    'blocked': False,
                    'rssi': None,
                    'device_class': None,
                    'services': [],
                    'services_count': 0
                })

    return devices

def flood_attack(target_addr, packet_size, threads):
    """Flood attack usando l2ping com melhor monitoramento"""
    print(f"Starting flood attack on {target_addr} with {threads} threads, packet size {packet_size}")
    
    def flood_thread(thread_id):
        try:
            print(f"Thread {thread_id} starting flood attack")
            process = subprocess.Popen(
                ['l2ping', '-i', 'hci0', '-s', str(packet_size), '-f', target_addr],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            
            # Monitor the process
            start_time = time.time()
            packet_count = 0
            
            while flood_running and time.time() - start_time < 30:  # Run for 30 seconds max per thread
                line = process.stdout.readline()
                if not line:
                    break
                if "bytes from" in line:
                    packet_count += 1
                if packet_count % 100 == 0:
                    print(f"Thread {thread_id} sent {packet_count} packets")
            
            # Try to terminate gracefully
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                
            print(f"Thread {thread_id} finished, sent {packet_count} packets")
            
        except Exception as e:
            print(f"Thread {thread_id} error: {e}")

    # Start all threads
    thread_list = []
    for i in range(threads):
        thread = threading.Thread(
            target=flood_thread,
            args=(i,),
            daemon=True
        )
        thread.start()
        thread_list.append(thread)
    
    return thread_list

# ====== Funções Serial Bluetooth Corrigidas ======

def pair_and_trust_device(address, pin="1234"):
    """Parea e confia em um dispositivo Bluetooth"""
    try:
        print(f"Tentando parear com {address}...")
        
        # Primeiro remove o dispositivo se já existir pareado
        subprocess.run(['bluetoothctl', 'remove', address], check=False, timeout=5)
        time.sleep(1)
        
        # Pareamento simples
        result = subprocess.run(
            ['bluetoothctl', 'pair', address],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode == 0 or "Pairing successful" in result.stdout:
            print(f"Pareamento bem-sucedido com {address}")
            
            # Configura como confiável
            subprocess.run(['bluetoothctl', 'trust', address], check=False, timeout=5)
            time.sleep(1)
            return True
        else:
            print(f"Falha no pareamento: {result.stderr}")
            return False
            
    except Exception as e:
        print(f"Erro durante pareamento: {e}")
        return False

def connect_rfcomm(address, channel=1):
    """Conecta a um dispositivo Bluetooth via RFCOMM"""
    try:
        # Libera a porta se já estiver em uso
        subprocess.run(['sudo', 'rfcomm', 'release', '0'], check=False, timeout=5)
        time.sleep(2)
        
        # Tenta criar a porta RFCOMM
        print(f"Tentando bind RFCOMM para {address} canal {channel}")
        result = subprocess.run(
            ['sudo', 'rfcomm', 'bind', '/dev/rfcomm0', address, str(channel)],
            capture_output=True,
            text=True,
            timeout=15
        )
        
        if result.returncode == 0:
            print(f"RFCOMM bind successful for {address}")
            time.sleep(2)
            
            # Verifica se a porta foi criada
            if os.path.exists('/dev/rfcomm0'):
                # Configura permissões
                subprocess.run(['sudo', 'chmod', '666', '/dev/rfcomm0'], check=False)
                return True
            else:
                print("Porta /dev/rfcomm0 não foi criada")
                return False
        else:
            print(f"RFCOMM bind failed: {result.stderr}")
            return False
            
    except Exception as e:
        print(f"Erro RFCOMM: {e}")
        return False

def disconnect_rfcomm():
    """Desconecta a porta RFCOMM"""
    try:
        result = subprocess.run(
            ['sudo', 'rfcomm', 'release', '0'],
            capture_output=True,
            text=True,
            timeout=10
        )
        return result.returncode == 0
    except Exception as e:
        print(f"Erro RFCOMM release: {e}")
        return False

def serial_reader():
    """Thread para ler continuamente da porta serial"""
    global serial_connection, serial_messages, serial_connected
    
    while serial_connected:
        try:
            if serial_connection and serial_connection.is_open:
                # Lê dados disponíveis
                if serial_connection.in_waiting > 0:
                    data = serial_connection.read(serial_connection.in_waiting)
                    if data:
                        decoded_data = data.decode('utf-8', errors='ignore').strip()
                        if decoded_data:
                            # Adiciona à lista de mensagens com timestamp
                            timestamp = time.strftime("%H:%M:%S")
                            serial_messages.append(f"[{timestamp}] {decoded_data}")
                            
                            # Mantém apenas as últimas 100 mensagens
                            if len(serial_messages) > 100:
                                serial_messages.pop(0)
                
                time.sleep(0.1)  # Pequena pausa para não sobrecarregar
            else:
                time.sleep(1)
        except Exception as e:
            print(f"Erro na leitura serial: {e}")
            time.sleep(1)

def send_serial_data(data, port='/dev/rfcomm0', baudrate=9600):
    """Envia dados para a porta serial"""
    global serial_connection
    
    try:
        if not os.path.exists(port):
            return False, f"Porta {port} não encontrada"
        
        # Se não há conexão serial ativa, cria uma
        if serial_connection is None or not serial_connection.is_open:
            serial_connection = serial.Serial(port, baudrate=baudrate, timeout=0.1)
        
        # Envia dados
        if not data.endswith('\n'):
            data += '\n'
        
        serial_connection.write(data.encode('utf-8'))
        serial_connection.flush()
        
        return True, "Dados enviados"
        
    except Exception as e:
        return False, f"Erro ao enviar dados: {str(e)}"

def check_rfcomm_connection():
    """Verifica se a conexão RFCOMM está ativa"""
    try:
        # Verifica se a porta existe
        if not os.path.exists('/dev/rfcomm0'):
            return False, "Porta /dev/rfcomm0 não existe"
        
        # Verifica se há dispositivos conectados via rfcomm
        result = subprocess.run(
            ['rfcomm', 'show', '0'],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        connected = result.returncode == 0 and "connected" in result.stdout.lower()
        return connected, result.stdout if result.returncode == 0 else result.stderr
        
    except Exception as e:
        return False, f"Erro ao verificar conexão: {str(e)}"

# ====== Helpers ======
def ok(payload: Any, status=200):
    return jsonify({"ok": True, "data": payload}), status

def err(msg: str, status=400):
    return jsonify({"ok": False, "error": msg}), status

def run_async(coro):
    """Isola event loop para chamadas BLE dentro do Flask (sem reloader)."""
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.run_until_complete(asyncio.sleep(0))
        loop.close()

# ====== HTML Interface Simplificada ======
INDEX_HTML = r"""
<!doctype html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Bluetooth Lab - Porta 5001</title>
  <style>
    body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,'Helvetica Neue',Arial,sans-serif;margin:0;padding:24px;background:#0b0e14;color:#e6e6e6}
    h1,h2{margin:0 0 12px}
    section{border:1px solid #22283a;border-radius:10px;padding:16px;margin:16px 0;background:#111626}
    button{padding:8px 12px;border-radius:8px;border:0;background:#2f6feb;color:#fff;cursor:pointer}
    input,select,textarea{padding:8px;border-radius:8px;border:1px solid #2a3150;background:#0f1424;color:#ddd}
    pre{white-space:pre-wrap;background:#0f1424;padding:12px;border-radius:8px;overflow:auto}
    .row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
    .muted{color:#9aa0b4}
    a{color:#9fd3ff}
    .note{font-size:.9em;color:#9aa0b4}
    .danger{background:#dc3545 !important}
    .warning{background:#ffc107 !important;color:#000 !important}
    .success{background:#28a745 !important}
    
    /* Display styles for organized JSON */
    .json-display {font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace; font-size: 12px;}
    .dict-container {margin: 5px 0; padding-left: 15px; border-left: 1px solid #2a3150;}
    .dict-item {margin: 3px 0; display: flex; align-items: flex-start;}
    .dict-key {color: #9fd3ff; font-weight: bold; min-width: 120px;}
    .dict-value {color: #e6e6e6;}
    .list-container {margin: 5px 0; padding-left: 15px;}
    .list-item {margin: 3px 0; padding: 2px 5px; background: #1a1f2e; border-radius: 4px;}
    .list-value {color: #e6e6e6;}
    .bool-value.true {color: #28a745;}
    .bool-value.false {color: #dc3545;}
    .null-value {color: #9aa0b4; font-style: italic;}
    .no-data {color: #9aa0b4; font-style: italic;}
    
    /* Device cards */
    .device-grid {display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 15px; margin: 15px 0;}
    .device-card {background: #1a1f2e; border: 1px solid #2a3150; border-radius: 8px; padding: 15px;}
    .device-header {display: flex; justify-content: between; align-items: center; margin-bottom: 10px;}
    .device-name {font-weight: bold; color: #9fd3ff;}
    .device-address {font-family: monospace; color: #9aa0b4; font-size: 0.9em;}
    .device-status {display: flex; gap: 10px; margin: 8px 0;}
    .status-badge {padding: 2px 8px; border-radius: 12px; font-size: 0.8em;}
    .status-connected {background: #28a745;}
    .status-paired {background: #17a2b8;}
    .status-trusted {background: #6f42c1;}
    .status-blocked {background: #dc3545;}
    
    /* Beacon list */
    .beacon-list {max-height: 400px; overflow-y: auto;}
    .beacon-item {background: #1e293b; margin: 5px 0; padding: 10px; border-radius: 6px; border-left: 4px solid #3b82f6;}
    .beacon-item.ibeacon {border-left-color: #ef4444;}
    .beacon-item.eddystone {border-left-color: #10b981;}
    
    /* Serial terminal */
    .terminal {background: #000; color: #00ff00; font-family: 'Courier New', monospace; padding: 15px; border-radius: 5px; height: 400px; overflow-y: auto;}
    .terminal-line {margin: 2px 0;}
    .terminal-input {display: flex; gap: 10px; margin-top: 10px;}
    .terminal-input input {flex: 1;}
    
    /* Connection status */
    .connection-status {padding: 10px; border-radius: 5px; margin: 10px 0;}
    .status-connected {background: #1e3a1e; border: 1px solid #28a745;}
    .status-disconnected {background: #3a1e1e; border: 1px solid #dc3545;}
    .status-pairing {background: #2a2a1e; border: 1px solid #ffc107;}
  </style>
</head>
<body>
  <h1>Bluetooth Lab</h1>
  <p class="muted">Ferramentas de teste para BLE/BR-EDR e serial.</p>

  <!-- Seção para Beacon Detection -->
  <section id="beacon-detection">
    <h2>🔍 Beacon Detection</h2>
    <div class="row">
      <label for="beaconScanTime">Tempo scan (s):</label>
      <input id="beaconScanTime" value="10" style="width:80px">
      <button onclick="startBeaconScan()" class="success">Iniciar Scan Beacons</button>
      <button onclick="stopBeaconScan()" class="warning">Parar Scan</button>
      <button onclick="clearBeacons()">Limpar Lista</button>
    </div>
    
    <div class="row">
      <div style="flex:1;">
        <h4>📱 Beacons Detectados</h4>
        <div class="beacon-list" id="beaconList">
          <div class="muted">Nenhum beacon detectado</div>
        </div>
      </div>
    </div>
  </section>

  <!-- Seção para Bluetooth Classic -->
  <section id="classic-scan">
    <h2>Scan Bluetooth Classic (bluetoothctl)</h2>
    <div class="row">
      <label for="bluetoothctlWait">Tempo espera (s):</label>
      <input id="bluetoothctlWait" value="5" style="width:80px">
      <button onclick="scanBluetoothCtl()">Scan com bluetoothctl</button>
      <button onclick="clearBluetoothCtl()">Limpar Scan</button>
    </div>
    <div id="bluetoothctlOut" class="json-display">—</div>
  </section>

  <!-- Seção para Serial Bluetooth Simplificada -->
  <section id="serial-bluetooth">
    <h2>🔌 Terminal Serial Bluetooth</h2>
    
    <div class="row">
      <input id="serialDevice" placeholder="Endereço Bluetooth (ex: 38:18:2B:EA:80:B2)" style="min-width:280px" value="38:18:2B:EA:80:B2">
      <input id="serialChannel" type="number" value="1" style="width:80px" placeholder="Canal">
      <input id="serialPin" placeholder="PIN (padrão: 1234)" value="1234" style="width:120px">
      <select id="serialBaudrate" style="width:120px">
        <option value="9600">9600 baud</option>
        <option value="38400">38400 baud</option>
        <option value="115200">115200 baud</option>
      </select>
      <button onclick="connectSerial()" class="success">Conectar</button>
      <button onclick="disconnectSerial()" class="warning">Desconectar</button>
      <button onclick="checkConnection()">Verificar Conexão</button>
    </div>
    
    <div id="connectionStatus" class="connection-status status-disconnected">
      Status: Desconectado
    </div>
    
    <div class="row">
      <div style="flex:1;">
        <h4>Terminal Serial - Comunicação Bidirecional</h4>
        <div class="terminal" id="serialTerminal">
          <div class="terminal-line">Terminal Serial Bluetooth</div>
          <div class="terminal-line">Conecte-se a um dispositivo para começar...</div>
        </div>
        <div class="terminal-input">
          <input id="serialCommand" placeholder="Digite comando para enviar..." onkeypress="handleSerialKeypress(event)">
          <button onclick="sendSerialCommand()">Enviar</button>
          <button onclick="clearTerminal()">Limpar Terminal</button>
          <button onclick="getSerialMessages()">Atualizar</button>
        </div>
      </div>
    </div>
  </section>

  <section id="flood-attack" style="border-color: #dc3545;">
    <h2 style="color: #dc3545;">⚠ Flood Attack (Cuidado!)</h2>
    <p class="note" style="color: #ff6b6b;">
      ATENÇÃO: Esta funcionalidade é apenas para testes de segurança em equipamentos próprios.
      Use com responsabilidade.
    </p>
    <div class="row">
      <input id="floodTarget" placeholder="Endereço alvo (ex: AA:BB:CC:DD:EE:FF)" style="min-width:280px">
      <input id="floodPacketSize" type="number" value="600" style="width:120px" placeholder="Tamanho pacote">
      <input id="floodThreads" type="number" value="3" style="width:100px" placeholder="Threads">
      <button onclick="startFlood()" class="danger">Iniciar Flood</button>
      <button onclick="stopFlood()" class="warning">Parar Flood</button>
      <button onclick="getFloodStatus()">Status</button>
    </div>
    <div id="floodOut" class="json-display">—</div>
  </section>

  <section id="hci">
    <h2>Adaptador (HCI)</h2>
    <div class="row">
      <label for="adapter">Adapter:</label>
      <input id="adapter" value="hci0" style="width:140px">
      <button onclick="getHci()">Ler Info</button>
      <button onclick="restartBluetooth()">Reiniciar Bluetooth</button>
    </div>
    <div id="hciOut" class="json-display">Clique em "Ler Info".</div>
  </section>

  <section id="scan">
    <h2>Scan</h2>
    <div class="row">
      <label for="bleTimeout">BLE (s):</label>
      <input id="bleTimeout" value="10" style="width:80px">
      <label for="bleSvc">UUIDs (csv):</label>
      <input id="bleSvc" placeholder="ex: 180D,180F" style="min-width:200px">
      <label for="bleRssi">RSSI ≥</label>
      <input id="bleRssi" type="number" placeholder="-70" style="width:90px">
      <button onclick="scanBle()">Scan BLE</button>
    </div>
    <div id="bleOut" class="json-display">—</div>

    <div class="row" style="margin-top:10px">
      <label for="classicDuration">Clássico (bluetoothctl):</label>
      <input id="classicDuration" value="8" style="width:80px">
      <button onclick="scanClassic()">Scan BR/EDR</button>
    </div>
    <div id="classicOut" class="json-display">—</div>
  </section>

  <p class="muted">© Laboratório local. Use apenas seus próprios dispositivos e ambiente controlado.</p>

<script>
// Variáveis para controle
let beaconScanInterval = null;
let serialConnected = false;
let messagePollInterval = null;

// Funções para Beacon Detection
async function startBeaconScan() {
  const scanTime = parseInt(document.getElementById('beaconScanTime').value || '10', 10);
  const res = await fetch(`/api/beacons/start?duration=${scanTime}`);
  const data = await res.json();
  
  if (data.ok) {
    beaconScanInterval = setInterval(updateBeaconList, 2000);
    updateBeaconList();
  }
}

async function stopBeaconScan() {
  if (beaconScanInterval) {
    clearInterval(beaconScanInterval);
    beaconScanInterval = null;
  }
  
  const res = await fetch(`/api/beacons/stop`);
  updateBeaconList();
}

async function clearBeacons() {
  const res = await fetch(`/api/beacons/clear`, {method: 'POST'});
  updateBeaconList();
}

async function updateBeaconList() {
  const res = await fetch(`/api/beacons/list`);
  const data = await res.json();
  
  if (data.ok) {
    const beaconList = document.getElementById('beaconList');
    
    if (data.data.beacons.length === 0) {
      beaconList.innerHTML = '<div class="muted">Nenhum beacon detectado</div>';
      return;
    }
    
    beaconList.innerHTML = '';
    
    data.data.beacons.forEach(beacon => {
      const beaconItem = document.createElement('div');
      beaconItem.className = `beacon-item ${beacon.beacon_type ? beacon.beacon_type.toLowerCase() : ''}`;
      
      let details = [];
      if (beacon.beacon_type) details.push(`Tipo: ${beacon.beacon_type}`);
      if (beacon.rssi) details.push(`RSSI: ${beacon.rssi}dBm`);
      if (beacon.tx_power) details.push(`TX: ${beacon.tx_power}dBm`);
      if (beacon.uuid) details.push(`UUID: ${beacon.uuid.substring(0, 8)}...`);
      
      beaconItem.innerHTML = `
        <div><strong>${beacon.name}</strong> (${beacon.address})</div>
        <div style="font-size:0.9em;color:#9aa0b4;">
          ${details.join(' | ')}
        </div>
        <div style="font-size:0.8em;color:#6b7280;">
          Pacotes: ${beacon.packet_count} | Idade: ${beacon.age_seconds}s
        </div>
      `;
      
      beaconList.appendChild(beaconItem);
    });
  }
}

// Funções para Bluetooth Classic
async function scanBluetoothCtl(){
  const waitTime = parseInt(document.getElementById('bluetoothctlWait').value||'5',10);
  const res = await fetch(`/api/scan/bluetoothctl?wait_time=${waitTime}`);
  const data = await res.json();
  
  if (data.ok) {
    // Criar display organizado dos dispositivos
    let html = '<div class="device-grid">';
    data.data.devices.forEach(device => {
      html += `
        <div class="device-card">
          <div class="device-header">
            <div class="device-name">${device.name}</div>
            <div class="device-address">${device.address}</div>
          </div>
          <div class="device-status">
            ${device.connected ? '<span class="status-badge status-connected">Conectado</span>' : ''}
            ${device.paired ? '<span class="status-badge status-paired">Pareado</span>' : ''}
            ${device.trusted ? '<span class="status-badge status-trusted">Confiável</span>' : ''}
            ${device.blocked ? '<span class="status-badge status-blocked">Bloqueado</span>' : ''}
          </div>
          <div style="font-size:0.9em; margin-top:8px;">
            ${device.rssi ? `RSSI: ${device.rssi}dBm` : ''}
            ${device.device_class ? `<br>Classe: 0x${device.device_class}` : ''}
            ${device.services_count > 0 ? `<br>Serviços: ${device.services_count}` : ''}
          </div>
        </div>
      `;
    });
    html += '</div>';
    document.getElementById('bluetoothctlOut').innerHTML = html;
  } else {
    document.getElementById('bluetoothctlOut').textContent = JSON.stringify(data, null, 2);
  }
}

async function clearBluetoothCtl(){
  document.getElementById('bluetoothctlOut').innerHTML = '—';
}

// Funções para Serial Bluetooth
async function connectSerial(){
  const device = document.getElementById('serialDevice').value.trim();
  const channel = parseInt(document.getElementById('serialChannel').value || '1', 10);
  const pin = document.getElementById('serialPin').value.trim() || '1234';
  const baudrate = document.getElementById('serialBaudrate').value;
  
  if(!device){ alert('Informe o endereço Bluetooth'); return; }
  
  updateConnectionStatus('pairing', 'Conectando...');
  addTerminalLine(`🔗 Conectando a ${device}...`);
  
  const res = await fetch(`/api/serial/connect`, {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({address: device, channel: channel, pin: pin, baudrate: baudrate})
  });
  const data = await res.json();
  
  if (data.ok) {
    serialConnected = true;
    updateConnectionStatus('connected', `Conectado a ${device}`);
    addTerminalLine(`✅ ${data.data.message}`);
    
    // Inicia polling de mensagens
    if (messagePollInterval) {
      clearInterval(messagePollInterval);
    }
    messagePollInterval = setInterval(getSerialMessages, 1000);
    
  } else {
    updateConnectionStatus('disconnected', `Erro: ${data.error}`);
    addTerminalLine(`❌ Erro: ${data.error}`);
  }
}

async function disconnectSerial(){
  if (messagePollInterval) {
    clearInterval(messagePollInterval);
    messagePollInterval = null;
  }
  
  const res = await fetch(`/api/serial/disconnect`, {method: 'POST'});
  const data = await res.json();
  
  if (data.ok) {
    serialConnected = false;
    updateConnectionStatus('disconnected', 'Desconectado');
    addTerminalLine('🔌 Desconectado');
  } else {
    addTerminalLine(`❌ Erro ao desconectar: ${data.error}`);
  }
}

async function checkConnection(){
  const res = await fetch(`/api/serial/status`);
  const data = await res.json();
  
  if (data.ok) {
    if (data.data.connected) {
      updateConnectionStatus('connected', data.data.message);
      addTerminalLine(`✅ ${data.data.message}`);
    } else {
      updateConnectionStatus('disconnected', data.data.message);
      addTerminalLine(`❌ ${data.data.message}`);
    }
  }
}

async function sendSerialCommand(){
  const command = document.getElementById('serialCommand').value.trim();
  if(!command) return;
  
  const baudrate = document.getElementById('serialBaudrate').value;
  
  addTerminalLine(`➤ ENVIADO: ${command}`);
  document.getElementById('serialCommand').value = '';
  
  const res = await fetch(`/api/serial/send`, {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({command: command, baudrate: baudrate})
  });
  const data = await res.json();
  
  if (!data.ok) {
    addTerminalLine(`❌ Erro: ${data.error}`);
  }
}

async function getSerialMessages(){
  const res = await fetch(`/api/serial/messages`);
  const data = await res.json();
  
  if (data.ok && data.data.messages.length > 0) {
    data.data.messages.forEach(msg => {
      addTerminalLine(`◀ RECEBIDO: ${msg}`);
    });
  }
}

function handleSerialKeypress(event){
  if(event.key === 'Enter'){
    sendSerialCommand();
  }
}

function addTerminalLine(text){
  const terminal = document.getElementById('serialTerminal');
  const line = document.createElement('div');
  line.className = 'terminal-line';
  line.textContent = text;
  terminal.appendChild(line);
  terminal.scrollTop = terminal.scrollHeight;
}

function clearTerminal(){
  document.getElementById('serialTerminal').innerHTML = '<div class="terminal-line">Terminal limpo</div>';
}

function updateConnectionStatus(status, message) {
  const statusElement = document.getElementById('connectionStatus');
  if (status === 'connected') {
    statusElement.className = 'connection-status status-connected';
    statusElement.innerHTML = `✅ ${message}`;
  } else if (status === 'pairing') {
    statusElement.className = 'connection-status status-pairing';
    statusElement.innerHTML = `🔄 ${message}`;
  } else {
    statusElement.className = 'connection-status status-disconnected';
    statusElement.innerHTML = `❌ ${message}`;
  }
}

// Funções para Flood Attack
async function startFlood(){
  const target = document.getElementById('floodTarget').value.trim();
  const packetSize = parseInt(document.getElementById('floodPacketSize').value||'600',10);
  const threads = parseInt(document.getElementById('floodThreads').value||'3',10);
  
  if(!target){ alert('Informe o endereço alvo'); return; }
  
  const res = await fetch(`/api/flood/start`, {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({target: target, packet_size: packetSize, threads: threads})
  });
  const data = await res.json();
  document.getElementById('floodOut').innerHTML = formatJsonDisplay(data);
}

async function stopFlood(){
  const res = await fetch(`/api/flood/stop`, {method: 'POST'});
  const data = await res.json();
  document.getElementById('floodOut').innerHTML = formatJsonDisplay(data);
}

async function getFloodStatus(){
  const res = await fetch(`/api/flood/status`);
  const data = await res.json();
  document.getElementById('floodOut').innerHTML = formatJsonDisplay(data);
}

// Funções para HCI
async function getHci(){
  const adapter = document.getElementById('adapter').value || 'hci0';
  const res = await fetch(`/api/hci?adapter=${encodeURIComponent(adapter)}`);
  const data = await res.json();
  document.getElementById('hciOut').innerHTML = formatJsonDisplay(data);
}

async function restartBluetooth(){
  const res = await fetch(`/api/hci/restart`, {method: 'POST'});
  const data = await res.json();
  document.getElementById('hciOut').innerHTML = formatJsonDisplay(data);
}

// Funções para Scan BLE/Classic
async function scanBle(){
  const t = parseInt(document.getElementById('bleTimeout').value||'10',10);
  const uuids = document.getElementById('bleSvc').value||'';
  const rssi  = document.getElementById('bleRssi').value||'';
  const res = await fetch(`/api/scan/ble?timeout=${t}&uuids=${encodeURIComponent(uuids)}&rssi_min=${encodeURIComponent(rssi)}`);
  const data = await res.json();
  document.getElementById('bleOut').innerHTML = formatJsonDisplay(data);
}

async function scanClassic(){
  const d = parseInt(document.getElementById('classicDuration').value||'8',10);
  const res = await fetch(`/api/scan/classic?duration=${d}`);
  const data = await res.json();
  document.getElementById('classicOut').innerHTML = formatJsonDisplay(data);
}

// Função para formatar exibição JSON
function formatJsonDisplay(data) {
  if (!data) return '<div class="no-data">Sem dados</div>';
  
  if (data.ok === false) {
    return `<div style="color: #dc3545;">Erro: ${data.error}</div>`;
  }
  
  return formatDataDisplay(data.data || data);
}

function formatDataDisplay(obj) {
  if (Array.isArray(obj)) {
    return formatArrayDisplay(obj);
  } else if (typeof obj === 'object' && obj !== null) {
    return formatObjectDisplay(obj);
  } else {
    return `<span>${obj}</span>`;
  }
}

function formatArrayDisplay(arr) {
  if (arr.length === 0) return '<div class="no-data">Array vazio</div>';
  
  let html = '<div class="list-container">';
  arr.forEach(item => {
    html += `<div class="list-item">${formatDataDisplay(item)}</div>`;
  });
  html += '</div>';
  return html;
}

function formatObjectDisplay(obj) {
  let html = '<div class="dict-container">';
  for (const [key, value] of Object.entries(obj)) {
    html += `
      <div class="dict-item">
        <span class="dict-key">${key}:</span>
        <span class="dict-value">${formatDataDisplay(value)}</span>
      </div>
    `;
  }
  html += '</div>';
  return html;
}

// Verificar status da conexão ao carregar a página
window.addEventListener('load', function() {
  checkConnection();
});
</script>
</body>
</html>
"""

@app.route("/")
def index():
    return Response(INDEX_HTML, mimetype="text/html; charset=utf-8")

# ====== Novas Rotas para Beacon Detection ======

@app.get("/api/beacons/start")
def api_beacons_start():
    """Inicia scan contínuo de beacons"""
    global beacon_scanning
    
    if beacon_scanning:
        return ok({"status": "already_scanning", "message": "Scan já está em andamento"})
    
    duration = int(request.args.get("duration", 10))
    beacon_scanning = True
    
    # Inicia scan em background
    def background_scan():
        async def scan():
            scanner = BleakScanner(
                detection_callback=beacon_detection_callback
            )
            await scanner.start()
            await asyncio.sleep(duration)
            await scanner.stop()
        
        run_async(scan())
    
    threading.Thread(target=background_scan, daemon=True).start()
    
    return ok({
        "status": "started", 
        "duration": duration,
        "message": f"Scan de beacons iniciado por {duration} segundos"
    })

def beacon_detection_callback(device, advertisement_data):
    """Callback para detecção de dispositivos BLE"""
    if beacon_scanning:
        beacon_detector.update_beacon(device, advertisement_data)

@app.get("/api/beacons/stop")
def api_beacons_stop():
    """Para scan de beacons"""
    global beacon_scanning
    beacon_scanning = False
    
    return ok({
        "status": "stopped",
        "message": "Scan de beacons parado",
        "beacons_found": len(beacon_detector.beacons)
    })

@app.post("/api/beacons/clear")
def api_beacons_clear():
    """Limpa lista de beacons"""
    beacon_detector.beacons.clear()
    return ok({"status": "cleared", "message": "Lista de beacons limpa"})

@app.get("/api/beacons/list")
def api_beacons_list():
    """Retorna lista de beacons detectados"""
    beacons_list = []
    current_time = time.time()
    
    for address, beacon in beacon_detector.beacons.items():
        beacons_list.append({
            "address": beacon.address,
            "name": beacon.name,
            "rssi": beacon.rssi,
            "tx_power": beacon.tx_power,
            "uuid": beacon.uuid,
            "major": beacon.major,
            "minor": beacon.minor,
            "company": beacon.company,
            "beacon_type": beacon.beacon_type,
            "first_seen": beacon.first_seen,
            "last_seen": beacon.last_seen,
            "packet_count": beacon.packet_count,
            "age_seconds": round(current_time - beacon.last_seen, 1)
        })
    
    # Remove beacons antigos (mais de 5 minutos)
    old_beacons = [
        addr for addr, beacon in beacon_detector.beacons.items()
        if current_time - beacon.last_seen > 300
    ]
    for addr in old_beacons:
        del beacon_detector.beacons[addr]
    
    return ok({
        "beacons": sorted(beacons_list, key=lambda x: x["last_seen"], reverse=True),
        "total_beacons": len(beacons_list),
        "scanning": beacon_scanning
    })

# ====== Rotas para Serial Bluetooth Corrigidas ======

@app.post("/api/serial/connect")
def api_serial_connect():
    """Conecta a um dispositivo Bluetooth via RFCOMM"""
    global serial_connected, serial_reader_thread
    
    body = request.get_json(force=True, silent=True) or {}
    address = body.get("address", "").strip().upper()
    channel = int(body.get("channel", 1))
    pin = body.get("pin", "1234")
    baudrate = body.get("baudrate", "9600")
    
    if not address:
        return err("Endereço Bluetooth é obrigatório")
    
    if not re.match(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$', address):
        return err("Formato de endereço Bluetooth inválido")
    
    try:
        # Primeiro tenta parear
        paired = pair_and_trust_device(address, pin)
        if not paired:
            print("Pareamento falhou, tentando RFCOMM mesmo assim...")
        
        # Conectar via RFCOMM
        success = connect_rfcomm(address, channel)
        if success:
            serial_connected = True
            
            # Inicia thread de leitura serial
            serial_reader_thread = threading.Thread(target=serial_reader, daemon=True)
            serial_reader_thread.start()
            
            return ok({
                "status": "connected",
                "address": address,
                "channel": channel,
                "baudrate": baudrate,
                "port": "/dev/rfcomm0",
                "message": f"Conectado a {address} via RFCOMM0"
            })
        else:
            return err(f"Falha ao conectar a {address} via RFCOMM", 500)
    except Exception as e:
        return err(f"Erro na conexão serial: {e}", 500)

@app.post("/api/serial/disconnect")
def api_serial_disconnect():
    """Desconecta a porta RFCOMM"""
    global serial_connected, serial_connection
    
    try:
        success = disconnect_rfcomm()
        serial_connected = False
        
        # Fecha conexão serial se existir
        if serial_connection and serial_connection.is_open:
            serial_connection.close()
            serial_connection = None
        
        return ok({"status": "disconnected", "message": "RFCOMM0 desconectado"})
    except Exception as e:
        return err(f"Erro ao desconectar: {e}", 500)

@app.get("/api/serial/status")
def api_serial_status():
    """Verifica status da conexão serial"""
    try:
        connected, message = check_rfcomm_connection()
        return ok({
            "connected": connected,
            "message": message,
            "port_exists": os.path.exists('/dev/rfcomm0')
        })
    except Exception as e:
        return err(f"Erro ao verificar status: {e}", 500)

@app.post("/api/serial/send")
def api_serial_send():
    """Envia dados para dispositivo serial Bluetooth"""
    body = request.get_json(force=True, silent=True) or {}
    command = body.get("command", "").strip()
    baudrate = int(body.get("baudrate", 9600))
    
    if not command:
        return err("Comando é obrigatório")
    
    try:
        success, message = send_serial_data(command, '/dev/rfcomm0', baudrate)
        
        if success:
            return ok({
                "sent": command,
                "status": "sent"
            })
        else:
            return err(message, 500)
        
    except Exception as e:
        return err(f"Erro ao enviar comando: {e}", 500)

@app.get("/api/serial/messages")
def api_serial_messages():
    """Retorna mensagens recebidas da serial"""
    global serial_messages
    
    # Retorna mensagens e limpa a lista
    messages = serial_messages.copy()
    serial_messages.clear()
    
    return ok({
        "messages": messages,
        "count": len(messages)
    })

# ====== Rotas Corrigidas ======

@app.get("/api/scan/bluetoothctl")
def api_scan_bluetoothctl():
    """Scan Bluetooth classic usando bluetoothctl com mais informações"""
    wait_time = int(request.args.get("wait_time", 5))
    try:
        devices = list_bluetooth_improved(wait_time)
        return ok({
            "method": "bluetoothctl",
            "wait_time": wait_time,
            "devices_found": len(devices),
            "devices": devices
        })
    except Exception as e:
        return err(f"Erro no scan bluetoothctl: {e}", 500)

@app.get("/api/scan/classic")
def api_scan_classic():
    """Scan Bluetooth classic usando bluetoothctl (alternativa)"""
    duration = int(request.args.get("duration", 8))
    try:
        devices = list_bluetooth_improved(duration)
        return ok({
            "method": "bluetoothctl",
            "duration": duration,
            "devices_found": len(devices),
            "devices": devices
        })
    except Exception as e:
        return err(f"Erro no scan classic: {e}", 500)

@app.post("/api/flood/start")
def api_flood_start():
    """Inicia flood attack com monitoramento"""
    global flood_threads, flood_running
    
    if flood_running:
        return err("Flood já está em execução. Pare primeiro.")
    
    body = request.get_json(force=True, silent=True) or {}
    target = body.get("target", "").strip().upper()
    packet_size = int(body.get("packet_size", 600))
    threads = int(body.get("threads", 3))
    
    if not target:
        return err("Endereço target é obrigatório")
    
    if not re.match(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$', target):
        return err("Formato de endereço Bluetooth inválido. Use: AA:BB:CC:DD:EE:FF")
    
    if threads > 10:
        return err("Número máximo de threads é 10 por segurança")
    
    try:
        flood_running = True
        flood_threads = flood_attack(target, packet_size, threads)
        
        return ok({
            "status": "started",
            "target": target,
            "packet_size": packet_size,
            "threads": threads,
            "message": f"Flood attack iniciado com {threads} threads",
            "monitoring": "Use o botão Status para verificar o progresso"
        })
        
    except Exception as e:
        flood_running = False
        return err(f"Erro ao iniciar flood: {e}", 500)

@app.post("/api/flood/stop")
def api_flood_stop():
    """Para flood attack"""
    global flood_running
    
    if not flood_running:
        return err("Nenhum flood em execução")
    
    try:
        # Kill all l2ping processes
        subprocess.run(['pkill', '-f', 'l2ping'], check=False, timeout=10)
        time.sleep(2)
        
        # Force kill if still running
        subprocess.run(['pkill', '-9', '-f', 'l2ping'], check=False, timeout=5)
    except Exception as e:
        print(f"Erro ao parar l2ping: {e}")
    
    flood_running = False
    flood_threads = []
    
    return ok({
        "status": "stopped",
        "message": "Flood attack parado",
        "threads_terminated": True
    })

@app.get("/api/flood/status")
def api_flood_status():
    """Retorna status do flood attack"""
    try:
        # Check if l2ping processes are running
        result = subprocess.run(
            ['pgrep', '-f', 'l2ping'],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        processes_running = bool(result.stdout.strip())
        
        return ok({
            "flood_running": flood_running,
            "processes_active": processes_running,
            "active_threads": len([t for t in flood_threads if t.is_alive()]) if flood_threads else 0,
            "message": "Flood ativo" if processes_running else "Flood inativo"
        })
    except Exception as e:
        return err(f"Erro ao verificar status: {e}", 500)

@app.get("/api/hci")
def api_hci():
    """Retorna info básica do adaptador"""
    adapter = request.args.get("adapter", "hci0")
    info: Dict[str, Any] = {"adapter": adapter}
    
    # Check if adapter exists
    base = f"/sys/class/bluetooth/{adapter}"
    info["exists"] = os.path.exists(base)
    
    try:
        with open(os.path.join(base, "address"), "r") as f:
            info["address"] = f.read().strip()
    except Exception:
        info["address"] = "Não disponível"
    
    # Get detailed info using hciconfig
    import subprocess, shlex
    def run(cmd):
        try:
            p = subprocess.run(shlex.split(cmd), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=10)
            return p.stdout.strip()
        except Exception as e:
            return f"erro: {e}"
    
    info["hciconfig"] = run("hciconfig -a")
    info["hciconfig_hci0"] = run("hciconfig hci0")
    info["btmgmt_info"] = run(f"btmgmt -i {adapter} info")
    info["bluetooth_status"] = run("systemctl status bluetooth --no-pager")
    
    return ok(info)

@app.post("/api/hci/restart")
def api_hci_restart():
    """Reinicia serviço Bluetooth"""
    try:
        result = subprocess.run(
            ["sudo", "systemctl", "restart", "bluetooth"],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        return ok({
            "status": "restarted",
            "message": "Serviço Bluetooth reiniciado",
            "output": result.stdout,
            "error": result.stderr
        })
    except Exception as e:
        return err(f"Erro ao reiniciar Bluetooth: {e}", 500)

@app.get("/api/scan/ble")
def api_scan_ble():
    """Scan BLE com bleak corrigido"""
    if BleakScanner is None:
        return err("bleak não instalado ou indisponível. pip install bleak", 500)
    
    timeout = float(request.args.get("timeout", 10))
    
    async def _scan():
        try:
            devices = await BleakScanner.discover(timeout=timeout)
            out = []
            for d in devices:
                out.append({
                    "address": d.address,
                    "name": d.name or "Unknown",
                    "rssi": d.rssi,
                    "details": str(d.details) if hasattr(d, 'details') else "",
                    "metadata": str(d.metadata) if hasattr(d, 'metadata') else {}
                })
            return out
        except Exception as e:
            print(f"BLE scan error: {e}")
            return []

    try:
        res = run_async(_scan())
        return ok({
            "timeout": timeout,
            "devices_found": len(res),
            "devices": res
        })
    except Exception as e:
        return err(f"Falha no scan BLE: {e}", 500)

# ====== Main ======
if __name__ == "__main__":
    print("Iniciando Bluetooth Lab com Terminal Serial em Tempo Real...")
    print("Acesse: http://localhost:5001")
    app.run(host="0.0.0.0", port=5001, debug=False)
EOF


tee /etc/systemd/system/mirako-bluetooth.service >/dev/null <<'EOF'
[Unit]
Description=Mirako Bluetooth Flask Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/mirako_web/
ExecStart=/usr/bin/python3 /opt/mirako_web/bluetooth.py
Restart=always
RestartSec=5
Environment=PORT=5001

[Install]
WantedBy=multi-user.target
EOF



    
sudo systemctl daemon-reload
sudo systemctl enable --now mirako-bluetooth
sudo systemctl restart mirako-bluetooth 
sudo systemctl status mirako-bluetooth --no-pager
# logs em tempo real
sudo journalctl -u mirako-bluetooth -f


