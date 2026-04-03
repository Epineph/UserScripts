#!/usr/bin/env python3
"""
annotate_disk_usage.py

Add two columns to a disk_usage_report CSV:

  - mark_delete   : '', 'yes', 'maybe'
  - recursive     : '', 'yes' (only meaningful for dirs)

Heuristics:
  - Anything under a path containing '/.cache/' is pre-marked as 'maybe'.
"""

import csv
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: annotate_disk_usage.py disk_usage_report.csv [out.csv]")
        sys.exit(1)

    in_path = Path(sys.argv[1]).expanduser().resolve()
    out_path = (
        Path(sys.argv[2]).expanduser().resolve()
        if len(sys.argv) >= 3
        else in_path.with_name(in_path.stem + "_annotated.csv")
    )

    with (
        in_path.open("r", encoding="utf-8", newline="") as f_in,
        out_path.open("w", encoding="utf-8", newline="") as f_out,
    ):
        reader = csv.DictReader(f_in)
        fieldnames = reader.fieldnames + ["mark_delete", "recursive"]
        writer = csv.DictWriter(f_out, fieldnames=fieldnames)
        writer.writeheader()

        for row in reader:
            path = row.get("path", "")
            kind = row.get("kind", "")
            mark = ""
            rec = ""

            if "/.cache/" in path:
                mark = "maybe"
                if kind == "dir":
                    rec = "yes"

            row["mark_delete"] = mark
            row["recursive"] = rec
            writer.writerow(row)

    print(f"Annotated CSV written to: {out_path}")


if __name__ == "__main__":
    main()
