from __future__ import annotations

import re
from collections import defaultdict
from datetime import date, timedelta
from decimal import Decimal

from .models import AccountBalance, BudgetSummary, Entry, Goal, RecurringPayment
from .util import add_months, fmt_money, money, monday_for


def is_internal_transfer(entry: Entry) -> bool:
    name = entry.name.upper()
    category = entry.bank_category.upper()
    return bool(re.search(r"\b(TFR|TRANSFER|OSKO|PAYMENT\s+TO|PAYMENT\s+FROM)\b", name)) or category in {"TRANSFER", "TFR"}


def is_credit_card_account(account: str, names: dict[str, str], balances: dict[str, AccountBalance]) -> bool:
    display = names.get(account, account).lower()
    if "credit card" in display or "credit cards" in display:
        return True
    return account in balances and balances[account].balance < 0


def is_savings_account(account: str, names: dict[str, str], entries: list[Entry]) -> bool:
    if not account or account == "All Accounts":
        return False
    display = names.get(account, account).lower()
    if "saving" in display or "sec acc" in display:
        return True
    savings = [entry for entry in entries if entry.account == account and entry.type == "Saving"]
    expenses = [entry for entry in entries if entry.account == account and entry.type == "Expense"]
    return bool(savings and expenses and len(savings) >= len(expenses) * 0.25)


def is_savings_credit(entry: Entry) -> bool:
    category = entry.bank_category.upper()
    return entry.type in {"Saving", "Income"} or category in {"CREDIT", "DEP", "INT"}


def is_savings_payment(entry: Entry) -> bool:
    category = entry.bank_category.upper()
    return entry.type in {"Expense", "Bill"} or category in {"PAYMENT", "DEBIT", "CASH", "ATM"}


def is_goal_saving_entry(entry: Entry, goals: list[Goal]) -> bool:
    if entry.type != "Saving" or is_internal_transfer(entry) or not entry.category.strip():
        return False
    return any(entry.category.strip().lower() == goal.name.strip().lower() for goal in goals)


def actual_savings_amount(items: list[Entry], goals: list[Goal], selected_account: str | None = None) -> Decimal:
    goal_accounts = {goal.account for goal in goals if goal.account}
    total = money(0)
    for entry in items:
        if selected_account and selected_account != "All Accounts":
            relevant_account = entry.account == selected_account
        else:
            relevant_account = entry.account in goal_accounts
        if relevant_account and is_savings_credit(entry):
            total += entry.amount
        elif not relevant_account and is_goal_saving_entry(entry, goals):
            total += entry.amount
    return money(total)


def entry_balance_delta(entry: Entry, names: dict[str, str], balances: dict[str, AccountBalance]) -> Decimal:
    category = entry.bank_category.upper()
    if is_credit_card_account(entry.account, names, balances):
      return entry.amount if category == "PAYMENT" or entry.type in {"Saving", "Income"} else -entry.amount
    return entry.amount if entry.type in {"Saving", "Income"} or category in {"CREDIT", "DEP", "INT"} else -entry.amount


def calculated_balances(entries: list[Entry], balances: dict[str, AccountBalance], names: dict[str, str]) -> dict[str, tuple[Decimal, date, str]]:
    accounts = {entry.account for entry in entries if entry.account} | set(balances.keys())
    result: dict[str, tuple[Decimal, date, str]] = {}
    for account in accounts:
        candidates: list[tuple[date, Decimal, str, int]] = []
        anchor = balances.get(account)
        if anchor:
            candidates.append((anchor.date, anchor.balance, anchor.source, 1))
        for entry in entries:
            if entry.account == account and entry.balance != 0:
                candidates.append((entry.date, entry.balance, entry.source, 0))
        if not candidates:
            continue

        # Prefer the newest known balance. If the account CSV and a statement
        # have the same date, the account CSV wins because it is the bank's
        # account-level closing snapshot.
        anchor_date, balance, source, _priority = max(candidates, key=lambda item: (item[0], item[3]))
        for entry in entries:
            if entry.account == account and entry.date > anchor_date:
                balance += entry_balance_delta(entry, names, balances)
        latest_date = max([anchor_date] + [entry.date for entry in entries if entry.account == account and entry.date > anchor_date])
        result[account] = (money(balance), latest_date, source)
    return result


