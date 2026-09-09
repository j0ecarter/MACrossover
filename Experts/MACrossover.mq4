//+------------------------------------------------------------------+
//|                                                MACrossover.mq4    |
//|                                                      version 2.00 |
//|                                                                   |
//|  An MT4 Expert Advisor built as a learning project. The entry     |
//|  signal is a 20/50 moving-average crossover. That signal has no   |
//|  edge and is not expected to make money - it is a placeholder,    |
//|  and everything of value here is the machinery around it:         |
//|                                                                   |
//|    - risk-based position sizing that holds money-at-risk constant |
//|    - ATR-scaled stops that breathe with volatility                |
//|    - parameters that adapt to the symbol rather than being tuned  |
//|      to one pair                                                  |
//|    - a session filter working in GMT off a detected broker offset |
//|    - hard safety limits: demo guard, daily loss cap, trade cap,   |
//|      consecutive-loss cooldown                                    |
//|    - a CSV trade journal, so running it produces data you can     |
//|      actually learn from                                          |
//|    - ECN-safe order placement with errors split by whether a      |
//|      retry could possibly help                                    |
//|                                                                   |
//|  WHAT CHANGED IN 2.00                                             |
//|    1. FIXED a real defect: on an opposite crossover the EA closed |
//|       its position and returned without opening the new one.      |
//|       Because crossovers strictly alternate, that meant it only   |
//|       ever traded in one direction. It now reverses properly.     |
//|    2. Refuses to start on a live account unless explicitly told.  |
//|    3. Daily loss cap, daily trade cap, consecutive-loss cooldown. |
//|    4. Every entry and exit is written to a CSV journal.           |
//|    5. Stop clamps and the spread cap now scale off a long-period  |
//|       ATR baseline, so EURUSD and GBPUSD both behave sensibly     |
//|       without per-symbol tuning.                                  |
//+------------------------------------------------------------------+
#property copyright "Joe"
#property version   "2.00"
#property strict

//====================================================================
// SECTION 1 - USER INPUTS
//====================================================================

input string  InpSectionStrategy        = "--- Strategy ---";
input int     InpFastMaPeriod           = 20;    // Fast MA period (bars)
input int     InpSlowMaPeriod           = 50;    // Slow MA period (bars)
input ENUM_MA_METHOD     InpMaMethod    = MODE_SMA;     // MA calculation method
input ENUM_APPLIED_PRICE InpMaPrice     = PRICE_CLOSE;  // Price the MA is built from

input string  InpSectionRisk            = "--- Risk & sizing ---";
input bool    InpUseRiskBasedSizing     = true;  // Size from % risk rather than fixed lots
input double  InpRiskPercentPerTrade    = 0.5;   // % of balance risked per trade
input double  InpFixedLotSize           = 0.01;  // Lots used when risk-based sizing is off

input string  InpSectionStops           = "--- Stop sizing ---";
input bool    InpUseAtrStops            = true;  // Size stops from ATR rather than fixed pips
input int     InpAtrPeriod              = 14;    // ATR lookback for the live stop
input double  InpAtrStopMultiplier      = 1.5;   // Stop distance   = ATR x this
input double  InpAtrTargetMultiplier    = 3.0;   // Target distance = ATR x this
input double  InpAtrTrailingMultiplier  = 1.0;   // Trailing distance = ATR x this
input double  InpStopLossPips           = 10.0;  // Fixed stop, used when ATR stops are off
input double  InpTakeProfitPips         = 20.0;  // Fixed target, used when ATR stops are off

input string  InpSectionScaling         = "--- Symbol auto-scaling ---";
input bool    InpAutoScaleToSymbol      = true;  // Derive clamps from the symbol's own volatility
input int     InpBaselineAtrPeriod      = 100;   // Long ATR used as the symbol's volatility yardstick
input double  InpMinStopAsBaselineRatio = 0.5;   // Stop floor   = baseline ATR x this
input double  InpMaxStopAsBaselineRatio = 3.0;   // Stop ceiling = baseline ATR x this
input double  InpMaxSpreadAsAtrRatio    = 0.35;  // Reject entry if spread > live ATR x this
input double  InpMinStopPips            = 5.0;   // Absolute floor,   used when auto-scaling is off
input double  InpMaxStopPips            = 25.0;  // Absolute ceiling, used when auto-scaling is off
input double  InpMaxSpreadPips          = 2.5;   // Absolute spread cap, always applied as a backstop

input string  InpSectionSession         = "--- Trading hours (GMT) ---";
input bool    InpUseSessionFilter       = true;  // Only take entries inside the window below
input int     InpSessionStartHourGmt    = 7;     // 07:00 GMT - around the London open
input int     InpSessionEndHourGmt      = 20;    // 20:00 GMT - mid NY afternoon
input bool    InpCloseAtSessionEnd      = true;  // Flatten when the window closes
input bool    InpCloseBeforeWeekend     = true;  // Do not carry a position over the weekend
input int     InpFridayCloseHourGmt     = 19;    // Friday flatten time
input bool    InpAutoDetectGmtOffset    = true;  // Work out the broker's server offset itself
input int     InpBrokerGmtOffsetHours   = 2;     // Manual offset, for the tester or as fallback

input string  InpSectionManagement      = "--- Trade management ---";
input bool    InpReverseOnOppositeSignal= true;  // Close AND open the other way on a reverse cross
input bool    InpCloseOnOppositeSignal  = true;  // Close on a reverse cross (without reversing)
input bool    InpUseTrailingStop        = true;  // Enable the trailing stop
input double  InpTrailingStopPips       = 8.0;   // Trailing distance, when ATR stops are off
input double  InpTrailingStepPips       = 2.0;   // Minimum improvement before moving the stop

input string  InpSectionSafety          = "--- Safety limits ---";
input bool    InpAllowLiveAccount       = false; // MUST be set true to run on a live account
input double  InpMaxDailyLossPercent    = 3.0;   // Stop trading for the day past this loss (0 = off)
input int     InpMaxTradesPerDay        = 10;    // Cap on entries per GMT day (0 = off)
input int     InpMaxConsecutiveLosses   = 3;     // Losses in a row before a cooldown (0 = off)
input int     InpCooldownMinutes        = 60;    // Length of that cooldown
input bool    InpFlattenOnDailyLoss     = true;  // Also close any open position when the cap trips

input string  InpSectionJournal         = "--- Journalling ---";
input bool    InpWriteJournal           = true;  // Write every entry and exit to a CSV
input string  InpJournalFileName        = "";    // Blank = <symbol>_MACrossover_journal.csv

input string  InpSectionExecution       = "--- Execution ---";
input int     InpMagicNumber            = 20260909;// Unique ID so this EA only touches its own trades
input double  InpMaxSlippagePips        = 1.0;   // Maximum accepted price deviation
input int     InpOrderRetryAttempts     = 3;     // How many times to retry a rejected order
input int     InpOrderRetryDelayMs      = 500;   // Pause between retries, in milliseconds
input string  InpTradeComment           = "MACrossover";

//====================================================================
// SECTION 2 - GLOBAL STATE
//====================================================================

// Price value of one pip, and how many Points make a pip. On a
// 5-digit EURUSD quote a pip is 0.0001 = ten Points. Slippage and
// MODE_STOPLEVEL are quoted in Points; humans talk in pips.
double   g_pipSizeInPrice        = 0.0;
int      g_pointsPerPip          = 1;

