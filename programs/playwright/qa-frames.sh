# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
if [ "$#" -ne 3 ]; then
  echo "usage: qa-frames <video> <t1,t2,...> <out.png>   (t in seconds, e.g. 3,7.5,12)" >&2
  exit 2
fi
video=$1 out=$3
IFS=, read -ra times <<<"$2"
label() {
  echo "drawtext=fontfile=${font}:text='$1':x=8:y=8:fontsize=22:fontcolor=white:box=1:boxcolor=black@0.7:boxborderw=6"
}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
n=0
for t in "${times[@]}"; do
  if ! [[ $t =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "qa-frames: '$t' is not a time in seconds" >&2
    exit 2
  fi
  frame=$(printf '%s/%03d.png' "$tmp" "$n")
  tile=$(label "$t s")
  ffmpeg -y -loglevel error -ss "$t" -i "$video" -frames:v 1 -vf "scale=480:-2,$tile" "$frame"
  if [ ! -s "$frame" ]; then
    end=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$video")
    end=$(printf '%.2f' "$end")
    echo "qa-frames: $t s is past the end of $video; using its last frame ($end s)" >&2
    # -update keeps overwriting one image, so what is left is the last frame.
    tile=$(label "$end s (end)")
    ffmpeg -y -loglevel error -sseof -1 -i "$video" -update 1 -vf "scale=480:-2,$tile" "$frame"
  fi
  if [ ! -s "$frame" ]; then
    echo "qa-frames: no frame in $video" >&2
    exit 1
  fi
  n=$((n + 1))
done
cols=$((n < 3 ? n : 3))
rows=$(((n + cols - 1) / cols))
ffmpeg -y -loglevel error -framerate 1 -i "$tmp/%03d.png" -vf "tile=${cols}x${rows}:padding=4:color=white" -frames:v 1 "$out"
echo "qa-frames: $n tiles ($2 s) in $out"
