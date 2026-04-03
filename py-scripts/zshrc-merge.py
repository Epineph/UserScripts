#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# zshrc_merge.py
#
# Merge "missing" blocks from a source .zshrc into a target .zshrc safely.
#
# Core idea:
#   - Identify "significant" lines (non-empty, not pure comments).
#   - Consider a significant line "present" if its normalized form exists in
#     target. (Normalization collapses whitespace.)
#   - Collect contiguous missing blocks from source (including adjacent comments
#     and blank lines for readability).
#   - Insert each block near an "anchor" line that exists in target.
#   - Default is dry-run; apply requires --apply.
#
# Safety:
#   - If overlap of significant lines is zero and target is not empty, abort
#     unless --allow-no-overlap or interactive confirmation is used.
#
# -----------------------------------------------------------------------------

from __future__ import annotations

import argparse
import datetime as _dt
import difflib
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from typing import Optional, List, Dict, Tuple


# -----------------------------------------------------------------------------
# Helpers: text classification and normalization
# -----------------------------------------------------------------------------


def _is_pure_comment(line: str) -> bool:
    s = line.lstrip()
    return bool(s) and s.startswith("#")


def _is_blank(line: str) -> bool:
    return line.strip() == ""


def _normalize_significant(line: str) -> str:
    """
    Normalize a significant line for matching:
      - strip leading/trailing whitespace
      - collapse internal whitespace sequences to single spaces
    """
    s = line.strip()
    parts = s.split()
    return " ".join(parts)


def _fingerprint(line: str) -> Optional[str]:
    """
    Fingerprint used for "presence" and anchoring.
    Returns None for blank lines and pure comments.
    """
    if _is_blank(line) or _is_pure_comment(line):
        return None
    return _normalize_significant(line)


def _read_text(path: str) -> List[str]:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read().splitlines(keepends=True)


def _write_text(path: str, lines: List[str]) -> None:
    parent = os.path.dirname(os.path.abspath(path)) or "."
    os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8", errors="strict") as f:
        f.writelines(lines)


def _timestamp() -> str:
    return _dt.datetime.now().strftime("%Y%m%d-%H%M%S")


def _which(cmd: str) -> Optional[str]:
    return shutil.which(cmd)


def _pager_cmd() -> List[str]:
    """
    Pager for help output (not for diffs).
    User can override with HELP_PAGER.
    """
    env = os.environ.get("HELP_PAGER", "").strip()
    if env:
        return env.split()

    if _which("less"):
        return ["less", "-R"]
    return ["cat"]


def _page_text(text: str) -> None:
    """
    Pipe text to pager only if stdout is a TTY; otherwise print.
    """
    if not sys.stdout.isatty():
        sys.stdout.write(text)
        return

    cmd = _pager_cmd()
    try:
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        assert p.stdin is not None
        p.stdin.write(text.encode("utf-8", errors="replace"))
        p.stdin.close()
        p.wait()
    except Exception:
        sys.stdout.write(text)


# -----------------------------------------------------------------------------
# Data model: a merge block
# -----------------------------------------------------------------------------


@dataclass
class Block:
    src_start: int  # 0-based line index in source
    src_end: int  # inclusive 0-based line index in source
    lines: List[str]  # actual lines from source (keepends preserved)
    before_anchor_fp: Optional[str]
    after_anchor_fp: Optional[str]


# -----------------------------------------------------------------------------
# Block discovery
# -----------------------------------------------------------------------------


def _index_fps(lines: List[str]) -> Dict[str, List[int]]:
    """
    Map fingerprint -> list of indices where it occurs in the given text.
    """
    m: Dict[str, List[int]] = {}
    for i, line in enumerate(lines):
        fp = _fingerprint(line)
        if fp is None:
            continue
        m.setdefault(fp, []).append(i)
    return m


