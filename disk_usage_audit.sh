#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# disk-usage-audit — Comprehensive disk usage audit for local filesystems
# Version: 1.1.0
# Requires: bash ≥ 4, coreutils (du, df, sort, awk, numfmt), find, grep, sed
# Optional: sudo (for broader access), helpout/batwrap/bat (for help display)
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
IFS=$'\n\t'
# ──────────────────────────────────────────────────────────────────────────────
# Globals (defaults; override via CLI)
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_NAME="$(basename "$0")"
NOW_STAMP="$(date +%Y%m%d_%H%M%S)"
OUTDIR="$PWD/du_audit_${NOW_STAMP}"
DEPTH=2             # directory summary depth
TOPN=25             # top-N items for stdout previews
MIN_FILE_SIZE="50M" # threshold for "large files" scan
USE_SUDO=0          # 1 => prefix scans with sudo
QUIET=0             # 1 => minimal stdout chatter
INCLUDE_REMOTE=0    # include NFS/CIFS/SSHFS/etc. if set
CUSTOM_PATHS=""     # comma-separated list of root scan paths
EXCLUDES=""         # comma-separated path globs to exclude
WRITE_REPORTS=1     # write TSV/CSV to $OUTDIR
DO_PER_USER=1       # aggregate sizes per file owner
DO_BY_EXT=1         # aggregate by file extension
CSV_SEP=","         # CSV separator for extension summary
# Filesystem types excluded by default (ephemeral/virtual)
DEFAULT_EXCLUDED_FSTYPES=(
	"autofs" "bpf" "cgroup" "cgroup2" "configfs" "debugfs" "devpts"
	"devtmpfs" "efivarfs" "fusectl" "hugetlbfs" "mqueue" "overlay"
	"proc" "pstore" "ramfs" "securityfs" "squashfs" "sysfs" "tmpfs"
	"tracefs" "zram"
)
# Remote/network FS types (excluded unless --include-remote)
REMOTE_FSTYPES=("nfs" "nfs4" "cifs" "smb3" "sshfs" "9p" "glusterfs")

# ──────────────────────────────────────────────────────────────────────────────
# Pretty/help plumbing
# ──────────────────────────────────────────────────────────────────────────────
function _have() { command -v "$1" >/dev/null 2>&1; }

# Your preferred bat options (fallback to cat)
BAT_OPTS=(
	--style="snip"
	--italic-text="always"
	--theme="Dracula"
	--squeeze-blank
	--squeeze-limit="2"
	--tabs="2"
	--paging="never"
  --wrap="auto"
  --chop-long-lines
  --force-colorization
  --paging="never"
)

