//+------------------------------------------------------------------+
//|                                   XRP_H4_HybridSwingEA.mq4       |
//|  Option A (Maximum profit WITH survival) — Regime-gated swings    |
//|                                                                  |
//|  Designed for XRP/USDT (or XRPUSD) on MT4 CFD feeds.              |
//|                                                                  |
//|  CORE PHILOSOPHY (based on long history behavior):                |
//|   - XRP trends are RARE on H4; most bars are compression/chop.    |
//|   - So we do: WAIT (regime gate) -> STRIKE ONCE (one-shot)        |
//|     -> TAKE PARTIAL -> TRAIL RUNNER -> NO RE-ENTRY until reset.   |
//|                                                                  |
//|  REGIME GATE (H4, closed bars):                                   |
//|   1) ATR percentile (rolling window) >= ATR_Pctl_Enter            |
//|   2) ADX >= ADX_Min and rising for 2 bars                         |
//|   3) BB bandwidth >= Min_BB_Bandwidth and optionally expanding    |
//|                                                                  |
//|  ENTRY (only when regime is active, one-shot per regime):         |
//|   - Breakout close outside Bollinger band on closed bar:          |
//|       Buy  if Close[1] > Upper[1] (+ optional RSI confirm)         |
//|       Sell if Close[1] < Lower[1] (+ optional RSI confirm)         |
//|                                                                  |
//|  RISK/EXITS:                                                      |
//|   - Initial SL = SL_ATR_Mult * ATR(H4)                            |
//|   - Partial close at Partial_R * R (default 1.5R)                 |
//|   - Move SL to BE + buffer after partial                          |
//|   - ATR trailing for runner                                       |
//|   - Time-stop after MaxHoldBars H4 bars (optional)                |
//+------------------------------------------------------------------+
#property strict

//=========================== Inputs ================================//
extern string TradeSymbol              = "";          // "" = chart symbol
extern int    MagicNumber              = 990001;

extern ENUM_TIMEFRAMES TF              = PERIOD_H4;

// Direction
extern bool   AllowBuy                 = true;
extern bool   AllowSell                = true;

// Indicators
extern int    BB_Period                = 20;
extern double BB_Dev                   = 2.0;

extern int    RSI_Period               = 14;
extern bool   UseRSIConfirm            = true;
extern double RSI_BuyAbove             = 52.0;
extern double RSI_SellBelow            = 48.0;

extern int    ADX_Period               = 14;
extern double ADX_Min                  = 28.0;        // trend strength
extern double ADX_ResetBelow           = 20.0;        // regime reset

extern int    ATR_Period               = 14;

// Regime (volatility + expansion)
extern int    ATR_Pctl_Window          = 120;         // rolling window in H4 bars
extern double ATR_Pctl_Enter           = 65.0;        // enter regime when ATR percentile >= this
extern double ATR_Pctl_Reset           = 45.0;        // reset when ATR percentile falls below this

extern double Min_BB_Bandwidth         = 0.020;       // (Upper-Lower)/Mid (H4); tune per feed
extern bool   Require_BB_Expansion     = true;        // bandwidth rising vs previous bar

// Risk / lots
extern bool   UseFixedLots             = false;
extern double FixedLots                = 0.10;
extern double RiskPercent              = 1.0;         // start low; increase only after proof

// Stops & exits
extern double SL_ATR_Mult              = 1.5;         // initial SL distance
extern bool   UsePartial               = true;
extern double Partial_R                = 1.5;         // take partial at +1.5R
extern double PartialClosePercent      = 50.0;        // close % of position
extern int    BE_Buffer_Points         = 120;         // BE buffer (points) to cover spread

extern bool   UseATRTrailing           = true;
extern double Trail_ATR_Mult           = 1.0;         // trailing distance
extern double Trail_Start_R            = 0.7;         // start trailing after +0.7R
extern int    Trail_MinStep_Points     = 120;         // min SL improve (points) to modify

// Time stop
extern bool   UseTimeStop              = true;
extern int    MaxHoldBars              = 10;          // H4 bars to hold before time-exit
extern double TimeStop_MinProfit_R     = 0.3;         // if profit < 0.3R after MaxHoldBars => close