// Decimal places allowed on a lot size, from the broker's lot step.
int      g_lotDigits             = 2;

// Open time of the last bar we have already acted on.
datetime g_lastProcessedBar      = 0;

// Hours to subtract from server time to reach GMT.
int      g_brokerGmtOffset       = 0;

// Ticket of the position this EA currently believes is open, or -1.
// Used to notice when a position disappears - closed by its stop or
// target rather than by us - so the exit can still be journalled.
int      g_openTicket            = -1;

// Cached details of that open position, captured at entry. Once the
// order leaves the live pool these are the only record we have until
// history is queried.
double   g_openStopPips          = 0.0;
double   g_openAtrPips           = 0.0;
double   g_openSpreadPips        = 0.0;

// Trading is suspended until this server time (consecutive-loss
// cooldown). Zero means no cooldown active.
datetime g_cooldownUntil         = 0;

// Close time of the trade that triggered the current cooldown.
// Without this the cooldown re-arms forever: closed-trade history
// does not change while we wait, so the same losing streak would
// trip the limit again the instant the pause expired. A new cooldown
// therefore requires a loss NEWER than the one that caused the last.
datetime g_cooldownTriggerClose  = 0;

// Resolved journal filename, worked out once in OnInit.
string   g_journalFileName       = "";

// Set once the daily loss cap has tripped, so the log line is
// printed once rather than on every bar for the rest of the day.
datetime g_dailyLossReportedDay  = 0;

//====================================================================
// SECTION 3 - LIFECYCLE
//====================================================================

