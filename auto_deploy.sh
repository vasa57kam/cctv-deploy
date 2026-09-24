#!/usr/bin/env bash

set -euo pipefail

BASE="/opt/cctv"
APP="$BASE/app"
WORKER="$BASE/worker"
STORAGE="$BASE/storage"
BACKUP="$BASE/backup"
VERSION="2.9"

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

echo "=== Резервные копии ==="
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


PAY_METHODS = [
    ("cash", "Наличные"),
    ("transfer", "Перевод по номеру"),
    ("card", "Карта онлайн"),
    ("promised", "Обещанный платёж"),
    ("other", "Другое"),
]


DEFAULT_SETTINGS = {
    "method_cash": "1",
    "method_transfer": "1",
    "method_card": "0",
    "method_promised": "1",
    "method_other": "0",
    "transfer_instruction": (
        "Переведите сумму на карту Сбербанк: 0000 0000 0000 0000 (Имя Фамилия). "
        "В комментарии к заявке укажите дату перевода и последние 4 цифры карты."
    ),
    "promised_amount": "300",
    "promised_repay_seconds": "604800",
    "promised_fee_percent": "10",
}


def method_label(code):
    return dict(PAY_METHODS).get(code, code)


camera_access = db.Table(
    "camera_access",
    db.Column("id", db.Integer, primary_key=True),
    db.Column("camera_id", db.Integer, db.ForeignKey("camera.id"), nullable=False),
    db.Column("user_id", db.Integer, db.ForeignKey("user.id"), nullable=False),
)


class Setting(db.Model):
    __tablename__ = "setting"

    key = db.Column(db.String(80), primary_key=True)
    value = db.Column(db.Text)


class Tariff(db.Model):
    __tablename__ = "tariff"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(80), nullable=False)
    price = db.Column(db.Float, nullable=False)
    period_days = db.Column(db.Integer, default=30)
    interval_seconds = db.Column(db.Integer, default=2592000)
    max_cameras = db.Column(db.Integer, default=1)
    archive_days = db.Column(db.Integer, default=7)
    is_active = db.Column(db.Boolean, default=True)


class User(UserMixin, db.Model):
    __tablename__ = "user"

    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    password_hash = db.Column(db.String(255), nullable=False)
    balance = db.Column(db.Float, default=0.0)
    credit_limit = db.Column(db.Float, default=0.0)
    admin = db.Column(db.Boolean, default=False)
    active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    tariff_id = db.Column(db.Integer, db.ForeignKey("tariff.id"), nullable=True)
    subscription_ends_at = db.Column(db.DateTime, nullable=True)

    tariff = db.relationship("Tariff", backref="users")
    transactions = db.relationship("Transaction", backref="user", lazy=True)

    @property
    def is_active(self):
        return self.active


class Camera(db.Model):
    __tablename__ = "camera"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    rtsp_url = db.Column(db.Text, nullable=False)
    user_id = db.Column(db.Integer, nullable=True)
    active = db.Column(db.Boolean, default=True)
    recording_enabled = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    users = db.relationship("User", secondary="camera_access", backref="cameras")


class Transaction(db.Model):
    __tablename__ = "transaction"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    amount = db.Column(db.Float, nullable=False)
    reason = db.Column(db.String(255))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class PaymentRequest(db.Model):
    __tablename__ = "payment_request"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    amount = db.Column(db.Float, nullable=False)
    method = db.Column(db.String(20), default="other")
    comment = db.Column(db.String(255))
    status = db.Column(db.String(10), default="pending")
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    processed_at = db.Column(db.DateTime, nullable=True)

    user = db.relationship("User", backref="payment_requests")


