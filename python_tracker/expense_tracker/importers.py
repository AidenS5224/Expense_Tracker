from __future__ import annotations

import csv
from datetime import date, timedelta
from pathlib import Path

from .models import AccountBalance, Entry, ImportResult
from .storage import TrackerStore
from .util import header_match, money, new_id, normalize_account, normalize_text, parse_date


def duplicate_type(entry_type: str) -> str:
    return "Saving" if entry_type == "Income" else entry_type


def import_key(account: str, day: date, entry_type: str, name: str, amount, balance, bank_category: str, serial: str) -> str:
    return "|".join(
        [
            account.strip().lower(),
            day.isoformat(),
            duplicate_type(entry_type).strip().lower(),
            normalize_text(name),
            f"{money(amount):.2f}",
            f"{money(balance):.2f}",
            bank_category.strip().lower(),
            serial.strip().lower(),
        ]
    )


def fallback_key(account: str, day: date, entry_type: str, name: str, amount, balance, bank_category: str) -> str:
    return "|".join(
        [
            account.strip().lower(),
            day.isoformat(),
            duplicate_type(entry_type).strip().lower(),
            normalize_text(name),
            f"{money(amount):.2f}",
            f"{money(balance):.2f}",
            bank_category.strip().lower(),
        ]
    )


def soft_keys(account: str, day: date, name: str, amount, balance, bank_category: str) -> set[str]:
    keys = set()
    for offset in (-1, 0, 1):
        keys.add(
            "|".join(
                [
                    account.strip().lower(),
                    (day + timedelta(days=offset)).isoformat(),
                    normalize_text(name),
                    f"{money(amount):.2f}",
                    f"{money(balance):.2f}",
                    bank_category.strip().lower(),
                ]
            )
        )
    return keys


class DuplicateLookup:
    def __init__(self, entries: list[Entry]) -> None:
        self.import_keys: set[str] = set()
        self.serial_keys: set[str] = set()
        self.fallback_keys: set[str] = set()
        self.soft_keys: set[str] = set()
        for entry in entries:
            key = entry.import_key or import_key(
                entry.account,
                entry.date,
                entry.type,
                entry.name,
                entry.amount,
                entry.balance,
                entry.bank_category,
                entry.serial,
            )
            if key:
                self.import_keys.add(key)
            if entry.serial.strip():
                self.serial_keys.add(f"{entry.account.strip().lower()}|{entry.serial.strip().lower()}")
            self.fallback_keys.add(
                fallback_key(entry.account, entry.date, entry.type, entry.name, entry.amount, entry.balance, entry.bank_category)
            )
            self.soft_keys.update(soft_keys(entry.account, entry.date, entry.name, entry.amount, entry.balance, entry.bank_category))

    def contains(self, key: str, account: str, day: date, entry_type: str, name: str, amount, balance, bank_category: str, serial: str) -> bool:
        if key in self.import_keys:
            return True
        if serial.strip():
            return f"{account.strip().lower()}|{serial.strip().lower()}" in self.serial_keys
        if fallback_key(account, day, entry_type, name, amount, balance, bank_category) in self.fallback_keys:
            return True
        return any(key in self.soft_keys for key in soft_keys(account, day, name, amount, balance, bank_category))

    def add(self, key: str, account: str, day: date, entry_type: str, name: str, amount, balance, bank_category: str, serial: str) -> None:
        self.import_keys.add(key)
        if serial.strip():
            self.serial_keys.add(f"{account.strip().lower()}|{serial.strip().lower()}")
        self.fallback_keys.add(fallback_key(account, day, entry_type, name, amount, balance, bank_category))
        self.soft_keys.update(soft_keys(account, day, name, amount, balance, bank_category))


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def import_statement(store: TrackerStore, path: Path, fallback_account: str | None = None) -> ImportResult:
    rows = read_csv(path)
    if not rows:
        return ImportResult(0, 0, 0, 0)

    headers = list(rows[0].keys())
    date_header = header_match(headers, [r"^date$", r"transaction.*date", r"posted.*date", r"process.*date"])
    desc_header = header_match(headers, [r"^narrative$", r"description", r"details", r"narration", r"merchant", r"payee", r"transaction"])
    amount_header = header_match(headers, [r"^amount$", r"transaction.*amount", r"value"])
    debit_header = header_match(headers, [r"^debit amount$", r"debit", r"withdrawal", r"paid.?out"])
    credit_header = header_match(headers, [r"^credit amount$", r"credit", r"deposit", r"paid.?in"])
    account_header = header_match(headers, [r"^bank account$", r"^account$", r"account number"])
    balance_header = header_match(headers, [r"^balance$", r"closing balance"])
    bank_category_header = header_match(headers, [r"^categories$", r"^category$", r"transaction category"])
    serial_header = header_match(headers, [r"^serial$", r"reference", r"transaction id"])

    if not date_header or not (amount_header or debit_header or credit_header):
        raise ValueError("Could not identify Date and Amount columns.")

    lookup = DuplicateLookup(store.entries())
    source = path.name
    added: list[Entry] = []
    duplicates = 0
    zero = 0

    for row in rows:
        if amount_header:
            signed_amount = money(row.get(amount_header))
        else:
            credit = abs(money(row.get(credit_header))) if credit_header else money(0)
            debit = abs(money(row.get(debit_header))) if debit_header else money(0)
            signed_amount = credit - debit
        if signed_amount == 0:
            zero += 1
            continue

        day = parse_date(row.get(date_header))
        entry_type = "Expense" if signed_amount < 0 else "Saving"
        amount = abs(signed_amount)
        name = (row.get(desc_header) if desc_header else "Bank transaction") or "Bank transaction"
        account = normalize_account(row.get(account_header)) if account_header and row.get(account_header) else (fallback_account or path.stem)
        balance = money(row.get(balance_header)) if balance_header else money(0)
        bank_category = (row.get(bank_category_header) if bank_category_header else "") or ""
        serial = (row.get(serial_header) if serial_header else "") or ""
        key = import_key(account, day, entry_type, name, amount, balance, bank_category, serial)
        if lookup.contains(key, account, day, entry_type, name, amount, balance, bank_category, serial):
            duplicates += 1
            continue
        entry = Entry(
            id=new_id(),
            type=entry_type,
            date=day,
            name=name.strip(),
            category=bank_category.strip() or "Other",
            account=account,
            amount=amount,
            note="Imported from bank statement",
            balance=balance,
            bank_category=bank_category.strip(),
            serial=serial.strip(),
            source=source,
            import_key=key,
        )
        added.append(entry)
        lookup.add(key, account, day, entry_type, name, amount, balance, bank_category, serial)

    store.insert_entries(added)
    return ImportResult(read=len(rows), added=len(added), duplicates=duplicates, skipped_zero=zero)


