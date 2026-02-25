function heic2() {
  emulate -L zsh
  setopt pipefail null_glob extended_glob

  #-----------------------------------------------------------------------------
  # heic2
  # Convert HEIC/HEIF images to another format using `heif-convert` (libheif).
  #
  # Defaults:
  #   - If no -t/--target or -d/--directory: convert *.heic/*.HEIC in $PWD.
  #   - Output is written alongside each input file (in-place).
  #   - Original is deleted after successful conversion (unless -k/--keep-original).
  #
  # Notes:
  #   - If -R/--recursive and -o/--output are both used, relative subdirectories
  #     are preserved under the output directory.
  #-----------------------------------------------------------------------------

  local prog="heic2"

  function _heic2_usage() {
    cat <<'EOF'
heic2

Usage:
  heic2 [options] [--] [files...]

Options:
  -t, --target <file>					Convert a specific file. May be repeated.
                  						(You may also pass files as positional args.)
  -d, --directory <dir> 			Convert files in a directory (default: current dir).
  -R, --recursive       			Recurse into subdirectories when using --directory.

  -e, --extension <ext>   		Output extension/format: jpg|jpeg|png (default: jpg).
                        			Case-insensitive; a leading dot is allowed.

  -o, --output <dir>       		Output directory. If omitted: write next to inputs.
  -f, --force              		If --output dir does not exist, offer to create it.
                          		(Creation always prompts; --noconfirm does not bypass.)

  -k, --keep-original      		Keep the original .heic/.HEIC (default: delete it).
      --noconfirm          		Skip confirmation prompts for:
                            		- recursive conversion (-R)
                          			- deleting originals (default behavior)

      --overwrite         		If an output file already exists, overwrite it.
                        			(Default: skip and report.)

  -h, --help               		Show this help.

	Examples:
  # -----------------------------------------------------------------------------
  # 										heic2 — examples and usage
  # -----------------------------------------------------------------------------

  # 1)	Convert all .heic/.HEIC in the current directory →

				.jpg (default), delete heic2

	# 2)	Convert all in current directory → .png, delete originals

				heic2 -e png

  # 3) 	Convert specific files (positional targets) → .jpg, keep originals

				heic2 IMG_0001.HEIC IMG_0002.heic -e jpg -k

  # 4) 	Convert specific files (repeatable -t) → .jpeg, delete originals

				heic2 -t IMG_0001.HEIC -t IMG_0002.HEIC -e jpeg

  # 5) 	Convert a non-recursive directory → ./out, keep originals; create ./out

				heic2 -d . -e png -o ./out -f -k

  # 6) 	Recursive directory convert → ~/Pictures/converted, preserve structure,
				keep originals; create output dir; skip prompts

				heic2 -d ~/DCIM/Camera -R -e png -o \
				~/Pictures/converted -f --noconfirm -k

  # 7) 	Recursive directory convert → ~/Pictures/converted, delete originals;
				create output dir; skip prompts

				heic2 -d ~/DCIM/Camera -R -e jpg -o ~/Pictures/converted -f --noconfirm

  # 8) 	Overwrite outputs if they already exist (otherwise they are skipped)

				heic2 -d . -e jpg --overwrite

  # 9) 	Same as (8) but keep originals

				heic2 -d . -e jpg --overwrite -k


	#10)	Convert all .heic in directory ~/DCIM/Camera recursively to .png,
				write outputs to ~/Pictures/converted, keep originals; create output
				dir if doesn't exist since it is forced (-f); skip all prompts:

				heic2 -d ~/DCIM/Camera -R -e png \
				-o ~/Pictures/converted -f --noconfirm -k
EOF
  }

  function _heic2_die() {
    print -u2 -- "${prog}: $*"
    return 2
  }

  function _heic2_need_cmd() {
    command -v "$1" >/dev/null 2>&1 || _heic2_die "missing dependency: $1"
  }

  function _heic2_confirm() {
    local prompt="$1"
    local ans=""
    if [[ ! -t 0 ]]; then
      _heic2_die "confirmation required but stdin is not a TTY: ${prompt}"
      return 2
    fi
    print -n -- "${prompt} [y/N] "
    read -r ans
    [[ "${ans}" == [Yy]* ]]
  }

  function _heic2_norm_ext() {
    local x="${1:l}"
    x="${x#.}"                 # remove leading dot
    case "${x}" in
      jpg|jpeg|png) print -- "${x}" ;;
      *) return 1 ;;
    esac
  }

  function _heic2_convert_one() {
    # Args:
    #   1: input file (absolute or relative)
    #   2: output file (absolute or relative)
    local in="$1"
    local out="$2"

    if [[ ! -f "${in}" ]]; then
      failed+=("${in}")
      return 1
    fi

    if [[ -e "${out}" && ${overwrite} -eq 0 ]]; then
      skipped+=("${in}")
      return 0
    fi

    if [[ -e "${out}" && ${overwrite} -eq 1 ]]; then
      rm -f -- "${out}" || {
        failed+=("${in}")
        return 1
      }
    fi

    heif-convert -- "${in}" "${out}" || {
      failed+=("${in}")
      return 1
    }

    converted+=("${in}")

    if [[ ${keep_original} -eq 0 ]]; then
      rm -f -- "${in}" && deleted+=("${in}") || {
        # Conversion succeeded but deletion failed; treat as failure to be honest.
        failed+=("${in}")
        return 1
      }
    fi

    return 0
  }

  #-----------------------------------------------------------------------------
  # Parse arguments
  #-----------------------------------------------------------------------------
  local -a targets=()
  local directory=""
  local out_dir=""
  local out_ext="jpg"

  local keep_original=0
  local recursive=0
  local force=0
  local noconfirm=0
  local overwrite=0

  local arg=""
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "${arg}" in
      -h|--help)
        _heic2_usage
        return 0
        ;;
      -t|--target)
        shift
        [[ $# -gt 0 ]] || _heic2_die "--target requires a file"
        targets+=("$1")
        shift
        ;;
      --target=*)
        targets+=("${arg#*=}")
        shift
        ;;
      -d|--directory)
        shift
        [[ $# -gt 0 ]] || _heic2_die "--directory requires a path"
        directory="$1"
        shift
        ;;
      --directory=*)
        directory="${arg#*=}"
        shift
        ;;
      -R|--recursive)
        recursive=1
        shift
        ;;
      -e|--extension)
        shift
        [[ $# -gt 0 ]] || _heic2_die "--extension requires a value"
        out_ext="$1"
        shift
        ;;
      --extension=*)
        out_ext="${arg#*=}"
        shift
        ;;
      -o|--output)
        shift
        [[ $# -gt 0 ]] || _heic2_die "--output requires a directory"
        out_dir="$1"
        shift
        ;;
      --output=*)
        out_dir="${arg#*=}"
        shift
        ;;
      -f|--force)
        force=1
        shift
        ;;
      -k|--keep-original)
        keep_original=1
        shift
        ;;
      --noconfirm)
        noconfirm=1
        shift
        ;;
      --overwrite)
        overwrite=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        _heic2_die "unknown option: ${arg} (use --help)"
        return 2
        ;;
      *)
        # Positional args are treated as target files.
        targets+=("${arg}")
        shift
        ;;
    esac
  done

  # Remaining args after -- are also treated as target files.
  while [[ $# -gt 0 ]]; do
    targets+=("$1")
    shift
  done

  if [[ ${#targets[@]} -gt 0 && -n "${directory}" ]]; then
    _heic2_die "use either --target/positional files OR --directory, not both"
    return 2
  fi

  out_ext="$(_heic2_norm_ext "${out_ext}")" || {
    _heic2_die "unsupported --extension '${out_ext}'. Use: jpg|jpeg|png"
    return 2
  }

  _heic2_need_cmd heif-convert || return 2

  #-----------------------------------------------------------------------------
  # Resolve mode + sanity checks
  #-----------------------------------------------------------------------------
  local mode=""

  if [[ ${#targets[@]} -gt 0 ]]; then
    mode="targets"
  else
    mode="directory"
    if [[ -z "${directory}" ]]; then
      directory="."
    fi
  fi

  if [[ "${mode}" == "targets" ]]; then
    # Targets must be files.
    local t=""
    for t in "${targets[@]}"; do
      if [[ -d "${t}" ]]; then
        _heic2_die "target is a directory (use --directory instead): ${t}"
        return 2
      fi
    done
  fi

  if [[ "${mode}" == "directory" ]]; then
    if [[ ! -d "${directory}" ]]; then
      _heic2_die "directory does not exist: ${directory}"
      return 2
    fi
  fi

  #-----------------------------------------------------------------------------
  # Output directory handling
  #-----------------------------------------------------------------------------
  if [[ -n "${out_dir}" ]]; then
    if [[ -e "${out_dir}" && ! -d "${out_dir}" ]]; then
      _heic2_die "--output exists but is not a directory: ${out_dir}"
      return 2
    fi

    if [[ ! -d "${out_dir}" ]]; then
      if [[ ${force} -eq 1 ]]; then
        if _heic2_confirm "Create output directory '${out_dir}'?"; then
          mkdir -p -- "${out_dir}" || {
            _heic2_die "failed to create: ${out_dir}"
            return 2
          }
        else
          _heic2_die "output directory not created; aborting"
          return 2
        fi
      else
        _heic2_die "output directory does not exist: ${out_dir} ${prog}: create it \
          or re-run with --force to offer creation"
        return 2
      fi
    fi
  fi

  #-----------------------------------------------------------------------------
  # Confirmation prompts
  #-----------------------------------------------------------------------------
  if [[ ${noconfirm} -eq 0 ]]; then
    if [[ "${mode}" == "directory" && ${recursive} -eq 1 ]]; then
      _heic2_confirm \
        "Recursive conversion will scan '${directory}' for \
        .heic/.HEIC files. Proceed?" || return 1
    fi

    if [[ ${keep_original} -eq 0 ]]; then
      _heic2_confirm \
        "Original .heic/.HEIC files will be deleted after successful \
        conversion. Proceed?" || return 1
    fi
  fi

  #-----------------------------------------------------------------------------
  # Gather inputs
  #-----------------------------------------------------------------------------
  local -a files=()

  if [[ "${mode}" == "targets" ]]; then
    # Filter to HEIC/HEIF extensions only (case-insensitive match on suffix).
    local f=""
    for f in "${targets[@]}"; do
      if [[ "${f:l}" == *.heic ]]; then
        files+=("${f}")
      else
        skipped+=("${f}")
      fi
    done
  else
    if [[ ${recursive} -eq 1 ]]; then
      local dir_abs="${directory:A}"
      local -a found=()
      while IFS= read -r -d '' f; do
        found+=("${f}")
      done < <(find "${dir_abs}" -type f -iname '*.heic' -print0)
      files=("${found[@]}")
    else
      # Non-recursive: only files directly in the directory.
      files=("${directory}"/**.heic(N) "${directory}"/**.HEIC(N))
      # The patterns above intentionally match only one 
      # path segment (no recursion). In zsh, ** without (/) 
      # qualifiers can recurse; here we avoid recursion by
      # relying on the fact we used a literal directory 
      # prefix + a filename glob.
    fi
  fi

  if [[ ${#files[@]} -eq 0 ]]; then
    print -u2 -- "${prog}: no .heic/.HEIC files found"
    return 1
  fi

  #-----------------------------------------------------------------------------
  # Convert
  #-----------------------------------------------------------------------------
  local -a converted=() skipped=() failed=() deleted=()

  local in=""
  for in in "${files[@]}"; do
    local in_abs="${in:A}"
    local in_dir="${in_abs:h}"
    local stem="${in_abs:t:r}"

    local out_path=""

    if [[ -z "${out_dir}" ]]; then
      # Default: in-place output alongside the input file.
      out_path="${in_dir}/${stem}.${out_ext}"
    else
      if [[ "${mode}" == "directory" && ${recursive} -eq 1 ]]; then
        # Preserve relative structure under out_dir.
        local root_abs="${directory:A}"
        local rel="${in_abs#${root_abs}/}"
        local rel_dir="${rel:h}"
        local out_sub="${out_dir}/${rel_dir}"
        mkdir -p -- "${out_sub}" 2>/dev/null || true
        out_path="${out_sub}/${stem}.${out_ext}"
      else
        out_path="${out_dir}/${stem}.${out_ext}"
      fi
    fi

    _heic2_convert_one "${in_abs}" "${out_path}"
  done

  #-----------------------------------------------------------------------------
  # Report
  #-----------------------------------------------------------------------------
  print -- "${prog}: done"
  print -- "  Converted: ${#converted[@]}"
  print -- "  Deleted:   ${#deleted[@]}"
  print -- "  Skipped:   ${#skipped[@]}"
  print -- "  Failed:    ${#failed[@]}"

  if [[ ${#failed[@]} -gt 0 ]]; then
    print -u2 -- "${prog}: failures:"
    local x=""
    for x in "${failed[@]}"; do
      print -u2 -- "  - ${x}"
    done
    return 1
  fi

  return 0
}
