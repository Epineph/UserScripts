# AI Agent Instructions for UserScripts

## Project Overview

UserScripts is a large personal utility collection of ~500+ shell scripts and Python utilities spanning system administration, build automation, disk management, networking, and installation workflows—primarily for Arch Linux-based systems.

## Architecture & Organization

### Multi-Language Approach

- **Primary:** Bash/sh scripts (majority) with strict mode: `set -euo pipefail` + `IFS=$'\n\t'`
- **Secondary:** Python 3 (utilities, automation, analysis)
- **Tertiary:** PowerShell (Windows-specific scripts)
- Scripts are **flat** at root level (no monolithic component structure)—organized loosely by function (build, install, disk, git, network, hyprland, etc.)

### Critical Patterns

#### 1. Bash Script Conventions

- **Strict mode mandatory** for new bash scripts:
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  IFS=$'\n\t'
  ```
- **Helper functions** precede main logic: `_log()`, `_die()`, `_have()` (examples: [build-llvm.sh](build-llvm.sh#L27-L44))
- **Exit codes:** Always return non-zero on error; use `[[ $# -eq N ]]` for arg count validation
- **Help text:** Use heredocs with `cat <<'EOF'` and provide `-h|--help` flag support
- **Temp files:** Use `mktemp` for cleanup-safe operations
- **Command checks:** Verify tools exist via `command -v` or `_have()` before use

#### 2. Python Script Patterns

- **Shebang:** `#!/usr/bin/env python3`
- **Documentation:** Include docstrings with features, examples, and usage
- **Rich library:** Use `rich.progress` for progress bars and colored output (see [downloader.py](downloader.py))
- **Type hints:** Include them when appropriate for clarity
- **Argparse:** Use for CLI argument parsing; avoid positional-only for flexibility

#### 3. Build & Installation Scripts

Scripts like [build-llvm.sh](build-llvm.sh), [build_repo.sh](build_repo.sh) follow a pattern:

- Detect project type (CMake, Autotools, Cargo, Python, Node, Go)
- Use out-of-tree builds (separate `build/` directory)
- Install to `$HOME/bin` or `$HOME/.local/` unless system-wide install is intended
- Support `--help` and `--directory` flags
- Log all significant actions with timestamps

#### 4. Disk/Storage Scripts

Heavy use of system utilities (`lvm`, `mdadm`, `cryptsetup`, `dd`, `shred`, `wipefs`):

- **Root requirement:** Always check `[[ $(id -u) -eq 0 ]]` or document
- **Safety checks:** Verify mountpoints, prompt before destructive ops
- **Examples:** [secure-wipe.sh](secure-wipe.sh), [disk_usage_report.py](disk_usage_report.py)

#### 5. Git/Clone Scripts

[clone-all-repositories.sh](clone-all-repositories.sh) exemplifies:

- URL canonicalization (lowercase, strip `.git`)
- Duplicate detection by normalized URL
- Deduplication logging (who claimed it first)
- Config-driven repo lists (inline arrays of `"name url"` pairs)

## Developer Workflows

### Running/Testing Scripts

1. Most scripts accept `--help` to show usage
2. Verify shebang is correct (`#!/usr/bin/env bash` preferred over `/bin/bash`)
3. For system-critical scripts (disk, LVM, crypto): **test in isolated VMs or with mock data first**
4. Check dependencies listed in comments (e.g., [build-llvm.sh](build-llvm.sh#L12-L15))

### Adding New Scripts

- Follow **strict mode** for bash scripts
- Add **help text** using heredocs
- Document **dependencies** in header comments
- Use **helper functions** for common tasks (logging, validation)
- Test **argument parsing** with edge cases (no args, wrong args, `-h`)
- Name scripts clearly: verb-noun pattern (`build-llvm.sh`, `secure-wipe.sh`) or noun-verb (`backup_usb.sh`)

## Key Files & Patterns

| Pattern          | Example                                                                        | Purpose                                                                |
| ---------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------- |
| Build automation | [build-llvm.sh](build-llvm.sh), [build_repo.sh](build_repo.sh)                 | Compile LLVM from source; detect & build projects (CMake, Cargo, etc.) |
| Disk management  | [secure-wipe.sh](secure-wipe.sh), [disk_usage_report.py](disk_usage_report.py) | Secure erasure, space analysis, LVM/LUKS ops                           |
| Git operations   | [clone-all-repositories.sh](clone-all-repositories.sh)                         | Batch clone with dedup, URL normalization                              |
| System admin     | `install-*-packages.sh`, `pacman-*`, `yay-*`                                   | Arch Linux package mgmt, AUR builds                                    |
| Hyprland config  | `hypr_scripts/`, `hyprland_*`                                                  | Wayland window manager setup                                           |

## Non-Obvious Conventions

1. **IFS manipulation:** Custom IFS is used in many scripts to handle newlines & tabs safely; preserve existing `IFS=$'\n\t'`
2. **Function scoping:** Leading underscore prefix (`_log`, `_die`) signals "internal helper"; no leading underscore = exportable
3. **Color output:** Use ANSI codes or avoid color in core logic; reserve color for status messages & errors
4. **No global state:** Scripts are typically stateless; avoid relying on environment variables not mentioned in `--help`
5. **Logging:** Use stderr (`>&2`) for logs/errors; stdout only for intended output data

## When to Ask for Clarification

Before implementing changes:

- If a script modifies system state (mounts, partitions, crypto), clarify the test environment
- If adding new dependencies (Python packages, system tools), verify they're acceptable for this repo
- If changing naming conventions or file organization, confirm alignment with existing patterns

---

_Last updated: February 2026. For questions, reference the script headers and existing patterns._
