#!/usr/bin/env python3
"""
Hyprland Monitor Configuration Control Utility

This script manages monitor configurations using Hyprland's controller 'hyprctl'.
It supports:
  - Enabling and disabling monitors
  - Dynamic monitor selection (focused or secondary)
  - Listing connected monitors
  - Temporarily disabling a monitor with automatic re-enable timer
  - Prevention of disabling the last active monitor indefinitely
  - Optional desktop notifications via notify2 or notify-send

Usage Examples:
    List connected monitors:
        ./monitor_control.py --list

    Disable the secondary monitor for default 5 minutes with desktop popup:
        ./monitor_control.py disable --notify

    Disable HDMI-A-1 for 2 hours, 30 minutes and 20 seconds quietly:
        ./monitor_control.py disable --monitor HDMI-A-1 --hours 2 --minutes 30 --seconds 20 --quiet

    Enable DP-1 with defaults:
        ./monitor_control.py enable --monitor DP-1 --defaults

    Show help:
        ./monitor_control.py --help
"""

import sys
import os
import json
import argparse
from argparse import RawDescriptionHelpFormatter
import subprocess
import tempfile
from enum import Enum
from pathlib import Path
from subprocess import CalledProcessError, DEVNULL
import typing

# Attempt to import notify2 for popup notifications
try:
    import notify2
    HAVE_NOTIFY2 = True
except ImportError:
    HAVE_NOTIFY2 = False

# Command actions for enable/disable
class Command(Enum):
    ENABLE = 'enable'
    DISABLE = 'disable'

    def __str__(self):
        return self.name.lower()

# Global flags
QUIET = False
USE_NOTIFY = False
NOTIFY_CMD = ['notify-send', 'Hyprland Monitor Control']


def printError(*args, **kwargs):
    """
    Print error messages to stderr (always shown).
    """
    print(*args, file=sys.stderr, **kwargs)


def notify_popup(message: str) -> None:
    """
    Send a notification via notify2 if available, else fallback to notify-send.
    """
    if HAVE_NOTIFY2:
        try:
            notify2.init("Hyprland Monitor Control")
            n = notify2.Notification("Hyprland Monitor Control", message)
            n.show()
        except Exception:
            pass
    else:
        try:
            subprocess.call(NOTIFY_CMD + [message], stdout=DEVNULL, stderr=DEVNULL)
        except Exception:
            pass


def output(message: str) -> None:
    """
    Display a message either via console or desktop notification.
    """
    if USE_NOTIFY:
        notify_popup(message)
    if not QUIET:
        print(message)


def humanize_duration(total_seconds: int) -> str:
    """
    Convert seconds into human-readable "X hours, Y minutes, Z seconds".
    """
    parts = []
    hours, rem = divmod(total_seconds, 3600)
    minutes, seconds = divmod(rem, 60)
    if hours:
        parts.append(f"{hours} hour{'s' if hours != 1 else ''}")
    if minutes:
        parts.append(f"{minutes} minute{'s' if minutes != 1 else ''}")
    if seconds or not parts:
        parts.append(f"{seconds} second{'s' if seconds != 1 else ''}")
    return ", ".join(parts)


def getMonitors() -> typing.List[dict]:
    """
    Retrieves the list of current monitors and their properties from hyprctl in JSON format.
    """
    try:
        out = subprocess.check_output(['hyprctl', 'monitors', '-j'])
        return json.loads(out)
    except CalledProcessError as e:
        raise RuntimeError(f"Error retrieving monitors: {e}")


def getFocusedMonitorName() -> str:
    monitors = getMonitors()
    focused = next((m for m in monitors if m.get('focused')), None)
    if not focused:
        raise RuntimeError("No focused monitor found")
    return focused['name']


def getSecondaryMonitorName() -> str:
    monitors = getMonitors()
    if len(monitors) > 1:
        sec = next((m for m in monitors if not m.get('focused')), monitors[1])
        return sec['name']
    return getFocusedMonitorName()


def getMonitorConfig(name: str, silent: bool = False) -> typing.Optional[dict]:
    mon = next((m for m in getMonitors() if m.get('name') == name), None)
    if mon is None and not silent:
        printError(f"Invalid monitor name: {name}")
    return mon


def disableMonitor(monitor_name: str, config_file: Path) -> None:
    cfg = getMonitorConfig(monitor_name)
    if cfg is None:
        printError(f"Cannot disable; config not found: {monitor_name}")
        return
    with config_file.open('w') as f:
        json.dump(cfg, f)
    try:
        subprocess.check_call(['hyprctl', 'keyword', 'monitor', f"{monitor_name},disable"])
        output(f"Disabled monitor: {monitor_name}")
    except CalledProcessError as e:
        raise RuntimeError(f"Error disabling: {e}")


