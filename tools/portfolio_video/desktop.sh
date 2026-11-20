#!/bin/bash
# Escritorio privado para grabar el vídeo: un Xvfb con tres monitores RandR
# de 1920x1080 y contenido real, más 1920 px libres a la derecha donde el
# host X11 coloca la pantalla virtual que pide el cliente:
#   M0  el portfolio (dist/ de Astro servido en 127.0.0.1) en Chrome
#   M1  VS Code con una COPIA de host/src (lo que se escriba no toca el repo)
#   M2  un vídeo en bucle (a 0.4x: Movie Maker graba al ~40 % de tiempo real)
#   +   la página del repo en GitHub, que asoma en la pantalla virtual
# Nada sale al escritorio real: WAYLAND_DISPLAY y el bus de sesión se quitan.
#
# Uso: desktop.sh            (deja todo corriendo; stop.sh lo para)
# Variables: IM2_VIDEO_WORK (por defecto /tmp/im2-video), PORTFOLIO_DIST, CLIP,
#            VIRTUAL_URL
set -e
HERE=$(dirname "$(readlink -f "$0")")
ROOT=$(readlink -f "$HERE/../..")
WORK=${IM2_VIDEO_WORK:-/tmp/im2-video}
PORTFOLIO_DIST=${PORTFOLIO_DIST:-$ROOT/../pgscom.github.io/dist}
CLIP=${CLIP:-$ROOT/../pgscom.github.io/public/proyvid/blender-cotracker3.mp4}
VIRTUAL_URL=${VIRTUAL_URL:-https://github.com/PGSCOM/Immersive}
PORT=41950
W=1920; H=1080

mkdir -p "$WORK"
rm -rf "$WORK/ch0" "$WORK/ch2" "$WORK/ch3" "$WORK/vsc" "$WORK/Immersive"
: > "$WORK/pids"
unset WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_TYPE=x11

# -noreset: si no, el servidor borra los monitores RandR al irse xrandr.
Xvfb -displayfd 5 -noreset -screen 0 $((W*4))x${H}x24 -nolisten tcp 5>"$WORK/display.tmp" >/dev/null 2>&1 &
echo $! >> "$WORK/pids"
for i in $(seq 50); do [ -s "$WORK/display.tmp" ] && break; sleep 0.1; done
export DISPLAY=":$(tr -d '\n' < "$WORK/display.tmp")"
echo "$DISPLAY" > "$WORK/display"
xrandr --setmonitor M0 $W/510x$H/290+0+0 screen >/dev/null
xrandr --setmonitor M1 $W/510x$H/290+$W+0 none >/dev/null
xrandr --setmonitor M2 $W/510x$H/290+$((W*2))+0 none >/dev/null
xsetroot -solid "#141613"

(cd "$PORTFOLIO_DIST" && exec python3 -m http.server $PORT --bind 127.0.0.1 >/dev/null 2>&1) &
echo $! >> "$WORK/pids"

cp "$CLIP" "$WORK/clip.mp4"
cp "$HERE/video.html" "$WORK/video.html"

# Chrome trabaja en píxeles lógicos: con escala 1.25, 1536x864 llena 1920x1080.
CH="google-chrome --ozone-platform=x11 --no-first-run --no-default-browser-check --disable-sync
	--password-store=basic --disable-features=Translate,MediaRouter
	--autoplay-policy=no-user-gesture-required --force-device-scale-factor=1.25 --lang=en-US"
# Sin la burbuja de Google Translate (la página de GitHub está en inglés).
for prof in ch0 ch2 ch3; do
	mkdir -p "$WORK/$prof/Default"
	echo '{"translate":{"enabled":false},"translate_blocked_languages":["en","es"]}' > "$WORK/$prof/Default/Preferences"
done
$CH --user-data-dir="$WORK/ch0" --window-position=0,0 --window-size=1536,864 \
	--app=http://127.0.0.1:$PORT/ >/dev/null 2>&1 &
echo $! >> "$WORK/pids"
$CH --user-data-dir="$WORK/ch2" --window-position=3072,0 --window-size=1536,864 \
	--app="file://$WORK/video.html" >/dev/null 2>&1 &
echo $! >> "$WORK/pids"
$CH --user-data-dir="$WORK/ch3" --window-position=4608,0 --window-size=1536,864 \
	--app="$VIRTUAL_URL" >/dev/null 2>&1 &
echo $! >> "$WORK/pids"

mkdir -p "$WORK/Immersive/host" "$WORK/Immersive/protocol" "$WORK/vsc/User"
cp -r "$ROOT/host/src" "$WORK/Immersive/host/"
cp "$ROOT/protocol/protocol.h" "$WORK/Immersive/protocol/"
cp "$HERE/vscode-settings.json" "$WORK/vsc/User/settings.json"
code --user-data-dir="$WORK/vsc" --extensions-dir="$WORK/vsext" --new-window "$WORK/Immersive" \
	-g "$WORK/Immersive/host/src/network/server.cpp:94" >/dev/null 2>&1 &
sleep 10
for w in $(xdotool search --class code); do
	xdotool windowmove "$w" $W 0 windowsize "$w" $W $H 2>/dev/null || true
done
# La ventana de VS Code (Electron) arranca su propio proceso; guárdalo también.
pgrep -f -- "--user-data-dir=$WORK/vsc" | head -1 >> "$WORK/pids" || true
echo "escritorio en $DISPLAY"
