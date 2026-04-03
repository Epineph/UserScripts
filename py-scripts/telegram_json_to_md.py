#!/usr/bin/env python3
"""
telegram_json_to_md.py — Convert Telegram export result.json to markdown.

Usage
-----
  telegram_json_to_md.py result.json
  telegram_json_to_md.py result.json -o chat-log.md

Then, to get a PDF:
  pandoc chat-log.md -o chat-log.pdf
"""

import argparse
import datetime as dt
import json
from pathlib import Path
from typing import Any, Dict, List, Union


# ───────────────────────────── Helpers ─────────────────────────────


def normalize_text(text: Any) -> str:
    """
    Telegram 'text' can be:
      - a plain string
      - a list of strings and/or dicts like {"type": "bold", "text": "Hello"}
    This flattens everything into a single plain string.
    """
    if isinstance(text, str):
        return text

    if isinstance(text, list):
        parts: List[str] = []
        for chunk in text:
            if isinstance(chunk, str):
                parts.append(chunk)
            elif isinstance(chunk, dict):
                value = chunk.get("text")
                # Nested structure possible, recurse if needed
                parts.append(normalize_text(value))
        return "".join(parts)

    # Fallback – just string representation
    return str(text)


def format_timestamp(raw_date: str) -> str:
    """
    Telegram JSON dates are usually ISO 8601, e.g. '2025-11-05T17:11:26'.
    This tries to normalize, but falls back to the raw string if parsing fails.
    """
    if not raw_date:
        return "unknown-time"
    try:
        # Strip trailing 'Z' if present
        raw = raw_date.replace("Z", "")
        dt_obj = dt.datetime.fromisoformat(raw)
        return dt_obj.strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return raw_date


def format_message(msg: Dict[str, Any]) -> str:
    """
    Turn one Telegram message dict into a single human-readable line.
    Example:
      '2025-11-05 17:11:26 — Heini: some text [file: Heini-CV.pdf]'
    """
    raw_date = msg.get("date")
    ts = format_timestamp(raw_date)

    sender = msg.get("from") or msg.get("author") or "SYSTEM"
    body = normalize_text(msg.get("text", ""))

    # Collect attachments if present
    attach_bits: List[str] = []

    if "photo" in msg:
        attach_bits.append(f"[photo: {msg['photo']}]")

    if "file" in msg:
        f = msg["file"]
        if isinstance(f, dict):
            name = f.get("name") or f.get("file_name") or "file"
        else:
            name = str(f)
        attach_bits.append(f"[file: {name}]")

    if "media_type" in msg:
        attach_bits.append(f"[media: {msg['media_type']}]")

    # Combine text and attachments
    body = body.strip()
    if attach_bits:
        att = " ".join(attach_bits)
        body = f"{body} {att}".strip()

    if not body:
        body = "(non-text message)"

    return f"{ts} — {sender}: {body}"


# ───────────────────────────── Main ─────────────────────────────


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Convert Telegram result.json export to markdown."
    )
    ap.add_argument("input", help="Path to Telegram result.json")
    ap.add_argument(
        "-o",
        "--output",
        help="Output markdown file (default: same name with .md extension).",
    )
    args = ap.parse_args()

    in_path = Path(args.input)
    data = json.loads(in_path.read_text(encoding="utf-8"))

    # Telegram exports typically use 'messages' at the top level
    messages = data.get("messages")
    if messages is None:
        # Some variants embed chats in 'chats' → 'list'
        messages = data.get("chats", {}).get("list", [])

    title = data.get("name") or data.get("title") or in_path.stem

    lines: List[str] = []
    lines.append(f"# Telegram chat export: {title}")
    lines.append("")
    lines.append(f"_Source JSON_: `{in_path.resolve()}`")
    lines.append("")

    for msg in messages:
        if not isinstance(msg, dict):
            continue

        # Filter only "message"-like entries; ignore weird system entries if desired
        mtype = msg.get("type")
        if mtype not in (None, "message", "service"):
            continue

        lines.append("- " + format_message(msg))

    out_text = "\n".join(lines)

    out_path = Path(args.output) if args.output else in_path.with_suffix(".md")
    out_path.write_text(out_text, encoding="utf-8")

    print(f"Wrote markdown log to: {out_path.resolve()}")


if __name__ == "__main__":
    main()
