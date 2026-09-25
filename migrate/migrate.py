import sqlite3, os

DB = "/opt/cctv/app/cctv.db"
os.makedirs(os.path.dirname(DB), exist_ok=True)
conn = sqlite3.connect(DB)
cur = conn.cursor()


def cols(t):
    return {r[1] for r in cur.execute(f"PRAGMA table_info({t})").fetchall()}


def has(t):
    return t in {r[0] for r in cur.execute(
        "SELECT name FROM sqlite_master WHERE type='table'").fetchall()}


cur.executescript("""
CREATE TABLE IF NOT EXISTS setting (key VARCHAR(80) PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS tariff (id INTEGER PRIMARY KEY, name VARCHAR(80) NOT NULL, price FLOAT NOT NULL,
  period_days INTEGER, interval_seconds INTEGER, max_cameras INTEGER, archive_days INTEGER,
  is_active BOOLEAN, is_b2b BOOLEAN DEFAULT 0, max_users INTEGER DEFAULT 1);
CREATE TABLE IF NOT EXISTS tariff_bundle (id INTEGER PRIMARY KEY, tariff_id INTEGER NOT NULL,
  months INTEGER NOT NULL, discount_percent FLOAT DEFAULT 0, is_active BOOLEAN DEFAULT 1);
CREATE TABLE IF NOT EXISTS user (id INTEGER PRIMARY KEY, username VARCHAR(80) NOT NULL UNIQUE,
  password_hash VARCHAR(255) NOT NULL, balance FLOAT DEFAULT 0, credit_limit FLOAT DEFAULT 0,
  admin BOOLEAN DEFAULT 0, active BOOLEAN DEFAULT 1, created_at TIMESTAMP, tariff_id INTEGER,
  subscription_ends_at TIMESTAMP, auto_renew BOOLEAN DEFAULT 0, referred_by INTEGER, partner_of INTEGER);
CREATE TABLE IF NOT EXISTS team_member (id INTEGER PRIMARY KEY, owner_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL UNIQUE, role VARCHAR(20) DEFAULT 'viewer', created_at TIMESTAMP);
CREATE TABLE IF NOT EXISTS camera (id INTEGER PRIMARY KEY, name VARCHAR(120) NOT NULL, rtsp_url TEXT NOT NULL,
  user_id INTEGER, active BOOLEAN DEFAULT 1, recording_enabled BOOLEAN DEFAULT 0,
  group_name VARCHAR(60), created_at TIMESTAMP);
CREATE TABLE IF NOT EXISTS camera_access (id INTEGER PRIMARY KEY, camera_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL, enabled BOOLEAN DEFAULT 1);
CREATE TABLE IF NOT EXISTS "transaction" (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL,
  amount FLOAT NOT NULL, reason VARCHAR(255), created_at TIMESTAMP);
CREATE TABLE IF NOT EXISTS payment_request (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL,
  amount FLOAT NOT NULL, method VARCHAR(20), comment VARCHAR(255), status VARCHAR(10) DEFAULT 'pending',
  user_hidden BOOLEAN DEFAULT 0, admin_hidden BOOLEAN DEFAULT 0, created_at TIMESTAMP, processed_at TIMESTAMP);
CREATE TABLE IF NOT EXISTS promised_debt (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL,
  principal FLOAT NOT NULL, repay_amount FLOAT NOT NULL, created_at TIMESTAMP, due_at TIMESTAMP,
  status VARCHAR(10) DEFAULT 'active', repaid_at TIMESTAMP);
CREATE TABLE IF NOT EXISTS subscription_freeze (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL,
  freeze_from TIMESTAMP NOT NULL, freeze_to TIMESTAMP NOT NULL, original_ends_at TIMESTAMP,
  status VARCHAR(10) DEFAULT 'pending', created_at TIMESTAMP);
CREATE TABLE IF NOT EXISTS referral (id INTEGER PRIMARY KEY, referrer_id INTEGER NOT NULL,
  referee_id INTEGER NOT NULL, bonus_amount FLOAT DEFAULT 0, status VARCHAR(10) DEFAULT 'pending',
  created_at TIMESTAMP, credited_at TIMESTAMP);
CREATE TABLE IF NOT EXISTS audit_log (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL,
  action VARCHAR(40) NOT NULL, target VARCHAR(255), ip VARCHAR(45), created_at TIMESTAMP);
CREATE TABLE IF NOT EXISTS archive_order (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL,
  camera_id INTEGER NOT NULL, from_dt TIMESTAMP NOT NULL, to_dt TIMESTAMP NOT NULL,
  price FLOAT DEFAULT 0, status VARCHAR(10) DEFAULT 'pending', file_path VARCHAR(500),
  created_at TIMESTAMP, processed_at TIMESTAMP);
CREATE TABLE IF NOT EXISTS partner (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL UNIQUE,
  commission_percent FLOAT DEFAULT 30, total_referrals INTEGER DEFAULT 0, total_earned FLOAT DEFAULT 0);
CREATE TABLE IF NOT EXISTS whitelabel (id INTEGER PRIMARY KEY, partner_id INTEGER NOT NULL UNIQUE,
  domain VARCHAR(200), logo_url VARCHAR(500), primary_color VARCHAR(20) DEFAULT '#38bdf8',
  brand_name VARCHAR(80) DEFAULT 'CCTV');
""")

