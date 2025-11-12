#!/usr/bin/env python3
"""
Binary size utilities (IEC: B, KiB, MiB, GiB).

This module provides:
  - sum_binary_bytes(...): sum arbitrary inputs into an exact integer byte total.
  - format_binary_size_full(...): "full expansion" formatter (GiB MiB KiB bytes).
  - format_binary_size_remainder(...): optional remainder-style formatter (largest unit + one remainder tier).

Design notes:
  • Parsing accepts tokens like "512B", "2 KiB", "1.5GiB" and keyword parts
    (bytes/b, kib/kb, mib/mb, gib/gb).
  • All arithmetic is done in integer bytes. Fractional units are FLOORed to bytes.
  • KB/MB/GB are intentionally mapped to KiB/MiB/GiB to eliminate decimal drift.
"""
from __future__ import annotations
import re
from typing import Union

Number = Union[int, float]

# ---------------------------- Core constants ---------------------------------
IEC = {
    "B":   1,
    "KiB": 1 << 10,             # 1024
    "MiB": 1 << 20,             # 1,048,576
    "GiB": 1 << 30,             # 1,073,741,824
}

# Case-insensitive aliases; KB/MB/GB → KiB/MiB/GiB (binary)
ALIASES = {
    "b": "B", "byte": "B", "bytes": "B",
    "kb": "KiB", "kib": "KiB", "k": "KiB",
    "mb": "MiB", "mib": "MiB", "m": "MiB",
    "gb": "GiB", "gib": "GiB", "g": "GiB",
    "kibibyte": "KiB", "kibibytes": "KiB",
    "mebibyte": "MiB", "mebibytes": "MiB",
    "gibibyte": "GiB", "gibibytes": "GiB",
}

TOKEN_RE = re.compile(
    r"""^\s*
        (?P<value>[-+]?\d+(?:\.\d+)?)     # integer or float
        \s*
        (?P<unit>[a-zA-Z]+)               # unit token
        \s*$
    """,
    re.VERBOSE,
)

# ---------------------------- Parsing helpers --------------------------------
def _normalize_unit(u: str) -> str:
    """Map many spellings to canonical IEC tokens."""
    key = u.strip().lower()
    if key in ALIASES:
        return ALIASES[key]
    if key in ("b", "kib", "mib", "gib"):
        return {"b": "B", "kib": "KiB", "mib": "MiB", "gib": "GiB"}[key]
    raise ValueError(f"Unknown unit: {u!r}. Allowed: B/KiB/MiB/GiB (KB/MB/GB map to binary).")

def _to_bytes(value: Number, unit: str) -> int:
    """Convert value@unit → integer bytes (floor fractional bytes)."""
    if value < 0:
        raise ValueError("Sizes must be non-negative.")
    mult = IEC[_normalize_unit(unit)]
    return int(float(value) * mult)  # floor via int()

def _parse_token(token: str) -> int:
    """Parse a token like '2048B' or '1.5 GiB' to bytes."""
    m = TOKEN_RE.match(token)
    if not m:
        raise ValueError(f"Could not parse token {token!r}. Example: '512B', '2 KiB', '1.5GiB'.")
    val = float(m.group("value"))
    unit = m.group("unit")
    return _to_bytes(val, unit)

# ------------------------------ Core API -------------------------------------
def sum_binary_bytes(
    *parts: Union[str, Number],
    bytes: Number = 0,  # also accepts: b=, kib=, mib=, gib= (and kb/mb/gb as binary)
    b: Number = 0,
    kib: Number = 0, kb: Number = 0,
    mib: Number = 0, mb: Number = 0,
    gib: Number = 0, gb: Number = 0,
) -> int:
    """
    Sum any combination of B/KiB/MiB/GiB into an exact integer byte total.

    Accepts positional tokens (e.g., "1 GiB", "512 MiB", 1536) and keyword parts.
    Bare numbers in *parts are interpreted as bytes.

    Returns
    -------
    int
        Exact total in bytes (non-negative).
    """
    total = 0

    for p in parts:
        if isinstance(p, (int, float)):
            total += _to_bytes(p, "B")
        elif isinstance(p, str):
            total += _parse_token(p)
        else:
            raise TypeError(f"Unsupported part type: {type(p).__name__}")

    total += _to_bytes(bytes, "B") + _to_bytes(b, "B")
    total += _to_bytes(kib, "KiB") + _to_bytes(kb, "KiB")
    total += _to_bytes(mib, "MiB") + _to_bytes(mb, "MiB")
    total += _to_bytes(gib, "GiB") + _to_bytes(gb, "GiB")
    return int(total)

