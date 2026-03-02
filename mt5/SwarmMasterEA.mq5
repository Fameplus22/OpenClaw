#property strict
#include <Trade/Trade.mqh>

// ========================== Core Controls ==========================
input int      InpMaxPositionsPerAgentPerAsset = 2;   // hard rule
input double   InpMinLot                        = 0.01;
input double   InpMaxLot                        = 0.05;
input int      InpEvalTrades                    = 30;
input int      InpHistoryLookbackDays           = 14;
input double   InpMinProfitFactor               = 1.02;
input int      InpSlippagePoints                = 20;
input bool     InpWriteDashboardFile            = true;
input string   InpDashboardFile                 = "swarm_state.csv";
input string   InpOpenPositionsFile             = "swarm_open_positions.csv";

// ========================== 100x Redesign Controls ==========================
input bool     InpUseMTFConfirm                 = true;     // #1
input int      InpH1EmaPeriod                   = 50;
input bool     InpUseRegimeFilter               = true;     // #2
input int      InpAdxPeriod                     = 14;
input int      InpBbPeriod                      = 20;
input double   InpAdxTrendThresh                = 22.0;
input bool     InpUsePortfolioRiskManager       = true;     // #3
input double   InpDirectionRiskCapPct           = 60.0;     // max same-direction risk budget share
input double   InpPortfolioRiskBudgetPct        = 4.0;      // total live risk budget
input bool     InpUseKellyScaling               = true;     // #5
input bool     InpUseSniperEntry                = true;     // #6
input int      InpSniperExpiryBars              = 2;
input bool     InpUseSessionFilter              = true;     // #7
input bool     InpUseNewsFilter                 = false;
input string   InpNewsWindowFile                = "news_windows.csv"; // start_utc,end_utc lines
input bool     InpTesterSingleSymbolMode        = true;
input bool     InpTesterRelaxFilters            = true;

// -------------------------------------------------------------------
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

enum RegimeType
{
   REGIME_TREND = 0,
   REGIME_RANGE,
   REGIME_VOLATILE,
   REGIME_QUIET
};

enum AssetClassType
{
   ASSET_FX = 0,
   ASSET_METAL,
   ASSET_INDEX,
   ASSET_STOCK
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
   double   peakPnl;
   double   maxDrawdown;
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
string universe[];
datetime lastBarTimes[];
int fileHandle = INVALID_HANDLE;

// Learning table: strategy x regime x assetclass
int    statN[10][4][4];
double statPnL[10][4][4];
double statPnLSq[10][4][4];

int AgentIndexByMagic(ulong magic){ for(int i=0;i<10;i++) if(agents[i].magic==magic) return i; return -1; }


string RegimeToStr(RegimeType r)
{
   if(r==REGIME_TREND) return "TREND";
   if(r==REGIME_RANGE) return "RANGE";
   if(r==REGIME_VOLATILE) return "VOLATILE";
   return "QUIET";
}

string AssetClassToStr(AssetClassType c)
{
   if(c==ASSET_FX) return "FX";
   if(c==ASSET_METAL) return "METAL";
   if(c==ASSET_INDEX) return "INDEX";
   return "STOCK";
}

void LogSwapEvent(int agentId, int oldStrat, int newStrat, int trades, double winRate, double pnl, double pf, RegimeType r, AssetClassType c)
{
   int fh = FileOpen("swarm_swap_log.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(fh==INVALID_HANDLE) return;
   if(FileSize(fh)==0)
      FileWrite(fh,"timestamp","agent_id","old_strategy","new_strategy","trades","win_rate","pnl","profit_factor","regime","asset_class");
   FileSeek(fh,0,SEEK_END);
   FileWrite(fh,
             TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
             agentId, oldStrat, newStrat, trades,
             DoubleToString(winRate,4),
             DoubleToString(pnl,2),
             DoubleToString(pf,4),
             RegimeToStr(r),
             AssetClassToStr(c));
   FileClose(fh);
}

bool ContainsIgnoreCase(string haystack, string needle)
{
   string hs = haystack;
   string nd = needle;
   StringToUpper(hs);
   StringToUpper(nd);
   return (StringFind(hs, nd) >= 0);
}

double PipSize(const string sym)
{
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(digits == 3 || digits == 5) return point * 10.0;
   return point;
}

bool IsTradableSymbol(const string sym)
{
   long mode = SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED) return false;
   return SymbolSelect(sym, true);
}

bool IsTop30Forex(const string sym)
{
   string base = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
   string profit = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
   if(StringLen(base) != 3 || StringLen(profit) != 3) return false;
   string pair = base + profit;
   string top30[] = {
      "EURUSD","GBPUSD","USDJPY","USDCHF","AUDUSD","USDCAD","NZDUSD",
      "EURGBP","EURJPY","EURCHF","EURAUD","EURCAD","EURNZD",
      "GBPJPY","GBPCHF","GBPAUD","GBPCAD","GBPNZD",
      "AUDJPY","AUDCHF","AUDCAD","AUDNZD",
      "NZDJPY","NZDCHF","NZDCAD","CADJPY","CADCHF","CHFJPY","USDSEK","USDNOK"
   };
   for(int i=0;i<ArraySize(top30);i++) if(pair==top30[i]) return true;
   return false;
}

bool IsGoldSymbol(const string sym){ return ContainsIgnoreCase(sym,"XAU") || ContainsIgnoreCase(sym,"GOLD"); }
bool IsSilverSymbol(const string sym){ return ContainsIgnoreCase(sym,"XAG") || ContainsIgnoreCase(sym,"SILVER"); }
bool IsTargetIndex(const string sym){ return ContainsIgnoreCase(sym,"NAS")||ContainsIgnoreCase(sym,"USTEC")||ContainsIgnoreCase(sym,"US100")||ContainsIgnoreCase(sym,"US30")||ContainsIgnoreCase(sym,"DJI")||ContainsIgnoreCase(sym,"GER30")||ContainsIgnoreCase(sym,"DE30")||ContainsIgnoreCase(sym,"DAX"); }
bool IsFastStock(const string sym){ string t[] = {"NVDA","TSLA","AAPL","META","AMZN","MSFT","AMD","NFLX"}; for(int i=0;i<ArraySize(t);i++) if(ContainsIgnoreCase(sym,t[i])) return true; return false; }

AssetClassType AssetClassOf(const string sym)
{
   if(IsTop30Forex(sym)) return ASSET_FX;
   if(IsGoldSymbol(sym) || IsSilverSymbol(sym)) return ASSET_METAL;
   if(IsTargetIndex(sym)) return ASSET_INDEX;
   return ASSET_STOCK;
}

void BuildUniverse()
{
   ArrayResize(universe, 0);

   if(MQLInfoInteger(MQL_TESTER) && InpTesterSingleSymbolMode)
   {
      ArrayResize(universe, 1);
      universe[0] = _Symbol;
      ArrayResize(lastBarTimes, 1);
      lastBarTimes[0] = 0;
      Print("Tester single-symbol mode ON: ", _Symbol);
      return;
   }

   int total = SymbolsTotal(false);
   for(int i=0;i<total;i++)
   {
      string sym = SymbolName(i,false);
      if(sym=="" || !IsTradableSymbol(sym)) continue;
      bool keep = IsTop30Forex(sym) || IsGoldSymbol(sym) || IsSilverSymbol(sym) || IsTargetIndex(sym) || IsFastStock(sym);
      if(!keep) continue;
      int n=ArraySize(universe);
      ArrayResize(universe,n+1);
      universe[n]=sym;
   }
   ArrayResize(lastBarTimes, ArraySize(universe));
   for(int j=0;j<ArraySize(lastBarTimes);j++) lastBarTimes[j]=0;
   Print("Target universe loaded: ", ArraySize(universe));
}

int PositionsByAgentAndSymbol(ulong magic, const string sym)
{
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)==magic && PositionGetString(POSITION_SYMBOL)==sym) c++;
   }
   return c;
}

