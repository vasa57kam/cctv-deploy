#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    log_error "Запустите от root: sudo bash install.sh"
    exit 1
fi

if [ -f .env ]; then
    source .env
else
    log_warn ".env не найден, значения по умолчанию"
    ADMIN_USERNAME="admin"
    ADMIN_PASSWORD="admin123"
    SECRET_KEY=$(openssl rand -hex 32 2>/dev/null || echo "change-me")
fi

INSTALL_DIR="${INSTALL_DIR:-/opt/cctv}"
FLASK_PORT="${FLASK_PORT:-8077}"
NGINX_PORT="${NGINX_PORT:-80}"

log_info "=== Развёртывание CCTV Cloud ==="

# Системные пакеты
log_info "=== Системные пакеты ==="
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip ffmpeg nginx git curl sqlite3 > /dev/null 2>&1
log_info "Установлены"

# Репозиторий
log_info "=== Репозиторий ==="
if [ ! -d "$INSTALL_DIR/.git" ]; then
    if [ -d "$INSTALL_DIR" ]; then
        log_warn "$INSTALL_DIR существует, но не git-репо"
    else
        git clone https://github.com/vasa57kam/cctv-deploy.git "$INSTALL_DIR"
    fi
fi
cd "$INSTALL_DIR"
git pull || log_warn "git pull не удался"

# Venv
log_info "=== Python venv ==="
if [ ! -d "$INSTALL_DIR/venv" ]; then
    python3 -m venv "$INSTALL_DIR/venv"
fi
source "$INSTALL_DIR/venv/bin/activate"
pip install --upgrade pip -q

# ВАЖНО: без подавления ошибок!
if [ -f "$INSTALL_DIR/requirements.txt" ]; then
    pip install -r "$INSTALL_DIR/requirements.txt"
else
    log_error "requirements.txt не найден!"
    exit 1
fi
log_info "Python пакеты установлены"

# .env
log_info "=== .env ==="
if [ ! -f "$INSTALL_DIR/.env" ]; then
    cat > "$INSTALL_DIR/.env" <<EOF
ADMIN_USERNAME=$ADMIN_USERNAME
ADMIN_PASSWORD=$ADMIN_PASSWORD
SECRET_KEY=$SECRET_KEY
FLASK_PORT=$FLASK_PORT
EOF
    log_info "Создан .env"
else
    log_info ".env уже есть"
fi
source "$INSTALL_DIR/.env"

# Папки
log_info "=== Папки ==="
mkdir -p "$INSTALL_DIR/app/static"
mkdir -p "$INSTALL_DIR/storage/{live,archive,logs,previews,exports,cuts}"
mkdir -p "$INSTALL_DIR/backup"
log_info "Готово"

# Миграция
log_info "=== Миграция БД ==="
"$INSTALL_DIR/venv/bin/python" "$INSTALL_DIR/migrate/migrate.py"
log_info "Готово"

# Systemd
log_info "=== Systemd сервисы ==="

cat > /etc/systemd/system/cctv-web.service <<EOF
[Unit]
Description=CCTV Flask web
After=network.target

[Service]
Type=notify
User=root
WorkingDirectory=$INSTALL_DIR/app
Environment="PATH=$INSTALL_DIR/venv/bin"
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/venv/bin/gunicorn -w 1 -b 127.0.0.1:$FLASK_PORT --timeout 120 app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/cctv-worker.service <<EOF
[Unit]
Description=CCTV worker
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
Environment="PATH=$INSTALL_DIR/venv/bin"
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/worker/worker.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/cctv-billing.service <<EOF
[Unit]
Description=CCTV billing
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
Environment="PATH=$INSTALL_DIR/venv/bin"
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/billing/billing.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/cctv-browserd.service <<EOF
[Unit]
Description=CCTV browser daemon
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
Environment="PATH=$INSTALL_DIR/venv/bin"
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/browserd/browserd.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cctv-web cctv-worker cctv-billing cctv-browserd
log_info "Готово"

# Nginx
log_info "=== Nginx ==="
cat > /etc/nginx/sites-available/cctv <<EOF
server {
    listen $NGINX_PORT;
    server_name _;
    client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:$FLASK_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }

    location /live/ {
        proxy_pass http://127.0.0.1:$FLASK_PORT;
        proxy_buffering off;
        proxy_cache off;
    }

    location /archive/ {
        proxy_pass http://127.0.0.1:$FLASK_PORT;
        proxy_buffering off;
        proxy_cache off;
    }

    location /thumb/ {
        proxy_pass http://127.0.0.1:$FLASK_PORT;
        proxy_buffering off;
    }

    location /static/ {
        alias $INSTALL_DIR/app/static/;
        expires 1y;
    }
}
EOF

ln -sf /etc/nginx/sites-available/cctv /etc/nginx/sites-enabled/cctv
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
log_info "Готово"

# Запуск
log_info "=== Запуск ==="
systemctl restart cctv-web cctv-worker cctv-billing cctv-browserd
sleep 3

# Проверка
log_info "=== Проверка ==="
for svc in cctv-web cctv-worker cctv-billing cctv-browserd; do
    if systemctl is-active --quiet $svc; then
        log_info "✓ $svc работает"
    else
        log_error "✗ $svc не запустился"
        journalctl -u $svc -n 10 --no-pager
    fi
done

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$FLASK_PORT/login 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    log_info "✓ Сайт отвечает (код $HTTP_CODE)"
else
    log_error "✗ Сайт не отвечает (код $HTTP_CODE)"
fi

IP=$(hostname -I | awk '{print $1}')
log_info "=== Готово ==="
log_info "Админка: http://$IP:$NGINX_PORT/admin"
log_info "Логин: $ADMIN_USERNAME"
log_info "Пароль: $ADMIN_PASSWORD"