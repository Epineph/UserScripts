#!/usr/bin/env python3
"""
luks-guard: Hyprland-oriented session guard and encrypted-system kill-switch.

This script is intentionally user-session based. It does not install a
systemd service. Hyprland starts it with exec-once, and hypridle handles true
Wayland idle detection when available.
"""

from __future__ import annotations

import argparse
import fcntl
import getpass
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import termios
import time
import tty
from pathlib import Path
from typing import Any

APP = "luks-guard"
HOME = Path.home()
CONFIG_DIR = HOME / ".config" / APP
CACHE_DIR = HOME / ".cache" / APP
CONFIG_PATH = CONFIG_DIR / "config.json"
STATE_PATH = CACHE_DIR / "state.json"
SAFE_PATH = CACHE_DIR / "safe-session"
LOCK_PATH = CACHE_DIR / "daemon.lock"
PROMPT_LOCK_PATH = CACHE_DIR / "prompt.lock"
HYPR_CONF_PATH = HOME / ".config" / "hypr" / "conf.d" / "luks-guard.conf"
HYPRIDLE_CONF_PATH = HOME / ".config" / "hypr" / "luks-guard-hypridle.conf"
HYPRIDLE_PID_PATH = CACHE_DIR / "hypridle.pid"

DEFAULT_CONFIG: dict[str, Any] = {
    "luks_devices": [],
    "verify_policy": "any",
    "idle_enabled": True,
    "idle_seconds": 7200,
    "reoccur_enabled": False,
    "reoccur_seconds": 0,
    "startup_grace_seconds": 60,
    "prompt_deadline_seconds": 300,
    "post_logout_shutdown_seconds": 300,
    "failed_attempt_shutdown_seconds": 5,
    "hard_poweroff": True,
    "terminal_order": ["wezterm", "alacritty", "kitty", "foot", "xterm",
                       "konsole"],
    "terminal_classes": ["wezterm", "org.wezfurlong.wezterm", "alacritty",
                         "kitty", "foot", "xterm", "konsole"],
}


# ---------------------------------------------------------------------------
# Files and JSON
# ---------------------------------------------------------------------------


def ensure_dirs() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)


def load_json(path: Path, default: dict[str, Any]) -> dict[str, Any]:
    if not path.exists():
        return dict(default)
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:
        return dict(default)
    merged = dict(default)
    merged.update(data)
    return merged


def save_json(path: Path, data: dict[str, Any]) -> None:
    ensure_dirs()
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")
    tmp.replace(path)


def load_config() -> dict[str, Any]:
    ensure_dirs()
    cfg = load_json(CONFIG_PATH, DEFAULT_CONFIG)
    return cfg


def save_config(cfg: dict[str, Any]) -> None:
    save_json(CONFIG_PATH, cfg)


def load_state() -> dict[str, Any]:
    return load_json(STATE_PATH, {})


def save_state(state: dict[str, Any]) -> None:
    save_json(STATE_PATH, state)


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def which(cmd: str) -> str | None:
    return shutil.which(cmd)


def run_quiet(cmd: list[str], **kwargs: Any) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        **kwargs,
    )


