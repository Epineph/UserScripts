#!/usr/bin/env python3
"""
dcf_rich.py: simple wrapper around `dcfldd` for multi-target copies
with built-in ETA/status every STATUSINTERVAL seconds.

Requirements:
  • dcfldd (Debian/Ubuntu: apt install dcfldd)
  • Python 3.7+

Usage:
  sudo dcf_rich.py [OPTIONS]

Options:
  -i, --input INPUT        Source file or device
  -t, --target TARGET      Destination (can repeat)
  -b, --bs SIZE            Block size, e.g. 512K, 1M, 4MiB, 2GiB  [default: 1M]
  -s, --status-interval N  Status print interval in seconds        [default: 1]
  -h, --help               Show this help and exit

Example:
  sudo dcf_rich.py \
    -b 4MiB -s 2 \
    -i /dev/sda \
    -t backup1.img \
    -t backup2.img
"""
import argparse
import shutil
import subprocess
import sys

def main():
    parser = argparse.ArgumentParser(
        prog="dcf_rich.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__
    )
    parser.add_argument(
        "-i", "--input",
        required=True,
        help="Source file or device"
    )
    parser.add_argument(
        "-t", "--target",
        required=True,
        action="append",
        help="Destination file (repeat for multiple)"
    )
    parser.add_argument(
        "-b", "--bs",
        default="1M",
        help="Block size (e.g. 512K, 1M, 4MiB)"
    )
    parser.add_argument(
        "-s", "--status-interval",
        type=int,
        default=1,
        help="How often (s) to print status"
    )
    args = parser.parse_args()

    # Ensure dcfldd is installed
    if not shutil.which("dcfldd"):
        print("ERROR: 'dcfldd' not found in PATH. Install via 'apt install dcfldd'.", file=sys.stderr)
        sys.exit(1)

    # Build command
    cmd = [
        "dcfldd",
        f"if={args.input}",
        f"bs={args.bs}",
        f"statusinterval={args.status_interval}",
    ]
    # Add one of= per target
    for idx, tgt in enumerate(args.target, start=1):
        # first target uses 'of=', subsequent get 'of2=', 'of3=' etc.
        suffix = "" if idx == 1 else str(idx)
        cmd.append(f"of{suffix}={tgt}")

    # Execute
    print(f"Executing: {' '.join(cmd)}\n")
    ret = subprocess.call(cmd)
    if ret != 0:
        sys.exit(ret)

if __name__ == "__main__":
    main()

