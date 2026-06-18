package com.immersive2.decoder;

import android.graphics.Rect;
import android.media.Image;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.os.Build;
import android.util.Log;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.UsedByGodot;

import java.nio.ByteBuffer;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Godot Android plugin that exposes hardware video decoding (H.264 / HEVC /
 * AV1) through Android MediaCodec for the Immersive-2 VR client.
 *
 * One decoder instance per stream id. Input is an elementary stream access
 * unit per submit() call (Annex-B for H.264/HEVC, OBUs for AV1 — exactly what
 * the Immersive-2 host produces). Output frames are returned as tightly
 * packed NV12 (width*height luma + width*height/2 interleaved UV), which the
 * client's screen shader renders directly.
 */
public class Im2VideoDecoder extends GodotPlugin {

    private static final String TAG = "Im2VideoDecoder";

    private static class StreamDecoder {
        MediaCodec codec;
        final MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        final Object frameLock = new Object();
        byte[] lastFrame;       // packed NV12, null when consumed
        int frameWidth;
        int frameHeight;
        int submitCount;        // diagnostics
        int outputCount;        // diagnostics
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

    private final ConcurrentHashMap<Integer, StreamDecoder> streams =
            new ConcurrentHashMap<>();

    public Im2VideoDecoder(Godot godot) {
        super(godot);
    }

    @Override
    public String getPluginName() {
        return "Im2VideoDecoder";
    }

    /** Create a decoder for the stream. mime: video/avc, video/hevc, video/av01. */
    @UsedByGodot
    public boolean create(int streamId, String mime, int width, int height) {
        release_decoder(streamId);
        try {
            MediaCodec codec = MediaCodec.createDecoderByType(mime);
            MediaFormat fmt = MediaFormat.createVideoFormat(mime, width, height);
            fmt.setInteger(MediaFormat.KEY_COLOR_FORMAT,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible);
            if (Build.VERSION.SDK_INT >= 30) {
                try {
                    fmt.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
                } catch (Exception ignored) { /* optional feature */ }
            }
            codec.configure(fmt, null, null, 0);
            codec.start();

            StreamDecoder sd = new StreamDecoder();
            sd.codec = codec;
            sd.frameWidth = width;
            sd.frameHeight = height;
            streams.put(streamId, sd);
            Log.i(TAG, "Decoder created: stream=" + streamId + " mime=" + mime
                    + " " + width + "x" + height);
            return true;
        } catch (Exception e) {
            Log.w(TAG, "Failed to create decoder for " + mime + ": " + e);
            return false;
        }
    }

    /** Submit one encoded access unit; also drains any ready output frames. */
    @UsedByGodot
    public boolean submit(int streamId, byte[] data) {
        StreamDecoder sd = streams.get(streamId);
        if (sd == null || data == null || data.length == 0) return false;
        try {
            if (sd.submitCount < 12) {
                Log.i(TAG, "submit AU #" + sd.submitCount + " size=" + data.length
                        + " nals=" + nalTypes(data));
            }
            sd.submitCount++;
            int idx = sd.codec.dequeueInputBuffer(10_000);
            if (idx >= 0) {
                ByteBuffer in = sd.codec.getInputBuffer(idx);
                if (in != null) {
                    in.clear();
                    in.put(data);
                    sd.codec.queueInputBuffer(idx, 0, data.length,
                            System.nanoTime() / 1000, 0);
                }
            }
            drain(sd);
            return idx >= 0;
        } catch (Exception e) {
            Log.w(TAG, "submit failed: " + e);
            return false;
        }
    }

    /**
     * Latest decoded frame as packed NV12, or an empty array if no new frame
     * arrived since the last call.
     */
    @UsedByGodot
    public byte[] get_frame(int streamId) {
        StreamDecoder sd = streams.get(streamId);
        if (sd == null) return new byte[0];
        try {
            drain(sd);
        } catch (Exception e) {
            Log.w(TAG, "drain failed: " + e);
        }
        synchronized (sd.frameLock) {
            if (sd.lastFrame == null) return new byte[0];
            byte[] out = sd.lastFrame;
            sd.lastFrame = null;
            return out;
        }
    }

    @UsedByGodot
    public int get_frame_width(int streamId) {
        StreamDecoder sd = streams.get(streamId);
        return sd != null ? sd.frameWidth : 0;
    }

    @UsedByGodot
    public int get_frame_height(int streamId) {
        StreamDecoder sd = streams.get(streamId);
        return sd != null ? sd.frameHeight : 0;
    }