def goal_progress(goals: list[Goal], balances: dict[str, tuple[Decimal, date, str]]) -> list[tuple[Goal, Decimal, Decimal]]:
    available = {account: max(money(0), balance) for account, (balance, _, _) in balances.items()}
    rows = []
    for goal in sorted(goals, key=lambda g: (g.account, g.expected_date, g.name)):
        if goal.goal_kind == "Weekly":
            remaining = goal.weekly_amount if goal.is_ongoing or goal.expected_date >= date.today() else money(0)
            rows.append((goal, money(0), money(remaining)))
            continue
        amount = available.get(goal.account, money(0))
        saved = min(goal.target_amount, amount)
        available[goal.account] = max(money(0), amount - goal.target_amount)
        rows.append((goal, money(saved), max(money(0), goal.target_amount - saved)))
    return rows


def recurring_due_in_range(payment: RecurringPayment, start: date, end: date) -> bool:
    # Match the PowerShell app: range end is exclusive.
    if start <= payment.date < end:
        return True
    if payment.date > end:
        return False

    interval = {
        "Weekly": 7,
        "Fortnightly": 14,
    }.get(payment.frequency)
    if interval:
        days_since = max(0, (start - payment.date).days)
        periods = -(-days_since // interval)
        next_date = payment.date + timedelta(days=periods * interval)
        return start <= next_date < end

    if payment.frequency in {"Monthly", "Quarterly", "Annual"}:
        month_step = {"Monthly": 1, "Quarterly": 3, "Annual": 12}[payment.frequency]
        next_date = payment.date
        while next_date < start:
            next_date = add_months(next_date, month_step)
        return start <= next_date < end

    return False


def is_paycheck_entry(entry: Entry) -> bool:
    text = f"{entry.category} {entry.name}".upper()
    return (
        entry.type == "Income"
        or entry.bank_category.upper() == "DEP"
    ) and ("PAYCHECK" in text or "PAYROLL" in text or "SALARY" in text)


def is_other_income_entry(entry: Entry, goals: list[Goal]) -> bool:
    if is_paycheck_entry(entry):
        return False
    category = entry.bank_category.upper()
    if category == "DEP":
        return True
    if is_internal_transfer(entry):
        return False
    if entry.type == "Income":
        return True
    if entry.type != "Saving":
        return False
    if is_goal_saving_entry(entry, goals):
        return False
    return category == "INT" or entry.category.upper() in {"INTEREST", "OTHER INCOME"}


def current_week_budget(
    entries: list[Entry],
    goals: list[Goal],
    recurring: list[RecurringPayment],
    balances: dict[str, tuple[Decimal, date, str]],
    account_names: dict[str, str],
    account_balance_anchors: dict[str, AccountBalance],
    minimum_savings: Decimal,
) -> BudgetSummary:
    start = monday_for(date.today())
    end = start + timedelta(days=7)
    week_entries = [entry for entry in entries if start <= entry.date < end]
    paycheck = sum((entry.amount for entry in week_entries if is_paycheck_entry(entry)), money(0))
    other_income = sum((entry.amount for entry in week_entries if is_other_income_entry(entry, goals)), money(0))
    debt_accounts = {
        account
        for account, (balance, _, _) in balances.items()
        if is_credit_card_account(account, account_names, account_balance_anchors) or balance < 0
    }
    spend = sum(
        (
            entry.amount
            for entry in week_entries
            if entry.type in {"Expense", "Bill"}
            and entry.account not in debt_accounts
            and not is_internal_transfer(entry)
        ),
        money(0),
    )
    bill_entries = sum((entry.amount for entry in week_entries if entry.type == "Bill"), money(0))
    recurring_total = sum((payment.amount for payment in recurring if recurring_due_in_range(payment, start, end)), money(0))
    debts = money(0)
    for account, (balance, _, _) in balances.items():
        if is_credit_card_account(account, account_names, account_balance_anchors) and balance < 0:
            debts += abs(balance)
    bills = money(bill_entries + recurring_total)
    remaining = money(paycheck + other_income - minimum_savings - spend - bills - debts)
    return BudgetSummary(
        paycheck=money(paycheck),
        other_income=money(other_income),
        savings=money(minimum_savings),
        spend=money(spend),
        bills=bills,
        debts=money(debts),
        remaining=remaining,
        week_start=start,
        week_end=end - timedelta(days=1),
    )


def month_buckets(entries: list[Entry], months_back: int = 11, selected_month: str | None = None) -> list[date]:
    if selected_month and selected_month != "All Months":
        year, month = selected_month.split("-", 1)
        start = date(int(year), int(month), 1)
        end = add_months(start, 1)
        days = []
        cursor = start
        while cursor < end:
            days.append(cursor)
            cursor += timedelta(days=1)
        return days
    today = date.today().replace(day=1)
    buckets = []
    for index in range(-months_back, 1):
        year = today.year + (today.month - 1 + index) // 12
        month = (today.month - 1 + index) % 12 + 1
        buckets.append(date(year, month, 1))
    return buckets


def monthly_flow(entries: list[Entry], goals: list[Goal], account: str | None = None, selected_month: str | None = None) -> list[dict[str, object]]:
    rows = []
    is_daily = bool(selected_month and selected_month != "All Months")
    for bucket in month_buckets(entries, selected_month=selected_month):
        if is_daily:
            items = [entry for entry in entries if entry.date == bucket and (not account or account == "All Accounts" or entry.account == account)]
            label = bucket.strftime("%d")
        else:
            items = [entry for entry in entries if entry.date.year == bucket.year and entry.date.month == bucket.month and (not account or account == "All Accounts" or entry.account == account)]
            label = bucket.strftime("%b")
        out = sum((entry.amount for entry in items if entry.type in {"Expense", "Bill"} and not is_internal_transfer(entry)), money(0))
        saved = actual_savings_amount(items, goals, account)
        rows.append({"label": label, "Out": money(out), "Saved": money(saved), "Net": money(saved - out)})
    return rows


def income_vs_spend(
    entries: list[Entry],
    account: str | None = None,
    names: dict[str, str] | None = None,
    balances: dict[str, AccountBalance] | None = None,
    selected_month: str | None = None,
) -> tuple[list[dict[str, object]], list[str]]:
    names = names or {}
    balances = balances or {}
    is_card = bool(account and account != "All Accounts" and is_credit_card_account(account, names, balances))
    is_savings = bool(account and account != "All Accounts" and is_savings_account(account, names, entries))
    labels = ["Credit + Interest", "Payments", "Net"] if is_savings else ["Income", "Out", "Net"]
    rows = []
    is_daily = bool(selected_month and selected_month != "All Months")
    for bucket in month_buckets(entries, selected_month=selected_month):
        if is_daily:
            items = [entry for entry in entries if entry.date == bucket and (not account or account == "All Accounts" or entry.account == account)]
            label = bucket.strftime("%d")
        else:
            items = [entry for entry in entries if entry.date.year == bucket.year and entry.date.month == bucket.month and (not account or account == "All Accounts" or entry.account == account)]
            label = bucket.strftime("%b")
        if is_card:
            income = sum((entry.amount for entry in items if entry.bank_category.upper() == "PAYMENT"), money(0))
            out = sum((entry.amount for entry in items if entry.bank_category.upper() in {"OTHER", "FEE", "FEES", "DEBIT", "CASH"}), money(0))
            rows.append({"label": label, "Income": money(income), "Out": money(out), "Net": money(income - out)})
        elif is_savings:
            credit = sum((entry.amount for entry in items if is_savings_credit(entry)), money(0))
            payments = sum((entry.amount for entry in items if is_savings_payment(entry)), money(0))
            rows.append({"label": label, "Credit + Interest": money(credit), "Payments": money(payments), "Net": money(credit - payments)})
        else:
            income = sum((entry.amount for entry in items if entry.type == "Income"), money(0))
            out = sum((entry.amount for entry in items if entry.type in {"Expense", "Bill"} and not is_internal_transfer(entry)), money(0))
            rows.append({"label": label, "Income": money(income), "Out": money(out), "Net": money(income - out)})
    return rows, labels


def category_spend(entries: list[Entry]) -> list[tuple[str, Decimal]]:
    totals: dict[str, Decimal] = defaultdict(lambda: money(0))
    for entry in entries:
        if entry.type in {"Expense", "Bill"} and not is_internal_transfer(entry):
            totals[entry.category or entry.bank_category or "Other"] += entry.amount
    return sorted(totals.items(), key=lambda item: item[1], reverse=True)