def import_accounts_csv(store: TrackerStore, path: Path) -> ImportResult:
    rows = read_csv(path)
    if not rows:
        return ImportResult(0, 0, 0, 0)
    headers = list(rows[0].keys())
    type_header = header_match(headers, [r"^account type$"])
    name_header = header_match(headers, [r"^account nickname/name$", r"nickname", r"account name"])
    bsb_header = header_match(headers, [r"^bsb$"])
    account_header = header_match(headers, [r"^account number/portfolio number$", r"account number", r"portfolio"])
    balance_header = header_match(headers, [r"^closing balance$", r"balance"])
    date_header = header_match(headers, [r"^as at date for closing balance$", r"balance date", r"^as at date$"])
    if not account_header or not balance_header or not date_header:
        raise ValueError("Could not identify account number, balance, and balance date columns.")

    current = store.account_balances()
    updated = 0
    for row in rows:
        bsb = normalize_account(row.get(bsb_header)) if bsb_header else ""
        account_number = normalize_account(row.get(account_header))
        account = f"{bsb}{account_number}" if bsb and not account_number.startswith(bsb) else account_number
        if not account:
            continue
        balance = AccountBalance(account=account, balance=money(row.get(balance_header)), date=parse_date(row.get(date_header)), source=path.name)
        existing = current.get(account)
        if existing and existing.date > balance.date:
            continue
        store.replace_account_balance(balance)
        current[account] = balance
        display = ""
        if name_header and row.get(name_header):
            display = str(row.get(name_header)).strip()
        elif type_header and row.get(type_header):
            display = str(row.get(type_header)).strip()
        if display:
            store.set_account_name(account, display)
        updated += 1
    return ImportResult(read=len(rows), added=updated, duplicates=0, skipped_zero=0)