double GetBufferValue(int handle,int buffer,int shift){ if(handle==INVALID_HANDLE) return 0.0; double data[]; ArraySetAsSeries(data,true); if(CopyBuffer(handle,buffer,shift,1,data)<=0) return 0.0; return data[0]; }
double MAValue(const string sym, ENUM_TIMEFRAMES tf, ENUM_MA_METHOD maMethod, int maPeriod, ENUM_APPLIED_PRICE apPrice, int shift){ int h=iMA(sym,tf,maPeriod,0,maMethod,apPrice); double v=GetBufferValue(h,0,shift); IndicatorRelease(h); return v; }
double RSIValue(const string sym,int period,int shift){ int h=iRSI(sym,PERIOD_M5,period,PRICE_CLOSE); double v=GetBufferValue(h,0,shift); IndicatorRelease(h); return v; }
double ATRValue(const string sym,int period,int shift){ int h=iATR(sym,PERIOD_M5,period); double v=GetBufferValue(h,0,shift); IndicatorRelease(h); return v; }
double ADXValue(const string sym,int period,int shift){ int h=iADX(sym,PERIOD_M5,period); double v=GetBufferValue(h,0,shift); IndicatorRelease(h); return v; }
void MACDValues(const string sym,double &m,double &s){ int h=iMACD(sym,PERIOD_M5,12,26,9,PRICE_CLOSE); if(h==INVALID_HANDLE){m=0;s=0;return;} m=GetBufferValue(h,0,0); s=GetBufferValue(h,1,0); IndicatorRelease(h); }

double BollWidth(const string sym)
{
   int h=iBands(sym,PERIOD_M5,InpBbPeriod,0,2.0,PRICE_CLOSE);
   if(h==INVALID_HANDLE) return 0.0;
   double mid=GetBufferValue(h,0,0), up=GetBufferValue(h,1,0), lo=GetBufferValue(h,2,0);
   IndicatorRelease(h);
   if(mid==0) return 0.0;
   return (up-lo)/mid;
}

double ATRPercentileProxy(const string sym)
{
   double atr0 = ATRValue(sym,14,0);
   double sum=0.0;
   for(int i=1;i<=50;i++) sum += ATRValue(sym,14,i);
   double avg = sum/50.0;
   if(avg<=0) return 0.5;
   double ratio = atr0/avg;
   if(ratio<0.7) return 0.2;
   if(ratio>1.3) return 0.85;
   return 0.5;
}

