"""Distill a Claude Code JSONL session log down to the substantive conversation.

Emits a chronological, human-readable transcript to stdout. Keeps:
- User messages (full text)
- Assistant text blocks (full text, drops thinking blocks)
- Tool-call summaries (name + short input description)
- Tool-result heads (first N chars only)

Skips: attachments (task_reminder, skill_listing, deferred_tools_delta,
file-history-snapshot), queue-operation frames, thinking blocks, full tool
outputs, raw base64/image payloads.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

INPUT = Path(r"C:\Users\hp\.claude\projects\F--devf\fc9d3d75-30b0-48d3-828f-497990aa6250.jsonl")
OUTPUT = Path(r"F:\devf\.session_readable.txt")

TOOL_RESULT_HEAD = 0  # 0 = drop tool results entirely
KEEP_TOOL_CALLS = False  # drop tool-call summaries too; text-only distillation


def _extract_text(content) -> list[str]:
    """Pull plain-text pieces out of a message.content, skipping thinking blocks."""
    out: list[str] = []
    if isinstance(content, str):
        if content.strip():
            out.append(content.strip())
        return out
    if not isinstance(content, list):
        return out
    for block in content:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text":
            t = (block.get("text") or "").strip()
            if t:
                out.append(t)
        elif btype == "tool_use":
            if not KEEP_TOOL_CALLS:
                continue
            name = block.get("name", "?")
            inp = block.get("input") or {}
            desc_parts = []
            for k in ("description", "file_path", "command"):
                if k in inp:
                    v = inp[k]
                    if isinstance(v, str):
                        if len(v) > 120:
                            v = v[:120] + "…"
                        desc_parts.append(f"{k}={v!r}")
            out.append(f"[TOOL:{name}] " + " | ".join(desc_parts))
        elif btype == "tool_result":
            if TOOL_RESULT_HEAD <= 0:
                continue
            raw = block.get("content")
            if isinstance(raw, list):
                raw = " ".join(
                    (b.get("text", "") if isinstance(b, dict) else str(b))
                    for b in raw
                )
            elif not isinstance(raw, str):
                raw = json.dumps(raw)[:TOOL_RESULT_HEAD]
            raw = (raw or "").strip().replace("\n", " ")
            if len(raw) > TOOL_RESULT_HEAD:
                raw = raw[:TOOL_RESULT_HEAD] + "…"
            if raw:
                out.append(f"[RESULT] {raw}")
    return out


def main() -> None:
    lines_out: list[str] = []
    boundary_count = 0
    prev_ts_day = ""

    with INPUT.open("r", encoding="utf-8") as fh:
        for raw_line in fh:
            try:
                obj = json.loads(raw_line)
            except json.JSONDecodeError:
                continue

            t = obj.get("type")
            ts = obj.get("timestamp", "")
            ts_day = ts[:10]

            # Day-boundary separator for scanning.
            if ts_day and ts_day != prev_ts_day:
                if prev_ts_day:
                    lines_out.append("")
                lines_out.append(f"═════════ {ts_day} ═════════")
                prev_ts_day = ts_day

            # Detect session-continuation ("/compact" / resume). These show as
            # assistant messages whose first text is a summary of prior context.
            # We surface them as boundaries for orientation.
            if t == "user":
                msg = obj.get("message", {})
                role = msg.get("role") if isinstance(msg, dict) else None
                content = msg.get("content") if isinstance(msg, dict) else None
                # user messages carrying tool_result come through here too
                texts = _extract_text(content)
                for txt in texts:
                    if txt.startswith("[RESULT]"):
                        lines_out.append(f"  {txt}")
                    else:
                        lines_out.append("")
                        lines_out.append(f"── USER @ {ts} ──")
                        lines_out.append(txt)
                        lines_out.append("")

            elif t == "assistant":
                msg = obj.get("message", {})
                content = msg.get("content") if isinstance(msg, dict) else None
                texts = _extract_text(content)
                if texts:
                    header_shown = False
                    for txt in texts:
                        if txt.startswith("[TOOL:"):
                            lines_out.append(f"  {txt}")
                        else:
                            if not header_shown:
                                lines_out.append(f"── ASSISTANT @ {ts} ──")
                                header_shown = True
                            lines_out.append(txt)
                    if header_shown:
                        lines_out.append("")

            # Skip: attachment, file-history-snapshot, queue-operation, etc.

    OUTPUT.write_text("\n".join(lines_out), encoding="utf-8")
    print(f"Wrote {OUTPUT} ({len(lines_out)} lines, {OUTPUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
