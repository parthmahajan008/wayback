"""Local embedding model (sentence-transformers on Apple GPU via MPS)."""

from __future__ import annotations

import os
import threading
import time

import numpy as np

MODEL_NAME = os.environ.get("WAYBACK_MODEL", "BAAI/bge-base-en-v1.5")
# bge models expect this instruction on queries (not on passages).
QUERY_PREFIX = "Represent this sentence for searching relevant passages: " if "bge" in MODEL_NAME else ""


class Embedder:
    """One model shared by indexing and queries.

    Indexing encodes in small sub-batches, taking the lock for each one and
    stepping aside while a query is waiting, so searches stay fast mid-index.
    Running two MPS models from two threads at once is not safe.
    """

    SUB_BATCH = 32

    def __init__(self) -> None:
        self._model = None
        self._lock = threading.Lock()
        self._queries_waiting = 0
        self.device = "cpu"

    def _load(self):
        if self._model is None:
            import torch
            from sentence_transformers import SentenceTransformer

            self.device = "mps" if torch.backends.mps.is_available() else "cpu"
            model = SentenceTransformer(MODEL_NAME, device=self.device)
            if self.device == "mps":
                model.half()
            model.max_seq_length = 512
            self._model = model
        return self._model

    def _encode(self, texts: list[str]) -> np.ndarray:
        return self._load().encode(
            texts, batch_size=self.SUB_BATCH, normalize_embeddings=True, convert_to_numpy=True
        ).astype(np.float16)

    def encode(self, texts: list[str]) -> np.ndarray:
        out = []
        for i in range(0, len(texts), self.SUB_BATCH):
            while self._queries_waiting:
                time.sleep(0.01)
            with self._lock:
                out.append(self._encode(texts[i : i + self.SUB_BATCH]))
        return np.concatenate(out) if out else np.zeros((0, 0), dtype=np.float16)

    def encode_query(self, q: str) -> np.ndarray:
        self._queries_waiting += 1
        try:
            with self._lock:
                return self._encode([QUERY_PREFIX + q])[0]
        finally:
            self._queries_waiting -= 1


embedder = Embedder()