RegimeType ClassifyRegime(const string sym)
{
   double adx = ADXValue(sym, InpAdxPeriod, 0);
   double atrPct = ATRPercentileProxy(sym);
   double bw = BollWidth(sym);

   if(adx >= InpAdxTrendThresh && atrPct >= 0.45) return REGIME_TREND;
   if(atrPct >= 0.75 || bw >= 0.03) return REGIME_VOLATILE;
   if(adx < 16.0 && atrPct < 0.35 && bw < 0.015) return REGIME_QUIET;
   return REGIME_RANGE;
}

bool StrategyAllowedInRegime(int strat, RegimeType r)
{
   bool trendStrat = (strat==STRAT_SMA_CROSS || strat==STRAT_BREAKOUT20 || strat==STRAT_ATR_IMPULSE || strat==STRAT_MOMENTUM5 || strat==STRAT_MACD_HIST || strat==STRAT_TREND_SLOPE);
   bool meanRev = (strat==STRAT_RSI_REV || strat==STRAT_DONCHIAN_REVERT || strat==STRAT_EMA_PULLBACK || strat==STRAT_VWAP_PROXY);

   if(r==REGIME_TREND) return trendStrat;
   if(r==REGIME_RANGE) return meanRev;
   if(r==REGIME_VOLATILE) return (strat==STRAT_BREAKOUT20 || strat==STRAT_ATR_IMPULSE || strat==STRAT_MOMENTUM5);
   return (strat==STRAT_RSI_REV || strat==STRAT_EMA_PULLBACK); // quiet
}

bool MTFTrendAgrees(const string sym, int direction)
{
   if(!InpUseMTFConfirm) return true;
   double e0 = MAValue(sym, PERIOD_H1, MODE_EMA, InpH1EmaPeriod, PRICE_CLOSE, 0);
   double e3 = MAValue(sym, PERIOD_H1, MODE_EMA, InpH1EmaPeriod, PRICE_CLOSE, 3);
   int h1Trend = (e0>e3?1:-1);
   return (direction==h1Trend);
}

bool IsSessionAllowed(const string sym)
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;
   AssetClassType c = AssetClassOf(sym);
   if(c==ASSET_FX) return (h>=6 && h<=20);      // London + NY overlap focus
   if(c==ASSET_METAL) return (h>=7 && h<=21);
   if(c==ASSET_INDEX) return (h>=12 && h<=21);  // US/EU index active zones
   return (h>=13 && h<=20);                     // US stocks
}

bool InNewsBlackout()
{
   if(!InpUseNewsFilter) return false;
   int fh = FileOpen(InpNewsWindowFile, FILE_READ|FILE_CSV|FILE_ANSI, ',');
   if(fh==INVALID_HANDLE) return false;

   datetime now = TimeGMT();
   bool block=false;
   while(!FileIsEnding(fh))
   {
      string s1=FileReadString(fh);
      string s2=FileReadString(fh);
      if(s1=="" || s2=="") continue;
      datetime t1=(datetime)StringToTime(s1);
      datetime t2=(datetime)StringToTime(s2);
      if(now>=t1 && now<=t2){ block=true; break; }
   }
   FileClose(fh);
   return block;
}

void ComputeBotStopsAndTargets(int idx,const string sym,int signal,double entry,double &sl,double &tp,double &riskPips)
{
   // #8 adaptive stops: tighter of swing/EMA/ATR-protective logic that still respects noise floor
   double pip=PipSize(sym);
   if(pip<=0) pip=SymbolInfoDouble(sym,SYMBOL_POINT);

   double atr=ATRValue(sym,14,0);
   double ema20=MAValue(sym,PERIOD_M5,MODE_EMA,20,PRICE_CLOSE,0);

   double swingLo=DBL_MAX, swingHi=-DBL_MAX;
   for(int i=1;i<=8;i++)
   {
      swingLo=MathMin(swingLo, iLow(sym,PERIOD_M5,i));
      swingHi=MathMax(swingHi, iHigh(sym,PERIOD_M5,i));
   }

   double slBySwing = (signal>0 ? swingLo - 1.5*pip : swingHi + 1.5*pip);
   double slByEma   = (signal>0 ? ema20 - 2.0*pip : ema20 + 2.0*pip);
   double slByAtr   = (signal>0 ? entry - MathMax(atr*1.2, 8.0*pip) : entry + MathMax(atr*1.2, 8.0*pip));

   if(signal>0) sl = MathMax(slBySwing, MathMax(slByEma, slByAtr));
   else         sl = MathMin(slBySwing, MathMin(slByEma, slByAtr));

   double riskDist=MathAbs(entry-sl);
   if(riskDist < 6.0*pip)
   {
      sl = (signal>0 ? entry-6.0*pip : entry+6.0*pip);
      riskDist=MathAbs(entry-sl);
   }

   riskPips=riskDist/pip;
   double tpDist = riskDist * agents[idx].rrTarget;
   tp = (signal>0 ? entry+tpDist : entry-tpDist);
}

