#property strict

#include <Trade/Trade.mqh>
CTrade trade;

/*
   TJR_Framework_EA_fully_commented.mq5

   PURPOSE OF THIS EA
   -----------------------------------------------------------------------------
   This Expert Advisor is a student style, rule based interpretation of the
   strategy described in the supplied TJR transcript.

   It does NOT claim to be:
   - an official TJR strategy file
   - a perfect translation of discretionary trading
   - proof that the strategy is profitable

   It DOES try to do the following:
   - convert spoken strategy ideas into explicit code rules
   - make every decision in the transcript measurable and testable
   - provide a transparent implementation that can be discussed in a thesis

   CORE STRATEGY IDEA FROM THE TRANSCRIPT
   -----------------------------------------------------------------------------
   1) Mark higher timeframe liquidity / key levels.
   2) Wait for price to hit / sweep one of those levels.
   3) On a lower timeframe, wait for reversal evidence.
   4) Then wait for continuation from a continuation confluence.
   5) Enter in the direction of the new move.
   6) Put the stop beyond the reversal leg extreme.
   7) Target opposite higher timeframe liquidity.

   IMPORTANT ADAPTATION FOR THIS THESIS VERSION
   -----------------------------------------------------------------------------
   The original transcript talks about session highs/lows such as London and
   Asia. In this thesis version those are intentionally NOT used because the
   dataset setup does not support them in a clean, reliable way.

   Therefore this EA uses these higher timeframe references instead:
   - previous day regular session high/low (used as a session proxy)
   - H1 highs/lows
   - H4 highs/lows

   THESIS POSITIONING
   -----------------------------------------------------------------------------
   The correct way to present this file in a bachelor thesis is:

   "This EA is a formalized student interpretation of the verbal strategy rules
   described in the transcript. Some concepts that are discretionary in the
   original explanation, such as BOS, inverse FVG, order block, breaker block,
   and Fibonacci 79% confirmation, had to be translated into deterministic
   program rules."
*/

// =============================================================================
// STATE MACHINE
// =============================================================================
// The EA runs as a small state machine.
//
// STATE_IDLE
//    No active setup. We are waiting for price to sweep a higher timeframe level.
//
// STATE_WAIT_REVERSAL
//    A key level has been swept. Now we wait for a lower timeframe reversal.
//
// STATE_WAIT_CONTINUATION
//    Reversal has been found. Now we wait for continuation from EQ / FVG /
//    order block / breaker block before entering.
// =============================================================================
enum SetupState
{
   STATE_IDLE = 0,
   STATE_WAIT_REVERSAL = 1,
   STATE_WAIT_CONTINUATION = 2
};

// =============================================================================
// INPUTS
// =============================================================================
// These inputs make the EA configurable while keeping the logic readable.
// =============================================================================

// -----------------------------------------------------------------------------
// Risk sizing
// -----------------------------------------------------------------------------
// RiskPercent
//    Percent of current account balance risked per trade attempt.
//
// MaxLots
//    Hard cap so the EA never exceeds a chosen size even if the stop is tiny.
// -----------------------------------------------------------------------------
input double RiskPercent = 2.0;
input double MaxLots     = 100.0;

// -----------------------------------------------------------------------------
// Lower timeframe for reversal / continuation logic
// -----------------------------------------------------------------------------
// The transcript says TJR commonly uses 1 minute or 5 minute charts.
// This EA lets the user choose that timeframe.
// -----------------------------------------------------------------------------
input ENUM_TIMEFRAMES EntryTF = PERIOD_M1;

// -----------------------------------------------------------------------------
// Trading window in New York time (ET)
// -----------------------------------------------------------------------------
// The user's testing is built around New York open style logic.
// We therefore define one daily trading window in ET.
// -----------------------------------------------------------------------------
input int ET_UTC_OffsetHours = -5;
input int TradeStartHour     = 8;
input int TradeStartMinute   = 30;
input int TradeEndHour       = 16;
input int TradeEndMinute     = 0;

// -----------------------------------------------------------------------------
// Higher timeframe liquidity references
// -----------------------------------------------------------------------------
// UsePrevDayHighLow
//    Uses the previous regular session high/low as a session proxy.
//
// UseH1Levels / UseH4Levels
//    Adds highs and lows from previous H1/H4 candles.
//
// H1_LevelCount / H4_LevelCount
//    Controls how many previous candles are harvested.
//    This is an implementation choice because the transcript does not give an
//    exact number.
// -----------------------------------------------------------------------------
input bool UsePrevDayHighLow = true;
input bool UseH1Levels       = true;
input bool UseH4Levels       = true;
input int  H1_LevelCount     = 3;
input int  H4_LevelCount     = 2;

// -----------------------------------------------------------------------------
// Avoid clutter from nearly identical levels
// -----------------------------------------------------------------------------
// If two levels of the same type are extremely close, keep only one.
// -----------------------------------------------------------------------------
input int  MinLevelSpacingPoints = 50;

// -----------------------------------------------------------------------------
// Sweep / execution tuning
// -----------------------------------------------------------------------------
// SweepBufferPoints
//    Price must move beyond a level by at least this distance to count as a
//    proper sweep.
//
// SLBufferPoints
//    Extra distance added beyond the leg extreme when setting stop loss.
//
// DeviationPoints
//    Slippage tolerance for CTrade execution.
//
// MaxSpreadPoints
//    Safety filter: do not enter if spread is too high.
// -----------------------------------------------------------------------------
input int SweepBufferPoints = 5;
input int SLBufferPoints    = 5;
input int DeviationPoints   = 20;
input int MaxSpreadPoints   = 40;

// -----------------------------------------------------------------------------
// Reversal confluences mentioned in transcript
// -----------------------------------------------------------------------------
// BOS, inverse FVG, Fibonacci 79% close.
// -----------------------------------------------------------------------------
input bool UseBOS_Reversal   = true;
input bool UseIFVG_Reversal  = true;
input bool UseFib79_Reversal = true;

input int  BOS_LookbackBars       = 5;
input int  MaxWaitBarsForReversal = 120;

