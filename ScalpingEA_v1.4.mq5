//+------------------------------------------------------------------+
//|                                        AutoScalper_EA_v4.mq5    |
//|              Auto Scalping EA - v4.0 + SMC Trailing SL          |
//|   Added: Secure Profit + SMC Trailing Stop (from Manual Trailer) |
//|   v4.1: Daily Profit Target Auto-Stop + Live Stats Panel         |
//+------------------------------------------------------------------+
#property copyright "AutoScalper EA v4"
#property version   "4.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- ================================================================
input group "=== ENTRY SETTINGS ==="
input double   InpStopDistance    = 50.0;   // Stop Order Distance (points)
input double   InpTakeProfit      = 150.0;  // Take Profit (points)
input double   InpStopLoss        = 50.0;   // Stop Loss (points)
input int      InpMaxSpread       = 50;     // Max Allowed Spread (points)

input group "=== LOT SCALING ==="
input double   InpBaseLot         = 0.01;   // Base Lot (per equity step)
input double   InpEquityStep      = 500.0;  // Equity Step ($500 per 0.01)

input group "=== BREAKEVEN ==="
input bool     InpUseBreakeven    = true;   // Enable Breakeven
input double   InpBEProfit        = 15.0;   // Profit to trigger BE (points)
input double   InpBEOffset        = 5.0;    // Points above/below entry

input group "=== SMC TRAILING SL (from Manual Trailer) ==="
input bool     InpUseSecureProfit = true;   // Enable Secure Profit (Stage 1)
input int      InpSecureAt        = 12;     // Secure profit at X points
input int      InpSecureAmount    = 6;      // Points to secure above/below entry
input bool     InpUseSMCTrailSL   = true;   // Enable SMC Trailing SL (Stage 2)
input int      InpSMCTrailStart   = 20;     // Start SMC trailing at X points profit
input int      InpSMCTrailStop    = 10;     // SMC trail distance from price (points)
input int      InpSMCTrailStep    = 3;      // SMC trail step sensitivity (points)

input group "=== SESSION FILTER (Server Time) ==="
input bool     InpUseSession      = true;   // Enable Session Filter
input int      InpSessionStart    = 7;      // Session Start Hour
input int      InpSessionEnd      = 20;     // Session End Hour

input group "=== CANDLE CONFIRMATION ==="
input bool     InpUseCandleConfirm = true;  // Use candle direction to confirm entry
input ENUM_TIMEFRAMES InpTF       = PERIOD_M5; // Timeframe for candle check

input group "=== RISK MANAGEMENT ==="
input int      InpCooldownBars    = 0;      // Bars cooldown after a loss
input int      InpMaxPositions    = 1;      // Max positions per direction
input bool     InpCloseOpposite   = true;   // Cancel opposite stop if position opens
input int      InpMaxHoldMinutes  = 300;    // Max position duration (minutes)
input double   InpDailyLossLimit  = 0;    // Daily loss limit % (0=disable)
input int      InpMagicNumber     = 202403; // Magic Number
input int      InpSlippage        = 25;     // Max slippage (points)

input group "=== DAILY PROFIT TARGET ==="
input double   InpDailyProfitTarget = 500.0; // Daily Profit Target ($) — 0 = disable
input bool     InpCloseOnTarget     = true;  // Close all positions when target hit

input group "=== STATS PANEL ==="
input bool     InpShowPanel       = true;   // Show Stats Panel on Chart
input int      InpPanelX          = 20;     // Panel X position (pixels from LEFT edge)
input int      InpPanelY          = 30;     // Panel Y position (pixels from top)
input color    InpPanelBG         = C'15,18,30';      // Panel background colour
input color    InpPanelBorder     = C'50,90,160';     // Panel border colour
input color    InpColorProfit     = clrLimeGreen;     // Profit colour
input color    InpColorLoss       = clrTomato;        // Loss colour
input color    InpColorNeutral    = clrWhite;         // Neutral text colour
input color    InpColorLabel      = C'140,160,200';   // Label colour

//--- Global Variables
CTrade         Trade;
CPositionInfo  PositionInfo;
COrderInfo     OrderInfo;

