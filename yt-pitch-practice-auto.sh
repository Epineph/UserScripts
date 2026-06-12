#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# yt-pitch-practice-auto
#
# Download a video/audio source with yt-dlp, globally shift pitch with Rubber
# Band, optionally change tempo, and optionally estimate/correct microtonal
# detuning with librosa. This is for whole-track retuning, not note-by-note
# vocal-style autotune.
#
# Copyright note:
#   Use only for material you have permission to download/process.
# -----------------------------------------------------------------------------

function usage() {
  cat <<'EOF_USAGE'
yt-pitch-practice-auto

Usage:
  yt-pitch-practice-auto --url URL [options]
  yt-pitch-practice-auto URL [options]

Core options:
  -u, --url URL                 URL to download. Mandatory unless positional.
  -o, --out-dir DIR             Output directory. Default: current directory.
  -n, --name NAME               Output basename. Default: downloaded title.
      --audio-only              Output audio only.
      --container mkv|mp4       Video container. Default: mkv.
      --audio-format FORMAT     Audio-only format: flac, wav, opus, m4a, mp3.
                                Default: flac.

Pitch / tempo:
      --pitch-semitones N       Explicit pitch shift in semitones. Default: 0.
      --pitch-up N              Equivalent to --pitch-semitones +N.
      --pitch-down N            Equivalent to --pitch-semitones -N.
      --tempo-percent P         Tempo as percent of original. Default: 100.
                                80 = slower, 125 = faster.

Automatic and manual retuning:
      --auto-retune             Estimate global detuning in cents and correct
                                the soundtrack to the nearest A440 12-TET grid.
                                Requires Python with librosa installed.
      --tuning-cents C          Manual source detuning in cents. Positive means
                                the source is sharp; negative means flat.
                                Correction applied is -C/100 semitones.
      --analysis-offset SEC     Skip this many seconds before tuning analysis.
                                Default: 20.
      --analysis-seconds SEC    Maximum seconds used for tuning analysis.
                                Default: 180.
      --analysis-only           Download/extract/analyse, print final planned
                                shift, then exit without writing output.

Guitar tuning transposition:
      --source-tuning NAME      Source tuning: standard, eb, d, db, c, b, bb,
                                a. Aliases: e, d#, c#, h, bflat, etc.
      --target-tuning NAME      Target tuning. Default is standard when only
                                --source-tuning is given.

Song-key transposition:
      --source-key KEY          Source musical key, e.g. C, Cm, Eb, F#.
                                Use "auto" to call keyfinder-cli.
      --target-key KEY          Target musical key, e.g. C or Eb.
                                If this is given without --source-key, source
                                key detection defaults to keyfinder-cli.

Quality / compatibility:
      --crf N                   Video CRF when video re-encoding is required.
                                Default: 15. Lower is larger/better.
      --preset NAME             x264 preset when re-encoding video.
                                Default: veryslow.
      --no-formant              Disable Rubber Band formant preservation.
      --cookies-from-browser B  Pass browser cookies to yt-dlp, e.g. firefox.
      --keep-temp               Keep temporary working directory.
  -h, --help                    Show help.

Notes:
  * --auto-retune corrects small global detuning, e.g. a recording 23 cents
    flat becomes +0.23 semitones.
  * --source-tuning eb --target-tuning standard transposes +1 semitone.
  * --source-tuning c# --target-tuning standard transposes +3 semitones.
  * --source-key and --source-tuning are both transpositions. Use both only if
    you deliberately want both effects.
  * Key detection is probabilistic. Use --source-key manually when you know it.

Examples:
  # Correct a whole soundtrack that is globally flat/sharp:
  yt-pitch-practice-auto URL --auto-retune

  # The source is in Eb standard and slightly flat; bring it to standard pitch:
  yt-pitch-practice-auto URL --source-tuning eb --auto-retune

  # The source is C# standard and you play in standard tuning:
  yt-pitch-practice-auto URL --source-tuning c# --target-tuning standard

  # Source key is Eb; transpose the song to C:
  yt-pitch-practice-auto URL --source-key Eb --target-key C

  # Detect source key with keyfinder-cli, transpose to C, and retune cents:
  yt-pitch-practice-auto URL --source-key auto --target-key C --auto-retune

  # Manual correction: source is 18 cents flat, so shift up by 0.18 semitones:
  yt-pitch-practice-auto URL --tuning-cents -18

  # Analysis only, useful before rendering a large video:
  yt-pitch-practice-auto URL --source-tuning eb --auto-retune --analysis-only
EOF_USAGE
}

