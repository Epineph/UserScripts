"""File-selection boundaries and real encrypted-archive round trips."""

from __future__ import annotations

import json
import os
import shlex
import shutil
import stat
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "find-encrypt.sh"
PASSWORD = "fixture-only passphrase with spaces"
SEVEN_ZIP = next(
    (path for name in ("7z", "7zz", "7za") if (path := shutil.which(name))),
    None,
)


def write_file(path: Path, content: str | bytes = "fixture data") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content.encode() if isinstance(content, str) else content)
    return path


@pytest.fixture
def run_cli(tmp_path):
    scratch = tmp_path / "scratch"
    scratch.mkdir()

    def run(*arguments, data=None, environment=None):
        env = os.environ.copy()
        env.update(TMPDIR=str(scratch), LC_ALL="C.UTF-8")
        if environment:
            env.update(environment)
        result = subprocess.run(
            ["/usr/bin/bash", str(SCRIPT), *map(str, arguments)],
            cwd=tmp_path,
            env=env,
            input=data,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=25,
            check=False,
        )
        assert not list(scratch.iterdir()), "Discovery temporary files leaked"
        assert not list(tmp_path.rglob(".find-encrypt.*")), "Archive stage leaked"
        return result

    return run


@pytest.fixture(params=["find", "fd"])
def backend(request):
    if not shutil.which(request.param):
        pytest.skip(f"{request.param} is unavailable")
    return request.param


def selected_paths(result):
    assert result.returncode == 0, result.stderr
    paths = [
        Path(shlex.split(line.strip())[0])
        for line in result.stdout.splitlines()
        if line.startswith("  ")
    ]
    assert f"Selected: {len(paths)} files\n" in result.stdout
    return set(paths)


def output_path(result):
    assert result.returncode == 0, result.stderr
    line = next(line for line in result.stdout.splitlines() if line.startswith("Output: "))
    return Path(shlex.split(line.removeprefix("Output: "))[0])


def tool_directory(tmp_path, extra=None):
    directory = tmp_path / "fixture-bin"
    directory.mkdir(exist_ok=True)
    for name in (
        "bash",
        "cat",
        "cp",
        "realpath",
        "mktemp",
        "sort",
        "env",
        "rm",
        "find",
        "iconv",
        "mkdir",
        "chmod",
        "mv",
        "stat",
        "rmdir",
    ):
        executable = shutil.which(name)
        assert executable, f"Test dependency unavailable: {name}"
        (directory / name).symlink_to(executable)
    for name, source in (extra or {}).items():
        executable = directory / name
        if executable.is_symlink():
            executable.unlink()
        executable.write_text(f"#!{sys.executable}\n" + source)
        executable.chmod(0o755)
    return directory


@pytest.mark.parametrize(
    "options", [("-e", "iso,img,.tar.gz"), ("-e", ".iso", "-e", "img", "--filetype", "tar.gz")]
)
def test_multiple_filetypes_across_multiple_targets(run_cli, tmp_path, backend, options):
    first = tmp_path / "first"
    second = tmp_path / "second"
    expected = {
        write_file(first / "image.ISO"),
        write_file(first / "disk.img"),
        write_file(second / "backup.tar.gz"),
    }
    write_file(first / "ignored.txt")
    write_file(second / "ordinary.gz")
    result = run_cli(
        "--backend",
        backend,
        "-t",
        first,
        second,
        "--target",
        first,
        *options,
        "--dry-run",
        "-o",
        "archive",
    )
    assert selected_paths(result) == expected
    assert not (tmp_path / "archive.7z").exists()


def test_paths_are_not_split_at_commas_or_spaces(run_cli, tmp_path):
    first = write_file(tmp_path / "space dir" / "one,two.pdf")
    second = write_file(tmp_path / "second.pdf")
    result = run_cli("--path", first, "--target", second, "--dry-run")
    assert selected_paths(result) == {first, second}


def test_globs_or_together_and_with_filetypes(run_cli, tmp_path, backend):
    source = tmp_path / "source"
    expected = {
        write_file(source / "report-final.pdf"),
        write_file(source / "summary.docx"),
    }
    write_file(source / "report-final.txt")
    write_file(source / "other.pdf")
    result = run_cli(
        source,
        "--backend",
        backend,
        "-e",
        "pdf,docx",
        "-g",
        "report*",
        "-g",
        "summary*",
        "--dry-run",
    )
    assert selected_paths(result) == expected


