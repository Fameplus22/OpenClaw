from pydantic import BaseModel, Field


class RiskConfig(BaseModel):
    max_risk_per_trade: float = Field(default=0.01, description="1% of entry price")
    min_lot: float = 0.01
    max_lot: float = 0.05
    take_profit_fraction: float = Field(default=0.50, description="Take profits once position gain >= 50% of risk target")
    stop_loss_fraction: float = Field(default=1.00, description="Stop loss at 100% of risk target")


class MasterConfig(BaseModel):
    symbol: str = "EURUSD"
    timeframe: str = "M5"
    initial_balance: float = 10_000.0
    target_multiple_7d: float = 10.0
    agent_count: int = 10
    evaluation_window_trades: int = 30
    replacement_min_profit_factor: float = 1.02
    heartbeat_seconds: int = 5
    state_file: str = "state.json"


DEFAULT_RISK = RiskConfig()
DEFAULT_MASTER = MasterConfig()