// -----------------------------------------------------------------------------
// Continuation confluences mentioned in transcript
// -----------------------------------------------------------------------------
// EQ, FVG, order block, breaker block.
// -----------------------------------------------------------------------------
input bool UseEQ_Continuation      = true;
input bool UseFVG_Continuation     = true;
input bool UseOB_Continuation      = true;
input bool UseBreaker_Continuation = true;

input int  MaxWaitBarsForContinuation = 120;
input int  ScanBarsFVG                 = 120;

// -----------------------------------------------------------------------------
// Fallback target if no opposite liquidity exists above/below entry
// -----------------------------------------------------------------------------
input int DefaultRR_TP = 3;

// -----------------------------------------------------------------------------
// TJR says he usually wants the first key level hit and is not a fan of taking
// repeated later day trades. This input keeps that behavior.
// -----------------------------------------------------------------------------
input bool OneTradePerDay = true;

// -----------------------------------------------------------------------------
// Force close before end of session. This is mainly a backtest / engineering
// choice, not a direct transcript rule.
// -----------------------------------------------------------------------------
input bool ForceCloseAtTradeEnd = true;

// -----------------------------------------------------------------------------
// Print debug messages to tester journal.
// -----------------------------------------------------------------------------
input bool PrintDebug = true;

// =============================================================================
// DATA STRUCTURES
// =============================================================================

// -----------------------------------------------------------------------------
// Level
// -----------------------------------------------------------------------------
// Represents one higher timeframe liquidity reference.
//
// price
//    Price of the level.
//
// isHigh
//    true  -> level is above highs, so sweeping it is bearish context
//    false -> level is below lows, so sweeping it is bullish context
//
// swept
//    Once a level has been used, it is marked as swept so the same exact level
//    is not repeatedly re-used that day.
// -----------------------------------------------------------------------------
struct Level
{
   double price;
   bool   isHigh;
   bool   swept;
};

// -----------------------------------------------------------------------------
// Zone
// -----------------------------------------------------------------------------
// Generic price area used for FVG / order block / breaker block zones.
// -----------------------------------------------------------------------------
struct Zone
{
   double low;
   double high;
   bool   valid;
};

// =============================================================================
// GLOBAL VARIABLES
// =============================================================================

// Dynamic list of higher timeframe liquidity levels for the current ET day.
Level    levels[];

// Current ET day start and session boundaries expressed in server time.
datetime g_etDayStart     = 0;
datetime g_tradeStartSrv  = 0;
datetime g_tradeEndSrv    = 0;

// Used so the EA only acts once per newly closed bar on the entry timeframe.
datetime lastClosedBarProcessed = 0;

// Current setup state from the state machine.
SetupState state = STATE_IDLE;

// -----------------------------------------------------------------------------
// Sweep / setup context
// -----------------------------------------------------------------------------
// setupLong
//    true  -> we want to trade long
//    false -> we want to trade short
//
// sweepLevelPrice
//    Which higher timeframe level was swept.
//
// sweepTimeSrv
//    When that sweep was detected.
//
// reversalTimeSrv
//    When reversal confirmation happened.
// -----------------------------------------------------------------------------
bool      setupLong       = false;
double    sweepLevelPrice = 0.0;
datetime  sweepTimeSrv    = 0;
datetime  reversalTimeSrv = 0;

// How many closed bars we have waited since sweep or reversal.
int       barsSinceSweep    = 0;
int       barsSinceReversal = 0;

// If true, no new setup is allowed later the same day.
bool      daySetupConsumed = false;

// -----------------------------------------------------------------------------
// Reversal leg extremes
// -----------------------------------------------------------------------------
// These are critical because they define:
// - stop placement
// - equilibrium
// - continuation context
// -----------------------------------------------------------------------------
double legHigh = 0.0;
double legLow  = 0.0;

// -----------------------------------------------------------------------------
// Continuation framework
// -----------------------------------------------------------------------------
double equilibrium = 0.0;
Zone   zFvg;
Zone   zOb;
Zone   zBreaker;

// Stored mainly for clarity / debugging so the journal can show which bar
// touched the continuation area.
double   continuationTouchLow  = 0.0;
double   continuationTouchHigh = 0.0;
datetime continuationTouchTime = 0;
string   continuationSource    = "";

// -----------------------------------------------------------------------------
// Manual trade management
// -----------------------------------------------------------------------------
// Because this thesis setup uses a custom symbol and manual testing logic, the
// EA manages stop and target internally after entry rather than relying only on
// broker side SL/TP behavior.
// -----------------------------------------------------------------------------
bool   g_managePosition = false;
bool   g_posLong        = false;
double g_posSL          = 0.0;
double g_posTP          = 0.0;

// =============================================================================
// TIME HELPERS
// =============================================================================

// Returns the current server offset from UTC in whole hours.
int GetServerUTCOffsetHours()
{
   datetime srv = TimeTradeServer();
   datetime gmt = TimeGMT();
   return (int)MathRound((double)(srv - gmt) / 3600.0);
}

// Builds a datetime value from components.
datetime MakeTime(int y,int mo,int d,int h,int mi,int s)
{
   MqlDateTime t;
   t.year = y;
   t.mon  = mo;
   t.day  = d;
   t.hour = h;
   t.min  = mi;
   t.sec  = s;
   return StructToTime(t);
}

// Convert server time to ET.
datetime ServerToET(datetime serverTime)
{
   int srvOff = GetServerUTCOffsetHours();
   datetime gmt = serverTime - srvOff * 3600;
   return gmt + ET_UTC_OffsetHours * 3600;
}

// Convert ET to server time.
datetime ETToServer(datetime etTime)
{
   int srvOff = GetServerUTCOffsetHours();
   datetime gmt = etTime - ET_UTC_OffsetHours * 3600;
   return gmt + srvOff * 3600;
}

// Returns midnight of the current ET day.
datetime GetETDayStart(datetime serverNow)
{
   datetime etNow = ServerToET(serverNow);
   MqlDateTime d;
   TimeToStruct(etNow, d);
   return MakeTime(d.year, d.mon, d.day, 0, 0, 0);
}