function die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

function note() {
  printf '==> %s\n' "$*" >&2
}

function have() {
  command -v "$1" >/dev/null 2>&1
}

function lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

function require_base_programs() {
  local missing=()
  local program

  for program in yt-dlp ffmpeg ffprobe rubberband awk sed tr date mktemp; do
    have "$program" || missing+=("$program")
  done

  ((${#missing[@]} == 0)) || die "missing programs: ${missing[*]}"
}

function require_optional_programs() {
  if [[ "$AUTO_RETUNE" -eq 1 ]]; then
    have python3 || die "--auto-retune requires python3"
  fi

  if [[ "$SOURCE_KEY" == "auto" ]]; then
    have keyfinder-cli || die "--source-key auto requires keyfinder-cli"
  fi
}

function is_number() {
  [[ "$1" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]]
}

function is_positive_number() {
  is_number "$1" && awk -v x="$1" 'BEGIN { exit !(x > 0) }'
}

function abs_float() {
  awk -v x="$1" 'BEGIN { if (x < 0) x = -x; printf "%.10g", x }'
}

function add_floats() {
  awk -v a="$1" -v b="$2" 'BEGIN { printf "%+.6f", a + b }'
}

function tempo_changed() {
  awk -v p="$TEMPO_PERCENT" 'BEGIN {
    d = p - 100
    if (d < 0) {
      d = -d
    }
    exit !(d > 0.000001)
  }'
}

function tempo_ratio() {
  awk -v p="$TEMPO_PERCENT" 'BEGIN { printf "%.10g", p / 100 }'
}

function make_safe_stem() {
  local input="$1"
  local stem

  stem="${NAME:-$(basename "$input")}"
  stem="${stem%.*}"

  printf '%s' "$stem" |
    sed -E \
      -e 's/[[:space:]]+/_/g' \
      -e 's/[^A-Za-z0-9._+-]+/_/g' \
      -e 's/_+/_/g' \
      -e 's/^_//' \
      -e 's/_$//'
}

function make_shift_tag() {
  local pitch tempo

  pitch="$(printf '%s' "$PITCH_SEMITONES" |
    sed -e 's/^+//' -e 's/-/m/' -e 's/\./p/g')"

  tempo="$(printf '%s' "$TEMPO_PERCENT" |
    sed -e 's/\./p/g')"

  printf 'pitch_%sst_tempo_%spct' "$pitch" "$tempo"
}

function normalise_note_name() {
  local note="$1"

  note="${note//♭/b}"
  note="${note//♯/#}"
  note="$(lower "$note")"
  note="$(printf '%s' "$note" | sed -E 's/[[:space:]_-]+//g')"
  note="$(printf '%s' "$note" |
    sed -E 's/(major|maj|min|minor)$//; s/m$//')"

  printf '%s' "$note"
}

function pitch_class_index() {
  local note

  note="$(normalise_note_name "$1")"

  case "$note" in
    c|b#) printf '0' ;;
    c#|db) printf '1' ;;
    d) printf '2' ;;
    d#|eb) printf '3' ;;
    e|fb) printf '4' ;;
    e#|f) printf '5' ;;
    f#|gb) printf '6' ;;
    g) printf '7' ;;
    g#|ab) printf '8' ;;
    a) printf '9' ;;
    a#|bb) printf '10' ;;
    b|h|cb) printf '11' ;;
    *) die "unsupported key/note name: $1" ;;
  esac
}

