# MACrossover

A MetaTrader 4 Expert Advisor written in MQL4, with a candle-countdown
indicator alongside it. Runs on EURUSD and GBPUSD M5.

**The strategy is a 20/50 moving-average crossover, and it does not
make money.** That is not modesty — it is the premise of the project.
A two-MA crossover has no persistent edge in liquid FX, and on a
5-minute chart the spread alone consumes a large share of the daily
range. The signal is a placeholder.

What the repository is actually about is everything wrapped around
that signal: sizing, risk limits, broker-constraint handling, error
recovery, and producing data you can learn from. Those parts transfer
to any strategy. The signal does not.

---

## What it does

Once per completed bar, the EA compares the 20 and 50 SMA on the two
most recently *closed* bars. A cross opens a position; the opposite
cross reverses it. Every trade carries a stop and a target sized from
current volatility, and the position size is calculated so that the
money at risk is the same regardless of how wide that stop is.

Around that sit the parts that took the actual work.

### Position sizing holds risk constant

```
riskAmount     = balance × riskPercent / 100
pipValuePerLot = (MODE_TICKVALUE / MODE_TICKSIZE) × pipSize
lots           = riskAmount / (stopPips × pipValuePerLot)
```

rounded **down** to the broker's lot step — rounding up would silently
exceed the configured risk — and refused entirely if the broker's
minimum lot would risk more than the budget allows.

Paired with ATR-scaled stops, this means a quiet market produces a
tight stop and a large position, an active one produces a wide stop
and a small position, and the money at risk is identical in both.

### Parameters scale to the symbol, not to a pair

GBPUSD moves roughly a third more than EURUSD and costs more to trade.
Rather than shipping per-pair presets, every threshold is expressed as
a multiple of the symbol's own volatility, measured as a long-period
ATR baseline:

| Threshold | Expressed as |
|---|---|
| Stop floor | `baselineATR × 0.5` |
| Stop ceiling | `baselineATR × 3.0` |
| Spread cap | `liveATR × 0.35`, with an absolute backstop |

The spread rule is the interesting one. What matters is not the spread
in isolation but the spread relative to the movement available: 1.5
pips against a 20-pip target is 7.5% given away at entry; the same 1.5
pips at 3am against a 4-pip range is fatal. Tying the cap to ATR gets
that right on any instrument without tuning.

### Safety limits that survive a restart

- Refuses to start on a live account unless explicitly overridden
- Daily loss cap, after which it stops entering and optionally flattens
- Maximum trades per day
- Consecutive-loss cooldown

Every one of these is recomputed from the broker's closed-trade history
rather than held in a variable, so restarting the terminal cannot reset
a limit that has already tripped.

### A health monitor

An EA can die quietly: removed from a chart, AutoTrading toggled off,
the terminal disconnected, a chart closed by accident. Nothing in MT4
tells you, and the first symptom is usually noticing days later that a
pair stopped trading.

`FleetMonitor` puts a panel on one chart showing whether everything you
expect to be running actually is:

```
FLEET  |  NOT ALL RUNNING  (2/3)
  GBPUSD M5 EA              RUNNING
  EURUSD M5 EA              RUNNING - AutoTrading off
  USDJPY M5 EA              NOT LOADED
  terminal: connected, AutoTrading on  |  18:42:07
```

MT4 gives an EA on one chart no way to see an EA on another - there is
no process list and no cross-chart API. The only state shared between
charts in a terminal is the GlobalVariable pool, so each component
publishes a heartbeat and a status bitmask there and the monitor reads
them back.

The heartbeat carries `TimeLocal()`, not `TimeCurrent()`. That
distinction is the whole trick: `TimeCurrent()` is the timestamp of the
last quote received, so it stops advancing in a quiet market and a
perfectly healthy EA would read as dead every night. The PC clock
always advances, and a timer rather than `OnTick` does the writing.

The status bitmask matters as much as the heartbeat, because a
heartbeat alone only proves the code is executing - it cannot tell
"running and working" from "running but unable to place a trade". The
monitor also distinguishes faults from the EA correctly doing nothing:
being outside the session window is information, having AutoTrading
switched off is an alarm. And it flags components that are heartbeating
but *not* in your expected list, which catches the opposite failure - an
EA left running on a chart you had forgotten about.

### A trade journal

Every entry and exit is appended to `MQL4/Files/<symbol>_MACrossover_journal.csv`
with the conditions at the time, not just the result:

```
server_time, gmt_time, event, ticket, symbol, timeframe, direction,
lots, price, stop_pips, target_pips, atr_pips, spread_pips, profit,
balance, trades_today, note
```

