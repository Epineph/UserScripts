"""Optional fd/fzf file selection shared by the transfer scripts.

Keep this module alongside the scripts when using --interactive. Records are
NUL-delimited and carry encoded file identities; previews decode these without
inserting filenames into shell commands.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

# -- Errors and discovery ------------------------------------------------------

def fail(message: str, exit_code: int = 2) -> None:
  print(message, file=sys.stderr)
  raise SystemExit(exit_code)


def normalized_extensions(extensions: list[str]) -> list[str]:
  """Accept png or .png, including compound extensions such as tar.gz."""
  result: list[str] = []
  for value in extensions:
    extension = value.lstrip(".")
    if not extension or any(char in extension for char in "/\\*?[]\x00"):
      fail(f"Error: invalid extension {value!r}; use e.g. -e png or -e tar.gz.")
    result.append(extension)
  return result


def discover_files(
  fd: str,
  sources: list[Path],
  args: argparse.Namespace,
) -> list[Path]:
  """Discover regular files and include explicitly supplied matching files."""
  extensions = normalized_extensions(args.extension)
  directories: list[Path] = []
  candidates: list[Path] = []

  for source in sources:
    source = Path(os.path.abspath(source.expanduser()))
    if source.is_dir():
      directories.append(source)
    elif source.is_file():
      candidates.append(source)
    else:
      fail(f"Error: picker source is not a regular file or directory: {source}")

  if directories:
    command = [
      fd, "--type", "f", "--absolute-path", "--print0",
      "--color", "never", "--ignore-case",
    ]
    if args.hidden:
      command.append("--hidden")
    if args.no_ignore:
      command.append("--no-ignore")
    command.extend(["--", "", *map(str, directories)])
    result = subprocess.run(command, capture_output=True, check=False)
    if result.returncode != 0:
      message = os.fsdecode(result.stderr).strip()
      fail(f"Error: fd discovery failed (exit {result.returncode}): {message}")
    candidates.extend(
      Path(os.fsdecode(value)) for value in result.stdout.split(b"\0") if value
    )

  # fd's extension regex can miss a newline or non-UTF-8 byte before the dot.
  # Filter here, preserving all filesystem names and deduplicating search roots.
  return [
    path for path in dict.fromkeys(candidates)
    if not extensions or any(
      path.name.casefold().endswith(f".{extension.casefold()}")
      for extension in extensions
    )
  ]


# -- Interactive selection -----------------------------------------------------

def select_files(
  args: argparse.Namespace,
  *,
  sources: list[Path],
  multiple: bool,
) -> list[Path]:
  """Return selected files, or exit before the caller starts an operation."""
  fd = shutil.which("fd") or shutil.which("fdfind")
  fzf = shutil.which("fzf")
  missing = [name for name, path in (("fd", fd), ("fzf", fzf)) if not path]
  if missing:
    fail(
      "Error: --interactive requires fd and fzf on PATH. Missing: "
      + ", ".join(missing)
      + ".\nOn Arch Linux: sudo pacman -S fd fzf (bat is optional)."
    )
  if not sys.stdin.isatty():
    fail("Error: --interactive requires a terminal on standard input.")

  try:
    candidates = discover_files(fd, sources, args)
    if not candidates:
      fail("No matching files found; no files were changed.", 1)

    command = [
      fzf, "--read0", "--print0", "--layout=reverse", "--border",
      "--delimiter=\t", "--with-nth=2..",
      "--prompt=Files> ",
      "--bind=enter:accept,esc:abort,ctrl-c:abort",
    ]
    if multiple:
      command.extend([
        "--multi",
        (
          "--bind=tab:toggle+down,shift-tab:toggle+up,"
          "shift-left-click:toggle,ctrl-a:select-all,ctrl-d:deselect-all"
        ),
        (
          "--header=Tab / Shift-click: mark | Ctrl-A: all | Ctrl-D: clear | "
          "Enter: accept | Esc: cancel"
        ),
      ])
    else:
      command.extend([
        "--no-multi",
        "--header=Select one source file | Enter: accept | Esc: cancel",
      ])

    bat = shutil.which("bat") or shutil.which("batcat")
    if not args.no_preview and bat:
      # Decode the identity in Python so even non-UTF-8 filenames reach bat.
      preview_code = (
        "import base64,subprocess,sys; "
        "subprocess.run([sys.argv[1], '--color=always', '--paging=never', "
        "'--style=numbers', '--line-range=:300', '--', "
        "base64.b64decode(sys.argv[2])], check=False)"
      )
      preview = shlex.join([sys.executable, "-c", preview_code, bat]) + " {1}"
      command.extend([
        f"--preview={preview}", "--preview-window=right:50%:wrap",
        "--bind=ctrl-p:toggle-preview",
      ])
    elif not args.no_preview:
      print(
        "Warning: bat was not found on PATH; continuing without previews.",
        file=sys.stderr,
      )

    env = os.environ.copy()
    # Global options can auto-accept files or change the returned path format.
    # Require an explicit selection with the bindings and output format above.
    env.pop("FZF_DEFAULT_OPTS", None)
    env.pop("FZF_DEFAULT_OPTS_FILE", None)
    env["SHELL"] = "/bin/sh"
    # fzf replaces invalid UTF-8. Hide an ASCII identity ahead of each label,
    # escaping label controls so tabs/newlines cannot change the record format.
    identities = {
      base64.b64encode(os.fsencode(path)): path for path in candidates
    }
    records = []
    for identity, path in identities.items():
      label = json.dumps(str(path), ensure_ascii=False)[1:-1]
      records.append(identity + b"\t" + label.encode("utf-8", "backslashreplace"))
    result = subprocess.run(
      command,
      input=b"\0".join(records) + b"\0",
      stdout=subprocess.PIPE,
      env=env,
      check=False,
    )
  except KeyboardInterrupt:
    fail("Selection cancelled; no files were changed.", 130)
  except OSError as error:
    fail(f"Error: could not run the file picker: {error}")

  if result.returncode in (130, -2):
    fail("Selection cancelled; no files were changed.", 130)
  if result.returncode == 1:
    fail("No files selected; no files were changed.", 1)
  if result.returncode != 0:
    fail(f"Error: fzf failed (exit {result.returncode}); operation aborted.")
  if not result.stdout:
    fail("No files selected; no files were changed.", 1)
  if not result.stdout.endswith(b"\0"):
    fail("Error: fzf returned an invalid selection; operation aborted.")

  selected_ids = list(dict.fromkeys(
    value.partition(b"\t")[0] for value in result.stdout.split(b"\0") if value
  ))
  if not selected_ids or (not multiple and len(selected_ids) != 1):
    fail("Error: expected exactly one source file; operation aborted.")
  if any(identity not in identities for identity in selected_ids):
    fail("Error: fzf returned an unknown file identity; operation aborted.")
  selected = [identities[identity] for identity in selected_ids]
  for path in selected:
    if not path.is_file():
      fail(f"Error: selected file is unavailable: {path}")
  return selected
