#!/usr/bin/env python3
"""Inventory files across target groups with scoped traversal and filters.

``file-inventory`` uses ``fd`` for fast discovery when available and falls back
to a Python walker.  Metadata, extension/shebang classification, summaries,
Rich terminal tables, and CSV output are generated from structured Python data;
the script never parses presentation-oriented ``eza`` or ``lsd`` output.

Target clauses are ordered.  Options between two ``--target`` occurrences apply
to the preceding group.  A group-capable option family used only after the final
target is broadcast to every group, including repeated values in that trailing
bundle.  ``--this-target`` and ``--all-targets`` make either scope explicit when
the shorthand would be ambiguous.

Examples
--------
Inspect the current directory without recursion::

    file-inventory.py --sort size --total-size

Apply one trailing policy to two target groups::

    file-inventory.py \
      -t "$HOME/repos,/usr/local/bin/*" \
      -t "$HOME/my_repos" \
      -r -d 4 -x "*.sh,*.py" "*.R,*.Rmd,script" \
      --max-size 5MiB -l 150 --sort size --total-size

Give the groups distinct policies::

    file-inventory.py \
      -t "$HOME/repos" -r -d 2 -x "*.sh" -e archived -n 30 \
      -t "$HOME/my_repos" -r -d 6 -x "*.py,*.Rmd" -n 75

Export the displayed rows as RFC-compatible CSV as well as showing the table::

    file-inventory.py -t . -r -x script --csv inventory.csv
"""

from __future__ import annotations

import argparse
import csv
import fnmatch
import glob
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field, replace
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import IO, Any, Iterable, Sequence

VERSION = "1.0.0"
DEFAULT_DEPTH = 1
SHEBANG_READ_LIMIT = 4096


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass(slots=True)
class TargetClause:
    """One occurrence of ``-t/--target`` and its shared policy."""

    raw_targets: list[str]


@dataclass(slots=True)
class ScopeEvent:
    """An ordered target-capable option captured by argparse."""

    family: str
    value: Any
    group_index: int | None
    scope: str
    order: int
    option: str


@dataclass(slots=True)
class GroupConfig:
    """Effective traversal and filtering configuration for one target group."""

    recursive: bool = False
    depth: int | None = None
    extensions: list[str] = field(default_factory=list)
    exclude_extensions: list[str] = field(default_factory=list)
    raw_excludes: list[str] = field(default_factory=list)
    broadcast_excludes: list[str] = field(default_factory=list)
    local_excludes: list[str] = field(default_factory=list)
    min_size: int | None = None
    max_size: int | None = None
    number_results: int | None = None

    @property
    def effective_depth(self) -> int | None:
        """Return ``None`` for unlimited traversal or a relative depth cap."""
        if self.depth is not None:
            return self.depth
        if self.recursive:
            return None
        return DEFAULT_DEPTH


@dataclass(slots=True)
class RootSpec:
    """A canonical target and exclusions that apply specifically to it."""

    path: Path
    exclusions: list[Path] = field(default_factory=list)


@dataclass(slots=True)
class TargetGroup:
    """Resolved targets plus their effective configuration."""

    index: int
    raw_targets: list[str]
    roots: list[RootSpec]
    config: GroupConfig
    resolution_warnings: list[str] = field(default_factory=list)


@dataclass(slots=True)
class FileRecord:
    """A regular file and all target memberships retained after deduplication."""

    path: Path
    groups: tuple[int, ...]
    roots: tuple[Path, ...]
    relative_paths: tuple[str, ...]
    memberships: tuple[tuple[int, Path, str], ...]
    name: str
    extension: str
    language: str
    interpreter: str
    shebang: str
    executable: bool
    size: int
    mtime: float


@dataclass(slots=True)
class GroupStats:
    """Counts collected before and after result limits for a target group."""

    group_index: int
    discovered: int = 0
    matched: int = 0
    selected: int = 0
    displayed: int = 0
    matched_bytes: int = 0
    selected_bytes: int = 0
    displayed_bytes: int = 0
    errors: int = 0


@dataclass(slots=True)
class InventoryResult:
    """Complete result, including pre-limit records used for honest totals."""

    groups: list[TargetGroup]
    all_matched: list[FileRecord]
    selected: list[FileRecord]
    displayed: list[FileRecord]
    stats: list[GroupStats]
    backend: str
    warnings: list[str]


# ---------------------------------------------------------------------------
# Ordered argparse actions
# ---------------------------------------------------------------------------


def _namespace_list(namespace: argparse.Namespace, name: str) -> list[Any]:
    value = getattr(namespace, name, None)
    if value is None:
        value = []
        setattr(namespace, name, value)
    return value


def _next_order(namespace: argparse.Namespace) -> int:
    order = int(getattr(namespace, "_event_order", 0))
    setattr(namespace, "_event_order", order + 1)
    return order


class TargetAction(argparse.Action):
    """Create a target clause while preserving command-line order."""

    def __call__(
        self,
        parser: argparse.ArgumentParser,
        namespace: argparse.Namespace,
        values: str | Sequence[Any] | None,
        option_string: str | None = None,
    ) -> None:
        value_list = [values] if isinstance(values, str) else values or []
        raw_targets = split_comma_values(value_list, split_whitespace=False)
        if not raw_targets:
            parser.error(f"{option_string} requires at least one non-empty target")
        clauses = _namespace_list(namespace, "_target_clauses")
        clauses.append(TargetClause(raw_targets=raw_targets))
        setattr(namespace, "_current_group", len(clauses) - 1)


class ScopeModeAction(argparse.Action):
    """Change the scope assigned to subsequent target-capable options."""

    def __init__(self, *args: Any, mode: str, **kwargs: Any) -> None:
        self.mode = mode
        kwargs["nargs"] = 0
        super().__init__(*args, **kwargs)

    def __call__(
        self,
        parser: argparse.ArgumentParser,
        namespace: argparse.Namespace,
        values: str | Sequence[Any] | None,
        option_string: str | None = None,
    ) -> None:
        del parser, values, option_string
        setattr(namespace, "_scope_mode", self.mode)


class ScopedOptionAction(argparse.Action):
    """Capture a target-capable option instead of flattening it globally."""

    def __init__(self, *args: Any, family: str, **kwargs: Any) -> None:
        self.family = family
        super().__init__(*args, **kwargs)

    def __call__(
        self,
        parser: argparse.ArgumentParser,
        namespace: argparse.Namespace,
        values: Any,
        option_string: str | None = None,
    ) -> None:
        if self.nargs == 0:
            value: Any = True
        else:
            try:
                if self.family in {"extensions", "exclude_extensions"}:
                    value = split_comma_values(values, split_whitespace=True)
                elif self.family == "excludes":
                    value = split_comma_values(values, split_whitespace=False)
                else:
                    value = values
            except argparse.ArgumentTypeError as exc:
                parser.error(f"{option_string}: {exc}")
            if self.family in {"extensions", "exclude_extensions", "excludes"} and not value:
                parser.error(f"{option_string} requires at least one non-empty value")

        events = _namespace_list(namespace, "_scope_events")
        events.append(
            ScopeEvent(
                family=self.family,
                value=value,
                group_index=getattr(namespace, "_current_group", None),
                scope=getattr(namespace, "_scope_mode", "auto"),
                order=_next_order(namespace),
                option=option_string or self.dest,
            )
        )


