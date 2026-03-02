#property strict
#include <Trade/Trade.mqh>

input double   InpRiskPercent           = 1.0;
input double   InpMinLot                = 0.01;
input double   InpMaxLot                = 0.05;
input double   InpTakeProfitRiskFactor  = 0.50;
input double   InpStopLossRiskFactor    = 1.00;
input int      InpEvalTrades            = 30;
input double   InpMinProfitFactor       = 1.02;
input int      InpSlippagePoints        = 20;
input bool     InpWriteDashboardFile    = true;
input string   InpDashboardFile         = "swarm_state.csv";

enum StrategyType
{
   STRAT_SMA_CROSS = 0,
   STRAT_EMA_PULLBACK,
   STRAT_RSI_REV,
   STRAT_BREAKOUT20,
   STRAT_ATR_IMPULSE,
   STRAT_MOMENTUM5,
   STRAT_VWAP_PROXY,
   STRAT_DONCHIAN_REVERT,
   STRAT_MACD_HIST,
   STRAT_TREND_SLOPE
};

struct Agent
{
   int      id;
   int      strategy;
   bool     alive;
   int      trades;
   int      wins;
   double   realizedPnl;
   ulong    magic;
};

CTrade trade;
Agent agents[10];
datetime lastBar = 0;
int fileHandle = INVALID_HANDLE;

double GetBufferValue(int handle, int shift)
{
   if(handle == INVALID_HANDLE)
      return 0.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) <= 0)
      return 0.0;
   return buf[0];
}

double MAValue(ENUM_MA_METHOD method, int period, ENUM_APPLIED_PRICE price, int shift)
{
   int h = iMA(_Symbol, PERIOD_M5, period, 0, method, price);
   double v = GetBufferValue(h, shift);
   IndicatorRelease(h);
   return v;
}

double RSIValue(int period, int shift)
{
   int h = iRSI(_Symbol, PERIOD_M5, period, PRICE_CLOSE);
   double v = GetBufferValue(h, shift);
   IndicatorRelease(h);
   return v;
}

double ATRValue(int period, int shift)
{
   int h = iATR(_Symbol, PERIOD_M5, period);
   double v = GetBufferValue(h, shift);
   IndicatorRelease(h);
   return v;
}

void MACDValues(double &mainVal, double &signalVal)
{
   int h = iMACD(_Symbol, PERIOD_M5, 12, 26, 9, PRICE_CLOSE);
   if(h == INVALID_HANDLE)
   {
      mainVal = 0.0;
      signalVal = 0.0;
      return;
   }
   double m[], s[];
   ArraySetAsSeries(m, true);
   ArraySetAsSeries(s, true);
   if(CopyBuffer(h, 0, 0, 1, m) <= 0 || CopyBuffer(h, 1, 0, 1, s) <= 0)
   {
      mainVal = 0.0;
      signalVal = 0.0;
   }
   else
   {
      mainVal = m[0];
      signalVal = s[0];
   }
   IndicatorRelease(h);
}

int OnInit()
{
   for(int i=0; i<10; i++)
   {
      agents[i].id = i + 1;
      agents[i].strategy = i;
      agents[i].alive = true;
      agents[i].trades = 0;
      agents[i].wins = 0;
      agents[i].realizedPnl = 0.0;
      agents[i].magic = 990000 + i + 1;
   }

   if(InpWriteDashboardFile)
   {
      fileHandle = FileOpen(InpDashboardFile, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
      if(fileHandle != INVALID_HANDLE)
      {
         FileWrite(fileHandle, "timestamp", "agent_id", "strategy", "alive", "trades", "wins", "win_rate", "realized_pnl");
         FileFlush(fileHandle);
      }
   }

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(fileHandle != INVALID_HANDLE)
      FileClose(fileHandle);
}

void OnTick()
{
   datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
   if(barTime == lastBar)
      return;
   lastBar = barTime;

   RefreshClosedTrades();

   for(int i=0; i<10; i++)
   {
      if(!agents[i].alive || HasOpenPosition(agents[i].magic))
         continue;

      int signal = GetSignal(agents[i].strategy);
      if(signal != 0)
         PlaceAgentTrade(i, signal);
   }

   ReplaceUnderperformers();
   WriteState();
}

bool HasOpenPosition(ulong magic)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == magic && PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
   }
   return false;
}

void PlaceAgentTrade(int idx, int signal)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = (signal > 0 ? ask : bid);

   double riskDistance = entry * (InpRiskPercent / 100.0);
   double slDistance = riskDistance * InpStopLossRiskFactor;
   double tpDistance = riskDistance * InpTakeProfitRiskFactor;

   double lot = ComputeLot(entry);
   double sl = (signal > 0 ? entry - slDistance : entry + slDistance);
   double tp = (signal > 0 ? entry + tpDistance : entry - tpDistance);

   trade.SetExpertMagicNumber((long)agents[idx].magic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   bool ok = (signal > 0)
             ? trade.Buy(lot, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "SwarmBuy")
             : trade.Sell(lot, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "SwarmSell");

   if(!ok)
      Print("Agent ", agents[idx].id, " order failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
}

double ComputeLot(double entry)
{
   double raw = (AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0)) / MathMax(entry, 0.00001);
   double clipped = MathMax(InpMinLot, MathMin(InpMaxLot, raw));

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   clipped = MathMax(minv, MathMin(maxv, clipped));
   clipped = MathFloor(clipped / step) * step;
   return NormalizeDouble(clipped, 2);
}

