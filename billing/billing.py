#!/usr/bin/env python3
"""
CCTV Billing Service
Фоновый сервис для обработки подписок, обещанных платежей и заморозок.
Тикает каждую секунду, но проверки проводит с заданным интервалом.
"""

import os
import time
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path

BASE_DIR = Path(os.environ.get("CCTV_BASE_DIR", "/opt/cctv"))
DB_PATH = BASE_DIR / "app" / "cctv.db"

# Интервалы проверок (секунды)
SUBSCRIPTION_INTERVAL = 60
DEBT_INTERVAL = 300
FREEZE_INTERVAL = 300


def get_db():
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def log(msg):
    print(f"[{datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def process_subscriptions():
    """Проверка подписок: автопродление или блокировка при истечении."""
    conn = get_db()
    cur = conn.cursor()
    now = datetime.utcnow()

    cur.execute("""
        SELECT u.id, u.username, u.balance, u.credit_limit, u.auto_renew,
               u.subscription_ends_at, u.active,
               t.price, t.interval_seconds, t.name AS tariff_name
        FROM user u
        JOIN tariff t ON u.tariff_id = t.id
        WHERE u.active = 1
          AND u.admin = 0
          AND u.subscription_ends_at IS NOT NULL
    """)

    users = cur.fetchall()
    processed = 0

    for user in users:
        try:
            ends_at = datetime.fromisoformat(user["subscription_ends_at"])
        except Exception:
            continue

        # Если подписка ещё активна — пропускаем
        if now < ends_at:
            continue

        price = float(user["price"] or 0)
        balance = float(user["balance"] or 0)
        credit_limit = float(user["credit_limit"] or 0)
        interval = int(user["interval_seconds"] or 2592000)
        username = user["username"]
        tariff_name = user["tariff_name"] or "тариф"

        if user["auto_renew"]:
            # Автопродление: списываем и сдвигаем срок
            if balance >= price:
                new_balance = balance - price
                new_ends = ends_at + timedelta(seconds=interval)

                cur.execute(
                    "UPDATE user SET balance = ?, subscription_ends_at = ? WHERE id = ?",
                    (new_balance, new_ends.isoformat(), user["id"]),
                )
                cur.execute(
                    """INSERT INTO "transaction" (user_id, amount, reason, created_at)
                       VALUES (?, ?, ?, ?)""",
                    (
                        user["id"],
                        -price,
                        f"Автопродление тарифа {tariff_name}",
                        now.isoformat(),
                    ),
                )
                conn.commit()
                processed += 1
                log(
                    f"Продлил {username}: -{price}р, новый срок {new_ends.strftime('%d.%m.%Y %H:%M')}"
                )
            elif balance >= -credit_limit:
                # Уходим в кредит
                new_balance = balance - price
                new_ends = ends_at + timedelta(seconds=interval)

                cur.execute(
                    "UPDATE user SET balance = ?, subscription_ends_at = ? WHERE id = ?",
                    (new_balance, new_ends.isoformat(), user["id"]),
                )
                cur.execute(
                    """INSERT INTO "transaction" (user_id, amount, reason, created_at)
                       VALUES (?, ?, ?, ?)""",
                    (
                        user["id"],
                        -price,
                        f"Автопродление тарифа {tariff_name} (в кредит)",
                        now.isoformat(),
                    ),
                )
                conn.commit()
                processed += 1
                log(
                    f"Продлил {username} в кредит: -{price}р, баланс {new_balance:.2f}р"
                )
            else:
                # Недостаточно средств даже с кредитом — блокируем
                cur.execute("UPDATE user SET active = 0 WHERE id = ?", (user["id"],))
                cur.execute(
                    """INSERT INTO "transaction" (user_id, amount, reason, created_at)
                       VALUES (?, ?, ?, ?)""",
                    (
                        user["id"],
                        0,
                        f"Блокировка: недостаточно средств для продления {tariff_name}",
                        now.isoformat(),
                    ),
                )
                conn.commit()
                processed += 1
                log(f"Заблокировал {username}: недостаточно средств для {tariff_name}")
        else:
            # Нет автопродления — блокируем
            cur.execute("UPDATE user SET active = 0 WHERE id = ?", (user["id"],))
            cur.execute(
                """INSERT INTO "transaction" (user_id, amount, reason, created_at)
                   VALUES (?, ?, ?, ?)""",
                (
                    user["id"],
                    0,
                    f"Блокировка: подписка {tariff_name} истекла без автопродления",
                    now.isoformat(),
                ),
            )
            conn.commit()
            processed += 1
            log(f"Заблокировал {username}: подписка {tariff_name} истекла")

    conn.close()
    if processed:
        log(f"Обработано подписок: {processed}")


def process_promised_debts():
    """Списание обещанных платежей по истечении срока."""
    conn = get_db()
    cur = conn.cursor()
    now = datetime.utcnow()

    cur.execute("""
        SELECT d.id, d.user_id, d.principal, d.repay_amount, d.due_at,
               u.username, u.balance
        FROM promised_debt d
        JOIN user u ON d.user_id = u.id
        WHERE d.status = 'active' AND d.due_at <= ?
    """, (now.isoformat(),))

    debts = cur.fetchall()
    processed = 0

    for debt in debts:
        repay = float(debt["repay_amount"] or 0)
        balance = float(debt["balance"] or 0)
        username = debt["username"]

        if balance >= repay:
            new_balance = balance - repay

            cur.execute(
                "UPDATE user SET balance = ? WHERE id = ?",
                (new_balance, debt["user_id"]),
            )
            cur.execute(
                """UPDATE promised_debt
                   SET status = 'repaid', repaid_at = ?
                   WHERE id = ?""",
                (now.isoformat(), debt["id"]),
            )
            cur.execute(
                """INSERT INTO "transaction" (user_id, amount, reason, created_at)
                   VALUES (?, ?, ?, ?)""",
                (
                    debt["user_id"],
                    -repay,
                    f"Возврат обещанного платежа (долг {debt['principal']}р)",
                    now.isoformat(),
                ),
            )
            conn.commit()
            processed += 1
            log(f"Списал долг {username}: -{repay}р")
        else:
            log(
                f"Недостаточно средств для списания долга {username}: "
                f"нужно {repay}р, есть {balance}р"
            )

    conn.close()
    if processed:
        log(f"Обработано долгов: {processed}")


def process_freezes():
    """Завершение заморозок: сдвиг срока подписки."""
    conn = get_db()
    cur = conn.cursor()
    now = datetime.utcnow()

    cur.execute("""
        SELECT f.id, f.user_id, f.freeze_from, f.freeze_to, f.price,
               u.username, u.subscription_ends_at
        FROM subscription_freeze f
        JOIN user u ON f.user_id = u.id
        WHERE f.status = 'active' AND f.freeze_to <= ?
    """, (now.isoformat(),))

    freezes = cur.fetchall()
    processed = 0

    for freeze in freezes:
        try:
            freeze_from = datetime.fromisoformat(freeze["freeze_from"])
            freeze_to = datetime.fromisoformat(freeze["freeze_to"])
        except Exception:
            continue

        freeze_duration = freeze_to - freeze_from

        # Сдвигаем срок подписки на длительность заморозки
        if freeze["subscription_ends_at"]:
            try:
                ends_at = datetime.fromisoformat(freeze["subscription_ends_at"])
                new_ends = ends_at + freeze_duration
                cur.execute(
                    "UPDATE user SET subscription_ends_at = ? WHERE id = ?",
                    (new_ends.isoformat(), freeze["user_id"]),
                )
            except Exception:
                pass

        cur.execute(
            """UPDATE subscription_freeze
               SET status = 'completed'
               WHERE id = ?""",
            (freeze["id"],),
        )
        conn.commit()
        processed += 1
        log(
            f"Завершил заморозку {freeze['username']}: "
            f"+{freeze_duration.days} дн. к подписке"
        )

    conn.close()
    if processed:
        log(f"Обработано заморозок: {processed}")


def main():
    log("Billing service started")

    last_subscription = 0
    last_debt = 0
    last_freeze = 0

    while True:
        now = time.time()

        try:
            if now - last_subscription >= SUBSCRIPTION_INTERVAL:
                process_subscriptions()
                last_subscription = now

            if now - last_debt >= DEBT_INTERVAL:
                process_promised_debts()
                last_debt = now

            if now - last_freeze >= FREEZE_INTERVAL:
                process_freezes()
                last_freeze = now
        except Exception as e:
            log(f"Unhandled error: {e}")

        time.sleep(1)


if __name__ == "__main__":
    main()