def notify(message: str, urgency: str = "normal") -> None:
    if which("hyprctl"):
        subprocess.run(
            ["hyprctl", "notify", "1", "4500", "rgb(ffcc00)", message],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return
    if which("notify-send"):
        subprocess.run(
            ["notify-send", "-u", urgency, APP, message],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def seconds_from_parts(hours: int, minutes: int, seconds: int) -> int:
    total = hours * 3600 + minutes * 60 + seconds
    if total < 0:
        raise ValueError("time cannot be negative")
    return total


def format_seconds(seconds: int) -> str:
    seconds = max(0, int(seconds))
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m}m {s}s"
    if m:
        return f"{m}m {s}s"
    return f"{s}s"


# ---------------------------------------------------------------------------
# LUKS discovery and verification
# ---------------------------------------------------------------------------


def walk_lsblk(node: dict[str, Any], out: list[dict[str, Any]]) -> None:
    out.append(node)
    for child in node.get("children", []) or []:
        walk_lsblk(child, out)


def detect_luks_devices() -> list[str]:
    if not which("lsblk"):
        return []
    proc = run_quiet(["lsblk", "-J", "-o", "NAME,PATH,FSTYPE,MOUNTPOINTS"])
    if proc.returncode != 0:
        return []
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return []
    nodes: list[dict[str, Any]] = []
    for dev in data.get("blockdevices", []):
        walk_lsblk(dev, nodes)
    devices = []
    for node in nodes:
        if node.get("fstype") == "crypto_LUKS" and node.get("path"):
            devices.append(str(node["path"]))
    return sorted(set(devices))


def cryptsetup_test_passphrase(device: str, passphrase: str) -> bool:
    if not which("sudo") or not which("cryptsetup"):
        return False
    cryptsetup = which("cryptsetup") or "/usr/bin/cryptsetup"
    cmd = [
        "sudo",
        "-n",
        cryptsetup,
        "open",
        "--test-passphrase",
        device,
    ]
    proc = subprocess.run(
        cmd,
        input=passphrase + "\n",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return proc.returncode == 0


def verify_passphrase(passphrase: str, cfg: dict[str, Any]) -> bool:
    devices = list(cfg.get("luks_devices") or [])
    if not devices:
        devices = detect_luks_devices()
    if not devices:
        eprint("No LUKS devices configured or detected.")
        return False

    results = [cryptsetup_test_passphrase(dev, passphrase) for dev in devices]
    policy = str(cfg.get("verify_policy", "any")).lower()
    if policy == "all":
        return all(results)
    return any(results)


# ---------------------------------------------------------------------------
# Terminal detection and launch
# ---------------------------------------------------------------------------


def terminal_command(cfg: dict[str, Any], child: list[str]) -> list[str] | None:
    for term in cfg.get("terminal_order", DEFAULT_CONFIG["terminal_order"]):
        if not which(term):
            continue
        if term == "wezterm":
            return [term, "start", "--always-new-process", "--class",
                    "luks-guard", "--"] + child
        if term == "alacritty":
            return [term, "--class", "luks-guard", "-e"] + child
        if term == "kitty":
            return [term, "--class", "luks-guard"] + child
        if term == "foot":
            return [term, "-a", "luks-guard"] + child
        if term == "xterm":
            return [term, "-class", "luks-guard", "-e"] + child
        if term == "konsole":
            return [term, "--nofork", "-e"] + child
    return None


def hypr_clients() -> list[dict[str, Any]]:
    if not which("hyprctl"):
        return []
    proc = run_quiet(["hyprctl", "clients", "-j"])
    if proc.returncode != 0:
        return []
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return []
    if isinstance(data, list):
        return data
    return []


def terminal_is_open(cfg: dict[str, Any]) -> bool:
    classes = [str(x).lower() for x in cfg.get("terminal_classes", [])]
    for client in hypr_clients():
        fields = [str(client.get("class", "")), str(client.get("title", ""))]
        joined = " ".join(fields).lower()
        if any(cls in joined for cls in classes):
            return True
    return False


def launch_prompt(reason: str = "manual", force: bool = False) -> None:
    cfg = load_config()
    cmd = [str(Path(sys.argv[0]).resolve()), "prompt", "--reason", reason]
    if force:
        cmd.append("--force")
    term_cmd = terminal_command(cfg, cmd)
    if term_cmd is None:
        eprint("No supported terminal found; running prompt in current process.")
        prompt_cmd(argparse.Namespace(force=force, reason=reason))
        return
    subprocess.Popen(
        term_cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


# ---------------------------------------------------------------------------
# Authentication state and prompt
# ---------------------------------------------------------------------------


def current_boot_id() -> str | None:
    try:
        return Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    except Exception:
        return None


def current_session_id() -> str | None:
    for key in ("HYPRLAND_INSTANCE_SIGNATURE", "XDG_SESSION_ID"):
        value = os.environ.get(key)
        if value:
            return value
    return None


def safe_session_active() -> bool:
    if not SAFE_PATH.exists():
        return False
    try:
        data = json.loads(SAFE_PATH.read_text(encoding="utf-8"))
    except Exception:
        SAFE_PATH.unlink(missing_ok=True)
        return False
    if not isinstance(data, dict):
        SAFE_PATH.unlink(missing_ok=True)
        return False

    saved_boot = data.get("boot_id")
    current_boot = current_boot_id()
    if saved_boot and current_boot and saved_boot != current_boot:
        SAFE_PATH.unlink(missing_ok=True)
        return False

    saved_session = data.get("session_id")
    current_session = current_session_id()
    if saved_session and current_session and saved_session != current_session:
        SAFE_PATH.unlink(missing_ok=True)
        return False

    return True


def mark_authenticated() -> None:
    state = load_state()
    state["last_auth_epoch"] = time.time()
    save_state(state)


def last_auth_age() -> int | None:
    state = load_state()
    last = state.get("last_auth_epoch")
    if not isinstance(last, (int, float)):
        return None
    return int(time.time() - float(last))


def prompt_already_running() -> bool:
    ensure_dirs()
    lock = PROMPT_LOCK_PATH.open("w")
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    return False


def read_secret(prompt: str, timeout_seconds: int) -> str | None:
    fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        os.write(fd, prompt.encode())
        buf: list[str] = []
        deadline = time.monotonic() + timeout_seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                os.write(fd, b"\n")
                return None
            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                os.write(fd, b"\n")
                return None
            ch = os.read(fd, 1)
            if ch in (b"\n", b"\r"):
                os.write(fd, b"\n")
                return "".join(buf)
            if ch in (b"\x03", b"\x04"):
                os.write(fd, b"\n")
                return None
            if ch in (b"\x7f", b"\b"):
                if buf:
                    buf.pop()
                continue
            try:
                buf.append(ch.decode())
            except UnicodeDecodeError:
                continue
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        os.close(fd)


def sync_disks() -> None:
    if which("sync"):
        subprocess.run(["sync"], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)


def kill_now(hard: bool = True, reason: str = "manual") -> None:
    notify(f"{APP}: kill-switch triggered ({reason}).", "critical")
    sync_disks()
    if hard and which("sudo") and which("systemctl"):
        proc = subprocess.run(
            ["sudo", "-n", "/usr/bin/systemctl", "poweroff", "--force",
             "--force"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if proc.returncode == 0:
            return
    if which("systemctl"):
        subprocess.run(["systemctl", "poweroff", "-i"])
    else:
        subprocess.run(["poweroff"])


def schedule_shutdown(seconds: int) -> None:
    minutes = max(1, int(round(seconds / 60)))
    msg = f"{APP}: authentication timeout; powering off."
    shutdown = which("shutdown") or "/usr/bin/shutdown"
    cmds = [
        ["sudo", "-n", shutdown, "-h", f"+{minutes}", msg],
        [shutdown, "-h", f"+{minutes}", msg],
    ]
    for cmd in cmds:
        try:
            proc = subprocess.run(cmd, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL)
        except FileNotFoundError:
            continue
        if proc.returncode == 0:
            notify(f"{APP}: shutdown scheduled in {minutes} minute(s).",
                   "critical")
            return
    notify(f"{APP}: could not schedule delayed shutdown.", "critical")


def cancel_shutdown() -> None:
    shutdown = which("shutdown") or "/usr/bin/shutdown"
    cmds = [["sudo", "-n", shutdown, "-c"], [shutdown, "-c"]]
    for cmd in cmds:
        try:
            subprocess.run(cmd, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        except FileNotFoundError:
            continue


def logout_session() -> None:
    if which("hyprctl"):
        subprocess.run(["hyprctl", "dispatch", "exit"],
                       stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        return
    sid = os.environ.get("XDG_SESSION_ID")
    if sid and which("loginctl"):
        subprocess.run(["loginctl", "terminate-session", sid],
                       stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)


def countdown_poweroff(seconds: int, reason: str) -> None:
    for left in range(seconds, 0, -1):
        print(f"{APP}: {reason}; powering off in {left}s", flush=True)
        time.sleep(1)
    kill_now(load_config().get("hard_poweroff", True), reason)


def prompt_cmd(args: argparse.Namespace) -> None:
    cfg = load_config()
    ensure_dirs()

    if safe_session_active() and not args.force:
        print(f"{APP}: safe-session is active; prompt suppressed.")
        return

    lock_handle = PROMPT_LOCK_PATH.open("w")
    try:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"{APP}: another prompt is already active.")
        return

    deadline_seconds = int(cfg.get("prompt_deadline_seconds", 300))
    deadline = time.monotonic() + deadline_seconds
    attempts = 3

    print(f"{APP}: authentication required ({args.reason}).")
    print(f"Timeout: {format_seconds(deadline_seconds)}. Attempts: {attempts}.")

    for attempt in range(1, attempts + 1):
        remaining = int(deadline - time.monotonic())
        if remaining <= 0:
            break
        secret = read_secret(f"Passphrase [{attempt}/{attempts}]: ", remaining)
        if secret is None:
            break
        if verify_passphrase(secret, cfg):
            mark_authenticated()
            cancel_shutdown()
            print(f"{APP}: authentication accepted.")
            notify(f"{APP}: authentication accepted.")
            return
        print(f"{APP}: authentication failed.")

    if time.monotonic() >= deadline:
        print(f"{APP}: prompt ignored for too long.")
        schedule_shutdown(int(cfg.get("post_logout_shutdown_seconds", 300)))
        logout_session()
        return

    countdown = int(cfg.get("failed_attempt_shutdown_seconds", 5))
    countdown_poweroff(countdown, "three failed authentication attempts")


# ---------------------------------------------------------------------------
# Hyprland and hypridle integration
# ---------------------------------------------------------------------------


def write_hypr_conf() -> None:
    HYPR_CONF_PATH.parent.mkdir(parents=True, exist_ok=True)
    content = f"""# Generated by {APP}.
# Source this file from ~/.config/hypr/hyprland.conf, for example:
# source = ~/.config/hypr/conf.d/luks-guard.conf

exec-once = {Path(sys.argv[0]).resolve()} daemon
exec-once = {Path(sys.argv[0]).resolve()} hypridle-start

# Immediate confidentiality-first poweroff. This is intentionally abrupt.
bindl = $mainMod SHIFT, ESCAPE, exec, {Path(sys.argv[0]).resolve()} kill-now --hard --reason keybind
"""
    HYPR_CONF_PATH.write_text(content, encoding="utf-8")


def write_hypridle_conf() -> None:
    cfg = load_config()
    HYPRIDLE_CONF_PATH.parent.mkdir(parents=True, exist_ok=True)
    timeout = int(cfg.get("idle_seconds", 7200))
    content = f"""# Generated by {APP}.
# This separate hypridle instance only handles the encrypted-system guard.

general {{
    ignore_dbus_inhibit = false
}}

listener {{
    timeout = {timeout}
    on-timeout = {Path(sys.argv[0]).resolve()} ensure-prompt --reason idle
}}
"""
    HYPRIDLE_CONF_PATH.write_text(content, encoding="utf-8")


def hypridle_start_cmd(_: argparse.Namespace) -> None:
    cfg = load_config()
    if not cfg.get("idle_enabled", True):
        return
    if safe_session_active():
        return
    if not which("hypridle"):
        notify(f"{APP}: hypridle not found; idle kill-switch inactive.",
               "critical")
        return
    write_hypridle_conf()
    if HYPRIDLE_PID_PATH.exists():
        try:
            old_pid = int(HYPRIDLE_PID_PATH.read_text().strip())
            os.kill(old_pid, signal.SIGTERM)
        except Exception:
            pass
    proc = subprocess.Popen(
        ["hypridle", "-c", str(HYPRIDLE_CONF_PATH)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    HYPRIDLE_PID_PATH.write_text(str(proc.pid), encoding="utf-8")


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def install_cmd(args: argparse.Namespace) -> None:
    cfg = load_config()
    detected = detect_luks_devices()
    if args.luks_device:
        cfg["luks_devices"] = args.luks_device
    elif not cfg.get("luks_devices") and detected:
        cfg["luks_devices"] = detected
    apply_time_options(cfg, args)
    save_config(cfg)
    write_hypr_conf()
    write_hypridle_conf()
    print(f"Config written: {CONFIG_PATH}")
    print(f"Hyprland snippet written: {HYPR_CONF_PATH}")
    print(f"Hypridle config written: {HYPRIDLE_CONF_PATH}")
    if detected:
        print("Detected LUKS devices:")
        for dev in detected:
            print(f"  {dev}")
    print("Remember to source the Hyprland snippet from hyprland.conf.")


def apply_time_options(cfg: dict[str, Any], args: argparse.Namespace) -> None:
    if getattr(args, "idle", None) is True:
        cfg["idle_enabled"] = True
    if getattr(args, "idle", None) is False:
        cfg["idle_enabled"] = False

    hours = int(getattr(args, "hours", 0) or 0)
    minutes = int(getattr(args, "minutes", 0) or 0)
    seconds = int(getattr(args, "seconds", 0) or 0)
    total = seconds_from_parts(hours, minutes, seconds)
    if total > 0:
        if getattr(args, "reoccur", False):
            cfg["reoccur_enabled"] = True
            cfg["reoccur_seconds"] = total
        else:
            cfg["idle_seconds"] = total

    if getattr(args, "no_reoccur", False):
        cfg["reoccur_enabled"] = False
        cfg["reoccur_seconds"] = 0


def configure_cmd(args: argparse.Namespace) -> None:
    cfg = load_config()
    apply_time_options(cfg, args)
    save_config(cfg)
    write_hypridle_conf()
    print(f"Updated: {CONFIG_PATH}")
    print(f"idle_enabled={cfg['idle_enabled']}")
    print(f"idle_seconds={cfg['idle_seconds']} ({format_seconds(cfg['idle_seconds'])})")
    print(f"reoccur_enabled={cfg['reoccur_enabled']}")
    print(f"reoccur_seconds={cfg['reoccur_seconds']} "
          f"({format_seconds(cfg['reoccur_seconds'])})")
    if getattr(args, "restart_hypridle", False):
        if safe_session_active():
            print("hypridle: not restarted because safe-session is active")
        elif not cfg.get("idle_enabled", True):
            print("hypridle: not restarted because idle guard is disabled")
        else:
            hypridle_start_cmd(argparse.Namespace())
            print("hypridle: restart requested")


def safe_session_cmd(args: argparse.Namespace) -> None:
    ensure_dirs()
    mode = str(getattr(args, "mode", "on") or "on").lower()
    if mode not in ("on", "off"):
        eprint(f"{APP}: safe-session mode must be 'on' or 'off'.")
        raise SystemExit(2)

    if args.off or mode == "off":
        SAFE_PATH.unlink(missing_ok=True)
        print(f"{APP}: safe-session disabled.")
        return

    payload = {
        "created_epoch": time.time(),
        "boot_id": current_boot_id(),
        "session_id": current_session_id(),
    }
    SAFE_PATH.write_text(json.dumps(payload, indent=2) + "\n",
                         encoding="utf-8")
    print(f"{APP}: safe-session enabled for this user session.")
    print("Idle and recurring prompts are suppressed; key-bound poweroff remains.")


def ensure_prompt_cmd(args: argparse.Namespace) -> None:
    if safe_session_active() and not args.force:
        return
    age = last_auth_age()
    if age is None or args.force:
        launch_prompt(args.reason, force=args.force)
        return
    launch_prompt(args.reason, force=True)


def daemon_cmd(_: argparse.Namespace) -> None:
    ensure_dirs()
    lock = LOCK_PATH.open("w")
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return

    cfg = load_config()
    start = time.monotonic()
    prompted_at_start = False

    while True:
        cfg = load_config()
        if safe_session_active():
            time.sleep(5)
            continue

        age = last_auth_age()
        if age is None and not prompt_already_running():
            grace = int(cfg.get("startup_grace_seconds", 60))
            if terminal_is_open(cfg) or time.monotonic() - start >= grace:
                if not prompted_at_start:
                    launch_prompt("startup", force=True)
                    prompted_at_start = True

        if cfg.get("reoccur_enabled") and age is not None:
            recur = int(cfg.get("reoccur_seconds", 0))
            if recur > 0 and age >= recur and not prompt_already_running():
                launch_prompt("reoccur", force=True)

        time.sleep(5)


def kill_cmd(args: argparse.Namespace) -> None:
    kill_now(args.hard, args.reason)


def status_cmd(_: argparse.Namespace) -> None:
    cfg = load_config()
    age = last_auth_age()
    print(f"config: {CONFIG_PATH}")
    print(f"safe_session: {safe_session_active()}")
    print(f"last_auth_age: {format_seconds(age) if age is not None else 'never'}")
    print(f"idle_enabled: {cfg.get('idle_enabled')}")
    print(f"idle_seconds: {cfg.get('idle_seconds')} "
          f"({format_seconds(int(cfg.get('idle_seconds', 0)))})")
    print(f"reoccur_enabled: {cfg.get('reoccur_enabled')}")
    print(f"reoccur_seconds: {cfg.get('reoccur_seconds')} "
          f"({format_seconds(int(cfg.get('reoccur_seconds', 0)))})")
    print("luks_devices:")
    for dev in cfg.get("luks_devices", []):
        print(f"  {dev}")


def detect_cmd(_: argparse.Namespace) -> None:
    for dev in detect_luks_devices():
        print(dev)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


class VerboseHelpFormatter(argparse.ArgumentDefaultsHelpFormatter,
                           argparse.RawDescriptionHelpFormatter):
    """Argparse formatter preserving examples while showing defaults."""


def parser_kwargs(description: str, epilog: str = "") -> dict[str, Any]:
    return {
        "description": description,
        "epilog": epilog,
        "formatter_class": VerboseHelpFormatter,
    }


def add_time_flags(parser: argparse.ArgumentParser) -> None:
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--idle",
        dest="idle",
        action="store_true",
        help="enable the idle guard",
    )
    group.add_argument(
        "--no-idle",
        dest="idle",
        action="store_false",
        help="disable idle prompting, but leave other commands available",
    )
    parser.set_defaults(idle=None)
    parser.add_argument(
        "-H",
        "--hours",
        type=int,
        default=0,
        metavar="N",
        help="hours to add to the interval being configured",
    )
    parser.add_argument(
        "-M",
        "--minutes",
        type=int,
        default=0,
        metavar="N",
        help="minutes to add to the interval being configured",
    )
    parser.add_argument(
        "-S",
        "--seconds",
        type=int,
        default=0,
        metavar="N",
        help="seconds to add to the interval being configured",
    )
    parser.add_argument(
        "-r",
        "--re-occur",
        dest="reoccur",
        action="store_true",
        help=(
            "apply -H/-M/-S to the recurring prompt interval instead of "
            "the idle interval"
        ),
    )
    parser.add_argument(
        "--no-reoccur",
        action="store_true",
        help="disable recurring prompts and set their interval to zero",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=APP,
        **parser_kwargs(
            "Hyprland session guard for encrypted Arch systems.\n\n"
            "luks-guard is a user-session guard. It can:\n"
            "  * verify that the user still knows a configured LUKS passphrase,\n"
            "  * launch a prompt after startup, idle timeout, or recurring timeout,\n"
            "  * power off quickly after ignored or failed authentication,\n"
            "  * integrate with Hyprland and a separate hypridle instance,\n"
            "  * suppress prompts temporarily with safe-session.\n\n"
            "Security model:\n"
            "  The key-bound poweroff remains active during safe-session.\n"
            "  safe-session only suppresses startup, idle, and recurring prompts.\n"
            "  This does not replace full-disk encryption, screen locking, or backups.",
            "Typical setup:\n"
            "  luks-guard install -H 3 --luks-device /dev/nvme0n1p8\n"
            "  echo 'source = ~/.config/hypr/conf.d/luks-guard.conf' \\\n"
            "    >> ~/.config/hypr/hyprland.conf\n"
            "  hyprctl reload\n\n"
            "Common examples:\n"
            "  luks-guard status\n"
            "  luks-guard detect\n"
            "  luks-guard configure --idle -H 3\n"
            "  luks-guard configure -r -H 1\n"
            "  luks-guard configure --no-reoccur\n"
            "  luks-guard configure --no-idle\n"
            "  luks-guard configure --idle -H 3 --restart-hypridle\n"
            "  luks-guard safe-session\n"
            "  luks-guard safe-session on\n"
            "  luks-guard safe-session off\n"
            "  luks-guard prompt --force --reason manual-test\n"
            "  luks-guard ensure-prompt --force --reason manual-test\n"
            "  luks-guard hypridle-start\n"
            "  luks-guard kill-now --soft --reason test\n\n"
            "Use '<command> --help' for command-specific details.",
        ),
    )
    sub = parser.add_subparsers(
        dest="cmd",
        required=True,
        metavar="COMMAND",
        title="commands",
    )

    p = sub.add_parser(
        "install",
        help="write config and Hyprland snippets",
        **parser_kwargs(
            "Install or refresh luks-guard user configuration.\n\n"
            "This writes:\n"
            "  * ~/.config/luks-guard/config.json\n"
            "  * ~/.config/hypr/conf.d/luks-guard.conf\n"
            "  * ~/.config/hypr/luks-guard-hypridle.conf\n\n"
            "It does not install a system service. Hyprland starts the daemon "
            "and hypridle integration from the generated snippet.",
            "Examples:\n"
            "  luks-guard install\n"
            "  luks-guard install -H 3\n"
            "  luks-guard install --luks-device /dev/nvme0n1p8\n"
            "  luks-guard install --luks-device /dev/nvme0n1p8 \\\n"
            "    --luks-device /dev/nvme0n1p11 -H 3\n\n"
            "After install, source the generated Hyprland snippet from "
            "hyprland.conf, then reload Hyprland.",
        ),
    )
    add_time_flags(p)
    p.add_argument(
        "--luks-device",
        action="append",
        default=[],
        metavar="PATH",
        help=(
            "LUKS block device to test with cryptsetup open "
            "--test-passphrase; may be repeated"
        ),
    )
    p.set_defaults(func=install_cmd)

    p = sub.add_parser(
        "configure",
        help="change idle and recurring prompt settings",
        **parser_kwargs(
            "Change timing and enablement settings in config.json.\n\n"
            "Without -r/--re-occur, -H/-M/-S configure the idle interval.\n"
            "With -r/--re-occur, -H/-M/-S configure the recurring interval.\n"
            "--no-reoccur disables recurring prompts and sets the interval to 0.\n"
            "--no-idle disables idle prompts but does not disable manual prompts "
            "or the key-bound poweroff.",
            "Examples:\n"
            "  luks-guard configure --idle -H 3\n"
            "  luks-guard configure -H 2 -M 30\n"
            "  luks-guard configure -r -H 1\n"
            "  luks-guard configure --no-reoccur\n"
            "  luks-guard configure --no-idle\n"
            "  luks-guard configure --idle -H 3 --restart-hypridle\n\n"
            "Note:\n"
            "  'configure hypridle-start' is invalid. Use 'hypridle-start' as "
            "its own command, or pass --restart-hypridle to configure.",
        ),
    )
    add_time_flags(p)
    p.add_argument(
        "--restart-hypridle",
        action="store_true",
        help="restart the guard's separate hypridle instance after writing config",
    )
    p.set_defaults(func=configure_cmd)

    p = sub.add_parser(
        "safe-session",
        help="temporarily suppress prompts for this Hyprland session",
        **parser_kwargs(
            "Enable or disable safe-session.\n\n"
            "When enabled, startup, idle, and recurring prompts are suppressed.\n"
            "The immediate key-bound poweroff remains active.\n\n"
            "The marker is tied to the current boot/session when those IDs are "
            "available, so it should not silently persist into a later session.",
            "Examples:\n"
            "  luks-guard safe-session\n"
            "  luks-guard safe-session on\n"
            "  luks-guard safe-session off\n"
            "  luks-guard safe-session --off\n\n"
            "Use this when you deliberately want uninterrupted work and accept "
            "that automatic prompts are paused.",
        ),
    )
    p.add_argument(
        "mode",
        nargs="?",
        metavar="{on,off}",
        help="optional state; omitted or 'on' enables, 'off' disables",
    )
    p.add_argument(
        "--off",
        action="store_true",
        help="disable safe-session; equivalent to 'safe-session off'",
    )
    p.set_defaults(func=safe_session_cmd)

    p = sub.add_parser(
        "prompt",
        help="run the authentication prompt in the current terminal",
        **parser_kwargs(
            "Run the LUKS authentication prompt in the current terminal.\n\n"
            "A successful passphrase updates last_auth_age. Three failed "
            "attempts trigger the configured poweroff countdown. If the prompt "
            "times out, luks-guard schedules shutdown and logs out the session.",
            "Examples:\n"
            "  luks-guard prompt\n"
            "  luks-guard prompt --reason manual-test\n"
            "  luks-guard prompt --force --reason safe-session-test\n\n"
            "--force bypasses safe-session suppression.",
        ),
    )
    p.add_argument(
        "--force",
        action="store_true",
        help="run even when safe-session is active",
    )
    p.add_argument(
        "--reason",
        default="manual",
        metavar="TEXT",
        help="reason shown in the prompt and notifications",
    )
    p.set_defaults(func=prompt_cmd)

    p = sub.add_parser(
        "ensure-prompt",
        help="launch the prompt in a configured terminal",
        **parser_kwargs(
            "Launch the authentication prompt in a new terminal.\n\n"
            "This is the command used by hypridle and the daemon. It avoids "
            "running directly inside Hyprland hooks and uses the configured "
            "terminal_order.",
            "Examples:\n"
            "  luks-guard ensure-prompt\n"
            "  luks-guard ensure-prompt --reason idle\n"
            "  luks-guard ensure-prompt --force --reason manual-test\n\n"
            "If safe-session is active, this exits silently unless --force is used.",
        ),
    )
    p.add_argument(
        "--force",
        action="store_true",
        help="launch even when safe-session is active",
    )
    p.add_argument(
        "--reason",
        default="manual",
        metavar="TEXT",
        help="reason passed to the prompt",
    )
    p.set_defaults(func=ensure_prompt_cmd)

    p = sub.add_parser(
        "daemon",
        help="run the Hyprland session monitor loop",
        **parser_kwargs(
            "Run the foreground session monitor.\n\n"
            "Hyprland normally starts this with exec-once. It checks startup "
            "authentication and recurring prompts. True idle detection is "
            "handled by hypridle-start and hypridle, not by this loop.",
            "Examples:\n"
            "  luks-guard daemon\n\n"
            "For normal use, do not run this manually except while debugging.",
        ),
    )
    p.set_defaults(func=daemon_cmd)

    p = sub.add_parser(
        "hypridle-start",
        help="start the guard's separate hypridle instance",
        **parser_kwargs(
            "Start or restart the guard's separate hypridle instance.\n\n"
            "The generated hypridle config calls 'ensure-prompt --reason idle' "
            "after idle_seconds. This command is normally started by Hyprland "
            "from the generated snippet.",
            "Examples:\n"
            "  luks-guard hypridle-start\n"
            "  luks-guard configure --idle -H 3 --restart-hypridle\n\n"
            "If safe-session is active or idle is disabled, this command exits "
            "without starting hypridle.",
        ),
    )
    p.set_defaults(func=hypridle_start_cmd)

    p = sub.add_parser(
        "kill-now",
        help="trigger immediate poweroff",
        **parser_kwargs(
            "Trigger the kill-switch immediately.\n\n"
            "By default this uses systemctl poweroff --force --force via sudo "
            "when possible. --soft requests a less abrupt systemctl poweroff.",
            "Examples:\n"
            "  luks-guard kill-now --reason keybind\n"
            "  luks-guard kill-now --soft --reason test\n\n"
            "Warning:\n"
            "  The default hard mode is intentionally abrupt. Use it only for "
            "the confidentiality-first case.",
        ),
    )
    p.add_argument(
        "--hard",
        action="store_true",
        help="use forced poweroff when possible",
    )
    p.add_argument(
        "--soft",
        dest="hard",
        action="store_false",
        help="request normal system poweroff instead of forced poweroff",
    )
    p.add_argument(
        "--reason",
        default="manual",
        metavar="TEXT",
        help="reason included in the notification",
    )
    p.set_defaults(hard=True, func=kill_cmd)

    p = sub.add_parser(
        "status",
        help="show current state and configured devices",
        **parser_kwargs(
            "Print current luks-guard state.\n\n"
            "This shows the config path, safe-session state, last successful "
            "authentication age, idle settings, recurring settings, and the "
            "configured LUKS devices.",
            "Examples:\n"
            "  luks-guard status\n",
        ),
    )
    p.set_defaults(func=status_cmd)

    p = sub.add_parser(
        "detect",
        help="print detected LUKS block devices",
        **parser_kwargs(
            "Detect LUKS devices using lsblk JSON output.\n\n"
            "Only devices with FSTYPE=crypto_LUKS are printed. This is a "
            "convenience helper for choosing --luks-device values.",
            "Examples:\n"
            "  luks-guard detect\n"
            "  luks-guard install --luks-device $(luks-guard detect | head -n 1)\n",
        ),
    )
    p.set_defaults(func=detect_cmd)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.func(args)
    except KeyboardInterrupt:
        print(f"\n{APP}: interrupted.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
