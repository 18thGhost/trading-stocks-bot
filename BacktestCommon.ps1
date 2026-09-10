#requires -Version 5.1
<#
Shared backtest plumbing used by Backtest-IndicatorLayer.ps1 and Backtest-ModelB.ps1.
Not a scheduled job - run manually, produces a results file, never sends Telegram
alerts or touches config.json's live thresholds.

Correctness note on look-ahead bias: RSI, Bollinger Bands, ATR, and KAMA as
implemented in Indicators.ps1 are all causal - each index's value depends only on
bars at or before that index (RSI/ATR/KAMA via recursive smoothing from the start,
Bollinger via a trailing window ending at the index). That means computing each
indicator's full series ONCE over the whole history and then reading values off at
each historical index is NOT look-ahead bias for these specific indicators - it
would be wrong for something like a full-period z-score, but RSI/BB/ATR/KAMA don't
have that problem by construction.
#>

function Get-FullHistoryTD {
    param([string]$Symbol, [string]$ApiKey, [int]$OutputSize = 500)
    try {
        $url = "https://api.twelvedata.com/time_series?symbol=$Symbol&interval=1day&outputsize=$OutputSize&apikey=$ApiKey"
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 30
        if ($resp.status -eq "error" -or -not $resp.values) { return $null }
        $bars = $resp.values | Sort-Object { [datetime]$_.datetime }
        return @{
            Date  = @($bars | ForEach-Object { $_.datetime })
            High  = @($bars | ForEach-Object { [double]$_.high })
            Low   = @($bars | ForEach-Object { [double]$_.low })
            Close = @($bars | ForEach-Object { [double]$_.close })
        }
    } catch {
        return $null
    }
}

function Get-FullHistoryAV {
    param([string]$Symbol, [string]$ApiKey, [bool]$InPence = $false)
    try {
        $url = "https://www.alphavantage.co/query?function=TIME_SERIES_DAILY&symbol=$Symbol&outputsize=full&apikey=$ApiKey"
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 30
        $series = $resp.'Time Series (Daily)'
        if (-not $series) { return $null }
        $dates = $series.PSObject.Properties.Name | Sort-Object
        $divisor = if ($InPence) { 100.0 } else { 1.0 }
        return @{
            Date  = @($dates)
            High  = @($dates | ForEach-Object { [double]$series.$_.'2. high' / $divisor })
            Low   = @($dates | ForEach-Object { [double]$series.$_.'3. low' / $divisor })
            Close = @($dates | ForEach-Object { [double]$series.$_.'4. close' / $divisor })
        }
    } catch {
        return $null
    }
}

<#
Computes every derived per-day field once: RSI, Bollinger, ATR, KAMA (+ trailing
4 for the suppression check), red-day flag, and rolling 20-day high / % below it.
Both backtest scripts read off this same series, so the indicator math is defined
exactly once and can't drift between Model A's and Model B's evaluation.
#>
function Get-DailySeries {
    param($History, [int]$BurnIn = 50)

    $close = $History.Close
    $n = $close.Count
    if ($n -le $BurnIn) { return $null }

    $rsi = Get-RSI -Prices $close -Period 14
    $bb = Get-BollingerBands -Prices $close -Period 20 -NumStdDev 2.0
    $atr = Get-ATR -High $History.High -Low $History.Low -Close $close -Period 14
    $kama = Get-KAMA -Prices $close -Period 10 -FastPeriod 2 -SlowPeriod 30

    $days = @()
    for ($i = $BurnIn; $i -lt $n; $i++) {
        $rollHigh = ($History.High[($i-19)..$i] | Measure-Object -Maximum).Maximum
        $pctBelowHigh = if ($rollHigh -gt 0) { (($close[$i] - $rollHigh) / $rollHigh) * 100 } else { $null }
        $isRed = if ($i -gt 0) { $close[$i] -lt $close[$i-1] } else { $false }

        $kamaRecent = $null
        if ($i -ge 3 -and $null -ne $kama[$i] -and $null -ne $kama[$i-3]) {
            $kamaRecent = @([double]$kama[$i-3], [double]$kama[$i-2], [double]$kama[$i-1], [double]$kama[$i])
        }

        $days += [pscustomobject]@{
            Index        = $i
            Date         = $History.Date[$i]
            Close        = $close[$i]
            IsRedDay     = $isRed
            RSI          = if ($null -ne $rsi[$i]) { [double]$rsi[$i] } else { $null }
            LowerBand    = if ($null -ne $bb.Lower[$i]) { [double]$bb.Lower[$i] } else { $null }
            UpperBand    = if ($null -ne $bb.Upper[$i]) { [double]$bb.Upper[$i] } else { $null }
            ATR          = if ($null -ne $atr[$i]) { [double]$atr[$i] } else { $null }
            Kama         = if ($null -ne $kama[$i]) { [double]$kama[$i] } else { $null }
            KamaRecent   = $kamaRecent
            RollingHigh20 = $rollHigh
            PctBelowHigh = $pctBelowHigh
        }
    }
    return $days
}

