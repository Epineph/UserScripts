# Temporary console workloads

Run from a terminal in Hyprland, without prefixing the wrapper with sudo:

```bash
cd ~/my_repos/UserScripts
./tty-ionice.sh --dry-run -- ninja -C "$HOME/llvm-build" -j 4
./tty-ionice.sh -- ninja -C "$HOME/llvm-build" -j 4
```

First try a short visible console check:

```bash
./tty-ionice.sh -- bash -c 'id; ionice -p $$; sleep 5'
```

`--help` documents every option and the environment and recovery behavior.
The wrapper uses `openvt -s -w` to allocate an unused VT and return afterwards.
It does not force an occupied VT, stop SDDM, or change systemd settings.
Privilege is dropped with `runuser` before running the supplied command.
Arguments are passed separately, not evaluated as shell code. The command's
exit status is recorded separately because the launcher status is insufficient.

The desktop remains alive. Switching consoles does not reclaim its RAM or stop
background applications. Close unnecessary applications first. This is not a
promise of faster compilation: CPU, RAM, thermal limits and disk scheduling
determine the benefit. Class 2, priority 0 is highest *best-effort I/O* priority,
not CPU priority. The host NVMe scheduler was `none` when inspected; do not
assume that setting ionice will improve throughput with that scheduler.

Avoid wrapping the old `building_scripts/build_llvm_v2.sh`: it independently
changes boot targets, CPU governor and swap. Run the build command directly.

## Diagnosis on 2026-11-13

The old LLVM script executes `systemctl set-default multi-user.target` and
`systemctl isolate multi-user.target` in setup. It restores graphical.target
only in the later cleanup function. It uses `set -e`, with no EXIT cleanup
trap: an error skips restoration, and isolating the target can terminate its
own graphical terminal. This explains how the script could leave future boots
in text mode. Its build also explicitly uses ionice priority 7, not 0.

Current live checks found graphical.target as default, SDDM enabled/running,
and a successful SDDM launch of start-hyprland on tty1. No boot repair needed.

Hypridle requests locking after 600 seconds. Hyprlock authenticates through
PAM's login stack; the current faillock counter was empty. The historical
password failure is not established by these checks. Polkit is a separate
authorization path. The configured bare `hyprpolkitagent` command is absent
from PATH; the installed executable is under /usr/lib/hyprpolkitagent, and
its user service was inactive. This is a separate configuration finding,
not evidence that polkit caused the old lock-screen password failures.

No boot, PAM, scheduler or desktop configuration was modified. Real console
switching and interactive password entry require a user-observed check.

References: [systemctl](https://www.freedesktop.org/software/systemd/man/latest/systemctl),
and the installed `man openvt`, `man ionice`, `man runuser`.
