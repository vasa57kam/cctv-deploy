#!/usr/bin/env bash

set -euo pipefail

BASE="/opt/cctv"
APP="$BASE/app"
WORKER="$BASE/worker"
STORAGE="$BASE/storage"

if [[ $EUID -ne 0 ]]; then
    echo "Запусти скрипт через sudo или от root."
    exit 1
fi

echo "=== CCTV MVP auto deploy ==="

mkdir -p "$APP/templates"
mkdir -p "$WORKER"
mkdir -p "$STORAGE/live"
mkdir -p "$STORAGE/archive"
mkdir -p "$STORAGE/logs"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    python3 \
    python3-venv \
    python3-pip \
    ffmpeg \
    nginx \
    sqlite3 \
    openssl

id -u cctv &>/dev/null || useradd \
    --system \
    --home-dir "$BASE" \
    --shell /usr/sbin/nologin \
    cctv

echo "=== Создаём requirements.txt ==="

cat > "$APP/requirements.txt" <<'REQ_EOF'
Flask
Flask-SQLAlchemy
Flask-Login
gunicorn
REQ_EOF

echo "=== Создаём app.py ==="

cat > "$APP/app.py" <<'APP_PY_EOF'
import os
from datetime import datetime
from pathlib import Path
from functools import wraps

from flask import (
    Flask,
    render_template,
    request,
    redirect,
    url_for,
    abort,
    send_from_directory,
    flash,
)
from flask_sqlalchemy import SQLAlchemy
from flask_login import (
    LoginManager,
    UserMixin,
    login_user,
    login_required,
    logout_user,
    current_user,
)
from werkzeug.security import generate_password_hash, check_password_hash


BASE_DIR = Path("/opt/cctv")
STORAGE_DIR = BASE_DIR / "storage"
LIVE_DIR = STORAGE_DIR / "live"
ARCHIVE_DIR = STORAGE_DIR / "archive"
DB_PATH = BASE_DIR / "app" / "cctv.db"

DB_PATH.parent.mkdir(parents=True, exist_ok=True)
LIVE_DIR.mkdir(parents=True, exist_ok=True)
ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)

app = Flask(__name__)
app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", "change-me")
app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{DB_PATH}"
app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
app.config["SQLALCHEMY_ENGINE_OPTIONS"] = {
    "connect_args": {"check_same_thread": False}
}

db = SQLAlchemy(app)

login_manager = LoginManager(app)
login_manager.login_view = "login"


class User(UserMixin, db.Model):
    __tablename__ = "user"

    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    password_hash = db.Column(db.String(255), nullable=False)
    balance = db.Column(db.Float, default=0.0)
    admin = db.Column(db.Boolean, default=False)
    active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    cameras = db.relationship("Camera", backref="owner", lazy=True)
    transactions = db.relationship("Transaction", backref="user", lazy=True)

    @property
    def is_active(self):
        return self.active


class Camera(db.Model):
    __tablename__ = "camera"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    rtsp_url = db.Column(db.Text, nullable=False)
    user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=True)
    active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class Transaction(db.Model):
    __tablename__ = "transaction"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    amount = db.Column(db.Float, nullable=False)
    reason = db.Column(db.String(255))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


@login_manager.user_loader
def load_user(user_id):
    return User.query.get(int(user_id))


def init_db():
    db.create_all()

    admin_username = os.environ.get("ADMIN_USERNAME", "admin")
    admin_password = os.environ.get("ADMIN_PASSWORD", "admin123")

    admin = User.query.filter_by(username=admin_username).first()
    if not admin:
        admin = User(
            username=admin_username,
            password_hash=generate_password_hash(admin_password),
            admin=True,
            active=True,
            balance=0.0,
        )
        db.session.add(admin)
        db.session.commit()


with app.app_context():
    init_db()


def admin_required(f):
    @wraps(f)
    @login_required
    def decorated_function(*args, **kwargs):
        if not current_user.admin:
            abort(403)
        return f(*args, **kwargs)

    return decorated_function


def can_view_camera(camera):
    if current_user.admin:
        return True

    if not camera.active:
        return False

    if camera.user_id != current_user.id:
        return False

    if not current_user.is_active:
        return False

    if current_user.balance <= 0:
        return False

    return True


