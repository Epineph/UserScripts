#!/usr/bin/env python3
"""
hunspell_autocorrect.py — naive "best guess" auto-correct using hunspell.

Reads text from stdin and prints corrected text to stdout, replacing unknown
words by the first suggestion hunspell returns.

Example:
  echo "Det her er en teskt" | hunspell_autocorrect.py -d da_DK
  echo "Bu bir sınav cümlesi" | hunspell_autocorrect.py -d tr_TR
"""

import argparse
import re
import subprocess
import sys
from typing import Optional

WORD_RE = re.compile(r"\w+", re.UNICODE)


def parse_suggestion_line(line: str) -> Optional[str]:
    """
    Parse a hunspell '-a' protocol line and return first suggestion, or None.

    Examples:
      "& teskt 5 14: text, test, teske, beskt, tyktes"
      "? teskt 2 14: text, test"
    """
    line = line.strip()
    if not line or line[0] not in ("&", "?"):
        return None
    parts = line.split(":", 1)
    if len(parts) != 2:
        return None
    sugg_part = parts[1].strip()
    if not sugg_part:
        return None
    first = sugg_part.split(",", 1)[0].strip()
    return first or None


def match_case(suggestion: str, original: str) -> str:
    """
    Rough case preservation:
      - "WORD" -> "SUGGESTION"
      - "Word" -> "Suggestion"
      - else   -> "suggestion"
    """
    if original.isupper():
        return suggestion.upper()
    if original[:1].isupper():
        return suggestion.capitalize()
    return suggestion


class HunspellSession:
    """Persistent hunspell -a process to avoid restarting for every word."""

    def __init__(self, dictionary: str):
        self.proc = subprocess.Popen(
            ["hunspell", "-a", "-d", dictionary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        # First line is a header like "Hunspell 1.7.2"
        _ = self.proc.stdout.readline()

    def suggest(self, word: str) -> Optional[str]:
        """Return best suggestion for $(word), or None if hunspell is happy."""
        if not self.proc or not self.proc.stdin or not self.proc.stdout:
            return None

        # Send word to hunspell
        self.proc.stdin.write(word + "\n")
        self.proc.stdin.flush()

        suggestion = None

        # -a protocol: responses for each word end with a blank line
        while True:
            line = self.proc.stdout.readline()
            if not line:
                break  # EOF
            if line.strip() == "":
                break  # end of this word's block

            first_char = line[0]
            if first_char in ("*", "+", "-"):
                # * correct, + root form, - forbidden word → no change
                suggestion = None
            elif first_char in ("&", "?"):
                cand = parse_suggestion_line(line)
                if cand:
                    suggestion = cand
        return suggestion

    def close(self) -> None:
        try:
            if self.proc and self.proc.stdin:
                self.proc.stdin.write("\n")
                self.proc.stdin.flush()
                self.proc.stdin.close()
        except Exception:
            pass
        if self.proc:
            self.proc.terminate()


def process_line(line: str, session: HunspellSession) -> str:
    """
    Tokenize line into words / whitespace / punctuation, auto-correct words.
    """
    tokens = re.findall(r"\w+|\s+|[^\w\s]", line, flags=re.UNICODE)
    out_tokens = []

    for tok in tokens:
        if WORD_RE.fullmatch(tok):
            suggestion = session.suggest(tok)
            if suggestion:
                suggestion = match_case(suggestion, tok)
                out_tokens.append(suggestion)
            else:
                out_tokens.append(tok)
        else:
            out_tokens.append(tok)

    return "".join(out_tokens)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Naive autocorrect wrapper around hunspell."
    )
    parser.add_argument(
        "-d",
        "--dict",
        default="en_GB",
        help="Hunspell dictionary name (e.g. da_DK, tr_TR, en_GB)",
    )
    args = parser.parse_args()

    session = HunspellSession(args.dict)

    try:
        for line in sys.stdin:
            corrected = process_line(line, session)
            sys.stdout.write(corrected)
    except BrokenPipeError:
        # Allow use in pipelines without ugly traceback.
        pass
    finally:
        session.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
