# Trading Swarm Design Notes

## What was built
- A **master bot** that coordinates 10 strategy agents.
- Each agent has a different strategy and independent PnL.
- Underperforming agents are automatically replaced after evaluation windows.
- Risk controls are centralized (small lot sizing, capped risk, TP/SL logic).
- A real-time **Streamlit dashboard** reads `state.json` so you can monitor without opening MT5.

## Hard questions + answers

1. **Can a system target 10x in 7 days with low risk and 1% price-risk constraints?**
   - Realistically: **very unlikely** in live markets while staying safe. The target is kept as a metric, but risk controls are prioritized over aggressive growth.

2. **How do we avoid overfitting if we keep replacing weak bots?**
   - Replacement uses a strategy pool and fixed windows, not instant reaction to short noise. You should still validate on out-of-sample data before live deployment.

3. **What stops lot sizes from creeping too high?**
   - Hard min/max lot boundaries + per-trade risk fraction.

4. **Why take profit at 50% while risk is 1% of entry price?**
   - This creates conservative exits and reduces exposure duration. It can lower reward/risk, so win-rate pressure is higher.

5. **Can this directly place MT5 trades now?**
   - The current version is framework-first and simulation-friendly. MT5 execution adapter is the next layer to wire.

## Important
This is not financial advice. Test with demo/paper trading first.