double         PtVal;
datetime       LastLossTime       = 0;
datetime       LastBarTime        = 0;
bool           BullishCandle      = false;
bool           BearishCandle      = false;
double         DailyStartEquity   = 0;
datetime       DailyResetTime     = 0;

//--- Daily Profit Target
bool           DailyTargetHit     = false;
datetime       DailyTargetDate    = 0;   // date when target was last hit

//--- Panel object name prefix
#define PANEL_PREFIX "ASv4_Panel_"

struct PositionData
{
   ulong ticket;
   bool  partial1Done;
   bool  partial2Done;
};
PositionData posData[];
int posDataCount = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   Trade.SetExpertMagicNumber(InpMagicNumber);
   Trade.SetDeviationInPoints(InpSlippage);
   Trade.SetTypeFilling(ORDER_FILLING_RETURN);
   Trade.SetAsyncMode(false);

   PtVal = _Point;
   if(_Digits == 3 || _Digits == 5)
      PtVal = _Point * 10;

   DailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   DailyResetTime   = TimeCurrent();

   // Build initial panel
   if(InpShowPanel) BuildPanel();

   Print("=== AutoScalper EA v4.1 Initialized ===");
   Print("Symbol: ", _Symbol, " | Magic: ", InpMagicNumber);
   Print("Daily Profit Target: $", InpDailyProfitTarget);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeletePanel();
   Print("AutoScalper EA v4.1 Removed. Final Equity: $", AccountInfoDouble(ACCOUNT_EQUITY));
}

