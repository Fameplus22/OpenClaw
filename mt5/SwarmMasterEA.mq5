#property strict
#include <Trade/Trade.mqh>

// Hard rule enforced: max 2 open positions per agent per asset
input int      InpMaxPositionsPerAgentPerAsset = 2;
input double   InpMinLot                        = 0.01;
input double   InpMaxLot                        = 0.05;
input int      InpEvalTrades                    = 30;
input double   InpMinProfitFactor               = 1.02;
input int      InpSlippagePoints                = 20;
input bool     InpWriteDashboardFile            = true;
input string   InpDashboardFile                 = "swarm_state.csv";
input string   InpOpenPositionsFile             = "swarm_open_positions.csv";

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
   double   riskPct;
   double   rrTarget;
   ulong    magic;
};

struct PositionTrack
{
   ulong  ticket;
   double initialVolume;
   double riskPips;
   bool   tp1;
   bool   tp2;
   bool   tp3;
   bool   tp4;
};

CTrade trade;
Agent agents[10];
PositionTrack tracks[];
string forexSymbols[];
datetime lastBarTimes[];
int fileHandle = INVALID_HANDLE;

int AgentIndexByMagic(ulong magic)
{
   for(int i=0; i<10; i++) if(agents[i].magic == magic) return i;
   return -1;
}

double PipSize(const string sym)
{
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(digits == 3 || digits == 5) return point * 10.0;
   return point;
}

bool IsForexSymbol(const string sym)
{
   string base = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
   string profit = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
   long mode = SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED) return false;
   return (StringLen(base) == 3 && StringLen(profit) == 3);
}

void BuildForexUniverse()
{
   ArrayResize(forexSymbols, 0);
   int total = SymbolsTotal(false);
   for(int i=0; i<total; i++)
   {
      string sym = SymbolName(i, false);
      if(sym == "" || !IsForexSymbol(sym)) continue;
      SymbolSelect(sym, true);
      int n = ArraySize(forexSymbols);
      ArrayResize(forexSymbols, n + 1);
      forexSymbols[n] = sym;
   }
   ArrayResize(lastBarTimes, ArraySize(forexSymbols));
   for(int j=0; j<ArraySize(lastBarTimes); j++) lastBarTimes[j] = 0;
   Print("Forex universe loaded: ", ArraySize(forexSymbols), " symbols");
}

int PositionsByAgentAndSymbol(ulong magic, const string sym)
{
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == magic && PositionGetString(POSITION_SYMBOL) == sym)
         count++;
   }
   return count;
}

double GetBufferValue(int handle, int buffer, int shift)
{
   if(handle == INVALID_HANDLE) return 0.0;
   double data[]; ArraySetAsSeries(data, true);
   if(CopyBuffer(handle, buffer, shift, 1, data) <= 0) return 0.0;
   return data[0];
}

double MAValue(const string sym, ENUM_MA_METHOD method, int period, ENUM_APPLIED_PRICE price, int shift)
{
   int h = iMA(sym, PERIOD_M5, period, 0, method, price);
   double v = GetBufferValue(h, 0, shift);
   IndicatorRelease(h);
   return v;
}

double RSIValue(const string sym, int period, int shift)
{
   int h = iRSI(sym, PERIOD_M5, period, PRICE_CLOSE);
   double v = GetBufferValue(h, 0, shift);
   IndicatorRelease(h);
   return v;
}

double ATRValue(const string sym, int period, int shift)
{
   int h = iATR(sym, PERIOD_M5, period);
   double v = GetBufferValue(h, 0, shift);
   IndicatorRelease(h);
   return v;
}

void MACDValues(const string sym, double &mainVal, double &signalVal)
{
   int h = iMACD(sym, PERIOD_M5, 12, 26, 9, PRICE_CLOSE);
   if(h == INVALID_HANDLE) { mainVal = 0.0; signalVal = 0.0; return; }
   mainVal = GetBufferValue(h, 0, 0);
   signalVal = GetBufferValue(h, 1, 0);
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
      agents[i].riskPct = 0.20 + (0.10 * (i % 4));
      agents[i].rrTarget = 3.0 + (i % 3);
      agents[i].magic = 990000 + i + 1;
   }

   BuildForexUniverse();

   if(InpWriteDashboardFile)
   {
      fileHandle = FileOpen(InpDashboardFile, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
      if(fileHandle != INVALID_HANDLE)
      {
         FileWrite(fileHandle, "timestamp", "symbol", "agent_id", "strategy", "risk_pct", "rr", "alive", "trades", "wins", "win_rate", "realized_pnl");
         FileFlush(fileHandle);
      }
   }
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(fileHandle != INVALID_HANDLE) FileClose(fileHandle);
}

