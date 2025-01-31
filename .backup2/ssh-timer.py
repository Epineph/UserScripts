#!/usr/bin/env python3
"""
mytimer.py

A small script to parse different textual representations of time
(e.g., "14400 seconds", "240 minutes", "4 hours",
"3 hours 59 minutes 1 second") into a total duration in seconds.

It prints ONLY the total duration in seconds as an integer,
making it easy to feed into other commands, such as:

    ssh-add -t $(python mytimer.py "3 hours 59 minutes 1 second") ~/.ssh/id_rsa
"""

import sys

def parse_time_input(time_str):
    """
    Parse a time specification string (e.g., '4 hours', '240 minutes',
    '14400 seconds', '3 hours 59 minutes 1 second') into total seconds.

    Parameters
    ----------
    time_str : str
        A string describing the time units
        (e.g. "4 hours", "59 minutes", "3 hours 59 minutes 1 second").

    Returns
    -------
    float
        Total time in seconds, as a float (in case of fractional units).
    """
    # Remove commas to simplify tokenization (e.g., "3 hours, 59 minutes")
    time_str_cleaned = time_str.replace(",", "")

    # Split on whitespace to get tokens
    tokens = time_str_cleaned.split()

    # Dictionary for recognized units and their corresponding conversion to seconds
    time_units_seconds = {
        "second": 1.0,
        "seconds": 1.0,
        "minute": 60.0,
        "minutes": 60.0,
        "hour": 3600.0,
        "hours": 3600.0
    }

    total_seconds = 0.0

    # We expect tokens in pairs: number + unit 
    # Example: ["3", "hours", "59", "minutes", "1", "second"]
    i = 0
    while i < len(tokens):
        try:
            quantity = float(tokens[i])
        except ValueError:
            raise ValueError(f"Invalid time quantity: {tokens[i]}")

        i += 1
        if i >= len(tokens):
            raise ValueError("Time specification ended abruptly; a unit is expected.")

        unit = tokens[i].lower()
        i += 1  # advance to next token

        if unit not in time_units_seconds:
            raise ValueError(f"Unrecognized time unit: {unit}")

        total_seconds += quantity * time_units_seconds[unit]

    return total_seconds

def main():
    # Require a time specification on the command line
    if len(sys.argv) < 2:
        print("Usage: python mytimer.py <time specification string>")
        print('Example: python mytimer.py "3 hours 59 minutes 1 second"')
        sys.exit(1)

    # Join all command line arguments into one string
    time_str = " ".join(sys.argv[1:])

    # Parse the time specification and print the total seconds as an integer
    try:
        total_seconds = parse_time_input(time_str)
        # Print only the integer part for direct ssh-add usage
        print(int(total_seconds))
    except ValueError as e:
        print(f"Error parsing time input: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()