// Returns today's trade start and end times in server time.
void GetTradeWindowBounds(datetime serverNow, datetime &startSrv, datetime &endSrv)
{
   datetime etNow = ServerToET(serverNow);
   MqlDateTime d;
   TimeToStruct(etNow, d);

   datetime startET = MakeTime(d.year, d.mon, d.day, TradeStartHour, TradeStartMinute, 0);
   datetime endET   = MakeTime(d.year, d.mon, d.day, TradeEndHour,   TradeEndMinute,   0);

   if(endET <= startET)
      endET += 86400;

   startSrv = ETToServer(startET);
   endSrv   = ETToServer(endET);
}

// True only while current server time is inside the chosen ET trading window.
bool InTradeWindow(datetime serverNow)
{
   datetime startSrv, endSrv;
   GetTradeWindowBounds(serverNow, startSrv, endSrv);
   return (serverNow >= startSrv && serverNow <= endSrv);
}

// =============================================================================
// MARKET / PRICE HELPERS
// =============================================================================

// Returns true if the symbol currently has an open position.
bool HasOpenPosition()
{
   return PositionSelect(_Symbol);
}

// Returns the most recently CLOSED bar on a timeframe.
// r[0] would be the active bar, so we intentionally use r[1].
bool GetLastClosedBar(MqlRates &bar, ENUM_TIMEFRAMES tf)
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, tf, 0, 2, r) != 2)
      return false;

   bar = r[1];
   return true;
}

// Convenience function returning the time of the most recently closed bar.
datetime GetLastClosedBarTime(ENUM_TIMEFRAMES tf)
{
   MqlRates bar;
   if(!GetLastClosedBar(bar, tf))
      return 0;
   return bar.time;
}

// Returns the symbol tick size.
double GetTickSize()
{
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0.0)
      ts = _Point;
   return ts;
}

// Rounds a raw price to the nearest tradable tick.
double NormalizePrice(double price)
{
   double ts = GetTickSize();
   if(ts <= 0.0)
      ts = _Point;

   return NormalizeDouble(MathRound(price / ts) * ts, _Digits);
}

// Reads bid/ask and normalizes them.
// If live quote values are missing in tester, it falls back to the last close.
void GetNormalizedBidAsk(double &bid, double &ask)
{
   double rawBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double rawAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(rawBid <= 0.0 && rawAsk <= 0.0)
   {
      MqlRates c;
      if(GetLastClosedBar(c, EntryTF))
      {
         rawBid = c.close;
         rawAsk = c.close;
      }
   }
   else if(rawBid <= 0.0)
   {
      rawBid = rawAsk;
   }
   else if(rawAsk <= 0.0)
   {
      rawAsk = rawBid;
   }

   // Just in case quote ordering is inverted in tester edge cases.
   if(rawAsk < rawBid)
   {
      double tmp = rawAsk;
      rawAsk = rawBid;
      rawBid = tmp;
   }

   bid = NormalizePrice(rawBid);
   ask = NormalizePrice(rawAsk);
}

// Returns current spread in points.
double CurrentSpreadPoints()
{
   double bid, ask;
   GetNormalizedBidAsk(bid, ask);
   if(bid <= 0.0 || ask <= 0.0)
      return 0.0;
   return (ask - bid) / _Point;
}

// Finds the first closed bar shift on a timeframe before a specific time.
// This is useful when we want H1/H4 bars that existed before today's session.
int GetFirstClosedShiftBeforeTime(ENUM_TIMEFRAMES tf, datetime whenSrv)
{
   int shift = iBarShift(_Symbol, tf, whenSrv, false);
   if(shift < 0)
      return -1;

   datetime barOpen = iTime(_Symbol, tf, shift);
   int sec = PeriodSeconds(tf);
   if(sec <= 0)
      sec = 60;

   // If the bar is still active at whenSrv, step one bar further back.
   if(barOpen + sec > whenSrv)
      shift++;

   return shift;
}

// =============================================================================
// STATE RESET HELPERS
// =============================================================================

// Clears all manual position tracking variables.
void ResetManagedPositionPlan()
{
   g_managePosition = false;
   g_posLong = false;
   g_posSL = 0.0;
   g_posTP = 0.0;
}

// Clears all setup state so the EA can look for a new setup.
void ResetState()
{
   state = STATE_IDLE;
   setupLong = false;
   sweepLevelPrice = 0.0;
   sweepTimeSrv = 0;
   reversalTimeSrv = 0;
   barsSinceSweep = 0;
   barsSinceReversal = 0;

   legHigh = 0.0;
   legLow  = 0.0;
   equilibrium = 0.0;

   zFvg.low = 0.0;
   zFvg.high = 0.0;
   zFvg.valid = false;

   zOb.low = 0.0;
   zOb.high = 0.0;
   zOb.valid = false;

   zBreaker.low = 0.0;
   zBreaker.high = 0.0;
   zBreaker.valid = false;

   continuationTouchLow  = 0.0;
   continuationTouchHigh = 0.0;
   continuationTouchTime = 0;
   continuationSource    = "";
}

// =============================================================================
// LEVEL MANAGEMENT
// =============================================================================

// Adds a new higher timeframe level to the levels array.
void AddLevel(double price, bool isHigh)
{
   if(price <= 0.0)
      return;

   Level L;
   L.price = NormalizePrice(price);
   L.isHigh = isHigh;
   L.swept = false;

   int n = ArraySize(levels);
   ArrayResize(levels, n + 1);
   levels[n] = L;
}

// Removes near duplicate levels of the same type.
void DedupLevels()
{
   double eps = (double)MinLevelSpacingPoints * _Point;
   if(eps < 2.0 * _Point)
      eps = 2.0 * _Point;

   for(int i=0; i<ArraySize(levels); i++)
   {
      if(levels[i].price <= 0.0)
         continue;

      for(int j=i+1; j<ArraySize(levels); j++)
      {
         if(levels[j].price <= 0.0)
            continue;

         if(levels[i].isHigh != levels[j].isHigh)
            continue;

         if(MathAbs(levels[i].price - levels[j].price) <= eps)
            levels[j].price = 0.0;
      }
   }

   // Compact the array by keeping only non-zero levels.
   Level tmp[];
   ArrayResize(tmp, 0);

   for(int i=0; i<ArraySize(levels); i++)
   {
      if(levels[i].price <= 0.0)
         continue;

      int n = ArraySize(tmp);
      ArrayResize(tmp, n + 1);
      tmp[n] = levels[i];
   }

   ArrayResize(levels, ArraySize(tmp));
   for(int i=0; i<ArraySize(tmp); i++)
      levels[i] = tmp[i];
}