// Execution filters
extern int    SlippagePoints           = 30;
extern int    MaxSpreadPoints          = 25000;       // XRP spreads can be huge on some CFDs
extern int    MaxOpenTradesPerSymbol   = 1;

// Debug
extern bool   DebugLogs                = false;

//=========================== Helpers ===============================//
string Sym(){ return (StringLen(TradeSymbol)>0 ? TradeSymbol : Symbol()); }
int DigitsOf(string s){ return (int)MarketInfo(s, MODE_DIGITS); }
double Pt(string s){ return MarketInfo(s, MODE_POINT); }
double Norm(string s, double p){ return NormalizeDouble(p, DigitsOf(s)); }
int SpreadPts(string s){ return (int)MarketInfo(s, MODE_SPREAD); }

double LotStep(string s){ return MarketInfo(s, MODE_LOTSTEP); }
double MinLot(string s){ return MarketInfo(s, MODE_MINLOT); }
double MaxLot(string s){ return MarketInfo(s, MODE_MAXLOT); }

double ClampLot(string s, double lots)
{
   double step = LotStep(s); if(step<=0) step=0.01;
   double minL = MinLot(s);
   double maxL = MaxLot(s);

   if(lots < minL) lots = minL;
   if(lots > maxL) lots = maxL;

   lots = MathFloor(lots/step)*step;
   lots = NormalizeDouble(lots, 2);
   if(lots < minL) lots = minL;
   return lots;
}

double ATRv(string s, ENUM_TIMEFRAMES tf, int shift)
{
   double a = iATR(s, tf, ATR_Period, shift);
   if(a<=0) a = iATR(s, tf, ATR_Period, shift+1);
   if(a<=0) a = Pt(s)*100;
   return a;
}

double CalcLotsByRisk(string s, double slDistPrice)
{
   if(slDistPrice <= 0) return ClampLot(s, FixedLots);

   double riskMoney = AccountBalance() * (RiskPercent/100.0);

   double tickValue = MarketInfo(s, MODE_TICKVALUE);
   double tickSize  = MarketInfo(s, MODE_TICKSIZE);
   if(tickValue<=0 || tickSize<=0) return ClampLot(s, FixedLots);

   double ticks = slDistPrice / tickSize;
   if(ticks<=0) return ClampLot(s, FixedLots);

   double lossPerLot = ticks * tickValue;
   if(lossPerLot<=0) return ClampLot(s, FixedLots);

   return ClampLot(s, riskMoney / lossPerLot);
}

bool HasSufficientMargin(string s, double lots)
{
   double mr = MarketInfo(s, MODE_MARGINREQUIRED);
   if(mr<=0) return true;
   return (AccountFreeMargin() > mr*lots);
}

bool IsNewBar(string s, ENUM_TIMEFRAMES tf)
{
   static datetime last=0;
   datetime t = iTime(s, tf, 0);
   if(t==0) return false;
   if(t==last) return false;
   last=t;
   return true;
}

int CountOpenOrders(string s)
{
   int cnt=0;
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()!=s) continue;
      if(OrderMagicNumber()!=MagicNumber) continue;
      int t = OrderType();
      if(t==OP_BUY || t==OP_SELL) cnt++;
   }
   return cnt;
}

//=========================== Bollinger =============================//
double BBUpper(string s, int shift){ return iBands(s, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_UPPER, shift); }
double BBLower(string s, int shift){ return iBands(s, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_LOWER, shift); }
double BBMid  (string s, int shift){ return iBands(s, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_MAIN,  shift); }

double BBBandwidth(string s, int shift)
{
   double up  = BBUpper(s, shift);
   double lo  = BBLower(s, shift);
   double mid = BBMid(s, shift);
   if(up<=0 || lo<=0 || mid<=0) return 0;
   return (up - lo) / mid;
}

//=========================== ATR Percentile ========================//
// Percentile rank of current ATR vs last N ATRs (closed bars).
double ATRPercentile(string s, int windowBars, int shiftCurrent)
{
   if(windowBars < 20) windowBars = 20;

   double cur = ATRv(s, TF, shiftCurrent);
   if(cur <= 0) return 0;

   int valid=0, le=0;
   for(int i=shiftCurrent; i<shiftCurrent+windowBars; i++)
   {
      double a = ATRv(s, TF, i);
      if(a<=0) continue;
      valid++;
      if(a <= cur) le++;
   }
   if(valid<=0) return 0;
   return (100.0 * le) / valid;
}

