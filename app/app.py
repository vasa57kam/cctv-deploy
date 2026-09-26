import os, re, time, json, base64, socket, threading
import urllib.request, urllib.parse
from datetime import datetime, timedelta
from pathlib import Path
from functools import wraps
from concurrent.futures import ThreadPoolExecutor
import subprocess
from flask import Flask, render_template, request, redirect, url_for, abort, send_from_directory, send_file, flash, session, jsonify, g
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import func
from flask_login import LoginManager, UserMixin, login_user, login_required, logout_user, current_user
from werkzeug.security import generate_password_hash, check_password_hash

BASE_DIR = Path("/opt/cctv"); STORAGE_DIR = BASE_DIR / "storage"
LIVE_DIR = STORAGE_DIR / "live"; ARCHIVE_DIR = STORAGE_DIR / "archive"
PREVIEW_DIR = STORAGE_DIR / "previews"; EXPORT_DIR = STORAGE_DIR / "exports"
DB_PATH = BASE_DIR / "app" / "cctv.db"
DAEMON_URL = "http://127.0.0.1:8099/"
SCAN_STATE_PATH = STORAGE_DIR / "scan_state.json"
for d in (DB_PATH.parent, LIVE_DIR, ARCHIVE_DIR, PREVIEW_DIR, EXPORT_DIR):
    d.mkdir(parents=True, exist_ok=True)

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
ROLES = [("viewer", "Охранник (только лайв)"), ("manager", "Менеджер (лайв+архив)"), ("accountant", "Бухгалтер (без камер)"), ("admin", "Админ организации")]
DEFAULT_SETTINGS = {
    "method_cash": "1", "method_transfer": "1", "method_card": "0", "method_promised": "1", "method_other": "0",
    "transfer_instruction": "Переведите сумму на карту Сбербанк: 0000 0000 0000 0000 (Имя Фамилия). В комментарии укажите дату и последние 4 цифры.",
    "promised_amount": "300", "promised_repay_seconds": "604800", "promised_fee_percent": "10",
    "partner_commission": "30", "archive_order_price": "100", "freeze_price_per_day": "50",
    "motion_threshold": "0.06",
    "whitelabel_name": "CCTV Cloud", "whitelabel_primary": "#38bdf8", "whitelabel_logo": "",
}

SCAN_PORTS = [554, 80, 8080, 8000, 8899, 37777, 5000, 8443, 5540, 8554, 81, 88]
RTSP_PATTERNS = [
    "/Streaming/Channels/101", "/Streaming/Channels/102", "/h264/ch1/main/av_stream",
    "/cam/realmonitor?channel=1&subtype=0", "/cam/realmonitor?channel=1&subtype=1",
    "/axis-media/media.amp", "/media/video1", "/ch01.264", "/ch01_264",
    "/11", "/12", "/1", "/stream1", "/live/ch00_0", "/h264_stream", "/video1",
    "/user=admin&password=&channel=1&stream=0.sdp",
]
DEFAULT_CREDS = [("admin", "admin"), ("admin", "12345"), ("admin", "123456"),
                 ("admin", "password"), ("root", "root"), ("admin", "888888")]

def method_label(code): return dict(PAY_METHODS).get(code, code)
def role_label(code): return dict(ROLES).get(code, code)

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
    is_b2b = db.Column(db.Boolean, default=False); max_users = db.Column(db.Integer, default=1)
    bundles = db.relationship("TariffBundle", backref="tariff", lazy=True)

class TariffBundle(db.Model):
    __tablename__ = "tariff_bundle"
    id = db.Column(db.Integer, primary_key=True)
    tariff_id = db.Column(db.Integer, db.ForeignKey("tariff.id"), nullable=False)
    months = db.Column(db.Integer, nullable=False)
    discount_percent = db.Column(db.Float, default=0.0)
    is_active = db.Column(db.Boolean, default=True)

class User(UserMixin, db.Model):
    __tablename__ = "user"
    id = db.Column(db.Integer, primary_key=True); username = db.Column(db.String(80), unique=True, nullable=False)
    password_hash = db.Column(db.String(255), nullable=False); balance = db.Column(db.Float, default=0.0)
    credit_limit = db.Column(db.Float, default=0.0); admin = db.Column(db.Boolean, default=False)
    active = db.Column(db.Boolean, default=True); created_at = db.Column(db.DateTime, default=datetime.utcnow)
    tariff_id = db.Column(db.Integer, db.ForeignKey("tariff.id"), nullable=True)
    subscription_ends_at = db.Column(db.DateTime, nullable=True)
    auto_renew = db.Column(db.Boolean, default=False)
    referred_by = db.Column(db.Integer, nullable=True); partner_of = db.Column(db.Integer, nullable=True)
    tariff = db.relationship("Tariff", backref="users")
    transactions = db.relationship("Transaction", backref="user", lazy=True)
    @property
    def is_active(self): return self.active

class TeamMember(db.Model):
    __tablename__ = "team_member"
    id = db.Column(db.Integer, primary_key=True)
    owner_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False, unique=True)
    role = db.Column(db.String(20), default="viewer")
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    owner = db.relationship("User", foreign_keys=[owner_id], backref="team_members_owned")
    user = db.relationship("User", foreign_keys=[user_id], backref="team_membership")

class Camera(db.Model):
    __tablename__ = "camera"
    id = db.Column(db.Integer, primary_key=True); name = db.Column(db.String(120), nullable=False)
    rtsp_url = db.Column(db.Text, nullable=False); user_id = db.Column(db.Integer, nullable=True)
    active = db.Column(db.Boolean, default=True); recording_enabled = db.Column(db.Boolean, default=False)
    recording_mode = db.Column(db.String(12), default="continuous")
    motion_zone = db.Column(db.String(60), nullable=True)
    group_name = db.Column(db.String(60), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    users = db.relationship("User", secondary="camera_access", backref="cameras")

class CameraRequest(db.Model):
    __tablename__ = "camera_request"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    ip = db.Column(db.String(64), nullable=False)
    login = db.Column(db.String(64), nullable=True)
    password = db.Column(db.String(64), nullable=True)
    comment = db.Column(db.String(255))
    status = db.Column(db.String(10), default="pending")
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    user = db.relationship("User", backref="camera_requests")

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
    user_hidden = db.Column(db.Boolean, default=False); admin_hidden = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow); processed_at = db.Column(db.DateTime, nullable=True)
    user = db.relationship("User", backref="payment_requests")

class PromisedDebt(db.Model):
    __tablename__ = "promised_debt"
    id = db.Column(db.Integer, primary_key=True); user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    principal = db.Column(db.Float, nullable=False); repay_amount = db.Column(db.Float, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow); due_at = db.Column(db.DateTime, nullable=False)
    status = db.Column(db.String(10), default="active"); repaid_at = db.Column(db.DateTime, nullable=True)
    user = db.relationship("User", backref="promised_debts")

class SubscriptionFreeze(db.Model):
    __tablename__ = "subscription_freeze"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    freeze_from = db.Column(db.DateTime, nullable=False); freeze_to = db.Column(db.DateTime, nullable=False)
    status = db.Column(db.String(10), default="pending"); price = db.Column(db.Float, default=0.0)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    user = db.relationship("User", backref="freezes")

class Referral(db.Model):
    __tablename__ = "referral"
    id = db.Column(db.Integer, primary_key=True)
    referrer_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    referee_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    bonus_amount = db.Column(db.Float, default=0.0)
    status = db.Column(db.String(10), default="pending")
    created_at = db.Column(db.DateTime, default=datetime.utcnow); credited_at = db.Column(db.DateTime, nullable=True)
    referrer = db.relationship("User", foreign_keys=[referrer_id], backref="referrals_made")
    referee = db.relationship("User", foreign_keys=[referee_id], backref="referred_by_link")

class AuditLog(db.Model):
    __tablename__ = "audit_log"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    action = db.Column(db.String(40), nullable=False); target = db.Column(db.String(255))
    ip = db.Column(db.String(45)); created_at = db.Column(db.DateTime, default=datetime.utcnow)
    user = db.relationship("User", backref="audit_logs")

class ArchiveOrder(db.Model):
    __tablename__ = "archive_order"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False)
    camera_id = db.Column(db.Integer, db.ForeignKey("camera.id"), nullable=False)
    from_dt = db.Column(db.DateTime, nullable=False); to_dt = db.Column(db.DateTime, nullable=False)
    price = db.Column(db.Float, default=0.0); status = db.Column(db.String(10), default="pending")
    created_at = db.Column(db.DateTime, default=datetime.utcnow); processed_at = db.Column(db.DateTime, nullable=True)
    user = db.relationship("User", backref="archive_orders")
    camera = db.relationship("Camera")

class Partner(db.Model):
    __tablename__ = "partner"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("user.id"), nullable=False, unique=True)
    commission_percent = db.Column(db.Float, default=30.0)
    total_referrals = db.Column(db.Integer, default=0); total_earned = db.Column(db.Float, default=0.0)
    user = db.relationship("User", backref="partner_profile")