def get_camera_or_403(camera_id):
    camera = Camera.query.get(camera_id)
    if not camera:
        abort(404)

    if not can_view_camera(camera):
        abort(403)

    return camera


@app.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard"))

    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")

        user = User.query.filter_by(username=username).first()

        if user and check_password_hash(user.password_hash, password):
            if not user.active:
                flash("Аккаунт заблокирован.")
                return render_template("login.html")

            login_user(user)
            return redirect(url_for("dashboard"))

        flash("Неверный логин или пароль.")

    return render_template("login.html")


@app.route("/logout")
@login_required
def logout():
    logout_user()
    return redirect(url_for("login"))


@app.route("/")
@login_required
def dashboard():
    if current_user.admin:
        cameras = Camera.query.order_by(Camera.id.desc()).all()
    else:
        cameras = Camera.query.filter_by(
            user_id=current_user.id,
            active=True,
        ).order_by(Camera.id.desc()).all()

    return render_template("dashboard.html", cameras=cameras)


@app.route("/camera/<int:camera_id>")
@login_required
def camera_page(camera_id):
    camera = get_camera_or_403(camera_id)

    recordings = []
    camera_dir = ARCHIVE_DIR / f"camera_{camera.id}"

    if camera_dir.exists():
        recordings = sorted(
            [item.name for item in camera_dir.glob("*.mp4")],
            reverse=True,
        )[:50]

    return render_template(
        "camera.html",
        camera=camera,
        recordings=recordings,
    )


@app.route("/live/<int:camera_id>/<path:filename>")
@login_required
def live_file(camera_id, filename):
    camera = get_camera_or_403(camera_id)
    directory = str(LIVE_DIR / f"camera_{camera.id}")
    return send_from_directory(directory, filename, conditional=True)


@app.route("/archive/<int:camera_id>/<path:filename>")
@login_required
def archive_file(camera_id, filename):
    camera = get_camera_or_403(camera_id)
    directory = str(ARCHIVE_DIR / f"camera_{camera.id}")
    return send_from_directory(
        directory,
        filename,
        as_attachment=False,
        conditional=True,
    )


@app.route("/admin")
@admin_required
def admin_page():
    users = User.query.order_by(User.id.desc()).all()
    cameras = Camera.query.order_by(Camera.id.desc()).all()
    transactions = Transaction.query.order_by(Transaction.id.desc()).limit(50).all()

    return render_template(
        "admin.html",
        users=users,
        cameras=cameras,
        transactions=transactions,
    )


@app.route("/admin/user/add", methods=["POST"])
@admin_required
def admin_user_add():
    username = request.form.get("username", "").strip()
    password = request.form.get("password", "").strip()

    if not username or not password:
        flash("Укажите логин и пароль.")
        return redirect(url_for("admin_page"))

    exists = User.query.filter_by(username=username).first()
    if exists:
        flash("Такой пользователь уже существует.")
        return redirect(url_for("admin_page"))

    user = User(
        username=username,
        password_hash=generate_password_hash(password),
        active=True,
        admin=False,
        balance=0.0,
    )

    db.session.add(user)
    db.session.commit()

    flash(f"Пользователь {username} создан.")
    return redirect(url_for("admin_page"))


@app.route("/admin/user/<int:user_id>/toggle", methods=["POST"])
@admin_required
def admin_user_toggle(user_id):
    user = User.query.get_or_404(user_id)
    user.active = not user.active
    db.session.commit()

    if user.active:
        flash(f"Пользователь {user.username} разблокирован.")
    else:
        flash(f"Пользователь {user.username} заблокирован.")

    return redirect(url_for("admin_page"))


@app.route("/admin/user/topup", methods=["POST"])
@admin_required
def admin_topup():
    user_id = request.form.get("user_id", "")
    amount_raw = request.form.get("amount", "")
    reason = request.form.get("reason", "").strip()

    try:
        user_id = int(user_id)
        amount = float(amount_raw)
    except ValueError:
        flash("Некорректные данные.")
        return redirect(url_for("admin_page"))

    user = User.query.get_or_404(user_id)

    user.balance += amount

    transaction = Transaction(
        user_id=user.id,
        amount=amount,
        reason=reason or "Ручная корректировка",
    )

    db.session.add(transaction)
    db.session.commit()

    flash(f"Баланс пользователя {user.username} изменён на {amount}.")
    return redirect(url_for("admin_page"))