//=========================== Regime Lock ===========================//
// Regime ID uses the time of bar[1] where regime became active.
string GV_RegimeIDKey(string s){ return "XRP_HYB2_REGIME_ID_" + IntegerToString(MagicNumber) + "_" + s; }
string GV_TradedIDKey(string s){ return "XRP_HYB2_TRADED_ID_" + IntegerToString(MagicNumber) + "_" + s; }

double GetRegimeID(string s){ return (GlobalVariableCheck(GV_RegimeIDKey(s)) ? GlobalVariableGet(GV_RegimeIDKey(s)) : 0.0); }
void   SetRegimeID(string s, double v){ GlobalVariableSet(GV_RegimeIDKey(s), v); }

double GetTradedID(string s){ return (GlobalVariableCheck(GV_TradedIDKey(s)) ? GlobalVariableGet(GV_TradedIDKey(s)) : 0.0); }
void   SetTradedID(string s, double v){ GlobalVariableSet(GV_TradedIDKey(s), v); }

//=========================== Partial flags =========================//
string GV_PartialKey(int ticket){ return "XRP_HYB2_P1_" + IntegerToString(ticket); }
bool PartialDone(int ticket){ return GlobalVariableCheck(GV_PartialKey(ticket)); }
void MarkPartialDone(int ticket){ GlobalVariableSet(GV_PartialKey(ticket), 1.0); }

//=========================== Regime Logic ==========================//
bool RegimeActive(string s, double &outRegimeID, double &outAtrPctl)
{
   // Use CLOSED bars only: shifts 1,2,3
   double adx1 = iADX(s, TF, ADX_Period, PRICE_CLOSE, MODE_MAIN, 1);
   double adx2 = iADX(s, TF, ADX_Period, PRICE_CLOSE, MODE_MAIN, 2);
   double adx3 = iADX(s, TF, ADX_Period, PRICE_CLOSE, MODE_MAIN, 3);

   double bw1 = BBBandwidth(s, 1);
   double bw2 = BBBandwidth(s, 2);

   outAtrPctl = ATRPercentile(s, ATR_Pctl_Window, 1);

   // Reset condition: volatility cooled OR ADX cooled
   if((adx1 > 0 && adx1 < ADX_ResetBelow) || (outAtrPctl > 0 && outAtrPctl < ATR_Pctl_Reset))
   {
      SetRegimeID(s, 0.0);
      outRegimeID = 0.0;
      return false;
   }

   bool volOk   = (outAtrPctl >= ATR_Pctl_Enter);
   bool adxOk   = (adx1 >= ADX_Min);
   bool adxRise = (adx1 > adx2 && adx2 > adx3);            // rising 2 bars
   bool bwOk    = (bw1 >= Min_BB_Bandwidth);
   bool bwExp   = (!Require_BB_Expansion || (bw1 > bw2));

   bool active = (volOk && adxOk && adxRise && bwOk && bwExp);

   if(!active)
   {
      outRegimeID = GetRegimeID(s); // keep previous ID (if any)
      return false;
   }

   // Start or keep regime ID
   double id = GetRegimeID(s);
   if(id <= 0)
   {
      datetime t1 = iTime(s, TF, 1);
      id = (double)t1;
      SetRegimeID(s, id);
   }
   outRegimeID = id;
   return true;
}

//=========================== Entry Signals =========================//
bool BuySignal(string s)
{
   double c1 = iClose(s, TF, 1);
   double up1 = BBUpper(s, 1);
   if(c1<=0 || up1<=0) return false;
   if(c1 <= up1) return false;

   if(!UseRSIConfirm) return true;

   double r1 = iRSI(s, TF, RSI_Period, PRICE_CLOSE, 1);
   double r2 = iRSI(s, TF, RSI_Period, PRICE_CLOSE, 2);
   return (r1 > RSI_BuyAbove && r1 > r2);
}

