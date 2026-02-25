//+------------------------------------------------------------------+
//| ConsistentDailyProfit_EA_CENT_v2.mq5                            |
//| CENT ACCOUNT VERSION - USC (US Cents)                           |
//| Daily Target: 500-1000 usc (5-10 USD equivalent)               |
//| Daily Loss Limit: 50-150 usc (0.50-1.50 USD equivalent)        |
//| Initial Deposit: 550 usc (~5.50 USD)                           |
//+------------------------------------------------------------------+
#property copyright "Consistent Daily Profit - Cent Account v2"
#property link      ""
#property version   "6.10"
#property strict

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//| ALL profit/loss values are in usc (US Cents)                    |
//| Conversion: 100 usc = 1.00 USD                                  |
//+------------------------------------------------------------------+

// CHANGED: DailyProfitTargetMin from 2500.0 usc to 500.0 usc (= $5 USD)
// CHANGED: DailyProfitTargetMax from 5500.0 usc to 1000.0 usc (= $10 USD)
input double DailyProfitTargetMin = 500.0;   // Min daily profit target in usc (500 usc = $5 USD)
input double DailyProfitTargetMax = 1000.0;  // Max daily profit target in usc (1000 usc = $10 USD)

// CHANGED: DailyLossLimit from 150.0 usc to 100.0 usc default (range: 50-150 usc = $0.50-$1.50 USD)
input double DailyLossLimit       = 100.0;   // Daily loss limit in usc (50-150 usc = $0.50-$1.50 USD)

// CHANGED: ProfitPerLotIncrease scaled down from 500 usc to 100 usc
// Rationale: smaller account (550 usc) needs finer lot-step granularity
// Every 100 usc profit (~$1 USD) = +0.01 lot increase
input double ProfitPerLotIncrease = 100.0;   // Increase lot by 0.01 per X usc profit (100 usc = $1 USD)

input double BaseLot              = 0.01;    // Starting lot size (minimum safe for 550 usc account)
input double MaxLot               = 0.30;    // Maximum lot size cap (reduced for 550 usc safety)

// --- Trade Parameters (unchanged) ---
input int    StopLoss             = 30;      // Stop Loss in points
input int    TakeProfit           = 600;      // Take Profit in points
input int    TrailingStop         = 8;       // Trailing Stop points (auto trades only)
input int    TrailingStep         = 10;      // Trailing Step points (auto trades only)
input int    MagicNumber          = 123;     // EA Magic Number
input int    Slippage             = 3;       // Max slippage in points
input int    MaxDailyTrades       = 100;     // Max trades per day
input int    MinDailyTrades       = 10;      // Minimum trades per day (force-trade guarantee)

// --- Indicator Parameters (unchanged) ---
input int    RSIPeriod            = 10;      // RSI Period
input int    FastMAPeriod         = 8;       // Fast EMA period
input int    SlowMAPeriod         = 21;      // Slow EMA period
input int    ADXPeriod            = 10;      // ADX Period
input double ADXThreshold         = 18.0;    // ADX minimum threshold for momentum

// --- Manual Trade Management (unchanged) ---
input bool   ManageManualTrades   = true;    // Enable auto SL/TP for manual entries
input bool   UseAlert             = false;   // Enable audio/visual alerts

//+------------------------------------------------------------------+
//| ADVANCED MANUAL TRAILING SETTINGS (unchanged logic)             |
//+------------------------------------------------------------------+
input group "=== Manual Entry Trailing Settings ==="
input bool   UseAdvancedManualTrailing = true; // Advanced trailing for manual trades
input int    ManualSecureAt       = 12;      // Lock in profit after X points gain
input int    ManualSecureAmount   = 6;       // Move SL to BE + this many points
input int    ManualTrailStart     = 20;      // Begin aggressive trailing after X points
input int    ManualTrailStop      = 10;      // Trail distance behind price (points)
input int    ManualTrailStep      = 3;       // Minimum SL movement step (points)
input bool   ManualUseSLAtStructure = true;  // Use swing structure for initial SL
input int    ManualSLBufferPips   = 5;       // Buffer beyond swing high/low (points)

