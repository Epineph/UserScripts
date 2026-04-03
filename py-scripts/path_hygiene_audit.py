#!/usr/bin/env python3
"""
path_hygiene_audit.py

Audit + (optionally) remediate ownership/group/permission hygiene for directories
on $PATH.

Policy (deliberately conservative and portable):
  - If a PATH entry is under $HOME:
      expected owner = current user
      expected group = user's primary group
  - Otherwise (system PATH entry):
      expected owner = root
      expected group = root

Permission tightening:
  - Always remove group-writable and world-writable bits from PATH directories.
  - Always ensure owner has rwx on PATH directories (u+rwx).
  - Never add permissions to group/other; only remove unsafe writes.
  - If a directory is already more restrictive (e.g., 0700), it remains so unless
    it is unsafe or unusable.

By default, this is a DRY RUN and prints suggested commands.
With --noconfirm, it will attempt to apply fixes.

Examples (5+):
  1) Dry run audit of current PATH:
       ./path_hygiene_audit.py

  2) Apply fixes (will require sudo for system paths):
       ./path_hygiene_audit.py --noconfirm

  3) Audit a custom PATH string:
       ./path_hygiene_audit.py --path "/usr/local/bin:/usr/bin:$HOME/.cargo/bin"

  4) Only audit (no changes) but show symlink targets:
       ./path_hygiene_audit.py --show-symlinks

  5) Audit and include non-existent PATH entries in the report:
       ./path_hygiene_audit.py --include-missing

  6) Audit only a subset by providing a file containing paths (one per line):
       ./path_hygiene_audit.py --path-file ./path_entries.txt
"""

from __future__ import annotations

import argparse
import getpass
import os
import pwd
import grp
import stat
from pathlib import Path
from typing import Iterable, List, Optional, Tuple


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _mode_oct(m: int) -> str:
    return format(m & 0o777, "04o")


def _name_from_uid(uid: int) -> str:
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return str(uid)


def _name_from_gid(gid: int) -> str:
    try:
        return grp.getgrgid(gid).gr_name
    except KeyError:
        return str(gid)


def _real(p: str) -> str:
    try:
        return os.path.realpath(p)
    except Exception:
        return p


def _commonpath_ok(a: str, b: str) -> bool:
    """
    os.path.commonpath() raises on mixed absolute/relative in some cases.
    """
    try:
        os.path.commonpath([a, b])
        return True
    except Exception:
        return False


def _is_under(child: str, parent: str) -> bool:
    """
    True if child is (or is inside) parent, after realpath normalization.
    """
    child_r = os.path.realpath(child)
    parent_r = os.path.realpath(parent)

    if not os.path.isabs(child_r) or not os.path.isabs(parent_r):
        return False

    if not _commonpath_ok(child_r, parent_r):
        return False

    return os.path.commonpath([child_r, parent_r]) == parent_r


def _dedupe_preserve_order(items: Iterable[str]) -> List[str]:
    seen = set()
    out: List[str] = []
    for x in items:
        if x in seen:
            continue
        seen.add(x)
        out.append(x)
    return out


# ---------------------------------------------------------------------------
# Policy + Planning
# ---------------------------------------------------------------------------

class PlannedFix:
    def __init__(
        self,
        path: str,
        expected_uid: int,
        expected_gid: int,
        expected_owner: str,
        expected_group: str,
        need_chown: bool,
        new_mode: Optional[int],
        reasons: List[str],
    ) -> None:
        self.path = path
        self.expected_uid = expected_uid
        self.expected_gid = expected_gid
        self.expected_owner = expected_owner
        self.expected_group = expected_group
        self.need_chown = need_chown
        self.new_mode = new_mode
        self.reasons = reasons

    def has_any_change(self) -> bool:
        return self.need_chown or self.new_mode is not None


def _expected_ids_for_path(
    path_entry: str,
    home_dir: str,
    user_uid: int,
    user_gid: int,
    root_uid: int,
    root_gid: int,
) -> Tuple[int, int, str]:
    """
    Return expected (uid, gid, classification) for a PATH directory.
    """
    # Prefer realpath for classification; symlinks should be judged by target.
    real_entry = os.path.realpath(path_entry)
    if _is_under(real_entry, home_dir):
        return (user_uid, user_gid, "home")
    return (root_uid, root_gid, "system")


