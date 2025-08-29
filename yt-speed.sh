#!/usr/bin/env bash
# ytspeed — Download and/or time-stretch a video; audio kept in sync; output MP4.
# Dependencies: ffmpeg, yt-dlp (only required in URL mode), GNU getopt (on Arch by default).

ytspeed() {
  # ---------- Help ----------
  _help() {
    cat <<'EOF'
ytspeed — download and/or speed-adjust a video while keeping audio in sync (final output: .mp4)

USAGE:
  ytspeed [OPTIONS] [URL-or-input] [tempo]

MODES:
  URL mode:
    -u, --url <URL>            If -t/--tempo omitted -> download only (no re-encode).
                               If -t/--tempo provided -> download then re-encode.

  File mode:
    -i, --input <file>         Use an existing local file (requires -t/--tempo).

OPTIONS:
  -t, --tempo <val>            Playback speed as percent (e.g., 85) or decimal (e.g., 0.85).
                               If omitted in URL mode -> download only.
                               If omitted in file mode -> error.
                               If omitted but env var "video_speed" is set, that is used.

  -o, --output <dir>           Output directory (default: current working directory).

  -n, --name <basename>        Basename (no extension) for the final MP4. For download-only,
                               it also names the merged download.

  -h, --help                   Show this help.

POSITIONAL FALLBACKS:
  If you prefer positionals, after options you may pass:
    [URL-or-input] [tempo]
  If it starts with "http", it is treated as URL; otherwise as input path.
  Tempo accepts either 85 (percent) or 0.85 (decimal).

DETAILS:
  * Video speed: setpts = (1/tempo) * PTS
  * Audio speed: ffmpeg 'atempo' (auto-chained if overall tempo outside [0.5, 2.0])
  * Final container: MP4 (H.264/AAC). Source may be .mkv/.webm/.mkv.webm — all handled.

ENVIRONMENT:
  video_speed     Optional default tempo (percent like 95, or decimal like 0.95)

EXAMPLES:
  # Download only (best ≤1080p video + best audio), current dir:
  ytspeed -u 'https://youtu.be/VIDEO'

  # Download and slow to 85% (percent form), name final file explicitly:
  ytspeed --url 'https://youtu.be/VIDEO' --tempo 85 --name "Despacito-85pct"

  # Download and slow to 0.7× (decimal form), to ./out:
  ytspeed -u 'https://youtu.be/VIDEO' -t 0.7 -o ./out

  # Re-encode an existing file to 95% speed:
  ytspeed -i ./input.mkv -t 95

  # Use env default tempo:
  export video_speed=0.9
  ytspeed -u 'https://youtu.be/VIDEO'
EOF
  }

  # ---------- Require ffmpeg ----------
  command -v ffmpeg >/dev/null 2>&1 || { echo "Error: ffmpeg not found." >&2; return 1; }

  # ---------- Parse options (GNU getopt) ----------
  local OPTIONS=hu:U:i:I:t:T:o:O:n:N:
  local LONGOPTS=help,url:,URL:,input:,INPUT:,tempo:,TEMPO:,output:,OUTPUT:,name:,NAME:
  local parsed
  parsed=$(getopt --options="$OPTIONS" --longoptions="$LONGOPTS" --name ytspeed -- "$@") || {
    echo "Try: ytspeed --help" >&2; return 2; }
  eval set -- "$parsed"

  local url="" input="" tempo_arg="" outdir="" namebase=""
  while true; do
    case "$1" in
      -h|--help) _help; return 0 ;;
      -u|--url|-U|--URL) url="$2"; shift 2 ;;
      -i|--input|-I|--INPUT) input="$2"; shift 2 ;;
      -t|--tempo|-T|--TEMPO) tempo_arg="$2"; shift 2 ;;
      -o|--output|-O|--OUTPUT) outdir="$2"; shift 2 ;;
      -n|--name|-N|--NAME) namebase="$2"; shift 2 ;;
      --) shift; break ;;
      *) echo "Internal parsing error." >&2; return 3 ;;
    esac
  done

  # ---------- Positional fallbacks ----------
  # Accept up to two: [URL-or-input] [tempo]
  if [[ -z "$url" && -z "$input" && $# -ge 1 ]]; then
    if [[ "$1" =~ ^https?:// ]]; then url="$1"; else input="$1"; fi
    shift
  fi
  if [[ -z "$tempo_arg" && $# -ge 1 ]]; then tempo_arg="$1"; shift; fi

  # ---------- Output dir ----------
  [[ -z "$outdir" ]] && outdir="$PWD"
  mkdir -p "$outdir" || { echo "Error: cannot create output dir: $outdir" >&2; return 4; }

  # ---------- Tempo default from env video_speed ----------
  if [[ -z "$tempo_arg" && -n "$video_speed" ]]; then
    tempo_arg="$video_speed"
  fi

  # ---------- Mode validation ----------
  if [[ -n "$url" && -n "$input" ]]; then
    echo "Error: Provide either --url or --input, not both." >&2; return 5
  fi
  if [[ -z "$url" && -z "$input" ]]; then
    echo "Error: You must provide either --url URL or --input FILE (or use positionals)." >&2; return 6
  fi

  # ---------- Tempo parsing (percent or decimal) ----------
  # Accepts "85" -> 0.85; "0.85" -> 0.85
  local tempo_dec=""
  if [[ -n "$tempo_arg" ]]; then
    if [[ "$tempo_arg" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      # If >1, treat as percent
      if awk 'BEGIN{exit !('"$tempo_arg"' > 1)}'; then
        tempo_dec=$(awk 'BEGIN{printf("%.10f", '"$tempo_arg"' / 100.0)}')
      else
        tempo_dec="$tempo_arg"
      fi
      # must be positive
      awk 'BEGIN{exit !('"$tempo_dec"' > 0)}' || { echo "Error: tempo must be > 0." >&2; return 7; }
    else
      echo "Error: tempo must be numeric (e.g., 85 or 0.85)." >&2; return 8
    fi
  fi

  # ---------- Helper: build atempo chain within [0.5,2.0] per stage ----------
  _build_atempo_chain() {
    local t="$1" chain=() iter=0
    while awk 'BEGIN{exit !('"$t"' < 0.5)}'; do
      chain+=("atempo=0.5"); t=$(awk 'BEGIN{printf("%.10f",'$t' / 0.5)}'); ((iter++)); [[ $iter -gt 12 ]] && break
    done
    while awk 'BEGIN{exit !('"$t"' > 2.0)}'; do
      chain+=("atempo=2.0"); t=$(awk 'BEGIN{printf("%.10f",'$t' / 2.0)}'); ((iter++)); [[ $iter -gt 12 ]] && break
    done
    chain+=("atempo=$(awk 'BEGIN{printf("%.10f",'$t')}' )")
    local IFS=,; echo "${chain[*]}"
  }

  # ---------- Acquire source (URL mode or file mode) ----------
  local src_file="" base_noext=""
  if [[ -n "$url" ]]; then
    command -v yt-dlp >/dev/null 2>&1 || { echo "Error: yt-dlp not found." >&2; return 9; }

    # If user provided -n for download-only, honor it in the yt-dlp template.
    local ytdlp_outtmpl
    if [[ -n "$namebase" ]]; then
      # yt-dlp will append container extension; we request mkv merge.
      ytdlp_outtmpl="$outdir/${namebase}.%(ext)s"
    else
      ytdlp_outtmpl="$outdir/%(title)s.%(ext)s"
    fi

    # Download best ≤1080p video + best audio, merge to MKV (container may be mkv or webm internally).
    src_file="$(yt-dlp -f "bv*[height<=1080]+ba/best" \
                -o "$ytdlp_outtmpl" \
                --merge-output-format mkv \
                --print "%(filepath)s" \
                --no-progress \
                "$url" | tail -n1)"
    [[ -f "$src_file" ]] || { echo "Error: download failed." >&2; return 10; }
    base_noext="$(basename "${src_file%.*}")"

    # If no tempo requested -> download-only
    if [[ -z "$tempo_dec" ]]; then
      echo "Downloaded: $src_file"
      return 0
    fi
  else
    # File mode
    src_file="$input"
    [[ -f "$src_file" ]] || { echo "Error: input not found: $src_file" >&2; return 11; }
    base_noext="$(basename "${src_file%.*}")"
    [[ -n "$tempo_dec" ]] || { echo "Error: --tempo is required with --input." >&2; return 12; }
  fi

  # ---------- Compute filters ----------
  # setpts = 1/tempo
  local setpts_factor
  setpts_factor="$(awk 'BEGIN{printf("%.10f", 1.0/'"$tempo_dec"') }')"
  local atempo_chain
  atempo_chain="$(_build_atempo_chain "$tempo_dec")"

  # ---------- Output filename (always .mp4) ----------
  local tempo_pct out_name
  tempo_pct="$(awk 'BEGIN{printf("%d", ('"$tempo_dec"'*100)+0.5)}')"
  if [[ -n "$namebase" ]]; then
    out_name="${namebase}.mp4"
  else
    out_name="${base_noext}-${tempo_pct}pct.mp4"
  fi
  local out_path="$outdir/$out_name"

  # ---------- Re-encode ----------
  # Accept any source extension (.mkv, .webm, even odd ".mkv.webm") — ffmpeg will parse container by content.
  ffmpeg -hide_banner -y -i "$src_file" \
    -filter_complex "[0:v]setpts=${setpts_factor}*PTS[v];[0:a]${atempo_chain}[a]" \
    -map "[v]" -map "[a]" \
    -c:v libx264 -crf 18 -preset veryfast \
    -c:a aac -b:a 192k \
    -movflags +faststart \
    "$out_path"
  local rc=$?
  [[ $rc -eq 0 ]] || { echo "Error: ffmpeg failed (exit $rc)." >&2; return $rc; }

  echo "Wrote: $out_path"
}

# --- Quick examples to set the env variable you asked about ---
# export video_speed=95     # percent default if -t is omitted
# export video_speed=0.95   # decimal default if -t is omitted
