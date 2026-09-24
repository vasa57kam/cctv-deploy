#!/usr/bin/env bash
set -euo pipefail
BASE="/opt/cctv"; APP="$BASE/app"; WORKER="$BASE/worker"; STORAGE="$BASE/storage"; BACKUP="$BASE/backup"; VERSION="3.3"
[[ $EUID -ne 0 ]] && { echo "Запусти через sudo или от root."; exit 1; }
echo "=== CCTV deploy v$VERSION: остановка сервисов ==="
systemctl stop cctv-web cctv-worker cctv-billing 2>/dev/null || true
mkdir -p "$APP/templates" "$WORKER" "$STORAGE/live" "$STORAGE/archive" "$STORAGE/logs" "$BACKUP"
export DEBIAN_FRONTEND=noninteractive
echo "=== Пакеты ==="
apt-get update || echo "WARNING: apt update с ошибками, продолжаю"
apt-get install -y python3 python3-venv python3-pip ffmpeg nginx sqlite3 openssl
id -u cctv &>/dev/null || useradd --system --home-dir "$BASE" --shell /usr/sbin/nologin cctv
echo "=== Резервные копии ==="
if [ -f "$APP/cctv.db" ]; then cp -a "$APP/cctv.db" "$BACKUP/cctv-$(date +%Y%m%d-%H%M%S).db"; ls -1t "$BACKUP"/cctv-*.db 2>/dev/null | tail -n +8 | xargs -r rm -f; echo "Бэкап базы создан."; fi
if [ -f "$BASE/.env" ]; then cp -a "$BASE/.env" "$BACKUP/env-$(date +%Y%m%d-%H%M%S)"; ls -1t "$BACKUP"/env-* 2>/dev/null | tail -n +8 | xargs -r rm -f; fi
echo "=== requirements.txt ==="
cat > "$APP/requirements.txt" <<'REQ_EOF'
Flask==3.0.3
Flask-SQLAlchemy==3.1.1
Flask-Login==0.6.3
gunicorn==22.0.0
REQ_EOF
echo "=== app.py ==="
cat > "$APP/app.py" <<'APP_EOF'
import os, time
from datetime import datetime, timedelta
from pathlib import Path
from functools import wraps
from flask import Flask, render_template, request, redirect, url_for, abort, send_from_directory, flash
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager, UserMixin, login_user, login_required, logout_user, current_user
from werkzeug.security import generate_password_hash, check_password_hash

BASE_DIR = Path("/opt/cctv"); STORAGE_DIR = BASE_DIR / "storage"
LIVE_DIR = STORAGE_DIR / "live"; ARCHIVE_DIR = STORAGE_DIR / "archive"; DB_PATH = BASE_DIR / "app" / "cctv.db"
DB_PATH.parent.mkdir(parents=True, exist_ok=True); LIVE_DIR.mkdir(parents=True, exist_ok=True); ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
app = Flask(__name__)
app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", "change-me")
app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{DB_PATH}"
app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
app.config["SQLALCHEMY_ENGINE_OPTIONS"] = {"connect_args": {"check_same_thread": False}}
db = SQLAlchemy(app)
login_manager = LoginManager(app)
login_manager.login_view = "login"
login_manager.login_message = "Для доступа к этой странице нужно войти."

PAY_METHODS = [("cash", "Наличные"), ("transfer", "Перевод по номеру"), ("card", "Карта онлайн"), ("promised", "Обещанный платёж"), ("other", "Другое")]
DEFAULT_SETTINGS = {
    "method_cash": "1", "method_transfer": "1", "method_card": "0", "method_promised": "1", "method_other": "0",
    "transfer_instruction": "Переведите сумму на карту Сбербанк: 0000 0000 0000 0000 (Имя Фамилия). В комментарии к заявке укажите дату перевода и последние 4 цифры карты.",
    "promised_amount": "300", "promised_repay_seconds": "604800", "promised_fee_percent": "10",
}

def method_label(code): return dict(PAY_METHODS).get(code, code)

camera_access = db.Table("camera_access",
    db.Column("id", db.Integer, primary_key=True),
    db.Column("camera_id", db.Integer, db.ForeignKey("camera.id"), nullable=False),
    db.Column("user_id", db.Integer, db.ForeignKey("user.id"), nullable=False),
    db.Column("enabled", db.Boolean, default=True))

class Setting(db.Model):
    __tablename__ = "setting"
    key = db.Column(db.String(80), primary_key=True); value = db.Column(db.Text)

class Tariff(db.Model):
    __tablename__ = "tariff"
    id = db.Column(db.Integer, primary_key=True); name = db.Column(db.String(80), nullable=False)
    price = db.Column(db.Float, nullable=False); period_days = db.Column(db.Integer, default=30)
    interval_seconds = db.Column(db.Integer, default=2592000); max_cameras = db.Column(db.Integer, default=1)
    archive_days = db.Column(db.Integer, default=7); is_active = db.Column(db.Boolean, default=True)

class User(UserMixin, db.Model):
    __tablename__ = "user"
    id = db.Column(db.Integer, primary_key=True); username = db.Column(db.String(80), unique=True, nullable=False)
    password_hash = db.Column(db.String(255), nullable=False); balance = db.Column(db.Float, default=0.0)
    credit_limit = db.Column(db.Float, default=0.0); admin = db.Column(db.Boolean, default=False)
    active = db.Column(db.Boolean, default=True); created_at = db.Column(db.DateTime, default=datetime.utcnow)
    tariff_id = db.Column(db.Integer, db.ForeignKey("tariff.id"), nullable=True)
    subscription_ends_at = db.Column(db.DateTime, nullable=True)
    tariff = db.relationship("Tariff", backref="users")
    transactions = db.relationship("Transaction", backref="user", lazy=True)
    @property
    def is_active(self): return self.active

class Camera(db.Model):
    __tablename__ = "camera"
    id = db.Column(db.Integer, primary_key=True); name = db.Column(db.String(120), nullable=False)
    rtsp_url = db.Column(db.Text, nullable=False); user_id = db.Column(db.Integer, nullable=True)
    active = db.Column(db.Boolean, default=True); recording_enabled = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    users = db.relationship("User", secondary="camera_access", backref="cameras")

class Transaction(db.Model):
    __tablename__ = "transaction"
    id = db.Column(db.Integer, primary_key=True); user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    amount = db.Column(db.Float, nullable=False); reason = db.Column(db.String(255))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

class PaymentRequest(db.Model):
    __tablename__ = "payment_request"
    id = db.Column(db.Integer, primary_key=True); user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    amount = db.Column(db.Float, nullable=False); method = db.Column(db.String(20), default="other")
    comment = db.Column(db.String(255)); status = db.Column(db.String(10), default="pending")
    user_hidden = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow); processed_at = db.Column(db.DateTime, nullable=True)
    user = db.relationship("User", backref="payment_requests")

class PromisedDebt(db.Model):
    __tablename__ = "promised_debt"
    id = db.Column(db.Integer, primary_key=True); user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    principal = db.Column(db.Float, nullable=False); repay_amount = db.Column(db.Float, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow); due_at = db.Column(db.DateTime, nullable=False)
    status = db.Column(db.String(10), default="active"); repaid_at = db.Column(db.DateTime, nullable=True)
    user = db.relationship("User", backref="promised_debts")

@login_manager.user_loader
def load_user(user_id): return db.session.get(User, int(user_id))

def get_setting(key, default=None):
    row = db.session.get(Setting, key)
    return DEFAULT_SETTINGS.get(key, default) if row is None else row.value

def set_setting(key, value):
    row = db.session.get(Setting, key)
    if row is None: db.session.add(Setting(key=key, value=value))
    else: row.value = value

def available_methods():
    return [(c, l) for c, l in PAY_METHODS if c != "promised" and get_setting(f"method_{c}", "0") == "1"]

def init_db():
    db.create_all()
    if Tariff.query.count() == 0:
        db.session.add_all([
            Tariff(name="Старт", price=290, period_days=30, interval_seconds=2592000, max_cameras=1, archive_days=3),
            Tariff(name="Базовый", price=690, period_days=30, interval_seconds=2592000, max_cameras=3, archive_days=7),
            Tariff(name="Бизнес", price=1990, period_days=30, interval_seconds=2592000, max_cameras=10, archive_days=7)])
        db.session.commit()
    au = os.environ.get("ADMIN_USERNAME", "admin"); ap = os.environ.get("ADMIN_PASSWORD", "admin123")
    if not User.query.filter_by(username=au).first():
        db.session.add(User(username=au, password_hash=generate_password_hash(ap), admin=True, active=True, balance=0.0))
        db.session.commit()

with app.app_context(): init_db()

def get_or_404(model, ident):
    obj = db.session.get(model, ident)
    if obj is None: abort(404)
    return obj

def admin_redirect(anchor):
    return redirect(url_for("admin_page") + anchor)

def user_redirect(anchor):
    return redirect(url_for("dashboard") + anchor)

def interval_label(seconds):
    seconds = int(seconds or 0)
    if seconds <= 0: return "—"
    if seconds % 2592000 == 0: return f"{seconds // 2592000} мес"
    if seconds % 86400 == 0: return f"{seconds // 86400} дн"
    if seconds % 3600 == 0: return f"{seconds // 3600} ч"
    if seconds % 60 == 0: return f"{seconds // 60} мин"
    return f"{seconds} сек"

def admin_required(f):
    @wraps(f)
    @login_required
    def decorated(*a, **kw):
        if not current_user.admin: abort(403)
        return f(*a, **kw)
    return decorated

def subscription_active(user):
    return user.subscription_ends_at is not None and user.subscription_ends_at > datetime.utcnow()

def user_link(user_id, camera_id):
    return db.session.execute(camera_access.select().where(
        camera_access.c.user_id == user_id, camera_access.c.camera_id == camera_id)).fetchone()

def enabled_cameras(user):
    rows = db.session.execute(camera_access.select().where(
        camera_access.c.user_id == user.id, camera_access.c.enabled == True).order_by(camera_access.c.camera_id)).fetchall()
    return [db.session.get(Camera, r.camera_id) for r in rows if db.session.get(Camera, r.camera_id)]

def enabled_count(user): return len(enabled_cameras(user))

def can_view_camera(camera):
    if current_user.admin: return True
    if not camera.active: return False
    row = user_link(current_user.id, camera.id)
    if row is None or not row.enabled: return False
    if not current_user.is_active: return False
    return subscription_active(current_user)

def get_camera_or_403(camera_id):
    camera = db.session.get(Camera, camera_id)
    if not camera: abort(404)
    if not can_view_camera(camera): abort(403)
    return camera

def can_add_camera_to_user(user):
    if user is None: return True
    if user.tariff is None: return False
    return enabled_count(user) < user.tariff.max_cameras