def test_exclusions_are_anchored_and_literal_paths_are_not_globs(run_cli, tmp_path, backend):
    source = tmp_path / "source"
    expected = {
        write_file(source / "keep.iso"),
        write_file(source / "literal1" / "keep.iso"),
        write_file(source / "elsewhere" / "nested" / "old" / "keep.iso"),
    }
    excluded = source / "literal[1]"
    write_file(excluded / "skip.iso")
    write_file(source / "nested" / "old" / "skip.iso")
    write_file(source / "elsewhere" / "cache-data" / "skip.iso")
    result = run_cli(
        source,
        "--backend",
        backend,
        "-e",
        "iso",
        "--exclude",
        excluded,
        "-x",
        "nested/old",
        "-E",
        "cache*",
        "--keep-paths",
        "--dry-run",
    )
    assert selected_paths(result) == expected


def test_hidden_symlinks_and_ignore_files_have_documented_behavior(run_cli, tmp_path, backend):
    source = tmp_path / "source"
    ordinary = write_file(source / "ordinary.iso")
    ignored = write_file(source / "git-ignored.iso")
    hidden = write_file(source / ".hidden.iso")
    nested = write_file(source / ".hidden" / "nested.iso")
    write_file(source / ".gitignore", "git-ignored.iso\n")
    (source / "link.iso").symlink_to(ordinary)
    (source / "link-dir").symlink_to(source / ".hidden", target_is_directory=True)
    args = (source, "--backend", backend, "-e", "iso", "--dry-run")
    assert selected_paths(run_cli(*args)) == {ordinary, ignored}
    assert selected_paths(run_cli(*args, "--hidden")) == {ordinary, ignored, hidden, nested}


@pytest.mark.parametrize(
    "options, expected",
    [
        (("-o", "backup"), "backup.7z"),
        (("-o", "backup.7z"), "backup.7z"),
        (("-n", "backup"), "backup.7z"),
        (("-o", "backup", "--name", "backup.7z"), "backup.7z"),
        (("-o", "new/subdir/", "-n", "backup"), "new/subdir/backup.7z"),
        (("-o", "new/subdir/backup"), "new/subdir/backup.7z"),
        (("-o", "new/subdir/"), "new/subdir/encrypted-files.7z"),
    ],
)
def test_output_normalization_without_writes(run_cli, tmp_path, options, expected):
    source = write_file(tmp_path / "source.txt")
    result = run_cli(source, *options, "--dry-run")
    assert output_path(result) == tmp_path / expected
    assert not (tmp_path / expected).exists()
    assert not (tmp_path / "new").exists()


def test_existing_output_directory_uses_name(run_cli, tmp_path):
    source = write_file(tmp_path / "source.txt")
    destination = tmp_path / "destination"
    destination.mkdir()
    result = run_cli(source, "-o", destination, "--name", "chosen", "--dry-run")
    assert output_path(result) == destination / "chosen.7z"


@pytest.mark.parametrize("kind", ["mismatch", "existing", "dangling-link"])
def test_output_conflicts_fail_without_altering_existing_files(run_cli, tmp_path, kind):
    source = write_file(tmp_path / "source.txt")
    destination = tmp_path / "archive.7z"
    options = ["--output", str(destination), "--dry-run"]
    if kind == "mismatch":
        options.extend(["--name", "other"])
    elif kind == "existing":
        destination.write_bytes(b"existing archive")
    else:
        destination.symlink_to(tmp_path / "nonexistent")
    result = run_cli(source, *options)
    assert result.returncode == 1
    assert source.read_text() == "fixture data"
    if kind == "existing":
        assert destination.read_bytes() == b"existing archive"
    elif kind == "dangling-link":
        assert destination.is_symlink()
    else:
        assert "disagree" in result.stderr
        assert not destination.exists()


def test_no_matches_is_error_without_output(run_cli, tmp_path):
    source = write_file(tmp_path / "source.txt")
    result = run_cli(source, "-e", "iso", "-o", "missing/backup", "--dry-run")
    assert result.returncode == 1
    assert "No files matched" in result.stderr
    assert not (tmp_path / "missing").exists()