double DirectionalOpenRisk(bool longs)
{
   double total=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;

      long type=PositionGetInteger(POSITION_TYPE);
      bool isLong = (type==POSITION_TYPE_BUY);
      if(isLong!=longs) continue;

      string sym=PositionGetString(POSITION_SYMBOL);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double vol=PositionGetDouble(POSITION_VOLUME);
      if(sl<=0 || vol<=0) continue;

      double tickValue=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE);
      double tickSize=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
      if(tickValue<=0 || tickSize<=0) continue;

      double riskPerLot=(MathAbs(open-sl)/tickSize)*tickValue;
      total += riskPerLot*vol;
   }
   return total;
}

bool PortfolioRiskAllows(bool newLong, double newRiskCash)
{
   if(!InpUsePortfolioRiskManager) return true;

   double budget = AccountInfoDouble(ACCOUNT_BALANCE) * (InpPortfolioRiskBudgetPct/100.0);
   if(budget<=0) return true;

   double longRisk = DirectionalOpenRisk(true);
   double shortRisk = DirectionalOpenRisk(false);

   if(newLong) longRisk += newRiskCash;
   else shortRisk += newRiskCash;

   double dirCap = budget * (InpDirectionRiskCapPct/100.0);
   return (longRisk <= dirCap && shortRisk <= dirCap);
}

double StrategySharpe(int strat, RegimeType r, AssetClassType c)
{
   int n = statN[strat][(int)r][(int)c];
   if(n < 5) return -999.0;
   double mean = statPnL[strat][(int)r][(int)c] / n;
   double var = (statPnLSq[strat][(int)r][(int)c] / n) - mean*mean;
   if(var <= 1e-9) return 0.0;
   return mean / MathSqrt(var);
}

void ReassignAgentSmart(int idx, RegimeType r, AssetClassType c)
{
   // #4 smarter evolution
   int best = agents[idx].strategy;
   double bestS = -9999.0;
   for(int s=0;s<10;s++)
   {
      if(!StrategyAllowedInRegime(s,r)) continue;
      double sh = StrategySharpe(s,r,c);
      if(sh > bestS) { bestS=sh; best=s; }
   }
   agents[idx].strategy = best;
}

double KellyScale(int idx)
{
   if(!InpUseKellyScaling) return 1.0;
   if(agents[idx].trades < 12) return 1.0;

   double w = (double)agents[idx].wins / MathMax(agents[idx].trades,1);
   double rr = agents[idx].rrTarget;
   double k = w - ((1.0-w)/MathMax(rr,0.1)); // basic Kelly fraction

   double scale = 1.0 + 2.0*k;
   if(scale < 0.3) scale = 0.3;
   if(scale > 1.8) scale = 1.8;
   return scale;
}

double ComputeLot(const string sym,double riskDistPrice,double riskPct)
{
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double riskCash=balance*(riskPct/100.0);

   double tickValue=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0 || tickValue<=0) return InpMinLot;

   double lossPerLot=(riskDistPrice/tickSize)*tickValue;
   if(lossPerLot<=0) return InpMinLot;

   double raw=riskCash/lossPerLot;
   double clipped=MathMax(InpMinLot,MathMin(InpMaxLot,raw));
   double step=SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
   double minv=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
   double maxv=SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);

   clipped=MathMax(minv,MathMin(maxv,clipped));
   clipped=MathFloor(clipped/step)*step;
   return NormalizeDouble(clipped,2);
}

void TrackPosition(ulong ticket,double vol,double riskPips)
{
   if(ticket==0) return;
   for(int i=0;i<ArraySize(tracks);i++) if(tracks[i].ticket==ticket) return;
   int n=ArraySize(tracks); ArrayResize(tracks,n+1);
   tracks[n].ticket=ticket; tracks[n].initialVolume=vol; tracks[n].riskPips=riskPips;
   tracks[n].tp1=tracks[n].tp2=tracks[n].tp3=tracks[n].tp4=false;
}
int FindTrackIndex(ulong ticket){ for(int i=0;i<ArraySize(tracks);i++) if(tracks[i].ticket==ticket) return i; return -1; }

