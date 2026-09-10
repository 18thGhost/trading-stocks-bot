#requires -Version 5.1
<#
Crypto observation scanner. Same mechanical spirit as SmallCapScout but for the top
~10 coins by market prominence. SPOT PRICES ONLY. Purely informational - no
thresholds that imply a buy, no position sizing, no signal, and no concept of
leverage anywhere. There is also no execution path: Trading 212 does not trade
crypto, so nothing here can be acted on through the rest of this system.

Crypto trades 24/7 and moves far more than equities (3-8% on a normal day), so:
  - pullback thresholds are wider than the stock scouts (-6% / -12% vs -2/-5)
  - this is a once-a-day snapshot of a market that never closes - treat it as
    "here is where things sit", not a trigger

Twelve Data crypto quotes carry no volume field, so there is no volume-spike
section (unlike SmallCapScout). Shares the twelvedata.lock with the other jobs.
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
    $file = Join-Path $Path ("coin_{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $file -Value ("[{0}] {1}" -f $stamp, $Text)
}

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

function Get-TwelveDataQuote {
    param([string]$Symbol, [string]$ApiKey)
    try {
        $url = "https://api.twelvedata.com/quote?symbol=$Symbol&apikey=$ApiKey"
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 15
        if ($resp.status -eq "error" -or -not $resp.close) { return $null }
        return @{
            price         = [double]$resp.close
            changePercent = [double]$resp.percent_change
        }
    } catch {
        return $null
    }
}

