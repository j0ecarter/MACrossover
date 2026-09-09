# MACrossover

A MetaTrader 4 Expert Advisor written in MQL4, tuned for **EURUSD M5**.
A moving-average crossover is the entry signal, but the point of this
project is the surrounding machinery: ATR-scaled stops, risk-based
position sizing, a session filter, broker-constraint handling,
ECN-safe order placement, and retry logic for transient trade errors.

> **This is not a profitable strategy.** A two-MA crossover has no
> persistent edge, and on M5 spread alone consumes a large share of the
> daily range. Treat the signal as a placeholder and the execution layer
> as the actual deliverable.

## Why M5 needed more than a timeframe change

The EA reads `Period()`, so it runs on any chart. But two things break
down when you move from H1 to M5, and both are handled explicitly.

**Volatility swings too much for a fixed stop.** EURUSD M5 ATR runs
roughly 3-5 pips through London and New York and under 2 pips overnight.
A 10-pip stop is generous at 04:00 and tight at 13:30. So the stop is
sized from ATR instead, and position size varies per trade to keep the
*money* at risk constant. Wider stop, smaller position; the risk in
pounds does not move.

**The quiet hours are actively harmful.** Overnight, M5 ranges collapse
to a pip or two while spread stays constant, so cost as a fraction of
available movement goes vertical. The daily rollover is worse. A session
filter restricts entries to 07:00-20:00 GMT on weekdays, and positions
are flattened at the session close and before the weekend - a 7-pip stop
cannot survive a Sunday-open gap.

## Layout

```
Experts/MACrossover.mq4       The Expert Advisor
Indicators/CandleTimer.mq4    "Candle closes in MM:SS" chart label
Include/                      Shared helper headers (add as the project grows)
Scripts/                      One-shot utility scripts
docs/                         Strategy notes, backtest reports, screenshots
tools/find_mt4.sh             Locate the Wine-hosted MT4 installation
tools/install_to_mt4.sh       Symlink the EA into MQL4/Experts
tools/build.sh                Headless compile via metaeditor.exe
```

`Experts/`, `Include/` and `Scripts/` mirror the folder structure inside
MT4's `MQL4/` data directory, so each can be symlinked straight in.

## Installing into MetaTrader 4

```bash
./tools/install_to_mt4.sh
```

This finds the MQL4 data folder inside MT4's Wine prefix and symlinks
the EA into `MQL4/Experts/`. A symlink rather than a copy, so the file
MetaEditor compiles and the file git tracks are the same file.

Then in MetaEditor open `MACrossover.mq4` and press **F7**. In MT4,
refresh the Navigator panel, drag the EA onto a EURUSD M5 chart, tick
**Allow live trading**, and enable **AutoTrading**.

If the script cannot find the data folder, run `./tools/find_mt4.sh` -
it is read-only and prints every relevant path.

## Parameters

Defaults are set for EURUSD M5.

### Strategy

| Input | Default | Meaning |
|---|---|---|
| `InpFastMaPeriod` / `InpSlowMaPeriod` | 20 / 50 | Crossover periods. Fast must be smaller than slow. |
| `InpMaMethod` / `InpMaPrice` | SMA / Close | How the averages are built. |

### Risk and stop sizing

| Input | Default | Meaning |
|---|---|---|
| `InpRiskPercentPerTrade` | 0.5 | Percent of balance risked per trade. Half the H1 figure, because M5 takes many more trades. |
| `InpUseAtrStops` | true | Size stops from ATR rather than a fixed pip count. |
| `InpAtrStopMultiplier` | 1.5 | Stop distance = ATR x this. |
| `InpAtrTargetMultiplier` | 3.0 | Target distance = ATR x this, i.e. a 2:1 reward-to-risk shape. |
| `InpMinStopPips` / `InpMaxStopPips` | 5 / 25 | Clamps. The floor stops a dead-quiet market producing a stop that spread alone would close; the ceiling stops a news spike producing a position too small for the broker's minimum lot. |
| `InpStopLossPips` / `InpTakeProfitPips` | 10 / 20 | Used only when `InpUseAtrStops` is false. |

### Trading hours

| Input | Default | Meaning |
|---|---|---|
| `InpUseSessionFilter` | true | Restrict entries to the window below. |
| `InpSessionStartHourGmt` / `InpSessionEndHourGmt` | 7 / 20 | London open through NY afternoon, in **GMT**. |
| `InpCloseAtSessionEnd` | true | Flatten when the window closes. |
| `InpCloseBeforeWeekend` / `InpFridayCloseHourGmt` | true / 19 | Do not hold through the weekend gap. |
| `InpAutoDetectGmtOffset` | true | Derive the broker's server offset from `TimeGMT()`. Falls back to `InpBrokerGmtOffsetHours` in the Strategy Tester, where `TimeGMT()` is modelled and meaningless. |

### Execution

| Input | Default | Meaning |
|---|---|---|
| `InpMagicNumber` | 20260909 | Identifies this EA's trades so it never touches anything else. |
| `InpMaxSpreadPips` | 1.5 | Entries are skipped when the spread is wider. Tighter than the H1 default, because 1.5 pips against a 20-pip target is already 7.5% given away at entry. |
| `InpMaxSlippagePips` | 1.0 | Maximum accepted price deviation. |

## What to check in the log

On attach, the Experts tab should show the pip geometry, the detected
broker clock offset, the session window, and the current ATR-derived
stop. Verify:

- `pip=0.00010, points per pip=10` on a 5-digit EURUSD feed. If it reads
  `0.00001`, every stop distance is wrong by a factor of ten.
- The detected GMT offset matches your broker (usually GMT+2 or GMT+3).
- Watch for `error 130 (invalid stops)`. With ATR stops on M5 the
  broker's `MODE_STOPLEVEL` clamp fires far more often than on H1.

## Testing

MT4's Strategy Tester interpolates M1 data into fake ticks. On H1 that
is roughly tolerable; with a 7-pip stop on M5 the tester genuinely
cannot tell whether the stop or the target was hit first inside a bar,
so it guesses. **Treat M5 backtest results as close to meaningless**
unless you import real tick data. Demo forward-testing is far more
informative.

## Status

Learning project. Not deployed against a live account.
