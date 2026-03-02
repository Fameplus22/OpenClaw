from __future__ import annotations

import json
import time
from pathlib import Path

import pandas as pd

CSV_PATH = Path("swarm_state.csv")
STATE_PATH = Path("state.json")


def build_state(df: pd.DataFrame) -> dict:
    latest_ts = df["timestamp"].max()
    current = df[df["timestamp"] == latest_ts].copy()
    current["balance"] = 10000 + current["realized_pnl"].astype(float)
    total = float(current["balance"].sum())
    return {
        "symbol": "MT5",
        "target_7d": 10.0,
        "equity_total": round(total, 2),
        "equity_multiple": round(total / (10000 * len(current)), 3) if len(current) else 1.0,
        "agents": [
            {
                "id": int(r.agent_id),
                "strategy": f"strategy_{int(r.strategy)}",
                "alive": bool(int(r.alive)),
                "balance": round(float(r.balance), 2),
                "trades": int(r.trades),
                "pnl": round(float(r.realized_pnl), 2),
                "win_rate": float(r.win_rate),
            }
            for r in current.itertuples(index=False)
        ],
        "timestamp": int(time.time()),
    }


def main():
    print("Watching swarm_state.csv -> state.json")
    while True:
        if CSV_PATH.exists():
            try:
                df = pd.read_csv(CSV_PATH)
                if not df.empty:
                    STATE_PATH.write_text(json.dumps(build_state(df), indent=2))
            except Exception as e:
                print("bridge error:", e)
        time.sleep(2)


if __name__ == "__main__":
    main()
