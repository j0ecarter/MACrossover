//+------------------------------------------------------------------+
//|                                             MaCrossoverBot.mq4    |
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
//|  HONEST WARNING                                                   |
//|    A moving-average crossover has no persistent edge in liquid    |
//|    FX markets. Everything valuable in this file is the plumbing   |
//|    around the signal: position sizing, broker constraints, order  |
//|    error handling, and state management. Swap the signal out      |
//|    later; keep the plumbing.                                      |
//+------------------------------------------------------------------+
#property copyright "Joe"
#property version   "1.00"
#property strict                 // Enforces modern MQL4 rules. Always keep this on.

//====================================================================
// SECTION 1 - USER INPUTS
//--------------------------------------------------------------------
// "input" variables appear in the EA's properties dialog in MT4 and
// in the Strategy Tester's optimisation tab. Anything you might ever
// want to tune without recompiling belongs here.
//====================================================================

input string  InpSectionStrategy      = "--- Strategy ---";
input int     InpFastMaPeriod         = 20;      // Fast MA period (bars)
input int     InpSlowMaPeriod         = 50;      // Slow MA period (bars)
input ENUM_MA_METHOD    InpMaMethod   = MODE_SMA;        // MA calculation method
input ENUM_APPLIED_PRICE InpMaPrice   = PRICE_CLOSE;     // Price the MA is built from

input string  InpSectionRisk          = "--- Risk & sizing ---";
input bool    InpUseRiskBasedSizing   = true;    // true = size from % risk, false = fixed lots
input double  InpRiskPercentPerTrade  = 1.0;     // % of account balance risked per trade
input double  InpFixedLotSize         = 0.01;    // Lots used when risk-based sizing is off
input double  InpStopLossPips         = 30.0;    // Stop loss distance in pips (0 = none)
input double  InpTakeProfitPips       = 60.0;    // Take profit distance in pips (0 = none)

input string  InpSectionManagement    = "--- Trade management ---";
input bool    InpCloseOnOppositeSignal= true;    // Close the position when the MAs cross back
input bool    InpUseTrailingStop      = false;   // Enable a simple trailing stop
input double  InpTrailingStopPips     = 20.0;    // Trailing distance in pips
input double  InpTrailingStepPips     = 5.0;     // Minimum improvement before moving the stop

input string  InpSectionExecution     = "--- Execution ---";
input int     InpMagicNumber          = 20260909;// Unique ID so this EA only touches its own trades
input double  InpMaxSpreadPips        = 3.0;     // Skip entries when the spread is wider than this
input double  InpMaxSlippagePips      = 2.0;     // Maximum price deviation we will accept
input int     InpOrderRetryAttempts   = 3;       // How many times to retry a rejected order
input int     InpOrderRetryDelayMs    = 500;     // Pause between retries, in milliseconds
input string  InpTradeComment         = "MaCrossoverBot";

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
   if(InpUseRiskBasedSizing)
   {
      if(InpRiskPercentPerTrade <= 0.0 || InpRiskPercentPerTrade > 10.0)
      {
         Print("ERROR: Risk percent must be between 0 and 10. ",
               "Anything above ~2% per trade is reckless.");
         return(INIT_PARAMETERS_INCORRECT);
      }
      if(InpStopLossPips <= 0.0)
      {
         Print("ERROR: Risk-based sizing needs a non-zero stop loss ",
               "to size against.");
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

   Print(InpTradeComment, " initialised on ", Symbol(),
         ". Digits=", Digits,
         ", pip=", DoubleToString(g_pipSizeInPrice, Digits),
         ", points per pip=", g_pointsPerPip,
         ", lot step=", DoubleToString(lotStep, g_lotDigits));

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Called when the EA is removed. Nothing to clean up here, but the  |
//| reason code is useful in the log when you are debugging reloads.  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   PrintFormat("%s stopped. Reason code: %d", InpTradeComment, reason);
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

   // The MAs need enough history to be meaningful.
   if(Bars < InpSlowMaPeriod + 3)
      return;

   int signal = GetCrossoverSignal();   // +1 = long, -1 = short, 0 = nothing

   // --- Manage any position we already have -----------------------
   if(HasOpenPosition())
   {
      if(InpCloseOnOppositeSignal && signal != 0 && signal != GetOpenPositionDirection())
      {
         ClosePosition();
      }
      return;   // Never stack positions in this EA.
   }

   // --- Consider a new entry --------------------------------------
   if(signal == 0)
      return;

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
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
{
   double currentSpreadPips = MarketInfo(Symbol(), MODE_SPREAD) / (double)g_pointsPerPip;

   if(currentSpreadPips > InpMaxSpreadPips)
   {
      PrintFormat("Skipping entry: spread %.1f pips exceeds the %.1f pip limit.",
                  currentSpreadPips, InpMaxSpreadPips);
      return(false);
   }
   return(true);
}

//====================================================================
// SECTION 5 - THE SIGNAL
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
// SECTION 6 - POSITION INSPECTION
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
// SECTION 7 - POSITION SIZING
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
//| Worked example - EURUSD, standard account:                        |
//|   balance 10,000 GBP, risk 1%          -> riskAmount = 100        |
//|   stop 30 pips, pip value ~7.90/lot    -> 30 * 7.90 = 237 per lot |
//|   100 / 237                            -> 0.42 lots               |
//|   lot step 0.01                        -> 0.42 lots               |
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
// SECTION 8 - ORDER PLACEMENT
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
   double lotSize = CalculateLotSize(InpStopLossPips);
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
      Print("Not enough free margin for a ", DoubleToString(lotSize, g_lotDigits), " lot position.");
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
      PrintFormat("OrderSend attempt %d/%d failed with error %d (%s).",
                  attempt, InpOrderRetryAttempts, errorCode, ErrorDescription(errorCode));

      if(!IsRetryableError(errorCode))
         return;                     // A permanent error - retrying will not help.

      Sleep(InpOrderRetryDelayMs);
   }

   if(ticket < 0)
   {
      Print("Giving up on this entry after ", InpOrderRetryAttempts, " attempts.");
      return;
   }

   AttachStopsToOrder(ticket, direction);
}

