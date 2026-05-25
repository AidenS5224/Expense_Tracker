Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms.DataVisualization

$ErrorActionPreference = "Stop"

$AppDir = Join-Path $PSScriptRoot "tracker-data"
$DataPath = Join-Path $AppDir "data.json"

if (-not (Test-Path $AppDir)) {
  New-Item -ItemType Directory -Path $AppDir | Out-Null
}

$script:Entries = New-Object System.Collections.ArrayList
$script:Goals = New-Object System.Collections.ArrayList
$script:DisplayedGoalIds = @()
$script:DisplayedRecurringKeys = @()
$script:RecurringExclusions = @{}
$script:RecurringManual = New-Object System.Collections.ArrayList
$script:AllocationHistory = @{}
$script:WeeklyAvailableSavings = [decimal]0
$script:UpdatingWeeklySavingsBox = $false
$script:HiddenBalanceAccounts = @{}
$script:AccountNames = @{}
$script:AccountBalances = @{}
$script:AccountFilterMap = @{}
$script:EntryAccountMap = @{}
$script:DisplayedBalanceAccounts = @()
$script:EditingId = $null
$NewAccountOption = "New account..."

function Reset-AppSettings {
  $script:Settings = [pscustomobject]@{
    WeekStartsOn = "Monday"
    CurrencyCulture = "en-AU"
    LeftGraphDefault = "Data Table"
    RightGraphDefault = "Income vs Spend"
  }
}

Reset-AppSettings

$Categories = @{
  Expense = @("Rent / Mortgage", "Utilities", "Groceries", "Transport", "Insurance", "Medical", "Subscriptions", "Dining", "Personal", "Entertainment", "Debt", "Other")
  Saving = @("Emergency Fund", "Holiday", "Home", "Car", "Investment", "Other")
  Bill = @("Rent / Mortgage", "Utilities", "Insurance", "Subscriptions", "Medical", "Debt", "Other")
  Income = @("Paycheck", "Bonus", "Refund", "Interest", "Other")
}

function New-EntryId {
  return [guid]::NewGuid().ToString("N")
}

function ConvertTo-Money([decimal]$Value) {
  $cultureName = if ($script:Settings -and $script:Settings.CurrencyCulture) { [string]$script:Settings.CurrencyCulture } else { "en-AU" }
  try {
    return $Value.ToString("C2", [Globalization.CultureInfo]::GetCultureInfo($cultureName))
  } catch {
    return $Value.ToString("C2", [Globalization.CultureInfo]::GetCultureInfo("en-AU"))
  }
}

function Get-GoalKind($goal) {
  if ($goal -and $goal.GoalKind) { return [string]$goal.GoalKind }
  return "Target"
}

function Get-GoalWeeklyAmount($goal) {
  if (-not $goal) { return [decimal]0 }
  if ((Get-GoalKind $goal) -eq "Weekly") {
    if ($null -ne $goal.WeeklyAmount) { return [decimal]$goal.WeeklyAmount }
    return [decimal]$goal.TargetAmount
  }
  return [decimal]0
}

function Test-WeeklyGoalActive($goal, [Nullable[datetime]]$asOfDate = $null) {
  if ((Get-GoalKind $goal) -ne "Weekly") { return $false }
  if (-not $asOfDate.HasValue) { $asOfDate = [datetime]::Today }
  if ($goal.IsOngoing) { return $true }
  if (-not $goal.ExpectedDate) { return $true }
  return ([datetime]$goal.ExpectedDate).Date -ge $asOfDate.Value.Date
}

function Get-GoalSortDate($goal) {
  if ($goal -and $goal.ExpectedDate) { return [datetime]$goal.ExpectedDate }
  return [datetime]::MaxValue
}

function Get-AccountDisplayName([string]$account) {
  if ([string]::IsNullOrWhiteSpace($account)) { return "" }
  if ($script:AccountNames.ContainsKey($account) -and -not [string]::IsNullOrWhiteSpace($script:AccountNames[$account])) {
    return "$($script:AccountNames[$account]) ($account)"
  }
  return $account
}

function Get-AccountRawValue([string]$display) {
  if ([string]::IsNullOrWhiteSpace($display) -or $display -eq "All Accounts") { return $display }
  if ($script:AccountFilterMap.ContainsKey($display)) { return $script:AccountFilterMap[$display] }
  return $display
}

function Get-EntryAccountRawValue([string]$display) {
  if ([string]::IsNullOrWhiteSpace($display) -or $display -eq $NewAccountOption) { return $display }
  if ($script:EntryAccountMap.ContainsKey($display)) { return $script:EntryAccountMap[$display] }
  return $display
}

function Test-InternalTransfer($entry) {
  if (-not $entry) { return $false }
  $name = ([string]$entry.Name).ToUpperInvariant()
  $bankCategory = ([string]$entry.BankCategory).ToUpperInvariant()
  if ($name -match "\b(TFR|TRANSFER|OSKO|PAYMENT\s+TO|PAYMENT\s+FROM)\b") { return $true }
  if ($bankCategory -in @("TRANSFER", "TFR")) { return $true }
  return $false
}

function Test-SavingsAccount([string]$account) {
  if ([string]::IsNullOrWhiteSpace($account) -or $account -eq "All Accounts") { return $false }
  $display = (Get-AccountDisplayName $account).ToLowerInvariant()
  if ($display -match "saving|sec acc") { return $true }
  $savingRows = @($script:Entries | Where-Object { $_.Account -eq $account -and $_.Type -eq "Saving" })
  $expenseRows = @($script:Entries | Where-Object { $_.Account -eq $account -and $_.Type -eq "Expense" })
  return ($savingRows.Count -gt 0 -and $expenseRows.Count -gt 0 -and $savingRows.Count -ge ($expenseRows.Count * 0.25))
}

function Test-CreditCardAccount([string]$account) {
  if ([string]::IsNullOrWhiteSpace($account) -or $account -eq "All Accounts") { return $false }
  $display = (Get-AccountDisplayName $account).ToLowerInvariant()
  if ($display -match "credit\s*card|credit cards") { return $true }
  if ($script:AccountBalances.ContainsKey($account) -and [decimal]$script:AccountBalances[$account].Balance -lt 0) {
    $cardRows = @($script:Entries | Where-Object {
      $_.Account -eq $account -and
      ([string]$_.BankCategory).ToUpperInvariant() -in @("PAYMENT", "OTHER")
    })
    return ($cardRows.Count -gt 0)
  }
  return $false
}

function Test-SavingsAccountCredit($entry) {
  if (-not $entry) { return $false }
  $bankCategory = ([string]$entry.BankCategory).ToUpperInvariant()
  return ($entry.Type -in @("Saving", "Income") -or $bankCategory -in @("CREDIT", "DEP", "INT"))
}

function Test-SavingsAccountPayment($entry) {
  if (-not $entry) { return $false }
  $bankCategory = ([string]$entry.BankCategory).ToUpperInvariant()
  return ($entry.Type -in @("Expense", "Bill") -or $bankCategory -in @("PAYMENT", "DEBIT", "CASH", "ATM"))
}