def _plan_fix(
    path_entry: str,
    st: os.stat_result,
    expected_uid: int,
    expected_gid: int,
) -> PlannedFix:
    """
    Determine whether owner/group/mode are "incorrect" by policy and safety.
    Plan the minimal changes consistent with the policy.
    """
    reasons: List[str] = []

    actual_uid = st.st_uid
    actual_gid = st.st_gid
    actual_mode = stat.S_IMODE(st.st_mode)

    expected_owner = _name_from_uid(expected_uid)
    expected_group = _name_from_gid(expected_gid)

    need_chown = False
    if actual_uid != expected_uid:
        need_chown = True
        reasons.append(
            f"owner mismatch: {_name_from_uid(actual_uid)} -> {expected_owner}"
        )
    if actual_gid != expected_gid:
        need_chown = True
        reasons.append(
            f"group mismatch: {_name_from_gid(actual_gid)} -> {expected_group}"
        )

    # Permission tightening:
    #   - Ensure owner has rwx (u+rwx).
    #   - Remove group/other write bits.
    #   - Leave other bits as-is (do not add perms to g/o).
    new_mode = actual_mode

    if (new_mode & 0o700) != 0o700:
        new_mode |= 0o700
        reasons.append("directory not fully accessible to owner; add u+rwx")

    if new_mode & 0o020:
        new_mode &= ~0o020
        reasons.append("group-writable PATH dir; remove g+w")

    if new_mode & 0o002:
        new_mode &= ~0o002
        reasons.append("world-writable PATH dir; remove o+w")

    if new_mode == actual_mode:
        new_mode_out: Optional[int] = None
    else:
        new_mode_out = new_mode

    return PlannedFix(
        path=path_entry,
        expected_uid=expected_uid,
        expected_gid=expected_gid,
        expected_owner=expected_owner,
        expected_group=expected_group,
        need_chown=need_chown,
        new_mode=new_mode_out,
        reasons=reasons,
    )


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

def _print_header(title: str) -> None:
    print("=" * 79)
    print(title)
    print("=" * 79)


def _print_kv(k: str, v: str) -> None:
    print(f"{k:<20} {v}")


def _suggest_chown_cmd(path_entry: str, owner: str, group: str) -> str:
    # Use sudo only when targeting root ownership/group (common for system dirs).
    if owner == "root" or group == "root":
        return f"sudo chown {owner}:{group} {path_entry!r}"
    return f"chown {owner}:{group} {path_entry!r}"


def _suggest_chmod_cmd(path_entry: str, mode: int) -> str:
    return f"chmod {format(mode & 0o777, '04o')} {path_entry!r}"


def _apply_fix(fix: PlannedFix, dry_run: bool) -> Tuple[bool, List[str]]:
    """
    Attempt to apply changes. Returns (all_ok, messages).
    """
    msgs: List[str] = []
    ok = True

    if not fix.has_any_change():
        msgs.append("No changes needed.")
        return (True, msgs)

    if dry_run:
        msgs.append("DRY RUN: not applying changes.")
        if fix.need_chown:
            msgs.append(
                "Would run: " + _suggest_chown_cmd(
                    fix.path, fix.expected_owner, fix.expected_group
                )
            )
        if fix.new_mode is not None:
            msgs.append("Would run: " + _suggest_chmod_cmd(fix.path, fix.new_mode))
        return (True, msgs)

    # Apply ownership changes first.
    if fix.need_chown:
        try:
            os.chown(fix.path, fix.expected_uid, fix.expected_gid)
            msgs.append(
                f"Applied chown to {fix.expected_owner}:{fix.expected_group}."
            )
        except PermissionError as e:
            ok = False
            msgs.append(
                f"FAILED chown (permission denied): {e}. "
                "Suggested command:"
            )
            msgs.append(
                "  " + _suggest_chown_cmd(
                    fix.path, fix.expected_owner, fix.expected_group
                )
            )
        except Exception as e:
            ok = False
            msgs.append(f"FAILED chown (unexpected): {e}.")

    if fix.new_mode is not None:
        try:
            os.chmod(fix.path, fix.new_mode)
            msgs.append(f"Applied chmod to {_mode_oct(fix.new_mode)}.")
        except PermissionError as e:
            ok = False
            msgs.append(
                f"FAILED chmod (permission denied): {e}. Suggested command:"
            )
            msgs.append("  " + _suggest_chmod_cmd(fix.path, fix.new_mode))
        except Exception as e:
            ok = False
            msgs.append(f"FAILED chmod (unexpected): {e}.")

    return (ok, msgs)