    @UsedByGodot
    public void release_decoder(int streamId) {
        StreamDecoder sd = streams.remove(streamId);
        if (sd == null) return;
        try {
            sd.codec.stop();
        } catch (Exception ignored) {}
        try {
            sd.codec.release();
        } catch (Exception ignored) {}
    }

    // -----------------------------------------------------------------------

    /** Pull all ready output frames; keep only the newest (low latency). */
    private void drain(StreamDecoder sd) {
        while (true) {
            int out = sd.codec.dequeueOutputBuffer(sd.info, 0);
            if (out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED
                    || out == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) {
                continue;
            }
            if (out < 0) break;

            try {
                Image img = sd.codec.getOutputImage(out);
                if (img != null) {
                    byte[] nv12 = imageToNV12(img, sd);
                    synchronized (sd.frameLock) {
                        sd.lastFrame = nv12;
                    }
                    sd.outputCount++;
                    if (sd.outputCount <= 5 || sd.outputCount % 60 == 0) {
                        Log.i(TAG, "decoder output frame #" + sd.outputCount
                                + " " + sd.frameWidth + "x" + sd.frameHeight
                                + " bytes=" + nv12.length);
                    }
                    img.close();
                }
            } catch (Exception e) {
                Log.w(TAG, "output conversion failed: " + e);
            } finally {
                sd.codec.releaseOutputBuffer(out, false);
            }
        }
    }

    /**
     * Convert a flexible YUV_420_888 Image to tightly packed NV12, honouring
     * row/pixel strides and the crop rectangle.
     */
    private static byte[] imageToNV12(Image img, StreamDecoder sd) {
        Rect crop = img.getCropRect();
        int w = crop.width() & ~1;
        int h = crop.height() & ~1;
        sd.frameWidth = w;
        sd.frameHeight = h;

        byte[] out = new byte[w * h * 3 / 2];

        // --- Y plane ---
        Image.Plane yPlane = img.getPlanes()[0];
        ByteBuffer yBuf = yPlane.getBuffer();
        int yRowStride = yPlane.getRowStride();
        int yPixStride = yPlane.getPixelStride();  // normally 1
        int dst = 0;
        byte[] row = new byte[yRowStride];
        for (int r = 0; r < h; r++) {
            int base = (crop.top + r) * yRowStride + crop.left * yPixStride;
            yBuf.position(base);
            if (yPixStride == 1) {
                yBuf.get(out, dst, w);
                dst += w;
            } else {
                int n = Math.min(yRowStride - (crop.left * yPixStride), w * yPixStride);
                yBuf.get(row, 0, n);
                for (int c = 0; c < w; c++) out[dst++] = row[c * yPixStride];
            }
        }

        // --- Chroma planes → interleaved UV (NV12) ---
        Image.Plane uPlane = img.getPlanes()[1];
        Image.Plane vPlane = img.getPlanes()[2];
        ByteBuffer uBuf = uPlane.getBuffer();
        ByteBuffer vBuf = vPlane.getBuffer();
        int uRowStride = uPlane.getRowStride();
        int uPixStride = uPlane.getPixelStride();
        int vRowStride = vPlane.getRowStride();
        int vPixStride = vPlane.getPixelStride();

        int cw = w / 2, ch = h / 2;
        int cropX = crop.left / 2, cropY = crop.top / 2;
        byte[] uRow = new byte[uRowStride];
        byte[] vRow = new byte[vRowStride];
        for (int r = 0; r < ch; r++) {
            int ubase = (cropY + r) * uRowStride + cropX * uPixStride;
            int vbase = (cropY + r) * vRowStride + cropX * vPixStride;
            int un = Math.min(uBuf.limit() - ubase, cw * uPixStride);
            int vn = Math.min(vBuf.limit() - vbase, cw * vPixStride);
            uBuf.position(ubase);
            uBuf.get(uRow, 0, Math.max(0, un));
            vBuf.position(vbase);
            vBuf.get(vRow, 0, Math.max(0, vn));
            for (int c = 0; c < cw; c++) {
                int ui = c * uPixStride;
                int vi = c * vPixStride;
                out[dst++] = ui < un ? uRow[ui] : 0;
                out[dst++] = vi < vn ? vRow[vi] : 0;
            }
        }
        return out;
    }

    @Override
    public void onMainDestroy() {
        for (Integer id : streams.keySet()) {
            release_decoder(id);
        }
        super.onMainDestroy();
    }
}
