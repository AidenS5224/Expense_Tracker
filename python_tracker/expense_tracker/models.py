from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from decimal import Decimal


Money = Decimal


@dataclass(frozen=True)
class Entry:
    id: str
    type: str
    date: date
    name: str
    category: str
    account: str
    amount: Money
    note: str = ""
    frequency: str = ""
    goal: Money = Decimal("0")
    balance: Money = Decimal("0")
    bank_category: str = ""
    serial: str = ""
    source: str = ""
    import_key: str = ""


@dataclass(frozen=True)
class Goal:
    id: str
    name: str
    account: str
    target_amount: Money
    expected_date: date
    mode: str = "Save"
    goal_kind: str = "Target"
    weekly_amount: Money = Decimal("0")
    is_ongoing: bool = False
    note: str = ""


@dataclass(frozen=True)
class RecurringPayment:
    key: str
    name: str
    category: str
    account: str
    amount: Money
    date: date
    frequency: str = "Recurring"
    count: int = 0
    manual: bool = True


@dataclass(frozen=True)
class AccountBalance:
    account: str
    balance: Money
    date: date
    source: str = "Accounts CSV"


@dataclass(frozen=True)
class BudgetSummary:
    paycheck: Money
    other_income: Money
    savings: Money
    spend: Money
    bills: Money
    debts: Money
    remaining: Money
    week_start: date
    week_end: date


@dataclass(frozen=True)
class ProjectionPoint:
    week: int
    date: date
    goal_id: str
    goal_name: str
    allocation: Money
    total_allocated: Money


@dataclass(frozen=True)
class ImportResult:
    read: int
    added: int
    duplicates: int
    skipped_zero: int = 0