// Builds today's list of higher timeframe liquidity levels.
void BuildLevelsForToday()
{
   ArrayResize(levels, 0);

   datetime nowSrv = TimeCurrent();
   g_etDayStart = GetETDayStart(nowSrv);
   GetTradeWindowBounds(nowSrv, g_tradeStartSrv, g_tradeEndSrv);

   // --------------------------------------------------------------------------
   // 1) Previous day high / low
   // --------------------------------------------------------------------------
   // In the original transcript, TJR uses session highs/lows. Because this
   // thesis version intentionally excludes Asia/London sessions, the previous
   // regular session high/low is used as the session proxy.
   // --------------------------------------------------------------------------
   if(UsePrevDayHighLow)
   {
      datetime prevStartSrv = g_tradeStartSrv - 86400;
      datetime prevEndSrv   = g_tradeEndSrv   - 86400;

      MqlRates m1[];
      int copied = CopyRates(_Symbol, PERIOD_M1, prevStartSrv, prevEndSrv, m1);

      double hi = -DBL_MAX;
      double lo =  DBL_MAX;

      for(int i=0; i<copied; i++)
      {
         if(m1[i].high > hi) hi = m1[i].high;
         if(m1[i].low  < lo) lo = m1[i].low;
      }

      if(hi > -DBL_MAX && lo < DBL_MAX)
      {
         AddLevel(hi, true);
         AddLevel(lo, false);
      }
   }

   // --------------------------------------------------------------------------
   // 2) H1 highs/lows
   // --------------------------------------------------------------------------
   if(UseH1Levels)
   {
      int h1Shift = GetFirstClosedShiftBeforeTime(PERIOD_H1, g_tradeStartSrv);
      if(h1Shift >= 0)
      {
         for(int k=0; k<H1_LevelCount; k++)
         {
            int idx = h1Shift + k;
            double hi = iHigh(_Symbol, PERIOD_H1, idx);
            double lo = iLow(_Symbol,  PERIOD_H1, idx);
            if(hi > 0.0) AddLevel(hi, true);
            if(lo > 0.0) AddLevel(lo, false);
         }
      }
   }

   // --------------------------------------------------------------------------
   // 3) H4 highs/lows
   // --------------------------------------------------------------------------
   if(UseH4Levels)
   {
      int h4Shift = GetFirstClosedShiftBeforeTime(PERIOD_H4, g_tradeStartSrv);
      if(h4Shift >= 0)
      {
         for(int k=0; k<H4_LevelCount; k++)
         {
            int idx = h4Shift + k;
            double hi = iHigh(_Symbol, PERIOD_H4, idx);
            double lo = iLow(_Symbol,  PERIOD_H4, idx);
            if(hi > 0.0) AddLevel(hi, true);
            if(lo > 0.0) AddLevel(lo, false);
         }
      }
   }

   DedupLevels();
   ResetState();
   daySetupConsumed = false;
   lastClosedBarProcessed = GetLastClosedBarTime(EntryTF);

   if(PrintDebug)
      Print(TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
            " New ET day. Levels=", ArraySize(levels));
}

// =============================================================================
// SWEEP DETECTION
// =============================================================================

// Checks whether the latest closed bar swept one of the stored higher timeframe
// levels.
//
// If a HIGH is swept, we prepare a SHORT setup.
// If a LOW is swept, we prepare a LONG setup.
bool DetectSweepOnClosedBar(const MqlRates &bar, bool &outLongSetup, double &outLevelPrice)
{
   if(ArraySize(levels) <= 0)
      return false;

   double buf = (double)SweepBufferPoints * _Point;

   for(int i=0; i<ArraySize(levels); i++)
   {
      if(levels[i].swept)
         continue;

      // Sweep above a higher timeframe high -> bearish setup candidate.
      if(levels[i].isHigh)
      {
         if(bar.high >= levels[i].price + buf)
         {
            levels[i].swept = true;
            outLongSetup = false;
            outLevelPrice = levels[i].price;
            return true;
         }
      }
      // Sweep below a higher timeframe low -> bullish setup candidate.
      else
      {
         if(bar.low <= levels[i].price - buf)
         {
            levels[i].swept = true;
            outLongSetup = true;
            outLevelPrice = levels[i].price;
            return true;
         }
      }
   }

   return false;
}

// =============================================================================
// REVERSAL LOGIC HELPERS
// =============================================================================

// Highest high among previous N bars in a local window.
double HighestHighPrevN(const MqlRates &rates[], int startIndex, int count)
{
   double hh = -DBL_MAX;
   for(int i=startIndex; i<startIndex+count; i++)
      if(rates[i].high > hh) hh = rates[i].high;
   return hh;
}

// Lowest low among previous N bars in a local window.
double LowestLowPrevN(const MqlRates &rates[], int startIndex, int count)
{
   double ll = DBL_MAX;
   for(int i=startIndex; i<startIndex+count; i++)
      if(rates[i].low < ll) ll = rates[i].low;
   return ll;
}

// Simple candle direction helpers.
bool CandleBullish(const MqlRates &c) { return (c.close > c.open); }
bool CandleBearish(const MqlRates &c) { return (c.close < c.open); }

// -----------------------------------------------------------------------------
// BOS reversal
// -----------------------------------------------------------------------------
// Student interpretation:
// - after sweeping lows, if price closes above recent structure, it counts as a
//   bullish reversal signal
// - after sweeping highs, if price closes below recent structure, it counts as
//   a bearish reversal signal
// -----------------------------------------------------------------------------
bool ReversalByBOS(bool wantLong, datetime &bosBarTime)
{
   int need = BOS_LookbackBars + 3;
   MqlRates r[];
   ArraySetAsSeries(r, true);

   if(CopyRates(_Symbol, EntryTF, 0, need, r) < need)
      return false;

   MqlRates lastClosed = r[1];
   double hh = HighestHighPrevN(r, 2, BOS_LookbackBars);
   double ll = LowestLowPrevN(r, 2, BOS_LookbackBars);

   if(wantLong)
   {
      if(lastClosed.close > hh)
      {
         bosBarTime = lastClosed.time;
         return true;
      }
   }
   else
   {
      if(lastClosed.close < ll)
      {
         bosBarTime = lastClosed.time;
         return true;
      }
   }

   return false;
}

