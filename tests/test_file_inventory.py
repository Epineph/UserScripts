"""Focused behavioral tests for the standalone file-inventory CLI."""

from __future__ import annotations

import csv
import importlib.util
import sys
from pathlib import Path

import pytest

SCRIPT_PATH = Path(__file__).parents[1] / "file-inventory.py"
SPEC = importlib.util.spec_from_file_location("file_inventory_under_test", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
inventory_cli = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = inventory_cli
SPEC.loader.exec_module(inventory_cli)


def write_file(path: Path, content: bytes, *, executable: bool = False) -> Path:
    """Create a test file and optionally make it user-executable."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    if executable:
        path.chmod(path.stat().st_mode | 0o100)
    return path


def resolved_groups(argv: list[str]):
    """Parse and resolve target groups using the public implementation."""
    namespace, clauses, configs = inventory_cli.parse_cli(argv)
    return inventory_cli.resolve_target_groups(clauses, configs, hidden=namespace.hidden)


def run_python_inventory(argv: list[str]):
    """Run an inventory through the deterministic Python discovery backend."""
    namespace, clauses, configs = inventory_cli.parse_cli(argv)
    groups = inventory_cli.resolve_target_groups(clauses, configs, hidden=namespace.hidden)
    return inventory_cli.inventory(
        groups,
        backend_request="python",
        hidden=namespace.hidden,
        case_sensitive=namespace.case_sensitive,
        sort_key=namespace.sort,
        reverse_sort=namespace.reverse,
        global_limit=namespace.limit,
    )


def test_trailing_singleton_options_are_broadcast(tmp_path: Path) -> None:
    """One final occurrence of each group-capable family configures all groups."""
    first = tmp_path / "first"
    second = tmp_path / "second"
    first.mkdir()
    second.mkdir()

    _, clauses, configs = inventory_cli.parse_cli(
        [
            "-t",
            str(first),
            "-t",
            str(second),
            "-r",
            "-d",
            "3",
            "-x",
            "*.sh, *.py",
            "--max-size",
            "2MiB",
        ]
    )

    assert len(clauses) == 2
    assert [config.effective_depth for config in configs] == [3, 3]
    assert [config.extensions for config in configs] == [
        ["*.sh", "*.py"],
        ["*.sh", "*.py"],
    ]
    assert [config.max_size for config in configs] == [2 * 1024**2, 2 * 1024**2]


def test_repeated_options_stay_local_and_number_results_is_never_auto_broadcast(
    tmp_path: Path,
) -> None:
    """Repeated policy families bind to their clauses; final -n remains local."""
    first = tmp_path / "first"
    second = tmp_path / "second"
    first.mkdir()
    second.mkdir()

    _, _, configs = inventory_cli.parse_cli(
        [
            "-t",
            str(first),
            "-d",
            "1",
            "-x",
            "sh",
            "-t",
            str(second),
            "-d",
            "5",
            "-x",
            "py",
            "-n",
            "7",
        ]
    )

    assert [config.effective_depth for config in configs] == [1, 5]
    assert [config.extensions for config in configs] == [["sh"], ["py"]]
    assert [config.number_results for config in configs] == [None, 7]


def test_explicit_scope_markers_resolve_final_group_ambiguity(tmp_path: Path) -> None:
    """The final target can receive a unique selector through --this-target."""
    first = tmp_path / "first"
    second = tmp_path / "second"
    first.mkdir()
    second.mkdir()

    _, _, configs = inventory_cli.parse_cli(
        [
            "-t",
            str(first),
            "-t",
            str(second),
            "--this-target",
            "-x",
            "py",
        ]
    )
    assert [config.extensions for config in configs] == [[], ["py"]]


def test_explicit_global_selector_is_a_default_overridden_by_local_selector(
    tmp_path: Path,
) -> None:
    """Explicit all-target selectors apply everywhere except a local replacement."""
    first = tmp_path / "first"
    second = tmp_path / "second"
    first.mkdir()
    second.mkdir()

    _, _, configs = inventory_cli.parse_cli(
        [
            "-t",
            str(first),
            "-t",
            str(second),
            "--all-targets",
            "-x",
            "sh",
            "--this-target",
            "-x",
            "py",
        ]
    )
    assert [config.extensions for config in configs] == [["sh"], ["py"]]


def test_comma_and_quoted_glob_targets_expand_and_deduplicate(tmp_path: Path) -> None:
    """Target lists support commas and wrapper-side glob expansion without duplicates."""
    alpha = tmp_path / "alpha"
    beta = tmp_path / "beta"
    alpha.mkdir()
    beta.mkdir()

    groups = resolved_groups(["-t", f"{alpha},{tmp_path / 'b*'}", str(alpha), "-d", "1"])
    assert [root.path for root in groups[0].roots] == [alpha.resolve(), beta.resolve()]


def test_exclusion_attaches_only_to_compatible_root_and_respects_depth(
    tmp_path: Path,
) -> None:
    """Relative exclusions are partitioned and cannot sit beyond a finite depth."""
    first = tmp_path / "first"
    second = tmp_path / "second"
    excluded = first / "cache"
    excluded.mkdir(parents=True)
    second.mkdir()

    groups = resolved_groups(["-t", f"{first},{second}", "-r", "-d", "1", "-e", "cache"])
    assert groups[0].roots[0].exclusions == [excluded.resolve()]
    assert groups[0].roots[1].exclusions == []

    deep = first / "level1" / "level2"
    deep.mkdir(parents=True)
    with pytest.raises(ValueError, match="beyond the effective depth 1"):
        resolved_groups(["-t", str(first), "-d", "1", "-e", "level1/level2"])


def test_exclusion_rejects_target_itself_and_symlink_escape(tmp_path: Path) -> None:
    """Canonical containment prevents excluding the root or a symlinked outside tree."""
    root = tmp_path / "root"
    outside = tmp_path / "outside"
    root.mkdir()
    outside.mkdir()

    with pytest.raises(ValueError, match="strict descendant"):
        resolved_groups(["-t", str(root), "-r", "-e", str(root)])

    link = root / "outside-link"
    try:
        link.symlink_to(outside, target_is_directory=True)
    except OSError as exc:  # pragma: no cover - unusual restricted filesystem
        pytest.skip(f"symlinks are unavailable: {exc}")
    with pytest.raises(ValueError, match="strict descendant"):
        resolved_groups(["-t", str(root), "-r", "-e", str(link)])


def test_broadcast_exclusions_route_across_distinct_target_groups(tmp_path: Path) -> None:
    """A broadcast exclusion attaches only where it is a reachable descendant."""
    first = tmp_path / "first"
    second = tmp_path / "second"
    cache = first / "cache"
    generated = second / "generated"
    cache.mkdir(parents=True)
    generated.mkdir(parents=True)

    groups = resolved_groups(
        [
            "-t",
            str(first),
            "-t",
            str(second),
            "-r",
            "-e",
            "cache",
            "-e",
            "generated",
        ]
    )
    assert groups[0].roots[0].exclusions == [cache.resolve()]
    assert groups[1].roots[0].exclusions == [generated.resolve()]
    assert [group.config.broadcast_excludes for group in groups] == [
        ["cache", "generated"],
        ["cache", "generated"],
    ]


def test_repeated_trailing_extension_events_broadcast_as_one_bundle(tmp_path: Path) -> None:
    """Repeatable final -x occurrences are all broadcast when none occurred earlier."""
    first = tmp_path / "first"
    second = tmp_path / "second"
    first.mkdir()
    second.mkdir()
    _, _, configs = inventory_cli.parse_cli(
        [
            "-t",
            str(first),
            "-t",
            str(second),
            "-x",
            "sh",
            "-x",
            "py",
        ]
    )
    assert [config.extensions for config in configs] == [["sh", "py"], ["sh", "py"]]


def test_depth_extensions_and_extensionless_shebang_detection(tmp_path: Path) -> None:
    """Depth is relative to the root and py matches an extensionless Python shebang."""
    root = tmp_path / "root"
    shell = write_file(root / "direct.sh", b"#!/bin/sh\necho direct\n", executable=True)
    tool = write_file(
        root / "tool",
        b"#!/usr/bin/env -S python3 -u\nprint('tool')\n",
        executable=True,
    )
    report = write_file(root / "sub" / "report.Rmd", b"---\ntitle: report\n---\n")
    write_file(root / "sub" / "deep" / "hidden.py", b"print('too deep')\n")

    result = run_python_inventory(
        ["-t", str(root), "-d", "2", "-x", "*.py,*.Rmd", "--sort", "path"]
    )
    assert [record.path for record in result.displayed] == [report.resolve(), tool.resolve()]
    tool_record = next(record for record in result.displayed if record.path == tool.resolve())
    assert tool_record.interpreter == "python3"
    assert tool_record.language == "python"
    assert tool_record.executable is True
    assert shell.resolve() not in {record.path for record in result.displayed}


def test_suffix_selector_uses_shebang_fallback_only_for_extensionless_files(
    tmp_path: Path,
) -> None:
    """*.sh includes extensionless shell scripts without accepting wrong suffixes."""
    root = tmp_path / "root"
    shell = write_file(root / "direct.sh", b"#!/bin/sh\n")
    tool = write_file(root / "tool", b"#!/usr/bin/env bash\n")
    wrong = write_file(root / "wrong.py", b"#!/usr/bin/env bash\n")
    zsh_file = write_file(root / "other.zsh", b"#!/usr/bin/env zsh\n")

    suffix_result = run_python_inventory(["-t", str(root), "-x", "*.sh"])
    assert [record.path for record in suffix_result.displayed] == [
        shell.resolve(),
        tool.resolve(),
    ]

    language_result = run_python_inventory(["-t", str(root), "-x", "shell"])
    assert {record.path for record in language_result.displayed} == {
        shell.resolve(),
        tool.resolve(),
        wrong.resolve(),
        zsh_file.resolve(),
    }


def test_general_patterns_exclusions_and_case_sensitivity(tmp_path: Path) -> None:
    """Wildcard selectors remain globs, while decorated suffixes honor case."""
    root = tmp_path / "root"
    lower = write_file(root / "lower.py", b"lower")
    upper = write_file(root / "upper.PY", b"upper")
    bytecode = write_file(root / "module.pyo", b"bytecode")
    write_file(root / "notes.txt", b"notes")

    wildcard = run_python_inventory(["-t", str(root), "-x", "*.py?"])
    assert [record.path for record in wildcard.displayed] == [bytecode.resolve()]

    excluded = run_python_inventory(["-t", str(root), "-x", "*.*", "-X", "*.py?"])
    assert bytecode.resolve() not in {record.path for record in excluded.displayed}

    sensitive = run_python_inventory(["-t", str(root), "-x", "*.PY", "--case-sensitive"])
    assert [record.path for record in sensitive.displayed] == [upper.resolve()]
    assert lower.resolve() not in {record.path for record in sensitive.displayed}


@pytest.mark.parametrize("value", [",,,", "'unterminated"])
def test_invalid_or_empty_selector_lists_are_normal_argparse_errors(
    value: str, capsys: pytest.CaptureFixture[str]
) -> None:
    """Malformed list input cannot silently expand a scan or leak a traceback."""
    with pytest.raises(SystemExit) as raised:
        inventory_cli.parse_cli(["-x", value])
    captured = capsys.readouterr()
    assert raised.value.code == 2
    assert "error:" in captured.err
    assert "Traceback" not in captured.err


@pytest.mark.parametrize(
    ("line", "selector", "language"),
    [
        (b"#!/usr/bin/env bash\n", "sh", "shell"),
        (b"#!/usr/bin/env -S Rscript --vanilla\n", "R", "r"),
        (b"#!/usr/bin/python3.12 -u\n", "py", "python"),
        (b"#!/usr/bin/env node\n", "script", "javascript"),
    ],
)
def test_common_shebang_forms_match_language_selectors(
    tmp_path: Path, line: bytes, selector: str, language: str
) -> None:
    """Direct/env/env -S interpreter forms receive stable language labels."""
    root = tmp_path / "root"
    write_file(root / "tool", line + b"body\n")
    result = run_python_inventory(["-t", str(root), "-x", selector])
    assert len(result.displayed) == 1
    assert result.displayed[0].language == language


def test_inclusive_size_bounds_sorting_and_limits_preserve_honest_totals(
    tmp_path: Path,
) -> None:
    """Totals use all unique matches before per-group and global limits."""
    root = tmp_path / "root"
    write_file(root / "small.py", b"12345")
    write_file(root / "medium.py", b"1234567890")
    write_file(root / "large.py", b"123456789012345")

    result = run_python_inventory(
        [
            "-t",
            str(root),
            "-x",
            "py",
            "--min-size",
            "5B",
            "--max-size",
            "15B",
            "-n",
            "2",
            "-l",
            "1",
            "--sort",
            "size",
        ]
    )

    assert [record.size for record in result.all_matched] == [15, 10, 5]
    assert [record.size for record in result.selected] == [15, 10]
    assert [record.size for record in result.displayed] == [15]
    assert inventory_cli.global_totals(result) == ((3, 30), (2, 25), (1, 15))


def test_csv_round_trip_quotes_commas_newlines_and_unicode(tmp_path: Path) -> None:
    """csv.DictWriter preserves paths that shell-oriented exporters usually corrupt."""
    root = tmp_path / "root"
    unusual = write_file(root / "comma, newline\nβ.py", b"print('ok')\n")
    result = run_python_inventory(["-t", str(root), "-x", "py"])
    destination = tmp_path / "inventory.csv"
    destination.write_text("old data", encoding="utf-8")
    destination.chmod(0o640)
    inventory_cli.write_csv(result.displayed, str(destination))

    with destination.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    assert len(rows) == 1
    assert rows[0]["path"] == str(unusual.resolve())
    assert rows[0]["name"] == unusual.name
    assert rows[0]["language"] == "python"
    assert "\x1b[" not in destination.read_text(encoding="utf-8")
    assert destination.stat().st_mode & 0o777 == 0o640

    protected = tmp_path / "protected.txt"
    protected.write_text("keep", encoding="utf-8")
    linked_output = tmp_path / "linked.csv"
    linked_output.symlink_to(protected)
    with pytest.raises(RuntimeError, match="non-regular CSV destination"):
        inventory_cli.write_csv(result.displayed, str(linked_output))
    assert protected.read_text(encoding="utf-8") == "keep"


def test_overlapping_roots_preserve_exact_membership_associations(tmp_path: Path) -> None:
    """Deduplication retains each group/root/relative-path triple for CSV consumers."""
    root = tmp_path / "root"
    item = write_file(root / "item.py", b"item")
    result = run_python_inventory(["-t", str(root), str(item), "-x", "py"])

    assert len(result.displayed) == 1
    assert result.displayed[0].memberships == (
        (1, root.resolve(), "item.py"),
        (1, item.resolve(), "item.py"),
    )

    destination = tmp_path / "memberships.csv"
    inventory_cli.write_csv(result.displayed, str(destination))
    with destination.open(newline="", encoding="utf-8") as handle:
        row = next(csv.DictReader(handle))
    memberships = inventory_cli.json.loads(row["memberships"])
    assert memberships == [
        {"group": 1, "root": str(root.resolve()), "relative_path": "item.py"},
        {"group": 1, "root": str(item.resolve()), "relative_path": "item.py"},
    ]


def test_hidden_target_glob_respects_hidden_flag(tmp_path: Path) -> None:
    """Quoted target globs omit dotfiles unless --hidden explicitly opts in."""
    root = tmp_path / "root"
    visible = write_file(root / "visible.py", b"visible")
    hidden = write_file(root / ".hidden.py", b"hidden")
    broken = root / "broken-link"
    broken.symlink_to(root / "missing-target")
    pattern = str(root / "*")

    ordinary = run_python_inventory(["-t", pattern])
    with_hidden = run_python_inventory(["-t", pattern, "--hidden"])
    assert [record.path for record in ordinary.displayed] == [visible.resolve()]
    assert [record.path for record in with_hidden.displayed] == [
        hidden.resolve(),
        visible.resolve(),
    ]
    assert any("broken-link" in warning for warning in ordinary.warnings)

    with pytest.raises(ValueError, match="does not exist or cannot be resolved"):
        resolved_groups(["-t", str(broken)])


def test_csv_stdout_is_isolated_and_destination_failure_prints_no_report(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Machine stdout is CSV-only, and output errors occur before report rendering."""
    root = tmp_path / "root"
    write_file(root / "one.py", b"1")

    assert inventory_cli.main(["-t", str(root), "--csv", "-"]) == 0
    captured = capsys.readouterr()
    assert captured.out.startswith("index,groups,roots,path,")
    assert "File inventory" not in captured.out

    missing = tmp_path / "missing" / "inventory.csv"
    assert inventory_cli.main(["-t", str(root), "--csv", str(missing)]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "cannot write CSV output" in captured.err


def test_non_utf8_filename_is_escaped_in_valid_utf8_csv(tmp_path: Path) -> None:
    """Legal undecodable Unix path bytes cannot crash or corrupt CSV output."""
    if sys.platform == "win32":  # pragma: no cover - repository is Linux-oriented
        pytest.skip("raw byte filenames are a POSIX behavior")
    root = tmp_path / "root"
    root.mkdir()
    raw_path = inventory_cli.os.fsencode(root) + b"/bad_\xff.py"
    descriptor = inventory_cli.os.open(
        raw_path,
        inventory_cli.os.O_CREAT | inventory_cli.os.O_WRONLY,
        0o600,
    )
    inventory_cli.os.write(descriptor, b"content")
    inventory_cli.os.close(descriptor)

    result = run_python_inventory(["-t", str(root), "-x", "py"])
    destination = tmp_path / "non-utf8.csv"
    inventory_cli.write_csv(result.displayed, str(destination))
    text = destination.read_text(encoding="utf-8")
    assert "bad_\\udcff.py" in text


@pytest.mark.skipif(inventory_cli.find_fd() is None, reason="fd/fdfind is not installed")
def test_fd_and_python_backends_find_the_same_regular_files(tmp_path: Path) -> None:
    """The optimized backend retains the deterministic fallback's core semantics."""
    root = tmp_path / "root"
    write_file(root / "one.py", b"1")
    write_file(root / "sub" / "two.sh", b"22")
    write_file(root / ".hidden.py", b"333")

    namespace, clauses, configs = inventory_cli.parse_cli(
        ["-t", str(root), "-r", "-d", "2", "--hidden"]
    )
    groups = inventory_cli.resolve_target_groups(clauses, configs, hidden=namespace.hidden)
    common = {
        "hidden": namespace.hidden,
        "case_sensitive": False,
        "sort_key": "path",
        "reverse_sort": False,
        "global_limit": None,
    }
    python_result = inventory_cli.inventory(groups, backend_request="python", **common)
    fd_result = inventory_cli.inventory(groups, backend_request="fd", **common)
    assert [record.path for record in fd_result.displayed] == [
        record.path for record in python_result.displayed
    ]


@pytest.mark.skipif(inventory_cli.find_fd() is None, reason="fd/fdfind is not installed")
def test_fd_exclusion_is_root_anchored_and_casefold_ties_are_stable(tmp_path: Path) -> None:
    """Exact exclusions and limiting produce identical backend results."""
    root = tmp_path / "root"
    write_file(root / "cache" / "drop.py", b"drop")
    retained = write_file(root / "other" / "cache" / "keep.py", b"keep")
    upper = write_file(root / "A" / "x.py", b"upper")
    write_file(root / "a" / "x.py", b"lower")

    namespace, clauses, configs = inventory_cli.parse_cli(
        ["-t", str(root), "-r", "-e", "cache", "-x", "py", "-n", "1"]
    )
    groups = inventory_cli.resolve_target_groups(clauses, configs, hidden=False)
    common = {
        "hidden": False,
        "case_sensitive": False,
        "sort_key": "path",
        "reverse_sort": False,
        "global_limit": None,
    }
    python_result = inventory_cli.inventory(groups, backend_request="python", **common)
    fd_result = inventory_cli.inventory(groups, backend_request="fd", **common)
    assert [record.path for record in fd_result.displayed] == [
        record.path for record in python_result.displayed
    ]
    assert retained.resolve() in {record.path for record in fd_result.all_matched}
    assert upper.resolve() in {record.path for record in fd_result.displayed}
