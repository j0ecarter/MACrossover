//+------------------------------------------------------------------+
//|                                                 CandleTimer.mq4   |
//|                                                                   |
//|  Draws a "candle closes in MM:SS" label on the chart.             |
//|                                                                   |
//|  WHY THIS EXISTS                                                  |
//|    MACrossover only makes decisions when a bar CLOSES, so knowing |
//|    how long that is away is the difference between watching the   |
//|    chart usefully and watching it blankly.                        |
//|                                                                   |
//|  THE ONE INTERESTING PROBLEM                                      |
//|    The obvious implementation counts down from TimeCurrent().     |
//|    That is the timestamp of the last quote the broker sent, NOT   |
//|    a live clock - so in a quiet market the countdown freezes for  |
//|    seconds at a time and then jumps. Overnight it can look        |
//|    completely stuck.                                              |
//|                                                                   |
//|    Instead, this samples the gap between server time and the PC   |
//|    clock whenever a tick arrives, then counts down using the PC   |
//|    clock plus that gap. The PC clock always advances, so the      |
//|    display is smooth, and each tick re-anchors it to the server   |
//|    so it cannot drift.                                            |
//+------------------------------------------------------------------+
#property copyright "Joe"
#property version   "1.00"
#property strict
#property indicator_chart_window

//====================================================================
// INPUTS
//====================================================================

input string  InpSectionPosition   = "--- Position ---";
input ENUM_BASE_CORNER InpCorner   = CORNER_LEFT_UPPER;  // Which corner to anchor to
input int     InpXDistance         = 12;    // Pixels from that corner, horizontally
input int     InpYDistance         = 95;    // Pixels from that corner, vertically
                                            // (95 clears the one-click trading panel)

input string  InpSectionAppearance = "--- Appearance ---";
input string  InpFontName          = "Consolas";  // A monospaced font stops the label jittering
input int     InpFontSize          = 11;
input bool    InpAutoContrastColour = true; // Pick black or white to suit the chart background
input color   InpNormalColour      = clrSilver;   // Used only when auto-contrast is off
input color   InpWarningColour     = clrGold;     // Used inside the warning window
input color   InpImminentColour    = clrTomato;   // Used in the final few seconds
input int     InpWarningSeconds    = 60;    // Switch to the warning colour below this
input int     InpImminentSeconds   = 10;    // Switch to the imminent colour below this

input string  InpSectionText       = "--- Text ---";
input string  InpLabelPrefix       = "Candle closes in ";
input bool    InpShowTimeframe     = true;  // Prefix the timeframe, e.g. "M5 | "

//====================================================================
// GLOBAL STATE
//====================================================================

// Chart object name. Prefixed so it cannot collide with objects drawn
// by other indicators, and so OnDeinit knows exactly what to remove.
string   g_labelName = "CandleTimer_Label";

// Server time minus local PC time, in seconds. Re-sampled on every
// tick. See the header comment for why this matters.
int      g_serverMinusLocalSeconds = 0;

// Set true once a tick has been seen, so we do not count down from a
// clock offset we have not measured yet.
bool     g_haveClockOffset = false;

//====================================================================
// LIFECYCLE
//====================================================================

//+------------------------------------------------------------------+
//| Create the label and start a one-second timer.                    |
//|                                                                   |
//| The timer is what makes this tick over smoothly. Without it the   |
//| label would only update when a price tick arrived.                |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!CreateLabel())
   {
      Print("CandleTimer: could not create the chart label. Error ", GetLastError());
      return(INIT_FAILED);
    }

   // Seed the offset immediately so the first render is sensible even
   // before any tick arrives.
   g_serverMinusLocalSeconds = (int)(TimeCurrent() - TimeLocal());
   g_haveClockOffset = true;

   EventSetTimer(1);
   UpdateLabel();

   Print("CandleTimer attached to ", Symbol(), " ", TimeframeToText(Period()),
         ". Label at corner ", EnumToString(InpCorner),
         ", offset ", InpXDistance, "x", InpYDistance,
         ", colour ", (InpAutoContrastColour ? "auto-contrast" : "fixed"), ".");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Tidy up. Leaving objects behind on the chart is bad manners and   |
//| they accumulate every time the indicator is reloaded.             |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectDelete(0, g_labelName);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Called once a second by the timer set in OnInit.                  |
//+------------------------------------------------------------------+
void OnTimer()
{
   UpdateLabel();
}

//+------------------------------------------------------------------+
//| Called on every tick. Used only to re-anchor the clock offset -   |
//| this indicator draws nothing from price data.                     |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   g_serverMinusLocalSeconds = (int)(TimeCurrent() - TimeLocal());
   g_haveClockOffset = true;

   UpdateLabel();

   return(rates_total);
}

//====================================================================
// DRAWING
//====================================================================