//+------------------------------------------------------------------+
//| Validate everything, work out the broker's quirks, and refuse to  |
//| start if anything is wrong. A bad configuration caught here costs |
//| nothing; the same one caught at OrderSend costs money.            |
//+------------------------------------------------------------------+
int OnInit()
{
   // --- The most important check in the file ----------------------
   // This EA has no proven edge and is not intended for real money.
   // Running on a live account has to be a deliberate act, not the
   // result of having the wrong terminal in front of you.
   if(!InpAllowLiveAccount && !IsDemo())
   {
      string refusal = InpTradeComment + " refuses to start: this is a LIVE account "
                     + "(#" + IntegerToString(AccountNumber()) + ", " + AccountServer() + "). "
                     + "Set InpAllowLiveAccount to true only if you genuinely mean it.";
      Print(refusal);
      Alert(refusal);
      return(INIT_FAILED);
   }

   // --- Strategy parameters ---------------------------------------
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

   // --- Risk parameters -------------------------------------------
   if(InpUseRiskBasedSizing &&
      (InpRiskPercentPerTrade <= 0.0 || InpRiskPercentPerTrade > 10.0))
   {
      Print("ERROR: Risk percent must be between 0 and 10. ",
            "Above ~2% per trade is reckless.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // --- Stop parameters -------------------------------------------
   if(InpUseAtrStops)
   {
      if(InpAtrPeriod < 1 || InpBaselineAtrPeriod < 1)
      {
         Print("ERROR: ATR periods must be at least 1.");
         return(INIT_PARAMETERS_INCORRECT);
      }
      if(InpAtrStopMultiplier <= 0.0 || InpAtrTargetMultiplier <= 0.0)
      {
         Print("ERROR: ATR multipliers must be greater than zero.");
         return(INIT_PARAMETERS_INCORRECT);
      }
   }
   else if(InpUseRiskBasedSizing && InpStopLossPips <= 0.0)
   {
      Print("ERROR: Risk-based sizing divides by the stop distance, ",
            "so it cannot work with a zero stop.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(InpAutoScaleToSymbol &&
      InpMaxStopAsBaselineRatio <= InpMinStopAsBaselineRatio)
   {
      Print("ERROR: InpMaxStopAsBaselineRatio must exceed InpMinStopAsBaselineRatio.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(!InpAutoScaleToSymbol && InpMaxStopPips <= InpMinStopPips)
   {
      Print("ERROR: InpMaxStopPips must exceed InpMinStopPips.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // --- Session window --------------------------------------------
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
         Print("ERROR: Session start equals end, leaving no window to trade in.");
         return(INIT_PARAMETERS_INCORRECT);
      }
   }

   // --- Broker geometry -------------------------------------------
   CalculatePipGeometry();

   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(lotStep <= 0.0) lotStep = 0.01;
   g_lotDigits = (int)MathRound(-MathLog10(lotStep));
   if(g_lotDigits < 0) g_lotDigits = 0;

   g_brokerGmtOffset = DetermineBrokerGmtOffset();

   // --- Journal ----------------------------------------------------
   g_journalFileName = (StringLen(InpJournalFileName) > 0)
                     ? InpJournalFileName
                     : Symbol() + "_MACrossover_journal.csv";

   // --- Adopt any position already open ----------------------------
   // Covers a terminal restart or a parameter change mid-trade: we
   // reattach to our own position rather than losing track of it.
   g_openTicket = FindOpenTicket();
   if(g_openTicket >= 0)
      Print("Adopted an existing position, ticket ", g_openTicket, ".");

   ReportStartupState();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Print everything a person needs to sanity-check the setup before  |
//| walking away from the terminal.                                   |
//+------------------------------------------------------------------+
void ReportStartupState()
{
   Print(InpTradeComment, " v2.00 on ", Symbol(), " ", TimeframeToText(Period()),
         " | account #", AccountNumber(), " ", (IsDemo() ? "DEMO" : "LIVE"),
         " | balance ", DoubleToString(AccountBalance(), 2), " ", AccountCurrency());

   Print("Pip geometry: Digits=", Digits,
         ", pip=", DoubleToString(g_pipSizeInPrice, Digits),
         ", points per pip=", g_pointsPerPip,
         ", broker min stop=", DoubleToString(GetBrokerMinimumStopPips(), 1), " pips");

   Print("Broker clock is GMT", (g_brokerGmtOffset >= 0 ? "+" : ""), g_brokerGmtOffset,
         ". Server ", TimeToString(TimeCurrent()),
         " = GMT ", TimeToString(CurrentGmtTime()));

   if(InpUseSessionFilter)
      Print("Session: ", InpSessionStartHourGmt, ":00-", InpSessionEndHourGmt,
            ":00 GMT weekdays. Currently ",
            (IsWithinTradingSession() ? "INSIDE" : "outside"), " the window.");

   double baselineAtr = GetBaselineAtrInPips();
   double liveAtr     = GetAtrInPips();

   if(InpAutoScaleToSymbol && baselineAtr > 0.0)
      Print("Auto-scaled to ", Symbol(), ": baseline ATR(", InpBaselineAtrPeriod, ") = ",
            DoubleToString(baselineAtr, 1), " pips, so stop clamps are ",
            DoubleToString(baselineAtr * InpMinStopAsBaselineRatio, 1), "-",
            DoubleToString(baselineAtr * InpMaxStopAsBaselineRatio, 1), " pips.");

   if(liveAtr > 0.0)
      Print("Live ATR(", InpAtrPeriod, ") = ", DoubleToString(liveAtr, 1),
            " pips, giving a ", DoubleToString(CurrentStopLossPips(), 1),
            " pip stop and a ", DoubleToString(CurrentTakeProfitPips(), 1), " pip target.",
            " Spread cap now ", DoubleToString(CurrentMaxSpreadPips(), 2), " pips.");
   else
      Print("ATR not yet readable - the chart needs more history. ",
            "Scroll back to load bars if this persists.");

   Print("Safety: ", (InpMaxDailyLossPercent > 0.0
            ? "daily loss cap " + DoubleToString(InpMaxDailyLossPercent, 1) + "%" : "no daily loss cap"),
         ", ", (InpMaxTradesPerDay > 0
            ? IntegerToString(InpMaxTradesPerDay) + " trades/day" : "no trade cap"),
         ", ", (InpMaxConsecutiveLosses > 0
            ? IntegerToString(InpMaxConsecutiveLosses) + " losses then "
              + IntegerToString(InpCooldownMinutes) + "min cooldown" : "no loss cooldown"),
         ". Journal: ", (InpWriteJournal ? g_journalFileName : "disabled"));
}

//+------------------------------------------------------------------+
//| Nothing to release, but the reason code helps when debugging      |
//| unexpected reloads.                                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print(InpTradeComment, " stopped. Reason code: ", reason);
}

//+------------------------------------------------------------------+
//| Thin router. Preconditions first, then delegate to named helpers. |
//+------------------------------------------------------------------+
void OnTick()
{
   // A position may have closed on its stop or target since the last
   // tick. Notice that first, so the journal and the loss counters
   // are up to date before anything else reads them.
   DetectAndJournalClosedPosition();

   if(InpUseTrailingStop)
      ApplyTrailingStop();

   // Time-based and risk-based exits must act mid-bar. Waiting for a
   // bar close to flatten before the weekend would mean sitting
   // through the gap, which is the thing being avoided.
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
      if(InpFlattenOnDailyLoss && HasBreachedDailyLossCap())
      {
         ClosePosition("daily loss cap reached");
         return;
      }
   }

   // Everything below runs once per completed bar. Running entry
   // logic every tick would fire the same signal hundreds of times.
   if(!IsNewBar())
      return;

   if(!IsTradeAllowed())
   {
      Print("Trading is not currently allowed by the terminal or broker.");
      return;
   }

   // The indicators need history before they mean anything.
   int barsNeeded = InpSlowMaPeriod + 3;
   if(InpUseAtrStops)
      barsNeeded = MathMax(barsNeeded, InpAtrPeriod + 3);
   if(InpAutoScaleToSymbol)
      barsNeeded = MathMax(barsNeeded, InpBaselineAtrPeriod + 3);
   if(Bars < barsNeeded)
      return;

   int signal = GetCrossoverSignal();   // +1 long, -1 short, 0 nothing

   // --- Handle an existing position --------------------------------
   if(HasOpenPosition())
   {
      bool isOppositeSignal = (signal != 0 && signal != GetOpenPositionDirection());

      if(!isOppositeSignal)
         return;

      if(!InpReverseOnOppositeSignal && !InpCloseOnOppositeSignal)
         return;   // Configured to ride it out until stop or target.

      // THE 2.00 FIX.
      //
      // Version 1 closed here and then returned. Because crossovers
      // strictly alternate up, down, up, down, that meant the EA
      // closed on every reverse cross and was always flat by the time
      // the next signal arrived - which was necessarily back in the
      // original direction. It only ever traded one way.
      //
      // Now the close is checked for success, and if we are meant to
      // reverse we fall through into the entry logic below rather
      // than returning.
      if(!ClosePosition("opposite crossover signal"))
         return;   // Close failed - do not open the other way on top of it.

      if(!InpReverseOnOppositeSignal)
         return;   // Close-only mode: wait for a fresh signal.

      // Fall through and open in the new direction.
   }

   // --- Consider a new entry ---------------------------------------
   if(signal == 0)
      return;

   if(!IsWithinTradingSession())
      return;   // Silent: true on most bars, would flood the log.

   if(ShouldFlattenForWeekend())
      return;

   if(!AreSafetyLimitsSatisfied())
      return;

   if(!IsSpreadAcceptable())
      return;

   OpenPosition(signal);
}

//====================================================================
// SECTION 4 - MARKET GEOMETRY
//====================================================================

//+------------------------------------------------------------------+
//| Work out what a "pip" means for this symbol.                      |
//|                                                                   |
//| Brokers quote FX to 4 or 5 decimals (2 or 3 for JPY pairs). On a  |
//| 5-digit feed EURUSD is 1.09876, so a Point is 0.00001 while a pip |
//| is 0.0001 - ten Points. Getting this wrong makes every stop ten   |
//| times too tight, and is the single most common beginner bug.      |
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
//| True exactly once per newly opened bar.                           |
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
//| Current spread in pips.                                           |
//+------------------------------------------------------------------+
double CurrentSpreadPips()
{
   return(MarketInfo(Symbol(), MODE_SPREAD) / (double)g_pointsPerPip);
}

//+------------------------------------------------------------------+
//| The broker's minimum permitted stop distance, in pips.            |
//+------------------------------------------------------------------+
double GetBrokerMinimumStopPips()
{
   if(g_pipSizeInPrice <= 0.0)
      return(0.0);

   return((MarketInfo(Symbol(), MODE_STOPLEVEL) * Point) / g_pipSizeInPrice);
}

//+------------------------------------------------------------------+
//| Readable timeframe name, for logging.                             |
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
// timezone (GMT+2 and GMT+3 are common) and many shift with US
// daylight saving, so the offset is re-derived on every load.
//====================================================================

//+------------------------------------------------------------------+
//| Hours to subtract from server time to get GMT.                    |
//|                                                                   |
//| TimeGMT() reads the PC clock and its timezone, so it is only      |
//| meaningful live. In the tester it is modelled, so the manual      |
//| input is used there instead.                                      |
//+------------------------------------------------------------------+
int DetermineBrokerGmtOffset()
{
   if(!InpAutoDetectGmtOffset || IsTesting() || IsOptimization())
      return(InpBrokerGmtOffsetHours);

   datetime serverTime = TimeCurrent();
   datetime gmtTime    = TimeGMT();

   if(serverTime <= 0 || gmtTime <= 0)
   {
      Print("WARNING: Could not read both clocks to detect the broker offset. ",
            "Using the manual value of ", InpBrokerGmtOffsetHours, ".");
      return(InpBrokerGmtOffsetHours);
   }

   int detectedOffset = (int)MathRound((double)(serverTime - gmtTime) / 3600.0);

   if(detectedOffset < -12 || detectedOffset > 14)
   {
      Print("WARNING: Detected an implausible offset of ", detectedOffset,
            " hours. Using the manual value of ", InpBrokerGmtOffsetHours, ".");
      return(InpBrokerGmtOffsetHours);
   }

   return(detectedOffset);
}

//+------------------------------------------------------------------+
//| Now, in GMT, derived from the server clock.                       |
//+------------------------------------------------------------------+
datetime CurrentGmtTime()
{
   return((datetime)(TimeCurrent() - g_brokerGmtOffset * 3600));
}

//+------------------------------------------------------------------+
//| Server time at which the current GMT day began. Used as the       |
//| boundary for "today" in the daily caps, so those line up with     |
//| the session filter rather than with the broker's arbitrary day.   |
//+------------------------------------------------------------------+
datetime StartOfCurrentGmtDayInServerTime()
{
   MqlDateTime gmtNow;
   TimeToStruct(CurrentGmtTime(), gmtNow);

   int secondsIntoDay = gmtNow.hour * 3600 + gmtNow.min * 60 + gmtNow.sec;

   return((datetime)(TimeCurrent() - secondsIntoDay));
}

//+------------------------------------------------------------------+
//| Is the market inside the configured window? Handles a window that |
//| wraps past midnight, and refuses weekends outright.               |
//+------------------------------------------------------------------+
bool IsWithinTradingSession()
{
   if(!InpUseSessionFilter)
      return(true);

   MqlDateTime gmtNow;
   TimeToStruct(CurrentGmtTime(), gmtNow);

   if(gmtNow.day_of_week == 0 || gmtNow.day_of_week == 6)   // Sun / Sat
      return(false);

   int hourNow = gmtNow.hour;

   if(InpSessionStartHourGmt < InpSessionEndHourGmt)
      return(hourNow >= InpSessionStartHourGmt && hourNow < InpSessionEndHourGmt);

   // Window wraps past midnight, e.g. 22:00 -> 04:00.
   return(hourNow >= InpSessionStartHourGmt || hourNow < InpSessionEndHourGmt);
}

//+------------------------------------------------------------------+
//| Should we be flat because the weekend is approaching?             |
//|                                                                   |
//| An ATR-sized stop cannot survive a Sunday-open gap, which         |
//| routinely exceeds it. Holding over a weekend converts a           |
//| controlled risk into an uncontrolled one.                         |
//+------------------------------------------------------------------+
bool ShouldFlattenForWeekend()
{
   if(!InpCloseBeforeWeekend)
      return(false);

   MqlDateTime gmtNow;
   TimeToStruct(CurrentGmtTime(), gmtNow);

   if(gmtNow.day_of_week == 5 && gmtNow.hour >= InpFridayCloseHourGmt)
      return(true);

   if(gmtNow.day_of_week == 6)
      return(true);

   return(false);
}

//====================================================================
// SECTION 6 - THE SIGNAL
//====================================================================

//+------------------------------------------------------------------+
//| Moving-average crossover on the two most recently CLOSED bars.    |
//|                                                                   |
//|   shift 0 = bar currently forming  (values still changing)        |
//|   shift 1 = bar that just closed   (final)                        |
//|   shift 2 = the one before that    (final)                        |
//|                                                                   |
//| Comparing shifts 1 and 2 gives a signal that cannot repaint.      |
//| Comparing shift 0 to shift 1 would let a signal appear and then   |
//| vanish before the bar closed - the classic reason a backtest and  |
//| live trading disagree.                                            |
//|                                                                   |
//| Returns +1 bullish, -1 bearish, 0 no cross.                       |
//+------------------------------------------------------------------+
int GetCrossoverSignal()
{
   double fastPrevious = iMA(Symbol(), Period(), InpFastMaPeriod, 0, InpMaMethod, InpMaPrice, 2);
   double slowPrevious = iMA(Symbol(), Period(), InpSlowMaPeriod, 0, InpMaMethod, InpMaPrice, 2);
   double fastCurrent  = iMA(Symbol(), Period(), InpFastMaPeriod, 0, InpMaMethod, InpMaPrice, 1);
   double slowCurrent  = iMA(Symbol(), Period(), InpSlowMaPeriod, 0, InpMaMethod, InpMaPrice, 1);

   if(fastPrevious <= slowPrevious && fastCurrent > slowCurrent)
      return(1);

   if(fastPrevious >= slowPrevious && fastCurrent < slowCurrent)
      return(-1);

   return(0);
}

//====================================================================
// SECTION 7 - VOLATILITY, STOPS AND SYMBOL SCALING
//--------------------------------------------------------------------
// The point of this section is that nothing here is tuned to a
// specific pair. GBPUSD moves roughly a third more than EURUSD and
// costs more to trade; expressing every threshold as a multiple of
// the symbol's OWN volatility means both behave sensibly under one
// set of inputs, and so does anything else you attach it to.
//====================================================================

//+------------------------------------------------------------------+
//| ATR of the last closed bar, in pips. Short period - this is the   |
//| "what is happening right now" measure.                            |
//+------------------------------------------------------------------+
double GetAtrInPips()
{
   double atrInPrice = iATR(Symbol(), Period(), InpAtrPeriod, 1);

   if(atrInPrice <= 0.0 || g_pipSizeInPrice <= 0.0)
      return(0.0);

   return(atrInPrice / g_pipSizeInPrice);
}

//+------------------------------------------------------------------+
//| ATR over a much longer window, in pips. This is the symbol's      |
//| typical volatility - its yardstick - and it barely moves from     |
//| bar to bar, which is what makes it usable as a scale factor.      |
//|                                                                   |
//| On EURUSD M5 this sits around 3-4 pips; on GBPUSD around 5-6.     |
//| Every clamp below is expressed against it.                        |
//+------------------------------------------------------------------+
double GetBaselineAtrInPips()
{
   double atrInPrice = iATR(Symbol(), Period(), InpBaselineAtrPeriod, 1);

   if(atrInPrice <= 0.0 || g_pipSizeInPrice <= 0.0)
      return(0.0);

   return(atrInPrice / g_pipSizeInPrice);
}

//+------------------------------------------------------------------+
//| Lower bound on the stop distance, in pips.                        |
//|                                                                   |
//| Stops this side of the floor get closed by ordinary noise and     |
//| spread rather than by the trade being wrong.                      |
//+------------------------------------------------------------------+
double MinimumStopPips()
{
   if(!InpAutoScaleToSymbol)
      return(InpMinStopPips);

   double baseline = GetBaselineAtrInPips();

   if(baseline <= 0.0)
      return(InpMinStopPips);   // Not enough history yet.

   return(baseline * InpMinStopAsBaselineRatio);
}

//+------------------------------------------------------------------+
//| Upper bound on the stop distance, in pips.                        |
//|                                                                   |
//| Without a ceiling a news spike inflates ATR, the stop widens, and |
//| risk-based sizing returns a position below the broker's minimum   |
//| lot - so the EA silently stops trading at exactly the moment the  |
//| market is most active.                                            |
//+------------------------------------------------------------------+
double MaximumStopPips()
{
   if(!InpAutoScaleToSymbol)
      return(InpMaxStopPips);

   double baseline = GetBaselineAtrInPips();

   if(baseline <= 0.0)
      return(InpMaxStopPips);

   return(baseline * InpMaxStopAsBaselineRatio);
}

//+------------------------------------------------------------------+
//| The spread we are willing to pay right now, in pips.              |
//|                                                                   |
//| Expressed as a fraction of live ATR, because what matters is not  |
//| the spread in isolation but the spread relative to the movement   |
//| available. 1.5 pips against a 20 pip target is 7.5% given away;   |
//| the same 1.5 pips at 3am against a 4 pip range is fatal. The      |
//| absolute cap is kept as a backstop for when ATR misreads.         |
//+------------------------------------------------------------------+
double CurrentMaxSpreadPips()
{
   double absoluteCap = InpMaxSpreadPips;

   if(!InpAutoScaleToSymbol)
      return(absoluteCap);

   double liveAtr = GetAtrInPips();

   if(liveAtr <= 0.0)
      return(absoluteCap);

   double adaptiveCap = liveAtr * InpMaxSpreadAsAtrRatio;

   return(MathMin(adaptiveCap, absoluteCap));
}

//+------------------------------------------------------------------+
//| Reject entries when the spread is too wide to be worth paying.    |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
{
   double spreadPips = CurrentSpreadPips();
   double capPips    = CurrentMaxSpreadPips();

   if(spreadPips > capPips)
   {
      Print("Skipping entry: spread ", DoubleToString(spreadPips, 2),
            " pips exceeds the current cap of ", DoubleToString(capPips, 2),
            " pips (ATR ", DoubleToString(GetAtrInPips(), 1), ").");
      return(false);
   }
   return(true);
}

//+------------------------------------------------------------------+
//| Stop distance for a trade opened right now, in pips.              |
//|                                                                   |
//| The broker's minimum is applied HERE, before the figure reaches   |
//| position sizing. AttachStopsToOrder has to widen anything inside  |
//| MODE_STOPLEVEL or the broker rejects it; if sizing used the       |
//| narrower pre-clamp number the position would be built for one     |
//| stop and given another, quietly risking more than configured.     |
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
         stopPips = InpStopLossPips;   // No ATR yet - fall back quietly.
      else
      {
         stopPips = atrPips * InpAtrStopMultiplier;

         double floorPips   = MinimumStopPips();
         double ceilingPips = MaximumStopPips();

         if(stopPips < floorPips)   stopPips = floorPips;
         if(stopPips > ceilingPips) stopPips = ceilingPips;
      }
   }

   double brokerMinimum = GetBrokerMinimumStopPips();
   if(stopPips < brokerMinimum)
      stopPips = brokerMinimum;

   return(stopPips);
}

//+------------------------------------------------------------------+
//| Take-profit distance for a trade opened right now, in pips.       |
//+------------------------------------------------------------------+
double CurrentTakeProfitPips()
{
   double takePips;

   if(!InpUseAtrStops)
      takePips = InpTakeProfitPips;
   else
   {
      double atrPips = GetAtrInPips();
      takePips = (atrPips > 0.0) ? atrPips * InpAtrTargetMultiplier : InpTakeProfitPips;
   }

   return(MathMax(takePips, GetBrokerMinimumStopPips()));
}

//+------------------------------------------------------------------+
//| Trailing distance to use right now, in pips.                      |
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
// MT4 has no "current position" object. You loop the order pool and
// filter yourself. The magic number is what stops this EA touching
// trades you opened by hand or that another EA opened on the same
// chart, so every loop checks it.
//====================================================================

//+------------------------------------------------------------------+
//| Ticket of this EA's open market order, or -1 if it has none.      |
//+------------------------------------------------------------------+
int FindOpenTicket()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol())            continue;
      if(OrderMagicNumber() != InpMagicNumber) continue;
      if(OrderType() > OP_SELL)                continue;   // Skip pending orders.

      return(OrderTicket());
   }
   return(-1);
}