@app.route("/admin/camera/add", methods=["POST"])
@admin_required
def admin_camera_add():
    name = request.form.get("name", "").strip()
    rtsp_url = request.form.get("rtsp_url", "").strip()
    user_id = request.form.get("user_id", "").strip()

    if not name or not rtsp_url:
        flash("Укажите название камеры и RTSP.")
        return redirect(url_for("admin_page"))

    camera = Camera(
        name=name,
        rtsp_url=rtsp_url,
        active=True,
    )

    if user_id:
        try:
            camera.user_id = int(user_id)
        except ValueError:
            camera.user_id = None

    db.session.add(camera)
    db.session.commit()

    flash(f"Камера {name} добавлена.")
    return redirect(url_for("admin_page"))


@app.route("/admin/camera/<int:camera_id>/assign", methods=["POST"])
@admin_required
def admin_camera_assign(camera_id):
    camera = Camera.query.get_or_404(camera_id)
    user_id = request.form.get("user_id", "").strip()

    if user_id:
        try:
            camera.user_id = int(user_id)
        except ValueError:
            camera.user_id = None
    else:
        camera.user_id = None

    db.session.commit()

    flash("Камера назначена.")
    return redirect(url_for("admin_page"))


@app.route("/admin/camera/<int:camera_id>/toggle", methods=["POST"])
@admin_required
def admin_camera_toggle(camera_id):
    camera = Camera.query.get_or_404(camera_id)
    camera.active = not camera.active
    db.session.commit()

    if camera.active:
        flash(f"Камера {camera.name} включена.")
    else:
        flash(f"Камера {camera.name} выключена.")

    return redirect(url_for("admin_page"))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
APP_PY_EOF

echo "=== Создаём base.html ==="

cat > "$APP/templates/base.html" <<'BASE_HTML_EOF'
<!doctype html>
<html lang="ru">
<head>
    <meta charset="utf-8">
    <title>CCTV MVP</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 20px;
        }
        table {
            border-collapse: collapse;
            margin-bottom: 20px;
        }
        td, th {
            border: 1px solid #ccc;
            padding: 6px 10px;
        }
        nav {
            margin-bottom: 15px;
        }
        nav a {
            margin-right: 10px;
        }
        .messages {
            color: darkred;
            margin-bottom: 10px;
        }
        form.inline {
            display: inline;
        }
    </style>
</head>
<body>

<nav>
    {% if current_user.is_authenticated %}
        <a href="{{ url_for('dashboard') }}">Камеры</a>

        {% if current_user.admin %}
            <a href="{{ url_for('admin_page') }}">Админка</a>
        {% endif %}

        <span>Баланс: {{ "%.2f"|format(current_user.balance) }}</span>
        <a href="{{ url_for('logout') }}">Выход: {{ current_user.username }}</a>
    {% else %}
        <a href="{{ url_for('login') }}">Вход</a>
    {% endif %}
</nav>

<hr>

{% with messages = get_flashed_messages() %}
    {% if messages %}
        <div class="messages">
            <ul>
                {% for message in messages %}
                    <li>{{ message }}</li>
                {% endfor %}
            </ul>
        </div>
    {% endif %}
{% endwith %}

{% block content %}{% endblock %}

</body>
</html>
BASE_HTML_EOF

echo "=== Создаём login.html ==="

cat > "$APP/templates/login.html" <<'LOGIN_HTML_EOF'
{% extends "base.html" %}

{% block content %}
<h1>Вход</h1>

<form method="post" action="{{ url_for('login') }}">
    <p>
        Логин:<br>
        <input type="text" name="username" required>
    </p>

    <p>
        Пароль:<br>
        <input type="password" name="password" required>
    </p>

    <p>
        <button type="submit">Войти</button>
    </p>
</form>
{% endblock %}
LOGIN_HTML_EOF

echo "=== Создаём dashboard.html ==="

