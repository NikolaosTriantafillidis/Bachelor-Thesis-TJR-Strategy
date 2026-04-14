#property strict

#include <Trade/Trade.mqh>
CTrade trade;

enum SetupState
{
   STATE_IDLE = 0,
   STATE_WAIT_REVERSAL = 1,
   STATE_WAIT_CONTINUATION = 2
};

// ---------------- Inputs ----------------

// Risk sizing
input double RiskPercent = 2.0;
input double MaxLots     = 100.0;

// Timeframe
input ENUM_TIMEFRAMES EntryTF = PERIOD_M1;

// Trading window (ET)
input int ET_UTC_OffsetHours = -5;
input int TradeStartHour     = 8;
input int TradeStartMinute   = 30;
input int TradeEndHour       = 16;
input int TradeEndMinute     = 0;

// Levels
input bool UsePrevDayHighLow = true;
input bool UseH1Levels       = true;
input bool UseH4Levels       = true;
input int  H1_LevelCount     = 3;
input int  H4_LevelCount     = 2;

// Avoid clustered levels (teacher: avoid narrow band / stacked levels)
input int  MinLevelSpacingPoints = 50;   // e.g. 50 points

// Sweep / execution
input int SweepBufferPoints = 5;
input int SLBufferPoints    = 5;
input int DeviationPoints   = 20;

// Spread / distance safety (teacher: avoid narrow SL/TP)
input int    MaxSpreadPoints  = 40;   // skip entries if spread > this
input int    MinStopPoints    = 80;   // minimum SL distance
input int    MinTargetPoints  = 120;  // minimum TP distance
input double MinRR            = 1.5;  // minimum risk-reward (TP >= MinRR * risk)

// Reversal confluences
input bool UseBOS_Reversal   = true;
input bool UseIFVG_Reversal  = true;
input bool UseFib79_Reversal = true;

input int  BOS_LookbackBars       = 5;
input int  MaxWaitBarsForReversal = 120;

// Continuation confluences
input bool UseEQ_Continuation      = true;
input bool UseFVG_Continuation     = true;
input bool UseOB_Continuation      = true;
input bool UseBreaker_Continuation = true;

input int  MaxWaitBarsForContinuation = 120;

// FVG scan depth
input int  ScanBarsFVG = 120;

// Fallback TP RR if no opposite liquidity found
input int DefaultRR_TP = 3;

input bool PrintDebug = true;

// ---------------- Structs ----------------

struct Level
{
   double price;
   bool   isHigh;
   bool   swept;
};

struct Zone
{
   double low;
   double high;
   bool   valid;
};

// ---------------- Globals ----------------

Level    levels[];
datetime g_etDayStart = 0;

SetupState state = STATE_IDLE;

bool      setupLong = false;
double    sweepLevelPrice = 0.0;
datetime  sweepTimeSrv = 0;

int       barsSinceSweep = 0;
int       barsSinceReversal = 0;

datetime  lastClosedBarProcessed = 0;

// Leg extremes (sweep -> reversal)
double legHigh = 0.0;
double legLow  = 0.0;

// Continuation zones
double equilibrium = 0.0;
Zone zFvg;
Zone zOb;
Zone zBreaker;

// ---------------- Utility ----------------

int GetServerUTCOffsetHours()
{
   datetime srv = TimeTradeServer();
   datetime gmt = TimeGMT();
   return (int)MathRound((double)(srv - gmt) / 3600.0);
}

datetime MakeTime(int y,int mo,int d,int h,int mi,int s)
{
   MqlDateTime t;
   t.year=y; t.mon=mo; t.day=d;
   t.hour=h; t.min=mi; t.sec=s;
   return StructToTime(t);
}

datetime ServerToET(datetime serverTime)
{
   int srvOff = GetServerUTCOffsetHours();
   datetime gmt = serverTime - srvOff * 3600;
   return gmt + ET_UTC_OffsetHours * 3600;
}

datetime ETToServer(datetime etTime)
{
   int srvOff = GetServerUTCOffsetHours();
   datetime gmt = etTime - ET_UTC_OffsetHours * 3600;
   return gmt + srvOff * 3600;
}

datetime GetETDayStart(datetime serverNow)
{
   datetime etNow = ServerToET(serverNow);
   MqlDateTime d; TimeToStruct(etNow, d);
   return MakeTime(d.year, d.mon, d.day, 0, 0, 0);
}