//+------------------------------------------------------------------+
//| Does this EA have a position open?                                |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   return(FindOpenTicket() >= 0);
}

//+------------------------------------------------------------------+
//| Direction of the open position: +1 long, -1 short, 0 none.        |
//+------------------------------------------------------------------+
int GetOpenPositionDirection()
{
   int ticket = FindOpenTicket();

   if(ticket < 0 || !OrderSelect(ticket, SELECT_BY_TICKET))
      return(0);

   if(OrderType() == OP_BUY)  return(1);
   if(OrderType() == OP_SELL) return(-1);

   return(0);
}

//====================================================================
// SECTION 9 - POSITION SIZING
//====================================================================

//+------------------------------------------------------------------+
//| Turn a risk percentage and a stop distance into a lot size.       |
//|                                                                   |
//|   1. riskAmount    = balance x riskPercent / 100                  |
//|   2. pipValuePerLot = (MODE_TICKVALUE / MODE_TICKSIZE) x pipSize  |
//|   3. lots          = riskAmount / (stopPips x pipValuePerLot)     |
//|   4. round DOWN to the lot step, clamp to min/max                 |
//|                                                                   |
//| Step 4 rounds down deliberately. Rounding up would silently push  |
//| the trade past the risk the user configured.                      |
//|                                                                   |
//| Worked example - 10,000 GBP balance, 0.5% risk:                   |
//|   quiet hour, ATR 2.0 -> stop hits the floor, say 2.5 pips        |
//|     pip value ~7.90/lot -> 2.5 x 7.90 = 19.75 per lot             |
//|     50 / 19.75 = 2.53 lots                                        |
//|   London, ATR 5.0 -> stop = 7.5 pips                              |
//|     7.5 x 7.90 = 59.25 per lot                                    |
//|     50 / 59.25 = 0.84 lots                                        |
//|                                                                   |
//| The position shrank as the stop widened, so the money at risk     |
//| stayed at 50 GBP in both cases. That is the whole reason ATR      |
//| stops and risk-based sizing belong together - and also why the    |
//| stop floor matters, since a tiny stop implies a large position.   |
//+------------------------------------------------------------------+
double CalculateLotSize(double stopLossInPips)
{
   if(!InpUseRiskBasedSizing)
      return(NormaliseLotSize(InpFixedLotSize));

   double riskAmount = AccountBalance() * InpRiskPercentPerTrade / 100.0;

   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);  // Account currency per tick per lot
   double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);   // Price move of one tick

   if(tickValue <= 0.0 || tickSize <= 0.0 || stopLossInPips <= 0.0)
   {
      Print("WARNING: Cannot compute a risk-based size ",
            "(tickValue=", tickValue, ", tickSize=", tickSize,
            ", stop=", stopLossInPips, "). Falling back to the fixed lot size.");
      return(NormaliseLotSize(InpFixedLotSize));
   }

   double pipValuePerLot = (tickValue / tickSize) * g_pipSizeInPrice;

   return(NormaliseLotSize(riskAmount / (stopLossInPips * pipValuePerLot)));
}