// -----------------------------------------------------------------------------
// FVG finder
// -----------------------------------------------------------------------------
// Finds the most recent fair value gap in the requested direction.
//
// bullish = true
//    look for bullish FVG: bar1.high < bar3.low
//
// bullish = false
//    look for bearish FVG: bar1.low > bar3.high
// -----------------------------------------------------------------------------
bool FindMostRecentFVG(Zone &outGap, bool bullish)
{
   outGap.low = 0.0;
   outGap.high = 0.0;
   outGap.valid = false;

   int need = MathMax(30, ScanBarsFVG);
   MqlRates r[];
   ArraySetAsSeries(r, true);

   int got = CopyRates(_Symbol, EntryTF, 1, need, r);
   if(got < 10)
      return false;

   // Scan from older to newer.
   for(int s=got-1; s>=2; s--)
   {
      MqlRates b1 = r[s];
      MqlRates b3 = r[s-2];

      if(bullish)
      {
         if(b1.high < b3.low)
         {
            outGap.low = b1.high;
            outGap.high = b3.low;
            outGap.valid = true;
         }
      }
      else
      {
         if(b1.low > b3.high)
         {
            outGap.low = b3.high;
            outGap.high = b1.low;
            outGap.valid = true;
         }
      }
   }

   return outGap.valid;
}

// -----------------------------------------------------------------------------
// Inverse FVG reversal
// -----------------------------------------------------------------------------
// Student interpretation of transcript:
// - if we want longs, look for a bearish FVG that gets invalidated upward
// - if we want shorts, look for a bullish FVG that gets invalidated downward
// -----------------------------------------------------------------------------
bool ReversalByIFVG(bool wantLong, datetime &sigTime)
{
   Zone gap;

   if(wantLong)
   {
      if(!FindMostRecentFVG(gap, false))
         return false;
   }
   else
   {
      if(!FindMostRecentFVG(gap, true))
         return false;
   }

   MqlRates lastClosed;
   if(!GetLastClosedBar(lastClosed, EntryTF))
      return false;

   if(wantLong)
   {
      if(gap.valid && lastClosed.close > gap.high)
      {
         sigTime = lastClosed.time;
         return true;
      }
   }
   else
   {
      if(gap.valid && lastClosed.close < gap.low)
      {
         sigTime = lastClosed.time;
         return true;
      }
   }

   return false;
}

// -----------------------------------------------------------------------------
// Compute sweep-to-reversal leg extremes
// -----------------------------------------------------------------------------
// This is a very important function because the resulting legHigh / legLow are
// used for:
// - stop placement
// - equilibrium
// - continuation context
// - Fib 79% calculation
// -----------------------------------------------------------------------------
bool ComputeLegExtremes(datetime fromSrv, datetime toSrv, double &outHi, double &outLo)
{
   if(toSrv <= fromSrv)
      return false;

   MqlRates r[];
   int copied = CopyRates(_Symbol, EntryTF, fromSrv, toSrv, r);
   if(copied <= 0)
      return false;

   outHi = -DBL_MAX;
   outLo =  DBL_MAX;

   for(int i=0; i<copied; i++)
   {
      if(r[i].high > outHi) outHi = r[i].high;
      if(r[i].low  < outLo) outLo = r[i].low;
   }

   return (outHi > -DBL_MAX && outLo < DBL_MAX && outHi > outLo);
}

// -----------------------------------------------------------------------------
// Fibonacci 79% reversal
// -----------------------------------------------------------------------------
// Student interpretation:
// use the sweep-to-reversal leg and require a close beyond the 79% level in the
// direction of the reversal.
// -----------------------------------------------------------------------------
bool ReversalByFib79(bool wantLong, double hi, double lo, datetime &sigTime)
{
   if(hi <= lo)
      return false;

   double thrLong  = lo + 0.79 * (hi - lo);
   double thrShort = hi - 0.79 * (hi - lo);

   MqlRates lastClosed;
   if(!GetLastClosedBar(lastClosed, EntryTF))
      return false;

   if(wantLong)
   {
      if(lastClosed.close > thrLong)
      {
         sigTime = lastClosed.time;
         return true;
      }
   }
   else
   {
      if(lastClosed.close < thrShort)
      {
         sigTime = lastClosed.time;
         return true;
      }
   }

   return false;
}

// =============================================================================
// CONTINUATION ZONES
// =============================================================================

// Returns true if a candle overlaps a given price zone.
bool TouchesZone(const MqlRates &c, const Zone &z)
{
   if(!z.valid)
      return false;
   return (c.low <= z.high && c.high >= z.low);
}

