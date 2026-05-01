#property strict

#include <Trade/Trade.mqh>
CTrade trade;

/*
   TJR_Framework_EA.mq5

   HIGH LEVEL IDEA OF THE EA
   -------------------------
   The EA turns a spoken strategy into a fixed sequence of rules:

   1) Build important higher timeframe levels for the day
      - previous day high / low
      - recent H1 highs / lows
      - recent H4 highs / lows

   2) Wait for price to sweep one of those levels
      - sweep above a high  -> possible short idea
      - sweep below a low   -> possible long idea

   3) After the sweep, wait for reversal confirmation on the lower timeframe
      - BOS
      - inverse FVG
      - Fib 79 rule

   4) After reversal, wait for continuation confirmation
      - EQ
      - FVG
      - OB
      - Breaker

   5) Enter the trade

   6) Manage the position manually
      - close at planned SL
      - close at planned TP
      - or force close near end of session
*/


enum SetupState
{
   STATE_IDLE = 0,
   STATE_WAIT_REVERSAL = 1,
   STATE_WAIT_CONTINUATION = 2
};


// ============================================================================
// 1) INPUTS
// ============================================================================
// Inputs are values that can be changed from MT5 when the EA is attached.
// They control risk, timeframe, session, confluences, and debug behavior.

// Risk sizing.
// RiskPercent = percent of account balance to risk per trade idea.
// MaxLots     = hard cap so the EA never uses more than this size.
input double RiskPercent = 2.0;
input double MaxLots     = 100.0;

// Lower timeframe used for reversal / continuation logic.
input ENUM_TIMEFRAMES EntryTF = PERIOD_M1;

// Trading window in New York / ET.
// If the test is done during daylight saving time, this may need to be -4.
input int ET_UTC_OffsetHours = -5;
input int TradeStartHour     = 8;
input int TradeStartMinute   = 30;
input int TradeEndHour       = 16;
input int TradeEndMinute     = 0;


// Higher timeframe liquidity references.
input bool UsePrevDayHighLow = true;
input bool UseH1Levels       = true;
input bool UseH4Levels       = true;
input int  H1_LevelCount     = 3;
input int  H4_LevelCount     = 2;

// If many levels are almost the same, remove duplicates.
input int  MinLevelSpacingPoints = 50;

// Sweep / execution tuning.
input int SweepBufferPoints = 5;
input int SLBufferPoints    = 5;
input int DeviationPoints   = 20;
input int MaxSpreadPoints   = 40;

// Reversal confluences.
input bool UseBOS_Reversal   = true;
input bool UseIFVG_Reversal  = true;
input bool UseFib79_Reversal = true;

input int  BOS_LookbackBars       = 5;
input int  MaxWaitBarsForReversal = 120;

// Continuation confluences.
input bool UseEQ_Continuation      = true;
input bool UseFVG_Continuation     = true;
input bool UseOB_Continuation      = true;
input bool UseBreaker_Continuation = true;

input int  MaxWaitBarsForContinuation = 120;
input int  ScanBarsFVG                 = 120;

// If no opposite liquidity target is found, use RR-based target.
input int DefaultRR_TP = 3;

// One main setup per day.
input bool OneTradePerDay = true;

// Force flat near end of session.
input bool ForceCloseAtTradeEnd = true;

// Print detailed messages into Experts tab.
input bool PrintDebug = true;


// ============================================================================
// 2) DATA STRUCTURES
// ============================================================================

// A Level is one price reference used as possible liquidity.
struct Level
{
   double price;   // actual price level
   bool   isHigh;  // true  = high liquidity above price
                   // false = low liquidity below price
   bool   swept;   // true once this level has already been used today
};

// A Zone is an area with a lower edge and upper edge.
// It is used for FVG, order block, breaker block, etc.
struct Zone
{
   double low;
   double high;
   bool   valid;
};


// ============================================================================
// 3) GLOBAL VARIABLES
// ============================================================================

// Dynamic array that stores all today's levels.
Level    levels[];

// Current ET day and the current trading window, stored in server time.
datetime g_etDayStart     = 0;
datetime g_tradeStartSrv  = 0;
datetime g_tradeEndSrv    = 0;

// Time of the last closed bar that has already been processed.
datetime lastClosedBarProcessed = 0;

// Current state of the EA.
SetupState state = STATE_IDLE;

// Current setup direction and timing.
// setupLong = true  -> looking for long
// setupLong = false -> looking for short
bool      setupLong       = false;
double    sweepLevelPrice = 0.0;
datetime  sweepTimeSrv    = 0;
datetime  reversalTimeSrv = 0;

