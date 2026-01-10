//+------------------------------------------------------------------+
//|                                                   CryptoEA_M30.mq4|
//|  XM Crypto CFD (MT4) - M30 Trend + Pullback EA                    |
//|  Symbols: ETH / XRP (and others)                                  |
//|  Logic: EMA trend filter + RSI pullback + ATR-based SL/TP         |
//|  Risk: Fixed lot OR % risk per trade, with caps and safety checks |
//|  Notes: Backtest-first. No martingale/grid.                       |
//+------------------------------------------------------------------+
#property strict

//========================= INPUTS ==================================
extern int    WorkingTimeframe      = PERIOD_M30; // Enforce M30 logic
extern int    MagicNumber           = 240901;

extern double RiskPercent           = 1.0;  // % of balance risk per trade (if FixedLot<=0)
extern double FixedLot              = 0.0;  // If > 0, use this lot size (testing)
extern double MaxLot                = 5.0;  // Hard cap to prevent runaway lots
extern double MinLotOverride        = 0.0;  // If >0, override broker min lot (rare; usually keep 0)

extern int    Slippage              = 5;
extern int    MaxSpreadPoints       = 1500;  // points (e.g., 400 = 40 pips if 5-digit; crypto varies)

extern int    EMAFast               = 50;
extern int    EMASlow               = 200;

extern int    RSIPeriod             = 14;
extern double RSI_BuyLevel          = 45.0; // Pullback threshold for buys
extern double RSI_SellLevel         = 55.0; // Pullback threshold for sells
extern bool   UseRSICrossConfirm    = true; // Confirm RSI turning direction using previous bar

extern int    ATRPeriod             = 14;
extern double StopATR_Mult          = 2.2;  // SL = ATR * mult
extern double TakeATR_Mult          = 5.2;  // TP = ATR * mult

extern bool   UseTrailingStop       = false;
extern double TrailATR_Mult         = 1.5;  // trailing distance = ATR * mult
extern bool   UseBreakEven          = false;
extern double BE_ATR_TriggerMult    = 1.5;  // move to BE when profit >= ATR*mult
extern double BE_ExtraPoints        = 0;    // add extra points to BE (0 = pure breakeven)

extern bool   OneTradeAtATimeSymbol = true; // at most one open trade per symbol+magic
extern bool   OnlyNewBarEntries     = true; // evaluate entry only on new bar (recommended)

// Safety / Trading windows (optional)
extern bool   UseMaxDailyLoss       = false;
extern double MaxDailyLossPercent   = 10.0; // stop trading for the day if equity drawdown exceeds %

extern bool   AllowBuy              = true;
extern bool   AllowSell             = true;

//========================= GLOBALS =================================
datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(WorkingTimeframe != PERIOD_M30)
   {
      Print("WARNING: WorkingTimeframe input is not M30. Current: ", WorkingTimeframe,
            ". This EA is designed for M30. It will still enforce the input timeframe for signals.");
   }
   g_lastBarTime = 0;
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   // Basic checks
   if(!IsTradeAllowed()) return;
   if(!IsConnected())    return;

   // Enforce entry evaluation on new bar if configured
   if(OnlyNewBarEntries)
   {
      if(!IsNewBar(WorkingTimeframe)) return;
   }

   // Spread filter
   if(!SpreadOK()) return;

   // Daily loss protection (optional)
   if(UseMaxDailyLoss && IsDailyLossLimitHit()) return;

   // Manage existing positions (trailing/breakeven)
   ManageOpenPositions();

   // Entry logic
   if(OneTradeAtATimeSymbol && HasOpenPosition(Symbol(), MagicNumber)) return;

   // Decide signals
   int signal = GetSignal(); // 1=buy, -1=sell, 0=none

   if(signal == 1 && AllowBuy)
      TryOpen(OP_BUY);
   else if(signal == -1 && AllowSell)
      TryOpen(OP_SELL);
}