def test_auto_falls_back_without_fd_or_7z(run_cli, tmp_path):
    directory = tool_directory(tmp_path)
    source = write_file(tmp_path / "source.txt")
    result = run_cli(source, "--dry-run", environment={"PATH": str(directory)})
    assert selected_paths(result) == {source}
    assert "Backend: find\n" in result.stdout


FAKE_FZF = """
import json, os, sys
from pathlib import Path
items = sys.stdin.buffer.read().split(b'\\0')[:-1]
Path(os.environ['FZF_LOG']).write_text(json.dumps({
    'args': sys.argv[1:],
    'inherited_defaults': [key for key in (
        'FZF_DEFAULT_OPTS', 'FZF_DEFAULT_OPTS_FILE', 'FZF_DEFAULT_COMMAND'
    ) if key in os.environ],
}))
mode = os.environ.get('FZF_MODE', 'select')
if mode == 'cancel':
    sys.exit(130)
if mode == 'empty':
    sys.exit(0)
if mode == 'unknown':
    sys.stdout.buffer.write(b'/not-a-discovered-file\\0')
else:
    sys.stdout.buffer.write(items[-1] + b'\\0')
"""


@pytest.mark.parametrize("mode", ["select", "cancel", "empty", "unknown"])
def test_picker_selects_only_candidates_and_cancellation_writes_nothing(run_cli, tmp_path, mode):
    directory = tool_directory(tmp_path, {"fzf": FAKE_FZF})
    source = tmp_path / "source"
    write_file(source / "a.iso")
    chosen = write_file(source / "z.iso")
    log = tmp_path / "picker.json"
    result = run_cli(
        source,
        "--interactive",
        "--dry-run",
        "-o",
        "missing/output",
        environment={
            "PATH": str(directory),
            "FZF_LOG": str(log),
            "FZF_MODE": mode,
            "FZF_DEFAULT_OPTS": "--filter=unexpected",
            "FZF_DEFAULT_OPTS_FILE": "/missing/default-options",
            "FZF_DEFAULT_COMMAND": "false",
        },
    )
    calls = json.loads(log.read_text())
    assert calls["inherited_defaults"] == []
    assert {"--multi", "--read0", "--print0"} <= set(calls["args"])
    assert not (tmp_path / "missing").exists()
    if mode == "select":
        assert selected_paths(result) == {chosen}
    else:
        assert result.returncode == (130 if mode == "cancel" else 1)


FAKE_7Z = """
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
data = sys.stdin.read()
record = {
    'args': args,
    'password_received': data == os.environ['EXPECTED_PASSWORD'] + '\\n',
    'secret_exported': any(os.environ.get(name) == os.environ['EXPECTED_PASSWORD']
                           for name in ('secret', 'confirmation')),
}
with Path(os.environ['SEVEN_LOG']).open('a') as stream:
    stream.write(json.dumps(record) + '\\n')
archive = next(Path(arg) for arg in args if arg.endswith('/archive.7z'))
if args[0] == 'a':
    archive.write_bytes(b'temporary archive')
if args[0] == os.environ.get('FAIL_COMMAND'):
    sys.exit(2)
if args[0] == 't' and os.environ.get('RACE_OUTPUT'):
    Path(os.environ['RACE_OUTPUT']).write_bytes(b'concurrent owner')
if args[0] == 't' and os.environ.get('MUTATE_SOURCE'):
    source = Path(os.environ['MUTATE_SOURCE'])
    mode = os.environ.get('SOURCE_CHANGE', 'modify')
    if mode == 'modify':
        source.write_bytes(b'changed while archiving')
    elif mode == 'replace':
        previous = source.stat()
        replacement = source.with_suffix('.replacement')
        replacement.write_bytes(source.read_bytes())
        os.utime(replacement, ns=(previous.st_atime_ns, previous.st_mtime_ns))
        replacement.replace(source)
    else:
        source.unlink()
        source.symlink_to(os.environ['OUTSIDE_SOURCE'])
"""


