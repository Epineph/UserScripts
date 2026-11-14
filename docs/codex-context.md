# Current project context

## File encryption wrapper, 2026-11-14

- Added `find-encrypt.sh`, `docs/find-encrypt.md`, and focused pytest coverage.
  The pre-existing `encrypt-files.sh` is a separate fixed CSV export workflow.
- Multiple positional paths and `-t/--target` select roots/files. Extensions
  accept repeated or comma-separated values. Paths never split on commas.
- Uses fd if installed, otherwise find; common matching rules ignore ignore
  files. Optional fzf multi-selection has isolated defaults and NUL I/O.
- Encryption is always enabled. Password flags take no values; hidden terminal
  input is confirmed, or `--password-stdin` supplies one line. Passwords travel
  via a pipe. Silent mode requires stdin passwords and disallows fzf.
- Flat archive layout is the default. `--keep-paths` stores relative paths
  beneath the common source base. Flat mode rejects duplicate basenames.
- Stages and tests before publishing without overwriting. Explicit cleanup
  checks original file identity and metadata, handles hardlink ctime changes,
  and prunes only empty selected-parent directories below protected roots.
- Regression fixes: explicitly guard `cd` in conditional subshells; reject
  symlink roots with trailing slashes and symlink ancestors; avoid translating
  incompatible shell glob syntax into fd exclusion syntax.
- Confirmed Arch Linux, 7-Zip 26.06, fd 10.5.0, and fzf 0.74.5 locally.
- Checks: Bash syntax, ShellCheck, shfmt, real 7z round trips, and 67 focused
  pytest cases. Test fixtures and archives are confined to temporary paths.
  A real pseudo-terminal run also verified fzf Ctrl-A/Enter selection, hidden
  password confirmation without echo, encryption, and exact extraction.
- The existing `pyproject.toml` Ruff configuration contains unsupported W503.
  The test file was checked with equivalent isolated Ruff rules and Black;
  repository configuration was left as found.
- Useful commands are in the guide's Validation section. No installation,
  push, or encryption/deletion of the user's existing files was performed.
