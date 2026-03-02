from __future__ import annotations

import math
from dataclasses import dataclass

import pandas as pd


@dataclass
class Metrics:
    sharpe: float
    max_drawdown: float
    profit_factor: float
    recovery_factor: float
    expectancy: float


def compute_metrics(pnl: pd.Series) -> Metrics:
    pnl = pnl.fillna(0.0)
    eq = pnl.cumsum()
    dd = eq - eq.cummax()
    max_dd = float(dd.min()) if len(dd) else 0.0

    wins = pnl[pnl > 0].sum()
    losses = -pnl[pnl < 0].sum()
    pf = float(wins / losses) if losses > 0 else math.inf

    mu = float(pnl.mean()) if len(pnl) else 0.0
    sd = float(pnl.std(ddof=0)) if len(pnl) else 0.0
    sharpe = mu / sd if sd > 1e-9 else 0.0

    net = float(pnl.sum())
    rec = net / abs(max_dd) if abs(max_dd) > 1e-9 else 0.0

    return Metrics(sharpe=sharpe, max_drawdown=max_dd, profit_factor=pf, recovery_factor=rec, expectancy=mu)


def walk_forward(trades: pd.DataFrame, train_months: int = 6, test_months: int = 2) -> pd.DataFrame:
    trades = trades.copy()
    trades["time"] = pd.to_datetime(trades["time"], utc=True)
    trades = trades.sort_values("time")

    out = []
    start = trades["time"].min().to_period("M").to_timestamp()
    end = trades["time"].max().to_period("M").to_timestamp()

    cursor = start
    while cursor < end:
        train_end = cursor + pd.DateOffset(months=train_months)
        test_end = train_end + pd.DateOffset(months=test_months)

        train = trades[(trades.time >= cursor) & (trades.time < train_end)]
        test = trades[(trades.time >= train_end) & (trades.time < test_end)]
        if len(train) < 30 or len(test) < 10:
            cursor = cursor + pd.DateOffset(months=test_months)
            continue

        # choose best strategy on train by Sharpe, validate on test
        rows = []
        for s, g in train.groupby("strategy"):
            m = compute_metrics(g["pnl"])
            rows.append((s, m.sharpe))
        best = max(rows, key=lambda x: x[1])[0]

        test_best = test[test.strategy == best]
        m2 = compute_metrics(test_best["pnl"]) if len(test_best) else Metrics(0, 0, 0, 0, 0)

        out.append(
            {
                "train_start": cursor,
                "train_end": train_end,
                "test_end": test_end,
                "selected_strategy": best,
                "test_sharpe": m2.sharpe,
                "test_pf": m2.profit_factor,
                "test_max_dd": m2.max_drawdown,
                "test_recovery": m2.recovery_factor,
            }
        )

        cursor = cursor + pd.DateOffset(months=test_months)

    return pd.DataFrame(out)


if __name__ == "__main__":
    print("walkforward module ready. Feed a trades DataFrame with columns: time,strategy,pnl")