// How many bars we have waited inside each state.
int       barsSinceSweep    = 0;
int       barsSinceReversal = 0;

// Daily lock for one setup idea per day.
bool      daySetupConsumed = false;

// Extremes of the full reversal leg.
double legHigh = 0.0;
double legLow  = 0.0;

// Continuation references.
double equilibrium = 0.0;
Zone   zFvg;
Zone   zOb;
Zone   zBreaker;

// Information about which candle touched continuation.
double   continuationTouchLow  = 0.0;
double   continuationTouchHigh = 0.0;
datetime continuationTouchTime = 0;
string   continuationSource    = "";

// Manual management plan for the current symbol trade.
bool   g_managePosition = false;
bool   g_posLong        = false;
double g_posSL          = 0.0;
double g_posTP          = 0.0;

// Used to stop repeated forced-close spam.
datetime g_lastForcedCloseDay = 0;


// ============================================================================
// 4) TIME HELPERS
// ============================================================================

// Return the server offset from UTC in hours.
int GetServerUTCOffsetHours()
{
   datetime srv = TimeTradeServer();
   datetime gmt = TimeGMT();
   return (int)MathRound((double)(srv - gmt) / 3600.0);
}

// Build one datetime value from year, month, day, hour, minute, second.
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

// Convert ET back to server time.
datetime ETToServer(datetime etTime)
{
   int srvOff = GetServerUTCOffsetHours();
   datetime gmt = etTime - ET_UTC_OffsetHours * 3600;
   return gmt + srvOff * 3600;
}

// Return the start of the ET day for a given server time.
datetime GetETDayStart(datetime serverNow)
{
   datetime etNow = ServerToET(serverNow);
   MqlDateTime d;
   TimeToStruct(etNow, d);
   return MakeTime(d.year, d.mon, d.day, 0, 0, 0);
}

// Build today's ET session window and convert it into server time.
void GetTradeWindowBounds(datetime serverNow, datetime &startSrv, datetime &endSrv)
{
   datetime etNow = ServerToET(serverNow);
   MqlDateTime d;
   TimeToStruct(etNow, d);

   datetime startET = MakeTime(d.year, d.mon, d.day, TradeStartHour, TradeStartMinute, 0);
   datetime endET   = MakeTime(d.year, d.mon, d.day, TradeEndHour,   TradeEndMinute,   0);

   // Safety: if end is not after start, push end one full day ahead.
   if(endET <= startET)
      endET += 86400;

   startSrv = ETToServer(startET);
   endSrv   = ETToServer(endET);
}

// Check whether current time is inside the allowed trading window.
bool InTradeWindow(datetime serverNow)
{
   datetime startSrv, endSrv;
   GetTradeWindowBounds(serverNow, startSrv, endSrv);
   return (serverNow >= startSrv && serverNow <= endSrv);
}


// ============================================================================
// 5) POSITION HELPERS
// ============================================================================
// Checks whether there is an open position for the current symbol.
// That means the EA assumes that:
// - this chart is the only place where NVDA is being traded
// - there are no manual NVDA trades open
// - there is no second EA trading NVDA on the same account

// Do we currently have any open position for this symbol?
bool HasOpenPosition()
{
   return PositionSelect(_Symbol);
}

// Read whether the current symbol position is long or short.
// This is mainly used when the EA needs to understand the direction
// of the already open trade during manual management.
bool GetCurrentPositionDirection(bool &isLong)
{
   isLong = false;

   if(!PositionSelect(_Symbol))
      return false;

   long type = PositionGetInteger(POSITION_TYPE);
   isLong = (type == POSITION_TYPE_BUY);
   return true;
}

// ============================================================================
// 6) MARKET / PRICE HELPERS
// ============================================================================

// Return the last fully closed candle on a chosen timeframe.
bool GetLastClosedBar(MqlRates &bar, ENUM_TIMEFRAMES tf)
{
   MqlRates r[];
   ArraySetAsSeries(r, true);

   // r[0] = current forming bar
   // r[1] = last closed bar
   if(CopyRates(_Symbol, tf, 0, 2, r) != 2)
      return false;

   bar = r[1];
   return true;
}

// Return only the time of the last closed candle.
datetime GetLastClosedBarTime(ENUM_TIMEFRAMES tf)
{
   MqlRates bar;
   if(!GetLastClosedBar(bar, tf))
      return 0;
   return bar.time;
}

