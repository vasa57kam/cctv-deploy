import os, time, sqlite3
from datetime import datetime, timedelta
from pathlib import Path

BASE_DIR = Path(os.environ.get("CCTV_BASE_DIR", "/opt/cctv"))
DB_PATH = BASE_DIR / "app" / "cctv.db"
SUBSCRIPTION_INTERVAL = 60; DEBT_INTERVAL = 300; FREEZE_INTERVAL = 300; VPN_BILLING_INTERVAL = 60
VPN_RATES = {"vpn_vless_reality": 0.50, "vpn_wireguard": 0.33, "vpn_openvpn": 0.25}

def get_db():
    conn = sqlite3.connect(str(DB_PATH)); conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL"); return conn

def log(msg): print(f"[{datetime.utcnow():%Y-%m-%d %H:%M:%S}] {msg}", flush=True)

def process_subscriptions():
    conn = get_db(); cur = conn.cursor(); now = datetime.utcnow()
    cur.execute("""SELECT u.id,u.username,u.balance,u.credit_limit,u.auto_renew,u.subscription_ends_at,
                   t.price,t.interval_seconds,t.name AS tn FROM user u JOIN tariff t ON u.tariff_id=t.id
                   WHERE u.active=1 AND u.admin=0 AND u.subscription_ends_at IS NOT NULL""")
    for u in cur.fetchall():
        try: ends = datetime.fromisoformat(u["subscription_ends_at"])
        except Exception: continue
        if now < ends: continue
        price=float(u["price"] or 0); bal=float(u["balance"] or 0); cl=float(u["credit_limit"] or 0)
        if u["auto_renew"] and (bal >= price or bal >= -cl):
            ne = ends + timedelta(seconds=int(u["interval_seconds"] or 2592000))
            cur.execute("UPDATE user SET balance=?, subscription_ends_at=? WHERE id=?", (bal-price, ne.isoformat(), u["id"]))
            cur.execute('INSERT INTO "transaction"(user_id,amount,reason,created_at) VALUES(?,?,?,?)',
                        (u["id"], -price, f"Автопродление {u['tn']}", now.isoformat()))
            conn.commit(); log(f"Продлил {u['username']}: -{price}р")
        else:
            cur.execute("UPDATE user SET active=0 WHERE id=?", (u["id"],)); conn.commit()
            log(f"Заблокировал {u['username']}")
    conn.close()

def process_vpn_billing():
    conn = get_db(); cur = conn.cursor(); now = datetime.utcnow()
    try:
        cur.execute("""SELECT s.id,s.user_id,s.type,u.username,u.balance,u.active FROM services s
                       JOIN user u ON s.user_id=u.id WHERE s.status='active' AND s.type LIKE 'vpn_%'""")
    except Exception:
        conn.close(); return
    n=0
    for s in cur.fetchall():
        rate = VPN_RATES.get(s["type"], 0)
        if not rate: continue
        bal = float(s["balance"] or 0)
        if bal >= rate and s["active"]:
            cur.execute("UPDATE user SET balance=? WHERE id=?", (bal-rate, s["user_id"]))
            cur.execute('INSERT INTO "transaction"(user_id,amount,reason,created_at) VALUES(?,?,?,?)',
                        (s["user_id"], -rate, f"{s['type']} (1 мин)", now.isoformat()))
            conn.commit(); n+=1
        elif s["active"]:
            cur.execute("UPDATE services SET status='suspended' WHERE id=?", (s["id"],)); conn.commit()
            log(f"Приостановил {s['type']} для {s['username']}")
    conn.close()
    if n: log(f"VPN списаний: {n}")

def process_promised_debts():
    conn = get_db(); cur = conn.cursor(); now = datetime.utcnow()
    cur.execute("""SELECT d.id,d.user_id,d.principal,d.repay_amount,u.username,u.balance FROM promised_debt d
                   JOIN user u ON d.user_id=u.id WHERE d.status='active' AND d.due_at<=?""", (now.isoformat(),))
    for d in cur.fetchall():
        rep=float(d["repay_amount"] or 0); bal=float(d["balance"] or 0)
        if bal >= rep:
            cur.execute("UPDATE user SET balance=? WHERE id=?", (bal-rep, d["user_id"]))
            cur.execute("UPDATE promised_debt SET status='repaid', repaid_at=? WHERE id=?", (now.isoformat(), d["id"]))
            cur.execute('INSERT INTO "transaction"(user_id,amount,reason,created_at) VALUES(?,?,?,?)',
                        (d["user_id"], -rep, f"Возврат обещанного ({d['principal']}р)", now.isoformat()))
            conn.commit(); log(f"Списал долг {d['username']}: -{rep}р")
    conn.close()

def process_freezes():
    conn = get_db(); cur = conn.cursor(); now = datetime.utcnow()
    cur.execute("""SELECT f.id,f.user_id,f.freeze_from,f.freeze_to,u.username,u.subscription_ends_at
                   FROM subscription_freeze f JOIN user u ON f.user_id=u.id
                   WHERE f.status='active' AND f.freeze_to<=?""", (now.isoformat(),))
    for f in cur.fetchall():
        try:
            fr=datetime.fromisoformat(f["freeze_from"]); to=datetime.fromisoformat(f["freeze_to"])
        except Exception: continue
        if f["subscription_ends_at"]:
            try:
                e=datetime.fromisoformat(f["subscription_ends_at"])
                cur.execute("UPDATE user SET subscription_ends_at=? WHERE id=?", ((e+(to-fr)).isoformat(), f["user_id"]))
            except Exception: pass
        cur.execute("UPDATE subscription_freeze SET status='completed' WHERE id=?", (f["id"],)); conn.commit()
        log(f"Заморозка завершена: {f['username']}")
    conn.close()

def main():
    log("Billing started (CCTV + VPN)")
    ls=ld=lf=lv=0
    while True:
        n=time.time()
        try:
            if n-ls>=SUBSCRIPTION_INTERVAL: process_subscriptions(); ls=n
            if n-lv>=VPN_BILLING_INTERVAL: process_vpn_billing(); lv=n
            if n-ld>=DEBT_INTERVAL: process_promised_debts(); ld=n
            if n-lf>=FREEZE_INTERVAL: process_freezes(); lf=n
        except Exception as e: log(f"Error: {e}")
        time.sleep(1)

if __name__ == "__main__": main()