function Get-PriceHistoryTD {
    param([string]$Symbol, [string]$ApiKey, [int]$OutputSize = 30)
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

function Get-CoinContext {
    param([string]$Symbol, [string]$ApiKey, [double]$Price)
    $hist = Get-PriceHistoryTD -Symbol $Symbol -ApiKey $ApiKey -OutputSize 30
    if (-not $hist -or $hist.Close.Count -lt 25) { return $null }
    $rsi = [double](Get-RSI -Prices $hist.Close -Period 14)[-1]
    $atr = [double](Get-ATR -High $hist.High -Low $hist.Low -Close $hist.Close -Period 14)[-1]
    $rh20 = ($hist.High[-20..-1] | Measure-Object -Maximum).Maximum
    return @{
        RSI       = $rsi
        ATR       = $atr
        ATRpct    = if ($Price -gt 0) { $atr / $Price * 100 } else { $null }
        BelowHigh = if ($rh20 -gt 0) { (($rh20 - $Price) / $rh20) * 100 } else { $null }
    }
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

function Format-CoinLine {
    param($Row)
    $ctx = $Row.Ctx
    $chg = "{0:+0.00;-0.00}" -f $Row.Change
    $line = "$($Row.Name)  `$$([math]::Round($Row.Price,4)) ($chg%)"
    if ($ctx) {
        $rsiEmoji = if ($ctx.RSI -gt 70) { " overbought" } elseif ($ctx.RSI -lt 30) { " oversold" } else { "" }
        $atrPart = if ($null -ne $ctx.ATRpct) { " | ATR $([math]::Round($ctx.ATRpct,1))%" } else { "" }
        $highPart = if ($null -ne $ctx.BelowHigh) { " | $([math]::Round($ctx.BelowHigh,1))% below 20d high" } else { "" }
        $line += "  | RSI $([math]::Round($ctx.RSI,1))$rsiEmoji$atrPart$highPart"
    } else {
        $line += "  | context unavailable"
    }
    return $line
}

# ---- main ----

$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$scout = $Config.coinScout

if (-not $scout -or -not $scout.universe -or $scout.universe.Count -eq 0) {
    Write-Host "No coinScout.universe configured - nothing to scan." -ForegroundColor Yellow
    exit 1
}

if (-not (Wait-ForApiLock -LogPath $Config.logPath -OwnerName "CoinScout")) {
    Write-Host "Could not acquire twelvedata.lock - skipping this run." -ForegroundColor Yellow
    exit 1
}

try {

$pullbackPct = $scout.pullbackPct
$strongPct = $scout.strongPct
$delaySec = if ($scout.requestDelaySeconds) { $scout.requestDelaySeconds } else { 8 }

$results = @()
$failed = @()
$i = 0
$total = $scout.universe.Count

foreach ($sym in $scout.universe) {
    $i++
    $name = ($sym -replace '/USD', '')
    Write-Host "[$i/$total] Checking $sym..."
    $q = Get-TwelveDataQuote -Symbol $sym -ApiKey $Config.twelveDataApiKey
    Start-Sleep -Seconds $delaySec
    if (-not $q) { $failed += $name; continue }

    $ctx = Get-CoinContext -Symbol $sym -ApiKey $Config.twelveDataApiKey -Price $q.price
    if ($i -lt $total) { Start-Sleep -Seconds $delaySec }

    $results += [pscustomobject]@{
        Symbol = $sym
        Name   = $name
        Price  = $q.price
        Change = $q.changePercent
        Ctx    = $ctx
    }
}

$strong = @($results | Where-Object { $_.Change -le $strongPct } | Sort-Object Change)
$pullback = @($results | Where-Object { $_.Change -le $pullbackPct -and $_.Change -gt $strongPct } | Sort-Object Change)

$lines = @()
$lines += "COIN SCOUT - $(Get-Date -Format 'yyyy-MM-dd HH:mm') UK"
$lines += "Scanned $($results.Count)/$total coins ($($failed.Count) fetch failures) - spot prices, observation only, 24/7 market snapshot"
$lines += ""
$lines += "ALL COINS"
foreach ($r in $results) { $lines += "  $(Format-CoinLine -Row $r)" }
$lines += ""

if ($strong.Count -gt 0) {
    $lines += "DEEP DIP TODAY (<= $strongPct%):"
    foreach ($s in $strong) { $lines += "  $(Format-CoinLine -Row $s)" }
    $lines += ""
}
if ($pullback.Count -gt 0) {
    $lines += "PULLBACK TODAY ($strongPct% to $pullbackPct%):"
    foreach ($p in $pullback) { $lines += "  $(Format-CoinLine -Row $p)" }
    $lines += ""
}
if ($strong.Count -eq 0 -and $pullback.Count -eq 0) {
    $lines += "No coin down more than $pullbackPct% today."
    $lines += ""
}

if ($failed.Count -gt 0) {
    $lines += "Fetch failed for: $($failed -join ', ')"
    $lines += ""
}

$lines += "Spot prices only. No execution path (Trading 212 has no crypto). Not a signal. No leverage. Verify independently."

$report = $lines -join "`n"
Write-Host $report
Write-Log -Path $Config.logPath -Text $report

$tg = @()
$tg += "₿ COIN SCOUT - $(Get-Date -Format 'HH:mm') UK"
$tg += "$($results.Count)/$total coins | spot, observation only, 24/7 snapshot"
$tg += ""
foreach ($r in $results) { $tg += Format-CoinLine -Row $r }
$tg += ""
if ($strong.Count -gt 0) {
    $tg += "🔴 DEEP DIP (<= $strongPct%): $(($strong | ForEach-Object { $_.Name }) -join ', ')"
}
if ($pullback.Count -gt 0) {
    $tg += "🟠 PULLBACK ($strongPct% to $pullbackPct%): $(($pullback | ForEach-Object { $_.Name }) -join ', ')"
}
if ($strong.Count -eq 0 -and $pullback.Count -eq 0) {
    $tg += "✅ Nothing down more than $pullbackPct% today."
}
$tg += ""
$tg += "Spot only. No execution path. Not a signal. No leverage."
$telegramText = $tg -join "`n"

Send-TelegramMessage -Token $Config.telegram.botToken -ChatId $Config.telegram.chatId -Text $telegramText -LogPath $Config.logPath

} finally {
    Remove-ApiLock -LogPath $Config.logPath
}
