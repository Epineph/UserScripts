#!/usr/bin/env python3
"""
format_sh.py — A simple shell-script formatter

This tool enforces:
  • Maximum line width (default 80 characters).
  • Backslash continuation for wrapped commands.
  • Normalized spacing after comment markers (#).
  • Automatic wrapping of long inline comments, continuing with additional comment lines.

Usage:
    format_sh.py [-h] [-w WIDTH] input_file [output_file]

Example:
    # In-place (auto-backup under ~/.logs/scripts/YYYY-MM-DD/HH-MM-SS)
    format_sh.py -w 100 ~/.zsh_profile/zsh_plugins.zsh

    # Write to a separate file (no backup)
    format_sh.py ~/.zsh_profile/zsh_plugins.zsh formatted_plugins.zsh
"""
import argparse
import re
import sys
import textwrap
import shutil
from pathlib import Path
from datetime import datetime

def parse_args():
    parser = argparse.ArgumentParser(
        description="Wrap and align shell scripts to a standard style"
    )
    parser.add_argument(
        "input_file", type=Path,
        help="Path to the shell script to format"
    )
    parser.add_argument(
        "output_file", type=Path, nargs="?",
        help="Optional path to write the formatted script; if omitted, input is amended (with backup)"
    )
    parser.add_argument(
        "-w", "--width", type=int, default=80,
        help="Maximum line width before wrapping (default: 80)"
    )
    return parser.parse_args()

def split_comment(line):
    match = re.search(r'(?<!\\)#', line)
    if not match:
        return line.rstrip(), ''
    idx = match.start()
    code = line[:idx].rstrip()
    comment_text = line[idx+1:].lstrip()
    return code, comment_text

def wrap_code(code, width, indent_str):
    if len(code) <= width:
        return [code]
    subsequent_indent = indent_str + '    '
    wrapped = textwrap.wrap(
        code,
        width=width,
        initial_indent=indent_str,
        subsequent_indent=subsequent_indent,
        break_long_words=False,
        break_on_hyphens=False
    )
    return [line + ' \\' for line in wrapped[:-1]] + [wrapped[-1]]

def wrap_comment(text, width, indent_str):
    max_comment_width = width - len(indent_str) - 2
    lines = textwrap.wrap(
        text,
        width=max_comment_width,
        break_long_words=False,
        break_on_hyphens=False
    )
    return [f"{indent_str}# {line}" for line in lines]

def process_file(path, width):
    output = []
    for raw in path.read_text().splitlines():
        code, comment = split_comment(raw)
        indent_match = re.match(r'(\s*)', code)
        indent_str = indent_match.group(1) if indent_match else ''
        code_lines = wrap_code(code, width, indent_str) if code else ['']
        if comment:
            inline = f"{code_lines[-1]}  # {comment}".rstrip()
            if len(inline) <= width:
                code_lines[-1] = inline
            else:
                fragments = wrap_comment(comment, width, indent_str)
                code_lines[-1] = f"{code_lines[-1]}  {fragments[0].lstrip()}"
                for frag in fragments[1:]:
                    output.append(frag)
        output.extend(code_lines)
    return output

def main():
    args = parse_args()
    formatted = process_file(args.input_file, args.width)

    # Determine destination
    dest = args.output_file or args.input_file

    # If in-place, backup under ~/.logs/scripts/YYYY-MM-DD/HH-MM-SS
    if args.output_file is None:
        now = datetime.now()
        date_str = now.strftime('%Y-%m-%d')
        time_str = now.strftime('%H-%M-%S')
        backup_dir = Path.home() / '.logs' / 'scripts' / date_str / time_str
        backup_dir.mkdir(parents=True, exist_ok=True)
        backup_path = backup_dir / f"{args.input_file.name}.bak"
        shutil.copy2(args.input_file, backup_path)
        print(f"[INFO] Backed up original to: {backup_path}")
        print(f"[INFO] Writing formatted script to: {args.input_file}")
    else:
        print(f"[INFO] Writing formatted script to: {dest}")

    text = "\n".join(formatted) + "\n"
    Path(dest).write_text(text)

if __name__ == '__main__':
    main()