class WhiteLabel(db.Model):
    __tablename__ = "whitelabel"
    id = db.Column(db.Integer, primary_key=True)
    partner_id = db.Column(db.Integer, db.ForeignKey("partner.id"), nullable=False, unique=True)
    domain = db.Column(db.String(200), nullable=True); logo_url = db.Column(db.String(500), nullable=True)
    primary_color = db.Column(db.String(20), default="#38bdf8"); brand_name = db.Column(db.String(80), default="CCTV")
    partner = db.relationship("Partner", backref="whitelabel")

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
            Tariff(name="Старт", price=290, interval_seconds=2592000, max_cameras=1, archive_days=3),
            Tariff(name="Базовый", price=690, interval_seconds=2592000, max_cameras=3, archive_days=7),
            Tariff(name="Бизнес", price=1990, interval_seconds=2592000, max_cameras=10, archive_days=7),
            Tariff(name="B2B Офис", price=4990, interval_seconds=2592000, max_cameras=20, archive_days=30, is_b2b=True, max_users=5),
            Tariff(name="B2B ТСЖ", price=1490, interval_seconds=2592000, max_cameras=8, archive_days=14, is_b2b=True, max_users=3)])
        db.session.commit()
        for t in Tariff.query.all():
            db.session.add_all([TariffBundle(tariff_id=t.id, months=m, discount_percent=d) for m, d in ((3, 5.0), (6, 10.0), (12, 15.0))])
        db.session.commit()
    au = os.environ.get("ADMIN_USERNAME", "admin"); ap = os.environ.get("ADMIN_PASSWORD", "admin123")
    if not User.query.filter_by(username=au).first():
        db.session.add(User(username=au, password_hash=generate_password_hash(ap), admin=True, active=True, balance=0.0))
        db.session.commit()

with app.app_context(): init_db()

@app.template_filter("rudate")
def rudate(dt):
    if not dt: return ""
    now = datetime.utcnow()
    t = f"{dt.hour:02d}:{dt.minute:02d}"
    if dt.date() == now.date(): return f"сегодня, {t}"
    if dt.date() == (now - timedelta(days=1)).date(): return f"вчера, {t}"
    months = ["янв", "фев", "мар", "апр", "мая", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]
    return f"{dt.day} {months[dt.month - 1]}, {t}"

@app.context_processor
def inject_brand():
    brand = {"name": get_setting("whitelabel_name", "CCTV Cloud"),
             "color": get_setting("whitelabel_primary", "#38bdf8"),
             "logo": get_setting("whitelabel_logo", "")}
    host = (request.host or "").split(":")[0]
    wl = WhiteLabel.query.filter_by(domain=host).first() if host else None
    if wl:
        brand = {"name": wl.brand_name or brand["name"], "color": wl.primary_color or brand["color"], "logo": wl.logo_url or ""}
    return {"brand": brand}

def get_or_404(model, ident):
    obj = db.session.get(model, ident)
    if obj is None: abort(404)
    return obj

def admin_redirect(anchor): return redirect(url_for("admin_page") + anchor)
def user_redirect(anchor): return redirect(url_for("dashboard") + anchor)

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

def audit(user, action, target=""):
    if user is None or not getattr(user, "id", None): return
    try:
        db.session.add(AuditLog(user_id=user.id, action=action, target=str(target)[:200],
            ip=(request.remote_addr or "")[:45], created_at=datetime.utcnow()))
        db.session.commit()
    except Exception:
        db.session.rollback()

def team_member_of(user):
    return user.team_membership[0] if user.team_membership else None

def team_role(user):
    m = team_member_of(user)
    return m.role if m else None

def active_freeze(user):
    if user is None: return None
    now = datetime.utcnow()
    return SubscriptionFreeze.query.filter_by(user_id=user.id, status="active").filter(
        SubscriptionFreeze.freeze_from <= now, SubscriptionFreeze.freeze_to >= now).first()

def subscription_active(user):
    if user is None or user.subscription_ends_at is None: return False
    if active_freeze(user): return False
    return user.subscription_ends_at > datetime.utcnow()

def user_link(user_id, camera_id):
    return db.session.execute(camera_access.select().where(
        camera_access.c.user_id == user_id, camera_access.c.camera_id == camera_id)).fetchone()

def enabled_cameras(user):
    rows = db.session.execute(camera_access.select().where(
        camera_access.c.user_id == user.id, camera_access.c.enabled == True).order_by(camera_access.c.camera_id)).fetchall()
    return [db.session.get(Camera, r.camera_id) for r in rows if db.session.get(Camera, r.camera_id)]

def enabled_count(user): return len(enabled_cameras(user))

def effective_owner(user):
    m = team_member_of(user)
    return m.owner if m else user

def can_view_camera(camera):
    if current_user.admin: return True
    if not camera.active: return False
    role = team_role(current_user)
    if role == "accountant": return False
    owner = effective_owner(current_user)
    row = user_link(owner.id, camera.id)
    if row is None or not row.enabled: return False
    if not current_user.is_active or not owner.is_active: return False
    return subscription_active(owner)

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

def thumb_state(camera):
    p = PREVIEW_DIR / f"thumb_{camera.id}.jpg"
    if not p.exists() or p.stat().st_size == 0:
        return {"url": None, "online": False}
    return {"url": f"/thumb/{camera.id}", "online": (time.time() - p.stat().st_mtime) < 120}

def apply_tariff(user, tariff, months=1, discount=0.0):
    now = datetime.utcnow()
    total = round(tariff.price * months * (1 - discount / 100.0), 2)
    if user.balance < total:
        return False, f"Недостаточно баланса: нужно {total:.2f}, на балансе {user.balance:.2f}"
    base = now
    if user.tariff_id == tariff.id and user.subscription_ends_at and user.subscription_ends_at > now:
        base = user.subscription_ends_at
    user.balance -= total
    suffix = f" x{months} мес" if months > 1 else ""
    disc = f" (скидка {discount:.0f}%)" if discount else ""
    db.session.add(Transaction(user_id=user.id, amount=-total, reason=f"Списание по тарифу {tariff.name}{suffix}{disc}"))
    user.tariff_id = tariff.id
    user.subscription_ends_at = base + timedelta(seconds=(tariff.interval_seconds or 2592000) * months)
    db.session.commit()
    audit(user, "tariff_apply", f"{tariff.name}{suffix}")
    return True, f"Тариф {tariff.name}{suffix} подключён до {user.subscription_ends_at:%d.%m.%Y %H:%M:%S}{disc}"

def fetch_page(url, cookie):
    headers = {"User-Agent": "Mozilla/5.0"}
    if cookie: headers["Cookie"] = cookie
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return resp.read().decode("utf-8", "ignore")

def extract_candidates(html, base_url):
    found = []
    for p in (r'https?://[^\s"\'<>\\]+\.m3u8[^\s"\'<>\\]*', r'rtsp://[^\s"\'<>\\]+'):
        for m in re.findall(p, html):
            u = m.replace("&amp;", "&")
            if u not in found: found.append(u)
    for m in re.findall(r'https?://[^\s"\'<>\\]+/recording_status\.json[^\s"\'<>\\]*', html):
        alt = m.replace("recording_status.json", "index.m3u8").replace("&amp;", "&")
        if alt not in found: found.append(alt)
    return found

def daemon_call(payload, timeout=180):
    req = urllib.request.Request(DAEMON_URL, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())

def probe_stream(url, idx):
    out = PREVIEW_DIR / f"cand_{idx}.jpg"
    if out.exists(): out.unlink()
    cmd = ["ffmpeg", "-nostdin", "-loglevel", "error", "-rtsp_transport", "tcp", "-i", url, "-frames:v", "1", "-y", str(out)]
    try: subprocess.run(cmd, timeout=12, capture_output=True)
    except subprocess.TimeoutExpired: return False
    return out.exists() and out.stat().st_size > 0

CHUNK_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})\.mp4$")
DAY_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})\.mp4$")