if has("tariff"):
    c = cols("tariff")
    if "is_b2b" not in c:
        cur.execute("ALTER TABLE tariff ADD COLUMN is_b2b BOOLEAN DEFAULT 0")
    if "max_users" not in c:
        cur.execute("ALTER TABLE tariff ADD COLUMN max_users INTEGER DEFAULT 1")
    if "interval_seconds" not in c:
        cur.execute("ALTER TABLE tariff ADD COLUMN interval_seconds INTEGER")
        cur.execute("UPDATE tariff SET interval_seconds = COALESCE(period_days,30)*86400 WHERE interval_seconds IS NULL")
        print("migration: tariff += interval_seconds")

if has("user"):
    c = cols("user")
    for name, ddl in [("tariff_id", "INTEGER"), ("subscription_ends_at", "TIMESTAMP"),
                      ("credit_limit", "FLOAT DEFAULT 0"), ("auto_renew", "BOOLEAN DEFAULT 0"),
                      ("referred_by", "INTEGER"), ("partner_of", "INTEGER")]:
        if name not in c:
            cur.execute(f"ALTER TABLE user ADD COLUMN {name} {ddl}")
            print(f"migration: user += {name}")

if has("camera"):
    c = cols("camera")
    if "recording_enabled" not in c:
        cur.execute("ALTER TABLE camera ADD COLUMN recording_enabled BOOLEAN DEFAULT 0")
        print("migration: camera += recording_enabled")
    if "group_name" not in c:
        cur.execute("ALTER TABLE camera ADD COLUMN group_name VARCHAR(60)")
        print("migration: camera += group_name")

if has("camera_access"):
    c = cols("camera_access")
    if "enabled" not in c:
        cur.execute("ALTER TABLE camera_access ADD COLUMN enabled BOOLEAN DEFAULT 1")
        print("migration: camera_access += enabled")
    cur.execute("""INSERT INTO camera_access (camera_id, user_id, enabled)
        SELECT id, user_id, 1 FROM camera WHERE user_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM camera_access ca
                        WHERE ca.camera_id = camera.id AND ca.user_id = camera.user_id)""")
    print("migration: camera_access seeded from old owners")

if has("payment_request"):
    c = cols("payment_request")
    if "user_hidden" not in c:
        cur.execute("ALTER TABLE payment_request ADD COLUMN user_hidden BOOLEAN DEFAULT 0")
        print("migration: payment_request += user_hidden")
    if "admin_hidden" not in c:
        cur.execute("ALTER TABLE payment_request ADD COLUMN admin_hidden BOOLEAN DEFAULT 0")
        print("migration: payment_request += admin_hidden")

n = cur.execute("SELECT COUNT(*) FROM tariff").fetchone()[0]
if n == 0:
    cur.execute("""INSERT INTO tariff
        (name, price, period_days, interval_seconds, max_cameras, archive_days, is_active, is_b2b, max_users)
        VALUES (?,?,?,?,?,?,1,0,1),(?,?,?,?,?,?,1,0,1),(?,?,?,?,?,?,1,0,1),
               (?,?,?,?,?,?,1,1,5),(?,?,?,?,?,?,1,1,3)""",
        ("Старт", 290, 30, 2592000, 1, 3,
         "Базовый", 690, 30, 2592000, 3, 7,
         "Бизнес", 1990, 30, 2592000, 10, 7,
         "B2B Офис", 4990, 30, 2592000, 20, 30,
         "B2B ТСЖ", 1490, 30, 2592000, 8, 14))
    for tid in range(1, 6):
        for months, disc in ((3, 5.0), (6, 10.0), (12, 15.0)):
            cur.execute("INSERT INTO tariff_bundle (tariff_id, months, discount_percent, is_active) VALUES (?,?,?,1)",
                        (tid, months, disc))
    print("migration: seeded default tariffs + bundles")

cur.execute("PRAGMA journal_mode=WAL").fetchall()
conn.commit()
conn.close()
print("migration ok")