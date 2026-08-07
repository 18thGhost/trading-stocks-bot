#requires -Version 5.1
<#
Wide-universe pullback screener. Scans config.json's screener.universe for stocks down
Config-defined pullback/strong-drop percentages today. Read-only, objective, mechanical -
flags moves, renders no opinion, places no trades. Runs slowly (one request per
requestDelaySeconds) to respect Twelve Data's free-tier 8 req/min cap.
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
    $file = Join-Path $Path ("screener_{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))
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
            name          = $resp.name
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

function Get-RsiAtrContext {
    param([string]$Ticker, [string]$ApiKey)
    $hist = Get-PriceHistoryTD -Symbol $Ticker -ApiKey $ApiKey -OutputSize 30
    if (-not $hist -or $hist.Close.Count -lt 25) { return $null }
    return @{
        RSI = [double](Get-RSI -Prices $hist.Close -Period 14)[-1]
        ATR = [double](Get-ATR -High $hist.High -Low $hist.Low -Close $hist.Close -Period 14)[-1]
    }
}

function Format-ContextText {
    param($Ctx)
    if (-not $Ctx) { return "RSI/ATR unavailable" }
    $tag = if ($Ctx.RSI -le 30) { " (oversold)" } elseif ($Ctx.RSI -ge 70) { " (overbought)" } else { "" }
    return "RSI $([math]::Round($Ctx.RSI,1))$tag, ATR $([math]::Round($Ctx.ATR,2))"
}

function Format-TelegramScreenerReport {
    param([array]$Strong, [array]$Pullback, $Context, [int]$Scanned, [int]$Total, [int]$Failed, [double]$StrongPct, [double]$PullbackPct)

    $t = @()
    $t += "📊 SCREENER RUN - $(Get-Date -Format 'HH:mm') UK"
    $t += "Scanned $Scanned/$Total tickers ($Failed failed)"
    $t += ""

    if ($Strong.Count -eq 0 -and $Pullback.Count -eq 0) {
        $t += "✅ No pullbacks detected across the watchlist universe today."
    } else {
        if ($Strong.Count -gt 0) {
            $t += "🔴 STRONG BUY ZONE (<= $StrongPct% today):"
            foreach ($s in $Strong) {
                $t += "  $($s.Ticker) ($($s.Name)): $([math]::Round($s.Change,2))% - $([math]::Round($s.Price,2))"
                $ctx = $Context[$s.Ticker]
                if ($ctx) {
                    $rsiEmoji = if ($ctx.RSI -gt 70) { " 🔥" } elseif ($ctx.RSI -lt 30) { " ❄️" } else { "" }
                    $t += "    📊 RSI: $([math]::Round($ctx.RSI,1))$rsiEmoji | ATR: $([math]::Round($ctx.ATR,2))"
                } else {
                    $t += "    RSI/ATR unavailable"
                }
            }
            $t += ""
        }
        if ($Pullback.Count -gt 0) {
            $t += "🟠 PULLBACK ($StrongPct% to $PullbackPct% today):"
            foreach ($p in $Pullback) {
                $t += "  $($p.Ticker) ($($p.Name)): $([math]::Round($p.Change,2))% - $([math]::Round($p.Price,2))"
                $ctx = $Context[$p.Ticker]
                if ($ctx) {
                    $rsiEmoji = if ($ctx.RSI -gt 70) { " 🔥" } elseif ($ctx.RSI -lt 30) { " ❄️" } else { "" }
                    $t += "    📊 RSI: $([math]::Round($ctx.RSI,1))$rsiEmoji | ATR: $([math]::Round($ctx.ATR,2))"
                } else {
                    $t += "    RSI/ATR unavailable"
                }
            }
            $t += ""
        }
    }

    $t += "Objective move detection only - no buy/sell opinion, no trades placed. Verify before acting."
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
$screener = $Config.screener

if (-not $screener -or -not $screener.universe -or $screener.universe.Count -eq 0) {
    Write-Host "No screener.universe configured - nothing to scan." -ForegroundColor Yellow
    exit 1
}

if (-not (Wait-ForApiLock -LogPath $Config.logPath -OwnerName "ScreenerBot")) {
    Write-Host "Could not acquire twelvedata.lock (PortfolioBot holding it too long) - skipping this run." -ForegroundColor Yellow
    exit 1
}

try {

$pullbackPct = $screener.pullbackPct
$strongPct = $screener.strongPct
$delaySec = if ($screener.requestDelaySeconds) { $screener.requestDelaySeconds } else { 8 }

$results = @()
$failed = @()
$i = 0
$total = $screener.universe.Count

foreach ($ticker in $screener.universe) {
    $i++
    Write-Host "[$i/$total] Checking $ticker..."
    $q = Get-TwelveDataQuote -Symbol $ticker -ApiKey $Config.twelveDataApiKey
    if ($q) {
        $results += [pscustomobject]@{
            Ticker = $ticker
            Name   = $q.name
            Price  = $q.price
            Change = $q.changePercent
        }
    } else {
        $failed += $ticker
    }
    if ($i -lt $total) { Start-Sleep -Seconds $delaySec }
}

$strong = @($results | Where-Object { $_.Change -le $strongPct } | Sort-Object Change)
$pullback = @($results | Where-Object { $_.Change -le $pullbackPct -and $_.Change -gt $strongPct } | Sort-Object Change)
$matches = @($strong) + @($pullback)

# RSI(14)/ATR(14) context for matched tickers only - keeps this to a handful of
# extra calls on a normal day (often zero) rather than pulling history for all 30.
$context = @{}
if ($matches.Count -gt 0) {
    Write-Host "`nFetching RSI/ATR context for $($matches.Count) matched ticker(s)..."
    foreach ($m in $matches) {
        Start-Sleep -Seconds $delaySec
        $context[$m.Ticker] = Get-RsiAtrContext -Ticker $m.Ticker -ApiKey $Config.twelveDataApiKey
    }
}

$lines = @()
$lines += "SCREENER RUN - $(Get-Date -Format 'yyyy-MM-dd HH:mm') UK"
$lines += "Scanned $($results.Count)/$total tickers ($($failed.Count) fetch failures)"
$lines += ""

if ($strong.Count -eq 0 -and $pullback.Count -eq 0) {
    $lines += "No pullbacks detected across the watchlist universe today."
} else {
    if ($strong.Count -gt 0) {
        $lines += "STRONG BUY ZONE (<= $strongPct% today):"
        foreach ($s in $strong) {
            $lines += ("  {0} ({1}): {2:0.00}% - {3:0.00}" -f $s.Ticker, $s.Name, $s.Change, $s.Price)
            $lines += "    $(Format-ContextText -Ctx $context[$s.Ticker])"
        }
        $lines += ""
    }
    if ($pullback.Count -gt 0) {
        $lines += "PULLBACK ($strongPct% to $pullbackPct% today):"
        foreach ($p in $pullback) {
            $lines += ("  {0} ({1}): {2:0.00}% - {3:0.00}" -f $p.Ticker, $p.Name, $p.Change, $p.Price)
            $lines += "    $(Format-ContextText -Ctx $context[$p.Ticker])"
        }
        $lines += ""
    }
}

if ($failed.Count -gt 0) {
    $lines += "Fetch failed for: $($failed -join ', ')"
    $lines += ""
}

$lines += "Objective move detection only - no buy/sell opinion, no trades placed. Verify before acting."

$report = $lines -join "`n"

Write-Host $report
Write-Log -Path $Config.logPath -Text $report

$telegramText = Format-TelegramScreenerReport -Strong $strong -Pullback $pullback -Context $context `
    -Scanned $results.Count -Total $total -Failed $failed.Count -StrongPct $strongPct -PullbackPct $pullbackPct
Send-TelegramMessage -Token $Config.telegram.botToken -ChatId $Config.telegram.chatId -Text $telegramText -LogPath $Config.logPath

} finally {
    Remove-ApiLock -LogPath $Config.logPath
}
