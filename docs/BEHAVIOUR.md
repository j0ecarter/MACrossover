# What the EA does, tick by tick

A precise description of `Experts/MACrossover.mq4` v2.00, written so
that unexpected behaviour can be checked against intent rather than
guessed at.

## On attach — `OnInit()`

Refuses to start if any of these fail:

1. **Live account** and `InpAllowLiveAccount` is false. Checked first,
   before anything else, and raises an `Alert` as well as a log line.
2. MA periods below 1, or fast >= slow.
3. Risk percent outside 0–10.
4. ATR periods below 1, or non-positive multipliers.
5. Stop ceiling not above the floor.
6. Session hours outside 0–23, or start equal to end.

Then it establishes three facts about the broker and prints them:

| Fact | Source | Why it matters |
|---|---|---|
| Pip size | `Digits == 3 \|\| 5` → pip is 10 Points | Wrong here means every stop is 10x off |
| Lot precision | `MODE_LOTSTEP` | Rounding lots to the wrong precision gets orders rejected |
| GMT offset | `TimeCurrent() - TimeGMT()` | The session filter is meaningless without it |

It also adopts any position already open with its magic number, so a
restart or a parameter change mid-trade does not orphan a position.

## On every tick — `OnTick()`

In order:

1. **`DetectAndJournalClosedPosition()`** — if the tracked ticket has
   left the live pool, it closed on its stop or target. Journal it and
   clear the tracker. Done first so the loss counters are current
   before anything reads them.
2. **Trailing stop**, if enabled.
3. **Mid-bar exits**, if a position is open: Friday close, session end,
   daily loss cap. These cannot wait for a bar close — flattening
   before the weekend is pointless if you sit through the gap first.

Everything below is gated behind `IsNewBar()`.

## On each completed bar

4. `IsTradeAllowed()` — AutoTrading, the live-trading checkbox, broker
   permission. Logs when false.
5. Enough history for the slowest indicator in use (the baseline ATR
   needs 100 bars plus a margin).
6. `GetCrossoverSignal()` — SMA(20) vs SMA(50) at **shift 2 versus
   shift 1**. Never shift 0.
7. **If a position is open:**
   - Not an opposite signal → return.
   - Opposite signal → close. If the close fails, return without
     opening anything.
   - `InpReverseOnOppositeSignal` → fall through to entry.
   - Otherwise → return.
8. No signal → return.
9. Outside the session window → return, silently.
10. Friday close window → return.
11. Safety limits → return if any is breached.
12. Spread above the adaptive cap → return, with a log line.
13. `OpenPosition()`.

## Entry mechanics

Distances are resolved **once**, before sizing, and passed down — so a
position can never be sized against one stop and given another.

```
stopPips   = clamp(ATR(14) × 1.5, floor, ceiling), then floored at MODE_STOPLEVEL
targetPips = ATR(14) × 3.0, floored at MODE_STOPLEVEL
lots       = risk ÷ (stopPips × pipValuePerLot), rounded down
```

Then: free-margin check → up to 3 `OrderSend` attempts with
`RefreshRates()` before each → `OrderModify` to attach the levels →
journal row. If the modify fails after 3 attempts it logs
`WARNING: Ticket N is OPEN WITHOUT A STOP LOSS`.

## Trailing stop

Two guards decide whether it acts:

```mql4
if(proposedStop <= openPrice)                                   return;
if(currentStop > 0.0 && proposedStop < currentStop + trailStep) return;
```

The first means the trail never engages until price is more than one
trailing distance in profit — its first act is always to move the stop
from below the entry to above it. It is a break-even mechanism before
it is a trailing one. The second enforces a minimum improvement so it
is not sending a modify on every tick of a trend.

## Safety limits

All recomputed from closed-trade history rather than held in memory, so
a terminal restart cannot clear a limit that has already tripped.

- **Daily loss cap** — realised P/L including commission and swap since
  the start of the current *GMT* day, so the boundary lines up with the
  session filter rather than the broker's arbitrary day.
- **Trades per day** — counted by open time, including a position still
  running, so the cap cannot be exceeded by holding.
- **Consecutive losses** — walks back through closed trades until a win
  ends the streak. Each cooldown is anchored to the close time that
  triggered it, so it cannot re-arm on the same streak.

## What it deliberately does not do

- No pending orders; market orders only.
- Never more than one position at a time.
- Never touches an order without its magic number.
- No trend filter, no news filter, no equity-based (as opposed to
  realised) drawdown limit.
- No knowledge of whether the strategy is working. That is what the
  journal is for.