void OnTick()
{
   ManagePartialTakeProfits();
   RefreshClosedTrades();

   for(int s=0; s<ArraySize(forexSymbols); s++)
   {
      string sym = forexSymbols[s];
      datetime barTime = iTime(sym, PERIOD_M5, 0);
      if(barTime == 0 || barTime == lastBarTimes[s]) continue;
      lastBarTimes[s] = barTime;

      for(int i=0; i<10; i++)
      {
         if(!agents[i].alive) continue;
         if(PositionsByAgentAndSymbol(agents[i].magic, sym) >= InpMaxPositionsPerAgentPerAsset) continue;

         int signal = GetSignal(agents[i].strategy, sym);
         if(signal != 0) PlaceAgentTrade(i, signal, sym);
      }
   }

   ReplaceUnderperformers();
   WriteState();
   WriteOpenPositionsSnapshot();
}

void ComputeBotStopsAndTargets(int idx, const string sym, int signal, double entry, double &sl, double &tp, double &riskPips)
{
   double atr = ATRValue(sym, 14, 0);
   double pip = PipSize(sym);
   if(pip <= 0) pip = SymbolInfoDouble(sym, SYMBOL_POINT);

   double stratMult = 1.2 + (agents[idx].strategy % 4) * 0.4;
   double riskDist = MathMax(atr * stratMult, 8.0 * pip);
   riskPips = riskDist / pip;

   double tpDist = riskDist * agents[idx].rrTarget;
   sl = (signal > 0) ? entry - riskDist : entry + riskDist;
   tp = (signal > 0) ? entry + tpDist : entry - tpDist;
}

double ComputeLot(const string sym, double riskDistPrice, double riskPct)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskCash = balance * (riskPct / 100.0);

   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0) return InpMinLot;

   double lossPerLot = (riskDistPrice / tickSize) * tickValue;
   if(lossPerLot <= 0) return InpMinLot;

   double raw = riskCash / lossPerLot;
   double clipped = MathMax(InpMinLot, MathMin(InpMaxLot, raw));

   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double minv = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);

   clipped = MathMax(minv, MathMin(maxv, clipped));
   clipped = MathFloor(clipped / step) * step;
   return NormalizeDouble(clipped, 2);
}

void TrackPosition(ulong ticket, double vol, double riskPips)
{
   if(ticket == 0) return;
   for(int i=0; i<ArraySize(tracks); i++) if(tracks[i].ticket == ticket) return;
   int n = ArraySize(tracks);
   ArrayResize(tracks, n + 1);
   tracks[n].ticket = ticket;
   tracks[n].initialVolume = vol;
   tracks[n].riskPips = riskPips;
   tracks[n].tp1 = tracks[n].tp2 = tracks[n].tp3 = tracks[n].tp4 = false;
}

int FindTrackIndex(ulong ticket)
{
   for(int i=0; i<ArraySize(tracks); i++) if(tracks[i].ticket == ticket) return i;
   return -1;
}

void PlaceAgentTrade(int idx, int signal, const string sym)
{
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double entry = (signal > 0 ? ask : bid);

   double sl=0.0,tp=0.0,riskPips=0.0;
   ComputeBotStopsAndTargets(idx, sym, signal, entry, sl, tp, riskPips);
   double riskDist = MathAbs(entry - sl);

   double lot = ComputeLot(sym, riskDist, agents[idx].riskPct);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   trade.SetExpertMagicNumber((long)agents[idx].magic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   bool ok = (signal > 0)
             ? trade.Buy(lot, sym, 0.0, NormalizeDouble(sl, digits), NormalizeDouble(tp, digits), "SwarmBuy")
             : trade.Sell(lot, sym, 0.0, NormalizeDouble(sl, digits), NormalizeDouble(tp, digits), "SwarmSell");

   if(!ok)
   {
      Print("Agent ", agents[idx].id, " order failed on ", sym, ": ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return;
   }

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == agents[idx].magic && PositionGetString(POSITION_SYMBOL) == sym)
      {
         TrackPosition(ticket, PositionGetDouble(POSITION_VOLUME), riskPips);
         break;
      }
   }
}