function nearest_key_shift() {
  local source target raw

  source="$(pitch_class_index "$1")"
  target="$(pitch_class_index "$2")"
  raw=$((target - source))

  while ((raw > 6)); do
    raw=$((raw - 12))
  done

  while ((raw < -6)); do
    raw=$((raw + 12))
  done

  printf '%+d' "$raw"
}

function tuning_offset() {
  local tuning

  tuning="$(lower "$1")"
  tuning="$(printf '%s' "$tuning" | sed -E 's/[[:space:]_-]+//g')"

  case "$tuning" in
    standard|std|e|estandard) printf '0' ;;
    eb|d#|eflat|dsharp|ebstandard|dsharpstandard) printf -- '-1' ;;
    d|dstandard) printf -- '-2' ;;
    db|c#|dflat|csharp|dbstandard|csharpstandard) printf -- '-3' ;;
    c|cstandard) printf -- '-4' ;;
    b|h|bstandard|hstandard) printf -- '-5' ;;
    bb|a#|bflat|asharp|bbstandard|asharpstandard) printf -- '-6' ;;
    a|astandard) printf -- '-7' ;;
    *) die "unsupported guitar tuning: $1" ;;
  esac
}

function tuning_shift() {
  local source target source_offset target_offset

  source="$1"
  target="$2"

  if [[ -z "$source" && -z "$target" ]]; then
    printf '+0'
    return 0
  fi

  [[ -n "$source" ]] || source="standard"
  [[ -n "$target" ]] || target="standard"

  source_offset="$(tuning_offset "$source")"
  target_offset="$(tuning_offset "$target")"

  printf '%+.6f' "$((target_offset - source_offset))"
}

function detect_key() {
  local input="$1"
  local key

  key="$(keyfinder-cli -n standard "$input" | head -n 1 | tr -d '\r')"
  [[ -n "$key" ]] || die "keyfinder-cli did not return a key"

  printf '%s' "$key"
}

function detect_tuning_cents() {
  local input="$1"

  ANALYSIS_OFFSET_ENV="$ANALYSIS_OFFSET" \
  ANALYSIS_SECONDS_ENV="$ANALYSIS_SECONDS" \
  python3 - "$input" <<'PY'
import os
import sys

try:
    import librosa
except Exception as exc:  # pragma: no cover - user environment dependent
    raise SystemExit(
        "error: --auto-retune requires Python package 'librosa' "
        f"({exc})"
    )

path = sys.argv[1]
offset = float(os.environ.get("ANALYSIS_OFFSET_ENV", "20"))
duration = float(os.environ.get("ANALYSIS_SECONDS_ENV", "180"))

try:
    y, sr = librosa.load(
        path,
        sr=22050,
        mono=True,
        offset=max(offset, 0.0),
        duration=max(duration, 1.0),
    )
    if y.size < sr:
        y, sr = librosa.load(
            path,
            sr=22050,
            mono=True,
            offset=0.0,
            duration=max(duration, 1.0),
        )
except Exception as exc:
    raise SystemExit(f"error: could not analyse tuning: {exc}")

if y.size < sr:
    raise SystemExit("error: not enough audio for tuning analysis")

try:
    tuning = librosa.estimate_tuning(
        y=y,
        sr=sr,
        resolution=0.01,
        bins_per_octave=12,
    )
except Exception as exc:
    raise SystemExit(f"error: librosa tuning estimation failed: {exc}")

cents = float(tuning) * 100.0
print(f"{cents:+.2f}")
PY
}

