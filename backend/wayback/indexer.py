"""Incremental indexer: scan transcripts, chunk, store, embed.

Pass 1 parses every new/changed transcript and writes chunks + FTS rows, so
keyword search works right away. Pass 2 embeds chunk texts that have no vector
yet, newest sessions first, so recent work becomes semantically searchable
before a long backlog finishes.
"""

from __future__ import annotations

import hashlib
import threading
import time
import traceback

from . import parsers, store
from .embedder import embedder
from .parsers import Message

CHUNK_CHARS = 1200
OVERLAP = 150
EMBED_BATCH = 256
# Bump when parsing/chunking changes: every transcript is re-parsed, while
# vectors are reused by content hash so only changed chunks get re-embedded.
PARSER_VERSION = "2"


def _split(text: str) -> list[str]:
    if len(text) <= CHUNK_CHARS:
        return [text]
    out, start = [], 0
    while start < len(text):
        end = min(len(text), start + CHUNK_CHARS)
        if end < len(text):
            # Prefer breaking on a paragraph, then a line, then a sentence.
            for sep in ("\n\n", "\n", ". ", " "):
                cut = text.rfind(sep, start + CHUNK_CHARS // 2, end)
                if cut != -1:
                    end = cut + len(sep)
                    break
        out.append(text[start:end].strip())
        if end >= len(text):
            break
        start = max(end - OVERLAP, start + 1)
    return [c for c in out if c]


def chunk_messages(msgs: list[Message]) -> list[tuple[int, str, str | None, str]]:
    """-> [(msg_idx, role, ts, text)]; consecutive tool calls are grouped."""
    out: list[tuple[int, str, str | None, str]] = []
    tool_buf: list[str] = []
    tool_start = 0
    tool_ts = None

    def flush():
        nonlocal tool_buf
        if tool_buf:
            out.append((tool_start, "tool", tool_ts, "\n".join(tool_buf)))
            tool_buf = []

    for i, m in enumerate(msgs):
        if m.role == "tool":
            if not tool_buf:
                tool_start, tool_ts = i, m.ts
            tool_buf.append(m.text)
            if sum(len(t) for t in tool_buf) > CHUNK_CHARS:
                flush()
            continue
        flush()
        for piece in _split(m.text):
            out.append((i, m.role, m.ts, piece))
    flush()
    return out


def _hash(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8", "ignore")).hexdigest()


class Indexer:
    def __init__(self, on_vectors_changed=None) -> None:
        self.on_vectors_changed = on_vectors_changed or (lambda: None)
        self.lock = threading.Lock()
        self.wake = threading.Event()
        self.state = {
            "phase": "idle",
            "files_total": 0,
            "files_done": 0,
            "to_embed": 0,
            "embedded": 0,
            "last_run": None,
            "error": None,
        }

    # ------------------------------------------------------------ scanning
    def _scan(self, conn) -> list[tuple[str, str]]:
        files = [("claude", p) for p in parsers.discover_claude()] + [
            ("codex", p) for p in parsers.discover_codex()
        ]
        known = {r["path"]: (r["mtime"], r["size"]) for r in conn.execute("SELECT path, mtime, size FROM files")}
        present = set()
        changed = []
        for src, path in files:
            present.add(path)
            try:
                sig = parsers.file_sig(path)
            except OSError:
                continue
            if known.get(path) != sig:
                changed.append((src, path))
        # Drop sessions whose transcript files were deleted.
        for path in set(known) - present:
            row = conn.execute("SELECT session_key FROM files WHERE path=?", (path,)).fetchone()
            if row:
                store.delete_session(conn, row[0])
            conn.execute("DELETE FROM files WHERE path=?", (path,))
        conn.commit()
        # Newest files first so recent sessions land in the index first.
        changed.sort(key=lambda sp: parsers.file_sig(sp[1])[0], reverse=True)
        return changed

    def _index_file(self, conn, src: str, path: str, titles: dict) -> None:
        sig = parsers.file_sig(path)
        sess = parsers.parse_claude(path) if src == "claude" else parsers.parse_codex(path, titles)
        key = f"{src}:{path}"
        store.delete_session(conn, key)
        if sess and sess.messages:
            conn.execute(
                "INSERT INTO sessions VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (key, sess.id, src, path, sess.title, sess.cwd, sess.kind,
                 sess.started_at, sess.updated_at, sess.git_branch, len(sess.messages)),
            )
            rows = chunk_messages(sess.messages)
            for seq, (msg_idx, role, ts, text) in enumerate(rows):
                cur = conn.execute(
                    "INSERT INTO chunks(session_key, seq, msg_idx, role, ts, text, hash) VALUES (?,?,?,?,?,?,?)",
                    (key, seq, msg_idx, role, ts, text, _hash(text)),
                )
                conn.execute("INSERT INTO chunks_fts(rowid, text) VALUES (?, ?)", (cur.lastrowid, text))
        conn.execute(
            "INSERT OR REPLACE INTO files(path, mtime, size, session_key) VALUES (?,?,?,?)",
            (path, sig[0], sig[1], key),
        )

    # ------------------------------------------------------------ embedding
    def _embed_pending(self, conn) -> None:
        pending = conn.execute(
            """SELECT c.hash, MIN(c.role) AS role, MIN(c.text) AS text, MAX(s.updated_at) AS u
               FROM chunks c JOIN sessions s ON s.key = c.session_key
               LEFT JOIN embeddings e ON e.hash = c.hash
               WHERE e.hash IS NULL GROUP BY c.hash ORDER BY u DESC"""
        ).fetchall()
        self.state.update(phase="embedding", to_embed=len(pending), embedded=0)
        last_refresh = time.time()
        for i in range(0, len(pending), EMBED_BATCH):
            batch = pending[i : i + EMBED_BATCH]
            vecs = embedder.encode([f"{r['role']}: {r['text']}" for r in batch])
            conn.executemany(
                "INSERT OR REPLACE INTO embeddings(hash, vec) VALUES (?, ?)",
                [(r["hash"], v.tobytes()) for r, v in zip(batch, vecs)],
            )
            conn.commit()
            self.state["embedded"] = i + len(batch)
            if time.time() - last_refresh > 45:
                self.on_vectors_changed()
                last_refresh = time.time()
        if pending:
            self.on_vectors_changed()

    # ------------------------------------------------------------ driver
    def run_once(self) -> None:
        with self.lock:
            conn = store.connect()
            try:
                self.state.update(phase="scanning", error=None)
                if store.get_meta(conn, "parser_version") != PARSER_VERSION:
                    conn.execute("DELETE FROM files")
                    store.set_meta(conn, "parser_version", PARSER_VERSION)
                    conn.commit()
                changed = self._scan(conn)
                self.state.update(phase="parsing", files_total=len(changed), files_done=0)
                titles = parsers.load_codex_titles()
                for n, (src, path) in enumerate(changed, 1):
                    try:
                        self._index_file(conn, src, path, titles)
                    except Exception:  # one bad transcript must not stop the run
                        traceback.print_exc()
                    self.state["files_done"] = n
                    if n % 50 == 0:
                        conn.commit()
                conn.commit()
                if changed:
                    self.on_vectors_changed()
                self._embed_pending(conn)
                # Remove vectors no chunk references any more.
                conn.execute("DELETE FROM embeddings WHERE hash NOT IN (SELECT hash FROM chunks)")
                conn.commit()
                self.state["last_run"] = time.time()
            except Exception as e:
                traceback.print_exc()
                self.state["error"] = str(e)
            finally:
                self.state["phase"] = "idle"
                conn.close()

    def loop(self, interval: float = 120) -> None:
        while True:
            self.run_once()
            self.wake.wait(interval)
            self.wake.clear()
