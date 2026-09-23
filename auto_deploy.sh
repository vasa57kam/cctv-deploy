#!/usr/bin/env bash

set -euo pipefail

BASE="/opt/cctv"
APP="$BASE/app"
WORKER="$BASE/worker"
STORAGE="$BASE/storage"
BACKUP="$BASE/backup"
VERSION="2.1"

if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo или от root."
    exit 1
fi

echo "=== CCTV deploy v$VERSION: остановка сервисов ==="
systemctl stop cctv-web cctv-worker cctv-billing 2>/dev/null || true

mkdir -p "$APP/templates"
mkdir -p "$WORKER"
mkdir -p "$STORAGE/live"
mkdir -p "$STORAGE/archive"
mkdir -p "$STORAGE/logs"
mkdir -p "$BACKUP"

export DEBIAN_FRONTEND=noninteractive

echo "=== Пакеты ==="
apt-get update || echo "WARNING: apt update с ошибками, продолжаю"
apt-get install -y python3 python3-venv python3-pip ffmpeg nginx sqlite3 openssl

id -u cctv &>/dev/null || useradd --system --home-dir "$BASE" --shell /usr/sbin/nologin cctv

echo "=== Резервные копии базы и .env ==="
if [ -f "$APP/cctv.db" ]; then
    cp -a "$APP/cctv.db" "$BACKUP/cctv-$(date +%Y%m%d-%H%M%S).db"
    ls -1t "$BACKUP"/cctv-*.db 2>/dev/null | tail -n +8 | xargs -r rm -f
    echo "Бэкап базы создан."
fi
if [ -f "$BASE/.env" ]; then
    cp -a "$BASE/.env" "$BACKUP/env-$(date +%Y%m%d-%H%M%S)"
    ls -1t "$BACKUP"/env-* 2>/dev/null | tail -n +8 | xargs -r rm -f
fi

echo "=== requirements.txt ==="
cat > "$APP/requirements.txt" <<'REQ_EOF'
Flask==3.0.3
Flask-SQLAlchemy==3.1.1
Flask-Login==0.6.3
gunicorn==22.0.0
REQ_EOF

echo "=== app.py ==="
cat > "$APP/app.py" <<'APP_EOF'
import os
import time
from datetime import datetime, timedelta
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
login_manager.login_message = "Для доступа к этой странице нужно войти."


class Tariff(db.Model):
    __tablename__ = "tariff"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(80), nullable=False)
    price = db.Column(db.Float, nullable=False)
    period_days = db.Column(db.Integer, default=30)
    max_cameras = db.Column(db.Integer, default=1)
    archive_days = db.Column(db.Integer, default=7)
    is_active = db.Column(db.Boolean, default=True)


class User(UserMixin, db.Model):
    __tablename__ = "user"

    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    password_hash = db.Column(db.String(255), nullable=False)
    balance = db.Column(db.Float, default=0.0)
    admin = db.Column(db.Boolean, default=False)
    active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    tariff_id = db.Column(db.Integer, db.ForeignKey("tariff.id"), nullable=True)
    subscription_ends_at = db.Column(db.DateTime, nullable=True)

    tariff = db.relationship("Tariff", backref="users")
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
    recording_enabled = db.Column(db.Boolean, default=True)
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
    return db.session.get(User, int(user_id))


def init_db():
    db.create_all()

    if Tariff.query.count() == 0:
        db.session.add_all([
            Tariff(name="Старт", price=290, period_days=30, max_cameras=1, archive_days=3),
            Tariff(name="Базовый", price=690, period_days=30, max_cameras=3, archive_days=7),
            Tariff(name="Бизнес", price=1990, period_days=30, max_cameras=10, archive_days=7),
        ])
        db.session.commit()

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


def get_or_404(model, ident):
    obj = db.session.get(model, ident)
    if obj is None:
        abort(404)
    return obj


def admin_required(f):
    @wraps(f)
    @login_required
    def decorated_function(*args, **kwargs):
        if not current_user.admin:
            abort(403)
        return f(*args, **kwargs)

    return decorated_function


def subscription_active(user):
    if user.subscription_ends_at is None:
        return False
    return user.subscription_ends_at > datetime.utcnow()


def can_view_camera(camera):
    if current_user.admin:
        return True

    if not camera.active:
        return False

    if camera.user_id != current_user.id:
        return False

    if not current_user.is_active:
        return False

    if not subscription_active(current_user):
        return False

    return True


def get_camera_or_403(camera_id):
    camera = db.session.get(Camera, camera_id)
    if not camera:
        abort(404)

    if not can_view_camera(camera):
        abort(403)

    return camera


def user_camera_count(user):
    return Camera.query.filter_by(user_id=user.id).count()


def can_add_camera_to_user(user):
    if user is None:
        return True
    if user.tariff is None:
        return False
    return user_camera_count(user) < user.tariff.max_cameras