//+------------------------------------------------------------------+
//| Attach a stop loss and take profit to an order that is already    |
//| open, respecting the broker's minimum stop distance.              |
//+------------------------------------------------------------------+
void AttachStopsToOrder(int ticket, int direction)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
   {
      Print("Could not select ticket ", ticket, " to attach stops.");
      return;
   }

   double openPrice = OrderOpenPrice();

   // The broker will not accept a stop closer to price than this.
   // MODE_STOPLEVEL is in Points; convert it to price units.
   double minimumStopDistance = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;

   double stopLossPrice   = 0.0;
   double takeProfitPrice = 0.0;

   if(InpStopLossPips > 0.0)
   {
      double stopDistance = MathMax(InpStopLossPips * g_pipSizeInPrice, minimumStopDistance);
      stopLossPrice = (direction > 0) ? openPrice - stopDistance
                                      : openPrice + stopDistance;
      stopLossPrice = NormalizeDouble(stopLossPrice, Digits);
   }

   if(InpTakeProfitPips > 0.0)
   {
      double profitDistance = MathMax(InpTakeProfitPips * g_pipSizeInPrice, minimumStopDistance);
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
      PrintFormat("OrderModify attempt %d/%d on ticket %d failed with error %d (%s).",
                  attempt, InpOrderRetryAttempts, ticket, errorCode, ErrorDescription(errorCode));

      if(!IsRetryableError(errorCode))
         break;

      Sleep(InpOrderRetryDelayMs);
      RefreshRates();
   }

   Print("WARNING: Ticket ", ticket, " is OPEN WITHOUT A STOP LOSS. Intervene manually.");
}

//+------------------------------------------------------------------+
//| Close this EA's open position at market.                          |
//+------------------------------------------------------------------+
void ClosePosition()
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
            Print("Closed ticket ", ticket, " on an opposite signal.");
            break;
         }

         int errorCode = GetLastError();
         PrintFormat("OrderClose attempt %d/%d on ticket %d failed with error %d (%s).",
                     attempt, InpOrderRetryAttempts, ticket, errorCode, ErrorDescription(errorCode));

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
// SECTION 9 - TRADE MANAGEMENT
//====================================================================

//+------------------------------------------------------------------+
//| A simple trailing stop.                                           |
//|                                                                   |
//| Once price has moved in our favour by more than the trailing      |
//| distance, keep the stop that far behind the current price. The    |
//| "step" input stops us from spamming the server with a modify      |
//| request on every single tick.                                     |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
   double trailDistance = InpTrailingStopPips * g_pipSizeInPrice;
   double trailStep     = InpTrailingStepPips * g_pipSizeInPrice;
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
         if(proposedStop <= OrderOpenPrice())                        continue;
         if(currentStop > 0.0 && proposedStop < currentStop + trailStep) continue;
      }
      else // OP_SELL
      {
         proposedStop = NormalizeDouble(Ask + trailDistance, Digits);

         // Only ever move the stop DOWN.
         if(proposedStop >= OrderOpenPrice())                        continue;
         if(currentStop > 0.0 && proposedStop > currentStop - trailStep) continue;
      }

      if(!OrderModify(OrderTicket(), OrderOpenPrice(), proposedStop,
                      OrderTakeProfit(), 0, clrAqua))
      {
         int errorCode = GetLastError();
         PrintFormat("Trailing stop update failed on ticket %d: error %d (%s).",
                     OrderTicket(), errorCode, ErrorDescription(errorCode));
      }
   }
}

//====================================================================
// SECTION 10 - ERROR HANDLING UTILITIES
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
