from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional

import pandas as pd

from .config import RiskConfig
from .strategies import StrategySpec


@dataclass
class Trade:
    side: int
    entry: float
    exit: Optional[float] = None
    pnl: float = 0.0


@dataclass
class BotAgent:
    id: int
    strategy: StrategySpec
    risk: RiskConfig
    balance: float
    trades: List[Trade] = field(default_factory=list)
    alive: bool = True

    def score(self) -> float:
        if not self.trades:
            return 1.0
        wins = sum(1 for t in self.trades if t.pnl > 0)
        return (self.balance, wins / max(len(self.trades), 1))

    def _lot_size(self, price: float) -> float:
        theoretical = max(self.risk.min_lot, min(self.risk.max_lot, (self.balance * self.risk.max_risk_per_trade) / max(price, 1e-9)))
        return round(theoretical, 2)

    def step(self, market: pd.DataFrame) -> None:
        if not self.alive:
            return
        signal = self.strategy.signal_fn(market)
        if signal == 0:
            return
        entry = float(market.close.iloc[-1])
        lot = self._lot_size(entry)
        risk_unit = entry * self.risk.max_risk_per_trade
        tp = risk_unit * self.risk.take_profit_fraction
        sl = risk_unit * self.risk.stop_loss_fraction

        next_px = float(market.close.iloc[-1] + (market.close.iloc[-1] - market.close.iloc[-2]))
        move = (next_px - entry) * signal
        pnl = lot * (tp if move > 0 else -sl)

        tr = Trade(side=signal, entry=entry, exit=next_px, pnl=pnl)
        self.trades.append(tr)
        self.balance += pnl

    def as_dict(self) -> dict:
        return {
            "id": self.id,
            "strategy": self.strategy.name,
            "alive": self.alive,
            "balance": round(self.balance, 2),
            "trades": len(self.trades),
            "pnl": round(self.balance - 10_000, 2),
            "win_rate": round(sum(1 for t in self.trades if t.pnl > 0) / max(len(self.trades), 1), 3),
        }