function Test-KamaDowntrend {
    param([double]$Price, $KamaRecent)
    if (-not $KamaRecent -or $KamaRecent.Count -lt 4) { return $false }
    $decliningStreak = ($KamaRecent[3] -lt $KamaRecent[2]) -and ($KamaRecent[2] -lt $KamaRecent[1]) -and ($KamaRecent[1] -lt $KamaRecent[0])
    return $decliningStreak -and ($Price -lt $KamaRecent[3])
}

function New-Bucket {
    return @{ Count = 0; Sum5 = 0.0; Win5 = 0; Sum10 = 0.0; Win10 = 0; Sum20 = 0.0; Win20 = 0 }
}

function Add-ToBucket {
    param($Bucket, [double[]]$Close, [int]$Index)
    $n = $Close.Count
    $Bucket.Count++
    if ($Index + 5 -lt $n) {
        $r = (($Close[$Index+5] - $Close[$Index]) / $Close[$Index]) * 100
        $Bucket.Sum5 += $r
        if ($r -gt 0) { $Bucket.Win5++ }
    }
    if ($Index + 10 -lt $n) {
        $r = (($Close[$Index+10] - $Close[$Index]) / $Close[$Index]) * 100
        $Bucket.Sum10 += $r
        if ($r -gt 0) { $Bucket.Win10++ }
    }
    if ($Index + 20 -lt $n) {
        $r = (($Close[$Index+20] - $Close[$Index]) / $Close[$Index]) * 100
        $Bucket.Sum20 += $r
        if ($r -gt 0) { $Bucket.Win20++ }
    }
}

function Format-BucketRow {
    param([string]$Label, $Bucket)
    if ($Bucket.Count -eq 0) { return "  {0,-22} n=0" -f $Label }
    $wr5  = if ($Bucket.Count -gt 0) { [math]::Round(100.0 * $Bucket.Win5 / [math]::Max(1,$Bucket.Count), 1) } else { 0 }
    $wr10 = [math]::Round(100.0 * $Bucket.Win10 / [math]::Max(1,$Bucket.Count), 1)
    $wr20 = [math]::Round(100.0 * $Bucket.Win20 / [math]::Max(1,$Bucket.Count), 1)
    $avg5  = [math]::Round($Bucket.Sum5  / [math]::Max(1,$Bucket.Count), 2)
    $avg10 = [math]::Round($Bucket.Sum10 / [math]::Max(1,$Bucket.Count), 2)
    $avg20 = [math]::Round($Bucket.Sum20 / [math]::Max(1,$Bucket.Count), 2)
    return "  {0,-22} n={1,-5} +5d: {2,5}% win / {3,6}% avg   +10d: {4,5}% win / {5,6}% avg   +20d: {6,5}% win / {7,6}% avg" -f `
        $Label, $Bucket.Count, $wr5, $avg5, $wr10, $avg10, $wr20, $avg20
}