void PlaceAgentTrade(int idx,int signal,const string sym)
{
   double ask=SymbolInfoDouble(sym,SYMBOL_ASK), bid=SymbolInfoDouble(sym,SYMBOL_BID);
   double entry=(signal>0?ask:bid);

   double sl=0,tp=0,riskPips=0;
   ComputeBotStopsAndTargets(idx,sym,signal,entry,sl,tp,riskPips);
   double riskDist=MathAbs(entry-sl);

   // #5 dynamic sizing from Kelly-inspired scaling
   double riskPct = agents[idx].riskPct * KellyScale(idx);
   double lot=ComputeLot(sym,riskDist,riskPct);

   double tickValue=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
   double riskCash = (tickSize>0 && tickValue>0) ? ((riskDist/tickSize)*tickValue*lot) : 0.0;
   if(!PortfolioRiskAllows(signal>0, riskCash)) return; // #3

   trade.SetExpertMagicNumber((long)agents[idx].magic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   // #6 sniper entry (limit at EMA10 pullback, expire in 2 bars)
   bool ok=false;
   int digits=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   if(InpUseSniperEntry)
   {
      double ema10 = MAValue(sym, PERIOD_M5, MODE_EMA, 10, PRICE_CLOSE, 0);
      datetime exp = TimeCurrent() + (InpSniperExpiryBars * PeriodSeconds(PERIOD_M5));
      if(signal>0)
      {
         double lim = MathMin(entry, ema10);
         ok = trade.BuyLimit(lot, NormalizeDouble(lim,digits), sym, NormalizeDouble(sl,digits), NormalizeDouble(tp,digits), ORDER_TIME_SPECIFIED, exp, "SniperBuy");
      }
      else
      {
         double lim = MathMax(entry, ema10);
         ok = trade.SellLimit(lot, NormalizeDouble(lim,digits), sym, NormalizeDouble(sl,digits), NormalizeDouble(tp,digits), ORDER_TIME_SPECIFIED, exp, "SniperSell");
      }
   }
   else
   {
      ok = (signal>0)
           ? trade.Buy(lot,sym,0.0,NormalizeDouble(sl,digits),NormalizeDouble(tp,digits),"SwarmBuy")
           : trade.Sell(lot,sym,0.0,NormalizeDouble(sl,digits),NormalizeDouble(tp,digits),"SwarmSell");
   }

   if(!ok) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)==agents[idx].magic && PositionGetString(POSITION_SYMBOL)==sym)
      { TrackPosition(ticket, PositionGetDouble(POSITION_VOLUME), riskPips); break; }
   }
}

void ManagePartialTakeProfits()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;

      string sym=PositionGetString(POSITION_SYMBOL);
      long type=PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double current=(type==POSITION_TYPE_BUY)?SymbolInfoDouble(sym,SYMBOL_BID):SymbolInfoDouble(sym,SYMBOL_ASK);
      double vol=PositionGetDouble(POSITION_VOLUME);
      double pip=PipSize(sym);
      double movePips=(type==POSITION_TYPE_BUY)?(current-open)/pip:(open-current)/pip;

      int ti=FindTrackIndex(ticket);
      if(ti<0)
      {
         double sl=PositionGetDouble(POSITION_SL);
         double rp=MathAbs(open-sl)/pip;
         TrackPosition(ticket,vol,rp);
         ti=FindTrackIndex(ticket);
         if(ti<0) continue;
      }
      double riskPips=MathMax(tracks[ti].riskPips,1.0);

      ulong mg=(ulong)PositionGetInteger(POSITION_MAGIC);
      int ai=AgentIndexByMagic(mg);
      int strat=(ai>=0?agents[ai].strategy:0);
      bool trendStrat=(strat==STRAT_SMA_CROSS||strat==STRAT_BREAKOUT20||strat==STRAT_ATR_IMPULSE||strat==STRAT_MOMENTUM5||strat==STRAT_MACD_HIST||strat==STRAT_TREND_SLOPE);

      double l1=trendStrat?1.0:0.8;
      double l2=trendStrat?2.0:1.5;
      double l3=trendStrat?3.0:2.0;
      double l4=trendStrat?5.0:3.0;
      double p1=trendStrat?0.10:0.40;
      double p2=trendStrat?0.15:0.30;
      double p3=trendStrat?0.25:0.20;
      // p4 implicitly rest

      double step=SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
      double minv=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
      double s1=MathMax(minv, MathFloor((tracks[ti].initialVolume*p1)/step)*step);
      double s2=MathMax(minv, MathFloor((tracks[ti].initialVolume*p2)/step)*step);
      double s3=MathMax(minv, MathFloor((tracks[ti].initialVolume*p3)/step)*step);

      if(movePips>=riskPips*l1 && !tracks[ti].tp1 && vol>minv){ trade.PositionClosePartial(ticket, MathMin(s1,vol)); tracks[ti].tp1=true; }
      if(movePips>=riskPips*l2 && !tracks[ti].tp2 && PositionGetDouble(POSITION_VOLUME)>minv){ trade.PositionClosePartial(ticket, MathMin(s2,PositionGetDouble(POSITION_VOLUME))); tracks[ti].tp2=true; }
      if(movePips>=riskPips*l3 && !tracks[ti].tp3 && PositionGetDouble(POSITION_VOLUME)>minv){ trade.PositionClosePartial(ticket, MathMin(s3,PositionGetDouble(POSITION_VOLUME))); tracks[ti].tp3=true; }
      if(movePips>=riskPips*l4 && !tracks[ti].tp4 && PositionGetDouble(POSITION_VOLUME)>minv){ trade.PositionClosePartial(ticket, PositionGetDouble(POSITION_VOLUME)); tracks[ti].tp4=true; }
   }
}

