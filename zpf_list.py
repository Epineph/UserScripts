#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# zpf_list.py
#
# Purpose:
#   List aliases and/or functions defined in ~/.zsh_profile/*.zsh (only).
#
# Core idea:
#   1) Parse ~/.zsh_profile/*.zsh to extract candidate alias/function names.
#   2) Launch a clean-ish zsh, force `setopt interactive`, source those files,
#      then query zsh for the *actual* current definitions of those names.
#
# Output controls:
#   --name and --body are combinable. If neither is set, defaults to both.
#   --format=plain|markdown (markdown is nicer with bat).
#
# Paging:
#   Default: paging OFF.
#   --paging[=auto|always|never]
#     auto   -> use pager only when stdout is a TTY
#     always -> force pager
#     never  -> never page
#   Pager preference: bat if available; otherwise cat.
#
# Lint:
#   --lint runs `zsh -n` over collected definitions (syntax check).
# -----------------------------------------------------------------------------

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Set, Tuple


# ------------------------------- Parsing -------------------------------------


_ALIAS_RE = re.compile(
    r"""^\s*alias\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*=""",
    re.ASCII,
)

_FUNC_RE_1 = re.compile(
    r"""^\s*function\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\))?\s*\{""",
    re.ASCII,
)

_FUNC_RE_2 = re.compile(
    r"""^\s*(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{""",
    re.ASCII,
)


def _is_comment_line(line: str) -> bool:
    return bool(re.match(r"^\s*#", line))


def parse_profile_files(profile_dir: Path) -> Tuple[List[Path], Set[str], Set[str]]:
    files = sorted(profile_dir.glob("*.zsh"))
    alias_names: Set[str] = set()
    func_names: Set[str] = set()

    for fp in files:
        try:
            lines = fp.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue

        for line in lines:
            if _is_comment_line(line):
                continue

            m = _ALIAS_RE.match(line)
            if m:
                alias_names.add(m.group("name"))
                continue

            m = _FUNC_RE_1.match(line)
            if m:
                func_names.add(m.group("name"))
                continue

            m = _FUNC_RE_2.match(line)
            if m:
                func_names.add(m.group("name"))
                continue

    return files, alias_names, func_names


# ---------------------------- Zsh collection ---------------------------------


@dataclass(frozen=True)
class Collected:
    aliases: Dict[str, str]
    functions: Dict[str, str]


def _require_exe(name: str) -> str:
    exe = shutil.which(name)
    if not exe:
        raise FileNotFoundError(f"Required executable not found in PATH: {name}")
    return exe


def _chunks(items: Sequence[str], size: int = 200) -> Iterable[List[str]]:
    for i in range(0, len(items), size):
        yield list(items[i : i + size])


