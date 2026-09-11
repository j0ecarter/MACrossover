//+------------------------------------------------------------------+
//|                                                FleetMonitor.mq4   |
//|                                                      version 1.00 |
//|                                                                   |
//|  Shows, on one chart, whether every EA and indicator you expect   |
//|  to be running actually is.                                       |
//|                                                                   |
//|  WHY THIS IS NOT TRIVIAL IN MT4                                   |
//|    An EA on one chart cannot see an EA on another. MT4 exposes no |
//|    process list, no "what is attached where" API, nothing. The    |
//|    only shared state between charts in a terminal is the          |
//|    GlobalVariable pool, so that is what this uses:                |
//|                                                                   |
//|      every component writes  MACX_<SYMBOL>_<TF>_<ROLE>_HB         |
//|      every few seconds, and  MACX_<SYMBOL>_<TF>_<ROLE>_ST         |
//|      alongside it carrying a status bitmask.                      |
//|                                                                   |
//|    This monitor reads them back and compares against the list of  |
//|    components you say you expect. Absent means never loaded;      |
//|    present but stale means loaded and then stopped responding.    |
//|                                                                   |
//|  THE CLOCK TRAP                                                   |
//|    The obvious heartbeat value is TimeCurrent(). It is wrong.     |
//|    TimeCurrent() is the timestamp of the last quote received, so  |
//|    in a quiet market it stops advancing and a perfectly healthy   |
//|    EA reads as dead. Heartbeats therefore carry TimeLocal() - the |
//|    PC clock, which always advances - and are driven by a timer    |
//|    rather than by incoming ticks.                                 |
//|                                                                   |
//|  EXPECTED-COMPONENTS FORMAT                                       |
//|    Comma-separated SYMBOL:TIMEFRAME:ROLE, for example             |
//|      GBPUSD:M5:EA,EURUSD:M5:EA,GBPUSD:M5:CandleTimer             |
//|    Roles are whatever the components publish - "EA" for           |
//|    MACrossover, "CandleTimer" for the countdown indicator.        |
//+------------------------------------------------------------------+
#property copyright "Joe"
#property version   "1.00"
#property strict
#property indicator_chart_window

//====================================================================
// INPUTS
//====================================================================

input string  InpSectionFleet      = "--- What should be running ---";
input string  InpExpectedComponents = "GBPUSD:M5:EA,EURUSD:M5:EA";
input int     InpStaleSeconds      = 30;   // No heartbeat for this long = stalled
input bool    InpShowUnexpected    = true; // Also list components you did NOT declare

input string  InpSectionPosition   = "--- Position ---";
input ENUM_BASE_CORNER InpCorner   = CORNER_LEFT_UPPER;
input int     InpXDistance         = 12;
input int     InpYDistance         = 134;  // Clear of the one-click panel and CandleTimer's backdrop

input string  InpSectionAppearance = "--- Appearance ---";
input string  InpFontName          = "Consolas";
input int     InpFontSize          = 10;
input int     InpLineSpacing       = 15;   // Pixels between rows
input int     InpRefreshSeconds    = 2;

input string  InpSectionPanel      = "--- Background panel ---";
input bool    InpShowPanel         = true;              // Solid backdrop behind the text
input color   InpPanelColour       = C'22,26,34';       // Dark slate
input color   InpPanelBorderColour = C'74,84,100';
input int     InpPanelOpacity      = 75;   // 100 = solid, lower = more of the chart shows through
input int     InpPanelPadding      = 8;    // Pixels of margin inside the panel
input int     InpPanelExtraWidth   = 0;    // Nudge the auto-width if it misjudges

input string  InpSectionColours    = "--- Text colours ---";
input bool    InpAutoContrastColour = true;             // Match neutral text to the backdrop
input color   InpNeutralColour     = clrWhite;          // Used when auto-contrast is off
input color   InpOkColour          = clrSpringGreen;
input color   InpWarnColour        = clrGold;
input color   InpFailColour        = clrTomato;

//====================================================================
// STATUS BITS
//--------------------------------------------------------------------
// Must match the definitions in MACrossover.mq4. A component reports
// these so the monitor can distinguish "running fine" from "running,
// but unable to do its job" - which look identical from a heartbeat
// alone and are very different things to a person.
//====================================================================

#define STATUS_OK              0
#define STATUS_TRADE_DISABLED  1    // Terminal or broker forbids trading
#define STATUS_DISCONNECTED    2    // No connection to the trade server
#define STATUS_COOLDOWN        4    // Paused after consecutive losses
#define STATUS_DAILY_CAP       8    // Daily loss cap reached
#define STATUS_OUT_OF_SESSION  16   // Outside the configured trading hours
#define STATUS_UNPROTECTED     32   // A position is open with no stop loss