bool InTradeWindow(datetime serverNow)
{
   datetime etNow = ServerToET(serverNow);
   MqlDateTime d; TimeToStruct(etNow, d);

   datetime startET = MakeTime(d.year,d.mon,d.day, TradeStartHour, TradeStartMinute, 0);
   datetime endET   = MakeTime(d.year,d.mon,d.day, TradeEndHour,   TradeEndMinute,   0);
   if(endET <= startET) endET += 86400;

   return (etNow >= startET && etNow <= endET);
}

bool HasOpenPosition()
{
   return PositionSelect(_Symbol);
}

datetime GetLastClosedBarTime(ENUM_TIMEFRAMES tf)
{
   MqlRates r[2];
   if(CopyRates(_Symbol, tf, 0, 2, r) != 2) return 0;
   return r[1].time;
}

double CurrentSpreadPoints()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0) return 0.0;
   return (ask - bid) / _Point;
}

// ---------------- State / levels ----------------

void ResetState()
{
   state = STATE_IDLE;
   setupLong = false;
   sweepLevelPrice = 0.0;
   sweepTimeSrv = 0;
   barsSinceSweep = 0;
   barsSinceReversal = 0;

   legHigh = 0.0;
   legLow  = 0.0;

   equilibrium = 0.0;

   zFvg.low = zFvg.high = 0.0; zFvg.valid = false;
   zOb.low  = zOb.high  = 0.0; zOb.valid  = false;
   zBreaker.low = zBreaker.high = 0.0; zBreaker.valid = false;
}

void AddLevel(double price, bool isHigh)
{
   if(price <= 0.0) return;
   Level L; L.price = price; L.isHigh = isHigh; L.swept = false;
   int n = ArraySize(levels);
   ArrayResize(levels, n+1);
   levels[n] = L;
}

void DedupLevels()
{
   double eps = (double)MinLevelSpacingPoints * _Point;
   if(eps < 2.0 * _Point) eps = 2.0 * _Point;

   for(int i=0;i<ArraySize(levels);i++)
   {
      if(levels[i].price <= 0.0) continue;
      for(int j=i+1;j<ArraySize(levels);j++)
      {
         if(levels[j].price <= 0.0) continue;
         if(levels[i].isHigh != levels[j].isHigh) continue;

         if(MathAbs(levels[i].price - levels[j].price) <= eps)
            levels[j].price = 0.0;
      }
   }

   Level tmp[];
   ArrayResize(tmp, 0);

   for(int i=0;i<ArraySize(levels);i++)
   {
      if(levels[i].price <= 0.0) continue;
      int n = ArraySize(tmp);
      ArrayResize(tmp, n+1);
      tmp[n] = levels[i];
   }

   ArrayResize(levels, ArraySize(tmp));
   if(ArraySize(tmp) > 0)
      ArrayCopy(levels, tmp, 0, 0, WHOLE_ARRAY);
}

