# Third-party notices

## Bundled in the app

| Component | License | Notes |
|---|---|---|
| [uv](https://github.com/astral-sh/uv) | MIT or Apache-2.0 | Binary shipped in `Wayback.app/Contents/MacOS/uv`. License texts are in [`third_party/uv/`](third_party/uv). |

## Downloaded on first launch (not redistributed)

`uv` installs these into `~/Library/Application Support/Wayback/venv` from PyPI and Hugging Face,
under their own licenses:

| Component | License |
|---|---|
| [PyTorch](https://github.com/pytorch/pytorch) | BSD-3-Clause |
| [sentence-transformers](https://github.com/UKPLab/sentence-transformers) | Apache-2.0 |
| [transformers](https://github.com/huggingface/transformers) | Apache-2.0 |
| [FastAPI](https://github.com/fastapi/fastapi) | MIT |
| [Uvicorn](https://github.com/encode/uvicorn) | BSD-3-Clause |
| [NumPy](https://github.com/numpy/numpy) | BSD-3-Clause |
| [BAAI/bge-base-en-v1.5](https://huggingface.co/BAAI/bge-base-en-v1.5) (embedding model) | MIT |

The full dependency set is pinned in [`backend/uv.lock`](backend/uv.lock).

Claude Code and Codex are products of Anthropic and OpenAI respectively. Wayback is an
independent project, not affiliated with or endorsed by either.
