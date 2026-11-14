#!/usr/bin/env bash
# Find regular files, optionally select with fzf, and create an encrypted 7z.

# A caller may use bash -x; never trace the password-handling code.
set +x
set -Eeuo pipefail
umask 077

readonly PROGRAM="${0##*/}"
declare -a roots=() boundaries=() extensions=() globs=() excludes=() selected=()
declare -A seen=()
declare -A file_states=() directory_states=() prune_candidates=()
declare -A inode_last=() inode_original=() inode_expected=()
output=""
archive_name=""
backend="auto"
interactive=0
hidden=0
dry_run=0
password_stdin=0
level=5
keep_paths=0
layout=""
delete_sources=0
prune_empty=0
verbose=0
silent=0
work_dir=""
stage_dir=""
source_base=""
seven_zip=""
REPLY=""

# ---------------------------------------------------------------------------
# Interface and argument parsing
# ---------------------------------------------------------------------------

function usage() {
  cat <<'EOF'
Usage: find-encrypt.sh [OPTIONS] [PATH ...]

Find files recursively and create one password-protected .7z archive, including
encrypted filenames. Sources are retained unless --delete-source-files is set.
PATH can be a directory or a file. Multiple paths are combined and duplicate
paths are removed. Default path: . (no arguments displays this help).

Selection:
  -e, --extension TYPES  Extensions, repeated or comma-separated (OR matching)
      --filetype TYPES   Alias for --extension; .iso and tar.gz also work
  -g, --glob PATTERN     Filename glob, e.g. '*report*'; repeat for OR matching
  -E, -x, --exclude ITEM Exclude an absolute path, a path relative to each
                        search root, or a component glob such as 'cache*'
  -t, --target PATH ... Add search paths (space-separated, or repeat -t)
      --path PATH       Alias for --target
  -i, --interactive     Select with fzf: Tab toggles, Enter accepts, Esc cancels
      --hidden          Include hidden files and directories
      --backend MODE    auto (default), fd, or find

Archive:
  -o, --output PATH     Archive filename, or directory (existing or ending /)
  -n, --name NAME       Archive basename; .7z is appended if missing
  -p, --passphrase, --password, --encrypt
                        Request encryption (already the default); no value
      --password-stdin  Read one password line from stdin instead of the TTY
  -l, --level N         Compression level 0..9 (default: 5; 0 = store only)
      --keep-paths      Preserve paths relative to the common search base
      --preserve-paths  Alias for --keep-paths
      --flatten         Store basenames at archive top level (the default)
      --delete-source-files
                        Delete selected, unchanged originals ONLY after
                        successful archive verification and publication
      --delete-sources  Alias for --delete-source-files
      --prune-empty-dirs
                        Remove empty source subdirectories after deletion;
                        requires --delete-source-files; keep search roots
      --dry-run         Show the selected files and output; do not prompt,
                        create output directories, or run 7z
  -v, --verbose         Show discovery, archive commands, and cleanup details
  -s, --silent          Suppress ALL output, including errors; no fzf or TTY
                        prompts. Requires --password-stdin unless --dry-run.
                        Takes precedence over --verbose; check exit status.
  -h, --help            Show this help
      --                End options (for paths beginning with -)

Naming:
  --output backup                   -> ./backup.7z
  --output /safe/backup              -> /safe/backup.7z
  --output /safe/ --name backup      -> /safe/backup.7z
  --name backup                     -> ./backup.7z
  --output backup.7z --name backup   -> accepted (same normalized name)
  --output backup.7z --name other    -> error, exit status 1
  Default name: encrypted-files.7z. Existing archives are never overwritten.

Examples (quote paths with spaces and all glob patterns):
  # Preview ISO and IMG files from two locations
  ./find-encrypt.sh ~/Downloads /mnt/images -e iso,img -o images --dry-run

  # Multiple paths with -t; repeated extensions mean the same as iso,img
  ./find-encrypt.sh -t ~/Downloads /mnt/images -e iso -e img -o images

  # Repeated targets; file paths containing commas stay intact
  ./find-encrypt.sh -t './project one' -t './notes,final.txt' -o selected

  # Choose files in fzf, then enter and confirm the hidden passphrase
  ./find-encrypt.sh ~/Downloads /mnt/images -e iso -e img -i -p -o images

  # Combine file types (OR) with filename globs (OR); families use AND
  ./find-encrypt.sh ~/Documents -e pdf,docx -g '*report*' -o reports
  ./find-encrypt.sh ~/Documents -g '*report*' -g '*invoice*' -o documents

  # Exact filenames or compound extensions
  ./find-encrypt.sh ~/Work -g 'results.csv' --keep-paths -o results
  ./find-encrypt.sh ~/Backups -e tar.gz,tar.zst -o backups -l 0

  # Absolute exclusions affect only that path; component globs match anywhere
  ./find-encrypt.sh ~/Downloads -e iso --exclude ~/Downloads/old -o images
  ./find-encrypt.sh ~/Documents -x .git -x 'cache*' -i -o /safe/ -n documents

  # A relative path is anchored to each root (./old differs from old)
  ./find-encrypt.sh -t ~/One ~/Two -x ./old -x cache/temp -o selected

  # Direct files; output name alone or a full output path
  ./find-encrypt.sh ./one.txt ./two.txt --name selected
  ./find-encrypt.sh ./one.txt -o /mnt/backup/selected
  ./find-encrypt.sh ./one.txt -o selected.7z --name selected

  # Preserve paths; otherwise every selected file is at the archive top level
  ./find-encrypt.sh -t ~/Docs ~/Pictures --keep-paths -o personal
  ./find-encrypt.sh ~/Downloads -e iso --flatten -o images

  # Include hidden files and force the find fallback; print extra details
  ./find-encrypt.sh ~/Work --hidden --backend find --keep-paths -v -o work

  # Preview cleanup first; remove --dry-run to perform the displayed action
  ./find-encrypt.sh ~/Exports -e csv -o exports --keep-paths \
    --delete-source-files --prune-empty-dirs --dry-run

  # Interactive selection limits deletion to the files selected in fzf
  ./find-encrypt.sh ~/Exports -e csv -i -o exports --delete-source-files

  # Automation: supply a password from a protected source, never as an argument
  ./find-encrypt.sh ~/Exports -e csv -o exports --password-stdin \
    < /secure/archive-password.txt

  # Silent operation also suppresses errors; inspect the command's exit status
  ./find-encrypt.sh ~/Exports -e csv -o exports --password-stdin --silent \
    < /secure/archive-password.txt

  # A filename starting with a dash, and restoring stored paths
  ./find-encrypt.sh -o selected -- ./-report.txt
  7z x selected.7z -o./restored

Layout and cleanup:
  With one directory, --keep-paths stores paths beneath that directory. With
  multiple roots/files, it uses their common directory (shown as Source base).
  Flat mode refuses duplicate filenames rather than renaming or losing files.
  Source deletion happens only after 7z creation, 7z testing, and publication
  all succeed. Changed/replaced files are retained; incomplete cleanup returns
  nonzero while keeping the verified archive. Pruning only visits parents of
  deleted files, never search roots or parents of explicitly supplied files.
  Deletion is ordinary unlinking, not secure erasure. This is not a filesystem
  snapshot: use stable source trees, especially when requesting deletion.

Exit status:
  0 = success (also help/dry-run); 1 = validation/archive/cleanup failure;
  130 = interrupted or fzf cancelled. Other tool/signal failures can be nonzero.

Requires Bash 4+, GNU coreutils, iconv, and 7z/7zz/7za. fd is optional; find
is the fallback. fzf is required only with -i. No sudo is invoked. Extensions
are case-insensitive; globs and exclusions are case-sensitive. Extension and
glob filters combine with AND. Ignore files (.gitignore/.ignore) are not read.
Symlinks are not followed. Use stable source files while archiving.

Flat archives refuse duplicate basenames; use --keep-paths to retain them.
Passwords are hidden, confirmed, and sent through a pipe, never in command
arguments or environment variables. Empty passwords are refused. The archive
is tested before publication. Filenames must be UTF-8 without CR/LF because
7z list files are line-based. Spaces, quotes, and wildcard characters are safe.
EOF
}