//+------------------------------------------------------------------+
void OnTick()
{
   // ---- Daily reset (midnight) ----
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   datetime todayMidnight = StringToTime(
      StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));

   if(TimeCurrent() - DailyResetTime > 3600 && dt.hour == 0)
   {
      DailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      DailyResetTime   = TimeCurrent();
      DailyTargetHit   = false;
      Print("New day - Equity reset to: $", DailyStartEquity, " | Target unlocked");
   }

   // ---- Recalculate today's profit ----
   double todayProfit = CalcTodayProfit();

   // ---- Check Daily Profit Target ----
   if(InpDailyProfitTarget > 0 && !DailyTargetHit)
   {
      if(todayProfit >= InpDailyProfitTarget)
      {
         DailyTargetHit  = true;
         DailyTargetDate = todayMidnight;
         Print("=== DAILY PROFIT TARGET HIT: $", DoubleToString(todayProfit, 2),
               " >= $", InpDailyProfitTarget, " | EA paused until tomorrow ===");

         if(InpCloseOnTarget)
         {
            CloseAllPositions("Daily target hit");
            CancelAllPending();
         }
         else
         {
            CancelAllPending();
         }
         UpdatePanel(todayProfit);
         return;
      }
   }

   // ---- If target already hit today, do nothing ----
   if(DailyTargetHit && DailyTargetDate == todayMidnight)
   {
      UpdatePanel(todayProfit);
      return;
   }

   // ---- Daily Loss Limit ----
   if(InpDailyLossLimit > 0 && !CheckEquityProtection())
   {
      CloseAllPositions("Daily loss limit");
      CancelAllPending();
      UpdatePanel(todayProfit);
      return;
   }

   // ---- Candle bar update ----
   datetime currentBar = iTime(_Symbol, InpTF, 0);
   if(currentBar != LastBarTime)
   {
      LastBarTime    = currentBar;
      double openPrev  = iOpen (_Symbol, InpTF, 1);
      double closePrev = iClose(_Symbol, InpTF, 1);
      BullishCandle  = (closePrev > openPrev);
      BearishCandle  = (closePrev < openPrev);
   }

   // Manage existing positions (every tick)
   ManagePositions();

   //---- ENTRY FILTERS ----
   if(InpUseSession && !IsInSession())
   {
      CancelAllPending();
      UpdatePanel(todayProfit);
      return;
   }

   long spreadPts = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPts > InpMaxSpread)
   {
      static datetime lastSpreadWarn = 0;
      if(TimeCurrent() - lastSpreadWarn > 60)
      {
         Print("Spread too wide: ", spreadPts, " pts - skipping");
         lastSpreadWarn = TimeCurrent();
      }
      UpdatePanel(todayProfit);
      return;
   }

   if(InpCooldownBars > 0 && LastLossTime > 0)
   {
      int barsSinceLoss = Bars(_Symbol, InpTF, LastLossTime, TimeCurrent());
      if(barsSinceLoss < InpCooldownBars)
      {
         UpdatePanel(todayProfit);
         return;
      }
   }

   bool hasBuyStop    = HasPendingOrder(ORDER_TYPE_BUY_STOP);
   bool hasSellStop   = HasPendingOrder(ORDER_TYPE_SELL_STOP);
   int  buyPositions  = CountPositions(POSITION_TYPE_BUY);
   int  sellPositions = CountPositions(POSITION_TYPE_SELL);

   double lotSize = CalculateLotSize();
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(InpCloseOpposite)
   {
      if(buyPositions  > 0 && hasSellStop) CancelPendingOrders(ORDER_TYPE_SELL_STOP);
      if(sellPositions > 0 && hasBuyStop)  CancelPendingOrders(ORDER_TYPE_BUY_STOP);
   }

   bool canBuy = !InpUseCandleConfirm || BullishCandle;
   if(!hasBuyStop && buyPositions < InpMaxPositions && canBuy)
   {
      double price = NormalizeDouble(ask + InpStopDistance * PtVal, _Digits);
      double sl    = NormalizeDouble(price - InpStopLoss   * PtVal, _Digits);
      double tp    = NormalizeDouble(price + InpTakeProfit  * PtVal, _Digits);

      if(IsTradeAllowed(price, sl, tp, ORDER_TYPE_BUY_STOP))
      {
         if(SafeOrderSend(ORDER_TYPE_BUY_STOP, lotSize, price, sl, tp, "AS_BuyStop"))
            Print("Buy Stop | Price:", price, " SL:", sl, " TP:", tp, " Lot:", lotSize);
      }
   }

   bool canSell = !InpUseCandleConfirm || BearishCandle;
   if(!hasSellStop && sellPositions < InpMaxPositions && canSell)
   {
      double price = NormalizeDouble(bid - InpStopDistance * PtVal, _Digits);
      double sl    = NormalizeDouble(price + InpStopLoss   * PtVal, _Digits);
      double tp    = NormalizeDouble(price - InpTakeProfit  * PtVal, _Digits);

      if(IsTradeAllowed(price, sl, tp, ORDER_TYPE_SELL_STOP))
      {
         if(SafeOrderSend(ORDER_TYPE_SELL_STOP, lotSize, price, sl, tp, "AS_SellStop"))
            Print("Sell Stop | Price:", price, " SL:", sl, " TP:", tp, " Lot:", lotSize);
      }
   }

   UpdatePanel(todayProfit);
}

//+------------------------------------------------------------------+
//| Calculate today's closed + floating P&L                         |
//+------------------------------------------------------------------+
double CalcTodayProfit()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime startOfDay = StringToTime(
      StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));

   double profit = 0;

   // Closed deals today
   if(HistorySelect(startOfDay, TimeCurrent()))
   {
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber) continue;
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)  continue;
         profit += HistoryDealGetDouble(ticket, DEAL_PROFIT)
                 + HistoryDealGetDouble(ticket, DEAL_COMMISSION)
                 + HistoryDealGetDouble(ticket, DEAL_SWAP);
      }
   }

   // Floating open positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionInfo.SelectByIndex(i)) continue;
      if(PositionInfo.Symbol() != _Symbol || PositionInfo.Magic() != InpMagicNumber) continue;
      profit += PositionInfo.Profit() + PositionInfo.Swap();
   }

   return profit;
}

//+------------------------------------------------------------------+
//| Manage all position modifications (every tick)                   |
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionInfo.SelectByIndex(i)) continue;
      if(PositionInfo.Symbol() != _Symbol || PositionInfo.Magic() != InpMagicNumber) continue;

      // 1. Time-based exit
      if(InpMaxHoldMinutes > 0)
      {
         datetime openTime = PositionInfo.Time();
         if(TimeCurrent() - openTime > InpMaxHoldMinutes * 60)
         {
            Print("Time exit | Ticket:", PositionInfo.Ticket());
            SafePositionClose(PositionInfo.Ticket());
            continue;
         }
      }

      // 2. Breakeven
      if(InpUseBreakeven)
         CheckBreakeven();

      // 3. SMC Trailing SL
      ManageSMCTrailingSL();
   }
}