def spawn_reenable(script: str, monitor_name: str, delay: int, force: bool, use_defaults: bool) -> None:
    """
    Spawn a background process that sleeps and then re-enables the monitor.
    """
    cmd = [sys.executable, script, 'enable', '--monitor', monitor_name]
    if force:
        cmd.append('--force')
    if use_defaults:
        cmd.append('--defaults')
    wrapper = f"sleep {delay}; {' '.join(cmd)}"
    subprocess.Popen(['sh', '-c', wrapper], stdout=DEVNULL, stderr=DEVNULL)


def enableMonitor(
    monitor_name: str,
    config_file: Path,
    *,
    force: bool = False,
    use_defaults: bool = False
) -> None:
    cur = getMonitorConfig(monitor_name, silent=True)
    if cur is not None and not force:
        printError("Already enabled; use --force to override.")
        return
    try:
        if not config_file.exists():
            if not use_defaults:
                printError("No state file; use --defaults for auto-config.")
                return
            subprocess.check_call(['hyprctl', 'keyword', 'monitor', f"{monitor_name},preferred,auto,1"])
            output(f"Enabled with defaults: {monitor_name}")
        else:
            with config_file.open('r') as f:
                cfg = json.load(f)
            cfg_str = '{name},{width}x{height}@{refresh_rate},{x}x{y},{scale}'.format(
                name=cfg['name'], width=cfg['width'], height=cfg['height'],
                refresh_rate=cfg['refreshRate'], x=cfg['x'], y=cfg['y'], scale=cfg['scale']
            )
            subprocess.check_call(['hyprctl', 'keyword', 'monitor', cfg_str])
            output(f"Restored: {monitor_name}")
    except CalledProcessError as e:
        raise RuntimeError(f"Error enabling: {e}")


def main():
    global QUIET, USE_NOTIFY
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=RawDescriptionHelpFormatter)
    parser.add_argument('--list', action='store_true', help="List monitors and exit.")
    parser.add_argument('command', choices=list(Command), type=Command, nargs='?', help="enable or disable")
    parser.add_argument('--monitor', '-M', help="Monitor name (e.g., DP-1)")
    parser.add_argument('--force', '-f', action='store_true', help="Force reload on enable")
    parser.add_argument('--defaults', action='store_true', help="Use auto-config if no state")
    parser.add_argument('--hours', type=int, help="Hours to wait before re-enable")
    parser.add_argument('--minutes', '-m', type=int, help="Minutes to wait before re-enable")
    parser.add_argument('--seconds', type=int, help="Seconds to wait before re-enable")
    parser.add_argument('--notify', '-N', action='store_true', help="Use desktop notifications and default 5m timer if none specified")
    parser.add_argument('--quiet', action='store_true', help="Suppress console output (implies notify)")
    args = parser.parse_args()
    QUIET = args.quiet
    USE_NOTIFY = args.notify or args.quiet
    if args.list:
        for m in getMonitors():
            output(f"{m['name']}: {m['width']}x{m['height']}@{m['refreshRate']} at {m['x']}x{m['y']}")
        return
    if not args.command:
        parser.print_help()
        return
    mon = args.monitor or getSecondaryMonitorName()
    cfg_file = Path(tempfile.gettempdir()) / f"hyprland-{mon}.state"
    # Compute delay
    delay = ((args.hours or 0) * 3600) + ((args.minutes or 0) * 60) + (args.seconds or 0)
    # Default to 5 minutes when using --notify without explicit timer
    if args.notify and delay == 0 and args.command == Command.DISABLE:
        delay = 5 * 60
    if args.command == Command.DISABLE:
        active = getMonitors()
        names = [m['name'] for m in active]
        if mon not in names:
            printError(f"Not active or already disabled: {mon}")
            return
        if len(active) <= 1 and delay <= 0:
            printError("Cannot disable last monitor indefinitely; specify a timer or use --notify.")
            return
        disableMonitor(mon, cfg_file)
        if delay > 0:
            human = humanize_duration(delay)
            output(f"Will re-enable in {human} ({delay} seconds)")
            spawn_reenable(os.path.abspath(__file__), mon, delay, args.force, args.defaults)
        return
    elif args.command == Command.ENABLE:
        enableMonitor(mon, cfg_file, force=args.force, use_defaults=args.defaults)
        return
    else:
        raise RuntimeError(f"Unknown command: {args.command}")


if __name__ == '__main__':
    main()

