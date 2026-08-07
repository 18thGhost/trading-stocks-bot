#requires -Version 5.1
<#
Small/mid-cap observation scanner. Same spirit as ScreenerBot but with wider
pullback thresholds (small-caps move 2-5% on a normal day) and volume-spike
flagging. Purely informational - no thresholds, no ATR sizing, no buy signal.
Universe is hand-picked from general knowledge, not live-verified market cap
(Twelve Data's free tier doesn't expose market-cap data). Runs slowly (one
request per requestDelaySeconds) to respect Twelve Data's free-tier 8 req/min
cap, and shares the twelvedata.lock with PortfolioBot/ScreenerBot so all three
never collide on the same API budget.
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
    $file = Join-Path $Path ("smallcap_{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))
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
        $volRatio = $null
        if ($resp.volume -and $resp.average_volume -and [double]$resp.average_volume -gt 0) {
            $volRatio = [double]$resp.volume / [double]$resp.average_volume
        }
        return @{
            price         = [double]$resp.close
            changePercent = [double]$resp.percent_change
            name          = $resp.name
            volumeRatio   = $volRatio
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

function Format-ContextText {
    param($Ctx)
    if (-not $Ctx) { return "RSI/ATR unavailable" }
    $tag = if ($Ctx.RSI -le 30) { " (oversold)" } elseif ($Ctx.RSI -ge 70) { " (overbought)" } else { "" }
    return "RSI $([math]::Round($Ctx.RSI,1))$tag, ATR $([math]::Round($Ctx.ATR,2))"
}

function Format-TelegramSmallCapReport {
    param([array]$Strong, [array]$Pullback, [array]$VolumeSpikes, $Context, [int]$Scanned, [int]$Total, [int]$Failed, [double]$StrongPct, [double]$PullbackPct)

    $t = @()
    $t += "🔬 SMALL CAP SCOUT - $(Get-Date -Format 'HH:mm') UK"
    $t += "Scanned $Scanned/$Total tickers ($Failed failed) | observation only, no thresholds, no trades"
    $t += ""

    if ($Strong.Count -eq 0 -and $Pullback.Count -eq 0 -and $VolumeSpikes.Count -eq 0) {
        $t += "✅ Nothing unusual across the small-cap watchlist today."
    } else {
        if ($Strong.Count -gt 0) {
            $t += "🔴 DEEP PULLBACK (<= $StrongPct% today):"
            foreach ($s in $Strong) {
                $t += "  $($s.Ticker) ($($s.Name)): $([math]::Round($s.Change,2))% - $([math]::Round($s.Price,2))"
                $ctx = $Context[$s.Ticker]
                if ($ctx) {
                    $rsiEmoji = if ($ctx.RSI -gt 70) { " 🔥" } elseif ($ctx.RSI -lt 30) { " ❄️" } else { "" }
                    $t += "    📊 RSI: $([math]::Round($ctx.RSI,1))$rsiEmoji | ATR: $([math]::Round($ctx.ATR,2))"
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
                }
            }
            $t += ""
        }
        if ($VolumeSpikes.Count -gt 0) {
            $t += "📢 UNUSUAL VOLUME (>= 2x average):"
            foreach ($v in $VolumeSpikes) {
                $dirEmoji = if ($v.Change -ge 0) { "🟢" } else { "🔴" }
                $t += "  $dirEmoji $($v.Ticker) ($($v.Name)): $([math]::Round($v.Change,2))% - Volume $([math]::Round($v.VolumeRatio,1))x avg"
            }
            $t += ""
        }
    }

    $t += "Objective move/volume detection only - no buy/sell opinion, no trades placed. Verify before acting."
    return ($t -join "`n")
}

# ---- main ----

$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$scout = $Config.smallCapScout

if (-not $scout -or -not $scout.universe -or $scout.universe.Count -eq 0) {
    Write-Host "No smallCapScout.universe configured - nothing to scan." -ForegroundColor Yellow
    exit 1
}

if (-not (Wait-ForApiLock -LogPath $Config.logPath -OwnerName "SmallCapScout")) {
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

foreach ($ticker in $scout.universe) {
    $i++
    Write-Host "[$i/$total] Checking $ticker..."
    $q = Get-TwelveDataQuote -Symbol $ticker -ApiKey $Config.twelveDataApiKey
    if ($q) {
        $results += [pscustomobject]@{
            Ticker      = $ticker
            Name        = $q.name
            Price       = $q.price
            Change      = $q.changePercent
            VolumeRatio = $q.volumeRatio
        }
    } else {
        $failed += $ticker
    }
    if ($i -lt $total) { Start-Sleep -Seconds $delaySec }
}

$strong = @($results | Where-Object { $_.Change -le $strongPct } | Sort-Object Change)
$pullback = @($results | Where-Object { $_.Change -le $pullbackPct -and $_.Change -gt $strongPct } | Sort-Object Change)
$volumeSpikes = @($results | Where-Object { $null -ne $_.VolumeRatio -and $_.VolumeRatio -ge 2.0 } | Sort-Object VolumeRatio -Descending)
$matches = @($strong) + @($pullback)

$context = @{}
if ($matches.Count -gt 0) {
    Write-Host "`nFetching RSI/ATR context for $($matches.Count) matched ticker(s)..."
    foreach ($m in $matches) {
        Start-Sleep -Seconds $delaySec
        $context[$m.Ticker] = Get-RsiAtrContext -Ticker $m.Ticker -ApiKey $Config.twelveDataApiKey
    }
}

$lines = @()
$lines += "SMALL CAP SCOUT - $(Get-Date -Format 'yyyy-MM-dd HH:mm') UK"
$lines += "Scanned $($results.Count)/$total tickers ($($failed.Count) fetch failures) - observation only, no thresholds, no trades"
$lines += ""

if ($strong.Count -eq 0 -and $pullback.Count -eq 0 -and $volumeSpikes.Count -eq 0) {
    $lines += "Nothing unusual across the small-cap watchlist today."
} else {
    if ($strong.Count -gt 0) {
        $lines += "DEEP PULLBACK (<= $strongPct% today):"
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
    if ($volumeSpikes.Count -gt 0) {
        $lines += "UNUSUAL VOLUME (>= 2x average):"
        foreach ($v in $volumeSpikes) {
            $lines += ("  {0} ({1}): {2:0.00}% - volume {3:0.0}x avg" -f $v.Ticker, $v.Name, $v.Change, $v.VolumeRatio)
        }
        $lines += ""
    }
}

if ($failed.Count -gt 0) {
    $lines += "Fetch failed for: $($failed -join ', ')"
    $lines += ""
}

$lines += "Objective move/volume detection only - no buy/sell opinion, no trades placed. Verify before acting."

$report = $lines -join "`n"

Write-Host $report
Write-Log -Path $Config.logPath -Text $report

$telegramText = Format-TelegramSmallCapReport -Strong $strong -Pullback $pullback -VolumeSpikes $volumeSpikes -Context $context `
    -Scanned $results.Count -Total $total -Failed $failed.Count -StrongPct $strongPct -PullbackPct $pullbackPct
Send-TelegramMessage -Token $Config.telegram.botToken -ChatId $Config.telegram.chatId -Text $telegramText -LogPath $Config.logPath

} finally {
    Remove-ApiLock -LogPath $Config.logPath
}