// Get tick size from symbol settings.
double GetTickSize()
{
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0.0)
      ts = _Point;
   return ts;
}

// Round a price to the nearest legal tick size.
double NormalizePrice(double price)
{
   double ts = GetTickSize();
   if(ts <= 0.0)
      ts = _Point;

   return NormalizeDouble(MathRound(price / ts) * ts, _Digits);
}

// Read current Bid and Ask and normalize them.
void GetNormalizedBidAsk(double &bid, double &ask)
{
   double rawBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double rawAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // If no live Bid/Ask is available, use the last close as fallback.
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

   // Safety: if Ask comes below Bid, swap them.
   if(rawAsk < rawBid)
   {
      double tmp = rawAsk;
      rawAsk = rawBid;
      rawBid = tmp;
   }

   bid = NormalizePrice(rawBid);
   ask = NormalizePrice(rawAsk);
}

// Return spread measured in points.
double CurrentSpreadPoints()
{
   double bid, ask;
   GetNormalizedBidAsk(bid, ask);
   if(bid <= 0.0 || ask <= 0.0)
      return 0.0;
   return (ask - bid) / _Point;
}

// Find the first fully closed bar before a given time on a higher timeframe.
int GetFirstClosedShiftBeforeTime(ENUM_TIMEFRAMES tf, datetime whenSrv)
{
   int shift = iBarShift(_Symbol, tf, whenSrv, false);
   if(shift < 0)
      return -1;

   datetime barOpen = iTime(_Symbol, tf, shift);
   int sec = PeriodSeconds(tf);
   if(sec <= 0)
      sec = 60;

   // If that bar would still be open at whenSrv, move one bar older.
   if(barOpen + sec > whenSrv)
      shift++;

   return shift;
}


// ============================================================================
// 7) STATE RESET HELPERS
// ============================================================================

// Clear the stored manual position plan.
void ResetManagedPositionPlan()
{
   g_managePosition = false;
   g_posLong = false;
   g_posSL = 0.0;
   g_posTP = 0.0;
}

// Clear all temporary setup variables and go back to idle state.
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


// ============================================================================
// 8) LEVEL MANAGEMENT
// ============================================================================

// Add one new level into the levels array.
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

// Remove near-duplicate levels.
void DedupLevels()
{
   double eps = (double)MinLevelSpacingPoints * _Point;
   if(eps < 2.0 * _Point)
      eps = 2.0 * _Point;

   // First pass: mark duplicates by setting price to zero.
   for(int i=0; i<ArraySize(levels); i++)
   {
      if(levels[i].price <= 0.0)
         continue;

      for(int j=i+1; j<ArraySize(levels); j++)
      {
         if(levels[j].price <= 0.0)
            continue;

         // Compare highs only with highs, lows only with lows.
         if(levels[i].isHigh != levels[j].isHigh)
            continue;

         if(MathAbs(levels[i].price - levels[j].price) <= eps)
            levels[j].price = 0.0;
      }
   }

   // Second pass: rebuild a clean array.
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
   if(ArraySize(tmp) > 0)
      ArrayCopy(levels, tmp, 0, 0, WHOLE_ARRAY);
}

// Build all today's levels.
void BuildLevelsForToday()
{
   // Start from an empty set.
   ArrayResize(levels, 0);

   datetime nowSrv = TimeCurrent();

   // Save the current ET day and the ET session bounds.
   g_etDayStart = GetETDayStart(nowSrv);
   GetTradeWindowBounds(nowSrv, g_tradeStartSrv, g_tradeEndSrv);

   // Reset the one-time forced-close lock for the new day.
   g_lastForcedCloseDay = 0;

   // --------------------------------------------------
   // Previous day high / low
   // --------------------------------------------------
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

   // --------------------------------------------------
   // H1 highs / lows
   // --------------------------------------------------
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

   // --------------------------------------------------
   // H4 highs / lows
   // --------------------------------------------------
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

   // Clean up duplicates and reset daily state.
   DedupLevels();
   ResetState();
   daySetupConsumed = false;

   // Remember the most recent closed bar so it is not processed twice.
   lastClosedBarProcessed = GetLastClosedBarTime(EntryTF);

   if(PrintDebug)
      Print(TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
            " New ET day. Levels=", ArraySize(levels));
}


// ============================================================================
// 9) SWEEP DETECTION
// ============================================================================