//+------------------------------------------------------------------+
//| Round down to the broker's lot step and clamp to min/max.         |
//| Returns 0.0 when the broker's minimum exceeds our risk budget -   |
//| callers must treat that as "skip this trade", not "trade small".  |
//+------------------------------------------------------------------+
double NormaliseLotSize(double requestedLots)
{
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

   if(lotStep <= 0.0) lotStep = 0.01;

   double steppedLots = MathFloor(requestedLots / lotStep) * lotStep;
   steppedLots = NormalizeDouble(steppedLots, g_lotDigits);

   if(steppedLots > maxLot)
      steppedLots = maxLot;

   if(steppedLots < minLot)
   {
      Print("Requested size ", DoubleToString(requestedLots, 4),
            " is below the broker minimum of ", DoubleToString(minLot, g_lotDigits),
            ". Skipping the trade rather than risking more than configured.");
      return(0.0);
   }

   return(steppedLots);
}

//====================================================================
// SECTION 10 - SAFETY LIMITS
//--------------------------------------------------------------------
// None of this improves the strategy. All of it bounds how badly a
// bad day can go, which is a different and more achievable goal.
// Every figure is recomputed from closed-trade history rather than
// held in memory, so a terminal restart cannot reset the limits.
//====================================================================

//+------------------------------------------------------------------+
//| Net realised profit for this EA on this symbol so far today, in   |
//| account currency. Includes commission and swap, because those are |
//| real money and excluding them flatters the numbers.               |
//+------------------------------------------------------------------+
double RealisedProfitToday()
{
   datetime dayStart = StartOfCurrentGmtDayInServerTime();
   double   total    = 0.0;

   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         continue;
      if(OrderSymbol() != Symbol())            continue;
      if(OrderMagicNumber() != InpMagicNumber) continue;
      if(OrderType() > OP_SELL)                continue;
      if(OrderCloseTime() < dayStart)          continue;

      total += OrderProfit() + OrderCommission() + OrderSwap();
   }

   return(total);
}

