from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Dict, List

import numpy as np
import pandas as pd

SignalFn = Callable[[pd.DataFrame], int]


@dataclass
class StrategySpec:
    name: str
    description: str
    signal_fn: SignalFn


def _need(df: pd.DataFrame, n: int) -> bool:
    return len(df) >= n


def sma_cross(df: pd.DataFrame) -> int:
    if not _need(df, 30):
        return 0
    fast = df.close.rolling(10).mean().iloc[-1]
    slow = df.close.rolling(30).mean().iloc[-1]
    return 1 if fast > slow else -1


def ema_pullback(df: pd.DataFrame) -> int:
    if not _need(df, 40):
        return 0
    ema = df.close.ewm(span=20).mean()
    price, e = df.close.iloc[-1], ema.iloc[-1]
    return 1 if price < e * 0.998 else -1 if price > e * 1.002 else 0


def rsi_reversion(df: pd.DataFrame) -> int:
    if not _need(df, 20):
        return 0
    delta = df.close.diff().fillna(0)
    up = delta.clip(lower=0).rolling(14).mean()
    down = (-delta.clip(upper=0)).rolling(14).mean().replace(0, 1e-9)
    rsi = 100 - (100 / (1 + up / down))
    v = rsi.iloc[-1]
    return 1 if v < 30 else -1 if v > 70 else 0


def breakout_20(df: pd.DataFrame) -> int:
    if not _need(df, 22):
        return 0
    hi = df.high.iloc[-21:-1].max()
    lo = df.low.iloc[-21:-1].min()
    p = df.close.iloc[-1]
    return 1 if p > hi else -1 if p < lo else 0


def atr_break(df: pd.DataFrame) -> int:
    if not _need(df, 30):
        return 0
    tr = np.maximum(df.high - df.low, np.maximum((df.high - df.close.shift()).abs(), (df.low - df.close.shift()).abs()))
    atr = tr.rolling(14).mean().iloc[-1]
    move = df.close.iloc[-1] - df.close.iloc[-2]
    return 1 if move > atr * 0.35 else -1 if move < -atr * 0.35 else 0


def momentum_5(df: pd.DataFrame) -> int:
    if not _need(df, 8):
        return 0
    m = df.close.pct_change(5).iloc[-1]
    return 1 if m > 0.001 else -1 if m < -0.001 else 0


def vwap_reclaim(df: pd.DataFrame) -> int:
    if not _need(df, 20):
        return 0
    typical = (df.high + df.low + df.close) / 3
    vwap = (typical * df.tick_volume).cumsum() / (df.tick_volume.cumsum() + 1e-9)
    p = df.close.iloc[-1]
    return 1 if p > vwap.iloc[-1] and df.close.iloc[-2] <= vwap.iloc[-2] else -1 if p < vwap.iloc[-1] and df.close.iloc[-2] >= vwap.iloc[-2] else 0


def donchian_mean_revert(df: pd.DataFrame) -> int:
    if not _need(df, 25):
        return 0
    hi = df.high.rolling(20).max().iloc[-1]
    lo = df.low.rolling(20).min().iloc[-1]
    mid = (hi + lo) / 2
    p = df.close.iloc[-1]
    return -1 if p > hi * 0.999 else 1 if p < lo * 1.001 else (1 if p < mid * 0.998 else -1 if p > mid * 1.002 else 0)


def macd_hist(df: pd.DataFrame) -> int:
    if not _need(df, 40):
        return 0
    ema12 = df.close.ewm(span=12).mean()
    ema26 = df.close.ewm(span=26).mean()
    macd = ema12 - ema26
    signal = macd.ewm(span=9).mean()
    h = macd.iloc[-1] - signal.iloc[-1]
    return 1 if h > 0 else -1


def trend_filter(df: pd.DataFrame) -> int:
    if not _need(df, 60):
        return 0
    slope = np.polyfit(np.arange(30), df.close.iloc[-30:].values, 1)[0]
    return 1 if slope > 0 else -1


def default_strategy_pool() -> List[StrategySpec]:
    return [
        StrategySpec("sma_cross", "10/30 SMA trend follower", sma_cross),
        StrategySpec("ema_pullback", "EMA20 pullback re-entry", ema_pullback),
        StrategySpec("rsi_reversion", "RSI mean reversion", rsi_reversion),
        StrategySpec("breakout_20", "20-bar breakout", breakout_20),
        StrategySpec("atr_break", "ATR impulse continuation", atr_break),
        StrategySpec("momentum_5", "5-bar momentum", momentum_5),
        StrategySpec("vwap_reclaim", "VWAP reclaim break", vwap_reclaim),
        StrategySpec("donchian_mean_revert", "Donchian reversion", donchian_mean_revert),
        StrategySpec("macd_hist", "MACD histogram direction", macd_hist),
        StrategySpec("trend_filter", "Linear trend slope", trend_filter),
    ]


def strategy_lookup() -> Dict[str, StrategySpec]:
    return {s.name: s for s in default_strategy_pool()}
