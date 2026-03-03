#property strict
#include <Trade/Trade.mqh>

CTrade trade;

input string InpSymbols = "EURUSD,GBPUSD,USDJPY,USDCHF,AUDUSD,NZDUSD,USDCAD,XAUUSD,GOLD";
input ENUM_TIMEFRAMES InpHTF = PERIOD_H4;
input ENUM_TIMEFRAMES InpLTF = PERIOD_M15;
input int InpEMA = 50;
input int InpSwingHTF = 5;
input int InpSwingLTF = 3;
input double InpFvgAtrHTF = 0.15;
input double InpFvgAtrLTF = 0.10;
input double InpStopMinPips = 20.0;
input double InpStopMaxPips = 50.0;
input double InpStopFallbackPips = 30.0;
input double InpRRFloor = 3.0;
input double InpRRPreferred = 5.0;
input double InpRRCap = 8.0;
input double InpRiskPct = 0.5;
input double InpBeTrigger = 0.50;
input int InpMaxOpenPerSymbol = 2;
input int InpMaxTotalOpenPositions = 3;
input double InpMinMarginLevelPct = 500.0;
input double InpMaxDailyLossPct = 2.0;
input long InpMagic = 881500;

string syms[];
datetime lastBar[];
double gDayStartBalance=0.0;
int gDay=-1;

bool ContainsIC(string a, string b){ string x=a,y=b; StringToUpper(x); StringToUpper(y); return StringFind(x,y)>=0; }
double PipSize(const string s){ int d=(int)SymbolInfoInteger(s,SYMBOL_DIGITS); double p=SymbolInfoDouble(s,SYMBOL_POINT); return (d==3||d==5)?p*10.0:p; }
bool IsGold(string s){ return ContainsIC(s,"XAU")||ContainsIC(s,"GOLD"); }

double MAVal(string s, ENUM_TIMEFRAMES tf, int period, int shift){ int h=iMA(s,tf,period,0,MODE_EMA,PRICE_CLOSE); if(h==INVALID_HANDLE) return 0; double b[]; ArraySetAsSeries(b,true); if(CopyBuffer(h,0,shift,1,b)<=0){IndicatorRelease(h); return 0;} IndicatorRelease(h); return b[0]; }
double ATRVal(string s, ENUM_TIMEFRAMES tf, int period, int shift){ int h=iATR(s,tf,period); if(h==INVALID_HANDLE) return 0; double b[]; ArraySetAsSeries(b,true); if(CopyBuffer(h,0,shift,1,b)<=0){IndicatorRelease(h); return 0;} IndicatorRelease(h); return b[0]; }

int BiasHTF(string s)
{
   double e0=MAVal(s,InpHTF,InpEMA,0), e3=MAVal(s,InpHTF,InpEMA,3);
   double hi=-DBL_MAX, lo=DBL_MAX;
   for(int i=1;i<=20;i++){ hi=MathMax(hi,iHigh(s,InpHTF,i)); lo=MathMin(lo,iLow(s,InpHTF,i)); }
   double c=iClose(s,InpHTF,0);
   if(e0>e3 && c>hi) return 1;
   if(e0<e3 && c<lo) return -1;
   return 0;
}

bool BullFVG(string s){ double l1=iLow(s,InpLTF,1), h3=iHigh(s,InpLTF,3); double atr=ATRVal(s,InpLTF,14,1); return (l1>h3 && (l1-h3)>=InpFvgAtrLTF*atr); }
bool BearFVG(string s){ double h1=iHigh(s,InpLTF,1), l3=iLow(s,InpLTF,3); double atr=ATRVal(s,InpLTF,14,1); return (l3>h1 && (l3-h1)>=InpFvgAtrLTF*atr); }

int OpenCountSym(string s){ int c=0; for(int i=PositionsTotal()-1;i>=0;i--){ ulong t=PositionGetTicket(i); if(t==0||!PositionSelectByTicket(t)) continue; if(PositionGetString(POSITION_SYMBOL)==s && (long)PositionGetInteger(POSITION_MAGIC)==InpMagic) c++; } return c; }

