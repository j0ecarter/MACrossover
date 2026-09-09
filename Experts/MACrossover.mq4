//+------------------------------------------------------------------+
//|                                                MACrossover.mq4    |
//|                                                                   |
//|  A deliberately simple, heavily commented MT4 Expert Advisor,     |
//|  written as a learning skeleton rather than as a money-maker.     |
//|                                                                   |
//|  STRATEGY                                                         |
//|    - Two simple moving averages: one fast, one slow.              |
//|    - Fast crosses ABOVE slow on a completed bar  -> open long.    |
//|    - Fast crosses BELOW slow on a completed bar  -> open short.   |
//|    - At most one position open at a time for this EA.             |
//|    - Every decision is made once per COMPLETED bar, never on      |
//|      every incoming tick. See IsNewBar() for why this matters.    |
//|                                                                   |
//|  TUNED FOR M5                                                     |
//|    Defaults below are set for a 5-minute EURUSD chart. Two        |
//|    features exist specifically because M5 is a harsher            |
//|    environment than H1:                                           |
//|                                                                   |
//|    1. ATR-BASED STOPS. A fixed 10-pip stop is generous at 04:00   |
//|       and suffocating at 13:30, because EURUSD M5 volatility      |
//|       swings by a factor of three or more across the day. Sizing  |
//|       the stop from ATR makes it track the market it is in.       |
//|       Position size then varies per trade to keep the MONEY at    |
//|       risk constant - which is the point of risk-based sizing.    |
//|                                                                   |
//|    2. A TRADING-HOURS FILTER. On H1 the Asian session is merely   |
//|       quiet. On M5 it is a whipsaw generator: ranges collapse to  |
//|       a pip or two while spread stays constant, so cost as a      |
//|       fraction of available movement goes vertical. The daily     |
//|       rollover is worse still. The filter works in GMT, with the  |
//|       broker's server offset detected automatically.              |
//|                                                                   |
//|  HONEST WARNING                                                   |
//|    A moving-average crossover has no persistent edge, and on M5   |
//|    spread alone will consume a large share of the daily range.    |
//|    Everything valuable in this file is the plumbing around the    |
//|    signal: position sizing, broker constraints, order error       |
//|    handling and state management. Swap the signal out later;      |
//|    keep the plumbing.                                             |
//+------------------------------------------------------------------+
#property copyright "Joe"
#property version   "1.10"
#property strict                 // Enforces modern MQL4 rules. Always keep this on.

//====================================================================
// SECTION 1 - USER INPUTS
//--------------------------------------------------------------------
// "input" variables appear in the EA's properties dialog in MT4 and
// in the Strategy Tester's optimisation tab. Anything you might ever
// want to tune without recompiling belongs here.
//====================================================================

input string  InpSectionStrategy       = "--- Strategy ---";
input int     InpFastMaPeriod          = 20;     // Fast MA period (bars)
input int     InpSlowMaPeriod          = 50;     // Slow MA period (bars)
input ENUM_MA_METHOD     InpMaMethod   = MODE_SMA;      // MA calculation method
input ENUM_APPLIED_PRICE InpMaPrice    = PRICE_CLOSE;   // Price the MA is built from

input string  InpSectionRisk           = "--- Risk & sizing ---";
input bool    InpUseRiskBasedSizing    = true;   // true = size from % risk, false = fixed lots
input double  InpRiskPercentPerTrade   = 0.5;    // % of balance risked per trade (halved for M5)
input double  InpFixedLotSize          = 0.01;   // Lots used when risk-based sizing is off

input string  InpSectionStops          = "--- Stop sizing ---";
input bool    InpUseAtrStops           = true;   // true = size stops from ATR, false = fixed pips
input int     InpAtrPeriod             = 14;     // ATR lookback in bars
input double  InpAtrStopMultiplier     = 1.5;    // Stop distance = ATR x this
input double  InpAtrTargetMultiplier   = 3.0;    // Target distance = ATR x this
input double  InpAtrTrailingMultiplier = 1.0;    // Trailing distance = ATR x this
input double  InpMinStopPips           = 5.0;    // Floor on the ATR-derived stop
input double  InpMaxStopPips           = 25.0;   // Ceiling on the ATR-derived stop
input double  InpStopLossPips          = 10.0;   // Fixed stop, used when ATR stops are off
input double  InpTakeProfitPips        = 20.0;   // Fixed target, used when ATR stops are off

input string  InpSectionSession        = "--- Trading hours (GMT) ---";
input bool    InpUseSessionFilter      = true;   // Only take entries inside the window below
input int     InpSessionStartHourGmt   = 7;      // 07:00 GMT - around the London open
input int     InpSessionEndHourGmt     = 20;     // 20:00 GMT - mid NY afternoon
input bool    InpCloseAtSessionEnd     = true;   // Flatten when the window closes
input bool    InpCloseBeforeWeekend    = true;   // Do not carry a position over the weekend
input int     InpFridayCloseHourGmt    = 19;     // Friday flatten time
input bool    InpAutoDetectGmtOffset   = true;   // Work out the broker's server offset itself
input int     InpBrokerGmtOffsetHours  = 2;      // Manual offset, used in the tester or as fallback

input string  InpSectionManagement     = "--- Trade management ---";
input bool    InpCloseOnOppositeSignal = true;   // Close the position when the MAs cross back
input bool    InpUseTrailingStop       = true;   // Enable a trailing stop
input double  InpTrailingStopPips      = 8.0;    // Trailing distance, when ATR stops are off
input double  InpTrailingStepPips      = 2.0;    // Minimum improvement before moving the stop