def _run_zsh_collect(
    *,
    zsh_exe: str,
    profile_dir: Path,
    kind: str,
    names: Sequence[str],
) -> Dict[str, str]:
    """
    kind:
      - "aliases"   -> {name: "alias name='...'"}
      - "functions" -> {name: "name () { ... }"}
    """
    if kind not in {"aliases", "functions"}:
        raise ValueError(f"Invalid kind: {kind}")

    # Force interactive so modules guarded by `zsh_is_interactive || return 0`
    # are actually sourced.
    if kind == "aliases":
        zsh_code = r"""
emulate -L zsh
setopt no_aliases
setopt interactive
setopt null_glob
profile_dir="$1"
shift

for f in "$profile_dir"/*.zsh; do
  source "$f" 2>/dev/null
done

for n in "$@"; do
  if alias "$n" >/dev/null 2>&1; then
    print -r -- "@@BEGIN@@ $n"
    alias -L "$n"
    print -r -- "@@END@@"
  fi
done
"""
    else:
        zsh_code = r"""
emulate -L zsh
setopt no_aliases
setopt interactive
setopt null_glob
profile_dir="$1"
shift

for f in "$profile_dir"/*.zsh; do
  source "$f" 2>/dev/null
done

for n in "$@"; do
  if (( ${+functions[$n]} )); then
    print -r -- "@@BEGIN@@ $n"
    functions "$n"
    print -r -- "@@END@@"
  fi
done
"""

    out: Dict[str, str] = {}
    if not names:
        return out

    for batch in _chunks(list(names), size=200):
        proc = subprocess.run(
            [zsh_exe, "-c", zsh_code, "--", str(profile_dir), *batch],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        # Do not hard-fail on return codes; sourcing may return non-zero.
        if proc.stderr.strip():
            # Keep stderr visible, but do not intermingle with structured output.
            print(proc.stderr.rstrip(), file=sys.stderr)

        current: str | None = None
        buf: List[str] = []

        for line in proc.stdout.splitlines():
            if line.startswith("@@BEGIN@@ "):
                current = line.split(" ", 1)[1].strip()
                buf = []
                continue
            if line.strip() == "@@END@@":
                if current is not None:
                    out[current] = "\n".join(buf).rstrip()
                current = None
                buf = []
                continue
            if current is not None:
                buf.append(line)

    return out


def collect_definitions(profile_dir: Path, want_aliases: bool,
                        want_functions: bool) -> Collected:
    zsh_exe = _require_exe("zsh")
    _, alias_names, func_names = parse_profile_files(profile_dir)

    aliases: Dict[str, str] = {}
    functions: Dict[str, str] = {}

    if want_aliases:
        aliases = _run_zsh_collect(
            zsh_exe=zsh_exe,
            profile_dir=profile_dir,
            kind="aliases",
            names=sorted(alias_names),
        )

    if want_functions:
        functions = _run_zsh_collect(
            zsh_exe=zsh_exe,
            profile_dir=profile_dir,
            kind="functions",
            names=sorted(func_names),
        )

    return Collected(aliases=aliases, functions=functions)


# ------------------------------- Linting -------------------------------------


def lint_with_zsh(definitions: str) -> Tuple[bool, str]:
    zsh_exe = _require_exe("zsh")
    proc = subprocess.run(
        [zsh_exe, "-n"],
        input=definitions,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    ok = (proc.returncode == 0)
    msg = proc.stderr.rstrip()
    return ok, msg


# ------------------------------ Formatting -----------------------------------


def _md_code(lang: str, body: str) -> str:
    return f"```{lang}\n{body.rstrip()}\n```\n"


def format_output(
    collected: Collected,
    *,
    mode: str,
    want_name: bool,
    want_body: bool,
    fmt: str,
) -> str:
    if fmt not in {"plain", "markdown"}:
        raise ValueError(f"Invalid format: {fmt}")

    out: List[str] = []

    def section(title: str) -> None:
        if fmt == "markdown":
            out.append(f"## {title}\n")
        else:
            out.append(f"== {title} ==\n")

    def item(kind: str, name: str, body: str) -> None:
        if fmt == "markdown":
            if want_name and not want_body:
                out.append(f"- `{name}`\n")
            elif want_body and not want_name:
                out.append(_md_code("zsh", body))
            else:
                out.append(f"### {kind}: `{name}`\n")
                out.append(_md_code("zsh", body))
        else:
            if want_name and not want_body:
                out.append(f"{name}\n")
            elif want_body and not want_name:
                out.append(f"{body.rstrip()}\n")
            else:
                out.append(f"# {kind}: {name}\n")
                out.append(f"{body.rstrip()}\n")

    first = True

    if mode in {"aliases", "both"} and collected.aliases:
        if not first:
            out.append("\n")
        first = False
        section("aliases")
        for n in sorted(collected.aliases.keys()):
            item("alias", n, collected.aliases[n])

    if mode in {"functions", "both"} and collected.functions:
        if not first:
            out.append("\n")
        section("functions")
        for n in sorted(collected.functions.keys()):
            item("function", n, collected.functions[n])

    return "".join(out).rstrip() + "\n"


# ------------------------------- Paging --------------------------------------


def _should_page(paging: str) -> bool:
    if paging == "never":
        return False
    if paging == "always":
        return True
    # auto
    return sys.stdout.isatty()


def _run_pager(text: str, fmt: str, bat_args: List[str]) -> int:
    bat = shutil.which("bat")
    if bat:
        # Use a stable, explicit language when rendering markdown.
        cmd = [bat, "--paging=always"]
        if fmt == "markdown":
            cmd += ["-l", "markdown"]
        cmd += bat_args
        proc = subprocess.run(cmd, input=text, text=True, check=False)
        return proc.returncode
    # Fallback: cat (not a pager, but respects "bat else cat" requirement).
    proc = subprocess.run(["cat"], input=text, text=True, check=False)
    return proc.returncode


# ------------------------------- CLI -----------------------------------------


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="zpf_list.py",
        formatter_class=argparse.RawTextHelpFormatter,
        description=(
            "List aliases/functions defined in ~/.zsh_profile/*.zsh only.\n"
            "Flags --name and --body are combinable; if neither is given,\n"
            "defaults to both.\n"
            "\n"
            "Examples:\n"
            "  # List names + bodies (default), no paging\n"
            "  zpf_list.py\n"
            "\n"
            "  # Names only (functions)\n"
            "  zpf_list.py functions --name\n"
            "\n"
            "  # Bodies only (aliases)\n"
            "  zpf_list.py aliases --body\n"
            "\n"
            "  # Names + bodies explicitly\n"
            "  zpf_list.py both --name --body\n"
            "\n"
            "  # Markdown output + paging only when in a TTY\n"
            "  zpf_list.py --format=markdown --paging\n"
            "\n"
            "  # Force paging (useful in ISO/TTY), render as markdown\n"
            "  zpf_list.py --format=markdown --paging=always\n"
            "\n"
            "  # Never page even if --paging would otherwise be used\n"
            "  zpf_list.py --format=markdown --paging=never\n"
            "\n"
            "  # Lint the collected definitions with zsh syntax check\n"
            "  zpf_list.py --lint\n"
            "\n"
            "  # Pass extra options to bat (repeatable)\n"
            "  zpf_list.py --format=markdown --paging --bat-arg='--theme=gruvbox-dark'\n"
            "  zpf_list.py --format=markdown --paging --bat-arg='--style=grid,header'\n"
            "\n"
            "  # Use a different profile directory\n"
            "  zpf_list.py --profile-dir ~/.config/zsh/profile.d --name\n"
        ),
    )


    p.add_argument(
        "mode",
        nargs="?",
        choices=["aliases", "functions", "both"],
        default="both",
        help="What to list (default: both).",
    )

    p.add_argument(
        "--profile-dir",
        default=str(Path.home() / ".zsh_profile"),
        help="Profile directory containing *.zsh modules.",
    )

    p.add_argument("--name", action="store_true", help="Include names in output.")
    p.add_argument("--body", action="store_true", help="Include bodies in output.")

    p.add_argument(
        "--format",
        choices=["plain", "markdown"],
        default="plain",
        help="Output format (default: plain).",
    )

    p.add_argument(
        "--lint",
        action="store_true",
        help="Run `zsh -n` over collected definitions; non-zero on errors.",
    )

    p.add_argument(
        "--paging",
        nargs="?",
        const="auto",
        choices=["auto", "always", "never"],
        default="never",
        help=(
            "Paging control (default: never).\n"
            "  --paging        == --paging=auto\n"
            "  --paging=auto   use pager only when stdout is a TTY\n"
            "  --paging=always force pager\n"
            "  --paging=never  never page"
        ),
    )

    p.add_argument(
        "--bat-arg",
        action="append",
        default=[],
        help="Extra argument to pass to bat (repeatable).",
    )

    return p


def main(argv: Sequence[str]) -> int:
    args = build_arg_parser().parse_args(argv)

    profile_dir = Path(os.path.expanduser(args.profile_dir)).resolve()
    if not profile_dir.is_dir():
        print(f"Error: profile dir not found: {profile_dir}", file=sys.stderr)
        return 2

    # --name and --body are combinable; default is both if neither given.
    want_name = args.name
    want_body = args.body
    if not want_name and not want_body:
        want_name = True
        want_body = True

    want_aliases = args.mode in {"aliases", "both"}
    want_functions = args.mode in {"functions", "both"}

    try:
        collected = collect_definitions(profile_dir, want_aliases, want_functions)
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 2

    # Lint uses bodies regardless of output selection.
    if args.lint:
        bodies: List[str] = []
        if want_aliases:
            bodies.extend(collected.aliases.values())
        if want_functions:
            bodies.extend(collected.functions.values())
        ok, msg = lint_with_zsh("\n\n".join(bodies) + "\n")
        if not ok:
            if msg:
                print(msg, file=sys.stderr)
            return 1

    text = format_output(
        collected,
        mode=args.mode,
        want_name=want_name,
        want_body=want_body,
        fmt=args.format,
    )

    if _should_page(args.paging):
        return _run_pager(text, args.format, args.bat_arg)

    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