def camera_archive_days(camera):
    vals = [u.tariff.archive_days for u in camera.users if u.tariff is not None and u.tariff.archive_days]
    return max(vals) if vals else 7

def apply_tariff(user, tariff):
    now = datetime.utcnow()
    if user.balance < tariff.price:
        return False, f"Недостаточно баланса: нужно {tariff.price:.2f}, на балансе {user.balance:.2f}"
    base = now
    if user.tariff_id == tariff.id and user.subscription_ends_at and user.subscription_ends_at > now:
        base = user.subscription_ends_at
    user.balance -= tariff.price
    db.session.add(Transaction(user_id=user.id, amount=-tariff.price,
        reason=f"Списание по тарифу {tariff.name} ({interval_label(tariff.interval_seconds)})"))
    user.tariff_id = tariff.id
    user.subscription_ends_at = base + timedelta(seconds=tariff.interval_seconds or 2592000)
    db.session.commit()
    return True, f"Тариф {tariff.name} подключён до {user.subscription_ends_at:%d.%m.%Y %H:%M:%S}"

@app.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated: return redirect(url_for("dashboard"))
    if request.method == "POST":
        username = request.form.get("username", "").strip(); password = request.form.get("password", "")
        user = User.query.filter_by(username=username).first()
        if user and check_password_hash(user.password_hash, password):
            if not user.active:
                flash("Аккаунт заблокирован."); return render_template("login.html")
            login_user(user); return redirect(url_for("dashboard"))
        flash("Неверный логин или пароль.")
    return render_template("login.html")

@app.route("/logout")
@login_required
def logout():
    logout_user(); return redirect(url_for("login"))

@app.route("/")
@login_required
def dashboard():
    if current_user.admin:
        cameras = Camera.query.order_by(Camera.id.desc()).all(); cam_items = []
    else:
        cameras = []
        cam_items = [{"camera": c, "enabled": bool(user_link(current_user.id, c.id).enabled)} for c in current_user.cameras]
    tariff_options = [{"tariff": t, "label": interval_label(t.interval_seconds)} for t in Tariff.query.filter_by(is_active=True).order_by(Tariff.price).all()]
    my_requests = [{"p": p, "label": method_label(p.method)} for p in
        PaymentRequest.query.filter_by(user_id=current_user.id).order_by(PaymentRequest.id.desc()).limit(30).all()
        if not p.user_hidden][:10]
    methods = available_methods()
    transfer_instruction = get_setting("transfer_instruction", "") or ""
    promised_enabled = get_setting("method_promised", "0") == "1"
    try:
        promised_amount = float(get_setting("promised_amount", "300") or 0)
        promised_fee = float(get_setting("promised_fee_percent", "0") or 0)
        promised_repay_seconds = int(get_setting("promised_repay_seconds", "604800") or 0)
    except ValueError:
        promised_amount, promised_fee, promised_repay_seconds = 300.0, 0.0, 604800
    active_debt = PromisedDebt.query.filter_by(user_id=current_user.id, status="active").first()
    return render_template("dashboard.html", cameras=cameras, cam_items=cam_items,
        user_enabled_count=enabled_count(current_user), sub_active=subscription_active(current_user),
        tariff_options=tariff_options, my_requests=my_requests, methods=methods, transfer_instruction=transfer_instruction,
        promised_enabled=promised_enabled, promised_amount=promised_amount, promised_fee=promised_fee,
        promised_repay_seconds=promised_repay_seconds, promised_repay_label=interval_label(promised_repay_seconds), active_debt=active_debt)

@app.route("/payment/request", methods=["POST"])
@login_required
def payment_request():
    anchor = "#topup"
    try: amount = float(request.form.get("amount", "0"))
    except ValueError: flash("Некорректная сумма."); return user_redirect(anchor)
    if amount <= 0: flash("Сумма должна быть больше нуля."); return user_redirect(anchor)
    method = request.form.get("method", "other")
    if method not in [c for c, _ in available_methods()]: flash("Способ пополнения недоступен."); return user_redirect(anchor)
    comment = request.form.get("comment", "").strip()
    db.session.add(PaymentRequest(user_id=current_user.id, amount=amount, method=method, comment=comment, status="pending", created_at=datetime.utcnow()))
    db.session.commit()
    flash("Заявка создана. Администратор подтвердит пополнение.")
    return user_redirect(anchor)

@app.route("/payment/request/<int:pr_id>/comment", methods=["POST"])
@login_required
def payment_request_comment(pr_id):
    anchor = "#topup"
    pr = get_or_404(PaymentRequest, pr_id)
    if pr.user_id != current_user.id: abort(403)
    if pr.status != "pending":
        flash("Комментарий можно менять, пока заявка на рассмотрении.")
        return user_redirect(anchor)
    pr.comment = request.form.get("comment", "").strip()
    db.session.commit()
    flash("Комментарий заявки обновлён.")
    return user_redirect(anchor)

@app.route("/payment/request/<int:pr_id>/delete", methods=["POST"])
@login_required
def payment_request_delete(pr_id):
    anchor = "#topup"
    pr = get_or_404(PaymentRequest, pr_id)
    if pr.user_id != current_user.id: abort(403)
    if pr.status != "pending":
        flash("Удалить можно только необработанную заявку. Обработанную можно скрыть.")
        return user_redirect(anchor)
    db.session.delete(pr)
    db.session.commit()
    flash("Заявка удалена.")
    return user_redirect(anchor)

@app.route("/payment/request/<int:pr_id>/hide", methods=["POST"])
@login_required
def payment_request_hide(pr_id):
    anchor = "#topup"
    pr = get_or_404(PaymentRequest, pr_id)
    if pr.user_id != current_user.id: abort(403)
    pr.user_hidden = True
    db.session.commit()
    flash("Запись скрыта из вашего списка (у администратора она остаётся).")
    return user_redirect(anchor)

@app.route("/promised/connect", methods=["POST"])
@login_required
def promised_connect():
    anchor = "#promised"
    if get_setting("method_promised", "0") != "1": flash("Обещанный платёж отключён администратором."); return user_redirect(anchor)
    if PromisedDebt.query.filter_by(user_id=current_user.id, status="active").first(): flash("У вас уже есть активный обещанный платёж."); return user_redirect(anchor)
    try:
        amount = float(get_setting("promised_amount", "300")); repay_seconds = int(get_setting("promised_repay_seconds", "604800")); fee = float(get_setting("promised_fee_percent", "0"))
    except ValueError: flash("Обещанный платёж неправильно настроен."); return user_redirect(anchor)
    now = datetime.utcnow(); repay_amount = round(amount * (1 + fee / 100.0), 2)
    current_user.balance += amount
    db.session.add(Transaction(user_id=current_user.id, amount=amount, reason="Обещанный платёж: зачислено"))
    db.session.add(PromisedDebt(user_id=current_user.id, principal=amount, repay_amount=repay_amount, created_at=now, due_at=now + timedelta(seconds=repay_seconds), status="active"))
    db.session.commit()
    flash(f"Обещанный платёж {amount:.2f} подключён. К возврату {repay_amount:.2f} до {now + timedelta(seconds=repay_seconds):%d.%m.%Y %H:%M}.")
    return user_redirect(anchor)

@app.route("/promised/repay", methods=["POST"])
@login_required
def promised_repay():
    anchor = "#promised"
    debt = PromisedDebt.query.filter_by(user_id=current_user.id, status="active").first()
    if not debt: flash("Активного обещанного платежа нет."); return user_redirect(anchor)
    if current_user.balance < debt.repay_amount:
        flash(f"Недостаточно баланса для возврата: нужно {debt.repay_amount:.2f}."); return user_redirect(anchor)
    current_user.balance -= debt.repay_amount
    db.session.add(Transaction(user_id=current_user.id, amount=-debt.repay_amount, reason="Досрочный возврат обещанного платежа"))
    debt.status = "repaid"; debt.repaid_at = datetime.utcnow()
    db.session.commit()
    flash(f"Обещанный платёж погашен досрочно: {debt.repay_amount:.2f}.")
    return user_redirect(anchor)

@app.route("/tariff/choose", methods=["POST"])
@login_required
def tariff_choose():
    anchor = "#tariffs"
    try: tariff_id = int(request.form.get("tariff_id", ""))
    except ValueError: flash("Не выбран тариф."); return user_redirect(anchor)
    tariff = get_or_404(Tariff, tariff_id)
    if not tariff.is_active: flash("Тариф недоступен."); return user_redirect(anchor)
    if enabled_count(current_user) > tariff.max_cameras:
        return redirect(url_for("tariff_switch_page", tariff_id=tariff.id))
    ok, message = apply_tariff(current_user, tariff); flash(message)
    return user_redirect(anchor)

@app.route("/tariff/switch/<int:tariff_id>")
@login_required
def tariff_switch_page(tariff_id):
    tariff = get_or_404(Tariff, tariff_id)
    enabled_items = enabled_cameras(current_user)
    if len(enabled_items) <= tariff.max_cameras:
        ok, message = apply_tariff(current_user, tariff); flash(message)
        return user_redirect("#tariffs")
    return render_template("tariff_switch.html", tariff=tariff, enabled_items=enabled_items)

@app.route("/tariff/switch/<int:tariff_id>/apply", methods=["POST"])
@login_required
def tariff_switch_apply(tariff_id):
    anchor = "#tariffs"
    tariff = get_or_404(Tariff, tariff_id)
    chosen = {int(x) for x in request.form.getlist("camera_id") if x.strip().isdigit()}
    if len(chosen) > tariff.max_cameras:
        flash(f"Можно оставить не более {tariff.max_cameras} камер(ы)."); return redirect(url_for("tariff_switch_page", tariff_id=tariff.id))
    ok, message = apply_tariff(current_user, tariff)
    if not ok:
        flash(message); return user_redirect(anchor)
    for cam in current_user.cameras:
        db.session.execute(camera_access.update().where(
            camera_access.c.user_id == current_user.id, camera_access.c.camera_id == cam.id
        ).values(enabled=(cam.id in chosen)))
    db.session.commit()
    flash(message + " Лишние камеры помечены как недоступные по тарифу.")
    return user_redirect(anchor)

@app.route("/camera/<int:camera_id>/set_enabled", methods=["POST"])
@login_required
def camera_set_enabled(camera_id):
    anchor = "#cameras"
    camera = get_or_404(Camera, camera_id)
    row = user_link(current_user.id, camera.id)
    if row is None: abort(403)
    want = request.form.get("enabled") == "1"
    if want:
        if current_user.tariff is None:
            flash("Нет подключённого тарифа."); return user_redirect(anchor)
        if enabled_count(current_user) >= current_user.tariff.max_cameras:
            flash(f"Лимит тарифа: {current_user.tariff.max_cameras} камер(ы). Сначала отключите другую камеру.")
            return user_redirect(anchor)
        db.session.execute(camera_access.update().where(camera_access.c.id == row.id).values(enabled=True))
    else:
        db.session.execute(camera_access.update().where(camera_access.c.id == row.id).values(enabled=False))
    db.session.commit()
    flash(f"Камера {camera.name}: {'включена в работу' if want else 'отключена (слот освобождён)'}.")
    return user_redirect(anchor)