# ---------------------------------------------------------------------------
# CLI construction and resolution
# ---------------------------------------------------------------------------


def nonnegative_int(text: str) -> int:
    """Argparse converter for integers greater than or equal to zero."""
    try:
        value = int(text)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"expected an integer, got {text!r}") from exc
    if value < 0:
        raise argparse.ArgumentTypeError("value must be greater than or equal to zero")
    return value


def build_parser() -> argparse.ArgumentParser:
    """Build the public command-line parser."""
    parser = argparse.ArgumentParser(
        prog="file-inventory.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=(
            "Inspect regular files under one or more target groups. By default, only\n"
            "direct children (depth 1) are inspected. -r means unlimited recursion;\n"
            "-d N sets a finite depth and implies recursion. Directory symlinks are\n"
            "never followed. Hidden entries are omitted unless --hidden is supplied."
        ),
        epilog=(
            "SCOPING\n"
            "  Each -t starts a target group. Options before the next -t are local.\n"
            "  A target-capable option family used only after the final -t is\n"
            "  broadcast to all groups, including repeated trailing values. -n is\n"
            "  local unless --all-targets is explicit;\n"
            "  -l is always a single global cap.\n"
            "  --this-target and --all-targets override the automatic rule for\n"
            "  subsequent options and persist until changed; --auto-scope restores\n"
            "  inference. Broadcast values are defaults: local scalar/selecting\n"
            "  options override them, while exclusions are additive.\n\n"
            "EXTENSIONS\n"
            "  sh, .sh, and *.sh are equivalent and matching is case-insensitive\n"
            "  unless --case-sensitive is used. 'script' selects known script\n"
            "  suffixes or any shebang; 'noext' selects extensionless files.\n"
            "  Extensionless shebangs such as env bash, env -S python3, and Rscript\n"
            "  are classified and can match sh, py, or R selectors.\n\n"
            "TARGETS AND EXCLUSIONS\n"
            "  Quote globs so this program expands them consistently. Escape a literal\n"
            "  comma as \\,. Relative exclusions are resolved beneath each compatible\n"
            "  target and must be existing strict descendants reachable within depth.\n\n"
            "SIZES\n"
            "  Plain values are bytes. KB/MB/GB are decimal; K/KiB, M/MiB, etc.\n"
            "  are binary. Bounds are inclusive."
        ),
    )

    target = parser.add_argument_group("target clauses")
    target.add_argument(
        "-t",
        "--target",
        "--targets",
        dest=argparse.SUPPRESS,
        nargs="+",
        action=TargetAction,
        metavar="PATH",
        help=(
            "Start a target group; accepts repeatable, comma-separated, and "
            "shell-separated paths or globs (default: current directory)."
        ),
    )
    target.add_argument(
        "-r",
        "-R",
        "--recursive",
        "--recursion",
        dest=argparse.SUPPRESS,
        nargs=0,
        action=ScopedOptionAction,
        family="recursive",
        help="Enable recursion; any effective -d bounds it regardless of option order.",
    )
    target.add_argument(
        "-d",
        "--depth",
        dest=argparse.SUPPRESS,
        action=ScopedOptionAction,
        family="depth",
        type=nonnegative_int,
        metavar="N",
        help="Maximum relative depth; 0 yields no directory contents.",
    )
    target.add_argument(
        "-e",
        "--exclude",
        dest=argparse.SUPPRESS,
        nargs="+",
        action=ScopedOptionAction,
        family="excludes",
        metavar="DIR",
        help="Exclude existing descendant directories; accepts commas/repetition.",
    )
    target.add_argument(
        "-x",
        "--extensions",
        dest=argparse.SUPPRESS,
        nargs="+",
        action=ScopedOptionAction,
        family="extensions",
        metavar="EXT",
        help="Include suffix/pattern selectors, plus special 'script' and 'noext'.",
    )
    target.add_argument(
        "-X",
        "--exclude-extensions",
        dest=argparse.SUPPRESS,
        nargs="+",
        action=ScopedOptionAction,
        family="exclude_extensions",
        metavar="EXT",
        help="Exclude suffix/pattern selectors; exclusions win over inclusions.",
    )
    target.add_argument(
        "--min-size",
        dest=argparse.SUPPRESS,
        action=ScopedOptionAction,
        family="min_size",
        metavar="SIZE",
        help="Inclusive minimum regular-file size (for example, 10KiB).",
    )
    target.add_argument(
        "--max-size",
        dest=argparse.SUPPRESS,
        action=ScopedOptionAction,
        family="max_size",
        metavar="SIZE",
        help="Inclusive maximum regular-file size (for example, 5MB).",
    )
    target.add_argument(
        "-n",
        "--number-results",
        dest=argparse.SUPPRESS,
        action=ScopedOptionAction,
        family="number_results",
        type=nonnegative_int,
        metavar="N",
        help="Limit the current group after sorting (never auto-broadcast).",
    )
    target.add_argument(
        "--this-target",
        dest=argparse.SUPPRESS,
        action=ScopeModeAction,
        mode="local",
        help="Keep subsequent target-capable options local to the current group.",
    )
    target.add_argument(
        "--all-targets",
        dest=argparse.SUPPRESS,
        action=ScopeModeAction,
        mode="all",
        help="Apply subsequent target-capable options to every target group.",
    )
    target.add_argument(
        "--auto-scope",
        dest=argparse.SUPPRESS,
        action=ScopeModeAction,
        mode="auto",
        help="Restore automatic local/trailing-singleton scope resolution.",
    )

    output = parser.add_argument_group("global selection and output")
    output.add_argument(
        "-l",
        "--limit",
        "--limit-all",
        type=nonnegative_int,
        default=None,
        metavar="N",
        help="Limit the merged result after per-group limits and sorting.",
    )
    output.add_argument(
        "-s",
        "--sort",
        choices=["path", "name", "extension", "language", "size", "date"],
        default="path",
        help="Global sort key; size/mtime date descend, others ascend (default: path).",
    )
    output.add_argument(
        "--reverse",
        action="store_true",
        help="Reverse the default direction for the selected sort key.",
    )
    output.add_argument(
        "--total-size",
        action="store_true",
        help=(
            "Show unique matched-file apparent-byte totals before and after "
            "per-group/global limits."
        ),
    )
    output.add_argument(
        "--summary-only",
        action="store_true",
        help="Show group and type summaries without the per-file table.",
    )
    output.add_argument(
        "--csv",
        metavar="FILE",
        help=(
            "Also export displayed records as CSV, atomically replacing FILE; "
            "use '-' for CSV-only stdout."
        ),
    )
    output.add_argument(
        "--no-rich",
        action="store_true",
        help="Use stable plain-text tables even when Rich is installed.",
    )
    output.add_argument(
        "--backend",
        choices=["auto", "fd", "python"],
        default="auto",
        help="Discovery backend (default: fd when installed, else Python).",
    )
    output.add_argument(
        "--hidden",
        action="store_true",
        help=(
            "Include hidden traversal/glob matches; explicitly named hidden targets "
            "always remain valid. Ignore files are not honored."
        ),
    )
    output.add_argument(
        "--case-sensitive",
        action="store_true",
        help="Make extension and filename-pattern selectors case-sensitive.",
    )
    output.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    return parser


