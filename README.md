# Expense Savings Tracker

A Windows desktop expense and savings tracker rebuilt as a native Python app.

## Features

- Import bank statement CSV files with duplicate detection.
- Import account balance CSV files and use them as balance anchors.
- Track expenses, income, savings goals, recurring payments, and account balances.
- Use weekly budget cards for paycheck, expected bills, minimum savings, spend, and remaining budget.
- Create target-by-date savings goals or fixed weekly savings goals.
- View two dashboard panels at once, including data table, cash flow, income vs spend, savings goals, and balance graphs.
- Name accounts, hide unused balance accounts, and keep all transaction data in the local database.
- Create automatic JSON backups before imports and restores.

## Run

Double-click:

```text
python_tracker\Start-Python-ExpenseTracker.cmd
```

Or run directly:

```powershell
cd python_tracker
py -3 -m expense_tracker
```

## Basic Use

1. Import account balances from your bank accounts CSV.
2. Import statement CSV files.
3. Use `Mark Income` on your paycheck transaction each week.
4. Add recurring payments and savings goals.
5. Use `Refresh` to recalculate the dashboard without restarting.

## Data

Local app data is saved in `python_tracker\data\tracker.sqlite3`.
The local database is ignored by Git and should not be uploaded.

## Privacy

Bank transactions and account balances stay local on your machine.