@app.route("/camera/<int:camera_id>")
@login_required
def camera_page(camera_id):
    camera = get_camera_or_403(camera_id); records = []
    camera_dir = ARCHIVE_DIR / f"camera_{camera.id}"
    if camera_dir.exists():
        cutoff = time.time() - camera_archive_days(camera) * 86400; now_ts = time.time()
        files = sorted(camera_dir.glob("*.mp4"), key=lambda p: p.stat().st_mtime, reverse=True)
        for p in files[:100]:
            st = p.stat()
            if st.st_mtime < cutoff: break
            records.append({"name": p.name, "ready": (now_ts - st.st_mtime) > 60, "size_mb": round(st.st_size / 1048576, 1)})
        records = records[:50]
    return render_template("camera.html", camera=camera, records=records)

@app.route("/live/<int:camera_id>/<path:filename>")
@login_required
def live_file(camera_id, filename):
    camera = get_camera_or_403(camera_id)
    return send_from_directory(str(LIVE_DIR / f"camera_{camera.id}"), filename, conditional=True)

@app.route("/archive/<int:camera_id>/<path:filename>")
@login_required
def archive_file(camera_id, filename):
    camera = get_camera_or_403(camera_id)
    return send_from_directory(str(ARCHIVE_DIR / f"camera_{camera.id}"), filename, as_attachment=False, conditional=True)

@app.route("/archive/<int:camera_id>/download/<path:filename>")
@login_required
def archive_download(camera_id, filename):
    camera = get_camera_or_403(camera_id)
    return send_from_directory(str(ARCHIVE_DIR / f"camera_{camera.id}"), filename, as_attachment=True, download_name=f"camera{camera.id}_{filename}")

@app.route("/admin")
@admin_required
def admin_page():
    users = User.query.order_by(User.id.desc()).all(); cameras = Camera.query.order_by(Camera.id.desc()).all()
    tariffs = Tariff.query.order_by(Tariff.id).all(); transactions = Transaction.query.order_by(Transaction.id.desc()).limit(50).all()
    pending_requests = [{"p": p, "label": method_label(p.method)} for p in PaymentRequest.query.filter_by(status="pending").order_by(PaymentRequest.id).all()]
    processed_requests = [{"p": p, "label": method_label(p.method)} for p in PaymentRequest.query.filter(PaymentRequest.status != "pending").order_by(PaymentRequest.id.desc()).limit(20).all()]
    debts = [{"d": d, "overdue": d.due_at < datetime.utcnow()} for d in PromisedDebt.query.filter_by(status="active").order_by(PromisedDebt.due_at).all()]
    settings = {k: get_setting(k) for k in DEFAULT_SETTINGS}
    return render_template("admin.html", users=users, cameras=cameras, tariffs=tariffs, transactions=transactions,
        pending_requests=pending_requests, processed_requests=processed_requests, debts=debts, settings=settings, methods=PAY_METHODS)

@app.route("/admin/settings", methods=["POST"])
@admin_required
def admin_settings():
    for code, _ in PAY_METHODS: set_setting(f"method_{code}", "1" if request.form.get(f"method_{code}") else "0")
    set_setting("transfer_instruction", request.form.get("transfer_instruction", "").strip())
    try:
        pa = float(request.form.get("promised_amount", "300")); rs = int(request.form.get("promised_repay_seconds", "604800")); fee = float(request.form.get("promised_fee_percent", "0"))
        if pa <= 0 or rs <= 0 or fee < 0: raise ValueError
    except ValueError: flash("Некорректные параметры обещанного платежа."); return admin_redirect("#settings")
    set_setting("promised_amount", str(pa)); set_setting("promised_repay_seconds", str(rs)); set_setting("promised_fee_percent", str(fee))
    db.session.commit(); flash("Настройки пополнения и обещанного платежа сохранены.")
    return admin_redirect("#settings")

@app.route("/admin/promised/<int:debt_id>/cancel", methods=["POST"])
@admin_required
def admin_promised_cancel(debt_id):
    debt = get_or_404(PromisedDebt, debt_id)
    if debt.status != "active": flash("Этот обещанный платёж уже закрыт."); return admin_redirect("#settings")
    debt.status = "cancelled"; debt.repaid_at = datetime.utcnow()
    db.session.commit()
    flash(f"Обещанный платёж {debt.user.username} на {debt.repay_amount:.2f} убран администратором.")
    return admin_redirect("#settings")

@app.route("/admin/user/add", methods=["POST"])
@admin_required
def admin_user_add():
    username = request.form.get("username", "").strip(); password = request.form.get("password", "").strip()
    if not username or not password: flash("Укажите логин и пароль."); return admin_redirect("#users")
    if User.query.filter_by(username=username).first(): flash("Такой пользователь уже существует."); return admin_redirect("#users")
    db.session.add(User(username=username, password_hash=generate_password_hash(password), active=True, admin=False, balance=0.0))
    db.session.commit(); flash(f"Пользователь {username} создан.")
    return admin_redirect("#users")

@app.route("/admin/user/<int:user_id>/edit", methods=["POST"])
@admin_required
def admin_user_edit(user_id):
    user = get_or_404(User, user_id); username = request.form.get("username", "").strip()
    if not username: flash("Пустой логин."); return admin_redirect("#users")
    ex = User.query.filter_by(username=username).first()
    if ex and ex.id != user.id: flash("Такой логин уже занят."); return admin_redirect("#users")
    user.username = username; db.session.commit(); flash("Пользователь обновлён.")
    return admin_redirect("#users")

@app.route("/admin/user/<int:user_id>/credit", methods=["POST"])
@admin_required
def admin_user_credit(user_id):
    user = get_or_404(User, user_id)
    try: limit = float(request.form.get("credit_limit", "0"))
    except ValueError: flash("Некорректный лимит."); return admin_redirect("#users")
    user.credit_limit = max(0.0, limit); db.session.commit()
    flash(f"Доверительный лимит {user.username}: {user.credit_limit:.2f}.")
    return admin_redirect("#users")

@app.route("/admin/user/<int:user_id>/toggle", methods=["POST"])
@admin_required
def admin_user_toggle(user_id):
    user = get_or_404(User, user_id)
    if user.id == current_user.id and user.active: flash("Нельзя заблокировать самого себя."); return admin_redirect("#users")
    user.active = not user.active; db.session.commit()
    flash(f"Пользователь {user.username} {'разблокирован' if user.active else 'заблокирован'}.")
    return admin_redirect("#users")

@app.route("/admin/user/<int:user_id>/delete", methods=["POST"])
@admin_required
def admin_user_delete(user_id):
    user = get_or_404(User, user_id)
    if user.id == current_user.id: flash("Нельзя удалить самого себя."); return admin_redirect("#users")
    for t in list(user.transactions): db.session.delete(t)
    for pr in list(user.payment_requests): db.session.delete(pr)
    for d in list(user.promised_debts): db.session.delete(d)
    db.session.execute(camera_access.delete().where(camera_access.c.user_id == user.id))
    db.session.delete(user); db.session.commit()
    flash(f"Пользователь {user.username} удалён. Камеры остались в общем пуле.")
    return admin_redirect("#users")

@app.route("/admin/user/<int:user_id>/password", methods=["POST"])
@admin_required
def admin_user_password(user_id):
    user = get_or_404(User, user_id); password = request.form.get("password", "").strip()
    if len(password) < 4: flash("Пароль должен быть не короче 4 символов."); return admin_redirect("#users")
    user.password_hash = generate_password_hash(password); db.session.commit()
    flash(f"Пароль пользователя {user.username} изменён.")
    return admin_redirect("#users")

@app.route("/admin/user/topup", methods=["POST"])
@admin_required
def admin_topup():
    try:
        user_id = int(request.form.get("user_id", "")); amount = float(request.form.get("amount", ""))
    except ValueError: flash("Некорректные данные."); return admin_redirect("#users")
    user = get_or_404(User, user_id); user.balance += amount
    reason = request.form.get("reason", "").strip() or method_label(request.form.get("method", "other"))
    db.session.add(Transaction(user_id=user.id, amount=amount, reason=f"Пополнение ({reason})"))
    db.session.commit(); flash(f"Баланс пользователя {user.username} изменён на {amount}.")
    return admin_redirect("#users")

@app.route("/admin/user/<int:user_id>/tariff", methods=["POST"])
@admin_required
def admin_user_tariff(user_id):
    user = get_or_404(User, user_id)
    try: tariff_id = int(request.form.get("tariff_id", ""))
    except ValueError: flash("Не выбран тариф."); return admin_redirect("#users")
    tariff = get_or_404(Tariff, tariff_id)
    if enabled_count(user) > tariff.max_cameras:
        flash(f"У {user.username} активных камер больше, чем разрешает тариф {tariff.name}. Сначала отзовите лишние доступы.")
        return admin_redirect("#cameras")
    ok, message = apply_tariff(user, tariff); flash(message)
    return admin_redirect("#users")

@app.route("/admin/payment/<int:pr_id>/approve", methods=["POST"])
@admin_required
def admin_payment_approve(pr_id):
    pr = get_or_404(PaymentRequest, pr_id)
    if pr.status != "pending": flash("Заявка уже обработана."); return admin_redirect("#requests")
    pr.status = "approved"; pr.processed_at = datetime.utcnow(); pr.user.balance += pr.amount
    db.session.add(Transaction(user_id=pr.user_id, amount=pr.amount, reason=f"Пополнение ({method_label(pr.method)})" + (f": {pr.comment}" if pr.comment else "")))
    db.session.commit(); flash(f"Пополнение {pr.amount:.2f} для {pr.user.username} подтверждено.")
    return admin_redirect("#requests")

@app.route("/admin/payment/<int:pr_id>/reject", methods=["POST"])
@admin_required
def admin_payment_reject(pr_id):
    pr = get_or_404(PaymentRequest, pr_id)
    if pr.status != "pending": flash("Заявка уже обработана."); return admin_redirect("#requests")
    pr.status = "rejected"; pr.processed_at = datetime.utcnow(); db.session.commit()
    flash("Заявка отклонена.")
    return admin_redirect("#requests")

@app.route("/admin/transaction/<int:tx_id>/delete", methods=["POST"])
@admin_required
def admin_transaction_delete(tx_id):
    tx = get_or_404(Transaction, tx_id)
    db.session.delete(tx); db.session.commit()
    flash("Транзакция удалена.")
    return admin_redirect("#transactions")

@app.route("/admin/transactions/clear", methods=["POST"])
@admin_required
def admin_transactions_clear():
    n = Transaction.query.delete()
    db.session.commit()
    flash(f"История транзакций очищена ({n} шт.). Балансы не изменились.")
    return admin_redirect("#transactions")