//+------------------------------------------------------------------+
//| How many trades this EA has opened today.                         |
//|                                                                   |
//| Counted by OPEN time, not close time, so a trade still running    |
//| is included - otherwise the cap could be exceeded by holding.     |
//+------------------------------------------------------------------+
int TradesOpenedToday()
{
   datetime dayStart = StartOfCurrentGmtDayInServerTime();
   int      count    = 0;

   for(int h = OrdersHistoryTotal() - 1; h >= 0; h--)
   {
      if(!OrderSelect(h, SELECT_BY_POS, MODE_HISTORY))
         continue;
      if(OrderSymbol() != Symbol())            continue;
      if(OrderMagicNumber() != InpMagicNumber) continue;
      if(OrderType() > OP_SELL)                continue;
      if(OrderOpenTime() < dayStart)           continue;

      count++;
   }

   for(int t = OrdersTotal() - 1; t >= 0; t--)
   {
      if(!OrderSelect(t, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderSymbol() != Symbol())            continue;
      if(OrderMagicNumber() != InpMagicNumber) continue;
      if(OrderType() > OP_SELL)                continue;
      if(OrderOpenTime() < dayStart)           continue;

      count++;
   }

   return(count);
}

//+------------------------------------------------------------------+
//| Details of the n-th most recent closed trade (n = 0 is the most   |
//| recent). Returns false when there are fewer than n+1 of them.     |
//|                                                                   |
//| MT4's history pool is not ordered by close time, so this finds    |
//| the latest close strictly earlier than the previous one found.    |
//| That is O(n x history), but n is only ever a handful, and it      |
//| means the loss counter is rebuilt from the broker's own record    |
//| rather than from a variable that a restart would clear.           |
//+------------------------------------------------------------------+
bool GetRecentClosedTrade(int n, datetime &closeTime, double &netProfit)
{
   datetime upperBound = TimeCurrent() + 86400;   // Start above any real close time.

   for(int rank = 0; rank <= n; rank++)
   {
      datetime bestTime   = 0;
      double   bestProfit = 0.0;
      bool     found      = false;

      for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
      {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
            continue;
         if(OrderSymbol() != Symbol())            continue;
         if(OrderMagicNumber() != InpMagicNumber) continue;
         if(OrderType() > OP_SELL)                continue;

         datetime thisClose = OrderCloseTime();

         if(thisClose >= upperBound) continue;   // Already counted in an earlier rank.
         if(found && thisClose <= bestTime) continue;

         bestTime   = thisClose;
         bestProfit = OrderProfit() + OrderCommission() + OrderSwap();
         found      = true;
      }

      if(!found)
         return(false);

      upperBound = bestTime;
      closeTime  = bestTime;
      netProfit  = bestProfit;
   }

   return(true);
}

//+------------------------------------------------------------------+
//| How many losses this EA has taken in a row, most recent first.    |
//| Stops counting at InpMaxConsecutiveLosses - we only need to know  |
//| whether the threshold is reached, not the full streak.            |
//+------------------------------------------------------------------+
int ConsecutiveLosses()
{
   if(InpMaxConsecutiveLosses <= 0)
      return(0);

   int streak = 0;

   for(int n = 0; n < InpMaxConsecutiveLosses; n++)
   {
      datetime closeTime = 0;
      double   profit    = 0.0;

      if(!GetRecentClosedTrade(n, closeTime, profit))
         break;

      if(profit >= 0.0)
         break;            // A win ends the streak.

      streak++;
   }

   return(streak);
}

//+------------------------------------------------------------------+
//| Has the daily loss cap been breached?                             |
//+------------------------------------------------------------------+
bool HasBreachedDailyLossCap()
{
   if(InpMaxDailyLossPercent <= 0.0)
      return(false);

   double balance = AccountBalance();
   if(balance <= 0.0)
      return(false);

   double lossToday = -RealisedProfitToday();          // Positive when down.
   double capAmount = balance * InpMaxDailyLossPercent / 100.0;

   return(lossToday >= capAmount);
}

//+------------------------------------------------------------------+
//| Gate every entry through the safety limits.                       |
//|                                                                   |
//| Logs at most once per day per limit, because these are true for   |
//| the rest of the session once tripped and would otherwise repeat   |
//| on every bar.                                                     |
//+------------------------------------------------------------------+
bool AreSafetyLimitsSatisfied()
{
   // --- Cooldown after a run of losses -----------------------------
   if(g_cooldownUntil > 0)
   {
      if(TimeCurrent() < g_cooldownUntil)
         return(false);

      Print("Cooldown finished, trading resumes.");
      g_cooldownUntil = 0;
   }

   if(InpMaxConsecutiveLosses > 0)
   {
      datetime mostRecentClose  = 0;
      double   mostRecentProfit = 0.0;

      if(GetRecentClosedTrade(0, mostRecentClose, mostRecentProfit) &&
         mostRecentClose > g_cooldownTriggerClose)
      {
         int streak = ConsecutiveLosses();

         if(streak >= InpMaxConsecutiveLosses)
         {
            g_cooldownUntil        = (datetime)(TimeCurrent() + InpCooldownMinutes * 60);
            g_cooldownTriggerClose = mostRecentClose;

            Print(streak, " losses in a row. Pausing for ", InpCooldownMinutes,
                  " minutes, until ", TimeToString(g_cooldownUntil), ".");
            return(false);
         }
      }
   }

   // --- Daily loss cap ---------------------------------------------
   if(HasBreachedDailyLossCap())
   {
      datetime today = StartOfCurrentGmtDayInServerTime();

      if(g_dailyLossReportedDay != today)
      {
         Print("Daily loss cap reached: ", DoubleToString(RealisedProfitToday(), 2),
               " ", AccountCurrency(), " against a cap of ",
               DoubleToString(InpMaxDailyLossPercent, 1),
               "%. No further entries today.");
         g_dailyLossReportedDay = today;
      }
      return(false);
   }

   // --- Daily trade cap --------------------------------------------
   if(InpMaxTradesPerDay > 0 && TradesOpenedToday() >= InpMaxTradesPerDay)
      return(false);   // Silent: true for the rest of the day.

   return(true);
}

//====================================================================
// SECTION 11 - ORDER PLACEMENT
//====================================================================

//+------------------------------------------------------------------+
//| Open a market position (+1 long, -1 short).                       |
//|                                                                   |
//| The order is sent WITHOUT a stop or target and the levels are     |
//| attached immediately afterwards with OrderModify. Many ECN/STP    |
//| brokers reject an OrderSend carrying SL/TP with error 130;        |
//| sending bare and then modifying works everywhere, at the cost of  |
//| a brief window in which the position is unprotected. That window  |
//| is why AttachStopsToOrder shouts if it fails.                     |
//+------------------------------------------------------------------+
void OpenPosition(int direction)
{
   // Resolve the distances ONCE and pass them down. Re-reading ATR
   // inside AttachStopsToOrder could yield a different number, and
   // the position would then be sized against a stop it never got.
   double stopLossPips   = CurrentStopLossPips();
   double takeProfitPips = CurrentTakeProfitPips();
   double atrPips        = GetAtrInPips();
   double spreadPips     = CurrentSpreadPips();

   double lotSize = CalculateLotSize(stopLossPips);
   if(lotSize <= 0.0)
      return;

   int   orderType  = (direction > 0) ? OP_BUY : OP_SELL;
   int   slippage   = (int)MathRound(InpMaxSlippagePips * g_pointsPerPip);
   color arrowColor = (direction > 0) ? clrDodgerBlue : clrOrangeRed;

   // ResetLastError first, so GetLastError below reflects this call
   // rather than something stale from earlier.
   ResetLastError();
   double freeMarginAfter = AccountFreeMarginCheck(Symbol(), orderType, lotSize);
   if(freeMarginAfter <= 0.0 || GetLastError() == ERR_NOT_ENOUGH_MONEY)
   {
      Print("Not enough free margin for ", DoubleToString(lotSize, g_lotDigits), " lots.");
      return;
   }

   int ticket = -1;

   for(int attempt = 1; attempt <= InpOrderRetryAttempts; attempt++)
   {
      // A stale cached price is the usual cause of error 129.
      RefreshRates();
      double entryPrice = (direction > 0) ? Ask : Bid;

      ticket = OrderSend(Symbol(), orderType, lotSize,
                         NormalizeDouble(entryPrice, Digits),
                         slippage,
                         0.0, 0.0,
                         InpTradeComment, InpMagicNumber, 0, arrowColor);

      if(ticket >= 0)
         break;

      int errorCode = GetLastError();
      Print("OrderSend attempt ", attempt, "/", InpOrderRetryAttempts,
            " failed: error ", errorCode, " (", ErrorDescription(errorCode), ").");

      if(!IsRetryableError(errorCode))
         return;

      Sleep(InpOrderRetryDelayMs);
   }

   if(ticket < 0)
   {
      Print("Giving up on this entry after ", InpOrderRetryAttempts, " attempts.");
      return;
   }

   // Remember the context of this trade so the exit can be journalled
   // with the conditions that produced it, not just the result.
   g_openTicket     = ticket;
   g_openStopPips   = stopLossPips;
   g_openAtrPips    = atrPips;
   g_openSpreadPips = spreadPips;

   Print("Opened ", (direction > 0 ? "LONG " : "SHORT "),
         DoubleToString(lotSize, g_lotDigits), " lots, ticket ", ticket,
         " | stop ", DoubleToString(stopLossPips, 1),
         " target ", DoubleToString(takeProfitPips, 1),
         " | ATR ", DoubleToString(atrPips, 1),
         " spread ", DoubleToString(spreadPips, 2),
         " | trade ", TradesOpenedToday(), " of ",
         (InpMaxTradesPerDay > 0 ? IntegerToString(InpMaxTradesPerDay) : "unlimited"), " today");

   AttachStopsToOrder(ticket, direction, stopLossPips, takeProfitPips);

   JournalEntry(ticket, direction, lotSize, stopLossPips, takeProfitPips,
                atrPips, spreadPips);
}

//+------------------------------------------------------------------+
//| Attach stop and target to an order that is already open,          |
//| respecting the broker's minimum distance.                         |
//+------------------------------------------------------------------+
void AttachStopsToOrder(int ticket, int direction,
                        double stopLossPips, double takeProfitPips)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
   {
      Print("Could not select ticket ", ticket, " to attach stops.");
      return;
   }

   double openPrice          = OrderOpenPrice();
   double minimumStopDistance = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;

   double stopLossPrice   = 0.0;
   double takeProfitPrice = 0.0;

   if(stopLossPips > 0.0)
   {
      double stopDistance = MathMax(stopLossPips * g_pipSizeInPrice, minimumStopDistance);
      stopLossPrice = (direction > 0) ? openPrice - stopDistance : openPrice + stopDistance;
      stopLossPrice = NormalizeDouble(stopLossPrice, Digits);
   }

   if(takeProfitPips > 0.0)
   {
      double profitDistance = MathMax(takeProfitPips * g_pipSizeInPrice, minimumStopDistance);
      takeProfitPrice = (direction > 0) ? openPrice + profitDistance : openPrice - profitDistance;
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
            " on ticket ", ticket, " failed: error ", errorCode,
            " (", ErrorDescription(errorCode), ").");

      if(!IsRetryableError(errorCode))
         break;

      Sleep(InpOrderRetryDelayMs);
      RefreshRates();
   }

   Print("WARNING: Ticket ", ticket, " is OPEN WITHOUT A STOP LOSS. Intervene manually.");
}

