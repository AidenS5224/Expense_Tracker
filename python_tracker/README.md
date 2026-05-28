# Expense & Savings Tracker - Python

Native Python rebuild of the PowerShell Expense & Savings Tracker.

## Requirements

- Python 3.11 or newer
- Pillow is optional but recommended for smoother anti-aliased charts

Install the optional chart renderer with:

```powershell
py -3 -m pip install pillow
```

## Run

From this folder:

```powershell
py -3 -m expense_tracker
```

Or double-click:

```text
Start-Python-ExpenseTracker.cmd
```

The start script will use Codex's bundled Python runtime if it is available. For normal long-term use outside Codex, install Python 3.11+ from python.org.

## Data

The app stores data in:

```text
data/tracker.sqlite3
```

On first launch, it will migrate the existing PowerShell JSON data from:

```text
../tracker-data/data.json
```

The PowerShell app is not modified.

## Features In This Build

- SQLite data store
- JSON migration from the PowerShell tracker
- Statement CSV import with duplicate detection
- Accounts CSV import
- Current balances using account balance anchors plus later transactions
- Weekly budget cards
- Transaction, balance, recurring payment, and savings goal tables
- Two side-by-side graph panes
- Savings projection using a smoothed minimum-peak allocation model
- Manual entry editing
- Goal and recurring payment editing