#define MAX_DISPLAY_LINES      24
#define GLOBAL_PREFIX          "MACX_"

//====================================================================
// STATE
//====================================================================

string g_objectPrefix = "FleetMon_";

// Widest line and number of lines rendered on the last refresh, used
// to size the backdrop. Measured in characters - safe only because
// the default font is monospaced, which is why Consolas is the
// default and why changing it may need InpPanelExtraWidth.
int    g_widestLineChars = 0;
int    g_renderedLines   = 0;

//====================================================================
// LIFECYCLE
//====================================================================

int OnInit()
{
   if(InpStaleSeconds < 5)
   {
      Print("FleetMonitor: InpStaleSeconds below 5 will produce false alarms. ",
            "Components only heartbeat every few seconds.");
   }

   // The backdrop must exist BEFORE the first text label. MT4 draws
   // chart objects in creation order, so a panel created later would
   // paint over the very text it is meant to sit behind.
   EnsureBackgroundPanel();

   EventSetTimer(MathMax(1, InpRefreshSeconds));
   RefreshPanel();

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   RemoveAllPanelObjects();
   ChartRedraw();
}

void OnTimer()
{
   RefreshPanel();
}

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
   // The timer drives the display. Ticks are irrelevant here - which
   // is the point, since a dead feed is exactly when you most want
   // this panel to keep updating.
   return(rates_total);
}

//====================================================================
// THE CHECK
//====================================================================

//+------------------------------------------------------------------+
//| Build the GlobalVariable name a component publishes under.        |
//| This convention is shared with MACrossover.mq4 and               |
//| CandleTimer.mq4 - change it in one place and you must change it   |
//| in all three.                                                     |
//+------------------------------------------------------------------+
string HeartbeatName(string symbolName, string timeframeText, string role)
{
   return(GLOBAL_PREFIX + symbolName + "_" + timeframeText + "_" + role + "_HB");
}

string StatusName(string symbolName, string timeframeText, string role)
{
   return(GLOBAL_PREFIX + symbolName + "_" + timeframeText + "_" + role + "_ST");
}

//+------------------------------------------------------------------+
//| Seconds since a component last reported in, or -1 if it never has.|
//+------------------------------------------------------------------+
int SecondsSinceHeartbeat(string heartbeatName)
{
   if(!GlobalVariableCheck(heartbeatName))
      return(-1);

   datetime lastSeen = (datetime)GlobalVariableGet(heartbeatName);

   if(lastSeen <= 0)
      return(-1);

   int age = (int)(TimeLocal() - lastSeen);

   // A negative age means the writing terminal's clock is ahead of
   // ours, which should be impossible within one terminal. Treat it
   // as fresh rather than reporting nonsense.
   return(age < 0 ? 0 : age);
}

//+------------------------------------------------------------------+
//| Turn a status bitmask into a short human-readable tag list.       |
//+------------------------------------------------------------------+
string DescribeStatusFlags(int flags)
{
   if(flags == STATUS_OK)
      return("");

   string description = "";

   if((flags & STATUS_DISCONNECTED)   != 0) description += "disconnected, ";
   if((flags & STATUS_TRADE_DISABLED) != 0) description += "AutoTrading off, ";
   if((flags & STATUS_UNPROTECTED)    != 0) description += "NO STOP LOSS, ";
   if((flags & STATUS_DAILY_CAP)      != 0) description += "daily cap hit, ";
   if((flags & STATUS_COOLDOWN)       != 0) description += "cooldown, ";
   if((flags & STATUS_OUT_OF_SESSION) != 0) description += "out of session, ";

   // Trim the trailing separator.
   if(StringLen(description) > 2)
      description = StringSubstr(description, 0, StringLen(description) - 2);

   return(description);
}

//+------------------------------------------------------------------+
//| Do any of these flags mean something is actually broken, as       |
//| opposed to merely idle by design?                                 |
//|                                                                   |
//| Being outside the session window or in a cooldown is the EA doing |
//| its job. Being disconnected, having trading disabled, or holding  |
//| an unprotected position is not.                                   |
//+------------------------------------------------------------------+
bool FlagsIndicateProblem(int flags)
{
   int problemMask = STATUS_DISCONNECTED | STATUS_TRADE_DISABLED | STATUS_UNPROTECTED;
   return((flags & problemMask) != 0);
}

//====================================================================
// RENDERING
//====================================================================