int GetSignal(int strat,const string sym)
{
   switch(strat)
   {
      case STRAT_SMA_CROSS:        { double f=MAValue(sym,PERIOD_M5,MODE_SMA,10,PRICE_CLOSE,0), s=MAValue(sym,PERIOD_M5,MODE_SMA,30,PRICE_CLOSE,0); return (f>s?1:-1);} 
      case STRAT_EMA_PULLBACK:     { double e=MAValue(sym,PERIOD_M5,MODE_EMA,20,PRICE_CLOSE,0), c=iClose(sym,PERIOD_M5,0); if(c<e*0.998) return 1; if(c>e*1.002) return -1; return 0; }
      case STRAT_RSI_REV:          { double r=RSIValue(sym,14,0); if(r<30) return 1; if(r>70) return -1; return 0; }
      case STRAT_BREAKOUT20:       { double hi=-DBL_MAX,lo=DBL_MAX; for(int i=1;i<=20;i++){ hi=MathMax(hi,iHigh(sym,PERIOD_M5,i)); lo=MathMin(lo,iLow(sym,PERIOD_M5,i)); } double c=iClose(sym,PERIOD_M5,0); if(c>hi) return 1; if(c<lo) return -1; return 0; }
      case STRAT_ATR_IMPULSE:      { double atr=ATRValue(sym,14,0), d=iClose(sym,PERIOD_M5,0)-iClose(sym,PERIOD_M5,1); if(d>atr*0.35) return 1; if(d<-atr*0.35) return -1; return 0; }
      case STRAT_MOMENTUM5:        { double p0=iClose(sym,PERIOD_M5,0), p5=iClose(sym,PERIOD_M5,5); if(p5<=0) return 0; double m=(p0-p5)/p5; if(m>0.001) return 1; if(m<-0.001) return -1; return 0; }
      case STRAT_VWAP_PROXY:       { double c=iClose(sym,PERIOD_M5,0), ema=MAValue(sym,PERIOD_M5,MODE_EMA,40,PRICE_TYPICAL,0); if(c>ema) return 1; if(c<ema) return -1; return 0; }
      case STRAT_DONCHIAN_REVERT:  { double hi=-DBL_MAX,lo=DBL_MAX; for(int i=1;i<=20;i++){ hi=MathMax(hi,iHigh(sym,PERIOD_M5,i)); lo=MathMin(lo,iLow(sym,PERIOD_M5,i)); } double c=iClose(sym,PERIOD_M5,0); if(c>hi*0.999) return -1; if(c<lo*1.001) return 1; return 0; }
      case STRAT_MACD_HIST:        { double m=0,s=0; MACDValues(sym,m,s); return (m-s>0?1:-1); }
      case STRAT_TREND_SLOPE:      { double c0=iClose(sym,PERIOD_M5,0), c30=iClose(sym,PERIOD_M5,30); return (c0>c30?1:-1); }
   }
   return 0;
}

void RefreshClosedTrades()
{
   datetime from=TimeCurrent()-86400*InpHistoryLookbackDays, to=TimeCurrent();
   if(!HistorySelect(from,to)) return;

   for(int i=0;i<10;i++){ agents[i].trades=0; agents[i].wins=0; agents[i].realizedPnl=0.0; agents[i].peakPnl=0.0; agents[i].maxDrawdown=0.0; }

   int deals=HistoryDealsTotal();
   for(int i=0;i<deals;i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(ticket==0) continue;
      ulong magic=(ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC);
      long entry=HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_OUT) continue;

      int ai=AgentIndexByMagic(magic);
      if(ai<0) continue;

      string sym=HistoryDealGetString(ticket, DEAL_SYMBOL);
      double profit=HistoryDealGetDouble(ticket,DEAL_PROFIT)+HistoryDealGetDouble(ticket,DEAL_SWAP)+HistoryDealGetDouble(ticket,DEAL_COMMISSION);
      agents[ai].trades++; agents[ai].realizedPnl += profit; if(profit>0) agents[ai].wins++;
      if(agents[ai].realizedPnl > agents[ai].peakPnl) agents[ai].peakPnl = agents[ai].realizedPnl;
      double ddNow = agents[ai].peakPnl - agents[ai].realizedPnl;
      if(ddNow > agents[ai].maxDrawdown) agents[ai].maxDrawdown = ddNow;

      // #4 stats by strategy x regime x asset class (regime approximated at close time from current snapshot)
      RegimeType r = ClassifyRegime(sym);
      AssetClassType c = AssetClassOf(sym);
      int s = agents[ai].strategy;
      statN[s][(int)r][(int)c]++;
      statPnL[s][(int)r][(int)c] += profit;
      statPnLSq[s][(int)r][(int)c] += profit*profit;
   }
}

void ReplaceUnderperformers()
{
   for(int i=0;i<10;i++)
   {
      if(agents[i].trades < InpEvalTrades) continue;
      double bal=AccountInfoDouble(ACCOUNT_BALANCE);
      double pf=(bal + agents[i].realizedPnl)/MathMax(bal,1.0);
      if(pf < InpMinProfitFactor)
      {
         string focus = (ArraySize(universe)>0 ? universe[(i + (int)TimeCurrent()) % ArraySize(universe)] : "EURUSD");
         RegimeType r = ClassifyRegime(focus);
         AssetClassType c = AssetClassOf(focus);

         int oldStrat = agents[i].strategy;
         double wr = (agents[i].trades>0 ? (double)agents[i].wins/agents[i].trades : 0.0);
         ReassignAgentSmart(i, r, c);
         int newStrat = agents[i].strategy;

         LogSwapEvent(agents[i].id, oldStrat, newStrat, agents[i].trades, wr, agents[i].realizedPnl, pf, r, c);

         agents[i].riskPct = 0.20 + (0.10 * ((i + agents[i].strategy) % 4));
         agents[i].rrTarget = 3.0 + ((i + agents[i].strategy) % 3);
         agents[i].trades=0; agents[i].wins=0; agents[i].realizedPnl=0.0; agents[i].peakPnl=0.0; agents[i].maxDrawdown=0.0; agents[i].alive=true;
      }
   }
}