cat > "$APP/templates/dashboard.html" <<'DASH_HTML_EOF'
{% extends "base.html" %}

{% block content %}
<h1>Камеры</h1>

{% if not current_user.admin and current_user.balance <= 0 %}
    <p style="color:red;">
        Баланс не пополнен. Доступ к камерам может быть заблокирован.
    </p>
{% endif %}

<table>
    <tr>
        <th>ID</th>
        <th>Название</th>
        <th>Владелец</th>
        <th>Статус</th>
        <th></th>
    </tr>

    {% for camera in cameras %}
    <tr>
        <td>{{ camera.id }}</td>
        <td>{{ camera.name }}</td>
        <td>
            {% if camera.owner %}
                {{ camera.owner.username }}
            {% else %}
                -
            {% endif %}
        </td>
        <td>
            {% if camera.active %}
                активна
            {% else %}
                выключена
            {% endif %}
        </td>
        <td>
            <a href="{{ url_for('camera_page', camera_id=camera.id) }}">Открыть</a>
        </td>
    </tr>
    {% endfor %}
</table>
{% endblock %}
DASH_HTML_EOF

echo "=== Создаём camera.html ==="

cat > "$APP/templates/camera.html" <<'CAMERA_HTML_EOF'
{% extends "base.html" %}

{% block content %}
<h1>{{ camera.name }}</h1>

<h2>Онлайн</h2>

<video id="video" controls autoplay muted width="800"></video>

<script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
<script>
    const video = document.getElementById("video");
    const src = "{{ url_for('live_file', camera_id=camera.id, filename='index.m3u8') }}";

    if (window.Hls && Hls.isSupported()) {
        const hls = new Hls();
        hls.loadSource(src);
        hls.attachMedia(video);

        hls.on(Hls.Events.ERROR, function(event, data) {
            console.error("HLS error:", data);
        });
    } else {
        video.src = src;
    }
</script>

<h2>Архив</h2>

{% if recordings %}
    <ul>
        {% for record in recordings %}
            <li>
                <a href="{{ url_for('archive_file', camera_id=camera.id, filename=record) }}" target="_blank">
                    {{ record }}
                </a>
            </li>
        {% endfor %}
    </ul>
{% else %}
    <p>Архив пока пуст или запись ещё не началась.</p>
{% endif %}

{% endblock %}
CAMERA_HTML_EOF

echo "=== Создаём admin.html ==="

cat > "$APP/templates/admin.html" <<'ADMIN_HTML_EOF'
{% extends "base.html" %}

{% block content %}
<h1>Админка</h1>

<h2>Пользователи</h2>

<table>
    <tr>
        <th>ID</th>
        <th>Логин</th>
        <th>Баланс</th>
        <th>Админ</th>
        <th>Статус</th>
        <th>Действия</th>
    </tr>

    {% for user in users %}
    <tr>
        <td>{{ user.id }}</td>
        <td>{{ user.username }}</td>
        <td>{{ "%.2f"|format(user.balance) }}</td>
        <td>{{ "да" if user.admin else "нет" }}</td>
        <td>{{ "активен" if user.active else "заблокирован" }}</td>
        <td>
            <form method="post" action="{{ url_for('admin_user_toggle', user_id=user.id) }}" class="inline">
                <button type="submit">
                    {{ "Заблокировать" if user.active else "Разблокировать" }}
                </button>
            </form>
        </td>
    </tr>
    {% endfor %}
</table>

<h3>Добавить пользователя</h3>

<form method="post" action="{{ url_for('admin_user_add') }}">
    <input type="text" name="username" placeholder="Логин" required>
    <input type="password" name="password" placeholder="Пароль" required>
    <button type="submit">Создать</button>
</form>

<h3>Изменить баланс</h3>

<form method="post" action="{{ url_for('admin_topup') }}">
    <select name="user_id">
        {% for user in users %}
            <option value="{{ user.id }}">{{ user.username }}</option>
        {% endfor %}
    </select>

    <input type="text" name="amount" placeholder="100 или -100" required>
    <input type="text" name="reason" placeholder="Пополнение">
    <button type="submit">Изменить баланс</button>
</form>

<hr>

<h2>Камеры</h2>