// Builds continuation confluence areas after reversal has been confirmed.
void BuildContinuationZones(bool wantLong, datetime reversalSignalTime)
{
   // Equilibrium = midpoint of reversal leg.
   equilibrium = (legHigh + legLow) * 0.5;

   // --------------------------------------------------------------------------
   // FVG continuation zone in the new direction
   // --------------------------------------------------------------------------
   zFvg.low = 0.0; zFvg.high = 0.0; zFvg.valid = false;
   if(UseFVG_Continuation)
   {
      Zone gap;
      if(FindMostRecentFVG(gap, wantLong) && gap.valid)
         zFvg = gap;
   }

   zOb.low = 0.0; zOb.high = 0.0; zOb.valid = false;
   zBreaker.low = 0.0; zBreaker.high = 0.0; zBreaker.valid = false;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int got = CopyRates(_Symbol, EntryTF, 1, 200, r);
   if(got < 10)
      return;

   // --------------------------------------------------------------------------
   // Order block approximation
   // --------------------------------------------------------------------------
   // For longs:
   //    last bearish candle before bullish reversal/displacement
   // For shorts:
   //    last bullish candle before bearish reversal/displacement
   // --------------------------------------------------------------------------
   if(UseOB_Continuation)
   {
      for(int i=got-1; i>=0; i--)
      {
         if(r[i].time > reversalSignalTime)
            continue;

         if(wantLong && CandleBearish(r[i]))
         {
            zOb.low = r[i].low;
            zOb.high = r[i].high;
            zOb.valid = true;
            break;
         }

         if(!wantLong && CandleBullish(r[i]))
         {
            zOb.low = r[i].low;
            zOb.high = r[i].high;
            zOb.valid = true;
            break;
         }
      }
   }

   // --------------------------------------------------------------------------
   // Breaker block approximation
   // --------------------------------------------------------------------------
   if(UseBreaker_Continuation)
   {
      for(int i=got-1; i>=1; i--)
      {
         MqlRates a = r[i];
         MqlRates b = r[i-1];

         if(b.time > reversalSignalTime)
            continue;

         if(wantLong)
         {
            if(CandleBearish(a) && CandleBullish(b) && b.close > a.high)
            {
               zBreaker.low = a.low;
               zBreaker.high = a.high;
               zBreaker.valid = true;
               break;
            }
         }
         else
         {
            if(CandleBullish(a) && CandleBearish(b) && b.close < a.low)
            {
               zBreaker.low = a.low;
               zBreaker.high = a.high;
               zBreaker.valid = true;
               break;
            }
         }
      }
   }
}

// -----------------------------------------------------------------------------
// Continuation confirmation
// -----------------------------------------------------------------------------
// Student interpretation:
// - price must retrace into one continuation confluence area
// - the same closed bar must also close in the intended direction
//
// This is not meant to perfectly reproduce discretionary trading. It is meant
// to create one explicit, repeatable coding rule from the transcript.
// -----------------------------------------------------------------------------
bool ContinuationConfirmed(bool wantLong, datetime &signalBarTime)
{
   MqlRates lastClosed;
   if(!GetLastClosedBar(lastClosed, EntryTF))
      return false;

   bool touched = false;
   string source = "";

   // Equilibrium touch
   if(UseEQ_Continuation)
   {
      bool touchedEq = false;
      if(wantLong)
         touchedEq = (lastClosed.low <= equilibrium);
      else
         touchedEq = (lastClosed.high >= equilibrium);

      if(touchedEq)
      {
         touched = true;
         source = "EQ";
      }
   }

   // FVG touch
   if(!touched && UseFVG_Continuation && zFvg.valid && TouchesZone(lastClosed, zFvg))
   {
      touched = true;
      source = "FVG";
   }

   // Order block touch
   if(!touched && UseOB_Continuation && zOb.valid && TouchesZone(lastClosed, zOb))
   {
      touched = true;
      source = "OB";
   }

   // Breaker touch
   if(!touched && UseBreaker_Continuation && zBreaker.valid && TouchesZone(lastClosed, zBreaker))
   {
      touched = true;
      source = "BREAKER";
   }

   if(!touched)
      return false;

   // Save touch info so the logs explain what happened.
   continuationTouchLow  = lastClosed.low;
   continuationTouchHigh = lastClosed.high;
   continuationTouchTime = lastClosed.time;
   continuationSource    = source;

   if(PrintDebug)
      Print(TimeToString(lastClosed.time, TIME_DATE|TIME_SECONDS),
            " CONTINUATION TOUCH source=", source);

   // Directional close requirement.
   // Long continuation must close bullish.
   // Short continuation must close bearish.
   if(wantLong && !CandleBullish(lastClosed))
      return false;
   if(!wantLong && !CandleBearish(lastClosed))
      return false;

   signalBarTime = lastClosed.time;
   return true;
}

// =============================================================================
// TARGETING AND LOT SIZING
// =============================================================================

// Finds the nearest opposite direction liquidity level.
//
// If we are long -> target nearest high above entry.
// If we are short -> target nearest low below entry.
double FindNearestTP(bool wantLong, double entryPrice)
{
   double best = 0.0;

   if(wantLong)
   {
      double minAbove = DBL_MAX;
      for(int i=0; i<ArraySize(levels); i++)
      {
         if(!levels[i].isHigh)
            continue;
         if(levels[i].price <= entryPrice)
            continue;
         if(levels[i].price < minAbove)
            minAbove = levels[i].price;
      }
      if(minAbove < DBL_MAX)
         best = minAbove;
   }
   else
   {
      double maxBelow = -DBL_MAX;
      for(int i=0; i<ArraySize(levels); i++)
      {
         if(levels[i].isHigh)
            continue;
         if(levels[i].price >= entryPrice)
            continue;
         if(levels[i].price > maxBelow)
            maxBelow = levels[i].price;
      }
      if(maxBelow > -DBL_MAX)
         best = maxBelow;
   }

   return best;
}

// Converts one price unit of movement into money per lot.
double MoneyPerPriceUnitPerLot()
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0.0 || tickSize <= 0.0)
      return 0.0;

   return tickValue / tickSize;
}

// Rounds lot size down to broker volume step and respects min/max limits.
double NormalizeLotsToStep(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(stepLot <= 0.0)
      stepLot = 1.0;

   lots = MathFloor(lots / stepLot) * stepLot;
   lots = MathMax(minLot, lots);
   lots = MathMin(maxLot, lots);
   lots = MathMin(MaxLots, lots);
   return lots;
}

// Calculates lot size using BOTH risk cap and margin cap.
// This prevents "not enough money" errors from earlier versions.
double CalcLotsByRiskAndMargin(bool wantLong, double entry, double sl)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (RiskPercent / 100.0);

   double slDist = MathAbs(entry - sl);
   if(slDist <= 0.0)
      return 0.0;

   double moneyPerUnit = MoneyPerPriceUnitPerLot();
   if(moneyPerUnit <= 0.0)
      return 0.0;

   double riskPerLot = slDist * moneyPerUnit;
   if(riskPerLot <= 0.0)
      return 0.0;

   // Size allowed by risk.
   double lotsByRisk = riskAmount / riskPerLot;

   // Size allowed by margin.
   double marginPerLot = 0.0;
   ENUM_ORDER_TYPE ordType = wantLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if(!OrderCalcMargin(ordType, _Symbol, 1.0, entry, marginPerLot) || marginPerLot <= 0.0)
   {
      // Fallback approximation for exchange-stock style custom symbols.
      double contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      if(contract <= 0.0)
         contract = 1.0;
      marginPerLot = entry * contract;
   }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(freeMargin <= 0.0)
      freeMargin = balance;

   double lotsByMargin = freeMargin / marginPerLot;

   // Small haircut avoids edge cases where rounding causes rejection.
   lotsByMargin *= 0.98;

   double lots = MathMin(lotsByRisk, lotsByMargin);
   lots = NormalizeLotsToStep(lots);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lots < minLot)
      return 0.0;

   return lots;
}

