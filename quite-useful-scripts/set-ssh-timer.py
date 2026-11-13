#!/usr/bin/env python3
"""
ssh_time.py: Add an SSH key with a specified lifetime.

Usage:
    ssh_time.py [-s SECONDS] [-m MINUTES] [-H HOURS] [--key /path/to/key]

At least one time option must be provided.
The key path is optional and defaults to $HOME/.ssh/id_rsa.
"""

import argparse
import os
import subprocess
import sys

def parse_arguments():
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description='Add SSH key with specified lifetime.'
    )
    parser.add_argument('-s', '--seconds', type=int, default=0, help='Lifetime in seconds')
    parser.add_argument('-m', '--minutes', type=int, default=0, help='Lifetime in minutes')
    parser.add_argument('-H', '--hours', type=int, default=0, help='Lifetime in hours')
    parser.add_argument('--key', type=str, default=os.path.join(os.environ.get("HOME", ""), ".ssh/id_rsa"),
                        help='Path to the SSH key (default: ~/.ssh/id_rsa)')
    args = parser.parse_args()

    # Validate that at least one time argument is non-zero.
    if args.seconds == 0 and args.minutes == 0 and args.hours == 0:
        parser.error('At least one of the options -s/--seconds, -m/--minutes, or -H/--hours must be provided.')
    return args

def compute_total_seconds(seconds, minutes, hours):
    """Compute the total lifetime in seconds."""
    return seconds + minutes * 60 + hours * 3600

def format_time(total_seconds):
    """Return a formatted string representing the lifetime."""
    if total_seconds < 60:
        minutes_float = total_seconds / 60
        return f"Time: {total_seconds} seconds ({minutes_float:.2f} minutes)"
    elif total_seconds < 3600:
        minutes_int = total_seconds // 60
        remaining_seconds = total_seconds % 60
        hours_float = total_seconds / 3600
        return f"Time: {minutes_int} minutes, {remaining_seconds} seconds ({hours_float:.2f} hours)"
    else:
        hours_int = total_seconds // 3600
        remaining_minutes = (total_seconds % 3600) // 60
        remaining_seconds = total_seconds % 60
        return f"Time: {hours_int} hours, {remaining_minutes} minutes, {remaining_seconds} seconds"

def start_ssh_agent():
    """Start an SSH agent if one is not already running."""
    if 'SSH_AUTH_SOCK' not in os.environ:
        process = subprocess.run(['ssh-agent', '-s'], capture_output=True, text=True)
        output = process.stdout
        # Evaluate output (e.g., set environment variables) if needed.
        # For simplicity, we assume the user's shell will pick it up.
        print(output.strip())

def add_ssh_key(total_seconds, key_path):
    """Add the SSH key with the specified timeout."""
    print(f"Adding key: {key_path} with lifetime set to {total_seconds} seconds")
    subprocess.run(['ssh-add', '-t', str(total_seconds), key_path])

def main():
    args = parse_arguments()
    total_seconds = compute_total_seconds(args.seconds, args.minutes, args.hours)
    start_ssh_agent()
    add_ssh_key(total_seconds, args.key)
    print(format_time(total_seconds))

if __name__ == '__main__':
    main()
