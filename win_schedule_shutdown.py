#!/usr/bin/env python3
import os
import sys
import platform

def schedule_shutdown(time_seconds, restart=False):
    """
    Schedules a shutdown or restart based on the time in seconds.
    """
    try:
        if platform.system() == "Windows":
            # Windows command for shutdown or restart
            command = f"shutdown /{'r' if restart else 's'} /t {time_seconds}"
        else:
            # Linux/Mac command for shutdown or restart
            command = f"sudo shutdown {'-r' if restart else ''} +{time_seconds // 60}"

        print(f"Executing: {command}")
        os.system(command)
    except Exception as e:
        print(f"Error scheduling shutdown: {e}")

def main():
    """
    Main function to handle arguments and perform actions.
    """
    if len(sys.argv) < 3:
        print("Usage: schedule_shutdown.py <time> <unit> [--restart]")
        print("<time>: The time value (integer or float).")
        print("<unit>: 'seconds' or 'minutes'.")
        print("--restart: Optional flag to schedule a restart instead of a shutdown.")
        sys.exit(1)

    try:
        # Parse arguments
        time_value = float(sys.argv[1])
        time_unit = sys.argv[2].lower()
        restart = "--restart" in sys.argv

        # Convert minutes to seconds if needed
        if time_unit == "minutes":
            time_seconds = int(time_value * 60)
        elif time_unit == "seconds":
            time_seconds = int(time_value)
        else:
            print("Invalid unit. Use 'seconds' or 'minutes'.")
            sys.exit(1)

        # Confirm and schedule shutdown/restart
        print(f"Scheduling a {'restart' if restart else 'shutdown'} in {time_seconds} seconds.")
        schedule_shutdown(time_seconds, restart)

    except ValueError:
        print("Invalid time value. Please provide a number.")
        sys.exit(1)

if __name__ == "__main__":
    main()
