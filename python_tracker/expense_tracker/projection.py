from __future__ import annotations

from datetime import date, timedelta
from decimal import Decimal

from .models import Goal, ProjectionPoint
from .util import money


def deadline_week_index(week_dates: list[date], due: date) -> int:
    index = 0
    for i, week in enumerate(week_dates):
        if week <= due:
            index = i
    return index


def is_peak_feasible(peak: Decimal, fixed_totals: list[Decimal], var_goals: list[dict]) -> bool:
    deadline_indexes = sorted({goal["deadline"] for goal in var_goals})
    for deadline in deadline_indexes:
        capacity = sum((max(money(0), peak - fixed_totals[w]) for w in range(deadline + 1)), money(0))
        required = sum((goal["amount"] for goal in var_goals if goal["deadline"] <= deadline), money(0))
        if capacity + Decimal("0.01") < required:
            return False
    return True


def minimum_feasible_peak(fixed_totals: list[Decimal], var_goals: list[dict]) -> Decimal:
    if not fixed_totals:
        return money(0)
    fixed_peak = max(fixed_totals) if fixed_totals else money(0)
    variable_total = sum((goal["amount"] for goal in var_goals), money(0))
    if variable_total <= 0:
        return money(fixed_peak)
    low = fixed_peak
    high = fixed_peak + variable_total
    for _ in range(70):
        mid = money((low + high) / 2)
        if is_peak_feasible(mid, fixed_totals, var_goals):
            high = mid
        else:
            low = mid
    return money(high)


def project_to_simplex(values: list[Decimal], target: Decimal) -> list[Decimal]:
    target = max(money(0), money(target))
    n = len(values)
    if n == 0:
        return []
    cleaned = [max(money(0), money(value)) for value in values]
    if target == 0:
        return [money(0) for _ in cleaned]
    values_float = sorted([float(value) for value in cleaned], reverse=True)
    cumulative = 0.0
    theta = 0.0
    target_float = float(target)
    for idx, value in enumerate(values_float, start=1):
        cumulative += value
        candidate = (cumulative - target_float) / idx
        next_value = values_float[idx] if idx < len(values_float) else float("-inf")
        if candidate >= next_value:
            theta = candidate
            break
    projected = [Decimal(str(max(float(value) - theta, 0.0))) for value in cleaned]
    total = sum(projected, Decimal("0"))
    if total > 0:
        projected = [money(value * target / total) for value in projected]
    difference = target - sum(projected, Decimal("0"))
    if projected and difference != 0:
        projected[0] = money(projected[0] + difference)
    return projected


def optimized_variable_allocations(week_count: int, var_goals: list[dict], weekly_capacity: list[Decimal]) -> list[list[Decimal]]:
    if not var_goals:
        return [[money(0) for _ in var_goals] for _ in range(week_count)]

    allocations = [[money(0) for _ in var_goals] for _ in range(week_count)]
    for g, goal in enumerate(var_goals):
        deadline = goal["deadline"]
        average = goal["amount"] / Decimal(deadline + 1)
        for week in range(deadline + 1):
            urgency = Decimal("1") + (Decimal(week) / Decimal(max(1, deadline + 1))) * Decimal("0.08")
            allocations[week][g] = money(average * urgency)

    for _ in range(140):
        for week in range(week_count):
            active = [g for g, goal in enumerate(var_goals) if week <= goal["deadline"]]
            if not active:
                continue
            row_values = [allocations[week][g] for g in active]
            projected = project_to_simplex(row_values, weekly_capacity[week])
            for i, g in enumerate(active):
                allocations[week][g] = projected[i]
            for g, goal in enumerate(var_goals):
                if week > goal["deadline"]:
                    allocations[week][g] = money(0)

        for g, goal in enumerate(var_goals):
            deadline = goal["deadline"]
            column = [allocations[week][g] for week in range(deadline + 1)]
            projected = project_to_simplex(column, goal["amount"])
            for week in range(deadline + 1):
                allocations[week][g] = projected[week]
            for week in range(deadline + 1, week_count):
                allocations[week][g] = money(0)

    return allocations


def minimum_savings_projection(goal_rows: list[tuple[Goal, Decimal, Decimal]], today: date | None = None) -> tuple[Decimal, list[ProjectionPoint]]:
    today = today or date.today()
    relevant_goals = [goal for goal, _, _ in goal_rows if goal.goal_kind != "Weekly" or not goal.is_ongoing]
    latest_due = max((goal.expected_date for goal in relevant_goals), default=today + timedelta(weeks=12))
    max_weeks = max(1, ((latest_due - today).days // 7) + 1)
    if any(goal.goal_kind == "Weekly" and goal.is_ongoing for goal, _, _ in goal_rows):
        max_weeks = max(max_weeks, 52)
    max_weeks = min(104, max_weeks)
    week_dates = [today + timedelta(days=7 * week) for week in range(max_weeks)]

    fixed = [[money(0) for _ in goal_rows] for _ in range(max_weeks)]
    fixed_totals = [money(0) for _ in range(max_weeks)]
    variable_goals: list[dict] = []

    for index, (goal, _saved, remaining) in enumerate(goal_rows):
        if goal.goal_kind == "Weekly":
            weekly = money(goal.weekly_amount)
            if weekly <= 0:
                continue
            for week, week_date in enumerate(week_dates):
                active = goal.is_ongoing or week_date <= goal.expected_date
                if active:
                    fixed[week][index] = weekly
                    fixed_totals[week] += weekly
            continue
        if remaining <= 0:
            continue
        variable_goals.append(
            {
                "index": index,
                "goal": goal,
                "amount": money(remaining),
                "deadline": deadline_week_index(week_dates, goal.expected_date),
            }
        )

    peak = minimum_feasible_peak(fixed_totals, variable_goals)
    capacity = [max(money(0), peak - total) for total in fixed_totals]
    variable_alloc = optimized_variable_allocations(max_weeks, variable_goals, capacity)

    points: list[ProjectionPoint] = []
    for week, week_date in enumerate(week_dates):
        for index, (goal, _, _) in enumerate(goal_rows):
            allocation = fixed[week][index]
            if allocation > 0:
                points.append(ProjectionPoint(week, week_date, goal.id, goal.name, money(allocation), money(peak)))
        for var_index, item in enumerate(variable_goals):
            allocation = variable_alloc[week][var_index]
            if allocation > Decimal("0.005"):
                goal = item["goal"]
                points.append(ProjectionPoint(week, week_date, goal.id, goal.name, money(allocation), money(peak)))
    return money(peak), points


def minimum_weekly_rate(goal_rows: list[tuple[Goal, Decimal, Decimal]], today: date | None = None) -> Decimal:
    today = today or date.today()
    target_rows = sorted(
        [(goal, remaining) for goal, _saved, remaining in goal_rows if goal.goal_kind != "Weekly" and remaining > 0],
        key=lambda item: item[0].expected_date,
    )
    weekly_rows = sorted(
        [
            goal
            for goal, _saved, _remaining in goal_rows
            if goal.goal_kind == "Weekly"
            and goal.weekly_amount > 0
            and (goal.is_ongoing or goal.expected_date >= today)
        ],
        key=lambda goal: goal.expected_date,
    )

    cumulative = money(0)
    minimum = money(0)
    for goal, remaining in target_rows:
        cumulative += remaining
        weeks = max(1, (goal.expected_date - today).days // 7)
        needed = cumulative / Decimal(weeks)
        if needed > minimum:
            minimum = needed

    fixed = sum((goal.weekly_amount for goal in weekly_rows), money(0))
    return money(minimum + fixed)
