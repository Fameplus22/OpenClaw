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