def _overlap_stats(src_lines: List[str], tgt_lines: List[str]) -> Tuple[int, int, int]:
    """
    Returns (src_sig_count, tgt_sig_count, intersection_count) over fingerprints.
    """
    src_set = {fp for fp in (_fingerprint(x) for x in src_lines) if fp is not None}
    tgt_set = {fp for fp in (_fingerprint(x) for x in tgt_lines) if fp is not None}
    inter = src_set & tgt_set
    return (len(src_set), len(tgt_set), len(inter))


def _discover_blocks(
    src_lines: List[str], tgt_fp_index: Dict[str, List[int]]
) -> List[Block]:
    """
    Scan source left-to-right collecting blocks that contain missing significant
    lines, and include adjacent non-significant lines for readability.
    """
    blocks: List[Block] = []

    last_present_fp: Optional[str] = None
    prebuffer: List[Tuple[int, str]] = []

    in_block = False
    block_start = -1
    block_items: List[Tuple[int, str]] = []
    before_anchor_fp: Optional[str] = None
    after_anchor_fp: Optional[str] = None

    def flush_block() -> None:
        nonlocal in_block, block_start, block_items, before_anchor_fp, after_anchor_fp
        if not in_block:
            return
        if not block_items:
            in_block = False
            return

        src_start = block_items[0][0]
        src_end = block_items[-1][0]
        lines = [x[1] for x in block_items]

        blocks.append(
            Block(
                src_start=src_start,
                src_end=src_end,
                lines=lines,
                before_anchor_fp=before_anchor_fp,
                after_anchor_fp=after_anchor_fp,
            )
        )

        in_block = False
        block_start = -1
        block_items = []
        before_anchor_fp = None
        after_anchor_fp = None

    for i, line in enumerate(src_lines):
        fp = _fingerprint(line)

        if fp is None:
            if in_block:
                block_items.append((i, line))
            else:
                prebuffer.append((i, line))
            continue

        present = fp in tgt_fp_index

        if in_block:
            if present:
                after_anchor_fp = fp
                flush_block()
                prebuffer = []
                last_present_fp = fp
            else:
                block_items.append((i, line))
        else:
            if present:
                prebuffer = []
                last_present_fp = fp
            else:
                in_block = True
                before_anchor_fp = last_present_fp
                block_items = prebuffer + [(i, line)]
                prebuffer = []

    if in_block:
        flush_block()

    return blocks


# -----------------------------------------------------------------------------
# Insertion logic
# -----------------------------------------------------------------------------


def _find_insertion_index(
    tgt_lines: List[str], before_fp: Optional[str], after_fp: Optional[str]
) -> int:
    """
    Compute insertion index into target:
      - Prefer inserting AFTER last occurrence of before_fp.
      - Else insert BEFORE first occurrence of after_fp.
      - Else append at end.
    """
    if before_fp is not None:
        last_idx = -1
        for i, line in enumerate(tgt_lines):
            if _fingerprint(line) == before_fp:
                last_idx = i
        if last_idx >= 0:
            return last_idx + 1

    if after_fp is not None:
        for i, line in enumerate(tgt_lines):
            if _fingerprint(line) == after_fp:
                return i

    return len(tgt_lines)


def _trim_boundary_blanks(
    block_lines: List[str], left_neighbor: Optional[str], right_neighbor: Optional[str]
) -> List[str]:
    """
    Tidy: avoid creating large blank stacks at boundaries.
    """
    out = list(block_lines)

    if left_neighbor is not None and _is_blank(left_neighbor):
        while out and _is_blank(out[0]):
            out.pop(0)

    if right_neighbor is not None and _is_blank(right_neighbor):
        while out and _is_blank(out[-1]):
            out.pop()

    return out