def _read_path_file(path_file: str) -> List[str]:
    out: List[str] = []
    with open(path_file, "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            out.append(s)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="path_hygiene_audit.py",
        description=(
            "Audit + optionally remediate owner/group/permission hygiene for "
            "directories on PATH."
        ),
    )
    parser.add_argument(
        "--noconfirm",
        action="store_true",
        help="Apply changes instead of dry run.",
    )
    parser.add_argument(
        "--path",
        default=None,
        help="Override PATH string to audit (colon-separated).",
    )
    parser.add_argument(
        "--path-file",
        default=None,
        help="Read PATH entries from a file (one directory per line).",
    )
    parser.add_argument(
        "--include-missing",
        action="store_true",
        help="Include non-existent PATH entries in the report (as warnings).",
    )
    parser.add_argument(
        "--show-symlinks",
        action="store_true",
        help="Show realpath targets for symlinked PATH entries.",
    )
    args = parser.parse_args()

    user = getpass.getuser()
    user_entry = pwd.getpwnam(user)
    user_uid = user_entry.pw_uid
    user_gid = user_entry.pw_gid
    user_group = grp.getgrgid(user_gid).gr_name

    home_dir = str(Path.home())
    root_uid = 0
    root_gid = 0

    dry_run = not args.noconfirm

    if args.path_file is not None:
        raw_entries = _read_path_file(args.path_file)
    else:
        path_str = args.path if args.path is not None else os.environ.get("PATH", "")
        raw_entries = [p for p in path_str.split(":")]

    entries = _dedupe_preserve_order([p for p in raw_entries if p])

    _print_header("PATH Hygiene Audit")
    _print_kv("User", user)
    _print_kv("UID:GID", f"{user_uid}:{user_gid}")
    _print_kv("Primary group", user_group)
    _print_kv("Home", home_dir)
    _print_kv("Mode", "APPLY" if not dry_run else "DRY RUN")
    print()

    if not entries:
        print("No PATH entries found.")
        return 2

    any_problems = False
    any_failed = False

    for i, p in enumerate(entries, start=1):
        p_disp = p
        real_p = _real(p)

        print("-" * 79)
        print(f"[{i:02d}] {p_disp}")
        if args.show_symlinks and real_p != p:
            _print_kv("Realpath", real_p)

        if not os.path.exists(p):
            msg = "MISSING: does not exist."
            if args.include_missing:
                print(msg)
            else:
                print(msg + " (skipping; use --include-missing to include)")
            any_problems = True
            continue

        try:
            st = os.stat(p)
        except Exception as e:
            print(f"ERROR: cannot stat path: {e}")
            any_problems = True
            continue

        if not stat.S_ISDIR(st.st_mode):
            print("WARNING: PATH entry is not a directory. (skipping)")
            any_problems = True
            continue

        actual_owner = _name_from_uid(st.st_uid)
        actual_group = _name_from_gid(st.st_gid)
        actual_mode = stat.S_IMODE(st.st_mode)

        exp_uid, exp_gid, classification = _expected_ids_for_path(
            p, home_dir, user_uid, user_gid, root_uid, root_gid
        )
        exp_owner = _name_from_uid(exp_uid)
        exp_group = _name_from_gid(exp_gid)

        _print_kv("Class", classification)
        _print_kv("Current", f"{actual_owner}:{actual_group} {_mode_oct(actual_mode)}")
        _print_kv("Expected", f"{exp_owner}:{exp_group} (policy)")
        print()

        fix = _plan_fix(p, st, exp_uid, exp_gid)

        if not fix.has_any_change():
            print("Status: OK (no changes needed).")
            continue

        any_problems = True
        print("Status: NOT OK (mismatch detected).")
        print("Findings:")
        for r in fix.reasons:
            print(f"  - {r}")

        print()
        print("Suggested remediation (commands):")
        if fix.need_chown:
            print("  " + _suggest_chown_cmd(p, fix.expected_owner, fix.expected_group))
        if fix.new_mode is not None:
            print("  " + _suggest_chmod_cmd(p, fix.new_mode))

        print()
        ok, msgs = _apply_fix(fix, dry_run=dry_run)
        for m in msgs:
            print(m)

        if not ok:
            any_failed = True

    print("-" * 79)
    if not any_problems:
        print("RESULT: OK. No owner/group/permission issues detected by policy.")
        return 0

    if any_failed:
        print("RESULT: ISSUES DETECTED, AND AT LEAST ONE FIX FAILED.")
        print("        Re-run with sufficient privileges (sudo) if appropriate.")
        return 1

    if dry_run:
        print("RESULT: ISSUES DETECTED (dry run).")
        print("        Re-run with --noconfirm to attempt applying fixes.")
        return 1

    print("RESULT: ISSUES DETECTED, FIXES APPLIED SUCCESSFULLY.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

