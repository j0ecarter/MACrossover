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
//|                                                                   |
//|  NOT MONITORED BY FLEETMONITOR                                    |
//|    This indicator deliberately publishes no heartbeat. It draws a |
//|    label and nothing else - if it stops, you can see that it has  |
//|    stopped by looking at the chart. Monitoring it added three     |
//|    inputs and a GlobalVariable for no information you did not      |
//|    already have, and it cluttered the fleet panel with rows that  |
//|    could never tell you anything useful.                          |
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
input bool    InpAutoContrastColour = true; // Match the text to whatever it sits on
input color   InpNormalColour      = clrWhite;    // Used only when auto-contrast is off
input color   InpWarningColour     = clrGold;     // Used inside the warning window
input color   InpImminentColour    = clrTomato;   // Used in the final few seconds

input string  InpSectionPanel      = "--- Background panel ---";
input bool    InpShowPanel         = true;              // Solid backdrop behind the text
input color   InpPanelColour       = C'22,26,34';       // Dark slate
input color   InpPanelBorderColour = C'74,84,100';
input int     InpPanelOpacity      = 75;   // 100 = solid, lower = more of the chart shows through
input int     InpPanelPadding      = 7;    // Pixels of margin inside the panel
input int     InpPanelExtraWidth   = 0;    // Nudge the auto-width if it misjudges
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
string   g_panelName = "CandleTimer_Panel";

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
   // The backdrop has to exist before the text label. MT4 draws chart
   // objects in creation order, so a panel created afterwards would
   // paint straight over the text it is meant to sit behind.
   CreateBackgroundPanel();

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
   ObjectDelete(0, g_panelName);

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

   ResizeBackgroundPanel(StringLen(text));

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Create the solid backdrop the countdown sits on.                  |
//|                                                                   |
//| Without it the chart's grid lines run through the glyphs. Thin    |
//| coloured text over a dotted grid is hard to read at a glance,     |
//| which defeats the point of something you check in passing.        |
//+------------------------------------------------------------------+
void CreateBackgroundPanel()
{
   if(!InpShowPanel)
      return;

   if(ObjectFind(0, g_panelName) < 0)
   {
      if(!ObjectCreate(0, g_panelName, OBJ_RECTANGLE_LABEL, 0, 0, 0))
         return;
   }

   ObjectSetInteger(0, g_panelName, OBJPROP_CORNER,      InpCorner);
   ObjectSetInteger(0, g_panelName, OBJPROP_BGCOLOR,     BlendTowardsChart(InpPanelColour, InpPanelOpacity));
   ObjectSetInteger(0, g_panelName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, g_panelName, OBJPROP_COLOR,       BlendTowardsChart(InpPanelBorderColour, InpPanelOpacity));
   ObjectSetInteger(0, g_panelName, OBJPROP_WIDTH,       1);
   ObjectSetInteger(0, g_panelName, OBJPROP_SELECTABLE,  false);
   ObjectSetInteger(0, g_panelName, OBJPROP_SELECTED,    false);
   ObjectSetInteger(0, g_panelName, OBJPROP_HIDDEN,      true);
   ObjectSetInteger(0, g_panelName, OBJPROP_BACK,        false);
}

//+------------------------------------------------------------------+
//| Fit the backdrop to the current text.                             |
//|                                                                   |
//| Character width is estimated at 0.62 x the font size, about right |
//| for Consolas. A proportional font will misjudge it, which is what |
//| InpPanelExtraWidth is for.                                        |
//+------------------------------------------------------------------+
void ResizeBackgroundPanel(int textLengthChars)
{
   if(!InpShowPanel)
      return;

   if(ObjectFind(0, g_panelName) < 0)
      CreateBackgroundPanel();

   int estimatedCharWidth = (int)MathCeil(InpFontSize * 0.62);

   int panelWidth  = textLengthChars * estimatedCharWidth
                   + InpPanelPadding * 2 + InpPanelExtraWidth;
   int panelHeight = (int)MathCeil(InpFontSize * 1.6) + InpPanelPadding * 2;

   if(panelWidth < 60) panelWidth = 60;

   ObjectSetInteger(0, g_panelName, OBJPROP_XDISTANCE, MathMax(0, InpXDistance - InpPanelPadding));
   ObjectSetInteger(0, g_panelName, OBJPROP_YDISTANCE, MathMax(0, InpYDistance - InpPanelPadding));
   ObjectSetInteger(0, g_panelName, OBJPROP_XSIZE,     panelWidth);
   ObjectSetInteger(0, g_panelName, OBJPROP_YSIZE,     panelHeight);

   // Re-applied every second, so a chart theme change or an opacity
   // tweak takes effect without reloading the indicator.
   ObjectSetInteger(0, g_panelName, OBJPROP_BGCOLOR, BlendTowardsChart(InpPanelColour, InpPanelOpacity));
   ObjectSetInteger(0, g_panelName, OBJPROP_COLOR,   BlendTowardsChart(InpPanelBorderColour, InpPanelOpacity));
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
   // What the text actually sits on: the panel when there is one,
   // otherwise the chart itself.
   int backgroundColour = InpShowPanel
                        ? (int)BlendTowardsChart(InpPanelColour, InpPanelOpacity)
                        : (int)ChartGetInteger(0, CHART_COLOR_BACKGROUND);

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

//+------------------------------------------------------------------+
//| The panel colour, mixed towards the chart's own background.       |
//|                                                                   |
//| MT4 chart objects have no alpha channel - OBJPROP_BGCOLOR is a    |
//| flat opaque colour and there is no way to make a rectangle label  |
//| genuinely see-through. So rather than fake transparency, this     |
//| blends the panel colour with the chart background, which reads as |
//| a tint instead of a slab.                                         |
//|                                                                   |
//| Worth being clear that this is not merely the available option,   |
//| it is the correct one: the panel exists to stop the chart grid    |
//| running through the text. Genuine transparency would bring that   |
//| problem straight back.                                            |
//|                                                                   |
//| MQL colours are packed 0x00BBGGRR, hence the channel order.       |
//+------------------------------------------------------------------+
color BlendTowardsChart(color foreground, int opacityPercent)
{
   if(opacityPercent >= 100)
      return(foreground);

   if(opacityPercent <= 0)
      return((color)ChartGetInteger(0, CHART_COLOR_BACKGROUND));

   int front = (int)foreground;
   int back  = (int)ChartGetInteger(0, CHART_COLOR_BACKGROUND);

   double weight = opacityPercent / 100.0;

   int red   = (int)MathRound(( front        & 0xFF) * weight + ( back        & 0xFF) * (1.0 - weight));
   int green = (int)MathRound(((front >> 8)  & 0xFF) * weight + ((back >> 8)  & 0xFF) * (1.0 - weight));
   int blue  = (int)MathRound(((front >> 16) & 0xFF) * weight + ((back >> 16) & 0xFF) * (1.0 - weight));

   red   = (int)MathMax(0, MathMin(255, red));
   green = (int)MathMax(0, MathMin(255, green));
   blue  = (int)MathMax(0, MathMin(255, blue));

   return((color)(blue * 65536 + green * 256 + red));
}
//+------------------------------------------------------------------+