function calculate_final_pitch() {
  local key_source key_shift tuning_transpose tuning_correction
  local auto_cents total_tuning_cents total

  total="$REQUESTED_PITCH_SEMITONES"
  tuning_transpose="$(tuning_shift "$SOURCE_TUNING" "$TARGET_TUNING")"
  total="$(add_floats "$total" "$tuning_transpose")"

  KEY_SHIFT_SEMITONES='+0'
  DETECTED_SOURCE_KEY=''

  if [[ -n "$TARGET_KEY" && -z "$SOURCE_KEY" ]]; then
    SOURCE_KEY='auto'
  fi

  if [[ -n "$SOURCE_KEY" || -n "$TARGET_KEY" ]]; then
    [[ -n "$TARGET_KEY" ]] || die "--source-key requires --target-key"

    if [[ "$SOURCE_KEY" == "auto" ]]; then
      key_source="$(detect_key "$RAW_AUDIO")"
      DETECTED_SOURCE_KEY="$key_source"
      note "detected source key: $key_source"
    else
      key_source="$SOURCE_KEY"
    fi

    KEY_SHIFT_SEMITONES="$(nearest_key_shift "$key_source" "$TARGET_KEY")"
    total="$(add_floats "$total" "$KEY_SHIFT_SEMITONES")"
  fi

  DETECTED_TUNING_CENTS=''
  total_tuning_cents='0'

  if [[ -n "$MANUAL_TUNING_CENTS" ]]; then
    total_tuning_cents="$(add_floats "$total_tuning_cents" \
      "$MANUAL_TUNING_CENTS")"
  fi

  if [[ "$AUTO_RETUNE" -eq 1 ]]; then
    auto_cents="$(detect_tuning_cents "$RAW_AUDIO")"
    DETECTED_TUNING_CENTS="$auto_cents"
    total_tuning_cents="$(add_floats "$total_tuning_cents" "$auto_cents")"
    note "detected global detuning: ${auto_cents} cents"
  fi

  tuning_correction="$(awk -v c="$total_tuning_cents" \
    'BEGIN { printf "%+.6f", -c / 100 }')"

  total="$(add_floats "$total" "$tuning_correction")"
  PITCH_SEMITONES="$total"

  note "explicit pitch shift: ${REQUESTED_PITCH_SEMITONES} st"
  note "tuning transpose: ${tuning_transpose} st"
  note "key transpose: ${KEY_SHIFT_SEMITONES} st"
  note "microtuning correction: ${tuning_correction} st"
  note "final pitch shift: ${PITCH_SEMITONES} st"
}

function build_audio_args() {
  local format="$1"
  AUDIO_ARGS=()

  case "$format" in
    flac)
      AUDIO_ARGS=(-c:a flac -compression_level 12)
      ;;
    wav)
      AUDIO_ARGS=(-c:a pcm_f32le)
      ;;
    opus)
      AUDIO_ARGS=(-c:a libopus -b:a 510k -vbr on -compression_level 10)
      ;;
    m4a)
      AUDIO_ARGS=(-c:a aac -b:a 320k)
      ;;
    mp3)
      AUDIO_ARGS=(-c:a libmp3lame -b:a 320k)
      ;;
    *)
      die "unsupported audio format: $format"
      ;;
  esac
}

function download_source() {
  local tmp="$1"
  local url="$2"
  local mode="$3"
  local path_file="$tmp/downloaded-path.txt"
  local -a cmd=()

  cmd=(
    yt-dlp
    --no-simulate
    --no-playlist
    --continue
    --newline
    --embed-metadata
    -o "$tmp/source.%(ext)s"
    --print-to-file "after_move:filepath" "$path_file"
  )

  if [[ "$mode" == "audio" ]]; then
    cmd+=(-f "bestaudio/best")
  else
    cmd+=(
      -f "bestvideo*+bestaudio/best"
      -S "res,fps,hdr:12,vcodec,acodec,br"
      --merge-output-format mkv
      --remux-video mkv
    )
  fi

  if have aria2c; then
    cmd+=(
      --downloader aria2c
      --downloader-args "aria2c:-x 16 -s 16 -k 1M"
    )
  fi

  if [[ -n "$COOKIES_FROM_BROWSER" ]]; then
    cmd+=(--cookies-from-browser "$COOKIES_FROM_BROWSER")
  fi

  note "downloading source media"
  "${cmd[@]}" "$url" >&2

  [[ -s "$path_file" ]] || die "yt-dlp did not report final file path"

  tail -n 1 "$path_file"
}

