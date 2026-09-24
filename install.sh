#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="/opt/cctv"
VERSION="4.0"
[[ $EUID -ne 0 ]] && { echo "Запусти от root"; exit 1; }
echo "=== CCTV install v$VERSION из $REPO ==="
systemctl stop cctv-web cctv-worker cctv-billing cctv-browserd 2>/dev/null || true
mkdir -p "$BASE/app/templates" "$BASE/app/static" "$BASE/worker" "$BASE/backup" \
  "$BASE/storage/live" "$BASE/storage/archive" "$BASE/storage/logs" \
  "$BASE/storage/previews" "$BASE/storage/exports"
export DEBIAN_FRONTEND=noninteractive
echo "=== Пакеты ==="
apt-get update || echo "WARNING: apt update с ошибками"
apt-get install -y python3 python3-venv python3-pip ffmpeg nginx sqlite3 openssl git
id -u cctv &>/dev/null || useradd --system --home-dir "$BASE" --shell /usr/sbin/nologin cctv
echo "=== Бэкапы ==="
if [ -f "$BASE/app/cctv.db" ]; then
  cp -a "$BASE/app/cctv.db" "$BASE/backup/cctv-$(date +%Y%m%d-%H%M%S).db"
  ls -1t "$BASE/backup"/cctv-*.db 2>/dev/null | tail -n +8 | xargs -r rm -f
  echo "бэкап базы ok"
fi
if [ -f "$BASE/.env" ]; then
  cp -a "$BASE/.env" "$BASE/backup/env-$(date +%Y%m%d-%H%M%S)"
  ls -1t "$BASE/backup"/env-* 2>/dev/null | tail -n +8 | xargs -r rm -f
fi
echo "=== Копирование файлов ==="
cp -f "$REPO/app/app.py" "$BASE/app/app.py"
cp -f "$REPO/app/templates/"*.html "$BASE/app/templates/"
cp -f "$REPO/app/static/manifest.json" "$BASE/app/static/manifest.json"
cp -f "$REPO/worker/worker.py" "$REPO/worker/billing.py" "$REPO/worker/browserd.py" "$BASE/worker/"
cp -f "$REPO/requirements.txt" "$BASE/app/requirements.txt"
cp -f "$REPO/units/cctv-web.service" "$REPO/units/cctv-worker.service" \
      "$REPO/units/cctv-billing.service" "$REPO/units/cctv-browserd.service" /etc/systemd/system/
echo "=== Иконки PWA ==="
python3 - "$BASE/app/static" <<'PYPNG'
import sys, struct, zlib
def png(sz, path):
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    raw = b""
    for y in range(sz):
        raw += b"\x00" + bytes([56, 189, 248]) * sz
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", sz, sz, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
d = sys.argv[1]
png(192, f"{d}/icon-192.png"); png(512, f"{d}/icon-512.png")
PYPNG
echo "=== .env ==="
if [ ! -f "$BASE/.env" ]; then
  ADMIN_PASSWORD=$(openssl rand -hex 8); SECRET_KEY=$(openssl rand -hex 32)
  printf 'SECRET_KEY=%s\nADMIN_USERNAME=admin\nADMIN_PASSWORD=%s\n' "$SECRET_KEY" "$ADMIN_PASSWORD" > "$BASE/.env"
  chmod 600 "$BASE/.env"
  echo "Admin password: $ADMIN_PASSWORD" > "$BASE/admin_password.txt"
  chmod 600 "$BASE/admin_password.txt"
  echo "пароль админа сохранён в $BASE/admin_password.txt"
else
  echo ".env уже есть — не трогаем"
fi
echo "=== venv и зависимости ==="
[ -f "$BASE/venv/bin/activate" ] || python3 -m venv "$BASE/venv"
"$BASE/venv/bin/pip" install --upgrade pip
"$BASE/venv/bin/pip" install -r "$BASE/app/requirements.txt"
"$BASE/venv/bin/python" -m playwright install --with-deps chromium 2>/dev/null \
  || "$BASE/venv/bin/python" -m playwright install chromium \
  || echo "WARNING: chromium не поставился"
echo "=== Миграция БД ==="
python3 "$REPO/migrate/migrate.py"
chown -R cctv:cctv "$BASE"
echo "=== Освобождение порта 80 ==="
wait_port_free() {
  local n=0
  while [ "$n" -lt "$1" ]; do
    ss -tln | grep -q ':80 ' || return 0
    sleep 1; n=$((n+1))
  done
  ss -tln | grep -q ':80 ' && return 1 || return 0
}
NGINX_LISTEN=80
for i in 1 2 3; do
  if ! ss -tln | grep -q ':80 '; then break; fi
  PID=$(ss -tlnp | grep ':80 ' | grep -oP 'pid=\K[0-9]+' | head -1) || true
  [ -z "$PID" ] && break
  CID=""
  if command -v docker &>/dev/null; then
    CID=$(docker ps -q 2>/dev/null | while read -r c; do
            docker top "$c" 2>/dev/null | awk -v p="$PID" '$2==p{print c; exit}'
          done | head -1) || true
  fi
  if [ -n "$CID" ]; then
    echo "порт 80 держит контейнер $CID — останавливаю"
    docker update --restart=no "$CID" 2>/dev/null || true
    docker stop "$CID" 2>/dev/null || true
    if ! wait_port_free 10; then docker rm -f "$CID" 2>/dev/null || true; wait_port_free 5 || true; fi
  else
    echo "убиваю процесс $PID на порту 80"
    kill -9 "$PID" 2>/dev/null || true
    wait_port_free 5 || true
  fi
done
if ss -tln | grep -q ':80 '; then
  echo "WARNING: 80 занят — ставлю сайт на 8090 (нужен проброс 81->8090)"
  NGINX_LISTEN=8090
fi
echo "=== Nginx ==="
cp -f "$REPO/nginx/cctv.conf" /etc/nginx/sites-available/cctv
sed -i "s/__PORT__/$NGINX_LISTEN/" /etc/nginx/sites-available/cctv
ln -sf /etc/nginx/sites-available/cctv /etc/nginx/sites-enabled/cctv
rm -f /etc/nginx/sites-enabled/default
nginx -t
echo "=== Старт ==="
systemctl daemon-reload
systemctl enable --now cctv-web cctv-worker cctv-billing cctv-browserd
if ! systemctl restart nginx; then
  systemctl kill nginx 2>/dev/null || true; pkill -9 nginx 2>/dev/null || true
  sleep 1; systemctl start nginx
fi
sleep 3
CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$NGINX_LISTEN/login)
DCODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -d '{"cmd":"status"}' http://127.0.0.1:8099/)
echo "сайт: $CODE (ждём 200); демон браузера: $DCODE (ждём 200)"
if [ "$CODE" != "200" ]; then
  echo "!!! сайт не поднялся, логи:"
  journalctl -u cctv-web -n 30 --no-pager || true
  exit 1
fi
echo "$VERSION" > "$BASE/VERSION"; chown cctv:cctv "$BASE/VERSION"
echo "=== ГОТОВО: v$VERSION, порт $NGINX_LISTEN ==="
echo "пароль админа: cat $BASE/admin_password.txt"