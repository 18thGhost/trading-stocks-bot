#requires -Version 5.1
<#
Standard technical indicator math: KAMA, Bollinger Bands, RSI, ATR, and ATR-based
position sizing. Pure functions operating on plain double[] arrays - no external
libraries. These are generic, publicly documented formulas, not tied to any
specific security. They compute numbers; they render no opinion on what to buy.
#>

function Get-KAMA {
    param(
        [double[]]$Prices,
        [int]$Period = 10,
        [int]$FastPeriod = 2,
        [int]$SlowPeriod = 30
    )
    $n = $Prices.Length
    if ($n -le $Period) { throw "Need more than $Period prices to compute KAMA($Period)" }

    $fastSC = 2.0 / ($FastPeriod + 1)
    $slowSC = 2.0 / ($SlowPeriod + 1)

    $kama = New-Object 'object[]' $n
    for ($i = 0; $i -lt $Period; $i++) { $kama[$i] = $null }
    $kama[$Period] = $Prices[$Period]

    for ($t = $Period + 1; $t -lt $n; $t++) {
        $change = [math]::Abs($Prices[$t] - $Prices[$t - $Period])
        $volatility = 0.0
        for ($i = $t - $Period + 1; $i -le $t; $i++) {
            $volatility += [math]::Abs($Prices[$i] - $Prices[$i - 1])
        }
        $er = if ($volatility -eq 0) { 0.0 } else { $change / $volatility }
        $sc = [math]::Pow(($er * ($fastSC - $slowSC) + $slowSC), 2)
        $prevKama = [double]$kama[$t - 1]
        $kama[$t] = $prevKama + $sc * ($Prices[$t] - $prevKama)
    }
    return $kama
}

function Get-RSI {
    param(
        [double[]]$Prices,
        [int]$Period = 14
    )
    $n = $Prices.Length
    if ($n -le $Period) { throw "Need more than $Period prices to compute RSI($Period)" }

    $rsi = New-Object 'object[]' $n
    for ($i = 0; $i -le $Period; $i++) { $rsi[$i] = $null }

    $gainSum = 0.0
    $lossSum = 0.0
    for ($i = 1; $i -le $Period; $i++) {
        $delta = $Prices[$i] - $Prices[$i - 1]
        if ($delta -gt 0) { $gainSum += $delta } else { $lossSum += [math]::Abs($delta) }
    }
    $avgGain = $gainSum / $Period
    $avgLoss = $lossSum / $Period
    $rsi[$Period] = if ($avgLoss -eq 0) { 100.0 } else { 100.0 - (100.0 / (1.0 + ($avgGain / $avgLoss))) }

    for ($t = $Period + 1; $t -lt $n; $t++) {
        $delta = $Prices[$t] - $Prices[$t - 1]
        $gain = if ($delta -gt 0) { $delta } else { 0.0 }
        $loss = if ($delta -lt 0) { [math]::Abs($delta) } else { 0.0 }
        $avgGain = (($avgGain * ($Period - 1)) + $gain) / $Period
        $avgLoss = (($avgLoss * ($Period - 1)) + $loss) / $Period
        $rsi[$t] = if ($avgLoss -eq 0) { 100.0 } else { 100.0 - (100.0 / (1.0 + ($avgGain / $avgLoss))) }
    }
    return $rsi
}

function Get-BollingerBands {
    param(
        [double[]]$Prices,
        [int]$Period = 20,
        [double]$NumStdDev = 2.0
    )
    $n = $Prices.Length
    if ($n -lt $Period) { throw "Need at least $Period prices to compute Bollinger Bands($Period)" }

    $upper = New-Object 'object[]' $n
    $middle = New-Object 'object[]' $n
    $lower = New-Object 'object[]' $n
    for ($i = 0; $i -lt ($Period - 1); $i++) { $upper[$i] = $null; $middle[$i] = $null; $lower[$i] = $null }

    for ($t = $Period - 1; $t -lt $n; $t++) {
        $window = $Prices[($t - $Period + 1)..$t]
        $mean = ($window | Measure-Object -Average).Average
        $sumSqDiff = 0.0
        foreach ($p in $window) { $sumSqDiff += [math]::Pow($p - $mean, 2) }
        $stdDev = [math]::Sqrt($sumSqDiff / $Period)

        $middle[$t] = $mean
        $upper[$t] = $mean + ($NumStdDev * $stdDev)
        $lower[$t] = $mean - ($NumStdDev * $stdDev)
    }
    return @{ Upper = $upper; Middle = $middle; Lower = $lower }
}

function Get-MeanReversionSignal {
    param(
        [double]$Price,
        [double]$UpperBand,
        [double]$LowerBand,
        [double]$RSI,
        [double]$OversoldRSI = 30,
        [double]$OverboughtRSI = 70
    )
    if ($Price -le $LowerBand -and $RSI -le $OversoldRSI) { return "OVERSOLD" }
    if ($Price -ge $UpperBand -and $RSI -ge $OverboughtRSI) { return "OVERBOUGHT" }
    return "NEUTRAL"
}

function Get-ATR {
    param(
        [double[]]$High,
        [double[]]$Low,
        [double[]]$Close,
        [int]$Period = 14
    )
    $n = $High.Length
    if ($High.Length -ne $Low.Length -or $High.Length -ne $Close.Length) {
        throw "High, Low, Close arrays must be the same length"
    }
    if ($n -le $Period) { throw "Need more than $Period bars to compute ATR($Period)" }

    $tr = New-Object double[] $n
    $tr[0] = $High[0] - $Low[0]
    for ($i = 1; $i -lt $n; $i++) {
        $range1 = $High[$i] - $Low[$i]
        $range2 = [math]::Abs($High[$i] - $Close[$i - 1])
        $range3 = [math]::Abs($Low[$i] - $Close[$i - 1])
        $tr[$i] = [math]::Max($range1, [math]::Max($range2, $range3))
    }

    $atr = New-Object 'object[]' $n
    for ($i = 0; $i -lt $Period; $i++) { $atr[$i] = $null }

    $sum = 0.0
    for ($i = 1; $i -le $Period; $i++) { $sum += $tr[$i] }
    $atr[$Period] = $sum / $Period

    for ($t = $Period + 1; $t -lt $n; $t++) {
        $atr[$t] = ((([double]$atr[$t - 1]) * ($Period - 1)) + $tr[$t]) / $Period
    }
    return $atr
}

function Get-ATRPositionSize {
    param(
        [double]$AccountEquity,
        [double]$RiskPercent,
        [double]$ATR,
        [double]$ATRMultiplier = 2.0
    )
    # Returns fractional shares - T212 supports fractional share quantities,
    # so this deliberately does NOT floor to a whole share.
    $dollarRiskPerShare = $ATR * $ATRMultiplier
    if ($dollarRiskPerShare -le 0) { return 0.0 }
    $dollarRiskPerTrade = $AccountEquity * $RiskPercent
    return $dollarRiskPerTrade / $dollarRiskPerShare
}