void ManagePartialTakeProfits()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double current = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double pip = PipSize(sym);
      double movePips = (type == POSITION_TYPE_BUY) ? (current - open) / pip : (open - current) / pip;

      int ti = FindTrackIndex(ticket);
      if(ti < 0)
      {
         double sl = PositionGetDouble(POSITION_SL);
         double riskPips = MathAbs(open - sl) / pip;
         TrackPosition(ticket, vol, riskPips);
         ti = FindTrackIndex(ticket);
         if(ti < 0) continue;
      }

      double riskPips = MathMax(tracks[ti].riskPips, 1.0);
      double slice = tracks[ti].initialVolume * 0.20;
      double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
      slice = MathFloor(slice / step) * step;
      if(slice < SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN)) slice = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);

      if(movePips >= riskPips * 1.0 && !tracks[ti].tp1 && vol > SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN))
      { trade.PositionClosePartial(ticket, MathMin(slice, vol)); tracks[ti].tp1 = true; }
      if(movePips >= riskPips * 2.0 && !tracks[ti].tp2 && PositionGetDouble(POSITION_VOLUME) > SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN))
      { trade.PositionClosePartial(ticket, MathMin(slice, PositionGetDouble(POSITION_VOLUME))); tracks[ti].tp2 = true; }
      if(movePips >= riskPips * 3.0 && !tracks[ti].tp3 && PositionGetDouble(POSITION_VOLUME) > SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN))
      { trade.PositionClosePartial(ticket, MathMin(slice, PositionGetDouble(POSITION_VOLUME))); tracks[ti].tp3 = true; }
      if(movePips >= riskPips * 4.0 && !tracks[ti].tp4 && PositionGetDouble(POSITION_VOLUME) > SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN))
      { trade.PositionClosePartial(ticket, MathMin(slice, PositionGetDouble(POSITION_VOLUME))); tracks[ti].tp4 = true; }
   }
}

int GetSignal(int strat, const string sym)
{
   switch(strat)
   {
      case STRAT_SMA_CROSS:        return SignalSmaCross(sym);
      case STRAT_EMA_PULLBACK:     return SignalEmaPullback(sym);
      case STRAT_RSI_REV:          return SignalRsi(sym);
      case STRAT_BREAKOUT20:       return SignalBreakout20(sym);
      case STRAT_ATR_IMPULSE:      return SignalAtrImpulse(sym);
      case STRAT_MOMENTUM5:        return SignalMomentum5(sym);
      case STRAT_VWAP_PROXY:       return SignalVwapProxy(sym);
      case STRAT_DONCHIAN_REVERT:  return SignalDonchianRevert(sym);
      case STRAT_MACD_HIST:        return SignalMacdHist(sym);
      case STRAT_TREND_SLOPE:      return SignalTrendSlope(sym);
   }
   return 0;
}

int SignalSmaCross(const string sym){ double f=MAValue(sym,MODE_SMA,10,PRICE_CLOSE,0); double s=MAValue(sym,MODE_SMA,30,PRICE_CLOSE,0); return (f>s?1:-1); }
int SignalEmaPullback(const string sym){ double e=MAValue(sym,MODE_EMA,20,PRICE_CLOSE,0); double c=iClose(sym,PERIOD_M5,0); if(c<e*0.998) return 1; if(c>e*1.002) return -1; return 0; }
int SignalRsi(const string sym){ double r=RSIValue(sym,14,0); if(r<30) return 1; if(r>70) return -1; return 0; }
int SignalBreakout20(const string sym){ double hi=-DBL_MAX, lo=DBL_MAX; for(int i=1;i<=20;i++){ hi=MathMax(hi,iHigh(sym,PERIOD_M5,i)); lo=MathMin(lo,iLow(sym,PERIOD_M5,i)); } double c=iClose(sym,PERIOD_M5,0); if(c>hi) return 1; if(c<lo) return -1; return 0; }
int SignalAtrImpulse(const string sym){ double atr=ATRValue(sym,14,0); double d=iClose(sym,PERIOD_M5,0)-iClose(sym,PERIOD_M5,1); if(d>atr*0.35) return 1; if(d<-atr*0.35) return -1; return 0; }
int SignalMomentum5(const string sym){ double p0=iClose(sym,PERIOD_M5,0); double p5=iClose(sym,PERIOD_M5,5); if(p5<=0) return 0; double m=(p0-p5)/p5; if(m>0.001) return 1; if(m<-0.001) return -1; return 0; }
int SignalVwapProxy(const string sym){ double c=iClose(sym,PERIOD_M5,0); double ema=MAValue(sym,MODE_EMA,40,PRICE_TYPICAL,0); if(c>ema) return 1; if(c<ema) return -1; return 0; }
int SignalDonchianRevert(const string sym){ double hi=-DBL_MAX, lo=DBL_MAX; for(int i=1;i<=20;i++){ hi=MathMax(hi,iHigh(sym,PERIOD_M5,i)); lo=MathMin(lo,iLow(sym,PERIOD_M5,i)); } double c=iClose(sym,PERIOD_M5,0); if(c>hi*0.999) return -1; if(c<lo*1.001) return 1; return 0; }
int SignalMacdHist(const string sym){ double m=0.0,s=0.0; MACDValues(sym,m,s); return (m-s>0?1:-1); }
int SignalTrendSlope(const string sym){ double c0=iClose(sym,PERIOD_M5,0); double c30=iClose(sym,PERIOD_M5,30); return (c0>c30?1:-1); }