function Test-GoalSavingEntry($entry) {
  if (-not $entry -or $entry.Type -ne "Saving") { return $false }
  if (Test-InternalTransfer $entry) { return $false }
  $category = ([string]$entry.Category).Trim()
  if ([string]::IsNullOrWhiteSpace($category)) { return $false }
  foreach ($goal in $script:Goals) {
    if ($category.Equals(([string]$goal.Name).Trim(), [StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }
  return $false
}

function Get-AllKnownAccounts {
  $accounts = @(
    $script:Entries | ForEach-Object { $_.Account }
    $script:Goals | ForEach-Object { $_.Account }
    $script:AccountBalances.Keys
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique

  if ($accounts.Count -eq 0) {
    return @("Card", "Debit", "Cash", "Bank Transfer", "Direct Debit", "Savings", "Other")
  }
  return $accounts
}

function Get-NormalizedAccountId([string]$bsb, [string]$accountNumber) {
  $cleanBsb = ([string]$bsb).Trim() -replace "\s", ""
  $cleanAccount = ([string]$accountNumber).Trim() -replace "\s", ""
  if ($cleanBsb.Length -gt 0 -and $cleanAccount.Length -gt 4) {
    return "$cleanBsb$cleanAccount"
  }
  return $cleanAccount
}

function Get-NormalizedStatementAccount([string]$account) {
  $cleanAccount = ([string]$account).Trim() -replace "\s", ""
  if ($cleanAccount.Length -gt 0) { return $cleanAccount }
  return ([string]$account).Trim()
}

function Get-LatestStatementBalances {
  $balances = @{}
  foreach ($entry in $script:Entries) {
    if ([string]::IsNullOrWhiteSpace($entry.Account) -or [decimal]$entry.Balance -eq 0) { continue }
    $account = [string]$entry.Account
    if (
      -not $balances.ContainsKey($account) -or
      [datetime]$entry.Date -gt [datetime]$balances[$account].Date
    ) {
      $balances[$account] = [pscustomobject]@{
        Balance = [decimal]$entry.Balance
        Date = [datetime]$entry.Date
        Source = "Statement"
      }
    }
  }
  return $balances
}

function Get-CalculatedAccountBalances {
  $statementBalances = Get-LatestStatementBalances
  $accountRows = New-Object System.Collections.ArrayList
  $allAccounts = @(
    $script:Entries | ForEach-Object { $_.Account }
    $script:AccountBalances.Keys
    $statementBalances.Keys
  ) | Where-Object { $_ } | Sort-Object -Unique

  foreach ($account in $allAccounts) {
    $accountsRecord = if ($script:AccountBalances.ContainsKey($account)) { $script:AccountBalances[$account] } else { $null }
    $statementRecord = if ($statementBalances.ContainsKey($account)) { $statementBalances[$account] } else { $null }
    $selected = $null

    if ($accountsRecord) {
      $selected = $accountsRecord
    } elseif ($statementRecord) {
      $selected = $statementRecord
    }

    $baseDate = if ($selected) { [datetime]$selected.Date } else { [datetime]::MinValue }
    $baseDay = $baseDate.Date
    $balance = if ($selected) { [decimal]$selected.Balance } else { [decimal]0 }
    $latestDate = $baseDate
    $adjustmentEntries = @($script:Entries | Where-Object {
      $_.Account -eq $account -and
      [decimal]$_.Balance -eq 0 -and
      ([datetime]$_.Date).Date -gt $baseDay
    } | Sort-Object Date)

    foreach ($adjustmentEntry in $adjustmentEntries) {
      $balance += Get-EntryBalanceDelta $adjustmentEntry
      if ([datetime]$adjustmentEntry.Date -gt $latestDate) {
        $latestDate = [datetime]$adjustmentEntry.Date
      }
    }

    if ($selected) {
      [void]$accountRows.Add([pscustomobject]@{
        Account = $account
        Date = $latestDate
        Balance = $balance
        Source = if ($adjustmentEntries.Count -gt 0) { "$($selected.Source) + Transactions" } else { [string]$selected.Source }
      })
    } elseif ($adjustmentEntries.Count -gt 0) {
      [void]$accountRows.Add([pscustomobject]@{
        Account = $account
        Date = $latestDate
        Balance = $balance
        Source = "Transactions"
      })
    }
  }

  return @($accountRows | Sort-Object Account)
}

function Get-EntryBalanceDelta($entry) {
  $bankCategory = ([string]$entry.BankCategory).ToUpperInvariant()
  if (Test-CreditCardAccount ([string]$entry.Account)) {
    if ($bankCategory -eq "PAYMENT") { return [decimal]$entry.Amount }
    if ($bankCategory -in @("OTHER", "FEE", "FEES", "DEBIT", "CASH")) { return -1 * [decimal]$entry.Amount }
  }

  if ($entry.Type -in @("Saving", "Income")) {
    return [decimal]$entry.Amount
  }
  return -1 * [decimal]$entry.Amount
}

function Get-AccountBalanceAnchor([string]$account) {
  $statementEntry = @($script:Entries |
    Where-Object {
      $_.Account -eq $account -and
      $null -ne $_.Date -and
      $null -ne $_.Balance -and
      [decimal]$_.Balance -ne 0
    } |
    Sort-Object Date -Descending |
    Select-Object -First 1)[0]

  $statementRecord = if ($statementEntry) {
    [pscustomobject]@{
      Balance = [decimal]$statementEntry.Balance
      Date = [datetime]$statementEntry.Date
      Source = "Statement"
    }
  } else {
    $null
  }

  $accountsRecord = if ($script:AccountBalances.ContainsKey($account)) { $script:AccountBalances[$account] } else { $null }
  if ($accountsRecord) { return $accountsRecord }
  if ($statementRecord) { return $statementRecord }
  return $null
}

function Get-EstimatedAccountBalanceAt([datetime]$targetDate, [string]$account) {
  $anchor = Get-AccountBalanceAnchor $account
  if (-not $anchor) { return [decimal]0 }

  $anchorDate = ([datetime]$anchor.Date).Date
  $target = $targetDate.Date
  $balance = [decimal]$anchor.Balance

  if ($target -eq $anchorDate) { return $balance }

  if ($target -gt $anchorDate) {
    $transactions = @($script:Entries | Where-Object {
      $_.Account -eq $account -and
      $null -ne $_.Date -and
      ([datetime]$_.Date).Date -gt $anchorDate -and
      ([datetime]$_.Date).Date -le $target
    })
    foreach ($entry in $transactions) {
      $balance += Get-EntryBalanceDelta $entry
    }
    return $balance
  }

  $transactions = @($script:Entries | Where-Object {
    $_.Account -eq $account -and
    $null -ne $_.Date -and
    ([datetime]$_.Date).Date -gt $target -and
    ([datetime]$_.Date).Date -le $anchorDate
  })
  foreach ($entry in $transactions) {
    $balance -= Get-EntryBalanceDelta $entry
  }
  return $balance
}

function Test-AccountHasBalanceDataInRange([string]$account, [datetime]$rangeStart, [datetime]$rangeEnd) {
  $hasTransaction = @($script:Entries | Where-Object {
    $_.Account -eq $account -and
    $null -ne $_.Date -and
    ([datetime]$_.Date) -ge $rangeStart -and
    ([datetime]$_.Date) -le $rangeEnd
  } | Select-Object -First 1).Count -gt 0
  if ($hasTransaction) { return $true }

  $anchor = Get-AccountBalanceAnchor $account
  return ($anchor -and [datetime]$anchor.Date -ge $rangeStart -and [datetime]$anchor.Date -le $rangeEnd)
}

function Test-AccountHasFutureBalanceData([string]$account, [datetime]$asOfDate) {
  $hasFutureTransaction = @($script:Entries | Where-Object {
    $_.Account -eq $account -and
    $null -ne $_.Date -and
    ([datetime]$_.Date) -gt $asOfDate
  } | Select-Object -First 1).Count -gt 0
  if ($hasFutureTransaction) { return $true }

  $anchor = Get-AccountBalanceAnchor $account
  return ($anchor -and [datetime]$anchor.Date -gt $asOfDate)
}

function Get-AccountBalanceDataRanges([object[]]$accounts) {
  $ranges = @{}
  $accountSet = @{}
  foreach ($account in $accounts) {
    if (-not [string]::IsNullOrWhiteSpace([string]$account)) {
      $accountSet[[string]$account] = $true
    }
  }

  foreach ($account in $accountSet.Keys) {
    $anchor = Get-AccountBalanceAnchor $account
    if ($anchor) {
      $date = ([datetime]$anchor.Date).Date
      $ranges[$account] = [pscustomobject]@{ First = $date; Last = $date }
    }
  }

  foreach ($entry in $script:Entries) {
    $account = [string]$entry.Account
    if (-not $accountSet.ContainsKey($account) -or $null -eq $entry.Date) { continue }
    $date = ([datetime]$entry.Date).Date
    if (-not $ranges.ContainsKey($account)) {
      $ranges[$account] = [pscustomobject]@{ First = $date; Last = $date }
      continue
    }
    if ($date -lt [datetime]$ranges[$account].First) { $ranges[$account].First = $date }
    if ($date -gt [datetime]$ranges[$account].Last) { $ranges[$account].Last = $date }
  }

  return $ranges
}

function Get-GoalSavedAmount($goal, $calculatedBalances = $null) {
  if (-not $calculatedBalances) {
    $calculatedBalances = Get-CalculatedAccountBalances
  }

  $balanceRow = @($calculatedBalances | Where-Object { $_.Account -eq $goal.Account } | Select-Object -First 1)[0]
  if ($balanceRow) {
    return [math]::Max([decimal]0, [decimal]$balanceRow.Balance)
  }

  return [decimal](@($script:Entries | Where-Object { $_.Type -eq "Saving" -and $_.Account -eq $goal.Account } | Measure-Object Amount -Sum).Sum)
}

function Get-GoalProgressRows {
  $calculatedBalances = Get-CalculatedAccountBalances
  $availableByAccount = @{}
  foreach ($row in $calculatedBalances) {
    $availableByAccount[[string]$row.Account] = [math]::Max([decimal]0, [decimal]$row.Balance)
  }

  $rows = New-Object System.Collections.ArrayList
  foreach ($goal in @($script:Goals | Sort-Object Account, @{ Expression = { Get-GoalSortDate $_ } } )) {
    $account = [string]$goal.Account
    if ((Get-GoalKind $goal) -eq "Weekly") {
      [void]$rows.Add([pscustomobject]@{
        Goal = $goal
        Saved = [decimal]0
        Remaining = if (Test-WeeklyGoalActive $goal) { Get-GoalWeeklyAmount $goal } else { [decimal]0 }
      })
      continue
    }
    $available = if ($availableByAccount.ContainsKey($account)) { [decimal]$availableByAccount[$account] } else { [decimal]0 }
    $saved = [math]::Min([decimal]$goal.TargetAmount, $available)
    $availableByAccount[$account] = [math]::Max([decimal]0, $available - [decimal]$goal.TargetAmount)

    [void]$rows.Add([pscustomobject]@{
      Goal = $goal
      Saved = [decimal]$saved
      Remaining = [math]::Max([decimal]0, [decimal]$goal.TargetAmount - [decimal]$saved)
    })
  }

  return @($rows)
}

function Get-GoalStatus([decimal]$remaining, [decimal]$requiredWeekly, [decimal]$projectedWeekly, [double]$weeksRemaining) {
  if ($remaining -le 0) { return "Ahead" }
  if ($projectedWeekly -le 0) { return "Impossible" }
  if ($projectedWeekly -lt $requiredWeekly * [decimal]0.75) { return "Behind" }
  if ($projectedWeekly -ge $requiredWeekly) { return "On Track" }
  return "Behind"
}

function Get-AllocationPlan([decimal]$weeklyAvailableSavings, [hashtable]$previousAllocations = $null, [Nullable[datetime]]$asOfDate = $null, [object[]]$goalRows = $null) {
  if (-not $previousAllocations) { $previousAllocations = $script:AllocationHistory }
  $effectiveDate = if ($asOfDate.HasValue) { $asOfDate.Value } else { [datetime]::Today }
  if (-not $goalRows) { $goalRows = Get-GoalProgressRows }

  $activeRows = @($goalRows | Where-Object { [decimal]$_.Remaining -gt 0 })
  $allocations = @{}
  $details = New-Object System.Collections.ArrayList
  $remainingBudget = [math]::Max([decimal]0, $weeklyAvailableSavings)
  if ($activeRows.Count -eq 0 -or $remainingBudget -le 0) {
    return [pscustomobject]@{ Rows = @(); TotalAllocated = [decimal]0; Leftover = $remainingBudget; Warning = "" }
  }

  $scoreRows = New-Object System.Collections.ArrayList
  foreach ($row in $activeRows) {
    $goal = $row.Goal
    $remaining = [decimal]$row.Remaining
    $target = [math]::Max([decimal]1, [decimal]$goal.TargetAmount)
    $daysRemaining = [math]::Max(1, (([datetime]$goal.ExpectedDate - $effectiveDate).TotalDays))
    $weeksRemaining = [math]::Max([double]1, [double]($daysRemaining / 7))
    $requiredWeekly = $remaining / [decimal]$weeksRemaining
    $urgencyWeight = [decimal](1 / $weeksRemaining)
    $shortfallWeight = [decimal]1 + ($remaining / $target)
    $riskWeight = [decimal]1 + ($requiredWeekly / [math]::Max([decimal]1, $weeklyAvailableSavings))
    $priorityScore = $urgencyWeight * $shortfallWeight * $riskWeight
    [void]$scoreRows.Add([pscustomobject]@{
      Goal = $goal
      Remaining = $remaining
      WeeksRemaining = $weeksRemaining
      RequiredWeekly = $requiredWeekly
      PriorityScore = $priorityScore
    })
  }

  $totalPriority = [decimal](@($scoreRows | Measure-Object PriorityScore -Sum).Sum)
  foreach ($row in $scoreRows) {
    $goal = $row.Goal
    $previous = if ($previousAllocations.ContainsKey($goal.Id)) { [decimal]$previousAllocations[$goal.Id] } else { [decimal]0 }
    $raw = if ($totalPriority -gt 0) { $weeklyAvailableSavings * ([decimal]$row.PriorityScore / $totalPriority) } else { [decimal]0 }
    $smoothed = if ($previous -gt 0) { ([decimal]0.7 * $previous) + ([decimal]0.3 * $raw) } else { $raw }
    if ($previous -gt 0) {
      $smoothed = [math]::Min($previous * [decimal]1.15, [math]::Max($previous * [decimal]0.85, $smoothed))
    }
    $allocated = [math]::Min([decimal]$row.Remaining, [math]::Min($remainingBudget, $smoothed))
    $allocations[$goal.Id] = [decimal]$allocated
    $remainingBudget -= [decimal]$allocated
  }

  foreach ($row in @($scoreRows | Sort-Object { $_.Goal.ExpectedDate })) {
    if ($remainingBudget -le 0) { break }
    $goal = $row.Goal
    $currentAllocation = if ($allocations.ContainsKey($goal.Id)) { [decimal]$allocations[$goal.Id] } else { [decimal]0 }
    $room = [math]::Max([decimal]0, [decimal]$row.Remaining - $currentAllocation)
    if ($room -le 0) { continue }
    $extra = [math]::Min($room, $remainingBudget)
    $allocations[$goal.Id] = $currentAllocation + $extra
    $remainingBudget -= $extra
  }

  $totalAllocated = [decimal]0
  foreach ($row in $scoreRows) {
    $goal = $row.Goal
    $allocation = if ($allocations.ContainsKey($goal.Id)) { [decimal]$allocations[$goal.Id] } else { [decimal]0 }
    $totalAllocated += $allocation
    $weeksToComplete = if ($allocation -gt 0) { [math]::Ceiling(([decimal]$row.Remaining / $allocation)) } else { [double]::PositiveInfinity }
    $completionDate = if ($allocation -gt 0) { $effectiveDate.AddDays([double]$weeksToComplete * 7) } else { [datetime]$goal.ExpectedDate }
    $status = Get-GoalStatus ([decimal]$row.Remaining) ([decimal]$row.RequiredWeekly) $allocation ([double]$row.WeeksRemaining)
    [void]$details.Add([pscustomobject]@{
      GoalId = $goal.Id
      GoalName = $goal.Name
      TargetDate = [datetime]$goal.ExpectedDate
      Remaining = [decimal]$row.Remaining
      RequiredWeekly = [decimal]$row.RequiredWeekly
      Allocation = [decimal]$allocation
      ProjectedCompletion = $completionDate
      Status = $status
    })
  }

  $requiredTotal = [decimal](@($scoreRows | Measure-Object RequiredWeekly -Sum).Sum)
  $warning = if ($weeklyAvailableSavings -lt $requiredTotal) { "Warning: weekly savings is too low to hit all deadlines" } else { "" }
  return [pscustomobject]@{
    Rows = @($details | Sort-Object TargetDate)
    TotalAllocated = $totalAllocated
    Leftover = [math]::Max([decimal]0, $weeklyAvailableSavings - $totalAllocated)
    Warning = $warning
  }
}

function Get-AllocationProjection([decimal]$weeklyAvailableSavings) {
  $goalRows = @(Get-GoalProgressRows | ForEach-Object {
    [pscustomobject]@{ Goal = $_.Goal; Saved = [decimal]$_.Saved; Remaining = [decimal]$_.Remaining }
  })
  $previous = @{}
  foreach ($key in $script:AllocationHistory.Keys) { $previous[$key] = [decimal]$script:AllocationHistory[$key] }
  $latestDue = @($script:Goals | Sort-Object ExpectedDate -Descending | Select-Object -First 1)[0]
  $maxWeeks = if ($latestDue) { [math]::Max(12, [math]::Ceiling((([datetime]$latestDue.ExpectedDate - [datetime]::Today).TotalDays) / 7)) } else { 12 }
  $maxWeeks = [math]::Min(104, $maxWeeks)
  $points = New-Object System.Collections.ArrayList

  for ($week = 0; $week -le $maxWeeks; $week++) {
    $date = [datetime]::Today.AddDays($week * 7)
    $plan = Get-AllocationPlan $weeklyAvailableSavings $previous $date $goalRows
    foreach ($row in $plan.Rows) {
      [void]$points.Add([pscustomobject]@{
        Week = $week
        Date = $date
        GoalId = $row.GoalId
        GoalName = $row.GoalName
        Allocation = [decimal]$row.Allocation
      })
      $previous[$row.GoalId] = [decimal]$row.Allocation
    }
    foreach ($goalRow in $goalRows) {
      $allocationRow = $plan.Rows | Where-Object { $_.GoalId -eq $goalRow.Goal.Id } | Select-Object -First 1
      if ($allocationRow) {
        $goalRow.Remaining = [math]::Max([decimal]0, [decimal]$goalRow.Remaining - [decimal]$allocationRow.Allocation)
      }
    }
    if (@($goalRows | Where-Object { [decimal]$_.Remaining -gt 0 }).Count -eq 0) { break }
  }

  return @($points)
}

function Get-RecurringMerchantKey([string]$name) {
  $key = ([string]$name).ToUpperInvariant()
  $key = $key -replace "\d+", " "
  $key = $key -replace "\b(DEBIT|CREDIT|CARD|VISA|MASTERCARD|EFTPOS|POS|PAYMENT|PURCHASE|WITHDRAWAL|ONLINE|MOBILE|TRANSFER|TFR|BPAY|DIRECT)\b", " "
  $key = $key -replace "[^A-Z]+", " "
  $key = $key.Trim() -replace "\s+", " "
  if ($key.Length -eq 0) { return ([string]$name).Trim().ToUpperInvariant() }
  return $key
}

function Get-RecurringDetectionKey($entry) {
  $amountKey = ([decimal]$entry.Amount).ToString("0.00", [Globalization.CultureInfo]::InvariantCulture)
  return "$(Get-RecurringMerchantKey $entry.Name)|$($entry.Account)|$amountKey"
}

function Get-RecurringFrequency([object[]]$entries) {
  $dates = @($entries | Sort-Object Date | ForEach-Object { [datetime]$_.Date })
  if ($dates.Count -lt 2) { return "" }

  $gaps = New-Object System.Collections.ArrayList
  for ($i = 1; $i -lt $dates.Count; $i++) {
    $days = [int](($dates[$i] - $dates[$i - 1]).TotalDays)
    if ($days -gt 0) { [void]$gaps.Add($days) }
  }
  if ($gaps.Count -eq 0) { return "" }

  $average = [double](@($gaps | Measure-Object -Average).Average)
  if ($average -ge 5 -and $average -le 9) { return "Weekly" }
  if ($average -ge 12 -and $average -le 17) { return "Fortnightly" }
  if ($average -ge 24 -and $average -le 38) { return "Monthly" }
  if ($average -ge 75 -and $average -le 105) { return "Quarterly" }
  if ($average -ge 330 -and $average -le 400) { return "Annual" }
  return "Recurring"
}

function New-RecurringPaymentRecord([object[]]$items, [string]$key) {
  $latest = @($items | Sort-Object Date -Descending | Select-Object -First 1)[0]
  $merchantName = @($items |
    Group-Object Name |
    Sort-Object Count -Descending |
    Select-Object -First 1)[0].Name
  $frequency = Get-RecurringFrequency $items
  if ([string]::IsNullOrWhiteSpace($frequency)) { $frequency = "Recurring" }

  return [pscustomobject]@{
    Key = $key
    Name = $merchantName
    Category = $latest.Category
    Account = $latest.Account
    Amount = [decimal]$latest.Amount
    Date = [datetime]$latest.Date
    Frequency = $frequency
    Count = $items.Count
  }
}

function Get-DetectedRecurringPayments {
  $candidates = @($script:Entries | Where-Object {
    $_.Type -in @("Expense", "Bill") -and
    -not [string]::IsNullOrWhiteSpace($_.Name) -and
    [decimal]$_.Amount -gt 0
  })

  return @($candidates |
    Group-Object {
      Get-RecurringDetectionKey $_
    } |
    Where-Object { $_.Count -ge 2 -and -not $script:RecurringExclusions.ContainsKey([string]$_.Name) } |
    ForEach-Object {
      $items = @($_.Group | Sort-Object Date)
      $frequency = Get-RecurringFrequency $items
      if ([string]::IsNullOrWhiteSpace($frequency)) { return }

      $record = New-RecurringPaymentRecord $items ([string]$_.Name)
      $record.Amount = [decimal]$items[-1].Amount
      $record.Frequency = $frequency
      $record
    } |
    Sort-Object Date -Descending)
}

function Get-RecurringPayments {
  $manualRows = @($script:RecurringManual | Where-Object { -not $script:RecurringExclusions.ContainsKey([string]$_.Key) })
  return @($manualRows | Sort-Object Date -Descending)
}

function ConvertTo-WeeklyAmount([decimal]$amount, [string]$frequency) {
  switch ($frequency) {
    "Weekly" { return $amount }
    "Fortnightly" { return $amount / 2 }
    "Monthly" { return ($amount * 12) / 52 }
    "Quarterly" { return ($amount * 4) / 52 }
    "Annual" { return $amount / 52 }
    default { return $amount }
  }
}

function Get-RecurringIntervalDays([string]$frequency) {
  switch ($frequency) {
    "Weekly" { return 7 }
    "Fortnightly" { return 14 }
    "Monthly" { return 0 }
    "Quarterly" { return 0 }
    "Annual" { return 0 }
    default { return -1 }
  }
}

function Test-RecurringPaymentDueInRange($payment, [datetime]$rangeStart, [datetime]$rangeEnd) {
  if (-not $payment -or $null -eq $payment.Date) { return $false }
  $anchorDate = ([datetime]$payment.Date).Date
  $frequency = [string]$payment.Frequency

  if ($anchorDate -ge $rangeStart.Date -and $anchorDate -lt $rangeEnd.Date) { return $true }
  if ($anchorDate -gt $rangeEnd.Date) { return $false }

  $intervalDays = Get-RecurringIntervalDays $frequency
  if ($intervalDays -gt 0) {
    $daysSinceAnchor = [math]::Max(0, ($rangeStart.Date - $anchorDate).TotalDays)
    $periods = [math]::Ceiling($daysSinceAnchor / $intervalDays)
    $nextDate = $anchorDate.AddDays($periods * $intervalDays)
    return ($nextDate -ge $rangeStart.Date -and $nextDate -lt $rangeEnd.Date)
  }

  if ($frequency -eq "Monthly" -or $frequency -eq "Quarterly" -or $frequency -eq "Annual") {
    $monthStep = if ($frequency -eq "Monthly") { 1 } elseif ($frequency -eq "Quarterly") { 3 } else { 12 }
    $nextDate = $anchorDate
    while ($nextDate -lt $rangeStart.Date) {
      $nextDate = $nextDate.AddMonths($monthStep)
    }
    return ($nextDate -ge $rangeStart.Date -and $nextDate -lt $rangeEnd.Date)
  }

  return $false
}

function Get-ProjectionSummary {
  $today = [datetime]::Today
  $recentStart = $today.AddDays(-90)
  $currentPaycheck = Get-CurrentPaycheck
  $recentItems = @($script:Entries | Where-Object {
    $_.Date -ge $recentStart -and $_.Type -in @("Expense", "Bill") -and -not (Test-InternalTransfer $_)
  })
  $weeks = [math]::Max(1, (($today - $recentStart).TotalDays / 7))
  $recentSpend = [decimal](@($recentItems | Measure-Object Amount -Sum).Sum)
  $weeklySpend = $recentSpend / [decimal]$weeks

  $incomeItems = @($script:Entries | Where-Object {
    $_.Date -ge $recentStart -and $_.Type -eq "Income"
  })
  $weeklyIncome = [decimal]0
  if ($currentPaycheck) {
    $weeklyIncome = [decimal]$currentPaycheck.Amount
  } elseif ($incomeItems.Count -eq 1) {
    $weeklyIncome = [decimal]$incomeItems[0].Amount
  } elseif ($incomeItems.Count -gt 1) {
    $firstIncome = [datetime](@($incomeItems | Sort-Object Date | Select-Object -First 1)[0].Date)
    $lastIncome = [datetime](@($incomeItems | Sort-Object Date -Descending | Select-Object -First 1)[0].Date)
    $incomeWeeks = [math]::Max(1, (($lastIncome - $firstIncome).TotalDays / 7) + 1)
    $weeklyIncome = [decimal](@($incomeItems | Measure-Object Amount -Sum).Sum) / [decimal]$incomeWeeks
  }

  $recurringWeekly = [decimal]0
  foreach ($payment in Get-RecurringPayments) {
    $recurringWeekly += ConvertTo-WeeklyAmount ([decimal]$payment.Amount) ([string]$payment.Frequency)
  }

  $requiredWeekly = [decimal]0
  foreach ($row in Get-GoalProgressRows) {
    $goal = $row.Goal
    if ((Get-GoalKind $goal) -eq "Weekly") {
      if (Test-WeeklyGoalActive $goal $today) { $requiredWeekly += Get-GoalWeeklyAmount $goal }
      continue
    }
    $remaining = [decimal]$row.Remaining
    $daysLeft = [math]::Max(1, (([datetime]$goal.ExpectedDate - $today).TotalDays))
    $requiredWeekly += $remaining / ([decimal]$daysLeft / 7)
  }

  return [pscustomobject]@{
    CurrentPaycheck = $currentPaycheck
    CurrentPaycheckAmount = if ($currentPaycheck) { [decimal]$currentPaycheck.Amount } else { [decimal]0 }
    CurrentPaycheckDate = if ($currentPaycheck) { [datetime]$currentPaycheck.Date } else { $null }
    WeeklyIncome = $weeklyIncome
    WeeklySpend = $weeklySpend
    RecurringWeekly = $recurringWeekly
    IncomeBasedAvailable = [math]::Max([decimal]0, $weeklyIncome - $recurringWeekly)
    RequiredSavingsWeekly = $requiredWeekly
    ProjectedSavingsMonthly = $requiredWeekly * [decimal](52 / 12)
  }
}

function Get-CurrentPaycheck {
  $latestDate = @($script:Entries |
    Where-Object { $_.Type -eq "Income" -and [decimal]$_.Amount -gt 0 } |
    Sort-Object Date -Descending |
    Select-Object -First 1)[0]
  if (-not $latestDate) { return $null }

  $date = [datetime]$latestDate.Date
  $items = @($script:Entries | Where-Object { $_.Type -eq "Income" -and ([datetime]$_.Date).Date -eq $date.Date })
  $amount = [decimal](@($items | Measure-Object Amount -Sum).Sum)
  $name = if ($items.Count -eq 1) { [string]$items[0].Name } else { "$($items.Count) income entries" }
  return [pscustomobject]@{
    Date = $date
    Amount = $amount
    Name = $name
  }
}

function Get-EffectiveWeeklyAvailableSavings($projection = $null) {
  if (-not $projection) { $projection = Get-ProjectionSummary }
  if ([decimal]$projection.WeeklyIncome -gt 0) {
    return [decimal]$projection.IncomeBasedAvailable
  }
  return [decimal]$script:WeeklyAvailableSavings
}

function Get-PaycheckDistribution($projection = $null) {
  if (-not $projection) { $projection = Get-ProjectionSummary }
  $paycheck = if ([decimal]$projection.CurrentPaycheckAmount -gt 0) { [decimal]$projection.CurrentPaycheckAmount } else { [decimal]$script:WeeklyAvailableSavings }
  $recurring = [math]::Min($paycheck, [decimal]$projection.RecurringWeekly)
  $everydaySpend = [math]::Min([math]::Max([decimal]0, $paycheck - $recurring), [decimal]$projection.WeeklySpend)
  $availableForSavings = [math]::Max([decimal]0, $paycheck - $recurring - $everydaySpend)
  $plan = Get-AllocationPlan $availableForSavings
  $savings = [math]::Min($availableForSavings, [decimal]$plan.TotalAllocated)
  $spend = [math]::Max([decimal]0, $paycheck - $recurring - $savings)
  $warning = ""
  if ($paycheck -le 0) {
    $warning = "Mark this week's paycheck as Income"
  } elseif ($availableForSavings -lt [decimal]$projection.RequiredSavingsWeekly) {
    $warning = "Savings target short by $(ConvertTo-Money ([decimal]$projection.RequiredSavingsWeekly - $availableForSavings))/wk"
  } elseif (-not [string]::IsNullOrWhiteSpace($plan.Warning)) {
    $warning = $plan.Warning
  }

  return [pscustomobject]@{
    Paycheck = $paycheck
    PaycheckDate = $projection.CurrentPaycheckDate
    Recurring = $recurring
    EverydaySpend = $everydaySpend
    AvailableForSavings = $availableForSavings
    Savings = $savings
    Spend = $spend
    Plan = $plan
    Warning = $warning
  }
}

function Get-MinimumWeeklySavingsPlan([Nullable[datetime]]$asOfDate = $null, [object[]]$goalRows = $null) {
  $effectiveDate = if ($asOfDate.HasValue) { $asOfDate.Value } else { [datetime]::Today }
  if (-not $goalRows) { $goalRows = Get-GoalProgressRows }

  $weeklyRows = @($goalRows |
    Where-Object { (Get-GoalKind $_.Goal) -eq "Weekly" -and (Test-WeeklyGoalActive $_.Goal $effectiveDate) -and (Get-GoalWeeklyAmount $_.Goal) -gt 0 } |
    Sort-Object { Get-GoalSortDate $_.Goal })

  $targetRows = @($goalRows |
    Where-Object { (Get-GoalKind $_.Goal) -ne "Weekly" -and [decimal]$_.Remaining -gt 0 } |
    Sort-Object { [datetime]$_.Goal.ExpectedDate })

  if ($targetRows.Count -eq 0 -and $weeklyRows.Count -eq 0) {
    return [pscustomobject]@{ MinimumWeeklyRate = [decimal]0; Rows = @(); Warning = "" }
  }

  $cumulativeRemaining = [decimal]0
  $minimumRate = [decimal]0
  foreach ($row in $targetRows) {
    $goal = $row.Goal
    $cumulativeRemaining += [decimal]$row.Remaining
    $weeksRemaining = [decimal][math]::Max(1, [math]::Floor((([datetime]$goal.ExpectedDate - $effectiveDate).TotalDays) / 7))
    $rateNeeded = $cumulativeRemaining / $weeksRemaining
    if ($rateNeeded -gt $minimumRate) { $minimumRate = $rateNeeded }
  }

  $rows = New-Object System.Collections.ArrayList
  foreach ($row in $targetRows) {
    $goal = $row.Goal
    $weeksRemaining = [decimal][math]::Max(1, [math]::Floor((([datetime]$goal.ExpectedDate - $effectiveDate).TotalDays) / 7))
    $requiredWeekly = [decimal]$row.Remaining / $weeksRemaining
    [void]$rows.Add([pscustomobject]@{
      GoalId = $goal.Id
      GoalName = $goal.Name
      TargetDate = [datetime]$goal.ExpectedDate
      Remaining = [decimal]$row.Remaining
      RequiredWeekly = $requiredWeekly
      Mode = if ($goal.Mode) { [string]$goal.Mode } else { "Save" }
    })
  }

  $fixedWeekly = [decimal]0
  foreach ($row in $weeklyRows) {
    $goal = $row.Goal
    $weeklyAmount = Get-GoalWeeklyAmount $goal
    $fixedWeekly += $weeklyAmount
    [void]$rows.Add([pscustomobject]@{
      GoalId = $goal.Id
      GoalName = $goal.Name
      TargetDate = if ($goal.IsOngoing) { [datetime]::MaxValue } else { [datetime]$goal.ExpectedDate }
      Remaining = [decimal]0
      RequiredWeekly = $weeklyAmount
      Mode = if ($goal.Mode) { [string]$goal.Mode } else { "Save" }
    })
  }

  return [pscustomobject]@{
    MinimumWeeklyRate = $minimumRate + $fixedWeekly
    Rows = @($rows)
    Warning = ""
  }
}

function Get-MinimumSavingsProjection {
  $goalRows = @(Get-GoalProgressRows | ForEach-Object {
    [pscustomobject]@{ Goal = $_.Goal; Saved = [decimal]$_.Saved; Remaining = [decimal]$_.Remaining }
  })
  $plan = Get-MinimumWeeklySavingsPlan -asOfDate ([datetime]::Today) -goalRows $goalRows
  $weeklyRate = [decimal]$plan.MinimumWeeklyRate
  $latestDue = @($script:Goals | Where-Object { -not $_.IsOngoing } | Sort-Object ExpectedDate -Descending | Select-Object -First 1)[0]
  $maxWeeks = if ($latestDue) { [math]::Max(12, [math]::Ceiling((([datetime]$latestDue.ExpectedDate - [datetime]::Today).TotalDays) / 7)) } else { 12 }
  if (@($script:Goals | Where-Object { (Get-GoalKind $_) -eq "Weekly" -and $_.IsOngoing }).Count -gt 0) {
    $maxWeeks = [math]::Max($maxWeeks, 52)
  }
  $maxWeeks = [math]::Min(104, $maxWeeks)
  $points = New-Object System.Collections.ArrayList

  for ($week = 0; $week -le $maxWeeks; $week++) {
    $date = [datetime]::Today.AddDays($week * 7)
    $remainingBudget = $weeklyRate
    foreach ($goalRow in @($goalRows | Where-Object { (Get-GoalKind $_.Goal) -eq "Weekly" -and (Test-WeeklyGoalActive $_.Goal $date) } | Sort-Object { Get-GoalSortDate $_.Goal })) {
      $allocation = [math]::Min($remainingBudget, (Get-GoalWeeklyAmount $goalRow.Goal))
      if ($allocation -le 0) { continue }
      [void]$points.Add([pscustomobject]@{
        Week = $week
        Date = $date
        GoalId = $goalRow.Goal.Id
        GoalName = $goalRow.Goal.Name
        Allocation = [decimal]$allocation
        TotalAllocated = [decimal]$weeklyRate
      })
      $remainingBudget -= $allocation
    }
    foreach ($goalRow in @($goalRows | Where-Object { (Get-GoalKind $_.Goal) -ne "Weekly" -and [decimal]$_.Remaining -gt 0 } | Sort-Object { [datetime]$_.Goal.ExpectedDate })) {
      if ($remainingBudget -le 0) { break }
      $allocation = [math]::Min([decimal]$goalRow.Remaining, $remainingBudget)
      if ($allocation -le 0) { continue }
      [void]$points.Add([pscustomobject]@{
        Week = $week
        Date = $date
        GoalId = $goalRow.Goal.Id
        GoalName = $goalRow.Goal.Name
        Allocation = [decimal]$allocation
        TotalAllocated = [decimal]$weeklyRate
      })
      $goalRow.Remaining = [math]::Max([decimal]0, [decimal]$goalRow.Remaining - $allocation)
      $remainingBudget -= $allocation
    }
    $hasTargetRemaining = @($goalRows | Where-Object { (Get-GoalKind $_.Goal) -ne "Weekly" -and [decimal]$_.Remaining -gt 0 }).Count -gt 0
    $hasActiveWeekly = @($goalRows | Where-Object { (Get-GoalKind $_.Goal) -eq "Weekly" -and (Test-WeeklyGoalActive $_.Goal $date.AddDays(7)) }).Count -gt 0
    if (-not $hasTargetRemaining -and -not $hasActiveWeekly) { break }
  }

  return [pscustomobject]@{
    MinimumWeeklyRate = $weeklyRate
    Points = @($points)
    Plan = $plan
  }
}

function Get-ProjectedMonthlyGoalSavings([datetime]$monthDate) {
  $monthStart = New-Object datetime ($monthDate.Year, $monthDate.Month, 1)
  $monthEnd = $monthStart.AddMonths(1).AddDays(-1)
  $today = [datetime]::Today
  $total = [decimal]0

  foreach ($row in Get-GoalProgressRows) {
    $goal = $row.Goal
    $remaining = [decimal]$row.Remaining
    if ($remaining -le 0) { continue }

    $dueDate = [datetime]$goal.ExpectedDate
    if ($dueDate -lt $monthStart) { continue }

    $projectionStart = if ($monthStart -lt $today) { $today } else { $monthStart }
    if ($projectionStart -gt $monthEnd) { continue }

    $daysUntilDue = [math]::Max(1, ($dueDate - $today).TotalDays)
    $dailyRequired = $remaining / [decimal]$daysUntilDue
    $projectionEnd = if ($dueDate -lt $monthEnd) { $dueDate } else { $monthEnd }
    $activeDaysThisMonth = [math]::Max(0, ($projectionEnd - $projectionStart).TotalDays + 1)
    $total += $dailyRequired * [decimal]$activeDaysThisMonth
  }

  return $total
}

function Get-ProjectedMonthlyGoalSend([datetime]$monthDate) {
  $monthStart = New-Object datetime ($monthDate.Year, $monthDate.Month, 1)
  $monthEnd = $monthStart.AddMonths(1).AddDays(-1)
  $total = [decimal]0

  foreach ($row in Get-GoalProgressRows) {
    $goal = $row.Goal
    $mode = if ($goal.Mode) { [string]$goal.Mode } else { "Save" }
    if ($mode -ne "Send") { continue }
    $dueDate = [datetime]$goal.ExpectedDate
    if ($dueDate -ge $monthStart -and $dueDate -le $monthEnd) {
      $total += [decimal]$goal.TargetAmount
    }
  }

  return $total
}

function Get-HistoricalSavingsBalance([datetime]$monthDate, [string]$selectedAccount) {
  $monthEnd = (New-Object datetime ($monthDate.Year, $monthDate.Month, 1)).AddMonths(1).AddDays(-1)
  return Get-HistoricalSavingsBalanceAt $monthEnd $selectedAccount
}

function Get-HistoricalSavingsBalanceAt([datetime]$asOfDate, [string]$selectedAccount) {
  $accounts = if ($selectedAccount -and $selectedAccount -ne "All Accounts") {
    @($selectedAccount)
  } else {
    @($script:Goals | ForEach-Object { $_.Account } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
  }

  $total = [decimal]0
  foreach ($account in $accounts) {
    $total += Get-EstimatedAccountBalanceAt $asOfDate $account
  }

  return $total
}

function Get-AccountsForBalanceGraph([string]$selectedAccount) {
  if ($selectedAccount -and $selectedAccount -ne "All Accounts") { return @($selectedAccount) }
  return @(
    $script:Entries | ForEach-Object { $_.Account }
    $script:AccountBalances.Keys
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique
}

function Get-HistoricalAccountBalance([datetime]$monthDate, [string]$account) {
  $monthEnd = (New-Object datetime ($monthDate.Year, $monthDate.Month, 1)).AddMonths(1).AddDays(-1)
  $latestBalanceEntry = @($script:Entries |
    Where-Object {
      $_.Account -eq $account -and
      $null -ne $_.Date -and
      ([datetime]$_.Date) -le $monthEnd -and
      $null -ne $_.Balance -and
      [decimal]$_.Balance -ne 0
    } |
    Sort-Object Date -Descending |
    Select-Object -First 1)[0]

  if ($latestBalanceEntry) { return [decimal]$latestBalanceEntry.Balance }
  return Get-EstimatedAccountBalanceAt $monthEnd $account
}

function Get-ProjectedAccountGoalSavings([datetime]$monthDate, [string]$account) {
  $monthStart = New-Object datetime ($monthDate.Year, $monthDate.Month, 1)
  $monthEnd = $monthStart.AddMonths(1).AddDays(-1)
  $today = [datetime]::Today
  $total = [decimal]0

  foreach ($row in Get-GoalProgressRows) {
    $goal = $row.Goal
    if ($goal.Account -ne $account) { continue }
    $remaining = [decimal]$row.Remaining
    if ($remaining -le 0) { continue }
    $dueDate = [datetime]$goal.ExpectedDate
    if ($dueDate -lt $monthStart) { continue }
    $projectionStart = if ($monthStart -lt $today) { $today } else { $monthStart }
    if ($projectionStart -gt $monthEnd) { continue }
    $daysUntilDue = [math]::Max(1, ($dueDate - $today).TotalDays)
    $dailyRequired = $remaining / [decimal]$daysUntilDue
    $projectionEnd = if ($dueDate -lt $monthEnd) { $dueDate } else { $monthEnd }
    $activeDaysThisMonth = [math]::Max(0, ($projectionEnd - $projectionStart).TotalDays + 1)
    $total += $dailyRequired * [decimal]$activeDaysThisMonth
  }

  return $total
}

function Get-ProjectedAccountGoalSend([datetime]$monthDate, [string]$account) {
  $monthStart = New-Object datetime ($monthDate.Year, $monthDate.Month, 1)
  $monthEnd = $monthStart.AddMonths(1).AddDays(-1)
  $total = [decimal]0

  foreach ($row in Get-GoalProgressRows) {
    $goal = $row.Goal
    if ($goal.Account -ne $account) { continue }
    $mode = if ($goal.Mode) { [string]$goal.Mode } else { "Save" }
    if ($mode -ne "Send") { continue }
    $dueDate = [datetime]$goal.ExpectedDate
    if ($dueDate -ge $monthStart -and $dueDate -le $monthEnd) {
      $total += [decimal]$goal.TargetAmount
    }
  }

  return $total
}

function Get-NiceAxisLimit([double]$value) {
  $abs = [math]::Abs($value)
  if ($abs -lt 100) { return 100 }
  $power = [math]::Pow(10, [math]::Floor([math]::Log10($abs)))
  $scaled = $abs / $power
  if ($scaled -le 1) { $nice = 1 }
  elseif ($scaled -le 2) { $nice = 2 }
  elseif ($scaled -le 5) { $nice = 5 }
  else { $nice = 10 }
  return $nice * $power
}

function Set-ChartAxisScale($chart, [double]$minValue, [double]$maxValue, [int]$xPointCount) {
  if ($maxValue -lt 0) { $maxValue = 0 }
  if ($minValue -gt 0) { $minValue = 0 }

  $range = [math]::Max(1, $maxValue - $minValue)
  $padding = $range * 0.08
  $upper = $maxValue + $padding
  $lower = $minValue - $padding

  if ($upper -le 0) { $upper = [math]::Max(1, $range * 0.08) }
  if ($lower -ge 0) { $lower = -1 * [math]::Max(1, $range * 0.08) }

  $area = $chart.ChartAreas[0]
  $area.AxisY.Minimum = $lower
  $area.AxisY.Maximum = $upper
  $area.AxisY.Interval = [double]::NaN
  $area.AxisX.Interval = [math]::Max(1, [math]::Ceiling($xPointCount / 12))
  $area.RecalculateAxesScale()
}

function Add-ZeroAxisLine($chart) {
  $area = $chart.ChartAreas[0]
  $area.AxisY.StripLines.Clear()
  $zeroLine = New-Object System.Windows.Forms.DataVisualization.Charting.StripLine
  $zeroLine.IntervalOffset = 0
  $zeroLine.StripWidth = 0
  $zeroLine.BorderColor = [Drawing.Color]::FromArgb(60, 48, 40)
  $zeroLine.BorderWidth = 2
  $zeroLine.BorderDashStyle = [System.Windows.Forms.DataVisualization.Charting.ChartDashStyle]::Solid
  [void]$area.AxisY.StripLines.Add($zeroLine)
}

function Save-Entries {
  $payload = [pscustomobject]@{
    entries = @($script:Entries)
    goals = @($script:Goals)
    recurringExclusions = @($script:RecurringExclusions.Keys)
    recurringManual = @($script:RecurringManual)
    allocationHistory = [pscustomobject]$script:AllocationHistory
    weeklyAvailableSavings = $script:WeeklyAvailableSavings
    hiddenBalanceAccounts = @($script:HiddenBalanceAccounts.Keys)
    accountNames = [pscustomobject]$script:AccountNames
    accountBalances = [pscustomobject]$script:AccountBalances
    settings = $script:Settings
  }
  $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $DataPath -Encoding UTF8
}

function New-AutoBackup([string]$reason) {
  if (-not (Test-Path $DataPath)) { return $null }
  $backupDir = Join-Path $AppDir "backups"
  if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
  }
  $safeReason = ([string]$reason) -replace "[^A-Za-z0-9_-]+", "-"
  if ([string]::IsNullOrWhiteSpace($safeReason)) { $safeReason = "backup" }
  $fileName = "auto-$safeReason-$((Get-Date).ToString('yyyyMMdd-HHmmss')).json"
  $backupPath = Join-Path $backupDir $fileName
  Copy-Item -Path $DataPath -Destination $backupPath -Force
  return $backupPath
}

function Load-Entries {
  $script:Entries.Clear()
  $script:Goals.Clear()
  $script:RecurringExclusions = @{}
  $script:RecurringManual.Clear()
  $script:AccountNames = @{}
  $script:AccountBalances = @{}
  $script:AllocationHistory = @{}
  $script:WeeklyAvailableSavings = [decimal]0
  $script:HiddenBalanceAccounts = @{}
  Reset-AppSettings
  if (Test-Path $DataPath) {
    try {
      $json = Get-Content -Path $DataPath -Raw | ConvertFrom-Json
      foreach ($entry in @($json.entries)) {
        [void]$script:Entries.Add([pscustomobject]@{
          Id = [string]$entry.Id
          Type = [string]$entry.Type
          Date = [datetime]$entry.Date
          Name = [string]$entry.Name
          Category = [string]$entry.Category
          Account = [string]$entry.Account
          Frequency = [string]$entry.Frequency
          Amount = [decimal]$entry.Amount
          Goal = [decimal]$entry.Goal
          Note = [string]$entry.Note
          Balance = if ($null -ne $entry.Balance) { [decimal]$entry.Balance } else { [decimal]0 }
          BankCategory = if ($entry.BankCategory) { [string]$entry.BankCategory } else { "" }
          Serial = if ($entry.Serial) { [string]$entry.Serial } else { "" }
          Source = if ($entry.Source) { [string]$entry.Source } else { "" }
          ImportKey = if ($entry.ImportKey) { [string]$entry.ImportKey } else { "" }
        })
      }
      foreach ($goal in @($json.goals)) {
        [void]$script:Goals.Add([pscustomobject]@{
          Id = if ($goal.Id) { [string]$goal.Id } else { New-EntryId }
          Name = [string]$goal.Name
          Account = [string]$goal.Account
          TargetAmount = [decimal]$goal.TargetAmount
          ExpectedDate = if ($goal.ExpectedDate) { [datetime]$goal.ExpectedDate } else { [datetime]::Today }
          Mode = if ($goal.Mode) { [string]$goal.Mode } else { "Save" }
          GoalKind = if ($goal.GoalKind) { [string]$goal.GoalKind } else { "Target" }
          WeeklyAmount = if ($null -ne $goal.WeeklyAmount) { [decimal]$goal.WeeklyAmount } else { [decimal]0 }
          IsOngoing = if ($null -ne $goal.IsOngoing) { [bool]$goal.IsOngoing } else { $false }
          Note = if ($goal.Note) { [string]$goal.Note } else { "" }
        })
      }
      if ($json.accountNames) {
        foreach ($property in $json.accountNames.PSObject.Properties) {
          $script:AccountNames[[string]$property.Name] = [string]$property.Value
        }
      }
      if ($json.settings) {
        if ($json.settings.WeekStartsOn) { $script:Settings.WeekStartsOn = [string]$json.settings.WeekStartsOn }
        if ($json.settings.CurrencyCulture) { $script:Settings.CurrencyCulture = [string]$json.settings.CurrencyCulture }
        if ($json.settings.LeftGraphDefault) { $script:Settings.LeftGraphDefault = [string]$json.settings.LeftGraphDefault }
        if ($json.settings.RightGraphDefault) { $script:Settings.RightGraphDefault = [string]$json.settings.RightGraphDefault }
      }
      foreach ($key in @($json.recurringExclusions)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$key)) {
          $script:RecurringExclusions[[string]$key] = $true
        }
      }
      foreach ($record in @($json.recurringManual)) {
        if ($record.Key) {
          [void]$script:RecurringManual.Add([pscustomobject]@{
            Key = [string]$record.Key
            Name = [string]$record.Name
            Category = if ($record.Category) { [string]$record.Category } else { "" }
            Account = [string]$record.Account
            Amount = [decimal]$record.Amount
            Date = if ($record.Date) { [datetime]$record.Date } else { [datetime]::Today }
            Frequency = if ($record.Frequency) { [string]$record.Frequency } else { "Recurring" }
            Count = if ($record.Count) { [int]$record.Count } else { 0 }
          })
        }
      }
      if ($json.allocationHistory) {
        foreach ($property in $json.allocationHistory.PSObject.Properties) {
          $script:AllocationHistory[[string]$property.Name] = [decimal]$property.Value
        }
      }
      if ($null -ne $json.weeklyAvailableSavings) {
        $script:WeeklyAvailableSavings = [decimal]$json.weeklyAvailableSavings
      }
      foreach ($account in @($json.hiddenBalanceAccounts)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$account)) {
          $script:HiddenBalanceAccounts[[string]$account] = $true
        }
      }
      if ($json.accountBalances) {
        foreach ($property in $json.accountBalances.PSObject.Properties) {
          $balance = $property.Value
          $script:AccountBalances[[string]$property.Name] = [pscustomobject]@{
            Balance = [decimal]$balance.Balance
            Date = [datetime]$balance.Date
            Source = if ($balance.Source) { [string]$balance.Source } else { "Accounts CSV" }
          }
        }
      }
      if ($script:Goals.Count -eq 0) {
        foreach ($entry in @($script:Entries | Where-Object { $_.Type -eq "Saving" -and $_.Goal -gt 0 })) {
          [void]$script:Goals.Add([pscustomobject]@{
            Id = New-EntryId
            Name = $entry.Name
            Account = $entry.Account
            TargetAmount = [decimal]$entry.Goal
            ExpectedDate = $entry.Date.AddMonths(12)
            Mode = "Save"
            GoalKind = "Target"
            WeeklyAmount = [decimal]0
            IsOngoing = $false
            Note = "Migrated from old savings entry goal"
          })
        }
      }
      return
    } catch {
      [System.Windows.Forms.MessageBox]::Show("The saved tracker data could not be loaded. A fresh file will be started.", "Tracker", "OK", "Warning") | Out-Null
    }
  }

  [void]$script:Entries.Add([pscustomobject]@{
    Id = New-EntryId; Type = "Expense"; Date = [datetime]::Today; Name = "Example groceries"; Category = "Groceries"; Account = "Debit"; Frequency = ""; Amount = [decimal]120.50; Goal = [decimal]0; Note = ""; Balance = [decimal]0; BankCategory = ""; Serial = ""; Source = ""; ImportKey = ""
  })
  [void]$script:Entries.Add([pscustomobject]@{
    Id = New-EntryId; Type = "Bill"; Date = [datetime]::Today; Name = "Example rent"; Category = "Rent / Mortgage"; Account = "Bank Transfer"; Frequency = "Monthly"; Amount = [decimal]2200; Goal = [decimal]0; Note = ""; Balance = [decimal]0; BankCategory = ""; Serial = ""; Source = ""; ImportKey = ""
  })
  [void]$script:Entries.Add([pscustomobject]@{
    Id = New-EntryId; Type = "Saving"; Date = [datetime]::Today; Name = "Emergency fund"; Category = "Emergency Fund"; Account = "Savings"; Frequency = ""; Amount = [decimal]250; Goal = [decimal]5000; Note = ""; Balance = [decimal]0; BankCategory = ""; Serial = ""; Source = ""; ImportKey = ""
  })
  [void]$script:Goals.Add([pscustomobject]@{
    Id = New-EntryId; Name = "Emergency fund"; Account = "Savings"; TargetAmount = [decimal]5000; ExpectedDate = [datetime]::Today.AddMonths(12); Mode = "Save"; GoalKind = "Target"; WeeklyAmount = [decimal]0; IsOngoing = $false; Note = "Starter savings goal"
  })
  Save-Entries
}

function Get-FilteredEntries {
  $type = $viewCombo.SelectedItem
  $search = $searchBox.Text.Trim().ToLowerInvariant()
  $month = $monthCombo.SelectedItem
  $account = Get-AccountRawValue ([string]$accountFilterCombo.SelectedItem)

  $items = @($script:Entries | Where-Object {
    (($type -eq "All") -or ($_.Type -eq $type)) -and
    (($month -eq "All Months") -or ($_.Date.ToString("yyyy-MM") -eq $month)) -and
    (($account -eq "All Accounts") -or ($_.Account -eq $account)) -and
    (($search.Length -eq 0) -or (
      $_.Name.ToLowerInvariant().Contains($search) -or
      $_.Category.ToLowerInvariant().Contains($search) -or
      $_.Account.ToLowerInvariant().Contains($search) -or
      $_.Type.ToLowerInvariant().Contains($search) -or
      $_.Note.ToLowerInvariant().Contains($search)
    ))
  })

  switch ($sortCombo.SelectedItem) {
    "Oldest first" { return @($items | Sort-Object Date) }
    "Highest amount" { return @($items | Sort-Object Amount -Descending) }
    "Lowest amount" { return @($items | Sort-Object Amount) }
    default { return @($items | Sort-Object Date -Descending) }
  }
}

function Get-SummaryEntries {
  $month = $monthCombo.SelectedItem
  $account = Get-AccountRawValue ([string]$accountFilterCombo.SelectedItem)
  return @($script:Entries | Where-Object {
    (($month -eq "All Months") -or ($_.Date.ToString("yyyy-MM") -eq $month)) -and
    (($account -eq "All Accounts") -or ($_.Account -eq $account))
  })
}

function Get-CurrentBudgetWeekRange {
  $today = [datetime]::Today
  $weekStartsOn = if ($script:Settings -and $script:Settings.WeekStartsOn) { [string]$script:Settings.WeekStartsOn } else { "Monday" }
  $startDay = switch ($weekStartsOn) {
    "Sunday" { [int][DayOfWeek]::Sunday }
    default { [int][DayOfWeek]::Monday }
  }
  $daysSinceStart = (([int]$today.DayOfWeek - $startDay + 7) % 7)
  $start = $today.AddDays(-1 * $daysSinceStart).Date
  return [pscustomobject]@{
    Start = $start
    End = $start.AddDays(7)
    Label = "$($start.ToString('dd/MM/yyyy')) - $($start.AddDays(6).ToString('dd/MM/yyyy'))"
  }
}

function Get-ThisWeekBudgetSummary([string]$selectedAccount = "All Accounts") {
  $week = Get-CurrentBudgetWeekRange
  $items = @($script:Entries | Where-Object {
    $entryDate = if ($null -ne $_.Date) { [datetime]$_.Date } else { [datetime]::MinValue }
    $entryDate -ge [datetime]$week.Start -and
    $entryDate -lt [datetime]$week.End -and
    (($selectedAccount -eq "All Accounts") -or ($_.Account -eq $selectedAccount))
  })

  $paycheck = [decimal](@($items | Where-Object { $_.Type -eq "Income" } | Measure-Object Amount -Sum).Sum)

  $goalRows = Get-GoalProgressRows
  if ($selectedAccount -ne "All Accounts") {
    $goalRows = @($goalRows | Where-Object { [string]$_.Goal.Account -eq $selectedAccount })
  }
  $minimumPlan = Get-MinimumWeeklySavingsPlan -goalRows $goalRows
  $savings = [decimal]$minimumPlan.MinimumWeeklyRate
  $spend = [decimal](@($items | Where-Object { $_.Type -eq "Expense" -and -not (Test-InternalTransfer $_) } | Measure-Object Amount -Sum).Sum)
  $billTransactions = [decimal](@($items | Where-Object { $_.Type -eq "Bill" -and -not (Test-InternalTransfer $_) } | Measure-Object Amount -Sum).Sum)

  $recurringBills = [decimal]0
  foreach ($payment in Get-RecurringPayments) {
    if ($selectedAccount -ne "All Accounts" -and [string]$payment.Account -ne $selectedAccount) { continue }
    if (Test-RecurringPaymentDueInRange $payment ([datetime]$week.Start) ([datetime]$week.End)) {
      $recurringBills += [decimal]$payment.Amount
    }
  }
  $bills = $billTransactions + $recurringBills
  $remaining = $paycheck - $savings - $spend - $bills

  return [pscustomobject]@{
    Week = $week
    Paycheck = $paycheck
    Savings = $savings
    Spend = $spend
    Bills = $bills
    Remaining = $remaining
  }
}

function Get-ThisWeekBudgetRows([string]$selectedAccount = "All Accounts") {
  $budget = Get-ThisWeekBudgetSummary $selectedAccount

  return @(
    [pscustomobject]@{ Item = "Week"; Amount = ""; Detail = [string]$budget.Week.Label }
    [pscustomobject]@{ Item = "Paycheck"; Amount = ConvertTo-Money ([decimal]$budget.Paycheck); Detail = "Income marked inside this Monday budget week" }
    [pscustomobject]@{ Item = "Savings"; Amount = ConvertTo-Money ([decimal]$budget.Savings); Detail = "Minimum weekly saving to hit active goals" }
    [pscustomobject]@{ Item = "Spend"; Amount = ConvertTo-Money ([decimal]$budget.Spend); Detail = "Expenses, excluding transfers" }
    [pscustomobject]@{ Item = "Bills"; Amount = ConvertTo-Money ([decimal]$budget.Bills); Detail = "Recurring payments due this week plus bill entries" }
    [pscustomobject]@{ Item = "Remaining"; Amount = ConvertTo-Money ([decimal]$budget.Remaining); Detail = "Paycheck minus savings, spend, and bills" }
  )
}

function Get-SelectedMonthRange {
  if (-not $monthCombo -or -not $monthCombo.SelectedItem) { return $null }
  $month = [string]$monthCombo.SelectedItem
  if ($month -eq "All Months") { return $null }
  $start = [datetime]::MinValue
  if (-not [datetime]::TryParseExact($month, "yyyy-MM", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$start)) {
    return $null
  }
  $end = $start.AddMonths(1).AddTicks(-1)
  return [pscustomobject]@{ Start = $start; End = $end; Label = $start.ToString("MMMM yyyy") }
}

function Get-ChartBuckets([int]$futureMonths = 0) {
  $selectedRange = Get-SelectedMonthRange
  $buckets = New-Object System.Collections.ArrayList
  if ($selectedRange) {
    $days = [datetime]::DaysInMonth($selectedRange.Start.Year, $selectedRange.Start.Month)
    for ($day = 1; $day -le $days; $day++) {
      $start = New-Object datetime ($selectedRange.Start.Year, $selectedRange.Start.Month, $day)
      [void]$buckets.Add([pscustomobject]@{
        Index = $day - 1
        Start = $start
        End = $start.AddDays(1).AddTicks(-1)
        Label = $start.ToString("dd")
        IsFuture = $start.Date -gt [datetime]::Today
      })
    }
    return @($buckets)
  }

  for ($i = -11; $i -le $futureMonths; $i++) {
    $start = (Get-Date -Day 1).AddMonths($i)
    [void]$buckets.Add([pscustomobject]@{
      Index = $i + 11
      Start = $start
      End = $start.AddMonths(1).AddTicks(-1)
      Label = $start.ToString("MMM")
      IsFuture = $i -gt 0
    })
  }
  return @($buckets)
}

function Get-ChartScopeLabel {
  $selectedRange = Get-SelectedMonthRange
  if ($selectedRange) { return [string]$selectedRange.Label }
  return "All Months"
}

function Refresh-Categories {
  $current = $categoryCombo.SelectedItem
  $categoryCombo.Items.Clear()
  foreach ($category in $Categories[$typeCombo.SelectedItem]) {
    [void]$categoryCombo.Items.Add($category)
  }
  if ($typeCombo.SelectedItem -eq "Saving") {
    foreach ($goalName in @($script:Goals | ForEach-Object { $_.Name } | Where-Object { $_ } | Sort-Object -Unique)) {
      if (-not $categoryCombo.Items.Contains($goalName)) {
        [void]$categoryCombo.Items.Add($goalName)
      }
    }
  }
  if ($current -and $categoryCombo.Items.Contains($current)) {
    $categoryCombo.SelectedItem = $current
  } elseif ($categoryCombo.Items.Count -gt 0) {
    $categoryCombo.SelectedIndex = 0
  }
}

function Refresh-EntryAccounts([string]$preferredAccount = $null) {
  if (-not $accountCombo) { return }
  $currentRaw = if ($preferredAccount) { $preferredAccount } else { Get-EntryAccountRawValue ([string]$accountCombo.SelectedItem) }
  $accountCombo.Items.Clear()
  $script:EntryAccountMap = @{}

  $accounts = @(Get-AllKnownAccounts)
  if ($currentRaw -and $currentRaw -ne $NewAccountOption -and $accounts -notcontains $currentRaw) {
    $accounts += $currentRaw
  }

  foreach ($account in @($accounts | Sort-Object -Unique)) {
    $display = Get-AccountDisplayName $account
    $script:EntryAccountMap[$display] = $account
    [void]$accountCombo.Items.Add($display)
  }
  [void]$accountCombo.Items.Add($NewAccountOption)

  $displayCurrent = if ($currentRaw -and $currentRaw -ne $NewAccountOption) { Get-AccountDisplayName $currentRaw } else { $null }
  if ($displayCurrent -and $accountCombo.Items.Contains($displayCurrent)) {
    $accountCombo.SelectedItem = $displayCurrent
  } elseif ($accountCombo.Items.Count -gt 1) {
    $accountCombo.SelectedIndex = 0
  } else {
    $accountCombo.SelectedItem = $NewAccountOption
  }
}

function Reset-Form {
  $script:EditingId = $null
  $typeCombo.SelectedItem = "Expense"
  Refresh-Categories
  Refresh-EntryAccounts
  $datePicker.Value = [datetime]::Today
  $nameBox.Text = ""
  $amountBox.Value = 0
  $noteBox.Text = ""
  $saveButton.Text = "Add Entry"
}

function Show-EntryPanel {
  Reset-Form
  $inputPanel.Visible = $true
  $inputPanel.BringToFront()
}

function Refresh-Months {
  $current = $monthCombo.SelectedItem
  $monthCombo.Items.Clear()
  [void]$monthCombo.Items.Add("All Months")
  foreach ($month in @($script:Entries | ForEach-Object { $_.Date.ToString("yyyy-MM") } | Sort-Object -Unique -Descending)) {
    [void]$monthCombo.Items.Add($month)
  }
  if ($current -and $monthCombo.Items.Contains($current)) {
    $monthCombo.SelectedItem = $current
  } else {
    $monthCombo.SelectedItem = "All Months"
  }
}

function Refresh-Accounts {
  $current = $accountFilterCombo.SelectedItem
  $currentRaw = Get-AccountRawValue ([string]$current)
  $accountFilterCombo.Items.Clear()
  $script:AccountFilterMap = @{}
  [void]$accountFilterCombo.Items.Add("All Accounts")
  $accounts = @(
    $script:Entries | ForEach-Object { $_.Account }
    $script:Goals | ForEach-Object { $_.Account }
    $script:AccountBalances.Keys
  ) | Where-Object { $_ } | Sort-Object -Unique
  foreach ($account in $accounts) {
    $display = Get-AccountDisplayName $account
    $script:AccountFilterMap[$display] = $account
    [void]$accountFilterCombo.Items.Add($display)
  }
  $displayCurrent = if ($currentRaw -and $currentRaw -ne "All Accounts") { Get-AccountDisplayName $currentRaw } else { "All Accounts" }
  if ($displayCurrent -and $accountFilterCombo.Items.Contains($displayCurrent)) {
    $accountFilterCombo.SelectedItem = $displayCurrent
  } else {
    $accountFilterCombo.SelectedItem = "All Accounts"
  }
}

function Refresh-Summary {
  $selectedAccount = if ($accountFilterCombo -and $accountFilterCombo.SelectedItem) { Get-AccountRawValue ([string]$accountFilterCombo.SelectedItem) } else { "All Accounts" }
  $budget = Get-ThisWeekBudgetSummary $selectedAccount
  $remainingBudget = [decimal]$budget.Remaining

  $remainingBudgetValue.Text = ConvertTo-Money $remainingBudget
  $remainingBudgetValue.ForeColor = if ($remainingBudget -lt 0) { [Drawing.Color]::FromArgb(180, 35, 24) } else { [Drawing.Color]::FromArgb(32, 128, 79) }
  $savedBalanceValue.Text = ConvertTo-Money ([decimal]$budget.Savings)
  $billValue.Text = ConvertTo-Money ([decimal]$budget.Bills)
  $progressValue.Text = ConvertTo-Money ([decimal]$budget.Paycheck)
  $minimumWeeklyValue.Text = ConvertTo-Money ([decimal]$budget.Spend)
}

function Refresh-Chart {
  $script:ChartProjectionCache = Get-ProjectionSummary
  $script:ChartDistributionCache = Get-PaycheckDistribution $script:ChartProjectionCache
  try {
    if ($chart) {
      Render-Chart $chart $chartDataTable $graphModeCombo $chartTitleLabel $projectionSummaryLabel
    }
    if ($chart2) {
      Render-Chart $chart2 $chartDataTable2 $graphModeCombo2 $chartTitleLabel2 $projectionSummaryLabel2
    }
  } finally {
    $script:ChartProjectionCache = $null
    $script:ChartDistributionCache = $null
  }
}

function Render-BudgetDataTable($dataTable, [string]$selectedAccount) {
  if (-not $dataTable) { return }
  $dataTable.Rows.Clear()
  foreach ($row in Get-ThisWeekBudgetRows $selectedAccount) {
    $rowIndex = $dataTable.Rows.Add()
    $gridRow = $dataTable.Rows[$rowIndex]
    $gridRow.Cells["BudgetItem"].Value = $row.Item
    $gridRow.Cells["BudgetAmount"].Value = $row.Amount
    $gridRow.Cells["BudgetDetail"].Value = $row.Detail
    if ($row.Item -eq "Remaining" -and ([string]$row.Amount).StartsWith("-")) {
      $gridRow.DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(180, 35, 24)
    }
  }
}

function Render-Chart($chart, $dataTable, $graphModeCombo, $chartTitleLabel, $projectionSummaryLabel) {
  $chart.Series.Clear()
  $chart.Titles.Clear()
  $graphMode = if ($graphModeCombo -and $graphModeCombo.SelectedItem) { [string]$graphModeCombo.SelectedItem } else { "Savings Projection" }
  $selectedAccount = if ($accountFilterCombo -and $accountFilterCombo.SelectedItem) { Get-AccountRawValue ([string]$accountFilterCombo.SelectedItem) } else { "All Accounts" }
  if ($graphMode -eq "Data Table") {
    if ($chartTitleLabel) { $chartTitleLabel.Text = "Data Table" }
    if ($chart) { $chart.Visible = $false }
    if ($dataTable) {
      $dataTable.Visible = $true
      Render-BudgetDataTable $dataTable $selectedAccount
      $dataTable.BringToFront()
    }
    return
  }
  if ($chart) { $chart.Visible = $true }
  if ($dataTable) { $dataTable.Visible = $false }

  $projection = if ($script:ChartProjectionCache) { $script:ChartProjectionCache } else { Get-ProjectionSummary }
  $distribution = if ($script:ChartDistributionCache) { $script:ChartDistributionCache } else { Get-PaycheckDistribution $projection }
  $effectiveWeeklySavings = [decimal]$distribution.AvailableForSavings
  $minimumProjection = if ($graphMode -eq "Savings Projection") { Get-MinimumSavingsProjection } else { $null }
  $minimumWeeklyRate = if ($minimumProjection) { [decimal]$minimumProjection.MinimumWeeklyRate } else { [decimal]0 }
  $hasAllocationProjection = ($graphMode -eq "Savings Projection" -and $minimumWeeklyRate -gt 0 -and $script:Goals.Count -gt 0)
  if ($hasAllocationProjection) {
    if ($chartTitleLabel) { $chartTitleLabel.Text = "Savings Projection" }
    $chartTitle = New-Object System.Windows.Forms.DataVisualization.Charting.Title
    $chartTitle.Text = "Minimum Weekly Savings Projection - $(Get-ChartScopeLabel)"
    $chartTitle.Font = New-Object Drawing.Font("Segoe UI", 11, [Drawing.FontStyle]::Bold)
    $chartTitle.ForeColor = [Drawing.Color]::FromArgb(33, 26, 22)
    [void]$chart.Titles.Add($chartTitle)

    $selectedRange = Get-SelectedMonthRange
    $points = @($minimumProjection.Points)
    if ($selectedRange) {
      $points = @($points | Where-Object {
        [datetime]$_.Date -ge [datetime]$selectedRange.Start -and
        [datetime]$_.Date -le [datetime]$selectedRange.End
      })
    }
    $goalSeriesRows = @($points |
      Group-Object GoalId |
      ForEach-Object { $_.Group | Select-Object -First 1 } |
      Sort-Object GoalName)
    $palette = @(
      [Drawing.Color]::FromArgb(49, 92, 114),
      [Drawing.Color]::FromArgb(47, 133, 90),
      [Drawing.Color]::FromArgb(180, 35, 24),
      [Drawing.Color]::FromArgb(136, 92, 42),
      [Drawing.Color]::FromArgb(112, 78, 132),
      [Drawing.Color]::FromArgb(54, 126, 151)
    )

    $seriesIndex = 0
    foreach ($goalRow in $goalSeriesRows) {
      $series = New-Object System.Windows.Forms.DataVisualization.Charting.Series ([string]$goalRow.GoalId)
      $series.LegendText = [string]$goalRow.GoalName
      $series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
      $series.BorderWidth = 3
      $series.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::Circle
      $series.MarkerSize = 6
      $series.Color = $palette[$seriesIndex % $palette.Count]
      [void]$chart.Series.Add($series)
      $seriesIndex++
    }

    $totalSeries = New-Object System.Windows.Forms.DataVisualization.Charting.Series "Total weekly savings"
    $totalSeries.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
    $totalSeries.BorderWidth = 2
    $totalSeries.Color = [Drawing.Color]::FromArgb(79, 68, 58)
    $totalSeries.BorderDashStyle = [System.Windows.Forms.DataVisualization.Charting.ChartDashStyle]::Dash
    $totalSeries.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::None
    [void]$chart.Series.Add($totalSeries)

    $allValues = New-Object System.Collections.ArrayList
    $weeks = @($points | Select-Object Week, Date -Unique | Sort-Object Week)
    if ($weeks.Count -eq 0 -and -not $selectedRange) {
      $weeks = @(0..11 | ForEach-Object { [pscustomobject]@{ Week = $_; Date = [datetime]::Today.AddDays($_ * 7) } })
    }
    foreach ($week in $weeks) {
      $label = ([datetime]$week.Date).ToString("dd/MM")
      foreach ($goalRow in $goalSeriesRows) {
        $seriesName = [string]$goalRow.GoalId
        $allocationPoint = @($points | Where-Object { $_.Week -eq $week.Week -and $_.GoalId -eq $goalRow.GoalId } | Select-Object -First 1)[0]
        $value = if ($allocationPoint) { [decimal]$allocationPoint.Allocation } else { [decimal]0 }
        $point = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
        $point.SetValueXY([int]$week.Week, [double]$value)
        $point.AxisLabel = $label
        $targetSeries = $chart.Series.FindByName($seriesName)
        if ($targetSeries) { [void]$targetSeries.Points.Add($point) }
        [void]$allValues.Add([double]$value)
      }
      $totalPoint = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
      $weekTotal = [decimal](@($points | Where-Object { $_.Week -eq $week.Week } | Measure-Object Allocation -Sum).Sum)
      if ($weekTotal -le 0 -and $goalSeriesRows.Count -gt 0) { $weekTotal = [decimal]$minimumWeeklyRate }
      $totalPoint.SetValueXY([int]$week.Week, [double]$weekTotal)
      $totalPoint.AxisLabel = $label
      $totalWeeklySeries = $chart.Series.FindByName("Total weekly savings")
      if ($totalWeeklySeries) { [void]$totalWeeklySeries.Points.Add($totalPoint) }
      [void]$allValues.Add([double]$weekTotal)
    }

    $maxValue = [double]$minimumWeeklyRate
    foreach ($value in $allValues) {
      if ($value -gt $maxValue) { $maxValue = $value }
    }
    Set-ChartAxisScale $chart 0 $maxValue $weeks.Count
    Add-ZeroAxisLine $chart
    $statusText = if ($effectiveWeeklySavings -lt $minimumWeeklyRate) { "Short by $(ConvertTo-Money ($minimumWeeklyRate - $effectiveWeeklySavings))/wk" } else { "Available covers target" }
    $projectionSummaryLabel.Text = "Minimum needed/wk: $(ConvertTo-Money $minimumWeeklyRate)    Available/wk: $(ConvertTo-Money $effectiveWeeklySavings)    $statusText"
    return
  }

  if ($chartTitleLabel) { $chartTitleLabel.Text = $graphMode }
  $isSavingsIncomeSpend = ($graphMode -eq "Income vs Spend" -and (Test-SavingsAccount $selectedAccount))
  $isCreditCardIncomeSpend = ($graphMode -eq "Income vs Spend" -and (Test-CreditCardAccount $selectedAccount))
  $scopeLabel = Get-ChartScopeLabel
  $titleText = if ($selectedAccount -eq "All Accounts") { "$graphMode - All Accounts - $scopeLabel" } else { "$graphMode - $(Get-AccountDisplayName $selectedAccount) - $scopeLabel" }
  $chartTitle = New-Object System.Windows.Forms.DataVisualization.Charting.Title
  $chartTitle.Text = $titleText
  $chartTitle.Font = New-Object Drawing.Font("Segoe UI", 11, [Drawing.FontStyle]::Bold)
  $chartTitle.ForeColor = [Drawing.Color]::FromArgb(33, 26, 22)
  [void]$chart.Titles.Add($chartTitle)
  if ($graphMode -eq "Savings Goals") {
    $savedSeries = New-Object System.Windows.Forms.DataVisualization.Charting.Series "Saved balance"
    $savedSeries.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
    $savedSeries.BorderWidth = 3
    $savedSeries.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::Circle
    $savedSeries.MarkerSize = 7
    $savedSeries.Color = [Drawing.Color]::FromArgb(47, 133, 90)
    [void]$chart.Series.Add($savedSeries)

    $projectedSeries = New-Object System.Windows.Forms.DataVisualization.Charting.Series "Projected balance"
    $projectedSeries.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
    $projectedSeries.BorderWidth = 3
    $projectedSeries.BorderDashStyle = [System.Windows.Forms.DataVisualization.Charting.ChartDashStyle]::Dash
    $projectedSeries.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::Diamond
    $projectedSeries.MarkerSize = 7
    $projectedSeries.Color = [Drawing.Color]::FromArgb(136, 92, 42)
    [void]$chart.Series.Add($projectedSeries)

    $goalRows = @(Get-GoalProgressRows)
    $currentSaved = [decimal](@($goalRows | Measure-Object Saved -Sum).Sum)
    $goalTarget = [decimal](@($script:Goals | Measure-Object TargetAmount -Sum).Sum)
    $projectedSaved = $currentSaved
    $allValues = New-Object System.Collections.ArrayList
    [void]$allValues.Add([double]$currentSaved)
    [void]$allValues.Add([double]$goalTarget)

    $goalBuckets = Get-ChartBuckets 6
    foreach ($bucket in $goalBuckets) {
      $historicalSaved = Get-HistoricalSavingsBalanceAt ([datetime]$bucket.End) $selectedAccount

      $savedPoint = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
      $savedPoint.SetValueXY([int]$bucket.Index, [double]$historicalSaved)
      $savedPoint.AxisLabel = [string]$bucket.Label
      if ($bucket.IsFuture -or $historicalSaved -eq 0) { $savedPoint.IsEmpty = $true } else { [void]$allValues.Add([double]$historicalSaved) }
      [void]$savedSeries.Points.Add($savedPoint)

      $projectionPoint = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
      if (([datetime]$bucket.End).Date -lt [datetime]::Today) {
        $projectionPoint.SetValueXY([int]$bucket.Index, [double]$currentSaved)
        $projectionPoint.IsEmpty = $true
      } else {
        if ((Get-SelectedMonthRange)) {
          $weeklyNeed = [decimal](Get-MinimumWeeklySavingsPlan).MinimumWeeklyRate
          $projectedSaved = [math]::Min($goalTarget, $projectedSaved + ($weeklyNeed / [decimal]7))
          foreach ($row in Get-GoalProgressRows) {
            $goal = $row.Goal
            $mode = if ($goal.Mode) { [string]$goal.Mode } else { "Save" }
            if ($mode -eq "Send" -and ([datetime]$goal.ExpectedDate).Date -eq ([datetime]$bucket.Start).Date) {
              $projectedSaved = [math]::Max([decimal]0, $projectedSaved - [decimal]$goal.TargetAmount)
            }
          }
        } else {
          $monthDate = [datetime]$bucket.Start
          $monthlyNeed = Get-ProjectedMonthlyGoalSavings $monthDate
          $monthlySend = Get-ProjectedMonthlyGoalSend $monthDate
          $projectedSaved = [math]::Min($goalTarget, $projectedSaved + [decimal]$monthlyNeed)
          $projectedSaved = [math]::Max([decimal]0, $projectedSaved - [decimal]$monthlySend)
        }
        $projectionPoint.SetValueXY([int]$bucket.Index, [double]$projectedSaved)
        [void]$allValues.Add([double]$projectedSaved)
      }
      $projectionPoint.AxisLabel = [string]$bucket.Label
      [void]$projectedSeries.Points.Add($projectionPoint)

    }

    $maxValue = 0
    foreach ($value in $allValues) {
      if ($value -gt $maxValue) { $maxValue = $value }
    }
    Set-ChartAxisScale $chart 0 $maxValue $goalBuckets.Count
    Add-ZeroAxisLine $chart
    $projectionSummaryLabel.Text = "Saved balance: $(ConvertTo-Money $currentSaved)    Goal target: $(ConvertTo-Money $goalTarget)"
    return
  }
  if ($graphMode -eq "Balances") {
    $palette = @(
      [Drawing.Color]::FromArgb(49, 92, 114),
      [Drawing.Color]::FromArgb(47, 133, 90),
      [Drawing.Color]::FromArgb(180, 35, 24),
      [Drawing.Color]::FromArgb(136, 92, 42),
      [Drawing.Color]::FromArgb(112, 78, 132),
      [Drawing.Color]::FromArgb(54, 126, 151)
    )
    $accounts = @(Get-AccountsForBalanceGraph $selectedAccount)
    $seriesIndex = 0
    foreach ($account in $accounts) {
      $seriesName = [string]$account
      $series = New-Object System.Windows.Forms.DataVisualization.Charting.Series $seriesName
      $series.LegendText = Get-AccountDisplayName $account
      $series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
      $series.BorderWidth = 3
      $series.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::Circle
      $series.MarkerSize = 6
      $series.Color = $palette[$seriesIndex % $palette.Count]
      [void]$chart.Series.Add($series)
      $seriesIndex++
    }

    $hasSingleAccountGoalProjection = ($selectedAccount -and $selectedAccount -ne "All Accounts" -and @($script:Goals | Where-Object { $_.Account -eq $selectedAccount }).Count -gt 0)
    $projectedBalanceSeries = $null
    if ($hasSingleAccountGoalProjection) {
      $projectedBalanceSeries = New-Object System.Windows.Forms.DataVisualization.Charting.Series "Projected balance"
      $projectedBalanceSeries.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
      $projectedBalanceSeries.BorderWidth = 3
      $projectedBalanceSeries.BorderDashStyle = [System.Windows.Forms.DataVisualization.Charting.ChartDashStyle]::Dash
      $projectedBalanceSeries.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::Diamond
      $projectedBalanceSeries.MarkerSize = 6
      $projectedBalanceSeries.Color = [Drawing.Color]::FromArgb(136, 92, 42)
      [void]$chart.Series.Add($projectedBalanceSeries)
    }

    $allValues = New-Object System.Collections.ArrayList
    $projectedBalance = if ($hasSingleAccountGoalProjection) { Get-HistoricalAccountBalance ([datetime]::Today) $selectedAccount } else { [decimal]0 }
    $balanceBuckets = Get-ChartBuckets 0
    $balanceDataRanges = Get-AccountBalanceDataRanges $accounts
    $visibleBalanceSeries = @{}
    foreach ($bucket in $balanceBuckets) {
      foreach ($account in $accounts) {
        $balance = Get-EstimatedAccountBalanceAt ([datetime]$bucket.End) $account
        $point = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
        $point.SetValueXY([int]$bucket.Index, [double]$balance)
        $point.AxisLabel = [string]$bucket.Label
        $range = if ($balanceDataRanges.ContainsKey($account)) { $balanceDataRanges[$account] } else { $null }
        $hasVisibleData = $range -and ([datetime]$bucket.End).Date -ge ([datetime]$range.First).Date -and ([datetime]$bucket.Start).Date -le ([datetime]$range.Last).Date
        if (-not $hasVisibleData) {
          $point.IsEmpty = $true
        } else {
          [void]$allValues.Add([double]$balance)
          $visibleBalanceSeries[[string]$account] = $true
        }
        $targetSeries = $chart.Series.FindByName([string]$account)
        if ($targetSeries) { [void]$targetSeries.Points.Add($point) }
      }
    }
    foreach ($account in @($accounts)) {
      if (-not $visibleBalanceSeries.ContainsKey([string]$account)) {
        $seriesToRemove = $chart.Series.FindByName([string]$account)
        if ($seriesToRemove) { $chart.Series.Remove($seriesToRemove) }
      }
    }
    if ($hasSingleAccountGoalProjection -and $projectedBalanceSeries) {
      $projectionBuckets = Get-ChartBuckets 6
      foreach ($bucket in $projectionBuckets) {
        if (([datetime]$bucket.End).Date -lt [datetime]::Today) { continue }
        if (([datetime]$bucket.Start).Date -le [datetime]::Today -and ([datetime]$bucket.End).Date -ge [datetime]::Today) {
          $projectedBalance = Get-EstimatedAccountBalanceAt ([datetime]::Today) $selectedAccount
        } else {
          if ((Get-SelectedMonthRange)) {
            $projectedBalance += ([decimal](Get-MinimumWeeklySavingsPlan).MinimumWeeklyRate / [decimal]7)
          } else {
            $projectedBalance += Get-ProjectedAccountGoalSavings ([datetime]$bucket.Start) $selectedAccount
          }
        }
        if ((Get-SelectedMonthRange)) {
          foreach ($row in Get-GoalProgressRows) {
            $goal = $row.Goal
            $mode = if ($goal.Mode) { [string]$goal.Mode } else { "Save" }
            if ($goal.Account -eq $selectedAccount -and $mode -eq "Send" -and ([datetime]$goal.ExpectedDate).Date -eq ([datetime]$bucket.Start).Date) {
              $projectedBalance -= [decimal]$goal.TargetAmount
            }
          }
        } else {
          $projectedBalance -= Get-ProjectedAccountGoalSend ([datetime]$bucket.Start) $selectedAccount
        }
        $projectedBalance = [math]::Max([decimal]0, $projectedBalance)
        $point = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
        $point.SetValueXY([int]$bucket.Index, [double]$projectedBalance)
        $point.AxisLabel = [string]$bucket.Label
        [void]$projectedBalanceSeries.Points.Add($point)
        [void]$allValues.Add([double]$projectedBalance)
      }
    }

    $maxValue = 0
    $minValue = 0
    foreach ($value in $allValues) {
      if ($value -gt $maxValue) { $maxValue = $value }
      if ($value -lt $minValue) { $minValue = $value }
    }
    Set-ChartAxisScale $chart $minValue $maxValue $balanceBuckets.Count
    Add-ZeroAxisLine $chart
    $projectionSummaryLabel.Text = if ($selectedAccount -eq "All Accounts") { "Balances over time for all accounts" } else { "Balance over time for $(Get-AccountDisplayName $selectedAccount)" }
    return
  }
  $seriesNames = switch ($graphMode) {
    "Income vs Spend" { if ($isSavingsIncomeSpend) { @("Credit + Interest", "Payments", "Net") } else { @("Income", "Out", "Net") } }
    default { @("Out", "Saved", "Net", "Projected") }
  }
  foreach ($seriesName in $seriesNames) {
    $series = New-Object System.Windows.Forms.DataVisualization.Charting.Series $seriesName
    $series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
    $series.BorderWidth = 3
    $series.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::Circle
    $series.MarkerSize = 7
    if ($seriesName -eq "Out") { $series.Color = [Drawing.Color]::FromArgb(180, 35, 24) }
    if ($seriesName -eq "Payments") { $series.Color = [Drawing.Color]::FromArgb(180, 35, 24) }
    if ($seriesName -eq "Income") { $series.Color = [Drawing.Color]::FromArgb(47, 133, 90) }
    if ($seriesName -eq "Credit + Interest") { $series.Color = [Drawing.Color]::FromArgb(47, 133, 90) }
    if ($seriesName -eq "Saved") { $series.Color = [Drawing.Color]::FromArgb(47, 133, 90) }
    if ($seriesName -eq "Net") { $series.Color = [Drawing.Color]::FromArgb(49, 92, 114) }
    if ($seriesName -eq "Projected") {
      $series.Color = [Drawing.Color]::FromArgb(136, 92, 42)
      $series.BorderDashStyle = [System.Windows.Forms.DataVisualization.Charting.ChartDashStyle]::Dash
      $series.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::Diamond
    }
    [void]$chart.Series.Add($series)
  }

  $allValues = New-Object System.Collections.ArrayList
  $flowBuckets = Get-ChartBuckets 6
  foreach ($bucket in $flowBuckets) {
    $items = @($script:Entries | Where-Object {
      $entryDate = if ($null -ne $_.Date) { [datetime]$_.Date } else { [datetime]::MinValue }
      $entryDate -ge [datetime]$bucket.Start -and
      $entryDate -le [datetime]$bucket.End -and
      (($selectedAccount -eq "All Accounts") -or ($_.Account -eq $selectedAccount))
    })
    $out = [decimal](@($items | Where-Object { $_.Type -in @("Expense", "Bill") -and -not (Test-InternalTransfer $_) } | Measure-Object Amount -Sum).Sum)
    $saved = [decimal](@($items | Where-Object { Test-GoalSavingEntry $_ } | Measure-Object Amount -Sum).Sum)
    $income = [decimal](@($items | Where-Object Type -eq "Income" | Measure-Object Amount -Sum).Sum)
    $savingsCredit = [decimal](@($items | Where-Object { Test-SavingsAccountCredit $_ } | Measure-Object Amount -Sum).Sum)
    $savingsPayments = [decimal](@($items | Where-Object { Test-SavingsAccountPayment $_ } | Measure-Object Amount -Sum).Sum)
    $creditCardIncome = [decimal](@($items | Where-Object { ([string]$_.BankCategory).ToUpperInvariant() -eq "PAYMENT" } | Measure-Object Amount -Sum).Sum)
    $creditCardSpend = [decimal](@($items | Where-Object { ([string]$_.BankCategory).ToUpperInvariant() -in @("OTHER", "FEE", "FEES", "DEBIT", "CASH") } | Measure-Object Amount -Sum).Sum)
    $net = if ($graphMode -eq "Income vs Spend") {
      if ($isCreditCardIncomeSpend) {
        [decimal]($creditCardIncome - $creditCardSpend)
      } elseif ($isSavingsIncomeSpend) {
        [decimal]($savingsCredit - $savingsPayments)
      } else {
        [decimal]($income - $out)
      }
    } else { [decimal]($saved - $out) }
    $pairs = switch ($graphMode) {
      "Income vs Spend" {
        if ($isCreditCardIncomeSpend) {
          @(@("Income", [double]$creditCardIncome), @("Out", [double]$creditCardSpend), @("Net", [double]$net))
        } elseif ($isSavingsIncomeSpend) {
          @(@("Credit + Interest", [double]$savingsCredit), @("Payments", [double]$savingsPayments), @("Net", [double]$net))
        } else {
          @(@("Income", [double]$income), @("Out", [double]$out), @("Net", [double]$net))
        }
      }
      "Savings Goals" { @(@("Saved", [double]$saved)) }
      default { @(@("Out", [double]$out), @("Saved", [double]$saved), @("Net", [double]$net)) }
    }
    foreach ($pair in $pairs) {
      $point = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
      $point.SetValueXY([int]$bucket.Index, $pair[1])
      $point.AxisLabel = [string]$bucket.Label
      if ($bucket.IsFuture) { $point.IsEmpty = $true }
      $targetSeries = $chart.Series.FindByName([string]$pair[0])
      if ($targetSeries) { [void]$targetSeries.Points.Add($point) }
      if (-not $point.IsEmpty) { [void]$allValues.Add([double]$pair[1]) }
    }

    $projectedSeries = $chart.Series.FindByName("Projected")
    if ($projectedSeries) {
      $projectionPoint = New-Object System.Windows.Forms.DataVisualization.Charting.DataPoint
      $projectionPoint.SetValueXY([int]$bucket.Index, 0)
      $projectionPoint.AxisLabel = [string]$bucket.Label
      $projectionPoint.IsEmpty = $true
      if (([datetime]$bucket.End).Date -ge [datetime]::Today) {
        $projectedValue = if ((Get-SelectedMonthRange)) {
          ([decimal](Get-MinimumWeeklySavingsPlan).MinimumWeeklyRate / [decimal]7)
        } else {
          Get-ProjectedMonthlyGoalSavings ([datetime]$bucket.Start)
        }
        $projectionPoint.YValues[0] = [double]$projectedValue
        $projectionPoint.IsEmpty = $false
        [void]$allValues.Add([double]$projectedValue)
      }
      [void]$projectedSeries.Points.Add($projectionPoint)
    }
  }

  $maxValue = 0
  $minValue = 0
  foreach ($value in $allValues) {
    if ($value -gt $maxValue) { $maxValue = $value }
    if ($value -lt $minValue) { $minValue = $value }
  }
  Set-ChartAxisScale $chart $minValue $maxValue $flowBuckets.Count
  Add-ZeroAxisLine $chart

  $projectionSummaryLabel.Text = "Recent spend/wk: $(ConvertTo-Money $projection.WeeklySpend)    Required savings/wk: $(ConvertTo-Money $projection.RequiredSavingsWeekly)"
}

function Refresh-Allocation {
  if (-not $allocationGrid) { return }
  $allocationGrid.Rows.Clear()
  $projection = Get-ProjectionSummary
  $distribution = Get-PaycheckDistribution $projection
  $effectiveWeeklySavings = [decimal]$distribution.AvailableForSavings
  if ($weeklySavingsBox) {
    $script:UpdatingWeeklySavingsBox = $true
    $weeklySavingsBox.Value = [math]::Min([decimal]$weeklySavingsBox.Maximum, [math]::Max([decimal]$weeklySavingsBox.Minimum, [decimal]$distribution.Paycheck))
    $script:UpdatingWeeklySavingsBox = $false
    $weeklySavingsBox.Enabled = ([decimal]$projection.CurrentPaycheckAmount -le 0)
    $weeklySavingsLabel.Text = if ([decimal]$projection.CurrentPaycheckAmount -gt 0) { "Current paycheck" } else { "Manual paycheck" }
  }

  $plan = $distribution.Plan
  foreach ($row in $plan.Rows) {
    $rowIndex = $allocationGrid.Rows.Add()
    $gridRow = $allocationGrid.Rows[$rowIndex]
    $gridRow.Tag = $row.GoalId
    $gridRow.Cells["AllocationGoal"].Value = $row.GoalName
    $gridRow.Cells["AllocationAmount"].Value = ConvertTo-Money $row.Allocation
    $gridRow.Cells["AllocationRequired"].Value = ConvertTo-Money $row.RequiredWeekly
    $gridRow.Cells["AllocationCompletion"].Value = ([datetime]$row.ProjectedCompletion).ToString("dd/MM/yy")
    $gridRow.Cells["AllocationStatus"].Value = $row.Status
    if ($row.Status -eq "Behind" -or $row.Status -eq "Impossible") {
      $gridRow.DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(180, 35, 24)
    } elseif ($row.Status -eq "Ahead") {
      $gridRow.DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(47, 133, 90)
    }
  }
  if ($allocationGrid.Rows.Count -eq 0) {
    $rowIndex = $allocationGrid.Rows.Add()
    $allocationGrid.Rows[$rowIndex].Cells["AllocationGoal"].Value = "Enter weekly savings and add goals to see suggestions"
  }

  $dateText = if ($distribution.PaycheckDate) { " ($(([datetime]$distribution.PaycheckDate).ToString('dd/MM/yy')))" } else { "" }
  $allocationTotalLabel.Text = "Paycheck$($dateText): $(ConvertTo-Money $distribution.Paycheck)    Recurring: $(ConvertTo-Money $distribution.Recurring)    Everyday: $(ConvertTo-Money $distribution.EverydaySpend)    Savings: $(ConvertTo-Money $distribution.Savings)    Spend: $(ConvertTo-Money $distribution.Spend)"
  $allocationTotalLabel.ForeColor = [Drawing.Color]::FromArgb(79, 68, 58)
  if (-not [string]::IsNullOrWhiteSpace($distribution.Warning)) {
    $allocationTotalLabel.Text += "    $($distribution.Warning)"
    $allocationTotalLabel.ForeColor = [Drawing.Color]::FromArgb(180, 35, 24)
  }
  $allocationWarningLabel.Text = $distribution.Warning
}

function Save-WeeklyAllocationPlan {
  $distribution = Get-PaycheckDistribution
  $plan = $distribution.Plan
  if ($plan.Rows.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show("Mark income or enter a weekly savings amount, then make sure there is at least one active goal.", "Weekly Savings Allocation", "OK", "Information") | Out-Null
    return
  }
  $script:AllocationHistory = @{}
  foreach ($row in $plan.Rows) {
    $script:AllocationHistory[[string]$row.GoalId] = [decimal]$row.Allocation
  }
  Save-Entries
  Refresh-All
  [System.Windows.Forms.MessageBox]::Show("Saved this week's allocation as the smoothing baseline.", "Weekly Savings Allocation", "OK", "Information") | Out-Null
}

function Hide-SelectedBalanceAccount {
  $index = if ($accountBalancesList.SelectedRows.Count -gt 0) { $accountBalancesList.SelectedRows[0].Index } else { -1 }
  if ($index -lt 0 -or $index -ge $script:DisplayedBalanceAccounts.Count) {
    [System.Windows.Forms.MessageBox]::Show("Select an account from Current Balances first.", "Current Balances", "OK", "Information") | Out-Null
    return
  }

  $account = [string]$script:DisplayedBalanceAccounts[$index]
  $choice = [System.Windows.Forms.MessageBox]::Show("Hide $(Get-AccountDisplayName $account) from Current Balances? The transactions will stay in the database.", "Current Balances", "YesNo", "Question")
  if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }

  $script:HiddenBalanceAccounts[$account] = $true
  Save-Entries
  Refresh-Breakdowns
}

