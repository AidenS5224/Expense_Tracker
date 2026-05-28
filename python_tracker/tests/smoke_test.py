from pathlib import Path
import sys
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from expense_tracker.analytics import calculated_balances, current_week_budget, goal_progress
from expense_tracker.projection import minimum_savings_projection, minimum_weekly_rate
from expense_tracker.storage import LEGACY_JSON, TrackerStore


def main() -> None:
    with TemporaryDirectory() as tmp:
        store = TrackerStore(Path(tmp) / "tracker.sqlite3", LEGACY_JSON)
        store.initialize()
        entries = store.entries()
        goals = store.goals()
        account_names = store.account_names()
        account_balances = store.account_balances()
        balances = calculated_balances(entries, account_balances, account_names)
        goal_rows = goal_progress(goals, balances)
        minimum, points = minimum_savings_projection(goal_rows)
        weekly_rate = minimum_weekly_rate(goal_rows)
        budget = current_week_budget(
            entries,
            goals,
            store.recurring_payments(),
            balances,
            account_names,
            account_balances,
            weekly_rate,
        )
        print(f"entries={len(entries)} goals={len(goals)} balances={len(balances)} projection_points={len(points)}")
        print(f"projection_peak={minimum} minimum_weekly={weekly_rate} remaining_budget={budget.remaining}")
        if LEGACY_JSON.exists():
            assert entries
            assert balances
        assert weekly_rate >= 0


if __name__ == "__main__":
    main()