input string  InpSectionExecution      = "--- Execution ---";
input int     InpMagicNumber           = 20260909;// Unique ID so this EA only touches its own trades
input double  InpMaxSpreadPips         = 1.5;    // Skip entries when the spread is wider than this
input double  InpMaxSlippagePips       = 1.0;    // Maximum price deviation we will accept
input int     InpOrderRetryAttempts    = 3;      // How many times to retry a rejected order
input int     InpOrderRetryDelayMs     = 500;    // Pause between retries, in milliseconds
input string  InpTradeComment          = "MACrossover";

//====================================================================
// SECTION 2 - GLOBAL STATE
//--------------------------------------------------------------------
// Globals in an EA persist between ticks but are re-initialised when
// the EA is reloaded, the timeframe is changed, or the chart symbol
// is changed. Keep this list short and obvious.
//====================================================================

// Size of one "pip" expressed in price units for the current symbol.
// On a 5-digit EURUSD quote (1.09876) one pip is 0.0001, which is ten
// Points, not one. Getting this wrong is the single most common bug
// in beginner EAs - all your stops end up ten times too tight.
double   g_pipSizeInPrice     = 0.0;

// Number of Points in one pip (1 on 4-digit brokers, 10 on 5-digit).
// Slippage and broker stop levels are quoted in Points, not pips.
int      g_pointsPerPip       = 1;

// Number of decimal places a lot size may have, derived from the
// broker's lot step (e.g. step 0.01 -> 2 decimals).
int      g_lotDigits          = 2;

// Open time of the last bar we have already made a decision on.
// Used by IsNewBar() to run the strategy exactly once per bar.
datetime g_lastProcessedBar   = 0;

// Hours to subtract from the broker's server clock to get GMT.
// Brokers rarely run on GMT - most sit on GMT+2 or GMT+3 - so every
// session comparison has to go through this.
int      g_brokerGmtOffset    = 0;

//====================================================================
// SECTION 3 - LIFECYCLE EVENT HANDLERS
//--------------------------------------------------------------------
// MT4 calls these for you. You never call them yourself.
//   OnInit()   - once, when the EA is attached or reloaded.
//   OnTick()   - once for every incoming price tick.
//   OnDeinit() - once, when the EA is removed or the terminal closes.
//====================================================================