//+------------------------------------------------------------------+
//| SMC Trailing SL                                                  |
//+------------------------------------------------------------------+
void ManageSMCTrailingSL()
{
   ulong  ticket    = PositionInfo.Ticket();
   double openPrice = PositionInfo.PriceOpen();
   double currentSL = PositionInfo.StopLoss();
   double currentTP = PositionInfo.TakeProfit();

   double newSL  = 0;
   bool   modify = false;

   if(PositionInfo.PositionType() == POSITION_TYPE_BUY)
   {
      double bid          = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double profitPoints = (bid - openPrice) / PtVal;

      if(InpUseSecureProfit && profitPoints >= InpSecureAt)
      {
         double secureSL = openPrice + InpSecureAmount * PtVal;
         if(currentSL < secureSL)
         {
            newSL  = NormalizeDouble(secureSL, _Digits);
            modify = true;
            Print("SMC Secure (BUY) #", ticket,
                  " | Profit:", DoubleToString(profitPoints, 1), "pts | SL->", newSL);
         }
      }

      if(InpUseSMCTrailSL && profitPoints >= InpSMCTrailStart)
      {
         double trailSL = bid - InpSMCTrailStop * PtVal;
         double minSL   = openPrice + InpSecureAmount * PtVal;
         if(trailSL < minSL) trailSL = minSL;

         int    level  = (int)(profitPoints / 10) * 10;
         double lockSL = openPrice + (level - 5) * PtVal;
         if(lockSL > trailSL) trailSL = lockSL;

         if(trailSL > currentSL + InpSMCTrailStep * PtVal)
         {
            newSL  = NormalizeDouble(trailSL, _Digits);
            modify = true;
            Print("SMC Trail SL (BUY) #", ticket,
                  " | Profit:", DoubleToString(profitPoints, 1), "pts | SL->", newSL);
         }
      }
   }
   else
   {
      double ask          = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPoints = (openPrice - ask) / PtVal;

      if(InpUseSecureProfit && profitPoints >= InpSecureAt)
      {
         double secureSL = openPrice - InpSecureAmount * PtVal;
         if(currentSL > secureSL || currentSL == 0)
         {
            newSL  = NormalizeDouble(secureSL, _Digits);
            modify = true;
            Print("SMC Secure (SELL) #", ticket,
                  " | Profit:", DoubleToString(profitPoints, 1), "pts | SL->", newSL);
         }
      }

      if(InpUseSMCTrailSL && profitPoints >= InpSMCTrailStart)
      {
         double trailSL = ask + InpSMCTrailStop * PtVal;
         double minSL   = openPrice - InpSecureAmount * PtVal;
         if(trailSL > minSL) trailSL = minSL;

         int    level  = (int)(profitPoints / 10) * 10;
         double lockSL = openPrice - (level - 5) * PtVal;
         if(lockSL < trailSL) trailSL = lockSL;

         if(currentSL == 0 || trailSL < currentSL - InpSMCTrailStep * PtVal)
         {
            newSL  = NormalizeDouble(trailSL, _Digits);
            modify = true;
            Print("SMC Trail SL (SELL) #", ticket,
                  " | Profit:", DoubleToString(profitPoints, 1), "pts | SL->", newSL);
         }
      }
   }

   if(modify)
      SafeModify(ticket, newSL, currentTP);
}

//+------------------------------------------------------------------+
//| ==================  STATS PANEL  ================================ |
//|  All objects use CORNER_LEFT_UPPER so X/Y are straightforward    |
//|  pixel offsets from the top-left of the chart window.            |
//+------------------------------------------------------------------+

// Panel dimensions — change here if you want a wider/taller panel
#define PANEL_W  240    // total width  (px)
#define PANEL_H  262    // total height (px)
#define PANEL_TITLEH 24 // title bar height
#define ROW_H    28     // row height
#define ROW_PAD  8      // left/right inner padding

