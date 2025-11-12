#!/usr/bin/env bash
# ytspeed — Download, tempo-change, and optional pitch-shift a video. Final output: .mp4
# Dependencies: ffmpeg (always), yt-dlp (URL mode), rubberband (only if --pitch used), GNU getopt.

set -o pipefail

print_help() {
  cat <<'EOF'
ytspeed — download and/or speed-adjust a video while keeping audio in sync (final output: .mp4)

USAGE:
  ytspeed [OPTIONS] [URL-or-input] [tempo]

MODES:
  URL mode:
    -u, --url <URL>            If -t/--tempo is omitted → download only (no re-encode).
                               If -t/--tempo provided → download then re-encode.

  File mode:
    -i, --input <file>         Use an existing local file (requires -t/--tempo or -p/--pitch).

OPTIONS:
  -t, --tempo <val>            Playback speed as percent (e.g., 85) or decimal (e.g., 0.85).
                               If omitted in URL mode and no pitch → download only.
                               If omitted in file mode but pitch is also omitted → error.
                               If omitted but env var "video_speed" is set, that is used.

  -p, --pitch <semitones>      Pitch shift in semitones (integer or decimal, positive or negative).
                               Uses 'rubberband' on the audio. May be combined with --tempo.

  -o, --output <dir>           Output directory (default: current working directory).

  -n, --name <basename>        Basename (no extension) for the final MP4. For download-only,
                               it also names the merged download.

  -h, --help                   Show this help.

POSITIONAL FALLBACKS:
  After options you may pass:  [URL-or-input] [tempo]
  If it starts with "http", it is treated as URL; otherwise as input path.
  Tempo accepts 85 (percent) or 0.85 (decimal).

DETAILS:
  * Video speed: setpts = (1/tempo) * PTS
  * Audio speed (no pitch): ffmpeg 'atempo' (auto-chained within [0.5, 2.0] per stage)
  * Audio with pitch: extracted WAV → rubberband (-p <semitones> and optionally -t <tempo>)
  * Final container is always MP4 (H.264/AAC). Source may be .mkv/.webm/.mkv.webm — all handled.

ENVIRONMENT:
  video_speed     Optional default tempo (percent like 95, or decimal like 0.95)
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "Error: '$1' not found in PATH." >&2; exit 1; }; }

# ---------- Require ffmpeg ----------
need ffmpeg

# ---------- Parse options (GNU getopt) ----------
OPTIONS=hu:U:i:I:t:T:o:O:n:N:p:P:
LONGOPTS=help,url:,URL:,input:,INPUT:,tempo:,TEMPO:,output:,OUTPUT:,name:,NAME:,pitch:,PITCH:

parsed=$(getopt --options="$OPTIONS" --longoptions="$LONGOPTS" --name ytspeed -- "$@") || { echo "Try: ytspeed --help" >&2; exit 2; }
eval set -- "$parsed"

url="" input="" tempo_arg="" outdir="$PWD" namebase="" pitch_arg=""

while true; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    -u|--url|-U|--URL) url="${2//\\}"; shift 2 ;;             # strip stray backslashes
    -i|--input|-I|--INPUT) input="$2"; shift 2 ;;
    -t|--tempo|-T|--TEMPO) tempo_arg="$2"; shift 2 ;;
    -o|--output|-O|--OUTPUT) outdir="$2"; shift 2 ;;
    -n|--name|-N|--NAME) namebase="$2"; shift 2 ;;
    -p|--pitch|-P|--PITCH) pitch_arg="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "Internal parsing error." >&2; exit 3 ;;
  esac
done

