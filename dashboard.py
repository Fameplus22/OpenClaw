import json
from pathlib import Path

import pandas as pd
import plotly.express as px
import streamlit as st

from prompt_hub.logger import query_prompts, init_db

STATE = Path("state.json")
SWARM_CSV = Path("swarm_state.csv")
OPEN_POS_CSV = Path("swarm_open_positions.csv")

st.set_page_config(page_title="Swarm Command Center", layout="wide")
st.title("🧠 Swarm Command Center")
st.caption("Real-time visibility across agents: performance, traded assets, and live positions")


def load_state():
    if STATE.exists():
        return json.loads(STATE.read_text())
    return None


def load_swarm_csv() -> pd.DataFrame:
    if SWARM_CSV.exists():
        try:
            return pd.read_csv(SWARM_CSV)
        except Exception:
            return pd.DataFrame()
    return pd.DataFrame()


def load_open_positions() -> pd.DataFrame:
    if OPEN_POS_CSV.exists():
        try:
            return pd.read_csv(OPEN_POS_CSV)
        except Exception:
            return pd.DataFrame()
    return pd.DataFrame()


swarm_tab, positions_tab, prompts_tab = st.tabs(["Agent Performance", "Open Positions", "All Prompts"])

with swarm_tab:
    state = load_state()
    swarm_log = load_swarm_csv()

    if state:
        agents = pd.DataFrame(state.get("agents", []))
    elif not swarm_log.empty:
        latest_ts = swarm_log["timestamp"].iloc[-1]
        agents = swarm_log[swarm_log["timestamp"] == latest_ts].copy()
        agents.rename(columns={"agent_id": "id", "realized_pnl": "pnl", "win_rate": "win_rate"}, inplace=True)
        if "balance" not in agents.columns:
            agents["balance"] = 10000 + agents["pnl"].astype(float)
    else:
        agents = pd.DataFrame()

    if agents.empty:
        st.warning("No agent performance data yet. Run EA + bridge to generate state files.")
    else:
        total_pnl = float(agents["pnl"].sum()) if "pnl" in agents else 0.0
        avg_wr = float(agents["win_rate"].astype(float).mean()) if "win_rate" in agents else 0.0
        alive_count = int(agents["alive"].astype(int).sum()) if "alive" in agents else len(agents)
        active_assets = 0
        if not swarm_log.empty and "symbol" in swarm_log.columns:
            active_assets = int(swarm_log["symbol"].nunique())

        m1, m2, m3, m4 = st.columns(4)
        m1.metric("Total Agent P&L", f"{total_pnl:,.2f}")
        m2.metric("Average Win Rate", f"{avg_wr:.2%}")
        m3.metric("Agents Alive", f"{alive_count}/10")
        m4.metric("Assets Touched", str(active_assets))

        c1, c2 = st.columns(2)
        with c1:
            fig = px.bar(agents, x="id", y="pnl", color="strategy", title="P&L by Agent", text_auto=True)
            st.plotly_chart(fig, use_container_width=True)
        with c2:
            fig2 = px.scatter(
                agents,
                x="win_rate",
                y="pnl",
                size="trades" if "trades" in agents.columns else None,
                color="strategy",
                hover_data=["id"],
                title="Risk/Reward Map",
            )
            st.plotly_chart(fig2, use_container_width=True)

        if not swarm_log.empty and "symbol" in swarm_log.columns and "realized_pnl" in swarm_log.columns:
            by_symbol = swarm_log.groupby("symbol", as_index=False)["realized_pnl"].sum().sort_values("realized_pnl", ascending=False)
            st.subheader("Assets Traded (P&L by Symbol)")
            st.plotly_chart(px.bar(by_symbol, x="symbol", y="realized_pnl", title="P&L by Asset"), use_container_width=True)

        st.subheader("Agent Table")
        st.dataframe(agents, use_container_width=True)

with positions_tab:
    pos = load_open_positions()
    if pos.empty:
        st.info("No open positions snapshot yet (`swarm_open_positions.csv`).")
    else:
        pos["pnl"] = pd.to_numeric(pos["pnl"], errors="coerce").fillna(0.0)
        p1, p2, p3 = st.columns(3)
        p1.metric("Open Positions", str(len(pos)))
        p2.metric("Open P&L", f"{pos['pnl'].sum():,.2f}")
        p3.metric("Assets in Play", str(pos["symbol"].nunique() if "symbol" in pos else 0))

        left, right = st.columns(2)
        with left:
            st.plotly_chart(px.bar(pos, x="symbol", y="pnl", color="side", title="Current Open P&L by Asset"), use_container_width=True)
        with right:
            st.plotly_chart(px.bar(pos, x="agent_id", y="pnl", color="symbol", title="Current Open P&L by Agent"), use_container_width=True)

        st.subheader("Live Position Blotter")
        st.dataframe(pos.sort_values("pnl", ascending=False), use_container_width=True)

with prompts_tab:
    init_db()
    st.subheader("Unified Prompt Inbox")
    c1, c2, c3 = st.columns([1, 1, 2])
    channel = c1.text_input("Channel", value="")
    chat_id = c2.text_input("Chat ID", value="")
    q = c3.text_input("Search", value="")
    limit = st.slider("Rows", 50, 2000, 300, 50)

    rows = query_prompts(limit=limit, channel=channel or None, chat_id=chat_id or None, q=q or None)
    df = pd.DataFrame([dict(r) for r in rows])
    if df.empty:
        st.info("No prompts logged yet.")
    else:
        st.dataframe(df, use_container_width=True)
        st.download_button("Download CSV", df.to_csv(index=False).encode("utf-8"), "all_prompts.csv", "text/csv")

st.caption("Tip: refresh the page to reload latest CSV/state snapshots from MT5.")