function Refresh-Breakdowns {
  $categoryList.Rows.Clear()
  $accountBalancesList.Rows.Clear()
  $recurringPaymentsList.Rows.Clear()
  $goalsList.Rows.Clear()

  $spendRows = Get-SummaryEntries | Where-Object { $_.Type -in @("Expense", "Bill") -and -not (Test-InternalTransfer $_) } |
    Group-Object Category |
    ForEach-Object {
      [pscustomobject]@{ Category = $_.Name; Amount = [decimal](@($_.Group | Measure-Object Amount -Sum).Sum) }
    } | Sort-Object Amount -Descending

  foreach ($row in @($spendRows | Select-Object -First 8)) {
    $rowIndex = $categoryList.Rows.Add()
    $gridRow = $categoryList.Rows[$rowIndex]
    $gridRow.Cells["CategoryName"].Value = $row.Category
    $gridRow.Cells["CategoryAmount"].Value = ConvertTo-Money $row.Amount
  }
  if ($categoryList.Rows.Count -eq 0) {
    $rowIndex = $categoryList.Rows.Add()
    $categoryList.Rows[$rowIndex].Cells["CategoryName"].Value = "No spend yet"
  }

  $accountRows = Get-CalculatedAccountBalances
  $script:DisplayedBalanceAccounts = @()

  foreach ($row in $accountRows) {
    if ($script:HiddenBalanceAccounts.ContainsKey([string]$row.Account)) { continue }
    $rowIndex = $accountBalancesList.Rows.Add()
    $gridRow = $accountBalancesList.Rows[$rowIndex]
    $gridRow.Cells["BalanceAccount"].Value = Get-AccountDisplayName $row.Account
    $gridRow.Cells["BalanceAmount"].Value = ConvertTo-Money $row.Balance
    $gridRow.Cells["BalanceDate"].Value = $row.Date.ToString("dd/MM/yy")
    $script:DisplayedBalanceAccounts += [string]$row.Account
  }
  if ($accountBalancesList.Rows.Count -eq 0) {
    $rowIndex = $accountBalancesList.Rows.Add()
    $accountBalancesList.Rows[$rowIndex].Cells["BalanceAccount"].Value = "No account balances yet"
  }

  $recurringRows = Get-RecurringPayments
  $script:DisplayedRecurringKeys = @()

  foreach ($row in @($recurringRows | Select-Object -First 8)) {
    $rowIndex = $recurringPaymentsList.Rows.Add()
    $gridRow = $recurringPaymentsList.Rows[$rowIndex]
    $gridRow.Tag = [string]$row.Key
    $gridRow.Cells["RecurringName"].Value = $row.Name
    $gridRow.Cells["RecurringAmount"].Value = ConvertTo-Money $row.Amount
    $gridRow.Cells["RecurringFrequency"].Value = $row.Frequency
    $gridRow.Cells["RecurringDate"].Value = $row.Date.ToString("dd/MM/yy")
    $script:DisplayedRecurringKeys += [string]$row.Key
  }
  if ($recurringPaymentsList.Rows.Count -eq 0) {
    $rowIndex = $recurringPaymentsList.Rows.Add()
    $recurringPaymentsList.Rows[$rowIndex].Cells["RecurringName"].Value = "No recurring payments added yet"
  }

  $script:DisplayedGoalIds = @()
  foreach ($goalRow in @(Get-GoalProgressRows | Sort-Object { Get-GoalSortDate $_.Goal })) {
    $goal = $goalRow.Goal
    $saved = [decimal]$goalRow.Saved
    $isWeeklyGoal = ((Get-GoalKind $goal) -eq "Weekly")
    $pct = if ($isWeeklyGoal) { "--" } elseif ($goal.TargetAmount -gt 0) { "$([math]::Min(100, [math]::Round(($saved / $goal.TargetAmount) * 100)))%" } else { "0%" }
    $mode = if ($goal.Mode) { [string]$goal.Mode } else { "Save" }
    $rowIndex = $goalsList.Rows.Add()
    $gridRow = $goalsList.Rows[$rowIndex]
    $gridRow.Cells["GoalName"].Value = $goal.Name
    $gridRow.Cells["GoalMode"].Value = $mode
    $gridRow.Cells["GoalProgress"].Value = $pct
    $gridRow.Cells["GoalSaved"].Value = if ($isWeeklyGoal) { "Weekly" } else { ConvertTo-Money $saved }
    $gridRow.Cells["GoalTarget"].Value = if ($isWeeklyGoal) { ConvertTo-Money (Get-GoalWeeklyAmount $goal) } else { ConvertTo-Money $goal.TargetAmount }
    $gridRow.Cells["GoalDate"].Value = if ($isWeeklyGoal -and $goal.IsOngoing) { "Ongoing" } else { $goal.ExpectedDate.ToString("dd/MM/yy") }
    $script:DisplayedGoalIds += $goal.Id
  }
  if ($goalsList.Rows.Count -eq 0) {
    $rowIndex = $goalsList.Rows.Add()
    $goalsList.Rows[$rowIndex].Cells["GoalName"].Value = "No savings goals yet"
  }
}

