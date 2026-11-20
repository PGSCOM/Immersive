# Vídeo de demostración (portfolio)

Cómo se hizo el vídeo de Immersive que sale en el portfolio (pgscom.es, ficha
`proyectos/immersive`) y cómo volver a grabarlo. Todo está en
`tools/portfolio_video/`; nada de esto forma parte del host ni del cliente.

## Qué enseña

70 s, 1920x1080 a 30 fps, sin audio ni textos. Es el **cliente real** (la
escena `main.tscn` de Godot) recibiendo el stream de un **host real** con el
backend X11, no un montaje: lo que aparece en las pantallas es un escritorio de
verdad capturado y codificado en directo.

| Escena | Qué pasa |
|---|---|
| intro | Tres monitores del PC flotando en arco: el portfolio en Chrome, VS Code con el código del host y un vídeo reproduciéndose |
| control | Clic con el láser en VS Code y, con el teclado VR, se escribe `// hola desde las gafas`; la cámara se acerca a leerlo |
| layout | El monitor del vídeo se coge por su barra y se encaja encima del de VS Code (marco de encaje), los dos se mueven juntos, y el de en medio crece desde su esquina |
| menu | El menú: pestañas Screens, Quality y Space, y el ambiente pasa de *Night* a *Dusk* |
| whiteboard | La pizarra: un monitor, una flecha y unas gafas dibujados con el láser |
| virtual | Se quita un monitor y se pide una pantalla virtual de 1920x1080: el host la crea como monitor RandR y aparece la página del repo en GitHub |
| outro | Plano general |

## Cómo está montado

1. **`desktop.sh`** arranca un `Xvfb` privado de 7680x1080 partido en tres
   monitores RandR de 1920x1080 (`M0`, `M1`, `M2`) con contenido real:
   - `M0`: el `dist/` del portfolio servido en `127.0.0.1:41950`, en Chrome.
   - `M1`: VS Code abierto sobre una **copia** de `host/src` en el directorio
     de trabajo (lo que se teclee en el vídeo no toca el repo), en la línea 94
     de `server.cpp`. Ajustes en `vscode-settings.json` (zoom, sin bienvenida,
     sin IA, sin autoguardado).
   - `M2`: `video.html`, un clip en bucle a 0.4x (ver más abajo por qué).
   - Los 1920 px de la derecha no los cubre ningún monitor: ahí hay otra
     ventana de Chrome con la página del repo, y ahí coloca el host la pantalla
     virtual.

   Chrome y VS Code se arrancan con `WAYLAND_DISPLAY` y el bus de sesión
   quitados y `--ozone-platform=x11`: si no, en una sesión Wayland se abren en
   el escritorio de verdad en vez de en el Xvfb. Cada Chrome tiene su
   `--user-data-dir` en el directorio de trabajo, con Google Translate
   desactivado en sus preferencias (si no, la página de GitHub sale con la
   burbuja de traducir). `stop.sh` lo para todo por PID.

2. **`record.sh`** arranca `immersive2_host --no-ui --no-usb --no-audio` en
   ese display (HOME privado, puertos 41900-41902) y el cliente Godot bajo
   `xvfb-run` con Movie Maker (`--write-movie`, `--fixed-fps 30`) y la
   coreografía `portfolio_video.gd` como script principal. Para grabar a
   1920x1080 escribe un `client/project/override.cfg` temporal con el tamaño
   de ventana y lo borra al acabar (`--resolution` no basta: Movie Maker usa el
   tamaño del proyecto).

3. **`portfolio_video.gd`** (un `SceneTree` como `client/tests/demo_video_test.gd`)
   mueve un puntero con guion a través de las mismas llamadas que usan los
   mandos: `main.pick()`, `LaserDrag.grab/drop`, `send_mouse_input`,
   `send_keyboard_pointer`, `send_ui_pointer_*`, `send_whiteboard_pointer`,
   `select_monitor` y `request_virtual_screen`. Las teclas, las pestañas y los
   botones se apuntan por la posición real de su `Button` en el SubViewport,
   así que el clic es de verdad. La cabeza (la cámara) sigue un punto de
   interés suavizado. Imprime `MARK <fotograma> <escena>` al empezar cada
   escena y una línea `ok`/`FAIL` por cada comprobación, como los tests.

