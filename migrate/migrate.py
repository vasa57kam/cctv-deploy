#!/usr/bin/env python3
import sqlite3
import os
import hashlib
from pathlib import Path

BASE_DIR = Path("/opt/cctv")
DB_PATH = BASE_DIR / "app" / "cctv.db"

def hash_password(password):
    salt = os.urandom(16).hex()
    hash_obj = hashlib.pbkdf2_hmac('sha256', password.encode(), salt.encode(), 100000)
    return f"pbkdf2:sha256:100000${salt}${hash_obj.hex()}"

def migrate():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    
    conn_wal = sqlite3.connect(str(DB_PATH))
    conn_wal.execute("PRAGMA journal_mode=WAL")
    conn_wal.commit()
    conn_wal.close()
    
    conn = sqlite3.connect(str(DB_PATH))
    cur = conn.cursor()
    
    try:
        cur.executescript("""
        CREATE TABLE IF NOT EXISTS setting (key TEXT PRIMARY KEY, value TEXT);
        
        CREATE TABLE IF NOT EXISTS tariff (
            id INTEGER PRIMARY KEY, name TEXT NOT NULL, price REAL NOT NULL,
            period_days INTEGER DEFAULT 30, interval_seconds INTEGER DEFAULT 2592000,
            max_cameras INTEGER DEFAULT 1, archive_days INTEGER DEFAULT 7,
            is_active INTEGER DEFAULT 1, is_b2b INTEGER DEFAULT 0, max_users INTEGER DEFAULT 1
        );
        
        CREATE TABLE IF NOT EXISTS tariff_bundle (
            id INTEGER PRIMARY KEY, tariff_id INTEGER NOT NULL, months INTEGER NOT NULL,
            discount_percent REAL DEFAULT 0.0, is_active INTEGER DEFAULT 1
        );
        
        CREATE TABLE IF NOT EXISTS user (
            id INTEGER PRIMARY KEY, username TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL,
            balance REAL DEFAULT 0.0, credit_limit REAL DEFAULT 0.0, admin INTEGER DEFAULT 0,
            active INTEGER DEFAULT 1, created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            tariff_id INTEGER, subscription_ends_at DATETIME, auto_renew INTEGER DEFAULT 0,
            referred_by INTEGER, partner_of INTEGER
        );
        
        CREATE TABLE IF NOT EXISTS camera (
            id INTEGER PRIMARY KEY, name TEXT NOT NULL, rtsp_url TEXT NOT NULL, user_id INTEGER,
            active INTEGER DEFAULT 1, recording_enabled INTEGER DEFAULT 0,
            recording_mode TEXT DEFAULT 'continuous', motion_zone TEXT, onvif_url TEXT,
            group_name TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        
        CREATE TABLE IF NOT EXISTS camera_access (
            id INTEGER PRIMARY KEY, camera_id INTEGER NOT NULL, user_id INTEGER NOT NULL, enabled INTEGER DEFAULT 1
        );
        
        CREATE TABLE IF NOT EXISTS camera_request (
            id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, ip TEXT NOT NULL, login TEXT,
            password TEXT, comment TEXT, status TEXT DEFAULT 'pending',
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        
        CREATE TABLE IF NOT EXISTS "transaction" (
            id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, amount REAL NOT NULL,
            reason TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        
        CREATE TABLE IF NOT EXISTS payment_request (
            id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, amount REAL NOT NULL,
            method TEXT DEFAULT 'other', comment TEXT, status TEXT DEFAULT 'pending',
            user_hidden INTEGER DEFAULT 0, admin_hidden INTEGER DEFAULT 0,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP, processed_at DATETIME
        );
        
        CREATE TABLE IF NOT EXISTS team_member (
            id INTEGER PRIMARY KEY, owner_id INTEGER NOT NULL, user_id INTEGER NOT NULL UNIQUE,
            role TEXT DEFAULT 'viewer', created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        
        CREATE TABLE IF NOT EXISTS partner (
            id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL UNIQUE,
            commission_percent REAL DEFAULT 30.0, total_referrals INTEGER DEFAULT 0,
            total_earned REAL DEFAULT 0.0
        );
        
        CREATE TABLE IF NOT EXISTS whitelabel (
            id INTEGER PRIMARY KEY, partner_id INTEGER NOT NULL UNIQUE, domain TEXT,
            logo_url TEXT, primary_color TEXT DEFAULT '#38bdf8', brand_name TEXT DEFAULT 'CCTV'
        );
        
        CREATE TABLE IF NOT EXISTS audit_log (
            id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, action TEXT NOT NULL,
            target TEXT, ip TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        
        CREATE INDEX IF NOT EXISTS idx_audit_user ON audit_log(user_id);
        CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_log(created_at);
        """)
        
        cur.execute("SELECT COUNT(*) FROM tariff")
        if cur.fetchone()[0] == 0:
            tariffs = [
                ("Старт", 290, 2592000, 1, 3, 0, 1),
                ("Базовый", 690, 2592000, 3, 7, 0, 1),
                ("Бизнес", 1990, 2592000, 10, 7, 0, 1),
                ("B2B Офис", 4990, 2592000, 20, 30, 1, 5),
                ("B2B ТСЖ", 1490, 2592000, 8, 14, 1, 3),
            ]
            for name, price, interval, max_cam, archive, is_b2b, max_users in tariffs:
                cur.execute(
                    "INSERT INTO tariff (name, price, interval_seconds, max_cameras, archive_days, is_b2b, max_users) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (name, price, interval, max_cam, archive, is_b2b, max_users)
                )
            
            cur.execute("SELECT id FROM tariff")
            tariff_ids = [r[0] for r in cur.fetchall()]
            for tid in tariff_ids:
                for months, discount in [(3, 5.0), (6, 10.0), (12, 15.0)]:
                    cur.execute(
                        "INSERT INTO tariff_bundle (tariff_id, months, discount_percent) VALUES (?, ?, ?)",
                        (tid, months, discount)
                    )
            print("migration: seeded default tariffs + bundles")
        
        admin_user = os.environ.get("ADMIN_USERNAME", "admin")
        admin_pass = os.environ.get("ADMIN_PASSWORD", "admin123")
        
        cur.execute("SELECT id FROM user WHERE username = ?", (admin_user,))
        if not cur.fetchone():
            try:
                cur.execute(
                    "INSERT INTO user (username, password_hash, admin, active) VALUES (?, ?, 1, 1)",
                    (admin_user, hash_password(admin_pass))
                )
                conn.commit()
                print(f"migration: created admin user '{admin_user}'")
            except sqlite3.IntegrityError:
                conn.rollback()
                print(f"migration: admin user '{admin_user}' already exists")
        
        conn.commit()
        print("migration ok")
        
    except Exception as e:
        conn.rollback()
        print(f"migration error: {e}")
        raise
    finally:
        conn.close()

if __name__ == "__main__":
    migrate()