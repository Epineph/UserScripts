# Find and encrypt files

[`find-encrypt.sh`](../find-encrypt.sh) selects regular files from one or more
paths and creates one encrypted `.7z` archive. File contents and archive
filenames are encrypted. The default layout is flat; use `--keep-paths` to
preserve directory structure. Originals are kept unless deletion is requested.

The complete command reference and examples are also available with:

```bash
./find-encrypt.sh --help
```

## Quick start

Preview the selection, then repeat without `--dry-run` to create the archive:

```bash
./find-encrypt.sh -t ~/Downloads /mnt/images \
  -e iso,img --exclude ~/Downloads/old \
  --keep-paths -o ~/Backups/images --dry-run

./find-encrypt.sh -t ~/Downloads /mnt/images \
  -e iso,img --exclude ~/Downloads/old \
  --keep-paths -o ~/Backups/images
```

The command prompts for a hidden passphrase and confirmation. `-p`,
`--passphrase`, `--password`, and `--encrypt` are equivalent optional flags;
encryption is already enabled. They **do not take a password argument**.
Empty passwords are rejected. Passwords are passed to 7z through a pipe,
never included in command arguments, logs, or environment variables.

## Requirements

The script uses Bash 4+, GNU coreutils, `iconv`, and `7z`, `7zz`, or `7za`.
It uses `fd` if available and falls back to `find`. `fzf` is needed only for
`--interactive`. It does not invoke `sudo` or install packages.

On the verified Arch Linux host, these tools were already installed. For an
Arch installation missing them, the corresponding package command is:

```bash
sudo pacman -S --needed 7zip fd fzf
```