//+------------------------------------------------------------------+
//| Improved Signal Engine (M30)                                      |
//| EMA trend + EMA pullback + RSI reversal                           |
//+------------------------------------------------------------------+
int GetSignal()
{
   int tf = WorkingTimeframe;

   // --- EMA values (closed candles only)
   double emaFast_1 = iMA(Symbol(), tf, EMAFast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaFast_2 = iMA(Symbol(), tf, EMAFast, 0, MODE_EMA, PRICE_CLOSE, 2);
   double emaSlow_1 = iMA(Symbol(), tf, EMASlow, 0, MODE_EMA, PRICE_CLOSE, 1);

   // --- Price
   double close_1 = iClose(Symbol(), tf, 1);
   double close_2 = iClose(Symbol(), tf, 2);

   // --- RSI
   double rsi_1 = iRSI(Symbol(), tf, RSIPeriod, PRICE_CLOSE, 1);
   double rsi_2 = iRSI(Symbol(), tf, RSIPeriod, PRICE_CLOSE, 2);

   // --- ATR filter (avoid dead market)
   double atr = iATR(Symbol(), tf, ATRPeriod, 1);
   if(atr <= 0) return 0;

   //==================================================
   // Trend definition
   //==================================================
   bool upTrend   = (emaFast_1 > emaSlow_1) && (emaFast_1 > emaFast_2);
   bool downTrend = (emaFast_1 < emaSlow_1) && (emaFast_1 < emaFast_2);

   //==================================================
   // Pullback definition (price near EMAFast)
   //==================================================
   double pullbackRange = atr * 0.6;

   bool pricePullbackBuy  = (close_1 <= emaFast_1 + pullbackRange);
   bool pricePullbackSell = (close_1 >= emaFast_1 - pullbackRange);

   //==================================================
   // RSI reversal
   //==================================================
   bool rsiBuy =
      (rsi_2 < RSI_BuyLevel) &&
      (rsi_1 > rsi_2) &&
      (rsi_1 < 55);

   bool rsiSell =
      (rsi_2 > RSI_SellLevel) &&
      (rsi_1 < rsi_2) &&
      (rsi_1 > 45);

   //==================================================
   // Final signals
   //==================================================
   if(upTrend && pricePullbackBuy && rsiBuy)
      return 1;

   if(downTrend && pricePullbackSell && rsiSell)
      return -1;

   return 0;
}


//+------------------------------------------------------------------+
//| Try open a trade (buy/sell)                                      |
//+------------------------------------------------------------------+
void TryOpen(int orderType)
{
   int tf = WorkingTimeframe;

   // Calculate ATR-based SL/TP (based on current price)
   double atr = iATR(Symbol(), tf, ATRPeriod, 1);
   if(atr <= 0) return;

   double slDist = atr * StopATR_Mult;
   double tpDist = atr * TakeATR_Mult;

   // Price
   RefreshRates();
   double price = (orderType == OP_BUY) ? Ask : Bid;

   // Stops
   double sl = 0, tp = 0;
   if(orderType == OP_BUY)
   {
      sl = price - slDist;
      tp = price + tpDist;
   }
   else
   {
      sl = price + slDist;
      tp = price - tpDist;
   }

   // Normalize to digits
   sl = NormalizeDouble(sl, Digits);
   tp = NormalizeDouble(tp, Digits);

   // Lot size
   double lots = CalculateLotSize(orderType, price, sl);
   if(lots <= 0)
   {
      Print("Lot calculation returned <= 0. Skip trade.");
      return;
   }

   // Broker min/max & step normalization
   lots = NormalizeLot(lots);
   if(lots <= 0) return;

   // Final spread check right before sending
   if(!SpreadOK()) return;

   // Send order
   int ticket = OrderSend(Symbol(), orderType, lots, price, Slippage, sl, tp,
                          "CryptoEA_M30", MagicNumber, 0, clrNONE);

   if(ticket < 0)
   {
      int err = GetLastError();
      Print("OrderSend failed. type=", orderType, " lots=", lots, " err=", err);
      ResetLastError();
      return;
   }

   Print("Order opened. ticket=", ticket, " type=", orderType, " lots=", lots,
         " price=", DoubleToString(price, Digits),
         " sl=", DoubleToString(sl, Digits),
         " tp=", DoubleToString(tp, Digits));
}

//+------------------------------------------------------------------+
//| Calculate lot size: FixedLot OR risk % based on SL distance       |
//+------------------------------------------------------------------+
double CalculateLotSize(int orderType, double entryPrice, double stopPrice)
{
   // Fixed lot overrides risk mode
   if(FixedLot > 0.0)
      return FixedLot;

   // Risk-based sizing
   double riskMoney = AccountBalance() * (RiskPercent / 100.0);
   if(riskMoney <= 0) return 0;

   // Stop distance in points
   double stopDistPoints = MathAbs(entryPrice - stopPrice) / Point;
   if(stopDistPoints <= 0) return 0;

   // Estimate money per point for 1 lot
   // tickvalue: money per tick; ticksize: price increment
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);

   if(tickValue <= 0 || tickSize <= 0) return 0;

   // money per point for 1 lot
   // 1 point is Point in price; how many ticks per point?
   double ticksPerPoint = Point / tickSize;
   if(ticksPerPoint <= 0) return 0;

   double moneyPerPointPerLot = tickValue * ticksPerPoint;
   if(moneyPerPointPerLot <= 0) return 0;

   // Risk money / (stop points * money per point per lot) = lots
   double lots = riskMoney / (stopDistPoints * moneyPerPointPerLot);

   // Cap lots
   if(MaxLot > 0 && lots > MaxLot) lots = MaxLot;

   return lots;
}