void WriteState()
{
   if(fileHandle==INVALID_HANDLE) return;
   datetime now=TimeCurrent();
   for(int i=0;i<10;i++)
   {
      double wr=(agents[i].trades>0?(double)agents[i].wins/agents[i].trades:0.0);
      // #10 real metrics proxy fields added: expectancy and recovery factor proxies
      double avgPnL=(agents[i].trades>0?agents[i].realizedPnl/agents[i].trades:0.0);
      double recovery=(MathAbs(agents[i].realizedPnl)>0?agents[i].realizedPnl/MathMax(1.0,MathAbs(avgPnL*3.0)):0.0);
      FileWrite(fileHandle,
                TimeToString(now,TIME_DATE|TIME_SECONDS),
                "TARGET_UNIVERSE",
                agents[i].id,
                agents[i].strategy,
                DoubleToString(agents[i].riskPct,2),
                DoubleToString(agents[i].rrTarget,1),
                (agents[i].alive?1:0),
                agents[i].trades,
                agents[i].wins,
                DoubleToString(wr,4),
                DoubleToString(agents[i].realizedPnl,2),
                DoubleToString(avgPnL,2),
                DoubleToString(recovery,2),
                DoubleToString(agents[i].maxDrawdown,2));
   }
   FileFlush(fileHandle);
}

void WriteOpenPositionsSnapshot()
{
   int fh = FileOpen(InpOpenPositionsFile, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(fh==INVALID_HANDLE) return;
   FileWrite(fh,"timestamp","ticket","symbol","agent_id","strategy","side","volume","open_price","current_price","sl","tp","pnl","swap","magic");

   datetime now=TimeCurrent();
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;

      string sym=PositionGetString(POSITION_SYMBOL);
      long type=PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double current=(type==POSITION_TYPE_BUY)?SymbolInfoDouble(sym,SYMBOL_BID):SymbolInfoDouble(sym,SYMBOL_ASK);
      double sl=PositionGetDouble(POSITION_SL), tp=PositionGetDouble(POSITION_TP), pnl=PositionGetDouble(POSITION_PROFIT), swap=PositionGetDouble(POSITION_SWAP), vol=PositionGetDouble(POSITION_VOLUME);
      ulong magic=(ulong)PositionGetInteger(POSITION_MAGIC);
      int ai=AgentIndexByMagic(magic);
      int aid=(ai>=0?agents[ai].id:-1), strat=(ai>=0?agents[ai].strategy:-1);
      string side=(type==POSITION_TYPE_BUY?"BUY":"SELL");

      FileWrite(fh,
                TimeToString(now,TIME_DATE|TIME_SECONDS),
                ticket,
                sym,
                aid,
                strat,
                side,
                DoubleToString(vol,2),
                DoubleToString(open,(int)SymbolInfoInteger(sym,SYMBOL_DIGITS)),
                DoubleToString(current,(int)SymbolInfoInteger(sym,SYMBOL_DIGITS)),
                DoubleToString(sl,(int)SymbolInfoInteger(sym,SYMBOL_DIGITS)),
                DoubleToString(tp,(int)SymbolInfoInteger(sym,SYMBOL_DIGITS)),
                DoubleToString(pnl,2),
                DoubleToString(swap,2),
                magic);
   }
   FileClose(fh);
}

int OnInit()
{
   for(int i=0;i<10;i++)
   {
      agents[i].id=i+1; agents[i].strategy=i; agents[i].alive=true;
      agents[i].trades=0; agents[i].wins=0; agents[i].realizedPnl=0.0;
      agents[i].riskPct=0.20 + (0.10*(i%4));
      agents[i].rrTarget=3.0 + (i%3);
      agents[i].peakPnl=0.0;
      agents[i].maxDrawdown=0.0;
      agents[i].magic=990000+i+1;
   }

   for(int a=0;a<10;a++)
      for(int r=0;r<4;r++)
         for(int c=0;c<4;c++)
         {
            statN[a][r][c]=0;
            statPnL[a][r][c]=0.0;
            statPnLSq[a][r][c]=0.0;
         }

   BuildUniverse();

   if(InpWriteDashboardFile)
   {
      fileHandle=FileOpen(InpDashboardFile,FILE_WRITE|FILE_CSV|FILE_ANSI,',');
      if(fileHandle!=INVALID_HANDLE)
      {
         FileWrite(fileHandle,"timestamp","symbol","agent_id","strategy","risk_pct","rr","alive","trades","wins","win_rate","realized_pnl","avg_pnl","recovery_factor","agent_max_dd");
         FileFlush(fileHandle);
      }
   }
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason){ if(fileHandle!=INVALID_HANDLE) FileClose(fileHandle); }

