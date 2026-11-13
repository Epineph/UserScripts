#!/usr/bin/env python3
"""
Hyprland Monitor Configuration Control Utility

This script manages monitor configurations using Hyprland's controller 'hyprctl'.
It supports enabling and disabling monitors and now integrates an HDMI-A-1 flag.
It is intended to be bound to key combinations—one for turning off HDMI-A-1 and one for turning it on.

Usage Examples:
    Disable HDMI-A-1:
        ./monitor_control.py disable --hdmi
    Enable HDMI-A-1 (with force):
        ./monitor_control.py enable -f --hdmi

Optional Flags:
    --hdmi          Override the monitor name to "HDMI-A-1".
    --force, -f     Force configuration reload if the monitor is already enabled.
    --defaults      Use preferred auto configuration if no state file is found.
"""

import sys
import json
import typing
import argparse
import subprocess
import tempfile
from enum import Enum
from pathlib import Path
from subprocess import CalledProcessError


class Command(Enum):
    ENABLE = 'enable'
    DISABLE = 'disable'

    def __str__(self):
        return self.name.lower()


def main(
    command: Command,
    monitor_name: typing.Optional[str] = None,
    *,
    force: bool = False,
    use_defaults: bool = False
):
    # If no monitor name is provided, choose the focused monitor.
    if not monitor_name:
        monitor_name = getFocusedMonitorName()

    # Generate the path to the temporary state file.
    config_file = Path(tempfile.gettempdir()) / f'hyprland-{monitor_name}.state'

    if command == Command.ENABLE:
        enableMonitor(monitor_name, config_file, force=force, use_defaults=use_defaults)
    elif command == Command.DISABLE:
        disableMonitor(monitor_name, config_file)
    else:
        raise RuntimeError(f"Unhandled command ({command})")


def disableMonitor(monitor_name: str, config_file: Path):
    """
    Disables the given monitor.

    Saves the current monitor configuration to a temporary state file for later restoration,
    then issues a hyprctl command to disable the monitor.
    """
    # Save the current monitor configuration in a temporary file.
    config = getMonitorConfig(monitor_name)  # use default behavior (print error if not found)
    if config is None:
        printError(f"Cannot disable monitor because its configuration could not be retrieved ({monitor_name}).")
        return

    with config_file.open('w') as fd:
        json.dump(config, fd)

    try:
        # Execute the hyprctl command to disable the specified monitor.
        subprocess.check_call(f'hyprctl keyword monitor {monitor_name},disable', shell=True)
    except CalledProcessError as e:
        raise RuntimeError(f"Error executing hyprctl command: {e}")


def enableMonitor(
    monitor_name: str,
    config_file: Path,
    *,
    force: bool = False,
    use_defaults: bool = False
):
    """
    Enables a monitor by restoring its previous configuration.

    If a state file exists, it restores the monitor's configuration. With the '--defaults'
    flag, it falls back to a default auto-configuration if no state file is found.
    """
    # Instead of throwing an error when the monitor is not active, we call getMonitorConfig with silent=True.
    current_config = getMonitorConfig(monitor_name, silent=True)
    if current_config is not None and not force:
        printError("Monitor is already enabled. Use '-f' or '--force' if you want to override the current configuration.")
        return

    try:
        if not config_file.exists():
            if not use_defaults:
                printError("Unable to find monitor state file. Use '--defaults' to use preferred auto configuration instead.")
                return
            # Use default configuration if state file is missing.
            subprocess.check_call(f'hyprctl keyword monitor {monitor_name},preferred,auto,1', shell=True)
        else:
            # Load the saved monitor configuration.
            with config_file.open('r') as fd:
                monitor = json.load(fd)

            # Format the monitor configuration string.
            monitor_cfg = '{name},{width}x{height}@{refresh_rate},{x}x{y},{scale}'.format(
                name=monitor['name'],
                width=monitor['width'],
                height=monitor['height'],
                refresh_rate=monitor['refreshRate'],
                x=monitor['x'],
                y=monitor['y'],
                scale=monitor['scale']
            )

            subprocess.check_call(f'hyprctl keyword monitor {monitor_cfg}', shell=True)
    except CalledProcessError as e:
        raise RuntimeError(f"Error executing hyprctl command: {e}")


def getFocusedMonitorName() -> str:
    """
    Returns the name of the currently focused monitor, based on hyprctl's JSON output.
    """
    try:
        monitor = next((m for m in getMonitors() if m.get('focused')), None)
        if not monitor:
            raise RuntimeError("No monitor is focused")
        else:
            return monitor['name']
    except CalledProcessError as e:
        raise RuntimeError(f"Error executing hyprctl command: {e}")


def getMonitorConfig(name: typing.Optional[str] = None, silent: bool = False) -> typing.Any:
    """
    Retrieves the configuration for a monitor with the specified name.

    If silent is False and the monitor is not found, an error is printed.
    """
    try:
        monitor = next((m for m in getMonitors() if m.get('name') == name), None)
        if monitor is None and not silent:
            printError(f"Invalid monitor name specified ({name})")
        return monitor
    except CalledProcessError as e:
        raise RuntimeError(f"Error executing hyprctl command: {e}")


def getMonitors() -> typing.Any:
    """
    Retrieves the list of current monitors and their properties from hyprctl in JSON format.
    """
    return json.loads(subprocess.check_output('hyprctl monitors -j', shell=True))


def printError(*args, **kwargs):
    """
    Helper function to print error messages to stderr.
    """
    print(*args, file=sys.stderr, **kwargs)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description="Hyprland Monitor Configuration Control Utility with HDMI-A-1 integration."
    )

    # Positional argument for command (enable/disable).
    parser.add_argument('command', choices=list(Command), type=Command,
                        help="Action to perform on the monitor (enable or disable)")
    # Optional positional argument for monitor name.
    parser.add_argument('monitor', nargs='?',
                        help="The name of the monitor (e.g., DP-1, HDMI-A-1). "
                             "Defaults to the focused monitor unless overridden by '--hdmi'.")
    # New flag to target HDMI-A-1 specifically.
    parser.add_argument('--hdmi', action='store_true',
                        help="Target the HDMI-A-1 monitor specifically. "
                             "Overrides any provided monitor name with 'HDMI-A-1'.")
    parser.add_argument('--force', '-f', dest='force', action='store_true',
                        help="Force configuration reload if the monitor is already enabled")
    parser.add_argument('--defaults', dest='defaults', action='store_true',
                        help="Use preferred auto configuration if no state file is found")

    args = parser.parse_args()

    # If '--hdmi' is set, force the monitor name to "HDMI-A-1".
    if args.hdmi:
        if args.monitor and args.monitor != "HDMI-A-1":
            printError("Warning: '--hdmi' flag is set. Overriding provided monitor name with 'HDMI-A-1'.")
        monitor_arg = "HDMI-A-1"
    else:
        monitor_arg = args.monitor

    # Call the main function with parsed arguments.
    main(args.command, monitor_arg, force=args.force, use_defaults=args.defaults)

