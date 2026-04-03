#!/usr/bin/env bash

python - <<'PY'
import re, sys, pathlib

path = pathlib.Path(sys.argv[1])
s = path.read_text(encoding="utf-8", errors="replace").splitlines()

out = []
for line in s:
  line = line.strip()
  if not line:
    continue
  if re.fullmatch(r"\d+", line):
    continue
  if re.match(r"\d\d:\d\d:\d\d[,.]\d+\s+-->\s+\d\d:\d\d:\d\d[,.]\d+", line):
    continue
  out.append(line)

txt = "\n".join(out)
print(txt)
PY "Veritasium-What-is-Reality.en-GB.srt" > transcript.txt

