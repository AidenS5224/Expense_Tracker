from __future__ import annotations

import re
import uuid
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from typing import Any


MONEY_QUANT = Decimal("0.01")


def new_id() -> str:
    return uuid.uuid4().hex


def money(value: Any) -> Decimal:
    if value is None:
        return Decimal("0.00")
    if isinstance(value, Decimal):
        return value.quantize(MONEY_QUANT, rounding=ROUND_HALF_UP)
    text = str(value).strip()
    if not text:
        return Decimal("0.00")
    negative = text.startswith("(") and text.endswith(")")
    text = text.replace("$", "").replace(",", "").replace("(", "").replace(")", "").strip()
    try:
        parsed = Decimal(text)
    except InvalidOperation:
        return Decimal("0.00")
    if negative:
        parsed = -abs(parsed)
    return parsed.quantize(MONEY_QUANT, rounding=ROUND_HALF_UP)


def fmt_money(value: Any) -> str:
    amount = money(value)
    sign = "-" if amount < 0 else ""
    amount = abs(amount)
    return f"{sign}${amount:,.2f}"


def parse_date(value: Any) -> date:
    if isinstance(value, date) and not isinstance(value, datetime):
        return value
    if isinstance(value, datetime):
        return value.date()
    text = "" if value is None else str(value).strip()
    if not text:
        return date.today()

    match = re.match(r"^/Date\((-?\d+)\)/$", text)
    if match:
        millis = int(match.group(1))
        return datetime.fromtimestamp(millis / 1000, tz=timezone.utc).date()

    for fmt in ("%d/%m/%Y", "%d/%m/%y", "%Y-%m-%d", "%d-%m-%Y", "%d.%m.%Y"):
        try:
            return datetime.strptime(text, fmt).date()
        except ValueError:
            pass

    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).date()
    except ValueError:
        pass

    for day_first in (True, False):
        parts = re.split(r"[/-]", text)
        if len(parts) == 3 and all(part.isdigit() for part in parts):
            a, b, c = [int(part) for part in parts]
            year = c + 2000 if c < 100 else c
            month = b if day_first else a
            day = a if day_first else b
            try:
                return date(year, month, day)
            except ValueError:
                pass
    return date.today()


def monday_for(day: date) -> date:
    return day - timedelta(days=day.weekday())


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip()).lower()


def normalize_account(value: Any) -> str:
    text = str(value or "").strip()
    return re.sub(r"\s+", "", text)


def clean_header(value: str) -> str:
    return normalize_text(value).replace("_", " ")


def header_match(headers: list[str], patterns: list[str]) -> str | None:
    for pattern in patterns:
        regex = re.compile(pattern, re.I)
        for header in headers:
            if regex.search(header):
                return header
    return None


def date_key(day: date) -> str:
    return day.isoformat()


def month_key(day: date) -> str:
    return f"{day.year:04d}-{day.month:02d}"


def add_months(day: date, months: int) -> date:
    month = day.month - 1 + months
    year = day.year + month // 12
    month = month % 12 + 1
    last = [31, 29 if year % 4 == 0 and (year % 100 != 0 or year % 400 == 0) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    return date(year, month, min(day.day, last))
