#requires -Version 5.1
<#
Mechanical portfolio rule-engine. Fetches prices, applies the thresholds in config.json,
grades qualifying signals with RSI/Bollinger/KAMA/ATR, and sends an alert (Telegram + log
file). It NEVER places trades - output is advisory only, every buy/sell is executed by the
user manually in their own brokerage.
#>

param(
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir "config.json" }
. (Join-Path $ScriptDir "Indicators.ps1")

function Write-Log {
    param([string]$Path, [string]$Text)
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $file = Join-Path $Path ("run_{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $file -Value ("[{0}] {1}" -f $stamp, $Text)
}

<#
PortfolioBot and ScreenerBot share one Twelve Data API key, which has an account-wide
(not per-script) 8-credit/minute cap. If both scripts run concurrently they compete for
the same budget and calls fail intermittently - confirmed 2026-08-06, when a delayed
14:30 run was still active at the 14:40 screener trigger, causing several quotes to
silently fall back to Alpha Vantage and one ticker's history fetch to fail outright.
This lock makes the two scripts mutually exclusive regardless of scheduling drift.
#>
function Wait-ForApiLock {
    param([string]$LogPath, [string]$OwnerName, [int]$MaxWaitSeconds = 600)
    $lockPath = Join-Path $LogPath "twelvedata.lock"
    if (-not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }

    $waited = 0
    while (Test-Path $lockPath) {
        $age = (Get-Date) - (Get-Item $lockPath).LastWriteTime
        if ($age.TotalMinutes -gt 10) {
            Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
            break
        }
        if ($waited -ge $MaxWaitSeconds) {
            Write-Log -Path $LogPath -Text "$OwnerName gave up waiting for twelvedata.lock after $MaxWaitSeconds s"
            return $false
        }
        Start-Sleep -Seconds 15
        $waited += 15
    }
    Set-Content -Path $lockPath -Value "$OwnerName $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    return $true
}

function Remove-ApiLock {
    param([string]$LogPath)
    $lockPath = Join-Path $LogPath "twelvedata.lock"
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}

function Get-SignalCsvPath {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    return (Join-Path $Path "signals.csv")
}

function Write-SignalLog {
    param([string]$Path, [array]$Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return }
    $csvPath = Get-SignalCsvPath -Path $Path
    $existing = @()
    if (Test-Path $csvPath) {
        try { $existing = @(Import-Csv -Path $csvPath) } catch { $existing = @() }
    }
    $todayTickers = $Rows | Select-Object -ExpandProperty Ticker -Unique
    $today = (Get-Date).ToString("yyyy-MM-dd")
    $kept = $existing | Where-Object { -not ($_.Date -eq $today -and $_.Ticker -in $todayTickers) }
    $combined = @($kept) + @($Rows)
    $combined | Export-Csv -Path $csvPath -NoTypeInformation -Force
}

function Get-YesterdaySignals {
    param([string]$Path)
    $csvPath = Get-SignalCsvPath -Path $Path
    $map = @{}
    if (-not (Test-Path $csvPath)) { return $map }
    try {
        $rows = Import-Csv -Path $csvPath
    } catch { return $map }
    if (-not $rows) { return $map }

    $today = (Get-Date).ToString("yyyy-MM-dd")
    $priorDates = $rows | Where-Object { $_.Date -ne $today } | Select-Object -ExpandProperty Date -Unique
    if (-not $priorDates) { return $map }
    $lastDate = ($priorDates | Sort-Object -Descending)[0]

    $rows | Where-Object { $_.Date -eq $lastDate -and $_.Signal -in @("BUY", "STRONG BUY", "ADD") } | ForEach-Object {
        $map[$_.Ticker] = @{ Date = $_.Date; Price = [double]$_.Price; Signal = $_.Signal }
    }
    return $map
}

function Get-TwelveDataQuote {
    param([string]$Symbol, [string]$ApiKey)
    try {
        $url = "https://api.twelvedata.com/quote?symbol=$Symbol&apikey=$ApiKey"
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 15
        if ($resp.status -eq "error" -or -not $resp.close) { return $null }
        $week52High = $null
        if ($resp.fifty_two_week -and $resp.fifty_two_week.high) {
            $week52High = [double]$resp.fifty_two_week.high
        }
        return @{
            price         = [double]$resp.close
            changePercent = [double]$resp.percent_change
            low           = [double]$resp.low
            week52High    = $week52High
            source        = "TwelveData"
        }
    } catch {
        return $null
    }
}

function Get-AlphaVantageQuote {
    param([string]$Symbol, [string]$ApiKey)
    try {
        $url = "https://www.alphavantage.co/query?function=GLOBAL_QUOTE&symbol=$Symbol&apikey=$ApiKey"
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 15
        $quote = $resp.'Global Quote'
        if (-not $quote -or -not $quote.'05. price') { return $null }
        $changePct = ($quote.'10. change percent' -replace '%', '')
        return @{
            price         = [double]$quote.'05. price'
            changePercent = [double]$changePct
            low           = [double]$quote.'04. low'
            week52High    = $null
            source        = "AlphaVantage"
        }
    } catch {
        return $null
    }
}

function Get-Quote {
    param($Ticker, $Info, $Config)
    $symbol = $Ticker
    if ($Info.exchange -and $Info.exchange -ne "NASDAQ" -and $Info.exchange -ne "NYSE") {
        $symbol = "$Ticker`:$($Info.exchange)"
    }
    $q = Get-TwelveDataQuote -Symbol $symbol -ApiKey $Config.twelveDataApiKey
    if (-not $q) {
        $avSymbol = if ($Info.avSymbol) { $Info.avSymbol } else { $Ticker }
        $q = Get-AlphaVantageQuote -Symbol $avSymbol -ApiKey $Config.alphaVantageApiKey
    }
    if ($q -and $Info.quoteInPence) {
        $q.price = $q.price / 100
        if ($q.week52High) { $q.week52High = $q.week52High / 100 }
        if ($q.low) { $q.low = $q.low / 100 }
    }
    return $q
}

function Get-PriceHistoryTD {
    param([string]$Symbol, [string]$ApiKey, [int]$OutputSize = 60)
    try {
        $url = "https://api.twelvedata.com/time_series?symbol=$Symbol&interval=1day&outputsize=$OutputSize&apikey=$ApiKey"
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 20
        if ($resp.status -eq "error" -or -not $resp.values) { return $null }
        $bars = $resp.values | Sort-Object { [datetime]$_.datetime }
        return @{
            High  = @($bars | ForEach-Object { [double]$_.high })
            Low   = @($bars | ForEach-Object { [double]$_.low })
            Close = @($bars | ForEach-Object { [double]$_.close })
        }
    } catch {
        return $null
    }
}

function Get-PriceHistoryAV {
    param([string]$Symbol, [string]$ApiKey, [bool]$InPence = $false)
    try {
        $url = "https://www.alphavantage.co/query?function=TIME_SERIES_DAILY&symbol=$Symbol&outputsize=compact&apikey=$ApiKey"
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 20
        $series = $resp.'Time Series (Daily)'
        if (-not $series) { return $null }
        $dates = $series.PSObject.Properties.Name | Sort-Object
        $divisor = if ($InPence) { 100.0 } else { 1.0 }
        return @{
            High  = @($dates | ForEach-Object { [double]$series.$_.'2. high' / $divisor })
            Low   = @($dates | ForEach-Object { [double]$series.$_.'3. low' / $divisor })
            Close = @($dates | ForEach-Object { [double]$series.$_.'4. close' / $divisor })
        }
    } catch {
        return $null
    }
}

function Get-Indicators {
    param($History)
    if (-not $History -or $History.Close.Count -lt 25) { return $null }
    $atrSeries = Get-ATR -High $History.High -Low $History.Low -Close $History.Close -Period 14
    $rsiSeries = Get-RSI -Prices $History.Close -Period 14
    $bb = Get-BollingerBands -Prices $History.Close -Period 20 -NumStdDev 2.0
    $kamaSeries = Get-KAMA -Prices $History.Close -Period 10 -FastPeriod 2 -SlowPeriod 30

    # Last 4 KAMA values, oldest to newest, so we can test for a genuine multi-day
    # decline rather than a single day-over-day comparison (see design note below).
    $kamaRecent = @([double]$kamaSeries[-4], [double]$kamaSeries[-3], [double]$kamaSeries[-2], [double]$kamaSeries[-1])

    return @{
        ATR         = [double]$atrSeries[-1]
        RSI         = [double]$rsiSeries[-1]
        UpperBand   = [double]$bb.Upper[-1]
        LowerBand   = [double]$bb.Lower[-1]
        KamaCurrent = $kamaRecent[3]
        KamaRecent  = $kamaRecent
    }
}

<#
Design note on the KAMA trend filter: a naive "KAMA_t < KAMA_(t-1)" check is
mathematically equivalent to just "price fell below yesterday's KAMA" (provable
algebraically from KAMA's recursive update rule, since the smoothing constant is
always strictly between 0 and 1) - it fires on almost any single red day, not just
sustained downtrends. Confirmed by testing against a synthetic isolated one-day
crash, which it incorrectly suppressed. Requiring 3 consecutive declining days
(4 trailing KAMA values, strictly decreasing) actually distinguishes a grinding
downtrend from a sharp one-day dip.
#>
function Test-KamaDowntrend {
    param([double]$Price, [double[]]$KamaRecent)
    if (-not $KamaRecent -or $KamaRecent.Count -lt 4) { return $false }
    $decliningStreak = ($KamaRecent[3] -lt $KamaRecent[2]) -and ($KamaRecent[2] -lt $KamaRecent[1]) -and ($KamaRecent[1] -lt $KamaRecent[0])
    return $decliningStreak -and ($Price -lt $KamaRecent[3])
}

function Get-T212Cash {
    param($Config)
    $t212 = $Config.trading212
    if (-not $t212 -or -not $t212.apiKey -or $t212.apiKey -eq "PASTE_TRADING212_KEY_HERE") { return $null }
    try {
        $pair = "$($t212.apiKey)`:$($t212.apiSecret)"
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
        $r = Invoke-RestMethod -Uri "https://live.trading212.com/api/v0/equity/account/cash" -Headers @{ Authorization = "Basic $b64" } -TimeoutSec 15
        if ($null -eq $r.free) { return $null }
        return @{ Free = [double]$r.free; Total = [double]$r.total }
    } catch {
        return $null
    }
}

function Get-FxRateGbpUsd {
    param($Config)
    $q = Get-TwelveDataQuote -Symbol "GBP/USD" -ApiKey $Config.twelveDataApiKey
    if ($q -and $q.price -gt 0) { return $q.price }
    return $null
}

function Get-StockState {
    param($Quote)
    if (-not $Quote) { return "UNKNOWN" }
    if ($Quote.changePercent -le -5) { return "STRONG BUY ZONE" }
    if ($Quote.changePercent -le -2) { return "PULLBACK" }
    if ($Quote.week52High -and $Quote.price -ge ($Quote.week52High * 0.95)) { return "NEAR HIGH" }
    return "NEUTRAL"
}

function Get-Signal {
    param([string]$Ticker, $Info, $Quote)
    if (-not $Quote) { return @{ Signal = "NO DATA"; Reason = "price fetch failed" } }

    $isRedDay = $Quote.changePercent -lt 0

    if ($Ticker -eq "RKLB") {
        if ($Quote.price -lt $Info.addBelow -and $isRedDay) {
            return @{ Signal = "ADD"; Reason = "below $($Info.addBelow) on a red day" }
        }
        return @{ Signal = "HOLD"; Reason = "no add - above threshold or rising" }
    }

    if ($null -eq $Info.buyBelow) {
        return @{ Signal = "MONITOR ONLY"; Reason = "no thresholds set in config yet" }
    }

    if ($Quote.price -ge $Info.waitAbove) {
        return @{ Signal = "WAIT"; Reason = "above $($Info.waitAbove)" }
    }
    if (-not $isRedDay) {
        return @{ Signal = "WAIT"; Reason = "green day - rule says only buy on red days" }
    }
    if ($Quote.price -lt $Info.strongBuyBelow) {
        return @{ Signal = "STRONG BUY"; Reason = "below $($Info.strongBuyBelow) on a red day" }
    }
    if ($Quote.price -lt $Info.buyBelow) {
        return @{ Signal = "BUY"; Reason = "below $($Info.buyBelow) on a red day" }
    }
    return @{ Signal = "WAIT"; Reason = "between buy and wait thresholds" }
}

function Get-EntryThreshold {
    param($Ticker, $Info)
    if ($Ticker -eq "RKLB") { return $Info.addBelow }
    return $Info.buyBelow
}

function Get-DistanceToBuy {
    param([double]$Price, [double]$BuyLevel)
    if ($BuyLevel -le 0) { return $null }
    return (($Price - $BuyLevel) / $BuyLevel) * 100
}

function Get-RsiTag {
    param([double]$RSI)
    if ($RSI -gt 70) { return "OVERBOUGHT" }
    if ($RSI -lt 30) { return "OVERSOLD" }
    return $null
}

<#
Confidence score (0-100), built only from indicators the script already computes -
no new data source, no change to what triggers BUY/WAIT/HOLD. Two gaps in the spec,
filled deliberately rather than left ambiguous:
  - RSI table starts at "30-40 -> +25"; RSI below 30 (deeper oversold) is folded into
    the same top tier rather than scored as 0, since scoring "more oversold" worse
    than "somewhat oversold" would invert the intent.
  - Bollinger table only names "near lower band" and "mid-range"; added a third tier
    for near/above the upper band (scored 0, same as "not near the band at all"),
    since that's the opposite of an oversold signal.
#>
function Get-ConfidenceScore {
    param(
        [double]$RSI,
        [double]$DistanceToBuy,
        [string]$MarketContext,
        [double]$Price,
        [double]$LowerBand,
        [double]$UpperBand
    )
    $score = 0

    if ($RSI -le 40) { $score += 25 }
    elseif ($RSI -le 50) { $score += 15 }
    elseif ($RSI -le 60) { $score += 5 }

    if ($DistanceToBuy -le 0) { $score += 25 }
    elseif ($DistanceToBuy -le 1) { $score += 15 }
    elseif ($DistanceToBuy -le 3) { $score += 5 }

    switch ($MarketContext) {
        "PULLBACK" { $score += 20 }
        "MIXED" { $score += 10 }
    }

    if ($UpperBand -gt $LowerBand) {
        $bandPosition = ($Price - $LowerBand) / ($UpperBand - $LowerBand)
        if ($bandPosition -le 0.15) { $score += 20 }
        elseif ($bandPosition -le 0.85) { $score += 5 }
    }

    return [math]::Min(100, $score)
}

function Get-ConfidenceInfo {
    param([int]$Score)
    if ($Score -ge 70) { return @{ Label = "HIGH CONFIDENCE"; Emoji = "✅" } }
    if ($Score -ge 40) { return @{ Label = "MEDIUM"; Emoji = "⚠️" } }
    return @{ Label = "LOW"; Emoji = "❌" }
}

function Get-SignalEmoji {
    param($Result)
    if ($Result.Suppressed) { return "🚫" }
    if ($Result.Signal -in @("BUY", "STRONG BUY", "ADD")) {
        if ($Result.Grade -eq "STRONG BUY SIGNAL") { return "🟢" }
        return "🟡"
    }
    if ($Result.Signal -eq "WAIT") { return "⚪" }
    if ($Result.Signal -eq "HOLD") { return "🔵" }
    if ($Result.Signal -eq "MONITOR ONLY") { return "👀" }
    return "❔"
}

function Get-ApproachNote {
    param($Ticker, $Info, $Quote, [string]$Signal, [double]$BandPct)
    if ($Signal -in @("BUY", "STRONG BUY", "ADD", "NO DATA", "MONITOR ONLY")) { return $null }
    $threshold = Get-EntryThreshold -Ticker $Ticker -Info $Info
    if ($null -eq $threshold -or -not $Quote) { return $null }
    $band = $threshold * (1 + $BandPct)
    if ($Quote.price -gt $threshold -and $Quote.price -le $band) {
        $pctAway = [math]::Round((($Quote.price - $threshold) / $threshold) * 100, 2)
        return "APPROACHING - within $pctAway% of $threshold trigger. Prepare capital."
    }
    return $null
}

function Get-TouchNote {
    param($Ticker, $Info, $Quote, [string]$Signal)
    if ($Signal -in @("BUY", "STRONG BUY", "ADD", "NO DATA", "MONITOR ONLY")) { return $null }
    $threshold = Get-EntryThreshold -Ticker $Ticker -Info $Info
    if ($null -eq $threshold -or -not $Quote -or -not $Quote.low) { return $null }
    if ($Quote.low -le $threshold -and $Quote.price -gt $threshold) {
        return "Touched buy zone today (session low $($Quote.low)) then recovered above $threshold."
    }
    return $null
}

function Format-TelegramReport {
    param(
        [array]$ThresholdResults,
        [array]$Active,
        [string]$OverallState,
        [string]$MarketContext,
        [double]$Fx,
        [double]$EffectiveCash,
        [double]$MaxSpend
    )

    $t = @()
    $t += "📊 PORTFOLIO CHECK - $(Get-Date -Format 'HH:mm') UK"
    $t += "🧭 State: $OverallState | Market: $MarketContext"
    $t += ""

    foreach ($r in $ThresholdResults) {
        if (-not $r.Quote) {
            $t += "$($r.Ticker) - price fetch failed"
            $t += ""
            continue
        }

        $currencySymbol = if ($r.Info.currency -eq "GBP") { "£" } else { "$" }
        $changeStr = "{0:+0.00;-0.00}" -f $r.Quote.changePercent
        $t += "$($r.Ticker) - $currencySymbol$([math]::Round($r.Quote.price,2)) ($changeStr%)"

        $icon = Get-SignalEmoji -Result $r
        $isActiveBuy = ($r.Signal -in @("BUY", "STRONG BUY", "ADD")) -and -not $r.Suppressed
        if ($r.Suppressed) {
            $t += "$icon SUPPRESSED (downtrend filter blocked this)"
        } elseif ($isActiveBuy) {
            $gradeWord = if ($r.Grade) { $r.Grade } else { "BUY SIGNAL" }
            $t += "$icon $gradeWord"
        } else {
            $t += "$icon $($r.Signal) ($($r.Reason))"
        }

        if ($null -ne $r.DistanceToBuy) {
            $distStr = if ($r.DistanceToBuy -le 0) { "at/below buy level" } else { "$([math]::Round($r.DistanceToBuy,2))%" }
            $t += "📏 Distance: $distStr"
        }
        if ($r.Indicators) {
            $rsiEmoji = if ($r.Indicators.RSI -gt 70) { " 🔥" } elseif ($r.Indicators.RSI -lt 30) { " ❄️" } else { "" }
            $t += "📊 RSI: $([math]::Round($r.Indicators.RSI,1))$rsiEmoji | ATR: $([math]::Round($r.Indicators.ATR,2))"
            $t += "📉 Bollinger: [$([math]::Round($r.Indicators.LowerBand,0)) - $([math]::Round($r.Indicators.UpperBand,0))]"
        }
        if ($isActiveBuy -and $null -ne $r.FinalValueGbp) {
            $t += "💷 Size: £$($r.FinalValueGbp)"
        }
        if ($null -ne $r.Confidence) {
            $t += "🧠 Confidence: $($r.Confidence) $($r.ConfidenceEmoji)"
        }
        $t += ""
    }

    if ($Active.Count -gt 0) {
        $t += "🎯 TOP SIGNALS:"
        $rank = 1
        foreach ($a in ($Active | Select-Object -First 3)) {
            $t += "   $rank. $($a.Ticker) - $($a.Confidence) $($a.ConfidenceEmoji)"
            $rank++
        }
        $t += ""
    }

    $t += "💰 Cash: £$EffectiveCash"
    $t += "📦 Max Spend: £$MaxSpend"
    $t += ""

    if ($Active.Count -eq 0) {
        $t += "🚫 ACTION: NO TRADE"
    }

    $t += ""
    $t += "Mechanical rule check only - not investment advice. You decide what, if anything, to execute."

    return ($t -join "`n")
}

function Send-TelegramMessage {
    param([string]$Token, [string]$ChatId, [string]$Text, [string]$LogPath)
    if ($Token -eq "PASTE_TELEGRAM_BOT_TOKEN_HERE" -or -not $Token) { return }
    try {
        $url = "https://api.telegram.org/bot$Token/sendMessage"
        $body = @{ chat_id = $ChatId; text = $Text }
        Invoke-RestMethod -Uri $url -Method Post -Body $body -TimeoutSec 15 | Out-Null
    } catch {
        Write-Log -Path $LogPath -Text "Telegram send failed: $($_.Exception.Message)"
    }
}

# ---- main ----

$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

if ($Config.twelveDataApiKey -eq "PASTE_TWELVE_DATA_KEY_HERE") {
    Write-Host "config.json still has placeholder API keys - fill them in before running for real." -ForegroundColor Yellow
    exit 1
}

if (-not (Wait-ForApiLock -LogPath $Config.logPath -OwnerName "PortfolioBot")) {
    Write-Host "Could not acquire twelvedata.lock (ScreenerBot holding it too long) - skipping this run." -ForegroundColor Yellow
    exit 1
}

try {

$approachBandPct = if ($Config.approachBandPct) { $Config.approachBandPct } else { 0.02 }
$callDelay = if ($Config.requestDelaySeconds) { $Config.requestDelaySeconds } else { 14 }
$riskPercent = if ($Config.riskPercent) { $Config.riskPercent } else { 0.01 }
$atrMultiplier = if ($Config.atrMultiplier) { $Config.atrMultiplier } else { 2.0 }
$lookback = if ($Config.historyLookbackDays) { $Config.historyLookbackDays } else { 60 }
$today = (Get-Date).ToString("yyyy-MM-dd")

$fx = Get-FxRateGbpUsd -Config $Config
Start-Sleep -Seconds $callDelay

$t212Cash = Get-T212Cash -Config $Config
if ($t212Cash) {
    $effectiveCash = $t212Cash.Free
    $accountEquity = $t212Cash.Total
    $cashSource = "Trading 212 live"
} else {
    $effectiveCash = $Config.cashGbp
    $accountEquity = $Config.cashGbp
    $cashSource = "manual config (T212 fetch unavailable)"
}

$yesterday = Get-YesterdaySignals -Path $Config.logPath

$results = @()
$stateVotes = @()
$csvRows = @()
$tickerProps = $Config.tickers.PSObject.Properties

foreach ($prop in $tickerProps) {
    $ticker = $prop.Name
    $info = $prop.Value
    $quote = Get-Quote -Ticker $ticker -Info $info -Config $Config
    Start-Sleep -Seconds $callDelay
    $signalResult = Get-Signal -Ticker $ticker -Info $info -Quote $quote
    $stockState = Get-StockState -Quote $quote
    $stateVotes += $stockState
    $approachNote = Get-ApproachNote -Ticker $ticker -Info $info -Quote $quote -Signal $signalResult.Signal -BandPct $approachBandPct
    $touchNote = Get-TouchNote -Ticker $ticker -Info $info -Quote $quote -Signal $signalResult.Signal

    $signal = $signalResult.Signal
    $reason = $signalResult.Reason
    $grade = $null
    $suppressed = $false
    $suppressReason = $null
    $ind = $null
    $suggestedShares = $null
    $suggestedValueGbp = $null

    $hasThreshold = ($null -ne $info.buyBelow) -or ($ticker -eq "RKLB" -and $info.addBelow)
    $isBuyType = $signal -in @("BUY", "STRONG BUY", "ADD")

    $hist = $null
    if ($quote -and $info.exchange -in @("NASDAQ", "NYSE")) {
        $hist = Get-PriceHistoryTD -Symbol $ticker -ApiKey $Config.twelveDataApiKey -OutputSize $lookback
        Start-Sleep -Seconds $callDelay
    } elseif ($quote -and $info.avSymbol) {
        $hist = Get-PriceHistoryAV -Symbol $info.avSymbol -ApiKey $Config.alphaVantageApiKey -InPence:($info.quoteInPence -eq $true)
        Start-Sleep -Seconds 2
    }
    $ind = Get-Indicators -History $hist

    if ($hasThreshold) {
        if ($isBuyType -and $ind) {
            # 3. KAMA trend regime filter - suppress mean-reversion buys during active downtrends
            if (Test-KamaDowntrend -Price $quote.price -KamaRecent $ind.KamaRecent) {
                $suppressed = $true
                $kamaTrail = ($ind.KamaRecent | ForEach-Object { [math]::Round($_, 2) }) -join " -> "
                $suppressReason = "downtrend active: 3 consecutive declining KAMA days ($kamaTrail), price below current KAMA"
            } else {
                # 2. RSI / Bollinger confirmation grading
                if ($ind.RSI -le 35 -or $quote.price -le $ind.LowerBand) {
                    $grade = "STRONG BUY SIGNAL"
                } else {
                    $grade = "WATCH SIGNAL"
                    $reason += " - price hit but not statistically oversold (RSI $([math]::Round($ind.RSI,1)), lower band $([math]::Round($ind.LowerBand,2)))"
                }

                # 1. ATR position sizing (fractional shares, GBP terms)
                $atrNative = $ind.ATR
                $priceNative = $quote.price
                if ($info.currency -eq "USD" -and $fx) {
                    $atrGbp = $atrNative / $fx
                    $priceGbp = $priceNative / $fx
                } else {
                    $atrGbp = $atrNative
                    $priceGbp = $priceNative
                }
                $shares = Get-ATRPositionSize -AccountEquity $accountEquity -RiskPercent $riskPercent -ATR $atrGbp -ATRMultiplier $atrMultiplier
                $suggestedShares = $shares
                $suggestedValueGbp = $shares * $priceGbp
            }
        } elseif ($isBuyType -and -not $ind) {
            $grade = "UNCONFIRMED (history unavailable)"
        }
    }

    $distanceToBuy = $null
    if ($hasThreshold -and $quote) {
        $distanceToBuy = Get-DistanceToBuy -Price $quote.price -BuyLevel (Get-EntryThreshold -Ticker $ticker -Info $info)
    }

    $results += [pscustomobject]@{
        Ticker            = $ticker
        Info              = $info
        Quote             = $quote
        Signal            = $signal
        Reason            = $reason
        State             = $stockState
        Approach          = $approachNote
        Touch             = $touchNote
        Grade             = $grade
        Suppressed        = $suppressed
        SuppressReason    = $suppressReason
        Indicators        = $ind
        SuggestedShares   = $suggestedShares
        SuggestedValueGbp = $suggestedValueGbp
        DistanceToBuy     = $distanceToBuy
        HasThreshold      = $hasThreshold
    }

    if ($quote) {
        $csvRows += [pscustomobject]@{
            Date          = $today
            Ticker        = $ticker
            Price         = [math]::Round($quote.price, 4)
            Currency      = $info.currency
            ChangePercent = $quote.changePercent
            Signal        = $signal
            Grade         = $grade
            Suppressed    = $suppressed
            RSI           = if ($ind) { [math]::Round($ind.RSI, 2) } else { "" }
            ATR           = if ($ind) { [math]::Round($ind.ATR, 4) } else { "" }
        }
    }
}

Write-SignalLog -Path $Config.logPath -Rows $csvRows

$overallState = "NEUTRAL"
if ($stateVotes -contains "STRONG BUY ZONE") {
    $overallState = "STRONG BUY ZONE"
} elseif ($stateVotes -contains "PULLBACK") {
    $overallState = "PULLBACK"
} elseif (@($stateVotes | Where-Object { $_ -eq "NEAR HIGH" }).Count -ge 3) {
    $overallState = "OVEREXTENDED"
}

# Market context: breadth of green vs red across the watchlist today (distinct from
# STATE above, which is about trend/volatility posture rather than today's breadth)
$validQuotes = @($results | Where-Object { $_.Quote })
$greenCount = @($validQuotes | Where-Object { $_.Quote.changePercent -gt 0 }).Count
$redCount = @($validQuotes | Where-Object { $_.Quote.changePercent -lt 0 }).Count
$totalValid = $validQuotes.Count
$marketContext = "MIXED"
if ($totalValid -gt 0) {
    $pctGreen = $greenCount / $totalValid
    $pctRed = $redCount / $totalValid
    if ($pctGreen -gt 0.70) { $marketContext = "EXTENDED" }
    elseif ($pctRed -gt 0.50) { $marketContext = "PULLBACK" }
}

# Confidence score - purely derived from data already computed above (RSI, distance
# to buy, market context, Bollinger position). Does not affect Signal/Grade/Suppressed.
foreach ($r in $results) {
    $conf = $null
    $confInfo = $null
    if ($r.HasThreshold -and $r.Indicators -and $null -ne $r.DistanceToBuy) {
        $conf = Get-ConfidenceScore -RSI $r.Indicators.RSI -DistanceToBuy $r.DistanceToBuy -MarketContext $marketContext `
            -Price $r.Quote.price -LowerBand $r.Indicators.LowerBand -UpperBand $r.Indicators.UpperBand
        $confInfo = Get-ConfidenceInfo -Score $conf
    }
    $r | Add-Member -NotePropertyName Confidence -NotePropertyValue $conf -Force
    $r | Add-Member -NotePropertyName ConfidenceLabel -NotePropertyValue $(if ($confInfo) { $confInfo.Label } else { $null }) -Force
    $r | Add-Member -NotePropertyName ConfidenceEmoji -NotePropertyValue $(if ($confInfo) { $confInfo.Emoji } else { $null }) -Force
}

# Action sizing, computed once here (highest confidence first) so both the detailed
# report and the Telegram summary read the same final numbers.
$active = @($results | Where-Object { $_.Signal -in @("BUY", "STRONG BUY", "ADD") -and -not $_.Suppressed -and $null -ne $_.SuggestedValueGbp } | Sort-Object -Property Confidence -Descending)
$maxSpend = [math]::Round($effectiveCash * $Config.maxDailySpendPct, 2)
if ($active.Count -gt 0) {
    $totalSuggested = ($active | Measure-Object -Property SuggestedValueGbp -Sum).Sum
    $scale = if ($totalSuggested -gt $maxSpend -and $totalSuggested -gt 0) { $maxSpend / $totalSuggested } else { 1.0 }
    foreach ($a in $active) {
        $a | Add-Member -NotePropertyName FinalValueGbp -NotePropertyValue ([math]::Round($a.SuggestedValueGbp * $scale, 2)) -Force
        $a | Add-Member -NotePropertyName FinalShares -NotePropertyValue ([math]::Round($a.SuggestedShares * $scale, 4)) -Force
        $a | Add-Member -NotePropertyName ScaledDown -NotePropertyValue ($scale -lt 1.0) -Force
    }
}

$lines = @()
$lines += "PORTFOLIO CHECK - $(Get-Date -Format 'yyyy-MM-dd HH:mm') UK"
$lines += "STATE: $overallState | MARKET CONTEXT: $marketContext ($greenCount green / $redCount red of $totalValid)"
$lines += ""

$thresholdResults = @($results | Where-Object { $_.HasThreshold })
$monitorResults = @($results | Where-Object { -not $_.HasThreshold })

foreach ($r in $thresholdResults) {
    if ($r.Quote) {
        $priceLine = "{0}: {1} {2} ({3:+0.00;-0.00}% today) [{4}]" -f `
            $r.Ticker, $r.Info.currency, [math]::Round($r.Quote.price, 2), $r.Quote.changePercent, $r.Quote.source
        if ($r.Info.currency -eq "USD" -and $fx) {
            $gbpEquiv = [math]::Round($r.Quote.price / $fx, 2)
            $priceLine += " = GBP $gbpEquiv"
        }
    } else {
        $priceLine = "$($r.Ticker): price fetch failed"
    }
    $lines += $priceLine

    if ($r.Suppressed) {
        $lines += "  -> SIGNAL SUPPRESSED ($($r.SuppressReason)) | state: $($r.State)"
    } else {
        $gradeSuffix = if ($r.Grade) { " [$($r.Grade)]" } else { "" }
        $lines += "  -> $($r.Signal)$gradeSuffix ($($r.Reason)) | state: $($r.State)"
    }
    if ($null -ne $r.DistanceToBuy) {
        $distLabel = if ($r.DistanceToBuy -le 0) { "AT/BELOW buy level" } else { "$([math]::Round($r.DistanceToBuy,2))% above buy level" }
        $lines += "     Distance to buy: $distLabel"
    }
    if ($r.Indicators) {
        $rsiTag = Get-RsiTag -RSI $r.Indicators.RSI
        $rsiTagText = if ($rsiTag) { " ($rsiTag)" } else { "" }
        $lines += "     RSI $([math]::Round($r.Indicators.RSI,1))$rsiTagText | ATR $([math]::Round($r.Indicators.ATR,2)) | Bollinger [$([math]::Round($r.Indicators.LowerBand,2)) - $([math]::Round($r.Indicators.UpperBand,2))] | KAMA $([math]::Round($r.Indicators.KamaCurrent,2))"
    }
    if ($null -ne $r.Confidence) {
        $lines += "     Confidence: $($r.Confidence)/100 ($($r.ConfidenceLabel) $($r.ConfidenceEmoji))"
    }
    if ($r.Approach) { $lines += "  !! $($r.Approach)" }
    if ($r.Touch) { $lines += "  ~~ $($r.Touch)" }
    $lines += ""
}

# Closest to entry: top 3 thresholded tickers by distance-to-buy, ascending
$closest = @($thresholdResults | Where-Object { $null -ne $_.DistanceToBuy } | Sort-Object DistanceToBuy | Select-Object -First 3)
if ($closest.Count -gt 0) {
    $lines += "CLOSEST TO ENTRY"
    foreach ($c in $closest) {
        $distLabel = if ($c.DistanceToBuy -le 0) { "AT/BELOW buy level" } else { "$([math]::Round($c.DistanceToBuy,2))% away" }
        $lines += "  $($c.Ticker): $distLabel"
    }
    $lines += ""
}

# Monitor only: tickers with no thresholds set, shown with indicators but no signal
if ($monitorResults.Count -gt 0) {
    $lines += "MONITOR ONLY (no thresholds set)"
    foreach ($m in $monitorResults) {
        if ($m.Quote) {
            $priceLine = "  {0}: {1} {2} ({3:+0.00;-0.00}% today)" -f `
                $m.Ticker, $m.Info.currency, [math]::Round($m.Quote.price, 2), $m.Quote.changePercent
            if ($m.Info.currency -eq "USD" -and $fx) {
                $priceLine += " = GBP $([math]::Round($m.Quote.price / $fx, 2))"
            }
            $lines += $priceLine
            if ($m.Indicators) {
                $rsiTag = Get-RsiTag -RSI $m.Indicators.RSI
                $rsiTagText = if ($rsiTag) { " ($rsiTag)" } else { "" }
                $lines += "    RSI $([math]::Round($m.Indicators.RSI,1))$rsiTagText | ATR $([math]::Round($m.Indicators.ATR,2)) | Bollinger [$([math]::Round($m.Indicators.LowerBand,2)) - $([math]::Round($m.Indicators.UpperBand,2))] | KAMA $([math]::Round($m.Indicators.KamaCurrent,2))"
            } else {
                $lines += "    (indicators unavailable this run)"
            }
        } else {
            $lines += "  $($m.Ticker): price fetch failed"
        }
    }
    $lines += ""
}

# Watchlist levels footer
$lines += "WATCHLIST LEVELS"
foreach ($r in $results) {
    if ($r.Ticker -eq "RKLB" -and $r.Info.addBelow) {
        $lines += "  $($r.Ticker): add < $($r.Info.addBelow)"
    } elseif ($r.Info.buyBelow) {
        $lines += "  $($r.Ticker): buy < $($r.Info.buyBelow), strong < $($r.Info.strongBuyBelow), wait > $($r.Info.waitAbove)"
    } else {
        $lines += "  $($r.Ticker): no thresholds set"
    }
}
$lines += ""

# Retrospective: yesterday's buy-type signals vs today's price
if ($yesterday.Count -gt 0) {
    $retroLines = @()
    foreach ($r in $results) {
        if ($yesterday.ContainsKey($r.Ticker) -and $r.Quote) {
            $y = $yesterday[$r.Ticker]
            $pctMove = [math]::Round((($r.Quote.price - $y.Price) / $y.Price) * 100, 2)
            $retroLines += "  $($r.Ticker) signaled $($y.Signal) on $($y.Date) at $($y.Price), now $([math]::Round($r.Quote.price,2)) ($pctMove%)"
        }
    }
    if ($retroLines.Count -gt 0) {
        $lines += "SINCE LAST SIGNAL"
        $lines += $retroLines
        $lines += ""
    }
}

# Action + ATR-based sizing (replaces flat conviction-weighted split) - $active,
# $maxSpend, and each item's Final* fields were already computed above, right after
# confidence scoring, so both this report and the Telegram summary agree exactly.
if ($active.Count -gt 0) {
    $lines += "ACTION: ATR-sized signals active today, highest confidence first (risk $([math]::Round($riskPercent*100,1))% of GBP $([math]::Round($accountEquity,2)) equity, $atrMultiplier`x ATR stop)"
    foreach ($a in $active) {
        $capNote = if ($a.ScaledDown) { " (scaled down - combined signals exceeded 30% cash cap)" } else { "" }
        $minNote = if ($a.FinalValueGbp -lt $Config.minPositionGbp) { " (below your GBP $($Config.minPositionGbp) min - consider combining or skipping)" } else { "" }
        $gradeTag = if ($a.Grade) { " [$($a.Grade)]" } else { "" }
        $confTag = if ($null -ne $a.Confidence) { " | confidence $($a.Confidence) $($a.ConfidenceEmoji)" } else { "" }
        $lines += "  $($a.Ticker): $($a.Signal)$gradeTag - $($a.FinalShares) shares (~GBP $($a.FinalValueGbp))$capNote$minNote$confTag"
    }
} else {
    $lines += "ACTION: NO TRADE"
}

$suppressedTickers = @($results | Where-Object { $_.Suppressed })
if ($suppressedTickers.Count -gt 0) {
    $lines += ""
    $lines += "SUPPRESSED (would be BUY but downtrend filter blocked it):"
    foreach ($s in $suppressedTickers) {
        $lines += "  $($s.Ticker): $($s.SuppressReason)"
    }
}

$lines += ""
$lines += "Cash available: GBP $effectiveCash ($cashSource) | Account equity: GBP $([math]::Round($accountEquity,2)) | Max spend today (30% rule): GBP $maxSpend | Min position: GBP $($Config.minPositionGbp)"
$lines += ""
$lines += "This is a mechanical rule check, not investment advice. You decide what, if anything, to execute."

$report = $lines -join "`n"

Write-Host $report
Write-Log -Path $Config.logPath -Text $report

$telegramText = Format-TelegramReport -ThresholdResults $thresholdResults -Active $active -OverallState $overallState `
    -MarketContext $marketContext -Fx $fx -EffectiveCash $effectiveCash -MaxSpend $maxSpend
Send-TelegramMessage -Token $Config.telegram.botToken -ChatId $Config.telegram.chatId -Text $telegramText -LogPath $Config.logPath

} finally {
    Remove-ApiLock -LogPath $Config.logPath
}