//+------------------------------------------------------------------+
//| Create the text label object, or reuse it if it already exists.   |
//+------------------------------------------------------------------+
bool CreateLabel()
{
   if(ObjectFind(0, g_labelName) < 0)
   {
      if(!ObjectCreate(0, g_labelName, OBJ_LABEL, 0, 0, 0))
         return(false);
   }

   ObjectSetInteger(0, g_labelName, OBJPROP_CORNER,     InpCorner);
   ObjectSetInteger(0, g_labelName, OBJPROP_XDISTANCE,  InpXDistance);
   ObjectSetInteger(0, g_labelName, OBJPROP_YDISTANCE,  InpYDistance);
   ObjectSetString (0, g_labelName, OBJPROP_FONT,       InpFontName);
   ObjectSetInteger(0, g_labelName, OBJPROP_FONTSIZE,   InpFontSize);
   ObjectSetInteger(0, g_labelName, OBJPROP_COLOR,      InpNormalColour);

   // The user should not be able to grab this with the mouse, and it
   // should not clutter the object list they actually work with.
   ObjectSetInteger(0, g_labelName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, g_labelName, OBJPROP_SELECTED,   false);
   ObjectSetInteger(0, g_labelName, OBJPROP_HIDDEN,     true);
   ObjectSetInteger(0, g_labelName, OBJPROP_BACK,       false);

   return(true);
}

//+------------------------------------------------------------------+
//| Work out how long is left and repaint the label.                  |
//+------------------------------------------------------------------+
void UpdateLabel()
{
   int secondsRemaining = SecondsUntilBarCloses();

   string text = InpLabelPrefix + FormatDuration(secondsRemaining);

   if(InpShowTimeframe)
      text = TimeframeToText(Period()) + " | " + text;

   // Market closed, or the clock has gone somewhere strange.
   if(secondsRemaining < 0)
      text = (InpShowTimeframe ? TimeframeToText(Period()) + " | " : "") + "market closed";

   ObjectSetString (0, g_labelName, OBJPROP_TEXT,  text);
   ObjectSetInteger(0, g_labelName, OBJPROP_COLOR, ColourForRemaining(secondsRemaining));

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Seconds until the current bar closes, or -1 if that cannot be     |
//| determined sensibly.                                              |
//|                                                                   |
//| Time[0] is the OPEN time of the bar currently forming, so the     |
//| close time is that plus one bar's worth of seconds.               |
//+------------------------------------------------------------------+
int SecondsUntilBarCloses()
{
   if(Bars < 1 || !g_haveClockOffset)
      return(-1);

   int barLengthSeconds = Period() * 60;   // Period() is in minutes
   datetime barCloseTime = Time[0] + barLengthSeconds;

   // Estimated server time, built from the PC clock so it advances
   // every second rather than only when a quote arrives.
   datetime estimatedServerNow = (datetime)(TimeLocal() + g_serverMinusLocalSeconds);

   int remaining = (int)(barCloseTime - estimatedServerNow);

   // A large negative value means no new bar has formed for longer
   // than a whole bar - the market is closed, or the feed has stopped.
   if(remaining < -barLengthSeconds)
      return(-1);

   // Small negative values are just the moment between the bar
   // expiring and the new one arriving. Show zero rather than flicker.
   if(remaining < 0)
      return(0);

   return(remaining);
}

//+------------------------------------------------------------------+
//| Colour the label by urgency.                                      |
//+------------------------------------------------------------------+
color ColourForRemaining(int secondsRemaining)
{
   color normalColour = InpAutoContrastColour ? ContrastingTextColour() : InpNormalColour;

   if(secondsRemaining < 0)                     return(normalColour);
   if(secondsRemaining <= InpImminentSeconds)   return(InpImminentColour);
   if(secondsRemaining <= InpWarningSeconds)    return(InpWarningColour);
   return(normalColour);
}

//+------------------------------------------------------------------+
//| Black or white, whichever is readable against the chart's own     |
//| background colour.                                                |
//|                                                                   |
//| A fixed light-grey label is invisible on MT4's pale default       |
//| scheme and a fixed black one is invisible on a dark scheme, so    |
//| neither is a safe default. MQL colours are packed 0x00BBGGRR;     |
//| the weights below are the standard perceived-luminance ones,      |
//| green counting for most because the eye is most sensitive to it.  |
//+------------------------------------------------------------------+
color ContrastingTextColour()
{
   int backgroundColour = (int)ChartGetInteger(0, CHART_COLOR_BACKGROUND);

   int redChannel   =  backgroundColour        & 0xFF;
   int greenChannel = (backgroundColour >> 8)  & 0xFF;
   int blueChannel  = (backgroundColour >> 16) & 0xFF;

   double perceivedLuminance = 0.299 * redChannel
                             + 0.587 * greenChannel
                             + 0.114 * blueChannel;

   return(perceivedLuminance > 140.0 ? clrBlack : clrWhite);
}

//+------------------------------------------------------------------+
//| Seconds as MM:SS, or H:MM:SS once past an hour.                   |
//+------------------------------------------------------------------+
string FormatDuration(int totalSeconds)
{
   if(totalSeconds < 0)
      return("--:--");

   int hours   = totalSeconds / 3600;
   int minutes = (totalSeconds % 3600) / 60;
   int seconds = totalSeconds % 60;

   if(hours > 0)
      return(IntegerToString(hours) + ":" +
             PadTwoDigits(minutes)  + ":" +
             PadTwoDigits(seconds));

   return(PadTwoDigits(minutes) + ":" + PadTwoDigits(seconds));
}

//+------------------------------------------------------------------+
//| Zero-pad a number to two digits, so the label does not change     |
//| width as the digits change.                                       |
//+------------------------------------------------------------------+
string PadTwoDigits(int value)
{
   if(value < 10)
      return("0" + IntegerToString(value));

   return(IntegerToString(value));
}

//+------------------------------------------------------------------+
//| Readable timeframe name.                                          |
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
//+------------------------------------------------------------------+
