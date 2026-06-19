package com.immersive2.decoder;

import android.graphics.SurfaceTexture;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.opengl.GLES11Ext;
import android.opengl.GLES30;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.util.Log;
import android.view.Surface;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.UsedByGodot;

import java.nio.ByteBuffer;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Godot Android plugin that exposes hardware video decoding (H.264 / HEVC /
 * AV1) through Android MediaCodec for the Immersive-2 VR client.
 *
 * Zero-copy path: MediaCodec decodes directly into a Surface backed by a
 * SurfaceTexture (GL_TEXTURE_EXTERNAL_OES). No CPU readback, no YUV unpacking.
 *
 * Lifecycle (must be called from Godot's render thread):
 *   create_with_surface(streamId, mime, w, h) → glTexName (>0 on success)
 *   submit(streamId, data)                     → called from any thread
 *   update_tex_image(streamId)                 → called from render thread each frame
 *   get_transform_matrix(streamId)             → float[16] column-major
 *   flush_decoder(streamId)                    → on UDP loss / seek
 *   release_decoder(streamId)                  → cleanup
 */
public class Im2VideoDecoder extends GodotPlugin {

    private static final String TAG = "Im2VideoDecoder";

    // -----------------------------------------------------------------------
    // Inner state
    // -----------------------------------------------------------------------

    private static class StreamDecoder {
        MediaCodec codec;
        final MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();

        // Surface path (zero-copy)
        SurfaceTexture surfaceTexture;
        Surface surface;
        int glTexName;
        volatile boolean frameAvailable = false;
        float[] transformMatrix = new float[16];
        long startTimeNs;
        // Dedicated thread for onFrameAvailableListener callbacks — avoids
        // dependency on the Android UI thread, which is blocked by the XR event
        // loop on PicoOS and never processes main-Looper messages in time.
        HandlerThread callbackThread;

        // Diagnostics
        int frameWidth;
        int frameHeight;
        int submitCount;
        int outputCount;
        int consumeCount;
    }

    private final ConcurrentHashMap<Integer, StreamDecoder> streams =
            new ConcurrentHashMap<>();

    // -----------------------------------------------------------------------
    // Constructor / plugin name
    // -----------------------------------------------------------------------

    public Im2VideoDecoder(Godot godot) {
        super(godot);
    }

    @Override
    public String getPluginName() {
        return "Im2VideoDecoder";
    }

    // -----------------------------------------------------------------------
    // Public API — called from GDScript
    // -----------------------------------------------------------------------

    /**
     * Create a zero-copy Surface decoder for the given stream using Godot's
     * own GL texture (obtained from ExternalTexture.get_external_buffer_id()).
     *
     * MUST be called from Godot's render thread (call_on_render_thread) because
     * GL operations require an active GL context.
     *
     * The caller (GDScript) creates an ExternalTexture, obtains its GL texture ID
     * via get_external_buffer_id(), and passes it here. MediaCodec then decodes
     * directly into that texture, which Godot already knows how to render.
     * This avoids the broken set_external_buffer_id() path where Godot cannot
     * see a GL texture it did not create itself.
     *
     * @param streamId  arbitrary integer key used to identify this stream
     * @param glTexId   Godot's GL_TEXTURE_EXTERNAL_OES texture name (from ExternalTexture)
     * @param mime      "video/avc", "video/hevc", or "video/av01"
     * @param width     expected frame width in pixels
     * @param height    expected frame height in pixels
     * @return          true on success, false on failure
     */
    @UsedByGodot
    public boolean create_with_surface(int streamId, int glTexId, String mime, int width, int height) {
        release_decoder(streamId);
        try {
            if (glTexId <= 0) {
                Log.w(TAG, "create_with_surface: invalid glTexId=" + glTexId + " for stream=" + streamId);
                return false;
            }

            // Set OES sampling parameters on Godot's texture. Godot creates the
            // texture but does not configure these; we must set them before
            // SurfaceTexture attaches to it.
            GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, glTexId);
            GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                    GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE);
            GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                    GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE);
            GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                    GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR);
            GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                    GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR);
            GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0);

            // --- SurfaceTexture + Surface using Godot's GL texture ---
            SurfaceTexture st = new SurfaceTexture(glTexId);
            st.setDefaultBufferSize(width, height);
            Surface surf = new Surface(st);

            // --- MediaCodec ---
            MediaCodec codec = MediaCodec.createDecoderByType(mime);
            // No KEY_COLOR_FORMAT — the driver chooses the optimal internal format
            // when a Surface output is provided.
            MediaFormat fmt = MediaFormat.createVideoFormat(mime, width, height);
            if (Build.VERSION.SDK_INT >= 30) {
                try {
                    fmt.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
                } catch (Exception ignored) { /* optional feature, not fatal */ }
            }
            codec.configure(fmt, surf, null, 0);
            codec.start();

            // --- StreamDecoder bookkeeping ---
            StreamDecoder sd = new StreamDecoder();
            sd.codec = codec;
            sd.surfaceTexture = st;
            sd.surface = surf;
            sd.glTexName = glTexId;
            sd.frameWidth = width;
            sd.frameHeight = height;
            sd.startTimeNs = System.nanoTime();

            // Use a dedicated HandlerThread rather than the Android UI thread (main
            // Looper). On PicoOS the UI thread is occupied by the OpenXR event loop
            // and processes very few messages per second, causing onFrameAvailable
            // callbacks to arrive tens of frames late — or never — making
            // frameAvailable permanently false and the decoded texture appear black.
            HandlerThread ht = new HandlerThread("Im2FrameAvail-" + streamId);
            ht.start();
            sd.callbackThread = ht;
            st.setOnFrameAvailableListener(t -> {
                if (!sd.frameAvailable) {
                    Log.d(TAG, "onFrameAvailable stream=" + streamId);
                }
                sd.frameAvailable = true;
            }, new Handler(ht.getLooper()));

            streams.put(streamId, sd);
            Log.i(TAG, "Surface decoder created: stream=" + streamId
                    + " mime=" + mime + " " + width + "x" + height
                    + " glTex=" + glTexId + " (Godot-owned)");
            return true;

        } catch (Exception e) {
            Log.w(TAG, "create_with_surface failed for stream=" + streamId + ": " + e);
            return false;
        }
    }

    /**
     * Submit one encoded access unit to the decoder and drain any ready output.
     *
     * Can be called from any thread. Elementary stream format: Annex-B for
     * H.264/HEVC, OBUs for AV1 — exactly what the Immersive-2 host produces.
     *
     * @return true if the buffer was successfully queued
     */
    @UsedByGodot
    public boolean submit(int streamId, byte[] data) {
        StreamDecoder sd = streams.get(streamId);
        if (sd == null || data == null || data.length == 0) return false;
        try {
            if (sd.submitCount < 12) {
                Log.i(TAG, "submit AU #" + sd.submitCount
                        + " size=" + data.length + " nals=" + nalTypes(data));
            }
            sd.submitCount++;

            long pts = (System.nanoTime() - sd.startTimeNs) / 1000; // µs

            int idx = sd.codec.dequeueInputBuffer(10_000);
            if (idx >= 0) {
                ByteBuffer in = sd.codec.getInputBuffer(idx);
                if (in != null) {
                    if (data.length <= in.capacity()) {
                        in.clear();
                        in.put(data);
                        sd.codec.queueInputBuffer(idx, 0, data.length, pts, 0);
                    } else {
                        Log.e(TAG, "Input buffer too small for stream=" + streamId
                                + " need=" + data.length + " cap=" + in.capacity()
                                + " (dropping frame to avoid crash)");
                        sd.codec.queueInputBuffer(idx, 0, 0, pts, 0);
                    }
                }
            }
            drain(sd);
            return idx >= 0;
        } catch (Exception e) {
            Log.w(TAG, "submit failed for stream=" + streamId + ": " + e);
            return false;
        }
    }

    /**
     * Latch the latest decoded frame into the OES texture.
     *
     * MUST be called from Godot's render thread (call_on_render_thread).
     *
     * @return true if a new frame was available and latched; false otherwise
     */
    @UsedByGodot
    public boolean update_tex_image(int streamId) {
        StreamDecoder sd = streams.get(streamId);
        if (sd == null || !sd.frameAvailable) return false;
        try {
            sd.frameAvailable = false;
            sd.surfaceTexture.updateTexImage();
            sd.surfaceTexture.getTransformMatrix(sd.transformMatrix);
            sd.consumeCount++;
            if (sd.consumeCount <= 5 || sd.consumeCount % 60 == 0) {
                Log.i(TAG, "consumed frame #" + sd.consumeCount + " stream=" + streamId);
            }
            return true;
        } catch (Exception e) {
            Log.w(TAG, "update_tex_image failed for stream=" + streamId + ": " + e);
            return false;
        }
    }

    /**
     * Return the SurfaceTexture transform matrix (float[16], column-major OpenGL).
     * Must be applied to texture coordinates in the shader to correctly map the
     * frame (handles flip, crop, and rotation encoded by the driver).
     *
     * Returns an identity matrix if the decoder does not exist.
     */
    @UsedByGodot
    public float[] get_transform_matrix(int streamId) {
        StreamDecoder sd = streams.get(streamId);
        if (sd == null) {
            // Identity matrix
            return new float[]{
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1
            };
        }
        return sd.transformMatrix;
    }

    /**
     * Flush the decoder's internal buffers without releasing it.
     *
     * Use after a UDP packet loss burst that causes the decoder to stall, or
     * before re-sending an IDR/keyframe. The decoder remains configured and
     * ready to accept a new keyframe immediately after this call.
     */
    @UsedByGodot
    public void flush_decoder(int streamId) {
        StreamDecoder sd = streams.get(streamId);
        if (sd == null) return;
        try {
            sd.codec.flush();
            sd.frameAvailable = false;
            Log.i(TAG, "flush_decoder: stream=" + streamId);
        } catch (Exception e) {
            Log.w(TAG, "flush_decoder failed for stream=" + streamId + ": " + e);
        }
    }

    /**
     * Stop and release the decoder for the given stream.
     *
     * Safe to call even if the stream was never created.
     */
    @UsedByGodot
    public void release_decoder(int streamId) {
        StreamDecoder sd = streams.remove(streamId);
        if (sd == null) return;
        try { sd.codec.stop(); }    catch (Exception ignored) {}
        try { sd.codec.release(); } catch (Exception ignored) {}
        try {
            if (sd.surface != null) sd.surface.release();
        } catch (Exception ignored) {}
        try {
            if (sd.surfaceTexture != null) sd.surfaceTexture.release();
        } catch (Exception ignored) {}
        if (sd.callbackThread != null) {
            sd.callbackThread.quitSafely();
            sd.callbackThread = null;
        }
        // The GL texture is Godot-owned (passed in via create_with_surface). Godot's
        // ExternalTexture manages its lifetime; we must not delete it here.
        Log.i(TAG, "release_decoder: stream=" + streamId);
    }

    // -----------------------------------------------------------------------
    // Deprecated — kept so old GDScript callers do not crash during migration
    // -----------------------------------------------------------------------

    /**
     * @deprecated Use {@link #create_with_surface} instead. This CPU-readback
     *             path has been removed; calling it is a no-op that returns false.
     */
    @Deprecated
    @UsedByGodot
    public boolean create(int streamId, String mime, int width, int height) {
        Log.w(TAG, "create() is deprecated — use create_with_surface(). "
                + "Stream " + streamId + " was NOT created.");
        return false;
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    /**
     * Pull all ready output buffers from the codec and release them to the
     * Surface (render=true). MediaCodec then writes the decoded frame into the
     * SurfaceTexture, triggering onFrameAvailableListener.
     */
    private void drain(StreamDecoder sd) {
        while (true) {
            int out = sd.codec.dequeueOutputBuffer(sd.info, 0);
            if (out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED
                    || out == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) {
                continue;
            }
            if (out < 0) break;

            // render=true → MediaCodec pushes the frame to the Surface
            sd.codec.releaseOutputBuffer(out, true);
            sd.outputCount++;
            if (sd.outputCount <= 5 || sd.outputCount % 60 == 0) {
                Log.i(TAG, "decoder output frame #" + sd.outputCount
                        + " " + sd.frameWidth + "x" + sd.frameHeight);
            }
        }
    }

    /** List the H.264 Annex-B NAL unit types present in an access unit (diagnostics). */
    private static String nalTypes(byte[] d) {
        StringBuilder sb = new StringBuilder("[");
        boolean first = true;
        for (int i = 0; i + 4 < d.length; i++) {
            if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) {
                int t = d[i + 3] & 0x1f;
                if (!first) sb.append(',');
                sb.append(t);
                first = false;
                i += 2;
            }
        }
        return sb.append(']').toString();
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    @Override
    public void onMainDestroy() {
        for (Integer id : streams.keySet()) {
            release_decoder(id);
        }
        super.onMainDestroy();
    }
}