def build_archive_days(camera):
    camera_dir = ARCHIVE_DIR / f"camera_{camera.id}"
    if not camera_dir.exists(): return []
    cutoff = time.time() - camera_archive_days(camera) * 86400
    now_ts = time.time()
    today = datetime.utcnow().strftime("%Y-%m-%d")
    days = {}
    for p in camera_dir.glob("*.mp4"):
        st = p.stat()
        if st.st_mtime < cutoff: continue
        m_day = DAY_RE.match(p.name); m_chunk = CHUNK_RE.match(p.name)
        if m_day:
            day = m_day.group(1)
            d = days.setdefault(day, {"day": day, "glued": None, "chunks": []})
            d["glued"] = {"name": p.name, "size_mb": round(st.st_size / 1048576, 1),
                          "ready": (now_ts - st.st_mtime) > 30,
                          "time_start": "00:00:00", "time_end": "23:59:59", "kind": "день, склеено", "s": 0}
        elif m_chunk:
            day = m_chunk.group(1)
            d = days.setdefault(day, {"day": day, "glued": None, "chunks": []})
            h, mi, s = m_chunk.group(2), m_chunk.group(3), m_chunk.group(4)
            s_sec = int(h) * 3600 + int(mi) * 60 + int(s)
            e_sec = min(86400, s_sec + 300)
            start = f"{h}:{mi}:{s}"
            end = (datetime.strptime(f"{day} {h}:{mi}:{s}", "%Y-%m-%d %H:%M:%S") + timedelta(minutes=5)).strftime("%H:%M:%S")
            d["chunks"].append({"name": p.name, "size_mb": round(st.st_size / 1048576, 1),
                "ready": (now_ts - st.st_mtime) > 60,
                "time_start": start, "time_end": end, "kind": "кусок 5 мин", "s": s_sec, "e": e_sec})
        else:
            day = p.name[:10]
            d = days.setdefault(day, {"day": day, "glued": None, "chunks": []})
            hm = re.match(r"^\d{4}-\d{2}-\d{2}_(\d{2})-(\d{2})-(\d{2})", p.name)
            s_sec = 0
            if hm:
                s_sec = int(hm.group(1)) * 3600 + int(hm.group(2)) * 60 + int(hm.group(3))
            d["chunks"].append({"name": p.name, "size_mb": round(st.st_size / 1048576, 1),
                "ready": (now_ts - st.st_mtime) > 60,
                "time_start": time.strftime("%H:%M:%S", time.gmtime(s_sec)),
                "time_end": time.strftime("%H:%M:%S", time.gmtime(min(86399, s_sec + 300))),
                "kind": "событие движения", "s": s_sec, "e": min(86400, s_sec + 300)})
    result = []
    for day in sorted(days.keys(), reverse=True):
        d = days[day]
        d["chunks"].sort(key=lambda x: x["name"])
        if d["glued"]:
            d["ranges"] = "00:00–23:59 (весь день одним файлом)"
            d["total_mb"] = d["glued"]["size_mb"]
            d["segments"] = [{"s": 0, "e": 86400, "file": d["glued"]["name"], "glued": True}]
        else:
            d["ranges"] = ", ".join(f"{c['time_start'][:5]}–{c['time_end'][:5]}" for c in d["chunks"]) or "нет данных"
            d["total_mb"] = round(sum(c["size_mb"] for c in d["chunks"]), 1)
            d["segments"] = [{"s": c["s"], "e": c["e"], "file": c["name"], "glued": False} for c in d["chunks"]]
        d["can_glue"] = (day < today) and (d["glued"] is None) and len(d["chunks"]) >= 1
        d["chunks"].sort(key=lambda x: x["name"], reverse=True)
        result.append(d)
    return result

def _port_open(ip, port, timeout=0.6):
    try:
        s = socket.create_connection((ip, port), timeout=timeout); s.close(); return True
    except Exception:
        return False

def _write_scan_state(state):
    tmp = SCAN_STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False))
    os.replace(tmp, SCAN_STATE_PATH)

def scan_state():
    if SCAN_STATE_PATH.exists():
        try: return json.loads(SCAN_STATE_PATH.read_text())
        except Exception: pass
    return {"running": False, "ip": "", "open_ports": [], "results": [], "checked": 0, "total": 0}

def run_scan(ip, login, password, try_defaults):
    state = {"running": True, "ip": ip, "open_ports": [], "results": [], "checked": 0, "total": 0,
             "started": datetime.utcnow().isoformat()}
    _write_scan_state(state)
    with ThreadPoolExecutor(max_workers=12) as ex:
        opens = list(ex.map(lambda p: (p, _port_open(ip, p)), SCAN_PORTS))
    state["open_ports"] = [p for p, ok in sorted(opens) if ok]
    _write_scan_state(state)
    creds = []
    if login:
        creds.append((login, password or ""))
    else:
        creds.append(None)
    if try_defaults:
        creds.extend(DEFAULT_CREDS)
    rtsp_port = next((p for p in (554, 8554, 5540) if p in state["open_ports"]), None)
    candidates = []
    if rtsp_port:
        for c in creds:
            auth = ""
            if c:
                auth = f"{urllib.parse.quote(c[0], safe='')}:{urllib.parse.quote(c[1], safe='')}@"
            for pat in RTSP_PATTERNS:
                candidates.append(f"rtsp://{auth}{ip}:{rtsp_port}{pat}")
    for hp in (80, 8080, 8000):
        if hp in state["open_ports"]:
            candidates += [f"http://{ip}:{hp}/video.m3u8", f"http://{ip}:{hp}/stream.m3u8",
                           f"http://{ip}:{hp}/hls/live.m3u8", f"http://{ip}:{hp}/live/1.m3u8"]
    state["total"] = len(candidates)
    _write_scan_state(state)
    idx = 100
    for url in candidates:
        if len(state["results"]) >= 8: break
        idx += 1
        ok = probe_stream(url, idx)
        state["checked"] += 1
        if ok:
            state["results"].append({"idx": idx, "url": url})
        _write_scan_state(state)
    state["running"] = False
    _write_scan_state(state)

@app.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated: return redirect(url_for("dashboard"))
    if request.method == "POST":
        username = request.form.get("username", "").strip(); password = request.form.get("password", "")
        user = User.query.filter_by(username=username).first()
        if user and check_password_hash(user.password_hash, password):
            if not user.active:
                flash("Аккаунт заблокирован."); return render_template("login.html")
            login_user(user); audit(user, "login")
            return redirect(url_for("dashboard"))
        flash("Неверный логин или пароль.")
    return render_template("login.html")

@app.route("/logout")
@login_required
def logout():
    audit(current_user, "logout"); session.pop("impersonator", None)
    logout_user(); return redirect(url_for("login"))

@app.route("/stop-impersonation")
@login_required
def stop_impersonation():
    imp_id = session.pop("impersonator", None)
    if not imp_id: return redirect(url_for("dashboard"))
    admin_user = db.session.get(User, int(imp_id))
    logout_user()
    if admin_user: login_user(admin_user)
    flash("Вы вернулись в админку.")
    return redirect(url_for("admin_page"))

@app.route("/thumb/<int:camera_id>")
@login_required
def camera_thumb(camera_id):
    camera = get_camera_or_403(camera_id)
    p = PREVIEW_DIR / f"thumb_{camera.id}.jpg"
    if not p.exists(): abort(404)
    resp = send_file(p, mimetype="image/jpeg")
    resp.headers["Cache-Control"] = "no-store"
    return resp

@app.route("/")
@login_required
def dashboard():
    role = team_role(current_user)
    owner = effective_owner(current_user)
    cam_items = []
    cameras = []
    if current_user.admin and not session.get("impersonator"):
        cameras = Camera.query.order_by(Camera.id.desc()).all()
    elif role:
        cameras = []
        cam_items = [{"camera": c, "enabled": True} for c in owner.cameras if user_link(owner.id, c.id) and user_link(owner.id, c.id).enabled]
    else:
        cam_items = [{"camera": c, "enabled": bool(user_link(current_user.id, c.id).enabled)} for c in current_user.cameras]
    thumbs = {}
    allcams = cameras or [it["camera"] for it in cam_items]
    for c in allcams:
        thumbs[c.id] = thumb_state(c)
    tariff_options = [{"tariff": t, "label": interval_label(t.interval_seconds),
                       "bundles": [b for b in t.bundles if b.is_active]}
                      for t in Tariff.query.filter_by(is_active=True).order_by(Tariff.price).all()]
    my_requests = [{"p": p, "label": method_label(p.method)} for p in
        PaymentRequest.query.filter_by(user_id=current_user.id).order_by(PaymentRequest.id.desc()).limit(30).all()
        if not p.user_hidden][:10]
    my_cam_requests = CameraRequest.query.filter_by(user_id=current_user.id).order_by(CameraRequest.id.desc()).limit(10).all()
    methods = available_methods()
    transfer_instruction = get_setting("transfer_instruction", "") or ""
    promised_enabled = get_setting("method_promised", "0") == "1"
    try:
        promised_amount = float(get_setting("promised_amount", "300") or 0)
        promised_fee = float(get_setting("promised_fee_percent", "0") or 0)
        promised_repay_seconds = int(get_setting("promised_repay_seconds", "604800") or 0)
        archive_price = float(get_setting("archive_order_price", "100") or 0)
        freeze_price = float(get_setting("freeze_price_per_day", "50") or 0)
    except ValueError:
        promised_amount, promised_fee, promised_repay_seconds, archive_price, freeze_price = 300.0, 0.0, 604800, 100.0, 50.0
    active_debt = PromisedDebt.query.filter_by(user_id=current_user.id, status="active").first()
    my_freezes = SubscriptionFreeze.query.filter_by(user_id=current_user.id).order_by(SubscriptionFreeze.id.desc()).limit(5).all()
    archive_orders = ArchiveOrder.query.filter_by(user_id=current_user.id).order_by(ArchiveOrder.id.desc()).limit(10).all()
    team_members = TeamMember.query.filter_by(owner_id=current_user.id).all() if (current_user.tariff and current_user.tariff.is_b2b) else []
    return render_template("dashboard.html", cameras=cameras, cam_items=cam_items, role=role, owner=owner, thumbs=thumbs,
        user_enabled_count=enabled_count(owner), sub_active=subscription_active(owner), freeze_now=active_freeze(owner),
        tariff_options=tariff_options, my_requests=my_requests, my_cam_requests=my_cam_requests,
        methods=methods, transfer_instruction=transfer_instruction,
        promised_enabled=promised_enabled, promised_amount=promised_amount, promised_fee=promised_fee,
        promised_repay_seconds=promised_repay_seconds, promised_repay_label=interval_label(promised_repay_seconds),
        active_debt=active_debt, my_freezes=my_freezes, archive_orders=archive_orders,
        archive_price=archive_price, freeze_price=freeze_price, team_members=team_members)