function Refresh-Grid {
  $grid.Rows.Clear()
  foreach ($entry in Get-FilteredEntries) {
    $rowIndex = $grid.Rows.Add()
    $row = $grid.Rows[$rowIndex]
    $row.Tag = $entry.Id
    $row.Cells["Date"].Value = $entry.Date.ToString("dd/MM/yyyy")
    $row.Cells["Name"].Value = $entry.Name
    $row.Cells["Category"].Value = $entry.Category
    $row.Cells["Account"].Value = Get-AccountDisplayName $entry.Account
    $row.Cells["Frequency"].Value = $entry.Frequency
    $row.Cells["Amount"].Value = ConvertTo-Money $entry.Amount
    $row.Cells["BankCategory"].Value = $entry.BankCategory
    $row.Cells["Note"].Value = $entry.Note
  }
}

function Refresh-All {
  if ($form) { $form.SuspendLayout() }
  if ($grid) { $grid.SuspendLayout() }
  if ($categoryList) { $categoryList.SuspendLayout() }
  if ($accountBalancesList) { $accountBalancesList.SuspendLayout() }
  if ($recurringPaymentsList) { $recurringPaymentsList.SuspendLayout() }
  if ($goalsList) { $goalsList.SuspendLayout() }
  try {
    Refresh-Months
    Refresh-Accounts
    Refresh-EntryAccounts
    Refresh-Summary
    Refresh-Chart
    Refresh-Breakdowns
    Refresh-Allocation
    Refresh-Grid
    Update-LastRefreshedStatus
  } finally {
    if ($goalsList) { $goalsList.ResumeLayout() }
    if ($recurringPaymentsList) { $recurringPaymentsList.ResumeLayout() }
    if ($accountBalancesList) { $accountBalancesList.ResumeLayout() }
    if ($categoryList) { $categoryList.ResumeLayout() }
    if ($grid) { $grid.ResumeLayout() }
    if ($form) { $form.ResumeLayout($true) }
  }
}