//+------------------------------------------------------------------+
//| Called once when the EA starts. Validate inputs here and fail     |
//| loudly rather than letting a bad configuration reach the market.  |
//+------------------------------------------------------------------+
int OnInit()
{
   // --- Validate the strategy parameters -------------------------
   if(InpFastMaPeriod < 1 || InpSlowMaPeriod < 1)
   {
      Print("ERROR: MA periods must be at least 1.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpFastMaPeriod >= InpSlowMaPeriod)
   {
      Print("ERROR: Fast MA period (", InpFastMaPeriod,
            ") must be smaller than slow MA period (", InpSlowMaPeriod, ").");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // --- Validate the risk parameters ------------------------------
   if(InpUseRiskBasedSizing &&
      (InpRiskPercentPerTrade <= 0.0 || InpRiskPercentPerTrade > 10.0))
   {
      Print("ERROR: Risk percent must be between 0 and 10. ",
            "Anything above ~2% per trade is reckless.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // --- Validate the stop parameters ------------------------------
   if(InpUseAtrStops)
   {
      if(InpAtrPeriod < 1)
      {
         Print("ERROR: ATR period must be at least 1.");
         return(INIT_PARAMETERS_INCORRECT);
      }
      if(InpAtrStopMultiplier <= 0.0 || InpAtrTargetMultiplier <= 0.0)
      {
         Print("ERROR: ATR multipliers must be greater than zero.");
         return(INIT_PARAMETERS_INCORRECT);
      }
      if(InpMinStopPips <= 0.0 || InpMaxStopPips <= InpMinStopPips)
      {
         Print("ERROR: Need 0 < InpMinStopPips < InpMaxStopPips.");
         return(INIT_PARAMETERS_INCORRECT);
      }
   }
   else if(InpUseRiskBasedSizing && InpStopLossPips <= 0.0)
   {
      // Risk-based sizing divides by the stop distance, so it cannot
      // work without one.
      Print("ERROR: Risk-based sizing needs a non-zero stop loss to size against.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // --- Validate the session window -------------------------------
   if(InpUseSessionFilter)
   {
      if(InpSessionStartHourGmt < 0 || InpSessionStartHourGmt > 23 ||
         InpSessionEndHourGmt   < 0 || InpSessionEndHourGmt   > 23)
      {
         Print("ERROR: Session hours must be in the range 0-23.");
         return(INIT_PARAMETERS_INCORRECT);
      }
      if(InpSessionStartHourGmt == InpSessionEndHourGmt)
      {
         Print("ERROR: Session start and end hours are identical, ",
               "which leaves no window to trade in.");
         return(INIT_PARAMETERS_INCORRECT);
      }
   }

   // --- Work out the symbol's pip geometry ------------------------
   CalculatePipGeometry();

   // --- Work out how many decimals the broker allows on lot sizes --
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(lotStep <= 0.0) lotStep = 0.01;                  // Defensive fallback.
   g_lotDigits = (int)MathRound(-MathLog10(lotStep));  // 0.01 -> 2, 0.1 -> 1
   if(g_lotDigits < 0) g_lotDigits = 0;

   // --- Work out the broker's clock offset from GMT ---------------
   g_brokerGmtOffset = DetermineBrokerGmtOffset();

   Print(InpTradeComment, " initialised on ", Symbol(),
         " ", TimeframeToText(Period()),
         ". Digits=", Digits,
         ", pip=", DoubleToString(g_pipSizeInPrice, Digits),
         ", points per pip=", g_pointsPerPip,
         ", lot step=", DoubleToString(lotStep, g_lotDigits));

   Print("Broker server clock is GMT", (g_brokerGmtOffset >= 0 ? "+" : ""),
         g_brokerGmtOffset, ". Server time now ", TimeToString(TimeCurrent()),
         ", so GMT is ", TimeToString(CurrentGmtTime()), ".");

   if(InpUseSessionFilter)
      Print("Session filter active: entries allowed ", InpSessionStartHourGmt,
            ":00 to ", InpSessionEndHourGmt, ":00 GMT, weekdays only.",
            " Currently ", (IsWithinTradingSession() ? "INSIDE" : "outside"),
            " the window.");

   if(InpUseAtrStops)
   {
      string atrNote = "ATR stops active: stop = ATR(" + IntegerToString(InpAtrPeriod)
                     + ") x " + DoubleToString(InpAtrStopMultiplier, 2)
                     + ", clamped to " + DoubleToString(InpMinStopPips, 1)
                     + "-" + DoubleToString(InpMaxStopPips, 1) + " pips.";

      // The ATR needs history. Right after attaching it may not be
      // readable yet, which is normal and not worth a warning.
      double atrNow = GetAtrInPips();
      if(atrNow > 0.0)
         atrNote = atrNote + " ATR is currently " + DoubleToString(atrNow, 1)
                 + " pips, giving a " + DoubleToString(CurrentStopLossPips(), 1)
                 + " pip stop.";
      else
         atrNote = atrNote + " ATR not yet readable - waiting for history.";

      Print(atrNote);
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Called when the EA is removed. Nothing to clean up here, but the  |
//| reason code is useful in the log when you are debugging reloads.  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print(InpTradeComment, " stopped. Reason code: ", reason);
}

//+------------------------------------------------------------------+
//| Called on every tick. Keep this function as a thin router: check  |
//| the preconditions, then delegate to named helpers.                |
//+------------------------------------------------------------------+
void OnTick()
{
   // Trailing stops need to react between bars, so manage the open
   // position on every tick - before the once-per-bar gate below.
   if(InpUseTrailingStop)
      ApplyTrailingStop();

   // Time-based exits also have to be honoured mid-bar. Waiting for
   // the next bar close to flatten before the weekend would mean
   // sitting through the gap, which is the thing we are avoiding.
   if(HasOpenPosition())
   {
      if(ShouldFlattenForWeekend())
      {
         ClosePosition("Friday close - not carrying over the weekend");
         return;
      }
      if(InpCloseAtSessionEnd && InpUseSessionFilter && !IsWithinTradingSession())
      {
         ClosePosition("trading session has ended");
         return;
      }
   }

   // Everything else only runs once per completed bar. Running entry
   // logic on every tick would fire the same signal hundreds of times
   // and would let a signal appear and disappear as the bar forms.
   if(!IsNewBar())
      return;

   // Is the terminal actually allowed to trade right now? This covers
   // the AutoTrading button, the "Allow live trading" checkbox, an
   // expired EA, and the broker disabling trading on the symbol.
   if(!IsTradeAllowed())
   {
      Print("Trading is not currently allowed by the terminal or broker.");
      return;
   }

   // The MAs and the ATR need enough history to be meaningful.
   if(Bars < MathMax(InpSlowMaPeriod, InpAtrPeriod) + 3)
      return;

   int signal = GetCrossoverSignal();   // +1 = long, -1 = short, 0 = nothing

   // --- Manage any position we already have -----------------------
   if(HasOpenPosition())
   {
      if(InpCloseOnOppositeSignal && signal != 0 && signal != GetOpenPositionDirection())
         ClosePosition("opposite crossover signal");

      return;   // Never stack positions in this EA.
   }

   // --- Consider a new entry --------------------------------------
   if(signal == 0)
      return;

   if(!IsWithinTradingSession())
      return;   // Silent: this fires on most bars of the day and would flood the log.

   if(ShouldFlattenForWeekend())
      return;   // No new positions into the Friday close either.

   if(!IsSpreadAcceptable())
      return;

   OpenPosition(signal);
}

//====================================================================
// SECTION 4 - MARKET GEOMETRY HELPERS
//====================================================================

//+------------------------------------------------------------------+
//| Determine what a "pip" means for the current symbol.              |
//|                                                                   |
//| Brokers quote FX with either 4 or 5 decimal places (2 or 3 for    |
//| JPY pairs). A 5-digit broker quotes EURUSD as 1.09876, so the     |
//| smallest price increment (a Point) is 0.00001, while a pip - the  |
//| unit traders actually talk in - is 0.0001, i.e. ten Points.       |
//+------------------------------------------------------------------+
void CalculatePipGeometry()
{
   if(Digits == 3 || Digits == 5)
   {
      g_pipSizeInPrice = Point * 10.0;
      g_pointsPerPip   = 10;
   }
   else
   {
      g_pipSizeInPrice = Point;
      g_pointsPerPip   = 1;
   }
}

//+------------------------------------------------------------------+
//| Returns true exactly once per newly opened bar.                   |
//|                                                                   |
//| Time[0] is the opening time of the bar currently forming. When    |
//| that value changes, a new bar has started, which means the        |
//| previous bar (index 1) has just closed and its values are final.  |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarOpenTime = Time[0];
   if(currentBarOpenTime == g_lastProcessedBar)
      return(false);

   g_lastProcessedBar = currentBarOpenTime;
   return(true);
}

//+------------------------------------------------------------------+
//| Reject entries when the spread is unusually wide - typically at   |
//| the daily rollover or around news. MODE_SPREAD is in Points.      |
//|                                                                   |
//| This matters far more on M5 than on H1. A 1.5 pip spread against  |
//| a 20 pip target is 7.5% of the trade given away at entry; the     |
//| same spread against an H1 60 pip target is 2.5%.                  |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
{
   double currentSpreadPips = MarketInfo(Symbol(), MODE_SPREAD) / (double)g_pointsPerPip;

   if(currentSpreadPips > InpMaxSpreadPips)
   {
      Print("Skipping entry: spread ", DoubleToString(currentSpreadPips, 1),
            " pips exceeds the ", DoubleToString(InpMaxSpreadPips, 1), " pip limit.");
      return(false);
   }
   return(true);
}

//+------------------------------------------------------------------+
//| Readable timeframe name, for the startup log line only.           |
//+------------------------------------------------------------------+
string TimeframeToText(int timeframeMinutes)
{
   switch(timeframeMinutes)
   {
      case PERIOD_M1:  return("M1");
      case PERIOD_M5:  return("M5");
      case PERIOD_M15: return("M15");
      case PERIOD_M30: return("M30");
      case PERIOD_H1:  return("H1");
      case PERIOD_H4:  return("H4");
      case PERIOD_D1:  return("D1");
      case PERIOD_W1:  return("W1");
      case PERIOD_MN1: return("MN1");
      default:         return("M" + IntegerToString(timeframeMinutes));
   }
}

//====================================================================
// SECTION 5 - BROKER CLOCK AND TRADING HOURS
//--------------------------------------------------------------------
// Nothing about server time is safe to assume. Brokers pick their own
// timezone - GMT+2 and GMT+3 are the common ones - and many shift by
// an hour with US daylight saving, which is why the offset is
// re-derived on every EA load rather than hardcoded.
//====================================================================

//+------------------------------------------------------------------+
//| Hours to subtract from server time to get GMT.                    |
//|                                                                   |
//| TimeGMT() reads the PC's clock and timezone, so it is only        |
//| trustworthy live. In the Strategy Tester it is modelled and the   |
//| comparison is meaningless, so the manual input is used there.     |
//+------------------------------------------------------------------+
int DetermineBrokerGmtOffset()
{
   if(!InpAutoDetectGmtOffset || IsTesting() || IsOptimization())
      return(InpBrokerGmtOffsetHours);

   datetime serverTime = TimeCurrent();
   datetime gmtTime    = TimeGMT();

   if(serverTime <= 0 || gmtTime <= 0)
   {
      Print("WARNING: Could not read the clocks to detect the broker offset. ",
            "Falling back to the manual value of ", InpBrokerGmtOffsetHours, ".");
      return(InpBrokerGmtOffsetHours);
   }

   int detectedOffset = (int)MathRound((double)(serverTime - gmtTime) / 3600.0);

   // Sanity-check: no real broker sits outside GMT-12..GMT+14.
   if(detectedOffset < -12 || detectedOffset > 14)
   {
      Print("WARNING: Detected an implausible broker offset of ", detectedOffset,
            " hours. Falling back to the manual value of ", InpBrokerGmtOffsetHours, ".");
      return(InpBrokerGmtOffsetHours);
   }

   return(detectedOffset);
}

//+------------------------------------------------------------------+
//| Current time expressed in GMT, derived from the server clock.     |
//+------------------------------------------------------------------+
datetime CurrentGmtTime()
{
   return((datetime)(TimeCurrent() - g_brokerGmtOffset * 3600));
}

//+------------------------------------------------------------------+
//| Is the market inside the configured trading window?               |
//|                                                                   |
//| Handles a window that wraps past midnight (start 22, end 4), and  |
//| refuses weekends outright. Returns true when the filter is off.   |
//+------------------------------------------------------------------+
bool IsWithinTradingSession()
{
   if(!InpUseSessionFilter)
      return(true);

   MqlDateTime gmtNow;
   TimeToStruct(CurrentGmtTime(), gmtNow);

   // day_of_week: 0 = Sunday, 6 = Saturday.
   if(gmtNow.day_of_week == 0 || gmtNow.day_of_week == 6)
      return(false);

   int hourNow = gmtNow.hour;

   if(InpSessionStartHourGmt < InpSessionEndHourGmt)
   {
      // Normal window, e.g. 07:00 -> 20:00.
      return(hourNow >= InpSessionStartHourGmt && hourNow < InpSessionEndHourGmt);
   }

   // Window wraps past midnight, e.g. 22:00 -> 04:00.
   return(hourNow >= InpSessionStartHourGmt || hourNow < InpSessionEndHourGmt);
}

//+------------------------------------------------------------------+
//| Should we be flat because the weekend is approaching?             |
//|                                                                   |
//| A 10-pip stop cannot survive a Sunday-open gap, which routinely   |
//| exceeds it. Holding an M5 position over a weekend converts a      |
//| controlled risk into an uncontrolled one.                         |
//+------------------------------------------------------------------+
bool ShouldFlattenForWeekend()
{
   if(!InpCloseBeforeWeekend)
      return(false);

   MqlDateTime gmtNow;
   TimeToStruct(CurrentGmtTime(), gmtNow);

   if(gmtNow.day_of_week == 5 && gmtNow.hour >= InpFridayCloseHourGmt)  // Friday
      return(true);

   if(gmtNow.day_of_week == 6)   // Saturday, if the broker is somehow still quoting
      return(true);

   return(false);
}

//====================================================================
// SECTION 6 - THE SIGNAL
//====================================================================

//+------------------------------------------------------------------+
//| Look for a moving-average crossover on the two most recently      |
//| CLOSED bars.                                                      |
//|                                                                   |
//|   shift 0 = the bar currently forming  (values still changing)    |
//|   shift 1 = the bar that just closed   (final)                    |
//|   shift 2 = the bar before that        (final)                    |
//|                                                                   |
//| Comparing shifts 1 and 2 gives a signal that can never repaint.   |
//| Comparing shift 0 to shift 1 would let a "signal" appear and then |
//| vanish before the bar closes - a classic backtest-vs-live gap.    |
//|                                                                   |
//| Returns +1 for a bullish cross, -1 for a bearish cross, 0 for no  |
//| cross.                                                            |
//+------------------------------------------------------------------+
int GetCrossoverSignal()
{
   double fastPrevious = iMA(Symbol(), Period(), InpFastMaPeriod, 0,
                             InpMaMethod, InpMaPrice, 2);
   double slowPrevious = iMA(Symbol(), Period(), InpSlowMaPeriod, 0,
                             InpMaMethod, InpMaPrice, 2);
   double fastCurrent  = iMA(Symbol(), Period(), InpFastMaPeriod, 0,
                             InpMaMethod, InpMaPrice, 1);
   double slowCurrent  = iMA(Symbol(), Period(), InpSlowMaPeriod, 0,
                             InpMaMethod, InpMaPrice, 1);

   // Bullish: fast was at or below slow, and is now clearly above.
   if(fastPrevious <= slowPrevious && fastCurrent > slowCurrent)
      return(1);

   // Bearish: fast was at or above slow, and is now clearly below.
   if(fastPrevious >= slowPrevious && fastCurrent < slowCurrent)
      return(-1);

   return(0);
}

//====================================================================
// SECTION 7 - STOP AND TARGET DISTANCES
//--------------------------------------------------------------------
// All three distances are expressed in PIPS and converted to price
// only at the point of use, so there is exactly one place where the
// pip-to-price conversion can go wrong.
//====================================================================

//+------------------------------------------------------------------+
//| Average True Range of the last closed bar, in pips.               |
//|                                                                   |
//| ATR measures how far price actually travels per bar, including    |
//| gaps. On EURUSD M5 it typically runs around 3-5 pips through      |
//| London and New York and under 2 pips overnight, which is exactly  |
//| the variation a fixed stop cannot cope with.                      |
//|                                                                   |
//| Read at shift 1 - the last CLOSED bar - for the same              |
//| no-repainting reason as the MA signal.                            |
//+------------------------------------------------------------------+
double GetAtrInPips()
{
   double atrInPrice = iATR(Symbol(), Period(), InpAtrPeriod, 1);

   if(atrInPrice <= 0.0 || g_pipSizeInPrice <= 0.0)
      return(0.0);

   return(atrInPrice / g_pipSizeInPrice);
}

//+------------------------------------------------------------------+
//| The stop distance to use for a trade opened right now, in pips.   |
//|                                                                   |
//| In ATR mode the raw figure is clamped between InpMinStopPips and  |
//| InpMaxStopPips. The floor stops a dead-quiet market producing a   |
//| stop so tight that spread alone closes the trade; the ceiling     |
//| stops a news spike producing a stop so wide that risk-based       |
//| sizing returns a position too small for the broker to accept.     |
//+------------------------------------------------------------------+
double CurrentStopLossPips()
{
   double stopPips;

   if(!InpUseAtrStops)
   {
      stopPips = InpStopLossPips;
   }
   else
   {
      double atrPips = GetAtrInPips();

      if(atrPips <= 0.0)
      {
         Print("WARNING: ATR unavailable. Falling back to the fixed stop of ",
               DoubleToString(InpStopLossPips, 1), " pips.");
         stopPips = InpStopLossPips;
      }
      else
      {
         stopPips = atrPips * InpAtrStopMultiplier;

         if(stopPips < InpMinStopPips) stopPips = InpMinStopPips;
         if(stopPips > InpMaxStopPips) stopPips = InpMaxStopPips;
      }
   }

   // Apply the broker's minimum stop distance HERE, before the figure
   // is used for sizing - not later when the stop is placed.
   //
   // AttachStopsToOrder() has to widen any stop that sits inside
   // MODE_STOPLEVEL, because the broker would reject it otherwise. If
   // sizing used the narrower pre-clamp figure, the position would be
   // built for a 5 pip stop and then given a 7 pip one, and the real
   // money at risk would quietly exceed InpRiskPercentPerTrade by 40%.
   // Clamping once, up front, keeps sizing and placement agreed on the
   // same number. This bites on M5 far more than on H1, because ATR
   // stops there are often close to the broker's floor.
   double brokerMinimumPips = GetBrokerMinimumStopPips();
   if(stopPips < brokerMinimumPips)
      stopPips = brokerMinimumPips;

   return(stopPips);
}

//+------------------------------------------------------------------+
//| The broker's minimum permitted stop distance, expressed in pips.  |
//|                                                                   |
//| MODE_STOPLEVEL is quoted in Points. It is commonly 0 on retail    |
//| EURUSD accounts, in which case this returns 0 and changes         |
//| nothing - but it can be 3-5 pips, which on M5 is larger than the  |
//| stop an ATR calculation would otherwise ask for.                  |
//+------------------------------------------------------------------+
double GetBrokerMinimumStopPips()
{
   if(g_pipSizeInPrice <= 0.0)
      return(0.0);

   return((MarketInfo(Symbol(), MODE_STOPLEVEL) * Point) / g_pipSizeInPrice);
}

//+------------------------------------------------------------------+
//| The take-profit distance for a trade opened right now, in pips.   |
//+------------------------------------------------------------------+
double CurrentTakeProfitPips()
{
   if(!InpUseAtrStops)
      return(InpTakeProfitPips);

   double atrPips = GetAtrInPips();

   if(atrPips <= 0.0)
      return(MathMax(InpTakeProfitPips, GetBrokerMinimumStopPips()));

   return(MathMax(atrPips * InpAtrTargetMultiplier, GetBrokerMinimumStopPips()));
}

//+------------------------------------------------------------------+
//| The trailing-stop distance to use right now, in pips.             |
//+------------------------------------------------------------------+
double CurrentTrailingPips()
{
   if(!InpUseAtrStops)
      return(InpTrailingStopPips);

   double atrPips = GetAtrInPips();

   if(atrPips <= 0.0)
      return(InpTrailingStopPips);

   return(atrPips * InpAtrTrailingMultiplier);
}

//====================================================================
// SECTION 8 - POSITION INSPECTION
//--------------------------------------------------------------------
// MT4 has no "current position" object. You loop over the terminal's
// order pool and filter by symbol and magic number yourself. The
// magic number is what stops this EA from touching trades opened by
// you manually or by another EA on the same chart.
//====================================================================

//+------------------------------------------------------------------+
//| Is there already a live market order belonging to this EA?        |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol())            continue;
      if(OrderMagicNumber() != InpMagicNumber) continue;
      if(OrderType() > OP_SELL)                continue;  // Ignore pending orders.
      return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Direction of this EA's open position: +1 long, -1 short, 0 none.  |
//+------------------------------------------------------------------+
int GetOpenPositionDirection()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol())            continue;
      if(OrderMagicNumber() != InpMagicNumber) continue;

      if(OrderType() == OP_BUY)  return(1);
      if(OrderType() == OP_SELL) return(-1);
   }
   return(0);
}

//====================================================================
// SECTION 9 - POSITION SIZING
//====================================================================

//+------------------------------------------------------------------+
//| Convert a risk percentage and a stop distance into a lot size.    |
//|                                                                   |
//| The chain of reasoning:                                           |
//|   1. How much money am I willing to lose?                         |
//|        riskAmount = balance * riskPercent / 100                   |
//|   2. What does one pip cost me, per lot, in account currency?     |
//|        MODE_TICKVALUE is the value of one TICK for one lot, so    |
//|        scale it from tick size up to pip size.                    |
//|   3. Divide.                                                      |
//|        lots = riskAmount / (stopPips * pipValuePerLot)            |
//|   4. Round DOWN to the broker's lot step and clamp to min/max.    |
//|      Always round down: rounding up silently increases your risk. |
//|                                                                   |
//| Worked example - EURUSD, 10,000 GBP balance, 0.5% risk:           |
//|   riskAmount = 50 GBP                                             |
//|   quiet hour, ATR 2.0 pips -> stop clamps to the 5.0 pip floor    |
//|     pip value ~7.90/lot, so 5 x 7.90 = 39.50 per lot              |
//|     50 / 39.50 = 1.26 lots                                        |
//|   London, ATR 5.0 pips -> stop = 5.0 x 1.5 = 7.5 pips             |
//|     7.5 x 7.90 = 59.25 per lot                                    |
//|     50 / 59.25 = 0.84 lots                                        |
//|                                                                   |
//| Note what happened: the position got SMALLER as the stop got      |
//| wider, so the money at risk stayed at 50 GBP in both cases. That  |
//| is the entire point of pairing ATR stops with risk-based sizing.  |
//+------------------------------------------------------------------+
double CalculateLotSize(double stopLossInPips)
{
   if(!InpUseRiskBasedSizing)
      return(NormaliseLotSize(InpFixedLotSize));

   double accountBalance = AccountBalance();
   double riskAmount     = accountBalance * InpRiskPercentPerTrade / 100.0;

   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE); // Account currency per tick, per lot
   double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);  // Price movement of one tick

   if(tickValue <= 0.0 || tickSize <= 0.0 || stopLossInPips <= 0.0)
   {
      Print("WARNING: Cannot compute risk-based size. Falling back to the fixed lot size.");
      return(NormaliseLotSize(InpFixedLotSize));
   }

   // Value of a one-pip move, for one lot, in the account currency.
   double pipValuePerLot = (tickValue / tickSize) * g_pipSizeInPrice;

   double rawLotSize = riskAmount / (stopLossInPips * pipValuePerLot);

   return(NormaliseLotSize(rawLotSize));
}

//+------------------------------------------------------------------+
//| Round a lot size down to the broker's step and clamp it to the    |
//| allowed min/max. Returns 0.0 if the broker's minimum is more than |
//| our risk budget allows - the caller must treat 0.0 as "skip".     |
//+------------------------------------------------------------------+
double NormaliseLotSize(double requestedLots)
{
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

   if(lotStep <= 0.0) lotStep = 0.01;

   // Round DOWN to the nearest valid step.
   double steppedLots = MathFloor(requestedLots / lotStep) * lotStep;
   steppedLots = NormalizeDouble(steppedLots, g_lotDigits);

   if(steppedLots > maxLot)
      steppedLots = maxLot;

   if(steppedLots < minLot)
   {
      Print("Requested size ", DoubleToString(requestedLots, 4),
            " is below the broker minimum of ", DoubleToString(minLot, g_lotDigits),
            ". Skipping trade.");
      return(0.0);
   }
   return(steppedLots);
}

//====================================================================
// SECTION 10 - ORDER PLACEMENT
//====================================================================

//+------------------------------------------------------------------+
//| Open a market position in the given direction (+1 long, -1 short).|
//|                                                                   |
//| Note the two-step approach: the order is sent WITHOUT a stop loss |
//| or take profit, and the levels are attached afterwards with       |
//| OrderModify. Many ECN/STP brokers reject an OrderSend that        |
//| carries SL/TP with error 130 (invalid stops). Sending bare and    |
//| then modifying works on every broker type, at the cost of a       |
//| brief window where the position is unprotected.                   |
//+------------------------------------------------------------------+
void OpenPosition(int direction)
{
   // Resolve the distances ONCE, here, and pass them down. If we read
   // the ATR again inside AttachStopsToOrder it could have moved, and
   // the position would be sized against a different stop than the
   // one actually placed - a silent risk-management bug.
   double stopLossPips   = CurrentStopLossPips();
   double takeProfitPips = CurrentTakeProfitPips();

   double lotSize = CalculateLotSize(stopLossPips);
   if(lotSize <= 0.0)
      return;

   int    orderType  = (direction > 0) ? OP_BUY : OP_SELL;
   int    slippage   = (int)MathRound(InpMaxSlippagePips * g_pointsPerPip);
   color  arrowColor = (direction > 0) ? clrDodgerBlue : clrOrangeRed;

   // Check we can actually afford the position before trying.
   // ResetLastError() first, so GetLastError() below reflects this call
   // and not some stale error left over from an earlier operation.
   ResetLastError();
   double freeMarginAfterTrade = AccountFreeMarginCheck(Symbol(), orderType, lotSize);
   if(freeMarginAfterTrade <= 0.0 || GetLastError() == ERR_NOT_ENOUGH_MONEY)
   {
      Print("Not enough free margin for a ", DoubleToString(lotSize, g_lotDigits),
            " lot position.");
      return;
   }

   int ticket = -1;
   for(int attempt = 1; attempt <= InpOrderRetryAttempts; attempt++)
   {
      // Refresh the cached Bid/Ask before every attempt - a stale price
      // is the usual cause of error 129 (invalid price).
      RefreshRates();
      double entryPrice = (direction > 0) ? Ask : Bid;

      ticket = OrderSend(Symbol(), orderType, lotSize,
                         NormalizeDouble(entryPrice, Digits),
                         slippage,
                         0.0, 0.0,                 // SL/TP attached separately, see above
                         InpTradeComment, InpMagicNumber, 0, arrowColor);

      if(ticket >= 0)
         break;

      int errorCode = GetLastError();
      Print("OrderSend attempt ", attempt, "/", InpOrderRetryAttempts,
            " failed with error ", errorCode, " (", ErrorDescription(errorCode), ").");

      if(!IsRetryableError(errorCode))
         return;                     // A permanent error - retrying will not help.

      Sleep(InpOrderRetryDelayMs);
   }

   if(ticket < 0)
   {
      Print("Giving up on this entry after ", InpOrderRetryAttempts, " attempts.");
      return;
   }

   Print("Opened ", (direction > 0 ? "LONG " : "SHORT "),
         DoubleToString(lotSize, g_lotDigits), " lots, ticket ", ticket,
         ". Stop ", DoubleToString(stopLossPips, 1),
         " pips, target ", DoubleToString(takeProfitPips, 1), " pips",
         (InpUseAtrStops ? " (ATR " + DoubleToString(GetAtrInPips(), 1) + " pips)." : "."));

   AttachStopsToOrder(ticket, direction, stopLossPips, takeProfitPips);
}

//+------------------------------------------------------------------+
//| Attach a stop loss and take profit to an order that is already    |
//| open, respecting the broker's minimum stop distance.              |
//+------------------------------------------------------------------+
void AttachStopsToOrder(int ticket, int direction,
                        double stopLossPips, double takeProfitPips)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
   {
      Print("Could not select ticket ", ticket, " to attach stops.");
      return;
   }

   double openPrice = OrderOpenPrice();

   // The broker will not accept a stop closer to price than this.
   // MODE_STOPLEVEL is in Points; convert it to price units. On M5
   // with tight ATR stops this clamp fires far more often than it
   // does on H1, so watch the log for it.
   double minimumStopDistance = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;

   double stopLossPrice   = 0.0;
   double takeProfitPrice = 0.0;

   if(stopLossPips > 0.0)
   {
      double stopDistance = MathMax(stopLossPips * g_pipSizeInPrice, minimumStopDistance);
      stopLossPrice = (direction > 0) ? openPrice - stopDistance
                                      : openPrice + stopDistance;
      stopLossPrice = NormalizeDouble(stopLossPrice, Digits);
   }

   if(takeProfitPips > 0.0)
   {
      double profitDistance = MathMax(takeProfitPips * g_pipSizeInPrice, minimumStopDistance);
      takeProfitPrice = (direction > 0) ? openPrice + profitDistance
                                        : openPrice - profitDistance;
      takeProfitPrice = NormalizeDouble(takeProfitPrice, Digits);
   }

   if(stopLossPrice == 0.0 && takeProfitPrice == 0.0)
      return;

   for(int attempt = 1; attempt <= InpOrderRetryAttempts; attempt++)
   {
      if(OrderModify(ticket, openPrice, stopLossPrice, takeProfitPrice, 0, clrYellow))
      {
         Print("Ticket ", ticket, " protected. SL=", DoubleToString(stopLossPrice, Digits),
               " TP=", DoubleToString(takeProfitPrice, Digits));
         return;
      }

      int errorCode = GetLastError();
      Print("OrderModify attempt ", attempt, "/", InpOrderRetryAttempts,
            " on ticket ", ticket, " failed with error ", errorCode,
            " (", ErrorDescription(errorCode), ").");

      if(!IsRetryableError(errorCode))
         break;

      Sleep(InpOrderRetryDelayMs);
      RefreshRates();
   }

   Print("WARNING: Ticket ", ticket, " is OPEN WITHOUT A STOP LOSS. Intervene manually.");
}

//+------------------------------------------------------------------+
//| Close this EA's open position at market. The reason string goes   |
//| straight into the log, which makes the Experts tab readable when  |
//| you are working out why a trade ended.                            |
//+------------------------------------------------------------------+
void ClosePosition(string reason)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol())            continue;
      if(OrderMagicNumber() != InpMagicNumber) continue;
      if(OrderType() > OP_SELL)                continue;

      int    ticket   = OrderTicket();
      double lots     = OrderLots();
      int    slippage = (int)MathRound(InpMaxSlippagePips * g_pointsPerPip);

      for(int attempt = 1; attempt <= InpOrderRetryAttempts; attempt++)
      {
         RefreshRates();
         double closePrice = (OrderType() == OP_BUY) ? Bid : Ask;

         if(OrderClose(ticket, lots, NormalizeDouble(closePrice, Digits), slippage, clrGray))
         {
            Print("Closed ticket ", ticket, ": ", reason, ".");
            break;
         }

         int errorCode = GetLastError();
         Print("OrderClose attempt ", attempt, "/", InpOrderRetryAttempts,
               " on ticket ", ticket, " failed with error ", errorCode,
               " (", ErrorDescription(errorCode), ").");

         if(!IsRetryableError(errorCode))
            break;

         Sleep(InpOrderRetryDelayMs);

         // The order pool may have shifted; re-select before retrying.
         if(!OrderSelect(ticket, SELECT_BY_TICKET))
            break;
      }
   }
}