//+------------------------------------------------------------------+
//| ACCOUNT REFERENCE (informational)                                |
//| Cent Account: 1 USC = 0.01 USD                                  |
//| 550 usc deposit = $5.50 USD                                     |
//| 500 usc min target = $5.00 USD/day                              |
//| 1000 usc max target = $10.00 USD/day                            |
//| 50-150 usc loss limit = $0.50-$1.50 USD/day                    |
//+------------------------------------------------------------------+

//--- Global Variables
int      rsiHandle;
int      fastMAHandle;
int      slowMAHandle;
int      adxHandle;
double   rsiBuffer[];
double   fastMABuffer[];
double   slowMABuffer[];
double   adxBuffer[];

datetime lastTradeDate        = 0;
int      dailyTradeCount      = 0;
double   dailyStartEquity     = 0;
double   dailyCurrentProfit   = 0;   // in usc
double   accountStartBalance  = 0;   // in usc (initial balance at EA start)
double   totalProfit          = 0;   // total profit since EA started, in usc
double   lastBuyPrice         = 0;
double   lastSellPrice        = 0;
datetime lastTradeTime        = 0;
bool     dailyTargetReached   = false;
bool     dailyMinTargetReached= false; // true when 500 usc min hit (keep trading to 1000)
double   currentLotSize       = 0.01;

//--- Manual Trade Tracking Structure (unchanged)
struct ManualTradeInfo
  {
   ulong    ticket;
   datetime detectedTime;
   bool     slModified;
   bool     tpModified;
   bool     isNew;
  };