//+------------------------------------------------------------------+
//| Rebuild the whole panel.                                          |
//+------------------------------------------------------------------+
void RefreshPanel()
{
   g_widestLineChars = 0;
   g_renderedLines   = 0;

   string expectedEntries[];
   int    expectedCount = SplitExpectedComponents(expectedEntries);

   int runningCount  = 0;
   int problemCount  = 0;
   int lineIndex     = 1;     // Line 0 is the header.

   string seenNames = "|";    // Track what we matched, for the unexpected scan.

   for(int i = 0; i < expectedCount && lineIndex < MAX_DISPLAY_LINES; i++)
   {
      string entry = expectedEntries[i];
      if(StringLen(entry) == 0)
         continue;

      string symbolName, timeframeText, role;
      if(!ParseComponentEntry(entry, symbolName, timeframeText, role))
      {
         SetPanelLine(lineIndex++, "  ? " + entry + "  (unreadable entry)", InpFailColour);
         problemCount++;
         continue;
      }

      string hbName = HeartbeatName(symbolName, timeframeText, role);
      seenNames += hbName + "|";

      int age = SecondsSinceHeartbeat(hbName);

      string label = "  " + PadRight(symbolName + " " + timeframeText + " " + role, 26);

      if(age < 0)
      {
         SetPanelLine(lineIndex++, label + "NOT LOADED", InpFailColour);
         problemCount++;
         continue;
      }

      if(age > InpStaleSeconds)
      {
         SetPanelLine(lineIndex++, label + "STALLED (" + FormatAge(age) + " ago)", InpFailColour);
         problemCount++;
         continue;
      }

      // Heartbeat is fresh. Now ask what it is actually able to do.
      int flags = (int)GlobalVariableGet(StatusName(symbolName, timeframeText, role));
      string flagText = DescribeStatusFlags(flags);

      runningCount++;

      if(FlagsIndicateProblem(flags))
      {
         SetPanelLine(lineIndex++, label + "RUNNING - " + flagText, InpWarnColour);
         problemCount++;
      }
      else if(StringLen(flagText) > 0)
      {
         SetPanelLine(lineIndex++, label + "RUNNING (" + flagText + ")", NeutralTextColour());
      }
      else
      {
         SetPanelLine(lineIndex++, label + "RUNNING", InpOkColour);
      }
   }

   // --- Anything heartbeating that we were not told to expect ------
   // Catches the opposite failure: an EA left running on a chart you
   // have forgotten about, quietly trading an account.
   if(InpShowUnexpected)
      lineIndex = AppendUnexpectedComponents(seenNames, lineIndex);

   // --- Header ------------------------------------------------------
   string headerText;
   color  headerColour;

   if(expectedCount == 0)
   {
      headerText   = "FLEET  |  nothing declared in InpExpectedComponents";
      headerColour = InpWarnColour;
   }
   else if(runningCount == 0)
   {
      headerText   = "FLEET  |  NO COMPONENTS RUNNING  (0/" + IntegerToString(expectedCount) + ")";
      headerColour = InpFailColour;
   }
   else if(problemCount > 0)
   {
      headerText   = "FLEET  |  NOT ALL RUNNING  (" + IntegerToString(runningCount)
                   + "/" + IntegerToString(expectedCount) + ")";
      headerColour = InpFailColour;
   }
   else
   {
      headerText   = "FLEET  |  ALL RUNNING  (" + IntegerToString(runningCount)
                   + "/" + IntegerToString(expectedCount) + ")";
      headerColour = InpOkColour;
   }

   SetPanelLine(0, headerText, headerColour);

   // --- Terminal-wide conditions -----------------------------------
   // These sit below the list because they affect every component at
   // once, so reading them per-row would just be repetition.
   if(lineIndex < MAX_DISPLAY_LINES)
   {
      string terminalState = "  terminal: "
                           + (IsConnected()      ? "connected" : "DISCONNECTED")
                           + ", AutoTrading "
                           + (IsExpertEnabled()  ? "on" : "OFF")
                           + "  |  " + TimeToString(TimeLocal(), TIME_SECONDS);

      color terminalColour = (IsConnected() && IsExpertEnabled())
                           ? NeutralTextColour() : InpFailColour;

      SetPanelLine(lineIndex++, terminalState, terminalColour);
   }

   // Blank any rows left over from a previous, longer render. These
   // deliberately do not count towards the panel size.
   for(int blank = lineIndex; blank < MAX_DISPLAY_LINES; blank++)
      SetPanelLine(blank, "", NeutralTextColour());

   ResizeBackgroundPanel();

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| List heartbeating components that are not in the expected list.   |
//+------------------------------------------------------------------+
int AppendUnexpectedComponents(string seenNames, int lineIndex)
{
   for(int i = 0; i < GlobalVariablesTotal() && lineIndex < MAX_DISPLAY_LINES; i++)
   {
      string name = GlobalVariableName(i);

      if(StringFind(name, GLOBAL_PREFIX) != 0)         continue;   // Not ours.
      if(StringLen(name) < 4)                          continue;
      if(StringSubstr(name, StringLen(name) - 3) != "_HB") continue;  // Status var, skip.
      if(StringFind(seenNames, "|" + name + "|") >= 0) continue;   // Already listed.

      int age = SecondsSinceHeartbeat(name);
      if(age < 0 || age > InpStaleSeconds)
         continue;   // Only report ones that are actually alive right now.

      // Strip the prefix and suffix back to something readable.
      string readable = StringSubstr(name, StringLen(GLOBAL_PREFIX));
      readable = StringSubstr(readable, 0, StringLen(readable) - 3);

      SetPanelLine(lineIndex++, "  " + PadRight(readable, 26) + "RUNNING - not declared",
                   InpWarnColour);
   }

   return(lineIndex);
}

//+------------------------------------------------------------------+
//| Split the expected-components input into individual entries.      |
//+------------------------------------------------------------------+
int SplitExpectedComponents(string &entries[])
{
   string raw = InpExpectedComponents;
   StringTrimLeft(raw);
   StringTrimRight(raw);

   if(StringLen(raw) == 0)
   {
      ArrayResize(entries, 0);
      return(0);
   }

   int count = StringSplit(raw, StringGetCharacter(",", 0), entries);

   for(int i = 0; i < count; i++)
   {
      StringTrimLeft(entries[i]);
      StringTrimRight(entries[i]);
   }

   return(count);
}

//+------------------------------------------------------------------+
//| Parse SYMBOL:TIMEFRAME:ROLE. Role defaults to EA when omitted.    |
//+------------------------------------------------------------------+
bool ParseComponentEntry(string entry, string &symbolName,
                         string &timeframeText, string &role)
{
   string parts[];
   int count = StringSplit(entry, StringGetCharacter(":", 0), parts);

   if(count < 2)
      return(false);

   symbolName    = parts[0];
   timeframeText = parts[1];
   role          = (count >= 3) ? parts[2] : "EA";

   StringTrimLeft(symbolName);    StringTrimRight(symbolName);
   StringTrimLeft(timeframeText); StringTrimRight(timeframeText);
   StringTrimLeft(role);          StringTrimRight(role);

   return(StringLen(symbolName) > 0 && StringLen(timeframeText) > 0);
}

//+------------------------------------------------------------------+
//| Create or update one row of the panel.                            |
//+------------------------------------------------------------------+
void SetPanelLine(int lineIndex, string text, color textColour)
{
   string objectName = g_objectPrefix + IntegerToString(lineIndex);

   if(ObjectFind(0, objectName) < 0)
   {
      if(!ObjectCreate(0, objectName, OBJ_LABEL, 0, 0, 0))
         return;

      ObjectSetInteger(0, objectName, OBJPROP_CORNER,     InpCorner);
      ObjectSetString (0, objectName, OBJPROP_FONT,       InpFontName);
      ObjectSetInteger(0, objectName, OBJPROP_FONTSIZE,   InpFontSize);
      ObjectSetInteger(0, objectName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, objectName, OBJPROP_SELECTED,   false);
      ObjectSetInteger(0, objectName, OBJPROP_HIDDEN,     true);
      ObjectSetInteger(0, objectName, OBJPROP_BACK,       false);
   }

   ObjectSetInteger(0, objectName, OBJPROP_XDISTANCE, InpXDistance);
   ObjectSetInteger(0, objectName, OBJPROP_YDISTANCE, InpYDistance + lineIndex * InpLineSpacing);
   ObjectSetString (0, objectName, OBJPROP_TEXT,      text);
   ObjectSetInteger(0, objectName, OBJPROP_COLOR,     textColour);

   // Remember the extent of the real content, for the backdrop.
   if(StringLen(text) > 0)
   {
      if(StringLen(text) > g_widestLineChars)
         g_widestLineChars = StringLen(text);

      if(lineIndex + 1 > g_renderedLines)
         g_renderedLines = lineIndex + 1;
   }
}

//+------------------------------------------------------------------+
//| Remove every object this indicator owns.                          |
//+------------------------------------------------------------------+
void RemoveAllPanelObjects()
{
   for(int i = 0; i < MAX_DISPLAY_LINES; i++)
      ObjectDelete(0, g_objectPrefix + IntegerToString(i));

   ObjectDelete(0, g_objectPrefix + "BG");
}

//+------------------------------------------------------------------+
//| Create the solid backdrop the text sits on.                       |
//|                                                                   |
//| Without it the chart's grid lines run straight through the        |
//| glyphs. Thin coloured text over a dotted grid is legible in a     |
//| screenshot and genuinely hard to read at a glance, which defeats  |
//| the point of a status panel you are supposed to be able to check  |
//| without concentrating.                                            |
//+------------------------------------------------------------------+
void EnsureBackgroundPanel()
{
   if(!InpShowPanel)
      return;

   string objectName = g_objectPrefix + "BG";

   if(ObjectFind(0, objectName) < 0)
   {
      if(!ObjectCreate(0, objectName, OBJ_RECTANGLE_LABEL, 0, 0, 0))
         return;
   }

   ObjectSetInteger(0, objectName, OBJPROP_CORNER,      InpCorner);
   ObjectSetInteger(0, objectName, OBJPROP_BGCOLOR,     BlendTowardsChart(InpPanelColour, InpPanelOpacity));
   ObjectSetInteger(0, objectName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, objectName, OBJPROP_COLOR,       BlendTowardsChart(InpPanelBorderColour, InpPanelOpacity));
   ObjectSetInteger(0, objectName, OBJPROP_WIDTH,       1);
   ObjectSetInteger(0, objectName, OBJPROP_SELECTABLE,  false);
   ObjectSetInteger(0, objectName, OBJPROP_SELECTED,    false);
   ObjectSetInteger(0, objectName, OBJPROP_HIDDEN,      true);
   ObjectSetInteger(0, objectName, OBJPROP_BACK,        false);
}

//+------------------------------------------------------------------+
//| Fit the backdrop to whatever was just rendered.                   |
//|                                                                   |
//| Character width is estimated at 0.62 x the font size, which is    |
//| about right for Consolas. A proportional font will misjudge it -  |
//| InpPanelExtraWidth exists for that case.                          |
//+------------------------------------------------------------------+
void ResizeBackgroundPanel()
{
   if(!InpShowPanel)
      return;

   string objectName = g_objectPrefix + "BG";

   if(ObjectFind(0, objectName) < 0)
      EnsureBackgroundPanel();

   int estimatedCharWidth = (int)MathCeil(InpFontSize * 0.62);

   int panelWidth  = g_widestLineChars * estimatedCharWidth
                   + InpPanelPadding * 2 + InpPanelExtraWidth;
   int panelHeight = g_renderedLines * InpLineSpacing + InpPanelPadding * 2;

   if(panelWidth  < 80) panelWidth  = 80;
   if(panelHeight < 30) panelHeight = 30;

   ObjectSetInteger(0, objectName, OBJPROP_XDISTANCE, MathMax(0, InpXDistance - InpPanelPadding));
   ObjectSetInteger(0, objectName, OBJPROP_YDISTANCE, MathMax(0, InpYDistance - InpPanelPadding));
   ObjectSetInteger(0, objectName, OBJPROP_XSIZE,     panelWidth);
   ObjectSetInteger(0, objectName, OBJPROP_YSIZE,     panelHeight);

   // Re-apply on every refresh, so changing the chart theme or the
   // opacity input takes effect without reloading the indicator.
   ObjectSetInteger(0, objectName, OBJPROP_BGCOLOR, BlendTowardsChart(InpPanelColour, InpPanelOpacity));
   ObjectSetInteger(0, objectName, OBJPROP_COLOR,   BlendTowardsChart(InpPanelBorderColour, InpPanelOpacity));
}

//+------------------------------------------------------------------+
//| Neutral text colour, contrast-matched to the chart background.    |
//| A fixed light grey is invisible on MT4's pale default scheme and  |
//| a fixed black is invisible on a dark one, so neither is safe.     |
//+------------------------------------------------------------------+
color NeutralTextColour()
{
   if(!InpAutoContrastColour)
      return(InpNeutralColour);

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
//| Pad to a fixed width so the status column lines up. Relies on the |
//| font being monospaced, which is why Consolas is the default.      |
//+------------------------------------------------------------------+
string PadRight(string text, int width)
{
   string padded = text;

   while(StringLen(padded) < width)
      padded += " ";

   return(padded);
}

//+------------------------------------------------------------------+
//| Seconds as a compact human duration.                              |
//+------------------------------------------------------------------+
string FormatAge(int seconds)
{
   if(seconds < 60)
      return(IntegerToString(seconds) + "s");

   if(seconds < 3600)
      return(IntegerToString(seconds / 60) + "m");

   return(IntegerToString(seconds / 3600) + "h");
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