void BuildLevelsForToday()
{
   ArrayResize(levels, 0);

   datetime nowSrv = TimeCurrent();
   datetime etDayStart = GetETDayStart(nowSrv);
   g_etDayStart = etDayStart;

   MqlDateTime d; TimeToStruct(etDayStart, d);

   datetime tradeStartET = MakeTime(d.year,d.mon,d.day, TradeStartHour, TradeStartMinute, 0);
   datetime tradeEndET   = MakeTime(d.year,d.mon,d.day, TradeEndHour,   TradeEndMinute,   0);
   if(tradeEndET <= tradeStartET) tradeEndET += 86400;

   datetime tradeStartSrv = ETToServer(tradeStartET);

   // Previous day window high/low as session proxy
   if(UsePrevDayHighLow)
   {
      datetime prevStartET = tradeStartET - 86400;
      datetime prevEndET   = tradeEndET   - 86400;

      datetime prevStartSrv = ETToServer(prevStartET);
      datetime prevEndSrv   = ETToServer(prevEndET);

      MqlRates m1[];
      int copied = CopyRates(_Symbol, PERIOD_M1, prevStartSrv, prevEndSrv, m1);

      double hi = -DBL_MAX;
      double lo =  DBL_MAX;

      if(copied > 0)
      {
         for(int i=0;i<copied;i++)
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
   }

   // H1 highs/lows before trade start
   if(UseH1Levels)
   {
      int h1Shift = iBarShift(_Symbol, PERIOD_H1, tradeStartSrv, true);
      if(h1Shift < 0) h1Shift = 0;

      for(int k=1;k<=H1_LevelCount;k++)
      {
         int idx = h1Shift + k;
         double hi = iHigh(_Symbol, PERIOD_H1, idx);
         double lo = iLow(_Symbol,  PERIOD_H1, idx);
         if(hi > 0.0) AddLevel(hi, true);
         if(lo > 0.0) AddLevel(lo, false);
      }
   }

   // H4 highs/lows before trade start
   if(UseH4Levels)
   {
      int h4Shift = iBarShift(_Symbol, PERIOD_H4, tradeStartSrv, true);
      if(h4Shift < 0) h4Shift = 0;

      for(int k=1;k<=H4_LevelCount;k++)
      {
         int idx = h4Shift + k;
         double hi = iHigh(_Symbol, PERIOD_H4, idx);
         double lo = iLow(_Symbol,  PERIOD_H4, idx);
         if(hi > 0.0) AddLevel(hi, true);
         if(lo > 0.0) AddLevel(lo, false);
      }
   }

   DedupLevels();
   ResetState();

   if(PrintDebug)
      Print(TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
            " New ET day. Levels=", ArraySize(levels));
}

// ---------------- Core detections ----------------

bool DetectSweep(bool &outLongSetup, double &outLevelPrice)
{
   if(ArraySize(levels) <= 0) return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double buf = (double)SweepBufferPoints * _Point;

   for(int i=0;i<ArraySize(levels);i++)
   {
      if(levels[i].swept) continue;

      if(levels[i].isHigh)
      {
         if(ask >= levels[i].price + buf)
         {
            levels[i].swept = true;
            outLongSetup = false;
            outLevelPrice = levels[i].price;
            return true;
         }
      }
      else
      {
         if(bid <= levels[i].price - buf)
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

double HighestHighPrevN(const MqlRates &rates[], int startIndex, int count)
{
   double hh = -DBL_MAX;
   for(int i=startIndex;i<startIndex+count;i++)
      if(rates[i].high > hh) hh = rates[i].high;
   return hh;
}

double LowestLowPrevN(const MqlRates &rates[], int startIndex, int count)
{
   double ll = DBL_MAX;
   for(int i=startIndex;i<startIndex+count;i++)
      if(rates[i].low < ll) ll = rates[i].low;
   return ll;
}

bool ReversalByBOS(bool wantLong, datetime &bosBarTime)
{
   int need = BOS_LookbackBars + 3;
   MqlRates r[];
   ArraySetAsSeries(r, true);

   if(CopyRates(_Symbol, EntryTF, 0, need, r) < need) return false;

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

bool CandleBullish(const MqlRates &c) { return (c.close > c.open); }
bool CandleBearish(const MqlRates &c) { return (c.close < c.open); }

bool TouchesZone(const MqlRates &c, const Zone &z)
{
   if(!z.valid) return false;
   return (c.low <= z.high && c.high >= z.low);
}

// FVG scan using chronological order (oldest -> newest)
bool FindMostRecentFVG(Zone &outGap, bool bullish)
{
   outGap.valid = false;

   int need = MathMax(30, ScanBarsFVG);
   MqlRates r[];
   ArraySetAsSeries(r, true);

   int got = CopyRates(_Symbol, EntryTF, 1, need, r); // closed bars only
   if(got < 10) return false;

   // Convert to chronological for easy consecutive indexing
   ArrayReverse(r);

   // Bullish FVG: bar1.high < bar3.low
   // Bearish FVG: bar1.low  > bar3.high
   for(int i=0;i<=ArraySize(r)-3;i++)
   {
      MqlRates b1 = r[i];
      MqlRates b3 = r[i+2];

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

// IFVG approximation
bool ReversalByIFVG(bool wantLong, datetime &sigTime)
{
   Zone gap;

   if(wantLong)
   {
      if(!FindMostRecentFVG(gap, false)) return false; // bearish gap
   }
   else
   {
      if(!FindMostRecentFVG(gap, true)) return false; // bullish gap
   }

   MqlRates r2[2];
   if(CopyRates(_Symbol, EntryTF, 0, 2, r2) != 2) return false;

   MqlRates lastClosed = r2[1];

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

bool ComputeLegExtremes(datetime sweepSrv, datetime reversalSrv, double &outHi, double &outLo)
{
   if(reversalSrv <= sweepSrv) return false;

   MqlRates r[];
   int copied = CopyRates(_Symbol, EntryTF, sweepSrv, reversalSrv, r);
   if(copied <= 0) return false;

   outHi = -DBL_MAX;
   outLo =  DBL_MAX;

   for(int i=0;i<copied;i++)
   {
      if(r[i].high > outHi) outHi = r[i].high;
      if(r[i].low  < outLo) outLo = r[i].low;
   }
   return (outHi > -DBL_MAX && outLo < DBL_MAX && outHi > outLo);
}

bool ReversalByFib79(bool wantLong, double hi, double lo, datetime &sigTime)
{
   if(hi <= lo) return false;

   double thrLong  = lo + 0.79 * (hi - lo);
   double thrShort = hi - 0.79 * (hi - lo);

   MqlRates r2[2];
   if(CopyRates(_Symbol, EntryTF, 0, 2, r2) != 2) return false;

   MqlRates lastClosed = r2[1];

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

void BuildContinuationZones(bool wantLong, datetime reversalTimeSrv)
{
   equilibrium = (legHigh + legLow) * 0.5;

   zFvg.valid = false;
   if(UseFVG_Continuation)
   {
      Zone gap;
      if(FindMostRecentFVG(gap, wantLong) && gap.valid)
      {
         zFvg = gap;
         zFvg.valid = true;
      }
   }

   zOb.valid = false;
   zBreaker.valid = false;

   // Use recent closed bars and pick structures that happened before the reversal time
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int got = CopyRates(_Symbol, EntryTF, 1, 200, r);
   if(got < 10) return;

   // Make chronological
   ArrayReverse(r);

   // OB: last opposite candle before reversal
   if(UseOB_Continuation)
   {
      for(int i=ArraySize(r)-1; i>=0; i--)
      {
         if(r[i].time > reversalTimeSrv) continue;

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

   // Breaker approximation
   if(UseBreaker_Continuation)
   {
      for(int i=0;i<ArraySize(r)-1;i++)
      {
         if(r[i+1].time > reversalTimeSrv) continue;

         MqlRates a = r[i];
         MqlRates b = r[i+1];

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

bool ContinuationConfirmed(bool wantLong, datetime &signalBarTime)
{
   MqlRates r2[2];
   if(CopyRates(_Symbol, EntryTF, 0, 2, r2) != 2) return false;

   MqlRates lastClosed = r2[1];

   bool dirClose = wantLong ? CandleBullish(lastClosed) : CandleBearish(lastClosed);
   if(!dirClose) return false;

   // EQ continuation
   if(UseEQ_Continuation)
   {
      bool touchedEq = wantLong ? (lastClosed.low <= equilibrium) : (lastClosed.high >= equilibrium);
      bool closedBeyond = wantLong ? (lastClosed.close > equilibrium) : (lastClosed.close < equilibrium);
      if(touchedEq && closedBeyond)
      {
         signalBarTime = lastClosed.time;
         return true;
      }
   }

   // FVG continuation
   if(UseFVG_Continuation && zFvg.valid && TouchesZone(lastClosed, zFvg))
   {
      bool closedBeyond = wantLong ? (lastClosed.close > zFvg.high) : (lastClosed.close < zFvg.low);
      if(closedBeyond)
      {
         signalBarTime = lastClosed.time;
         return true;
      }
   }

   // OB continuation
   if(UseOB_Continuation && zOb.valid && TouchesZone(lastClosed, zOb))
   {
      bool closedBeyond = wantLong ? (lastClosed.close > zOb.high) : (lastClosed.close < zOb.low);
      if(closedBeyond)
      {
         signalBarTime = lastClosed.time;
         return true;
      }
   }

   // Breaker continuation
   if(UseBreaker_Continuation && zBreaker.valid && TouchesZone(lastClosed, zBreaker))
   {
      bool closedBeyond = wantLong ? (lastClosed.close > zBreaker.high) : (lastClosed.close < zBreaker.low);
      if(closedBeyond)
      {
         signalBarTime = lastClosed.time;
         return true;
      }
   }

   return false;
}

double FindNearestTP(bool wantLong, double entryPrice)
{
   double best = 0.0;
   if(ArraySize(levels) <= 0) return 0.0;

   if(wantLong)
   {
      double minAbove = DBL_MAX;
      for(int i=0;i<ArraySize(levels);i++)
      {
         if(!levels[i].isHigh) continue;
         if(levels[i].price <= entryPrice) continue;
         if(levels[i].price < minAbove) minAbove = levels[i].price;
      }
      if(minAbove < DBL_MAX) best = minAbove;
   }
   else
   {
      double maxBelow = -DBL_MAX;
      for(int i=0;i<ArraySize(levels);i++)
      {
         if(levels[i].isHigh) continue;
         if(levels[i].price >= entryPrice) continue;
         if(levels[i].price > maxBelow) maxBelow = levels[i].price;
      }
      if(maxBelow > -DBL_MAX) best = maxBelow;
   }

   return best;
}

// Money per 1.0 price unit per 1 lot
double MoneyPerPriceUnitPerLot()
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0.0 || tickSize <= 0.0) return 0.0;
   return tickValue / tickSize;
}

double CalcLotsByRisk(double entry, double sl)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (RiskPercent / 100.0);

   double slDist = MathAbs(entry - sl);
   if(slDist <= 0.0) return 0.0;

   double moneyPerUnit = MoneyPerPriceUnitPerLot();
   if(moneyPerUnit <= 0.0) return 0.0;

   double riskPerLot = slDist * moneyPerUnit;
   if(riskPerLot <= 0.0) return 0.0;

   double lots = riskAmount / riskPerLot;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(stepLot <= 0.0) stepLot = 0.01;

   lots = MathFloor(lots / stepLot) * stepLot;
   lots = MathMax(minLot, lots);
   lots = MathMin(maxLot, lots);
   lots = MathMin(MaxLots, lots);

   return lots;
}

void TryEnterTrade()
{
   if(HasOpenPosition()) return;

   double sprPts = CurrentSpreadPoints();
   if(sprPts > (double)MaxSpreadPoints)
   {
      if(PrintDebug)
         Print("SKIP entry: spread too high sprPts=", DoubleToString(sprPts,1),
               " > MaxSpreadPoints=", MaxSpreadPoints);
      ResetState();
      return;
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry = setupLong ? ask : bid;

   // Initial SL from leg extremes + buffer
   double sl = setupLong
      ? (legLow  - (double)SLBufferPoints * _Point)
      : (legHigh + (double)SLBufferPoints * _Point);

   // Enforce minimum stop distance (avoid narrow SL)
   double slDistPts = MathAbs(entry - sl) / _Point;
   if(slDistPts < (double)MinStopPoints)
   {
      if(setupLong) sl = entry - (double)MinStopPoints * _Point;
      else         sl = entry + (double)MinStopPoints * _Point;
      slDistPts = (double)MinStopPoints;
   }

   double lots = CalcLotsByRisk(entry, sl);
   if(lots <= 0.0)
   {
      if(PrintDebug) Print("Lots calc failed (tickValue/tickSize?).");
      ResetState();
      return;
   }

   // TP: nearest opposite liquidity, but enforce MinTargetPoints and MinRR
   double tp = FindNearestTP(setupLong, entry);

   double risk = MathAbs(entry - sl);
   if(risk <= 0.0)
   {
      ResetState();
      return;
   }

   double rrTp = setupLong ? entry + MathMax((double)MinRR, (double)DefaultRR_TP) * risk
                           : entry - MathMax((double)MinRR, (double)DefaultRR_TP) * risk;

   // If no liquidity TP found, use RR TP
   if(tp <= 0.0) tp = rrTp;

   // Ensure TP direction is correct
   if(setupLong && tp <= entry) tp = rrTp;
   if(!setupLong && tp >= entry) tp = rrTp;

   // Enforce minimum target distance
   double tpDistPts = MathAbs(tp - entry) / _Point;
   if(tpDistPts < (double)MinTargetPoints)
   {
      // push TP to at least MinTargetPoints, and also keep MinRR
      double minTpByDist = setupLong ? entry + (double)MinTargetPoints * _Point
                                     : entry - (double)MinTargetPoints * _Point;

      double minTpByRR = setupLong ? entry + (double)MinRR * risk
                                   : entry - (double)MinRR * risk;

      if(setupLong) tp = MathMax(minTpByDist, minTpByRR);
      else         tp = MathMin(minTpByDist, minTpByRR);
   }

   trade.SetDeviationInPoints(DeviationPoints);

   bool ok = false;
   if(setupLong) ok = trade.Buy(lots, _Symbol, entry, sl, tp);
   else          ok = trade.Sell(lots, _Symbol, entry, sl, tp);

   if(PrintDebug)
   {
      if(ok)
         Print("ENTRY ", (setupLong ? "LONG" : "SHORT"),
               " lots=", DoubleToString(lots,2),
               " entry=", DoubleToString(entry,_Digits),
               " sl=", DoubleToString(sl,_Digits),
               " tp=", DoubleToString(tp,_Digits),
               " sprPts=", DoubleToString(sprPts,1));
      else
         Print("ENTRY FAILED: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }

   ResetState();
}

// ---------------- MT5 lifecycle ----------------

int OnInit()
{
   BuildLevelsForToday();
   return INIT_SUCCEEDED;
}

void OnTick()
{
   datetime nowSrv = TimeCurrent();

   // New ET day -> rebuild levels + reset state
   datetime etDay = GetETDayStart(nowSrv);
   if(etDay != g_etDayStart)
      BuildLevelsForToday();

   if(!InTradeWindow(nowSrv)) return;
   if(HasOpenPosition()) return;

   // Work only on new closed bars
   datetime closedBarTime = GetLastClosedBarTime(EntryTF);
   bool newClosedBar = (closedBarTime != 0 && closedBarTime != lastClosedBarProcessed);
   if(newClosedBar) lastClosedBarProcessed = closedBarTime;

   if(state == STATE_IDLE)
   {
      bool wantLong=false;
      double lvl=0.0;

      if(DetectSweep(wantLong, lvl))
      {
         setupLong = wantLong;
         sweepLevelPrice = lvl;
         sweepTimeSrv = nowSrv;

         state = STATE_WAIT_REVERSAL;
         barsSinceSweep = 0;
         barsSinceReversal = 0;

         if(PrintDebug)
            Print(TimeToString(nowSrv, TIME_DATE|TIME_SECONDS),
                  " SWEEP ", (setupLong ? "LOW" : "HIGH"),
                  " lvl=", DoubleToString(lvl,_Digits),
                  " -> WAIT_REVERSAL");
      }
      return;
   }

   if(state == STATE_WAIT_REVERSAL)
   {
      if(newClosedBar) barsSinceSweep++;

      if(barsSinceSweep > MaxWaitBarsForReversal)
      {
         if(PrintDebug) Print(TimeToString(nowSrv, TIME_DATE|TIME_SECONDS), " TIMEOUT REVERSAL -> IDLE");
         ResetState();
         return;
      }

      datetime sigTime = 0;
      bool revOk = false;

      if(UseBOS_Reversal && ReversalByBOS(setupLong, sigTime))
         revOk = true;

      if(!revOk && UseIFVG_Reversal && ReversalByIFVG(setupLong, sigTime))
         revOk = true;

      if(!revOk && UseFib79_Reversal)
      {
         MqlRates r2[2];
         if(CopyRates(_Symbol, EntryTF, 0, 2, r2) == 2)
         {
            datetime candidate = r2[1].time;
            double hi, lo;
            if(ComputeLegExtremes(sweepTimeSrv, candidate, hi, lo))
            {
               if(ReversalByFib79(setupLong, hi, lo, sigTime))
                  revOk = true;
            }
         }
      }

      if(!revOk) return;

      double hi, lo;
      if(!ComputeLegExtremes(sweepTimeSrv, sigTime, hi, lo))
      {
         if(PrintDebug) Print("Leg extremes failed -> IDLE");
         ResetState();
         return;
      }

      legHigh = hi;
      legLow  = lo;

      BuildContinuationZones(setupLong, sigTime);

      state = STATE_WAIT_CONTINUATION;
      barsSinceReversal = 0;

      if(PrintDebug)
         Print(TimeToString(sigTime, TIME_DATE|TIME_SECONDS),
               " REVERSAL confirmed -> WAIT_CONTINUATION eq=",
               DoubleToString(equilibrium,_Digits));

      return;
   }

   if(state == STATE_WAIT_CONTINUATION)
   {
      if(newClosedBar) barsSinceReversal++;

      if(barsSinceReversal > MaxWaitBarsForContinuation)
      {
         if(PrintDebug) Print(TimeToString(nowSrv, TIME_DATE|TIME_SECONDS), " TIMEOUT CONTINUATION -> IDLE");
         ResetState();
         return;
      }

      datetime contTime;
      if(ContinuationConfirmed(setupLong, contTime))
      {
         TryEnterTrade();
      }
      return;
   }
}