<table>
    <tr>
        <th>ID</th>
        <th>Название</th>
        <th>RTSP</th>
        <th>Владелец</th>
        <th>Статус</th>
        <th>Назначить</th>
        <th>Действия</th>
    </tr>

    {% for camera in cameras %}
    <tr>
        <td>{{ camera.id }}</td>
        <td>{{ camera.name }}</td>
        <td>{{ camera.rtsp_url }}</td>
        <td>
            {% if camera.owner %}
                {{ camera.owner.username }}
            {% else %}
                -
            {% endif %}
        </td>
        <td>
            {{ "активна" if camera.active else "выключена" }}
        </td>
        <td>
            <form method="post" action="{{ url_for('admin_camera_assign', camera_id=camera.id) }}">
                <select name="user_id">
                    <option value="">-- не назначена --</option>
                    {% for user in users %}
                        <option value="{{ user.id }}" {% if camera.user_id == user.id %}selected{% endif %}>
                            {{ user.username }}
                        </option>
                    {% endfor %}
                </select>
                <button type="submit">Назначить</button>
            </form>
        </td>
        <td>
            <form method="post" action="{{ url_for('admin_camera_toggle', camera_id=camera.id) }}">
                <button type="submit">
                    {{ "Выключить" if camera.active else "Включить" }}
                </button>
            </form>
        </td>
    </tr>
    {% endfor %}
</table>

<h3>Добавить камеру</h3>

<form method="post" action="{{ url_for('admin_camera_add') }}">
    <input type="text" name="name" placeholder="Название камеры" required>
    <input type="text" name="rtsp_url" placeholder="rtsp://login:pass@ip/stream" required>

    <select name="user_id">
        <option value="">-- не назначена --</option>
        {% for user in users %}
            <option value="{{ user.id }}">{{ user.username }}</option>
        {% endfor %}
    </select>

    <button type="submit">Добавить камеру</button>
</form>

<hr>

<h2>Последние транзакции</h2>

<table>
    <tr>
        <th>ID</th>
        <th>Пользователь</th>
        <th>Сумма</th>
        <th>Причина</th>
        <th>Дата</th>
    </tr>

    {% for transaction in transactions %}
    <tr>
        <td>{{ transaction.id }}</td>
        <td>{{ transaction.user.username }}</td>
        <td>{{ "%.2f"|format(transaction.amount) }}</td>
        <td>{{ transaction.reason }}</td>
        <td>{{ transaction.created_at.strftime("%Y-%m-%d %H:%M:%S") }}</td>
    </tr>
    {% endfor %}
</table>

{% endblock %}
ADMIN_HTML_EOF

echo "=== Создаём worker.py ==="

cat > "$WORKER/worker.py" <<'WORKER_PY_EOF'
import sqlite3
import subprocess
import time
import signal
from pathlib import Path


BASE_DIR = Path("/opt/cctv")
DB_PATH = BASE_DIR / "app" / "cctv.db"
ARCHIVE_DIR = BASE_DIR / "storage" / "archive"
LIVE_DIR = BASE_DIR / "storage" / "live"

procs = {}
running = True


def handle_signal(signum, frame):
    global running
    running = False


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)


def get_cameras():
    if not DB_PATH.exists():
        return []

    try:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        cursor = conn.execute(
            "SELECT id, rtsp_url FROM camera WHERE active=1"
        )
        rows = [dict(row) for row in cursor.fetchall()]
        conn.close()
        return rows
    except sqlite3.Error:
        return []


def start_camera(cam):
    camera_id = cam["id"]
    rtsp_url = cam["rtsp_url"]

    archive_dir = ARCHIVE_DIR / f"camera_{camera_id}"
    live_dir = LIVE_DIR / f"camera_{camera_id}"

    archive_dir.mkdir(parents=True, exist_ok=True)
    live_dir.mkdir(parents=True, exist_ok=True)

    cmd = [
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel", "warning",
        "-rtsp_transport", "tcp",
        "-i", rtsp_url,

        # Запись архива кусками по 5 минут
        "-map", "0:v",
        "-c:v", "copy",
        "-an",
        "-f", "segment",
        "-segment_time", "300",
        "-reset_timestamps", "1",
        "-strftime", "1",
        str(archive_dir / "%Y-%m-%d_%H-%M-%S.mp4"),

        # Live HLS поток для браузера
        "-map", "0:v",
        "-c:v", "copy",
        "-an",
        "-f", "hls",
        "-hls_time", "6",
        "-hls_list_size", "6",
        "-hls_flags", "delete_segments",
        str(live_dir / "index.m3u8"),
    ]

    return subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


