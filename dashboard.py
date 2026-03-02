import json
from pathlib import Path

import pandas as pd
import plotly.express as px
import streamlit as st

from prompt_hub.logger import query_prompts, init_db

STATE = Path("state.json")

st.set_page_config(page_title="Trading Swarm Monitor", layout="wide")
st.title("Master Bot + 10 Sub-bot Performance")


def load_state():
    if not STATE.exists():
        return None
    return json.loads(STATE.read_text())


swarm_tab, prompts_tab = st.tabs(["Swarm", "All Prompts"])

with swarm_tab:
    data = load_state()
    if not data:
        st.warning("No state.json yet. Start master bot first: python -m trading_swarm.master")
    else:
        c1, c2, c3 = st.columns(3)
        c1.metric("Total Equity", data["equity_total"])
        c2.metric("Equity Multiple", f"{data['equity_multiple']}x")
        c3.metric("7-Day Target", f"{data['target_7d']}x")

        agents = pd.DataFrame(data["agents"])
        st.dataframe(agents, use_container_width=True)

        fig = px.bar(agents, x="id", y="balance", color="strategy", title="Agent Balances")
        st.plotly_chart(fig, use_container_width=True)

        fig2 = px.scatter(agents, x="win_rate", y="pnl", size="trades", color="strategy", hover_data=["id"])
        st.plotly_chart(fig2, use_container_width=True)

        st.caption(f"Last update epoch: {data['timestamp']}")

with prompts_tab:
    init_db()
    st.subheader("Unified Prompt Inbox")
    c1, c2, c3 = st.columns([1, 1, 2])
    channel = c1.text_input("Channel filter (optional)", value="")
    chat_id = c2.text_input("Chat ID filter (optional)", value="")
    q = c3.text_input("Search text (optional)", value="")
    limit = st.slider("Rows", 50, 2000, 300, 50)

    rows = query_prompts(
        limit=limit,
        channel=channel or None,
        chat_id=chat_id or None,
        q=q or None,
    )
    df = pd.DataFrame([dict(r) for r in rows])
    if df.empty:
        st.info("No prompts logged yet.")
    else:
        st.dataframe(df, use_container_width=True)
        st.download_button(
            "Download CSV",
            data=df.to_csv(index=False).encode("utf-8"),
            file_name="all_prompts.csv",
            mime="text/csv",
        )

st.caption("Tip: Use the PromptHub API (/log) from any channel integration to centralize all prompts.")
