#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ssh-timer — timed ssh-agent key with scheduled Hyprland/Wayland notifications,
            plus rich Markdown/HTML help with formal math (Pandoc + MathJax).

Key features:
  - Fractional H/M/S parsing with exact downward carries (H→M, M→S).
  - ssh-add -t <seconds> lifetime; ensures ssh-agent exists.
  - Notification schedule per your 4 rules (50%, sub-checkpoints, etc.).
  - Output/notification switches: --no-output, --silence-notifications, --quiet.
  - Optional per-second terminal countdown: --timer-output.
  - Rich help:
      * --help-md   : print Markdown help (with TeX math)
      * --help-html : render same help to HTML via pandoc --mathjax and open it

Notes (rendering):
  - Terminal viewers don't render TeX math; use --help-html to see equations.
"""

import argparse
import math
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from typing import List, Optional, Tuple

APP_NAME = "ssh-timer"
DEFAULT_TITLE = "SSH key timer"
DEFAULT_NOTIFY_MS = 6000

HYPR_ICON_INFO = 1
HYPR_ICON_OK = 5
HYPR_ICON_WARN = 0
HYPR_ICON_ERR = 3

CLR_INFO = "rgb(88c0d0)"
CLR_OK = "rgb(a3be8c)"
CLR_WARN = "rgb(ebcb8b)"
CLR_ERR = "rgb(bf616a)"

HELP_MD = r"""
# `ssh-timer` — Formal Notes and Math

This is the **formal specification** for the time normalization used by `ssh-timer`
and the related **error bounds** + **correctness sketches**.

---

## Renderer note

- R/Quarto/Pandoc render TeX math to HTML/PDF (use `--mathjax` or LaTeX).  
  Pandoc manual: <https://pandoc.org/MANUAL.html>

- GitHub Markdown supports TeX math

- Terminal viewers (e.g., `glow`, `bat`) do not render TeX math.

---

## Time normalization (exact real construction)

Given inputs \(H, M, S \in \mathbb{R}_{\ge 0}\).

1. Split hours:
   \[
     H = \lfloor H \rfloor + \{H\}, \quad \{H\} = H - \lfloor H \rfloor.
   \]
2. Push fractional hours into minutes:
   \[
     M' = M + 60\,\{H\}.
   \]
3. Split minutes:
   \[
     M' = \lfloor M' \rfloor + \{M'\}, \quad \{M'\} = M' - \lfloor M' \rfloor.
   \]
4. Push fractional minutes into seconds:
   \[
     S' = S + 60\,\{M'\}.
   \]
5. Exact real seconds before integer cast:
   \[
     T_{\mathrm{sec}} = 3600\,\lfloor H \rfloor + 60\,\lfloor M' \rfloor + S'.
   \]
6. Integer timer:
   \[
     T =
     \begin{cases}
       \mathrm{round}(T_{\mathrm{sec}}) & \text{(round-to-nearest)}\\
       \lfloor T_{\mathrm{sec}} \rfloor & \text{(floor)}
     \end{cases}
   \]

**Compact form**:
\[
T_{\mathrm{sec}} = 3600\lfloor H \rfloor + 60\lfloor M+60\{H\} 
\rfloor + \bigl(S + 60\{\,M+60\{H\}\}\bigr).
\]

No intermediate rounding occurs; only the final integer cast can create error.

---

## Error bounds

- **Rounding to nearest**:
  \[
    |T - T_{\mathrm{sec}}| \le \tfrac{1}{2}\ \text{second}.
  \]
- **Floor**:
  \[
    0 \le T_{\mathrm{sec}} - \lfloor T_{\mathrm{sec}} \rfloor < 1\ \text{second}.
  \]
Thus the maximum error is ≤ 0.5 s (round) or < 1 s (floor).

---

## Correctness sketches

### No double-count (soundness)
Fractional mass flows downward exactly once:
\[
H \to M' \to S'.
\]
Integer contributions are accounted independently:
\[
3600\lfloor H \rfloor,\quad 60\lfloor M' \rfloor,\quad S'.
\]
There is no path for any portion to be added twice, and no upward carry.

### Minimal/canonical representation (uniqueness)
For integer \(T \ge 0\):
\[
h=\bigl\lfloor T/3600 \bigr\rfloor,\; r=T\bmod 3600,\;
m=\bigl\lfloor r/60 \bigr\rfloor,\; s=r\bmod 60
\]
gives the unique \(T=3600h+60m+s\) with \(0\le m<60,\,0\le s<60\).