int GetSignal(int strat)
{
   switch(strat)
   {
      case STRAT_SMA_CROSS:        return SignalSmaCross();
      case STRAT_EMA_PULLBACK:     return SignalEmaPullback();
      case STRAT_RSI_REV:          return SignalRsi();
      case STRAT_BREAKOUT20:       return SignalBreakout20();
      case STRAT_ATR_IMPULSE:      return SignalAtrImpulse();
      case STRAT_MOMENTUM5:        return SignalMomentum5();
      case STRAT_VWAP_PROXY:       return SignalVwapProxy();
      case STRAT_DONCHIAN_REVERT:  return SignalDonchianRevert();
      case STRAT_MACD_HIST:        return SignalMacdHist();
      case STRAT_TREND_SLOPE:      return SignalTrendSlope();
   }
   return 0;
}

int SignalSmaCross(){ double f=MAValue(MODE_SMA,10,PRICE_CLOSE,0); double s=MAValue(MODE_SMA,30,PRICE_CLOSE,0); return (f>s?1:-1); }
int SignalEmaPullback(){ double e=MAValue(MODE_EMA,20,PRICE_CLOSE,0); double c=iClose(_Symbol,PERIOD_M5,0); if(c<e*0.998) return 1; if(c>e*1.002) return -1; return 0; }
int SignalRsi(){ double r=RSIValue(14,0); if(r<30) return 1; if(r>70) return -1; return 0; }
int SignalBreakout20(){ double hi=-DBL_MAX, lo=DBL_MAX; for(int i=1;i<=20;i++){ hi=MathMax(hi,iHigh(_Symbol,PERIOD_M5,i)); lo=MathMin(lo,iLow(_Symbol,PERIOD_M5,i)); } double c=iClose(_Symbol,PERIOD_M5,0); if(c>hi) return 1; if(c<lo) return -1; return 0; }
int SignalAtrImpulse(){ double atr=ATRValue(14,0); double d=iClose(_Symbol,PERIOD_M5,0)-iClose(_Symbol,PERIOD_M5,1); if(d>atr*0.35) return 1; if(d<-atr*0.35) return -1; return 0; }
int SignalMomentum5(){ double p0=iClose(_Symbol,PERIOD_M5,0); double p5=iClose(_Symbol,PERIOD_M5,5); if(p5<=0) return 0; double m=(p0-p5)/p5; if(m>0.001) return 1; if(m<-0.001) return -1; return 0; }
int SignalVwapProxy(){ double c=iClose(_Symbol,PERIOD_M5,0); double ema=MAValue(MODE_EMA,40,PRICE_TYPICAL,0); if(c>ema) return 1; if(c<ema) return -1; return 0; }
int SignalDonchianRevert(){ double hi=-DBL_MAX, lo=DBL_MAX; for(int i=1;i<=20;i++){ hi=MathMax(hi,iHigh(_Symbol,PERIOD_M5,i)); lo=MathMin(lo,iLow(_Symbol,PERIOD_M5,i)); } double c=iClose(_Symbol,PERIOD_M5,0); if(c>hi*0.999) return -1; if(c<lo*1.001) return 1; return 0; }
int SignalMacdHist(){ double m=0.0,s=0.0; MACDValues(m,s); return (m-s>0?1:-1); }
int SignalTrendSlope(){ double c0=iClose(_Symbol,PERIOD_M5,0); double c30=iClose(_Symbol,PERIOD_M5,30); return (c0>c30?1:-1); }

void RefreshClosedTrades()
{
   datetime from = TimeCurrent() - 86400 * 14;
   datetime to = TimeCurrent();
   if(!HistorySelect(from, to))
      return;

   for(int i=0; i<10; i++)
   {
      agents[i].trades = 0;
      agents[i].wins = 0;
      agents[i].realizedPnl = 0.0;
   }

   int deals = HistoryDealsTotal();
   for(int i=0; i<deals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      ulong magic = (ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC);
      string sym = HistoryDealGetString(ticket, DEAL_SYMBOL);
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(sym != _Symbol || entry != DEAL_ENTRY_OUT)
         continue;

      for(int a=0; a<10; a++)
      {
         if(agents[a].magic == magic)
         {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_SWAP) + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
            agents[a].trades++;
            agents[a].realizedPnl += profit;
            if(profit > 0) agents[a].wins++;
            break;
         }
      }
   }
}

void ReplaceUnderperformers()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   for(int i=0; i<10; i++)
   {
      if(agents[i].trades < InpEvalTrades)
         continue;
      double pf = (balance + agents[i].realizedPnl) / MathMax(balance, 1.0);
      if(pf < InpMinProfitFactor)
      {
         int newStrategy = (agents[i].strategy + 3) % 10;
         Print("Replacing agent ", agents[i].id, " strategy ", agents[i].strategy, " -> ", newStrategy);
         agents[i].strategy = newStrategy;
         agents[i].trades = 0;
         agents[i].wins = 0;
         agents[i].realizedPnl = 0;
         agents[i].alive = true;
      }
   }
}

void WriteState()
{
   if(fileHandle == INVALID_HANDLE)
      return;

   datetime now = TimeCurrent();
   for(int i=0; i<10; i++)
   {
      double wr = (agents[i].trades > 0 ? (double)agents[i].wins / agents[i].trades : 0.0);
      FileWrite(fileHandle,
                TimeToString(now, TIME_DATE|TIME_SECONDS),
                agents[i].id,
                agents[i].strategy,
                (agents[i].alive ? 1 : 0),
                agents[i].trades,
                agents[i].wins,
                DoubleToString(wr, 4),
                DoubleToString(agents[i].realizedPnl, 2));
   }
   FileFlush(fileHandle);
}
