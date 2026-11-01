# shellcheck shell=bash
if [ "$#" -ne 2 ]; then
  echo "usage: qa-mp4 <in.webm> <out.mp4>" >&2
  exit 2
fi
offset=$(ffmpeg -hide_banner -nostats -i "$1" -map 0:v:0 -vf freezedetect=d=1 -f null - 2>&1 | awk '
  /freeze_start/ && !started { started = 1; start = $NF; next }
  /freeze_end/ && started && !ended { ended = 1; end = $NF }
  END { if (started && ended && start <= 1.5 && end > 0.5) printf "%.2f", end - 0.5; else print "0" }')
ffmpeg -y -loglevel error -ss "$offset" -i "$1" \
  -vf 'scale=trunc(iw/2)*2:trunc(ih/2)*2' \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$2"
echo "qa-mp4: trimmed a ${offset}s static lead-in; cite timestamps from $2"