def split_comma_values(values: Iterable[str], *, split_whitespace: bool) -> list[str]:
    """Split commas safely; optionally split whitespace for extension selectors."""
    result: list[str] = []
    for value in values:
        chunks = re.split(r"(?<!\\),", value)
        for chunk in chunks:
            chunk = chunk.replace(r"\,", ",").strip()
            if not chunk:
                continue
            if split_whitespace:
                try:
                    result.extend(part for part in shlex.split(chunk) if part)
                except ValueError as exc:
                    raise argparse.ArgumentTypeError(str(exc)) from exc
            else:
                result.append(chunk)
    return result


def parse_size(text: str) -> int:
    """Parse a decimal or binary human-size value into an integer byte count."""
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([kmgtp]?i?b?)?\s*", text, re.I)
    if match is None:
        raise ValueError(f"invalid size {text!r}")

    try:
        number = Decimal(match.group(1))
    except InvalidOperation as exc:  # pragma: no cover - guarded by the regex
        raise ValueError(f"invalid size {text!r}") from exc

    unit = (match.group(2) or "b").lower()
    decimal_units = {"b": 1, "kb": 1000, "mb": 1000**2, "gb": 1000**3, "tb": 1000**4, "pb": 1000**5}
    binary_units = {
        "k": 1024,
        "kib": 1024,
        "m": 1024**2,
        "mib": 1024**2,
        "g": 1024**3,
        "gib": 1024**3,
        "t": 1024**4,
        "tib": 1024**4,
        "p": 1024**5,
        "pib": 1024**5,
    }
    multiplier = decimal_units.get(unit, binary_units.get(unit))
    if multiplier is None:
        raise ValueError(f"unknown size unit in {text!r}")
    return int(number * multiplier)


def _apply_event(
    config: GroupConfig,
    event: ScopeEvent,
    local_lists: set[str],
    *,
    broadcast: bool,
) -> None:
    """Apply one event to a mutable group configuration."""
    family = event.family
    value = event.value

    if family == "recursive":
        config.recursive = True
    elif family == "depth":
        config.recursive = True
        config.depth = int(value)
    elif family == "extensions":
        if family in local_lists and not config.extensions:
            config.extensions = []
        config.extensions.extend(value)
    elif family == "exclude_extensions":
        config.exclude_extensions.extend(value)
    elif family == "excludes":
        config.raw_excludes.extend(value)
        if broadcast:
            config.broadcast_excludes.extend(value)
        else:
            config.local_excludes.extend(value)
    elif family == "min_size":
        config.min_size = parse_size(str(value))
    elif family == "max_size":
        config.max_size = parse_size(str(value))
    elif family == "number_results":
        config.number_results = int(value)
    else:  # pragma: no cover - parser controls event families
        raise AssertionError(f"unknown option family: {family}")


def resolve_group_configs(
    clauses: Sequence[TargetClause], events: Sequence[ScopeEvent], parser: argparse.ArgumentParser
) -> list[GroupConfig]:
    """Resolve automatic, global, and explicit-local target option scopes."""
    group_count = len(clauses)
    family_occurs_before_final = {
        family: any(
            event.family == family and event.group_index != group_count - 1 for event in events
        )
        for family in {event.family for event in events}
    }
    broadcast: list[ScopeEvent] = []
    local: dict[int, list[ScopeEvent]] = defaultdict(list)

    for event in events:
        if event.scope == "all":
            broadcast.append(event)
            continue
        if event.group_index is None:
            parser.error(f"{event.option} must follow -t/--target (or follow --all-targets)")

        if event.family == "number_results":
            local[event.group_index].append(event)
        elif event.scope == "local":
            local[event.group_index].append(event)
        elif event.group_index == group_count - 1 and not family_occurs_before_final[event.family]:
            broadcast.append(event)
        else:
            local[event.group_index].append(event)

    broadcast.sort(key=lambda event: event.order)
    for group_events in local.values():
        group_events.sort(key=lambda event: event.order)

    configs: list[GroupConfig] = []
    for group_index in range(group_count):
        config = GroupConfig()
        for event in broadcast:
            _apply_event(config, event, local_lists=set(), broadcast=True)

        local_events = local[group_index]
        local_extension_override = any(event.family == "extensions" for event in local_events)
        if local_extension_override:
            config.extensions = []
        for event in local_events:
            _apply_event(
                config,
                event,
                local_lists={"extensions"},
                broadcast=False,
            )

        config.extensions = dedupe_strings(config.extensions)
        config.exclude_extensions = dedupe_strings(config.exclude_extensions)
        config.raw_excludes = dedupe_strings(config.raw_excludes)
        config.broadcast_excludes = dedupe_strings(config.broadcast_excludes)
        config.local_excludes = dedupe_strings(config.local_excludes)
        if (
            config.min_size is not None
            and config.max_size is not None
            and config.min_size > config.max_size
        ):
            parser.error(f"target group {group_index + 1}: --min-size exceeds --max-size")
        configs.append(config)
    return configs


def parse_cli(
    argv: Sequence[str],
) -> tuple[argparse.Namespace, list[TargetClause], list[GroupConfig]]:
    """Parse argv and return global options, target clauses, and effective policies."""
    parser = build_parser()
    namespace = parser.parse_args(argv)
    clauses: list[TargetClause] = getattr(namespace, "_target_clauses", [])
    events: list[ScopeEvent] = getattr(namespace, "_scope_events", [])

    if not clauses:
        clauses = [TargetClause(raw_targets=["."])]
        for event in events:
            if event.group_index is None and event.scope != "all":
                event.group_index = 0

    configs = resolve_group_configs(clauses, events, parser)
    return namespace, clauses, configs


# ---------------------------------------------------------------------------
# Paths and exclusions
# ---------------------------------------------------------------------------


def dedupe_strings(values: Iterable[str]) -> list[str]:
    """Deduplicate strings while retaining the first occurrence."""
    return list(dict.fromkeys(values))


def _expand_pattern(
    raw: str,
    *,
    base: Path | None = None,
    include_hidden: bool = True,
) -> list[Path]:
    expanded = os.path.expandvars(os.path.expanduser(raw))
    candidate = Path(expanded)
    if base is not None and not candidate.is_absolute():
        candidate = base / candidate
    pattern = str(candidate)
    if glob.has_magic(pattern):
        matches = glob.glob(pattern, include_hidden=include_hidden)
        return [Path(match) for match in sorted(matches)]
    return [candidate]


def canonical_existing_path(path: Path, *, label: str) -> Path:
    """Resolve an existing path or raise a concise usage error."""
    try:
        return path.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise ValueError(f"{label} does not exist or cannot be resolved: {path}") from exc