void BuildPanel()
{
   if(!InpShowPanel) return;
   DeletePanel();

   int px = InpPanelX;   // top-left X of panel
   int py = InpPanelY;   // top-left Y of panel

   //--- outer background
   PanelRect(PANEL_PREFIX+"BG",
             px, py, PANEL_W, PANEL_H,
             InpPanelBG, InpPanelBG, BORDER_FLAT, 0);

   //--- border (drawn on top, transparent fill so BG shows through)
   PanelRect(PANEL_PREFIX+"BORDER",
             px, py, PANEL_W, PANEL_H,
             InpPanelBG, InpPanelBorder, BORDER_FLAT, 1);

   //--- title bar
   PanelRect(PANEL_PREFIX+"TITLE_BG",
             px, py, PANEL_W, PANEL_TITLEH,
             InpPanelBorder, InpPanelBorder, BORDER_FLAT, 0);

   // Title text — centred inside title bar
   PanelText(PANEL_PREFIX+"TITLE",
             px + PANEL_W/2, py + 4,
             "AutoScalper EA  v4.1",
             InpColorNeutral, 9, true, ANCHOR_UPPER);

   //--- data rows (label left-aligned, value right-aligned)
   int ry = py + PANEL_TITLEH + 2;  // first row top

   // Row: Status
   PanelText(PANEL_PREFIX+"LBL_STAT", px+ROW_PAD,        ry+6, "Status",       InpColorLabel,   8, false, ANCHOR_LEFT_UPPER);
   PanelText(PANEL_PREFIX+"VAL_STAT", px+PANEL_W-ROW_PAD, ry+6, "—",           InpColorNeutral, 8, true,  ANCHOR_RIGHT_UPPER);
   ry += ROW_H;

   // Row: Target / Day
   PanelText(PANEL_PREFIX+"LBL_TARGET", px+ROW_PAD,        ry+6, "Target / Day", InpColorLabel,   8, false, ANCHOR_LEFT_UPPER);
   PanelText(PANEL_PREFIX+"VAL_TARGET", px+PANEL_W-ROW_PAD, ry+6,
             "$"+DoubleToString(InpDailyProfitTarget,2),    InpColorNeutral, 8, true, ANCHOR_RIGHT_UPPER);
   ry += ROW_H;

   // Row: Today P&L
   PanelText(PANEL_PREFIX+"LBL_TODAY", px+ROW_PAD,        ry+6, "Today P&L",  InpColorLabel,   8, false, ANCHOR_LEFT_UPPER);
   PanelText(PANEL_PREFIX+"VAL_TODAY", px+PANEL_W-ROW_PAD, ry+6, "$0.00",     InpColorNeutral, 8, true,  ANCHOR_RIGHT_UPPER);
   ry += ROW_H;

   // Row: Balance
   PanelText(PANEL_PREFIX+"LBL_BAL", px+ROW_PAD,        ry+6, "Balance",  InpColorLabel,   8, false, ANCHOR_LEFT_UPPER);
   PanelText(PANEL_PREFIX+"VAL_BAL", px+PANEL_W-ROW_PAD, ry+6, "—",       InpColorNeutral, 8, true,  ANCHOR_RIGHT_UPPER);
   ry += ROW_H;

   // Row: Equity
   PanelText(PANEL_PREFIX+"LBL_EQU", px+ROW_PAD,        ry+6, "Equity",   InpColorLabel,   8, false, ANCHOR_LEFT_UPPER);
   PanelText(PANEL_PREFIX+"VAL_EQU", px+PANEL_W-ROW_PAD, ry+6, "—",       InpColorNeutral, 8, true,  ANCHOR_RIGHT_UPPER);
   ry += ROW_H;

   // Row: Session
   PanelText(PANEL_PREFIX+"LBL_SESS", px+ROW_PAD,        ry+6, "Session",  InpColorLabel,   8, false, ANCHOR_LEFT_UPPER);
   PanelText(PANEL_PREFIX+"VAL_SESS", px+PANEL_W-ROW_PAD, ry+6, "—",       InpColorNeutral, 8, true,  ANCHOR_RIGHT_UPPER);
   ry += ROW_H;

   // thin separator line before progress bar
   PanelRect(PANEL_PREFIX+"SEP",
             px+ROW_PAD, ry+2, PANEL_W-ROW_PAD*2, 1,
             InpPanelBorder, InpPanelBorder, BORDER_FLAT, 0);
   ry += 6;

   // Progress bar
   int barW = PANEL_W - ROW_PAD*2;
   int barH = 14;
   int barX = px + ROW_PAD;
   int barY = ry + 4;

   PanelRect(PANEL_PREFIX+"PROG_BG",   barX, barY, barW, barH, C'35,38,55', C'35,38,55', BORDER_FLAT, 0);
   PanelRect(PANEL_PREFIX+"PROG_FILL", barX, barY, 0,    barH, InpColorProfit, InpColorProfit, BORDER_FLAT, 0);

   // Progress percentage label — centred over the bar
   PanelText(PANEL_PREFIX+"PROG_PCT",
             barX + barW/2, barY + 1,
             "0%  ($0.00 / $"+DoubleToString(InpDailyProfitTarget,2)+")",
             C'180,190,210', 7, false, ANCHOR_UPPER);

   ChartRedraw();
}