bool SellSignal(string s)
{
   double c1 = iClose(s, TF, 1);
   double lo1 = BBLower(s, 1);
   if(c1<=0 || lo1<=0) return false;
   if(c1 >= lo1) return false;

   if(!UseRSIConfirm) return true;

   double r1 = iRSI(s, TF, RSI_Period, PRICE_CLOSE, 1);
   double r2 = iRSI(s, TF, RSI_Period, PRICE_CLOSE, 2);
   return (r1 < RSI_SellBelow && r1 < r2);
}

//=========================== Orders ================================//
int SendOrderECN(string s, int cmd, double lots, double sl, string comment)
{
   RefreshRates();
   double price = (cmd==OP_BUY) ? MarketInfo(s, MODE_ASK) : MarketInfo(s, MODE_BID);
   price = Norm(s, price);

   int ticket = OrderSend(s, cmd, lots, price, SlippagePoints, 0, 0, comment, MagicNumber, 0, clrNONE);
   if(ticket < 0)
   {
      Print("OrderSend failed err=", GetLastError());
      return -1;
   }

   if(OrderSelect(ticket, SELECT_BY_TICKET))
   {
      bool ok = OrderModify(ticket, OrderOpenPrice(), Norm(s, sl), 0, 0, clrNONE);
      if(!ok) Print("OrderModify(SL) failed ticket=", ticket, " err=", GetLastError());
   }
   return ticket;
}

double InitialSL(string s, int cmd)
{
   double atr = ATRv(s, TF, 1);
   double dist = SL_ATR_Mult * atr;

   RefreshRates();
   double ask = MarketInfo(s, MODE_ASK);
   double bid = MarketInfo(s, MODE_BID);

   if(cmd==OP_BUY)  return Norm(s, ask - dist);
   else             return Norm(s, bid + dist);
}

double RDist(int type, double open, double sl)
{
   if(type==OP_BUY)  return (open - sl);
   else              return (sl - open);
}

int BarsSince(datetime openTime)
{
   // How many H4 bars since open time (approx using iBarShift)
   string s = Sym();
   int shift = iBarShift(s, TF, openTime, true);
   if(shift < 0) return 999999;
   return shift;
}

//=========================== Management ============================//
void ManageTrades(string s)
{
   RefreshRates();
   double point = Pt(s);
   int digits = DigitsOf(s);

   double atr = ATRv(s, TF, 1);
   double trailDist = Trail_ATR_Mult * atr;

   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()!=s) continue;
      if(OrderMagicNumber()!=MagicNumber) continue;

      int type = OrderType();
      if(type!=OP_BUY && type!=OP_SELL) continue;

      int ticket = OrderTicket();
      double open = OrderOpenPrice();
      double sl   = OrderStopLoss();
      double lots = OrderLots();

      if(open<=0 || sl<=0 || lots<=0) continue;

      double r = RDist(type, open, sl);
      if(r <= 0) continue;

      double bid = MarketInfo(s, MODE_BID);
      double ask = MarketInfo(s, MODE_ASK);

      double profitDist = (type==OP_BUY) ? (bid - open) : (open - ask);

      //---------- Partial at Partial_R * R ----------//
      if(UsePartial && !PartialDone(ticket))
      {
         if(profitDist >= (Partial_R * r))
         {
            double closeLots = lots * (PartialClosePercent/100.0);
            closeLots = ClampLot(s, closeLots);

            if(closeLots >= MinLot(s) && closeLots < lots)
            {
               bool okClose = OrderClose(ticket, closeLots, (type==OP_BUY ? bid : ask), SlippagePoints, clrNONE);
               if(okClose)
               {
                  MarkPartialDone(ticket);

                  // Move SL to BE + buffer after partial
                  double newSL = open;
                  if(type==OP_BUY) newSL = open + (BE_Buffer_Points * point);
                  else             newSL = open - (BE_Buffer_Points * point);

                  newSL = NormalizeDouble(newSL, digits);

                  bool tighten=false;
                  if(type==OP_BUY && sl < newSL) tighten=true;
                  if(type==OP_SELL && sl > newSL) tighten=true;

                  if(tighten && OrderSelect(ticket, SELECT_BY_TICKET))
                     OrderModify(ticket, OrderOpenPrice(), newSL, 0, 0, clrNONE);
               }
            }
         }
      }

      //---------- ATR trailing for runner ----------//
      if(UseATRTrailing)
      {
         if(profitDist >= (Trail_Start_R * r))
         {
            double curSL = OrderStopLoss();
            double desired = curSL;

            if(type==OP_BUY)
            {
               double target = bid - trailDist;
               target = NormalizeDouble(target, digits);
               if(target > curSL + (Trail_MinStep_Points*point)) desired = target;
            }
            else
            {
               double target = ask + trailDist;
               target = NormalizeDouble(target, digits);
               if(target < curSL - (Trail_MinStep_Points*point)) desired = target;
            }

            if(desired != curSL && OrderSelect(ticket, SELECT_BY_TICKET))
               OrderModify(ticket, OrderOpenPrice(), desired, 0, 0, clrNONE);
         }
      }

      //---------- Time stop ----------//
      if(UseTimeStop)
      {
         // Approx bars since open
         int bars = BarsSince(OrderOpenTime());
         if(bars >= MaxHoldBars)
         {
            // if still not moving, exit
            double curSL2 = OrderStopLoss();
            double r2 = RDist(type, open, curSL2);
            if(r2 > 0)
            {
               double p2 = (type==OP_BUY) ? (bid - open) : (open - ask);
               if(p2 < (TimeStop_MinProfit_R * r2))
               {
                  OrderClose(ticket, OrderLots(), (type==OP_BUY ? bid : ask), SlippagePoints, clrNONE);
               }
            }
         }
      }
   }
}