@pytest.mark.parametrize("failure", ["a", "t", "race", "none"])
def test_archive_failures_cleanup_and_publication_never_clobbers(run_cli, tmp_path, failure):
    directory = tool_directory(tmp_path, {"7z": FAKE_7Z})
    source = write_file(tmp_path / "source.txt")
    output = tmp_path / "archive.7z"
    log = tmp_path / "7z.jsonl"
    environment = {
        "PATH": str(directory),
        "SEVEN_LOG": str(log),
        "EXPECTED_PASSWORD": PASSWORD,
        "FAIL_COMMAND": failure,
        "secret": "inherited-value-must-not-be-exported",
        "confirmation": "inherited-value-must-not-be-exported",
    }
    if failure == "race":
        environment["RACE_OUTPUT"] = str(output)
    cleanup = ["--delete-source-files"] if failure != "none" else []
    result = run_cli(
        source,
        "--password-stdin",
        "-o",
        output,
        *cleanup,
        data=PASSWORD + "\n",
        environment=environment,
    )
    assert result.returncode == (0 if failure == "none" else 1), result.stderr
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    assert [call["args"][0] for call in calls] == (["a"] if failure == "a" else ["a", "t"])
    assert all(call["password_received"] and not call["secret_exported"] for call in calls)
    assert all(PASSWORD not in str(call["args"]) for call in calls)
    assert PASSWORD not in result.stdout + result.stderr
    assert source.read_text() == "fixture data"
    if failure == "race":
        assert output.read_bytes() == b"concurrent owner"
    elif failure == "none":
        assert output.read_bytes() == b"temporary archive"
        assert stat.S_IMODE(output.stat().st_mode) == 0o600
    else:
        assert not output.exists()


