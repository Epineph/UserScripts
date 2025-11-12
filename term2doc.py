#!/usr/bin/env python3
"""term2doc.py — Capture terminal output or file content and convert it into colourful PDF, Markdown, CSV, or image artefacts.

================================================================================
Rationale
--------------------------------------------------------------------------------
`bat`, `lsd`, and similar “modern” command‑line tools already provide rich,
syntax‑highlighted or colourised output.  Unfortunately, that richness is lost
as soon as you need to share the information as a document.  **Term2Doc** bridges
this gap: you feed it either

1. The *output* of an *arbitrary* shell command (e.g. ``bat my_script.py``,
   ``lsd -la``), **or**
2. The *contents* of an existing file (``*.txt``, ``*.md``, ``*.html`` …),

and the tool renders the result to **PDF**, **Markdown**, **CSV**, or **PNG** while
preserving colours where appropriate.

================================================================================
Hard requirements
--------------------------------------------------------------------------------
External binaries (installable from the Arch repos / AUR):

    bat             # syntax‑highlighting pager (community/bat)
    lsd             # ls clone with colours/icons (community/lsd)
    pandoc          # universal document converter (extra/pandoc)
    wkhtmltopdf     # HTML → PDF (extra/wkhtmltopdf)
    wkhtmltoimage   # HTML → PNG (comes with wkhtmltopdf)
    fd              # fast file finder (community/fd)
    ripgrep         # recursive grep (community/ripgrep)

Python libraries (install with ``pip install ...``):

    ansi2html
    pandas          # only needed for CSV export
    pygments        # optional, lets us highlight files without invoking bat

A reasonably complete LaTeX installation (e.g. ``texlive-most``) is required
*only* when you let Pandoc use its LaTeX backend (``*.md → *.pdf``).

================================================================================
CLI synopsis
--------------------------------------------------------------------------------
$ term2doc.py (--file PATH | --command "CMD") [--no-colour] -t TARGET [TARGET...]
                  [-o OUT] [--theme-css CSS] [--lsd-csv "lsd OPTIONS"]
                  [--keep-temp] [-v]

Arguments (most important):

    --file PATH           Treat PATH as the *source*.  If it is a script file,
                          Term2Doc will invoke *bat* internally to obtain
                          colourised output unless ``--no-colour`` is given.

    --command CMD         Execute CMD in the shell and capture *stdout* +
                          ANSI colours.  Useful for ``lsd`` listings etc.

    -t TARGET             One or more of {pdf, md, csv, png}.  For csv you
                          must supply a command that produces a tabular layout
                          (e.g. ``--command "lsd -la"``).

    -o OUT                Basename for the resulting artefact(s).  Extension is
                          appended automatically [default: derived from INPUT].

    --no-colour           Strip ANSI colours before processing (disables fancy
                          themes; mainly convenient for CSV).

Full details are available via ``-h / --help``.

================================================================================
Implementation notes
--------------------------------------------------------------------------------
* ANSI‑to‑HTML: handled by *ansi2html*; for Bat‑style themes we embed the CSS
  shipped with *bat* (``bat --list-themes``).
* HTML‑to‑PDF / PNG: delegated to *wkhtmltopdf* / *wkhtmltoimage*.
* CSV conversion for *lsd*: we run a *second*, colour‑less invocation of *lsd*
  using the ``--classic`` flag (guarantees stable whitespace layout) and parse
  the columns with a small regex into a *pandas* ``DataFrame``.
"""

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from typing import List, Optional

try:
    import pandas as pd
except ImportError:
    pd = None  # Optional unless CSV output requested

try:
    from ansi2html import Ansi2HTMLConverter
except ImportError:
    Ansi2HTMLConverter = None  # Will be checked at runtime


# ------------------------------------------------------------------------------
# Utility helpers
# ------------------------------------------------------------------------------

def _which(binary: str) -> Optional[str]:
    """Return PATH to *binary* if it exists in $PATH, else *None*."""
    return shutil.which(binary)


def _require_binaries(bins: List[str]) -> None:
    """Abort with a clear error if any *bins* are missing."""
    missing = [b for b in bins if not _which(b)]
    if missing:
        sys.exit(f"[ERROR] Required external tool(s) not found: {', '.join(missing)}")


