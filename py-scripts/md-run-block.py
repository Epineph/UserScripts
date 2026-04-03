#!/usr/bin/env python3
import sys
import re
import subprocess
import tempfile
from pathlib import Path


def find_block(path: Path, target_line: int):
    blocks = []
    in_block = False
    start = None
    lang = ""

    with path.open("r", encoding="utf-8") as f:
        for i, line in enumerate(f, start=1):
            m = re.match(r"^```(\w*)\s*$", line)
            if m:
                tag = m.group(1)
                if not in_block:
                    in_block = True
                    start = i
                    lang = tag or ""
                else:
                    # closing fence
                    blocks.append((start, i, lang))
                    in_block = False
                    start = None
                    lang = ""

    for s, e, lang in blocks:
        if s < target_line < e:
            return s, e, lang

    return None


def pick_interpreter(lang: str):
    lang = (lang or "").lower()
    if lang in ("bash", "sh", ""):
        return ["bash"]
    if lang in ("python", "py"):
        return ["python3"]
    if lang in ("r",):
        return ["Rscript"]
    raise SystemExit(f"Unsupported or unknown language tag: {lang!r}")


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <file> <line_number>", file=sys.stderr)
        sys.exit(1)

    path = Path(sys.argv[1])
    try:
        target_line = int(sys.argv[2])
    except ValueError:
        print("Line number must be an integer.", file=sys.stderr)
        sys.exit(1)

    if not path.is_file():
        print(f"File not found: {path}", file=sys.stderr)
        sys.exit(1)

    res = find_block(path, target_line)
    if res is None:
        print(
            f"No fenced code block found containing line {target_line}.",
            file=sys.stderr,
        )
        sys.exit(1)

    start, end, lang = res
    print(f"Found block: lines {start}-{end}, lang={lang!r}", file=sys.stderr)

    with path.open("r", encoding="utf-8") as f:
        lines = f.readlines()[start : end - 1]  # between fences

    interpreter = pick_interpreter(lang)

    with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as tmp:
        tmp_path = Path(tmp.name)
        tmp.writelines(lines)

    try:
        cmd = interpreter + [str(tmp_path)]
        print(f"Running: {' '.join(cmd)}", file=sys.stderr)
        result = subprocess.run(cmd)
        sys.exit(result.returncode)
    finally:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
