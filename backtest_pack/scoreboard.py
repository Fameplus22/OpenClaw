from __future__ import annotations

import argparse
from pathlib import Path

import pandas as pd


def to_num(df: pd.DataFrame, cols: list[str]):
    for c in cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary", default="backtest_pack/reports/summary.csv")
    ap.add_argument("--out", default="backtest_pack/reports/leaderboard.csv")
    args = ap.parse_args()

    df = pd.read_csv(args.summary)
    to_num(df, ["net_profit", "profit_factor", "expected_payoff", "recovery_factor", "sharpe_ratio", "balance_drawdown_max", "trades"])

    df["dd_abs"] = df["balance_drawdown_max"].abs() if "balance_drawdown_max" in df else 0.0
    df["score"] = (
        df.get("sharpe_ratio", 0).fillna(0) * 2.0
        + df.get("profit_factor", 0).fillna(0) * 1.5
        + df.get("recovery_factor", 0).fillna(0) * 1.5
        + (df.get("net_profit", 0).fillna(0) / 1000.0)
        - (df.get("dd_abs", 0).fillna(0) / 1000.0)
    )

    ranked = df.sort_values("score", ascending=False)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    ranked.to_csv(out, index=False)
    print("Wrote", out)
    print(ranked[[c for c in ["file", "score", "net_profit", "profit_factor", "sharpe_ratio", "recovery_factor", "balance_drawdown_max", "trades"] if c in ranked.columns]].head(20))


if __name__ == "__main__":
    main()
