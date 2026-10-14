#!/usr/bin/env python3
"""Print selected one-based lines from standard input."""

import argparse
import re
import sys


def parse_number(value):
    """Parse a positive line number, raising a useful CLI error otherwise."""
    try:
        number = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(
            f"{value!r} is not a positive line number"
        ) from error

    if number < 1:
        raise argparse.ArgumentTypeError("line numbers must be at least 1")
    return number


def parse_selectors(values):
    """Parse absolute selectors such as '1, 4 7 10-19'."""
    selected = set()
    for value in values:
        for token in value.split(","):
            token = token.strip()
            if not token:
                continue

            match = re.fullmatch(r"(\d+)(?:\s*-\s*(\d+))?", token)
            if match is None:
                raise argparse.ArgumentTypeError(
                    f"invalid line selector: {token!r}"
                )

            start = parse_number(match.group(1))
            end = parse_number(match.group(2)) if match.group(2) else start
            low, high = sorted((start, end))
            selected.update(range(low, high + 1))
    return selected


def parse_range(value):
    """Parse an inclusive range of distances back from the input's end."""
    match = re.fullmatch(r"\s*(\d+)\s*:\s*(\d+)\s*", value)
    if match is None:
        raise argparse.ArgumentTypeError(
            "range must be written as FROM:TO, for example 800:500"
        )

    return parse_number(match.group(1)), parse_number(match.group(2))


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Print selected one-based lines from standard input. "
            "Line selectors count from the start; --range counts "
            "backward from the end."
        ),
        epilog=(
            "Examples:\n"
            "  command | lines 1, 4 7 10-19\n"
            "  command | lines --from 800 --to 500\n"
            "  command | lines --range 800:500"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "selectors",
        nargs="*",
        metavar="LINE[,LINE|START-END]",
        help="absolute line numbers or inclusive ranges (one-based)",
    )
    parser.add_argument(
        "--from",
        dest="from_end",
        type=parse_number,
        metavar="N",
        help="start N lines back from the end (requires --to)",
    )
    parser.add_argument(
        "--to",
        dest="to_end",
        type=parse_number,
        metavar="N",
        help="end N lines back from the end (requires --from)",
    )
    parser.add_argument(
        "--range",
        type=parse_range,
        metavar="FROM:TO",
        help="select an inclusive range counted back from the end",
    )
    args = parser.parse_args()

    if (args.from_end is None) != (args.to_end is None):
        parser.error("--from and --to must be used together")
    if args.range is not None and args.from_end is not None:
        parser.error("use either --range or --from/--to, not both")
    if not args.selectors and args.range is None and args.from_end is None:
        parser.error("provide line selectors or a range")

    try:
        selected = parse_selectors(args.selectors)
    except argparse.ArgumentTypeError as error:
        parser.error(str(error))

    relative_range = args.range
    if args.from_end is not None:
        relative_range = args.from_end, args.to_end

    lines = sys.stdin.buffer.readlines()
    line_count = len(lines)

    if relative_range is not None:
        first, last = relative_range
        low, high = sorted((first, last))
        # A distance of 1 denotes the final input line.
        selected.update(
            line_count - distance + 1
            for distance in range(low, high + 1)
        )

    sys.stdout.buffer.writelines(
        line for number, line in enumerate(lines, start=1) if number in selected
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
