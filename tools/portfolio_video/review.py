#!/usr/bin/env python3
"""Pide a Gemini una revisión crítica del vídeo (una sola petición).

    GEMINI_API_KEY=... python3 review.py vídeo.mp4 [pregunta extra]

Manda una copia ligera (720p, unos MB) en línea, sin subir ficheros, a la API
de Gemini (claves de AI Studio, AIza... o AQ....). Imprime la respuesta.
"""
import base64
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

MODEL = os.environ.get("GEMINI_MODEL", "gemini-3.8-flash")
PROMPT = """Eres director de arte y editor de vídeo. Este vídeo va en el portfolio
de un desarrollador para enseñar Immersive: un programa que lleva los monitores
del PC a unas gafas de realidad virtual (cliente en Godot + OpenXR, host en C++).
Está grabado con el cliente real y no lleva textos ni audio.

Haz una revisión crítica y concreta, con marcas de tiempo:
1. ¿Se entiende qué es el proyecto y qué enseña cada escena?
2. ¿Se entiende sin textos? ¿Qué escena necesitaría más tiempo o un plano más claro?
3. Fallos visuales: parpadeos, saltos de cámara, cortes bruscos, elementos tapados
   o cortados, cosas que parezcan rotas.
4. Ritmo: ¿sobra o falta algo? ¿Hay tramos lentos?
5. Las tres mejoras que más subirían la calidad.
Sé breve y directo; no elogies por cortesía."""


def proxy(src):
    out = os.path.join(tempfile.mkdtemp(), "proxy.mp4")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-vf", "scale=-2:720",
                    "-c:v", "libx264", "-crf", "30", "-preset", "veryfast", "-an", out], check=True)
    return out


def ask(key, video, prompt):
    body = {"contents": [{"role": "user", "parts": [
        {"inline_data": {"mime_type": "video/mp4",
                         "data": base64.b64encode(open(video, "rb").read()).decode()}},
        {"text": prompt}]}]}
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent"
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "x-goog-api-key": key})
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            res = json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code}: {e.read().decode()[:2000]}")
    return "".join(p.get("text", "") for p in res["candidates"][0]["content"]["parts"])


def main():
    key = os.environ.get("GEMINI_API_KEY")
    if not key or len(sys.argv) < 2:
        sys.exit(__doc__)
    prompt = PROMPT + ("\n\n" + sys.argv[2] if len(sys.argv) > 2 else "")
    print(ask(key, proxy(sys.argv[1]), prompt))


if __name__ == "__main__":
    main()