//+------------------------------------------------------------------+
//| Normalize lots by broker rules                                   |
//+------------------------------------------------------------------+
double NormalizeLot(double lots)
{
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

   if(MinLotOverride > 0) minLot = MinLotOverride;

   if(lotStep <= 0) lotStep = 0.01;

   // clamp
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   // step normalize
   lots = MathFloor(lots / lotStep) * lotStep;

   // final normalize
   lots = NormalizeDouble(lots, 2);

   // sanity
   if(lots < minLot - 1e-9)
   {
      Print("Lot below min after normalization. minLot=", minLot, " lots=", lots);
      return 0;
   }
   return lots;
}

//+------------------------------------------------------------------+
//| Spread filter                                                    |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   double spread = MarketInfo(Symbol(), MODE_SPREAD);
   // MODE_SPREAD returns points already in MT4
   if(spread <= 0) return true; // some brokers return 0 on certain symbols; allow but be careful

   if(MaxSpreadPoints > 0 && spread > MaxSpreadPoints)
   {
      // Print occasionally
      // Print("Spread too high: ", spread, " points. Max: ", MaxSpreadPoints);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Check if there is an open position for this symbol+magic         |
//+------------------------------------------------------------------+
bool HasOpenPosition(string sym, int magic)
{
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == sym && OrderMagicNumber() == magic)
         {
            int type = OrderType();
            if(type == OP_BUY || type == OP_SELL) return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Manage open positions: trailing + break-even                      |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   if(!UseTrailingStop && !UseBreakEven) return;

   int tf = WorkingTimeframe;
   double atr = iATR(Symbol(), tf, ATRPeriod, 1);
   if(atr <= 0) return;

   RefreshRates();

   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol()) continue;
      if(OrderMagicNumber() != MagicNumber) continue;

      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL) continue;

      double openPrice = OrderOpenPrice();
      double sl        = OrderStopLoss();
      double tp        = OrderTakeProfit();

      // Compute current profit distance in points
      double currentPrice = (type == OP_BUY) ? Bid : Ask;
      double profitPoints = (type == OP_BUY)
                            ? (currentPrice - openPrice) / Point
                            : (openPrice - currentPrice) / Point;

      // Break-even logic
      if(UseBreakEven)
      {
         double beTriggerPoints = (atr * BE_ATR_TriggerMult) / Point;
         if(profitPoints >= beTriggerPoints)
         {
            double newSL = sl;

            if(type == OP_BUY)
            {
               double targetSL = openPrice + (BE_ExtraPoints * Point);
               if(sl <= 0 || sl < targetSL)
                  newSL = targetSL;
            }
            else
            {
               double targetSL = openPrice - (BE_ExtraPoints * Point);
               if(sl <= 0 || sl > targetSL)
                  newSL = targetSL;
            }

            newSL = NormalizeDouble(newSL, Digits);
            if(newSL != sl && IsValidStop(type, currentPrice, newSL))
               SafeModify(OrderTicket(), openPrice, newSL, tp);
         }
      }

      // Trailing stop logic
      if(UseTrailingStop)
      {
         double trailDist = atr * TrailATR_Mult;
         double newSL2 = sl;

         if(type == OP_BUY)
         {
            double candidate = currentPrice - trailDist;
            candidate = NormalizeDouble(candidate, Digits);

            // only move up
            if(sl <= 0 || candidate > sl)
               newSL2 = candidate;
         }
         else
         {
            double candidate = currentPrice + trailDist;
            candidate = NormalizeDouble(candidate, Digits);

            // only move down (for sell, SL is above price; "move down" means smaller value)
            if(sl <= 0 || candidate < sl)
               newSL2 = candidate;
         }

         if(newSL2 != sl && IsValidStop(type, currentPrice, newSL2))
            SafeModify(OrderTicket(), openPrice, newSL2, tp);
      }
   }
}