ManualTradeInfo g_manualTrades[];
double   g_point;
int      g_digits;

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Create indicator handles (unchanged)
   rsiHandle    = iRSI(_Symbol, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);
   fastMAHandle = iMA(_Symbol, PERIOD_CURRENT, FastMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   slowMAHandle = iMA(_Symbol, PERIOD_CURRENT, SlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   adxHandle    = iADX(_Symbol, PERIOD_CURRENT, ADXPeriod);

   if(rsiHandle    == INVALID_HANDLE || fastMAHandle == INVALID_HANDLE ||
      slowMAHandle == INVALID_HANDLE || adxHandle    == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create one or more indicator handles");
      return(INIT_FAILED);
     }

   ArraySetAsSeries(rsiBuffer,    true);
   ArraySetAsSeries(fastMABuffer, true);
   ArraySetAsSeries(slowMABuffer, true);
   ArraySetAsSeries(adxBuffer,    true);

   // Store initial balance in usc
   accountStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   currentLotSize      = BaseLot;

   // Point/digits for trailing (unchanged logic)
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(g_digits == 3 || g_digits == 5) g_point *= 10;

   // Startup summary
   Print("===========================================");
   Print("=== CENT ACCOUNT EA v6.10 STARTED      ===");
   Print("===========================================");
   Print("Currency Unit    : usc (US Cents)");
   Print("Account Currency : ", AccountInfoString(ACCOUNT_CURRENCY));
   Print("Starting Balance : ", DoubleToString(accountStartBalance, 2),
         " usc  (~$", DoubleToString(accountStartBalance / 100.0, 2), " USD)");
   Print("-------------------------------------------");
   Print("Min Daily Target : ", DailyProfitTargetMin,
         " usc  (~$", DoubleToString(DailyProfitTargetMin / 100.0, 2), " USD)");
   Print("Max Daily Target : ", DailyProfitTargetMax,
         " usc  (~$", DoubleToString(DailyProfitTargetMax / 100.0, 2), " USD)");
   Print("Daily Loss Limit : ", DailyLossLimit,
         " usc  (~$", DoubleToString(DailyLossLimit / 100.0, 2), " USD)");
   Print("-------------------------------------------");
   Print("Base Lot Size    : ", BaseLot);
   Print("Max Lot Size     : ", MaxLot);
   Print("Lot Step Every   : ", ProfitPerLotIncrease,
         " usc profit (~$", DoubleToString(ProfitPerLotIncrease / 100.0, 2), " USD)");
   Print("-------------------------------------------");
   if(UseAdvancedManualTrailing)
      Print("Manual Trailing  : ENABLED | Secure@", ManualSecureAt,
            "pts | Trail@", ManualTrailStart, "pts");
   else
      Print("Manual Trailing  : DISABLED");
   Print("===========================================");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(rsiHandle);
   IndicatorRelease(fastMAHandle);
   IndicatorRelease(slowMAHandle);
   IndicatorRelease(adxHandle);
   ObjectsDeleteAll(0, "M1MT_");

   double finalBalance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double sessionProfit  = finalBalance - accountStartBalance; // in usc

   Print("===========================================");
   Print("=== CENT ACCOUNT EA STOPPED            ===");
   Print("===========================================");
   Print("Final Balance    : ", DoubleToString(finalBalance, 2),
         " usc  (~$", DoubleToString(finalBalance / 100.0, 2), " USD)");
   Print("Session Profit   : ", DoubleToString(sessionProfit, 2),
         " usc  (~$", DoubleToString(sessionProfit / 100.0, 2), " USD)");
   Print("===========================================");
  }

//+------------------------------------------------------------------+
//| CalculateLotSize                                                  |
//| CHANGED: scaling based on usc profit units                       |
//| Every 100 usc (~$1 USD) of total profit = +0.01 lot             |
//+------------------------------------------------------------------+
double CalculateLotSize()
  {
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   // CHANGED: totalProfit is in usc; ProfitPerLotIncrease is also in usc
   totalProfit = currentBalance - accountStartBalance;

   // Only scale up if in profit
   int lotSteps = 0;
   if(totalProfit > 0)
      lotSteps = (int)(totalProfit / ProfitPerLotIncrease);

   double lots = BaseLot + (lotSteps * 0.01);

   // Normalize to broker lot step
   double lotStep       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot        = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxAllowedLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / lotStep) * lotStep;

   // Enforce limits
   if(lots < minLot)        lots = minLot;
   if(lots > MaxLot)        lots = MaxLot;         // CHANGED: MaxLot now 0.30 (safer for 550 usc)
   if(lots > maxAllowedLot) lots = maxAllowedLot;

   if(lots != currentLotSize)
     {
      Print("--- LOT SIZE UPDATE ---");
      Print("Total Profit : ", DoubleToString(totalProfit, 2),
            " usc (~$", DoubleToString(totalProfit / 100.0, 2), " USD)");
      Print("New Lot Size : ", DoubleToString(lots, 2),
            " (step #", lotSteps, ")");
      currentLotSize = lots;
     }

   return lots;
  }

//+------------------------------------------------------------------+
//| DetectManualTrades (unchanged logic)                             |
//+------------------------------------------------------------------+
void DetectManualTrades()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;

      // Skip if already tracked
      bool alreadyTracked = false;
      for(int j = 0; j < ArraySize(g_manualTrades); j++)
        {
         if(g_manualTrades[j].ticket == ticket) { alreadyTracked = true; break; }
        }
      if(alreadyTracked) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      // Only pure manual trades (magic = 0)
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      if(posMagic != 0) continue;

      int idx = ArraySize(g_manualTrades);
      ArrayResize(g_manualTrades, idx + 1);
      g_manualTrades[idx].ticket       = ticket;
      g_manualTrades[idx].detectedTime = TimeCurrent();
      g_manualTrades[idx].slModified   = false;
      g_manualTrades[idx].tpModified   = false;
      g_manualTrades[idx].isNew        = true;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      Print(">>> MANUAL TRADE DETECTED | Ticket #", ticket,
            " | ", (type == POSITION_TYPE_BUY ? "BUY" : "SELL"));
     }

   // Remove closed trades from tracking array
   for(int i = ArraySize(g_manualTrades) - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_manualTrades[i].ticket))
         ArrayRemove(g_manualTrades, i, 1);
     }
  }