int OpenCountTotal(){ int c=0; for(int i=PositionsTotal()-1;i>=0;i--){ ulong t=PositionGetTicket(i); if(t==0||!PositionSelectByTicket(t)) continue; if((long)PositionGetInteger(POSITION_MAGIC)==InpMagic) c++; } return c; }
void RefreshDay(){ MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); if(dt.day_of_year!=gDay){ gDay=dt.day_of_year; gDayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);} }
bool CapitalGuard(){
   RefreshDay();
   if(OpenCountTotal()>=InpMaxTotalOpenPositions) return false;
   double ml=AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(ml>0 && ml<InpMinMarginLevelPct) return false;
   if(gDayStartBalance>0){ double dd=(gDayStartBalance-AccountInfoDouble(ACCOUNT_EQUITY))/gDayStartBalance*100.0; if(dd>=InpMaxDailyLossPct) return false; }
   return true;
}

double LotByRisk(string s,double riskDist)
{
   double bal=AccountInfoDouble(ACCOUNT_BALANCE), cash=bal*(InpRiskPct/100.0);
   double tv=SymbolInfoDouble(s,SYMBOL_TRADE_TICK_VALUE), ts=SymbolInfoDouble(s,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0||ts<=0||riskDist<=0) return 0.01;
   double perLot=(riskDist/ts)*tv;
   double lot=cash/perLot;
   double minv=SymbolInfoDouble(s,SYMBOL_VOLUME_MIN), maxv=SymbolInfoDouble(s,SYMBOL_VOLUME_MAX), step=SymbolInfoDouble(s,SYMBOL_VOLUME_STEP);
   lot=MathMax(minv,MathMin(maxv,lot));
   lot=MathFloor(lot/step)*step;
   return NormalizeDouble(lot,2);
}

void TryTrade(string s)
{
   if(!CapitalGuard()) return;
   if(OpenCountSym(s)>=InpMaxOpenPerSymbol) return;
   int bias=BiasHTF(s);
   if(bias==0) return;

   double ema=MAVal(s,InpLTF,InpEMA,0);
   double c=iClose(s,InpLTF,0);

   bool longSig=(bias>0 && BullFVG(s) && c>=ema);
   bool shortSig=(bias<0 && BearFVG(s) && c<=ema);
   if(!longSig && !shortSig) return;

   double ask=SymbolInfoDouble(s,SYMBOL_ASK), bid=SymbolInfoDouble(s,SYMBOL_BID), pip=PipSize(s);
   double entry=longSig?ask:bid;
   double swing=longSig?iLow(s,InpLTF,1):iHigh(s,InpLTF,1);
   double sl=longSig?(swing-2*pip):(swing+2*pip);

   if(!IsGold(s)){
      double minD=InpStopMinPips*pip, maxD=InpStopMaxPips*pip;
      double rd=MathAbs(entry-sl);
      if(rd<minD) sl=longSig?(entry-minD):(entry+minD);
      rd=MathAbs(entry-sl);
      if(rd>maxD) return;
   }

   double riskDist=MathAbs(entry-sl);
   if(riskDist<=0 && !IsGold(s)) riskDist=InpStopFallbackPips*pip;
   if(riskDist<=0) return;

   double rr=MathMax(InpRRFloor,MathMin(InpRRPreferred,InpRRCap));
   double tp=longSig?(entry+riskDist*rr):(entry-riskDist*rr);
   double lot=LotByRisk(s,riskDist);

   trade.SetExpertMagicNumber(InpMagic);
   bool ok=longSig?trade.Buy(lot,s,0.0,sl,tp,"SMC-L"):trade.Sell(lot,s,0.0,sl,tp,"SMC-S");
   if(!ok) Print("Trade failed ",s," ",trade.ResultRetcodeDescription());
}

int OnInit()
{
   string parts[]; int n=StringSplit(InpSymbols,',',parts);
   ArrayResize(syms,0);
   for(int i=0;i<n;i++){
      string w=parts[i]; StringTrimLeft(w); StringTrimRight(w);
      if(w=="") continue;
      if(SymbolSelect(w,true)) { int m=ArraySize(syms); ArrayResize(syms,m+1); syms[m]=w; }
   }
   ArrayResize(lastBar,ArraySize(syms));
   for(int i=0;i<ArraySize(lastBar);i++) lastBar[i]=0;
   RefreshDay();
   return INIT_SUCCEEDED;
}

void OnTick()
{
   for(int i=0;i<ArraySize(syms);i++){
      string s=syms[i];
      datetime b=iTime(s,InpLTF,0);
      if(b==0||b==lastBar[i]) continue;
      lastBar[i]=b;
      TryTrade(s);
   }
}
