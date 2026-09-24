"""SQLite storage: sessions, chunks, an FTS5 index and hash-keyed embeddings.

Embeddings are keyed by the SHA1 of the chunk text, not by chunk id, so a
re-indexed (appended-to) transcript or a forked session that repeats its
parent's history reuses vectors instead of re-embedding them.
"""

from __future__ import annotations

import os
import sqlite3
from pathlib import Path

DATA_DIR = Path(os.environ.get("WAYBACK_DATA", Path.home() / "Library" / "Application Support" / "Wayback"))
DB_PATH = DATA_DIR / "index.db"

SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS files (
    path TEXT PRIMARY KEY, mtime REAL, size INTEGER, session_key TEXT
);
CREATE TABLE IF NOT EXISTS sessions (
    key TEXT PRIMARY KEY,           -- source:path (ids are not unique across forks/subagents)
    id TEXT, source TEXT, path TEXT, title TEXT, cwd TEXT, kind TEXT,
    started_at TEXT, updated_at TEXT, git_branch TEXT, n_msgs INTEGER
);
CREATE INDEX IF NOT EXISTS sessions_updated ON sessions(updated_at);
CREATE TABLE IF NOT EXISTS chunks (
    id INTEGER PRIMARY KEY, session_key TEXT, seq INTEGER, msg_idx INTEGER,
    role TEXT, ts TEXT, text TEXT, hash TEXT
);
CREATE INDEX IF NOT EXISTS chunks_session ON chunks(session_key, seq);
CREATE INDEX IF NOT EXISTS chunks_hash ON chunks(hash);
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    text, tokenize = "unicode61 tokenchars '_'"
);
CREATE TABLE IF NOT EXISTS embeddings (hash TEXT PRIMARY KEY, vec BLOB);
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
"""


def connect() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=30, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    conn.execute("PRAGMA synchronous=NORMAL")
    return conn


def get_meta(conn: sqlite3.Connection, k: str) -> str | None:
    row = conn.execute("SELECT v FROM meta WHERE k=?", (k,)).fetchone()
    return row[0] if row else None


def set_meta(conn: sqlite3.Connection, k: str, v: str) -> None:
    conn.execute("INSERT OR REPLACE INTO meta(k, v) VALUES (?, ?)", (k, v))


def delete_session(conn: sqlite3.Connection, key: str) -> None:
    conn.execute(
        "DELETE FROM chunks_fts WHERE rowid IN (SELECT id FROM chunks WHERE session_key=?)", (key,)
    )
    conn.execute("DELETE FROM chunks WHERE session_key=?", (key,))
    conn.execute("DELETE FROM sessions WHERE key=?", (key,))
