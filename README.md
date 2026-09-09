# MaCrossoverBot

A MetaTrader 4 Expert Advisor written in MQL4. A moving-average crossover
is used as the entry signal, but the point of this project is the
surrounding machinery: risk-based position sizing, broker-constraint
handling, ECN-safe order placement, and retry logic for transient trade
errors.

> **This is not a profitable strategy.** A two-MA crossover has no
> persistent edge in liquid FX markets. Treat the signal as a placeholder
> and the execution layer as the actual deliverable.

## Layout

```
Experts/MaCrossoverBot.mq4    The Expert Advisor
Include/                      Shared helper headers (add as the project grows)
Scripts/                      One-shot utility scripts
docs/                         Strategy notes, backtest reports, screenshots
```

This mirrors the folder structure inside MT4's `MQL4/` data directory, so
each folder can be symlinked straight into the terminal.

## Installing into MetaTrader 4

1. In MT4: **File -> Open Data Folder**. This opens the terminal's data
   directory, which is *not* where the application itself lives.
2. Navigate into `MQL4/Experts`.
3. Symlink this repo's source file into it rather than copying, so that
   the file MetaEditor compiles and the file git tracks are the same file:

   ```bash
   ln -s "$(pwd)/Experts/MaCrossoverBot.mq4" \
         "/path/to/MQL4/Experts/MaCrossoverBot.mq4"
   ```

4. In MetaEditor, open the file and press **F7** to compile. A
   `MaCrossoverBot.ex4` appears next to the source; it is gitignored.
5. In MT4, refresh the Navigator panel and drag the EA onto a chart.

## Parameters

| Input | Meaning |
|---|---|
| `InpFastMaPeriod` / `InpSlowMaPeriod` | Crossover periods. Fast must be smaller than slow. |
| `InpUseRiskBasedSizing` | Size each trade from a % of balance instead of a fixed lot. |
| `InpRiskPercentPerTrade` | Percentage of balance risked per trade. Capped at 10% by a startup check. |
| `InpStopLossPips` / `InpTakeProfitPips` | Distances in pips. Required when risk-based sizing is on. |
| `InpMagicNumber` | Identifies this EA's trades so it never touches anything else. |
| `InpMaxSpreadPips` | Entries are skipped when the spread is wider than this. |

## Testing

Run in the Strategy Tester on **Open prices only** first — the EA makes
decisions once per completed bar, so tick-level modelling adds cost
without adding accuracy. Then run forward on a **demo account** for a
meaningful period before considering anything else.

## Status

Learning project. Not deployed against a live account.