# ---------- Positional fallbacks ----------
if [[ -z "$url" && -z "$input" && $# -ge 1 ]]; then
  if [[ "$1" =~ ^https?:// ]]; then url="${1//\\}"; else input="$1"; fi
  shift
fi
if [[ -z "$tempo_arg" && $# -ge 1 ]]; then tempo_arg="$1"; shift; fi

mkdir -p "$outdir" || { echo "Error: cannot create output dir: $outdir" >&2; exit 4; }

# ---------- Tempo default from env ----------
if [[ -z "$tempo_arg" && -n "$video_speed" ]]; then
  tempo_arg="$video_speed"
fi

# ---------- Mode validation ----------
if [[ -n "$url" && -n "$input" ]]; then
  echo "Error: Provide either --url or --input, not both." >&2; exit 5
fi
if [[ -z "$url" && -z "$input" ]]; then
  echo "Error: Provide --url URL or --input FILE (or use positionals)." >&2; exit 6
fi

# ---------- Tempo parsing (percent or decimal) ----------
tempo_dec=""
if [[ -n "$tempo_arg" ]]; then
  tempo_arg="${tempo_arg/,/.}"  # normalize comma decimal -> dot
  if [[ "$tempo_arg" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    if LC_NUMERIC=C awk "BEGIN{exit !($tempo_arg > 1)}"; then
      tempo_dec=$(LC_NUMERIC=C awk "BEGIN{printf(\"%.10f\", $tempo_arg/100.0)}")
    else
      tempo_dec="$tempo_arg"
    fi
    LC_NUMERIC=C awk "BEGIN{exit !($tempo_dec > 0)}" || { echo "Error: tempo must be > 0." >&2; exit 7; }
  else
    echo "Error: tempo must be numeric (e.g., 85 or 0.85)." >&2; exit 8
  fi
fi

# ---------- Pitch parsing (int or decimal, signed) ----------
pitch=""
if [[ -n "$pitch_arg" ]]; then
  pitch_arg="${pitch_arg/,/.}"  # normalize comma decimal -> dot
  if [[ "$pitch_arg" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    pitch="$pitch_arg"
  else
    echo "Error: pitch must be a number (e.g., -2, 1, 1.5)." >&2; exit 9
  fi
fi

# ---------- Helper: build atempo chain for ffmpeg (no pitch case) ----------
build_atempo_chain() {
  local t="$1" chain=() iter=0
  while LC_NUMERIC=C awk "BEGIN{exit !($t < 0.5)}"; do
    chain+=("atempo=0.5")
    t=$(LC_NUMERIC=C awk "BEGIN{printf(\"%.10f\", $t/0.5)}")
    ((iter++)); [[ $iter -gt 12 ]] && break
  done
  while LC_NUMERIC=C awk "BEGIN{exit !($t > 2.0)}"; do
    chain+=("atempo=2.0")
    t=$(LC_NUMERIC=C awk "BEGIN{printf(\"%.10f\", $t/2.0)}")
    ((iter++)); [[ $iter -gt 12 ]] && break
  done
  chain+=("atempo=$(LC_NUMERIC=C awk "BEGIN{printf(\"%.10f\", $t)}")")
  local IFS=,
  echo "${chain[*]}"
}

# ---------- Acquire source (URL mode or file mode) ----------
src_file="" base_noext=""
if [[ -n "$url" ]]; then
  need yt-dlp
  if [[ -n "$namebase" ]]; then
    ytdlp_outtmpl="$outdir/${namebase}.%(ext)s"
  else
    ytdlp_outtmpl="$outdir/%(title)s.%(ext)s"
  fi
  src_file="$(yt-dlp -f "bv*[height<=1080]+ba/best" \
              -o "$ytdlp_outtmpl" \
              --merge-output-format mkv \
              --print after_move:filepath \
              --no-progress \
              "$url")"
  [[ -f "$src_file" ]] || { echo "Error: download failed." >&2; exit 10; }
  base_noext="$(basename "${src_file%.*}")"

  # Download-only if neither tempo nor pitch is given
  if [[ -z "$tempo_dec" && -z "$pitch" ]]; then
    echo "Downloaded: $src_file"
    exit 0
  fi
else
  src_file="$input"
  [[ -f "$src_file" ]] || { echo "Error: input not found: $src_file" >&2; exit 11; }
  base_noext="$(basename "${src_file%.*}")"

  if [[ -z "$tempo_dec" && -z "$pitch" ]]; then
    echo "Error: nothing to do (no --tempo and no --pitch)." >&2
    exit 12
  fi
fi

# ---------- Compute filters ----------
setpts_factor="$(LC_NUMERIC=C awk "BEGIN{t=${tempo_dec:-1}; if (t>0) printf(\"%.10f\", 1.0/t); else print \"1.0\";}")"

# ---------- Output filename (always .mp4) ----------
tempo_pct="$(LC_NUMERIC=C awk "BEGIN{printf(\"%d\", ((${tempo_dec:-1}*100)+0.5))}")"
pitch_tag=""
if [[ -n "$pitch" ]]; then
  if LC_NUMERIC=C awk "BEGIN{exit !($pitch < 0)}"; then pitch_tag="p${pitch}"; else pitch_tag="p+${pitch}"; fi
fi

if [[ -n "$namebase" ]]; then
  out_name="${namebase}.mp4"
else
  out_name="${base_noext}-${tempo_pct}pct${pitch_tag:+-${pitch_tag}}.mp4"
fi
out_path="$outdir/$out_name"

# (Optional) Uncomment for debug:
# echo "DEBUG tempo_dec=${tempo_dec:-1} setpts_factor=$setpts_factor url=$url" >&2

# ---------- Branch: with pitch (rubberband) vs without ----------
if [[ -n "$pitch" ]]; then
  need rubberband

  # temp WAVs (in output dir); ensure cleanup
  tmp_in="$(mktemp -p "$outdir" ytspeed_in_XXXX.wav)"
  tmp_out="$(mktemp -p "$outdir" ytspeed_out_XXXX.wav)"
  cleanup() { rm -f "$tmp_in" "$tmp_out"; }
  trap cleanup EXIT

  # Extract audio to PCM WAV
  ffmpeg -hide_banner -loglevel error -y -i "$src_file" -vn -acodec pcm_s16le "$tmp_in" || { echo "ffmpeg audio extract failed." >&2; exit 13; }

  # Apply rubberband: pitch only, or pitch+tempo (time-stretch factor must match video)
if [[ -n "$tempo_dec" ]]; then
  rubberband -p "$pitch" -t "$setpts_factor" "$tmp_in" "$tmp_out" || { echo "rubberband failed." >&2; exit 14; }
else
  rubberband -p "$pitch" "$tmp_in" "$tmp_out" || { echo "rubberband failed." >&2; exit 14; }
fi

  # Re-mux: video setpts (tempo if provided), audio = processed WAV
  ffmpeg -hide_banner -loglevel error -y -i "$src_file" -i "$tmp_out" \
    -filter_complex "[0:v]setpts=${setpts_factor}*PTS[v]" \
    -map "[v]" -map 1:a \
    -c:v libx264 -crf 18 -preset veryfast \
    -c:a aac -b:a 192k \
    -shortest -movflags +faststart \
    "$out_path" || { echo "ffmpeg mux failed." >&2; exit 15; }

  cleanup
  trap - EXIT
else
  # No pitch: ffmpeg handles both video (setpts) and audio (atempo chain)
  atempo_chain="$(build_atempo_chain "${tempo_dec:-1}")"
  ffmpeg -hide_banner -loglevel error -y -i "$src_file" \
    -filter_complex "[0:v]setpts=${setpts_factor}*PTS[v];[0:a]${atempo_chain}[a]" \
    -map "[v]" -map "[a]" \
    -c:v libx264 -crf 18 -preset veryfast \
    -c:a aac -b:a 192k \
    -shortest -movflags +faststart \
    "$out_path" || { echo "ffmpeg encode failed." >&2; exit 16; }
fi

echo "Wrote: $out_path"
exit 0