//====================================================================
// SECTION 11 - TRADE MANAGEMENT
//====================================================================

//+------------------------------------------------------------------+
//| A trailing stop.                                                  |
//|                                                                   |
//| Once price has moved in our favour by more than the trailing      |
//| distance, keep the stop that far behind the current price. The    |
//| "step" input stops us from spamming the server with a modify      |
//| request on every single tick.                                     |
//|                                                                   |
//| In ATR mode the distance breathes with volatility, exactly like   |
//| the initial stop does.                                            |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
   double trailDistance = CurrentTrailingPips() * g_pipSizeInPrice;
   double trailStep     = InpTrailingStepPips  * g_pipSizeInPrice;
   double minimumStop   = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;

   if(trailDistance < minimumStop)
      trailDistance = minimumStop;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol())            continue;
      if(OrderMagicNumber() != InpMagicNumber) continue;
      if(OrderType() > OP_SELL)                continue;

      RefreshRates();

      double currentStop = OrderStopLoss();
      double proposedStop;

      if(OrderType() == OP_BUY)
      {
         proposedStop = NormalizeDouble(Bid - trailDistance, Digits);

         // Only ever move the stop UP, and only by a meaningful amount.
         if(proposedStop <= OrderOpenPrice())                            continue;
         if(currentStop > 0.0 && proposedStop < currentStop + trailStep) continue;
      }
      else // OP_SELL
      {
         proposedStop = NormalizeDouble(Ask + trailDistance, Digits);

         // Only ever move the stop DOWN.
         if(proposedStop >= OrderOpenPrice())                            continue;
         if(currentStop > 0.0 && proposedStop > currentStop - trailStep) continue;
      }

      if(!OrderModify(OrderTicket(), OrderOpenPrice(), proposedStop,
                      OrderTakeProfit(), 0, clrAqua))
      {
         int errorCode = GetLastError();
         Print("Trailing stop update failed on ticket ", OrderTicket(),
               ": error ", errorCode, " (", ErrorDescription(errorCode), ").");
      }
   }
}