def expand_targets(raw_targets: Sequence[str], *, hidden: bool) -> tuple[list[Path], list[str]]:
    """Expand environment variables, tildes, quoted globs, and duplicates."""
    targets: list[Path] = []
    warnings: list[str] = []
    seen: set[Path] = set()
    for raw in raw_targets:
        normalized_raw = os.path.expandvars(os.path.expanduser(raw))
        is_glob = glob.has_magic(normalized_raw)
        expanded = _expand_pattern(raw, include_hidden=hidden)
        if is_glob and not expanded:
            raise ValueError(f"target glob matched nothing: {raw!r}")
        for candidate in expanded:
            try:
                path = canonical_existing_path(candidate, label="target")
            except ValueError:
                if not is_glob:
                    raise
                warnings.append(f"target glob entry is broken or unreadable; skipped: {candidate}")
                continue
            if not (path.is_dir() or path.is_file()):
                if not is_glob:
                    raise ValueError(f"target is not a regular file or directory: {path}")
                warnings.append(f"target glob entry is not a file or directory; skipped: {path}")
                continue
            if path not in seen:
                seen.add(path)
                targets.append(path)
    if not targets:
        raise ValueError("target clause resolved to no usable files or directories")
    return targets, warnings


def is_strict_descendant(path: Path, root: Path) -> bool:
    """Return true only when path is below, but not equal to, root."""
    try:
        relative = path.relative_to(root)
    except ValueError:
        return False
    return bool(relative.parts)


def resolve_exclusions(
    raw_excludes: Sequence[str],
    roots: Sequence[Path],
    depth: int | None,
    *,
    require_matches: bool,
) -> tuple[dict[Path, list[Path]], set[str]]:
    """Validate exclusions and partition them among compatible directory roots."""
    directory_roots = [root for root in roots if root.is_dir()]
    result: dict[Path, list[Path]] = {root: [] for root in roots}
    attached_raw: set[str] = set()

    for raw in raw_excludes:
        expanded_raw = os.path.expandvars(os.path.expanduser(raw))
        raw_path = Path(expanded_raw)
        candidates: list[Path] = []
        if raw_path.is_absolute():
            candidates.extend(_expand_pattern(raw))
        else:
            for root in directory_roots:
                candidates.extend(_expand_pattern(raw, base=root))

        canonical_candidates: list[Path] = []
        for candidate in candidates:
            try:
                canonical = canonical_existing_path(candidate, label="excluded directory")
            except ValueError:
                continue
            if canonical.is_dir() and canonical not in canonical_candidates:
                canonical_candidates.append(canonical)

        attached = False
        depth_failures: list[tuple[Path, int]] = []
        for exclusion in canonical_candidates:
            for root in directory_roots:
                if not is_strict_descendant(exclusion, root):
                    continue
                relative_depth = len(exclusion.relative_to(root).parts)
                if depth is not None and relative_depth > depth:
                    depth_failures.append((exclusion, relative_depth))
                    continue
                if exclusion not in result[root]:
                    result[root].append(exclusion)
                attached = True
                attached_raw.add(raw)

        if not attached and require_matches:
            if depth_failures:
                path, relative_depth = depth_failures[0]
                raise ValueError(
                    f"excluded directory {path} is at depth {relative_depth}, "
                    f"beyond the effective depth {depth}"
                )
            raise ValueError(
                f"excluded directory {raw!r} is not an existing strict descendant "
                "of any directory target in its effective scope"
            )
    return result, attached_raw


def merge_exclusion_maps(
    destination: dict[Path, list[Path]], source: dict[Path, list[Path]]
) -> None:
    """Merge per-root exclusion lists without changing their first-seen order."""
    for root, exclusions in source.items():
        for exclusion in exclusions:
            if exclusion not in destination[root]:
                destination[root].append(exclusion)


def resolve_target_groups(
    clauses: Sequence[TargetClause],
    configs: Sequence[GroupConfig],
    *,
    hidden: bool = False,
) -> list[TargetGroup]:
    """Resolve every target and exclusion after scope evaluation."""
    expanded_values = [expand_targets(clause.raw_targets, hidden=hidden) for clause in clauses]
    expanded_groups = [targets for targets, _ in expanded_values]
    resolution_warnings = [warnings for _, warnings in expanded_values]
    exclusion_maps: list[dict[Path, list[Path]]] = [
        {root: [] for root in roots} for roots in expanded_groups
    ]

    for roots, config, destination in zip(expanded_groups, configs, exclusion_maps, strict=True):
        local_map, _ = resolve_exclusions(
            config.local_excludes,
            roots,
            config.effective_depth,
            require_matches=True,
        )
        merge_exclusion_maps(destination, local_map)

    broadcast_excludes = dedupe_strings(
        exclusion for config in configs for exclusion in config.broadcast_excludes
    )
    for raw in broadcast_excludes:
        attached_anywhere = False
        for roots, config, destination in zip(
            expanded_groups, configs, exclusion_maps, strict=True
        ):
            if raw not in config.broadcast_excludes:
                continue
            broadcast_map, attached = resolve_exclusions(
                [raw],
                roots,
                config.effective_depth,
                require_matches=False,
            )
            merge_exclusion_maps(destination, broadcast_map)
            attached_anywhere = attached_anywhere or raw in attached
        if not attached_anywhere:
            depth_error: ValueError | None = None
            for roots, config in zip(expanded_groups, configs, strict=True):
                if raw not in config.broadcast_excludes:
                    continue
                try:
                    resolve_exclusions(
                        [raw],
                        roots,
                        config.effective_depth,
                        require_matches=True,
                    )
                except ValueError as exc:
                    if "beyond the effective depth" in str(exc):
                        depth_error = exc
                        break
            if depth_error is not None:
                raise depth_error
            raise ValueError(
                f"broadcast excluded directory {raw!r} is not an existing strict "
                "descendant reachable within the effective depth of any target"
            )

    groups: list[TargetGroup] = []
    grouped_values = zip(
        clauses,
        configs,
        expanded_groups,
        exclusion_maps,
        resolution_warnings,
        strict=True,
    )
    for index, (clause, config, roots, exclusions, warnings) in enumerate(grouped_values, start=1):
        root_specs = [RootSpec(path=root, exclusions=exclusions[root]) for root in roots]
        groups.append(
            TargetGroup(
                index=index,
                raw_targets=clause.raw_targets,
                roots=root_specs,
                config=config,
                resolution_warnings=warnings,
            )
        )
    return groups


def path_is_within(path: Path, parent: Path) -> bool:
    """Return true when path equals parent or is below it."""
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def path_is_excluded(path: Path, exclusions: Sequence[Path]) -> bool:
    """Check canonical path containment against exact excluded directories."""
    return any(path_is_within(path, exclusion) for exclusion in exclusions)


# ---------------------------------------------------------------------------
# Discovery backends
# ---------------------------------------------------------------------------


def find_fd() -> str | None:
    """Locate fd, including the Debian/Ubuntu ``fdfind`` spelling."""
    return shutil.which("fd") or shutil.which("fdfind")


