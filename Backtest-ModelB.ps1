#requires -Version 5.1
<#
STEP 2 - Model B: relative-pullback entry rule, backtestable across the full 2-year
history because it's not anchored to today's price (unlike Model A's fixed dollar
thresholds). Entry definition: red day AND price is X% or more below its trailing
20-day high. Sweeps several X values to see which depth (if any) shows an edge.
Does not touch config.json, PortfolioBot.ps1, or Model A's live thresholds in any
way - this is a separate, read-only comparison. Manual run only, no Telegram, no
scheduled task.
#>

param([string]$ConfigPath = "")

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir "config.json" }
. (Join-Path $ScriptDir "Indicators.ps1")
. (Join-Path $ScriptDir "BacktestCommon.ps1")

$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$callDelay = if ($Config.requestDelaySeconds) { $Config.requestDelaySeconds } else { 14 }
$thresholds = @(5, 8, 12, 18)

$tickerProps = $Config.tickers.PSObject.Properties
$combined = @{}
foreach ($x in $thresholds) { $combined[$x] = New-Bucket }
$allDaysCombined = New-Bucket

$report = @()
$report += "BACKTEST - STEP 2: MODEL B (relative pullback from 20-day high)"
$report += "Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') UK"
$report += "Entry: red day AND price >= X% below its trailing 20-day high. Sweeping X so we"
$report += "see which depth (if any) shows an edge, rather than guessing one number."
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
        $report += "$ticker : could not build series, skipped"
        $report += ""
        continue
    }

    $allDays = New-Bucket
    $perTicker = @{}
    foreach ($x in $thresholds) { $perTicker[$x] = New-Bucket }

    foreach ($d in $days) {
        Add-ToBucket -Bucket $allDays -Close $hist.Close -Index $d.Index
        Add-ToBucket -Bucket $allDaysCombined -Close $hist.Close -Index $d.Index

        if (-not $d.IsRedDay -or $null -eq $d.PctBelowHigh) { continue }
        $depthBelowHigh = -$d.PctBelowHigh   # PctBelowHigh is negative-or-zero; flip sign for readability

        foreach ($x in $thresholds) {
            if ($depthBelowHigh -ge $x) {
                Add-ToBucket -Bucket $perTicker[$x] -Close $hist.Close -Index $d.Index
                Add-ToBucket -Bucket $combined[$x] -Close $hist.Close -Index $d.Index
            }
        }
    }

    $report += "$ticker  ($($days.Count) trading days, $($hist.Date[0]) to $($hist.Date[-1]))"
    $report += (Format-BucketRow -Label "ALL DAYS (baseline)" -Bucket $allDays)
    foreach ($x in $thresholds) {
        $report += (Format-BucketRow -Label ">=$x% below 20d high" -Bucket $perTicker[$x])
    }
    $report += ""
}

$report += "===================================================================="
$report += "COMBINED ACROSS ALL TICKERS"
$report += (Format-BucketRow -Label "ALL DAYS (baseline)" -Bucket $allDaysCombined)
foreach ($x in $thresholds) {
    $report += (Format-BucketRow -Label ">=$x% below 20d high" -Bucket $combined[$x])
}
$report += ""
$report += "Reading this: entries get rarer and (usually) more extreme as X grows. Look for"
$report += "where win rate/avg return peaks relative to baseline - that's the depth worth"
$report += "actually using, not the deepest or shallowest number tested."

$text = $report -join "`n"
Write-Host $text

$outPath = Join-Path $ScriptDir "backtest-step2-results.txt"
Set-Content -Path $outPath -Value $text
Write-Host "`nSaved to $outPath"