@app.route("/camera/request", methods=["POST"])
@login_required
def camera_request():
    ip = request.form.get("ip", "").strip()
    if not re.match(r"^[a-zA-Z0-9.-]{3,64}$", ip):
        flash("Некорректный IP или имя хоста."); return user_redirect("#camera-request")
    db.session.add(CameraRequest(user_id=current_user.id, ip=ip,
        login=request.form.get("login", "").strip() or None,
        password=request.form.get("password", "").strip() or None,
        comment=request.form.get("comment", "").strip()))
    db.session.commit()
    flash("Заявка на добавление камеры отправлена администратору.")
    return user_redirect("#camera-request")

@app.route("/admin/camera-request/<int:rid>/close", methods=["POST"])
@admin_required
def camera_request_close(rid):
    r = get_or_404(CameraRequest, rid)
    r.status = "closed"; db.session.commit()
    return admin_redirect("#camera-requests")

@app.route("/admin/scan")
@admin_required
def admin_scan_page():
    st = scan_state()
    return render_template("scan.html", state=st,
        pre_ip=request.args.get("ip", ""), pre_login=request.args.get("login", ""), pre_pass=request.args.get("pass", ""))

@app.route("/admin/scan/start", methods=["POST"])
@admin_required
def admin_scan_start():
    ip = request.form.get("ip", "").strip()
    if not ip:
        flash("Укажите IP или имя хоста."); return redirect(url_for("admin_scan_page"))
    st = scan_state()
    if st.get("running"):
        flash("Сканирование уже идёт — дождитесь окончания."); return redirect(url_for("admin_scan_page"))
    login = request.form.get("login", "").strip()
    password = request.form.get("password", "").strip()
    try_defaults = request.form.get("try_defaults") == "1"
    threading.Thread(target=run_scan, args=(ip, login, password, try_defaults), daemon=True).start()
    audit(current_user, "scan_start", ip)
    flash(f"Сканирование {ip} запущено в фоне. Страница обновится сама.")
    return redirect(url_for("admin_scan_page"))

@app.route("/admin/scan/status")
@admin_required
def admin_scan_status():
    return jsonify(scan_state())

@app.route("/payment/request", methods=["POST"])
@login_required
def payment_request():
    try: amount = float(request.form.get("amount", "0"))
    except ValueError: flash("Некорректная сумма."); return user_redirect("#topup")
    if amount <= 0: flash("Сумма должна быть больше нуля."); return user_redirect("#topup")
    method = request.form.get("method", "other")
    if method not in [c for c, _ in available_methods()]: flash("Способ недоступен."); return user_redirect("#topup")
    db.session.add(PaymentRequest(user_id=current_user.id, amount=amount, method=method,
        comment=request.form.get("comment", "").strip(), status="pending", created_at=datetime.utcnow()))
    db.session.commit()
    flash("Заявка создана. Администратор подтвердит пополнение.")
    return user_redirect("#topup")

@app.route("/payment/request/<int:pr_id>/comment", methods=["POST"])
@login_required
def payment_request_comment(pr_id):
    pr = get_or_404(PaymentRequest, pr_id)
    if pr.user_id != current_user.id: abort(403)
    if pr.status != "pending": flash("Заявка уже обработана."); return user_redirect("#topup")
    pr.comment = request.form.get("comment", "").strip(); db.session.commit()
    return user_redirect("#topup")

@app.route("/payment/request/<int:pr_id>/delete", methods=["POST"])
@login_required
def payment_request_delete(pr_id):
    pr = get_or_404(PaymentRequest, pr_id)
    if pr.user_id != current_user.id or pr.status != "pending": abort(403)
    db.session.delete(pr); db.session.commit()
    return user_redirect("#topup")

@app.route("/payment/request/<int:pr_id>/hide", methods=["POST"])
@login_required
def payment_request_hide(pr_id):
    pr = get_or_404(PaymentRequest, pr_id)
    if pr.user_id != current_user.id: abort(403)
    pr.user_hidden = True; db.session.commit()
    return user_redirect("#topup")

@app.route("/promised/connect", methods=["POST"])
@login_required
def promised_connect():
    if get_setting("method_promised", "0") != "1": flash("Обещанный платёж отключён."); return user_redirect("#promised")
    if PromisedDebt.query.filter_by(user_id=current_user.id, status="active").first(): flash("Уже есть активный обещанный."); return user_redirect("#promised")
    try:
        amount = float(get_setting("promised_amount", "300")); repay_seconds = int(get_setting("promised_repay_seconds", "604800")); fee = float(get_setting("promised_fee_percent", "0"))
    except ValueError: return user_redirect("#promised")
    now = datetime.utcnow(); repay_amount = round(amount * (1 + fee / 100.0), 2)
    current_user.balance += amount
    db.session.add(Transaction(user_id=current_user.id, amount=amount, reason="Обещанный платёж: зачислено"))
    db.session.add(PromisedDebt(user_id=current_user.id, principal=amount, repay_amount=repay_amount, created_at=now, due_at=now + timedelta(seconds=repay_seconds), status="active"))
    db.session.commit()
    return user_redirect("#promised")

@app.route("/promised/repay", methods=["POST"])
@login_required
def promised_repay():
    debt = PromisedDebt.query.filter_by(user_id=current_user.id, status="active").first()
    if not debt: return user_redirect("#promised")
    if current_user.balance < debt.repay_amount:
        flash(f"Недостаточно баланса: нужно {debt.repay_amount:.2f}."); return user_redirect("#promised")
    current_user.balance -= debt.repay_amount
    db.session.add(Transaction(user_id=current_user.id, amount=-debt.repay_amount, reason="Досрочный возврат обещанного платежа"))
    debt.status = "repaid"; debt.repaid_at = datetime.utcnow(); db.session.commit()
    return user_redirect("#promised")

@app.route("/auto-renew/toggle", methods=["POST"])
@login_required
def auto_renew_toggle():
    current_user.auto_renew = not current_user.auto_renew
    db.session.commit()
    audit(current_user, "auto_renew", str(current_user.auto_renew))
    flash(f"Автопродление {'включено' if current_user.auto_renew else 'выключено'}.")
    return user_redirect("#tariffs")

@app.route("/freeze/request", methods=["POST"])
@login_required
def freeze_request():
    try: days = max(1, min(30, int(request.form.get("days", "7"))))
    except ValueError: days = 7
    if not subscription_active(current_user):
        flash("Нет активной подписки."); return user_redirect("#freeze")
    if SubscriptionFreeze.query.filter_by(user_id=current_user.id, status="pending").first():
        flash("Уже есть заявка на заморозке."); return user_redirect("#freeze")
    now = datetime.utcnow()
    db.session.add(SubscriptionFreeze(user_id=current_user.id, freeze_from=now, freeze_to=now + timedelta(days=days), status="pending"))
    db.session.commit()
    price = days * float(get_setting("freeze_price_per_day", "50") or 0)
    flash(f"Заявка на заморозку {days} дн. отправлена. Стоимость при подтверждении: {price:.0f} ₽.")
    return user_redirect("#freeze")

@app.route("/archive/order", methods=["POST"])
@login_required
def archive_order():
    try:
        camera_id = int(request.form.get("camera_id", ""))
        from_dt = datetime.strptime(request.form.get("from_dt", ""), "%Y-%m-%dT%H:%M")
        to_dt = datetime.strptime(request.form.get("to_dt", ""), "%Y-%m-%dT%H:%M")
    except (ValueError, TypeError):
        flash("Неверные данные периода."); return user_redirect("#archive-request")
    camera = get_or_404(Camera, camera_id)
    if to_dt <= from_dt: flash("Конец позже начала."); return user_redirect("#archive-request")
    if (to_dt - from_dt).total_seconds() > 3 * 86400: flash("Максимум 3 суток за заявку."); return user_redirect("#archive-request")
    price = float(get_setting("archive_order_price", "100") or 0)
    db.session.add(ArchiveOrder(user_id=current_user.id, camera_id=camera.id, from_dt=from_dt, to_dt=to_dt, price=price, status="pending"))
    db.session.commit()
    flash(f"Заявка на нарезку фрагмента создана. Стоимость {price:.0f} ₽ спишется после подтверждения.")
    return user_redirect("#archive-request")

@app.route("/archive-order/<int:oid>/download")
@login_required
def archive_order_download(oid):
    o = get_or_404(ArchiveOrder, oid)
    if o.user_id != current_user.id and not current_user.admin: abort(403)
    if o.status != "approved": abort(403)
    p = EXPORT_DIR / f"order_{o.id}.mp4"
    if not p.exists():
        flash("Файл ещё не подготовлен администратором.")
        return user_redirect("#archive-request")
    audit(current_user, "archive_order_download", o.id)
    return send_file(p, as_attachment=True, download_name=p.name)

@app.route("/tariff/choose", methods=["POST"])
@login_required
def tariff_choose():
    try:
        tariff_id = int(request.form.get("tariff_id", ""))
        bundle_id = request.form.get("bundle_id", "") or ""
    except ValueError: flash("Не выбран тариф."); return user_redirect("#tariffs")
    tariff = get_or_404(Tariff, tariff_id)
    if not tariff.is_active: return user_redirect("#tariffs")
    months, discount = 1, 0.0
    if bundle_id:
        b = db.session.get(TariffBundle, int(bundle_id))
        if b and b.tariff_id == tariff.id and b.is_active:
            months, discount = b.months, b.discount_percent
    if enabled_count(current_user) > tariff.max_cameras:
        return redirect(url_for("tariff_switch_page", tariff_id=tariff.id))
    ok, msg = apply_tariff(current_user, tariff, months, discount)
    flash(msg)
    return user_redirect("#tariffs")