@pytest.mark.skipif(SEVEN_ZIP is None, reason="7-Zip is unavailable")
@pytest.mark.parametrize("path_option", ["--keep-paths", "--preserve-paths"])
def test_real_encrypted_archive_preserves_structure_and_literal_filenames(
    run_cli, tmp_path, path_option
):
    source = tmp_path / "source"
    names = (
        "first/same.txt",
        "second/same.txt",
        "space dir/  file  ",
        'quotes"file.txt',
        "[wild]*?.txt",
        "@file.txt",
        "-leading.txt",
        "Danish-æøå.txt",
        '"quoted"',
    )
    contents = {name: ("content for " + name).encode() for name in names}
    for name, content in contents.items():
        write_file(source / name, content)
    output = tmp_path / "archive.7z"
    result = run_cli(
        source / "first",
        source / "second",
        *(source / name for name in names[2:]),
        path_option,
        "--password-stdin",
        "-o",
        output,
        data=PASSWORD + "\n",
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert stat.S_IMODE(output.stat().st_mode) == 0o600
    assert PASSWORD not in result.stdout + result.stderr
    wrong = subprocess.run(
        [SEVEN_ZIP, "l", str(output)],
        input="wrong password\n",
        text=True,
        capture_output=True,
        timeout=15,
        check=False,
    )
    assert wrong.returncode != 0
    assert "same.txt" not in wrong.stdout + wrong.stderr
    destination = tmp_path / "extracted"
    extracted = subprocess.run(
        [SEVEN_ZIP, "x", str(output), "-o" + str(destination)],
        input=PASSWORD + "\n",
        text=True,
        capture_output=True,
        timeout=15,
        check=False,
    )
    assert extracted.returncode == 0, extracted.stderr
    restored = {
        str(path.relative_to(destination)): path.read_bytes()
        for path in destination.rglob("*")
        if path.is_file()
    }
    assert restored == contents
    assert all((source / name).read_bytes() == content for name, content in contents.items())


@pytest.mark.parametrize(
    "invalid", ["empty-password", "newline", "carriage-return", "invalid-utf8"]
)
def test_unrepresentable_inputs_fail_before_archive_creation(run_cli, tmp_path, invalid):
    directory = tool_directory(tmp_path, {"7z": FAKE_7Z})
    names = {
        "empty-password": "file.txt",
        "newline": "line\nbreak.txt",
        "carriage-return": "carriage\rreturn.txt",
        "invalid-utf8": "bad-\udcff.txt",
    }
    source = write_file(tmp_path / names[invalid])
    log = tmp_path / "7z.jsonl"
    result = run_cli(
        source,
        "--password-stdin",
        "-o",
        "missing/output",
        data="\n" if invalid == "empty-password" else PASSWORD + "\n",
        environment={"PATH": str(directory), "SEVEN_LOG": str(log), "EXPECTED_PASSWORD": PASSWORD},
    )
    assert result.returncode == 1
    assert not log.exists(), "7z must not run for invalid inputs"
    assert not (tmp_path / "missing").exists()


@pytest.mark.parametrize("alias", ["-p", "--password", "--passphrase", "--encrypt"])
def test_password_aliases_take_no_value(run_cli, tmp_path, alias):
    source = write_file(tmp_path / "source.txt")
    result = run_cli(alias, source, "--dry-run")
    assert selected_paths(result) == {source}


@pytest.mark.skipif(SEVEN_ZIP is None, reason="7-Zip is unavailable")
def test_default_flatten_stores_only_unique_basenames(run_cli, tmp_path):
    first = write_file(tmp_path / "first" / "one.txt", "first")
    second = write_file(tmp_path / "second" / "two.txt", "second")
    output = tmp_path / "archive.7z"
    result = run_cli(first, second, "--password-stdin", "-o", output, data=PASSWORD + "\n")
    assert result.returncode == 0, result.stdout + result.stderr
    destination = tmp_path / "extracted"
    extracted = subprocess.run(
        [SEVEN_ZIP, "x", str(output), "-o" + str(destination)],
        input=PASSWORD + "\n",
        text=True,
        capture_output=True,
        timeout=15,
        check=False,
    )
    assert extracted.returncode == 0, extracted.stderr
    assert {path.name for path in destination.iterdir()} == {"one.txt", "two.txt"}
    assert (destination / "one.txt").read_text() == "first"
    assert (destination / "two.txt").read_text() == "second"


def test_default_flatten_rejects_duplicate_names_before_7z(run_cli, tmp_path):
    directory = tool_directory(tmp_path, {"7z": FAKE_7Z})
    first = write_file(tmp_path / "first" / "same.txt")
    second = write_file(tmp_path / "second" / "same.txt")
    log = tmp_path / "7z.jsonl"
    result = run_cli(
        first,
        second,
        "--password-stdin",
        "-o",
        "missing/output",
        data=PASSWORD + "\n",
        environment={"PATH": str(directory), "SEVEN_LOG": str(log), "EXPECTED_PASSWORD": PASSWORD},
    )
    assert result.returncode == 1
    assert "--keep-paths" in result.stderr
    assert not log.exists()
    assert not (tmp_path / "missing").exists()
    assert first.exists() and second.exists()


@pytest.mark.skipif(SEVEN_ZIP is None, reason="7-Zip is unavailable")
@pytest.mark.parametrize("delete_option", ["--delete-source-files", "--delete-sources"])
def test_delete_only_selected_sources_and_prune_within_roots(run_cli, tmp_path, delete_option):
    source = tmp_path / "source"
    selected = write_file(source / "nested" / "remove.iso", "selected")
    other_type = write_file(source / "keep" / "file.txt", "unselected")
    excluded = write_file(source / "excluded" / "keep.iso", "excluded")
    output = tmp_path / "archive.7z"
    result = run_cli(
        source,
        "-e",
        "iso",
        "--exclude",
        excluded.parent,
        delete_option,
        "--prune-empty-dirs",
        "--password-stdin",
        "-o",
        output,
        data=PASSWORD + "\n",
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert output.is_file()
    assert not selected.exists()
    assert not selected.parent.exists()
    assert source.is_dir(), "The explicitly selected search root must remain"
    assert other_type.read_text() == "unselected"
    assert excluded.read_text() == "excluded"
    destination = tmp_path / "restored"
    extracted = subprocess.run(
        [SEVEN_ZIP, "x", str(output), "-o" + str(destination)],
        input=PASSWORD + "\n",
        text=True,
        capture_output=True,
        timeout=15,
        check=False,
    )
    assert extracted.returncode == 0, extracted.stderr
    assert (destination / "remove.iso").read_text() == "selected"


def test_pruning_requires_source_deletion_and_dry_run_does_not_delete(run_cli, tmp_path):
    source = write_file(tmp_path / "source" / "nested" / "file.iso")
    rejected = run_cli(source, "--prune-empty-dirs", "--dry-run")
    assert rejected.returncode == 1
    result = run_cli(source, "--delete-source-files", "--prune-empty-dirs", "--dry-run")
    assert selected_paths(result) == {source}
    assert source.is_file()
    assert source.parent.is_dir()


@pytest.mark.parametrize("change", ["modify", "replace", "symlink"])
def test_changed_source_retained_after_verified_archive_is_published(run_cli, tmp_path, change):
    directory = tool_directory(tmp_path, {"7z": FAKE_7Z})
    source = write_file(tmp_path / "source" / "file.txt")
    outside = write_file(tmp_path / "outside.txt", "not selected")
    output = tmp_path / "archive.7z"
    result = run_cli(
        source,
        "--delete-source-files",
        "--password-stdin",
        "-o",
        output,
        data=PASSWORD + "\n",
        environment={
            "PATH": str(directory),
            "SEVEN_LOG": str(tmp_path / "7z.jsonl"),
            "EXPECTED_PASSWORD": PASSWORD,
            "MUTATE_SOURCE": str(source),
            "SOURCE_CHANGE": change,
            "OUTSIDE_SOURCE": str(outside),
        },
    )
    assert result.returncode == 1
    if change == "modify":
        assert source.read_bytes() == b"changed while archiving"
    elif change == "replace":
        assert source.read_bytes() == b"fixture data"
    else:
        assert source.is_symlink()
        assert outside.read_text() == "not selected"
    assert output.read_bytes() == b"temporary archive"


@pytest.mark.parametrize("options", [("--silent",), ("-s", "--verbose")])
def test_silent_dry_run_suppresses_every_output_stream(run_cli, tmp_path, options):
    source = write_file(tmp_path / "source.txt")
    result = run_cli(source, "--dry-run", *options)
    assert result.returncode == 0
    assert result.stdout == result.stderr == ""


@pytest.mark.parametrize("invalid", ["missing-source", "interactive", "no-password-stdin"])
def test_silent_errors_are_silent_and_do_not_publish(run_cli, tmp_path, invalid):
    source = write_file(tmp_path / "source.txt")
    args = [str(source), "--silent", "-o", "missing/archive"]
    if invalid == "missing-source":
        args[0] = str(tmp_path / "missing-source")
        args.append("--dry-run")
    elif invalid == "interactive":
        args.extend(["--interactive", "--dry-run"])
    result = run_cli(*args)
    assert result.returncode == 1
    assert result.stdout == result.stderr == ""
    assert not (tmp_path / "missing").exists()


@pytest.mark.parametrize("mode", ["--silent", "--verbose"])
def test_logging_modes_do_not_expose_passwords(run_cli, tmp_path, mode):
    directory = tool_directory(tmp_path, {"7z": FAKE_7Z})
    source = write_file(tmp_path / "source.txt")
    output = tmp_path / "archive.7z"
    result = run_cli(
        source,
        mode,
        "--password-stdin",
        "-o",
        output,
        data=PASSWORD + "\n",
        environment={
            "PATH": str(directory),
            "SEVEN_LOG": str(tmp_path / "7z.jsonl"),
            "EXPECTED_PASSWORD": PASSWORD,
        },
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert output.is_file()
    assert PASSWORD not in result.stdout + result.stderr
    if mode == "--silent":
        assert result.stdout == result.stderr == ""
    else:
        assert result.stdout or result.stderr


def test_eof_cannot_reuse_a_password_inherited_from_environment(run_cli, tmp_path):
    directory = tool_directory(tmp_path, {"7z": FAKE_7Z})
    source = write_file(tmp_path / "source.txt")
    log = tmp_path / "7z.jsonl"
    result = run_cli(
        source,
        "--password-stdin",
        "-o",
        "missing/archive",
        data="",
        environment={
            "PATH": str(directory),
            "SEVEN_LOG": str(log),
            "EXPECTED_PASSWORD": PASSWORD,
            "secret": PASSWORD,
        },
    )
    assert result.returncode == 1
    assert not log.exists()
    assert not (tmp_path / "missing").exists()


@pytest.mark.parametrize(
    "target_kind", ["trailing-directory", "ancestor-directory", "ancestor-file"]
)
def test_symlink_roots_and_ancestors_are_refused(run_cli, tmp_path, target_kind):
    original = write_file(tmp_path / "original" / "nested" / "file.txt", "original content")
    link = tmp_path / "linked"
    link.symlink_to(tmp_path / "original", target_is_directory=True)
    targets = {
        "trailing-directory": str(link) + "/",
        "ancestor-directory": str(link / "nested"),
        "ancestor-file": str(link / "nested" / "file.txt"),
    }
    result = run_cli(
        targets[target_kind], "--dry-run", "--delete-source-files", "-o", "missing/archive"
    )
    assert result.returncode == 1
    assert "symlink" in result.stderr.lower()
    assert original.read_text() == "original content"
    assert link.is_symlink()
    assert not (tmp_path / "missing").exists()


@pytest.mark.parametrize("excluded_component", ["cache{1,2}", "["])
def test_literal_exclusion_components_agree_between_backends(
    run_cli, tmp_path, backend, excluded_component
):
    source = tmp_path / "source"
    expected = {
        write_file(source / "cache1" / "file.iso"),
        write_file(source / "cache2" / "file.iso"),
    }
    write_file(source / excluded_component / "file.iso")
    result = run_cli(
        source,
        "--backend",
        backend,
        "--exclude",
        excluded_component,
        "--keep-paths",
        "--dry-run",
    )
    assert selected_paths(result) == expected


MOVING_MKDIR = """
import os, sys
from pathlib import Path
source = Path(os.environ['MOVE_SOURCE'])
if source.exists():
    source.rename(os.environ['MOVED_SOURCE'])
os.execv(os.environ['REAL_MKDIR'], ['mkdir', *sys.argv[1:]])
"""


def test_missing_source_base_never_falls_back_to_callers_working_directory(run_cli, tmp_path):
    source = write_file(tmp_path / "source" / "file.txt", "selected content")
    unrelated = write_file(tmp_path / "file.txt", "unrelated working-directory content")
    moved = tmp_path / "moved-source"
    output = tmp_path / "archive.7z"
    log = tmp_path / "7z.jsonl"
    directory = tool_directory(tmp_path, {"7z": FAKE_7Z, "mkdir": MOVING_MKDIR})
    result = run_cli(
        source.parent,
        "--keep-paths",
        "--password-stdin",
        "-o",
        output,
        data=PASSWORD + "\n",
        environment={
            "PATH": str(directory),
            "SEVEN_LOG": str(log),
            "EXPECTED_PASSWORD": PASSWORD,
            "MOVE_SOURCE": str(source.parent),
            "MOVED_SOURCE": str(moved),
            "REAL_MKDIR": shutil.which("mkdir"),
        },
    )
    assert result.returncode == 1
    assert not output.exists()
    assert not log.exists(), "7z must not run after changing to the source base fails"
    assert (moved / "file.txt").read_text() == "selected content"
    assert unrelated.read_text() == "unrelated working-directory content"


@pytest.mark.skipif(SEVEN_ZIP is None, reason="7-Zip is unavailable")
def test_selected_hardlinks_are_deleted_but_unselected_alias_is_retained(run_cli, tmp_path):
    first = write_file(tmp_path / "source" / "first.txt", "shared hardlink content")
    second = first.with_name("second.txt")
    unselected = first.with_name("unselected.txt")
    os.link(first, second)
    os.link(first, unselected)
    output = tmp_path / "archive.7z"
    result = run_cli(
        first,
        second,
        "--keep-paths",
        "--delete-source-files",
        "--password-stdin",
        "-o",
        output,
        data=PASSWORD + "\n",
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert not first.exists()
    assert not second.exists()
    assert unselected.read_text() == "shared hardlink content"
    assert unselected.stat().st_nlink == 1
    destination = tmp_path / "restored"
    extracted = subprocess.run(
        [SEVEN_ZIP, "x", str(output), "-o" + str(destination)],
        input=PASSWORD + "\n",
        text=True,
        capture_output=True,
        timeout=15,
        check=False,
    )
    assert extracted.returncode == 0, extracted.stderr
    assert {path.name for path in destination.iterdir()} == {"first.txt", "second.txt"}
    assert all(path.read_text() == "shared hardlink content" for path in destination.iterdir())
