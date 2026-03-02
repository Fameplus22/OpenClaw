from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Iterable, Optional

DB_PATH = Path("prompts.db")


def get_conn(db_path: Path = DB_PATH) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


def init_db(db_path: Path = DB_PATH) -> None:
    with get_conn(db_path) as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS prompts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts_utc TEXT NOT NULL,
                source TEXT,
                channel TEXT,
                chat_id TEXT,
                session_id TEXT,
                author TEXT,
                prompt_text TEXT NOT NULL
            )
            """
        )
        conn.execute("CREATE INDEX IF NOT EXISTS idx_prompts_ts ON prompts(ts_utc DESC)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_prompts_channel ON prompts(channel)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_prompts_chat ON prompts(chat_id)")


def log_prompt(
    ts_utc: str,
    prompt_text: str,
    source: str = "unknown",
    channel: Optional[str] = None,
    chat_id: Optional[str] = None,
    session_id: Optional[str] = None,
    author: Optional[str] = None,
    db_path: Path = DB_PATH,
) -> int:
    init_db(db_path)
    with get_conn(db_path) as conn:
        cur = conn.execute(
            """
            INSERT INTO prompts (ts_utc, source, channel, chat_id, session_id, author, prompt_text)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (ts_utc, source, channel, chat_id, session_id, author, prompt_text),
        )
        return int(cur.lastrowid)


def query_prompts(
    limit: int = 500,
    channel: Optional[str] = None,
    chat_id: Optional[str] = None,
    q: Optional[str] = None,
    db_path: Path = DB_PATH,
) -> Iterable[sqlite3.Row]:
    init_db(db_path)
    sql = "SELECT * FROM prompts WHERE 1=1"
    params = []

    if channel:
        sql += " AND channel = ?"
        params.append(channel)
    if chat_id:
        sql += " AND chat_id = ?"
        params.append(chat_id)
    if q:
        sql += " AND prompt_text LIKE ?"
        params.append(f"%{q}%")

    sql += " ORDER BY id DESC LIMIT ?"
    params.append(int(limit))

    with get_conn(db_path) as conn:
        rows = conn.execute(sql, params).fetchall()
    return rows