def _apply_blocks(tgt_lines: List[str], blocks: List[Block]) -> List[str]:
    """
    Apply blocks sequentially to a working copy of target.
    """
    out = list(tgt_lines)

    for b in blocks:
        ins = _find_insertion_index(out, b.before_anchor_fp, b.after_anchor_fp)

        left_neighbor = out[ins - 1] if ins - 1 >= 0 else None
        right_neighbor = out[ins] if ins < len(out) else None

        payload = _trim_boundary_blanks(b.lines, left_neighbor, right_neighbor)
        if not payload:
            continue

        out[ins:ins] = payload

        if out and not out[-1].endswith("\n"):
            out[-1] = out[-1] + "\n"

    return out


# -----------------------------------------------------------------------------
# CLI presentation
# -----------------------------------------------------------------------------

HELP_TEXT = r"""
NAME
  zshrc_merge.py - safely merge missing blocks from one .zshrc into another

SYNOPSIS
  zshrc_merge.py --source PATH --target PATH [--interactive] [--apply]
                 [--yes] [--allow-no-overlap] [--backup/--no-backup]

BEHAVIOR
  - Discovers blocks in SOURCE that appear missing from TARGET (based on
    normalized "significant lines": non-empty, non-comment).
  - Inserts blocks near anchors that exist in TARGET.
  - Default is DRY-RUN: shows a unified diff but does not write.
  - Writing requires --apply.

SAFETY
  If SOURCE and TARGET share zero significant lines and TARGET is not empty,
  the script aborts unless:
    - --allow-no-overlap is set, or
    - --interactive is used and you confirm.

EXAMPLES
  Dry-run merge (recommended first):
    zshrc_merge.py --source ~/.zshrc.laptop --target ~/.zshrc

  Interactive selection of blocks (dry-run until you add --apply):
    zshrc_merge.py --source ~/.zshrc.laptop --target ~/.zshrc --interactive

  Apply all discovered blocks non-interactively:
    zshrc_merge.py --source ~/.zshrc.laptop --target ~/.zshrc --apply --yes

  Allow merge even if no overlap exists (high risk):
    zshrc_merge.py --source A --target B --apply --yes --allow-no-overlap

NOTES
  This is a pragmatic merge tool, not a full zsh parser.
  Order matters in shells. Always dry-run, inspect the diff, then apply.

ENVIRONMENT
  HELP_PAGER   Pager used for --help (default: "less -R" or "cat")
"""


def _print_help(exit_code: int = 0) -> None:
    _page_text(HELP_TEXT.lstrip())
    raise SystemExit(exit_code)


def _prompt_choice(prompt: str, default: str = "n") -> str:
    """
    Return one of: y, n, a, q, ?
    """
    d = default.lower()
    if d not in {"y", "n"}:
        d = "n"

    suffix = "[y/N/a/q/?]" if d == "n" else "[Y/n/a/q/?]"
    while True:
        s = input(f"{prompt} {suffix} ").strip().lower()
        if s == "":
            return d
        if s in {"y", "n", "a", "q", "?"}:
            return s


def _unified_diff(old: List[str], new: List[str], fromfile: str, tofile: str) -> str:
    return (
        "".join(
            difflib.unified_diff(
                old,
                new,
                fromfile=fromfile,
                tofile=tofile,
                lineterm="",
            )
        )
        + "\n"
    )


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------