def discover_with_fd(
    fd_binary: str,
    root: RootSpec,
    depth: int | None,
    *,
    hidden: bool,
) -> tuple[list[Path], list[str]]:
    """Discover regular files below one directory using NUL-delimited fd output."""
    if depth == 0:
        return [], []

    command = [
        fd_binary,
        "--type",
        "file",
        "--color",
        "never",
        "--absolute-path",
        "--print0",
        "--no-ignore",
    ]
    if hidden:
        command.append("--hidden")
    if depth is not None:
        command.extend(["--max-depth", str(depth)])
    # A leading slash anchors fd's glob to this search root. Without it,
    # "cache" would also exclude "other/cache". Canonical post-filtering below
    # remains the source of truth in case fd's matching behavior changes.
    for exclusion in root.exclusions:
        relative = exclusion.relative_to(root.path).as_posix()
        command.extend(["--exclude", "/" + glob.escape(relative)])
    command.extend([".", str(root.path)])

    try:
        completed = subprocess.run(command, capture_output=True, check=False)
    except OSError as exc:
        return [], [f"fd could not scan {root.path}: {exc}"]

    warnings: list[str] = []
    if completed.returncode != 0:
        detail = os.fsdecode(completed.stderr).strip()
        warnings.append(
            f"fd returned status {completed.returncode} for {root.path}"
            + (f": {detail}" if detail else "")
        )

    paths: list[Path] = []
    for raw in completed.stdout.split(b"\0"):
        if not raw:
            continue
        candidate = Path(os.fsdecode(raw))
        try:
            canonical = candidate.resolve(strict=True)
        except (OSError, RuntimeError):
            warnings.append(f"file disappeared before metadata collection: {candidate}")
            continue
        if not path_is_within(canonical, root.path):
            warnings.append(f"fd returned a path outside its target; skipped: {candidate}")
            continue
        if path_is_excluded(canonical, root.exclusions):
            continue
        paths.append(canonical)
    return sorted(set(paths), key=os.fspath), warnings


def discover_with_python(
    root: RootSpec,
    depth: int | None,
    *,
    hidden: bool,
) -> tuple[list[Path], list[str]]:
    """Discover regular files without following directory symlinks."""
    if depth == 0:
        return [], []

    paths: list[Path] = []
    warnings: list[str] = []
    stack: list[tuple[Path, int]] = [(root.path, 0)]
    while stack:
        directory, directory_depth = stack.pop()
        if depth is not None and directory_depth >= depth:
            continue
        try:
            with os.scandir(directory) as iterator:
                entries = sorted(iterator, key=lambda entry: entry.name)
        except OSError as exc:
            warnings.append(f"cannot read directory {directory}: {exc}")
            continue

        for entry in entries:
            if not hidden and entry.name.startswith("."):
                continue
            candidate = Path(entry.path)
            try:
                if entry.is_symlink():
                    continue
                if entry.is_dir(follow_symlinks=False):
                    canonical_dir = candidate.resolve(strict=True)
                    if path_is_within(canonical_dir, root.path) and not path_is_excluded(
                        canonical_dir, root.exclusions
                    ):
                        stack.append((canonical_dir, directory_depth + 1))
                elif entry.is_file(follow_symlinks=False):
                    canonical_file = candidate.resolve(strict=True)
                    if path_is_within(canonical_file, root.path) and not path_is_excluded(
                        canonical_file, root.exclusions
                    ):
                        paths.append(canonical_file)
            except (OSError, RuntimeError) as exc:
                warnings.append(f"cannot inspect {candidate}: {exc}")
    return paths, warnings


def discover_root(
    root: RootSpec,
    depth: int | None,
    *,
    backend: str,
    fd_binary: str | None,
    hidden: bool,
) -> tuple[list[Path], list[str]]:
    """Discover a file target directly or dispatch a directory to a backend."""
    if root.path.is_file():
        return [root.path], []
    if backend == "fd":
        assert fd_binary is not None
        return discover_with_fd(fd_binary, root, depth, hidden=hidden)
    return discover_with_python(root, depth, hidden=hidden)


# ---------------------------------------------------------------------------
# Classification and filtering
# ---------------------------------------------------------------------------


LANGUAGE_BY_SUFFIX = {
    ".awk": "awk",
    ".bash": "shell",
    ".cjs": "javascript",
    ".fish": "shell",
    ".gjs": "javascript",
    ".js": "javascript",
    ".ksh": "shell",
    ".lua": "lua",
    ".mjs": "javascript",
    ".php": "php",
    ".pl": "perl",
    ".ps1": "powershell",
    ".py": "python",
    ".r": "r",
    ".rb": "ruby",
    ".rmd": "r-markdown",
    ".sed": "sed",
    ".sh": "shell",
    ".ts": "typescript",
    ".zsh": "shell",
}
SCRIPT_SUFFIXES = frozenset(LANGUAGE_BY_SUFFIX)
SELECTOR_LANGUAGE = {
    "awk": "awk",
    "bash": "shell",
    "fish": "shell",
    "js": "javascript",
    "javascript": "javascript",
    "ksh": "shell",
    "lua": "lua",
    "node": "javascript",
    "perl": "perl",
    "php": "php",
    "powershell": "powershell",
    "ps1": "powershell",
    "py": "python",
    "python": "python",
    "r": "r",
    "rb": "ruby",
    "rscript": "r",
    "ruby": "ruby",
    "sh": "shell",
    "shell": "shell",
    "ts": "typescript",
    "typescript": "typescript",
    "zsh": "shell",
}
EXPLICIT_LANGUAGE_SELECTORS = {
    "javascript",
    "powershell",
    "python",
    "shell",
    "typescript",
}


def normalize_interpreter(interpreter: str) -> str:
    """Map an interpreter basename to a stable language label."""
    value = interpreter.casefold()
    if re.fullmatch(r"python(?:\d+(?:\.\d+)*)?", value):
        return "python"
    if value in {"bash", "dash", "fish", "ksh", "sh", "zsh"}:
        return "shell"
    if value in {"r", "rscript"}:
        return "r"
    if value in {"node", "nodejs", "gjs", "deno", "bun"}:
        return "javascript"
    if value in {"pwsh", "powershell"}:
        return "powershell"
    if value in {"ruby", "perl", "lua", "php", "awk", "sed"}:
        return value
    return value


def interpreter_from_shebang(line: str) -> str:
    """Extract an interpreter from direct and ``/usr/bin/env`` shebangs."""
    if not line.startswith("#!"):
        return ""
    command = line[2:].strip()
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()
    if not tokens:
        return ""

    executable = Path(tokens[0]).name
    if executable != "env":
        return executable

    index = 1
    while index < len(tokens):
        token = tokens[index]
        if token == "--":
            index += 1
            break
        if token == "-S":
            index += 1
            break
        if token.startswith("-") or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", token):
            index += 1
            continue
        break
    return Path(tokens[index]).name if index < len(tokens) else ""


def read_shebang(path: Path) -> tuple[str, str]:
    """Read at most one bounded first line and return shebang/interpreter."""
    try:
        with path.open("rb") as handle:
            first_line = handle.readline(SHEBANG_READ_LIMIT)
    except OSError:
        return "", ""
    if not first_line.startswith(b"#!") or b"\0" in first_line:
        return "", ""
    line = first_line.decode("utf-8", errors="replace").rstrip("\r\n")
    return line, interpreter_from_shebang(line)


