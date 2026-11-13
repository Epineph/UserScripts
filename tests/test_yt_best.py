"""Offline CLI checks for cookie retry boundaries and Chrome keyring selection."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "yt-best.sh"
VIDEO = "https://www.youtube.com/watch?v=Y-W-w8yNiKU&t=1921s"
AUTH_ERROR = (
    "ERROR: [youtube] Y-W-w8yNiKU: Sign in to confirm you’re not a bot. "
    "Use --cookies-from-browser or --cookies for the authentication.\n"
)
FAKE_YT_DLP = """#!/usr/bin/python3
import json
import os
import sys
from pathlib import Path

log = Path(os.environ['YT_TEST_LOG'])
calls = log.read_text().splitlines() if log.exists() else []
with log.open('a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
outcomes = json.loads(os.environ['YT_TEST_OUTCOMES'])
outcome = outcomes[len(calls)] if len(calls) < len(outcomes) else {}
sys.stdout.write(outcome.get('stdout', 'format-output\\n'))
sys.stderr.write(outcome.get('stderr', ''))
sys.exit(outcome.get('status', 0))
"""


@pytest.fixture
def run_cli(tmp_path: Path):
    """Expose only fixture tools, so no test can access the real browser/network."""
    binary_dir = tmp_path / "bin"
    binary_dir.mkdir()
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    # Keep ffmpeg optional without accidentally discovering the system binary.
    for name in ("bash", "mktemp", "tee", "grep", "rm", "mkdir", "uname", "tr"):
        executable = shutil.which(name)
        assert executable is not None, f"Test dependency unavailable: {name}"
        (binary_dir / name).symlink_to(executable)
    downloader = binary_dir / "yt-dlp"
    downloader.write_text(FAKE_YT_DLP)
    downloader.chmod(0o755)
    log = tmp_path / "calls.jsonl"

    def run(
        *args: str,
        outcomes: tuple[dict, ...] = (),
        desktop: str = "Hyprland",
        session: str = "hyprland",
        ffmpeg: bool = True,
    ):
        if ffmpeg:
            merger = binary_dir / "ffmpeg"
            merger.write_text("#!/bin/sh\nexit 0\n")
            merger.chmod(0o755)
        environment = os.environ.copy()
        environment.update(
            PATH=str(binary_dir),
            HOME=str(tmp_path),
            TMPDIR=str(scratch),
            XDG_CURRENT_DESKTOP=desktop,
            DESKTOP_SESSION=session,
            YT_TEST_LOG=str(log),
            YT_TEST_OUTCOMES=json.dumps(outcomes),
        )
        result = subprocess.run(
            [str(binary_dir / "bash"), str(SCRIPT), *args],
            cwd=tmp_path,
            env=environment,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls

    return run


def browser_spec(arguments: list[str]) -> str | None:
    if "--cookies-from-browser" not in arguments:
        return None
    return arguments[arguments.index("--cookies-from-browser") + 1]


def test_public_video_does_not_read_cookies(run_cli):
    result, calls = run_cli(VIDEO)
    assert result.returncode == 0, result.stderr
    assert len(calls) == 1
    assert browser_spec(calls[0]) is None
    assert "--cookies" not in calls[0]
    assert calls[0][-2:] == ["--", VIDEO]


@pytest.mark.parametrize(
    "desktop,session", [("Hyprland", ""), ("GNOME:hYpRlAnD", ""), ("", "hyprland")]
)
def test_authentication_failure_retries_with_hyprland_keyring(run_cli, desktop, session):
    result, calls = run_cli(
        "--list-formats",
        VIDEO,
        outcomes=({"status": 1, "stderr": AUTH_ERROR},),
        desktop=desktop,
        session=session,
    )
    assert result.returncode == 0, result.stderr
    assert len(calls) == 2
    assert browser_spec(calls[0]) is None
    assert browser_spec(calls[1]) == "chrome+gnomekeyring"
    assert all(call[-2:] == ["--", VIDEO] for call in calls)
    assert all("--cookies" not in call for call in calls)


def test_other_desktops_keep_ytdlp_default_keyring(run_cli):
    result, calls = run_cli(
        "-F",
        VIDEO,
        outcomes=({"status": 1, "stderr": AUTH_ERROR},),
        desktop="KDE",
        session="plasma",
    )
    assert result.returncode == 0, result.stderr
    assert browser_spec(calls[1]) == "chrome"


@pytest.mark.parametrize(
    "message",
    [
        "ERROR: [youtube] example: HTTP Error 503: Service Unavailable\n",
        "ERROR: [youtube] example: Video unavailable\n",
        "ERROR: [vimeo] example: Sign in using --cookies-from-browser\n",
        "WARNING: [youtube] example: Sign in using --cookies-from-browser\n",
    ],
)
def test_unrelated_errors_and_warnings_do_not_request_cookies(run_cli, message):
    result, calls = run_cli(VIDEO, outcomes=({"status": 1, "stderr": message},))
    assert result.returncode == 1
    assert len(calls) == 1
    assert browser_spec(calls[0]) is None


@pytest.mark.parametrize("option", ["--browser", "-b", "--cookies-from-browser"])
def test_explicit_chrome_uses_working_keyring_immediately(run_cli, option):
    result, calls = run_cli(option, "chrome:Profile 1", "-F", VIDEO)
    assert result.returncode == 0, result.stderr
    assert len(calls) == 1
    assert browser_spec(calls[0]) == "chrome+gnomekeyring:Profile 1"


@pytest.mark.parametrize(
    "spec", ["chrome+kwallet6:Profile 1", "chrome+basictext", "firefox:Profile 1"]
)
def test_explicit_keyrings_and_other_browsers_remain_literal(run_cli, spec):
    result, calls = run_cli(f"--browser={spec}", "-F", VIDEO)
    assert result.returncode == 0, result.stderr
    assert len(calls) == 1
    assert browser_spec(calls[0]) == spec


def test_explicit_browser_failure_does_not_change_cookie_source(run_cli):
    result, calls = run_cli(
        "--browser",
        "firefox",
        VIDEO,
        outcomes=({"status": 7, "stderr": AUTH_ERROR},),
    )
    assert result.returncode == 7
    assert len(calls) == 1
    assert browser_spec(calls[0]) == "firefox"


def test_cookie_opt_out_prevents_retry(run_cli):
    result, calls = run_cli("--no-cookies", VIDEO, outcomes=({"status": 1, "stderr": AUTH_ERROR},))
    assert result.returncode == 1
    assert len(calls) == 1
    assert browser_spec(calls[0]) is None


def test_cookie_retry_failure_is_returned_without_repeated_retries(run_cli):
    result, calls = run_cli(
        VIDEO,
        outcomes=(
            {"status": 1, "stderr": AUTH_ERROR},
            {"status": 9, "stderr": AUTH_ERROR},
        ),
    )
    assert result.returncode == 9
    assert len(calls) == 2


def test_multiple_urls_retry_only_failed_url(run_cli):
    first = "https://youtu.be/public"
    result, calls = run_cli(
        "--mp4",
        first,
        VIDEO,
        outcomes=({}, {"status": 1, "stderr": AUTH_ERROR}, {}),
    )
    assert result.returncode == 0, result.stderr
    assert [call[-1] for call in calls] == [first, VIDEO, VIDEO]
    assert [browser_spec(call) for call in calls] == [None, None, "chrome+gnomekeyring"]


def test_failure_is_retained_while_remaining_urls_are_processed(run_cli):
    result, calls = run_cli(
        VIDEO,
        "https://youtu.be/another",
        outcomes=({"status": 5, "stderr": "ERROR: video unavailable\n"}, {}),
    )
    assert result.returncode != 0
    assert len(calls) == 2


def test_interrupt_stops_remaining_urls_and_cookie_retry(run_cli):
    result, calls = run_cli(
        VIDEO,
        "https://youtu.be/another",
        outcomes=({"status": 130, "stderr": AUTH_ERROR},),
    )
    assert result.returncode == 130
    assert len(calls) == 1


@pytest.mark.parametrize("option", ["-s", "--simulate", "-F", "--list-formats"])
def test_inspection_modes_need_no_ffmpeg_or_output_directory(run_cli, tmp_path, option):
    target = tmp_path / "missing" / "downloads with spaces"
    result, calls = run_cli(option, "--verbose", "--path", str(target), VIDEO, ffmpeg=False)
    assert result.returncode == 0, result.stderr
    assert len(calls) == 1
    assert "--verbose" in calls[0]
    assert not target.exists()


def test_mp4_download_preserves_quality_arguments_and_paths(run_cli, tmp_path):
    target = tmp_path / "downloads with spaces"
    result, calls = run_cli("--mp4", "--path", str(target), VIDEO)
    assert result.returncode == 0, result.stderr
    command = calls[0]
    assert command[command.index("--format") + 1] == "bv*+ba/b"
    assert command[command.index("--paths") + 1] == str(target)
    assert command[command.index("--merge-output-format") + 1] == "mp4"
    assert command[command.index("--remux-video") + 1] == "mp4"
    assert "--ignore-config" in command
    assert "--check-formats" in command
    assert target.is_dir()


def test_output_streams_are_not_mixed(run_cli):
    result, _ = run_cli(
        "-F",
        VIDEO,
        outcomes=({"stdout": "format-table\n", "stderr": "diagnostic-only\n"},),
    )
    assert result.returncode == 0
    assert result.stdout == "format-table\n"
    assert "diagnostic-only" in result.stderr


@pytest.mark.parametrize(
    "arguments",
    [
        ["--browser"],
        ["--browser="],
        ["--cookies-from-browser", ""],
        ["--browser", "chrome", "--browser", "firefox", VIDEO],
        ["--browser", "chrome", "--no-cookies", VIDEO],
        ["--no-cookies", "--browser", "chrome", VIDEO],
        ["--no-cookies", "--no-cookies", VIDEO],
    ],
)
def test_invalid_cookie_options_fail_before_running_downloader(run_cli, arguments):
    result, calls = run_cli(*arguments)
    assert result.returncode == 2
    assert calls == []
    assert "error:" in result.stderr
