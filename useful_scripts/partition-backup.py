#!/usr/bin/env python3
"""Back up an inactive Linux partition to files on a different physical drive.

Requires Python 3.10+, Rich, util-linux, and GNU ddrescue for images, or GNU
tar and Zstandard for file archives. See partition-backup-guide.md for examples.
All subprocesses receive argument lists; no shell is used.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import errno
import fcntl
import hashlib
import json
import math
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

try:
  from rich.console import Console
  from rich.panel import Panel
  from rich.progress import (
    BarColumn,
    DownloadColumn,
    Progress,
    SpinnerColumn,
    TextColumn,
    TimeElapsedColumn,
    TimeRemainingColumn,
    TransferSpeedColumn,
  )
  from rich.prompt import Confirm
  from rich.table import Table
except ImportError:
  Console = None


# --- Constants and errors -----------------------------------------------------

VERSION = "1.0.0"
GiB = 1024 ** 3
CHUNK = 1024 ** 2
MAP_STATES = set("?*/-+")
FILE_SYSTEMS = {
  "ext2": ("ext2", "ro"),
  "ext3": ("ext3", "ro,noload"),
  "ext4": ("ext4", "ro,noload"),
  "xfs": ("xfs", "ro,norecovery"),
  "ntfs": ("ntfs3", "ro"),
  "vfat": ("vfat", "ro"),
  "exfat": ("exfat", "ro"),
}
LONG_HELP = """
METHODS
  image: GNU ddrescue copies every byte to payload.img and saves rescue.map.
    Best before filesystem repair and for unreadable or encrypted partitions.
    Default: a first pass without scraping; no additional retry pass.
    --retries N permits a later scraping/retry stage when recovery is incomplete.
    --resume --name NAME reuses the image and map in DESTINATION/NAME.

  files: GNU tar plus Zstandard creates payload.tar.zst. Only for healthy,
    cleanly unmounted filesystems. The script mounts the source temporarily
    read-only, with journal replay disabled for ext3/ext4 and XFS. It also sets
    the kernel block device read-only until the temporary mount is removed.
    Owners, permissions, links, sparse files, ACLs and xattrs are requested.
    Filesystem-specific structures, deleted data and boot sectors are absent.
    NTFS alternate streams, Windows security metadata, Btrfs/ZFS snapshots,
    and other filesystem-specific features need an image or native backup.

SPACE
  image: full partition bytes plus max(1 GiB, --headroom * partition bytes).
  files: a conservative uncompressed tar estimate, compression overhead,
    and the same headroom rule. Compression savings are never assumed.
  Reported requirements are AVAILABLE bytes on an already formatted filesystem.
    A newly created destination partition needs additional filesystem overhead.
    Quotas, thin provisioning and hardware health cannot be guaranteed.

SAFETY AND VERIFICATION
  SOURCE must be a partition, an inactive LVM LV, or an opened inactive mapping.
    Whole disks, active swap, mounted sources and devices with holders are
    rejected. Stop automounters, virtual machines and other users of SOURCE.
  DESTINATION must exist on a supported local block-backed filesystem on a
    different physical drive. Root-filesystem destinations require an override.
    Network, loop-backed and unidentifiable destinations are rejected.
  The script never creates/formats partitions, repairs filesystems, or writes
    to an output block device. Existing backup folders require --resume.
  Every finished payload is read back to create a SHA-256 fingerprint.
    This alone does not prove equality with SOURCE. --compare-source explicitly
    rereads an image's source for comparison; use only on healthy hardware.
  Image completeness comes from contiguous '+' blocks covering rescue.map.
    A complete image may faithfully contain an already damaged filesystem.
  Archives are fully decompressed/listed before being marked complete.
    Restore a sample and inspect important files before repairing the original.
  Ctrl-C preserves partial files. Images can resume; archives must restart in
    a NEW folder. Exit codes: 0 complete, 1 error, 2 usage,
    3 incomplete recovery, 130 interrupted.

EXAMPLES
  sudo python3 partition-backup.py plan /dev/sda5 /mnt/backup
  sudo python3 partition-backup.py backup /dev/sda5 /mnt/backup --name sda5
  sudo python3 partition-backup.py backup /dev/sda5 /mnt/backup \\
    --name sda5 --resume --retries 2
  sudo python3 partition-backup.py plan /dev/sda5 /mnt/backup --method files
  sudo python3 partition-backup.py backup /dev/sda5 /mnt/backup \\
    --method files --name sda5-files --threads 4 --level 3
  sudo python3 partition-backup.py verify /mnt/backup/sda5