function die() {
  printf '%s: error: %s\n' "$PROGRAM" "$*" >&2
  exit 1
}

function log_verbose() {
  if ((verbose)); then printf '%s\n' "$*" >&2; fi
}

function configure_output() {
  # Find --silent before parsing so even argument errors can be silent.
  # Skip option values and the literal-path region after --.
  while (($#)); do
    case "$1" in
      --) break ;;
      -s | --silent) silent=1 ;;
      -e | --extension | --filetype | -g | --glob | -E | -x | --exclude | \
        -t | --target | --path | -o | --output | -n | --name | \
        --backend | -l | --level)
        if (($# >= 2)); then shift; fi
        ;;
    esac
    shift
  done
  if ((silent)); then exec >/dev/null 2>&1; fi
}

function require_value() {
  (($# >= 2)) && [[ -n "$2" ]] || die "$1 requires a value."
}

function parse_args() {
  local types extension
  while (($#)); do
    case "$1" in
      --extension=* | --filetype=* | --glob=* | --exclude=* | --path=* | \
        --target=* | \
        --output=* | --name=* | --backend=* | --level=*)
        set -- "${1%%=*}" "${1#*=}" "${@:2}"
        ;;
    esac
    case "$1" in
      -e | --extension | --filetype)
        require_value "$@"
        types="$2"
        [[ "$types" != *$'\n'* && "$types" != *$'\r'* ]] ||
          die "Extensions cannot contain CR/LF."
        [[ "$types" != ,* && "$types" != *, && "$types" != *,,* ]] ||
          die "Empty extension in '$types'."
        local -a parts=()
        IFS=, read -r -a parts <<<"$types"
        for extension in "${parts[@]}"; do
          extension="${extension#"${extension%%[![:space:]]*}"}"
          extension="${extension%"${extension##*[![:space:]]}"}"
          extension="${extension#.}"
          [[ -n "$extension" && "$extension" != *[/\*\?\[]* ]] ||
            die "Use literal extensions, e.g. -e iso,img or -e tar.gz."
          extensions+=("${extension,,}")
        done
        shift 2
        ;;
      -g | --glob)
        require_value "$@"
        [[ "$2" != */* ]] || die "--glob matches basenames, without /."
        globs+=("$2")
        shift 2
        ;;
      -E | -x | --exclude)
        require_value "$@"
        excludes+=("$2")
        shift 2
        ;;
      -t | --target | --path)
        require_value "$@"
        roots+=("$2")
        shift 2
        ;;
      -o | --output)
        require_value "$@"
        [[ -z "$output" ]] || die "Specify --output only once."
        output="$2"
        shift 2
        ;;
      -n | --name)
        require_value "$@"
        [[ -z "$archive_name" ]] || die "Specify --name only once."
        archive_name="$2"
        shift 2
        ;;
      --backend)
        require_value "$@"
        backend="$2"
        shift 2
        ;;
      -l | --level)
        require_value "$@"
        [[ "$2" =~ ^[0-9]$ ]] || die "--level must be 0..9."
        level="$2"
        shift 2
        ;;
      -i | --interactive)
        interactive=1
        shift
        ;;
      --hidden)
        hidden=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --password-stdin)
        password_stdin=1
        shift
        ;;
      --keep-paths | --preserve-paths)
        [[ "$layout" != flat ]] || die "Conflicting archive layout options."
        layout="paths"
        keep_paths=1
        shift
        ;;
      --flatten)
        [[ "$layout" != paths ]] || die "Conflicting archive layout options."
        layout="flat"
        shift
        ;;
      --delete-source-files | --delete-sources)
        delete_sources=1
        shift
        ;;
      --prune-empty-dirs)
        prune_empty=1
        shift
        ;;
      -v | --verbose)
        verbose=1
        shift
        ;;
      -s | --silent)
        silent=1
        shift
        ;;
      -p | --passphrase | --password | --encrypt) shift ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        roots+=("${@:2}")
        break
        ;;
      -*) die "Unknown option '$1'; see --help." ;;
      *)
        roots+=("$1")
        shift
        ;;
    esac
  done
  case "$backend" in
    auto | fd | find) ;;
    *) die "--backend must be auto, fd, or find." ;;
  esac
  ((! prune_empty || delete_sources)) ||
    die "--prune-empty-dirs requires --delete-source-files."
  ((! silent || ! interactive)) || die "--silent cannot be used with fzf."
  ((! silent || dry_run || password_stdin)) ||
    die "--silent requires --password-stdin for encryption."
}

# ---------------------------------------------------------------------------
# Paths, dependencies, and temporary files
# ---------------------------------------------------------------------------

function cleanup() {
  [[ -z "$stage_dir" ]] || rm -rf -- "$stage_dir"
  [[ -z "$work_dir" ]] || rm -rf -- "$work_dir"
  return 0
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

function canonical_path() {
  # NUL output preserves pathnames ending with a newline.
  IFS= read -r -d '' REPLY < <(realpath "$1" -z -- "$2") ||
    die "Cannot resolve path '$2'."
}

function normalize_name() {
  [[ -n "$1" && "$1" != . && "$1" != .. && "$1" != */* ]] ||
    die "--name must be a filename, without a directory."
  REPLY="$1"
  [[ "$REPLY" == *.7z ]] || REPLY+=".7z"
}

function resolve_paths() {
  local path base index name="" parent resolved
  if [[ -n "$archive_name" ]]; then
    normalize_name "$archive_name"
    name="$REPLY"
  fi
  if [[ -z "$output" ]]; then
    output="${name:-encrypted-files.7z}"
  elif [[ -d "$output" || "$output" == */ ]]; then
    output="${output%/}/${name:-encrypted-files.7z}"
  else
    normalize_name "${output##*/}"
    [[ -z "$name" || "$name" == "$REPLY" ]] ||
      die "--output and --name disagree ('$REPLY' versus '$name')."
    parent=""
    [[ "$output" != */* ]] || parent="${output%/*}/"
    output="$parent$REPLY"
  fi
  # Refuse even dangling symlinks before canonicalizing the destination.
  [[ ! -e "$output" && ! -L "$output" ]] ||
    die "Output already exists: $output"
  canonical_path -m "$output"
  output="$REPLY"
  [[ ! -e "$output" && ! -L "$output" ]] ||
    die "Output already exists: $output"

  ((${#roots[@]})) || roots=(.)
  for index in "${!roots[@]}"; do
    path="${roots[index]}"
    [[ ! -L "$path" ]] || die "Symlink input is not supported: $path"
    [[ -d "$path" || -f "$path" ]] || die "Not a file/directory: $path"
    canonical_path -e "$path"
    resolved="$REPLY"
    canonical_path -ms "$path"
    [[ "$resolved" == "$REPLY" ]] ||
      die "Symlink input or ancestor is not supported: $path"
    path="$resolved"
    roots[index]="$path"
    base="$path"
    [[ -d "$path" ]] || base="${path%/*}"
    base="${base:-/}"
    boundaries+=("$base")
    if [[ -z "$source_base" ]]; then
      source_base="$base"
    else
      while [[ "$base/" != "${source_base%/}/"* ]]; do
        source_base="${source_base%/*}"
        source_base="${source_base:-/}"
      done
    fi
  done
  for index in "${!excludes[@]}"; do
    path="${excludes[index]}"
    if [[ "$path" == /* ]]; then
      canonical_path -m "$path"
      excludes[index]="$REPLY"
    elif [[ "$path" == */* ]]; then
      path="${path#./}"
      path="${path%/}"
      [[ -n "$path" && "$path" != .. && "$path" != ../* &&
        "$path" != */../* && "$path" != */.. ]] ||
        die "Relative exclusions must stay inside each search root."
      excludes[index]="./$path"
    fi
  done
}

function dependencies() {
  local tool
  for tool in realpath mktemp sort env rm cp cat; do
    command -v "$tool" >/dev/null || die "Required command missing: $tool"
  done
  if [[ "$backend" == auto ]]; then
    if command -v fd >/dev/null; then
      backend="fd"
    else
      backend="find"
    fi
  fi
  command -v "$backend" >/dev/null || die "Required command missing: $backend"
  if ((interactive)); then
    command -v fzf >/dev/null || die "--interactive requires fzf."
  fi
  if ((! dry_run)); then
    for tool in iconv mkdir chmod mv stat rmdir; do
      command -v "$tool" >/dev/null || die "Required command missing: $tool"
    done
    for tool in 7z 7zz 7za; do
      if command -v "$tool" >/dev/null; then
        seven_zip="$(command -v "$tool")"
        break
      fi
    done
    [[ -n "$seven_zip" ]] || die "Install 7-Zip (7z, 7zz, or 7za)."
    canonical_path -e "$seven_zip"
    seven_zip="$REPLY"
  fi
}

# ---------------------------------------------------------------------------
# Discovery: common matching rules for fd and the find fallback
# ---------------------------------------------------------------------------

function escape_glob() {
  local character index
  REPLY=""
  for ((index = 0; index < ${#1}; index++)); do
    character="${1:index:1}"
    case "$character" in
      \\ | '*' | '?' | '[' | ']' | '{' | '}') REPLY+="\\" ;;
    esac
    REPLY+="$character"
  done
}

function excluded() {
  local path="$1" relative="$2" pattern rest component
  for pattern in "${excludes[@]}"; do
    if [[ "$pattern" == /* ]]; then
      [[ "$path" != "$pattern" && "$path" != "${pattern%/}/"* ]] ||
        return 0
    elif [[ "$pattern" == */* ]]; then
      pattern="${pattern#./}"
      [[ "$relative" != "$pattern" && "$relative" != "$pattern/"* ]] ||
        return 0
    else
      rest="$relative"
      while [[ -n "$rest" ]]; do
        component="${rest%%/*}"
        # Unquoted RHS intentionally performs shell-glob matching.
        # shellcheck disable=SC2053
        [[ "$component" != $pattern ]] || return 0
        [[ "$rest" == */* ]] || break
        rest="${rest#*/}"
      done
    fi
  done
  return 1
}

function matches() {
  local path="$1" relative="$2" name rest extension pattern found=0
  [[ -f "$path" && ! -L "$path" ]] || return 1
  excluded "$path" "$relative" && return 1
  if ((! hidden)); then
    rest="$relative"
    while [[ -n "$rest" ]]; do
      [[ "${rest%%/*}" != .* ]] || return 1
      [[ "$rest" == */* ]] || break
      rest="${rest#*/}"
    done
  fi
  name="${path##*/}"
  if ((${#extensions[@]})); then
    for extension in "${extensions[@]}"; do
      [[ "${name,,}" != *."$extension" ]] || found=1
    done
    ((found)) || return 1
  fi
  if ((${#globs[@]})); then
    found=0
    for pattern in "${globs[@]}"; do
      # shellcheck disable=SC2053
      [[ "$name" != $pattern ]] || found=1
    done
    ((found)) || return 1
  fi
  return 0
}

function discover_root() {
  local root="$1" pattern relative path
  local -a command=() prune=()
  log_verbose "Searching: $root"
  excluded "$root" "" && return 0
  if [[ -f "$root" ]]; then
    printf '%s\0' "$root" >"$work_dir/raw"
  else
    if [[ "$backend" == fd ]]; then
      command=(fd --type f --print0 --absolute-path --no-ignore
        --hidden --color never --show-errors)
    else
      command=(find -P "$root")
    fi
    for pattern in "${excludes[@]}"; do
      if [[ "$pattern" == /* ]]; then
        [[ "$pattern" == "${root%/}/"* ]] || continue
        relative="${pattern#"${root%/}/"}"
        escape_glob "$relative"
        relative="/$REPLY"
        escape_glob "$pattern"
        prune+=(-path "$REPLY" -o)
      elif [[ "$pattern" == */* ]]; then
        pattern="${pattern#./}"
        escape_glob "$pattern"
        relative="/$REPLY"
        escape_glob "${root%/}/$pattern"
        prune+=(-path "$REPLY" -o)
      else
        relative="$pattern"
        # fd's exclude syntax reserves a leading ! or #.
        [[ "$relative" != '!'* && "$relative" != '#'* ]] ||
          relative="\\$relative"
        prune+=(-name "$pattern" -o)
        # fd's globset grammar extends shell globs (e.g. brace alternation).
        # Let the shared matcher handle patterns without a safe translation.
        if [[ "$backend" == fd && "$pattern" == *[\[\]{}\\]* ]]; then
          continue
        fi
      fi
      [[ "$backend" != fd ]] || command+=(--exclude "$relative")
    done
    if [[ "$backend" == fd ]]; then
      ((hidden)) || command+=(--exclude '.*')
      command+=(-- . "$root")
    else
      ((hidden)) || prune+=(-name '.*' -o)
      if ((${#prune[@]})); then
        unset 'prune[${#prune[@]}-1]'
        # Only descendants are pruned; an explicitly named hidden root works.
        escape_glob "$root"
        command+=('(' ! -path "$REPLY" '(' "${prune[@]}" ')' ')'
          -prune -o)
      fi
      command+=(-type f -print0)
    fi
    if ! "${command[@]}" >"$work_dir/raw" 2>"$work_dir/scan-errors"; then
      cat "$work_dir/scan-errors" >&2
      die "File discovery failed for '$root'."
    fi
    # fd can return success despite unreadable directories. Do not archive
    # an incomplete selection while quietly discarding its diagnostics.
    if [[ -s "$work_dir/scan-errors" ]]; then
      cat "$work_dir/scan-errors" >&2
      die "Discovery reported errors for '$root'; no archive created."
    fi
  fi
  while IFS= read -r -d '' path; do
    if [[ -f "$root" ]]; then
      relative="${path##*/}"
    else relative="${path#"${root%/}/"}"; fi
    if matches "$path" "$relative"; then
      printf '%s\0' "$path" >>"$work_dir/candidates"
    fi
  done <"$work_dir/raw"
}

function select_files() {
  local root path status
  work_dir="$(mktemp -d -t find-encrypt.XXXXXXXX)"
  canonical_path -e "$work_dir"
  work_dir="$REPLY"
  excludes+=("$work_dir")
  : >"$work_dir/candidates"
  for root in "${roots[@]}"; do discover_root "$root"; done
  LC_ALL=C sort -zu "$work_dir/candidates" >"$work_dir/sorted"
  [[ -s "$work_dir/sorted" ]] || die "No files matched the selection."
  while IFS= read -r -d '' path; do seen["$path"]=1; done <"$work_dir/sorted"
  if ((interactive)); then
    if env -u FZF_DEFAULT_OPTS -u FZF_DEFAULT_OPTS_FILE \
      -u FZF_DEFAULT_COMMAND fzf --read0 --print0 --multi \
      --bind 'ctrl-a:select-all,ctrl-d:deselect-all' \
      --prompt 'Encrypt> ' \
      --header 'Tab: toggle | Ctrl-A: all | Ctrl-D: none | Enter: accept' \
      <"$work_dir/sorted" >"$work_dir/picked"; then
      [[ -s "$work_dir/picked" ]] || die "No files selected."
    else
      status=$?
      if ((status == 130)); then
        printf '%s: selection cancelled.\n' "$PROGRAM" >&2
        exit 130
      fi
      die "fzf returned status $status; no archive created."
    fi
  else
    cp -- "$work_dir/sorted" "$work_dir/picked"
  fi
  while IFS= read -r -d '' path; do
    [[ -n "${seen["$path"]:-}" ]] || die "fzf returned an unknown file."
    selected+=("$path")
  done <"$work_dir/picked"
  ((${#selected[@]})) || die "No files selected."
}

# ---------------------------------------------------------------------------
# Private password input and verified publication
# ---------------------------------------------------------------------------

function prepare_list() {
  local path relative entry state key
  : >"$work_dir/files.txt"
  for path in "${selected[@]}"; do
    [[ -f "$path" && ! -L "$path" && -r "$path" ]] ||
      die "Selected file disappeared, changed type, or is unreadable: $path"
    canonical_path -e "$path"
    [[ "$path" == "$REPLY" ]] || die "Selected path changed: $path"
    relative="${path#"${source_base%/}/"}"
    entry="$path"
    ((keep_paths == 0)) || entry="$relative"
    [[ "$entry" != *$'\n'* && "$entry" != *$'\r'* ]] ||
      die "7z list files cannot represent a filename containing CR/LF."
    # Absolute list entries produce basenames; relative entries keep paths.
    # Outer quotes preserve leading/trailing whitespace in both layouts.
    printf '"%s"\n' "$entry" >>"$work_dir/files.txt"
    if ((delete_sources)); then
      state="$(stat -c '%d:%i:%f:%u:%g:%s:%y|%h|%z' -- "$path")" ||
        die "Cannot snapshot selected file: $path"
      file_states["$path"]="$state"
      key="${state#*:}"
      key="${state%%:*}:${key%%:*}"
      inode_last["$key"]="$path"
      if [[ -z "${inode_original["$key"]:-}" ]]; then
        inode_original["$key"]="$state"
        inode_expected["$key"]="$state"
      fi
    fi
    if ((prune_empty)); then record_parents "$path"; fi
  done
  iconv -f UTF-8 -t UTF-8 "$work_dir/files.txt" >/dev/null ||
    die "Selected filenames must be valid UTF-8 for 7z list files."
}

function validate_layout() {
  local path name
  local -A names=()
  if ((! keep_paths)); then
    for path in "${selected[@]}"; do
      name="${path##*/}"
      [[ -z "${names["$name"]:-}" ]] ||
        die "Duplicate basename '$name'; use --keep-paths."
      names["$name"]=1
    done
  fi
}

function record_parents() {
  local path="$1" boundary="$source_base" root parent
  # Keep every named search root; for explicit files keep their parent too.
  for root in "${boundaries[@]}"; do
    if [[ "$path" == "${root%/}/"* ]] &&
      ((${#root} > ${#boundary})); then
      boundary="$root"
    fi
  done
  parent="${path%/*}"
  while [[ -n "$parent" && "$parent" != / && "$parent" != "$boundary" ]]; do
    directory_states["$parent"]="$(stat -c '%d:%i:%f' -- "$parent")" ||
      die "Cannot snapshot source directory: $parent"
    parent="${parent%/*}"
  done
}

function unchanged_source() {
  local path="$1" current resolved key state="${file_states["$1"]}"
  [[ -f "$path" && ! -L "$path" ]] || return 1
  IFS= read -r -d '' resolved < <(realpath -ez -- "$path" 2>/dev/null) ||
    return 1
  [[ "$resolved" == "$path" ]] || return 1
  current="$(stat -c '%d:%i:%f:%u:%g:%s:%y|%h|%z' -- "$path" 2>/dev/null)" ||
    return 1
  key="${state#*:}"
  key="${state%%:*}:${key%%:*}"
  [[ "$state" == "${inode_original["$key"]}" &&
    "$current" == "${inode_expected["$key"]}" ]]
}

function refresh_link_state() {
  local path="$1" key state="${file_states["$1"]}" last current links old_links
  key="${state#*:}"
  key="${state%%:*}:${key%%:*}"
  last="${inode_last["$key"]}"
  [[ "$last" != "$path" && -f "$last" && ! -L "$last" ]] || return 0
  state="${inode_expected["$key"]}"
  current="$(stat -c '%d:%i:%f:%u:%g:%s:%y|%h|%z' -- "$last")" || return 0
  links="${current#*|}"
  links="${links%%|*}"
  old_links="${state#*|}"
  old_links="${old_links%%|*}"
  # Unlinking one hardlink updates the shared ctime and link count. Accept
  # exactly that change; size, mtime, identity, owner and mode must still match.
  if [[ "${state%%|*}" == "${current%%|*}" ]] &&
    ((links + 1 == old_links)); then
    inode_expected["$key"]="$current"
  fi
}

function cleanup_sources() {
  local path parent current resolved failed=0 deleted=0 pruned=0
  for path in "${selected[@]}"; do
    if ! unchanged_source "$path"; then
      printf 'Retained changed or unavailable source: %q\n' "$path" >&2
      failed=1
      continue
    fi
    if ! rm -- "$path"; then
      printf 'Could not delete source: %q\n' "$path" >&2
      failed=1
      continue
    fi
    refresh_link_state "$path"
    deleted=$((deleted + 1))
    if ((verbose)); then printf 'Deleted source: %q\n' "$path" >&2; fi
    if ((prune_empty)); then
      parent="${path%/*}"
      while [[ -n "${directory_states["$parent"]:-}" ]]; do
        prune_candidates["$parent"]=1
        parent="${parent%/*}"
        [[ -n "$parent" ]] || break
      done
    fi
  done
  printf 'Deleted %s selected source files.\n' "$deleted"
  if ((prune_empty && ${#prune_candidates[@]})); then
    # Reverse path order visits descendants before their parents. rmdir is
    # deliberately non-recursive and cannot remove a nonempty directory.
    printf '%s\0' "${!prune_candidates[@]}" |
      LC_ALL=C sort -zr >"$work_dir/prune"
    while IFS= read -r -d '' path; do
      resolved=""
      current=""
      if [[ -d "$path" && ! -L "$path" ]] &&
        IFS= read -r -d '' resolved < <(realpath -ez -- "$path" 2>/dev/null); then
        current="$(stat -c '%d:%i:%f' -- "$path" 2>/dev/null)" || current=""
      fi
      if [[ "$resolved" != "$path" ||
        "$current" != "${directory_states["$path"]}" ]]; then
        printf 'Retained changed source directory: %q\n' "$path" >&2
        failed=1
        continue
      fi
      if ! rmdir --ignore-fail-on-non-empty -- "$path"; then
        failed=1
      elif [[ ! -d "$path" ]]; then
        pruned=$((pruned + 1))
        if ((verbose)); then printf 'Pruned directory: %q\n' "$path" >&2; fi
      fi
    done <"$work_dir/prune"
    printf 'Pruned %s empty source directories.\n' "$pruned"
  fi
  ((failed == 0)) ||
    die "Archive retained, but source cleanup was incomplete."
}

function create_archive() {
  local secret="" confirmation="" prompt_fd parent="${output%/*}"
  local -a create_command=() test_command=()
  # Do not inherit an export attribute from the caller's environment.
  export -n secret confirmation
  if ((password_stdin)); then
    IFS= read -r secret || [[ -n "$secret" ]] ||
      die "Cannot read a password from stdin."
  else
    if ! { exec {prompt_fd}<>/dev/tty; } 2>/dev/null; then
      die "A terminal is required; use --password-stdin for automation."
    fi
    printf 'Passphrase: ' >&"$prompt_fd"
    IFS= read -r -s -u "$prompt_fd" secret || die "Password input cancelled."
    printf '\nConfirm passphrase: ' >&"$prompt_fd"
    IFS= read -r -s -u "$prompt_fd" confirmation ||
      die "Password confirmation cancelled."
    printf '\n' >&"$prompt_fd"
    exec {prompt_fd}>&-
    [[ "$secret" == "$confirmation" ]] || die "Passphrases do not match."
    unset confirmation
  fi
  [[ -n "$secret" ]] || die "Empty passwords are not allowed."
  [[ "$secret" != *$'\r'* ]] || die "Passwords cannot contain CR."
  mkdir -p -- "$parent"
  stage_dir="$(mktemp -d -- "$parent/.find-encrypt.XXXXXXXX")"
  create_command=("$seven_zip" a -t7z -p -mhe=on -spd -r- -scsUTF-8
    "-mx=$level" -bso0 -bsp0 "$stage_dir/archive.7z" "@$work_dir/files.txt")
  test_command=("$seven_zip" t -bso0 -bsp0 -- "$stage_dir/archive.7z")
  if ((verbose)); then
    printf 'Create command (password via pipe):' >&2
    printf ' %q' "${create_command[@]}" >&2
    printf '\nTest command (password via pipe):' >&2
    printf ' %q' "${test_command[@]}" >&2
    printf '\n' >&2
  fi
  printf 'Creating encrypted archive (%s files)...\n' "${#selected[@]}"
  # The password is pipe input, not an argv entry or exported variable.
  if ! (
    # Commands in a conditional subshell do not inherit errexit behavior.
    cd -- "$source_base" || exit 1
    printf '%s\n' "$secret" | "${create_command[@]}"
  ); then
    unset secret
    die "7z creation failed; the temporary archive will be removed."
  fi
  printf 'Verifying archive...\n'
  # For reading, bare -p means EMPTY password, so let encrypted headers prompt.
  if ! printf '%s\n' "$secret" | "${test_command[@]}"; then
    unset secret
    die "7z verification failed; no archive published."
  fi
  unset secret
  chmod 600 -- "$stage_dir/archive.7z"
  # A same-filesystem no-clobber move also protects against a destination
  # created while compression was running. -T prevents moving into a directory.
  mv -nT -- "$stage_dir/archive.7z" "$output" ||
    die "Cannot publish archive; destination was not overwritten."
  [[ ! -e "$stage_dir/archive.7z" ]] ||
    die "Output appeared while archiving; destination was not overwritten."
  printf 'Created and verified: %q\n' "$output"
}

function main() {
  configure_output "$@"
  (($#)) || {
    usage
    return 0
  }
  parse_args "$@"
  dependencies
  resolve_paths
  select_files
  validate_layout
  printf 'Backend: %s\nSource base: %q\nOutput: %q\nSelected: %s files\n' \
    "$backend" "$source_base" "$output" "${#selected[@]}"
  if ((keep_paths)); then
    printf 'Layout: paths relative to source base\n'
  else printf 'Layout: flat (basenames only)\n'; fi
  if ((delete_sources)); then
    printf 'Cleanup: delete selected originals after verified publication\n'
    if ((prune_empty)); then
      printf 'Pruning: remove empty source subdirectories; keep search roots\n'
    fi
  fi
  if ((dry_run)); then
    printf '  %q\n' "${selected[@]}"
    printf 'Dry run: no archive created; source files are retained.\n'
    return 0
  fi
  if ((verbose)); then
    printf 'Selected source files:\n' >&2
    printf '  %q\n' "${selected[@]}" >&2
  fi
  prepare_list
  create_archive
  if ((delete_sources)); then cleanup_sources; fi
}

main "$@"