function extract_audio_to_wav() {
  local source="$1"
  local output="$2"

  note "extracting audio as 32-bit float WAV"

  ffmpeg \
    -hide_banner \
    -y \
    -i "$source" \
    -vn \
    -map 0:a:0 \
    -c:a pcm_f32le \
    "$output"
}

function process_audio() {
  local input="$1"
  local output="$2"
  local ratio
  local -a cmd=()

  ratio="$(tempo_ratio)"

  note "processing audio: pitch=${PITCH_SEMITONES} st, tempo=${TEMPO_PERCENT}%"

  cmd=(
    rubberband
    --fine
    --tempo "$ratio"
    --pitch "$PITCH_SEMITONES"
  )

  if [[ "$FORMANT" -eq 1 ]]; then
    cmd+=(--formant)
  fi

  cmd+=("$input" "$output")

  "${cmd[@]}"
}

function write_audio_only() {
  local processed="$1"
  local output="$2"

  build_audio_args "$AUDIO_FORMAT"

  note "writing audio-only output"

  ffmpeg \
    -hide_banner \
    -y \
    -i "$processed" \
    "${AUDIO_ARGS[@]}" \
    "$output"
}

function write_video_output() {
  local source="$1"
  local processed="$2"
  local output="$3"
  local ratio
  local video_audio_format

  ratio="$(tempo_ratio)"

  if [[ "$CONTAINER" == "mkv" ]]; then
    video_audio_format="flac"
  else
    video_audio_format="m4a"
  fi

  build_audio_args "$video_audio_format"

  if tempo_changed || [[ "$CONTAINER" == "mp4" ]]; then
    note "writing video output with H.264 re-encode"

    ffmpeg \
      -hide_banner \
      -y \
      -i "$source" \
      -i "$processed" \
      -map 0:v:0 \
      -map 1:a:0 \
      -filter:v "setpts=PTS/${ratio}" \
      -c:v libx264 \
      -preset "$PRESET" \
      -crf "$CRF" \
      -pix_fmt yuv420p \
      "${AUDIO_ARGS[@]}" \
      -shortest \
      "$output"
  else
    note "writing video output with copied video stream"

    ffmpeg \
      -hide_banner \
      -y \
      -i "$source" \
      -i "$processed" \
      -map 0:v:0 \
      -map 1:a:0 \
      -map 0:s? \
      -c:v copy \
      -c:s copy \
      "${AUDIO_ARGS[@]}" \
      -shortest \
      "$output"
  fi
}

URL=""
OUT_DIR="$PWD"
NAME=""
AUDIO_ONLY=0
CONTAINER="mkv"
AUDIO_FORMAT="flac"
REQUESTED_PITCH_SEMITONES="0"
PITCH_SEMITONES="0"
TEMPO_PERCENT="100"
CRF="15"
PRESET="veryslow"
FORMANT=1
KEEP_TEMP=0
COOKIES_FROM_BROWSER=""
AUTO_RETUNE=0
MANUAL_TUNING_CENTS=""
ANALYSIS_OFFSET="20"
ANALYSIS_SECONDS="180"
ANALYSIS_ONLY=0
SOURCE_TUNING=""
TARGET_TUNING=""
SOURCE_KEY=""
TARGET_KEY=""
KEY_SHIFT_SEMITONES="+0"
DETECTED_SOURCE_KEY=""
DETECTED_TUNING_CENTS=""