//=========================== Entry ================================//
void TryEntry(string s)
{
   // Spread filter
   int spr = SpreadPts(s);
   if(spr <= 0) RefreshRates();
   spr = SpreadPts(s);
   if(spr > MaxSpreadPoints) return;

   // Only on new H4 bar
   if(!IsNewBar(s, TF)) return;

   if(CountOpenOrders(s) >= MaxOpenTradesPerSymbol) return;

   double regimeID=0, atrP=0;
   bool active = RegimeActive(s, regimeID, atrP);
   if(!active) return;

   // One-shot per regime
   if(regimeID > 0 && GetTradedID(s) == regimeID) return;

   bool buy = AllowBuy  && BuySignal(s);
   bool sell= AllowSell && SellSignal(s);
   if(!buy && !sell) return;

   int cmd = buy ? OP_BUY : OP_SELL;

   double sl = InitialSL(s, cmd);

   RefreshRates();
   double entry = (cmd==OP_BUY) ? MarketInfo(s, MODE_ASK) : MarketInfo(s, MODE_BID);
   double slDist = MathAbs(entry - sl);

   double lots = FixedLots;
   if(!UseFixedLots) lots = CalcLotsByRisk(s, slDist);
   lots = ClampLot(s, lots);

   if(lots <= 0) return;
   if(!HasSufficientMargin(s, lots)) return;

   if(DebugLogs)
   {
      Print("ENTRY ", s,
            " cmd=", (cmd==OP_BUY?"BUY":"SELL"),
            " lots=", DoubleToString(lots,2),
            " sl=", DoubleToString(sl, DigitsOf(s)),
            " ATRpctl=", DoubleToString(atrP,1),
            " bw=", DoubleToString(BBBandwidth(s,1),4),
            " adx=", DoubleToString(iADX(s, TF, ADX_Period, PRICE_CLOSE, MODE_MAIN, 1),1));
   }

   int ticket = SendOrderECN(s, cmd, lots, sl, "XRP_H4_HYB");
   if(ticket > 0)
   {
      // Mark regime as traded to prevent repeated losses in chop
      SetTradedID(s, regimeID);
   }
}

//=========================== MT4 Events ============================//
int OnInit()
{
   Print("XRP_H4_HybridSwingEA init. Symbol=", Sym(), " TF=", TF);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("XRP_H4_HybridSwingEA deinit. reason=", reason);
}

void OnTick()
{
   string s = Sym();

   // Always manage first (partial / trailing / time-stop)
   ManageTrades(s);

   // Then try to enter at regime moments
   TryEntry(s);
}
//+------------------------------------------------------------------+
