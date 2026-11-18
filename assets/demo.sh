#!/usr/bin/env bash
# Records the README demo: runs assets/demo.tape with vhs (real nvim, real
# claude, so every take differs a little and costs a few cents), then cuts
# the stretches where nothing moves (Claude thinking) down to CAP seconds.
# Writes assets/demo.mp4 (full resolution; GitHub plays it when it is
# uploaded through the web editor) and assets/demo.gif (works from the repo).
# Needs vhs and ffmpeg (`brew install vhs`). Run from the repo root.
#   assets/demo.sh          record and convert
#   assets/demo.sh --keep   only convert the existing assets/demo-raw.mp4
set -euo pipefail

RAW=assets/demo-raw.mp4
MP4=assets/demo.mp4
GIF=assets/demo.gif
CAP=${CAP:-1.2}   # longest still stretch kept, seconds
HOLD=${HOLD:-3.5} # how long the last frame stays before the loop restarts
GIF_FPS=${GIF_FPS:-12}
GIF_WIDTH=${GIF_WIDTH:-1200}

[ "${1:-}" = "--keep" ] || vhs assets/demo.tape

dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$RAW")
# every still stretch as "start end"; the last one runs to the end of the file
cuts=$(ffmpeg -hide_banner -i "$RAW" -vf "freezedetect=n=0.001:d=$CAP" -map 0:v -f null - 2>&1 |
	awk -v dur="$dur" -v cap="$CAP" -v hold="$HOLD" '
		/freeze_start/ { start = $NF; open = 1 }
		/freeze_end/ { add(start, $NF, cap); open = 0 }
		END { if (open) add(start, dur, hold); print expr }
		function add(s, e, keep) {
			if (e - s > keep) expr = expr (expr ? "+" : "") "between(t," s + keep "," e ")"
		}')

ffmpeg -hide_banner -loglevel error -y -i "$RAW" \
	-vf "select='not(${cuts:-0})',setpts=N/FRAME_RATE/TB" \
	-c:v libx264 -crf 20 -preset slow -pix_fmt yuv420p -movflags +faststart -an "$MP4"

ffmpeg -hide_banner -loglevel error -y -i "$MP4" -filter_complex \
	"fps=$GIF_FPS,scale=$GIF_WIDTH:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
	"$GIF"

for f in "$MP4" "$GIF"; do
	printf '%s: %ss, %s\n' "$f" \
		"$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")" \
		"$(du -h "$f" | cut -f1)"
done
