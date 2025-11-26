#!/usr/bin/env python3
# ──────────────────────────────────────────────────────────────────────────────
# vacay.py — store and compare flight options within a vacation window
# ──────────────────────────────────────────────────────────────────────────────
"""
Store candidate flights for a given vacation period and list/sort them by
price and travel time.

Data file (default):
  ~/.local/share/vacay/flights.json

Subcommands:
  add   — add a new flight option
  list  — list stored flight options with computed durations
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, asdict
from datetime import date, datetime
from pathlib import Path
from typing import List, Optional


# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────

VACATION_START = date(2025, 1, 19)
VACATION_END = date(2025, 1, 31)

DATA_FILE = Path.home() / ".local" / "share" / "vacay" / "flights.json"


# ──────────────────────────────────────────────────────────────────────────────
# Data model
# ──────────────────────────────────────────────────────────────────────────────


@dataclass
class Direction:
    """One direction of travel (outbound or return)."""

    depart_iso: str  # "YYYY-MM-DDTHH:MM"
    arrive_iso: str  # "YYYY-MM-DDTHH:MM"
    stops: int  # 0 = direct, 1 = one stop, etc.

    def depart_dt(self) -> datetime:
        return datetime.fromisoformat(self.depart_iso)

    def arrive_dt(self) -> datetime:
        return datetime.fromisoformat(self.arrive_iso)


@dataclass
class FlightOption:
    """A complete flight option (one-way or return)."""

    id: int
    label: str
    price: float
    currency: str
    is_return: bool
    out: Direction
    back: Optional[Direction] = None
    provider: str = ""
    notes: str = ""

    # ---- derived quantities ---------------------------------------------------

    def out_duration(self):
        return self.out.arrive_dt() - self.out.depart_dt()

    def back_duration(self):
        if self.back is None:
            return None
        return self.back.arrive_dt() - self.back.depart_dt()

    def total_duration(self):
        """Total door-to-door duration (outbound + return if present)."""
        total = self.out_duration()
        back = self.back_duration()
        if back is not None:
            total += back
        return total


# ──────────────────────────────────────────────────────────────────────────────
# Persistence helpers
# ──────────────────────────────────────────────────────────────────────────────


def _ensure_data_dir() -> None:
    DATA_FILE.parent.mkdir(parents=True, exist_ok=True)


def load_db() -> List[FlightOption]:
    if not DATA_FILE.exists():
        return []
    with DATA_FILE.open("r", encoding="utf-8") as f:
        raw = json.load(f)

    flights: List[FlightOption] = []
    for item in raw:
        out = Direction(**item["out"])
        back_raw = item.get("back")
        back = Direction(**back_raw) if back_raw else None
        flights.append(
            FlightOption(
                id=item["id"],
                label=item["label"],
                price=item["price"],
                currency=item["currency"],
                is_return=bool(item["is_return"]),
                out=out,
                back=back,
                provider=item.get("provider", ""),
                notes=item.get("notes", ""),
            )
        )
    return flights


def save_db(flights: List[FlightOption]) -> None:
    _ensure_data_dir()
    serializable = []
    for f in flights:
        # dataclasses → dict
        d = asdict(f)
        serializable.append(d)
    with DATA_FILE.open("w", encoding="utf-8") as out:
        json.dump(serializable, out, indent=2, sort_keys=True)


# ──────────────────────────────────────────────────────────────────────────────
# Utility functions
# ──────────────────────────────────────────────────────────────────────────────


def new_id(flights: List[FlightOption]) -> int:
    if not flights:
        return 1
    return max(f.id for f in flights) + 1


def parse_iso_datetime(value: str) -> datetime:
    """
    Parse "YYYY-MM-DDTHH:MM" into datetime.
    Example: 2025-01-20T10:25
    """
    try:
        return datetime.fromisoformat(value)
    except ValueError as exc:
        msg = f"Invalid datetime '{value}', expected YYYY-MM-DDTHH:MM"
        raise argparse.ArgumentTypeError(msg) from exc


def format_duration(delta) -> str:
    """Return duration as 'Xh Ym'."""
    total_minutes = int(delta.total_seconds() // 60)
    hours, minutes = divmod(total_minutes, 60)
    return f"{hours:d}h {minutes:02d}m"


def in_vacation_window(dt: datetime) -> bool:
    return VACATION_START <= dt.date() <= VACATION_END


def reject_outside_window(
    *dts: datetime,
    force: bool,
) -> None:
    if force:
        return
    for dt in dts:
        if dt is None:
            continue
        if not in_vacation_window(dt):
            msg = (
                f"Error: datetime {dt.isoformat()} is outside vacation window "
                f"{VACATION_START}–{VACATION_END}. Use --force to override."
            )
            print(msg, file=sys.stderr)
            sys.exit(1)


# ──────────────────────────────────────────────────────────────────────────────
# Command handlers
# ──────────────────────────────────────────────────────────────────────────────


def cmd_add(args: argparse.Namespace) -> None:
    flights = load_db()

    out_depart = parse_iso_datetime(args.out_depart)
    out_arrive = parse_iso_datetime(args.out_arrive)

    back_depart = parse_iso_datetime(args.return_depart) if args.return_depart else None
    back_arrive = parse_iso_datetime(args.return_arrive) if args.return_arrive else None

    reject_outside_window(
        out_depart, out_arrive, back_depart, back_arrive, force=args.force
    )

    out_dir = Direction(
        depart_iso=out_depart.isoformat(timespec="minutes"),
        arrive_iso=out_arrive.isoformat(timespec="minutes"),
        stops=args.out_stops,
    )

    back_dir = None
    is_return = bool(back_depart and back_arrive)
    if is_return:
        back_dir = Direction(
            depart_iso=back_depart.isoformat(timespec="minutes"),
            arrive_iso=back_arrive.isoformat(timespec="minutes"),
            stops=args.return_stops,
        )

    flight = FlightOption(
        id=new_id(flights),
        label=args.label,
        price=args.price,
        currency=args.currency,
        is_return=is_return,
        out=out_dir,
        back=back_dir,
        provider=args.provider or "",
        notes=args.notes or "",
    )

    flights.append(flight)
    save_db(flights)

    print(f"Added option #{flight.id}: {flight.label}")


def cmd_list(args: argparse.Namespace) -> None:
    flights = load_db()
    if not flights:
        print("No flights stored yet.")
        return

    # filter
    if args.direct_only:
        flights = [
            f
            for f in flights
            if f.out.stops == 0 and (not f.is_return or (f.back and f.back.stops == 0))
        ]

    if args.within_window:

        def leg_in_window(dir_: Direction) -> bool:
            return in_vacation_window(dir_.depart_dt()) and in_vacation_window(
                dir_.arrive_dt()
            )

        flights = [
            f
            for f in flights
            if leg_in_window(f.out)
            and (not f.is_return or (f.back and leg_in_window(f.back)))
        ]

    if not flights:
        print("No flights match the given filters.")
        return

    # sort
    if args.sort == "price":
        flights.sort(key=lambda f: f.price)
    elif args.sort == "out-duration":
        flights.sort(key=lambda f: f.out_duration())
    elif args.sort == "total-duration":
        flights.sort(key=lambda f: f.total_duration())
    elif args.sort == "out-depart":
        flights.sort(key=lambda f: f.out.depart_dt())

    # print
    for f in flights:
        out_dep = f.out.depart_dt()
        out_arr = f.out.arrive_dt()
        out_dur = format_duration(f.out_duration())

        print("=" * 72)
        print(
            f"#{f.id} — {f.label} | {f.price:.0f} {f.currency} | "
            f"{'return' if f.is_return else 'one-way'}"
        )

        if f.provider:
            print(f"  Provider : {f.provider}")
        if f.notes:
            print(f"  Notes    : {f.notes}")

        print(
            f"  Outbound : {out_dep:%Y-%m-%d %H:%M} → {out_arr:%Y-%m-%d %H:%M}  "
            f"({out_dur}, {f.out.stops} stops)"
        )

        if f.is_return and f.back:
            back_dep = f.back.depart_dt()
            back_arr = f.back.arrive_dt()
            back_dur = format_duration(f.back_duration())
            total_dur = format_duration(f.total_duration())
            print(
                f"  Return   : {back_dep:%Y-%m-%d %H:%M} → {back_arr:%Y-%m-%d %H:%M}  "
                f"({back_dur}, {f.back.stops} stops)"
            )
            print(f"  Total trip duration (door-to-door, both legs): {total_dur}")
        else:
            print(f"  Total trip duration (outbound only): {out_dur}")

    print("=" * 72)
    print(f"{len(flights)} option(s) listed.")


# ──────────────────────────────────────────────────────────────────────────────
# CLI
# ──────────────────────────────────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="vacay",
        description=(
            "Store and compare flight options within a fixed vacation window. "
            "Datetimes use ISO format: YYYY-MM-DDTHH:MM"
        ),
    )

    sub = parser.add_subparsers(dest="command", required=True)

    # add
    p_add = sub.add_parser(
        "add",
        help="Add a new flight option",
    )
    p_add.add_argument(
        "--label",
        required=True,
        help="Short human-readable label for this option",
    )
    p_add.add_argument(
        "--price",
        type=float,
        required=True,
        help="Total price for the ticket(s)",
    )
    p_add.add_argument(
        "--currency",
        default="DKK",
        help="Currency code (default: DKK)",
    )

    p_add.add_argument(
        "--out-depart",
        required=True,
        help="Outbound departure datetime (YYYY-MM-DDTHH:MM)",
    )
    p_add.add_argument(
        "--out-arrive",
        required=True,
        help="Outbound arrival datetime (YYYY-MM-DDTHH:MM)",
    )
    p_add.add_argument(
        "--out-stops",
        type=int,
        default=0,
        help="Number of stops on outbound leg (0 = direct)",
    )

    p_add.add_argument(
        "--return-depart",
        help="Return departure datetime (YYYY-MM-DDTHH:MM); omit for one-way",
    )
    p_add.add_argument(
        "--return-arrive",
        help="Return arrival datetime (YYYY-MM-DDTHH:MM); omit for one-way",
    )
    p_add.add_argument(
        "--return-stops",
        type=int,
        default=0,
        help="Number of stops on return leg (0 = direct)",
    )

    p_add.add_argument(
        "--provider",
        default="",
        help="Airline or booking site (optional)",
    )
    p_add.add_argument(
        "--notes",
        default="",
        help="Free-form notes (baggage, refundability, etc.)",
    )
    p_add.add_argument(
        "--force",
        action="store_true",
        help=(
            "Allow dates outside the configured vacation window "
            f"({VACATION_START}–{VACATION_END})"
        ),
    )
    p_add.set_defaults(func=cmd_add)

    # list
    p_list = sub.add_parser(
        "list",
        help="List stored flight options",
    )
    p_list.add_argument(
        "--sort",
        choices=["price", "out-duration", "total-duration", "out-depart"],
        default="price",
        help="Sort key (default: price)",
    )
    p_list.add_argument(
        "--direct-only",
        action="store_true",
        help="Only show options where both legs are direct (0 stops)",
    )
    p_list.add_argument(
        "--within-window",
        action="store_true",
        help="Only show options fully within vacation window",
    )
    p_list.set_defaults(func=cmd_list)

    return parser


def main(argv: Optional[List[str]] = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
