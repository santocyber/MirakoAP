# Instalar dependências necessárias
sudo apt install -y python3 python3-pip python3-venv python3-dev \
    git build-essential libyaml-dev libffi-dev libssl-dev \
    libjpeg-dev zlib1g-dev avrdude nodejs npm build-essential libssl-dev libffi-dev
    
    sudo npm install -g cncjs --unsafe-perm




cat > /etc/systemd/system/cncjs.service <<'UNIT'

[Unit]
Description=CNCjs server
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/cncjs --port 8000
WorkingDirectory=/root/
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT




sudo systemctl daemon-reload
sudo systemctl enable cncjs
sudo systemctl start cncjs
sudo systemctl status cncjs



sudo apt install linuxcnc-uspace



pip install octoprint --break-system-packages

# Instalar dependências adicionais
pip install pillow --no-binary :all:


octoprint serve --port 8001 --iknowwhatimdoing












cat > /etc/systemd/system/octoprint.service <<'UNIT'
[Unit]
Description=OctoPrint CNC Service
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/octoprint serve --port 8001 --iknowwhatimdoing
WorkingDirectory=/root/
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# Configurações de segurança

# MUITO IMPORTANTE: NÃO isolar /dev nem devices
PrivateDevices=no
PrivateTmp=no
ProtectSystem=off
ProtectHome=off
DevicePolicy=auto
# Se tiver systemd mais novo, pode forçar:
# DeviceAllow=char-usb_device rw

ReadWritePaths=/root/.octoprint

[Install]
WantedBy=multi-user.target
UNIT


# Recarregar systemd
sudo systemctl daemon-reload

# Habilitar inicialização automática
sudo systemctl enable octoprint

# Iniciar serviço
sudo systemctl restart octoprint

# Verificar status
sudo systemctl status octoprint





sudo apt install -y build-essential pkg-config libusb-1.0-0-dev

mkdir laserweb
cd laserweb
git clone https://github.com/LaserWeb/lw.comm-server.git
cd lw.comm-server
sudo npm install serialport --unsafe-perm --build-from-source
sudo npm install




cat > /etc/systemd/system/lw-comm-server.service <<'UNIT'
[Unit]
Description=LW Comm Server Node.js Application
Documentation=https://example.com
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/lw.comm-server
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=lw-comm-server
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
UNIT



sudo systemctl enable lw-comm-server.service

sudo systemctl start lw-comm-server.service

journalctl -u lw-comm-server.service -f








