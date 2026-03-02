# Backtest Pack

This pack helps you run and evaluate 7m / 12m / 24m MT5 tests quickly.

## Structure
- `presets/7m.set`, `presets/12m.set`, `presets/24m.set`
- `results/` place exported MT5 tester reports here (`.html/.htm` or `.csv`)
- `collect_results.py` parses reports into `reports/summary.csv`
- `scoreboard.py` ranks runs into `reports/leaderboard.csv`

## How to run
1) In MT5 Strategy Tester:
   - EA: `SwarmMasterEA`
   - Load one preset from `presets/*.set`
   - Set date range manually (7m, 12m, 24m)
   - Run and export report to `backtest_pack/results/`

2) Build summary:
```bash
python backtest_pack/collect_results.py --in backtest_pack/results --out backtest_pack/reports/summary.csv
```

3) Build leaderboard:
```bash
python backtest_pack/scoreboard.py --summary backtest_pack/reports/summary.csv --out backtest_pack/reports/leaderboard.csv
```

## Walk-forward
Use `mt5/walkforward.py` for rolling train/test validation after collecting trade-level exports.

## Notes
- `news_windows.csv` can be used by EA for news blackout windows in live/backtest if enabled.
- Keep one report file per run with clear names, e.g. `EURUSD_7m_run1.html`.
