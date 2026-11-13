#!/usr/bin/env python3
"""Install, reinstall, or update Ventoy with explicit confirmation controls."""

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from fractions import Fraction
from pathlib import Path

MIB = 1024**2
GIB = 1024**3
BOOT_BYTES = 32 * MIB
MIN_ISO_BYTES = 32 * MIB


# -- Arguments and partition arithmetic ---------------------------------------


def percentage(value):
  """Accept ordinary decimal percentages, optionally ending in %."""
  if not re.fullmatch(r"[0-9]{1,3}(?:\.[0-9]{1,6})?%?", value):
    raise argparse.ArgumentTypeError("use a percentage such as 15 or 12.5%")
  result = Fraction(value.removesuffix("%"))
  if not 0 < result < 100:
    raise argparse.ArgumentTypeError("percentage must be above 0 and below 100")
  return result


def partition_sizes(total_bytes, iso_percent, gpt):
  """Return reserved MiB and estimated ISO bytes for Ventoy's current layout."""
  target = total_bytes * iso_percent.numerator // (100 * iso_percent.denominator)
  # Ventoy starts Part1 at 1 MiB, uses a 32 MiB Part2, and aligns to 4 KiB.
  # GPT also needs 33 trailing 512-byte sectors. -r accepts whole MiB.
  tail_bytes = 33 * 512 if gpt else 0
  available = (total_bytes - BOOT_BYTES - tail_bytes) // 4096 * 4096 - MIB
  if target < MIN_ISO_BYTES:
    raise ValueError("requested ISO partition is below the 32 MiB minimum")
  if target >= available:
    raise ValueError("lower the percentage to leave room for Ventoy's boot data")
  reserved_mib = (available - target + MIB - 1) // MIB
  iso_bytes = available - reserved_mib * MIB
  if iso_bytes < MIN_ISO_BYTES:
    raise ValueError("rounding would leave an ISO partition below 32 MiB")
  return reserved_mib, iso_bytes


# -- Read-only disk inspection ------------------------------------------------


def read_disk(device):
  """Use lsblk's explicit columns; retain descendants for mount checks."""
  result = subprocess.run(
    [
      "lsblk",
      "--bytes",
      "--json",
      "--tree",
      "--output",
      "PATH,TYPE,SIZE,LOG-SEC,MOUNTPOINTS,RO,MODEL,SERIAL,TRAN",
    ],
    check=True,
    capture_output=True,
    text=True,
  )
  entries = json.loads(result.stdout)["blockdevices"]
  for entry in walk_devices(entries):
    if entry["path"] == str(device):
      if entry["type"] != "disk":
        raise ValueError("select a whole disk, e.g. /dev/sda, not /dev/sda1")
      if entry["log-sec"] != 512:
        raise ValueError("this wrapper supports 512-byte logical sectors only")
      if entry["ro"]:
        raise ValueError(f"{device} is read-only")
      if entry["size"] <= 0:
        raise ValueError(f"{device} has no usable capacity")
      return entry
  raise ValueError(f"{device} was not found by lsblk")


def walk_devices(entries):
  for entry in entries:
    yield entry
    yield from walk_devices(entry.get("children", []))


def check_execution(device, disk):
  if os.geteuid() != 0:
    raise ValueError("--execute requires root; run this command with sudo")
  if not device.is_block_device():
    raise ValueError(f"{device} is not an accessible block device")
  for entry in walk_devices([disk]):
    if any(entry.get("mountpoints", [])):
      raise ValueError(
        f"{entry['path']} is mounted or active as swap; unmount/deactivate first"
      )
    if entry is not disk and entry["type"] != "part":
      raise ValueError(
        f"{entry['path']} has an active device mapping; deactivate it first"
      )


# -- CLI ---------------------------------------------------------------------