"""


class BackupError(Exception):
  """A failure that can be explained without a Python traceback."""


def now() -> str:
  return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def human(size: int) -> str:
  value = float(size)
  for unit in ("B", "KiB", "MiB", "GiB", "TiB", "PiB"):
    if value < 1024 or unit == "PiB":
      return f"{value:,.2f} {unit}"
    value /= 1024
  return str(size)


def progress() -> Progress:
  return Progress(
    SpinnerColumn(), TextColumn("{task.description}"), BarColumn(),
    DownloadColumn(), TransferSpeedColumn(), TimeElapsedColumn(),
    TimeRemainingColumn(), console=console,
  )


# --- Checked subprocesses and device identities -------------------------------

def require(*commands: str) -> None:
  missing = [name for name in commands if not shutil.which(name)]
  if missing:
    raise BackupError("Missing commands: " + ", ".join(missing))


def run(argv: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
  env = dict(os.environ, LC_ALL="C")
  result = subprocess.run(
    argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
    stderr=subprocess.PIPE, text=True, env=env,
  )
  if check and result.returncode:
    detail = result.stderr.strip() or result.stdout.strip()
    raise BackupError(f"{argv[0]} failed: {detail[-2000:]}")
  return result


def inventory() -> dict[str, dict]:
  columns = (
    "PATH,TYPE,SIZE,FSTYPE,LABEL,UUID,PARTUUID,PARTTYPE,MAJ:MIN,LOG-SEC,RO"
  )
  data = json.loads(run([
    "lsblk", "--json", "--bytes", "--list", "--output", columns,
  ]).stdout)
  return {entry["maj:min"]: entry for entry in data["blockdevices"]}


def device_number(path: Path) -> str:
  info = path.stat()
  if not stat.S_ISBLK(info.st_mode):
    raise BackupError(f"Not a block device: {path}")
  return f"{os.major(info.st_rdev)}:{os.minor(info.st_rdev)}"


def physical_drives(number: str, visited: set | None = None) -> set[str]:
  """Resolve partitions, device mapper and RAID to their physical parents."""
  visited = set() if visited is None else visited
  if number in visited:
    raise BackupError("Cycle in the kernel block-device topology.")
  visited = visited | {number}
  link = Path("/sys/dev/block") / number
  if not link.exists():
    raise BackupError(f"Cannot identify backing drive for {number}.")
  node = link.resolve()
  if (node / "partition").exists():
    parent_number = (node.parent / "dev").read_text().strip()
    return physical_drives(parent_number, visited)
  slaves = list((node / "slaves").iterdir())
  if slaves:
    result = set()
    for slave in slaves:
      result |= physical_drives((slave / "dev").read_text().strip(), visited)
    return result
  if node.name.startswith(("loop", "ram", "zram")):
    raise BackupError(f"Unsupported backing device: {node.name}")
  return {number}


def disk_identity(number: str) -> dict:
  node = (Path("/sys/dev/block") / number).resolve()
  identity = {"kernel_name": node.name}
  for key, relative in (
    ("serial", "device/serial"), ("wwid", "device/wwid")
  ):
    try:
      identity[key] = (node / relative).read_text().strip()
    except OSError:
      identity[key] = None
  return identity


def source_info(source: Path) -> dict:
  source = source.resolve(strict=True)
  number = device_number(source)
  devices = inventory()
  if number not in devices:
    raise BackupError("Source is absent from lsblk.")
  result = dict(devices[number])
  if result["type"] not in ("part", "crypt", "lvm"):
    raise BackupError(
      "Choose a partition or inactive crypt/LVM device, not a whole disk."
    )
  if (result.get("parttype") or "").lower() in (
    "0x5", "0x05", "0xf", "0x0f", "0x85"
  ):
    raise BackupError(
      "Choose each logical partition, not its extended container."
    )
  result["path"] = str(source)
  result["size"] = int(result["size"])
  if result["size"] <= 0:
    raise BackupError("Source has no usable capacity.")
  result["drives"] = sorted(physical_drives(number))
  result["disk_identities"] = [disk_identity(n) for n in result["drives"]]
  return result


def mount_records() -> list[dict]:
  result = run([
    "findmnt", "--json", "--list", "--output",
    "TARGET,SOURCE,FSTYPE,OPTIONS,MAJ:MIN",
  ])
  return json.loads(result.stdout)["filesystems"]


def check_inactive(source: dict) -> None:
  number = source["maj:min"]
  targets = []
  devices = None
  for mount in mount_records():
    in_use = mount["maj:min"] == number
    try:
      backing = Path(mount["source"].split("[", 1)[0])
      backing_number = device_number(backing)
      in_use = in_use or backing_number == number
      if mount["fstype"] == "btrfs" and source.get("uuid"):
        devices = inventory() if devices is None else devices
        in_use = in_use or (
          devices.get(backing_number, {}).get("uuid") == source["uuid"]
        )
    except (OSError, BackupError):
      pass
    if in_use:
      targets.append(mount["target"])
  if targets:
    raise BackupError("Unmount SOURCE first: " + ", ".join(targets))
  holders = Path("/sys/dev/block") / number / "holders"
  if any(holders.iterdir()):
    raise BackupError("SOURCE has active holders; close its mappings first.")
  for line in Path("/proc/swaps").read_text().splitlines()[1:]:
    candidate = Path(line.split()[0])
    try:
      if device_number(candidate) == number:
        raise BackupError("SOURCE is active swap; swap it off first.")
    except (OSError, BackupError) as exc:
      if isinstance(exc, BackupError) and "active swap" in str(exc):
        raise


def destination_info(destination: Path, source: dict, allow_root: bool) -> dict:
  destination = destination.resolve(strict=True)
  if not destination.is_dir():
    raise BackupError("DESTINATION must be an existing directory.")
  data = json.loads(run([
    "findmnt", "--json", "--target", str(destination), "--output",
    "TARGET,SOURCE,FSTYPE,OPTIONS,MAJ:MIN",
  ]).stdout)["filesystems"][0]
  if data["target"] == "/" and not allow_root:
    raise BackupError(
      "DESTINATION is on /. Check that the backup drive is mounted. "
      "Use --allow-root-destination only if this location is intentional."
    )
  if "rw" not in data["options"].split(","):
    raise BackupError("DESTINATION is mounted read-only.")
  if data["fstype"] not in (
    "ext2", "ext3", "ext4", "xfs", "btrfs", "ntfs3", "ntfs",
    "fuseblk", "exfat", "vfat", "msdos",
  ):
    raise BackupError("Use an identifiable local block-backed destination.")
  number = data["maj:min"]
  if not (Path("/sys/dev/block") / number).exists():
    # Btrfs and FUSE can expose a synthetic filesystem device number.
    backing = Path(data["source"].split("[", 1)[0])
    number = device_number(backing)
  drives = physical_drives(number)
  if data["fstype"] == "btrfs":
    devices = inventory()
    uuid = devices.get(number, {}).get("uuid")
    if not uuid:
      raise BackupError("Cannot identify all destination Btrfs devices.")
    for n, entry in devices.items():
      if entry.get("fstype") == "btrfs" and entry.get("uuid") == uuid:
        drives |= physical_drives(n)
  if drives & set(source["drives"]):
    raise BackupError(
      "SOURCE and DESTINATION share a physical drive. Choose another drive."
    )
  data["drives"] = sorted(drives)
  data["path"] = str(destination)
  data["free"] = shutil.disk_usage(destination).free
  return data


def same_source(previous: dict, current: dict) -> bool:
  """Use stable IDs when available; unnamed sources require the same path."""
  for key in ("size", "uuid", "partuuid", "fstype"):
    if previous.get(key) != current.get(key):
      return False
  stable = bool(previous.get("partuuid") or previous.get("uuid"))
  old_disks = previous["disk_identities"]
  new_disks = current["disk_identities"]
  def signatures(disks: list[dict]) -> list[tuple]:
    return sorted(
      (d.get("serial") or "", d.get("wwid") or "") for d in disks
    )
  if signatures(old_disks) != signatures(new_disks):
    return False
  have_disk_id = any(d.get("serial") or d.get("wwid") for d in old_disks)
  if not have_disk_id and previous["path"] != current["path"]:
    return False
  if not stable and previous["path"] != current["path"]:
    return False
  return True


# --- Read-only mounting and file-space estimation -----------------------------

@contextlib.contextmanager
def readonly_mount(source: dict):
  fstype = source.get("fstype")
  if fstype not in FILE_SYSTEMS:
    raise BackupError(
      f"File mode does not support {fstype!r}; use an image instead."
    )
  require("mount", "umount", "blockdev")
  check_inactive(source)
  path = source["path"]
  original_ro = run(["blockdev", "--getro", path]).stdout.strip()
  mountpoint = Path(tempfile.mkdtemp(prefix="partition-backup-"))
  mounted = False
  restore_ro = True
  try:
    run(["blockdev", "--setro", path])
    driver, options = FILE_SYSTEMS[fstype]
    run(["mount", "-t", driver, "-o", options, "--", path,
         str(mountpoint)])
    mounted = True
    mounts = [m for m in mount_records() if m["target"] == str(mountpoint)]
    if len(mounts) != 1 or "ro" not in mounts[0]["options"].split(","):
      raise BackupError("The temporary mount is not confirmed read-only.")
    yield mountpoint
  finally:
    # A mount interrupted during the command may have succeeded in the kernel.
    try:
      mounted = mounted or any(
        m["target"] == str(mountpoint) for m in mount_records()
      )
    except (OSError, BackupError, ValueError):
      restore_ro = False
      console.print(
        f"Cannot check mount cleanup. {path} remains read-only; inspect "
        f"{mountpoint} manually.", style="bold red", markup=False,
      )
    if mounted:
      result = run(["umount", "--", str(mountpoint)], check=False)
      if result.returncode:
        restore_ro = False
        console.print(
          f"Unmount failed; {path} remains read-only at {mountpoint}. "
          f"Unmount it manually. {result.stderr.strip()}", style="bold red",
          markup=False,
        )
    if restore_ro:
      try:
        if original_ro == "0":
          if not same_source(source, source_info(Path(path))):
            raise BackupError(
              "Source changed during cleanup; its read-only flag was retained."
            )
          run(["blockdev", "--setrw", path])
      finally:
        mountpoint.rmdir()
    else:
      raise BackupError(
        "Temporary mount cleanup failed; source remains read-only."
      )


def scan_files(root: Path) -> dict:
  """Estimate tar size from metadata, without reading file contents."""
  root_device = root.stat().st_dev
  pending = [root]
  seen = set()
  count = logical = allocated = tar_bytes = 0
  with console.status("Scanning file metadata; compression is not assumed..."):
    while pending:
      path = pending.pop()
      info = path.lstat()
      if info.st_dev != root_device:
        raise BackupError("Nested filesystem found; archive it separately.")
      if stat.S_ISSOCK(info.st_mode):
        raise BackupError(f"Socket cannot be archived faithfully: {path}")
      attrs = 0
      try:
        for key in os.listxattr(path, follow_symlinks=False):
          attrs += len(os.fsencode(key))
          attrs += len(os.getxattr(path, key, follow_symlinks=False))
      except OSError as exc:
        if exc.errno not in (errno.ENOTSUP, errno.EOPNOTSUPP):
          raise
      relative = os.fsencode(str(path.relative_to(root)))
      link_size = len(os.fsencode(os.readlink(path))) if path.is_symlink() else 0
      overhead = 8192 + 2 * (len(relative) + link_size + attrs)
      tar_bytes += math.ceil(overhead / 512) * 512
      count += 1
      if stat.S_ISREG(info.st_mode):
        identity = (info.st_dev, info.st_ino)
        if identity not in seen:
          seen.add(identity)
          logical += info.st_size
          allocated += info.st_blocks * 512
          tar_bytes += math.ceil(info.st_size / 512) * 512
      elif stat.S_ISDIR(info.st_mode):
        with os.scandir(path) as entries:
          pending.extend(Path(entry.path) for entry in entries)
  tar_bytes += CHUNK
  return {
    "entries": count, "logical_file_bytes": logical,
    "allocated_file_bytes": allocated, "estimated_tar_bytes": tar_bytes,
    "payload_budget": math.ceil(tar_bytes * 1.02) + CHUNK,
  }


def budget(payload: int, headroom: float, remaining: int | None = None) -> dict:
  reserve = max(GiB, math.ceil(payload * headroom))
  needed = payload if remaining is None else remaining
  return {"payload_budget": payload, "reserve": reserve,
          "additional_payload": needed, "required_free": needed + reserve}


def show_plan(source: dict, destination: dict, sizing: dict,
              method: str, scan: dict | None = None) -> None:
  table = Table(title="Partition backup plan", show_header=False)
  rows = [
    ("Method", method), ("Source", source["path"]),
    ("Filesystem", source.get("fstype") or "unknown / encrypted"),
    ("Full partition", human(source["size"])),
    ("Destination", destination["path"]),
    ("Payload budget", human(sizing["payload_budget"])),
    ("Additional payload", human(sizing["additional_payload"])),
    ("Safety reserve", human(sizing["reserve"])),
    ("Required AVAILABLE space", human(sizing["required_free"])),
    ("Available now", human(destination["free"])),
    ("Required free bytes", f"{sizing['required_free']:,}"),
    ("Required free MiB", f"{sizing['required_free'] / 1024 ** 2:,.2f}"),
  ]
  if scan:
    rows += [
      ("Entries", f"{scan['entries']:,}"),
      ("Logical file data", human(scan["logical_file_bytes"])),
      ("Allocated file data", human(scan["allocated_file_bytes"])),
    ]
  for label, value in rows:
    table.add_row(label, str(value))
  console.print(table)
  console.print(
    "A new destination partition needs extra filesystem overhead. "
    "The requirement above is free space after formatting.", markup=False,
  )


def check_space(destination: dict, sizing: dict) -> None:
  if destination["fstype"] in ("vfat", "msdos"):
    if sizing["payload_budget"] > 2 ** 32 - 1:
      raise BackupError("FAT32 has a 4 GiB file limit; use ext4, exFAT or NTFS.")
  free = shutil.disk_usage(destination["path"]).free
  if free < sizing["required_free"]:
    raise BackupError(
      f"Insufficient space: need {human(sizing['required_free'])} available, "
      f"have {human(free)}."
    )


# --- Backup state, locking and ddrescue map parsing ---------------------------

def save_state(folder: Path, state: dict) -> None:
  state["updated_utc"] = now()
  temporary = folder / "backup.json.tmp"
  with temporary.open("w", encoding="utf-8") as stream:
    json.dump(state, stream, indent=2)
    stream.write("\n")
    stream.flush()
    os.fsync(stream.fileno())
  temporary.replace(folder / "backup.json")
  fd = os.open(folder, os.O_RDONLY | os.O_DIRECTORY)
  try:
    os.fsync(fd)
  finally:
    os.close(fd)


def regular_file(path: Path) -> None:
  if not stat.S_ISREG(path.lstat().st_mode):
    raise BackupError(f"Expected a regular file, not a symlink/device: {path}")


def read_state(folder: Path) -> dict:
  regular_file(folder / "backup.json")
  state = json.loads((folder / "backup.json").read_text())
  expected = {"image": "payload.img", "files": "payload.tar.zst"}
  if state.get("schema") != 1 or state.get("method") not in expected:
    raise BackupError("Unknown backup metadata schema or method.")
  if state.get("payload") != expected[state["method"]]:
    raise BackupError("Unexpected payload name in backup metadata.")
  return state


@contextlib.contextmanager
def lock_folder(folder: Path):
  if folder.is_symlink() or not folder.is_dir():
    raise BackupError("Backup folder must be a real directory.")
  for path in folder.iterdir():
    regular_file(path)
  fd = os.open(folder / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
  try:
    try:
      fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
      raise BackupError("This backup is already in use.") from exc
    yield
  finally:
    os.close(fd)


def parse_map(path: Path, expected_size: int) -> dict:
  counts = {char: 0 for char in MAP_STATES}
  end = 0
  status_seen = False
  for line in path.read_text(encoding="ascii").splitlines():
    fields = line.split()
    if not fields or fields[0].startswith("#"):
      continue
    if not status_seen:
      if len(fields) not in (2, 3) or fields[1] not in MAP_STATES | set("FG"):
        raise BackupError("Invalid ddrescue map status line.")
      status_seen = True
      continue
    if len(fields) != 3 or fields[2] not in MAP_STATES:
      raise BackupError("Invalid ddrescue map data line.")
    position, length = int(fields[0], 0), int(fields[1], 0)
    if position != end or length <= 0 or position + length > expected_size:
      raise BackupError("ddrescue map has a gap, overlap or invalid extent.")
    counts[fields[2]] += length
    end += length
  if not status_seen or end != expected_size:
    raise BackupError("ddrescue map does not cover the entire partition.")
  return {"rescued": counts["+"], "pending": counts["?"],
          "unreadable_or_unresolved": counts["*"] + counts["/"] + counts["-"],
          "complete": counts["+"] == expected_size, "by_status": counts}


def stop_child(child: subprocess.Popen) -> None:
  if child.poll() is not None:
    return
  os.killpg(child.pid, signal.SIGINT)
  try:
    child.wait(timeout=15)
  except subprocess.TimeoutExpired:
    os.killpg(child.pid, signal.SIGTERM)
    try:
      child.wait(timeout=5)
    except subprocess.TimeoutExpired:
      os.killpg(child.pid, signal.SIGKILL)
      try:
        child.wait(timeout=5)
      except subprocess.TimeoutExpired as exc:
        raise BackupError(
          f"Child PID {child.pid} is blocked in kernel I/O. Wait for it to "
          "exit before resuming or using the source."
        ) from exc


def run_rescue(source: dict, folder: Path, retries: int) -> dict:
  require("ddrescue")
  if "GNU ddrescue" not in run(["ddrescue", "--version"]).stdout:
    raise BackupError("This utility requires GNU ddrescue, not dd_rescue.")
  size = source["size"]
  image, mapfile = folder / "payload.img", folder / "rescue.map"
  common = [
    "ddrescue", "--quiet", f"--size={size}",
    f"--sector-size={source['log-sec'] or 512}",
  ]
  if "--mapfile-interval" in run(["ddrescue", "--help"]).stdout:
    common += ["--mapfile-interval=1,30"]
  stages = [("Imaging: first pass", ["--no-scrape"])]
  if retries:
    stages.append(("Imaging: retry stage", [f"--retry-passes={retries}"]))
  stats = None
  for label, options in stages:
    if stats and stats["complete"]:
      break
    if not same_source(source, source_info(Path(source["path"]))):
      raise BackupError("Source identity changed before a ddrescue stage.")
    check_inactive(source)
    argv = common + options + ["--", source["path"], str(image), str(mapfile)]
    with (folder / "backup.log").open("a") as log, progress() as display:
      log.write(json.dumps({"time": now(), "command": argv}) + "\n")
      log.flush()
      child = subprocess.Popen(
        argv, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
        start_new_session=True, env=dict(os.environ, LC_ALL="C"),
      )
      task = display.add_task(label, total=size)
      try:
        while child.poll() is None:
          try:
            snapshot = parse_map(mapfile, size)
            display.update(task, completed=snapshot["rescued"])
          except (OSError, ValueError, BackupError):
            pass  # Map replacement can be observed between writes.
          time.sleep(0.25)
      finally:
        stop_child(child)
      if child.returncode:
        raise BackupError("ddrescue failed; inspect backup.log and resume.")
      stats = parse_map(mapfile, size)
      display.update(task, completed=stats["rescued"])
  if image.stat().st_size != size:
    raise BackupError("Image length differs from the source partition.")
  return stats


# --- Metadata-preserving archive creation and verification --------------------

def write_archive(root: Path, folder: Path, scan: dict,
                  threads: int, level: int) -> Path:
  require("tar", "zstd")
  if "GNU tar" not in run(["tar", "--version"]).stdout:
    raise BackupError("File mode requires GNU tar.")
  partial = folder / "payload.tar.zst.part"
  tar_args = [
    "tar", "--create", "--format=pax", "--sparse", "--acls", "--xattrs",
    "--xattrs-include=*", "--selinux", "--numeric-owner",
    "--one-file-system", "--file=-", "--directory", str(root), "--", ".",
  ]
  zstd_args = ["zstd", "--quiet", "--check", f"-{level}", f"-T{threads}", "-c"]
  tar_process = compressor = None
  with partial.open("xb") as output, \
       (folder / "tar.stderr.log").open("wb") as tar_errors, \
       (folder / "zstd.stderr.log").open("wb") as zstd_errors:
    try:
      tar_process = subprocess.Popen(
        tar_args, stdout=subprocess.PIPE, stderr=tar_errors,
        stdin=subprocess.DEVNULL, start_new_session=True,
        env=dict(os.environ, LC_ALL="C", TAR_OPTIONS=""),
      )
      compressor = subprocess.Popen(
        zstd_args, stdin=subprocess.PIPE, stdout=output, stderr=zstd_errors,
        start_new_session=True, env=dict(os.environ, LC_ALL="C"),
      )
      copied = 0
      with progress() as display:
        task = display.add_task("Tar stream (estimated)",
                                total=scan["estimated_tar_bytes"])
        while data := tar_process.stdout.read(CHUNK):
          compressor.stdin.write(data)
          copied += len(data)
          display.update(task, completed=copied,
                         total=max(scan["estimated_tar_bytes"], copied))
      tar_process.stdout.close()
      compressor.stdin.close()
      if tar_process.wait() or compressor.wait():
        raise BackupError("Archive creation failed; inspect the stderr logs.")
      output.flush()
      os.fsync(output.fileno())
    finally:
      for child in (tar_process, compressor):
        if child is not None:
          stop_child(child)
          if child.stdout is not None:
            child.stdout.close()
          if child.stdin is not None and not child.stdin.closed:
            child.stdin.close()
  if (folder / "tar.stderr.log").stat().st_size:
    raise BackupError("tar reported warnings; inspect tar.stderr.log.")
  return partial


def test_archive(path: Path, folder: Path) -> None:
  require("tar", "zstd")
  with console.status("Verifying archive headers and compressed contents..."), \
       (folder / "verification.log").open("a") as log:
    child = subprocess.Popen(
      ["tar", "--zstd", "--list", "--ignore-zeros", "--file", str(path)],
      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=log,
      start_new_session=True, env=dict(os.environ, LC_ALL="C", TAR_OPTIONS=""),
    )
    try:
      code = child.wait()
    finally:
      stop_child(child)
    if code:
      raise BackupError("Archive validation failed; inspect verification.log.")


def checksum(path: Path, expected_size: int | None = None,
             label: str = "Reading backup for SHA-256") -> str:
  digest = hashlib.sha256()
  fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
  with os.fdopen(fd, "rb", buffering=0) as stream, progress() as display:
    info = os.fstat(stream.fileno())
    if not (stat.S_ISREG(info.st_mode) or stat.S_ISBLK(info.st_mode)):
      raise BackupError("Checksum input is not a regular file or block device.")
    size = info.st_size if expected_size is None else expected_size
    task = display.add_task(label, total=size)
    count = 0
    while data := stream.read(CHUNK):
      digest.update(data)
      count += len(data)
      display.update(task, completed=count)
    if count != size:
      raise BackupError(
        "Checksum input length changed or differs from expected."
      )
  return digest.hexdigest()


def sync_file(path: Path) -> None:
  with path.open("rb") as stream:
    os.fsync(stream.fileno())


def fingerprint(folder: Path, state: dict, path: Path) -> None:
  sync_file(path)
  digest = checksum(path)
  state["sha256"] = digest
  state["payload_bytes"] = path.stat().st_size
  with (folder / "payload.sha256").open("w") as stream:
    stream.write(f"{digest}  {state['payload']}\n")
    stream.flush()
    os.fsync(stream.fileno())


# --- User-facing commands -----------------------------------------------------

def verify(folder: Path) -> int:
  with lock_folder(folder):
    state = read_state(folder)
    path = folder / state["payload"]
    regular_file(path)
    expected = state.get("sha256")
    if not expected or not re.fullmatch(r"[0-9a-f]{64}", expected):
      raise BackupError(
        "No finished fingerprint; backup was interrupted/failed."
      )
    actual = checksum(path, state["payload_bytes"], "Checking SHA-256")
    if actual != expected:
      raise BackupError("SHA-256 mismatch: backup contents have changed.")
    complete = state["status"] == "complete"
    if state["method"] == "image":
      regular_file(folder / "rescue.map")
      stats = parse_map(folder / "rescue.map", state["source"]["size"])
      complete = complete and stats["complete"]
    else:
      test_archive(path, folder)
    console.print("SHA-256 matches the recorded backup fingerprint.",
                  style="green", markup=False)
    if not complete:
      console.print("Recovery is INCOMPLETE; this is not a complete backup.",
                    style="bold red")
      return 3
    console.print("Backup checks passed. Inspect a restored sample as well.",
                  style="green")
    return 0


def execute(args: argparse.Namespace) -> int:
  require("lsblk", "findmnt")
  source = source_info(args.source)
  check_inactive(source)
  destination = destination_info(args.destination, source,
                                 args.allow_root_destination)
  if source.get("fstype") == "btrfs":
    console.print(
      "A Btrfs filesystem may span devices; image every member partition.",
      style="yellow", markup=False,
    )
  if args.method == "files":
    if os.geteuid() != 0:
      raise BackupError("File planning and backup require sudo for mounting.")
    require("tar", "zstd", "mount", "umount", "blockdev")
  if args.command == "backup":
    if os.geteuid() != 0:
      raise BackupError("Backups require sudo to read the partition.")
    if args.method == "image":
      require("ddrescue")
    if args.resume and (args.method != "image" or not args.name):
      raise BackupError("--resume requires image mode and an explicit --name.")
    if args.compare_source and args.method != "image":
      raise BackupError("--compare-source applies only to image mode.")
  mount_context = (
    readonly_mount(source) if args.method == "files"
    else contextlib.nullcontext(None)
  )
  with mount_context as mounted:
    scan = scan_files(mounted) if mounted else None
    payload = scan["payload_budget"] if scan else source["size"]
    remaining = None
    name = getattr(args, "name", None)
    if not name:
      stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
      name = f"{Path(source['path']).name}-{stamp}"
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,100}", name):
      raise BackupError("--name must be a simple filename without slashes.")
    folder = Path(destination["path"]) / name
    state = None
    resuming = getattr(args, "resume", False)
    if resuming:
      if folder.is_symlink():
        raise BackupError("Cannot resume through a symlink.")
      state = read_state(folder)
      if state["method"] != "image" or not same_source(state["source"], source):
        raise BackupError("Resume source does not match the recorded partition.")
      if state["status"] == "complete":
        raise BackupError("Already complete; use the verify command.")
      regular_file(folder / "payload.img")
      if (folder / "payload.img").stat().st_size != source["size"]:
        raise BackupError("Cannot resume: image length is incorrect.")
      if (folder / "rescue.map").exists():
        regular_file(folder / "rescue.map")
        if (folder / "rescue.map").stat().st_size:
          stats = parse_map(folder / "rescue.map", source["size"])
          remaining = source["size"] - stats["rescued"]
    elif args.command == "backup" and folder.exists():
      raise BackupError("Backup folder already exists; choose another --name.")
    sizing = budget(payload, args.headroom, remaining)
    show_plan(source, destination, sizing, args.method, scan)
    check_space(destination, sizing)
    if args.command == "plan":
      return 0
    if not args.yes and not Confirm.ask("Create this backup?", default=False):
      console.print("Cancelled; no backup files created.")
      return 130
    # Repeat device/location checks immediately before creating output files.
    current = source_info(Path(source["path"]))
    if not same_source(source, current):
      raise BackupError("Source identity changed during planning.")
    destination_info(args.destination, source, args.allow_root_destination)
    check_space(destination, sizing)
    if not resuming:
      folder.mkdir(mode=0o700)
      state = {
        "schema": 1, "tool_version": VERSION, "created_utc": now(),
        "source": source, "method": args.method, "status": "preparing",
        "payload": "payload.img" if args.method == "image"
                   else "payload.tar.zst",
        "destination": destination, "sizing": sizing, "scan": scan,
      }
    with lock_folder(folder):
      if resuming:
        # Lock before rereading state: concurrent resumes must never overlap.
        locked_state = read_state(folder)
        if locked_state != state:
          raise BackupError(
            "Backup metadata changed; inspect it before resuming."
          )
      state["status"], state["sha256"] = "running", None
      state["source_compared"] = False
      save_state(folder, state)
      try:
        path = folder / state["payload"]
        if args.method == "image":
          if not resuming:
            with path.open("xb") as stream:
              stream.truncate(source["size"])
          state["recovery"] = run_rescue(source, folder, args.retries)
          complete = state["recovery"]["complete"]
        else:
          partial = write_archive(
            mounted, folder, scan, args.threads, args.level
          )
          test_archive(partial, folder)
          partial.replace(path)
          complete = True
        fingerprint(folder, state, path)
        if args.compare_source:
          if not complete:
            raise BackupError("Cannot compare SOURCE: recovery is incomplete.")
          check_inactive(source)
          if not same_source(source, source_info(Path(source["path"]))):
            raise BackupError("Source identity changed before comparison.")
          original = checksum(Path(source["path"]), source["size"],
                              "Rereading SOURCE for SHA-256")
          if original != state["sha256"]:
            raise BackupError(
              "Source/image checksum mismatch; do not repair yet."
            )
          state["source_compared"] = True
        state["status"] = "complete" if complete else "incomplete"
        state.pop("error", None)
        save_state(folder, state)
        console.print(f"Backup folder: {folder}", markup=False)
        if not complete:
          lost = source["size"] - state["recovery"]["rescued"]
          console.print(
            f"INCOMPLETE: {human(lost)} unreadable or not yet recovered. "
            "Keep payload.img AND rescue.map; resume before repairing.",
            style="bold red", markup=False,
          )
          return 3
        return 0
      except (Exception, KeyboardInterrupt) as exc:
        state["status"] = "interrupted" if isinstance(
          exc, KeyboardInterrupt
        ) else "failed"
        state["error"] = str(exc) or "Interrupted by user."
        save_state(folder, state)
        raise


def parser() -> argparse.ArgumentParser:
  result = argparse.ArgumentParser(
    description="Back up a Linux partition to files on another physical drive.",
    epilog="Use --long-help for safety details, space rules and examples.",
  )
  result.add_argument("--version", action="version", version=VERSION)
  result.add_argument("--long-help", action="store_true", help="show full guide")
  commands = result.add_subparsers(dest="command")
  for name, description in (
    ("plan", "inspect source and calculate required available space"),
    ("backup", "create an image or compressed file archive"),
  ):
    command = commands.add_parser(name, help=description)
    command.add_argument("source", type=Path, help="e.g. /dev/sda5")
    command.add_argument("destination", type=Path, help="existing backup folder")
    command.add_argument("--method", choices=("image", "files"), default="image")
    command.add_argument("--headroom", type=float, default=0.05,
                         help="free-space reserve fraction (default: 0.05)")
    command.add_argument("--allow-root-destination", action="store_true",
                         help="allow intentionally backing up onto / filesystem")
    if name == "backup":
      command.add_argument("--name", help="backup subfolder name")
      command.add_argument("--resume", action="store_true")
      command.add_argument("--retries", type=int, default=0,
                           help="ddrescue retry passes after first pass")
      command.add_argument("--compare-source", action="store_true",
                           help="reread healthy SOURCE and compare SHA-256")
      command.add_argument("--threads", type=int,
                           default=min(4, os.cpu_count() or 1),
                           help="Zstandard threads (default: up to 4)")
      command.add_argument("--level", type=int, default=3,
                           help="Zstandard level 1-19 (default: 3)")
      command.add_argument("--yes", action="store_true",
                           help="skip the backup confirmation prompt")
  command = commands.add_parser("verify", help="check an existing backup")
  command.add_argument("folder", type=Path)
  return result


def main() -> int:
  global console
  command_parser = parser()
  args = command_parser.parse_args()
  if args.long_help:
    print(LONG_HELP.strip())
    return 0
  if not args.command:
    command_parser.print_help()
    return 0
  if sys.platform != "linux":
    command_parser.error("Run this script on Linux, not Windows/WSL storage.")
  if Console is None:
    print("Rich is missing. Install python-rich or: python3 -m pip install rich",
          file=sys.stderr)
    return 1
  console = Console(highlight=False)
  if args.command != "verify":
    if not math.isfinite(args.headroom) or not 0 <= args.headroom <= 1:
      command_parser.error("--headroom must be a fraction between 0 and 1")
  if args.command == "backup":
    if not 0 <= args.retries <= 100:
      command_parser.error("--retries must be 0-100")
    if not 1 <= args.threads <= 256 or not 1 <= args.level <= 19:
      command_parser.error("--threads must be 1-256 and --level 1-19")
  console.print(Panel("Linux partition backup | " + VERSION))
  try:
    if args.command == "verify":
      return verify(args.folder.absolute())
    code = execute(args)
    if code == 0 and args.command == "backup":
      console.print("Backup complete; SHA-256 fingerprint recorded.",
                    style="bold green")
    return code
  except KeyboardInterrupt:
    console.print("Interrupted. Partial files were retained.", style="yellow")
    return 130
  except (BackupError, OSError, ValueError, KeyError) as exc:
    console.print(f"Error: {exc}", style="bold red", markup=False)
    return 1


if __name__ == "__main__":
  sys.exit(main())