//+------------------------------------------------------------------+
//| Validate stop distance vs broker stop level                       |
//+------------------------------------------------------------------+
bool IsValidStop(int type, double currentPrice, double stopLossPrice)
{
   int stopLevel = (int)MarketInfo(Symbol(), MODE_STOPLEVEL); // points
   if(stopLevel <= 0) return true;

   double distPoints = MathAbs(currentPrice - stopLossPrice) / Point;
   if(distPoints < stopLevel)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| Safe order modify wrapper                                         |
//+------------------------------------------------------------------+
void SafeModify(int ticket, double openPrice, double sl, double tp)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return;

   bool ok = OrderModify(ticket, openPrice, sl, tp, 0, clrNONE);
   if(!ok)
   {
      int err = GetLastError();
      // Some brokers reject too-frequent modifies; keep logs
      Print("OrderModify failed. ticket=", ticket, " err=", err,
            " sl=", DoubleToString(sl, Digits), " tp=", DoubleToString(tp, Digits));
      ResetLastError();
   }
}

//+------------------------------------------------------------------+
//| New bar detection for a given timeframe                           |
//+------------------------------------------------------------------+
bool IsNewBar(int timeframe)
{
   datetime t = iTime(Symbol(), timeframe, 0);
   if(t == 0) return false;

   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Daily loss limit (equity drawdown from start of day)              |
//+------------------------------------------------------------------+
bool IsDailyLossLimitHit()
{
   // Estimate "start of day equity" by using balance + closed P/L today approach is complex.
   // Simple approximation: track equity at first tick of the day (server time).
   // For robustness, we implement an equity watermark per day in GlobalVariable.
   string key = "EA_DailyEquityStart_" + IntegerToString(MagicNumber) + "_" + IntegerToString(AccountNumber());
   string dayKey = "EA_DailyDay_" + IntegerToString(MagicNumber) + "_" + IntegerToString(AccountNumber());

   datetime now = TimeCurrent();
   int y = TimeYear(now), m = TimeMonth(now), d = TimeDay(now);
   int today = y*10000 + m*100 + d;

   double equity = AccountEquity();

   if(!GlobalVariableCheck(dayKey) || (int)GlobalVariableGet(dayKey) != today)
   {
      GlobalVariableSet(dayKey, today);
      GlobalVariableSet(key, equity);
      return false;
   }

   double startEquity = GlobalVariableGet(key);
   if(startEquity <= 0) return false;

   double ddPct = (startEquity - equity) / startEquity * 100.0;
   if(ddPct >= MaxDailyLossPercent)
   {
      // Print once per bar/tick is ok; keep it simple
      Print("Daily loss limit hit. StartEquity=", startEquity, " Equity=", equity, " DD%=", ddPct);
      return true;
   }
   return false;
}
//+------------------------------------------------------------------+