def main(argv: List[str]) -> int:
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("--help", "-h", action="store_true")
    p.add_argument("--source", required=False)
    p.add_argument("--target", required=False)

    p.add_argument("--interactive", action="store_true")
    p.add_argument("--apply", action="store_true")
    p.add_argument(
        "--yes", action="store_true", help="Non-interactive: accept all blocks."
    )
    p.add_argument("--allow-no-overlap", action="store_true")

    p.add_argument("--backup", dest="backup", action="store_true", default=True)
    p.add_argument("--no-backup", dest="backup", action="store_false")

    args = p.parse_args(argv)

    if args.help:
        _print_help(0)

    if not args.source or not args.target:
        _print_help(2)

    src_path = os.path.expanduser(args.source)
    tgt_path = os.path.expanduser(args.target)

    if not os.path.exists(src_path):
        print(f"[ERROR] Source not found: {src_path}", file=sys.stderr)
        return 2

    tgt_exists = os.path.exists(tgt_path)
    tgt_lines = _read_text(tgt_path) if tgt_exists else []
    src_lines = _read_text(src_path)

    tgt_is_empty = (not tgt_lines) or all(_is_blank(x) for x in tgt_lines)

    if tgt_is_empty:
        cmd = f'cp -- "{src_path}" "{tgt_path}"'
        if not args.apply:
            print("[INFO] Target is empty. The sensible operation is full populate.")
            print(f"[DRY-RUN] Would run:\n  {cmd}")
            return 0

        if tgt_exists and args.backup and not tgt_is_empty:
            bak = f"{tgt_path}.bak.{_timestamp()}"
            shutil.copy2(tgt_path, bak)

        os.makedirs(os.path.dirname(os.path.abspath(tgt_path)) or ".", exist_ok=True)
        shutil.copy2(src_path, tgt_path)
        print(f"[OK] Populated target with source:\n  {tgt_path}")
        return 0

    tgt_fp_index = _index_fps(tgt_lines)
    blocks = _discover_blocks(src_lines, tgt_fp_index)

    src_sig, tgt_sig, inter = _overlap_stats(src_lines, tgt_lines)
    if inter == 0 and not args.allow_no_overlap:
        msg = (
            "[WARN] No overlap of significant lines between source and target.\n"
            "       This is high risk (style/order may differ)."
        )
        if args.interactive:
            print(msg)
            c = _prompt_choice("Proceed anyway?", default="n")
            if c != "y":
                print("[ABORT] Refusing to merge with no overlap.")
                return 3
        else:
            print(msg, file=sys.stderr)
            print(
                "[ABORT] Use --allow-no-overlap or --interactive to override.",
                file=sys.stderr,
            )
            return 3

    if not blocks:
        print("[OK] No missing blocks detected. Nothing to do.")
        return 0

    chosen: List[Block] = []

    if args.yes and not args.interactive:
        chosen = blocks
    elif args.interactive:
        print(f"[INFO] Discovered {len(blocks)} candidate block(s).")
        add_all = False
        for k, b in enumerate(blocks, start=1):
            if add_all:
                chosen.append(b)
                continue

            span = f"source lines {b.src_start + 1}-{b.src_end + 1}"
            c = _prompt_choice(f"[{k}/{len(blocks)}] Add block ({span})?", default="n")
            if c == "?":
                print(
                    "".join(b.lines),
                    end="" if b.lines and b.lines[-1].endswith("\n") else "\n",
                )
                c = _prompt_choice(f"Add this block ({span})?", default="n")

            if c == "y":
                chosen.append(b)
            elif c == "a":
                chosen.append(b)
                add_all = True
            elif c == "q":
                print("[ABORT] User quit. No changes made.")
                return 4
    else:
        chosen = blocks

    new_lines = _apply_blocks(tgt_lines, chosen)

    diff = _unified_diff(
        tgt_lines,
        new_lines,
        fromfile=f"{tgt_path} (current)",
        tofile=f"{tgt_path} (proposed)",
    )

    if diff.strip() == "":
        print("[OK] Proposed merge results in no textual changes.")
        return 0

    print(diff, end="")

    if not args.apply:
        print("[DRY-RUN] Not writing. Re-run with --apply to write changes.")
        return 0

    if args.backup:
        bak = f"{tgt_path}.bak.{_timestamp()}"
        shutil.copy2(tgt_path, bak)
        print(f"[INFO] Backup written:\n  {bak}")

    _write_text(tgt_path, new_lines)
    print(f"[OK] Updated target:\n  {tgt_path}")

    print(
        f"[INFO] Overlap stats (significant lines): "
        f"source={src_sig}, target={tgt_sig}, intersection={inter}"
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