while running:
    cameras = get_cameras()
    active_camera_ids = set()

    for cam in cameras:
        camera_id = cam["id"]
        active_camera_ids.add(camera_id)

        proc = procs.get(camera_id)

        if proc is None or proc.poll() is not None:
            if proc is not None:
                proc.wait()

            procs[camera_id] = start_camera(cam)

    for camera_id in list(procs.keys()):
        if camera_id not in active_camera_ids:
            try:
                procs[camera_id].terminate()
            except Exception:
                pass

            del procs[camera_id]

    time.sleep(5)


for proc in procs.values():
    try:
        proc.terminate()
    except Exception:
        pass

for proc in procs.values():
    try:
        proc.wait()
    except Exception:
        pass
WORKER_PY_EOF

echo "=== Создаём .env ==="

if [ ! -f "$BASE/.env" ]; then
    ADMIN_PASSWORD=$(openssl rand -hex 8)
    SECRET_KEY=$(openssl rand -hex 32)

    cat > "$BASE/.env" <<EOF
SECRET_KEY=$SECRET_KEY
ADMIN_USERNAME=admin
ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF

    chmod 600 "$BASE/.env"

    echo "Admin password: $ADMIN_PASSWORD" > "$BASE/admin_password.txt"
    chmod 600 "$BASE/admin_password.txt"
else
    echo ".env уже существует, оставляем старый."
fi

echo "=== Создаём виртуальное окружение ==="

if [ ! -f "$BASE/venv/bin/activate" ]; then
    python3 -m venv "$BASE/venv"
fi

"$BASE/venv/bin/pip" install --upgrade pip
"$BASE/venv/bin/pip" install -r "$APP/requirements.txt"

echo "=== Назначаем владельца ==="

chown -R cctv:cctv "$BASE"

echo "=== Создаём systemd-сервис для веб-приложения ==="

cat > /etc/systemd/system/cctv-web.service <<'EOF'
[Unit]
Description=CCTV Flask web
After=network.target

[Service]
Type=simple
User=cctv
Group=cctv
WorkingDirectory=/opt/cctv/app
EnvironmentFile=/opt/cctv/.env
ExecStart=/opt/cctv/venv/bin/gunicorn --workers 2 --bind 127.0.0.1:8000 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "=== Создаём systemd-сервис для записи камер ==="

cat > /etc/systemd/system/cctv-worker.service <<'EOF'
[Unit]
Description=CCTV recorder worker
After=network.target

[Service]
Type=simple
User=cctv
Group=cctv
WorkingDirectory=/opt/cctv/worker
ExecStart=/opt/cctv/venv/bin/python3 /opt/cctv/worker/worker.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "=== Настраиваем Nginx ==="

cat > /etc/nginx/sites-available/cctv <<'EOF'
server {
    listen 80;
    server_name _;

    client_max_body_size 100m;

    proxy_read_timeout 300s;
    proxy_send_timeout 300s;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
    }
}
EOF

ln -sf /etc/nginx/sites-available/cctv /etc/nginx/sites-enabled/cctv
rm -f /etc/nginx/sites-enabled/default

echo "=== Перезапускаем сервисы ==="

systemctl daemon-reload

systemctl enable --now cctv-web.service
systemctl enable --now cctv-worker.service

systemctl enable nginx
systemctl restart nginx

echo ""
echo "=== Готово ==="
echo ""
echo "Файл с паролем админа:"
echo "/opt/cctv/admin_password.txt"
echo ""
echo "Посмотреть пароль:"
echo "sudo cat /opt/cctv/admin_password.txt"
echo ""
echo "Открой в браузере:"
echo "http://IP_СЕРВЕРА/"
echo ""
echo "Логи:"
echo "sudo journalctl -u cctv-web -f"
echo "sudo journalctl -u cctv-worker -f"