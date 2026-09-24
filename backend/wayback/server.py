# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Parth Mahajan

"""Local HTTP API used by the macOS app (127.0.0.1 only)."""

from __future__ import annotations

import json
import os
import threading
import time
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from . import parsers, rag, store
from .embedder import MODEL_NAME, embedder
from .indexer import Indexer
from .search import Filters, hybrid_search, vindex

indexer = Indexer(on_vectors_changed=vindex.rebuild)


@asynccontextmanager
async def lifespan(_app):
    def boot():
        embedder.encode_query("warm up")  # load the model before the first search
        vindex.rebuild()
        indexer.loop(interval=float(os.environ.get("WAYBACK_INTERVAL", 120)))

    threading.Thread(target=boot, daemon=True).start()
    yield


app = FastAPI(title="Wayback", lifespan=lifespan)


def _filters(source: str | None, include_exec: bool, include_subagents: bool, cwd: str | None, days: int | None) -> Filters:
    kinds = ["interactive"]
    if include_subagents:
        kinds.append("subagent")
    if include_exec:
        kinds.append("exec")
    return Filters(
        source=source if source in ("claude", "codex") else None,
        kinds=tuple(kinds),
        cwd=cwd or None,
        since=time.time() - days * 86400 if days else None,
    )


@app.get("/health")
def health():
    return {"ok": True}


@app.get("/status")
def status():
    conn = store.connect()
    try:
        counts = conn.execute(
            """SELECT (SELECT COUNT(*) FROM sessions) AS sessions,
                      (SELECT COUNT(*) FROM sessions WHERE source='claude') AS claude,
                      (SELECT COUNT(*) FROM sessions WHERE source='codex') AS codex,
                      (SELECT COUNT(*) FROM chunks) AS chunks,
                      (SELECT COUNT(*) FROM embeddings) AS embeddings"""
        ).fetchone()
    finally:
        conn.close()
    return {**indexer.state, **dict(counts), "vectors_loaded": vindex.size, "model": MODEL_NAME, "device": embedder.device}


@app.post("/reindex")
def reindex():
    indexer.wake.set()
    return {"ok": True}


@app.get("/projects")
def projects():
    conn = store.connect()
    try:
        rows = conn.execute(
            "SELECT cwd, COUNT(*) AS n, MAX(updated_at) AS last FROM sessions WHERE cwd != '' GROUP BY cwd ORDER BY last DESC"
        ).fetchall()
    finally:
        conn.close()
    return [dict(r) for r in rows]


@app.get("/search")
def search(
    q: str,
    mode: str = "hybrid",
    source: str | None = None,
    include_exec: bool = False,
    include_subagents: bool = True,
    cwd: str | None = None,
    days: int | None = None,
    limit: int = 40,
):
    if not q.strip():
        return {"results": [], "took_ms": 0}
    t = time.time()
    f = _filters(source, include_exec, include_subagents, cwd, days)
    results = hybrid_search(q, f, limit=limit, mode=mode)
    return {"results": results, "took_ms": int((time.time() - t) * 1000)}


@app.get("/session")
def session(key: str):
    src, _, path = key.partition(":")
    if not os.path.exists(path):
        raise HTTPException(404, "transcript not found")
    sess = parsers.parse_claude(path) if src == "claude" else parsers.parse_codex(path, parsers.load_codex_titles())
    return {
        "key": key, "id": sess.id, "source": sess.source, "title": sess.title, "cwd": sess.cwd,
        "kind": sess.kind, "path": path, "started_at": sess.started_at, "updated_at": sess.updated_at,
        "git_branch": sess.git_branch,
        "messages": [{"role": m.role, "text": m.text, "ts": m.ts} for m in sess.messages],
    }


@app.get("/providers")
def providers():
    return rag.providers()


class AskBody(BaseModel):
    question: str
    provider: str = "claude"
    model: str = "haiku"
    source: str | None = None
    include_exec: bool = False
    include_subagents: bool = True
    cwd: str | None = None
    days: int | None = None
    k: int = 10


@app.post("/ask")
def ask(body: AskBody):
    f = _filters(body.source, body.include_exec, body.include_subagents, body.cwd, body.days)

    def gen():
        hits, prompt = rag.build_context(body.question, f, k=body.k)
        yield "data: " + json.dumps({"type": "sources", "sources": hits}) + "\n\n"
        if not hits:
            yield "data: " + json.dumps({"type": "delta", "text": "No matching sessions found."}) + "\n\n"
        else:
            try:
                for piece in rag.answer(prompt, body.provider, body.model):
                    yield "data: " + json.dumps({"type": "delta", "text": piece}) + "\n\n"
            except Exception as e:
                yield "data: " + json.dumps({"type": "delta", "text": f"\n\n**Error:** {e}"}) + "\n\n"
        yield "data: " + json.dumps({"type": "done"}) + "\n\n"

    return StreamingResponse(gen(), media_type="text/event-stream")


def main() -> None:
    uvicorn.run(app, host="127.0.0.1", port=int(os.environ.get("WAYBACK_PORT", 8765)), log_level="warning")


if __name__ == "__main__":
    main()