The optional tools are described in the upstream [fd documentation](
https://github.com/sharkdp/fd) and [fzf documentation](
https://github.com/junegunn/fzf).

## Paths, file types, and exclusions

Positional paths, `-t/--target`, and `--path` can be combined. Paths are separate
shell arguments; quote each path containing spaces. Commas in paths remain
literal characters. With options but no paths, the search root is `.`.

```bash
# Several directories, including a path containing spaces
./find-encrypt.sh -t ~/Downloads '/mnt/External Drive/images' -o images

# Repeated targets and explicit files
./find-encrypt.sh -t ~/Documents -t ~/Pictures --keep-paths -o personal
./find-encrypt.sh './one.txt' './notes,final.txt' -o selected

# Several extensions: these forms are equivalent
./find-encrypt.sh ~/Downloads -e iso,img,pdf -o selected
./find-encrypt.sh ~/Downloads -e iso -e img -e pdf -o selected

# Leading dots, mixed case, and compound extensions are supported
./find-encrypt.sh ~/Backups -e .ISO,tar.gz,tar.zst -l 0 -o backups

# Filename globs: either glob matches, then the extension filter applies
./find-encrypt.sh ~/Docs -e pdf,docx \
  -g '*report*' -g '*invoice*' -o documents

# Search for an exact filename in several subdirectories
./find-encrypt.sh ~/Work -g results.csv --keep-paths -o results
```

Extensions match case-insensitively. Filename globs and exclusions are
case-sensitive. Repeated extensions use OR, repeated globs use OR, and the two
filter families combine with AND. Filters also apply to explicit file inputs.

| Exclusion | Meaning |
| --- | --- |
| `--exclude /data/old` | That literal absolute path and its descendants |
| `--exclude cache/temp` | That literal path beneath each search root |
| `--exclude ./old` | Only `old` directly beneath each search root |
| `--exclude old` | A file or directory component named `old` at any depth |
| `--exclude 'cache*'` | Any component matching the shell glob |

```bash
./find-encrypt.sh ~/Downloads -e iso,img \
  --exclude ~/Downloads/old -x 'cache*' -o images

./find-encrypt.sh -t ~/One ~/Two \
  -x ./old -x cache/temp --keep-paths -o selected

./find-encrypt.sh ~/Work --hidden -x .git --keep-paths -o work
./find-encrypt.sh ~/Work --backend find --keep-paths -o work --dry-run
```

Hidden files and directories are excluded unless `--hidden` is supplied.
An explicitly named hidden directory can be a root; hidden descendants still
require `--hidden`. Ignore files such as `.gitignore` are not consulted, so the
selection does not silently change when switching between fd and find.
Symlink entries are skipped, and roots reached through symlinks are refused.

## Interactive selection

```bash
./find-encrypt.sh -t ~/Downloads /mnt/images -e iso,img \
  --interactive --keep-paths --output images
```

Use Tab or Shift-Tab to toggle a file, Ctrl-A to select all, Ctrl-D to clear
selection, Enter to accept, and Esc to cancel. With no checked rows, Enter
accepts the current row according to fzf's usual behavior. Cancelling creates
no archive and deletes nothing. Paths are NUL-delimited when sent to fzf.
The wrapper clears `FZF_DEFAULT_OPTS`, `FZF_DEFAULT_OPTS_FILE`, and
`FZF_DEFAULT_COMMAND` for this invocation so personal bindings cannot replace
the intended selection command.

## Output naming

| Arguments | Result |
| --- | --- |
| `-o backup` | `./backup.7z` |
| `-o /safe/backup` | `/safe/backup.7z` |
| `-o /safe/backup.7z` | `/safe/backup.7z` |
| `-o /safe/ --name backup` | `/safe/backup.7z` |
| `--name backup` | `./backup.7z` |
| `-o backup.7z --name backup` | Accepted: normalized names agree |
| `-o backup.7z --name other` | Error, exit status 1 |

An existing directory or an output ending in `/` is a destination directory.
For a new directory, include the trailing `/`. Otherwise output is a filename.
`--name` must be a basename without `/`. The default name is
`encrypted-files.7z`; any filename without the exact `.7z` suffix receives it.
Existing output files and symlinks are refused. Missing output directories
are created only during actual archive creation, with private permissions.

## Flat or preserved paths

Without `--keep-paths`, files are stored at the top level:

```text
/data/work/reports/results.csv  -> results.csv
/data/work/notes/readme.txt     -> readme.txt
```

With `--keep-paths` and `/data/work` as the root:

```text
/data/work/reports/results.csv  -> reports/results.csv
/data/work/notes/readme.txt     -> notes/readme.txt
```

With multiple roots, the base is their common directory. For example,
`-t /data/work /data/photos --keep-paths` stores `work/...` and `photos/...`.
For explicit file inputs, their parent directories determine the common base.
The plan prints this base before asking for the passphrase. Stored paths are
relative, without a leading `/`. `--preserve-paths` aliases `--keep-paths`;
`--flatten` explicitly selects the default layout.

Flat mode refuses duplicate basenames before prompting. Use `--keep-paths`
to archive both files. Restore saved paths using `7z x`:

```bash
7z x personal.7z -o./restored
```

## Optional source deletion and pruning

Preview cleanup first:

```bash
./find-encrypt.sh ~/Exports -e csv --keep-paths -o ~/Backups/exports \
  --delete-source-files --prune-empty-dirs --dry-run
```

To perform it, remove `--dry-run`:

```bash
./find-encrypt.sh ~/Exports -e csv --keep-paths -o ~/Backups/exports \
  --delete-source-files --prune-empty-dirs
```

`--delete-sources` aliases `--delete-source-files`. Cleanup starts only after
archive creation, `7z t`, and publication all succeed. Before deleting each
selected original, the script rechecks its canonical path, device/inode,
type/mode, ownership, size, modification time, link count, and change time
against its pre-archive state. It accounts for its own hardlink removals.
Changed, replaced, or unavailable sources are retained. Cleanup errors return
nonzero while keeping the verified archive.

`--prune-empty-dirs` requires deletion explicitly. It checks directory identity
and uses nonrecursive `rmdir` only on parents of successfully deleted files.
It preserves search roots, parents of explicit file inputs, nonempty
directories, excluded files, and unrelated empty directories. Interactive
cleanup affects only the files chosen in fzf.

Use stable source trees: these checks are not a filesystem snapshot or a
guarantee against concurrent filesystem changes. Deletion is ordinary
unlinking, not secure erasure. No deletion is enabled by default.

## Verbose, silent, and automated operation

```bash
# Extra discovery, selection, command, and cleanup information
./find-encrypt.sh ~/Documents --keep-paths -o documents --verbose

# Read one password line from a protected source
./find-encrypt.sh ~/Exports -e csv -o exports --password-stdin \
  < /secure/archive-password.txt

# No output, including errors; inspect the exit status
./find-encrypt.sh ~/Exports -e csv -o exports --password-stdin --silent \
  < /secure/archive-password.txt
```

`-v` aliases `--verbose`; `-s` aliases `--silent`. Silent mode takes precedence
over verbose, rejects fzf, and requires `--password-stdin` for encryption.
`--dry-run --silent` needs no password. Protect any password source you choose;
the wrapper does not create or manage a password file. Interactive passwords
are confirmed; stdin passwords are a single line without confirmation.

Exit status 0 means success, including help and dry runs. Status 1 indicates
a validation, archive, or cleanup error. Status 130 indicates interruption or
fzf cancellation. Other external-tool or signal failures may return another
nonzero status. With silent mode, the exit status is the only diagnostic.

## Archive safeguards and limits

- Creation uses a private temporary directory beside the final destination.
  The archive is tested before a move that refuses to overwrite the target.
  Failed temporary archives are removed. Final archives have mode `0600`.
- Regular files only: directory metadata, symlinks, device nodes, and a complete
  filesystem backup are outside this script's scope.
- A quoted UTF-8 list file avoids command-length limits and treats spaces,
  quotes, wildcard characters, `@`, and leading dashes as literal filenames.
  CR/LF and invalid UTF-8 in list entries are rejected before creation.
- `--level 0` stores without compression; the default is level 5. Both modes
  encrypt file contents and filenames. The wrapper never prompts for sudo.

## Validation

The focused tests cover both discovery backends, naming and selection,
real encrypted archive/extraction round trips, hidden headers, unusual
filenames, failure cleanup, source replacement, hardlinks, and pruning.
Fixtures exercise fzf selection/cancellation and simulated compressor failures.

```bash
bash -n find-encrypt.sh
shellcheck find-encrypt.sh
shfmt -i 2 -ci -d find-encrypt.sh
PYTHONDONTWRITEBYTECODE=1 pytest -q tests/test_find_encrypt.py
```
