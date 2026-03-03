# OpenClaw Automation - Trading Swarm

A master trading bot framework with 10 sub-bots (agents), each running different strategy logic.

## Features
- 10 independent strategy agents
- Master coordinator and rotation/replacement of underperformers
- Conservative risk controls:
  - small lot boundaries (`0.01` to `0.05`)
  - per-trade risk based on `1%` of entry price
  - take-profit trigger at `50%` of configured risk target
- Live monitor dashboard outside MT5 via Streamlit
- Unified prompt hub (`prompts.db`) to view prompts from all channels in one place

## Files
- `trading_swarm/master.py` → main coordinator loop
- `trading_swarm/agent.py` → agent model + risk-aware execution simulation
- `trading_swarm/strategies.py` → 10 strategy signal functions
- `trading_swarm/config.py` → risk and master configuration
- `dashboard.py` → real-time performance + prompt visualizer
- `prompt_hub/logger.py` → SQLite prompt log store/query layer
- `prompt_hub/api.py` → lightweight HTTP API for logging/querying prompts
- `DESIGN_NOTES.md` → architecture notes and challenge Q&A

## Run
```bash
cd /home/yusuff/projects/OpenClawRepo
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Terminal 1 (master bot):
```bash
python -m trading_swarm.master
```

Terminal 2 (dashboard):
```bash
streamlit run dashboard.py
```

Terminal 3 (PromptHub API):
```bash
python -m prompt_hub.api
```

## PromptHub API
### Log prompt
`POST /log`
```json
{
  "ts_utc": "2026-03-02T11:41:00Z",
  "source": "telegram-bot",
  "channel": "telegram",
  "chat_id": "telegram:1196404962",
  "session_id": "optional",
  "author": "Yusuff",
  "prompt_text": "implement everything now"
}
```

### Query prompts
`GET /prompts?limit=300&channel=telegram&chat_id=telegram:1196404962&q=bot`

## Next step (for live MT5)
Wire an execution adapter using `MetaTrader5` package for live order placement and position sync, then test on demo account first.

## Warning
This software is experimental and high risk. Do not deploy live without extensive backtesting and paper trading.

## MT5 Native EA (MetaQuotes / MQL5)
A native MT5 Expert Advisor is included at:
- `mt5/SwarmMasterEA.mq5`

### Install in MT5
1. Open MT5 → `File` → `Open Data Folder`
2. Go to `MQL5/Experts/`
3. Copy `mt5/SwarmMasterEA.mq5` into that folder
4. In MetaEditor, compile the EA
5. Attach to a chart (M5 recommended)

### Notes
- This EA is MT5-native (MQL5), not Python.
- It runs 10 strategy-agents internally using magic numbers.
- It writes `swarm_state.csv` (MQL5 Files directory) for external monitoring bridges.


### New trade management behavior
- Risk distance is now configured in pips (`InpRiskPips`, default 20 pips).
- Big take-profit is `InpRiskPips * InpBigTPMultiplier` (default 20 * 5 = 100 pips).
- Partial profit-taking ladder closes portions at +20, +40, +60, +80 pips (based on risk-pips multiples), while runner targets the big TP.
- EA scans and trades across the broker forex universe (not only the chart symbol).


### Bot autonomy + hard rule
- Stop-loss is **not fixed**. Each bot computes dynamic SL from volatility (ATR-based) + strategy profile.
- Each bot has its own risk profile (`riskPct`) and reward target (`rrTarget`).
- Each bot keeps its own strategy logic and can be recycled to a new profile when underperforming.
- **Hard constraint enforced:** max `2` open positions per bot per asset (`InpMaxPositionsPerAgentPerAsset`).


### Enhanced live dashboard
- `dashboard.py` now includes:
  - **Agent Performance** tab (P&L, win-rate, assets traded, per-agent charts)
  - **Open Positions** tab (live position blotter with symbol, side, volume, P&L, SL/TP)
  - **All Prompts** tab (cross-channel prompt history)
- MT5 EA now exports open positions snapshot to `swarm_open_positions.csv`.


### Universe filtering (noise reduction)
The EA now only scans tradable broker symbols in this target set:
- Top 30 forex pairs
- Gold (XAU/*GOLD*)
- Silver (XAG/*SILVER*)
- NASDAQ, US30, German 30 aliases (e.g., USTEC/US100/NAS*, US30/DJI, GER30/DE30/DAX)
- A small fast-stock list (NVDA, TSLA, AAPL, META, AMZN, MSFT, AMD, NFLX)

This removes invalid/non-carried assets from execution attempts and cleans up logs.


## 100x Redesign (implemented)
The MT5 EA now includes:
1. Multi-timeframe confirmation (M5 signal must align with H1 EMA50 slope)
2. Regime classification (ADX + ATR percentile proxy + Bollinger width) with strategy-regime gating
3. Portfolio-level directional risk cap (blocks over-concentrated long/short exposure)
4. Smarter evolution using strategy × regime × asset-class Sharpe-style learning table
5. Kelly-inspired dynamic sizing (risk scales with rolling edge)
6. Sniper entries via pullback limit orders (EMA10) with short expiry
7. Session + news awareness filters (`news_windows.csv` optional)
8. Adaptive stop-loss and strategy-specific partial-take-profit behavior
9. Walk-forward validation utility: `mt5/walkforward.py` (train 6m / test 2m rolling)
10. Expanded metrics in state output (`avg_pnl`, `recovery_factor`)

### News window file format
Place `news_windows.csv` in MT5 Files directory. Each row:
`YYYY.MM.DD HH:MM,YYYY.MM.DD HH:MM`
(UTC start, UTC end)


## Backtest pack
Added `backtest_pack/` with:
- presets for 7m / 12m / 24m (`.set` files)
- report parser (`backtest_pack/collect_results.py`)
- run ranking (`backtest_pack/scoreboard.py`)
- usage guide (`backtest_pack/README.md`)

This is intended to validate strategy robustness before live deployment.


## MQL5-native backtesting workflow (preferred)
Backtesting/optimization is now native to MT5 Strategy Tester:
- `OnTester()` returns a composite fitness score (Sharpe proxy + PF + recovery + net return)
- `OnTesterPass()` writes pass metrics to `tester_pass_metrics.csv` in MT5 Files

Use MT5 Optimization directly with 7m / 12m / 24m date ranges and compare passes by the custom fitness criterion.

> Note: `backtest_pack/` is optional for external report aggregation only; core validation is now fully MQL5-native.


## TradingView Pine
- Added GC strategy: `tradingview/SMC_GC_H4_M15_Ticks.pine`
- Defaults aligned: H4->M15, structure stop 20-50 ticks band, RR floor/pref/cap 3/5/8, 20% partials at 1R..4R, BE at 50% TP distance.