// Check whether the latest closed candle swept one of today's levels.
bool DetectSweepOnClosedBar(const MqlRates &bar, bool &outLongSetup, double &outLevelPrice)
{
   if(ArraySize(levels) <= 0)
      return false;

   // Price must move slightly beyond the level, not just touch it.
   double buf = (double)SweepBufferPoints * _Point;

   for(int i=0; i<ArraySize(levels); i++)
   {
      // Ignore levels already used today.
      if(levels[i].swept)
         continue;

      // Sweep above a high -> possible short setup.
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
      // Sweep below a low -> possible long setup.
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


// ============================================================================
// 10) REVERSAL LOGIC HELPERS
// ============================================================================

// Highest high among a block of older candles.
double HighestHighPrevN(const MqlRates &rates[], int startIndex, int count)
{
   double hh = -DBL_MAX;
   for(int i=startIndex; i<startIndex+count; i++)
      if(rates[i].high > hh) hh = rates[i].high;
   return hh;
}

// Lowest low among a block of older candles.
double LowestLowPrevN(const MqlRates &rates[], int startIndex, int count)
{
   double ll = DBL_MAX;
   for(int i=startIndex; i<startIndex+count; i++)
      if(rates[i].low < ll) ll = rates[i].low;
   return ll;
}

// Candle direction helpers.
bool CandleBullish(const MqlRates &c) { return (c.close > c.open); }
bool CandleBearish(const MqlRates &c) { return (c.close < c.open); }

// BOS reversal.
// If we want long, price must close above recent highs.
// If we want short, price must close below recent lows.
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

// Find the most recent FVG in a chosen direction.
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
         // Bullish FVG shape.
         if(b1.high < b3.low)
         {
            outGap.low = b1.high;
            outGap.high = b3.low;
            outGap.valid = true;
         }
      }
      else
      {
         // Bearish FVG shape.
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

// Inverse FVG reversal.
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

// Measure the full leg from sweep time to reversal time.
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

// Fib 79 reversal.
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

// ============================================================================
// 11) CONTINUATION ZONES
// ============================================================================

// Check whether a candle overlaps a zone.
bool TouchesZone(const MqlRates &c, const Zone &z)
{
   if(!z.valid)
      return false;
   return (c.low <= z.high && c.high >= z.low);
}

// Build all continuation references after reversal is confirmed.
void BuildContinuationZones(bool wantLong, datetime reversalSignalTime)
{
   // EQ is the midpoint of the reversal leg.
   equilibrium = (legHigh + legLow) * 0.5;

   // Reset FVG continuation zone.
   zFvg.low = 0.0; zFvg.high = 0.0; zFvg.valid = false;
   if(UseFVG_Continuation)
   {
      Zone gap;
      if(FindMostRecentFVG(gap, wantLong) && gap.valid)
         zFvg = gap;
   }

   // Reset OB and Breaker zones.
   zOb.low = 0.0; zOb.high = 0.0; zOb.valid = false;
   zBreaker.low = 0.0; zBreaker.high = 0.0; zBreaker.valid = false;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int got = CopyRates(_Symbol, EntryTF, 1, 200, r);
   if(got < 10)
      return;

   // Order block approximation.
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

   // Breaker block approximation.
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

// Check whether the latest closed candle confirms continuation.
bool ContinuationConfirmed(bool wantLong, datetime &signalBarTime)
{
   MqlRates lastClosed;
   if(!GetLastClosedBar(lastClosed, EntryTF))
      return false;

   bool touched = false;
   string source = "";

   // --------------------------------------------------
   // EQ
   // --------------------------------------------------
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

   // --------------------------------------------------
   // FVG
   // --------------------------------------------------
   if(!touched && UseFVG_Continuation && zFvg.valid && TouchesZone(lastClosed, zFvg))
   {
      touched = true;
      source = "FVG";
   }

   // --------------------------------------------------
   // OB
   // --------------------------------------------------
   if(!touched && UseOB_Continuation && zOb.valid && TouchesZone(lastClosed, zOb))
   {
      touched = true;
      source = "OB";
   }

   // --------------------------------------------------
   // Breaker
   // --------------------------------------------------
   if(!touched && UseBreaker_Continuation && zBreaker.valid && TouchesZone(lastClosed, zBreaker))
   {
      touched = true;
      source = "BREAKER";
   }

   if(!touched)
      return false;

   // Save information about the touch candle.
   continuationTouchLow  = lastClosed.low;
   continuationTouchHigh = lastClosed.high;
   continuationTouchTime = lastClosed.time;
   continuationSource    = source;

   if(PrintDebug)
      Print(TimeToString(lastClosed.time, TIME_DATE|TIME_SECONDS),
            " CONTINUATION TOUCH source=", source);

   // Final directional filter.
   if(wantLong && !CandleBullish(lastClosed))
      return false;
   if(!wantLong && !CandleBearish(lastClosed))
      return false;

   signalBarTime = lastClosed.time;
   return true;
}

// ============================================================================
// 12) TARGETING AND LOT SIZING
// ============================================================================

// Find nearest opposite liquidity level.
double FindNearestTP(bool wantLong, double entryPrice)
{
   double best = 0.0;

   if(wantLong)
   {
      // For long, find nearest higher HIGH above entry.
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
      // For short, find nearest lower LOW below entry.
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

// Convert one full price unit movement into money per lot.
double MoneyPerPriceUnitPerLot()
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0.0 || tickSize <= 0.0)
      return 0.0;

   return tickValue / tickSize;
}

// Round lots down to legal volume step and broker limits.
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

// Calculate lot size using both risk limit and margin limit.
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

   // Maximum lots allowed by risk.
   double lotsByRisk = riskAmount / riskPerLot;

   // Estimate margin required for one lot.
   double marginPerLot = 0.0;
   ENUM_ORDER_TYPE ordType = wantLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if(!OrderCalcMargin(ordType, _Symbol, 1.0, entry, marginPerLot) || marginPerLot <= 0.0)
   {
      double contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      if(contract <= 0.0)
         contract = 1.0;
      marginPerLot = entry * contract;
   }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(freeMargin <= 0.0)
      freeMargin = balance;

   // Maximum lots allowed by margin.
   double lotsByMargin = freeMargin / marginPerLot;

   // Slighty less for safety.
   lotsByMargin *= 0.98;

   // Use the smaller of the two limits.
   double lots = MathMin(lotsByRisk, lotsByMargin);
   lots = NormalizeLotsToStep(lots);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lots < minLot)
      return 0.0;

   return lots;
}

// ============================================================================
// 13) POSITION MANAGEMENT
// ============================================================================

// Force close the current symbol position.
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

// Manage the open position for the current symbol.
void ManageOpenPosition(datetime nowSrv)
{
   // If there is no open position anymore, clear the stored management plan.
   if(!HasOpenPosition())
   {
      ResetManagedPositionPlan();
      return;
   }

   int sec = PeriodSeconds(EntryTF);
   if(sec <= 0)
      sec = 60;

   // Close in the last full candle interval before session end.
   datetime finalCloseCutoff = g_tradeEndSrv - sec;

   // --------------------------------------------------
   // Session-end forced close
   // --------------------------------------------------
   if(ForceCloseAtTradeEnd && nowSrv >= finalCloseCutoff)
   {
      datetime etDayNow = GetETDayStart(nowSrv);

      // Allow only one force-close attempt per ET day.
      if(g_lastForcedCloseDay != etDayNow)
      {
         if(ForceClosePosition("last in-session minute"))
            g_lastForcedCloseDay = etDayNow;
      }

      return;
   }

   // If no SL/TP plan exists, do nothing.
   if(!g_managePosition)
      return;

   bool posLong = false;
   if(!GetCurrentPositionDirection(posLong))
   {
      ResetManagedPositionPlan();
      return;
   }

   double bid, ask;
   GetNormalizedBidAsk(bid, ask);

   bool closeNow = false;
   string why = "";

   // For long positions, use Bid to test SL and TP.
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
   // For short positions, use Ask to test SL and TP.
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

// ============================================================================
// 14) ENTRY LOGIC
// ============================================================================

// Try to enter a trade once all other logic has already confirmed setup.
bool TryEnterTrade()
{
   // Never enter if there is already an open position on this symbol.
   if(HasOpenPosition())
      return false;

   // Skip entry if spread is too high.
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

   // Buy at Ask, sell at Bid.
   double entry = setupLong ? ask : bid;
   entry = NormalizePrice(entry);

   // --------------------------------------------------
   // Stop loss
   // --------------------------------------------------
   // For long: stop below leg low.
   // For short: stop above leg high.
   double sl = 0.0;
   if(setupLong)
      sl = NormalizePrice(legLow - (double)SLBufferPoints * _Point);
   else
      sl = NormalizePrice(legHigh + (double)SLBufferPoints * _Point);

   // Safety checks.
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

   // --------------------------------------------------
   // Take profit
   // --------------------------------------------------
   // Prefer nearest opposite liquidity target.
   // If none exists, use RR-based fallback.
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

   // Lot size based on both risk and margin.
   double lots = CalcLotsByRiskAndMargin(setupLong, entry, sl);
   if(lots <= 0.0)
   {
      if(PrintDebug) Print("SKIP entry: lots calc failed");
      ResetState();
      return false;
   }

   // Set allowed slippage / deviation for order execution.
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

   // If trade was opened, save its manual management plan.
   if(ok)
   {
      g_managePosition = true;
      g_posLong = setupLong;
      g_posSL = sl;
      g_posTP = tp;
   }

   // Reset setup state after entry attempt.
   ResetState();
   return ok;
}

// ============================================================================
// 15) MT5 LIFECYCLE
// ============================================================================

// Runs once when the EA is attached.
int OnInit()
{
   // Build today's levels immediately so the EA is ready from the start.
   BuildLevelsForToday();
   return INIT_SUCCEEDED;
}

// Runs on every tick.
void OnTick()
{
   datetime nowSrv = TimeCurrent();

   // --------------------------------------------------
   // STEP 1: manage any open position for this symbol first
   // --------------------------------------------------
   if(HasOpenPosition())
   {
      ManageOpenPosition(nowSrv);

      // If trade is still open after management, stop here.
      if(HasOpenPosition())
         return;
   }
   else if(g_managePosition)
   {
      // Safety cleanup if the stored plan says a position existed
      // but in reality there is none anymore.
      ResetManagedPositionPlan();
   }

   // --------------------------------------------------
   // STEP 2: if ET day changed, rebuild today's levels
   // --------------------------------------------------
   datetime etDay = GetETDayStart(nowSrv);
   if(etDay != g_etDayStart)
      BuildLevelsForToday();

   // --------------------------------------------------
   // STEP 3: only continue inside trading window
   // --------------------------------------------------
   if(!InTradeWindow(nowSrv))
      return;

   // --------------------------------------------------
   // STEP 4: process only newly closed bars
   // --------------------------------------------------
   datetime closedBarTime = GetLastClosedBarTime(EntryTF);
   bool newClosedBar = (closedBarTime != 0 && closedBarTime != lastClosedBarProcessed);
   if(!newClosedBar)
      return;

   lastClosedBarProcessed = closedBarTime;

   MqlRates lastClosed;
   if(!GetLastClosedBar(lastClosed, EntryTF))
      return;

   // Ignore bars from before today's ET session start.
   if(lastClosed.time < g_tradeStartSrv)
      return;

   // --------------------------------------------------
   // STATE A: IDLE -> wait for sweep
   // --------------------------------------------------
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

   // --------------------------------------------------
   // STATE B: WAIT_REVERSAL
   // --------------------------------------------------
   if(state == STATE_WAIT_REVERSAL)
   {
      barsSinceSweep++;

      // Cancel setup if reversal takes too long.
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

      // If BOS failed, try inverse FVG.
      if(!revOk && UseIFVG_Reversal && ReversalByIFVG(setupLong, sigTime))
         revOk = true;

      // If still no reversal, try Fib79.
      if(!revOk && UseFib79_Reversal)
      {
         double hi, lo;
         if(ComputeLegExtremes(sweepTimeSrv, lastClosed.time, hi, lo))
         {
            if(ReversalByFib79(setupLong, hi, lo, sigTime))
               revOk = true;
         }
      }

      // If still not confirmed, keep waiting.
      if(!revOk || sigTime <= sweepTimeSrv)
         return;

      // Once reversal is confirmed, measure the full reversal leg.
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

      // Build continuation references from the finished reversal leg.
      BuildContinuationZones(setupLong, sigTime);

      state = STATE_WAIT_CONTINUATION;
      barsSinceReversal = 0;

      if(PrintDebug)
         Print(TimeToString(sigTime, TIME_DATE|TIME_SECONDS),
               " REVERSAL confirmed -> WAIT_CONTINUATION eq=",
               DoubleToString(equilibrium, _Digits));

      return;
   }

   // --------------------------------------------------
   // STATE C: WAIT_CONTINUATION
   // --------------------------------------------------
   if(state == STATE_WAIT_CONTINUATION)
   {
      barsSinceReversal++;

      // Cancel setup if continuation takes too long.
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
         // Only allow continuation after or at reversal time.
         if(contTime >= reversalTimeSrv)
            TryEnterTrade();
      }

      return;
   }
}