That makes questions like *do my losses cluster when spread was above
half the ATR?* or *is the 20:00 flatten costing me?* answerable by
sorting a spreadsheet instead of guessing. Exits taken by the stop or
target are detected and journalled too, not only the ones the EA
closes itself.

### Execution details that bite in practice

- **Pips are not Points.** On a 5-digit feed a pip is ten Points.
  Slippage and `MODE_STOPLEVEL` are quoted in Points; humans think in
  pips. Conflating them makes every stop ten times too tight.
- **Decisions only at bar close**, comparing indicator shifts 1 and 2.
  Reading shift 0 lets a signal appear and vanish as the bar forms,
  which is the classic reason a backtest and live trading disagree.
- **Orders are sent bare, then modified** to attach stops. Many ECN
  brokers reject an `OrderSend` carrying SL/TP with error 130.
- **Errors are split by whether a retry could help.** Requotes and busy
  trade contexts are retried; invalid volume and disabled trading are
  not, because they will fail identically every time.
- **Session filter works in GMT**, with the broker's server offset
  detected from `TimeGMT()` at startup and a manual fallback for the
  Strategy Tester, where `TimeGMT()` is modelled and meaningless.

---

## Two bugs worth reading about

Both were found by review rather than by testing, and both are the kind
that produce plausible-looking behaviour rather than an error.

**Sizing used a pre-clamp stop.** `AttachStopsToOrder` widens any stop
that falls inside the broker's `MODE_STOPLEVEL`, because the broker
rejects anything tighter. But the sizing calculation used the narrower
pre-clamp figure — so a position built for a 5-pip stop could be given
a 7-pip one, and the real money at risk exceeded the configured
percentage by 40%. Silently, and only on trades where the clamp
happened to fire. The clamp now happens once, before sizing.

**The EA only traded in one direction.** On an opposite crossover it
closed the position and returned without opening the new one. Because
crossovers strictly alternate, it was always flat by the time the next
signal arrived — and that signal was necessarily back in the original
direction. Whichever way it happened to enter first was the only way it
ever traded. Fixed in 2.00, with the close now checked for success
before reversing so a failed close cannot stack an opposing position.

A third, in the cooldown: it re-armed forever, because the losing
streak it read from history did not change while it waited, so the same
streak re-tripped the limit the instant the pause expired. Each trigger
is now anchored to the close time that caused it.

---

## Layout

```
Experts/MACrossover.mq4       The Expert Advisor
Indicators/CandleTimer.mq4    "Candle closes in MM:SS" chart label
Indicators/FleetMonitor.mq4   Is everything actually running?
tools/find_mt4.sh             Locate the Wine-hosted MT4 data folder
tools/install_to_mt4.sh       Symlink both sources into MQL4/
tools/build.sh                Headless compile via metaeditor.exe
docs/                         Behaviour notes
```

`Experts/`, `Indicators/`, `Include/` and `Scripts/` mirror MT4's own
`MQL4/` layout so each can be symlinked straight in.

## Installing

```bash
./tools/install_to_mt4.sh
```

Symlinks rather than copies, so the file MetaEditor compiles and the
file git tracks are the same file. Then open each in MetaEditor and
press **F7**, and refresh MT4's Navigator.

On macOS, MT4 runs in a Wine wrapper and its data folder is buried
inside the prefix rather than sitting next to the `.app`.
`tools/find_mt4.sh` locates it.

## Running it

Attach to a **EURUSD or GBPUSD M5** chart — the EA takes its symbol and
timeframe from the chart, there is no input for either. Tick *Allow
live trading*, enable *AutoTrading*, and read the startup block in the
Experts log: it prints the detected pip geometry, the broker's GMT
offset, the session window, and the ATR-derived stop it would use right
now. If the pip size is wrong, everything downstream is wrong.

It will refuse to start on a live account.

## Testing

Run in the Strategy Tester on **Open prices only** first — decisions
are made at bar close, so tick-level modelling adds cost without
accuracy. Use visual mode as a functional smoke test: does it enter,
place stops, stop at the session boundary, flatten on Friday?

Do not read the tester's *results* as meaningful. With an ATR-sized
stop on M5, MT4's interpolated ticks cannot resolve whether the stop or
the target was hit first inside a bar, so it guesses. Demo
forward-testing and the CSV journal tell you far more.

## Status

Learning project, built to understand MT4's execution model and the
mechanics of automated order handling. Not deployed against a live
account, and not intended to be.

## Licence

MIT — see [LICENSE](LICENSE).
