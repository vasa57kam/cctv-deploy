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

def is_frozen(conn, user_id, now_str):
    row = conn.execute(
        "SELECT 1 FROM subscription_freeze WHERE user_id=? AND status='active' AND freeze_from <= ? AND freeze_to >= ?",
        (user_id, now_str, now_str)).fetchone()
    return row is not None

def tick():
    if not DB_PATH.exists(): return
    conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row
    now = datetime.utcnow(); now_str = now.isoformat(sep=" ")

    rows = conn.execute("""
        SELECT u.id AS user_id, u.username, u.balance, u.credit_limit, u.subscription_ends_at, u.auto_renew,
               t.id AS tariff_id, t.name AS tariff_name, t.price, t.interval_seconds
        FROM user u JOIN tariff t ON t.id = u.tariff_id
        WHERE u.active = 1 AND u.tariff_id IS NOT NULL AND u.subscription_ends_at IS NOT NULL""").fetchall()
    for r in rows:
        try: ends = datetime.fromisoformat(r["subscription_ends_at"])
        except (ValueError, TypeError): continue
        if is_frozen(conn, r["user_id"], now_str): continue
        interval = int(r["interval_seconds"] or 2592000)
        credit = float(r["credit_limit"] or 0)
        due_soon = ends <= now + timedelta(days=1)
        if ends > now and not (r["auto_renew"] and due_soon): continue
        if (r["balance"] - r["price"]) < -credit: continue
        base = ends if ends > now else now
        new_ends = base + timedelta(seconds=interval)
        conn.execute("UPDATE user SET balance = balance - ?, subscription_ends_at = ? WHERE id = ?",
            (r["price"], new_ends.isoformat(sep=" "), r["user_id"]))
        reason = f"Списание по тарифу {r['tariff_name']} (интервал {interval} с)"
        if r["auto_renew"] and ends > now:
            reason = f"Автопродление тарифа {r['tariff_name']} (интервал {interval} с)"
        conn.execute('INSERT INTO "transaction" (user_id, amount, reason, created_at) VALUES (?, ?, ?, ?)',
            (r["user_id"], -r["price"], reason, now_str))
        conn.commit()

    debts = conn.execute("""
        SELECT d.id, d.user_id, d.repay_amount, u.balance
        FROM promised_debt d JOIN user u ON u.id = d.user_id
        WHERE d.status = 'active' AND d.due_at <= ?""", (now_str,)).fetchall()
    for d in debts:
        if d["balance"] >= d["repay_amount"]:
            conn.execute("UPDATE user SET balance = balance - ? WHERE id = ?", (d["repay_amount"], d["user_id"]))
            conn.execute('INSERT INTO "transaction" (user_id, amount, reason, created_at) VALUES (?, ?, ?, ?)',
                (d["user_id"], -d["repay_amount"], "Возврат обещанного платежа (с комиссией)", now_str))
            conn.execute("UPDATE promised_debt SET status = 'repaid', repaid_at = ? WHERE id = ?", (now_str, d["id"]))
            conn.commit()
    conn.close()

while True:
    try: tick()
    except Exception as e: print("[billing] error:", e, flush=True)
    ticks += 1
    if ticks % 3600 == 0: prune_old_transactions()
    time.sleep(1)