function Refresh-AppData {
  Load-Entries
  Reset-Form
  $inputPanel.Visible = $false
  Refresh-All
}

function Update-LastRefreshedStatus {
  if (-not $lastRefreshLabel) { return }
  $lastRefreshLabel.Text = "Last refreshed: $((Get-Date).ToString('dd/MM/yyyy h:mm tt'))"
}

function Save-FormEntry {
  if ([string]::IsNullOrWhiteSpace($nameBox.Text)) {
    [System.Windows.Forms.MessageBox]::Show("Please enter a name.", "Tracker", "OK", "Information") | Out-Null
    return
  }
  $accountValue = Get-EntryAccountRawValue ([string]$accountCombo.SelectedItem)
  if ([string]::IsNullOrWhiteSpace($accountValue) -or $accountValue -eq $NewAccountOption) {
    [System.Windows.Forms.MessageBox]::Show("Please choose an account.", "Tracker", "OK", "Information") | Out-Null
    return
  }

  $entry = [pscustomobject]@{
    Id = if ($script:EditingId) { $script:EditingId } else { New-EntryId }
    Type = [string]$typeCombo.SelectedItem
    Date = $datePicker.Value.Date
    Name = $nameBox.Text.Trim()
    Category = [string]$categoryCombo.SelectedItem
    Account = $accountValue
    Frequency = ""
    Amount = [decimal]$amountBox.Value
    Goal = [decimal]0
    Note = $noteBox.Text.Trim()
    Balance = [decimal]0
    BankCategory = ""
    Serial = ""
    Source = "Manual"
    ImportKey = ""
  }

  $existing = $script:Entries | Where-Object Id -eq $entry.Id | Select-Object -First 1
  if ($existing) {
    $index = $script:Entries.IndexOf($existing)
    $script:Entries[$index] = $entry
  } else {
    [void]$script:Entries.Add($entry)
  }

  Save-Entries
  Reset-Form
  $inputPanel.Visible = $false
  Refresh-All
}

function Edit-SelectedEntry {
  if ($grid.SelectedRows.Count -eq 0) { return }
  $id = $grid.SelectedRows[0].Tag
  $entry = $script:Entries | Where-Object Id -eq $id | Select-Object -First 1
  if (-not $entry) { return }

  $script:EditingId = $entry.Id
  $typeCombo.SelectedItem = $entry.Type
  Refresh-Categories
  $datePicker.Value = $entry.Date
  $nameBox.Text = $entry.Name
  $categoryCombo.SelectedItem = $entry.Category
  $amountBox.Value = [decimal]$entry.Amount
  Refresh-EntryAccounts $entry.Account
  $noteBox.Text = $entry.Note
  $saveButton.Text = "Save Entry"
  $inputPanel.Visible = $true
  $inputPanel.BringToFront()
}

function Delete-SelectedEntry {
  if ($grid.SelectedRows.Count -eq 0) { return }
  $count = $grid.SelectedRows.Count
  $message = if ($count -eq 1) { "Delete the selected entry?" } else { "Delete the $count selected entries?" }
  $choice = [System.Windows.Forms.MessageBox]::Show($message, "Tracker", "YesNo", "Question")
  if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }

  $ids = @()
  foreach ($row in $grid.SelectedRows) {
    if ($row.Tag) { $ids += [string]$row.Tag }
  }

  foreach ($id in $ids) {
    $entry = $script:Entries | Where-Object Id -eq $id | Select-Object -First 1
    if ($entry) {
      $script:Entries.Remove($entry)
    }
  }

  if ($ids.Count -gt 0) {
    Save-Entries
    Refresh-All
  }
}

function Mark-SelectedIncome {
  $items = @(Get-SelectedGridEntries)
  if ($items.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show("Select one or more paycheck transactions first.", "Income", "OK", "Information") | Out-Null
    return
  }

  foreach ($entry in $items) {
    $entry.Type = "Income"
    if ([string]::IsNullOrWhiteSpace([string]$entry.Category) -or $entry.Category -in @("CREDIT", "DEP", "PAYMENT", "Other")) {
      $entry.Category = "Paycheck"
    }
    if ([string]::IsNullOrWhiteSpace([string]$entry.Note)) {
      $entry.Note = "Marked as income"
    }
  }

  Save-Entries
  Refresh-All
}

function Get-SelectedGridEntries {
  $items = New-Object System.Collections.ArrayList
  foreach ($row in $grid.SelectedRows) {
    if (-not $row.Tag) { continue }
    $entry = $script:Entries | Where-Object Id -eq ([string]$row.Tag) | Select-Object -First 1
    if ($entry) { [void]$items.Add($entry) }
  }
  return @($items)
}

function Add-SelectedRecurringPayment {
  $items = @(Get-SelectedGridEntries | Where-Object { $_.Type -in @("Expense", "Bill") })
  if ($items.Count -lt 2) {
    [System.Windows.Forms.MessageBox]::Show("Select two or more expense/payment transactions first.", "Recurring Payments", "OK", "Information") | Out-Null
    return
  }

  $accountCount = @($items | Group-Object Account).Count
  if ($accountCount -gt 1) {
    [System.Windows.Forms.MessageBox]::Show("Select transactions from one account at a time.", "Recurring Payments", "OK", "Information") | Out-Null
    return
  }

  $record = New-RecurringPaymentRecord $items ("manual|" + [guid]::NewGuid().ToString("N"))
  [void]$script:RecurringManual.Add($record)
  Save-Entries
  Refresh-Breakdowns
}

function Export-Csv {
  $dialog = New-Object System.Windows.Forms.SaveFileDialog
  $dialog.Filter = "CSV files (*.csv)|*.csv"
  $dialog.FileName = "expense-savings-tracker.csv"
  if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $script:Entries | Select-Object Date, Type, Name, Category, Account, Frequency, Amount, Goal, Balance, BankCategory, Serial, Source, ImportKey, Note |
      Export-Csv -Path $dialog.FileName -NoTypeInformation
  }
}

function Export-Backup {
  $dialog = New-Object System.Windows.Forms.SaveFileDialog
  $dialog.Filter = "JSON backup (*.json)|*.json"
  $dialog.FileName = "expense-savings-tracker-backup.json"
  if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    Copy-Item -Path $DataPath -Destination $dialog.FileName -Force
  }
}

function Import-Backup {
  $dialog = New-Object System.Windows.Forms.OpenFileDialog
  $dialog.Filter = "JSON backup (*.json)|*.json"
  if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $backupPath = New-AutoBackup "before-restore"
    Copy-Item -Path $dialog.FileName -Destination $DataPath -Force
    Load-Entries
    Reset-Form
    Refresh-All
    $backupText = if ($backupPath) { " Auto-backup created first: $backupPath" } else { "" }
    [System.Windows.Forms.MessageBox]::Show("Backup restored.$backupText", "Restore", "OK", "Information") | Out-Null
  }
}

function Show-SavingsGoalDialog($existingGoal) {
  $dialog = New-Object System.Windows.Forms.Form
  $dialog.Text = if ($existingGoal) { "Edit Savings Goal" } else { "Add Savings Goal" }
  $dialog.StartPosition = "CenterParent"
  $dialog.FormBorderStyle = "FixedDialog"
  $dialog.MinimizeBox = $false
  $dialog.MaximizeBox = $false
  $dialog.ClientSize = New-Object Drawing.Size(420, 390)

  Add-Label $dialog "Goal Name" 16 14 120 | Out-Null
  $goalNameBox = New-Object System.Windows.Forms.TextBox
  $goalNameBox.SetBounds(16, 34, 180, 28)
  $dialog.Controls.Add($goalNameBox)

  Add-Label $dialog "Account" 216 14 120 | Out-Null
  $goalAccountBox = New-Object System.Windows.Forms.ComboBox
  $goalAccountBox.SetBounds(216, 34, 180, 28)
  $goalAccountBox.DropDownStyle = "DropDown"
  foreach ($account in @($script:Entries | ForEach-Object { $_.Account } | Where-Object { $_ } | Sort-Object -Unique)) {
    [void]$goalAccountBox.Items.Add($account)
  }
  $dialog.Controls.Add($goalAccountBox)

  Add-Label $dialog "Plan" 16 76 120 | Out-Null
  $goalKindBox = New-Object System.Windows.Forms.ComboBox
  $goalKindBox.DropDownStyle = "DropDownList"
  $goalKindBox.Items.AddRange(@("Target by date", "Weekly amount"))
  $goalKindBox.SetBounds(16, 96, 180, 28)
  $dialog.Controls.Add($goalKindBox)

  Add-Label $dialog "Target Amount" 216 76 120 | Out-Null
  $targetBox = New-Object System.Windows.Forms.NumericUpDown
  $targetBox.DecimalPlaces = 2
  $targetBox.Maximum = 100000000
  $targetBox.ThousandsSeparator = $true
  $targetBox.SetBounds(216, 96, 180, 28)
  $dialog.Controls.Add($targetBox)

  Add-Label $dialog "Weekly Amount" 16 138 120 | Out-Null
  $weeklyAmountBox = New-Object System.Windows.Forms.NumericUpDown
  $weeklyAmountBox.DecimalPlaces = 2
  $weeklyAmountBox.Maximum = 100000000
  $weeklyAmountBox.ThousandsSeparator = $true
  $weeklyAmountBox.SetBounds(16, 158, 180, 28)
  $dialog.Controls.Add($weeklyAmountBox)

  Add-Label $dialog "Expected / End Date" 216 138 140 | Out-Null
  $expectedPicker = New-Object System.Windows.Forms.DateTimePicker
  $expectedPicker.Format = "Short"
  $expectedPicker.SetBounds(216, 158, 180, 28)
  $dialog.Controls.Add($expectedPicker)

  $ongoingCheck = New-Object System.Windows.Forms.CheckBox
  $ongoingCheck.Text = "Ongoing"
  $ongoingCheck.SetBounds(216, 188, 100, 24)
  $dialog.Controls.Add($ongoingCheck)

  Add-Label $dialog "Goal Type" 16 210 120 | Out-Null
  $goalModeBox = New-Object System.Windows.Forms.ComboBox
  $goalModeBox.DropDownStyle = "DropDownList"
  $goalModeBox.Items.AddRange(@("Save", "Send"))
  $goalModeBox.SetBounds(16, 230, 180, 28)
  $dialog.Controls.Add($goalModeBox)

  Add-Label $dialog "Basic Info" 16 270 120 | Out-Null
  $goalNoteBox = New-Object System.Windows.Forms.TextBox
  $goalNoteBox.Multiline = $true
  $goalNoteBox.ScrollBars = "Vertical"
  $goalNoteBox.SetBounds(16, 290, 380, 48)
  $dialog.Controls.Add($goalNoteBox)

  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = "Save"
  $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $ok.SetBounds(216, 350, 82, 30)
  $dialog.AcceptButton = $ok

  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = "Cancel"
  $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $cancel.SetBounds(314, 350, 82, 30)
  $dialog.CancelButton = $cancel
  $dialog.Controls.AddRange(@($ok, $cancel))

  if ($existingGoal) {
    $goalNameBox.Text = $existingGoal.Name
    $goalAccountBox.Text = $existingGoal.Account
    $targetBox.Value = [decimal]$existingGoal.TargetAmount
    $weeklyAmountBox.Value = if ($existingGoal.WeeklyAmount) { [decimal]$existingGoal.WeeklyAmount } else { [decimal]0 }
    $expectedPicker.Value = [datetime]$existingGoal.ExpectedDate
    $goalModeBox.SelectedItem = if ($existingGoal.Mode) { [string]$existingGoal.Mode } else { "Save" }
    $goalKindBox.SelectedItem = if ((Get-GoalKind $existingGoal) -eq "Weekly") { "Weekly amount" } else { "Target by date" }
    $ongoingCheck.Checked = if ($existingGoal.IsOngoing) { [bool]$existingGoal.IsOngoing } else { $false }
    $goalNoteBox.Text = $existingGoal.Note
  } else {
    $expectedPicker.Value = [datetime]::Today.AddMonths(12)
    $goalModeBox.SelectedItem = "Save"
    $goalKindBox.SelectedItem = "Target by date"
  }

  $refreshGoalKindUi = {
    $isWeekly = ([string]$goalKindBox.SelectedItem -eq "Weekly amount")
    $targetBox.Enabled = -not $isWeekly
    $weeklyAmountBox.Enabled = $isWeekly
    $ongoingCheck.Enabled = $isWeekly
    $expectedPicker.Enabled = (-not $isWeekly) -or (-not $ongoingCheck.Checked)
  }
  $goalKindBox.Add_SelectedIndexChanged($refreshGoalKindUi)
  $ongoingCheck.Add_CheckedChanged($refreshGoalKindUi)
  & $refreshGoalKindUi

  if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
  if ([string]::IsNullOrWhiteSpace($goalNameBox.Text) -or [string]::IsNullOrWhiteSpace($goalAccountBox.Text)) {
    [System.Windows.Forms.MessageBox]::Show("Please enter a goal name and account.", "Savings Goal", "OK", "Information") | Out-Null
    return $null
  }
  $goalKind = if ([string]$goalKindBox.SelectedItem -eq "Weekly amount") { "Weekly" } else { "Target" }
  if ($goalKind -eq "Target" -and [decimal]$targetBox.Value -le 0) {
    [System.Windows.Forms.MessageBox]::Show("Enter a target amount.", "Savings Goal", "OK", "Information") | Out-Null
    return $null
  }
  if ($goalKind -eq "Weekly" -and [decimal]$weeklyAmountBox.Value -le 0) {
    [System.Windows.Forms.MessageBox]::Show("Enter a weekly amount.", "Savings Goal", "OK", "Information") | Out-Null
    return $null
  }

  return [pscustomobject]@{
    Id = if ($existingGoal) { $existingGoal.Id } else { New-EntryId }
    Name = $goalNameBox.Text.Trim()
    Account = $goalAccountBox.Text.Trim()
    TargetAmount = if ($goalKind -eq "Weekly") { [decimal]$weeklyAmountBox.Value } else { [decimal]$targetBox.Value }
    ExpectedDate = $expectedPicker.Value.Date
    Mode = [string]$goalModeBox.SelectedItem
    GoalKind = $goalKind
    WeeklyAmount = if ($goalKind -eq "Weekly") { [decimal]$weeklyAmountBox.Value } else { [decimal]0 }
    IsOngoing = ($goalKind -eq "Weekly" -and $ongoingCheck.Checked)
    Note = $goalNoteBox.Text.Trim()
  }
}

function Add-SavingsGoal {
  $goal = Show-SavingsGoalDialog $null
  if (-not $goal) { return }
  [void]$script:Goals.Add($goal)
  Save-Entries
  Refresh-All
}

function Get-SelectedGoal {
  $index = if ($goalsList.SelectedRows.Count -gt 0) { $goalsList.SelectedRows[0].Index } else { -1 }
  if ($index -lt 0 -or $index -ge $script:DisplayedGoalIds.Count) { return $null }
  $id = $script:DisplayedGoalIds[$index]
  return $script:Goals | Where-Object Id -eq $id | Select-Object -First 1
}

function Edit-SavingsGoal {
  $existing = Get-SelectedGoal
  if (-not $existing) { return }
  $updated = Show-SavingsGoalDialog $existing
  if (-not $updated) { return }
  $index = $script:Goals.IndexOf($existing)
  $script:Goals[$index] = $updated
  Save-Entries
  Refresh-All
}

function Delete-SavingsGoal {
  $existing = Get-SelectedGoal
  if (-not $existing) { return }
  $choice = [System.Windows.Forms.MessageBox]::Show("Delete this savings goal?", "Savings Goal", "YesNo", "Question")
  if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  $script:Goals.Remove($existing)
  Save-Entries
  Refresh-All
}

function Remove-RecurringPayment {
  if ($recurringPaymentsList.SelectedRows.Count -eq 0) { return }
  $key = [string]$recurringPaymentsList.SelectedRows[0].Tag
  if ([string]::IsNullOrWhiteSpace($key)) { return }

  $choice = [System.Windows.Forms.MessageBox]::Show("Remove this recurring payment from the list?", "Recurring Payments", "YesNo", "Question")
  if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }

  $script:RecurringExclusions[[string]$key] = $true
  Save-Entries
  Refresh-Breakdowns
}

function Get-SelectedRecurringPayment {
  if ($recurringPaymentsList.SelectedRows.Count -eq 0) { return $null }
  $key = [string]$recurringPaymentsList.SelectedRows[0].Tag
  if ([string]::IsNullOrWhiteSpace($key)) { return $null }
  return $script:RecurringManual | Where-Object { $_.Key -eq $key } | Select-Object -First 1
}