//+------------------------------------------------------------------+
//| Close this EA's position at market.                               |
//|                                                                   |
//| Returns true only if nothing of ours remains open afterwards.     |
//| The caller relies on that: reversing on a failed close would      |
//| stack an opposing position on top of the one still running.       |
//+------------------------------------------------------------------+
bool ClosePosition(string reason)
{
   int ticket = FindOpenTicket();

   if(ticket < 0)
      return(true);   // Nothing to close - already in the desired state.

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return(false);

   double lots     = OrderLots();
   int    slippage = (int)MathRound(InpMaxSlippagePips * g_pointsPerPip);
   bool   closed   = false;

   for(int attempt = 1; attempt <= InpOrderRetryAttempts; attempt++)
   {
      if(!OrderSelect(ticket, SELECT_BY_TICKET))
         break;

      RefreshRates();
      double closePrice = (OrderType() == OP_BUY) ? Bid : Ask;

      if(OrderClose(ticket, lots, NormalizeDouble(closePrice, Digits), slippage, clrGray))
      {
         Print("Closed ticket ", ticket, ": ", reason, ".");
         closed = true;
         break;
      }

      int errorCode = GetLastError();
      Print("OrderClose attempt ", attempt, "/", InpOrderRetryAttempts,
            " on ticket ", ticket, " failed: error ", errorCode,
            " (", ErrorDescription(errorCode), ").");

      if(!IsRetryableError(errorCode))
         break;

      Sleep(InpOrderRetryDelayMs);
   }

   if(!closed)
   {
      Print("WARNING: Could not close ticket ", ticket, " (", reason, ").");
      return(false);
   }

   JournalExit(ticket, reason);
   g_openTicket = -1;

   return(true);
}

//====================================================================
// SECTION 12 - TRADE MANAGEMENT
//====================================================================

//+------------------------------------------------------------------+
//| Trailing stop.                                                    |
//|                                                                   |
//| The first guard means the trail never engages until price is more |
//| than one trailing distance in profit - so its first act is always |
//| to move the stop from below the entry to above it. It is a        |
//| break-even mechanism before it is a trailing one.                 |
//|                                                                   |
//| The second guard enforces a minimum improvement, so we are not    |
//| sending a modify request on every tick of a trending move.        |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
   double trailDistance = CurrentTrailingPips() * g_pipSizeInPrice;
   double trailStep     = InpTrailingStepPips  * g_pipSizeInPrice;
   double minimumStop   = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;

   if(trailDistance < minimumStop)
      trailDistance = minimumStop;

   int ticket = FindOpenTicket();
   if(ticket < 0 || !OrderSelect(ticket, SELECT_BY_TICKET))
      return;

   RefreshRates();

   double currentStop = OrderStopLoss();
   double openPrice   = OrderOpenPrice();
   double proposedStop;

   if(OrderType() == OP_BUY)
   {
      proposedStop = NormalizeDouble(Bid - trailDistance, Digits);

      if(proposedStop <= openPrice)                                   return;
      if(currentStop > 0.0 && proposedStop < currentStop + trailStep) return;
   }
   else if(OrderType() == OP_SELL)
   {
      proposedStop = NormalizeDouble(Ask + trailDistance, Digits);

      if(proposedStop >= openPrice)                                   return;
      if(currentStop > 0.0 && proposedStop > currentStop - trailStep) return;
   }
   else
   {
      return;
   }

   if(!OrderModify(ticket, openPrice, proposedStop, OrderTakeProfit(), 0, clrAqua))
   {
      int errorCode = GetLastError();
      Print("Trailing stop update failed on ticket ", ticket,
            ": error ", errorCode, " (", ErrorDescription(errorCode), ").");
   }
}

