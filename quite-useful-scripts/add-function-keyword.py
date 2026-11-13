#!/usr/bin/env python3
"""
add_function_keyword — normalize shell function headers to 'function name() {'

What it does
  • Rewrites lines like:   name() {       →   function name() {
                           name()         →   function name()   (when next line is '{')
  • Preserves indentation and trailing content after '{' on the same line.
  • Skips existing 'function name {' or 'function name() {'
  • Skips comment-only lines.
  • Skips content inside here-docs (<<EOF … EOF), including quoted and <<-TAB forms.

Scope & limitations
  • Matches function headers at the start of a line (after whitespace).
  • Handles '{' either on the same line or on the immediately following line.
  • Does NOT attempt to rewrite exotic forms (e.g., 'name() ( … )').
  • Here-doc delimiters are detected heuristically; common patterns are supported.

Usage
  dry run to stdout:
    add_function_keyword.py path1 [path2 …]

  in-place with backup:
    add_function_keyword.py -i -b .bak path1 [path2 …]

  print to stdout (no write):
    add_function_keyword.py --stdout path1

Exit codes
  0 success, 1 usage/error
"""
from __future__ import annotations
import argparse, io, os, re, sys
from typing import List, Optional, Tuple

# Recognize here-doc start: <<[-]? 'DELIM' | "DELIM" | DELIM
HEREDOC_START = re.compile(r"<<-?\s*(?P<q>['\"]?)(?P<tag>[^\s'\"\$`\\]+)(?P=q)")
# Function header same-line: indent + name() + { + rest
FUNC_SAME = re.compile(
    r"^(?P<indent>[ \t]*)" r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)" r"[ \t]*\(\)[ \t]*\{(?P<rest>.*)$"
)
# Function header lone line (brace next line): indent + name() [#comment]?
FUNC_NEXT = re.compile(
    r"^(?P<indent>[ \t]*)"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
    r"[ \t]*\(\)[ \t]*(?P<tail>(#[^\n]*)?)$"
)
# Lines already using 'function …'
HAS_FUNCTION_KW = re.compile(r"^[ \t]*function\b")
# Comment-only lines
COMMENT_ONLY = re.compile(r"^[ \t]*#")


def process_text(text: str) -> str:
    out_lines: List[str] = []
    lines = text.splitlines(keepends=True)

    in_here = False
    here_tag: Optional[str] = None
    here_allow_tabs = False

    pending: Optional[Tuple[str, str, str]] = None
    # (original_line, indent, name) for the 'name()' w/o '{' form

    i = 0
    n = len(lines)

    while i < n:
        line = lines[i]

        # Handle here-doc end if inside one
        if in_here:
            raw = line.rstrip("\n")
            cmp = raw.lstrip("\t") if here_allow_tabs else raw
            if cmp == here_tag:
                in_here = False
                here_tag = None
                here_allow_tabs = False
            out_lines.append(line)
            i += 1
            continue

        # Detect here-doc start (heuristic)
        m_hd = HEREDOC_START.search(line)
        if m_hd:
            in_here = True
            here_tag = m_hd.group("tag")
            here_allow_tabs = "<<-" in line
            out_lines.append(line)
            i += 1
            continue

        # If we had a pending 'name()' and now see a '{' line, emit fix
        if pending is not None:
            orig, indent, name = pending
            if re.match(r"^[ \t]*\{", line):
                out_lines.append(f"{indent}function {name}()\n")
                out_lines.append(line)
                pending = None
                i += 1
                continue
            else:
                # Not a brace line; flush original untouched, and keep processing
                out_lines.append(orig)
                pending = None
                # (do not 'continue': re-check current line below)

        # Skip comment-only lines quickly
        if COMMENT_ONLY.match(line):
            out_lines.append(line)
            i += 1
            continue

        # Already uses 'function' → leave as-is
        if HAS_FUNCTION_KW.match(line):
            out_lines.append(line)
            i += 1
            continue

        # Same-line header: name() {
        m1 = FUNC_SAME.match(line)
        if m1:
            indent = m1.group("indent")
            name = m1.group("name")
            rest = m1.group("rest")
            out_lines.append(
                f"{indent}function {name}() {{{rest}\n"
                if not line.endswith("\n")
                else f"{indent}function {name}() {{{rest}"
            )
            i += 1
            continue

        # Lone header: name() [#comment]
        m2 = FUNC_NEXT.match(line)
        if m2:
            indent = m2.group("indent")
            name = m2.group("name")
            # Queue pending; confirm next line starts with '{'
            pending = (line, indent, name)
            i += 1
            continue

        # Default: pass through
        out_lines.append(line)
        i += 1

    # If file ended with a pending header, flush original line untouched
    if pending is not None:
        out_lines.append(pending[0])

    return "".join(out_lines)


def process_file(path: str) -> Tuple[str, str]:
    with io.open(path, "r", encoding="utf-8", newline="") as f:
        original = f.read()
    fixed = process_text(original)
    return original, fixed


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="add_function_keyword",
        formatter_class=argparse.RawTextHelpFormatter,
        description=(
            "Rewrite shell function headers to 'function name() {' safely.\n"
            "Skips here-doc bodies and existing 'function' headers."
        ),
    )
    ap.add_argument("paths", nargs="+", help="Files to process")
    ap.add_argument("-i", "--in-place", action="store_true", help="Write changes back to files")
    ap.add_argument(
        "-b",
        "--backup",
        metavar="EXT",
        default="",
        help="Backup extension when using -i (e.g. .bak)",
    )
    ap.add_argument(
        "--stdout", action="store_true", help="Print the transformed content for a single file"
    )
    ap.add_argument("-q", "--quiet", action="store_true", help="Suppress per-file change notices")
    args = ap.parse_args(argv)

    rc = 0
    for p in args.paths:
        try:
            orig, fixed = process_file(p)
        except Exception as e:
            print(f"[error] {p}: {e}", file=sys.stderr)
            rc = 1
            continue

        changed = orig != fixed

        if args.stdout:
            # stdout mode expects exactly one file; still print best-effort
            sys.stdout.write(fixed)
            continue

        if args.in_place and changed:
            if args.backup:
                try:
                    os.replace(p, p + args.backup)
                except Exception as e:
                    print(f"[error] backup {p} → {p+args.backup}: {e}", file=sys.stderr)
                    rc = 1
                    continue
            try:
                with io.open(p, "w", encoding="utf-8", newline="") as f:
                    f.write(fixed)
            except Exception as e:
                print(f"[error] write {p}: {e}", file=sys.stderr)
                rc = 1
                continue
            if not args.quiet:
                print(f"[fix] {p}")
        else:
            # Dry-run summary
            if not args.quiet:
                print(f"[ok]  {p} (no change)" if not changed else f"[diff] {p} (would change)")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