function show_help() {
	local viewer="cat"
	if _have bat; then
		viewer="bat"
	fi

	if [[ "${viewer}" == "bat" ]]; then
		cat <<'EOF' | bat "${BAT_OPTS[@]}" -l md
# disk-usage-audit — Comprehensive disk usage report

## Synopsis
```sh
disk-usage-audit [options]
```
EOF

  cat <<'EOF2' | bat "${BAT_OPTS[@]}" -l bash 

## What it does
- Enumerates local filesystems (excludes virtual/ephemeral by default).
- Summarizes heaviest directories up to a chosen depth (`du -b -x`).
- Finds largest files above a size threshold.
- Aggregates usage by file owner (user) and by file extension.
- Emits *TSV/CSV* reports into a timestamped folder unless disabled.
- Prints concise Top-N previews to stdout.

## Key outputs (in $PWD/du_audit_YYYYMMDD_HHMMSS unless changed)
* `mountpoints.tsv`         — considered mountpoints + used/avail (bytes)
* `directories.tsv`         — directory sizes (bytes), depth-limited
* `largest_files.tsv`       — large files (≥ threshold), sorted by size
* `per_user.tsv`            — total bytes per owner (if enabled)
* `by_extension.csv`        — bytes & counts aggregated by file extension

### Options

"$SCRIPT_NAME" -h, --help           Show this help.
- `-q, --quiet`                       Suppress non-essential stdout.
- `-o, --output DIR`                  Reports output directory (default: _"$(pwd)"_).
- `-p, --paths P1,P2,...`             Scan these roots instead of autodetected
                                      mountpoints (still excludes virtual FS).
- `-d, --depth N`                     Directory summary depth (default: 2).
- `-n, --top N`                       Top-N items printed to stdout (default: 25).
- `-m, --min-file-size SZ`            Threshold for “large files” (default: 50M).
- `-X, --exclude GLOB1[,GLOB2...]`    Path globs to exclude (applies to du/find).
- `--sudo`                            Use sudo for scanning commands.
- `--include-remote`                  Include remote FS (NFS/CIFS/SSHFS/…).
- `--no-reports`                      Do not write report files, stdout only.
- `--no-per-user`                     Skip per-user aggregation.
- `--no-by-ext`                       Skip extension aggregation.


## Examples
- Basic local audit:
  `disk-usage-audit`

- Deeper directory summary and bigger Top-N:
  `disk-usage-audit -d 3 -n 50`

- Audit specific roots and exclude cache/tmp:
  `disk-usage-audit -p /,/home -X "/home/*/.cache,/var/tmp"`

- Include remote filesystems and scan with sudo:
  `disk-usage-audit --include-remote --sudo`

## Notes
- Uses bytes for reports; previews are humanized if `numfmt` is available.
- One-filesystem semantics (`-x`/`-xdev`) avoid crossing mount boundaries.
- Re-run with `--sudo` or as root to reduce permission denials.

EOF2
	else
		cat <<'EOF' | "${viewer}"
# disk-usage-audit — Comprehensive disk usage report
Use --help for full Markdown help (bat/helpout/cat fallback).
EOF
	fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Utility: logging and humanization
# ──────────────────────────────────────────────────────────────────────────────
function logi() { [[ "$QUIET" -eq 0 ]] && printf '%s\n' "$*"; }
function loge() { printf 'ERR: %s\n' "$*" >&2; }

function humanize() {
	if _have numfmt; then
		numfmt --to=iec --suffix=B --format="%.1f" 2>/dev/null || cat
	else
		cat
	fi
}

# CSV splitter → NUL-delimited stream for safe parsing
function split_csv() {
	local IFS=','
	read -r -a _out <<<"$1"
	printf '%s\0' "${_out[@]}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Argument parsing (supports long opts)
# ──────────────────────────────────────────────────────────────────────────────
function parse_args() {
	while (("$#")); do
		case "$1" in
		-h | --help)
			show_help
			exit 0
			;;
		-q | --quiet)
			QUIET=1
			shift
			;;
		-o | --output)
			OUTDIR="$2"
			shift 2
			;;
		-p | --paths)
			CUSTOM_PATHS="${2:-}"
			shift 2
			;;
		-d | --depth)
			DEPTH="${2:-2}"
			shift 2
			;;
		-n | --top)
			TOPN="${2:-25}"
			shift 2
			;;
		-m | --min-file-size)
			MIN_FILE_SIZE="${2:-50M}"
			shift 2
			;;
		-X | --exclude)
			EXCLUDES="${2:-}"
			shift 2
			;;
		--sudo)
			USE_SUDO=1
			shift
			;;
		--include-remote)
			INCLUDE_REMOTE=1
			shift
			;;
		--no-reports)
			WRITE_REPORTS=0
			shift
			;;
		--no-per-user)
			DO_PER_USER=0
			shift
			;;
		--no-by-ext)
			DO_BY_EXT=0
			shift
			;;
		--)
			shift
			break
			;;
		-*)
			loge "Unknown option: $1"
			exit 2
			;;
		*)
			shift
			;;
		esac
	done
}

# ──────────────────────────────────────────────────────────────────────────────
# Mountpoint detection & filtering
# ──────────────────────────────────────────────────────────────────────────────
function is_in_list() {
	local x="$1"
	shift
	local y
	for y in "$@"; do [[ "$x" == "$y" ]] && return 0; done
	return 1
}