//====================================================================
// SECTION 13 - JOURNALLING
//--------------------------------------------------------------------
// The strategy will not make money. What running it CAN produce is
// data - and a run that produces no data teaches nothing at all.
//
// Every row records the conditions at the time, not just the result,
// so questions like "do my losses cluster when spread was above half
// the ATR?" or "is the 20:00 flatten costing me?" can be answered by
// sorting a spreadsheet rather than by guessing.
//
// The file lands in MQL4/Files/ - MT4 sandboxes all file access there.
//====================================================================

//+------------------------------------------------------------------+
//| Append one row, creating the file with a header if it is new.     |
//+------------------------------------------------------------------+
void WriteJournalRow(string eventType, int ticket, string direction,
                     double lots, double price, double stopPips,
                     double targetPips, double atrPips, double spreadPips,
                     double profit, string note)
{
   if(!InpWriteJournal)
      return;

   int handle = FileOpen(g_journalFileName,
                         FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ',');

   if(handle == INVALID_HANDLE)
   {
      Print("Journal: could not open ", g_journalFileName,
            " (error ", GetLastError(), "). Continuing without journalling.");
      return;
   }

   // Append rather than overwrite, and write the header only once.
   FileSeek(handle, 0, SEEK_END);

   if(FileSize(handle) == 0)
   {
      FileWrite(handle,
                "server_time", "gmt_time", "event", "ticket", "symbol",
                "timeframe", "direction", "lots", "price", "stop_pips",
                "target_pips", "atr_pips", "spread_pips", "profit",
                "balance", "trades_today", "note");
   }

   FileWrite(handle,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             TimeToString(CurrentGmtTime(), TIME_DATE | TIME_SECONDS),
             eventType,
             IntegerToString(ticket),
             Symbol(),
             TimeframeToText(Period()),
             direction,
             DoubleToString(lots, g_lotDigits),
             DoubleToString(price, Digits),
             DoubleToString(stopPips, 1),
             DoubleToString(targetPips, 1),
             DoubleToString(atrPips, 1),
             DoubleToString(spreadPips, 2),
             DoubleToString(profit, 2),
             DoubleToString(AccountBalance(), 2),
             IntegerToString(TradesOpenedToday()),
             note);

   FileClose(handle);
}

//+------------------------------------------------------------------+
//| Record an entry.                                                  |
//+------------------------------------------------------------------+
void JournalEntry(int ticket, int direction, double lots,
                  double stopPips, double targetPips,
                  double atrPips, double spreadPips)
{
   double entryPrice = 0.0;
   if(OrderSelect(ticket, SELECT_BY_TICKET))
      entryPrice = OrderOpenPrice();

   WriteJournalRow("ENTRY", ticket, (direction > 0 ? "LONG" : "SHORT"),
                   lots, entryPrice, stopPips, targetPips,
                   atrPips, spreadPips, 0.0, "crossover signal");
}

//+------------------------------------------------------------------+
//| Record an exit, reading the realised result out of history.       |
//+------------------------------------------------------------------+
void JournalExit(int ticket, string reason)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY))
   {
      // Occasionally the order has not landed in history yet. Record
      // what we know rather than losing the row entirely.
      WriteJournalRow("EXIT", ticket, "", 0.0, 0.0, g_openStopPips, 0.0,
                      g_openAtrPips, g_openSpreadPips, 0.0,
                      reason + " (result not yet in history)");
      return;
   }

   double netProfit = OrderProfit() + OrderCommission() + OrderSwap();
   string direction = (OrderType() == OP_BUY) ? "LONG" : "SHORT";

   int heldMinutes = (int)((OrderCloseTime() - OrderOpenTime()) / 60);

   WriteJournalRow("EXIT", ticket, direction, OrderLots(), OrderClosePrice(),
                   g_openStopPips, 0.0, g_openAtrPips, g_openSpreadPips,
                   netProfit,
                   reason + " | held " + IntegerToString(heldMinutes) + "min");

   Print("Exit ticket ", ticket, ": ", DoubleToString(netProfit, 2), " ",
         AccountCurrency(), " (", reason, "). Today: ",
         DoubleToString(RealisedProfitToday(), 2), " ", AccountCurrency(),
         " over ", TradesOpenedToday(), " trades.");
}

//+------------------------------------------------------------------+
//| Notice a position that closed on its own stop or target.          |
//|                                                                   |
//| Those exits never pass through ClosePosition, so without this the |
//| journal would record entries with no matching exits - which is    |
//| to say, most of them.                                             |
//+------------------------------------------------------------------+
void DetectAndJournalClosedPosition()
{
   if(g_openTicket < 0)
      return;

   // Still in the live pool? Then nothing has happened.
   if(OrderSelect(g_openTicket, SELECT_BY_TICKET) && OrderCloseTime() == 0)
      return;

   int closedTicket = g_openTicket;
   g_openTicket = -1;                 // Clear first, so a failure here cannot loop.

   if(!OrderSelect(closedTicket, SELECT_BY_TICKET, MODE_HISTORY))
      return;

   // Distinguish a stop from a target by which level the close price
   // is nearer. MT4 does not tell us directly.
   string exitReason = "closed";
   double closePrice = OrderClosePrice();
   double stopLevel  = OrderStopLoss();
   double takeLevel  = OrderTakeProfit();

   if(stopLevel > 0.0 && takeLevel > 0.0)
      exitReason = (MathAbs(closePrice - stopLevel) < MathAbs(closePrice - takeLevel))
                 ? "stop loss" : "take profit";
   else if(stopLevel > 0.0)
      exitReason = "stop loss";
   else if(takeLevel > 0.0)
      exitReason = "take profit";

   JournalExit(closedTicket, exitReason);
}

//====================================================================
// SECTION 14 - ERROR HANDLING
//====================================================================

//+------------------------------------------------------------------+
//| Is a failed trade operation worth retrying?                       |
//|                                                                   |
//| Transient errors - requotes, busy trade threads - may well        |
//| succeed a moment later. Permanent ones (bad volume, invalid       |
//| stops, trading disabled) will fail identically every time, so     |
//| retrying only wastes time and fills the log.                      |
//+------------------------------------------------------------------+
bool IsRetryableError(int errorCode)
{
   switch(errorCode)
   {
      case ERR_SERVER_BUSY:         // 4
      case ERR_NO_CONNECTION:       // 6
      case ERR_TRADE_TIMEOUT:       // 128
      case ERR_INVALID_PRICE:       // 129
      case ERR_PRICE_CHANGED:       // 135
      case ERR_OFF_QUOTES:          // 136
      case ERR_BROKER_BUSY:         // 137
      case ERR_REQUOTE:             // 138
      case ERR_TRADE_CONTEXT_BUSY:  // 146
         return(true);
      default:
         return(false);
   }
}

//+------------------------------------------------------------------+
//| Readable text for the errors this EA actually meets. MT4 ships a  |
//| fuller version in stdlib.mqh; keeping a local one avoids the      |
//| dependency and keeps the messages relevant.                       |
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
      case 149: return("opposite position already open - hedging not allowed");
      default:  return("unmapped error " + IntegerToString(errorCode));
   }
}
//+------------------------------------------------------------------+
