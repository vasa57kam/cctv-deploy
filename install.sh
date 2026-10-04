#!/bin/bash
set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Проверка root
if [ "$EUID" -ne 0 ]; then
    log_error "Запустите скрипт от root: sudo bash install.sh"
    exit 1
fi

# Проверка ОС
if ! grep -qi 'ubuntu\|debian' /etc/os-release; then
    log_warn "Скрипт тестировался на Ubuntu/Debian. На других ОС могут быть проблемы."
fi

# Загрузка .env если есть
if [ -f .env ]; then
    source .env
else
    log_warn ".env не найден, используются значения по умолчанию"
    ADMIN_USERNAME="admin"
    ADMIN_PASSWORD="admin123"
    SECRET_KEY=$(openssl rand -hex 32)
    DOMAIN=""
    PORT=80
fi

# Параметры по умолчанию
INSTALL_DIR="${INSTALL_DIR:-/opt/cctv}"
REPO_URL="${REPO_URL:-https://github.com/vasa57kam/cctv-deploy.git}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
NGINX_PORT="${NGINX_PORT:-80}"
FLASK_PORT="${FLASK_PORT:-8077}"
BROWSERD_PORT="${BROWSERD_PORT:-8099}"

log_info "=== Развёртывание CCTV Cloud ==="
log_info "Установка в: $INSTALL_DIR"
log_info "Python: $PYTHON_BIN"
log_info "Nginx порт: $NGINX_PORT"
log_info "Flask порт: $FLASK_PORT"

# 1. Системные зависимости
log_info "=== Установка системных пакетов ==="
apt-get update -qq
apt-get install -y -qq \
    python3 python3-venv python3-pip \
    ffmpeg nginx git curl wget \
    sqlite3 \
    > /dev/null 2>&1
log_info "Системные пакеты установлены"

# 2. Клонирование/обновление репозитория
log_info "=== Работа с репозиторием ==="
if [ -d "$INSTALL_DIR" ]; then
    if [ -d "$INSTALL_DIR/.git" ]; then
        cd "$INSTALL_DIR"
        git pull || log_warn "git pull не удался, продолжаем с текущей версией"
    else
        log_error "$INSTALL_DIR существует, но не является git-репозиторием"
        exit 1
    fi
else
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# 3. Виртуальное окружение
log_info "=== Python виртуальное окружение ==="
if [ ! -d "$INSTALL_DIR/venv" ]; then
    $PYTHON_BIN -m venv "$INSTALL_DIR/venv"
fi
source "$INSTALL_DIR/venv/bin/activate"
pip install --upgrade pip -q
pip install -r "$INSTALL_DIR/requirements.txt" -q
log_info "Python пакеты установлены"

# 4. Создание .env
log_info "=== Настройка .env ==="
if [ ! -f "$INSTALL_DIR/.env" ]; then
    cat > "$INSTALL_DIR/.env" <<EOF
ADMIN_USERNAME=$ADMIN_USERNAME
ADMIN_PASSWORD=$ADMIN_PASSWORD
SECRET_KEY=$SECRET_KEY
DOMAIN=$DOMAIN
FLASK_PORT=$FLASK_PORT
BROWSERD_PORT=$BROWSERD_PORT
EOF
    log_info "Создан .env с настройками по умолчанию"
else
    log_info ".env уже существует, не перезаписываем"
fi
source "$INSTALL_DIR/.env"

# 5. Структура папок
log_info "=== Создание папок ==="
mkdir -p "$INSTALL_DIR/app/static"
mkdir -p "$INSTALL_DIR/storage/{live,archive,logs,previews,exports,cuts}"
mkdir -p "$INSTALL_DIR/backup"
chown -R www-data:www-data "$INSTALL_DIR/storage" 2>/dev/null || true
log_info "Папки созданы"

# 6. Миграция БД
log_info "=== Миграция базы данных ==="
cd "$INSTALL_DIR"
$INSTALL_DIR/venv/bin/python "$INSTALL_DIR/migrate/migrate.py"
log_info "Миграция завершена"

# 7. Systemd сервисы
log_info "=== Настройка systemd сервисов ==="

# cctv-web
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
ExecStart=$INSTALL_DIR/venv/bin/gunicorn -w 2 -b 127.0.0.1:$FLASK_PORT --timeout 120 app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# cctv-worker
cat > /etc/systemd/system/cctv-worker.service <<EOF
[Unit]
Description=CCTV worker (ffmpeg)
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

# cctv-billing
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

# cctv-browserd
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
log_info "Systemd сервисы настроены"

# 8. Nginx
log_info "=== Настройка Nginx ==="
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
        proxy_cache off;
    }

    location /static/ {
        alias $INSTALL_DIR/app/static/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
EOF

ln -sf /etc/nginx/sites-available/cctv /etc/nginx/sites-enabled/cctv
nginx -t && systemctl reload nginx
log_info "Nginx настроен"

# 9. Запуск сервисов
log_info "=== Запуск сервисов ==="
systemctl restart cctv-web cctv-worker cctv-billing cctv-browserd
sleep 3

# 10. Проверка
log_info "=== Проверка ==="
if systemctl is-active --quiet cctv-web; then
    log_info "✓ cctv-web работает"
else
    log_error " cctv-web не запустился"
    journalctl -u cctv-web -n 20 --no-pager
fi

if systemctl is-active --quiet cctv-worker; then
    log_info "✓ cctv-worker работает"
else
    log_error "✗ cctv-worker не запустился"
    journalctl -u cctv-worker -n 20 --no-pager
fi

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$FLASK_PORT/login 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    log_info "✓ Сайт отвечает (код $HTTP_CODE)"
else
    log_error "✗ Сайт не отвечает (код $HTTP_CODE)"
fi

log_info "=== Развёртывание завершено ==="
log_info "Админка: http://$(hostname -I | awk '{print $1}'):$NGINX_PORT/admin"
log_info "Логин: $ADMIN_USERNAME"
log_info "Пароль: $ADMIN_PASSWORD"
log_info ""
log_info "Полезные команды:"
log_info "  journalctl -u cctv-web -f          # логи веб-сервера"
log_info "  journalctl -u cctv-worker -f       # логи воркера"
log_info "  systemctl restart cctv-web         # перезапуск веб"
log_info "  cd $INSTALL_DIR && git pull && bash install.sh  # обновление"