function collect_mountpoints() {
	local -a excludes=("${DEFAULT_EXCLUDED_FSTYPES[@]}")
	local -a remote=("${REMOTE_FSTYPES[@]}")
	local line dev mnt fstype
	local -a mounts=()

	while read -r line; do
		dev="$(awk '{print $1}' <<<"$line")"
		mnt="$(awk '{print $2}' <<<"$line")"
		fstype="$(awk '{print $3}' <<<"$line")"

		[[ "$mnt" != /* ]] && continue
		if is_in_list "$fstype" "${excludes[@]}"; then continue; fi
		if [[ "$INCLUDE_REMOTE" -eq 0 ]] && is_in_list "$fstype" "${remote[@]}"; then
			continue
		fi
		if [[ ! " ${mounts[*]-} " =~ " ${mnt} " ]]; then
			mounts+=("$mnt")
		fi
	done </proc/self/mounts

	printf '%s\n' "${mounts[@]}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Build scan roots and options
# ──────────────────────────────────────────────────────────────────────────────
function build_roots() {
	if [[ -n "${CUSTOM_PATHS}" ]]; then
		mapfile -d '' roots < <(split_csv "${CUSTOM_PATHS}")
	else
		mapfile -t roots < <(collect_mountpoints)
	fi
	printf '%s\n' "${roots[@]}"
}

function build_du_excludes() {
	local -a args=()
	if [[ -n "${EXCLUDES}" ]]; then
		local -a globs=()
		mapfile -d '' globs < <(split_csv "${EXCLUDES}")
		local g
		for g in "${globs[@]}"; do
			args+=("--exclude=${g}")
		done
	fi
	printf '%s\n' "${args[@]}"
}

function build_find_prune_array() {
	# Emits a NUL-delimited array for find(1) to prune EXCLUDES
	if [[ -z "${EXCLUDES}" ]]; then
		return 0
	fi
	local -a globs=()
	mapfile -d '' globs < <(split_csv "${EXCLUDES}")
	local -a arr=()
	arr+=("(")
	local i=0
	for g in "${globs[@]}"; do
		((i > 0)) && arr+=(-o)
		arr+=(-path "$g")
		((i++))
	done
	arr+=(")" -prune -o)
	printf '%s\0' "${arr[@]}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Scanners
# ──────────────────────────────────────────────────────────────────────────────
function run_df_summary() {
	local out="${OUTDIR}/mountpoints.tsv"
	[[ "$WRITE_REPORTS" -eq 1 ]] && : >"$out"
	logi "• Collecting mountpoint usage (df)..."

	local df_cmd=(df -B1 --output=target,fstype,used,avail,source)
	"${df_cmd[@]}" | sed '1d' | while read -r tgt fstype used avail src; do
		if [[ "$WRITE_REPORTS" -eq 1 ]]; then
			printf "%s\t%s\t%s\t%s\t%s\n" \
				"$tgt" "$fstype" "$used" "$avail" "$src" >>"$out"
		fi
	done

	if [[ "$QUIET" -eq 0 && "$WRITE_REPORTS" -eq 1 ]]; then
		printf "\n== Mountpoints by used bytes ==\n"
		local tmp="${OUTDIR}/.df_top.tmp"
		awk -F'\t' '{print $3"\t"$1}' "$out" | sort -nr | head -n "$TOPN" >"$tmp"
		cut -f1 "$tmp" | humanize | paste -d' ' - <(cut -f2 "$tmp")
		rm -f -- "$tmp"
	fi
}

function run_directory_summary() {
	local out="${OUTDIR}/directories.tsv"
	[[ "$WRITE_REPORTS" -eq 1 ]] && : >"$out"
	local -a du_ex
	mapfile -t du_ex < <(build_du_excludes)

	logi "• Summarizing directories (du -b -x, depth=${DEPTH})..."
	local -a sudo_prefix_cmd=()
	[[ "$USE_SUDO" -eq 1 ]] && sudo_prefix_cmd=(sudo)

	while read -r r; do
		[[ -z "$r" ]] && continue
		"${sudo_prefix_cmd[@]}" du -b -x --max-depth="$DEPTH" "${du_ex[@]}" -- "$r" \
			2>/dev/null | sort -nr >>"$out"
	done < <(build_roots)

	if [[ "$QUIET" -eq 0 && "$WRITE_REPORTS" -eq 1 ]]; then
		printf "\n== Heaviest directories (Top %d) ==\n" "$TOPN"
		head -n "$TOPN" "$out" | awk '{print $1}' | humanize |
			paste -d' ' - <(head -n "$TOPN" "$out" | awk '{$1=""; sub(/^ /,"");print}')
	fi
}

function run_largest_files() {
	local out="${OUTDIR}/largest_files.tsv"
	[[ "$WRITE_REPORTS" -eq 1 ]] && : >"$out"

	logi "• Finding large files (≥ ${MIN_FILE_SIZE})..."
	local -a prune_arr=()
	mapfile -d '' prune_arr < <(build_find_prune_array)
	local -a sudo_prefix_cmd=()
	[[ "$USE_SUDO" -eq 1 ]] && sudo_prefix_cmd=(sudo)

	while read -r r; do
		[[ -z "$r" ]] && continue
		"${sudo_prefix_cmd[@]}" find "$r" -xdev "${prune_arr[@]}" -type f \
			-size "+${MIN_FILE_SIZE}" -printf '%s\t%p\n' 2>/dev/null
	done < <(build_roots) |
		sort -nr |
		tee >(head -n "$TOPN" >"${OUTDIR}/largest_files_preview.tsv" >/dev/null) \
			>>"$out"

	if [[ "$QUIET" -eq 0 && "$WRITE_REPORTS" -eq 1 ]]; then
		printf "\n== Largest files (Top %d, ≥ %s) ==\n" "$TOPN" "$MIN_FILE_SIZE"
		head -n "$TOPN" "$out" | awk -F'\t' '{print $1}' | humanize |
			paste -d' ' - <(head -n "$TOPN" "$out" | cut -f2-)
	fi
}

function run_per_user() {
	((DO_PER_USER == 1)) || return 0
	local out="${OUTDIR}/per_user.tsv"
	[[ "$WRITE_REPORTS" -eq 1 ]] && : >"$out"

	logi "• Aggregating per-user file sizes..."
	local -a prune_arr=()
	mapfile -d '' prune_arr < <(build_find_prune_array)
	local -a sudo_prefix_cmd=()
	[[ "$USE_SUDO" -eq 1 ]] && sudo_prefix_cmd=(sudo)

	while read -r r; do
		[[ -z "$r" ]] && continue
		"${sudo_prefix_cmd[@]}" find "$r" -xdev "${prune_arr[@]}" -type f \
			-printf '%u\t%s\n' 2>/dev/null
	done < <(build_roots) |
		awk -F'\t' '{a[$1]+=$2} END{for(u in a) printf "%s\t%s\n", a[u], u}' |
		sort -nr |
		tee >(head -n "$TOPN" >"${OUTDIR}/per_user_preview.tsv" >/dev/null) \
			>>"$out"

	if [[ "$QUIET" -eq 0 && "$WRITE_REPORTS" -eq 1 ]]; then
		printf "\n== By user (Top %d) ==\n" "$TOPN"
		head -n "$TOPN" "$out" | awk -F'\t' '{print $1}' | humanize |
			paste -d' ' - <(head -n "$TOPN" "$out" | awk -F'\t' '{print $2}')
	fi
}

function run_by_extension() {
	((DO_BY_EXT == 1)) || return 0
	local out="${OUTDIR}/by_extension.csv"
	[[ "$WRITE_REPORTS" -eq 1 ]] && : >"$out"

	logi "• Aggregating by file extension..."
	local -a prune_arr=()
	mapfile -d '' prune_arr < <(build_find_prune_array)
	local -a sudo_prefix_cmd=()
	[[ "$USE_SUDO" -eq 1 ]] && sudo_prefix_cmd=(sudo)

	{
		printf "extension%1$scount%1$stotal_bytes\n" "${CSV_SEP}"
		while read -r r; do
			[[ -z "$r" ]] && continue
			"${sudo_prefix_cmd[@]}" find "$r" -xdev "${prune_arr[@]}" -type f \
				-printf '%f\t%s\n' 2>/dev/null
		done < <(build_roots) |
			awk -F'\t' -v OFS='\t' '
          {
            fn=$1; sz=$2+0;
            ext="<none>";
            if (match(fn, /\.[^\.]+$/)) { ext=substr(fn, RSTART+1) }
            C[ext]+=1; S[ext]+=sz;
          }
          END {
            for (e in C) { printf "%s\t%d\t%d\n", e, C[e], S[e]; }
          }' |
			sort -nr -k3,3 |
			awk -F'\t' -v OFS="${CSV_SEP}" '{print $1,$2,$3}'
	} >>"$out"

	if [[ "$QUIET" -eq 0 && "$WRITE_REPORTS" -eq 1 ]]; then
		printf "\n== By extension (Top %d by total bytes) ==\n" "$TOPN"
		head -n "$TOPN" "$out" | column -s"${CSV_SEP}" -t
	fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
function main() {
	parse_args "$@"

	if [[ "$WRITE_REPORTS" -eq 1 ]]; then
		mkdir -p -- "$OUTDIR"
		logi "Output directory: $OUTDIR"
	fi

	run_df_summary
	run_directory_summary
	run_largest_files
	run_per_user
	run_by_extension

	if [[ "$QUIET" -eq 0 && "$WRITE_REPORTS" -eq 1 ]]; then
		printf "\nReports written to: %s\n" "$OUTDIR"
	fi
}

main "$@"