class PromisedDebt(db.Model):
    __tablename__ = "promised_debt"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    principal = db.Column(db.Float, nullable=False)
    repay_amount = db.Column(db.Float, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    due_at = db.Column(db.DateTime, nullable=False)
    status = db.Column(db.String(10), default="active")
    repaid_at = db.Column(db.DateTime, nullable=True)

    user = db.relationship("User", backref="promised_debts")


@login_manager.user_loader
def load_user(user_id):
    return db.session.get(User, int(user_id))


def get_setting(key, default=None):
    row = db.session.get(Setting, key)
    if row is None:
        return DEFAULT_SETTINGS.get(key, default)
    return row.value


def set_setting(key, value):
    row = db.session.get(Setting, key)
    if row is None:
        row = Setting(key=key, value=value)
        db.session.add(row)
    else:
        row.value = value


def available_methods():
    result = []
    for code, label in PAY_METHODS:
        if code == "promised":
            continue
        if get_setting(f"method_{code}", "0") == "1":
            result.append((code, label))
    return result


def init_db():
    db.create_all()

    if Tariff.query.count() == 0:
        db.session.add_all([
            Tariff(name="Старт", price=290, period_days=30, interval_seconds=2592000, max_cameras=1, archive_days=3),
            Tariff(name="Базовый", price=690, period_days=30, interval_seconds=2592000, max_cameras=3, archive_days=7),
            Tariff(name="Бизнес", price=1990, period_days=30, interval_seconds=2592000, max_cameras=10, archive_days=7),
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


def interval_label(seconds):
    seconds = int(seconds or 0)
    if seconds <= 0:
        return "—"
    if seconds % 2592000 == 0:
        return f"{seconds // 2592000} мес"
    if seconds % 86400 == 0:
        return f"{seconds // 86400} дн"
    if seconds % 3600 == 0:
        return f"{seconds // 3600} ч"
    if seconds % 60 == 0:
        return f"{seconds // 60} мин"
    return f"{seconds} сек"


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

    if current_user not in camera.users:
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


def can_add_camera_to_user(user):
    if user is None:
        return True
    if user.tariff is None:
        return False
    return len(user.cameras) < user.tariff.max_cameras


def camera_archive_days(camera):
    values = [
        u.tariff.archive_days
        for u in camera.users
        if u.tariff is not None and u.tariff.archive_days
    ]
    return max(values) if values else 7


def apply_tariff(user, tariff):
    now = datetime.utcnow()

    if user.balance < tariff.price:
        return False, (
            f"Недостаточно баланса: нужно {tariff.price:.2f}, "
            f"на балансе {user.balance:.2f}"
        )

    same_tariff = user.tariff_id == tariff.id

    base = now
    if same_tariff and user.subscription_ends_at and user.subscription_ends_at > now:
        base = user.subscription_ends_at

    user.balance -= tariff.price
    db.session.add(Transaction(
        user_id=user.id,
        amount=-tariff.price,
        reason=f"Списание по тарифу {tariff.name} ({interval_label(tariff.interval_seconds)})",
    ))

    user.tariff_id = tariff.id
    user.subscription_ends_at = base + timedelta(seconds=tariff.interval_seconds or 2592000)
    db.session.commit()

    return True, (
        f"Тариф {tariff.name} подключён до "
        f"{user.subscription_ends_at:%d.%m.%Y %H:%M:%S}"
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
        cameras = [c for c in current_user.cameras if c.active]

    tariff_options = [
        {"tariff": t, "label": interval_label(t.interval_seconds)}
        for t in Tariff.query.filter_by(is_active=True).order_by(Tariff.price).all()
    ]

    my_requests = [
        {"p": p, "label": method_label(p.method)}
        for p in PaymentRequest.query
        .filter_by(user_id=current_user.id)
        .order_by(PaymentRequest.id.desc())
        .limit(10).all()
    ]

    methods = available_methods()
    transfer_instruction = ""
    if any(code == "transfer" for code, _ in methods):
        transfer_instruction = get_setting("transfer_instruction", "") or ""

    promised_enabled = get_setting("method_promised", "0") == "1"
    try:
        promised_amount = float(get_setting("promised_amount", "300") or 0)
        promised_fee = float(get_setting("promised_fee_percent", "0") or 0)
        promised_repay_seconds = int(get_setting("promised_repay_seconds", "604800") or 0)
    except ValueError:
        promised_amount, promised_fee, promised_repay_seconds = 300.0, 0.0, 604800

    active_debt = PromisedDebt.query.filter_by(
        user_id=current_user.id, status="active"
    ).first()

    return render_template(
        "dashboard.html",
        cameras=cameras,
        sub_active=subscription_active(current_user),
        tariff_options=tariff_options,
        my_requests=my_requests,
        methods=methods,
        transfer_instruction=transfer_instruction,
        promised_enabled=promised_enabled,
        promised_amount=promised_amount,
        promised_fee=promised_fee,
        promised_repay_seconds=promised_repay_seconds,
        promised_repay_label=interval_label(promised_repay_seconds),
        active_debt=active_debt,
    )


@app.route("/payment/request", methods=["POST"])
@login_required
def payment_request():
    try:
        amount = float(request.form.get("amount", "0"))
    except ValueError:
        flash("Некорректная сумма.")
        return redirect(url_for("dashboard"))

    if amount <= 0:
        flash("Сумма должна быть больше нуля.")
        return redirect(url_for("dashboard"))

    method = request.form.get("method", "other")
    if method not in [code for code, _ in available_methods()]:
        flash("Способ пополнения недоступен.")
        return redirect(url_for("dashboard"))

    comment = request.form.get("comment", "").strip()

    pr = PaymentRequest(
        user_id=current_user.id,
        amount=amount,
        method=method,
        comment=comment,
        status="pending",
        created_at=datetime.utcnow(),
    )

    db.session.add(pr)
    db.session.commit()

    flash("Заявка создана. Администратор подтвердит пополнение.")
    return redirect(url_for("dashboard"))


@app.route("/promised/connect", methods=["POST"])
@login_required
def promised_connect():
    if get_setting("method_promised", "0") != "1":
        flash("Обещанный платёж отключён администратором.")
        return redirect(url_for("dashboard"))

    active = PromisedDebt.query.filter_by(
        user_id=current_user.id, status="active"
    ).first()
    if active:
        flash("У вас уже есть активный обещанный платёж.")
        return redirect(url_for("dashboard"))

    try:
        amount = float(get_setting("promised_amount", "300"))
        repay_seconds = int(get_setting("promised_repay_seconds", "604800"))
        fee = float(get_setting("promised_fee_percent", "0"))
    except ValueError:
        flash("Обещанный платёж неправильно настроен.")
        return redirect(url_for("dashboard"))

    now = datetime.utcnow()
    repay_amount = round(amount * (1 + fee / 100.0), 2)

    current_user.balance += amount
    db.session.add(Transaction(
        user_id=current_user.id,
        amount=amount,
        reason="Обещанный платёж: зачислено",
    ))

    debt = PromisedDebt(
        user_id=current_user.id,
        principal=amount,
        repay_amount=repay_amount,
        created_at=now,
        due_at=now + timedelta(seconds=repay_seconds),
        status="active",
    )
    db.session.add(debt)
    db.session.commit()

    flash(
        f"Обещанный платёж {amount:.2f} подключён. "
        f"К возврату {repay_amount:.2f} до {debt.due_at:%d.%m.%Y %H:%M}."
    )
    return redirect(url_for("dashboard"))


@app.route("/tariff/choose", methods=["POST"])
@login_required
def tariff_choose():
    try:
        tariff_id = int(request.form.get("tariff_id", ""))
    except ValueError:
        flash("Не выбран тариф.")
        return redirect(url_for("dashboard"))

    tariff = get_or_404(Tariff, tariff_id)

    if not tariff.is_active:
        flash("Тариф недоступен.")
        return redirect(url_for("dashboard"))

    ok, message = apply_tariff(current_user, tariff)
    flash(message)
    return redirect(url_for("dashboard"))


@app.route("/camera/<int:camera_id>")
@login_required
def camera_page(camera_id):
    camera = get_camera_or_403(camera_id)

    records = []
    camera_dir = ARCHIVE_DIR / f"camera_{camera.id}"

    if camera_dir.exists():
        archive_days = camera_archive_days(camera)
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

    pending_requests = [
        {"p": p, "label": method_label(p.method)}
        for p in PaymentRequest.query
        .filter_by(status="pending")
        .order_by(PaymentRequest.id).all()
    ]

    processed_requests = [
        {"p": p, "label": method_label(p.method)}
        for p in PaymentRequest.query
        .filter(PaymentRequest.status != "pending")
        .order_by(PaymentRequest.id.desc())
        .limit(20).all()
    ]

    debts = [
        {"d": d, "overdue": d.due_at < datetime.utcnow()}
        for d in PromisedDebt.query
        .filter_by(status="active")
        .order_by(PromisedDebt.due_at).all()
    ]

    settings = {key: get_setting(key) for key in DEFAULT_SETTINGS}

    return render_template(
        "admin.html",
        users=users,
        cameras=cameras,
        tariffs=tariffs,
        transactions=transactions,
        pending_requests=pending_requests,
        processed_requests=processed_requests,
        debts=debts,
        settings=settings,
        methods=PAY_METHODS,
    )


@app.route("/admin/settings", methods=["POST"])
@admin_required
def admin_settings():
    for code, _ in PAY_METHODS:
        set_setting(f"method_{code}", "1" if request.form.get(f"method_{code}") else "0")

    set_setting("transfer_instruction", request.form.get("transfer_instruction", "").strip())

    try:
        promised_amount = float(request.form.get("promised_amount", "300"))
        repay_seconds = int(request.form.get("promised_repay_seconds", "604800"))
        fee = float(request.form.get("promised_fee_percent", "0"))
        if promised_amount <= 0 or repay_seconds <= 0 or fee < 0:
            raise ValueError
    except ValueError:
        flash("Некорректные параметры обещанного платежа.")
        return redirect(url_for("admin_page"))

    set_setting("promised_amount", str(promised_amount))
    set_setting("promised_repay_seconds", str(repay_seconds))
    set_setting("promised_fee_percent", str(fee))
    db.session.commit()

    flash("Настройки пополнения и обещанного платежа сохранены.")
    return redirect(url_for("admin_page"))


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


@app.route("/admin/user/<int:user_id>/edit", methods=["POST"])
@admin_required
def admin_user_edit(user_id):
    user = get_or_404(User, user_id)
    username = request.form.get("username", "").strip()

    if not username:
        flash("Пустой логин.")
        return redirect(url_for("admin_page"))

    exists = User.query.filter_by(username=username).first()
    if exists and exists.id != user.id:
        flash("Такой логин уже занят.")
        return redirect(url_for("admin_page"))

    user.username = username
    db.session.commit()
    flash("Пользователь обновлён.")
    return redirect(url_for("admin_page"))


@app.route("/admin/user/<int:user_id>/credit", methods=["POST"])
@admin_required
def admin_user_credit(user_id):
    user = get_or_404(User, user_id)

    try:
        limit = float(request.form.get("credit_limit", "0"))
    except ValueError:
        flash("Некорректный лимит.")
        return redirect(url_for("admin_page"))

    user.credit_limit = max(0.0, limit)
    db.session.commit()

    flash(f"Доверительный лимит {user.username}: {user.credit_limit:.2f}.")
    return redirect(url_for("admin_page"))


@app.route("/admin/user/<int:user_id>/toggle", methods=["POST"])
@admin_required
def admin_user_toggle(user_id):
    user = get_or_404(User, user_id)

    if user.id == current_user.id and user.active:
        flash("Нельзя заблокировать самого себя.")
        return redirect(url_for("admin_page"))

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

    for pr in list(user.payment_requests):
        db.session.delete(pr)

    for debt in list(user.promised_debts):
        db.session.delete(debt)

    db.session.execute(
        camera_access.delete().where(camera_access.c.user_id == user.id)
    )

    db.session.delete(user)
    db.session.commit()

    flash(f"Пользователь {user.username} удалён. Камеры остались в общем пуле.")
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
    method = request.form.get("method", "other")

    try:
        user_id = int(user_id)
        amount = float(amount_raw)
    except ValueError:
        flash("Некорректные данные.")
        return redirect(url_for("admin_page"))

    user = get_or_404(User, user_id)

    user.balance += amount

    reason_text = reason or method_label(method)

    transaction = Transaction(
        user_id=user.id,
        amount=amount,
        reason=f"Пополнение ({reason_text})",
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


@app.route("/admin/payment/<int:pr_id>/approve", methods=["POST"])
@admin_required
def admin_payment_approve(pr_id):
    pr = get_or_404(PaymentRequest, pr_id)

    if pr.status != "pending":
        flash("Заявка уже обработана.")
        return redirect(url_for("admin_page"))

    pr.status = "approved"
    pr.processed_at = datetime.utcnow()
    pr.user.balance += pr.amount

    db.session.add(Transaction(
        user_id=pr.user_id,
        amount=pr.amount,
        reason=f"Пополнение ({method_label(pr.method)})" + (f": {pr.comment}" if pr.comment else ""),
    ))
    db.session.commit()

    flash(f"Пополнение {pr.amount:.2f} для {pr.user.username} подтверждено.")
    return redirect(url_for("admin_page"))


@app.route("/admin/payment/<int:pr_id>/reject", methods=["POST"])
@admin_required
def admin_payment_reject(pr_id):
    pr = get_or_404(PaymentRequest, pr_id)

    if pr.status != "pending":
        flash("Заявка уже обработана.")
        return redirect(url_for("admin_page"))

    pr.status = "rejected"
    pr.processed_at = datetime.utcnow()
    db.session.commit()

    flash("Заявка отклонена.")
    return redirect(url_for("admin_page"))


@app.route("/admin/tariff/add", methods=["POST"])
@admin_required
def admin_tariff_add():
    name = request.form.get("name", "").strip()

    try:
        price = float(request.form.get("price", "0"))
        interval_seconds = int(request.form.get("interval_seconds", "2592000"))
        max_cameras = int(request.form.get("max_cameras", "1"))
        archive_days = int(request.form.get("archive_days", "7"))
    except ValueError:
        flash("Некорректные числа в тарифе.")
        return redirect(url_for("admin_page"))

    if not name or price <= 0 or interval_seconds <= 0:
        flash("Название, цена и интервал должны быть положительными.")
        return redirect(url_for("admin_page"))

    tariff = Tariff(
        name=name,
        price=price,
        period_days=max(1, interval_seconds // 86400) if interval_seconds >= 86400 else 1,
        interval_seconds=interval_seconds,
        max_cameras=max_cameras,
        archive_days=archive_days,
        is_active=True,
    )

    db.session.add(tariff)
    db.session.commit()

    flash(f"Тариф {name} добавлен ({interval_label(interval_seconds)}).")
    return redirect(url_for("admin_page"))


@app.route("/admin/tariff/<int:tariff_id>/edit", methods=["POST"])
@admin_required
def admin_tariff_edit(tariff_id):
    tariff = get_or_404(Tariff, tariff_id)
    name = request.form.get("name", "").strip()

    try:
        price = float(request.form.get("price", "0"))
        interval_seconds = int(request.form.get("interval_seconds", "2592000"))
        max_cameras = int(request.form.get("max_cameras", "1"))
        archive_days = int(request.form.get("archive_days", "7"))
    except ValueError:
        flash("Некорректные числа в тарифе.")
        return redirect(url_for("admin_page"))

    if not name or price <= 0 or interval_seconds <= 0:
        flash("Название, цена и интервал должны быть положительными.")
        return redirect(url_for("admin_page"))

    tariff.name = name
    tariff.price = price
    tariff.interval_seconds = interval_seconds
    tariff.period_days = max(1, interval_seconds // 86400) if interval_seconds >= 86400 else 1
    tariff.max_cameras = max_cameras
    tariff.archive_days = archive_days
    db.session.commit()

    flash(f"Тариф {name} обновлён ({interval_label(interval_seconds)}).")
    return redirect(url_for("admin_page"))


@app.route("/admin/tariff/<int:tariff_id>/toggle", methods=["POST"])
@admin_required
def admin_tariff_toggle(tariff_id):
    tariff = get_or_404(Tariff, tariff_id)
    tariff.is_active = not tariff.is_active
    db.session.commit()
    flash(f"Тариф {tariff.name}: {'включён' if tariff.is_active else 'выключен'}.")
    return redirect(url_for("admin_page"))


@app.route("/admin/tariff/<int:tariff_id>/delete", methods=["POST"])
@admin_required
def admin_tariff_delete(tariff_id):
    tariff = get_or_404(Tariff, tariff_id)

    if tariff.users:
        flash(f"Тариф {tariff.name} нельзя удалить: на нём есть пользователи.")
        return redirect(url_for("admin_page"))

    name = tariff.name
    db.session.delete(tariff)
    db.session.commit()

    flash(f"Тариф {name} удалён.")
    return redirect(url_for("admin_page"))


@app.route("/admin/camera/add", methods=["POST"])
@admin_required
def admin_camera_add():
    name = request.form.get("name", "").strip()
    rtsp_url = request.form.get("rtsp_url", "").strip()

    if not name or not rtsp_url:
        flash("Укажите название камеры и RTSP.")
        return redirect(url_for("admin_page"))

    camera = Camera(
        name=name,
        rtsp_url=rtsp_url,
        active=True,
        recording_enabled=False,
    )

    db.session.add(camera)
    db.session.commit()

    flash(f"Камера {name} добавлена в пул. Запись выключена, включи кнопкой.")
    return redirect(url_for("admin_page"))


@app.route("/admin/camera/<int:camera_id>/edit", methods=["POST"])
@admin_required
def admin_camera_edit(camera_id):
    camera = get_or_404(Camera, camera_id)
    name = request.form.get("name", "").strip()
    rtsp_url = request.form.get("rtsp_url", "").strip()

    if not name or not rtsp_url:
        flash("Укажите название и RTSP.")
        return redirect(url_for("admin_page"))

    camera.name = name
    camera.rtsp_url = rtsp_url
    db.session.commit()

    flash(f"Камера {name} обновлена. Воркер подхватит за несколько секунд.")
    return redirect(url_for("admin_page"))


@app.route("/admin/camera/<int:camera_id>/grant", methods=["POST"])
@admin_required
def admin_camera_grant(camera_id):
    camera = get_or_404(Camera, camera_id)

    try:
        user_id = int(request.form.get("user_id", ""))
    except ValueError:
        flash("Не выбран пользователь.")
        return redirect(url_for("admin_page"))

    user = get_or_404(User, user_id)

    if camera in user.cameras:
        flash("Доступ уже выдан.")
        return redirect(url_for("admin_page"))

    if not can_add_camera_to_user(user):
        flash(f"У {user.username} лимит камер по тарифу или нет тарифа.")
        return redirect(url_for("admin_page"))

    user.cameras.append(camera)
    db.session.commit()

    flash(f"Доступ к {camera.name} выдан пользователю {user.username}.")
    return redirect(url_for("admin_page"))


@app.route("/admin/camera/<int:camera_id>/revoke", methods=["POST"])
@admin_required
def admin_camera_revoke(camera_id):
    camera = get_or_404(Camera, camera_id)

    try:
        user_id = int(request.form.get("user_id", ""))
    except ValueError:
        flash("Не выбран пользователь.")
        return redirect(url_for("admin_page"))

    user = get_or_404(User, user_id)

    if camera in user.cameras:
        user.cameras.remove(camera)
        db.session.commit()
        flash(f"Доступ к {camera.name} отозван у {user.username}.")
    else:
        flash("У этого пользователя не было доступа.")

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
        flash(f"Камера {camera.name}: запись ВКЛЮЧЕНА.")
    else:
        flash(f"Камера {camera.name}: запись выключена.")

    return redirect(url_for("admin_page"))


@app.route("/admin/camera/<int:camera_id>/delete", methods=["POST"])
@admin_required
def admin_camera_delete(camera_id):
    camera = get_or_404(Camera, camera_id)
    name = camera.name

    db.session.execute(
        camera_access.delete().where(camera_access.c.camera_id == camera.id)
    )
    db.session.delete(camera)
    db.session.commit()

    flash(f"Камера {name} удалена из пула. Файлы архива останутся на диске.")
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
input,select,textarea{background:#0b1229;border:1px solid #33415c;color:var(--text);border-radius:8px;padding:8px 10px;font-size:14px;}
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
  <span class="badge warn">v2.9</span>
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
         оплачено до {{ current_user.subscription_ends_at.strftime("%d.%m.%Y %H:%M:%S") }}</p>
    {% else %}
      <p><span class="badge bad">истекла</span>
         пополните баланс и подключите тариф ниже</p>
    {% endif %}
  {% else %}
    <p><span class="badge warn">тариф не подключён</span>
       выберите тариф в списке ниже</p>
  {% endif %}
  <p class="muted">Баланс: {{ "%.2f"|format(current_user.balance) }} р.
     {% if current_user.credit_limit %}
       Доверительный лимит: {{ "%.2f"|format(current_user.credit_limit) }} р.
     {% endif %}</p>
</div>

<div class="card">
  <h2>Пополнить баланс</h2>
  {% if methods %}
  <form method="post" action="{{ url_for('payment_request') }}" class="formrow">
    <input name="amount" placeholder="Сумма" required>
    <select name="method">
      {% for code, label in methods %}<option value="{{ code }}">{{ label }}</option>{% endfor %}
    </select>
    <input name="comment" placeholder="Комментарий / номер перевода" style="flex:1">
    <button class="btn" type="submit">Создать заявку</button>
  </form>
  {% if transfer_instruction %}
    <p class="muted" style="white-space:pre-line">{{ transfer_instruction }}</p>
  {% endif %}
  {% else %}
  <p class="muted">Способы пополнения сейчас отключены администратором.</p>
  {% endif %}
  {% if my_requests %}
  <table>
    <tr><th>ID</th><th>Сумма</th><th>Способ</th><th>Комментарий</th><th>Статус</th></tr>
    {% for item in my_requests %}
    <tr>
      <td>{{ item.p.id }}</td>
      <td>{{ "%.2f"|format(item.p.amount) }}</td>
      <td>{{ item.label }}</td>
      <td>{{ item.p.comment or "" }}</td>
      <td>
        {% if item.p.status == "pending" %}<span class="badge warn">на рассмотрении</span>
        {% elif item.p.status == "approved" %}<span class="badge ok">подтверждено</span>
        {% else %}<span class="badge bad">отклонено</span>{% endif %}
      </td>
    </tr>
    {% endfor %}
  </table>
  {% endif %}
</div>

{% if promised_enabled %}
<div class="card">
  <h2>Обещанный платёж</h2>
  {% if active_debt %}
    <p><span class="badge warn">долг</span>
       К возврату {{ "%.2f"|format(active_debt.repay_amount) }} р.
       до {{ active_debt.due_at.strftime("%d.%m.%Y %H:%M") }}.
       Списывается автоматически с баланса.</p>
  {% else %}
    <p class="muted">Можно получить {{ "%.2f"|format(promised_amount) }} р. сейчас.
       Вернуть нужно {{ "%.2f"|format(promised_amount * (1 + promised_fee / 100)) }} р.
       в течение {{ promised_repay_label }}. Списывает