@app.route("/admin/tariff/add", methods=["POST"])
@admin_required
def admin_tariff_add():
    name = request.form.get("name", "").strip()
    try:
        price = float(request.form.get("price", "0")); iv = int(request.form.get("interval_seconds", "2592000"))
        mc = int(request.form.get("max_cameras", "1")); ad = int(request.form.get("archive_days", "7"))
    except ValueError: flash("Некорректные числа в тарифе."); return admin_redirect("#tariffs")
    if not name or price <= 0 or iv <= 0: flash("Название, цена и интервал должны быть положительными."); return admin_redirect("#tariffs")
    db.session.add(Tariff(name=name, price=price, period_days=max(1, iv // 86400) if iv >= 86400 else 1, interval_seconds=iv, max_cameras=mc, archive_days=ad, is_active=True))
    db.session.commit(); flash(f"Тариф {name} добавлен ({interval_label(iv)}).")
    return admin_redirect("#tariffs")

@app.route("/admin/tariff/<int:tariff_id>/edit", methods=["POST"])
@admin_required
def admin_tariff_edit(tariff_id):
    tariff = get_or_404(Tariff, tariff_id); name = request.form.get("name", "").strip()
    try:
        price = float(request.form.get("price", "0")); iv = int(request.form.get("interval_seconds", "2592000"))
        mc = int(request.form.get("max_cameras", "1")); ad = int(request.form.get("archive_days", "7"))
    except ValueError: flash("Некорректные числа в тарифе."); return admin_redirect("#tariffs")
    if not name or price <= 0 or iv <= 0: flash("Название, цена и интервал должны быть положительными."); return admin_redirect("#tariffs")
    tariff.name = name; tariff.price = price; tariff.interval_seconds = iv
    tariff.period_days = max(1, iv // 86400) if iv >= 86400 else 1; tariff.max_cameras = mc; tariff.archive_days = ad
    db.session.commit(); flash(f"Тариф {name} обновлён ({interval_label(iv)}).")
    return admin_redirect("#tariffs")

@app.route("/admin/tariff/<int:tariff_id>/toggle", methods=["POST"])
@admin_required
def admin_tariff_toggle(tariff_id):
    tariff = get_or_404(Tariff, tariff_id); tariff.is_active = not tariff.is_active; db.session.commit()
    flash(f"Тариф {tariff.name}: {'включён' if tariff.is_active else 'выключен'}.")
    return admin_redirect("#tariffs")

@app.route("/admin/tariff/<int:tariff_id>/delete", methods=["POST"])
@admin_required
def admin_tariff_delete(tariff_id):
    tariff = get_or_404(Tariff, tariff_id)
    if tariff.users: flash(f"Тариф {tariff.name} нельзя удалить: на нём есть пользователи."); return admin_redirect("#tariffs")
    name = tariff.name; db.session.delete(tariff); db.session.commit()
    flash(f"Тариф {name} удалён.")
    return admin_redirect("#tariffs")

@app.route("/admin/camera/add", methods=["POST"])
@admin_required
def admin_camera_add():
    name = request.form.get("name", "").strip(); rtsp_url = request.form.get("rtsp_url", "").strip()
    if not name or not rtsp_url: flash("Укажите название камеры и RTSP."); return admin_redirect("#cameras")
    db.session.add(Camera(name=name, rtsp_url=rtsp_url, active=True, recording_enabled=False))
    db.session.commit(); flash(f"Камера {name} добавлена в пул. Запись выключена, включи кнопкой.")
    return admin_redirect("#cameras")

@app.route("/admin/camera/<int:camera_id>/edit", methods=["POST"])
@admin_required
def admin_camera_edit(camera_id):
    camera = get_or_404(Camera, camera_id); name = request.form.get("name", "").strip(); rtsp_url = request.form.get("rtsp_url", "").strip()
    if not name or not rtsp_url: flash("Укажите название и RTSP."); return admin_redirect("#cameras")
    camera.name = name; camera.rtsp_url = rtsp_url; db.session.commit()
    flash(f"Камера {name} обновлена. Воркер подхватит за несколько секунд.")
    return admin_redirect("#cameras")

@app.route("/admin/camera/<int:camera_id>/grant", methods=["POST"])
@admin_required
def admin_camera_grant(camera_id):
    camera = get_or_404(Camera, camera_id)
    try: user_id = int(request.form.get("user_id", ""))
    except ValueError: flash("Не выбран пользователь."); return admin_redirect("#cameras")
    user = get_or_404(User, user_id)
    if user_link(user.id, camera.id) is not None: flash("Доступ уже выдан."); return admin_redirect("#cameras")
    if not can_add_camera_to_user(user): flash(f"У {user.username} лимит камер по тарифу или нет тарифа."); return admin_redirect("#cameras")
    db.session.execute(camera_access.insert().values(camera_id=camera.id, user_id=user.id, enabled=True))
    db.session.commit()
    flash(f"Доступ к {camera.name} выдан пользователю {user.username}.")
    return admin_redirect("#cameras")

@app.route("/admin/camera/<int:camera_id>/revoke", methods=["POST"])
@admin_required
def admin_camera_revoke(camera_id):
    camera = get_or_404(Camera, camera_id)
    try: user_id = int(request.form.get("user_id", ""))
    except ValueError: flash("Не выбран пользователь."); return admin_redirect("#cameras")
    row = user_link(user_id, camera.id)
    if row is None: flash("У этого пользователя не было доступа."); return admin_redirect("#cameras")
    db.session.execute(camera_access.delete().where(camera_access.c.id == row.id))
    db.session.commit()
    flash(f"Доступ к {camera.name} отозван.")
    return admin_redirect("#cameras")

@app.route("/admin/camera/<int:camera_id>/toggle", methods=["POST"])
@admin_required
def admin_camera_toggle(camera_id):
    camera = get_or_404(Camera, camera_id); camera.active = not camera.active; db.session.commit()
    flash(f"Камера {camera.name} {'включена' if camera.active else 'выключена'}.")
    return admin_redirect("#cameras")

@app.route("/admin/camera/<int:camera_id>/recording", methods=["POST"])
@admin_required
def admin_camera_recording(camera_id):
    camera = get_or_404(Camera, camera_id); camera.recording_enabled = not camera.recording_enabled; db.session.commit()
    flash(f"Камера {camera.name}: запись {'ВКЛЮЧЕНА' if camera.recording_enabled else 'выключена'}.")
    return admin_redirect("#cameras")

@app.route("/admin/camera/<int:camera_id>/delete", methods=["POST"])
@admin_required
def admin_camera_delete(camera_id):
    camera = get_or_404(Camera, camera_id); name = camera.name
    db.session.execute(camera_access.delete().where(camera_access.c.camera_id == camera.id))
    db.session.delete(camera); db.session.commit()
    flash(f"Камера {name} удалена из пула. Файлы архива останутся на диске.")
    return admin_redirect("#cameras")

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
.card,details.card{background:var(--card);border:1px solid #2b3b57;border-radius:14px;padding:18px;margin-bottom:18px;}
summary{cursor:pointer;font-size:17px;font-weight:600;}
summary::-webkit-details-marker{display:none;}
summary::before{content:"▸ ";color:var(--accent);}
details[open] > summary::before{content:"▾ ";}
details[open] > summary{margin-bottom:12px;}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:14px;}
.cam{background:#16233c;border:1px solid #2b3b57;border-radius:12px;padding:14px;}
.cam h3{margin:0 0 8px;font-size:16px;}
.btn{display:inline-block;background:var(--accent);color:#082032;border:none;border-radius:8px;padding:8px 14px;font-size:14px;cursor:pointer;text-decoration:none;}
.btn:hover{filter:brightness(1.1);}
.btn.gray{background:#334155;color:var(--text);}
.btn.red{background:#7f1d1d;color:#fecaca;}
.btn.mini{padding:4px 8px;font-size:12px;}
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
  <span class="badge warn">v3.3</span>
  {% if current_user.is_authenticated %}
    <a href="{{ url_for('dashboard') }}">Мои камеры</a>
    {% if current_user.admin %}<a href="{{ url_for('admin_page') }}">Админка</a>{% endif %}
    <span class="spacer"></span>
    {% if not current_user.admin %}<a class="muted" href="/#topup">Баланс: {{ "%.2f"|format(current_user.balance) }} р. → пополнить</a>{% endif %}
    <a href="{{ url_for('logout') }}">Выход ({{ current_user.username }})</a>
  {% else %}
    <span class="spacer"></span>
    <a href="{{ url_for('login') }}">Вход</a>
  {% endif %}
</header>
<main>
{% with messages = get_flashed_messages() %}
  {% if messages %}<ul class="messages">{% for m in messages %}<li>{{ m }}</li>{% endfor %}</ul>{% endif %}
{% endwith %}
{% block content %}{% endblock %}
</main>
<script>
document.addEventListener("DOMContentLoaded", function () {
  var h = window.location.hash;
  if (!h) return;
  var el = document.querySelector(h);
  if (el) {
    if (el.tagName === "DETAILS") el.open = true;
    setTimeout(function () { el.scrollIntoView({block: "start"}); }, 60);
  }
});
</script>
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
<div class="card" id="subscribe">
  <h2>Подписка</h2>
  {% if current_user.tariff %}
    <p>Тариф: <b>{{ current_user.tariff.name }}</b> (камер: {{ current_user.tariff.max_cameras }}, архив: {{ current_user.tariff.archive_days }} дн.)
       {% if sub_active %}<span class="badge ok">активна</span> до {{ current_user.subscription_ends_at.strftime("%d.%m.%Y %H:%M:%S") }}
       {% else %}<span class="badge bad">истекла</span>{% endif %}</p>
  {% else %}<p><span class="badge warn">тариф не подключён</span> выберите тариф в блоке «Тарифы» ниже</p>{% endif %}
  <p class="muted">Баланс: {{ "%.2f"|format(current_user.balance) }} р.{% if current_user.credit_limit %} Доверительный лимит: {{ "%.2f"|format(current_user.credit_limit) }} р.{% endif %} Активных камер: {{ user_enabled_count }}.</p>
</div>

<details class="card" id="topup" open>
<summary>Пополнить баланс</summary>
{% if methods %}
<form method="post" action="{{ url_for('payment_request') }}" class="formrow">
  <input name="amount" placeholder="Сумма" required>
  <select name="method" id="topup-method">{% for code, label in methods %}<option value="{{ code }}">{{ label }}</option>{% endfor %}</select>
  <input name="comment" placeholder="Комментарий / номер перевода" style="flex:1">
  <button class="btn" type="submit">Создать заявку</button>
</form>
<p class="muted" id="hint-box" style="white-space:pre-line"></p>
<script>
(function () {
  var hints = {
    {% for code, label in methods %}
    "{{ code }}": {% if code == "transfer" %}{{ transfer_instruction | tojson }}{% elif code == "cash" %}"Оплатите наличными и создайте заявку — администратор подтвердит поступление."{% elif code == "card" %}"Онлайн-оплата картой появится после подключения платёжного шлюза."{% else %}"Укажите реквизиты или комментарий к заявке — администратор свяжется для подтверждения."{% endif %},
    {% endfor %}
  };
  var sel = document.getElementById("topup-method");
  var box = document.getElementById("hint-box");
  function upd() { box.textContent = hints[sel.value] || ""; }
  if (sel) { sel.addEventListener("change", upd); upd(); }
})();
</script>
{% else %}
<p class="muted">Способы пополнения сейчас отключены администратором.</p>
{% endif %}
{% if my_requests %}
<table>
  <tr><th>ID</th><th>Сумма</th><th>Способ</th><th>Комментарий</th><th>Статус</th><th></th></tr>
  {% for item in my_requests %}
  <tr><td>{{ item.p.id }}</td><td>{{ "%.2f"|format(item.p.amount) }}</td><td>{{ item.label }}</td><td>{{ item.p.comment or "" }}</td>
  <td>{% if item.p.status == "pending" %}<span class="badge warn">на рассмотрении</span>{% elif item.p.status == "approved" %}<span class="badge ok">подтверждено</span>{% else %}<span class="badge bad">отклонено</span>{% endif %}</td>
  <td>
    {% if item.p.status == "pending" %}
      <form method="post" action="{{ url_for('payment_request_comment', pr_id=item.p.id) }}" class="formrow" style="margin:0;">
        <input name="comment" value="{{ item.p.comment or '' }}" placeholder="Новый комментарий">
        <button class="btn gray mini" type="submit">Изменить</button>
      </form>
      <form method="post" action="{{ url_for('payment_request_delete', pr_id=item.p.id) }}" style="display:inline" onsubmit="return confirm('Удалить заявку #{{ item.p.id }}?');">
        <button class="btn red mini" type="submit">Удалить</button>
      </form>
    {% else %}
      <form method="post" action="{{ url_for('payment_request_hide', pr_id=item.p.id) }}" style="display:inline">
        <button class="btn gray mini" type="submit">Скрыть</button>
      </form>
    {% endif %}
  </td></tr>
  {% endfor %}
</table>
<p class="muted">Пока заявка «на рассмотрении» — можно менять комментарий или удалить её. Обработанные записи можно скрыть из своего списка (у администратора они остаются).</p>
{% endif %}
</details>

{% if promised_enabled %}
<details class="card" id="promised" {% if active_debt %}open{% endif %}>
<summary>Обещанный платёж</summary>
{% if active_debt %}
  <p><span class="badge warn">долг</span> К возврату {{ "%.2f"|format(active_debt.repay_amount) }} р. до {{ active_debt.due_at.strftime("%d.%m.%Y %H:%M") }}. Списывается автоматически с баланса.</p>
  <form method="post" action="{{ url_for('promised_repay') }}" class="formrow" onsubmit="return confirm('Вернуть долг досрочно?');">
    <button class="btn gray" type="submit">Вернуть досрочно {{ "%.2f"|format(active_debt.repay_amount) }} р.</button>
  </form>
{% else %}
  <p class="muted">Можно получить {{ "%.2f"|format(promised_amount) }} р. сейчас. Вернуть нужно {{ "%.2f"|format(promised_amount * (1 + promised_fee / 100)) }} р. в течение {{ promised_repay_label }}. Списывается автоматически, можно вернуть досрочно.</p>
  <form method="post" action="{{ url_for('promised_connect') }}" onsubmit="return confirm('Подключить обещанный платёж?');">
    <button class="btn" type="submit">Подключить обещанный платёж</button>
  </form>
{% endif %}
</details>
{% endif %}

<details class="card" id="tariffs">
<summary>Тарифы: подключить / продлить</summary>
<table>
  <tr><th>Тариф</th><th>Цена</th><th>Списание</th><th>Камер</th><th>Архив</th><th></th></tr>
  {% for opt in tariff_options %}
  <tr><td>{{ opt.tariff.name }}{% if current_user.tariff_id == opt.tariff.id %} <span class="badge ok">текущий</span>{% endif %}</td>
  <td>{{ "%.2f"|format(opt.tariff.price) }} р.</td><td>{{ opt.label }}</td><td>{{ opt.tariff.max_cameras }}</td><td>{{ opt.tariff.archive_days }} дн.</td>
  <td><form method="post" action="{{ url_for('tariff_choose') }}" style="display:inline" onsubmit="return confirm('Подключить/продлить тариф {{ opt.tariff.name }}? Цена спишется с баланса.');">
    <input type="hidden" name="tariff_id" value="{{ opt.tariff.id }}">
    <button class="btn" type="submit">{{ "Продлить" if current_user.tariff_id == opt.tariff.id else "Подключить" }}</button></form></td></tr>
  {% endfor %}
</table>
<p class="muted">Если на новом тарифе разрешено меньше камер, чем у вас подключено, система попросит выбрать, какие останутся рабочими.</p>
</details>
{% endif %}

<div id="cameras">
<h1>Мои камеры</h1>
{% if current_user.admin %}
  {% if cameras %}
  <div class="grid">
    {% for camera in cameras %}
    <div class="cam">
      <h3>{{ camera.name }}</h3>
      <p>{% if camera.active %}<span class="badge ok">вкл</span>{% else %}<span class="badge bad">выкл</span>{% endif %}
         {% if camera.recording_enabled %}<span class="badge ok">запись</span>{% else %}<span class="badge warn">без записи</span>{% endif %}</p>
      <a class="btn" href="{{ url_for('camera_page', camera_id=camera.id) }}">Открыть</a>
    </div>
    {% endfor %}
  </div>
  {% else %}<div class="card"><p class="muted">Камер пока нет.</p></div>{% endif %}
{% else %}
  {% if cam_items %}
  <div class="grid">
    {% for item in cam_items %}
    <div class="cam">
      <h3>{{ item.camera.name }}</h3>
      <p>{% if item.enabled %}<span class="badge ok">работает</span>{% else %}<span class="badge bad">недоступна по тарифу</span>{% endif %}
         {% if item.camera.recording_enabled %}<span class="badge ok">запись</span>{% else %}<span class="badge warn">без записи</span>{% endif %}</p>
      {% if item.enabled %}
        <a class="btn" href="{{ url_for('camera_page', camera_id=item.camera.id) }}">Открыть</a>
        <form method="post" action="{{ url_for('camera_set_enabled', camera_id=item.camera.id) }}" style="display:inline">
          <input type="hidden" name="enabled" value="0">
          <button class="btn gray" type="submit">Отключить</button>
        </form>
      {% else %}
        <form method="post" action="{{ url_for('camera_set_enabled', camera_id=item.camera.id) }}" style="display:inline">
          <input type="hidden" name="enabled" value="1">
          <button class="btn gray" type="submit">Включить</button>
        </form>
      {% endif %}
    </div>
    {% endfor %}
  </div>
  {% else %}<div class="card"><p class="muted">Камер пока нет.</p></div>{% endif %}
{% endif %}
</div>
{% endblock %}
DASH_EOF
echo "=== tariff_switch.html ==="
cat > "$APP/templates/tariff_switch.html" <<'SWITCH_EOF'
{% extends "base.html" %}
{% block content %}
<div class="card">
  <h1>Внимание: смена тарифа</h1>
  <p>Вы переходите на тариф <b>{{ tariff.name }}</b>. Он разрешает не более <b>{{ tariff.max_cameras }}</b> активных камер(ы).
     Сейчас у вас активных камер: <b>{{ enabled_items|length }}</b>.</p>
  <p>Выберите, какие камеры останутся рабочими. Остальные не удалятся — они станут
     «недоступны по тарифу», и вы сможете включить их позже, если освободите слот или вернётесь на тариф выше.</p>
  <form method="post" action="{{ url_for('tariff_switch_apply', tariff_id=tariff.id) }}">
    <table>
      <tr><th></th><th>Камера</th></tr>
      {% for cam in enabled_items %}
      <tr><td><input type="checkbox" name="camera_id" value="{{ cam.id }}" checked></td><td>{{ cam.name }}</td></tr>
      {% endfor %}
    </table>
    <p class="muted">Отметьте не более {{ tariff.max_cameras }}. Цена тарифа {{ "%.2f"|format(tariff.price) }} р. спишется сразу.</p>
    <button class="btn" type="submit">Переключить тариф</button>
    <a class="btn gray" href="{{ url_for('dashboard') }}#tariffs">Отмена</a>
  </form>
</div>
{% endblock %}
SWITCH_EOF
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
    <tr><td>{{ rec.name }}</td><td>{{ rec.size_mb }} МБ</td>
    <td>{% if rec.ready %}<span class="badge ok">готов</span>{% else %}<span class="badge warn">идёт запись…</span>{% endif %}</td>
    <td><a class="btn gray" href="{{ url_for('archive_file', camera_id=camera.id, filename=rec.name) }}" target="_blank">Смотреть</a>
    {% if rec.ready %}<a class="btn" href="{{ url_for('archive_download', camera_id=camera.id, filename=rec.name) }}">Скачать</a>{% endif %}</td></tr>
    {% endfor %}
  </table>
  {% else %}<p class="muted">Архив пуст: запись ещё не началась или выключена.</p>{% endif %}
</div>
<script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
<script>
const video = document.getElementById("video");
const statusEl = document.getElementById("player-status");
const src = "{{ url_for('live_file', camera_id=camera.id, filename='index.m3u8') }}";
if (window.Hls && Hls.isSupported()) {
  const hls = new Hls();
  hls.loadSource(src); hls.attachMedia(video);
  hls.on(Hls.Events.ERROR, function(e, data) { if (data.fatal) statusEl.textContent = "Нет сигнала: камера офлайн или поток недоступен"; });
} else { video.src = src; }
</script>
{% endblock %}
CAM_EOF
echo "=== admin.html ==="
cat > "$APP/templates/admin.html" <<'ADMIN_EOF'
{% extends "base.html" %}
{% block content %}
<h1>Админка <span class="badge warn">v3.3</span></h1>

<details class="card" id="requests" {% if pending_requests %}open{% endif %}>
<summary>Заявки на пополнение {% if pending_requests %}<span class="badge warn">новых: {{ pending_requests|length }}</span>{% endif %}</summary>
{% if pending_requests %}
<table><tr><th>ID</th><th>Пользователь</th><th>Сумма</th><th>Способ</th><th>Комментарий</th><th>Действия</th></tr>
{% for item in pending_requests %}<tr><td>{{ item.p.id }}</td><td>{{ item.p.user.username }}</td><td>{{ "%.2f"|format(item.p.amount) }}</td><td>{{ item.label }}</td><td>{{ item.p.comment or "" }}</td>
<td><form method="post" action="{{ url_for('admin_payment_approve', pr_id=item.p.id) }}" style="display:inline"><button class="btn" type="submit">Подтвердить</button></form>
<form method="post" action="{{ url_for('admin_payment_reject', pr_id=item.p.id) }}" style="display:inline"><button class="btn red" type="submit">Отклонить</button></form></td></tr>{% endfor %}</table>
{% else %}<p class="muted">Новых заявок нет.</p>{% endif %}
{% if processed_requests %}
<h2>История заявок</h2>
<table><tr><th>ID</th><th>Пользователь</th><th>Сумма</th><th>Способ</th><th>Статус</th></tr>
{% for item in processed_requests %}<tr><td>{{ item.p.id }}</td><td>{{ item.p.user.username }}</td><td>{{ "%.2f"|format(item.p.amount) }}</td><td>{{ item.label }}</td>
<td>{% if item.p.status == "approved" %}<span class="badge ok">подтверждено</span>{% else %}<span class="badge bad">отклонено</span>{% endif %}</td></tr>{% endfor %}</table>
{% endif %}
</details>

<details class="card" id="cameras" open>
<summary>Камеры (общий пул) — {{ cameras|length }}</summary>
<table><tr><th>ID</th><th>Название</th><th>Статус</th><th>Доступ выдан</th><th>Выдать доступ</th><th>Действия</th></tr>
{% for cam in cameras %}
<tr><td>{{ cam.id }}</td><td>{{ cam.name }}<br><span class="muted">{{ cam.rtsp_url }}</span></td>
<td>{% if cam.active %}<span class="badge ok">вкл</span>{% else %}<span class="badge bad">выкл</span>{% endif %} {% if cam.recording_enabled %}<span class="badge ok">запись</span>{% else %}<span class="badge warn">без записи</span>{% endif %}</td>
<td>{% for u in cam.users %}<span class="badge ok">{{ u.username }}</span> <form method="post" action="{{ url_for('admin_camera_revoke', camera_id=cam.id) }}" style="display:inline"><input type="hidden" name="user_id" value="{{ u.id }}"><button class="btn gray mini" type="submit">отозвать</button></form><br>{% else %}<span class="muted">никому</span>{% endfor %}</td>
<td><form method="post" action="{{ url_for('admin_camera_grant', camera_id=cam.id) }}" class="formrow"><select name="user_id">{% for u in users %}<option value="{{ u.id }}">{{ u.username }}</option>{% endfor %}</select><button class="btn gray" type="submit">Выдать</button></form></td>
<td><form method="post" action="{{ url_for('admin_camera_recording', camera_id=cam.id) }}" style="display:inline"><button class="btn gray mini" type="submit">{{ "Выкл запись" if cam.recording_enabled else "Вкл запись" }}</button></form>
<form method="post" action="{{ url_for('admin_camera_toggle', camera_id=cam.id) }}" style="display:inline"><button class="btn gray mini" type="submit">{{ "Выкл" if cam.active else "Вкл" }}</button></form>
<form method="post" action="{{ url_for('admin_camera_delete', camera_id=cam.id) }}" style="display:inline" onsubmit="return confirm('Удалить камеру {{ cam.name }} из пула?');"><button class="btn red mini" type="submit">Удалить</button></form></td></tr>
<tr><td colspan="6" class="muted"><form method="post" action="{{ url_for('admin_camera_edit', camera_id=cam.id) }}" class="formrow" style="margin:0;"><input name="name" value="{{ cam.name }}" placeholder="Название"><input name="rtsp_url" value="{{ cam.rtsp_url }}" placeholder="rtsp://..." style="flex:1"><button class="btn gray" type="submit">Сохранить камеру</button></form></td></tr>
{% endfor %}
</table>
<h2>Добавить камеру в пул</h2>
<form method="post" action="{{ url_for('admin_camera_add') }}" class="formrow"><input name="name" placeholder="Название" required><input name="rtsp_url" placeholder="rtsp://login:pass@ip/stream" required style="flex:1"><button class="btn" type="submit">Добавить</button></form>
</details>

<details class="card" id="users">
<summary>Пользователи — {{ users|length }}</summary>
<table><tr><th>ID</th><th>Логин</th><th>Баланс</th><th>Лимит</th><th>Тариф</th><th>Оплачено до</th><th>Статус</th><th>Действия</th></tr>
{% for u in users %}
<tr><td>{{ u.id }}</td><td>{{ u.username }}{% if u.admin %} <span class="badge warn">админ</span>{% endif %}</td><td>{{ "%.2f"|format(u.balance) }}</td><td>{{ "%.2f"|format(u.credit_limit or 0) }}</td>
<td>{{ u.tariff.name if u.tariff else "—" }}</td><td>{{ u.subscription_ends_at.strftime("%d.%m.%Y %H:%M:%S") if u.subscription_ends_at else "—" }}</td>
<td>{% if u.active %}<span class="badge ok">активен</span>{% else %}<span class="badge bad">заблокирован</span>{% endif %}</td>
<td><form method="post" action="{{ url_for('admin_user_toggle', user_id=u.id) }}" style="display:inline"><button class="btn gray mini" type="submit">{{ "Блок" if u.active else "Разблок" }}</button></form>
{% if not u.admin %}<form method="post" action="{{ url_for('admin_user_delete', user_id=u.id) }}" style="display:inline" onsubmit="return confirm('Удалить пользователя {{ u.username }}? Камеры останутся в пуле.');"><button class="btn red mini" type="submit">Удалить</button></form>{% endif %}</td></tr>
<tr><td colspan="8" class="muted">
  <form method="post" action="{{ url_for('admin_user_edit', user_id=u.id) }}" class="formrow" style="margin:0;"><input name="username" value="{{ u.username }}" placeholder="Новый логин"><button class="btn gray mini" type="submit">Переименовать</button></form>
  <form method="post" action="{{ url_for('admin_user_credit', user_id=u.id) }}" class="formrow" style="margin:4px 0 0 0;"><input name="credit_limit" value="{{ u.credit_limit or 0 }}" placeholder="Доверительный лимит"><button class="btn gray mini" type="submit">Задать лимит</button></form>
</td></tr>
{% endfor %}
</table>
<h2>Добавить пользователя</h2>
<form method="post" action="{{ url_for('admin_user_add') }}" class="formrow"><input name="username" placeholder="Логин" required><input name="password" type="password" placeholder="Пароль" required><button class="btn" type="submit">Создать</button></form>
<h2>Сменить пароль пользователю (включая себя)</h2>
<form method="post" id="pass-form" class="formrow"><select name="user_id" id="pass-user">{% for u in users %}<option value="{{ u.id }}">{{ u.username }}</option>{% endfor %}</select><input type="password" name="password" placeholder="Новый пароль" required><button class="btn" type="submit">Сменить пароль</button></form>
<h2>Пополнить баланс вручную</h2>
<form method="post" action="{{ url_for('admin_topup') }}" class="formrow"><select name="user_id">{% for u in users %}<option value="{{ u.id }}">{{ u.username }}</option>{% endfor %}</select><input name="amount" placeholder="100 или -100" required><select name="method">{% for code, label in methods %}<option value="{{ code }}">{{ label }}</option>{% endfor %}</select><input name="reason" placeholder="Причина (необязательно)"><button class="btn" type="submit">Применить</button></form>
<h2>Подключить тариф пользователю (списание с баланса)</h2>
<form method="post" id="tariff-form" class="formrow"><select name="user_id" id="tariff-user">{% for u in users %}<option value="{{ u.id }}">{{ u.username }}</option>{% endfor %}</select><select name="tariff_id">{% for t in tariffs %}<option value="{{ t.id }}">{{ t.name }} — {{ t.price }}</option>{% endfor %}</select><button class="btn" type="submit">Подключить</button></form>
</details>

<details class="card" id="tariffs">
<summary>Тарифы — {{ tariffs|length }}</summary>
<table><tr><th>Название</th><th>Цена</th><th>Списание</th><th>Камер</th><th>Архив</th><th>Статус</th><th></th></tr>
{% for t in tariffs %}
<tr><td>{{ t.name }}</td><td>{{ t.price }}</td>
<td>{% if t.interval_seconds % 2592000 == 0 %}{{ t.interval_seconds // 2592000 }} мес{% elif t.interval_seconds % 86400 == 0 %}{{ t.interval_seconds // 86400 }} дн{% elif t.interval_seconds % 3600 == 0 %}{{ t.interval_seconds // 3600 }} ч{% elif t.interval_seconds % 60 == 0 %}{{ t.interval_seconds // 60 }} мин{% else %}{{ t.interval_seconds }} сек{% endif %}</td>
<td>{{ t.max_cameras }}</td><td>{{ t.archive_days }} дн.</td><td>{% if t.is_active %}<span class="badge ok">активен</span>{% else %}<span class="badge bad">скрыт</span>{% endif %}</td>
<td><form method="post" action="{{ url_for('admin_tariff_toggle', tariff_id=t.id) }}" style="display:inline"><button class="btn gray mini" type="submit">{{ "Выкл" if t.is_active else "Вкл" }}</button></form>
<form method="post" action="{{ url_for('admin_tariff_delete', tariff_id=t.id) }}" style="display:inline" onsubmit="return confirm('Удалить тариф {{ t.name }}?');"><button class="btn red mini" type="submit">Удалить</button></form></td></tr>
<tr><td colspan="7" class="muted"><form method="post" action="{{ url_for('admin_tariff_edit', tariff_id=t.id) }}" class="formrow" style="margin:0;">
<input name="name" value="{{ t.name }}" placeholder="Название"><input name="price" value="{{ t.price }}" placeholder="Цена">
<select name="interval_seconds">{% if t.interval_seconds not in [1,60,3600,86400,2592000] %}<option value="{{ t.interval_seconds }}" selected>{{ t.interval_seconds }} сек (тек.)</option>{% endif %}<option value="1" {% if t.interval_seconds == 1 %}selected{% endif %}>посекундно</option><option value="60" {% if t.interval_seconds == 60 %}selected{% endif %}>поминутно</option><option value="3600" {% if t.interval_seconds == 3600 %}selected{% endif %}>почасово</option><option value="86400" {% if t.interval_seconds == 86400 %}selected{% endif %}>подневно</option><option value="2592000" {% if t.interval_seconds == 2592000 %}selected{% endif %}>помесячно</option></select>
<input name="max_cameras" value="{{ t.max_cameras }}" placeholder="Камер"><input name="archive_days" value="{{ t.archive_days }}" placeholder="Архив дней"><button class="btn gray" type="submit">Сохранить тариф</button></form></td></tr>
{% endfor %}
</table>
<h2>Добавить тариф</h2>
<form method="post" action="{{ url_for('admin_tariff_add') }}" class="formrow"><input name="name" placeholder="Название" required><input name="price" placeholder="Цена за интервал" required>
<select name="interval_seconds"><option value="1">посекундно</option><option value="60">поминутно</option><option value="3600">почасово</option><option value="86400">подневно</option><option value="2592000" selected>помесячно</option></select>
<input name="max_cameras" placeholder="Камер" value="1"><input name="archive_days" placeholder="Архив дней" value="7"><button class="btn" type="submit">Добавить</button></form>
</details>

<details class="card" id="settings">
<summary>Настройки пополнения и обещанного платежа</summary>
<form method="post" action="{{ url_for('admin_settings') }}">
  <p>{% for code, label in methods %}<label style="margin-right:16px;"><input type="checkbox" name="method_{{ code }}" value="1" {% if settings['method_' + code] == '1' %}checked{% endif %}> {{ label }}</label>{% endfor %}</p>
  <p class="muted">Инструкция для «Перевод по номеру» (показывается пользователям при выборе этого способа):</p>
  <textarea name="transfer_instruction" rows="3" style="width:100%;">{{ settings['transfer_instruction'] }}</textarea>
  <div class="formrow" style="margin-top:10px;">
    <input name="promised_amount" value="{{ settings['promised_amount'] }}" placeholder="Сумма обещанного">
    <select name="promised_repay_seconds">
      {% if settings['promised_repay_seconds'] not in ['3600','86400','259200','604800','1209600'] %}<option value="{{ settings['promised_repay_seconds'] }}" selected>{{ settings['promised_repay_seconds'] }} сек (тек.)</option>{% endif %}
      <option value="3600" {% if settings['promised_repay_seconds'] == '3600' %}selected{% endif %}>через 1 час</option>
      <option value="86400" {% if settings['promised_repay_seconds'] == '86400' %}selected{% endif %}>через 1 день</option>
      <option value="259200" {% if settings['promised_repay_seconds'] == '259200' %}selected{% endif %}>через 3 дня</option>
      <option value="604800" {% if settings['promised_repay_seconds'] == '604800' %}selected{% endif %}>через 7 дней</option>
      <option value="1209600" {% if settings['promised_repay_seconds'] == '1209600' %}selected{% endif %}>через 14 дней</option>
    </select>
    <label class="muted">Комиссия обещанного, % (0 = без комиссии):
      <input name="promised_fee_percent" value="{{ settings['promised_fee_percent'] }}" style="width:90px;"></label>
    <button class="btn" type="submit">Сохранить</button>
  </div>
</form>
<h2>Активные обещанные платежи</h2>
{% if debts %}
<table><tr><th>Пользователь</th><th>Взял</th><th>К возврату</th><th>До</th><th>Статус</th><th></th></tr>
{% for item in debts %}<tr><td>{{ item.d.user.username }}</td><td>{{ "%.2f"|format(item.d.principal) }}</td><td>{{ "%.2f"|format(item.d.repay_amount) }}</td><td>{{ item.d.due_at.strftime("%d.%m.%Y %H:%M") }}</td>
<td>{% if item.overdue %}<span class="badge bad">просрочен</span>{% else %}<span class="badge warn">активен</span>{% endif %}</td>
<td><form method="post" action="{{ url_for('admin_promised_cancel', debt_id=item.d.id) }}" style="display:inline" onsubmit="return confirm('Убрать обещанный платёж (списать долг)?');"><button class="btn red mini" type="submit">Убрать</button></form></td></tr>{% endfor %}</table>
{% else %}<p class="muted">Активных обещанных платежей нет.</p>{% endif %}
</details>

<details class="card" id="transactions">
<summary>Транзакции (последние 50)</summary>
<form method="post" action="{{ url_for('admin_transactions_clear') }}" style="margin-bottom:10px;" onsubmit="return confirm('Очистить ВСЮ историю транзакций? Балансы не изменятся.');">
  <button class="btn red" type="submit">Очистить всё</button>
</form>
<table><tr><th>ID</th><th>Пользователь</th><th>Сумма</th><th>Причина</th><th>Дата</th><th></th></tr>
{% for t in transactions %}<tr><td>{{ t.id }}</td><td>{{ t.user.username if t.user else "—" }}</td><td>{{ "%.2f"|format(t.amount) }}</td><td>{{ t.reason }}</td><td>{{ t.created_at.strftime("%d.%m.%Y %H:%M:%S") if t.created_at else "" }}</td>
<td><form method="post" action="{{ url_for('admin_transaction_delete', tx_id=t.id) }}" style="display:inline" onsubmit="return confirm('Удалить транзакцию #{{ t.id }}?');"><button class="btn red mini" type="submit">✕</button></form></td></tr>{% endfor %}
</table>
</details>

<script>
document.getElementById("tariff-form").addEventListener("submit", function () { this.action = "/admin/user/" + document.getElementById("tariff-user").value + "/tariff"; });
document.getElementById("pass-form").addEventListener("submit", function () { this.action = "/admin/user/" + document.getElementById("pass-user").value + "/password"; });
</script>
{% endblock %}
ADMIN_EOF
echo "=== worker.py ==="
cat > "$WORKER/worker.py" <<'WORKER_EOF'
import sqlite3, subprocess, time, signal
from pathlib import Path

BASE_DIR = Path("/opt/cctv"); DB_PATH = BASE_DIR / "app" / "cctv.db"
ARCHIVE_DIR = BASE_DIR / "storage" / "archive"; LIVE_DIR = BASE_DIR / "storage" / "live"; LOG_DIR = BASE_DIR / "storage" / "logs"
procs = {}; configs = {}; log_files = {}; running = True; loops = 0

def handle_signal(signum, frame):
    global running
    running = False

signal.signal(signal.SIGTERM, handle_signal); signal.signal(signal.SIGINT, handle_signal)

def get_cameras():
    if not DB_PATH.exists(): return []
    try:
        conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row
        rows = [dict(r) for r in conn.execute("SELECT id, rtsp_url, recording_enabled FROM camera WHERE active=1")]
        conn.close(); return rows
    except sqlite3.Error:
        return []

def camera_config(cam): return (cam["rtsp_url"], bool(cam["recording_enabled"]))

def cleanup_archives():
    try:
        conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row
        for row in conn.execute("SELECT id FROM camera").fetchall():
            cid = row["id"]
            days = conn.execute("SELECT MAX(t.archive_days) AS d FROM camera_access ca JOIN user u ON u.id=ca.user_id JOIN tariff t ON t.id=u.tariff_id WHERE ca.camera_id=? AND ca.enabled=1", (cid,)).fetchone()["d"]
            days = days or 7
            cutoff = time.time() - days * 86400
            d = ARCHIVE_DIR / f"camera_{cid}"
            if d.exists():
                for f in d.glob("*.mp4"):
                    if f.stat().st_mtime < cutoff: f.unlink()
        conn.close()
    except Exception:
        pass

def stop_camera(camera_id):
    proc = procs.pop(camera_id, None)
    if proc is not None:
        try:
            proc.terminate(); proc.wait(timeout=5)
        except Exception:
            try: proc.kill()
            except Exception: pass
    lf = log_files.pop(camera_id, None)
    if lf is not None:
        try: lf.close()
        except Exception: pass

def start_camera(cam):
    camera_id = cam["id"]; recording_enabled = bool(cam["recording_enabled"])
    archive_dir = ARCHIVE_DIR / f"camera_{camera_id}"; live_dir = LIVE_DIR / f"camera_{camera_id}"
    LOG_DIR.mkdir(parents=True, exist_ok=True); archive_dir.mkdir(parents=True, exist_ok=True); live_dir.mkdir(parents=True, exist_ok=True)
    log_path = LOG_DIR / f"camera_{camera_id}.log"
    if log_path.exists() and log_path.stat().st_size > 5 * 1024 * 1024: log_path.unlink()
    lf = open(log_path, "ab", buffering=0); log_files[camera_id] = lf
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "warning", "-rtsp_transport", "tcp", "-i", cam["rtsp_url"]]
    if recording_enabled:
        cmd += ["-map", "0:v", "-c:v", "copy", "-an", "-f", "segment", "-segment_time", "300", "-reset_timestamps", "1", "-strftime", "1", str(archive_dir / "%Y-%m-%d_%H-%M-%S.mp4")]
    cmd += ["-map", "0:v", "-c:v", "copy", "-an", "-f", "hls", "-hls_time", "6", "-hls_list_size", "6", "-hls_flags", "delete_segments", str(live_dir / "index.m3u8")]
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=lf)

while running:
    cameras = get_cameras(); active_ids = set()
    for cam in cameras:
        cid = cam["id"]; active_ids.add(cid); cfg = camera_config(cam)
        proc = procs.get(cid)
        if proc is not None and configs.get(cid) != cfg:
            stop_camera(cid); proc = None
        if proc is None or proc.poll() is not None:
            if proc is not None:
                proc.wait()
                lf = log_files.pop(cid, None)
                if lf is not None:
                    try: lf.close()
                    except Exception: pass
            procs[cid] = start_camera(cam); configs[cid] = cfg
    for cid in list(procs.keys()):
        if cid not in active_ids:
            stop_camera(cid); configs.pop(cid, None)
    loops += 1
    if loops % 300 == 0: cleanup_archives()
    time.sleep(5)

for cid in list(procs.keys()): stop_camera(cid)
WORKER_EOF
echo "=== billing.py ==="
cat > "$WORKER/billing.py" <<'BILLING_EOF'
import sqlite3, time
from datetime import datetime, timedelta
from pathlib import Path

DB_PATH = Path("/opt/cctv/app/cctv.db")
ticks = 0

def prune_old_transactions():
    try:
        conn = sqlite3.connect(DB_PATH)
        cutoff = (datetime.utcnow() - timedelta(days=90)).isoformat(sep=" ")
        conn.execute('DELETE FROM "transaction" WHERE created_at < ?', (cutoff,))
        conn.commit(); conn.close()
    except Exception:
        pass

def tick():
    if not DB_PATH.exists(): return
    conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row
    now = datetime.utcnow(); now_str = now.isoformat(sep=" ")
    rows = conn.execute("""
        SELECT u.id AS user_id, u.username, u.balance, u.credit_limit, u.subscription_ends_at,
               t.id AS tariff_id, t.name AS tariff_name, t.price, t.interval_seconds
        FROM user u JOIN tariff t ON t.id = u.tariff_id
        WHERE u.active = 1 AND u.tariff_id IS NOT NULL AND u.subscription_ends_at IS NOT NULL""").fetchall()
    for r in rows:
        try: ends = datetime.fromisoformat(r["subscription_ends_at"])
        except (ValueError, TypeError): continue
        if ends > now: continue
        interval = int(r["interval_seconds"] or 2592000); credit = float(r["credit_limit"] or 0)
        if (r["balance"] - r["price"]) < -credit: continue
        base = ends if ends > now else now
        new_ends = base + timedelta(seconds=interval)
        conn.execute("UPDATE user SET balance = balance - ?, subscription_ends_at = ? WHERE id = ?", (r["price"], new_ends.isoformat(sep=" "), r["user_id"]))
        conn.execute('INSERT INTO "transaction" (user_id, amount, reason, created_at) VALUES (?, ?, ?, ?)', (r["user_id"], -r["price"], f"Списание по тарифу {r['tariff_name']} (интервал {interval} с)", now_str))
        conn.commit()
    debts = conn.execute("""
        SELECT d.id, d.user_id, d.repay_amount, u.balance
        FROM promised_debt d JOIN user u ON u.id = d.user_id
        WHERE d.status = 'active' AND d.due_at <= ?""", (now_str,)).fetchall()
    for d in debts:
        if d["balance"] >= d["repay_amount"]:
            conn.execute("UPDATE user SET balance = balance - ? WHERE id = ?", (d["repay_amount"], d["user_id"]))
            conn.execute('INSERT INTO "transaction" (user_id, amount, reason, created_at) VALUES (?, ?, ?, ?)', (d["user_id"], -d["repay_amount"], "Возврат обещанного платежа (с комиссией)", now_str))
            conn.execute("UPDATE promised_debt SET status = 'repaid', repaid_at = ? WHERE id = ?", (now_str, d["id"]))
            conn.commit()
    conn.close()

while True:
    try: tick()
    except Exception as e: print("[billing] error:", e, flush=True)
    ticks += 1
    if ticks % 3600 == 0: prune_old_transactions()
    time.sleep(1)
BILLING_EOF
echo "=== .env (не трогаем, если есть) ==="
if [ ! -f "$BASE/.env" ]; then
    ADMIN_PASSWORD=$(openssl rand -hex 8); SECRET_KEY=$(openssl rand -hex 32)
    cat > "$BASE/.env" <<ENV_EOF
SECRET_KEY=$SECRET_KEY
ADMIN_USERNAME=admin
ADMIN_PASSWORD=$ADMIN_PASSWORD
ENV_EOF
    chmod 600 "$BASE/.env"
    echo "Admin password: $ADMIN_PASSWORD" > "$BASE/admin_password.txt"; chmod 600 "$BASE/admin_password.txt"
else
    echo ".env существует — оставляем прежним (пароль админа не меняется)."
fi
echo "=== Виртуальное окружение ==="
if [ ! -f "$BASE/venv/bin/activate" ]; then python3 -m venv "$BASE/venv"; fi
"$BASE/venv/bin/pip" install --upgrade pip
"$BASE/venv/bin/pip" install -r "$APP/requirements.txt"
echo "=== Миграция базы (идемпотентная) ==="
if [ -f "$APP/cctv.db" ]; then
    python3 - "$APP/cctv.db" <<'PYMIG'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1]); cur = conn.cursor()
tables = {r[0] for r in cur.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
cur.execute("CREATE TABLE IF NOT EXISTS tariff (id INTEGER PRIMARY KEY, name VARCHAR(80) NOT NULL, price FLOAT NOT NULL, period_days INTEGER, interval_seconds INTEGER, max_cameras INTEGER, archive_days INTEGER, is_active BOOLEAN)")
cur.execute("CREATE TABLE IF NOT EXISTS camera_access (id INTEGER PRIMARY KEY, camera_id INTEGER NOT NULL, user_id INTEGER NOT NULL, enabled BOOLEAN DEFAULT 1)")
cur.execute("CREATE TABLE IF NOT EXISTS payment_request (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, amount FLOAT NOT NULL, method VARCHAR(20), comment TEXT, status VARCHAR(10) DEFAULT 'pending', user_hidden BOOLEAN DEFAULT 0, created_at TIMESTAMP, processed_at TIMESTAMP)")
cur.execute("CREATE TABLE IF NOT EXISTS setting (key VARCHAR(80) PRIMARY KEY, value TEXT)")
cur.execute("CREATE TABLE IF NOT EXISTS promised_debt (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, principal FLOAT NOT NULL, repay_amount FLOAT NOT NULL, created_at TIMESTAMP, due_at TIMESTAMP, status VARCHAR(10) DEFAULT 'active', repaid_at TIMESTAMP)")
def cols(t): return {r[1] for r in cur.execute(f"PRAGMA table_info({t})").fetchall()}
if "tariff" in tables:
    tc = cols("tariff")
    if "interval_seconds" not in tc:
        cur.execute("ALTER TABLE tariff ADD COLUMN interval_seconds INTEGER")
        cur.execute("UPDATE tariff SET interval_seconds = COALESCE(period_days,30)*86400 WHERE interval_seconds IS NULL")
        print("migration: tariff += interval_seconds")
if "user" in tables:
    u = cols("user")
    if "tariff_id" not in u: cur.execute("ALTER TABLE user ADD COLUMN tariff_id INTEGER"); print("migration: user += tariff_id")
    if "subscription_ends_at" not in u: cur.execute("ALTER TABLE user ADD COLUMN subscription_ends_at TIMESTAMP"); print("migration: user += subscription_ends_at")
    if "credit_limit" not in u: cur.execute("ALTER TABLE user ADD COLUMN credit_limit FLOAT DEFAULT 0"); print("migration: user += credit_limit")
if "camera" in tables:
    c = cols("camera")
    if "recording_enabled" not in c: cur.execute("ALTER TABLE camera ADD COLUMN recording_enabled BOOLEAN DEFAULT 0"); print("migration: camera += recording_enabled")
if "camera_access" in tables:
    ca = cols("camera_access")
    if "enabled" not in ca:
        cur.execute("ALTER TABLE camera_access ADD COLUMN enabled BOOLEAN DEFAULT 1")
        print("migration: camera_access += enabled")
    cur.execute("INSERT INTO camera_access (camera_id, user_id, enabled) SELECT id, user_id, 1 FROM camera WHERE user_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM camera_access ca WHERE ca.camera_id = camera.id AND ca.user_id = camera.user_id)")
    print("migration: camera_access seeded from old owners")
if "payment_request" in tables:
    pr = cols("payment_request")
    if "user_hidden" not in pr:
        cur.execute("ALTER TABLE payment_request ADD COLUMN user_hidden BOOLEAN DEFAULT 0")
        print("migration: payment_request += user_hidden")
cur.execute("PRAGMA journal_mode=WAL").fetchall()
conn.commit(); conn.close(); print("migration ok")
PYMIG
else
    echo "База не найдена — будет создана при первом старте."
fi
echo "=== Владелец файлов ==="
chown -R cctv:cctv "$BASE"
echo "=== systemd-юниты ==="
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
echo "=== Освобождение порта 80 (терпеливое) ==="
wait_port_free() {
    local n=0
    while [ "$n" -lt "$1" ]; do
        ss -tln | grep -q ':80 ' || return 0
        sleep 1; n=$((n+1))
    done
    ss -tln | grep -q ':80 ' && return 1 || return 0
}
NGINX_LISTEN=80
STOPPED_CONTAINERS=""
for i in 1 2 3; do
    if ! ss -tln | grep -q ':80 '; then break; fi
    PID=$(ss -tlnp | grep ':80 ' | grep -oP 'pid=\K[0-9]+' | head -1) || true
    if [ -z "$PID" ]; then break; fi
    CID=""
    if command -v docker &>/dev/null; then
        CID=$(docker ps -q 2>/dev/null | while read -r c; do
                docker top "$c" 2>/dev/null | awk -v p="$PID" '$2==p{print c; exit}'
              done | head -1) || true
    fi
    if [ -n "$CID" ]; then
        echo "Порт 80 держит docker-контейнер $CID — отключаю автостарт и останавливаю (ждём освобождения)"
        docker update --restart=no "$CID" 2>/dev/null || true
        docker stop "$CID" 2>/dev/null || true
        STOPPED_CONTAINERS="$STOPPED_CONTAINERS $CID"
        if ! wait_port_free 10; then
            echo "Контейнер остановлен, но порт ещё занят — удаляю контейнер $CID"
            docker rm -f "$CID" 2>/dev/null || true
            wait_port_free 5 || true
        fi
    else
        echo "Убиваю процесс $PID, держащий порт 80"
        kill -9 "$PID" 2>/dev/null || true
        wait_port_free 5 || true
    fi
done
if [ -n "$STOPPED_CONTAINERS" ]; then
    echo "Остановленные контейнеры:$STOPPED_CONTAINERS (автостарт отключён)"
fi
if ss -tln | grep -q ':80 '; then
    echo "WARNING: порт 80 всё ещё занят — переключаю сайт на 8090"
    echo "Понадобится на роутере проброс: внешний 81 -> внутренний 8090"
    NGINX_LISTEN=8090
fi
echo "=== Nginx (listen $NGINX_LISTEN) ==="
cat > /etc/nginx/sites-available/cctv <<'NGINX_EOF'
server {
    listen __PORT__;
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
sed -i "s/__PORT__/$NGINX_LISTEN/" /etc/nginx/sites-available/cctv
ln -sf /etc/nginx/sites-available/cctv /etc/nginx/sites-enabled/cctv
rm -f /etc/nginx/sites-enabled/default
nginx -t
echo "=== Версия ==="
echo "$VERSION" > "$BASE/VERSION"; chown cctv:cctv "$BASE/VERSION"
echo "=== Старт сервисов ==="
systemctl daemon-reload
systemctl enable --now cctv-web.service
systemctl enable --now cctv-worker.service
systemctl enable --now cctv-billing.service
if ! systemctl restart nginx; then
    echo "WARNING: nginx restart failed, чищу зависшие процессы и стартую заново"
    systemctl kill nginx 2>/dev/null || true
    pkill -9 nginx 2>/dev/null || true
    sleep 1
    systemctl start nginx
fi
echo "=== Самопроверка ==="
sleep 3
SITE_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$NGINX_LISTEN/login)
echo "site login page: $SITE_CODE (ожидаем 200)"
if [ "$SITE_CODE" != "200" ]; then
    echo "!!! сайт не отвечает, логи:"
    journalctl -u cctv-web -n 20 --no-pager || true
    journalctl -u nginx -n 20 --no-pager || true
    exit 1
fi
echo ""
echo "=== Готово ==="
echo "Версия системы: $(cat "$BASE/VERSION"), сайт слушает порт $NGINX_LISTEN"
if [ -f "$APP/cctv.db" ]; then
    echo "Пользователей: $(sqlite3 "$APP/cctv.db" 'SELECT COUNT(*) FROM user;')"
    echo "Камер:         $(sqlite3 "$APP/cctv.db" 'SELECT COUNT(*) FROM camera;')"
    echo "Транзакций:    $(sqlite3 "$APP/cctv.db" 'SELECT COUNT(*) FROM \"transaction\";')"
fi
echo "Архив на диске: $(du -sh "$STORAGE/archive" 2>/dev/null | cut -f1)"