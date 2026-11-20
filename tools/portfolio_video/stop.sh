#!/bin/bash
# Para lo que arrancó desktop.sh (solo esos procesos, por PID).
WORK=${IM2_VIDEO_WORK:-/tmp/im2-video}
[ -f "$WORK/pids" ] && xargs -r kill < "$WORK/pids" 2>/dev/null
# Chrome y VS Code dejan hijos con su --user-data-dir dentro de $WORK.
for p in $(pgrep -f -- "--user-data-dir=$WORK/"); do kill "$p" 2>/dev/null; done
rm -f "$WORK/pids" "$WORK/display"
