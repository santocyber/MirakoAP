# Instalar dependências necessárias
sudo apt install -y python3 python3-pip python3-venv python3-dev \
    git build-essential libyaml-dev libffi-dev libssl-dev \
    libjpeg-dev zlib1g-dev avrdude nodejs npm
    
    sudo npm install -g cncjs --unsafe-perm




cat > /etc/systemd/system/cncjs.service <<'UNIT'

[Unit]
Description=CNCjs server
After=network.target

[Service]
Type=simple
User=cncjs
Group=cncjs
ExecStart=/usr/bin/cncjs --port 8000
WorkingDirectory=/home/cncjs
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT




sudo systemctl daemon-reload
sudo systemctl enable cncjs
sudo systemctl start cncjs




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
WorkingDirectory=/usr/local/bin/
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# Configurações de segurança
NoNewPrivileges=yes
ProtectSystem=strict
PrivateTmp=yes
ReadWritePaths=/usr/local/bin/.octoprint

[Install]
WantedBy=multi-user.target
UNIT


# Recarregar systemd
sudo systemctl daemon-reload

# Habilitar inicialização automática
sudo systemctl enable octoprint

# Iniciar serviço
sudo systemctl start octoprint

# Verificar status
sudo systemctl status octoprint





