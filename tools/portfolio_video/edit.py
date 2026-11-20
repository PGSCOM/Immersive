#!/usr/bin/env python3
"""Montaje del vídeo de portfolio a partir de la toma de record.sh.

    python3 edit.py [toma.avi] [salida.mp4]

Lee las marcas "MARK <frame> <escena>" de $IM2_VIDEO_WORK/godot.log, recorta
la espera inicial (de "intro" a "end") y codifica H.264 1080p30 con
faststart, sin audio ni textos. CRF (por defecto 28) elige la calidad: 28
deja los 70 s en ~24 MB, por debajo de los 25 MB por fichero de Cloudflare.
"""
import os
import re
import subprocess
import sys

WORK = os.environ.get("IM2_VIDEO_WORK", "/tmp/im2-video")
TAKE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(WORK, "take.avi")
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(WORK, "immersive.mp4")
FPS = 30


def main():
    log = open(os.path.join(WORK, "godot.log"), encoding="utf-8", errors="replace").read()
    mk = {m[1]: int(m[0]) for m in re.findall(r"^MARK (\d+) (\w+)", log, re.M)}
    start, dur = mk["intro"] / FPS, (mk["end"] - mk["intro"]) / FPS
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{start:.4f}", "-t", f"{dur:.4f}", "-i", TAKE,
                    "-an", "-c:v", "libx264", "-preset", "slow", "-crf", os.environ.get("CRF", "28"),
                    "-pix_fmt", "yuv420p", "-movflags", "+faststart", OUT], check=True)
    print(f"{OUT}: {dur:.1f} s, {os.path.getsize(OUT) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