//+------------------------------------------------------------------+
void UpdatePanel(double todayProfit)
{
   if(!InpShowPanel) return;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   bool   inSess  = IsInSession();

   string sessStr = inSess
      ? StringFormat("Active  %02d:00-%02d:00",  InpSessionStart, InpSessionEnd)
      : StringFormat("Closed  %02d:00-%02d:00",  InpSessionStart, InpSessionEnd);

   // ---- Status text & colour ----
   string statStr;
   color  statCol;
   if(DailyTargetHit)           { statStr = "TARGET HIT - OFF";  statCol = clrGold; }
   else if(!inSess&&InpUseSession){ statStr = "OUT OF SESSION";   statCol = clrOrange; }
   else                          { statStr = "RUNNING";           statCol = clrLimeGreen; }

   color todayCol = (todayProfit >= 0) ? InpColorProfit : InpColorLoss;

   // ---- Progress bar ----
   int barW = PANEL_W - ROW_PAD*2;
   double pct = 0;
   if(InpDailyProfitTarget > 0)
      pct = MathMin(MathMax(todayProfit / InpDailyProfitTarget * 100.0, 0.0), 100.0);
   int fillW = (int)MathRound(barW * pct / 100.0);

   color fillCol = (pct >= 100.0) ? clrGold : (pct >= 80.0 ? clrYellow : InpColorProfit);

   // ---- Apply values ----
   PanelSetText(PANEL_PREFIX+"VAL_STAT",  statStr,                             statCol);
   PanelSetText(PANEL_PREFIX+"VAL_TODAY", "$"+DoubleToString(todayProfit,2),   todayCol);
   PanelSetText(PANEL_PREFIX+"VAL_BAL",   "$"+DoubleToString(balance,2),       InpColorNeutral);
   PanelSetText(PANEL_PREFIX+"VAL_EQU",   "$"+DoubleToString(equity,2),        InpColorNeutral);
   PanelSetText(PANEL_PREFIX+"VAL_SESS",  sessStr, inSess ? InpColorProfit : clrOrange);

   ObjectSetInteger(0, PANEL_PREFIX+"PROG_FILL", OBJPROP_XSIZE,   MathMax(fillW,0));
   ObjectSetInteger(0, PANEL_PREFIX+"PROG_FILL", OBJPROP_COLOR,   fillCol);
   ObjectSetInteger(0, PANEL_PREFIX+"PROG_FILL", OBJPROP_BGCOLOR, fillCol);

   string pctTxt = StringFormat("%.0f%%   ($%.2f / $%.2f)", pct, todayProfit, InpDailyProfitTarget);
   ObjectSetString(0, PANEL_PREFIX+"PROG_PCT", OBJPROP_TEXT, pctTxt);

   ChartRedraw();
}