// =============================================================================
// POSITION MANAGEMENT
// =============================================================================

// Force closes the current position and resets manual management state.
bool ForceClosePosition(string why)
{
   if(!HasOpenPosition())
      return false;

   bool ok = trade.PositionClose(_Symbol, DeviationPoints);

   if(PrintDebug)
   {
      if(ok)
         Print("FORCED EXIT ", why);
      else
         Print("FORCED EXIT FAILED: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }

   if(ok)
      ResetManagedPositionPlan();

   return ok;
}

// Handles manual stop loss / take profit exits for the currently open trade.
void ManageOpenPosition(datetime nowSrv)
{
   if(!HasOpenPosition())
   {
      ResetManagedPositionPlan();
      return;
   }

   // Close in the last tradable minute of the session if requested.
   int sec = PeriodSeconds(EntryTF);
   if(sec <= 0)
      sec = 60;

   datetime finalCloseCutoff = g_tradeEndSrv - sec;

   if(ForceCloseAtTradeEnd && nowSrv >= finalCloseCutoff)
   {
      ForceClosePosition("last in-session minute");
      return;
   }

   if(!g_managePosition)
      return;

   double bid, ask;
   GetNormalizedBidAsk(bid, ask);

   bool closeNow = false;
   string why = "";

   if(g_posLong)
   {
      if(bid <= g_posSL)
      {
         closeNow = true;
         why = "manual SL";
      }
      else if(bid >= g_posTP)
      {
         closeNow = true;
         why = "manual TP";
      }
   }
   else
   {
      if(ask >= g_posSL)
      {
         closeNow = true;
         why = "manual SL";
      }
      else if(ask <= g_posTP)
      {
         closeNow = true;
         why = "manual TP";
      }
   }

   if(!closeNow)
      return;

   bool ok = trade.PositionClose(_Symbol, DeviationPoints);

   if(PrintDebug)
   {
      if(ok)
         Print("MANUAL EXIT ", why,
               " bid=", DoubleToString(bid, _Digits),
               " ask=", DoubleToString(ask, _Digits),
               " plannedSL=", DoubleToString(g_posSL, _Digits),
               " plannedTP=", DoubleToString(g_posTP, _Digits));
      else
         Print("MANUAL EXIT FAILED: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }

   if(ok)
      ResetManagedPositionPlan();
}

// =============================================================================
// ENTRY LOGIC
// =============================================================================

// Attempts to enter a trade after continuation has been confirmed.
bool TryEnterTrade()
{
   if(HasOpenPosition())
      return false;

   // Basic spread filter.
   double sprPts = CurrentSpreadPoints();
   if(sprPts > (double)MaxSpreadPoints)
   {
      if(PrintDebug)
         Print("SKIP entry: spread too high sprPts=", DoubleToString(sprPts,1),
               " > MaxSpreadPoints=", MaxSpreadPoints);
      ResetState();
      return false;
   }

   double bid, ask;
   GetNormalizedBidAsk(bid, ask);

   // Buy at ask, sell at bid.
   double entry = setupLong ? ask : bid;
   entry = NormalizePrice(entry);

   // --------------------------------------------------------------------------
   // Stop placement
   // --------------------------------------------------------------------------
   // Student rule:
   // put the stop beyond the reversal leg extreme, plus a small buffer.
   // This corresponds to the transcript idea of putting stops under lows or
   // above highs after the reversal/continuation forms.
   // --------------------------------------------------------------------------
   double sl = 0.0;
   if(setupLong)
      sl = NormalizePrice(legLow - (double)SLBufferPoints * _Point);
   else
      sl = NormalizePrice(legHigh + (double)SLBufferPoints * _Point);

   // Sanity checks.
   if(setupLong && sl >= entry)
   {
      if(PrintDebug) Print("SKIP entry: long SL is not below entry");
      ResetState();
      return false;
   }

   if(!setupLong && sl <= entry)
   {
      if(PrintDebug) Print("SKIP entry: short SL is not above entry");
      ResetState();
      return false;
   }

   double risk = MathAbs(entry - sl);
   if(risk <= 0.0)
   {
      if(PrintDebug) Print("SKIP entry: zero risk distance");
      ResetState();
      return false;
   }

   // --------------------------------------------------------------------------
   // Target placement
   // --------------------------------------------------------------------------
   // Primary rule:
   //    target opposite higher timeframe liquidity.
   // Fallback rule:
   //    use DefaultRR_TP * risk if no suitable liquidity target is available.
   // --------------------------------------------------------------------------
   double tp = FindNearestTP(setupLong, entry);
   if(tp <= 0.0)
   {
      if(setupLong)
         tp = NormalizePrice(entry + (double)DefaultRR_TP * risk);
      else
         tp = NormalizePrice(entry - (double)DefaultRR_TP * risk);
   }
   else
   {
      tp = NormalizePrice(tp);
   }

   double rr = MathAbs(tp - entry) / risk;

   // Position size is capped by both risk and margin.
   double lots = CalcLotsByRiskAndMargin(setupLong, entry, sl);
   if(lots <= 0.0)
   {
      if(PrintDebug) Print("SKIP entry: lots calc failed");
      ResetState();
      return false;
   }

   trade.SetDeviationInPoints(DeviationPoints);

   bool ok = false;
   if(setupLong)
      ok = trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0);
   else
      ok = trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0);

   if(PrintDebug)
   {
      if(ok)
      {
         Print("ENTRY ", (setupLong ? "LONG" : "SHORT"),
               " lots=", DoubleToString(lots,2),
               " entryRef=", DoubleToString(entry,_Digits),
               " slPlan=", DoubleToString(sl,_Digits),
               " tpPlan=", DoubleToString(tp,_Digits),
               " rr=", DoubleToString(rr,2),
               " sprPts=", DoubleToString(sprPts,1),
               " continuationSource=", continuationSource);
      }
      else
      {
         Print("ENTRY FAILED: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
   }

   // If order was sent successfully, store manual SL/TP plan.
   if(ok)
   {
      g_managePosition = true;
      g_posLong = setupLong;
      g_posSL = sl;
      g_posTP = tp;
   }

   // Whether entry succeeds or fails, the setup is finished.
   ResetState();
   return ok;
}

// =============================================================================
// MT5 LIFECYCLE
// =============================================================================

// Called once when the EA starts.
int OnInit()
{
   BuildLevelsForToday();
   return INIT_SUCCEEDED;
}

// Main event loop.
void OnTick()
{
   datetime nowSrv = TimeCurrent();

   // --------------------------------------------------------------------------
   // Step 1: manage any open position first
   // --------------------------------------------------------------------------
   if(HasOpenPosition())
   {
      ManageOpenPosition(nowSrv);
      if(HasOpenPosition())
         return;
   }
   else if(g_managePosition)
   {
      ResetManagedPositionPlan();
   }

   // --------------------------------------------------------------------------
   // Step 2: rebuild levels when ET day changes
   // --------------------------------------------------------------------------
   datetime etDay = GetETDayStart(nowSrv);
   if(etDay != g_etDayStart)
      BuildLevelsForToday();

   // Outside trade window -> do nothing.
   if(!InTradeWindow(nowSrv))
      return;

   // --------------------------------------------------------------------------
   // Step 3: only process once per newly closed bar
   // --------------------------------------------------------------------------
   datetime closedBarTime = GetLastClosedBarTime(EntryTF);
   bool newClosedBar = (closedBarTime != 0 && closedBarTime != lastClosedBarProcessed);
   if(!newClosedBar)
      return;

   lastClosedBarProcessed = closedBarTime;

   MqlRates lastClosed;
   if(!GetLastClosedBar(lastClosed, EntryTF))
      return;

   // Ignore bars before today's official session start.
   if(lastClosed.time < g_tradeStartSrv)
      return;

   // --------------------------------------------------------------------------
   // STATE 1: waiting for a sweep of higher timeframe liquidity
   // --------------------------------------------------------------------------
   if(state == STATE_IDLE)
   {
      if(OneTradePerDay && daySetupConsumed)
         return;

      bool wantLong = false;
      double lvl = 0.0;

      if(DetectSweepOnClosedBar(lastClosed, wantLong, lvl))
      {
         setupLong = wantLong;
         sweepLevelPrice = lvl;
         sweepTimeSrv = lastClosed.time;

         if(OneTradePerDay)
            daySetupConsumed = true;

         state = STATE_WAIT_REVERSAL;
         barsSinceSweep = 0;
         barsSinceReversal = 0;

         if(PrintDebug)
            Print(TimeToString(lastClosed.time, TIME_DATE|TIME_SECONDS),
                  " SWEEP ", (setupLong ? "LOW" : "HIGH"),
                  " lvl=", DoubleToString(lvl, _Digits),
                  " -> WAIT_REVERSAL");
      }
      return;
   }

   // --------------------------------------------------------------------------
   // STATE 2: waiting for a lower timeframe reversal after the sweep
   // --------------------------------------------------------------------------
   if(state == STATE_WAIT_REVERSAL)
   {
      barsSinceSweep++;

      if(barsSinceSweep > MaxWaitBarsForReversal)
      {
         if(PrintDebug)
            Print(TimeToString(nowSrv, TIME_DATE|TIME_SECONDS), " TIMEOUT REVERSAL -> IDLE");
         ResetState();
         return;
      }

      datetime sigTime = 0;
      bool revOk = false;

      // Try BOS first.
      if(UseBOS_Reversal && ReversalByBOS(setupLong, sigTime))
         revOk = true;

      // If BOS not found, try inverse FVG.
      if(!revOk && UseIFVG_Reversal && ReversalByIFVG(setupLong, sigTime))
         revOk = true;

      // If still not found, try Fib 79% rule.
      if(!revOk && UseFib79_Reversal)
      {
         double hi, lo;
         if(ComputeLegExtremes(sweepTimeSrv, lastClosed.time, hi, lo))
         {
            if(ReversalByFib79(setupLong, hi, lo, sigTime))
               revOk = true;
         }
      }

      if(!revOk || sigTime <= sweepTimeSrv)
         return;

      // Once reversal is confirmed, lock in the reversal leg extremes.
      double hi, lo;
      if(!ComputeLegExtremes(sweepTimeSrv, sigTime, hi, lo))
      {
         if(PrintDebug)
            Print("Leg extremes failed -> IDLE");
         ResetState();
         return;
      }

      legHigh = hi;
      legLow  = lo;
      reversalTimeSrv = sigTime;

      // Build EQ / FVG / OB / Breaker zones for continuation phase.
      BuildContinuationZones(setupLong, sigTime);

      state = STATE_WAIT_CONTINUATION;
      barsSinceReversal = 0;

      if(PrintDebug)
         Print(TimeToString(sigTime, TIME_DATE|TIME_SECONDS),
               " REVERSAL confirmed -> WAIT_CONTINUATION eq=",
               DoubleToString(equilibrium, _Digits));

      return;
   }

   // --------------------------------------------------------------------------
   // STATE 3: waiting for continuation from EQ / FVG / OB / Breaker
   // --------------------------------------------------------------------------
   if(state == STATE_WAIT_CONTINUATION)
   {
      barsSinceReversal++;

      if(barsSinceReversal > MaxWaitBarsForContinuation)
      {
         if(PrintDebug)
            Print(TimeToString(nowSrv, TIME_DATE|TIME_SECONDS), " TIMEOUT CONTINUATION -> IDLE");
         ResetState();
         return;
      }

      datetime contTime = 0;
      if(ContinuationConfirmed(setupLong, contTime))
      {
         if(contTime >= reversalTimeSrv)
            TryEnterTrade();
      }

      return;
   }
}