def _run_shell(cmd: str, capture=True, check=True, env=None, cwd=None) -> subprocess.CompletedProcess:
    """Execute *cmd* (through the shell).  Return the *CompletedProcess*."""
    return subprocess.run(
        cmd, shell=True, capture_output=capture, text=True, check=check, env=env, cwd=cwd
    )


def _capture_command_output(cmd: str, colour: bool = True) -> str:
    """Run *cmd* and return its stdout **with** or **without** ANSI colours."""
    env = os.environ.copy()
    if not colour:
        # Force downstream tools to disable colour if they respect NO_COLOR
        env["NO_COLOR"] = "1"
    cp = _run_shell(cmd, env=env)
    return cp.stdout


# ------------------------------------------------------------------------------
# Conversion primitives
# ------------------------------------------------------------------------------

def _ansi_to_html(ansi_text: str, theme_css: Optional[str] = None) -> str:
    """Convert *ansi_text* to a standalone HTML document preserving colours."""
    if Ansi2HTMLConverter is None:
        sys.exit("[ERROR] ansi2html Python package not installed (pip install ansi2html)")
    conv = Ansi2HTMLConverter(dark_bg=True, inline=True)
    body = conv.convert(ansi_text, full=False)
    css_block = f"<style>{theme_css}</style>" if theme_css else ""
    html = f"""<!doctype html>
<html lang='en'><head><meta charset='utf-8'>{css_block}
<title>term2doc export</title></head><body><pre>{body}</pre></body></html>"""
    return html


def _html_to_pdf(html_path: pathlib.Path, pdf_path: pathlib.Path) -> None:
    _require_binaries(["wkhtmltopdf"])
    _run_shell(f"wkhtmltopdf {html_path} {pdf_path}")


def _html_to_png(html_path: pathlib.Path, png_path: pathlib.Path) -> None:
    _require_binaries(["wkhtmltoimage"])
    _run_shell(f"wkhtmltoimage {html_path} {png_path}")


def _text_to_markdown(text_path: pathlib.Path, md_path: pathlib.Path) -> None:
    _require_binaries(["pandoc"])
    _run_shell(f"pandoc -s -o {md_path} {text_path}")


def _markdown_to_pdf(md_path: pathlib.Path, pdf_path: pathlib.Path) -> None:
    _require_binaries(["pandoc"])
    _run_shell(f"pandoc -s -o {pdf_path} {md_path}")


# ------------------------------------------------------------------------------
# LSD → CSV
# ------------------------------------------------------------------------------

_LSD_REGEX = re.compile(
    r"^(?P<perm>\S+)\s+"         # permissions
    r"(?P<links>\d+)\s+"         # hard links
    r"(?P<owner>\S+)\s+"         # owner
    r"(?P<group>\S+)\s+"         # group
    r"(?P<size>\d+)\s+"          # size in bytes
    r"(?P<date>\d{4}-\d{2}-\d{2})\s+"    # ISO date (lsd --date iso)
    r"(?P<time>\d{2}:\d{2}:\d{2})\s+"    # time
    r"(?P<name>.+)$"               # file name (greedy)
)


def _parse_lsd(text: str):
    if pd is None:
        sys.exit("[ERROR] pandas not installed; needed for CSV output (pip install pandas)")
    records = []
    for line in text.splitlines():
        m = _LSD_REGEX.match(line.strip())
        if m:
            records.append(m.groupdict())
    return pd.DataFrame.from_records(records)


# ------------------------------------------------------------------------------
# Main workflow
# ------------------------------------------------------------------------------

def _build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="term2doc.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="""Capture terminal output or file contents and render them as colourful documents.
Examples:
  term2doc.py --file my_script.py -t pdf
  term2doc.py --command "lsd -la --date iso" -t csv pdf
  term2doc.py --file report.html -t pdf
