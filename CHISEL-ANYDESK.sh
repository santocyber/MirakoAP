







# Dependências básicas
sudo apt-get update && sudo apt-get install -y curl ca-certificates xz-utils

# Descobre a sua arquitetura e escolhe o asset certo
ARCH=$(dpkg --print-architecture)               # armhf ou arm64
case "$ARCH" in
  arm64)  FILTER="linux_arm64" ;;
  armhf)  FILTER="linux_armv7|linux_arm" ;;     # armv7 (fallback: arm genérico)
  *)      echo "Arquitetura $ARCH não mapeada"; exit 1 ;;
esac

# Busca a URL do .deb (preferência) ou do .gz na última release
URL=$(curl -s https://api.github.com/repos/jpillora/chisel/releases/latest \
  | grep -oP '(?<="browser_download_url": ")[^"]+' \
  | grep -E "chisel_.*_(${FILTER})\.(deb|gz)$" | head -n1)

# Instala (.deb se houver; senão, extrai o .gz)
if echo "$URL" | grep -q '\.deb$'; then
  curl -L "$URL" -o /tmp/chisel.deb && sudo dpkg -i /tmp/chisel.deb || sudo apt -f install -y
else
  curl -L "$URL" -o /tmp/chisel.gz && gunzip -f /tmp/chisel.gz && \
  chmod +x /tmp/chisel && sudo mv /tmp/chisel /usr/local/bin/chisel
fi

# Verifique
chisel -v





tee /etc/systemd/system/chisel-client.service >/dev/null <<'EOF'
[Unit]
Description=Chisel client (reversos: 15000->127.0.0.1:80 e 15001->127.0.0.1:5000)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=orangepi
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"
ExecStart=/usr/bin/env chisel client \
  --keepalive 10s \
  --auth admin:qazwsx \
  chisel.mirako.org:6000 \
  R:0.0.0.0:15000:127.0.0.1:8080 \
  R:0.0.0.0:15001:127.0.0.1:5000 \
  R:0.0.0.0:15002:127.0.0.1:5001 \
  R:0.0.0.0:15003:127.0.0.1:5002
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target


EOF


sudo systemctl daemon-reload
sudo systemctl enable --now chisel-client
sudo systemctl restart chisel-client
journalctl -u chisel-client -f




















##PROXY REVERSO NGINX 

# All server fields such as server | location can be set, such as:
# location /web {
#     try_files $uri $uri/ /index.php$is_args$args;
# }
# error_page 404 /diy_404.html;
# If there is abnormal access to the reverse proxy website and the content has already been configured here, please prioritize checking if the configuration here is correct

# --- Upstreams dinâmicos por Referer (um ponto de verdade) ---
# Fallback (raiz)
set $api_upstream http://127.0.0.1:6000;
set $static_upstream http://127.0.0.1:6000;

# Se a página de origem é /web1/, use 15000
if ($http_referer ~* "/web1/") {
    set $api_upstream http://127.0.0.1:15000;
    set $static_upstream http://127.0.0.1:15000;
}

# Se a página de origem é /cam1/, use 15001
if ($http_referer ~* "/cam1/") {
    set $api_upstream http://127.0.0.1:15001;
    set $static_upstream http://127.0.0.1:15001;
}

# --- OPCIONAL: se os endpoints de gravação forem SEMPRE do cam1 ---
# Coloque ANTES do /api/ geral para ter prioridade
location ^~ /api/record/ {
    proxy_pass http://127.0.0.1:15001;  # cam1
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    client_max_body_size 100m;
}

# --- /api (ÚNICO bloco) ---
location ^~ /api/ {
    proxy_pass $api_upstream;  # mantém /api/... para o app selecionado pelo Referer
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_http_version 1.1;
    proxy_buffering off;             # evita buffering de respostas longas/stream
    proxy_request_buffering off;     # encaminha o body (POST/PUT) sem buffer
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    client_max_body_size 100m;
    # Se usar WebSocket em /api/:
    # proxy_set_header Upgrade $http_upgrade;
    # proxy_set_header Connection "upgrade";
}

# --- Stream de vídeo ---
location ^~ /video_feed {
    proxy_pass $static_upstream;     # preserva query (?dev=/dev/videoX)
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_read_timeout 3600s;
    add_header X-Accel-Buffering no;
    # Se for WebSocket:
    # proxy_set_header Upgrade $http_upgrade;
    # proxy_set_header Connection "upgrade";
}

# --- Imagens/Thumbs ---
location ^~ /media/ {
    proxy_pass $static_upstream;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_buffering off;             # evita atraso em geração on-demand
    expires -1;
    add_header Cache-Control "no-store";
}

# --- Conveniências ---
# Força barra final nas apps (resolve assets relativos)
location = /web1 { return 301 /web1/; }
location = /cam1 { return 301 /cam1/; }

# Redireciona a raiz para /web1/ (ou troque para /cam1/ se preferir)
location = / { return 302 /web1/; }
















