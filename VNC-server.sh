


sudo apt install tigervnc-standalone-server tigervnc-common
sudo apt install lxde lxde-core lxsession lxterminal -y


mkdir -p ~/.config/lxsession/LXDE/
mkdir -p ~/.config/lxpanel/LXDE/panels/
mkdir -p ~/.config/openbox/
nano ~/.config/lxsession/LXDE/autostart

@lxpanel --profile LXDE
@pcmanfm --desktop --profile LXDE
@xscreensaver -no-splash
@lxpolkit
@nm-applet
@blueman-applet
@clipit
@xterm
@firefox


nano ~/.vnc/xstartup

#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# Carrega Xresources se existir
if [ -r "$HOME/.Xresources" ]; then
    xrdb "$HOME/.Xresources"
fi

export DESKTOP_SESSION=LXDE
export XDG_CURRENT_DESKTOP=LXDE

# Inicia o LXDE e mantém o processo em foreground
if command -v startlxde >/dev/null 2>&1; then
    exec startlxde
else
    exec startlxsession
fi

chmod +x ~/.vnc/xstartup



sudo nano /etc/systemd/system/vncserver@.service


[Unit]
Description=VNC Server for %i
After=syslog.target network.target

[Service]
Type=forking
User=santocyber
PAMName=login
PIDFile=/home/santocyber/.vnc/%H:%i.pid
ExecStart=/usr/bin/vncserver %i -geometry 1280x720 -depth 24 -localhost no
ExecStop=/usr/bin/vncserver -kill %i

[Install]
WantedBy=multi-user.target






sudo systemctl daemon-reload
sudo systemctl enable vncserver@\:1.service
sudo systemctl start vncserver@\:1.service