""",
    )
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--file", help="Input file to process")
    src.add_argument("--command", help="Shell command to execute and capture")

    p.add_argument(
        "-t", "--to", dest="targets", nargs="+", required=True,
        choices=["pdf", "md", "csv", "png"],
        help="One or more output format(s)"
    )
    p.add_argument("-o", "--output", metavar="BASENAME", help="Basename for output artefact(s)")
    p.add_argument("--no-colour", action="store_true", help="Strip ANSI colours before processing")
    p.add_argument("--theme-css", metavar="CSSFILE", help="Path to custom CSS for ANSI → HTML")
    p.add_argument(
        "--lsd-csv", metavar="LSD_OPTS", default="-la --date iso --classic --color never",
        help="Options passed to a second colour‑less lsd invocation when CSV target is requested"
    )
    p.add_argument("--keep-temp", action="store_true", help="Do not delete temporary files")
    p.add_argument("-v", "--verbose", action="store_true", help="Chatty output to stderr")
    return p


def main() -> None:
    args = _build_arg_parser().parse_args()
    verbose = args.verbose

    # ------------------------------------------------------------------
    # Acquire raw *text* to convert
    # ------------------------------------------------------------------
    if args.file:
        src_path = pathlib.Path(args.file).expanduser().resolve()
        if not src_path.exists():
            sys.exit(f"[ERROR] File not found: {src_path}")
        if verbose:
            print(f"[INFO] Reading {src_path}", file=sys.stderr)
        # If it's a script and colours are desired, let bat do the highlighting
        if not args.no_colour and _which("bat"):
            bat_cmd = f"bat --style=numbers,grid --color always {src_path}"
            raw_text = _capture_command_output(bat_cmd, colour=True)
        else:
            raw_text = src_path.read_text()
    else:
        raw_text = _capture_command_output(args.command, colour=not args.no_colour)

    # Basename
    base = args.output or (src_path.stem if args.file else "term2doc")
    outdir = pathlib.Path.cwd()

    # ------------------------------------------------------------------
    # Prepare HTML if any of the targets depend on it (pdf/png)
    # ------------------------------------------------------------------
    if any(fmt in ("pdf", "png") for fmt in args.targets):
        if verbose:
            print("[INFO] Rendering ANSI → HTML", file=sys.stderr)
        if args.theme_css:
            theme_css = pathlib.Path(args.theme_css).read_text()
        else:
            theme_css = ""  # can embed Bat CSS here if available
        html_str = _ansi_to_html(raw_text, theme_css=theme_css)
        html_tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".html")
        html_tmp.write(html_str.encode())
        html_tmp.close()
        html_path = pathlib.Path(html_tmp.name)
    else:
        html_path = None  # type: ignore

    # ------------------------------------------------------------------
    # Produce artefacts
    # ------------------------------------------------------------------
    for fmt in args.targets:
        if fmt == "pdf":
            pdf_path = outdir / f"{base}.pdf"
            if verbose:
                print(f"[INFO] Writing {pdf_path}", file=sys.stderr)
            _html_to_pdf(html_path, pdf_path)

        elif fmt == "png":
            png_path = outdir / f"{base}.png"
            if verbose:
                print(f"[INFO] Writing {png_path}", file=sys.stderr)
            _html_to_png(html_path, png_path)

        elif fmt == "md":
            txt_tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".txt")
            txt_tmp.write(raw_text.encode())
            txt_tmp.close()
            md_path = outdir / f"{base}.md"
            if verbose:
                print(f"[INFO] Writing Markdown {md_path}", file=sys.stderr)
            _text_to_markdown(pathlib.Path(txt_tmp.name), md_path)
            if "pdf" in args.targets:
                # We'll convert MD → PDF *also* but only if user explicitly asked for pdf.
                pass

        elif fmt == "csv":
            if pd is None:
                sys.exit("[ERROR] pandas not installed; cannot export CSV")
            # If user supplied lsd output via --command we parse that; else re‑run colour‑less lsd
            if args.command:
                csv_text = raw_text
            else:
                # Need to invoke lsd ourselves
                lsd_opts = args.lsd_csv
                csv_text = _capture_command_output(f"lsd {lsd_opts}", colour=False)
            df = _parse_lsd(csv_text)
            csv_path = outdir / f"{base}.csv"
            if verbose:
                print(f"[INFO] Writing CSV {csv_path}", file=sys.stderr)
            df.to_csv(csv_path, index=False)

        else:
            sys.exit(f"[ERROR] Unsupported target: {fmt}")

    # ------------------------------------------------------------------
    # Clean‑up
    # ------------------------------------------------------------------
    if html_path and not args.keep_temp:
        html_path.unlink(missing_ok=True)

    if verbose:
        print("[INFO] Done.", file=sys.stderr)


if __name__ == "__main__":
    if shutil.which("wkhtmltopdf") is None:
        print("[WARN] wkhtmltopdf not found — PDF generation will fail", file=sys.stderr)
    main()