def confirm_operation(args, device):
  """Resolve wrapper approvals before providing Ventoy's native answers."""
  if not args.apply:
    answer = input(f"Apply {args.operation} to {device}? (y/N) ")
    if answer not in ("y", "Y"):
      return False

  if args.verify:
    answer = input(f"Verify {args.operation} on {device}: type YES to continue: ")
    if answer != "YES":
      return False
  elif not args.assume_yes:
    answer = input(f"Final confirmation for {device}. Continue? (y/N) ")
    if answer not in ("y", "Y"):
      return False

  if args.assume_yes:
    if args.verify:
      print(
        "--verify retained the mandatory YES approval. "
        "Ventoy's native confirmation prompts will be answered automatically.",
        flush=True,
      )
    else:
      print(
        "WARNING: All remaining confirmation protections have been disabled "
        "for this operation; only an error may halt it. "
        "Device and sizing validation remain enforced.",
        flush=True,
      )
    print("Continuing in 3 seconds (Ctrl+C to cancel).", flush=True)
    time.sleep(3)
  return True


def main(argv=None):
  parser = argparse.ArgumentParser(
    description=(
      "Allocate a percentage of the whole disk to Ventoy's ISO partition. "
      "Default: preview only. Installation/reinstallation erases existing data; "
      "update preserves the existing partition layout."
    ),
    epilog=(
      "Example: ./ventoy-percent --iso-percent 15 -g -L iso_disk /dev/sda\n"
      "Install: sudo ./ventoy-percent --iso-percent 15 -g -L iso_disk "
      "--execute /dev/sda\n"
      "Verify reinstall: sudo ./ventoy-percent --execute --reinstall "
      "--iso-percent 15 -g -L iso_disk /dev/sda --apply --verify --verbose\n"
      "Update: sudo ./ventoy-percent --execute --update /dev/sda\n"
      "The remainder stays unallocated for partitions you create later."
    ),
    formatter_class=argparse.RawDescriptionHelpFormatter,
    allow_abbrev=False,
  )
  parser.add_argument("device", help="whole disk, e.g. /dev/sda")
  operations = parser.add_mutually_exclusive_group()
  operations.add_argument(
    "-i", "--install", dest="operation", action="store_const", const="install",
    help="install Ventoy; fail if already installed (default)",
  )
  operations.add_argument(
    "-I", "--reinstall", "--re-install", dest="operation",
    action="store_const", const="reinstall",
    help="reinstall Ventoy, erasing existing data (Ventoy -I)",
  )
  operations.add_argument(
    "-u", "-U", "--update", dest="operation", action="store_const", const="update",
    help="update Ventoy without resizing existing partitions (Ventoy -u)",
  )
  parser.set_defaults(operation="install")
  parser.add_argument(
    "--iso-percent",
    type=percentage,
    help="percentage for Part1, e.g. 15 or 12.5%% (required for install/reinstall)",
  )
  parser.add_argument(
    "-g", "--gpt", action="store_true", help="use GPT (otherwise Ventoy uses MBR)"
  )
  parser.add_argument(
    "-L",
    "--label",
    default="iso_disk",
    help="ISO partition label (default: iso_disk)",
  )
  parser.add_argument(
    "--ventoy",
    default="ventoy",
    help="Ventoy executable or script (default: ventoy)",
  )
  parser.add_argument(
    "--execute",
    action="store_true",
    help="run the selected operation (otherwise preview only)",
  )
  parser.add_argument(
    "--apply", action="store_true", help="automatically approve the first prompt",
  )
  parser.add_argument(
    "--verify", action="store_true",
    help="imply --apply and --verbose; require exact YES before execution",
  )
  parser.add_argument(
    "-v", "--verbose", action="store_true",
    help="print full disk metadata and operation details",
  )
  parser.add_argument(
    "--yes", "--noconfirm", "--noconfir", dest="assume_yes", action="store_true",
    help="autoapprove the final prompt after a warning and 3 seconds; "
    "combine with --apply for both prompts (--verify still requires YES)",
  )
  parser.add_argument(
    "--force", action="store_true",
    help="equivalent to --apply --yes; does not select reinstall or bypass --verify",
  )
  args = parser.parse_args(argv)
  if args.operation != "update" and args.iso_percent is None:
    parser.error("--iso-percent is required for install/reinstall")
  args.apply = args.apply or args.verify or args.force
  args.assume_yes = args.assume_yes or args.force
  args.verbose = args.verbose or args.verify

  try:
    # Some Ventoy launchers expand $* unquoted; keep labels safe through them.
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}", args.label):
      raise ValueError(
        "label: use 1-15 ASCII letters/digits, _, . or -; "
        "start with a letter, digit or _"
      )
    device = Path(args.device).resolve()
    disk = read_disk(device)
    total = disk["size"]
    executable = shutil.which(args.ventoy)
    if executable is None:
      raise ValueError(f"Ventoy executable not found: {args.ventoy}")
    command = [executable]
    if args.operation == "update":
      command.extend(["-u", str(device)])
    else:
      if not args.gpt and total > 2**41:
        raise ValueError("use -g for GPT on disks larger than 2 TiB")
      reserved, iso_bytes = partition_sizes(total, args.iso_percent, args.gpt)
      command.extend([
        "-I" if args.operation == "reinstall" else "-i", "-r", str(reserved),
      ])
      if args.gpt:
        command.append("-g")
      command.extend(["-L", args.label, str(device)])

    print(f"Operation: {args.operation}")
    print(f"Disk: {device} ({total / GIB:.2f} GiB)")
    if args.operation == "update":
      print(
        "Update preserves the existing partition layout and ISO files. "
        "--iso-percent, -g/--gpt and -L/--label do not apply and are ignored."
      )
    else:
      print(
        f"ISO partition: ~{iso_bytes / GIB:.2f} GiB "
        f"({100 * iso_bytes / total:.4f}% of disk)"
      )
      print(f"Ventoy boot partition: {BOOT_BYTES // MIB} MiB")
      print(
        f"Reserved for later partitions: ~{reserved * MIB / GIB:.2f} GiB "
        f"(-r {reserved})"
      )
    if args.verbose:
      print(f"Capacity: {total} bytes; logical sector: {disk['log-sec']} bytes")
      if args.operation != "update":
        print(f"Requested ISO percentage: {float(args.iso_percent):g}%")
        print(f"Partition table: {'GPT' if args.gpt else 'MBR'}; label: {args.label}")
        print(f"Estimated ISO bytes: {iso_bytes}; reserved MiB: {reserved}")
      print(f"Execution: {'enabled' if args.execute else 'preview only'}")
      print(
        f"Approvals: first={'automatic' if args.apply else 'interactive'}, "
        f"final={'exact YES' if args.verify else 'automatic' if args.assume_yes else 'interactive'}"
      )
      print("Disk metadata (lsblk):")
      print(json.dumps(disk, indent=2, sort_keys=True))
    print(f"Command: {shlex.join(command)}", flush=True)

    if not args.execute:
      print("Preview only. Add --execute and run with sudo to run the operation.")
      return 0

    check_execution(device, disk)
    if args.operation != "update":
      print(f"Installation will ERASE existing data on {device}.", flush=True)
    if not (args.apply or args.assume_yes):
      return subprocess.run(command, check=False).returncode
    if not confirm_operation(args, device):
      print("Cancelled. Ventoy was not started.")
      return 1
    # Supported Ventoy installs have two y/Y prompts; updates have one.
    # Keep the input finite: additional prompts receive EOF, never blanket consent.
    answers = "y\n" if args.operation == "update" else "y\ny\n"
    return subprocess.run(command, input=answers, text=True, check=False).returncode
  except EOFError:
    parser.exit(1, f"{parser.prog}: error: confirmation input closed; Ventoy not started\n")
  except KeyboardInterrupt:
    parser.exit(130, f"\n{parser.prog}: interrupted\n")
  except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
    parser.exit(1, f"{parser.prog}: error: {error}\n")


if __name__ == "__main__":
  sys.exit(main())