def classify_path(path: Path, interpreter: str) -> tuple[str, str]:
    """Return the final suffix and normalized language classification."""
    extension = path.suffix
    suffix_language = LANGUAGE_BY_SUFFIX.get(extension.casefold(), "")
    language = normalize_interpreter(interpreter) if interpreter else suffix_language
    return extension, language


def _selector_text(text: str, case_sensitive: bool) -> str:
    return text if case_sensitive else text.casefold()


def selector_matches(record: FileRecord, selector: str, *, case_sensitive: bool) -> bool:
    """Match a suffix, filename glob, language alias, ``script``, or ``noext``."""
    raw = selector.strip()
    if not raw:
        return False
    compare = _selector_text(raw, case_sensitive)
    name = _selector_text(record.name, case_sensitive)
    language = _selector_text(record.language, case_sensitive)
    suffixes = _selector_text("".join(record.path.suffixes), case_sensitive)

    special = compare.casefold()
    if special in {"noext", "extensionless"}:
        return not record.extension
    if special in {"script", "shebang"}:
        return bool(record.shebang) or record.extension.casefold() in SCRIPT_SUFFIXES

    has_glob = any(character in raw for character in "*?[")
    simple_star_suffix = raw.startswith("*.") and not any(
        character in raw[2:] for character in "*?["
    )
    if has_glob and not simple_star_suffix:
        return fnmatch.fnmatchcase(name, compare)

    normalized = compare
    if normalized.startswith("*."):
        normalized = normalized[2:]
    elif normalized.startswith("."):
        normalized = normalized[1:]
    if not normalized:
        return False

    language_key = normalized if case_sensitive else normalized.casefold()
    wanted_language = SELECTOR_LANGUAGE.get(language_key)
    suffix_match = suffixes.endswith("." + normalized)
    language_match = (
        wanted_language is not None
        and language == wanted_language
        and (not record.extension or normalized.casefold() in EXPLICIT_LANGUAGE_SELECTORS)
    )
    return suffix_match or language_match


def record_matches(record: FileRecord, config: GroupConfig, *, case_sensitive: bool) -> bool:
    """Apply inclusive size bounds and extension/shebang selectors."""
    if config.min_size is not None and record.size < config.min_size:
        return False
    if config.max_size is not None and record.size > config.max_size:
        return False
    if config.extensions and not any(
        selector_matches(record, selector, case_sensitive=case_sensitive)
        for selector in config.extensions
    ):
        return False
    if any(
        selector_matches(record, selector, case_sensitive=case_sensitive)
        for selector in config.exclude_extensions
    ):
        return False
    return True


def build_record(path: Path, group: int, root: Path) -> FileRecord | None:
    """Collect lstat metadata and bounded shebang classification for one file."""
    try:
        metadata = path.lstat()
    except OSError:
        return None
    if not stat.S_ISREG(metadata.st_mode):
        return None

    shebang, interpreter = read_shebang(path)
    extension, language = classify_path(path, interpreter)
    try:
        relative = str(path.relative_to(root)) if root.is_dir() else path.name
    except ValueError:
        relative = path.name
    return FileRecord(
        path=path,
        groups=(group,),
        roots=(root,),
        relative_paths=(relative,),
        memberships=((group, root, relative),),
        name=path.name,
        extension=extension,
        language=language,
        interpreter=interpreter,
        shebang=shebang,
        executable=bool(metadata.st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)),
        size=int(metadata.st_size),
        mtime=float(metadata.st_mtime),
    )


# ---------------------------------------------------------------------------
# Sorting, limits, and inventory orchestration
# ---------------------------------------------------------------------------


def sort_records(records: Iterable[FileRecord], key: str, reverse: bool) -> list[FileRecord]:
    """Sort deterministically with size/date descending by default."""
    ordered = sorted(
        records,
        key=lambda record: (
            os.fspath(record.path).casefold(),
            os.fspath(record.path),
        ),
    )
    if key == "path":
        return list(reversed(ordered)) if reverse else ordered

    accessors = {
        "name": lambda record: record.name.casefold(),
        "extension": lambda record: record.extension.casefold(),
        "language": lambda record: record.language.casefold(),
        "size": lambda record: record.size,
        "date": lambda record: record.mtime,
    }
    descending_default = key in {"size", "date"}
    return sorted(ordered, key=accessors[key], reverse=descending_default != reverse)


def merge_record(existing: FileRecord, incoming: FileRecord) -> FileRecord:
    """Combine target memberships for one canonical file."""
    groups = tuple(dict.fromkeys((*existing.groups, *incoming.groups)))
    roots = tuple(dict.fromkeys((*existing.roots, *incoming.roots)))
    relative_paths = tuple(dict.fromkeys((*existing.relative_paths, *incoming.relative_paths)))
    memberships = tuple(dict.fromkeys((*existing.memberships, *incoming.memberships)))
    return replace(
        existing,
        groups=groups,
        roots=roots,
        relative_paths=relative_paths,
        memberships=memberships,
    )


def merge_records(records: Iterable[FileRecord]) -> list[FileRecord]:
    """Deduplicate canonical paths while retaining all target memberships."""
    merged: dict[Path, FileRecord] = {}
    for record in records:
        if record.path in merged:
            merged[record.path] = merge_record(merged[record.path], record)
        else:
            merged[record.path] = record
    return list(merged.values())


def inventory(
    groups: Sequence[TargetGroup],
    *,
    backend_request: str,
    hidden: bool,
    case_sensitive: bool,
    sort_key: str,
    reverse_sort: bool,
    global_limit: int | None,
) -> InventoryResult:
    """Discover, classify, filter, sort, deduplicate, and limit all groups."""
    fd_binary = find_fd()
    if backend_request == "fd" and fd_binary is None:
        raise RuntimeError("--backend fd was requested, but neither fd nor fdfind is in PATH")
    backend = (
        "fd" if backend_request == "fd" or (backend_request == "auto" and fd_binary) else "python"
    )

    stats: list[GroupStats] = []
    warnings = [warning for group in groups for warning in group.resolution_warnings]
    matched_by_group: list[list[FileRecord]] = []
    selected_by_group: list[list[FileRecord]] = []

    for group in groups:
        group_stats = GroupStats(group_index=group.index)
        records: dict[Path, FileRecord] = {}
        for root in group.roots:
            paths, root_warnings = discover_root(
                root,
                group.config.effective_depth,
                backend=backend,
                fd_binary=fd_binary,
                hidden=hidden,
            )
            warnings.extend(root_warnings)
            group_stats.errors += len(root_warnings)
            group_stats.discovered += len(paths)
            for path in paths:
                record = build_record(path, group.index, root.path)
                if record is None:
                    group_stats.errors += 1
                    warnings.append(f"could not collect regular-file metadata: {path}")
                    continue
                if record_matches(record, group.config, case_sensitive=case_sensitive):
                    if path in records:
                        records[path] = merge_record(records[path], record)
                    else:
                        records[path] = record

        matched = sort_records(records.values(), sort_key, reverse_sort)
        selected = matched
        if group.config.number_results is not None:
            selected = matched[: group.config.number_results]

        group_stats.matched = len(matched)
        group_stats.selected = len(selected)
        group_stats.matched_bytes = sum(record.size for record in matched)
        group_stats.selected_bytes = sum(record.size for record in selected)
        matched_by_group.append(matched)
        selected_by_group.append(selected)
        stats.append(group_stats)

    all_matched = sort_records(
        merge_records(record for records in matched_by_group for record in records),
        sort_key,
        reverse_sort,
    )
    selected = sort_records(
        merge_records(record for records in selected_by_group for record in records),
        sort_key,
        reverse_sort,
    )
    displayed = selected if global_limit is None else selected[:global_limit]

    for group_stats in stats:
        group_stats.displayed = sum(
            group_stats.group_index in record.groups for record in displayed
        )
        group_stats.displayed_bytes = sum(
            record.size for record in displayed if group_stats.group_index in record.groups
        )

    return InventoryResult(
        groups=list(groups),
        all_matched=all_matched,
        selected=selected,
        displayed=displayed,
        stats=stats,
        backend=backend,
        warnings=warnings,
    )


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------


