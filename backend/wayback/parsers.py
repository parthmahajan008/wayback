# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Parth Mahajan

"""Parse Claude Code and Codex session transcripts into a common shape.

Both tools write JSONL transcripts; this module turns one file into a
`Session` (metadata) plus a list of `Message`s holding only human-meaningful
text: user prompts, assistant replies and a short line per tool call.
Injected context (AGENTS.md, environment blocks, system reminders, compaction
prompts, ...) is stripped so it does not drown out real conversation.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path

HOME = Path.home()
CLAUDE_ROOT = HOME / ".claude" / "projects"
CODEX_ROOTS = [HOME / ".codex" / "sessions", HOME / ".codex" / "archived_sessions"]
CODEX_INDEX = HOME / ".codex" / "session_index.jsonl"

# Hard cap per message so giant pasted logs / generated prompts don't dominate.
MAX_MSG_CHARS = 8000
MAX_TOOL_CHARS = 300

_INJECTED_TAGS = (
    "environment_context|user_instructions|INSTRUCTIONS|in-app-browser-context|"
    "ide_opened_file|ide_selection|recommended_plugins|codex_internal_context|"
    "subagent_notification|system-reminder|task-notification|local-command-stdout|"
    "local-command-stderr|local-command-caveat|bash-stdout|bash-stderr|bash-input|"
    "command-message|turn_aborted|user_shell_command|skill"
)
_TAG_BLOCK = re.compile(rf"<({_INJECTED_TAGS})\b[^>]*>.*?</\1>", re.S)
_COMMAND = re.compile(
    r"<command-name>(.*?)</command-name>.*?(?:<command-args>(.*?)</command-args>)?", re.S
)
_SKIP_PREFIXES = (
    "# AGENTS.md instructions",
    "Your task is to create a detailed summary",
    "Caveat: The messages below were generated",
    "[Request interrupted",
)


@dataclass
class Message:
    role: str  # user | assistant | tool
    text: str
    ts: str | None = None


@dataclass
class Session:
    id: str
    source: str  # claude | codex
    path: str
    title: str = ""
    cwd: str = ""
    kind: str = "interactive"  # interactive | subagent | exec
    started_at: str | None = None
    updated_at: str | None = None
    git_branch: str = ""
    messages: list[Message] = field(default_factory=list)


def clean_user_text(text: str) -> str:
    """Strip injected context blocks; return '' if nothing human-written remains."""
    if not text or text.startswith(_SKIP_PREFIXES):
        return ""
    m = _COMMAND.search(text)
    if m and text.lstrip().startswith("<command-"):
        args = (m.group(2) or "").strip()
        return f"{m.group(1).strip()} {args}".strip()
    text = _TAG_BLOCK.sub("", text).strip()
    return text


def _cap(text: str, n: int = MAX_MSG_CHARS) -> str:
    return text if len(text) <= n else text[:n] + " …[truncated]"


def _tool_line(name: str, args) -> str:
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except (ValueError, TypeError):
            pass
    if isinstance(args, dict):
        for key in ("command", "cmd", "query", "pattern", "file_path", "url", "prompt", "description"):
            if key in args and args[key]:
                val = args[key]
                if isinstance(val, list):
                    val = " ".join(map(str, val))
                return f"[{name}] {str(val)[:MAX_TOOL_CHARS]}"
        args = json.dumps(args, ensure_ascii=False)
    return f"[{name}] {str(args)[:MAX_TOOL_CHARS]}"


def _iter_json(path: str):
    with open(path, "r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            try:
                yield json.loads(line)
            except ValueError:
                continue


# ---------------------------------------------------------------- Claude Code


def discover_claude() -> list[str]:
    if not CLAUDE_ROOT.exists():
        return []
    return [str(p) for p in CLAUDE_ROOT.rglob("*.jsonl")]


def parse_claude(path: str) -> Session | None:
    p = Path(path)
    is_sub = p.parent.name == "subagents"
    sid = p.stem
    s = Session(id=sid, source="claude", path=path, kind="subagent" if is_sub else "interactive")
    if is_sub:
        meta = p.with_suffix("").with_suffix(".meta.json")
        if meta.exists():
            try:
                s.title = json.loads(meta.read_text()).get("description", "")
            except ValueError:
                pass
    first_prompt = ""
    for d in _iter_json(path):
        t = d.get("type")
        if t == "ai-title" or t == "custom-title":
            s.title = d.get("aiTitle") or d.get("customTitle") or s.title
            continue
        if t == "summary" and d.get("summary") and not s.title:
            s.title = d["summary"]
            continue
        if t not in ("user", "assistant") or d.get("isMeta"):
            continue
        ts = d.get("timestamp")
        s.started_at = s.started_at or ts
        s.updated_at = ts or s.updated_at
        s.cwd = s.cwd or d.get("cwd", "")
        s.git_branch = s.git_branch or d.get("gitBranch", "")
        if not is_sub and d.get("sessionId"):
            s.id = d["sessionId"]
        content = (d.get("message") or {}).get("content")
        if t == "user":
            if isinstance(content, str):
                text = clean_user_text(content)
            elif isinstance(content, list):
                text = clean_user_text(
                    "\n".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text")
                )
            else:
                text = ""
            if text:
                first_prompt = first_prompt or text
                s.messages.append(Message("user", _cap(text), ts))
        else:
            if not isinstance(content, list):
                continue
            for c in content:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "text" and c.get("text", "").strip():
                    s.messages.append(Message("assistant", _cap(c["text"].strip()), ts))
                elif c.get("type") == "tool_use":
                    s.messages.append(Message("tool", _tool_line(c.get("name", "tool"), c.get("input")), ts))
    if not s.title:
        s.title = " ".join(first_prompt.split())[:90]
    return s


# ---------------------------------------------------------------------- Codex


def discover_codex() -> list[str]:
    out = []
    for root in CODEX_ROOTS:
        if root.exists():
            out.extend(str(p) for p in root.rglob("*.jsonl"))
    return out


def load_codex_titles() -> dict[str, str]:
    titles: dict[str, str] = {}
    if CODEX_INDEX.exists():
        for d in _iter_json(str(CODEX_INDEX)):
            if d.get("id") and d.get("thread_name"):
                titles[d["id"]] = d["thread_name"]
    return titles


def parse_codex(path: str, titles: dict[str, str] | None = None) -> Session | None:
    s = Session(id=Path(path).stem, source="codex", path=path)
    first_prompt = ""
    for d in _iter_json(path):
        t = d.get("type")
        p = d.get("payload") or {}
        ts = d.get("timestamp")
        if t == "session_meta":
            s.id = p.get("id") or p.get("session_id") or s.id
            s.cwd = p.get("cwd", "")
            s.started_at = p.get("timestamp") or ts
            src = p.get("source")
            if isinstance(src, dict) and "subagent" in src:
                s.kind = "subagent"
            elif src == "exec" or p.get("originator") == "codex_exec":
                s.kind = "exec"
            git = p.get("git") or {}
            s.git_branch = git.get("branch", "") if isinstance(git, dict) else ""
            continue
        if t != "response_item":
            continue
        s.updated_at = ts or s.updated_at
        pt = p.get("type")
        if pt == "message":
            role = p.get("role")
            if role not in ("user", "assistant"):
                continue
            text = "\n".join(
                c.get("text", "") for c in p.get("content") or [] if isinstance(c, dict)
            ).strip()
            if role == "user":
                text = clean_user_text(text)
                if text:
                    first_prompt = first_prompt or text
            if text:
                s.messages.append(Message(role, _cap(text), ts))
        elif pt in ("function_call", "custom_tool_call", "local_shell_call"):
            args = p.get("arguments") or p.get("input") or p.get("action")
            s.messages.append(Message("tool", _tool_line(p.get("name", "shell"), args), ts))
    titles = titles or {}
    s.title = titles.get(s.id) or " ".join(first_prompt.split())[:90]
    return s


def file_sig(path: str) -> tuple[float, int]:
    st = os.stat(path)
    return st.st_mtime, st.st_size