function Show-RecurringPaymentDialog($existing) {
  $dialog = New-Object System.Windows.Forms.Form
  $dialog.Text = "Edit Recurring Payment"
  $dialog.StartPosition = "CenterParent"
  $dialog.FormBorderStyle = "FixedDialog"
  $dialog.MinimizeBox = $false
  $dialog.MaximizeBox = $false
  $dialog.ClientSize = New-Object Drawing.Size(420, 250)

  Add-Label $dialog "Name" 16 14 120 | Out-Null
  $nameBox = New-Object System.Windows.Forms.TextBox
  $nameBox.SetBounds(16, 34, 380, 28)
  Set-InputStyle $nameBox
  $dialog.Controls.Add($nameBox)

  Add-Label $dialog "Account" 16 76 120 | Out-Null
  $accountBox = New-Object System.Windows.Forms.ComboBox
  $accountBox.SetBounds(16, 96, 180, 28)
  $accountBox.DropDownStyle = "DropDown"
  foreach ($account in Get-AllKnownAccounts) {
    [void]$accountBox.Items.Add($account)
  }
  Set-InputStyle $accountBox
  $dialog.Controls.Add($accountBox)

  Add-Label $dialog "Amount" 216 76 120 | Out-Null
  $amountBox = New-Object System.Windows.Forms.NumericUpDown
  $amountBox.DecimalPlaces = 2
  $amountBox.Maximum = 100000000
  $amountBox.ThousandsSeparator = $true
  $amountBox.SetBounds(216, 96, 180, 28)
  Set-InputStyle $amountBox
  $dialog.Controls.Add($amountBox)

  Add-Label $dialog "Frequency" 16 138 120 | Out-Null
  $frequencyBox = New-Object System.Windows.Forms.ComboBox
  $frequencyBox.SetBounds(16, 158, 180, 28)
  $frequencyBox.DropDownStyle = "DropDownList"
  $frequencyBox.Items.AddRange(@("Weekly", "Fortnightly", "Monthly", "Quarterly", "Annual", "Recurring"))
  Set-InputStyle $frequencyBox
  $dialog.Controls.Add($frequencyBox)

  Add-Label $dialog "Latest Date" 216 138 120 | Out-Null
  $datePicker = New-Object System.Windows.Forms.DateTimePicker
  $datePicker.Format = "Short"
  $datePicker.SetBounds(216, 158, 180, 28)
  Set-InputStyle $datePicker
  $dialog.Controls.Add($datePicker)

  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = "Save"
  $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $ok.SetBounds(216, 206, 82, 30)
  Set-ButtonStyle $ok $true
  $dialog.AcceptButton = $ok

  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = "Cancel"
  $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $cancel.SetBounds(314, 206, 82, 30)
  Set-ButtonStyle $cancel
  $dialog.CancelButton = $cancel
  $dialog.Controls.AddRange(@($ok, $cancel))

  $nameBox.Text = $existing.Name
  $accountBox.Text = $existing.Account
  $amountBox.Value = [decimal]$existing.Amount
  $frequencyBox.SelectedItem = if ($existing.Frequency) { $existing.Frequency } else { "Recurring" }
  $datePicker.Value = [datetime]$existing.Date

  if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
  if ([string]::IsNullOrWhiteSpace($nameBox.Text) -or [string]::IsNullOrWhiteSpace($accountBox.Text)) {
    [System.Windows.Forms.MessageBox]::Show("Please enter a name and account.", "Recurring Payments", "OK", "Information") | Out-Null
    return $null
  }

  return [pscustomobject]@{
    Key = $existing.Key
    Name = $nameBox.Text.Trim()
    Category = $existing.Category
    Account = $accountBox.Text.Trim()
    Amount = [decimal]$amountBox.Value
    Date = $datePicker.Value.Date
    Frequency = [string]$frequencyBox.SelectedItem
    Count = [int]$existing.Count
  }
}

function Edit-RecurringPayment {
  $existing = Get-SelectedRecurringPayment
  if (-not $existing) {
    [System.Windows.Forms.MessageBox]::Show("Select a manually added recurring payment first.", "Recurring Payments", "OK", "Information") | Out-Null
    return
  }
  $updated = Show-RecurringPaymentDialog $existing
  if (-not $updated) { return }
  $index = $script:RecurringManual.IndexOf($existing)
  $script:RecurringManual[$index] = $updated
  Save-Entries
  Refresh-Breakdowns
}

function Manage-AccountNames {
  $accounts = @($script:Entries | ForEach-Object { $_.Account } | Where-Object { $_ } | Sort-Object -Unique)
  if ($accounts.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show("Import or add transactions first so there are accounts to name.", "Account Names", "OK", "Information") | Out-Null
    return
  }

  $dialog = New-Object System.Windows.Forms.Form
  $dialog.Text = "Name Accounts"
  $dialog.StartPosition = "CenterParent"
  $dialog.FormBorderStyle = "FixedDialog"
  $dialog.MinimizeBox = $false
  $dialog.MaximizeBox = $false
  $dialog.ClientSize = New-Object Drawing.Size(560, 360)

  $label = New-Object System.Windows.Forms.Label
  $label.Text = "Select an account number, then enter the name you want to see in the app."
  $label.SetBounds(14, 12, 530, 22)
  $dialog.Controls.Add($label)

  $accountList = New-Object System.Windows.Forms.ListBox
  $accountList.SetBounds(14, 44, 250, 250)
  $accountList.Font = New-Object Drawing.Font("Consolas", 9)
  foreach ($account in $accounts) {
    [void]$accountList.Items.Add($account)
  }
  $dialog.Controls.Add($accountList)

  Add-Label $dialog "Friendly Name" 286 44 160 | Out-Null
  $nameBox = New-Object System.Windows.Forms.TextBox
  $nameBox.SetBounds(286, 66, 250, 28)
  $dialog.Controls.Add($nameBox)

  $preview = New-Object System.Windows.Forms.Label
  $preview.SetBounds(286, 108, 250, 50)
  $preview.ForeColor = [Drawing.Color]::FromArgb(111, 98, 88)
  $dialog.Controls.Add($preview)

  $apply = New-Object System.Windows.Forms.Button
  $apply.Text = "Apply Name"
  $apply.SetBounds(286, 174, 112, 32)
  Set-ButtonStyle $apply
  $dialog.Controls.Add($apply)

  $clearName = New-Object System.Windows.Forms.Button
  $clearName.Text = "Clear Name"
  $clearName.SetBounds(408, 174, 112, 32)
  Set-ButtonStyle $clearName
  $dialog.Controls.Add($clearName)

  $close = New-Object System.Windows.Forms.Button
  $close.Text = "Done"
  $close.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $close.SetBounds(454, 312, 82, 30)
  Set-ButtonStyle $close $true
  $dialog.AcceptButton = $close
  $dialog.Controls.Add($close)

  $accountList.Add_SelectedIndexChanged({
    $selected = [string]$accountList.SelectedItem
    if (-not $selected) { return }
    $nameBox.Text = if ($script:AccountNames.ContainsKey($selected)) { $script:AccountNames[$selected] } else { "" }
    $preview.Text = "Display: $(Get-AccountDisplayName $selected)"
  })
  $apply.Add_Click({
    $selected = [string]$accountList.SelectedItem
    if (-not $selected) { return }
    $script:AccountNames[$selected] = $nameBox.Text.Trim()
    $preview.Text = "Display: $(Get-AccountDisplayName $selected)"
    Save-Entries
    Refresh-All
  })
  $clearName.Add_Click({
    $selected = [string]$accountList.SelectedItem
    if (-not $selected) { return }
    if ($script:AccountNames.ContainsKey($selected)) { $script:AccountNames.Remove($selected) }
    $nameBox.Text = ""
    $preview.Text = "Display: $(Get-AccountDisplayName $selected)"
    Save-Entries
    Refresh-All
  })

  $accountList.SelectedIndex = 0
  [void]$dialog.ShowDialog($form)
}

function Show-SettingsDialog {
  $dialog = New-Object System.Windows.Forms.Form
  $dialog.Text = "Settings"
  $dialog.StartPosition = "CenterParent"
  $dialog.FormBorderStyle = "FixedDialog"
  $dialog.MinimizeBox = $false
  $dialog.MaximizeBox = $false
  $dialog.ClientSize = New-Object Drawing.Size(430, 260)

  $graphModes = @("Savings Projection", "Monthly Flow", "Income vs Spend", "Savings Goals", "Balances", "Data Table")

  Add-Label $dialog "Budget Week Starts" 16 16 160 | Out-Null
  $weekStartBox = New-Object System.Windows.Forms.ComboBox
  $weekStartBox.DropDownStyle = "DropDownList"
  $weekStartBox.Items.AddRange(@("Monday", "Sunday"))
  $weekStartBox.SetBounds(16, 38, 180, 28)
  Set-InputStyle $weekStartBox
  $dialog.Controls.Add($weekStartBox)

  Add-Label $dialog "Currency" 226 16 160 | Out-Null
  $currencyBox = New-Object System.Windows.Forms.ComboBox
  $currencyBox.DropDownStyle = "DropDownList"
  $currencyBox.Items.AddRange(@("AUD - Australia", "USD - United States", "GBP - United Kingdom", "EUR - Ireland"))
  $currencyBox.SetBounds(226, 38, 180, 28)
  Set-InputStyle $currencyBox
  $dialog.Controls.Add($currencyBox)

  Add-Label $dialog "Left Graph Default" 16 86 160 | Out-Null
  $leftGraphBox = New-Object System.Windows.Forms.ComboBox
  $leftGraphBox.DropDownStyle = "DropDownList"
  $leftGraphBox.Items.AddRange($graphModes)
  $leftGraphBox.SetBounds(16, 108, 180, 28)
  Set-InputStyle $leftGraphBox
  $dialog.Controls.Add($leftGraphBox)

  Add-Label $dialog "Right Graph Default" 226 86 160 | Out-Null
  $rightGraphBox = New-Object System.Windows.Forms.ComboBox
  $rightGraphBox.DropDownStyle = "DropDownList"
  $rightGraphBox.Items.AddRange($graphModes)
  $rightGraphBox.SetBounds(226, 108, 180, 28)
  Set-InputStyle $rightGraphBox
  $dialog.Controls.Add($rightGraphBox)

  $note = New-Object System.Windows.Forms.Label
  $note.Text = "Settings are saved with your tracker data. Budget totals recalculate immediately after saving."
  $note.SetBounds(16, 156, 390, 38)
  $note.ForeColor = [Drawing.Color]::FromArgb(111, 98, 88)
  $dialog.Controls.Add($note)

  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = "Save"
  $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $ok.SetBounds(226, 214, 82, 30)
  Set-ButtonStyle $ok $true
  $dialog.AcceptButton = $ok

  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = "Cancel"
  $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $cancel.SetBounds(324, 214, 82, 30)
  Set-ButtonStyle $cancel
  $dialog.CancelButton = $cancel
  $dialog.Controls.AddRange(@($ok, $cancel))

  $weekStartBox.SelectedItem = if ($script:Settings.WeekStartsOn) { [string]$script:Settings.WeekStartsOn } else { "Monday" }
  $currencyBox.SelectedItem = switch ([string]$script:Settings.CurrencyCulture) {
    "en-US" { "USD - United States" }
    "en-GB" { "GBP - United Kingdom" }
    "en-IE" { "EUR - Ireland" }
    default { "AUD - Australia" }
  }
  $leftGraphBox.SelectedItem = if ($graphModes -contains [string]$script:Settings.LeftGraphDefault) { [string]$script:Settings.LeftGraphDefault } else { "Data Table" }
  $rightGraphBox.SelectedItem = if ($graphModes -contains [string]$script:Settings.RightGraphDefault) { [string]$script:Settings.RightGraphDefault } else { "Income vs Spend" }

  if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

  $script:Settings.WeekStartsOn = [string]$weekStartBox.SelectedItem
  $script:Settings.CurrencyCulture = switch ([string]$currencyBox.SelectedItem) {
    "USD - United States" { "en-US" }
    "GBP - United Kingdom" { "en-GB" }
    "EUR - Ireland" { "en-IE" }
    default { "en-AU" }
  }
  $script:Settings.LeftGraphDefault = [string]$leftGraphBox.SelectedItem
  $script:Settings.RightGraphDefault = [string]$rightGraphBox.SelectedItem

  $graphModeCombo.SelectedItem = $script:Settings.LeftGraphDefault
  $graphModeCombo2.SelectedItem = $script:Settings.RightGraphDefault
  Save-Entries
  Refresh-All
}

function Show-HelpDialog {
  $message = @"
Dashboard cards

Remaining Budget = this week's paycheck minus minimum savings, expected bills, and spend.
Bills = bill entries this week plus recurring payments due inside the budget week.
Paycheck = income marked inside the current budget week.
Min Savings = weekly saving needed for active goals.
Spend = expense entries this week, excluding internal transfers.

Tips

Use Mark Income on your paycheck each week.
Use Refresh after editing data or importing files.
Bank statement imports report how many rows were added, skipped as duplicates, or skipped as zero-value rows.
Automatic backups are created before imports and restores.
"@
  [System.Windows.Forms.MessageBox]::Show($message, "Expense & Savings Tracker Help", "OK", "Information") | Out-Null
}

function Get-HeaderName($row, [string[]]$candidates) {
  $headers = @($row.PSObject.Properties.Name)
  foreach ($candidate in $candidates) {
    $match = $headers | Where-Object { $_ -match $candidate } | Select-Object -First 1
    if ($match) { return $match }
  }
  return $null
}

function Convert-StatementAmount($value) {
  if ($null -eq $value) { return [decimal]0 }
  $text = [string]$value
  $text = $text.Trim()
  if ($text.Length -eq 0) { return [decimal]0 }
  $negative = $text.StartsWith("(") -and $text.EndsWith(")")
  $text = $text.Replace("`$", "").Replace(",", "").Replace("(", "").Replace(")", "").Trim()
  $parsed = [decimal]0
  if ([decimal]::TryParse($text, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
    if ($negative) { return -[math]::Abs($parsed) }
    return $parsed
  }
  return [decimal]0
}

function Convert-StatementDate($value) {
  $date = [datetime]::Today
  $text = [string]$value
  $cultures = @(
    [Globalization.CultureInfo]::GetCultureInfo("en-AU"),
    [Globalization.CultureInfo]::InvariantCulture
  )
  foreach ($culture in $cultures) {
    if ($null -ne $value -and [datetime]::TryParse($text, $culture, [Globalization.DateTimeStyles]::None, [ref]$date)) {
      return $date.Date
    }
  }
  foreach ($format in @("dd/MM/yyyy", "d/MM/yyyy", "dd/M/yyyy", "d/M/yyyy", "yyyy-MM-dd")) {
    if ([datetime]::TryParseExact($text, $format, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) {
      return $date.Date
    }
  }
  if ($null -ne $value -and [datetime]::TryParse($text, [ref]$date)) {
    return $date.Date
  }
  return [datetime]::Today
}

function Get-DuplicateType([string]$type) {
  if ($type -eq "Income") { return "Saving" }
  return $type
}

function Get-DuplicateDateKey([datetime]$date) {
  return $date.ToString("yyyy-MM-dd")
}

function Get-DuplicateDateKeyVariants([datetime]$date) {
  return @(
    (Get-DuplicateDateKey $date),
    (Get-DuplicateDateKey $date.AddDays(1)),
    (Get-DuplicateDateKey $date.AddDays(-1))
  ) | Select-Object -Unique
}

function Get-NormalizedDuplicateText([string]$text) {
  return $text.Trim().ToLowerInvariant() -replace "\s+", " "
}

function New-ImportKey([string]$account, [datetime]$date, [string]$type, [string]$name, [decimal]$amount, [decimal]$balance, [string]$bankCategory, [string]$serial) {
  $parts = @(
    $account.Trim().ToLowerInvariant(),
    (Get-DuplicateDateKey $date),
    (Get-DuplicateType $type).Trim().ToLowerInvariant(),
    (Get-NormalizedDuplicateText $name),
    $amount.ToString("0.00", [Globalization.CultureInfo]::InvariantCulture),
    $balance.ToString("0.00", [Globalization.CultureInfo]::InvariantCulture),
    $bankCategory.Trim().ToLowerInvariant(),
    $serial.Trim().ToLowerInvariant()
  )
  return ($parts -join "|")
}

function Test-ImportedDuplicate([string]$importKey, [string]$account, [datetime]$date, [string]$type, [string]$name, [decimal]$amount, [decimal]$balance, [string]$bankCategory, [string]$serial) {
  foreach ($entry in $script:Entries) {
    if ($entry.ImportKey -and $entry.ImportKey -eq $importKey) { return $true }

    $existingKey = New-ImportKey $entry.Account $entry.Date $entry.Type $entry.Name ([decimal]$entry.Amount) ([decimal]$entry.Balance) ([string]$entry.BankCategory) ([string]$entry.Serial)
    if ($existingKey -eq $importKey) { return $true }

    if (-not [string]::IsNullOrWhiteSpace($serial) -and $entry.Account -eq $account -and $entry.Serial -eq $serial) {
      return $true
    }

    if (
      [string]::IsNullOrWhiteSpace($serial) -and
      $entry.Date.Date -eq $date.Date -and
      (Get-DuplicateType $entry.Type) -eq (Get-DuplicateType $type) -and
      $entry.Account -eq $account -and
      $entry.Name -eq $name.Trim() -and
      [decimal]$entry.Amount -eq $amount -and
      [decimal]$entry.Balance -eq $balance -and
      [string]$entry.BankCategory -eq $bankCategory
    ) {
      return $true
    }
  }
  return $false
}

function New-SerialDuplicateKey([string]$account, [string]$serial) {
  return "$($account.Trim().ToLowerInvariant())|$($serial.Trim().ToLowerInvariant())"
}

function New-FallbackDuplicateKey([string]$account, [datetime]$date, [string]$type, [string]$name, [decimal]$amount, [decimal]$balance, [string]$bankCategory) {
  $parts = @(
    $account.Trim().ToLowerInvariant(),
    (Get-DuplicateDateKey $date),
    (Get-DuplicateType $type).Trim().ToLowerInvariant(),
    (Get-NormalizedDuplicateText $name),
    $amount.ToString("0.00", [Globalization.CultureInfo]::InvariantCulture),
    $balance.ToString("0.00", [Globalization.CultureInfo]::InvariantCulture),
    $bankCategory.Trim().ToLowerInvariant()
  )
  return ($parts -join "|")
}

function New-SoftDuplicateKey([string]$account, [string]$dateKey, [string]$name, [decimal]$amount, [decimal]$balance, [string]$bankCategory) {
  $parts = @(
    $account.Trim().ToLowerInvariant(),
    $dateKey,
    (Get-NormalizedDuplicateText $name),
    $amount.ToString("0.00", [Globalization.CultureInfo]::InvariantCulture),
    $balance.ToString("0.00", [Globalization.CultureInfo]::InvariantCulture),
    $bankCategory.Trim().ToLowerInvariant()
  )
  return ($parts -join "|")
}

function New-SoftDuplicateKeys([string]$account, [datetime]$date, [string]$name, [decimal]$amount, [decimal]$balance, [string]$bankCategory) {
  $keys = New-Object System.Collections.Generic.List[string]
  foreach ($dateKey in (Get-DuplicateDateKeyVariants $date)) {
    $keys.Add((New-SoftDuplicateKey $account $dateKey $name $amount $balance $bankCategory))
  }
  return @($keys)
}

function New-DuplicateLookup {
  $lookup = [pscustomobject]@{
    ImportKeys = @{}
    SerialKeys = @{}
    FallbackKeys = @{}
    SoftKeys = @{}
  }

  foreach ($entry in $script:Entries) {
    $importKey = if ($entry.ImportKey) {
      [string]$entry.ImportKey
    } else {
      New-ImportKey $entry.Account $entry.Date $entry.Type $entry.Name ([decimal]$entry.Amount) ([decimal]$entry.Balance) ([string]$entry.BankCategory) ([string]$entry.Serial)
    }
    if (-not [string]::IsNullOrWhiteSpace($importKey)) {
      $lookup.ImportKeys[$importKey] = $true
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$entry.Serial)) {
      $lookup.SerialKeys[(New-SerialDuplicateKey ([string]$entry.Account) ([string]$entry.Serial))] = $true
    }

    $fallbackKey = New-FallbackDuplicateKey $entry.Account $entry.Date $entry.Type $entry.Name ([decimal]$entry.Amount) ([decimal]$entry.Balance) ([string]$entry.BankCategory)
    $lookup.FallbackKeys[$fallbackKey] = $true
    foreach ($softKey in (New-SoftDuplicateKeys $entry.Account $entry.Date $entry.Name ([decimal]$entry.Amount) ([decimal]$entry.Balance) ([string]$entry.BankCategory)) ) {
      $lookup.SoftKeys[$softKey] = $true
    }
  }

  return $lookup
}

function Test-DuplicateLookup($lookup, [string]$importKey, [string]$account, [datetime]$date, [string]$type, [string]$name, [decimal]$amount, [decimal]$balance, [string]$bankCategory, [string]$serial) {
  if ($lookup.ImportKeys.ContainsKey($importKey)) { return $true }

  if (-not [string]::IsNullOrWhiteSpace($serial)) {
    return $lookup.SerialKeys.ContainsKey((New-SerialDuplicateKey $account $serial))
  }

  if ($lookup.FallbackKeys.ContainsKey((New-FallbackDuplicateKey $account $date $type $name $amount $balance $bankCategory))) { return $true }
  foreach ($softKey in (New-SoftDuplicateKeys $account $date $name $amount $balance $bankCategory)) {
    if ($lookup.SoftKeys.ContainsKey($softKey)) { return $true }
  }
  return $false
}

function Add-DuplicateLookup($lookup, [string]$importKey, [string]$account, [datetime]$date, [string]$type, [string]$name, [decimal]$amount, [decimal]$balance, [string]$bankCategory, [string]$serial) {
  $lookup.ImportKeys[$importKey] = $true
  if (-not [string]::IsNullOrWhiteSpace($serial)) {
    $lookup.SerialKeys[(New-SerialDuplicateKey $account $serial)] = $true
  }
  $lookup.FallbackKeys[(New-FallbackDuplicateKey $account $date $type $name $amount $balance $bankCategory)] = $true
  foreach ($softKey in (New-SoftDuplicateKeys $account $date $name $amount $balance $bankCategory)) {
    $lookup.SoftKeys[$softKey] = $true
  }
}

function Show-AccountPrompt([string]$defaultName) {
  $dialog = New-Object System.Windows.Forms.Form
  $dialog.Text = "Statement Account"
  $dialog.StartPosition = "CenterParent"
  $dialog.FormBorderStyle = "FixedDialog"
  $dialog.MinimizeBox = $false
  $dialog.MaximizeBox = $false
  $dialog.ClientSize = New-Object Drawing.Size(360, 140)

  $label = New-Object System.Windows.Forms.Label
  $label.Text = "Which account is this bank statement for?"
  $label.SetBounds(14, 14, 330, 22)
  $dialog.Controls.Add($label)

  $box = New-Object System.Windows.Forms.TextBox
  $box.SetBounds(14, 44, 330, 28)
  $box.Text = $defaultName
  $dialog.Controls.Add($box)

  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = "Import"
  $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $ok.SetBounds(168, 92, 82, 30)
  $dialog.AcceptButton = $ok

  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = "Cancel"
  $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $cancel.SetBounds(262, 92, 82, 30)
  $dialog.CancelButton = $cancel
  $dialog.Controls.AddRange(@($ok, $cancel))

  if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
    $name = $box.Text.Trim()
    if ($name.Length -gt 0) { return $name }
  }
  return $null
}

function Show-NewAccountDialog {
  $dialog = New-Object System.Windows.Forms.Form
  $dialog.Text = "New Account"
  $dialog.StartPosition = "CenterParent"
  $dialog.FormBorderStyle = "FixedDialog"
  $dialog.MinimizeBox = $false
  $dialog.MaximizeBox = $false
  $dialog.ClientSize = New-Object Drawing.Size(360, 142)

  $label = New-Object System.Windows.Forms.Label
  $label.Text = "Enter the account name or number."
  $label.SetBounds(14, 14, 330, 22)
  $dialog.Controls.Add($label)

  $box = New-Object System.Windows.Forms.TextBox
  $box.SetBounds(14, 44, 330, 28)
  Set-InputStyle $box
  $dialog.Controls.Add($box)

  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = "Add"
  $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $ok.SetBounds(168, 94, 82, 30)
  Set-ButtonStyle $ok $true
  $dialog.AcceptButton = $ok

  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = "Cancel"
  $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $cancel.SetBounds(262, 94, 82, 30)
  Set-ButtonStyle $cancel
  $dialog.CancelButton = $cancel
  $dialog.Controls.AddRange(@($ok, $cancel))

  if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
    $account = $box.Text.Trim()
    if ($account.Length -gt 0) { return $account }
  }
  return $null
}

function Add-NewEntryAccount {
  if ([string]$accountCombo.SelectedItem -ne $NewAccountOption) { return }
  $account = Show-NewAccountDialog
  if ($account) {
    Refresh-EntryAccounts $account
  } else {
    Refresh-EntryAccounts
  }
}

