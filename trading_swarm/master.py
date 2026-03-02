from __future__ import annotations

import json
import random
import time
from pathlib import Path
from typing import List

import numpy as np
import pandas as pd

from .agent import BotAgent
from .config import DEFAULT_MASTER, DEFAULT_RISK, MasterConfig
from .strategies import default_strategy_pool


class MarketFeed:
    def __init__(self, seed: int = 42):
        self.rng = np.random.default_rng(seed)

    def get_bars(self, n: int = 200) -> pd.DataFrame:
        drift = 0.0001
        noise = self.rng.normal(0, 0.001, n).cumsum()
        close = 1.10 + drift * np.arange(n) + noise
        high = close + np.abs(self.rng.normal(0, 0.0004, n))
        low = close - np.abs(self.rng.normal(0, 0.0004, n))
        open_ = np.roll(close, 1)
        open_[0] = close[0]
        vol = self.rng.integers(100, 2000, n)
        return pd.DataFrame({"open": open_, "high": high, "low": low, "close": close, "tick_volume": vol})


class MasterBot:
    def __init__(self, cfg: MasterConfig = DEFAULT_MASTER):
        self.cfg = cfg
        self.feed = MarketFeed()
        pool = default_strategy_pool()
        self.agents: List[BotAgent] = [
            BotAgent(id=i + 1, strategy=pool[i % len(pool)], risk=DEFAULT_RISK, balance=cfg.initial_balance)
            for i in range(cfg.agent_count)
        ]
        self.start_total = cfg.initial_balance * cfg.agent_count
        self.state_file = Path(cfg.state_file)

    def _replace_underperformers(self) -> None:
        pool = default_strategy_pool()
        ranked = sorted(self.agents, key=lambda a: a.balance)
        worst = ranked[:2]
        for w in worst:
            if len(w.trades) < self.cfg.evaluation_window_trades:
                continue
            if w.balance < self.cfg.initial_balance * self.cfg.replacement_min_profit_factor:
                w.alive = False
                better = random.choice(pool)
                w.strategy = better
                w.balance = self.cfg.initial_balance
                w.trades = []
                w.alive = True

    def _state(self) -> dict:
        total = sum(a.balance for a in self.agents)
        return {
            "symbol": self.cfg.symbol,
            "target_7d": self.cfg.target_multiple_7d,
            "equity_total": round(total, 2),
            "equity_multiple": round(total / self.start_total, 3),
            "agents": [a.as_dict() for a in self.agents],
            "timestamp": int(time.time()),
        }

    def _persist(self):
        self.state_file.write_text(json.dumps(self._state(), indent=2))

    def run(self, cycles: int = 400):
        for _ in range(cycles):
            bars = self.feed.get_bars(250)
            for a in self.agents:
                a.step(bars)
            self._replace_underperformers()
            self._persist()
            time.sleep(self.cfg.heartbeat_seconds)


if __name__ == "__main__":
    MasterBot().run()
