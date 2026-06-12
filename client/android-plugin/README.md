# Im2VideoDecoder — Android MediaCodec plugin

Hardware video decoding (H.264 / HEVC / AV1) for the Immersive-2 VR client on
Quest / Pico, exposed to Godot as the `Im2VideoDecoder` singleton.

Without this plugin the client still works: it automatically falls back to
MJPEG when it cannot decode the stream codec.

## Build (requires Android Studio or the Android SDK + gradle)

```bash
cd client/android-plugin
gradle assembleRelease     # or open the folder in Android Studio
```

Output: `build/outputs/aar/im2decoder-release.aar`

## Install into the Godot project

Copy the AAR to:

```
client/project/addons/im2_decoder/bin/im2decoder-release.aar
```

(also `im2decoder-debug.aar` if you export debug builds). The export plugin in
`addons/im2_decoder` picks it up automatically when exporting for Android.

## Notes

- The `org.godotengine:godot` dependency version in `build.gradle` should
  roughly match your Godot editor version.
- AV1 decode requires a headset with an AV1-capable SoC (Quest 3 / XR2 Gen 2).
  Quest 2 supports H.264 and HEVC only; the client falls back automatically.
