# 1) Instala pacotes necessários (inclui o utilitário de senha)
apt update
apt install -y tigervnc-standalone-server tigervnc-common tigervnc-tools lxde lxde-core lxsession lxterminal dbus-x11 x11-xserver-utils desktop-file-utils xdg-utils firefox-esr network-manager-gnome policykit-1 lxpolkit

# 2) Pastas do root (sem usar ~ com sudo)
mkdir -p /root/.vnc
chmod 700 /root/.vnc

mkdir -p /root/.config/lxsession/LXDE
mkdir -p /root/.config/lxpanel/LXDE/panels
mkdir -p /root/.config/openbox

# 3) Autostart do LXDE (opcional, mas ok)
cat >/root/.config/lxsession/LXDE/autostart <<'EOF'
@lxpanel --profile LXDE
@pcmanfm --desktop --profile LXDE
@xscreensaver -no-splash
@lxpolkit
@nm-applet
@blueman-applet
@clipit
@xterm
@firefox
EOF

# 4) xstartup do VNC (essencial)
cat >/root/.vnc/xstartup <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# Garante runtime dir do root (alguns apps exigem isso)
export XDG_RUNTIME_DIR=/run/user/0
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# Inicia uma sessão DBus limpa e sobe o LXDE
exec dbus-run-session -- startlxde
EOF

chmod +x /root/.vnc/xstartup


# 5) Define a senha do VNC como "qazwsx" (não interativo)
# (Isso grava /root/.vnc/passwd no formato correto)
printf "%s\n%s\n\n" "qazwsx" "qazwsx" | vncpasswd
chmod 600 /root/.vnc/passwd

# 6) Service systemd correto
cat >/etc/systemd/system/vncserver@.service <<'EOF'
[Unit]
Description=TigerVNC server for display :%i
After=network.target

[Service]
Type=forking
User=root
Group=root
WorkingDirectory=/root
PIDFile=/root/.vnc/%H:%i.pid

ExecStartPre=-/usr/bin/vncserver -kill :%i
ExecStart=/usr/bin/vncserver :%i -geometry 1280x720 -depth 24 -localhost no
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOF

# 7) Recarrega e inicia
systemctl daemon-reload
systemctl enable vncserver@1.service
systemctl restart vncserver@1.service

# 8) Debug
systemctl status vncserver@1.service --no-pager -l || true
ls -la /root/.vnc || true
tail -n 200 /root/.vnc/*.log 2>/dev/null || true







