package com.immersive2.decoder;

import android.graphics.SurfaceTexture;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Build;
import android.util.Log;
import android.view.Surface;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.UsedByGodot;

import java.nio.ByteBuffer;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Godot Android plugin: hardware video decoding (H.264 / HEVC / AV1) via
 * MediaCodec, zero-copy, for the Immersive-2 VR client.
 *
 * <p>This is the "industry" path used by Virtual Desktop / Moonlight / ALVR:
 * MediaCodec decodes directly onto a {@link Surface} backed by a
 * {@link SurfaceTexture}, which writes into a Godot {@code ExternalTexture}
 * (a {@code GL_TEXTURE_EXTERNAL_OES} object). There is NO CPU readback and NO
 * YUV→RGB software conversion — the decoded frame stays on the GPU and the
 * panel shader samples it via {@code samplerExternalOES}.
 *
 * <p>Threading:
 * <ul>
 *   <li>{@link #create}/{@link #submit}/{@link #release_decoder} run on the
 *       caller (Godot main) thread.</li>
 *   <li>{@link #attach_to_render_context} and {@link #update_image} MUST run on
 *       Godot's render/GL thread — the GDScript side schedules them through
 *       {@code RenderingServer.call_on_render_thread()} because the external
 *       texture only exists in that GL context.</li>
 * </ul>
 * One encoded access unit per {@link #submit} (Annex-B for H.264/HEVC, OBUs for
 * AV1 — exactly what the Immersive-2 host emits).
 */
public class Im2VideoDecoder extends GodotPlugin {

    private static final String TAG = "Im2VideoDecoder";

    private static class StreamDecoder {
        MediaCodec codec;
        final MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        SurfaceTexture surfaceTexture;
        Surface surface;
        int externalTexId;
        volatile boolean attached;
        final float[] transform = new float[16];

        StreamDecoder() {
            // Identity transform until the first updateTexImage().
            transform[0] = 1f; transform[5] = 1f; transform[10] = 1f; transform[15] = 1f;
        }
    }

    private final ConcurrentHashMap<Integer, StreamDecoder> streams = new ConcurrentHashMap<>();

    public Im2VideoDecoder(Godot godot) {
        super(godot);
    }

    @Override
    public String getPluginName() {
        return "Im2VideoDecoder";
    }

    /**
     * Create a decoder that renders into the Godot ExternalTexture identified
     * by {@code externalTexId} (from {@code ExternalTexture.get_external_texture_id()}).
     *
     * @param mime video/avc, video/hevc or video/av01.
     */
    @UsedByGodot
    public boolean create(int streamId, String mime, int width, int height, int externalTexId) {
        release_decoder(streamId);
        try {
            StreamDecoder sd = new StreamDecoder();
            sd.externalTexId = externalTexId;

            // Detached SurfaceTexture: created here (Godot main thread), attached
            // to the GL context later from the render thread. The Surface can be
            // produced into before the consumer side is attached.
            sd.surfaceTexture = new SurfaceTexture(false);
            sd.surfaceTexture.setDefaultBufferSize(width, height);
            sd.surface = new Surface(sd.surfaceTexture);

            MediaCodec codec = MediaCodec.createDecoderByType(mime);
            MediaFormat fmt = MediaFormat.createVideoFormat(mime, width, height);
            if (Build.VERSION.SDK_INT >= 30) {
                try {
                    fmt.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
                } catch (Exception ignored) { /* optional */ }
            }
            // Decode straight to the surface (no output ByteBuffers).
            codec.configure(fmt, sd.surface, null, 0);
            codec.start();
            sd.codec = codec;

            streams.put(streamId, sd);
            Log.i(TAG, "Decoder created (surface): stream=" + streamId + " mime=" + mime
                    + " " + width + "x" + height + " texId=" + externalTexId);
            return true;
        } catch (Exception e) {
            Log.w(TAG, "Failed to create surface decoder for " + mime + ": " + e);
            release_decoder(streamId);
            return false;
        }
    }

    /** Submit one encoded access unit. Output frames are released to the surface. */
    @UsedByGodot
    public boolean submit(int streamId, byte[] data) {
        StreamDecoder sd = streams.get(streamId);
        if (sd == null || sd.codec == null || data == null || data.length == 0) return false;
        try {
            int idx = sd.codec.dequeueInputBuffer(10_000);
            if (idx >= 0) {
                ByteBuffer in = sd.codec.getInputBuffer(idx);
                if (in != null) {
                    in.clear();
                    in.put(data);
                    sd.codec.queueInputBuffer(idx, 0, data.length, System.nanoTime() / 1000, 0);
                }
            }
            drainToSurface(sd);
            return idx >= 0;
        } catch (Exception e) {
            Log.w(TAG, "submit failed: " + e);
            return false;
        }
    }

    /**
     * Attach the SurfaceTexture to Godot's GL context. MUST be called on the
     * render thread (via RenderingServer.call_on_render_thread) exactly once,
     * after the ExternalTexture's GL object exists.
     */
    @UsedByGodot
    public void attach_to_render_context(int streamId) {
        StreamDecoder sd = streams.get(streamId);
        if (sd == null || sd.surfaceTexture == null || sd.attached) return;
        try {
            sd.surfaceTexture.attachToGLContext(sd.externalTexId);
            sd.attached = true;
            Log.i(TAG, "SurfaceTexture attached to GL context: stream=" + streamId
                    + " texId=" + sd.externalTexId);
        } catch (Exception e) {
            Log.w(TAG, "attachToGLContext failed: " + e);
        }
    }

    /**
     * Pull the newest decoded frame into the external texture. MUST be called on
     * the render thread each rendered frame (cheap no-op when nothing new).
     */
    @UsedByGodot
    public void update_image(int streamId) {
        StreamDecoder sd = streams.get(streamId);
        if (sd == null || sd.surfaceTexture == null || !sd.attached) return;
        try {
            sd.surfaceTexture.updateTexImage();
            sd.surfaceTexture.getTransformMatrix(sd.transform);
        } catch (Exception e) {
            Log.w(TAG, "updateTexImage failed: " + e);
        }
    }

    /** The SurfaceTexture transform (column-major 4x4) applied to sample UVs. */
    @UsedByGodot
    public float[] get_transform(int streamId) {
        StreamDecoder sd = streams.get(streamId);
        return sd != null ? sd.transform : null;
    }

    @UsedByGodot
    public void release_decoder(int streamId) {
        StreamDecoder sd = streams.remove(streamId);
        if (sd == null) return;
        if (sd.codec != null) {
            try { sd.codec.stop(); } catch (Exception ignored) {}
            try { sd.codec.release(); } catch (Exception ignored) {}
        }
        if (sd.surface != null) {
            try { sd.surface.release(); } catch (Exception ignored) {}
        }
        if (sd.surfaceTexture != null) {
            try { sd.surfaceTexture.release(); } catch (Exception ignored) {}
        }
    }

    // -----------------------------------------------------------------------

    /** Release every ready output buffer to the surface; keep only the newest. */
    private void drainToSurface(StreamDecoder sd) {
        while (true) {
            int out = sd.codec.dequeueOutputBuffer(sd.info, 0);
            if (out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED
                    || out == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) {
                continue;
            }
            if (out < 0) break;
            // render == true → hand the frame to the Surface (SurfaceTexture).
            sd.codec.releaseOutputBuffer(out, true);
        }
    }

    @Override
    public void onMainDestroy() {
        for (Integer id : streams.keySet()) {
            release_decoder(id);
        }
        super.onMainDestroy();
    }
}