//+------------------------------------------------------------------+
//| ApplyManualInitialSLTP (unchanged logic)                         |
//+------------------------------------------------------------------+
void ApplyManualInitialSLTP()
  {
   if(!UseAdvancedManualTrailing) return;

   for(int i = 0; i < ArraySize(g_manualTrades); i++)
     {
      if(g_manualTrades[i].slModified && g_manualTrades[i].tpModified) continue;

      ulong ticket = g_manualTrades[i].ticket;
      if(!PositionSelectByTicket(ticket)) continue;

      double currentSL   = PositionGetDouble(POSITION_SL);
      double currentTP   = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double bid         = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask         = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      bool   modify      = false;
      double newSL       = currentSL;
      double newTP       = currentTP;

      // Apply SL if not already set
      if(currentSL == 0 || !g_manualTrades[i].slModified)
        {
         if(type == POSITION_TYPE_BUY)
           {
            newSL = NormalizeDouble(ask - StopLoss * g_point, g_digits);
            if(ManualUseSLAtStructure)
              {
               double swingLow = FindRecentSwingLow(20);
               if(swingLow > 0 && swingLow < ask - 10 * g_point)
                  newSL = NormalizeDouble(swingLow - ManualSLBufferPips * g_point, g_digits);
              }
           }
         else
           {
            newSL = NormalizeDouble(bid + StopLoss * g_point, g_digits);
            if(ManualUseSLAtStructure)
              {
               double swingHigh = FindRecentSwingHigh(20);
               if(swingHigh > 0 && swingHigh > bid + 10 * g_point)
                  newSL = NormalizeDouble(swingHigh + ManualSLBufferPips * g_point, g_digits);
              }
           }
         if(newSL != currentSL) { modify = true; g_manualTrades[i].slModified = true; }
        }

      // Apply TP if not already set
      if(TakeProfit > 0 && (currentTP == 0 || !g_manualTrades[i].tpModified))
        {
         newTP = (type == POSITION_TYPE_BUY)
                 ? NormalizeDouble(ask + TakeProfit * g_point, g_digits)
                 : NormalizeDouble(bid - TakeProfit * g_point, g_digits);
         modify = true;
         g_manualTrades[i].tpModified = true;
        }

      if(modify)
        {
         MqlTradeRequest req = {};
         MqlTradeResult  res = {};
         req.action   = TRADE_ACTION_SLTP;
         req.position = ticket;
         req.symbol   = _Symbol;
         req.sl       = newSL;
         req.tp       = newTP;
         if(OrderSend(req, res))
           {
            Print("Manual SL/TP Set | #", ticket, " | SL:", newSL, " TP:", newTP);
            string name = "M1MT_SL_" + IntegerToString(ticket);
            ObjectCreate(0, name, OBJ_ARROW, 0, TimeCurrent(), newSL);
            ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 159);
            ObjectSetInteger(0, name, OBJPROP_COLOR, clrOrange);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| FindRecentSwingLow (unchanged)                                   |
//+------------------------------------------------------------------+
double FindRecentSwingLow(int bars)
  {
   double lowest = DBL_MAX;
   for(int i = 2; i < bars; i++)
     {
      double low = iLow(_Symbol, PERIOD_CURRENT, i);
      if(low < iLow(_Symbol, PERIOD_CURRENT, i-1) &&
         low < iLow(_Symbol, PERIOD_CURRENT, i+1) &&
         low < lowest) lowest = low;
     }
   return (lowest == DBL_MAX) ? 0 : lowest;
  }

//+------------------------------------------------------------------+
//| FindRecentSwingHigh (unchanged)                                  |
//+------------------------------------------------------------------+
double FindRecentSwingHigh(int bars)
  {
   double highest = 0;
   for(int i = 2; i < bars; i++)
     {
      double high = iHigh(_Symbol, PERIOD_CURRENT, i);
      if(high > iHigh(_Symbol, PERIOD_CURRENT, i-1) &&
         high > iHigh(_Symbol, PERIOD_CURRENT, i+1) &&
         high > highest) highest = high;
     }
   return highest;
  }

//+------------------------------------------------------------------+
//| ManageAdvancedManualTrailing (unchanged logic)                   |
//+------------------------------------------------------------------+
void ManageAdvancedManualTrailing()
  {
   if(!UseAdvancedManualTrailing) return;

   for(int i = 0; i < ArraySize(g_manualTrades); i++)
     {
      ulong ticket = g_manualTrades[i].ticket;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      ENUM_POSITION_TYPE type      = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double             openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double             currentSL = PositionGetDouble(POSITION_SL);
      double             currentTP = PositionGetDouble(POSITION_TP);
      double             bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double             ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double             profitPts = 0;
      double             newSL     = 0;
      bool               modify    = false;
      string             action    = "";

      if(type == POSITION_TYPE_BUY)
        {
         profitPts = (bid - openPrice) / g_point;

         // Stage 1: Secure early (break-even + small buffer)
         if(profitPts >= ManualSecureAt)
           {
            double secureSL = openPrice + ManualSecureAmount * g_point;
            if(currentSL < secureSL)
              { newSL = NormalizeDouble(secureSL, g_digits); modify = true; action = "SECURE"; }
           }

         // Stage 2: Aggressive trailing
         if(profitPts >= ManualTrailStart)
           {
            double trailSL  = bid - ManualTrailStop * g_point;
            double floorSL  = openPrice + ManualSecureAmount * g_point;
            if(trailSL < floorSL) trailSL = floorSL;

            int    level    = (int)(profitPts / 10) * 10;
            double lockSL   = openPrice + (level - 5) * g_point;
            if(lockSL > trailSL) trailSL = lockSL;

            if(trailSL > currentSL + ManualTrailStep * g_point)
              {
               newSL  = NormalizeDouble(trailSL, g_digits);
               modify = true;
               action = (action == "SECURE") ? "SECURE+TRAIL" : "TRAIL";
              }
           }
        }
      else // SELL
        {
         profitPts = (openPrice - ask) / g_point;

         // Stage 1: Secure early
         if(profitPts >= ManualSecureAt)
           {
            double secureSL = openPrice - ManualSecureAmount * g_point;
            if(currentSL > secureSL || currentSL == 0)
              { newSL = NormalizeDouble(secureSL, g_digits); modify = true; action = "SECURE"; }
           }

         // Stage 2: Aggressive trailing
         if(profitPts >= ManualTrailStart)
           {
            double trailSL  = ask + ManualTrailStop * g_point;
            double ceilSL   = openPrice - ManualSecureAmount * g_point;
            if(trailSL > ceilSL) trailSL = ceilSL;

            int    level    = (int)(profitPts / 10) * 10;
            double lockSL   = openPrice - (level - 5) * g_point;
            if(lockSL < trailSL) trailSL = lockSL;

            if(currentSL == 0 || trailSL < currentSL - ManualTrailStep * g_point)
              {
               newSL  = NormalizeDouble(trailSL, g_digits);
               modify = true;
               action = (action == "SECURE") ? "SECURE+TRAIL" : "TRAIL";
              }
           }
        }

      if(modify)
        {
         MqlTradeRequest req = {};
         MqlTradeResult  res = {};
         req.action   = TRADE_ACTION_SLTP;
         req.position = ticket;
         req.symbol   = _Symbol;
         req.sl       = newSL;
         req.tp       = currentTP;
         if(OrderSend(req, res))
           {
            Print(action, " #", ticket,
                  " | Profit: ", DoubleToString(profitPts, 1), " pts",
                  " | New SL: ", DoubleToString(newSL, g_digits));
            string name = "M1MT_SL_" + IntegerToString(ticket);
            if(ObjectFind(0, name) >= 0)
              {
               ObjectMove(0, name, 0, TimeCurrent(), newSL);
               ObjectSetInteger(0, name, OBJPROP_COLOR, clrLime);
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| UpdateDailyStats                                                  |
//| CHANGED: all profit/loss comparisons now use usc targets         |
//| Min target = 500 usc ($5 USD) — keep trading after this         |
//| Max target = 1000 usc ($10 USD) — close all and stop            |
//| Loss limit = 50-150 usc (default 100 usc = $1 USD)             |
//+------------------------------------------------------------------+
void UpdateDailyStats()
  {
   datetime    now = TimeCurrent();
   MqlDateTime currDT, lastDT;
   TimeToStruct(now,          currDT);
   TimeToStruct(lastTradeDate, lastDT);

   // Reset stats on new trading day
   if(currDT.day != lastDT.day || lastTradeDate == 0)
     {
      dailyTradeCount        = 0;
      dailyStartEquity       = AccountInfoDouble(ACCOUNT_EQUITY);  // in usc
      dailyTargetReached     = false;
      dailyMinTargetReached  = false;
      lastTradeDate          = now;
      lastBuyPrice           = 0;
      lastSellPrice          = 0;

      CalculateLotSize(); // recalculate lot for new day based on cumulative profit

      Print("===========================================");
      Print("=== NEW TRADING DAY                    ===");
      Print("===========================================");
      Print("Min Target  : ", DailyProfitTargetMin,
            " usc (~$", DoubleToString(DailyProfitTargetMin / 100.0, 2), " USD)");
      Print("Max Target  : ", DailyProfitTargetMax,
            " usc (~$", DoubleToString(DailyProfitTargetMax / 100.0, 2), " USD)");
      Print("Loss Limit  : ", DailyLossLimit,
            " usc (~$", DoubleToString(DailyLossLimit / 100.0, 2), " USD)");
      Print("Lot Size    : ", DoubleToString(currentLotSize, 2));
      Print("Total Profit: ", DoubleToString(totalProfit, 2),
            " usc (~$", DoubleToString(totalProfit / 100.0, 2), " USD)");
      Print("Start Equity: ", DoubleToString(dailyStartEquity, 2), " usc");
      Print("===========================================");
     }

   // CHANGED: dailyCurrentProfit is in usc
   double currentEquity  = AccountInfoDouble(ACCOUNT_EQUITY); // in usc
   dailyCurrentProfit    = currentEquity - dailyStartEquity;

   // --- CHANGED: Check MIN target (500 usc) - log only, keep trading ---
   if(dailyCurrentProfit >= DailyProfitTargetMin && !dailyMinTargetReached)
     {
      dailyMinTargetReached = true;
      Print("*** MIN TARGET HIT: ", DoubleToString(dailyCurrentProfit, 2),
            " usc (~$", DoubleToString(dailyCurrentProfit / 100.0, 2),
            " USD) | Continuing to MAX target ", DailyProfitTargetMax, " usc ***");
     }

   // --- CHANGED: Check MAX target (1000 usc) - stop trading ---
   if(dailyCurrentProfit >= DailyProfitTargetMax && !dailyTargetReached)
     {
      dailyTargetReached = true;
      Print("*** MAX TARGET REACHED: ", DoubleToString(dailyCurrentProfit, 2),
            " usc (~$", DoubleToString(dailyCurrentProfit / 100.0, 2),
            " USD) | CLOSING ALL POSITIONS ***");
      CloseAllPositions("Daily MAX target reached");
     }

   // --- CHANGED: Check loss limit (50-150 usc, default 100 usc) ---
   if(dailyCurrentProfit <= -DailyLossLimit)
     {
      Print("*** LOSS LIMIT HIT: ", DoubleToString(dailyCurrentProfit, 2),
            " usc (~$", DoubleToString(dailyCurrentProfit / 100.0, 2),
            " USD) | STOPPING FOR THE DAY ***");
      CloseAllPositions("Daily loss limit reached");
      dailyTargetReached = true; // halt auto trading for the day
     }
  }

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Always update stats and manage manual trades
   UpdateDailyStats();

   if(ManageManualTrades || UseAdvancedManualTrailing)
     {
      DetectManualTrades();
      ApplyManualInitialSLTP();
      ManageAdvancedManualTrailing();
     }

   // Stop auto trading if daily target/loss limit hit
   if(dailyTargetReached) return;

   // Enforce max daily trade cap
   if(dailyTradeCount >= MaxDailyTrades) return;

   // Read indicator buffers
   if(CopyBuffer(rsiHandle,    0, 0, 5, rsiBuffer)   < 5) return;
   if(CopyBuffer(fastMAHandle, 0, 0, 5, fastMABuffer) < 5) return;
   if(CopyBuffer(slowMAHandle, 0, 0, 5, slowMABuffer) < 5) return;
   if(CopyBuffer(adxHandle,    0, 0, 3, adxBuffer)    < 3) return;

   double rsiNow     = rsiBuffer[0];
   double rsiPrev1   = rsiBuffer[1];
   double rsiPrev2   = rsiBuffer[2];
   double fastMA     = fastMABuffer[0];
   double fastMAPrev = fastMABuffer[1];
   double slowMA     = slowMABuffer[0];
   double adxNow     = adxBuffer[0];

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double ask   = tick.ask;
   double bid   = tick.bid;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // Count active EA positions
   int buyCount = 0, sellCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;
      long t = PositionGetInteger(POSITION_TYPE);
      if(t == POSITION_TYPE_BUY)  buyCount++;
      else if(t == POSITION_TYPE_SELL) sellCount++;
     }

   ManageAutoTrailingStops();
   double tradeLot = CalculateLotSize();

   // Signal logic (unchanged)
   bool isUptrend    = (fastMA > slowMA) && (fastMA > fastMAPrev);
   bool isDowntrend  = (fastMA < slowMA) && (fastMA < fastMAPrev);
   bool hasMomentum  = (adxNow > ADXThreshold);
   bool rsiBuy       = (rsiNow > rsiPrev1 && rsiPrev1 > rsiPrev2 && rsiNow < 60);
   bool rsiSell      = (rsiNow < rsiPrev1 && rsiPrev1 < rsiPrev2 && rsiNow > 40);
   bool buyDistOK    = (lastBuyPrice  == 0) || (MathAbs(ask - lastBuyPrice)  > 400 * point);
   bool sellDistOK   = (lastSellPrice == 0) || (MathAbs(bid - lastSellPrice) > 400 * point);

   datetime    now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   bool forceTrade = (dailyTradeCount < MinDailyTrades && dt.hour >= 17);

   // Execute BUY
   if((isUptrend || hasMomentum || forceTrade) && (rsiBuy || forceTrade) &&
      buyCount == 0 && buyDistOK)
     {
      if(OpenBuy(ask, point, tradeLot))
        { dailyTradeCount++; lastTradeTime = now; lastBuyPrice = ask; }
     }

   // Execute SELL
   if((isDowntrend || hasMomentum || forceTrade) && (rsiSell || forceTrade) &&
      sellCount == 0 && sellDistOK)
     {
      if(OpenSell(bid, point, tradeLot))
        { dailyTradeCount++; lastTradeTime = now; lastSellPrice = bid; }
     }
  }

//+------------------------------------------------------------------+
//| OpenBuy                                                           |
//| CHANGED: print statement shows usc daily P&L                    |
//+------------------------------------------------------------------+
bool OpenBuy(double price, double point, double lots)
  {
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = _Symbol;
   req.volume    = lots;
   req.type      = ORDER_TYPE_BUY;
   req.price     = price;
   req.sl        = NormalizeDouble(price - StopLoss  * point, _Digits);
   req.tp        = NormalizeDouble(price + TakeProfit * point, _Digits);
   req.deviation = Slippage;
   req.magic     = MagicNumber;
   req.comment   = "CentBUY_v2";

   if(!OrderSend(req, res)) { Print("BUY FAILED: ", GetLastError()); return false; }

   if(res.retcode == TRADE_RETCODE_DONE)
     {
      // CHANGED: daily P&L and progress shown in usc
      Print("BUY  ", DoubleToString(lots, 2), " lots @ ", DoubleToString(price, _Digits),
            " | Daily P&L: ", DoubleToString(dailyCurrentProfit, 2), " usc",
            " | To MAX: ", DoubleToString(dailyCurrentProfit / DailyProfitTargetMax * 100.0, 1), "%");
      if(UseAlert) Alert("BUY ", lots, " @ ", price);
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| OpenSell                                                          |
//| CHANGED: print statement shows usc daily P&L                    |
//+------------------------------------------------------------------+
bool OpenSell(double price, double point, double lots)
  {
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = _Symbol;
   req.volume    = lots;
   req.type      = ORDER_TYPE_SELL;
   req.price     = price;
   req.sl        = NormalizeDouble(price + StopLoss  * point, _Digits);
   req.tp        = NormalizeDouble(price - TakeProfit * point, _Digits);
   req.deviation = Slippage;
   req.magic     = MagicNumber;
   req.comment   = "CentSELL_v2";

   if(!OrderSend(req, res)) { Print("SELL FAILED: ", GetLastError()); return false; }

   if(res.retcode == TRADE_RETCODE_DONE)
     {
      // CHANGED: daily P&L and progress shown in usc
      Print("SELL ", DoubleToString(lots, 2), " lots @ ", DoubleToString(price, _Digits),
            " | Daily P&L: ", DoubleToString(dailyCurrentProfit, 2), " usc",
            " | To MAX: ", DoubleToString(dailyCurrentProfit / DailyProfitTargetMax * 100.0, 1), "%");
      if(UseAlert) Alert("SELL ", lots, " @ ", price);
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| ManageAutoTrailingStops (unchanged logic, EA trades only)        |
//+------------------------------------------------------------------+
void ManageAutoTrailingStops()
  {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue; // EA only

      long   posType   = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);

      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick)) continue;

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action   = TRADE_ACTION_SLTP;
      req.position = ticket;
      req.symbol   = _Symbol;
      req.tp       = PositionGetDouble(POSITION_TP);
      bool modify  = false;

      if(posType == POSITION_TYPE_BUY)
        {
         double newSL = NormalizeDouble(tick.bid - TrailingStop * point, _Digits);
         if(tick.bid > openPrice + TrailingStop * point && (newSL > currentSL || currentSL == 0))
           { req.sl = newSL; modify = true; }
        }
      else if(posType == POSITION_TYPE_SELL)
        {
         double newSL = NormalizeDouble(tick.ask + TrailingStop * point, _Digits);
         if(tick.ask < openPrice - TrailingStop * point && (newSL < currentSL || currentSL == 0))
           { req.sl = newSL; modify = true; }
        }

      if(modify) OrderSend(req, res);
     }
  }

//+------------------------------------------------------------------+
//| CloseAllPositions (unchanged logic)                              |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long posMagic = PositionGetInteger(POSITION_MAGIC);
      if(posMagic != MagicNumber && posMagic != 0) continue; // EA + manual

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action    = TRADE_ACTION_DEAL;
      req.position  = ticket;
      req.symbol    = _Symbol;
      req.volume    = PositionGetDouble(POSITION_VOLUME);
      req.deviation = Slippage;
      req.magic     = MagicNumber;

      long posType = PositionGetInteger(POSITION_TYPE);
      if(posType == POSITION_TYPE_BUY)
        { req.type = ORDER_TYPE_SELL; req.price = SymbolInfoDouble(_Symbol, SYMBOL_BID); }
      else
        { req.type = ORDER_TYPE_BUY;  req.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK); }

      if(OrderSend(req, res))
         Print("CLOSED #", ticket, " | Reason: ", reason,
               " | P&L: ", DoubleToString(dailyCurrentProfit, 2), " usc");
     }
  }
//+------------------------------------------------------------------+