//====================================================================
// SECTION 12 - ERROR HANDLING UTILITIES
//====================================================================

//+------------------------------------------------------------------+
//| Decide whether a failed trade operation is worth retrying.        |
//|                                                                   |
//| Transient errors are things like requotes and busy trade threads: |
//| the same request may well succeed a moment later. Permanent       |
//| errors (bad volume, invalid stops, trading disabled) will fail    |
//| identically every time, so retrying just wastes time and fills    |
//| the log.                                                          |
//+------------------------------------------------------------------+
bool IsRetryableError(int errorCode)
{
   switch(errorCode)
   {
      case ERR_SERVER_BUSY:              // 4    server is busy
      case ERR_NO_CONNECTION:            // 6    no connection to the trade server
      case ERR_TRADE_TIMEOUT:            // 128  trade timed out
      case ERR_INVALID_PRICE:            // 129  price is stale - RefreshRates and retry
      case ERR_PRICE_CHANGED:            // 135  price changed
      case ERR_OFF_QUOTES:               // 136  no quotes available
      case ERR_BROKER_BUSY:              // 137  broker is busy
      case ERR_REQUOTE:                  // 138  requote
      case ERR_TRADE_CONTEXT_BUSY:       // 146  another EA is using the trade thread
         return(true);
      default:
         return(false);
   }
}

//+------------------------------------------------------------------+
//| Human-readable text for the error codes this EA actually meets.   |
//| MT4 also ships stdlib.mqh with a full ErrorDescription(), but     |
//| keeping a short local version avoids the dependency and keeps     |
//| the log messages relevant to this EA.                             |
//+------------------------------------------------------------------+
string ErrorDescription(int errorCode)
{
   switch(errorCode)
   {
      case 0:   return("no error");
      case 4:   return("trade server is busy");
      case 6:   return("no connection to trade server");
      case 128: return("trade timeout");
      case 129: return("invalid price");
      case 130: return("invalid stops - too close to price, or ECN rejection");
      case 131: return("invalid trade volume");
      case 132: return("market is closed");
      case 133: return("trading is disabled");
      case 134: return("not enough money");
      case 135: return("price changed");
      case 136: return("off quotes");
      case 137: return("broker is busy");
      case 138: return("requote");
      case 145: return("modification denied - order too close to market");
      case 146: return("trade context is busy");
      case 147: return("expiration date denied by broker");
      case 148: return("too many open orders");
      default:  return("unmapped error " + IntegerToString(errorCode));
   }
}
//+------------------------------------------------------------------+