while (($#)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -u|--url)
      (($# >= 2)) || die "$1 requires an argument"
      URL="$2"
      shift 2
      ;;
    --url=*)
      URL="${1#*=}"
      shift
      ;;
    -o|--out-dir)
      (($# >= 2)) || die "$1 requires an argument"
      OUT_DIR="$2"
      shift 2
      ;;
    --out-dir=*)
      OUT_DIR="${1#*=}"
      shift
      ;;
    -n|--name)
      (($# >= 2)) || die "$1 requires an argument"
      NAME="$2"
      shift 2
      ;;
    --name=*)
      NAME="${1#*=}"
      shift
      ;;
    --audio-only)
      AUDIO_ONLY=1
      shift
      ;;
    --container)
      (($# >= 2)) || die "$1 requires an argument"
      CONTAINER="$(lower "$2")"
      shift 2
      ;;
    --container=*)
      CONTAINER="$(lower "${1#*=}")"
      shift
      ;;
    --audio-format)
      (($# >= 2)) || die "$1 requires an argument"
      AUDIO_FORMAT="$(lower "$2")"
      shift 2
      ;;
    --audio-format=*)
      AUDIO_FORMAT="$(lower "${1#*=}")"
      shift
      ;;
    --pitch-semitones|--pitch)
      (($# >= 2)) || die "$1 requires an argument"
      REQUESTED_PITCH_SEMITONES="$2"
      shift 2
      ;;
    --pitch-semitones=*|--pitch=*)
      REQUESTED_PITCH_SEMITONES="${1#*=}"
      shift
      ;;
    --pitch-up)
      (($# >= 2)) || die "$1 requires an argument"
      REQUESTED_PITCH_SEMITONES="+$2"
      shift 2
      ;;
    --pitch-up=*)
      REQUESTED_PITCH_SEMITONES="+${1#*=}"
      shift
      ;;
    --pitch-down)
      (($# >= 2)) || die "$1 requires an argument"
      REQUESTED_PITCH_SEMITONES="-$2"
      shift 2
      ;;
    --pitch-down=*)
      REQUESTED_PITCH_SEMITONES="-${1#*=}"
      shift
      ;;
    --tempo-percent|--tempo)
      (($# >= 2)) || die "$1 requires an argument"
      TEMPO_PERCENT="$2"
      shift 2
      ;;
    --tempo-percent=*|--tempo=*)
      TEMPO_PERCENT="${1#*=}"
      shift
      ;;
    --auto-retune|--auto-tune|--auto-correct-tuning)
      AUTO_RETUNE=1
      shift
      ;;
    --tuning-cents)
      (($# >= 2)) || die "$1 requires an argument"
      MANUAL_TUNING_CENTS="$2"
      shift 2
      ;;
    --tuning-cents=*)
      MANUAL_TUNING_CENTS="${1#*=}"
      shift
      ;;
    --analysis-offset)
      (($# >= 2)) || die "$1 requires an argument"
      ANALYSIS_OFFSET="$2"
      shift 2
      ;;
    --analysis-offset=*)
      ANALYSIS_OFFSET="${1#*=}"
      shift
      ;;
    --analysis-seconds)
      (($# >= 2)) || die "$1 requires an argument"
      ANALYSIS_SECONDS="$2"
      shift 2
      ;;
    --analysis-seconds=*)
      ANALYSIS_SECONDS="${1#*=}"
      shift
      ;;
    --analysis-only|--dry-analysis)
      ANALYSIS_ONLY=1
      shift
      ;;
    --source-tuning)
      (($# >= 2)) || die "$1 requires an argument"
      SOURCE_TUNING="$2"
      shift 2
      ;;
    --source-tuning=*)
      SOURCE_TUNING="${1#*=}"
      shift
      ;;
    --target-tuning)
      (($# >= 2)) || die "$1 requires an argument"
      TARGET_TUNING="$2"
      shift 2
      ;;
    --target-tuning=*)
      TARGET_TUNING="${1#*=}"
      shift
      ;;
    --source-key)
      (($# >= 2)) || die "$1 requires an argument"
      SOURCE_KEY="$(lower "$2")"
      shift 2
      ;;
    --source-key=*)
      SOURCE_KEY="$(lower "${1#*=}")"
      shift
      ;;
    --target-key)
      (($# >= 2)) || die "$1 requires an argument"
      TARGET_KEY="$2"
      shift 2
      ;;
    --target-key=*)
      TARGET_KEY="${1#*=}"
      shift
      ;;
    --crf)
      (($# >= 2)) || die "$1 requires an argument"
      CRF="$2"
      shift 2
      ;;
    --crf=*)
      CRF="${1#*=}"
      shift
      ;;
    --preset)
      (($# >= 2)) || die "$1 requires an argument"
      PRESET="$2"
      shift 2
      ;;
    --preset=*)
      PRESET="${1#*=}"
      shift
      ;;
    --cookies-from-browser)
      (($# >= 2)) || die "$1 requires an argument"
      COOKIES_FROM_BROWSER="$2"
      shift 2
      ;;
    --cookies-from-browser=*)
      COOKIES_FROM_BROWSER="${1#*=}"
      shift
      ;;
    --no-formant)
      FORMANT=0
      shift
      ;;
    --keep-temp)
      KEEP_TEMP=1
      shift
      ;;
    http://*|https://*)
      [[ -z "$URL" ]] || die "URL specified more than once"
      URL="$1"
      shift
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$URL" ]] || die "missing URL"
[[ "$CONTAINER" =~ ^(mkv|mp4)$ ]] || die "container must be mkv or mp4"
[[ "$AUDIO_FORMAT" =~ ^(flac|wav|opus|m4a|mp3)$ ]] ||
  die "audio format must be flac, wav, opus, m4a, or mp3"

is_number "$REQUESTED_PITCH_SEMITONES" ||
  die "pitch must be numeric, e.g. +3, -1, 0, 1.5"

if [[ -n "$MANUAL_TUNING_CENTS" ]]; then
  is_number "$MANUAL_TUNING_CENTS" ||
    die "--tuning-cents must be numeric, e.g. -18 or +23.5"
fi

is_positive_number "$TEMPO_PERCENT" ||
  die "tempo percent must be positive, e.g. 80, 100, 125"

is_positive_number "$CRF" ||
  die "CRF must be positive"

is_number "$ANALYSIS_OFFSET" || die "analysis offset must be numeric"
is_positive_number "$ANALYSIS_SECONDS" || die "analysis seconds must be positive"

require_base_programs
require_optional_programs
mkdir -p "$OUT_DIR"

TMP_DIR="$(mktemp -d --tmpdir yt-pitch-practice.XXXXXXXX)"

function cleanup() {
  if [[ "$KEEP_TEMP" -eq 1 ]]; then
    note "kept temporary directory: $TMP_DIR"
  else
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT

MODE="video"
[[ "$AUDIO_ONLY" -eq 1 ]] && MODE="audio"

SOURCE="$(download_source "$TMP_DIR" "$URL" "$MODE")"
RAW_AUDIO="$TMP_DIR/raw.wav"
PROCESSED_AUDIO="$TMP_DIR/processed.wav"

extract_audio_to_wav "$SOURCE" "$RAW_AUDIO"
calculate_final_pitch

if [[ "$ANALYSIS_ONLY" -eq 1 ]]; then
  printf 'analysis-only: final pitch shift %s semitones\n' "$PITCH_SEMITONES"
  exit 0
fi

process_audio "$RAW_AUDIO" "$PROCESSED_AUDIO"

STEM="$(make_safe_stem "$SOURCE")_$(make_shift_tag)"

if [[ "$AUDIO_ONLY" -eq 1 ]]; then
  OUTPUT="$OUT_DIR/$STEM.$AUDIO_FORMAT"
  write_audio_only "$PROCESSED_AUDIO" "$OUTPUT"
else
  OUTPUT="$OUT_DIR/$STEM.$CONTAINER"
  write_video_output "$SOURCE" "$PROCESSED_AUDIO" "$OUTPUT"
fi

printf 'wrote: %s\n' "$OUTPUT"