---

## Worked example

Input \(H=1.6,\;M=2.2,\;S=140\).

\[
\begin{aligned}
\lfloor H \rfloor &= 1,\ \{H\}=0.6, & M' &= 2.2 + 60\cdot 0.6 = 38.2,\\
\lfloor M' \rfloor &= 38,\ \{M'\}=0.2, & S' &= 140 + 60\cdot 0.2 = 152,\\
T_{\mathrm{sec}} &= 3600\cdot 1 + 60\cdot 38 + 152 = 6032.
\end{aligned}
\]

Decomposition: \(6032 = 3600\cdot 1 + 60\cdot 40 + 32 \Rightarrow 1\ 
\mathrm{h},\ 40\ \mathrm{m},\ 32\ \mathrm{s}.\)

---

## Notifications and environment

- Hyprland `hyprctl notify`: <https://wiki.hyprland.org/0.41.2/Configuring/Using-hyprctl/>  
- Wayland notification daemon (e.g., `mako`): <https://man.archlinux.org/man/mako.1.en>  
- SSH lifetime via `ssh-add -t` (seconds or time format): 
  (manpage summary) <https://www.root.cz/man/1/ssh-add/>

"""


def which(cmd: str) -> Optional[str]:
    return shutil.which(cmd)


def in_hyprland() -> bool:
    return (which("hyprctl") is not None) and bool(os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"))


def have_notify_send() -> bool:
    return which("notify-send") is not None


def have_pandoc() -> bool:
    return which("pandoc") is not None


def secs_to_hms(total: int) -> Tuple[int, int, int]:
    h = total // 3600
    r = total % 3600
    m = r // 60
    s = r % 60
    return h, m, s


def fmt_hms(total: int) -> str:
    h, m, s = secs_to_hms(total)
    parts = []
    if h:
        parts.append(f"{h} hour{'s' if h != 1 else ''}")
    if m:
        parts.append(f"{m} minute{'s' if m != 1 else ''}")
    if s or not parts:
        parts.append(f"{s} second{'s' if s != 1 else ''}")
    if len(parts) == 1:
        return parts[0]
    if len(parts) == 2:
        return f"{parts[0]} and {parts[1]}"
    return f"{parts[0]}, {parts[1]}, and {parts[2]}"


def parse_time_to_seconds(hours: float, minutes: float, seconds: float) -> int:
    total_seconds = 0.0
    if hours > 0:
        h_whole = math.floor(hours)
        h_frac = hours - h_whole
        total_seconds += h_whole * 3600
        minutes += h_frac * 60.0
    if minutes > 0:
        m_whole = math.floor(minutes)
        m_frac = minutes - m_whole
        total_seconds += m_whole * 60
        seconds += m_frac * 60.0
    total_seconds += seconds
    return int(round(total_seconds))


class Notifier:
    def __init__(self, mode: str, silence: bool, quiet: bool, title: str):
        self.mode = mode
        self.silence = silence
        self.quiet = quiet
        self.title = title
        if self.mode == "auto":
            if in_hyprland():
                self.mode = "hyprctl"
            elif have_notify_send():
                self.mode = "notify-send"
            else:
                self.mode = "none"

    def _hyprctl(self, msg: str, ms: int, level: str) -> None:
        icon, color = HYPR_ICON_INFO, CLR_INFO
        if level == "ok":
            icon, color = HYPR_ICON_OK, CLR_OK
        if level == "warn":
            icon, color = HYPR_ICON_WARN, CLR_WARN
        if level == "err":
            icon, color = HYPR_ICON_ERR, CLR_ERR
        subprocess.run(
            ["hyprctl", "notify", str(icon), str(ms), color, f"{self.title}: {msg}"], check=False
        )

    def _notify_send(self, msg: str, ms: int, level: str) -> None:
        urgency = {"ok": "low", "warn": "normal", "err": "critical"}.get(level, "normal")
        subprocess.run(
            ["notify-send", "--app-name", APP_NAME, "-u", urgency, "-t", str(ms), self.title, msg],
            check=False,
        )

    def send(
        self,
        msg: str,
        ms: int = DEFAULT_NOTIFY_MS,
        level: str = "info",
        force_final_under_quiet: bool = False,
    ) -> None:
        if self.silence:
            return
        if self.quiet and not force_final_under_quiet:
            return
        if self.mode == "hyprctl":
            self._hyprctl(msg, ms, level)
        elif self.mode == "notify-send":
            self._notify_send(msg, ms, level)
        else:
            # no backend: as a last resort
            sys.stderr.write(f"[{APP_NAME}] {msg}\n")


def ensure_ssh_agent() -> None:
    def agent_ok() -> bool:
        try:
            res = subprocess.run(
                ["ssh-add", "-l"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            return res.returncode in (0, 1)
        except FileNotFoundError:
            return False

    if agent_ok():
        return
    p = subprocess.run(["ssh-agent", "-s"], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("Failed to start ssh-agent")
    for line in p.stdout.splitlines():
        if "SSH_AUTH_SOCK" in line:
            os.environ["SSH_AUTH_SOCK"] = (
                line.split("SSH_AUTH_SOCK=", 1)[1].split(";", 1)[0].strip()
            )
        if "SSH_AGENT_PID" in line:
            os.environ["SSH_AGENT_PID"] = (
                line.split("SSH_AGENT_PID=", 1)[1].split(";", 1)[0].strip()
            )


def pick_default_key() -> Optional[str]:
    home = os.path.expanduser("~")
    for cand in (os.path.join(home, ".ssh", "id_ed25519"), os.path.join(home, ".ssh", "id_rsa")):
        if os.path.exists(cand):
            return cand
    return None


def add_key_with_lifetime(key_path: str, lifetime_seconds: int) -> None:
    # ssh-add -t accepts seconds or sshd_config(5) time formats; we pass seconds
    res = subprocess.run(["ssh-add", "-t", str(lifetime_seconds), key_path])
    if res.returncode != 0:
        raise RuntimeError("ssh-add failed")


def schedule_points_remaining(total: int) -> List[int]:
    pts = set()
    t = total

    def add(x: int):
        if 0 < x < t:
            pts.add(int(x))

    if 7200 > t >= 3600:
        add(int(t * 0.5))
        add(int(t * 0.1))  # 20% of 50% = 10% total
        add(600)
        add(180)
    elif 3600 > t >= 1800:
        add(int(t * 0.5))
        add(int(t * 0.25))
        add(300)
    elif 1800 > t >= 900:
        add(int(t * 0.5))
        add(180)
    elif 900 > t > 480:
        add(int(t * 0.5))
        add(15)
    pts.add(0)
    return sorted(pts, reverse=True)


def run_timer(total_seconds: int, notifier: Notifier, show_timer: bool, allow_output: bool) -> None:
    checkpoints = schedule_points_remaining(total_seconds)
    end_time = time.monotonic() + total_seconds
    events = [(end_time - rem, rem) for rem in sorted(checkpoints, reverse=True)]
    next_idx = 0
    interrupted = {"flag": False}

    def _sigint(_s, _f):
        interrupted["flag"] = True

    signal.signal(signal.SIGINT, _sigint)

    if not allow_output:
        notifier.send(f"SSH timer set for {fmt_hms(total_seconds)}", level="ok")
    if show_timer and allow_output:
        print(f"Countdown: {fmt_hms(total_seconds)}")

    if show_timer and allow_output:
        last = None
        while True:
            if interrupted["flag"]:
                notifier.send("Timer interrupted", level="warn")
                print("\n[interrupted]")
                return
            now = time.monotonic()
            remaining = max(0, int(round(end_time - now)))
            while next_idx < len(events) and now >= events[next_idx][0]:
                rem = events[next_idx][1]
                msg = "Time up!" if rem == 0 else f"Time remaining: {fmt_hms(rem)}"
                notifier.send(
                    msg, level=("ok" if rem == 0 else "info"), force_final_under_quiet=(rem == 0)
                )
                next_idx += 1
            if remaining != last and allow_output:
                print(f"\rT–{fmt_hms(remaining):<20}", end="", flush=True)
                last = remaining
            if remaining <= 0 and next_idx >= len(events):
                if allow_output:
                    print("\n[done]")
                return
            time.sleep(1.0)
    else:
        while next_idx < len(events):
            target_t, rem = events[next_idx]
            now = time.monotonic()
            if now < target_t:
                time.sleep(target_t - now)
            msg = "Time up!" if rem == 0 else f"Time remaining: {fmt_hms(rem)}"
            notifier.send(
                msg, level=("ok" if rem == 0 else "info"), force_final_under_quiet=(rem == 0)
            )
            next_idx += 1


def render_help_html() -> int:
    """Render HELP_MD to HTML using pandoc --mathjax; open if possible."""
    if not have_pandoc():
        print("ERROR: pandoc not found. Install pandoc to use --help-html.", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory() as td:
        md = os.path.join(td, "ssh-timer-help.md")
        html = os.path.join(td, "ssh-timer-help.html")
        with open(md, "w", encoding="utf-8") as f:
            f.write(HELP_MD)
        cmd = ["pandoc", "-s", "--mathjax", md, "-o", html]
        res = subprocess.run(cmd)
        if res.returncode != 0:
            print("ERROR: pandoc failed to render HTML.", file=sys.stderr)
            return 3
        opener = which("xdg-open") or which("gio") or which("open")
        if opener:
            subprocess.run([opener, html], check=False)
            print(f"[opened] {html}")
        else:
            print(html)
    return 0


def main() -> int:
    p = argparse.ArgumentParser(
        prog=APP_NAME, description="Timed ssh-agent key with Hyprland/Wayland notifications."
    )
    p.add_argument("-H", "--hours", type=float, default=0.0, help="Hours (float ok)")
    p.add_argument("-M", "--minutes", type=float, default=0.0, help="Minutes (float ok)")
    p.add_argument("-S", "--seconds", type=float, default=0.0, help="Seconds (float ok)")
    p.add_argument("-k", "--key", type=str, default=None, help="Path to private key")
    p.add_argument(
        "--backend",
        choices=["auto", "hyprctl", "notify-send"],
        default="auto",
        help="Notification backend preference",
    )
    p.add_argument(
        "-t",
        "--timer-output",
        action="store_true",
        help="Show a live per-second countdown in the terminal",
    )
    p.add_argument(
        "-n",
        "--no-output",
        action="store_true",
        help="Suppress terminal output, keep notifications",
    )
    p.add_argument(
        "-s", "--silence-notifications", action="store_true", help="Suppress desktop notifications"
    )
    p.add_argument(
        "-q",
        "--quiet",
        action="store_true",
        help="Suppress output + notifications except final notify (unless -s)",
    )
    p.add_argument("--title", type=str, default=DEFAULT_TITLE, help="Notification title")
    # Help exports
    p.add_argument(
        "--help-md", action="store_true", help="Print Markdown help with formal math and exit"
    )
    p.add_argument(
        "--help-html",
        action="store_true",
        help="Render Markdown help to HTML with MathJax (pandoc) and open",
    )

    args = p.parse_args()

    if args.help_md:
        print(HELP_MD)
        return 0
    if args.help_html:
        return render_help_html()

    if args.hours == 0 and args.minutes == 0 and args.seconds == 0:
        p.error("Provide at least one of -H/-M/-S (fractional allowed).")

    total_seconds = parse_time_to_seconds(args.hours, args.minutes, args.seconds)
    if total_seconds <= 0:
        p.error("Computed duration is not positive.")

    allow_output = not args.no_output and not args.quiet
    notifier = Notifier(
        mode=args.backend, silence=args.silence_notifications, quiet=args.quiet, title=args.title
    )

    if allow_output:
        provided = f"{args.hours:g} hours, {args.minutes:g} minutes, {args.seconds:g} seconds"
        print(f"You provided: {provided}")
        print(f"Equivalent to: {fmt_hms(total_seconds)} (i.e., {total_seconds} seconds in total)")
        print(f"Starting ssh-key lifetime: {fmt_hms(total_seconds)}")
        print("-" * 78)

    ensure_ssh_agent()
    key_path = args.key or pick_default_key()
    if not key_path or not os.path.exists(key_path):
        raise SystemExit("No default SSH key found; specify with --key <path>.")

    try:
        add_key_with_lifetime(key_path, total_seconds)
    except RuntimeError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    # Notify at start (useful when -n)
    notifier.send(f"SSH lifetime set for {fmt_hms(total_seconds)}", level="ok")

    run_timer(total_seconds, notifier, show_timer=args.timer_output, allow_output=allow_output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
