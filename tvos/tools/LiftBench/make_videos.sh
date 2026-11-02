#!/bin/sh
# The bench's clips (git-ignored): 1080p SDR H.264 at 24 and 60 fps, 20 s, from ffmpeg's testsrc2 (a moving pattern with detail).
set -e
cd "$(dirname "$0")/Videos"
for r in 24000/1001:24 30000/1001:30 60000/1001:60; do
  rate=${r%%:*}; name=${r##*:}
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=$rate" -t 20 -c:v libx264 -crf 16 -preset fast \
    -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 -movflags +faststart sdr1080p$name.mp4
done
