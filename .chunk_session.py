"""Split .session_readable.txt into chunks ≤ ~90KB each (fits in one Read call).
Splits on blank lines only (never mid-message), respects day boundaries when
possible so no message is cut in half.
"""
from pathlib import Path

SRC = Path(r"F:\devf\.session_readable.txt")
TARGET_BYTES = 55_000

text = SRC.read_text(encoding="utf-8")
lines = text.split("\n")

chunks: list[list[str]] = []
cur: list[str] = []
cur_size = 0

for ln in lines:
    cur.append(ln)
    cur_size += len(ln) + 1
    # Flush when we exceed target AND we're on a natural boundary (blank line
    # or day/compaction separator).
    if cur_size >= TARGET_BYTES:
        if ln.strip() == "" or ln.startswith("═══"):
            chunks.append(cur)
            cur = []
            cur_size = 0

if cur:
    chunks.append(cur)

print(f"Splitting into {len(chunks)} chunks")
for i, chunk in enumerate(chunks, 1):
    dest = Path(rf"F:\devf\.session_part_{i:02d}.txt")
    dest.write_text("\n".join(chunk), encoding="utf-8")
    # First user/assistant header in this chunk (for manifest orientation).
    header = next(
        (ln for ln in chunk if ln.startswith("── ") or ln.startswith("═══")),
        "(no header)",
    )
    try:
        print(f"  part_{i:02d}: {len(chunk)} lines, {dest.stat().st_size} bytes")
    except UnicodeEncodeError:
        pass