def format_binary_size_full(
    *parts: Union[str, Number],
    bytes: Number = 0, b: Number = 0,
    kib: Number = 0, kb: Number = 0,
    mib: Number = 0, mb: Number = 0,
    gib: Number = 0, gb: Number = 0,
) -> str:
    """
    Full expansion formatter: show GiB MiB KiB bytes, omitting zero tiers.

    Examples
    --------
    >>> format_binary_size_full("1536B")
    '1 KiB 512 bytes (= 1536 bytes)'
    >>> format_binary_size_full(gib=1, mib=512, kib=600)
    '1 GiB 512 MiB 600 KiB (= 1611661312 bytes)'
    """
    total = sum_binary_bytes(
        *parts, bytes=bytes, b=b, kib=kib, kb=kb, mib=mib, mb=mb, gib=gib, gb=gb
    )
    B, KiB, MiB, GiB = IEC["B"], IEC["KiB"], IEC["MiB"], IEC["GiB"]

    # Decompose total into GiB/MiB/KiB/bytes
    g, r = divmod(total, GiB)
    m, r = divmod(r, MiB)
    k, r = divmod(r, KiB)  # r is now bytes

    parts_out = []
    if g: parts_out.append(f"{g} GiB")
    if m: parts_out.append(f"{m} MiB")
    if k: parts_out.append(f"{k} KiB")
    if r or not parts_out:  # always show something; if total==0, show "0 bytes"
        parts_out.append(f"{r} bytes")

    return f"{' '.join(parts_out)} (= {total} bytes)"

# Optional: provide the remainder-style here for symmetry with your earlier version.
def format_binary_size_remainder(
    *parts: Union[str, Number],
    bytes: Number = 0, b: Number = 0,
    kib: Number = 0, kb: Number = 0,
    mib: Number = 0, mb: Number = 0,
    gib: Number = 0, gb: Number = 0,
) -> str:
    """
    Remainder style (largest unit + one remainder tier).
    Matches the semantics in the R and Bash examples.
    """
    total = sum_binary_bytes(
        *parts, bytes=bytes, b=b, kib=kib, kb=kb, mib=mib, mb=mb, gib=gib, gb=gb
    )
    KiB, MiB, GiB = IEC["KiB"], IEC["MiB"], IEC["GiB"]

    if total < KiB:
        return f"{total} bytes (= {total} bytes)"

    if total < MiB:
        k, r = divmod(total, KiB)
        s = f"{k} KiB" + (f" remainder {r} bytes" if r else "")
        return f"{s} (= {total} bytes)"

    if total < GiB:
        m, r = divmod(total, MiB)
        if r >= KiB:
            s = f"{m} MiB remainder {r // KiB} KiB"
        elif r:
            s = f"{m} MiB remainder {r} bytes"
        else:
            s = f"{m} MiB"
        return f"{s} (= {total} bytes)"

    g, r = divmod(total, GiB)
    if r >= MiB:
        s = f"{g} GiB remainder {r // MiB} MiB"
    elif r >= KiB:
        s = f"{g} GiB remainder {r // KiB} KiB"
    elif r:
        s = f"{g} GiB remainder {r} bytes"
    else:
        s = f"{g} GiB"
    return f"{s} (= {total} bytes)"


# ---------------------------- Worked examples --------------------------------
if __name__ == "__main__":
    # Full expansion
    print(format_binary_size_full("1 GiB", "512 MiB", "600 KiB"))  # 1 GiB 512 MiB 600 KiB (= 1611661312 bytes)
    print(format_binary_size_full("1536B"))                        # 1 KiB 512 bytes (= 1536 bytes)
    print(format_binary_size_full(kib=512))                        # 512 KiB (= 524288 bytes)

    # Remainder style (for parity with earlier function)
    print(format_binary_size_remainder("1536B"))                   # 1 KiB remainder 512 bytes (= 1536 bytes)

