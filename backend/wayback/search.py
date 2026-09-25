# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Parth Mahajan

"""Hybrid retrieval: dense vectors (GPU matmul) + BM25 (FTS5), fused with RRF."""

from __future__ import annotations

import re
import threading
from dataclasses import dataclass
from datetime import datetime, timezone

import numpy as np

from . import store
from .embedder import embedder

RRF_K = 60
_WORD = re.compile(r"[\w][\w.\-/]*", re.U)
_STOP = set("our us my me mine its not no can could should would have has had but if then so there their they a an and are as at be by for from how i in is it of on or that the this to was we what when where which who why with you your did do does".split())


def _epoch(ts: str | None) -> float:
    if not ts:
        return 0.0
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


@dataclass
class Filters:
    source: str | None = None  # claude | codex
    kinds: tuple[str, ...] = ("interactive", "subagent")
    cwd: str | None = None  # prefix match
    since: float | None = None  # epoch seconds


class VectorIndex:
    """All chunk vectors held in one (N, dim) float16 matrix on the GPU."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.ids = np.zeros(0, dtype=np.int64)
        self.matrix = None
        self.source = np.zeros(0, dtype=np.int8)
        self.kind = np.zeros(0, dtype=np.int8)
        self.updated = np.zeros(0, dtype=np.float64)
        self.cwd: np.ndarray = np.zeros(0, dtype=object)

    KINDS = {"interactive": 0, "subagent": 1, "exec": 2}

    def rebuild(self) -> None:
        import torch

        conn = store.connect()
        try:
            rows = conn.execute(
                """SELECT c.id, e.vec, s.source, s.kind, s.updated_at, s.cwd
                   FROM chunks c JOIN embeddings e ON e.hash = c.hash
                   JOIN sessions s ON s.key = c.session_key ORDER BY c.id"""
            ).fetchall()
        finally:
            conn.close()
        if not rows:
            return
        ids = np.fromiter((r[0] for r in rows), dtype=np.int64, count=len(rows))
        mat = np.frombuffer(b"".join(r[1] for r in rows), dtype=np.float16).reshape(len(rows), -1)
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        tensor = torch.from_numpy(mat.copy()).to(device)
        if device == "cpu":
            tensor = tensor.float()
        source = np.array([1 if r[2] == "codex" else 0 for r in rows], dtype=np.int8)
        kind = np.array([self.KINDS.get(r[3], 0) for r in rows], dtype=np.int8)
        updated = np.array([_epoch(r[4]) for r in rows])
        cwd = np.array([r[5] or "" for r in rows], dtype=object)
        with self.lock:
            self.ids, self.matrix, self.source, self.kind, self.updated, self.cwd = (
                ids, tensor, source, kind, updated, cwd,
            )

    def _mask(self, f: Filters) -> np.ndarray:
        m = np.isin(self.kind, [self.KINDS[k] for k in f.kinds if k in self.KINDS])
        if f.source:
            m &= self.source == (1 if f.source == "codex" else 0)
        if f.since:
            m &= self.updated >= f.since
        if f.cwd:
            m &= np.char.startswith(self.cwd.astype(str), f.cwd)
        return m

    def search(self, qvec: np.ndarray, f: Filters, k: int = 200) -> list[tuple[int, float]]:
        import torch

        with self.lock:
            if self.matrix is None or not len(self.ids):
                return []
            q = torch.from_numpy(qvec.astype(np.float16)).to(self.matrix.device).to(self.matrix.dtype)
            scores = (self.matrix @ q).float().cpu().numpy()
            mask = self._mask(f)
            ids = self.ids
        scores = np.where(mask, scores, -np.inf)
        k = min(k, int(mask.sum()))
        if k <= 0:
            return []
        top = np.argpartition(-scores, k - 1)[:k]
        top = top[np.argsort(-scores[top])]
        return [(int(ids[i]), float(scores[i])) for i in top]

    @property
    def size(self) -> int:
        return len(self.ids)


vindex = VectorIndex()


def query_terms(q: str) -> list[str]:
    return [w for w in _WORD.findall(q.lower()) if w not in _STOP and len(w) > 1]


def _fts_query(q: str) -> str:
    terms = query_terms(q)
    return " OR ".join('"' + t.replace('"', "") + '"' for t in terms[:16])


def _filter_sql(f: Filters) -> tuple[str, list]:
    sql = f" AND s.kind IN ({','.join('?' * len(f.kinds))})"
    args: list = list(f.kinds)
    if f.source:
        sql += " AND s.source = ?"
        args.append(f.source)
    if f.cwd:
        sql += " AND s.cwd LIKE ?"
        args.append(f.cwd.replace("%", r"\%") + "%")
    if f.since:
        sql += " AND s.updated_at >= ?"
        args.append(datetime.fromtimestamp(f.since, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"))
    return sql, args


def keyword_search(conn, q: str, f: Filters, k: int = 200) -> list[tuple[int, float]]:
    fq = _fts_query(q)
    if not fq:
        return []
    where, args = _filter_sql(f)
    # Rank in FTS alone first (joining inside the MATCH query is ~20x slower),
    # then apply session filters to the top candidates.
    try:
        top = conn.execute(
            "SELECT rowid, bm25(chunks_fts) AS s FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY s LIMIT 1500",
            [fq],
        ).fetchall()
    except Exception:
        return []
    if not top:
        return []
    score = {r[0]: -r[1] for r in top}
    keep = {
        r[0]
        for r in conn.execute(
            f"""SELECT c.id FROM chunks c JOIN sessions s ON s.key = c.session_key
                WHERE c.id IN ({','.join('?' * len(score))}) {where}""",
            [*score, *args],
        )
    }
    hits = [(cid, sc) for cid, sc in score.items() if cid in keep][:k]
    if len(hits) < k and len(top) == 1500:
        # Narrow filters can exclude most global top hits; fall back to the joined query.
        rows = conn.execute(
            f"""SELECT chunks_fts.rowid, bm25(chunks_fts) AS score FROM chunks_fts
                JOIN chunks c ON c.id = chunks_fts.rowid JOIN sessions s ON s.key = c.session_key
                WHERE chunks_fts MATCH ? {where} ORDER BY score LIMIT ?""",
            [fq, *args, k],
        ).fetchall()
        hits = [(r[0], -r[1]) for r in rows]
    return hits


def _snippet(text: str, terms: list[str], width: int = 420) -> str:
    low = text.lower()
    pos = min((p for p in (low.find(t) for t in terms) if p >= 0), default=0)
    start = max(0, pos - width // 3)
    snip = text[start : start + width]
    return ("…" if start else "") + snip + ("…" if start + width < len(text) else "")


def hybrid_search(
    q: str, f: Filters, limit: int = 40, mode: str = "hybrid", per_session: int = 3
) -> list[dict]:
    conn = store.connect()
    try:
        ranked: dict[int, float] = {}
        vec_hits = kw_hits = []
        if mode in ("hybrid", "semantic") and vindex.size:
            vec_hits = vindex.search(embedder.encode_query(q), f)
        if mode in ("hybrid", "keyword"):
            kw_hits = keyword_search(conn, q, f)
        for weight, hits in ((1.0, vec_hits), (1.0, kw_hits)):
            for rank, (cid, _) in enumerate(hits):
                ranked[cid] = ranked.get(cid, 0.0) + weight / (RRF_K + rank + 1)
        vec_score = dict(vec_hits)
        order = sorted(ranked, key=ranked.get, reverse=True)[: limit * 6]
        if not order:
            return []
        rows = {
            r["id"]: r
            for r in conn.execute(
                f"""SELECT c.id, c.session_key, c.seq, c.msg_idx, c.role, c.ts, c.text, c.hash,
                           s.id AS session_id, s.source, s.title, s.cwd, s.kind, s.path,
                           s.updated_at, s.git_branch
                    FROM chunks c JOIN sessions s ON s.key = c.session_key
                    WHERE c.id IN ({','.join('?' * len(order))})""",
                order,
            )
        }
        terms = query_terms(q)
        seen_hash, per_sess, out = set(), {}, []
        for cid in order:
            r = rows.get(cid)
            if r is None or r["hash"] in seen_hash:
                continue
            if per_sess.get(r["session_key"], 0) >= per_session:
                continue
            seen_hash.add(r["hash"])
            per_sess[r["session_key"]] = per_sess.get(r["session_key"], 0) + 1
            out.append(
                {
                    "chunk_id": cid,
                    "score": round(ranked[cid], 5),
                    "similarity": round(vec_score.get(cid, 0.0), 4),
                    "role": r["role"],
                    "ts": r["ts"],
                    "text": r["text"],
                    "snippet": _snippet(r["text"], terms),
                    "msg_idx": r["msg_idx"],
                    "seq": r["seq"],
                    "session_key": r["session_key"],
                    "session_id": r["session_id"],
                    "source": r["source"],
                    "title": r["title"] or "(untitled)",
                    "cwd": r["cwd"],
                    "kind": r["kind"],
                    "path": r["path"],
                    "updated_at": r["updated_at"],
                    "git_branch": r["git_branch"],
                }
            )
            if len(out) >= limit:
                break
        return out
    finally:
        conn.close()


def neighbors(conn, session_key: str, seq: int, radius: int = 1) -> list[dict]:
    return [
        dict(r)
        for r in conn.execute(
            "SELECT seq, role, text FROM chunks WHERE session_key=? AND seq BETWEEN ? AND ? ORDER BY seq",
            (session_key, seq - radius, seq + radius),
        )
    ]
