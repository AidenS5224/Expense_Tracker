# Expense & Savings Tracker

A Windows desktop expense and savings tracker built with PowerShell WinForms.

## Features

- Import bank statement CSV files.
- Import account balance CSV files.
- Track expenses, income, savings goals, recurring payments, and account balances.
- Show dashboard charts for cash flow, income vs spend, savings goals, and balances.
- Prevent duplicate statement imports.
- Store local data in `tracker-data/data.json`.

## Run

Double-click `Start-ExpenseTracker.cmd`, or run:

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File ".\ExpenseSavingsTracker.ps1"
```

## Privacy

Bank transactions and account balances are stored locally in `tracker-data/`.
That folder is ignored by Git and should not be uploaded.