function Import-BankStatement {
  $dialog = New-Object System.Windows.Forms.OpenFileDialog
  $dialog.Filter = "CSV bank statements (*.csv)|*.csv|All files (*.*)|*.*"
  if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

  try {
    $rows = @(Import-Csv -Path $dialog.FileName)
  } catch {
    [System.Windows.Forms.MessageBox]::Show("Could not read that CSV file. Export the statement as CSV and try again.", "Import Bank Statement", "OK", "Error") | Out-Null
    return
  }

  if ($rows.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show("That statement did not contain any rows.", "Import Bank Statement", "OK", "Information") | Out-Null
    return
  }

  $first = $rows[0]
  $dateHeader = Get-HeaderName $first @("(?i)^date$", "(?i)transaction.*date", "(?i)posted.*date", "(?i)process.*date")
  $descHeader = Get-HeaderName $first @("(?i)^narrative$", "(?i)description", "(?i)details", "(?i)narration", "(?i)merchant", "(?i)payee", "(?i)transaction")
  $amountHeader = Get-HeaderName $first @("(?i)^amount$", "(?i)transaction.*amount", "(?i)value")
  $debitHeader = Get-HeaderName $first @("(?i)^debit amount$", "(?i)debit", "(?i)withdrawal", "(?i)paid.?out")
  $creditHeader = Get-HeaderName $first @("(?i)^credit amount$", "(?i)credit", "(?i)deposit", "(?i)paid.?in")
  $accountHeader = Get-HeaderName $first @("(?i)^bank account$", "(?i)^account$", "(?i)account number")
  $balanceHeader = Get-HeaderName $first @("(?i)^balance$", "(?i)closing balance")
  $bankCategoryHeader = Get-HeaderName $first @("(?i)^categories$", "(?i)^category$", "(?i)transaction category")
  $serialHeader = Get-HeaderName $first @("(?i)^serial$", "(?i)reference", "(?i)transaction id")

  $fallbackAccountName = $null
  if (-not $accountHeader) {
    $fallbackAccountName = Show-AccountPrompt ([IO.Path]::GetFileNameWithoutExtension($dialog.FileName))
    if (-not $fallbackAccountName) { return }
  }

  if (-not $dateHeader -or (-not $amountHeader -and -not $debitHeader -and -not $creditHeader)) {
    [System.Windows.Forms.MessageBox]::Show("I could not identify the Date and Amount columns. Common headers like Date, Description, Amount, Debit, and Credit are supported.", "Import Bank Statement", "OK", "Warning") | Out-Null
    return
  }

  $backupPath = New-AutoBackup "statement-import"
  $added = 0
  $duplicatesSkipped = 0
  $zeroAmountSkipped = 0
  $duplicateLookup = New-DuplicateLookup
  foreach ($row in $rows) {
    $amount = [decimal]0
    if ($amountHeader) {
      $amount = Convert-StatementAmount $row.$amountHeader
    } else {
      $credit = if ($creditHeader) { Convert-StatementAmount $row.$creditHeader } else { [decimal]0 }
      $debit = if ($debitHeader) { Convert-StatementAmount $row.$debitHeader } else { [decimal]0 }
      $amount = [math]::Abs($credit) - [math]::Abs($debit)
    }

    if ($amount -eq 0) {
      $zeroAmountSkipped++
      continue
    }
    $entryType = if ($amount -lt 0) { "Expense" } else { "Saving" }
    $name = if ($descHeader) { [string]$row.$descHeader } else { "Bank transaction" }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = "Bank transaction" }
    $entryDate = Convert-StatementDate $row.$dateHeader
    $cleanAmount = [math]::Abs($amount)
    $accountName = if ($accountHeader -and -not [string]::IsNullOrWhiteSpace([string]$row.$accountHeader)) { Get-NormalizedStatementAccount ([string]$row.$accountHeader) } else { $fallbackAccountName }
    $balance = if ($balanceHeader) { Convert-StatementAmount $row.$balanceHeader } else { [decimal]0 }
    $bankCategory = if ($bankCategoryHeader) { ([string]$row.$bankCategoryHeader).Trim() } else { "" }
    $serial = if ($serialHeader) { ([string]$row.$serialHeader).Trim() } else { "" }
    $appCategory = if ($bankCategory.Length -gt 0) { $bankCategory } else { "Other" }
    $sourceFile = [IO.Path]::GetFileName($dialog.FileName)

    $importKey = New-ImportKey $accountName $entryDate $entryType $name $cleanAmount $balance $bankCategory $serial
    if (Test-DuplicateLookup $duplicateLookup $importKey $accountName $entryDate $entryType $name $cleanAmount $balance $bankCategory $serial) {
      $duplicatesSkipped++
      continue
    }

    [void]$script:Entries.Add([pscustomobject]@{
      Id = New-EntryId
      Type = $entryType
      Date = $entryDate
      Name = $name.Trim()
      Category = $appCategory
      Account = $accountName
      Frequency = ""
      Amount = [decimal]$cleanAmount
      Goal = [decimal]0
      Note = "Imported from bank statement"
      Balance = [decimal]$balance
      BankCategory = $bankCategory
      Serial = $serial
      Source = $sourceFile
      ImportKey = $importKey
    })
    Add-DuplicateLookup $duplicateLookup $importKey $accountName $entryDate $entryType $name $cleanAmount $balance $bankCategory $serial
    $added++
  }

  Save-Entries
  Refresh-All
  $backupText = if ($backupPath) { "`n`nAuto-backup: $backupPath" } else { "" }
  $summary = "Read $($rows.Count) row(s). Imported $added new transaction(s). Skipped $duplicatesSkipped duplicate(s) and $zeroAmountSkipped zero-value row(s). Debits were added as Expenses and credits as Savings. Bank Account, Narrative, Balance, Categories, and Serial are preserved where present.$backupText"
  [System.Windows.Forms.MessageBox]::Show($summary, "Import Bank Statement", "OK", "Information") | Out-Null
}

function Import-AccountsCsv {
  $dialog = New-Object System.Windows.Forms.OpenFileDialog
  $dialog.Filter = "Accounts CSV (*.csv)|*.csv|All files (*.*)|*.*"
  if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

  try {
    $rows = @(Import-Csv -Path $dialog.FileName)
  } catch {
    [System.Windows.Forms.MessageBox]::Show("Could not read that accounts CSV file.", "Import Accounts CSV", "OK", "Error") | Out-Null
    return
  }

  if ($rows.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show("That accounts CSV did not contain any rows.", "Import Accounts CSV", "OK", "Information") | Out-Null
    return
  }

  $first = $rows[0]
  $typeHeader = Get-HeaderName $first @("(?i)^account type$")
  $nameHeader = Get-HeaderName $first @("(?i)^account nickname/name$", "(?i)nickname", "(?i)account name")
  $bsbHeader = Get-HeaderName $first @("(?i)^bsb$")
  $accountHeader = Get-HeaderName $first @("(?i)^account number/portfolio number$", "(?i)account number", "(?i)portfolio")
  $balanceHeader = Get-HeaderName $first @("(?i)^closing balance$", "(?i)balance")
  $dateHeader = Get-HeaderName $first @("(?i)^as at date for closing balance$", "(?i)balance date", "(?i)^as at date$")

  if (-not $accountHeader -or -not $balanceHeader -or -not $dateHeader) {
    [System.Windows.Forms.MessageBox]::Show("I could not identify the account number, closing balance, and balance date columns.", "Import Accounts CSV", "OK", "Warning") | Out-Null
    return
  }

  $backupPath = New-AutoBackup "accounts-import"
  $updated = 0
  $skippedOlder = 0
  foreach ($row in $rows) {
    $accountId = Get-NormalizedAccountId $(if ($bsbHeader) { $row.$bsbHeader } else { "" }) $row.$accountHeader
    if ([string]::IsNullOrWhiteSpace($accountId)) { continue }

    $balance = Convert-StatementAmount $row.$balanceHeader
    $date = Convert-StatementDate $row.$dateHeader
    $source = [IO.Path]::GetFileName($dialog.FileName)
    $existingBalance = if ($script:AccountBalances.ContainsKey($accountId)) { $script:AccountBalances[$accountId] } else { $null }
    if ($existingBalance -and [datetime]$existingBalance.Date -gt $date) {
      $skippedOlder++
      if ($nameHeader -and -not [string]::IsNullOrWhiteSpace([string]$row.$nameHeader)) {
        $script:AccountNames[$accountId] = ([string]$row.$nameHeader).Trim()
      } elseif ($typeHeader -and -not $script:AccountNames.ContainsKey($accountId)) {
        $script:AccountNames[$accountId] = ([string]$row.$typeHeader).Trim()
      }
      continue
    }

    $script:AccountBalances[$accountId] = [pscustomobject]@{
      Balance = [decimal]$balance
      Date = $date
      Source = $source
    }

    if ($nameHeader -and -not [string]::IsNullOrWhiteSpace([string]$row.$nameHeader)) {
      $script:AccountNames[$accountId] = ([string]$row.$nameHeader).Trim()
    } elseif ($typeHeader -and -not $script:AccountNames.ContainsKey($accountId)) {
      $script:AccountNames[$accountId] = ([string]$row.$typeHeader).Trim()
    }
    $updated++
  }

  Save-Entries
  Refresh-All
  $backupText = if ($backupPath) { "`n`nAuto-backup: $backupPath" } else { "" }
  [System.Windows.Forms.MessageBox]::Show("Read $($rows.Count) row(s). Updated $updated account balance(s) and account name(s). Skipped $skippedOlder older balance row(s).$backupText", "Import Accounts CSV", "OK", "Information") | Out-Null
}

function Add-Label($parent, [string]$text, [int]$x, [int]$y, [int]$w = 120) {
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $text
  $label.SetBounds($x, $y, $w, 18)
  $label.ForeColor = [Drawing.Color]::FromArgb(111, 98, 88)
  $label.Font = New-Object Drawing.Font("Segoe UI", 8, [Drawing.FontStyle]::Bold)
  $parent.Controls.Add($label)
  return $label
}

function Add-SectionTitle($parent, [string]$text, [int]$x, [int]$y, [int]$w = 220) {
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $text
  $label.SetBounds($x, $y, $w, 24)
  $label.ForeColor = [Drawing.Color]::FromArgb(33, 26, 22)
  $label.Font = New-Object Drawing.Font("Segoe UI", 11, [Drawing.FontStyle]::Bold)
  $parent.Controls.Add($label)
  return $label
}

function Set-DashboardGridStyle($grid, [object[]]$columns) {
  $grid.Font = New-Object Drawing.Font("Segoe UI", 8)
  $grid.BackColor = [Drawing.Color]::White
  $grid.Anchor = "Top,Left"
  $grid.AllowUserToAddRows = $false
  $grid.AllowUserToDeleteRows = $false
  $grid.ReadOnly = $true
  $grid.SelectionMode = "FullRowSelect"
  $grid.MultiSelect = $false
  $grid.RowHeadersVisible = $false
  $grid.AutoSizeColumnsMode = "None"
  $grid.BackgroundColor = [Drawing.Color]::White
  $grid.BorderStyle = "FixedSingle"
  $grid.ColumnHeadersVisible = $false
  $grid.GridColor = [Drawing.Color]::White
  $grid.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::None
  $grid.DefaultCellStyle.BackColor = [Drawing.Color]::White
  $grid.DefaultCellStyle.ForeColor = [Drawing.Color]::Black
  $grid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(238, 232, 224)
  $grid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::Black
  $grid.DefaultCellStyle.Font = New-Object Drawing.Font("Consolas", 9)
  $grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(2, 0, 2, 0)
  $grid.AlternatingRowsDefaultCellStyle.BackColor = [Drawing.Color]::White
  $grid.RowTemplate.Height = 18

  foreach ($column in $columns) {
    [void]$grid.Columns.Add($column[0], $column[1])
  }
}

function Set-ButtonStyle($button, [bool]$primary = $false) {
  $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $button.FlatAppearance.BorderSize = 1
  if ($primary) {
    $button.BackColor = [Drawing.Color]::FromArgb(79, 47, 36)
    $button.ForeColor = [Drawing.Color]::White
    $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(79, 47, 36)
  } else {
    $button.BackColor = [Drawing.Color]::FromArgb(255, 250, 243)
    $button.ForeColor = [Drawing.Color]::FromArgb(33, 26, 22)
    $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(196, 171, 148)
  }
}

function Set-InputStyle($control) {
  $control.Font = New-Object Drawing.Font("Segoe UI", 9)
  if ($control -is [System.Windows.Forms.TextBox]) {
    $control.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  }
}

function Add-Metric($parent, [string]$title, [int]$x) {
  $panel = New-Object System.Windows.Forms.Panel
  $panel.SetBounds($x, 58, 174, 72)
  $panel.BackColor = [Drawing.Color]::FromArgb(255, 250, 243)
  $panel.BorderStyle = "FixedSingle"
  $titleLabel = New-Object System.Windows.Forms.Label
  $titleLabel.Text = $title
  $titleLabel.SetBounds(10, 8, 150, 18)
  $titleLabel.ForeColor = [Drawing.Color]::FromArgb(111, 98, 88)
  $titleLabel.Font = New-Object Drawing.Font("Segoe UI", 8, [Drawing.FontStyle]::Bold)
  $valueLabel = New-Object System.Windows.Forms.Label
  $valueLabel.Text = "$0"
  $valueLabel.SetBounds(10, 28, 150, 32)
  $valueLabel.Font = New-Object Drawing.Font("Segoe UI", 16, [Drawing.FontStyle]::Bold)
  $valueLabel.ForeColor = [Drawing.Color]::FromArgb(33, 26, 22)
  $panel.Controls.AddRange(@($titleLabel, $valueLabel))
  $parent.Controls.Add($panel)
  return $valueLabel
}

function Set-ControlBounds($control, [int]$x, [int]$y, [int]$width, [int]$height) {
  $control.SetBounds($x, $y, [math]::Max(20, $width), [math]::Max(20, $height))
}

function Apply-MainLayout {
  if (-not $form -or -not $grid) { return }

  $margin = 18
  $gap = 14
  $leftWidth = 0
  $contentX = $margin
  $right = $form.ClientSize.Width - $margin
  $contentWidth = [math]::Max(760, $right - $contentX)

  $topButtonY = 18
  $buttonGap = 8
  $restoreButton.SetBounds($right - 100, $topButtonY, 100, 34)
  $backupButton.SetBounds($restoreButton.Left - $buttonGap - 100, $topButtonY, 100, 34)
  $exportButton.SetBounds($backupButton.Left - $buttonGap - 100, $topButtonY, 100, 34)
  $nameAccountsButton.SetBounds($exportButton.Left - $buttonGap - 116, $topButtonY, 116, 34)
  $importAccountsButton.SetBounds($nameAccountsButton.Left - $buttonGap - 116, $topButtonY, 116, 34)
  $importStatementButton.SetBounds($importAccountsButton.Left - $buttonGap - 116, $topButtonY, 116, 34)
  $refreshButton.SetBounds($importStatementButton.Left - $buttonGap - 90, $topButtonY, 90, 34)
  $settingsButton.SetBounds($refreshButton.Left - $buttonGap - 72, $topButtonY, 72, 34)
  $helpButton.SetBounds($settingsButton.Left - $buttonGap - 58, $topButtonY, 58, 34)
  $lastRefreshLabel.SetBounds($margin, 130, 360, 16)

  $inputPanel.SetBounds($margin, 146, 350, 500)

  $chartWidth = [math]::Floor(($contentWidth - $gap) / 2)
  $chart2X = $contentX + $chartWidth + $gap
  $chartTitleLabel.SetBounds($contentX, 142, 180, 22)
  $graphModeCombo.SetBounds($contentX + 190, 138, 180, 30)
  $chartTitleLabel2.SetBounds($chart2X, 142, 180, 22)
  $graphModeCombo2.SetBounds($chart2X + 190, 138, 180, 30)
  $weeklySavingsLabel.Visible = $false
  $weeklySavingsBox.Visible = $false
  $saveAllocationButton.Visible = $false
  $allocationTotalLabel.Visible = $false
  $projectionSummaryLabel.SetBounds($contentX, 505, $chartWidth, 18)
  $projectionSummaryLabel2.SetBounds($chart2X, 505, $chartWidth, 18)
  Set-ControlBounds $chart $contentX 166 $chartWidth 330
  Set-ControlBounds $chart2 $chart2X 166 $chartWidth 330
  Set-ControlBounds $chartDataTable $contentX 166 $chartWidth 330
  Set-ControlBounds $chartDataTable2 $chart2X 166 $chartWidth 330
  $chartDataTable.Columns["BudgetItem"].Width = 120
  $chartDataTable.Columns["BudgetAmount"].Width = 120
  $chartDataTable.Columns["BudgetDetail"].Width = [math]::Max(220, $chartWidth - 244)
  $chartDataTable2.Columns["BudgetItem"].Width = 110
  $chartDataTable2.Columns["BudgetAmount"].Width = 110
  $chartDataTable2.Columns["BudgetDetail"].Width = [math]::Max(180, $chartWidth - 224)
  $allocationTitleLabel.Visible = $false
  $allocationGrid.Visible = $false
  $allocationWarningLabel.Visible = $false

  $middleY = 526
  $listY = 560
  $filterY = 704
  $listHeight = $filterY - $listY - 14
  $middleAvailable = $contentWidth - ($gap * 3)
  $categoryWidth = [math]::Max(130, [math]::Floor($middleAvailable * 0.13))
  $balancesWidth = [math]::Max(200, [math]::Floor($middleAvailable * 0.22))
  $goalsWidth = [math]::Max(460, [math]::Floor($middleAvailable * 0.30))
  $recurringWidth = $middleAvailable - $categoryWidth - $balancesWidth - $goalsWidth
  if ($recurringWidth -lt 300) {
    $shortfall = 300 - $recurringWidth
    $categoryTrim = [math]::Min([math]::Max(0, $categoryWidth - 120), [math]::Ceiling($shortfall / 2))
    $balancesTrim = [math]::Min([math]::Max(0, $balancesWidth - 190), $shortfall - $categoryTrim)
    $categoryWidth -= $categoryTrim
    $balancesWidth -= $balancesTrim
    $recurringWidth = $middleAvailable - $categoryWidth - $balancesWidth - $goalsWidth
  }
  $categoryX = $contentX
  $balancesX = $categoryX + $categoryWidth + $gap
  $recurringX = $balancesX + $balancesWidth + $gap
  $goalsX = $recurringX + $recurringWidth + $gap

  $categoryTitleLabel.SetBounds($categoryX, $middleY, $categoryWidth, 24)
  Set-ControlBounds $categoryList $categoryX $listY $categoryWidth $listHeight
  $categoryList.Columns["CategoryAmount"].Width = 92
  $categoryList.Columns["CategoryName"].Width = [math]::Max(80, $categoryWidth - 94)

  $balancesTitleLabel.SetBounds($balancesX, $middleY, [math]::Max(90, $balancesWidth - 64), 24)
  $hideBalanceButton.SetBounds($balancesX + $balancesWidth - 58, $middleY - 2, 58, 28)
  Set-ControlBounds $accountBalancesList $balancesX $listY $balancesWidth $listHeight
  $accountBalancesList.Columns["BalanceAmount"].Width = 90
  $accountBalancesList.Columns["BalanceDate"].Width = 72
  $accountBalancesList.Columns["BalanceAccount"].Width = [math]::Max(110, $balancesWidth - 166)

  $recurringTitleLabel.SetBounds($recurringX, $middleY, [math]::Max(70, $recurringWidth - 170), 24)
  $editRecurringButton.SetBounds($recurringX + $recurringWidth - 166, $middleY - 2, 68, 28)
  $removeRecurringButton.SetBounds($recurringX + $recurringWidth - 90, $middleY - 2, 90, 28)
  $editRecurringButton.BringToFront()
  $removeRecurringButton.BringToFront()
  Set-ControlBounds $recurringPaymentsList $recurringX $listY $recurringWidth $listHeight
  $recurringPaymentsList.Columns["RecurringAmount"].Width = 96
  $recurringPaymentsList.Columns["RecurringFrequency"].Width = 104
  $recurringPaymentsList.Columns["RecurringDate"].Width = 82
  $recurringPaymentsList.Columns["RecurringName"].Width = [math]::Max(220, $recurringWidth - 300)

  $goalsTitle.SetBounds($goalsX, $middleY, [math]::Max(100, $goalsWidth - 270), 24)
  $deleteGoalButton.SetBounds($goalsX + $goalsWidth - 90, $middleY - 2, 90, 28)
  $editGoalButton.SetBounds($deleteGoalButton.Left - $buttonGap - 78, $middleY - 2, 78, 28)
  $addGoalButton.SetBounds($editGoalButton.Left - $buttonGap - 78, $middleY - 2, 78, 28)
  Set-ControlBounds $goalsList $goalsX $listY $goalsWidth $listHeight
  $goalsList.Columns["GoalMode"].Width = 42
  $goalsList.Columns["GoalProgress"].Width = 42
  $goalsList.Columns["GoalSaved"].Width = 82
  $goalsList.Columns["GoalTarget"].Width = 82
  $goalsList.Columns["GoalDate"].Width = 72
  $goalsList.Columns["GoalName"].Width = [math]::Max(110, $goalsWidth - 324)

  $viewCombo.SetBounds($margin, $filterY, 120, 28)
  $monthCombo.SetBounds($viewCombo.Right + 10, $filterY, 130, 28)
  $accountFilterCombo.SetBounds($monthCombo.Right + 10, $filterY, 200, 28)
  $searchBox.SetBounds($accountFilterCombo.Right + 10, $filterY, 260, 28)
  $sortCombo.SetBounds($searchBox.Right + 10, $filterY, 150, 28)
  $deleteButton.SetBounds($right - 120, $filterY - 2, 120, 32)
  $editButton.SetBounds($deleteButton.Left - $buttonGap - 112, $filterY - 2, 112, 32)
  $addRecurringButton.SetBounds($editButton.Left - $buttonGap - 122, $filterY - 2, 122, 32)
  $markIncomeButton.SetBounds($addRecurringButton.Left - $buttonGap - 112, $filterY - 2, 112, 32)
  $addEntryButton.SetBounds($markIncomeButton.Left - $buttonGap - 96, $filterY - 2, 96, 32)

  Set-ControlBounds $grid $margin ($filterY + 40) ($right - $margin) ($form.ClientSize.Height - ($filterY + 58))
}

Load-Entries

$form = New-Object System.Windows.Forms.Form
$form.Text = "Expense & Savings Tracker"
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object Drawing.Size(1260, 900)
$form.Size = New-Object Drawing.Size(1260, 900)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$form.MaximizeBox = $true
$form.BackColor = [Drawing.Color]::FromArgb(246, 240, 232)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Expense & Savings Tracker"
$title.SetBounds(18, 16, 280, 34)
$title.Font = New-Object Drawing.Font("Segoe UI", 20, [Drawing.FontStyle]::Bold)
$title.ForeColor = [Drawing.Color]::FromArgb(33, 26, 22)
$title.Anchor = "Top,Left"
$form.Controls.Add($title)

$importStatementButton = New-Object System.Windows.Forms.Button
$importStatementButton.Text = "Import Statement"
$importStatementButton.SetBounds(536, 18, 116, 34)
$importStatementButton.Anchor = "Top,Left"
$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = "Refresh"
$refreshButton.SetBounds(438, 18, 90, 34)
$refreshButton.Anchor = "Top,Left"
$settingsButton = New-Object System.Windows.Forms.Button
$settingsButton.Text = "Settings"
$settingsButton.SetBounds(358, 18, 72, 34)
$settingsButton.Anchor = "Top,Left"
$helpButton = New-Object System.Windows.Forms.Button
$helpButton.Text = "Help"
$helpButton.SetBounds(292, 18, 58, 34)
$helpButton.Anchor = "Top,Left"
$importAccountsButton = New-Object System.Windows.Forms.Button
$importAccountsButton.Text = "Import Accounts"
$importAccountsButton.SetBounds(660, 18, 116, 34)
$importAccountsButton.Anchor = "Top,Left"
$nameAccountsButton = New-Object System.Windows.Forms.Button
$nameAccountsButton.Text = "Name Accounts"
$nameAccountsButton.SetBounds(786, 18, 116, 34)
$nameAccountsButton.Anchor = "Top,Left"
$exportButton = New-Object System.Windows.Forms.Button
$exportButton.Text = "Export CSV"
$exportButton.SetBounds(910, 18, 100, 34)
$exportButton.Anchor = "Top,Left"
$backupButton = New-Object System.Windows.Forms.Button
$backupButton.Text = "Backup"
$backupButton.SetBounds(1018, 18, 100, 34)
$backupButton.Anchor = "Top,Left"
$restoreButton = New-Object System.Windows.Forms.Button
$restoreButton.Text = "Restore"
$restoreButton.SetBounds(1126, 18, 100, 34)
$restoreButton.Anchor = "Top,Left"
$form.Controls.AddRange(@($helpButton, $settingsButton, $refreshButton, $importStatementButton, $importAccountsButton, $nameAccountsButton, $exportButton, $backupButton, $restoreButton))
foreach ($button in @($helpButton, $settingsButton, $refreshButton, $importStatementButton, $importAccountsButton, $nameAccountsButton, $exportButton, $backupButton, $restoreButton)) { Set-ButtonStyle $button }

$lastRefreshLabel = New-Object System.Windows.Forms.Label
$lastRefreshLabel.Text = "Last refreshed: --"
$lastRefreshLabel.SetBounds(18, 130, 360, 16)
$lastRefreshLabel.ForeColor = [Drawing.Color]::FromArgb(111, 98, 88)
$lastRefreshLabel.Font = New-Object Drawing.Font("Segoe UI", 8)
$form.Controls.Add($lastRefreshLabel)

$remainingBudgetValue = Add-Metric $form "REMAINING BUDGET" 18
$billValue = Add-Metric $form "BILLS" 204
$progressValue = Add-Metric $form "PAYCHECK" 390
$savedBalanceValue = Add-Metric $form "MIN SAVINGS" 576
$minimumWeeklyValue = Add-Metric $form "SPEND" 762

$inputPanel = New-Object System.Windows.Forms.Panel
$inputPanel.SetBounds(18, 146, 350, 500)
$inputPanel.BackColor = [Drawing.Color]::FromArgb(255, 250, 243)
$inputPanel.BorderStyle = "FixedSingle"
$inputPanel.Anchor = "Top,Left"
$inputPanel.Visible = $false
$form.Controls.Add($inputPanel)

$inputTitle = New-Object System.Windows.Forms.Label
$inputTitle.Text = "Add Entry"
$inputTitle.SetBounds(18, 16, 160, 24)
$inputTitle.Font = New-Object Drawing.Font("Segoe UI", 12, [Drawing.FontStyle]::Bold)
$inputPanel.Controls.Add($inputTitle)

Add-Label $inputPanel "Type" 18 54 | Out-Null
$typeCombo = New-Object System.Windows.Forms.ComboBox
$typeCombo.DropDownStyle = "DropDownList"
$typeCombo.Items.AddRange(@("Expense", "Saving", "Bill", "Income"))
$typeCombo.SetBounds(18, 74, 146, 30)
Set-InputStyle $typeCombo
$inputPanel.Controls.Add($typeCombo)

Add-Label $inputPanel "Date" 180 54 | Out-Null
$datePicker = New-Object System.Windows.Forms.DateTimePicker
$datePicker.Format = "Short"
$datePicker.SetBounds(180, 74, 146, 30)
Set-InputStyle $datePicker
$inputPanel.Controls.Add($datePicker)

Add-Label $inputPanel "Name" 18 114 | Out-Null
$nameBox = New-Object System.Windows.Forms.TextBox
$nameBox.SetBounds(18, 134, 308, 30)
Set-InputStyle $nameBox
$inputPanel.Controls.Add($nameBox)