def human_bytes(number: int) -> str:
    """Format bytes with binary IEC units."""
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    value = float(number)
    for unit in units:
        if abs(value) < 1024 or unit == units[-1]:
            return f"{int(value)} B" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{number} B"  # pragma: no cover


def mtime_utc(timestamp: float) -> str:
    """Render an epoch timestamp as an explicit UTC ISO-8601 string."""
    return datetime.fromtimestamp(timestamp, tz=timezone.utc).isoformat(timespec="seconds")


def safe_unicode(value: object) -> str:
    """Return valid UTF-8 text, escaping filesystem surrogate code points."""
    return str(value).encode("utf-8", errors="backslashreplace").decode("utf-8")


def terminal_text(value: object) -> str:
    """Escape controls so arbitrary filenames cannot alter terminal structure."""
    text = safe_unicode(value)
    escaped: list[str] = []
    named = {"\n": r"\n", "\r": r"\r", "\t": r"\t"}
    for character in text:
        if character in named:
            escaped.append(named[character])
            continue
        codepoint = ord(character)
        if codepoint < 32 or 127 <= codepoint < 160:
            width = 2 if codepoint <= 0xFF else 4
            prefix = "x" if width == 2 else "u"
            escaped.append(f"\\{prefix}{codepoint:0{width}x}")
        else:
            escaped.append(character)
    return "".join(escaped)


def group_depth_text(config: GroupConfig) -> str:
    """Describe one group's effective traversal depth."""
    depth = config.effective_depth
    return "unlimited" if depth is None else str(depth)


def target_summary(group: TargetGroup) -> str:
    """Summarize large expanded target globs without flooding terminal output."""
    if len(group.raw_targets) == 1 and len(group.roots) == 1:
        raw = os.path.expandvars(os.path.expanduser(group.raw_targets[0]))
        if not glob.has_magic(raw):
            return str(group.roots[0].path)
    raw_summary = ", ".join(group.raw_targets)
    return f"{raw_summary} ({len(group.roots)} resolved roots)"


def filter_text(config: GroupConfig, effective_exclusions: Sequence[Path] = ()) -> str:
    """Summarize selectors and size bounds compactly."""
    parts: list[str] = []
    if config.extensions:
        parts.append("+" + ",".join(config.extensions))
    if config.exclude_extensions:
        parts.append("-" + ",".join(config.exclude_extensions))
    if config.min_size is not None:
        parts.append(f">={human_bytes(config.min_size)}")
    if config.max_size is not None:
        parts.append(f"<={human_bytes(config.max_size)}")
    if effective_exclusions:
        parts.append("exclude:" + ",".join(map(str, effective_exclusions)))
    if config.number_results is not None:
        parts.append(f"n<={config.number_results}")
    return " ".join(parts) if parts else "all files"


def type_label(record: FileRecord) -> str:
    """Return an extension-first label for aggregate summaries."""
    if record.extension:
        return record.extension
    if record.language:
        return f"[no ext: {record.language}]"
    return "[no extension]"


def type_summary(records: Sequence[FileRecord]) -> list[tuple[str, int, int]]:
    """Aggregate unique matched records by extension/shebang classification."""
    counts: Counter[str] = Counter()
    sizes: Counter[str] = Counter()
    for record in records:
        label = type_label(record)
        counts[label] += 1
        sizes[label] += record.size
    return sorted(
        ((label, count, sizes[label]) for label, count in counts.items()),
        key=lambda item: (-item[1], item[0].casefold()),
    )


def global_totals(
    result: InventoryResult,
) -> tuple[tuple[int, int], tuple[int, int], tuple[int, int]]:
    """Return matched, selected, and displayed unique counts/bytes."""
    return (
        (len(result.all_matched), sum(record.size for record in result.all_matched)),
        (len(result.selected), sum(record.size for record in result.selected)),
        (len(result.displayed), sum(record.size for record in result.displayed)),
    )


def render_rich(result: InventoryResult, *, total_size: bool, summary_only: bool) -> bool:
    """Render Rich tables, returning false when Rich is unavailable."""
    try:
        from rich.console import Console
        from rich.markup import escape
        from rich.table import Table
    except ImportError:
        return False

    console = Console()
    summary = Table(title=f"File inventory ({result.backend} backend)", show_lines=False)
    summary.add_column("Group", justify="right")
    summary.add_column("Targets", overflow="fold")
    summary.add_column("Depth", justify="right")
    summary.add_column("Filters", overflow="fold")
    summary.add_column("Matched", justify="right")
    summary.add_column("Selected", justify="right")
    summary.add_column("Shown", justify="right")
    if total_size:
        summary.add_column("Matched size", justify="right")

    for group, stats_row in zip(result.groups, result.stats, strict=True):
        effective_exclusions = list(
            dict.fromkeys(exclusion for root in group.roots for exclusion in root.exclusions)
        )
        summary.add_row(
            str(group.index),
            escape(terminal_text(target_summary(group))),
            group_depth_text(group.config),
            escape(terminal_text(filter_text(group.config, effective_exclusions))),
            str(stats_row.matched),
            str(stats_row.selected),
            str(stats_row.displayed),
            *([human_bytes(stats_row.matched_bytes)] if total_size else []),
        )
    console.print(summary)

    aggregates = Table(title="Matched files by extension or shebang type")
    aggregates.add_column("Type")
    aggregates.add_column("Files", justify="right")
    aggregates.add_column("Apparent size", justify="right")
    for label, count, size in type_summary(result.all_matched):
        aggregates.add_row(escape(terminal_text(label)), str(count), human_bytes(size))
    if not result.all_matched:
        aggregates.add_row(escape("[none]"), "0", "0 B")
    console.print(aggregates)

    if total_size:
        matched, selected, displayed = global_totals(result)
        console.print(
            "Totals (unique files): "
            f"matched {matched[0]} / {human_bytes(matched[1])}; "
            f"after per-group limits {selected[0]} / {human_bytes(selected[1])}; "
            f"displayed {displayed[0]} / {human_bytes(displayed[1])}."
        )

    if not summary_only:
        files = Table(title="Displayed files", show_lines=False)
        files.add_column("#", justify="right")
        files.add_column("Group")
        files.add_column("Size", justify="right", no_wrap=True)
        files.add_column("Modified (UTC)", no_wrap=True)
        files.add_column("Type")
        files.add_column("Interpreter")
        files.add_column("Path", overflow="fold")
        for index, record in enumerate(result.displayed, start=1):
            files.add_row(
                str(index),
                ",".join(map(str, record.groups)),
                human_bytes(record.size),
                mtime_utc(record.mtime),
                escape(terminal_text(record.language or record.extension or "-")),
                escape(terminal_text(record.interpreter or "-")),
                escape(terminal_text(record.path)),
            )
        if not result.displayed:
            files.add_row("-", "-", "-", "-", "-", "-", "No matching files")
        console.print(files)
    return True


