#!/bin/bash
set -e
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
[ "$EUID" -ne 0 ] && { log_error "Запусти от root"; exit 1; }
[ -f .env ] && source .env
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin123}"
SECRET_KEY="${SECRET_KEY:-$(openssl rand -hex 32 2>/dev/null || echo change-me)}"
INSTALL_DIR="${INSTALL_DIR:-/opt/cctv}"
FLASK_PORT="${FLASK_PORT:-8077}"
NGINX_PORT="${NGINX_PORT:-80}"
log_info "=== Развёртывание CCTV Cloud ==="
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip ffmpeg nginx git curl sqlite3 >/dev/null 2>&1
log_info "Системные пакеты установлены"
if [ ! -d "$INSTALL_DIR/.git" ]; then
    [ -d "$INSTALL_DIR" ] || git clone https://github.com/vasa57kam/cctv-deploy.git "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"; git pull || true
[ -d venv ] || python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip -q
pip install -r requirements.txt
log_info "Python пакеты установлены"
[ -f .env ] || cat > .env <<ENVEOF
ADMIN_USERNAME=$ADMIN_USERNAME
ADMIN_PASSWORD=$ADMIN_PASSWORD
SECRET_KEY=$SECRET_KEY
FLASK_PORT=$FLASK_PORT
ENVEOF
source .env
mkdir -p app/static storage/{live,archive,logs,previews,exports,cuts} backup billing browserd
venv/bin/python migrate/migrate.py
PATHENV="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$INSTALL_DIR/venv/bin"
cat > /etc/systemd/system/cctv-web.service <<SEOF
[Unit]
Description=CCTV Flask web
After=network.target
[Service]
Type=notify
User=root
WorkingDirectory=$INSTALL_DIR/app
Environment="$PATHENV"
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/venv/bin/gunicorn -w 1 -b 127.0.0.1:$FLASK_PORT --timeout 120 app:app
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
SEOF
cat > /etc/systemd/system/cctv-worker.service <<SEOF
[Unit]
Description=CCTV worker
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
Environment="$PATHENV"
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/worker/worker.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
SEOF
cat > /etc/systemd/system/cctv-billing.service <<SEOF
[Unit]
Description=CCTV billing
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
Environment="$PATHENV"
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/billing/billing.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
SEOF
systemctl daemon-reload
systemctl enable cctv-web cctv-worker cctv-billing
cat > /etc/nginx/sites-available/cctv <<NEOF
server {
    listen $NGINX_PORT;
    server_name _;
    client_max_body_size 100M;
    location / {
        proxy_pass http://127.0.0.1:$FLASK_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
    }
    location /live/ { proxy_pass http://127.0.0.1:$FLASK_PORT; proxy_buffering off; }
    location /archive/ { proxy_pass http://127.0.0.1:$FLASK_PORT; proxy_buffering off; }
    location /thumb/ { proxy_pass http://127.0.0.1:$FLASK_PORT; proxy_buffering off; }
    location /static/ { alias $INSTALL_DIR/app/static/; expires 1y; }
}
NEOF
ln -sf /etc/nginx/sites-available/cctv /etc/nginx/sites-enabled/cctv
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
systemctl restart cctv-web cctv-worker cctv-billing
sleep 3
for s in cctv-web cctv-worker cctv-billing; do
    systemctl is-active --quiet $s && log_info "$s: OK" || { log_error "$s: FAIL"; journalctl -u $s -n 10 --no-pager; }
done
IP=$(hostname -I | awk '{print $1}')
log_info "Админка: http://$IP:$NGINX_PORT/admin (логин $ADMIN_USERNAME)"