void OnTick()
{
   ManagePartialTakeProfits();
   RefreshClosedTrades();

   if(InpUseNewsFilter && !MQLInfoInteger(MQL_TESTER) && InNewsBlackout())
   {
      WriteState();
      WriteOpenPositionsSnapshot();
      return;
   }

   for(int s=0;s<ArraySize(universe);s++)
   {
      string sym=universe[s];
      datetime bar=iTime(sym,PERIOD_M5,0);
      if(bar==0 || bar==lastBarTimes[s]) continue;
      lastBarTimes[s]=bar;

      bool relax = (MQLInfoInteger(MQL_TESTER) && InpTesterRelaxFilters);
      if(!relax && !IsSessionAllowed(sym)) continue;

      RegimeType r = ClassifyRegime(sym);

      for(int i=0;i<10;i++)
      {
         if(!agents[i].alive) continue;
         if(PositionsByAgentAndSymbol(agents[i].magic,sym) >= InpMaxPositionsPerAgentPerAsset) continue;

         if(!relax && InpUseRegimeFilter && !StrategyAllowedInRegime(agents[i].strategy, r)) continue;

         int signal=GetSignal(agents[i].strategy,sym);
         if(signal==0) continue;

         if(!relax && !MTFTrendAgrees(sym, signal)) continue;

         PlaceAgentTrade(i,signal,sym);
      }
   }

   ReplaceUnderperformers();
   WriteState();
   WriteOpenPositionsSnapshot();
}


// ========================== Tester Metrics ==========================
double g_testerNetProfit = 0.0;
double g_testerGrossProfit = 0.0;
double g_testerGrossLoss = 0.0;
double g_testerMaxDD = 0.0;
double g_testerRecovery = 0.0;
double g_testerPF = 0.0;
double g_testerSharpeProxy = 0.0;

double ComputeTesterSharpeProxy()
{
   datetime from=TimeCurrent()-86400*365*5, to=TimeCurrent();
   if(!HistorySelect(from,to)) return 0.0;

   double pnl[];
   ArrayResize(pnl,0);
   int deals=HistoryDealsTotal();
   for(int i=0;i<deals;i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(ticket==0) continue;
      long entry=HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_OUT) continue;
      double v=HistoryDealGetDouble(ticket,DEAL_PROFIT)+HistoryDealGetDouble(ticket,DEAL_SWAP)+HistoryDealGetDouble(ticket,DEAL_COMMISSION);
      int n=ArraySize(pnl);
      ArrayResize(pnl,n+1);
      pnl[n]=v;
   }
   int n=ArraySize(pnl);
   if(n<2) return 0.0;

   double mean=0.0;
   for(int i=0;i<n;i++) mean+=pnl[i];
   mean/=n;
   double var=0.0;
   for(int i=0;i<n;i++){ double d=pnl[i]-mean; var+=d*d; }
   var/=n;
   if(var<=1e-9) return 0.0;
   return mean/MathSqrt(var);
}

double OnTester()
{
   double net = TesterStatistics(STAT_PROFIT);
   double grossProfit = TesterStatistics(STAT_GROSS_PROFIT);
   double grossLossAbs = MathAbs(TesterStatistics(STAT_GROSS_LOSS));
   double maxDdAbs = MathAbs(TesterStatistics(STAT_BALANCE_DD));
   double maxDdPct = MathAbs(TesterStatistics(STAT_BALANCE_DDREL_PERCENT));
   double totalTrades = TesterStatistics(STAT_TRADES);

   double pf = (grossLossAbs>0.0 ? grossProfit/grossLossAbs : 0.0);
   double recovery = (maxDdAbs>0.0 ? net/maxDdAbs : 0.0);
   double sharpe = ComputeTesterSharpeProxy();

   g_testerNetProfit = net;
   g_testerGrossProfit = grossProfit;
   g_testerGrossLoss = grossLossAbs;
   g_testerMaxDD = maxDdAbs;
   g_testerRecovery = recovery;
   g_testerPF = pf;
   g_testerSharpeProxy = sharpe;

   // Custom optimization criterion: Sharpe * sqrt(trades) * (1 - maxDD%)
   double drawdownPenalty = 1.0 - (maxDdPct/100.0);
   if(drawdownPenalty < 0.0) drawdownPenalty = 0.0;
   double fitness = sharpe * MathSqrt(MathMax(totalTrades,1.0)) * drawdownPenalty;
   return fitness;
}

void OnTesterPass()
{
   int fh = FileOpen("tester_pass_metrics.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(fh==INVALID_HANDLE) return;

   if(FileSize(fh)==0)
      FileWrite(fh,"timestamp","net_profit","profit_factor","max_dd","recovery","sharpe_proxy");

   FileSeek(fh,0,SEEK_END);
   FileWrite(fh,
             TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
             DoubleToString(g_testerNetProfit,2),
             DoubleToString(g_testerPF,4),
             DoubleToString(g_testerMaxDD,2),
             DoubleToString(g_testerRecovery,4),
             DoubleToString(g_testerSharpeProxy,4));
   FileClose(fh);
}