@app.route("/tariff/switch/<int:tariff_id>")
@login_required
def tariff_switch_page(tariff_id):
    tariff = get_or_404(Tariff, tariff_id)
    enabled_items = enabled_cameras(current_user)
    if len(enabled_items) <= tariff.max_cameras:
        ok, msg = apply_tariff(current_user, tariff); flash(msg)
        return user_redirect("#tariffs")
    return render_template("tariff_switch.html", tariff=tariff, enabled_items=enabled_items)

@app.route("/tariff/switch/<int:tariff_id>/apply", methods=["POST"])
@login_required
def tariff_switch_apply(tariff_id):
    tariff = get_or_404(Tariff, tariff_id)
    chosen = {int(x) for x in request.form.getlist("camera_id") if x.strip().isdigit()}
    if len(chosen) > tariff.max_cameras:
        flash(f"Можно не более {tariff.max_cameras} камер."); return redirect(url_for("tariff_switch_page", tariff_id=tariff.id))
    ok, msg = apply_tariff(current_user, tariff)
    if not ok: flash(msg); return user_redirect("#tariffs")
    for cam in current_user.cameras:
        db.session.execute(camera_access.update().where(
            camera_access.c.user_id == current_user.id, camera_access.c.camera_id == cam.id
        ).values(enabled=(cam.id in chosen)))
    db.session.commit()
    flash(msg)
    return user_redirect("#tariffs")

@app.route("/camera/<int:camera_id>/set_enabled", methods=["POST"])
@login_required
def camera_set_enabled(camera_id):
    camera = get_or_404(Camera, camera_id)
    row = user_link(current_user.id, camera.id)
    if row is None: abort(403)
    want = request.form.get("enabled") == "1"
    if want:
        if current_user.tariff is None: flash("Нет тарифа."); return user_redirect("#cameras")
        if enabled_count(current_user) >= current_user.tariff.max_cameras:
            flash(f"Лимит тарифа: {current_user.tariff.max_cameras}."); return user_redirect("#cameras")
        db.session.execute(camera_access.update().where(camera_access.c.id == row.id).values(enabled=True))
    else:
        db.session.execute(camera_access.update().where(camera_access.c.id == row.id).values(enabled=False))
    db.session.commit()
    return user_redirect("#cameras")

@app.route("/camera/<int:camera_id>")
@login_required
def camera_page(camera_id):
    camera = get_camera_or_403(camera_id)
    audit(current_user, "camera_view", camera.name)
    days = build_archive_days(camera)
    days_json = json.dumps([{"day": d["day"], "segments": d["segments"]} for d in days])
    return render_template("camera.html", camera=camera, days=days, days_json=days_json,
        thumb=thumb_state(camera), zone=camera.motion_zone or "",
        is_admin=current_user.admin, team_role=team_role(current_user))

@app.route("/admin/camera/<int:camera_id>/zone", methods=["POST"])
@admin_required
def admin_camera_zone(camera_id):
    camera = get_or_404(Camera, camera_id)
    if request.form.get("clear") == "1":
        camera.motion_zone = None
        flash("Зона детекции сброшена: движение ищется по всему кадру.")
    else:
        try:
            x1 = float(request.form.get("x1", "0")); y1 = float(request.form.get("y1", "0"))
            x2 = float(request.form.get("x2", "1")); y2 = float(request.form.get("y2", "1"))
            if x2 - x1 < 0.05 or y2 - y1 < 0.05: raise ValueError
            camera.motion_zone = f"{max(0,min(1,x1)):.4f},{max(0,min(1,y1)):.4f},{max(0,min(1,x2)):.4f},{max(0,min(1,y2)):.4f}"
            flash("Зона детекции сохранена. Воркер применит за ~2 секунды.")
        except ValueError:
            flash("Некорректная зона: рамка слишком мала.")
    db.session.commit()
    audit(current_user, "motion_zone", camera.name)
    return redirect(url_for("camera_page", camera_id=camera.id))

@app.route("/admin/camera/<int:camera_id>/motion", methods=["POST"])
@admin_required
def admin_camera_motion(camera_id):
    camera = get_or_404(Camera, camera_id)
    camera.recording_mode = "motion" if (camera.recording_mode or "continuous") != "motion" else "continuous"
    db.session.commit()
    mode_ru = "по движению (событийная)" if camera.recording_mode == "motion" else "непрерывная"
    audit(current_user, "recording_mode", f"{camera.name}={mode_ru}")
    flash(f"Камера {camera.name}: режим записи — {mode_ru}. Воркер переключится за ~2 секунды.")
    return redirect(url_for("camera_page", camera_id=camera.id))

