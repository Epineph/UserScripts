#!/usr/bin/env bash
###############################################################################
#  capo-shift.sh ─ Download a YouTube video (or just its audio),
#                  pitch-shift by an arbitrary number of semitones, and
#                  write the result in a universal MP4 (video) or FLAC (audio).
#
#  Default behaviour:                     highest-quality video **and** audio,
#                                         shifted **-5 semitones** (capo-5 → 0)
#
#  Dependencies (all in Arch official repos):
#     yt-dlp      ffmpeg (compiled with librubberband)      python (≥3.6)
#
#  Usage examples
#  --------------
#   capo-shift.sh -u https://youtu.be/abc123                     # default (-5 st, AV)
#   capo-shift.sh --url https://youtu.be/abc123 -p 2             # +2 st, AV
#   capo-shift.sh -u https://youtu.be/abc123 -a -p -3            # audio-only, –3 st
#   capo-shift.sh -U https://youtu.be/abc123 -v                  # video-only, –5 st
#   capo-shift.sh --url https://youtu.be/abc123 -v -a -p 0       # AV, no shift
#
###############################################################################
set -euo pipefail

#-----------------------------  helper functions  -----------------------------
die() { printf "Error: %s\n" "$*" >&2; exit 1; }

usage() {
cat <<EOF
Usage: $(basename "$0") -u|--url URL [options]

Options (case-insensitive):
  -a | --audio           Produce audio-only FLAC
  -v | --video           Produce MP4 with shifted soundtrack
                         (If neither -a nor -v is given, or both are, MP4 is produced)
  -p | --pitch-shift N   Shift by N semitones (integer, + up / – down, default -5)

Examples:
  $(basename "$0") -u https://youtu.be/abc123             # default (-5 st, MP4)
  $(basename "$0") --url ... -a -p -3                     # audio-only, down 3 st
EOF
exit 1
}

#---------------------------  dependency check  -------------------------------
need_cmds=(yt-dlp ffmpeg python3)
for cmd in "${need_cmds[@]}"; do
  type -p "$cmd" >/dev/null || die "$cmd not found – install it first."
done
ffmpeg -hide_banner -filters 2>/dev/null | grep -q rubberband \
  || die "your ffmpeg lacks the rubberband filter (recompile/upgrade ffmpeg)."

#---------------------------  argument parsing  --------------------------------
url=""
pitch_shift=-5
want_audio=false
want_video=false

while [[ $# -gt 0 ]]; do
  opt="${1,,}"            # lower-case copy for case-insensitive match
  case "$opt" in
    -u|--url)           url="$2";           shift 2;;
    -a|--audio)         want_audio=true;    shift;;
    -v|--video)         want_video=true;    shift;;
    -p|--pitch-shift)   pitch_shift="$2";   shift 2;;
    -h|--help)          usage;;
    *)                  printf "Unknown option: %s\n\n" "$1"; usage;;
  esac
done

[[ -n "$url" ]] || usage
# If neither or both of -a/-v were given, default to “video result”
if { $want_audio && $want_video; } || { ! $want_audio && ! $want_video; }; then
  want_video=true
fi

#---------------------------  calculate pitch factor  --------------------------
pitch_factor=$(python3 - <<EOF
import math, sys
print(f"{math.pow(2, float(sys.argv[1])/12):.9f}")
EOF "$pitch_shift")

#---------------------------  download section  --------------------------------
printf 'Downloading source media …\n'
out_tpl='%(id)s.%(ext)s'

if $want_audio && ! $want_video; then
  yt-dlp -x --audio-format flac -o "$out_tpl" "$url"
  src_file="$(yt-dlp --get-filename -x -o "$out_tpl" "$url")"
else
  # highest quality MP4 video + audio in one file if possible
  yt-dlp -f "bv*+ba/best[ext=mp4]/best" -o "$out_tpl" "$url"
  src_file="$(yt-dlp --get-filename -o "$out_tpl" "$url")"
fi

base="${src_file%.*}"
shift_tag=$([ "$pitch_shift" -ge 0 ] && printf "+%d" "$pitch_shift" || printf "%d" "$pitch_shift")

#---------------------------  processing section  ------------------------------
if $want_audio && ! $want_video; then
  printf 'Pitch-shifting audio → FLAC …\n'
  ffmpeg -y -i "$src_file" \
        -af "rubberband=pitch=${pitch_factor}" \
        "${base}_shift${shift_tag}.flac"
  printf '✓  Output: %s\n' "${base}_shift${shift_tag}.flac"

else
  printf 'Pitch-shifting and muxing → MP4 …\n'
  ffmpeg -y -i "$src_file" \
        -af "rubberband=pitch=${pitch_factor}" \
        -c:v copy -c:a aac -b:a 192k \
        "${base}_shift${shift_tag}.mp4"
  printf '✓  Output: %s\n' "${base}_shift${shift_tag}.mp4"
fi