void RefreshClosedTrades()
{
   datetime from = TimeCurrent() - 86400 * 14;
   datetime to = TimeCurrent();
   if(!HistorySelect(from, to)) return;

   for(int i=0; i<10; i++) { agents[i].trades = 0; agents[i].wins = 0; agents[i].realizedPnl = 0.0; }

   int deals = HistoryDealsTotal();
   for(int i=0; i<deals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      ulong magic = (ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC);
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT) continue;

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
   for(int i=0; i<10; i++)
   {
      if(agents[i].trades < InpEvalTrades) continue;
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      double pf = (bal + agents[i].realizedPnl) / MathMax(bal, 1.0);
      if(pf < InpMinProfitFactor)
      {
         int newStrategy = (agents[i].strategy + 3) % 10;
         agents[i].strategy = newStrategy;
         agents[i].riskPct = 0.20 + (0.10 * ((i + newStrategy) % 4));
         agents[i].rrTarget = 3.0 + ((i + newStrategy) % 3);
         agents[i].trades = 0;
         agents[i].wins = 0;
         agents[i].realizedPnl = 0;
         agents[i].alive = true;
         Print("Recycled agent ", agents[i].id, " -> strat ", newStrategy, ", risk% ", DoubleToString(agents[i].riskPct,2), ", RR ", DoubleToString(agents[i].rrTarget,1));
      }
   }
}

void WriteState()
{
   if(fileHandle == INVALID_HANDLE) return;
   datetime now = TimeCurrent();
   for(int i=0; i<10; i++)
   {
      double wr = (agents[i].trades > 0 ? (double)agents[i].wins / agents[i].trades : 0.0);
      FileWrite(fileHandle,
                TimeToString(now, TIME_DATE|TIME_SECONDS),
                "ALL_FOREX",
                agents[i].id,
                agents[i].strategy,
                DoubleToString(agents[i].riskPct,2),
                DoubleToString(agents[i].rrTarget,1),
                (agents[i].alive ? 1 : 0),
                agents[i].trades,
                agents[i].wins,
                DoubleToString(wr, 4),
                DoubleToString(agents[i].realizedPnl, 2));
   }
   FileFlush(fileHandle);
}

void WriteOpenPositionsSnapshot()
{
   int fh = FileOpen(InpOpenPositionsFile, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(fh == INVALID_HANDLE) return;

   FileWrite(fh, "timestamp", "ticket", "symbol", "agent_id", "strategy", "side", "volume", "open_price", "current_price", "sl", "tp", "pnl", "swap", "magic");
   datetime now = TimeCurrent();

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double current = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double pnl = PositionGetDouble(POSITION_PROFIT);
      double swap = PositionGetDouble(POSITION_SWAP);
      double vol = PositionGetDouble(POSITION_VOLUME);
      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      int aidx = AgentIndexByMagic(magic);
      int aid = (aidx >= 0 ? agents[aidx].id : -1);
      int strat = (aidx >= 0 ? agents[aidx].strategy : -1);
      string side = (type == POSITION_TYPE_BUY ? "BUY" : "SELL");

      FileWrite(fh,
                TimeToString(now, TIME_DATE|TIME_SECONDS),
                (string)ticket,
                sym,
                aid,
                strat,
                side,
                DoubleToString(vol, 2),
                DoubleToString(open, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
                DoubleToString(current, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
                DoubleToString(sl, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
                DoubleToString(tp, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
                DoubleToString(pnl, 2),
                DoubleToString(swap, 2),
                (string)magic);
   }

   FileClose(fh);
}
