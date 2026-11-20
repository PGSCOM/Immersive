#!/bin/bash
# Graba la coreografía: host real (backend X11) sobre el escritorio de
# desktop.sh + el cliente Godot real con Movie Maker a 1920x1080 / 30 fps.
# Uso: record.sh [salida.avi]   (por defecto $IM2_VIDEO_WORK/take.avi)
# El cliente va en modo de medios por TCP (--im2-usb): bajo Movie Maker corre
# al ~40 % de tiempo real y por UDP desbordaría el buffer del socket, con lo
# que el control de tasa del host hundiría la calidad.
HERE=$(dirname "$(readlink -f "$0")")
ROOT=$(readlink -f "$HERE/../..")
WORK=${IM2_VIDEO_WORK:-/tmp/im2-video}
OUT=${1:-$WORK/take.avi}
DISP=$(cat "$WORK/display") || { echo "antes: desktop.sh"; exit 1; }
mkdir -p "$WORK/hosthome" "$WORK/godothome"
cd "$ROOT"
env -u WAYLAND_DISPLAY -u DBUS_SESSION_BUS_ADDRESS XDG_SESSION_TYPE=x11 DISPLAY="$DISP" \
	HOME="$WORK/hosthome" XDG_CONFIG_HOME="$WORK/hosthome/.config" \
	stdbuf -oL -eL ./host/build/immersive2_host --no-ui --no-usb --no-audio --pin 246810 \
	--tcp-port 41900 --udp-port 41901 --audio-port 41902 > "$WORK/host.log" 2>&1 &
HP=$!
sleep 1
# 1080p solo para esta grabación (override.cfg se borra al acabar).
printf '[display]\nwindow/size/viewport_width=1920\nwindow/size/viewport_height=1080\n' > client/project/override.cfg
timeout 900 env -u WAYLAND_DISPLAY HOME="$WORK/godothome" xvfb-run -a -s "-screen 0 1920x1080x24" \
	godot --rendering-driver opengl3 --xr-mode off --audio-driver Dummy --path client/project \
	--write-movie "$OUT" --fixed-fps 30 -s "$HERE/portfolio_video.gd" -- \
	--im2-host=127.0.0.1 --im2-port=41900 --im2-udp-port=41901 --im2-monitors=0,1,2 --im2-usb \
	> "$WORK/godot.log" 2>&1
rc=$?
rm -f client/project/override.cfg
kill $HP
grep -E "^(ok|FAIL|MARK|RESULT)|recorded" "$WORK/godot.log"
exit $rc
