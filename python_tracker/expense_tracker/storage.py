from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from datetime import date
from decimal import Decimal
from pathlib import Path
from typing import Iterable

from .models import AccountBalance, Entry, Goal, RecurringPayment
from .util import money, new_id, parse_date


ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "data"
DB_PATH = DATA_DIR / "tracker.sqlite3"
_LEGACY_CANDIDATES = [
    ROOT.parent / "tracker-data" / "data.json",
    ROOT.parent.parent / "tracker-data" / "data.json",
]
LEGACY_JSON = next((path for path in _LEGACY_CANDIDATES if path.exists()), _LEGACY_CANDIDATES[0])


class TrackerStore:
    def __init__(self, db_path: Path, legacy_json: Path | None = None) -> None:
        self.db_path = db_path
        self.legacy_json = legacy_json

    @classmethod
    def default(cls) -> "TrackerStore":
        return cls(DB_PATH, LEGACY_JSON)

    def connect(self) -> sqlite3.Connection:
        con = sqlite3.connect(self.db_path)
        con.row_factory = sqlite3.Row
        con.execute("PRAGMA foreign_keys = ON")
        return con

    @contextmanager
    def session(self):
        con = self.connect()
        try:
            yield con
            con.commit()
        finally:
            con.close()

    def initialize(self) -> None:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        with self.session() as con:
            self._create_schema(con)
            count = con.execute("SELECT COUNT(*) FROM entries").fetchone()[0]
        if count == 0 and self.legacy_json and self.legacy_json.exists():
            self.migrate_legacy_json(self.legacy_json)

    def _create_schema(self, con: sqlite3.Connection) -> None:
        con.executescript(
            """
            CREATE TABLE IF NOT EXISTS entries (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                date TEXT NOT NULL,
                name TEXT NOT NULL,
                category TEXT NOT NULL DEFAULT '',
                account TEXT NOT NULL DEFAULT '',
                amount TEXT NOT NULL DEFAULT '0',
                note TEXT NOT NULL DEFAULT '',
                frequency TEXT NOT NULL DEFAULT '',
                goal TEXT NOT NULL DEFAULT '0',
                balance TEXT NOT NULL DEFAULT '0',
                bank_category TEXT NOT NULL DEFAULT '',
                serial TEXT NOT NULL DEFAULT '',
                source TEXT NOT NULL DEFAULT '',
                import_key TEXT NOT NULL DEFAULT ''
            );

            CREATE INDEX IF NOT EXISTS idx_entries_date ON entries(date);
            CREATE INDEX IF NOT EXISTS idx_entries_account ON entries(account);
            CREATE INDEX IF NOT EXISTS idx_entries_import_key ON entries(import_key);

            CREATE TABLE IF NOT EXISTS goals (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                account TEXT NOT NULL,
                target_amount TEXT NOT NULL DEFAULT '0',
                expected_date TEXT NOT NULL,
                mode TEXT NOT NULL DEFAULT 'Save',
                goal_kind TEXT NOT NULL DEFAULT 'Target',
                weekly_amount TEXT NOT NULL DEFAULT '0',
                is_ongoing INTEGER NOT NULL DEFAULT 0,
                note TEXT NOT NULL DEFAULT ''
            );

            CREATE TABLE IF NOT EXISTS recurring_payments (
                key TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                category TEXT NOT NULL DEFAULT '',
                account TEXT NOT NULL DEFAULT '',
                amount TEXT NOT NULL DEFAULT '0',
                date TEXT NOT NULL,
                frequency TEXT NOT NULL DEFAULT 'Recurring',
                count INTEGER NOT NULL DEFAULT 0,
                manual INTEGER NOT NULL DEFAULT 1
            );

            CREATE TABLE IF NOT EXISTS recurring_exclusions (
                key TEXT PRIMARY KEY
            );

            CREATE TABLE IF NOT EXISTS account_names (
                account TEXT PRIMARY KEY,
                display_name TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS account_balances (
                account TEXT PRIMARY KEY,
                balance TEXT NOT NULL DEFAULT '0',
                date TEXT NOT NULL,
                source TEXT NOT NULL DEFAULT ''
            );

            CREATE TABLE IF NOT EXISTS hidden_balance_accounts (
                account TEXT PRIMARY KEY
            );

            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """
        )

    def migrate_legacy_json(self, path: Path) -> None:
        payload = json.loads(path.read_text(encoding="utf-8-sig"))
        entries = payload.get("entries") or []
        goals = payload.get("goals") or []
        recurring = payload.get("recurringManual") or []
        exclusions = payload.get("recurringExclusions") or []
        names = payload.get("accountNames") or {}
        balances = payload.get("accountBalances") or {}
        hidden = payload.get("hiddenBalanceAccounts") or []
        settings = payload.get("settings") or {}

        with self.session() as con:
            for item in entries:
                self.upsert_entry(self._entry_from_legacy(item), con)
            for item in goals:
                self.upsert_goal(self._goal_from_legacy(item), con)
            for item in recurring:
                self.upsert_recurring(self._recurring_from_legacy(item), con)
            for key in exclusions:
                if str(key).strip():
                    con.execute("INSERT OR IGNORE INTO recurring_exclusions(key) VALUES (?)", (str(key),))
            for account, display in dict(names).items():
                con.execute(
                    "INSERT OR REPLACE INTO account_names(account, display_name) VALUES (?, ?)",
                    (str(account), str(display)),
                )
            for account, item in dict(balances).items():
                con.execute(
                    """
                    INSERT OR REPLACE INTO account_balances(account, balance, date, source)
                    VALUES (?, ?, ?, ?)
                    """,
                    (
                        str(account),
                        str(money(item.get("Balance"))),
                        parse_date(item.get("Date")).isoformat(),
                        str(item.get("Source") or "Accounts CSV"),
                    ),
                )
            for account in hidden:
                if str(account).strip():
                    con.execute("INSERT OR IGNORE INTO hidden_balance_accounts(account) VALUES (?)", (str(account),))
            for key, value in dict(settings).items():
                con.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", (str(key), str(value)))
            if "weeklyAvailableSavings" in payload:
                con.execute(
                    "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                    ("weekly_available_savings", str(money(payload.get("weeklyAvailableSavings")))),
                )

    def replace_from_legacy_json(self, path: Path | None = None) -> None:
        path = path or self.legacy_json
        if not path or not path.exists():
            raise FileNotFoundError("Legacy tracker data.json was not found.")
        with self.session() as con:
            for table in (
                "entries",
                "goals",
                "recurring_payments",
                "recurring_exclusions",
                "account_names",
                "account_balances",
                "hidden_balance_accounts",
                "settings",
            ):
                con.execute(f"DELETE FROM {table}")
        self.migrate_legacy_json(path)

    def _entry_from_legacy(self, item: dict) -> Entry:
        return Entry(
            id=str(item.get("Id") or new_id()),
            type=str(item.get("Type") or "Expense"),
            date=parse_date(item.get("Date")),
            name=str(item.get("Name") or ""),
            category=str(item.get("Category") or ""),
            account=str(item.get("Account") or ""),
            frequency=str(item.get("Frequency") or ""),
            amount=money(item.get("Amount")),
            goal=money(item.get("Goal")),
            note=str(item.get("Note") or ""),
            balance=money(item.get("Balance")),
            bank_category=str(item.get("BankCategory") or ""),
            serial=str(item.get("Serial") or ""),
            source=str(item.get("Source") or ""),
            import_key=str(item.get("ImportKey") or ""),
        )

    def _goal_from_legacy(self, item: dict) -> Goal:
        return Goal(
            id=str(item.get("Id") or new_id()),
            name=str(item.get("Name") or ""),
            account=str(item.get("Account") or ""),
            target_amount=money(item.get("TargetAmount")),
            expected_date=parse_date(item.get("ExpectedDate")),
            mode=str(item.get("Mode") or "Save"),
            goal_kind=str(item.get("GoalKind") or "Target"),
            weekly_amount=money(item.get("WeeklyAmount")),
            is_ongoing=bool(item.get("IsOngoing") or False),
            note=str(item.get("Note") or ""),
        )

    def _recurring_from_legacy(self, item: dict) -> RecurringPayment:
        return RecurringPayment(
            key=str(item.get("Key") or f"manual|{new_id()}"),
            name=str(item.get("Name") or ""),
            category=str(item.get("Category") or ""),
            account=str(item.get("Account") or ""),
            amount=money(item.get("Amount")),
            date=parse_date(item.get("Date")),
            frequency=str(item.get("Frequency") or "Recurring"),
            count=int(item.get("Count") or 0),
            manual=True,
        )

    def upsert_entry(self, entry: Entry, con: sqlite3.Connection | None = None) -> None:
        own = con is None
        con = con or self.connect()
        con.execute(
            """
            INSERT OR REPLACE INTO entries
            (id, type, date, name, category, account, amount, note, frequency, goal, balance, bank_category, serial, source, import_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                entry.id,
                entry.type,
                entry.date.isoformat(),
                entry.name,
                entry.category,
                entry.account,
                str(money(entry.amount)),
                entry.note,
                entry.frequency,
                str(money(entry.goal)),
                str(money(entry.balance)),
                entry.bank_category,
                entry.serial,
                entry.source,
                entry.import_key,
            ),
        )
        if own:
            con.commit()
            con.close()

    def delete_entry(self, entry_id: str) -> None:
        with self.session() as con:
            con.execute("DELETE FROM entries WHERE id = ?", (entry_id,))

    def upsert_goal(self, goal: Goal, con: sqlite3.Connection | None = None) -> None:
        own = con is None
        con = con or self.connect()
        con.execute(
            """
            INSERT OR REPLACE INTO goals
            (id, name, account, target_amount, expected_date, mode, goal_kind, weekly_amount, is_ongoing, note)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                goal.id,
                goal.name,
                goal.account,
                str(money(goal.target_amount)),
                goal.expected_date.isoformat(),
                goal.mode,
                goal.goal_kind,
                str(money(goal.weekly_amount)),
                1 if goal.is_ongoing else 0,
                goal.note,
            ),
        )
        if own:
            con.commit()
            con.close()

    def delete_goal(self, goal_id: str) -> None:
        with self.session() as con:
            con.execute("DELETE FROM goals WHERE id = ?", (goal_id,))

    def upsert_recurring(self, payment: RecurringPayment, con: sqlite3.Connection | None = None) -> None:
        own = con is None
        con = con or self.connect()
        con.execute(
            """
            INSERT OR REPLACE INTO recurring_payments
            (key, name, category, account, amount, date, frequency, count, manual)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                payment.key,
                payment.name,
                payment.category,
                payment.account,
                str(money(payment.amount)),
                payment.date.isoformat(),
                payment.frequency,
                payment.count,
                1 if payment.manual else 0,
            ),
        )
        if own:
            con.commit()
            con.close()

    def delete_recurring(self, key: str) -> None:
        with self.session() as con:
            con.execute("DELETE FROM recurring_payments WHERE key = ?", (key,))
            con.execute("INSERT OR IGNORE INTO recurring_exclusions(key) VALUES (?)", (key,))

    def entries(self) -> list[Entry]:
        with self.session() as con:
            rows = con.execute("SELECT * FROM entries ORDER BY date DESC, name").fetchall()
        return [self._entry_from_row(row) for row in rows]

    def goals(self) -> list[Goal]:
        with self.session() as con:
            rows = con.execute("SELECT * FROM goals ORDER BY account, expected_date, name").fetchall()
        return [self._goal_from_row(row) for row in rows]

    def recurring_payments(self) -> list[RecurringPayment]:
        with self.session() as con:
            rows = con.execute(
                """
                SELECT rp.*
                FROM recurring_payments rp
                LEFT JOIN recurring_exclusions ex ON ex.key = rp.key
                WHERE ex.key IS NULL
                ORDER BY rp.date DESC, rp.name
                """
            ).fetchall()
        return [self._recurring_from_row(row) for row in rows]

    def account_balances(self) -> dict[str, AccountBalance]:
        with self.session() as con:
            rows = con.execute("SELECT * FROM account_balances").fetchall()
        return {
            row["account"]: AccountBalance(
                account=row["account"],
                balance=money(row["balance"]),
                date=parse_date(row["date"]),
                source=row["source"],
            )
            for row in rows
        }

    def account_names(self) -> dict[str, str]:
        with self.session() as con:
            rows = con.execute("SELECT * FROM account_names").fetchall()
        return {row["account"]: row["display_name"] for row in rows}

    def set_account_name(self, account: str, display_name: str) -> None:
        with self.session() as con:
            con.execute("INSERT OR REPLACE INTO account_names(account, display_name) VALUES (?, ?)", (account, display_name))

    def hide_balance_account(self, account: str) -> None:
        with self.session() as con:
            con.execute("INSERT OR IGNORE INTO hidden_balance_accounts(account) VALUES (?)", (account,))

    def hidden_balance_accounts(self) -> set[str]:
        with self.session() as con:
            rows = con.execute("SELECT account FROM hidden_balance_accounts").fetchall()
        return {row["account"] for row in rows}

    def setting(self, key: str, default: str = "") -> str:
        with self.session() as con:
            row = con.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
        return str(row["value"]) if row else default

    def set_setting(self, key: str, value: str) -> None:
        with self.session() as con:
            con.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", (key, value))

    def replace_account_balance(self, balance: AccountBalance) -> None:
        with self.session() as con:
            con.execute(
                """
                INSERT OR REPLACE INTO account_balances(account, balance, date, source)
                VALUES (?, ?, ?, ?)
                """,
                (balance.account, str(money(balance.balance)), balance.date.isoformat(), balance.source),
            )

    def insert_entries(self, entries: Iterable[Entry]) -> None:
        with self.session() as con:
            for entry in entries:
                self.upsert_entry(entry, con)

    def _entry_from_row(self, row: sqlite3.Row) -> Entry:
        return Entry(
            id=row["id"],
            type=row["type"],
            date=parse_date(row["date"]),
            name=row["name"],
            category=row["category"],
            account=row["account"],
            amount=money(row["amount"]),
            note=row["note"],
            frequency=row["frequency"],
            goal=money(row["goal"]),
            balance=money(row["balance"]),
            bank_category=row["bank_category"],
            serial=row["serial"],
            source=row["source"],
            import_key=row["import_key"],
        )

    def _goal_from_row(self, row: sqlite3.Row) -> Goal:
        return Goal(
            id=row["id"],
            name=row["name"],
            account=row["account"],
            target_amount=money(row["target_amount"]),
            expected_date=parse_date(row["expected_date"]),
            mode=row["mode"],
            goal_kind=row["goal_kind"],
            weekly_amount=money(row["weekly_amount"]),
            is_ongoing=bool(row["is_ongoing"]),
            note=row["note"],
        )

    def _recurring_from_row(self, row: sqlite3.Row) -> RecurringPayment:
        return RecurringPayment(
            key=row["key"],
            name=row["name"],
            category=row["category"],
            account=row["account"],
            amount=money(row["amount"]),
            date=parse_date(row["date"]),
            frequency=row["frequency"],
            count=int(row["count"]),
            manual=bool(row["manual"]),
        )