//+------------------------------------------------------------------+
void DeletePanel()
{
   ObjectsDeleteAll(0, PANEL_PREFIX);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Low-level panel helpers — ALL use CORNER_LEFT_UPPER              |
//+------------------------------------------------------------------+
void PanelRect(string name, int x, int y, int w, int h,
               color bgCol, color borderCol,
               ENUM_BORDER_TYPE btype, int bwidth)
{
   if(ObjectFind(0,name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,        w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,        h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,      bgCol);
   ObjectSetInteger(0, name, OBJPROP_COLOR,        borderCol);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE,  btype);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,        bwidth);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,   false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,       true);
   ObjectSetInteger(0, name, OBJPROP_BACK,         false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER,       0);
}

void PanelText(string name, int x, int y, string text,
               color clr, int fontSize, bool bold,
               ENUM_ANCHOR_POINT anchor)
{
   if(ObjectFind(0,name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  y);
   ObjectSetString (0, name, OBJPROP_TEXT,       text);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   fontSize);
   ObjectSetString (0, name, OBJPROP_FONT,       bold ? "Arial Bold" : "Arial");
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,     anchor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   ObjectSetInteger(0, name, OBJPROP_BACK,       false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER,     1);
}

void PanelSetText(string name, string text, color clr)
{
   ObjectSetString (0, name, OBJPROP_TEXT,  text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| Check equity protection                                          |
//+------------------------------------------------------------------+
bool CheckEquityProtection()
{
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double loss          = DailyStartEquity - currentEquity;
   if(loss <= 0) return true;

   double lossPct = (loss / DailyStartEquity) * 100.0;
   if(lossPct >= InpDailyLossLimit)
   {
      static bool warned = false;
      if(!warned)
      {
         Print("DAILY LOSS LIMIT HIT: ", DoubleToString(lossPct, 2), "% ($", DoubleToString(loss, 2), ")");
         warned = true;
      }
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Breakeven management                                             |
//+------------------------------------------------------------------+
void CheckBreakeven()
{
   ulong  ticket    = PositionInfo.Ticket();
   double openPrice = PositionInfo.PriceOpen();
   double currentSL = PositionInfo.StopLoss();

   if(PositionInfo.PositionType() == POSITION_TYPE_BUY)
   {
      double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double profit = (bid - openPrice) / PtVal;

      if(profit >= InpBEProfit && (currentSL < openPrice || currentSL == 0))
      {
         double newSL = NormalizeDouble(openPrice + InpBEOffset * PtVal, _Digits);
         if(newSL > currentSL || currentSL == 0)
            if(SafeModify(ticket, newSL, PositionInfo.TakeProfit()))
               Print("Breakeven (BUY) | Ticket:", ticket, " SL:", newSL);
      }
   }
   else
   {
      double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profit = (openPrice - ask) / PtVal;

      if(profit >= InpBEProfit && (currentSL > openPrice || currentSL == 0))
      {
         double newSL = NormalizeDouble(openPrice - InpBEOffset * PtVal, _Digits);
         if(newSL < currentSL || currentSL == 0)
            if(SafeModify(ticket, newSL, PositionInfo.TakeProfit()))
               Print("Breakeven (SELL) | Ticket:", ticket, " SL:", newSL);
      }
   }
}

//+------------------------------------------------------------------+
//| Safe helpers                                                     |
//+------------------------------------------------------------------+
bool SafeModify(ulong ticket, double sl, double tp, int retries = 3)
{
   for(int i = 0; i < retries; i++)
   {
      if(Trade.PositionModify(ticket, sl, tp)) return true;
      uint retcode = Trade.ResultRetcode();
      if(retcode == TRADE_RETCODE_INVALID_STOPS || retcode == TRADE_RETCODE_INVALID_PRICE)
      {
         Print("Modify failed permanently | Ticket:", ticket, " Code:", retcode);
         return false;
      }
      Sleep(100 + i * 50);
   }
   Print("Modify failed after retries | Ticket:", ticket);
   return false;
}

bool SafeOrderSend(ENUM_ORDER_TYPE type, double volume, double price, double sl, double tp, string comment, int retries = 3)
{
   for(int i = 0; i < retries; i++)
   {
      bool result = false;
      if(type == ORDER_TYPE_BUY_STOP)
         result = Trade.BuyStop(volume, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      else if(type == ORDER_TYPE_SELL_STOP)
         result = Trade.SellStop(volume, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment);

      if(result) return true;
      uint retcode = Trade.ResultRetcode();
      if(retcode == TRADE_RETCODE_INVALID_STOPS || retcode == TRADE_RETCODE_INVALID_PRICE ||
         retcode == TRADE_RETCODE_MARKET_CLOSED)
      {
         Print("Order failed permanently | Type:", EnumToString(type), " Code:", retcode);
         return false;
      }
      Sleep(100 + i * 50);
   }
   Print("Order failed after retries | Type:", EnumToString(type));
   return false;
}

bool SafePositionClose(ulong ticket, int retries = 3)
{
   for(int i = 0; i < retries; i++)
   {
      if(Trade.PositionClose(ticket)) return true;
      Sleep(100 + i * 50);
   }
   return false;
}

bool IsTradeAllowed(double price, double sl, double tp, ENUM_ORDER_TYPE type)
{
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
      { Print("Trading disabled"); return false; }

   long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   if(freezeLevel > 0)
   {
      double cp = (type == ORDER_TYPE_BUY_STOP) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(MathAbs(price - cp) / _Point <= freezeLevel) { Print("Price within freeze level"); return false; }
   }

   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopsLevel > 0)
   {
      if(MathAbs(price - sl) / _Point < stopsLevel || MathAbs(tp - price) / _Point < stopsLevel)
         { Print("SL/TP too close. Min: ", stopsLevel); return false; }
   }
   return true;
}

double CalculateLotSize()
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double steps   = MathFloor(equity / InpEquityStep);
   if(steps < 1) steps = 1;
   double lot     = NormalizeDouble(steps * InpBaseLot, 2);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   return NormalizeDouble(MathRound(lot / stepLot) * stepLot, 2);
}

bool HasPendingOrder(ENUM_ORDER_TYPE orderType)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderInfo.SelectByIndex(i))           continue;
      if(OrderInfo.Symbol()  != _Symbol)        continue;
      if(OrderInfo.Magic()   != InpMagicNumber) continue;
      if(OrderInfo.OrderType() == orderType)    return true;
   }
   return false;
}

