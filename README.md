# Trading Stocks — Mechanical Portfolio Rule Engine

A PowerShell automation system that watches a stock portfolio, applies user-defined
mechanical trading rules, and sends alerts — without ever placing a trade. Built
through AI pair-programming (Claude) across a single working session, from a plain
pasted "buy the dip" rule list to a scheduled system with live broker data, technical
indicators, and risk-based position sizing.

## What it does

- **PortfolioBot** — checks a watchlist of tickers daily against an entry rule, then
  confirms qualifying signals against RSI, Bollinger Bands, and a multi-day KAMA trend
  filter before sizing a suggested position with ATR-based volatility risk sizing
  (fixed % of account equity per trade, capped by a daily spend limit). Two entry
  rules are supported per ticker: **Model A** (fixed dollar thresholds + "only buy on
  red days") and **Model B** (buy when price is X% below its 20-day high on a red day,
  X from a 2-year backtest sweep). GOOGL runs Model B as a live pilot after Model A
  spent a month firing continuously the whole way down $360 → $329; the signal journal
  logs what the other model would have said each day for a running head-to-head.
- **ScreenerBot** — scans a wider universe of large-cap stocks for objective pullback
  moves (≥2% / ≥5% down), independent of the watchlist, with RSI/ATR context on
  anything that matches.
- **SmallCapScout** — the same pattern applied to a small/mid-cap universe, with wider
  pullback thresholds (small-caps move 2-5% on a normal day) and volume-spike
  detection (≥2x average volume). Pure information, same as ScreenerBot — no
  thresholds, no sizing, no signal.
- **CoinScout** — top-10 crypto by market prominence, spot prices only. RSI, ATR-as-%,
  and distance below the 20-day high per coin, with wider pullback thresholds still
  (crypto moves 3-8% on a normal day). There is no execution path — Trading 212 has no
  crypto — and nothing in it knows what leverage is. Once-a-day snapshot of a 24/7
  market, explicitly not a signal.
- **Live account sync** — pulls real cash balance from a Trading 212 account via its
  read-only API scope. The API key used has no order-placement permission, and the
  code never calls an order-placement endpoint — every trade is executed manually.
- **Telegram delivery** — both bots post a formatted daily report to Telegram, plus a
  full plain-text log and CSV signal history for after-the-fact review.

## Indicators implemented from scratch

`Indicators.ps1` is a small, dependency-free technical-analysis library: Kaufman's
Adaptive Moving Average (KAMA), RSI (Wilder smoothing), Bollinger Bands, Average True
Range (ATR), and ATR-based position sizing — plain PowerShell arrays and math, no
external packages.

## Design notes worth reading

- The KAMA trend filter isn't a naive day-over-day check — an earlier version was
  proven (algebraically and by test) to fire on almost any red day rather than a real
  downtrend, so it requires three consecutive declining days instead.
- Model B exists because fixed dollar thresholds don't survive a regime change: set
  against one price level, they become a line a trending stock walks straight through
  and keeps going. A relative pullback threshold ratchets with the 20-day high, so a
  slow grind lower stops re-triggering. `Backtest-ModelB.ps1` swept depths across
  2 years / 7 tickers; ~12% below the 20-day high was the best 20-day-forward bucket
  (n=411), with the edge still growing to 18% — hence buy at 12%, strong at 18%.
- `Backtest-IndicatorLayer.ps1` separately tested whether the RSI/Bollinger
  confirmation adds value on its own. On this basket it didn't (small sample, but
  consistently negative forward returns) — which is why the entry rule, not the
  confirmation layer, was the thing that got reworked.
- All three scheduled tasks share one third-party API key with an account-wide rate
  limit; a file-based mutual-exclusion lock stops them from colliding when one run
  overlaps another's trigger time (confirmed happening in practice, not theoretical -
  see commit history).
- `.Count` on a single-item PowerShell pipeline result is unreliable specifically
  under `-File` invocation (how Task Scheduler runs both scripts) — every filtered
  collection in this codebase is explicitly wrapped in `@(...)` to avoid it.

## What this project deliberately does not do

It does not predict prices, recommend stocks, or execute trades. Every signal is a
mechanical consequence of rules the user set; every purchase is made by hand.

## Setup

1. Copy `config.example.json` to `config.json` and fill in your own API keys
   (Twelve Data, Alpha Vantage, Telegram bot, Trading 212 — all free/read-only tiers).
2. `config.json` is gitignored — it holds live credentials and never belongs in
   version control.
3. Run `PortfolioBot.ps1` / `ScreenerBot.ps1` / `SmallCapScout.ps1` directly, or
   schedule them (e.g. Windows Task Scheduler) — see inline comments for the
   rate-limit-safe pacing they need.

## Stack

PowerShell 5.1+, Twelve Data + Alpha Vantage (market data), Trading 212 API
(read-only account sync), Telegram Bot API (alerts).