@app.route("/admin/camera/<int:camera_id>/glue/<day>", methods=["POST"])
@admin_required
def admin_camera_glue(camera_id, day):
    camera = get_or_404(Camera, camera_id)
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", day):
        flash("Неверный день."); return redirect(url_for("camera_page", camera_id=camera.id))
    if day >= datetime.utcnow().strftime("%Y-%m-%d"):
        flash("Текущий день склеивать рано: запись ещё идёт."); return redirect(url_for("camera_page", camera_id=camera.id))
    d = ARCHIVE_DIR / f"camera_{camera.id}"
    chunks = sorted([p for p in d.glob(f"{day}_*.mp4")]) if d.exists() else []
    if not chunks:
        flash("За этот день кусков нет."); return redirect(url_for("camera_page", camera_id=camera.id))
    out = d / f"{day}.mp4"
    if out.exists():
        flash("День уже склеен."); return redirect(url_for("camera_page", camera_id=camera.id))
    lst = d / f".concat_{day}.txt"
    with open(lst, "w") as fh:
        for f in chunks:
            fh.write(f"file '{f}'\n")
    rm_list = " ".join(f"'{f}'" for f in chunks)
    cmd = (f"ffmpeg -nostdin -loglevel error -f concat -safe 0 -i '{lst}' -c copy "
           f"-movflags +faststart '{out}' && rm -f {rm_list} '{lst}' || rm -f '{lst}'")
    subprocess.Popen(["bash", "-c", cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    audit(current_user, "glue_day", f"{camera.name} {day}")
    flash(f"Склейка дня {day} запущена в фоне: получится один файл с перемоткой; куски удалятся после успеха.")
    return redirect(url_for("camera_page", camera_id=camera.id))

@app.route("/live/<int:camera_id>/<path:filename>")
@login_required
def live_file(camera_id, filename):
    camera = get_camera_or_403(camera_id)
    return send_from_directory(str(LIVE_DIR / f"camera_{camera.id}"), filename, conditional=True)

@app.route("/archive/<int:camera_id>/<path:filename>")
@login_required
def archive_file(camera_id, filename):
    if team_role(current_user) == "viewer": abort(403)
    camera = get_camera_or_403(camera_id)
    return send_from_directory(str(ARCHIVE_DIR / f"camera_{camera.id}"), filename, as_attachment=False, conditional=True)

@app.route("/archive/<int:camera_id>/download/<path:filename>")
@login_required
def archive_download(camera_id, filename):
    if team_role(current_user) == "viewer": abort(403)
    camera = get_camera_or_403(camera_id)
    audit(current_user, "archive_download", f"{camera.name}/{filename}")
    return send_from_directory(str(ARCHIVE_DIR / f"camera_{camera.id}"), filename, as_attachment=True, download_name=f"camera{camera.id}_{filename}")

@app.route("/admin")
@admin_required
def admin_page():
    users = User.query.order_by(User.id.desc()).all()
    cameras = Camera.query.order_by(Camera.id.desc()).all()
    tariffs = Tariff.query.order_by(Tariff.id).all()
    thumbs = {c.id: thumb_state(c) for c in cameras}
    cam_requests = CameraRequest.query.order_by(CameraRequest.id.desc()).limit(30).all()
    q = request.args.get("q", "").strip()
    if q:
        like = f"%{q}%"
        transactions = db.session.execute(db.select(Transaction).join(User, Transaction.user_id == User.id).where(
            db.or_(User.username.like(like), Transaction.reason.like(like),
                   db.cast(Transaction.amount, db.String).like(like),
                   db.cast(Transaction.created_at, db.String).like(like))
        ).order_by(Transaction.id.desc()).limit(300)).scalars().all()
    else:
        transactions = Transaction.query.order_by(Transaction.id.desc()).limit(50).all()
    pending_requests = [{"p": p, "label": method_label(p.method)} for p in PaymentRequest.query.filter_by(status="pending").order_by(PaymentRequest.id).all()]
    processed_requests = [{"p": p, "label": method_label(p.method)} for p in
        PaymentRequest.query.filter(PaymentRequest.status != "pending", PaymentRequest.admin_hidden == False)
        .order_by(PaymentRequest.id.desc()).limit(50).all()]
    debts = [{"d": d, "overdue": d.due_at < datetime.utcnow()} for d in PromisedDebt.query.filter_by(status="active").all()]
    freezes = SubscriptionFreeze.query.filter(SubscriptionFreeze.status.in_(["pending", "active"])).order_by(SubscriptionFreeze.id.desc()).all()
    archive_orders = ArchiveOrder.query.order_by(ArchiveOrder.id.desc()).limit(30).all()
    partners = [{"p": p, "clients": User.query.filter_by(partner_of=p.id).count()} for p in Partner.query.all()]
    teams = TeamMember.query.order_by(TeamMember.id.desc()).all()
    recent_audit = AuditLog.query.order_by(AuditLog.id.desc()).limit(60).all()
    settings = {k: get_setting(k) for k in DEFAULT_SETTINGS}
    browser_active = False
    try: browser_active = bool(daemon_call({"cmd": "status"}, timeout=5).get("active"))
    except Exception: pass
    now = datetime.utcnow()
    paying = [u for u in users if u.tariff and subscription_active(u)]
    mrr = round(sum(u.tariff.price * (2592000.0 / (u.tariff.interval_seconds or 2592000)) for u in paying), 2)
    expired = [u for u in users if u.tariff and u.subscription_ends_at and u.subscription_ends_at <= now]
    churn = round(100.0 * len(expired) / max(1, len(paying) + len(expired)), 1)
    arpu = round(mrr / max(1, len(paying)), 2)
    revenue30 = round(-(db.session.execute(db.select(func.coalesce(func.sum(Transaction.amount), 0)).where(
        Transaction.amount < 0, Transaction.created_at >= now - timedelta(days=30))).scalar() or 0), 2)
    views = db.session.execute(db.select(func.date(AuditLog.created_at), func.count(AuditLog.id)).where(
        AuditLog.action == "camera_view", AuditLog.created_at >= now - timedelta(days=14))
        .group_by(func.date(AuditLog.created_at)).order_by(func.date(AuditLog.created_at))).all()
    stats = {"mrr": mrr, "churn": churn, "arpu": arpu, "revenue30": revenue30,
             "paying": len(paying), "total": len(users), "views": [(str(d), c) for d, c in views]}
    return render_template("admin.html", users=users, cameras=cameras, tariffs=tariffs, transactions=transactions,
        tx_query=q, pending_requests=pending_requests, processed_requests=processed_requests, debts=debts,
        freezes=freezes, archive_orders=archive_orders, partners=partners, teams=teams, thumbs=thumbs,
        cam_requests=cam_requests, recent_audit=recent_audit, settings=settings, methods=PAY_METHODS, roles=ROLES,
        browser_active=browser_active, stats=stats)

@app.route("/admin/browser")
@admin_required
def admin_browser_page():
    active = False; burl = ""
    try:
        st = daemon_call({"cmd": "status"}, timeout=5); active = bool(st.get("active")); burl = st.get("url", "")
    except Exception: pass
    return render_template("browser.html", active=active, burl=burl)

@app.route("/admin/browser/start", methods=["POST"])
@admin_required
def admin_browser_start():
    url = request.form.get("url", "").strip()
    if not url: flash("Укажи адрес."); return redirect(url_for("admin_browser_page"))
    try:
        r = daemon_call({"cmd": "start", "url": url, "cookie": ""})
        if r.get("ok"): flash("Браузер открыт.")
    except Exception as e: flash(f"Ошибка: {e}")
    return redirect(url_for("admin_browser_page"))

@app.route("/admin/browser/action", methods=["POST"])
@admin_required
def admin_browser_action():
    try:
        daemon_call({"cmd": "action", "act": request.form.get("act", "wait"),
            "x": request.form.get("x", "0"), "y": request.form.get("y", "0"),
            "text": request.form.get("text", "")}, timeout=60)
    except Exception as e: flash(f"Ошибка: {e}")
    return redirect(url_for("admin_browser_page"))

@app.route("/admin/browser/finish", methods=["POST"])
@admin_required
def admin_browser_finish():
    base_url = ""
    try:
        st = daemon_call({"cmd": "status"}, timeout=5); base_url = st.get("url", "")
        r = daemon_call({"cmd": "finish"}, timeout=120); cands = r.get("cands", [])[:12]
    except Exception as e:
        flash(f"Ошибка: {e}"); return redirect(url_for("admin_browser_page"))
    items = [{"idx": i, "url": u, "ok": probe_stream(u, i)} for i, u in enumerate(cands, 1)]
    return render_template("discover.html", items=items, error="", base_url=base_url)

@app.route("/admin/browser/cancel", methods=["POST"])
@admin_required
def admin_browser_cancel():
    try: daemon_call({"cmd": "cancel"}, timeout=30)
    except Exception: pass
    return redirect(url_for("admin_browser_page"))

@app.route("/admin/browser/shot.png")
@admin_required
def admin_browser_shot():
    p = PREVIEW_DIR / "browser_shot.png"
    if p.exists():
        resp = send_from_directory(str(PREVIEW_DIR), "browser_shot.png"); resp.headers["Cache-Control"] = "no-store"; return resp
    abort(404)

@app.route("/admin/discover", methods=["POST"])
@admin_required
def admin_discover():
    base_url = request.form.get("base_url", "").strip(); cookie = request.form.get("cookie", "").strip()
    if not base_url: return admin_redirect("#discover")
    error = ""; cands = []
    try:
        r = daemon_call({"cmd": "discover", "url": base_url, "cookie": cookie}, timeout=180); cands = r.get("cands", [])
    except Exception as e: error = f"Парсер недоступен ({e})."
    if not cands:
        try:
            html = fetch_page(base_url, cookie); cands = extract_candidates(html, base_url)
        except Exception as e: error += f" {e}"
    items = [{"idx": i, "url": u, "ok": probe_stream(u, i)} for i, u in enumerate(cands[:12], 1)]
    return render_template("discover.html", items=items, error=error, base_url=base_url)

@app.route("/admin/discover/preview/<path:filename>")
@admin_required
def discover_preview(filename):
    return send_from_directory(str(PREVIEW_DIR), filename, conditional=True)

@app.route("/admin/discover/attach", methods=["POST"])
@admin_required
def admin_discover_attach():
    url = request.form.get("url", "").strip()
    name = request.form.get("name", "").strip() or f"Источник {Camera.query.count() + 1}"
    rec = request.form.get("recording") == "1"
    if not url: return admin_redirect("#discover")
    db.session.add(Camera(name=name, rtsp_url=url, active=True, recording_enabled=rec))
    db.session.commit()
    return admin_redirect("#cameras")

@app.route("/admin/user/<int:user_id>/impersonate", methods=["POST"])
@admin_required
def admin_impersonate(user_id):
    user = get_or_404(User, user_id)
    if not user.active: return admin_redirect("#users")
    audit(current_user, "impersonate", user.username)
    session["impersonator"] = current_user.id
    logout_user(); login_user(user)
    return redirect(url_for("dashboard"))

@app.route("/admin/settings", methods=["POST"])
@admin_required
def admin_settings():
    for code, _ in PAY_METHODS: set_setting(f"method_{code}", "1" if request.form.get(f"method_{code}") else "0")
    for k in ("transfer_instruction", "promised_amount", "promised_repay_seconds", "promised_fee_percent",
              "partner_commission", "archive_order_price", "freeze_price_per_day", "motion_threshold",
              "whitelabel_name", "whitelabel_primary", "whitelabel_logo"):
        set_setting(k, request.form.get(k, ""))
    db.session.commit()
    flash("Настройки сохранены.")
    return admin_redirect("#settings")

@app.route("/admin/freeze/<int:freeze_id>/<action>", methods=["POST"])
@admin_required
def admin_freeze_action(freeze_id, action):
    fr = get_or_404(SubscriptionFreeze, freeze_id)
    if fr.status != "pending": return admin_redirect("#freezes")
    if action == "approve":
        days = max(1, (fr.freeze_to - fr.freeze_from).days or 1)
        price = round(days * float(get_setting("freeze_price_per_day", "50") or 0), 2)
        if fr.user.balance < price:
            flash(f"У {fr.user.username} не хватает баланса на заморозку ({price:.0f} ₽). Заявка не одобрена.")
            return admin_redirect("#freezes")
        fr.user.balance -= price
        db.session.add(Transaction(user_id=fr.user.id, amount=-price, reason=f"Платная заморозка подписки на {days} дн."))
        fr.price = price
        fr.status = "active"
        if fr.user.subscription_ends_at:
            fr.user.subscription_ends_at = fr.user.subscription_ends_at + (fr.freeze_to - fr.freeze_from)
        db.session.commit()
        flash(f"Заморозка одобрена: списано {price:.0f} ₽, доступ закрыт на период, запись идёт.")
    else:
        fr.status = "rejected"; db.session.commit(); flash("Заморозка отклонена.")
    return admin_redirect("#freezes")

@app.route("/admin/archive/<int:order_id>/<action>", methods=["POST"])
@admin_required
def admin_archive_order(order_id, action):
    o = get_or_404(ArchiveOrder, order_id)
    if o.status != "pending": return admin_redirect("#archive-orders")
    if action == "reject":
        o.status = "rejected"; o.processed_at = datetime.utcnow(); db.session.commit()
        flash("Заявка отклонена.")
        return admin_redirect("#archive-orders")
    if o.user.balance < o.price:
        flash(f"У {o.user.username} не хватает баланса ({o.price:.0f} ₽).")
        return admin_redirect("#archive-orders")
    o.user.balance -= o.price
    db.session.add(Transaction(user_id=o.user.id, amount=-o.price, reason=f"Нарезка фрагмента архива #{o.id} ({o.camera.name})"))
    o.status = "approved"; o.processed_at = datetime.utcnow()
    db.session.commit()
    flash(f"Оплачено. Положи файл в /opt/cctv/storage/exports/order_{o.id}.mp4 — клиент сможет скачать.")
    return admin_redirect("#archive-orders")

@app.route("/admin/partner/create", methods=["POST"])
@admin_required
def admin_partner_create():
    try: user_id = int(request.form.get("user_id", ""))
    except ValueError: return admin_redirect("#partners")
    user = get_or_404(User, user_id)
    if Partner.query.filter_by(user_id=user.id).first():
        flash("Уже партнёр."); return admin_redirect("#partners")
    commission = float(get_setting("partner_commission", "30") or 30)
    db.session.add(Partner(user_id=user.id, commission_percent=commission))
    db.session.commit()
    flash(f"Партнёр {user.username} создан, комиссия {commission}%.")
    return admin_redirect("#partners")

@app.route("/admin/partner/<int:pid>/edit", methods=["POST"])
@admin_required
def admin_partner_edit(pid):
    p = get_or_404(Partner, pid)
    try: p.commission_percent = max(0.0, min(90.0, float(request.form.get("commission_percent", "30"))))
    except ValueError: pass
    db.session.commit()
    flash(f"Комиссия партнёра {p.user.username}: {p.commission_percent}%.")
    return admin_redirect("#partners")

@app.route("/admin/partner/<int:pid>/attach", methods=["POST"])
@admin_required
def admin_partner_attach(pid):
    p = get_or_404(Partner, pid)
    try: user_id = int(request.form.get("user_id", ""))
    except ValueError: return admin_redirect("#partners")
    user = get_or_404(User, user_id)
    user.partner_of = p.id
    p.total_referrals = (p.total_referrals or 0) + 1
    db.session.commit()
    flash(f"Клиент {user.username} прикреплён к партнёру {p.user.username}.")
    return admin_redirect("#partners")

@app.route("/admin/partner/<int:pid>/detach", methods=["POST"])
@admin_required
def admin_partner_detach(pid):
    p = get_or_404(Partner, pid)
    try: user_id = int(request.form.get("user_id", ""))
    except ValueError: return admin_redirect("#partners")
    user = get_or_404(User, user_id)
    if user.partner_of == p.id:
        user.partner_of = None
        p.total_referrals = max(0, (p.total_referrals or 0) - 1)
        db.session.commit()
    return admin_redirect("#partners")

@app.route("/admin/partner/<int:pid>/whitelabel", methods=["POST"])
@admin_required
def admin_whitelabel_save(pid):
    partner = get_or_404(Partner, pid)
    wl = WhiteLabel.query.filter_by(partner_id=partner.id).first()
    if not wl:
        wl = WhiteLabel(partner_id=partner.id); db.session.add(wl)
    wl.domain = request.form.get("domain", "").strip() or None
    wl.logo_url = request.form.get("logo_url", "").strip() or None
    wl.primary_color = request.form.get("primary_color", "#38bdf8").strip()
    wl.brand_name = request.form.get("brand_name", "CCTV").strip()
    db.session.commit()
    flash("White-label сохранён.")
    return admin_redirect("#partners")

@app.route("/admin/team/invite", methods=["POST"])
@admin_required
def admin_team_invite():
    try: owner_id = int(request.form.get("owner_id", ""))
    except ValueError: return admin_redirect("#team")
    owner = get_or_404(User, owner_id)
    if not (owner.tariff and owner.tariff.is_b2b):
        flash("Владелец не на B2B-тарифе."); return admin_redirect("#team")
    if TeamMember.query.filter_by(owner_id=owner.id).count() >= owner.tariff.max_users:
        flash(f"Лимит сотрудников: {owner.tariff.max_users}."); return admin_redirect("#team")
    username = request.form.get("username", "").strip(); password = request.form.get("password", "").strip()
    role = request.form.get("role", "viewer")
    if role not in dict(ROLES): role = "viewer"
    if not username or not password: return admin_redirect("#team")
    user = User.query.filter_by(username=username).first()
    if not user:
        user = User(username=username, password_hash=generate_password_hash(password), active=True, admin=False, balance=0.0)
        db.session.add(user); db.session.commit()
    if user.team_membership or user.admin:
        flash(f"{username} не может войти в команду."); return admin_redirect("#team")
    db.session.add(TeamMember(owner_id=owner.id, user_id=user.id, role=role))
    db.session.commit()
    flash(f"Сотрудник {username} добавлен ({role_label(role)}).")
    return admin_redirect("#team")

@app.route("/admin/team/<int:mid>/remove", methods=["POST"])
@admin_required
def admin_team_remove(mid):
    m = get_or_404(TeamMember, mid); db.session.delete(m); db.session.commit()
    flash("Сотрудник удалён из команды.")
    return admin_redirect("#team")

@app.route("/admin/promised/<int:debt_id>/cancel", methods=["POST"])
@admin_required
def admin_promised_cancel(debt_id):
    debt = get_or_404(PromisedDebt, debt_id)
    if debt.status != "active": return admin_redirect("#settings")
    debt.status = "cancelled"; debt.repaid_at = datetime.utcnow(); db.session.commit()
    return admin_redirect("#settings")

@app.route("/admin/payment/<int:pr_id>/approve", methods=["POST"])
@admin_required
def admin_payment_approve(pr_id):
    pr = get_or_404(PaymentRequest, pr_id)
    if pr.status != "pending": return admin_redirect("#requests")
    pr.status = "approved"; pr.processed_at = datetime.utcnow(); pr.user.balance += pr.amount
    db.session.add(Transaction(user_id=pr.user_id, amount=pr.amount,
        reason=f"Пополнение ({method_label(pr.method)})" + (f": {pr.comment}" if pr.comment else "")))
    db.session.commit()
    if pr.user.partner_of:
        partner = Partner.query.filter_by(user_id=pr.user.partner_of).first()
        if partner:
            commission = round(pr.amount * partner.commission_percent / 100.0, 2)
            partner.user.balance += commission
            db.session.add(Transaction(user_id=partner.user_id, amount=commission,
                reason=f"Партнёрская комиссия {partner.commission_percent:.0f}% с платежа {pr.user.username}"))
            partner.total_earned = (partner.total_earned or 0) + commission
            db.session.commit()
            flash(f"Партнёру {partner.user.username} начислена комиссия {commission:.2f} ₽.")
    return admin_redirect("#requests")

@app.route("/admin/payment/<int:pr_id>/reject", methods=["POST"])
@admin_required
def admin_payment_reject(pr_id):
    pr = get_or_404(PaymentRequest, pr_id)
    if pr.status != "pending": return admin_redirect("#requests")
    pr.status = "rejected"; pr.processed_at = datetime.utcnow(); db.session.commit()
    return admin_redirect("#requests")

@app.route("/admin/payment/<int:pr_id>/hide", methods=["POST"])
@admin_required
def admin_payment_hide(pr_id):
    pr = get_or_404(PaymentRequest, pr_id); pr.admin_hidden = True; db.session.commit()
    return admin_redirect("#requests")

@app.route("/admin/user/add", methods=["POST"])
@admin_required
def admin_user_add():
    username = request.form.get("username", "").strip(); password = request.form.get("password", "").strip()
    if not username or not password or User.query.filter_by(username=username).first():
        return admin_redirect("#users")
    u = User(username=username, password_hash=generate_password_hash(password), active=True, admin=False, balance=0.0)
    db.session.add(u); db.session.commit()
    return admin_redirect("#users")

@app.route("/admin/user/<int:user_id>/edit", methods=["POST"])
@admin_required
def admin_user_edit(user_id):
    user = get_or_404(User, user_id); username = request.form.get("username", "").strip()
    if not username: return admin_redirect("#users")
    ex = User.query.filter_by(username=username).first()
    if ex and ex.id != user.id: return admin_redirect("#users")
    user.username = username; db.session.commit()
    return admin_redirect("#users")

@app.route("/admin/user/<int:user_id>/credit", methods=["POST"])
@admin_required
def admin_user_credit(user_id):
    user = get_or_404(User, user_id)
    try: limit = float(request.form.get("credit_limit", "0"))
    except ValueError: return admin_redirect("#users")
    user.credit_limit = max(0.0, limit); db.session.commit()
    return admin_redirect("#users")

@app.route("/admin/user/<int:user_id>/toggle", methods=["POST"])
@admin_required
def admin_user_toggle(user_id):
    user = get_or_404(User, user_id)
    if user.id == current_user.id and user.active: return admin_redirect("#users")
    user.active = not user.active; db.session.commit()
    return admin_redirect("#users")

@app.route("/admin/user/<int:user_id>/delete", methods=["POST"])
@admin_required
def admin_user_delete(user_id):
    user = get_or_404(User, user_id)
    if user.id == current_user.id: return admin_redirect("#users")
    for t in list(user.transactions): db.session.delete(t)
    for pr in list(user.payment_requests): db.session.delete(pr)
    for d in list(user.promised_debts): db.session.delete(d)
    for m in list(user.team_membership): db.session.delete(m)
    for m in list(user.team_members_owned): db.session.delete(m)
    for cr in list(user.camera_requests): db.session.delete(cr)
    db.session.execute(camera_access.delete().where(camera_access.c.user_id == user.id))
    db.session.delete(user); db.session.commit()
    return admin_redirect("#users")

@app.route("/admin/user/<int:user_id>/password", methods=["POST"])
@admin_required
def admin_user_password(user_id):
    user = get_or_404(User, user_id); password = request.form.get("password", "").strip()
    if len(password) < 4: return admin_redirect("#users")
    user.password_hash = generate_password_hash(password); db.session.commit()
    return admin_redirect("#users")

@app.route("/admin/user/topup", methods=["POST"])
@admin_required
def admin_topup():
    try:
        user_id = int(request.form.get("user_id", "")); amount = float(request.form.get("amount", ""))
    except ValueError: return admin_redirect("#users")
    user = get_or_404(User, user_id); user.balance += amount
    reason = request.form.get("reason", "").strip() or method_label(request.form.get("method", "other"))
    db.session.add(Transaction(user_id=user.id, amount=amount, reason=f"Пополнение ({reason})"))
    db.session.commit()
    return admin_redirect("#users")

@app.route("/admin/user/<int:user_id>/tariff", methods=["POST"])
@admin_required
def admin_user_tariff(user_id):
    user = get_or_404(User, user_id)
    try: tariff_id = int(request.form.get("tariff_id", ""))
    except ValueError: return admin_redirect("#users")
    tariff = get_or_404(Tariff, tariff_id)
    ok, msg = apply_tariff(user, tariff); flash(msg)
    return admin_redirect("#users")

@app.route("/admin/transaction/<int:tx_id>/delete", methods=["POST"])
@admin_required
def admin_transaction_delete(tx_id):
    tx = get_or_404(Transaction, tx_id); db.session.delete(tx); db.session.commit()
    return admin_redirect("#transactions")

@app.route("/admin/transactions/clear", methods=["POST"])
@admin_required
def admin_transactions_clear():
    n = Transaction.query.delete(); db.session.commit()
    flash(f"Очищено {n} транзакций.")
    return admin_redirect("#transactions")

@app.route("/admin/audit/clear", methods=["POST"])
@admin_required
def admin_audit_clear():
    n = AuditLog.query.delete(); db.session.commit()
    flash(f"Очищено {n} записей журнала.")
    return admin_redirect("#audit")

@app.route("/admin/tariff/add", methods=["POST"])
@admin_required
def admin_tariff_add():
    name = request.form.get("name", "").strip()
    try:
        price = float(request.form.get("price", "0")); iv = int(request.form.get("interval_seconds", "2592000"))
        mc = int(request.form.get("max_cameras", "1")); ad = int(request.form.get("archive_days", "7"))
        mu = int(request.form.get("max_users", "1"))
    except ValueError: return admin_redirect("#tariffs")
    if not name or price <= 0: return admin_redirect("#tariffs")
    t = Tariff(name=name, price=price, interval_seconds=iv, max_cameras=mc, archive_days=ad,
        is_b2b=request.form.get("is_b2b") == "1", max_users=mu, is_active=True)
    db.session.add(t); db.session.commit()
    for m, d in ((3, 5.0), (6, 10.0), (12, 15.0)):
        db.session.add(TariffBundle(tariff_id=t.id, months=m, discount_percent=d))
    db.session.commit()
    return admin_redirect("#tariffs")

@app.route("/admin/tariff/<int:tariff_id>/edit", methods=["POST"])
@admin_required
def admin_tariff_edit(tariff_id):
    tariff = get_or_404(Tariff, tariff_id); name = request.form.get("name", "").strip()
    try:
        price = float(request.form.get("price", "0")); iv = int(request.form.get("interval_seconds", "2592000"))
        mc = int(request.form.get("max_cameras", "1")); ad = int(request.form.get("archive_days", "7"))
        mu = int(request.form.get("max_users", "1"))
    except ValueError: return admin_redirect("#tariffs")
    if not name or price <= 0: return admin_redirect("#tariffs")
    tariff.name = name; tariff.price = price; tariff.interval_seconds = iv
    tariff.max_cameras = mc; tariff.archive_days = ad
    tariff.is_b2b = request.form.get("is_b2b") == "1"; tariff.max_users = mu
    db.session.commit()
    return admin_redirect("#tariffs")

@app.route("/admin/tariff/<int:tariff_id>/toggle", methods=["POST"])
@admin_required
def admin_tariff_toggle(tariff_id):
    tariff = get_or_404(Tariff, tariff_id); tariff.is_active = not tariff.is_active; db.session.commit()
    return admin_redirect("#tariffs")

@app.route("/admin/tariff/<int:tariff_id>/delete", methods=["POST"])
@admin_required
def admin_tariff_delete(tariff_id):
    tariff = get_or_404(Tariff, tariff_id)
    if tariff.users: return admin_redirect("#tariffs")
    TariffBundle.query.filter_by(tariff_id=tariff.id).delete()
    db.session.delete(tariff); db.session.commit()
    return admin_redirect("#tariffs")

@app.route("/admin/camera/add", methods=["POST"])
@admin_required
def admin_camera_add():
    name = request.form.get("name", "").strip(); rtsp_url = request.form.get("rtsp_url", "").strip()
    if not name or not rtsp_url: return admin_redirect("#cameras")
    db.session.add(Camera(name=name, rtsp_url=rtsp_url, active=True, recording_enabled=False,
        group_name=request.form.get("group", "").strip() or None))
    db.session.commit()
    return admin_redirect("#cameras")

@app.route("/admin/camera/<int:camera_id>/edit", methods=["POST"])
@admin_required
def admin_camera_edit(camera_id):
    camera = get_or_404(Camera, camera_id)
    camera.name = request.form.get("name", "").strip()
    camera.rtsp_url = request.form.get("rtsp_url", "").strip()
    camera.group_name = request.form.get("group", "").strip() or None
    db.session.commit()
    return admin_redirect("#cameras")

@app.route("/admin/camera/<int:camera_id>/grant", methods=["POST"])
@admin_required
def admin_camera_grant(camera_id):
    camera = get_or_404(Camera, camera_id)
    try: user_id = int(request.form.get("user_id", ""))
    except ValueError: return admin_redirect("#cameras")
    user = get_or_404(User, user_id)
    if user_link(user.id, camera.id) is not None: return admin_redirect("#cameras")
    db.session.execute(camera_access.insert().values(camera_id=camera.id, user_id=user.id, enabled=True))
    db.session.commit()
    return admin_redirect("#cameras")

@app.route("/admin/camera/<int:camera_id>/revoke", methods=["POST"])
@admin_required
def admin_camera_revoke(camera_id):
    camera = get_or_404(Camera, camera_id)
    try: user_id = int(request.form.get("user_id", ""))
    except ValueError: return admin_redirect("#cameras")
    row = user_link(user_id, camera.id)
    if row is None: return admin_redirect("#cameras")
    db.session.execute(camera_access.delete().where(camera_access.c.id == row.id))
    db.session.commit()
    return admin_redirect("#cameras")

@app.route("/admin/camera/<int:camera_id>/toggle", methods=["POST"])
@admin_required
def admin_camera_toggle(camera_id):
    camera = get_or_404(Camera, camera_id); camera.active = not camera.active; db.session.commit()
    return admin_redirect("#cameras")

@app.route("/admin/camera/<int:camera_id>/recording", methods=["POST"])
@admin_required
def admin_camera_recording(camera_id):
    camera = get_or_404(Camera, camera_id); camera.recording_enabled = not camera.recording_enabled; db.session.commit()
    audit(current_user, "recording_toggle", f"{camera.name}={camera.recording_enabled}")
    return admin_redirect("#cameras")

@app.route("/admin/camera/<int:camera_id>/delete", methods=["POST"])
@admin_required
def admin_camera_delete(camera_id):
    camera = get_or_404(Camera, camera_id)
    db.session.execute(camera_access.delete().where(camera_access.c.camera_id == camera.id))
    ArchiveOrder.query.filter_by(camera_id=camera.id).delete()
    db.session.delete(camera); db.session.commit()
    return admin_redirect("#cameras")

@app.route("/api/me")
@login_required
def api_me():
    return jsonify({"id": current_user.id, "username": current_user.username, "balance": current_user.balance,
        "tariff": current_user.tariff.name if current_user.tariff else None,
        "ends_at": current_user.subscription_ends_at.isoformat() if current_user.subscription_ends_at else None})

@app.route("/api/cameras")
@login_required
def api_cameras():
    owner = effective_owner(current_user)
    cams = Camera.query.all() if current_user.admin else owner.cameras
    return jsonify([{"id": c.id, "name": c.name, "group": c.group_name, "active": c.active,
        "recording": c.recording_enabled, "mode": c.recording_mode, "zone": c.motion_zone} for c in cams])

@app.route("/api/cameras/<int:cid>/records")
@login_required
def api_records(cid):
    camera = get_camera_or_403(cid)
    return jsonify(build_archive_days(camera))

@app.route("/static/<path:filename>")
def static_files(filename):
    return send_from_directory(str(BASE_DIR / "app" / "static"), filename)

@app.route("/manifest.json")
def manifest():
    return send_from_directory(str(BASE_DIR / "app" / "static"), "manifest.json")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