def apply_tariff(user, tariff):
    now = datetime.utcnow()

    if user.balance < tariff.price:
        return False, (
            f"Недостаточно баланса: нужно {tariff.price:.2f}, "
            f"на балансе {user.balance:.2f}"
        )

    base = now
    if user.subscription_ends_at and user.subscription_ends_at > now:
        base = user.subscription_ends_at

    user.balance -= tariff.price
    db.session.add(Transaction(
        user_id=user.id,
        amount=-tariff.price,
        reason=f"Подключение тарифа {tariff.name}",
    ))

    user.tariff_id = tariff.id
    user.subscription_ends_at = base + timedelta(days=tariff.period_days)
    db.session.commit()

    return True, (
        f"Тариф {tariff.name} подключён до "
        f"{user.subscription_ends_at:%d.%m.%Y}"
    )


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

    return render_template(
        "dashboard.html",
        cameras=cameras,
        sub_active=subscription_active(current_user),
    )


@app.route("/camera/<int:camera_id>")
@login_required
def camera_page(camera_id):
    camera = get_camera_or_403(camera_id)

    records = []
    camera_dir = ARCHIVE_DIR / f"camera_{camera.id}"

    if camera_dir.exists():
        archive_days = 7
        owner = camera.owner
        if owner is not None and owner.tariff is not None:
            archive_days = owner.tariff.archive_days or 7

        cutoff = time.time() - archive_days * 86400
        now_ts = time.time()

        files = sorted(
            camera_dir.glob("*.mp4"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )

        for p in files[:100]:
            st = p.stat()
            if st.st_mtime < cutoff:
                break
            records.append({
                "name": p.name,
                "ready": (now_ts - st.st_mtime) > 60,
                "size_mb": round(st.st_size / 1048576, 1),
            })

        records = records[:50]

    return render_template("camera.html", camera=camera, records=records)


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


@app.route("/archive/<int:camera_id>/download/<path:filename>")
@login_required
def archive_download(camera_id, filename):
    camera = get_camera_or_403(camera_id)
    directory = str(ARCHIVE_DIR / f"camera_{camera.id}")
    return send_from_directory(
        directory,
        filename,
        as_attachment=True,
        download_name=f"camera{camera.id}_{filename}",
    )


@app.route("/admin")
@admin_required
def admin_page():
    users = User.query.order_by(User.id.desc()).all()
    cameras = Camera.query.order_by(Camera.id.desc()).all()
    tariffs = Tariff.query.order_by(Tariff.id).all()
    transactions = Transaction.query.order_by(Transaction.id.desc()).limit(50).all()

    return render_template(
        "admin.html",
        users=users,
        cameras=cameras,
        tariffs=tariffs,
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
    user = get_or_404(User, user_id)
    user.active = not user.active
    db.session.commit()

    if user.active:
        flash(f"Пользователь {user.username} разблокирован.")
    else:
        flash(f"Пользователь {user.username} заблокирован.")

    return redirect(url_for("admin_page"))


@app.route("/admin/user/<int:user_id>/delete", methods=["POST"])
@admin_required
def admin_user_delete(user_id):
    user = get_or_404(User, user_id)

    if user.id == current_user.id:
        flash("Нельзя удалить самого себя.")
        return redirect(url_for("admin_page"))

    for transaction in list(user.transactions):
        db.session.delete(transaction)

    for camera in list(user.cameras):
        db.session.delete(camera)

    db.session.delete(user)
    db.session.commit()

    flash(f"Пользователь {user.username} и его камеры удалены.")
    return redirect(url_for("admin_page"))


@app.route("/admin/user/<int:user_id>/password", methods=["POST"])
@admin_required
def admin_user_password(user_id):
    user = get_or_404(User, user_id)
    password = request.form.get("password", "").strip()

    if len(password) < 4:
        flash("Пароль должен быть не короче 4 символов.")
        return redirect(url_for("admin_page"))

    user.password_hash = generate_password_hash(password)
    db.session.commit()

    flash(f"Пароль пользователя {user.username} изменён.")
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

    user = get_or_404(User, user_id)

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


@app.route("/admin/user/<int:user_id>/tariff", methods=["POST"])
@admin_required
def admin_user_tariff(user_id):
    user = get_or_404(User, user_id)
    tariff_id = request.form.get("tariff_id", "")

    try:
        tariff_id = int(tariff_id)
    except ValueError:
        flash("Не выбран тариф.")
        return redirect(url_for("admin_page"))

    tariff = get_or_404(Tariff, tariff_id)

    ok, message = apply_tariff(user, tariff)
    flash(message)

    return redirect(url_for("admin_page"))


@app.route("/admin/tariff/add", methods=["POST"])
@admin_required
def admin_tariff_add():
    name = request.form.get("name", "").strip()

    try:
        price = float(request.form.get("price", "0"))
        period_days = int(request.form.get("period_days", "30"))
        max_cameras = int(request.form.get("max_cameras", "1"))
        archive_days = int(request.form.get("archive_days", "7"))
    except ValueError:
        flash("Некорректные числа в тарифе.")
        return redirect(url_for("admin_page"))

    if not name or price <= 0:
        flash("Укажите название и цену.")
        return redirect(url_for("admin_page"))

    tariff = Tariff(
        name=name,
        price=price,
        period_days=period_days,
        max_cameras=max_cameras,
        archive_days=archive_days,
        is_active=True,
    )

    db.session.add(tariff)
    db.session.commit()

    flash(f"Тариф {name} добавлен.")
    return redirect(url_for("admin_page"))


@app.route("/admin/tariff/<int:tariff_id>/toggle", methods=["POST"])
@admin_required
def admin_tariff_toggle(tariff_id):
    tariff = get_or_404(Tariff, tariff_id)
    tariff.is_active = not tariff.is_active
    db.session.commit()
    flash(f"Тариф {tariff.name}: {'включён' if tariff.is_active else 'выключен'}.")
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

    user = None
    if user_id:
        try:
            user = db.session.get(User, int(user_id))
        except ValueError:
            user = None

    if user is not None and not can_add_camera_to_user(user):
        flash("У пользователя лимит камер по тарифу или нет тарифа.")
        return redirect(url_for("admin_page"))

    camera = Camera(
        name=name,
        rtsp_url=rtsp_url,
        active=True,
        recording_enabled=True,
    )

    if user is not None:
        camera.user_id = user.id

    db.session.add(camera)
    db.session.commit()

    flash(f"Камера {name} добавлена.")
    return redirect(url_for("admin_page"))


@app.route("/admin/camera/<int:camera_id>/assign", methods=["POST"])
@admin_required
def admin_camera_assign(camera_id):
    camera = get_or_404(Camera, camera_id)
    user_id = request.form.get("user_id", "").strip()

    if user_id:
        try:
            user = db.session.get(User, int(user_id))
        except ValueError:
            user = None

        if user is not None and not can_add_camera_to_user(user):
            flash("У этого пользователя лимит камер по тарифу или нет тарифа.")
            return redirect(url_for("admin_page"))

        camera.user_id = user.id if user is not None else None
    else:
        camera.user_id = None

    db.session.commit()

    flash("Камера назначена.")
    return redirect(url_for("admin_page"))


@app.route("/admin/camera/<int:camera_id>/toggle", methods=["POST"])
@admin_required
def admin_camera_toggle(camera_id):
    camera = get_or_404(Camera, camera_id)
    camera.active = not camera.active
    db.session.commit()

    if camera.active:
        flash(f"Камера {camera.name} включена.")
    else:
        flash(f"Камера {camera.name} выключена.")

    return redirect(url_for("admin_page"))


@app.route("/admin/camera/<int:camera_id>/recording", methods=["POST"])
@admin_required
def admin_camera_recording(camera_id):
    camera = get_or_404(Camera, camera_id)
    camera.recording_enabled = not camera.recording_enabled
    db.session.commit()

    if camera.recording_enabled:
        flash(f"Камера {camera.name}: запись включена.")
    else:
        flash(f"Камера {camera.name}: запись выключена.")

    return redirect(url_for("admin_page"))


@app.route("/admin/camera/<int:camera_id>/delete", methods=["POST"])
@admin_required
def admin_camera_delete(camera_id):
    camera = get_or_404(Camera, camera_id)
    name = camera.name
    db.session.delete(camera)
    db.session.commit()

    flash(f"Камера {name} удалена. Файлы архива останутся на диске.")
    return redirect(url_for("admin_page"))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
APP_EOF

echo "=== base.html ==="
cat > "$APP/templates/base.html" <<'BASE_EOF'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CCTV Cloud</title>
<style>
:root{--bg:#0f172a;--card:#1e293b;--accent:#38bdf8;--text:#e2e8f0;--muted:#94a3b8;--ok:#4ade80;--bad:#f87171;--warn:#facc15;}
*{box-sizing:border-box}
body{margin:0;font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--text);}
header{display:flex;align-items:center;gap:14px;padding:12px 20px;background:#111c33;border-bottom:1px solid #24344f;flex-wrap:wrap;}
header .logo{font-weight:700;font-size:18px;color:var(--accent);}
header a{color:var(--text);text-decoration:none;padding:6px 10px;border-radius:8px;}
header a:hover{background:#24344f;}
header .spacer{flex:1}
.badge{display:inline-block;padding:2px 10px;border-radius:999px;font-size:12px;}
.badge.ok{background:#14342a;color:var(--ok);}
.badge.bad{background:#3b1d1d;color:var(--bad);}
.badge.warn{background:#3b341a;color:var(--warn);}
main{padding:20px;max-width:1100px;margin:0 auto;}
.card{background:var(--card);border:1px solid #2b3b57;border-radius:14px;padding:18px;margin-bottom:18px;}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:14px;}
.cam{background:#16233c;border:1px solid #2b3b57;border-radius:12px;padding:14px;}
.cam h3{margin:0 0 8px;font-size:16px;}
.btn{display:inline-block;background:var(--accent);color:#082032;border:none;border-radius:8px;padding:8px 14px;font-size:14px;cursor:pointer;text-decoration:none;}
.btn:hover{filter:brightness(1.1);}
.btn.gray{background:#334155;color:var(--text);}
.btn.red{background:#7f1d1d;color:#fecaca;}
table{width:100%;border-collapse:collapse;font-size:14px;}
td,th{padding:8px 10px;border-bottom:1px solid #2b3b57;text-align:left;vertical-align:top;}
input,select{background:#0b1229;border:1px solid #33415c;color:var(--text);border-radius:8px;padding:8px 10px;font-size:14px;}
.messages{margin:0 0 14px;padding:0;}
.messages li{background:#3b1d1d;color:#fecaca;list-style:none;padding:8px 12px;border-radius:8px;margin-bottom:6px;}
.muted{color:var(--muted);font-size:13px;}
video{width:100%;border-radius:10px;background:#000;}
.formrow{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px;}
h1{font-size:22px;margin:0 0 16px;}
h2{font-size:17px;margin:0 0 12px;}
</style>
</head>
<body>
<header>
  <span class="logo">CCTV Cloud</span>
  <span class="badge warn">v2.1</span>
  {% if current_user.is_authenticated %}
    <a href="{{ url_for('dashboard') }}">Мои камеры</a>
    {% if current_user.admin %}<a href="{{ url_for('admin_page') }}">Админка</a>{% endif %}
    <span class="spacer"></span>
    {% if not current_user.admin %}
      <span class="muted">Баланс: {{ "%.2f"|format(current_user.balance) }} р.</span>
    {% endif %}
    <a href="{{ url_for('logout') }}">Выход ({{ current_user.username }})</a>
  {% else %}
    <span class="spacer"></span>
    <a href="{{ url_for('login') }}">Вход</a>
  {% endif %}
</header>
<main>
{% with messages = get_flashed_messages() %}
  {% if messages %}
    <ul class="messages">
      {% for m in messages %}<li>{{ m }}</li>{% endfor %}
    </ul>
  {% endif %}
{% endwith %}
{% block content %}{% endblock %}
</main>
</body>
</html>
BASE_EOF

echo "=== login.html ==="
cat > "$APP/templates/login.html" <<'LOGIN_EOF'
{% extends "base.html" %}

{% block content %}
<div class="card" style="max-width:380px;margin:60px auto;">
  <h1>Вход</h1>
  <form method="post" action="{{ url_for('login') }}">
    <div class="formrow"><input type="text" name="username" placeholder="Логин" required style="flex:1"></div>
    <div class="formrow"><input type="password" name="password" placeholder="Пароль" required style="flex:1"></div>
    <button class="btn" type="submit">Войти</button>
  </form>
</div>
{% endblock %}
LOGIN_EOF

echo "=== dashboard.html ==="
cat > "$APP/templates/dashboard.html" <<'DASH_EOF'
{% extends "base.html" %}

{% block content %}
{% if not current_user.admin %}
<div class="card">
  <h2>Подписка</h2>
  {% if current_user.tariff %}
    <p>Тариф: <b>{{ current_user.tariff.name }}</b>
       (камер: {{ current_user.tariff.max_cameras }},
       архив: {{ current_user.tariff.archive_days }} дн.)</p>
    {% if sub_active %}
      <p><span class="badge ok">активна</span>
         до {{ current_user.subscription_ends_at.strftime("%d.%m.%Y") }}</p>
    {% else %}
      <p><span class="badge bad">истекла</span>
         пополните баланс и попросите администратора продлить тариф</p>
    {% endif %}
  {% else %}
    <p><span class="badge warn">тариф не подключён</span>
       обратитесь к администратору</p>
  {% endif %}
  <p class="muted">Баланс: {{ "%.2f"|format(current_user.balance) }} р.</p>
</div>
{% endif %}

<h1>Мои камеры</h1>
{% if cameras %}
<div class="grid">
  {% for camera in cameras %}
  <div class="cam">
    <h3>{{ camera.name }}</h3>
    <p>
      {% if camera.active %}<span class="badge ok">вкл</span>{% else %}<span class="badge bad">выкл</span>{% endif %}
      {% if camera.recording_enabled %}<span class="badge ok">запись</span>{% else %}<span class="badge warn">без записи</span>{% endif %}
    </p>
    <a class="btn" href="{{ url_for('camera_page', camera_id=camera.id) }}">Открыть</a>
  </div>
  {% endfor %}
</div>
{% else %}
<div class="card"><p class="muted">Камер пока нет.</p></div>
{% endif %}
{% endblock %}
DASH_EOF

echo "=== camera.html ==="
cat > "$APP/templates/camera.html" <<'CAM_EOF'
{% extends "base.html" %}

{% block content %}
<h1>{{ camera.name }}</h1>

<div class="card">
  <h2>Онлайн</h2>
  <video id="video" controls autoplay muted></video>
  <p class="muted" id="player-status"></p>
</div>

<div class="card">
  <h2>Архив</h2>
  {% if records %}
  <table>
    <tr><th>Файл</th><th>Размер</th><th>Статус</th><th></th></tr>
    {% for rec in records %}
    <tr>
      <td>{{ rec.name }}</td>
      <td>{{ rec.size_mb }} МБ</td>
      <td>
        {% if rec.ready %}<span class="badge ok">готов</span>
        {% else %}<span class="badge warn">идёт запись…</span>{% endif %}
      </td>
      <td>
        <a class="btn gray" href="{{ url_for('archive_file', camera_id=camera.id, filename=rec.name) }}" target="_blank">Смотреть</a>
        {% if rec.ready %}
        <a class="btn" href="{{ url_for('archive_download', camera_id=camera.id, filename=rec.name) }}">Скачать</a>
        {% endif %}
      </td>
    </tr>
    {% endfor %}
  </table>
  {% else %}
  <p class="muted">Архив пуст: запись ещё не началась или выключена.</p>
  {% endif %}
</div>

<script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
<script>
const video = document.getElementById("video");
const statusEl = document.getElementById("player-status");
const src = "{{ url_for('live_file', camera_id=camera.id, filename='index.m3u8') }}";
if (window.Hls && Hls.isSupported()) {
  const hls = new Hls();
  hls.loadSource(src);
  hls.attachMedia(video);
  hls.on(Hls.Events.ERROR, function(e, data) {
    if (data.fatal) {
      statusEl.textContent = "Нет сигнала: камера офлайн или поток недоступен";
    }
  });
} else {
  video.src = src;
}
</script>
{% endblock %}
CAM_EOF

echo "=== admin.html ==="
cat > "$APP/templates/admin.html" <<'ADMIN_EOF'
{% extends "base.html" %}

{% block content %}
<h1>Админка <span class="badge warn">v2.1</span></h1>

<div class="card">
<h2>Пользователи</h2>
<table>
<tr><th>ID</th><th>Логин</th><th>Баланс</th><th>Тариф</th><th>До</th><th>Статус</th><th>Действия</th></tr>
{% for u in users %}
<tr>
<td>{{ u.id }}</td>
<td>{{ u.username }}{% if u.admin %} <span class="badge warn">админ</span>{% endif %}</td>
<td>{{ "%.2f"|format(u.balance) }}</td>
<td>{{ u.tariff.name if u.tariff else "—" }}</td>
<td>{{ u.subscription_ends_at.strftime("%d.%m.%Y") if u.subscription_ends_at else "—" }}</td>
<td>{% if u.active %}<span class="badge ok">активен</span>{% else %}<span class="badge bad">заблокирован</span>{% endif %}</td>
<td>
  <form method="post" action="{{ url_for('admin_user_toggle', user_id=u.id) }}" style="display:inline">
    <button class="btn gray" type="submit">{{ "Блок" if u.active else "Разблок" }}</button>
  </form>
  {% if not u.admin %}
  <form method="post" action="{{ url_for('admin_user_delete', user_id=u.id) }}" style="display:inline" onsubmit="return confirm('Удалить пользователя {{ u.username }} вместе с его камерами?');">
    <button class="btn red" type="submit">Удалить</button>
  </form>
  {% endif %}
</td>
</tr>
{% endfor %}
</table>

<h2>Добавить пользователя</h2>
<form method="post" action="{{ url_for('admin_user_add') }}" class="formrow">
<input name="username" placeholder="Логин" required>
<input name="password" type="password" placeholder="Пароль" required>
<button class="btn" type="submit">Создать</button>
</form>

<h2>Сменить пароль пользователю (включая себя)</h2>
<form method="post" id="pass-form" class="formrow">
<select name="user_id" id="pass-user">{% for u in users %}<option value="{{ u.id }}">{{ u.username }}</option>{% endfor %}</select>
<input type="password" name="password" placeholder="Новый пароль" required>
<button class="btn" type="submit">Сменить пароль</button>
</form>

<h2>Баланс</h2>
<form method="post" action="{{ url_for('admin_topup') }}" class="formrow">
<select name="user_id">{% for u in users %}<option value="{{ u.id }}">{{ u.username }}</option>{% endfor %}</select>
<input name="amount" placeholder="100 или -100" required>
<input name="reason" placeholder="Причина">
<button class="btn" type="submit">Применить</button>
</form>

<h2>Подключить тариф (списание с баланса)</h2>
<form method="post" id="tariff-form" class="formrow">
<select name="user_id" id="tariff-user">{% for u in users %}<option value="{{ u.id }}">{{ u.username }}</option>{% endfor %}</select>
<select name="tariff_id">{% for t in tariffs %}<option value="{{ t.id }}">{{ t.name }} — {{ t.price }}</option>{% endfor %}</select>
<button class="btn" type="submit">Подключить</button>
</form>
<p class="muted">Деньги списываются сразу; срок считается от текущей даты окончания, если подписка ещё активна.</p>
</div>

<div class="card">
<h2>Камеры</h2>
<table>
<tr><th>ID</th><th>Название</th><th>RTSP</th><th>Владелец</th><th>Статус</th><th>Назначить</th><th>Действия</th></tr>
{% for cam in cameras %}
<tr>
<td>{{ cam.id }}</td>
<td>{{ cam.name }}</td>
<td class="muted">{{ cam.rtsp_url }}</td>
<td>{{ cam.owner.username if cam.owner else "—" }}</td>
<td>
{% if cam.active %}<span class="badge ok">вкл</span>{% else %}<span class="badge bad">выкл</span>{% endif %}
{% if cam.recording_enabled %}<span class="badge ok">запись</span>{% else %}<span class="badge warn">без записи</span>{% endif %}
</td>
<td>
<form method="post" action="{{ url_for('admin_camera_assign', camera_id=cam.id) }}">
<select name="user_id">
<option value="">— нет —</option>
{% for u in users %}<option value="{{ u.id }}" {% if cam.user_id == u.id %}selected{% endif %}>{{ u.username }}</option>{% endfor %}
</select>
<button class="btn gray" type="submit">Назначить</button>
</form>
</td>
<td>
<form method="post" action="{{ url_for('admin_camera_toggle', camera_id=cam.id) }}" style="display:inline"><button class="btn gray" type="submit">{{ "Выкл" if cam.active else "Вкл" }}</button></form>
<form method="post" action="{{ url_for('admin_camera_recording', camera_id=cam.id) }}" style="display:inline"><button class="btn gray" type="submit">{{ "Стоп запись" if cam.recording_enabled else "Старт запись" }}</button></form>
<form method="post" action="{{ url_for('admin_camera_delete', camera_id=cam.id) }}" style="display:inline" onsubmit="return confirm('Удалить камеру {{ cam.name }}?');"><button class="btn red" type="submit">Удалить</button></form>
</td>
</tr>
{% endfor %}
</table>

<h2>Добавить камеру</h2>
<form method="post" action="{{ url_for('admin_camera_add') }}" class="formrow">
<input name="name" placeholder="Название" required>
<input name="rtsp_url" placeholder="rtsp://login:pass@ip/stream" required style="flex:1">
<select name="user_id"><option value="">— нет —</option>{% for u in users %}<option value="{{ u.id }}">{{ u.username }}</option>{% endfor %}</select>
<button class="btn" type="submit">Добавить</button>
</form>
</div>

<div class="card">
<h2>Тарифы</h2>
<table>
<tr><th>Название</th><th>Цена</th><th>Дней</th><th>Камер</th><th>Архив</th><th>Статус</th><th></th></tr>
{% for t in tariffs %}
<tr>
<td>{{ t.name }}</td>
<td>{{ t.price }}</td>
<td>{{ t.period_days }}</td>
<td>{{ t.max_cameras }}</td>
<td>{{ t.archive_days }} дн.</td>
<td>{% if t.is_active %}<span class="badge ok">активен</span>{% else %}<span class="badge bad">скрыт</span>{% endif %}</td>
<td>
<form method="post" action="{{ url_for('admin_tariff_toggle', tariff_id=t.id) }}" style="display:inline"><button class="btn gray" type="submit">{{ "Выкл" if t.is_active else "Вкл" }}</button></form>
</td>
</tr>
{% endfor %}
</table>

<h2>Добавить тариф</h2>
<form method="post" action="{{ url_for('admin_tariff_add') }}" class="formrow">
<input name="name" placeholder="Название" required>
<input name="price" placeholder="Цена" required>
<input name="period_days" placeholder="Дней" value="30">
<input name="max_cameras" placeholder="Камер" value="1">
<input name="archive_days" placeholder="Архив дней" value="7">
<button class="btn" type="submit">Добавить</button>
</form>
</div>

<div class="card">
<h2>Транзакции</h2>
<table>
<tr><th>ID</th><th>Пользователь</th><th>Сумма</th><th>Причина</th><th>Дата</th></tr>
{% for t in transactions %}
<tr>
<td>{{ t.id }}</td>
<td>{{ t.user.username if t.user else "—" }}</td>
<td>{{ "%.2f"|format(t.amount) }}</td>
<td>{{ t.reason }}</td>
<td>{{ t.created_at.strftime("%d.%m.%Y %H:%M") if t.created_at else "" }}</td>
</tr>
{% endfor %}
</table>
</div>

<script>
document.getElementById("tariff-form").addEventListener("submit", function () {
    var uid = document.getElementById("tariff-user").value;
    this.action = "/admin/user/" + uid + "/tariff";
});
document.getElementById("pass-form").addEventListener("submit", function () {
    var uid = document.getElementById("pass-user").value;
    this.action = "/admin/user/" + uid + "/password";
});
</script>
{% endblock %}
ADMIN_EOF

echo "=== worker.py ==="
cat > "$WORKER/worker.py" <<'WORKER_EOF'
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
            "SELECT id, rtsp_url, recording_enabled "
            "FROM camera WHERE active=1"
        )
        rows = [dict(row) for row in cursor.fetchall()]
        conn.close()
        return rows
    except sqlite3.Error:
        return []


def start_camera(cam):
    camera_id = cam["id"]
    rtsp_url = cam["rtsp_url"]
    recording_enabled = bool(cam["recording_enabled"])

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
    ]

    if recording_enabled:
        cmd += [
            "-map", "0:v",
            "-c:v", "copy",
            "-an",
            "-f", "segment",
            "-segment_time", "300",
            "-reset_timestamps", "1",
            "-strftime", "1",
            str(archive_dir / "%Y-%m-%d_%H-%M-%S.mp4"),
        ]

    cmd += [
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
WORKER_EOF

echo "=== billing.py ==="
cat > "$WORKER/billing.py" <<'BILLING_EOF'
import sqlite3
import time
from datetime import datetime, timedelta
from pathlib import Path


DB_PATH = Path("/opt/cctv/app/cctv.db")


def renew_due():
    if not DB_PATH.exists():
        return

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row

    now = datetime.utcnow()

    rows = conn.execute(
        """
        SELECT u.id AS user_id,
               u.username,
               u.balance,
               u.subscription_ends_at,
               t.id AS tariff_id,
               t.name AS tariff_name,
               t.price,
               t.period_days
        FROM user u
        JOIN tariff t ON t.id = u.tariff_id
        WHERE u.active = 1
          AND u.tariff_id IS NOT NULL
          AND u.subscription_ends_at IS NOT NULL
        """
    ).fetchall()

    for r in rows:
        try:
            ends = datetime.fromisoformat(r["subscription_ends_at"])
        except (ValueError, TypeError):
            continue

        if ends > now + timedelta(days=1):
            continue

        if r["balance"] < r["price"]:
            print(f"[billing] {r['username']}: не хватает баланса для продления {r['tariff_name']}", flush=True)
            continue

        base = ends if ends > now else now
        new_ends = base + timedelta(days=r["period_days"])

        conn.execute(
            "UPDATE user SET balance = balance - ?, subscription_ends_at = ?, tariff_id = ? WHERE id = ?",
            (r["price"], new_ends.isoformat(sep=" "), r["tariff_id"], r["user_id"]),
        )
        conn.execute(
            "INSERT INTO transaction (user_id, amount, reason, created_at) VALUES (?, ?, ?, ?)",
            (r["user_id"], -r["price"], f"Автопродление тарифа {r['tariff_name']}", now.isoformat(sep=" ")),
        )
        conn.commit()

        print(f"[billing] {r['username']}: продлён {r['tariff_name']} до {new_ends}", flush=True)

    conn.close()


while True:
    try:
        renew_due()
    except Exception as e:
        print("[billing] error:", e, flush=True)

    time.sleep(3600)
BILLING_EOF

echo "=== .env (не трогаем, если есть) ==="
if [ ! -f "$BASE/.env" ]; then
    ADMIN_PASSWORD=$(openssl rand -hex 8)
    SECRET_KEY=$(openssl rand -hex 32)

    cat > "$BASE/.env" <<ENV_EOF
SECRET_KEY=$SECRET_KEY
ADMIN_USERNAME=admin
ADMIN_PASSWORD=$ADMIN_PASSWORD
ENV_EOF

    chmod 600 "$BASE/.env"

    echo "Admin password: $ADMIN_PASSWORD" > "$BASE/admin_password.txt"
    chmod 600 "$BASE/admin_password.txt"
else
    echo ".env существует — оставляем прежним."
fi

echo "=== Виртуальное окружение ==="
if [ ! -f "$BASE/venv/bin/activate" ]; then
    python3 -m venv "$BASE/venv"
fi
"$BASE/venv/bin/pip" install --upgrade pip
"$BASE/venv/bin/pip" install -r "$APP/requirements.txt"

echo "=== Миграция базы (идемпотентная) ==="
if [ -f "$APP/cctv.db" ]; then
    python3 - "$APP/cctv.db" <<'PYMIG'
import sqlite3
import sys

path = sys.argv[1]
conn = sqlite3.connect(path)
cur = conn.cursor()

tables = {r[0] for r in cur.execute(
    "SELECT name FROM sqlite_master WHERE type='table'"
).fetchall()}

cur.execute(
    """
    CREATE TABLE IF NOT EXISTS tariff (
        id INTEGER PRIMARY KEY,
        name VARCHAR(80) NOT NULL,
        price FLOAT NOT NULL,
        period_days INTEGER,
        max_cameras INTEGER,
        archive_days INTEGER,
        is_active BOOLEAN
    )
    """
)

def cols(table):
    return {r[1] for r in cur.execute(f"PRAGMA table_info({table})").fetchall()}

if "user" in tables:
    u = cols("user")
    if "tariff_id" not in u:
        cur.execute("ALTER TABLE user ADD COLUMN tariff_id INTEGER")
        print("migration: user += tariff_id")
    if "subscription_ends_at" not in u:
        cur.execute("ALTER TABLE user ADD COLUMN subscription_ends_at TIMESTAMP")
        print("migration: user += subscription_ends_at")

if "camera" in tables:
    c = cols("camera")
    if "recording_enabled" not in c:
        cur.execute("ALTER TABLE camera ADD COLUMN recording_enabled BOOLEAN DEFAULT 1")
        print("migration: camera += recording_enabled")

cur.execute("PRAGMA journal_mode=WAL")
conn.commit()
conn.close()
print("migration ok")
PYMIG
else
    echo "База не найдена — будет создана при первом старте."
fi

echo "=== Владелец файлов ==="
chown -R cctv:cctv "$BASE"

echo "=== systemd: cctv-web ==="
cat > /etc/systemd/system/cctv-web.service <<'UNIT_WEB_EOF'
[Unit]
Description=CCTV Flask web
After=network.target

[Service]
Type=simple
User=cctv
Group=cctv
WorkingDirectory=/opt/cctv/app
EnvironmentFile=/opt/cctv/.env
ExecStart=/opt/cctv/venv/bin/gunicorn --workers 2 --bind 127.0.0.1:8077 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT_WEB_EOF

echo "=== systemd: cctv-worker ==="
cat > /etc/systemd/system/cctv-worker.service <<'UNIT_WORKER_EOF'
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
UNIT_WORKER_EOF

echo "=== systemd: cctv-billing ==="
cat > /etc/systemd/system/cctv-billing.service <<'UNIT_BILLING_EOF'
[Unit]
Description=CCTV billing worker
After=network.target

[Service]
Type=simple
User=cctv
Group=cctv
WorkingDirectory=/opt/cctv/worker
ExecStart=/opt/cctv/venv/bin/python3 /opt/cctv/worker/billing.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT_BILLING_EOF

echo "=== Nginx ==="
cat > /etc/nginx/sites-available/cctv <<'NGINX_EOF'
server {
    listen 80;
    server_name _;

    client_max_body_size 100m;

    proxy_read_timeout 300s;
    proxy_send_timeout 300s;

    location / {
        proxy_pass http://127.0.0.1:8077;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
    }
}
NGINX_EOF

ln -sf /etc/nginx/sites-available/cctv /etc/nginx/sites-enabled/cctv
rm -f /etc/nginx/sites-enabled/default

nginx -t

echo "=== Версия ==="
echo "$VERSION" > "$BASE/VERSION"
chown cctv:cctv "$BASE/VERSION"

echo "=== Старт сервисов ==="
systemctl daemon-reload
systemctl enable --now cctv-web.service
systemctl enable --now cctv-worker.service
systemctl enable --now cctv-billing.service
systemctl restart nginx

echo "=== Самопроверка С ВХОДОМ ПОД АДМИНОМ ==="
sleep 3

set +e
source "$BASE/.env"
LOGIN_CODE=$(curl -s -c /tmp/cctv_check_cj -o /dev/null -w "%{http_code}" --data "username=$ADMIN_USERNAME&password=$ADMIN_PASSWORD" http://127.0.0.1:8077/login)
ADMIN_CODE=$(curl -s -b /tmp/cctv_check_cj -o /dev/null -w "%{http_code}" http://127.0.0.1:8077/admin)
DASH_CODE=$(curl -s -b /tmp/cctv_check_cj -o /dev/null -w "%{http_code}" http://127.0.0.1:8077/)
rm -f /tmp/cctv_check_cj
set -e

echo "login POST:  $LOGIN_CODE (ожидаем 302)"
echo "admin GET:   $ADMIN_CODE (ожидаем 200)"
echo "dashboard:   $DASH_CODE (ожидаем 200)"

if [ "$ADMIN_CODE" != "200" ] || [ "$DASH_CODE" != "200" ]; then
    echo "!!! САМОПРОВЕРКА НЕ ПРОШЛА, логи:"
    journalctl -u cctv-web -n 30 --no-pager || true
    exit 1
fi

echo ""
echo "=== Готово ==="
echo "Версия системы: $(cat "$BASE/VERSION")"

if [ -f "$APP/cctv.db" ]; then
    echo "Пользователей: $(sqlite3 "$APP/cctv.db" 'SELECT COUNT(*) FROM user;')"
    echo "Камер:         $(sqlite3 "$APP/cctv.db" 'SELECT COUNT(*) FROM camera;')"
    echo "Транзакций:    $(sqlite3 "$APP/cctv.db" 'SELECT COUNT(*) FROM transaction;')"
fi
echo "Архив на диске: $(du -sh "$STORAGE/archive" 2>/dev/null | cut -f1)"
echo "Пароль админа:  sudo cat /opt/cctv/admin_password.txt"