def render_plain(result: InventoryResult, *, total_size: bool, summary_only: bool) -> None:
    """Render stable tab-delimited summaries without ANSI escapes."""
    print(f"File inventory ({result.backend} backend)")
    columns = ["group", "targets", "depth", "filters", "matched", "selected", "shown"]
    if total_size:
        columns.append("matched_size")
    print("\t".join(columns))
    for group, stats_row in zip(result.groups, result.stats, strict=True):
        effective_exclusions = list(
            dict.fromkeys(exclusion for root in group.roots for exclusion in root.exclusions)
        )
        row = [
            str(group.index),
            terminal_text(target_summary(group)),
            group_depth_text(group.config),
            terminal_text(filter_text(group.config, effective_exclusions)),
            str(stats_row.matched),
            str(stats_row.selected),
            str(stats_row.displayed),
        ]
        if total_size:
            row.append(str(stats_row.matched_bytes))
        print("\t".join(row))

    print("\nMatched files by extension or shebang type")
    print("type\tfiles\tsize_bytes")
    for label, count, size in type_summary(result.all_matched):
        print(f"{terminal_text(label)}\t{count}\t{size}")

    if total_size:
        matched, selected, displayed = global_totals(result)
        print(
            "\nTotals (unique files): "
            f"matched={matched[0]}/{matched[1]}B "
            f"selected={selected[0]}/{selected[1]}B "
            f"displayed={displayed[0]}/{displayed[1]}B"
        )

    if summary_only:
        return
    print("\nDisplayed files")
    print("index\tgroups\tsize_bytes\tmtime_utc\ttype\tinterpreter\tpath")
    for index, record in enumerate(result.displayed, start=1):
        print(
            "\t".join(
                [
                    str(index),
                    ",".join(map(str, record.groups)),
                    str(record.size),
                    mtime_utc(record.mtime),
                    terminal_text(record.language or record.extension or "-"),
                    terminal_text(record.interpreter or "-"),
                    terminal_text(record.path),
                ]
            )
        )


CSV_FIELDS = [
    "index",
    "groups",
    "roots",
    "path",
    "relative_paths",
    "memberships",
    "name",
    "extension",
    "language",
    "interpreter",
    "shebang",
    "executable",
    "size_bytes",
    "size_human",
    "mtime_utc",
]


def write_csv(records: Sequence[FileRecord], destination: str) -> None:
    """Write displayed records; filesystem output is replaced atomically."""

    def emit(handle: IO[str]) -> None:
        writer = csv.DictWriter(handle, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for index, record in enumerate(records, start=1):
            writer.writerow(
                {
                    "index": index,
                    "groups": json.dumps(record.groups),
                    "roots": json.dumps(
                        [safe_unicode(root) for root in record.roots],
                        ensure_ascii=False,
                    ),
                    "path": safe_unicode(record.path),
                    "relative_paths": json.dumps(
                        [safe_unicode(path) for path in record.relative_paths],
                        ensure_ascii=False,
                    ),
                    "memberships": json.dumps(
                        [
                            {
                                "group": group,
                                "root": safe_unicode(root),
                                "relative_path": safe_unicode(relative),
                            }
                            for group, root, relative in record.memberships
                        ],
                        ensure_ascii=False,
                    ),
                    "name": safe_unicode(record.name),
                    "extension": safe_unicode(record.extension),
                    "language": safe_unicode(record.language),
                    "interpreter": safe_unicode(record.interpreter),
                    "shebang": safe_unicode(record.shebang),
                    "executable": str(record.executable).lower(),
                    "size_bytes": record.size,
                    "size_human": human_bytes(record.size),
                    "mtime_utc": mtime_utc(record.mtime),
                }
            )

    if destination == "-":
        try:
            emit(sys.stdout)
        except (csv.Error, OSError, UnicodeError) as exc:
            raise RuntimeError(f"cannot write CSV to stdout: {exc}") from exc
        return

    output_path = Path(destination).expanduser()
    existing_mode: int | None = None
    try:
        output_metadata = output_path.lstat()
        if not stat.S_ISREG(output_metadata.st_mode):
            raise RuntimeError(f"refusing to replace non-regular CSV destination: {output_path}")
        existing_mode = stat.S_IMODE(output_metadata.st_mode)
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise RuntimeError(f"cannot inspect CSV output {output_path}: {exc}") from exc

    temporary_name: str | None = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            dir=output_path.parent,
            prefix=f".{output_path.name}.",
            suffix=".tmp",
        )
        with os.fdopen(descriptor, "w", newline="", encoding="utf-8") as handle:
            if existing_mode is not None:
                os.fchmod(handle.fileno(), existing_mode)
            emit(handle)
        os.replace(temporary_name, output_path)
        temporary_name = None
    except (csv.Error, OSError, UnicodeError) as exc:
        raise RuntimeError(f"cannot write CSV output {output_path}: {exc}") from exc
    finally:
        if temporary_name is not None:
            try:
                Path(temporary_name).unlink()
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main(argv: Sequence[str] | None = None) -> int:
    """Run the command-line inventory."""
    arguments = list(sys.argv[1:] if argv is None else argv)
    try:
        namespace, clauses, configs = parse_cli(arguments)
        groups = resolve_target_groups(clauses, configs, hidden=namespace.hidden)
        result = inventory(
            groups,
            backend_request=namespace.backend,
            hidden=namespace.hidden,
            case_sensitive=namespace.case_sensitive,
            sort_key=namespace.sort,
            reverse_sort=namespace.reverse,
            global_limit=namespace.limit,
        )
    except (RuntimeError, ValueError) as exc:
        print(f"file-inventory.py: error: {terminal_text(exc)}", file=sys.stderr)
        return 2

    for warning in result.warnings:
        print(f"file-inventory.py: warning: {terminal_text(warning)}", file=sys.stderr)

    if namespace.csv:
        try:
            write_csv(result.displayed, namespace.csv)
        except RuntimeError as exc:
            print(f"file-inventory.py: error: {terminal_text(exc)}", file=sys.stderr)
            return 2
        if namespace.csv == "-":
            return 0

    if not namespace.no_rich and render_rich(
        result,
        total_size=namespace.total_size,
        summary_only=namespace.summary_only,
    ):
        pass
    else:
        render_plain(
            result,
            total_size=namespace.total_size,
            summary_only=namespace.summary_only,
        )

    if namespace.csv:
        print(
            f"CSV written to {terminal_text(Path(namespace.csv).expanduser())}",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