4. **`edit.py`** recorta la espera inicial (de la marca `intro` a `end`) y
   codifica H.264 (`-preset slow`, `yuv420p`, `+faststart`). `CRF` elige la
   calidad; el 28 por defecto deja los 70 s en ~22 MB.

## Detalles que no son obvios

- **Medios por TCP (`--im2-usb`).** Bajo Movie Maker el cliente va al ~38 %
  de tiempo real. Por UDP no lee el socket a tiempo, el buffer se desborda, el
  control de tasa del host ve pérdidas y baja la calidad hasta el 5 % (medido:
  `link congested ... video bitrate down to 5%`). En modo de medios por TCP
  (el de USB) no hay pérdidas y el stream va entero.
- **El clip va a 0.4x.** Por la misma razón, un segundo del vídeo final son
  ~2.6 s reales del escritorio: el clip se reproduce a 0.4x para que en el
  resultado se vea a su velocidad. El menú muestra los fps reales del stream,
  no los del vídeo.
- **El nombre del PC.** El menú lo enseña; la coreografía lo cambia por
  `workstation` con `ui_overlay.set_host_label()` justo antes de abrirlo.
- **Encuadre.** La cámara mira 6° por encima de lo que sigue (12° desde que
  hay una pantalla encajada arriba). Venía de una versión con rótulos arriba a
  la izquierda; sin ellos se queda porque deja aire sobre las pantallas.

## Volver a grabarlo

Hace falta el host compilado (`host/build/immersive2_host`), Godot 4.7 en el
PATH, `Xvfb`, `xvfb-run`, `xrandr`, `xsetroot`, `xdotool`, `google-chrome`,
`code` y `ffmpeg`.

```bash
export IM2_VIDEO_WORK=/tmp/im2-video     # todo lo temporal va aquí
cd tools/portfolio_video
./desktop.sh          # PORTFOLIO_DIST, CLIP y VIRTUAL_URL cambian el contenido
./record.sh           # -> $IM2_VIDEO_WORK/take.avi (~3 min, RESULT fails=0)
python3 edit.py       # -> $IM2_VIDEO_WORK/immersive.mp4
./stop.sh
```

Reinicia el escritorio (`stop.sh` + `desktop.sh`) antes de cada toma: el texto
tecleado en VS Code se queda y el clic de la siguiente cae en otra línea.

## Dónde está el vídeo

En el repo del portfolio, `public/proyvid/immersive-vr.mp4` (22 MB, por
debajo de los 25 MB por fichero de Cloudflare Pages, así que va directo y el
build lo pasa a HLS). Un solo fichero para todo en
`src/content/proyectos/immersive.md`: `trailer` (fondo del hero), `video` (la
tarjeta) y la sección *Demo* de la ficha, con controles. La imagen de la
tarjeta (`src/assets/proyectos/immersive.webp`) es el plano final de la toma.

El nombre lleva `-vr` porque hubo una versión anterior `immersive.mp4` con
rótulos: con otra URL, un navegador con sus segmentos HLS en caché no la
vuelve a enseñar.

## Revisión

`review.py` manda una copia ligera del vídeo a la API de Gemini (clave en
`GEMINI_API_KEY`, nunca en el repo) y pide una crítica con marcas de tiempo.
Mientras se hizo este vídeo `gemini-3.8-flash` respondió siempre 503 (*high
demand*), así que la revisión se hizo a mano sobre hojas de fotogramas de cada
toma: de ahí salieron el acercamiento a lo tecleado, el encuadre y quitar la
burbuja de traducir.
