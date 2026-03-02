from __future__ import annotations

import argparse
import re
from pathlib import Path

import pandas as pd


def parse_html_report(path: Path) -> dict:
    text = path.read_text(errors="ignore")

    def pick(label: str):
        m = re.search(rf"{re.escape(label)}.*?([\-\d\.,]+)", text, re.IGNORECASE | re.DOTALL)
        return m.group(1).replace(",", "") if m else None

    out = {
        "file": path.name,
        "net_profit": pick("Net profit"),
        "profit_factor": pick("Profit factor"),
        "expected_payoff": pick("Expected payoff"),
        "recovery_factor": pick("Recovery factor"),
        "sharpe_ratio": pick("Sharpe ratio"),
        "balance_drawdown_max": pick("Balance drawdown max"),
        "trades": pick("Total trades"),
    }
    return out


def parse_csv_report(path: Path) -> dict:
    df = pd.read_csv(path)
    cols = {c.lower().strip(): c for c in df.columns}

    def c(*names):
        for n in names:
            if n in cols:
                return cols[n]
        return None

    out = {"file": path.name}
    if c("profit", "net profit"):
        out["net_profit"] = float(df[c("profit", "net profit")].sum())
    if c("pnl"):
        pnl = df[c("pnl")].astype(float)
        wins = pnl[pnl > 0].sum()
        losses = -pnl[pnl < 0].sum()
        out["profit_factor"] = (wins / losses) if losses > 0 else None
        out["expected_payoff"] = pnl.mean()
        eq = pnl.cumsum()
        dd = (eq - eq.cummax()).min()
        out["balance_drawdown_max"] = dd
        out["trades"] = len(df)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="in_dir", default="backtest_pack/results")
    ap.add_argument("--out", dest="out_csv", default="backtest_pack/reports/summary.csv")
    args = ap.parse_args()

    in_dir = Path(args.in_dir)
    rows = []
    for p in sorted(in_dir.glob("*")):
        if p.suffix.lower() in {".htm", ".html"}:
            rows.append(parse_html_report(p))
        elif p.suffix.lower() == ".csv":
            rows.append(parse_csv_report(p))

    if not rows:
        print("No reports found in", in_dir)
        return

    df = pd.DataFrame(rows)
    out = Path(args.out_csv)
    out.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(out, index=False)
    print("Wrote", out)
    print(df)


if __name__ == "__main__":
    main()