Add-Label $inputPanel "Category" 18 174 | Out-Null
$categoryCombo = New-Object System.Windows.Forms.ComboBox
$categoryCombo.DropDownStyle = "DropDownList"
$categoryCombo.SetBounds(18, 194, 146, 30)
Set-InputStyle $categoryCombo
$inputPanel.Controls.Add($categoryCombo)

Add-Label $inputPanel "Amount" 180 174 | Out-Null
$amountBox = New-Object System.Windows.Forms.NumericUpDown
$amountBox.DecimalPlaces = 2
$amountBox.Maximum = 100000000
$amountBox.ThousandsSeparator = $true
$amountBox.SetBounds(180, 194, 146, 30)
Set-InputStyle $amountBox
$inputPanel.Controls.Add($amountBox)

Add-Label $inputPanel "Account" 18 234 | Out-Null
$accountCombo = New-Object System.Windows.Forms.ComboBox
$accountCombo.DropDownStyle = "DropDownList"
$accountCombo.SetBounds(18, 254, 308, 30)
Set-InputStyle $accountCombo
$inputPanel.Controls.Add($accountCombo)

Add-Label $inputPanel "Note" 18 294 | Out-Null
$noteBox = New-Object System.Windows.Forms.TextBox
$noteBox.Multiline = $true
$noteBox.ScrollBars = "Vertical"
$noteBox.SetBounds(18, 314, 308, 116)
Set-InputStyle $noteBox
$inputPanel.Controls.Add($noteBox)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = "Add Entry"
$saveButton.SetBounds(18, 446, 146, 36)
$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = "Clear"
$clearButton.SetBounds(180, 446, 146, 36)
$inputPanel.Controls.AddRange(@($saveButton, $clearButton))
Set-ButtonStyle $saveButton $true
Set-ButtonStyle $clearButton

$chartTitleLabel = Add-SectionTitle $form "Monthly Flow" 386 142 220
$graphModeCombo = New-Object System.Windows.Forms.ComboBox
$graphModeCombo.DropDownStyle = "DropDownList"
$graphModeCombo.Items.AddRange(@("Savings Projection", "Monthly Flow", "Income vs Spend", "Savings Goals", "Balances", "Data Table"))
$graphModeCombo.SetBounds(596, 138, 190, 30)
Set-InputStyle $graphModeCombo
$form.Controls.Add($graphModeCombo)

$chartTitleLabel2 = Add-SectionTitle $form "Income vs Spend" 820 142 220
$graphModeCombo2 = New-Object System.Windows.Forms.ComboBox
$graphModeCombo2.DropDownStyle = "DropDownList"
$graphModeCombo2.Items.AddRange(@("Savings Projection", "Monthly Flow", "Income vs Spend", "Savings Goals", "Balances", "Data Table"))
$graphModeCombo2.SetBounds(1030, 138, 190, 30)
Set-InputStyle $graphModeCombo2
$form.Controls.Add($graphModeCombo2)

$projectionSummaryLabel = New-Object System.Windows.Forms.Label
$projectionSummaryLabel.SetBounds(666, 142, 560, 22)
$projectionSummaryLabel.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$projectionSummaryLabel.ForeColor = [Drawing.Color]::FromArgb(79, 68, 58)
$projectionSummaryLabel.Font = New-Object Drawing.Font("Segoe UI", 8, [Drawing.FontStyle]::Bold)
$projectionSummaryLabel.Visible = $false
$form.Controls.Add($projectionSummaryLabel)

$projectionSummaryLabel2 = New-Object System.Windows.Forms.Label
$projectionSummaryLabel2.SetBounds(1030, 142, 560, 22)
$projectionSummaryLabel2.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$projectionSummaryLabel2.ForeColor = [Drawing.Color]::FromArgb(79, 68, 58)
$projectionSummaryLabel2.Font = New-Object Drawing.Font("Segoe UI", 8, [Drawing.FontStyle]::Bold)
$projectionSummaryLabel2.Visible = $false
$form.Controls.Add($projectionSummaryLabel2)

$chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
$chart.SetBounds(386, 166, 840, 248)
$chart.BackColor = [Drawing.Color]::White
$chart.Anchor = "Top,Left"
$chartArea = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
$chartArea.BackColor = [Drawing.Color]::White
$chartArea.AxisX.MajorGrid.LineColor = [Drawing.Color]::FromArgb(228, 216, 204)
$chartArea.AxisY.MajorGrid.LineColor = [Drawing.Color]::FromArgb(228, 216, 204)
$chartArea.AxisY.LabelStyle.Format = "C0"
$chartArea.AxisX.Interval = 1
$chartArea.AxisX.LabelStyle.Font = New-Object Drawing.Font("Segoe UI", 8)
$chartArea.AxisY.LabelStyle.Font = New-Object Drawing.Font("Segoe UI", 8)
$chartArea.Position.Auto = $false
$chartArea.Position.X = 5
$chartArea.Position.Y = 8
$chartArea.Position.Width = 88
$chartArea.Position.Height = 84
$chartArea.InnerPlotPosition.Auto = $false
$chartArea.InnerPlotPosition.X = 12
$chartArea.InnerPlotPosition.Y = 5
$chartArea.InnerPlotPosition.Width = 80
$chartArea.InnerPlotPosition.Height = 78
$chart.ChartAreas.Add($chartArea)
$legend = New-Object System.Windows.Forms.DataVisualization.Charting.Legend
$legend.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Right
$legend.Font = New-Object Drawing.Font("Segoe UI", 8)
$chart.Legends.Add($legend)
$form.Controls.Add($chart)

$chartDataTable = New-Object System.Windows.Forms.DataGridView
$chartDataTable.SetBounds(386, 166, 840, 248)
Set-DashboardGridStyle $chartDataTable @(
  @("BudgetItem", "Item"),
  @("BudgetAmount", "Amount"),
  @("BudgetDetail", "Detail")
)
$chartDataTable.ColumnHeadersVisible = $true
$chartDataTable.EnableHeadersVisualStyles = $false
$chartDataTable.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(241, 229, 216)
$chartDataTable.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(33, 26, 22)
$chartDataTable.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font("Segoe UI", 8, [Drawing.FontStyle]::Bold)
$chartDataTable.Columns["BudgetAmount"].DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleRight
$chartDataTable.Visible = $false
$form.Controls.Add($chartDataTable)

$chart2 = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
$chart2.SetBounds(820, 166, 400, 330)
$chart2.BackColor = [Drawing.Color]::White
$chart2.Anchor = "Top,Left"
$chartArea2 = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
$chartArea2.BackColor = [Drawing.Color]::White
$chartArea2.AxisX.MajorGrid.LineColor = [Drawing.Color]::FromArgb(228, 216, 204)
$chartArea2.AxisY.MajorGrid.LineColor = [Drawing.Color]::FromArgb(228, 216, 204)
$chartArea2.AxisY.LabelStyle.Format = "C0"
$chartArea2.AxisX.Interval = 1
$chartArea2.AxisX.LabelStyle.Font = New-Object Drawing.Font("Segoe UI", 8)
$chartArea2.AxisY.LabelStyle.Font = New-Object Drawing.Font("Segoe UI", 8)
$chartArea2.Position.Auto = $false
$chartArea2.Position.X = 5
$chartArea2.Position.Y = 8
$chartArea2.Position.Width = 88
$chartArea2.Position.Height = 84
$chartArea2.InnerPlotPosition.Auto = $false
$chartArea2.InnerPlotPosition.X = 12
$chartArea2.InnerPlotPosition.Y = 5
$chartArea2.InnerPlotPosition.Width = 80
$chartArea2.InnerPlotPosition.Height = 78
$chart2.ChartAreas.Add($chartArea2)
$legend2 = New-Object System.Windows.Forms.DataVisualization.Charting.Legend
$legend2.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Right
$legend2.Font = New-Object Drawing.Font("Segoe UI", 8)
$chart2.Legends.Add($legend2)
$form.Controls.Add($chart2)

$chartDataTable2 = New-Object System.Windows.Forms.DataGridView
$chartDataTable2.SetBounds(820, 166, 400, 330)
Set-DashboardGridStyle $chartDataTable2 @(
  @("BudgetItem", "Item"),
  @("BudgetAmount", "Amount"),
  @("BudgetDetail", "Detail")
)
$chartDataTable2.ColumnHeadersVisible = $true
$chartDataTable2.EnableHeadersVisualStyles = $false
$chartDataTable2.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(241, 229, 216)
$chartDataTable2.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(33, 26, 22)
$chartDataTable2.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font("Segoe UI", 8, [Drawing.FontStyle]::Bold)
$chartDataTable2.Columns["BudgetAmount"].DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleRight
$chartDataTable2.Visible = $false
$form.Controls.Add($chartDataTable2)

$allocationTitleLabel = Add-SectionTitle $form "Weekly Savings Allocation" 386 382 240

$weeklySavingsLabel = New-Object System.Windows.Forms.Label
$weeklySavingsLabel.Text = "Weekly available"
$weeklySavingsLabel.SetBounds(636, 385, 130, 18)
$weeklySavingsLabel.ForeColor = [Drawing.Color]::FromArgb(111, 98, 88)
$weeklySavingsLabel.Font = New-Object Drawing.Font("Segoe UI", 8, [Drawing.FontStyle]::Bold)
$form.Controls.Add($weeklySavingsLabel)

$weeklySavingsBox = New-Object System.Windows.Forms.NumericUpDown
$weeklySavingsBox.DecimalPlaces = 2
$weeklySavingsBox.Maximum = 10000000
$weeklySavingsBox.ThousandsSeparator = $true
$weeklySavingsBox.SetBounds(768, 381, 118, 28)
$weeklySavingsBox.Value = [math]::Min([decimal]$weeklySavingsBox.Maximum, [math]::Max([decimal]0, $script:WeeklyAvailableSavings))
Set-InputStyle $weeklySavingsBox
$form.Controls.Add($weeklySavingsBox)

$saveAllocationButton = New-Object System.Windows.Forms.Button
$saveAllocationButton.Text = "Save Plan"
$saveAllocationButton.SetBounds(900, 380, 118, 30)
Set-ButtonStyle $saveAllocationButton
$form.Controls.Add($saveAllocationButton)

$allocationTotalLabel = New-Object System.Windows.Forms.Label
$allocationTotalLabel.SetBounds(1032, 384, 320, 20)
$allocationTotalLabel.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
$allocationTotalLabel.ForeColor = [Drawing.Color]::FromArgb(79, 68, 58)
$allocationTotalLabel.Font = New-Object Drawing.Font("Segoe UI", 8, [Drawing.FontStyle]::Bold)
$form.Controls.Add($allocationTotalLabel)

$allocationGrid = New-Object System.Windows.Forms.DataGridView
$allocationGrid.SetBounds(386, 418, 840, 78)
$allocationGrid.Font = New-Object Drawing.Font("Segoe UI", 8)
$allocationGrid.BackColor = [Drawing.Color]::White
$allocationGrid.Anchor = "Top,Left"
$allocationGrid.AllowUserToAddRows = $false
$allocationGrid.AllowUserToDeleteRows = $false
$allocationGrid.ReadOnly = $true
$allocationGrid.SelectionMode = "FullRowSelect"
$allocationGrid.MultiSelect = $false
$allocationGrid.RowHeadersVisible = $false
$allocationGrid.AutoSizeColumnsMode = "None"
$allocationGrid.BackgroundColor = [Drawing.Color]::White
$allocationGrid.BorderStyle = "FixedSingle"
$allocationGrid.EnableHeadersVisualStyles = $false
$allocationGrid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(241, 229, 216)
$allocationGrid.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(33, 26, 22)
$allocationGrid.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font("Segoe UI", 8, [Drawing.FontStyle]::Bold)
$allocationGrid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(49, 92, 114)
$allocationGrid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::White
$allocationGrid.AlternatingRowsDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(252, 248, 242)
$allocationGrid.RowTemplate.Height = 20
foreach ($column in @(
  @("AllocationGoal", "Goal"),
  @("AllocationAmount", "Suggested"),
  @("AllocationRequired", "Required/wk"),
  @("AllocationCompletion", "Completion"),
  @("AllocationStatus", "Status")
)) {
  [void]$allocationGrid.Columns.Add($column[0], $column[1])
}
$form.Controls.Add($allocationGrid)

$allocationWarningLabel = New-Object System.Windows.Forms.Label
$allocationWarningLabel.SetBounds(386, 500, 840, 18)
$allocationWarningLabel.ForeColor = [Drawing.Color]::FromArgb(180, 35, 24)
$allocationWarningLabel.Font = New-Object Drawing.Font("Segoe UI", 8, [Drawing.FontStyle]::Bold)
$form.Controls.Add($allocationWarningLabel)

$categoryTitleLabel = Add-SectionTitle $form "Category Spend" 386 424 220
$categoryList = New-Object System.Windows.Forms.DataGridView
$categoryList.SetBounds(386, 458, 260, 180)
Set-DashboardGridStyle $categoryList @(
  @("CategoryName", "Category"),
  @("CategoryAmount", "Amount")
)
$categoryList.Columns["CategoryAmount"].DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleRight
$form.Controls.Add($categoryList)

$balancesTitleLabel = Add-SectionTitle $form "Current Balances" 666 424 220
$hideBalanceButton = New-Object System.Windows.Forms.Button
$hideBalanceButton.Text = "Hide"
$hideBalanceButton.SetBounds(936, 422, 58, 28)
$hideBalanceButton.Anchor = "Top,Left"
Set-ButtonStyle $hideBalanceButton
$form.Controls.Add($hideBalanceButton)

$accountBalancesList = New-Object System.Windows.Forms.DataGridView
$accountBalancesList.SetBounds(666, 458, 330, 180)
Set-DashboardGridStyle $accountBalancesList @(
  @("BalanceAccount", "Account"),
  @("BalanceAmount", "Balance"),
  @("BalanceDate", "Date")
)
$accountBalancesList.Columns["BalanceAmount"].DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleRight
$accountBalancesList.Columns["BalanceDate"].DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter
$form.Controls.Add($accountBalancesList)

$recurringTitleLabel = Add-SectionTitle $form "Recurring Payments" 848 424 220
$editRecurringButton = New-Object System.Windows.Forms.Button
$editRecurringButton.Text = "Edit"
$editRecurringButton.SetBounds(916, 422, 68, 28)
$editRecurringButton.Anchor = "Top,Left"
Set-ButtonStyle $editRecurringButton
$form.Controls.Add($editRecurringButton)

$removeRecurringButton = New-Object System.Windows.Forms.Button
$removeRecurringButton.Text = "Remove"
$removeRecurringButton.SetBounds(992, 422, 90, 28)
$removeRecurringButton.Anchor = "Top,Left"
Set-ButtonStyle $removeRecurringButton
$form.Controls.Add($removeRecurringButton)

$recurringPaymentsList = New-Object System.Windows.Forms.DataGridView
$recurringPaymentsList.SetBounds(848, 458, 240, 180)
Set-DashboardGridStyle $recurringPaymentsList @(
  @("RecurringName", "Name"),
  @("RecurringAmount", "Amount"),
  @("RecurringFrequency", "Frequency"),
  @("RecurringDate", "Date")
)
$recurringPaymentsList.Columns["RecurringName"].FillWeight = 330
$recurringPaymentsList.Columns["RecurringAmount"].FillWeight = 75
$recurringPaymentsList.Columns["RecurringFrequency"].FillWeight = 78
$recurringPaymentsList.Columns["RecurringDate"].FillWeight = 58
$recurringPaymentsList.Columns["RecurringAmount"].DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleRight
$recurringPaymentsList.Columns["RecurringFrequency"].DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter
$recurringPaymentsList.Columns["RecurringDate"].DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter
$form.Controls.Add($recurringPaymentsList)

$goalsTitle = Add-SectionTitle $form "Savings Goals" 946 424 160
$goalsTitle.Anchor = "Top,Left"
$addGoalButton = New-Object System.Windows.Forms.Button
$addGoalButton.Text = "Add Goal"
$addGoalButton.SetBounds(964, 422, 78, 28)
$addGoalButton.Anchor = "Top,Left"
$editGoalButton = New-Object System.Windows.Forms.Button
$editGoalButton.Text = "Edit Goal"
$editGoalButton.SetBounds(1050, 422, 78, 28)
$editGoalButton.Anchor = "Top,Left"
$deleteGoalButton = New-Object System.Windows.Forms.Button
$deleteGoalButton.Text = "Delete Goal"
$deleteGoalButton.SetBounds(1136, 422, 90, 28)
$deleteGoalButton.Anchor = "Top,Left"
$form.Controls.AddRange(@($addGoalButton, $editGoalButton, $deleteGoalButton))
foreach ($button in @($addGoalButton, $editGoalButton, $deleteGoalButton)) { Set-ButtonStyle $button }

$goalsList = New-Object System.Windows.Forms.DataGridView
$goalsList.SetBounds(946, 458, 280, 180)
Set-DashboardGridStyle $goalsList @(
  @("GoalName", "Goal"),
  @("GoalMode", "Type"),
  @("GoalProgress", "%"),
  @("GoalSaved", "Saved"),
  @("GoalTarget", "Target"),
  @("GoalDate", "Date")
)
$goalsList.Columns["GoalMode"].DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter
$goalsList.Columns["GoalProgress"].DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter
$goalsList.Columns["GoalSaved"].DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleRight
$goalsList.Columns["GoalTarget"].DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleRight
$goalsList.Columns["GoalDate"].DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter
$form.Controls.Add($goalsList)

$viewCombo = New-Object System.Windows.Forms.ComboBox
$viewCombo.DropDownStyle = "DropDownList"
$viewCombo.Items.AddRange(@("All", "Expense", "Saving", "Bill", "Income"))
$viewCombo.SetBounds(18, 652, 120, 28)
$form.Controls.Add($viewCombo)

$monthCombo = New-Object System.Windows.Forms.ComboBox
$monthCombo.DropDownStyle = "DropDownList"
$monthCombo.SetBounds(148, 652, 130, 28)
$form.Controls.Add($monthCombo)

$accountFilterCombo = New-Object System.Windows.Forms.ComboBox
$accountFilterCombo.DropDownStyle = "DropDownList"
$accountFilterCombo.SetBounds(288, 652, 150, 28)
$form.Controls.Add($accountFilterCombo)

$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.SetBounds(448, 652, 230, 28)
$form.Controls.Add($searchBox)

$sortCombo = New-Object System.Windows.Forms.ComboBox
$sortCombo.DropDownStyle = "DropDownList"
$sortCombo.Items.AddRange(@("Newest first", "Oldest first", "Highest amount", "Lowest amount"))
$sortCombo.SetBounds(688, 652, 150, 28)
$form.Controls.Add($sortCombo)

$addRecurringButton = New-Object System.Windows.Forms.Button
$addRecurringButton.Text = "Add Recurring"
$addRecurringButton.SetBounds(880, 650, 122, 32)
$addRecurringButton.Anchor = "Top,Left"
$markIncomeButton = New-Object System.Windows.Forms.Button
$markIncomeButton.Text = "Mark Income"
$markIncomeButton.SetBounds(760, 650, 112, 32)
$markIncomeButton.Anchor = "Top,Left"
$addEntryButton = New-Object System.Windows.Forms.Button
$addEntryButton.Text = "Add Entry"
$addEntryButton.SetBounds(656, 650, 96, 32)
$addEntryButton.Anchor = "Top,Left"
$editButton = New-Object System.Windows.Forms.Button
$editButton.Text = "Edit Selected"
$editButton.SetBounds(1010, 650, 104, 32)
$editButton.Anchor = "Top,Left"
$deleteButton = New-Object System.Windows.Forms.Button
$deleteButton.Text = "Delete Selected"
$deleteButton.SetBounds(1122, 650, 104, 32)
$deleteButton.Anchor = "Top,Left"
$form.Controls.AddRange(@($addEntryButton, $markIncomeButton, $addRecurringButton, $editButton, $deleteButton))
Set-ButtonStyle $addEntryButton
Set-ButtonStyle $markIncomeButton
Set-ButtonStyle $addRecurringButton
Set-ButtonStyle $editButton
Set-ButtonStyle $deleteButton

$grid = New-Object System.Windows.Forms.DataGridView
$grid.SetBounds(18, 692, 1208, 162)
$grid.Anchor = "Left,Right,Top,Bottom"
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.ReadOnly = $true
$grid.SelectionMode = "FullRowSelect"
$grid.MultiSelect = $true
$grid.RowHeadersVisible = $false
$grid.AutoSizeColumnsMode = "Fill"
$grid.BackgroundColor = [Drawing.Color]::White
$grid.BorderStyle = "FixedSingle"
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(241, 229, 216)
$grid.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(33, 26, 22)
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font("Segoe UI", 8, [Drawing.FontStyle]::Bold)
$grid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(49, 92, 114)
$grid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::White
$grid.AlternatingRowsDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(252, 248, 242)
foreach ($column in @(
  @("Date", "Date"),
  @("Name", "Narrative / Name"),
  @("Category", "Category"),
  @("Account", "Account"),
  @("Frequency", "Frequency"),
  @("Amount", "Amount"),
  @("BankCategory", "Bank Category"),
  @("Note", "Note")
)) {
  [void]$grid.Columns.Add($column[0], $column[1])
}
$grid.Columns["Name"].FillWeight = 150
$grid.Columns["Note"].FillWeight = 170
$form.Controls.Add($grid)

$typeCombo.Add_SelectedIndexChanged({ Refresh-Categories })
$accountCombo.Add_SelectedIndexChanged({ Add-NewEntryAccount })
$saveButton.Add_Click({ Save-FormEntry })
$clearButton.Add_Click({ Reset-Form; $inputPanel.Visible = $false })
$weeklySavingsBox.Add_ValueChanged({
  if ($script:UpdatingWeeklySavingsBox) { return }
  $script:WeeklyAvailableSavings = [decimal]$weeklySavingsBox.Value
  Save-Entries
  Refresh-Chart
  Refresh-Allocation
})
$saveAllocationButton.Add_Click({ Save-WeeklyAllocationPlan })
$graphModeCombo.Add_SelectedIndexChanged({
  try {
    Refresh-Chart
  } catch {
    if ($chartTitleLabel) { $chartTitleLabel.Text = "Chart Error" }
    if ($projectionSummaryLabel) { $projectionSummaryLabel.Text = $_.Exception.Message }
  }
})
$graphModeCombo2.Add_SelectedIndexChanged({
  try {
    Refresh-Chart
  } catch {
    if ($chartTitleLabel2) { $chartTitleLabel2.Text = "Chart Error" }
    if ($projectionSummaryLabel2) { $projectionSummaryLabel2.Text = $_.Exception.Message }
  }
})
$viewCombo.Add_SelectedIndexChanged({ Refresh-Grid })
$monthCombo.Add_SelectedIndexChanged({
  Refresh-Summary
  try { Refresh-Chart } catch { if ($projectionSummaryLabel) { $projectionSummaryLabel.Text = $_.Exception.Message } }
  Refresh-Breakdowns
  Refresh-Grid
})
$accountFilterCombo.Add_SelectedIndexChanged({
  Refresh-Summary
  try { Refresh-Chart } catch { if ($projectionSummaryLabel) { $projectionSummaryLabel.Text = $_.Exception.Message } }
  Refresh-Breakdowns
  Refresh-Grid
})
$searchBox.Add_TextChanged({ Refresh-Grid })
$sortCombo.Add_SelectedIndexChanged({ Refresh-Grid })
$addEntryButton.Add_Click({ Show-EntryPanel })
$markIncomeButton.Add_Click({ Mark-SelectedIncome })
$addRecurringButton.Add_Click({ Add-SelectedRecurringPayment })
$editButton.Add_Click({ Edit-SelectedEntry })
$deleteButton.Add_Click({ Delete-SelectedEntry })
$grid.Add_CellDoubleClick({ Edit-SelectedEntry })
$hideBalanceButton.Add_Click({ Hide-SelectedBalanceAccount })
$addGoalButton.Add_Click({ Add-SavingsGoal })
$editGoalButton.Add_Click({ Edit-SavingsGoal })
$deleteGoalButton.Add_Click({ Delete-SavingsGoal })
$goalsList.Add_DoubleClick({ Edit-SavingsGoal })
$editRecurringButton.Add_Click({ Edit-RecurringPayment })
$removeRecurringButton.Add_Click({ Remove-RecurringPayment })
$recurringPaymentsList.Add_DoubleClick({ Edit-RecurringPayment })
$recurringPaymentsList.Add_KeyDown({
  if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Delete) {
    Remove-RecurringPayment
  }
})
$importStatementButton.Add_Click({ Import-BankStatement })
$importAccountsButton.Add_Click({ Import-AccountsCsv })
$nameAccountsButton.Add_Click({ Manage-AccountNames })
$refreshButton.Add_Click({ Refresh-AppData })
$settingsButton.Add_Click({ Show-SettingsDialog })
$helpButton.Add_Click({ Show-HelpDialog })
$exportButton.Add_Click({ Export-Csv })
$backupButton.Add_Click({ Export-Backup })
$restoreButton.Add_Click({ Import-Backup })

$viewCombo.SelectedItem = "All"
$sortCombo.SelectedItem = "Newest first"
$graphModeCombo.SelectedItem = if ($graphModeCombo.Items.Contains([string]$script:Settings.LeftGraphDefault)) { [string]$script:Settings.LeftGraphDefault } else { "Data Table" }
$graphModeCombo2.SelectedItem = if ($graphModeCombo2.Items.Contains([string]$script:Settings.RightGraphDefault)) { [string]$script:Settings.RightGraphDefault } else { "Income vs Spend" }
Reset-Form
Refresh-All
Apply-MainLayout
$form.Add_Resize({ Apply-MainLayout })

[void]$form.ShowDialog()
