#requires -Version 5.1
<#
STEP 1 - Indicator layer backtest. Tests whether the RSI/Bollinger confirmation
and the KAMA suppression filter actually correlate with better outcomes, entirely
independent of the specific dollar buyBelow/strongBuyBelow/waitAbove thresholds in
config.json (which are anchored to today's price and can't be meaningfully replayed
against 2-year-old prices). This only answers "is the confirmation logic doing
something real," not "are today's thresholds good" - that's what Model B (Step 2)
and the live signal journal are for.

Manual run only. Not scheduled, sends no Telegram message, does not touch the
live thresholds.
#>

param([string]$ConfigPath = "")

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir "config.json" }
. (Join-Path $ScriptDir "Indicators.ps1")
. (Join-Path $ScriptDir "BacktestCommon.ps1")

$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$callDelay = if ($Config.requestDelaySeconds) { $Config.requestDelaySeconds } else { 14 }

$tickerProps = $Config.tickers.PSObject.Properties
$allDaysCombined = New-Bucket
$redDaysCombined = New-Bucket
$strongCombined = New-Bucket
$watchCombined = New-Bucket
$suppressedCombined = New-Bucket

$report = @()
$report += "BACKTEST - STEP 1: INDICATOR LAYER"
$report += "Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') UK"
$report += "Question: does RSI<=35-or-price<=lowerBand confirmation, and 3-day-KAMA-decline"
$report += "suppression, correlate with better forward returns than an unconditional day?"
$report += ""

foreach ($prop in $tickerProps) {
    $ticker = $prop.Name
    $info = $prop.Value
    Write-Host "Fetching history for $ticker..."

    $hist = $null
    if ($info.exchange -in @("NASDAQ", "NYSE")) {
        $hist = Get-FullHistoryTD -Symbol $ticker -ApiKey $Config.twelveDataApiKey -OutputSize 500
        Start-Sleep -Seconds $callDelay
    } elseif ($info.avSymbol) {
        $hist = Get-FullHistoryAV -Symbol $info.avSymbol -ApiKey $Config.alphaVantageApiKey -InPence:($info.quoteInPence -eq $true)
        Start-Sleep -Seconds 2
    }

    if (-not $hist -or $hist.Close.Count -lt 100) {
        $report += "$ticker : insufficient history, skipped"
        $report += ""
        continue
    }

    $days = Get-DailySeries -History $hist -BurnIn 50
    if (-not $days) {
        $report += "$ticker : could not build indicator series, skipped"
        $report += ""
        continue
    }

    $allDays = New-Bucket
    $redDays = New-Bucket
    $strong = New-Bucket
    $watch = New-Bucket
    $suppressed = New-Bucket

    foreach ($d in $days) {
        Add-ToBucket -Bucket $allDays -Close $hist.Close -Index $d.Index
        Add-ToBucket -Bucket $allDaysCombined -Close $hist.Close -Index $d.Index

        if (-not $d.IsRedDay) { continue }
        Add-ToBucket -Bucket $redDays -Close $hist.Close -Index $d.Index
        Add-ToBucket -Bucket $redDaysCombined -Close $hist.Close -Index $d.Index

        if ($null -eq $d.RSI -or $null -eq $d.LowerBand) { continue }
        $isOversold = ($d.RSI -le 35) -or ($d.Close -le $d.LowerBand)

        if (-not $isOversold) {
            Add-ToBucket -Bucket $watch -Close $hist.Close -Index $d.Index
            Add-ToBucket -Bucket $watchCombined -Close $hist.Close -Index $d.Index
            continue
        }

        if (Test-KamaDowntrend -Price $d.Close -KamaRecent $d.KamaRecent) {
            Add-ToBucket -Bucket $suppressed -Close $hist.Close -Index $d.Index
            Add-ToBucket -Bucket $suppressedCombined -Close $hist.Close -Index $d.Index
        } elseif ($d.RSI -le 35 -or $d.Close -le $d.LowerBand) {
            Add-ToBucket -Bucket $strong -Close $hist.Close -Index $d.Index
            Add-ToBucket -Bucket $strongCombined -Close $hist.Close -Index $d.Index
        }
    }

    $report += "$ticker  ($($days.Count) trading days evaluated, $($hist.Date[0]) to $($hist.Date[-1]))"
    $report += (Format-BucketRow -Label "ALL DAYS (baseline)" -Bucket $allDays)
    $report += (Format-BucketRow -Label "RED DAYS (baseline)" -Bucket $redDays)
    $report += (Format-BucketRow -Label "STRONG (RSI/BB confirmed)" -Bucket $strong)
    $report += (Format-BucketRow -Label "WATCH (unconfirmed)" -Bucket $watch)
    $report += (Format-BucketRow -Label "KAMA-SUPPRESSED" -Bucket $suppressed)
    $report += ""
}

$report += "===================================================================="
$report += "COMBINED ACROSS ALL TICKERS"
$report += (Format-BucketRow -Label "ALL DAYS (baseline)" -Bucket $allDaysCombined)
$report += (Format-BucketRow -Label "RED DAYS (baseline)" -Bucket $redDaysCombined)
$report += (Format-BucketRow -Label "STRONG (RSI/BB confirmed)" -Bucket $strongCombined)
$report += (Format-BucketRow -Label "WATCH (unconfirmed)" -Bucket $watchCombined)
$report += (Format-BucketRow -Label "KAMA-SUPPRESSED" -Bucket $suppressedCombined)
$report += ""
$report += "Reading this: if STRONG's win rate/avg return beats ALL DAYS and RED DAYS,"
$report += "the confirmation layer is adding real value. If KAMA-SUPPRESSED's forward"
$report += "returns are worse than STRONG's, the trend filter is correctly avoiding bad entries."
$report += "If the numbers are all close together, the filters aren't doing much - worth knowing"
$report += "before trusting them, not after."

$text = $report -join "`n"
Write-Host $text

$outPath = Join-Path $ScriptDir "backtest-step1-results.txt"
Set-Content -Path $outPath -Value $text
Write-Host "`nSaved to $outPath"