void CancelPendingOrders(ENUM_ORDER_TYPE orderType)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderInfo.SelectByIndex(i))           continue;
      if(OrderInfo.Symbol()  != _Symbol)        continue;
      if(OrderInfo.Magic()   != InpMagicNumber) continue;
      if(OrderInfo.OrderType() == orderType)
         Trade.OrderDelete(OrderInfo.Ticket());
   }
}

void CancelAllPending()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderInfo.SelectByIndex(i))           continue;
      if(OrderInfo.Symbol()  != _Symbol)        continue;
      if(OrderInfo.Magic()   != InpMagicNumber) continue;
      Trade.OrderDelete(OrderInfo.Ticket());
   }
}

int CountPositions(ENUM_POSITION_TYPE posType)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionInfo.SelectByIndex(i))           continue;
      if(PositionInfo.Symbol()  != _Symbol)        continue;
      if(PositionInfo.Magic()   != InpMagicNumber) continue;
      if(PositionInfo.PositionType() == posType)   count++;
   }
   return count;
}

void CloseAllPositions(string reason = "")
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionInfo.SelectByIndex(i)) continue;
      if(PositionInfo.Symbol() != _Symbol || PositionInfo.Magic() != InpMagicNumber) continue;
      SafePositionClose(PositionInfo.Ticket());
   }
   Print("All positions closed", (reason != "" ? " | Reason: " + reason : ""));
}

bool IsInSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.hour >= InpSessionStart && dt.hour < InpSessionEnd);
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     request,
                        const MqlTradeResult&      result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong dealTicket = trans.deal;
      if(HistoryDealSelect(dealTicket))
      {
         long   magic  = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
         double profit = HistoryDealGetDouble (dealTicket, DEAL_PROFIT);
         long   entry  = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

         if(magic == InpMagicNumber && entry == DEAL_ENTRY_OUT && profit < 0)
         {
            LastLossTime = TimeCurrent();
            Print("Loss detected ($", DoubleToString(profit, 2), ") - Cooldown started");
         }
      }
   }
}
//+------------------------------------------------------------------+