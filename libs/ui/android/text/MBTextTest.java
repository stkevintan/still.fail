package dev.mbui;

import android.app.Activity;
import android.app.Instrumentation;
import android.graphics.Bitmap;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;

import java.nio.ByteBuffer;
import java.util.Arrays;

import static android.opengl.GLES30.*;

/**
 * Run as Android instrumentation. Compile this file with MBText.java and a copy
 * of the reference MBText.java renamed to MBTextBefore. The two classes use the
 * same Android font engine and offscreen GL context.
 */
public final class MBTextTest extends Instrumentation {
    static void check(boolean pass, String message) {
        if (!pass) throw new AssertionError(message);
    }

    static void sameShape(String text, int weight, int style, float scale) {
        double[] want = new double[text.length() * 4];
        double[] got = new double[want.length];
        int a = MBTextBefore.shape(text, 17.25, weight, style, want);
        int b = MBText.shape(text, 17.25, weight, style, got);
        check(a == b, "cluster count for " + text);
        for (int i = 0; i < a * 4; i++) {
            if (Double.doubleToRawLongBits(want[i]) != Double.doubleToRawLongBits(got[i])) {
                throw new AssertionError("shape field " + i + " at scale " + scale + " (" + weight + ", " + style
                    + "): " + want[i] + " != " + got[i] + " in " + text.substring(0, Math.min(text.length(), 120)));
            }
        }
        for (int i = 0; i < text.length(); i++) {
            float old = MBTextBefore.adv[i], current = MBText.adv[i];
            if (Float.floatToRawIntBits(old) != Float.floatToRawIntBits(current)) {
                throw new AssertionError("advance at " + i + " for U+" + Integer.toHexString(text.charAt(i))
                    + ": " + old + " != " + current);
            }
        }
    }

    static void shape() {
        String[] samples = {
            "", "flex fi AV To\tEnd", "中文漢字fi漢字、仮名。いろはカタカナ 한글",
            "測字\nfi\t字漢\n\n\t字，Ａ。AV", "中文👩🏽‍💻👪❤️e\u0301\n\tÉ字",
            "中文\tﬃ\r\nالعربية אבג 123 fi", "計測\temoji💡\nEnd",
            "測字前綴我是漢字測字後綴", "測字、漢字！測字：漢字　漢字", "ゔゕカッヷ・한글",
            "完成任务 ✅ 下一步 → 延迟 ≤ 16ms 🎉 汉字缓存命中测试",
            "Apple 的性能测试 foo 中 bar 字 baz 中文测试字 end",
            "pure ASCII line without any Han or tabs 0123456789 AV To fi fl",
            "pure ASCII\twith\ttabs\tand\nnewlines",
            "# flex fi\n## 中文漢字仮名\n\tTo AV Markdown\n".repeat(48),
            "文字版面布局測試包含中文日本語支援漢字的長篇測量".repeat(64)
        };
        for (float scale : new float[]{1f, 2.625f, 1f}) {
            MBText.setScale(scale);
            MBTextBefore.setScale(scale);
            for (int style : new int[]{0, 1, 2, 4, 8, 32, 64}) {
                for (int weight : new int[]{400, 700}) {
                    for (int pass = 0; pass < 2; pass++)
                        for (String text : samples) sameShape(text, weight, style, scale);
                }
            }
        }
        // Verify non-Bidi text with emoji/arrows/math symbols populates and hits isolated Han unitAdv cache.
        MBText.keysSweep();
        MBTextBefore.keysSweep();
        MBText.setScale(2.625f);
        MBTextBefore.setScale(2.625f);
        String mixed = "完成任务 ✅ 下一步 → 延迟 ≤ 16ms 🎉 汉字缓存命中测试";
        double[] mixedOut = new double[mixed.length() * 4];
        MBText.shape(mixed, 17.25, 400, 0, mixedOut);
        MBText.Clusters mixedFont = MBText.clusters(17.25f, 400, 0);
        char sampleHan = '汉';
        float[] hanPage = mixedFont.unitAdv[sampleHan >>> 8];
        check(hanPage != null && !Float.isNaN(hanPage[sampleHan & 255]),
                "non-Bidi mixed emoji/symbol run did not populate isolated Han unitAdv cache");
        sameShape(mixed, 400, 0, 2.625f);
        MBText.setScale(1f);
        MBTextBefore.setScale(1f);
        MBText.facesChanged();
        MBTextBefore.facesChanged();
        for (String text : samples) sameShape(text, 400, 0, 1f);
        MBText.keysSweep();
        MBTextBefore.keysSweep();
        for (String text : samples) sameShape(text, 400, 0, 1f);
        System.out.println("Shape: exact clusters, keys and advances at two densities, cold, warm and after sweep");
    }

    static byte[] pixels(Bitmap bmp, int width, int height) {
        int stride = bmp.getRowBytes();
        int row = width * (bmp.getConfig() == Bitmap.Config.ALPHA_8 ? 1 : 4);
        ByteBuffer src = ByteBuffer.allocate(stride * height);
        bmp.copyPixelsToBuffer(src);
        byte[] dst = new byte[row * height];
        for (int y = 0; y < height; y++) System.arraycopy(src.array(), y * stride, dst, y * row, row);
        return dst;
    }

    static void raster() {
        MBText.Scratch scratch = new MBText.Scratch();
        MBTextBefore.Scratch before = new MBTextBefore.Scratch();
        for (float size : new float[]{21.5f, 112f, 13f}) {
            for (String text : new String[]{"中", "j", "f", "W", "fi", "♥", "👩🏽‍💻", "café", " "}) {
                MBText.Entry e = new MBText.Entry(text, size, 700, 1);
                MBTextBefore.Entry old = new MBTextBefore.Entry(text, size, 700, 1);
                for (float scale : new float[]{1f, 2.625f, 1f}) {
                    for (int phase = 0; phase < MBText.SUB_COUNT; phase++) {
                        float dx = MBText.subDx(phase);
                        MBText.Drawn got = MBText.draw(e, scale, dx, MBText.paint(size * scale, 700, 1),
                            MBText.faces, MBText.faceGen[(e.style >>> 8) & 31], scratch);
                        MBTextBefore.Drawn want = MBTextBefore.draw(old, scale, dx,
                            MBTextBefore.paint(size * scale, 700, 1), MBTextBefore.faces, before);
                        String where = text + " at " + size + " x " + scale + ", phase " + phase;
                        check((got.bytes == null && got.bmp == null) == (want.bmp == null), "empty " + where);
                        if (want.bmp == null) continue;
                        check(got.w == want.bmp.getWidth() && got.h == want.bmp.getHeight(), "size " + where);
                        check(got.x0 == want.x0 && got.y0 == want.y0 && got.color == want.color, "ink " + where);
                        byte[] bytes = got.bytes != null ? got.bytes : pixels(got.bmp, got.w, got.h);
                        check(Arrays.equals(bytes, pixels(want.bmp, got.w, got.h)), "pixels " + where);
                        got.release();
                        want.bmp.recycle();
                    }
                }
            }
        }
        // Verify same Entry across a preview slotGen change invalidates cached GlyphBounds.
        {
            android.graphics.Paint narrow = new android.graphics.Paint(MBText.paint(20f, 400, 0));
            narrow.setTextScaleX(0.5f);
            android.graphics.Paint wide = new android.graphics.Paint(MBText.paint(20f, 400, 0));
            wide.setTextScaleX(2.0f);
            MBText.Entry reused = new MBText.Entry("W", 20f, 400, 0);
            MBText.Entry fresh = new MBText.Entry("W", 20f, 400, 0);
            MBText.Drawn d1 = MBText.draw(reused, 1f, 0f, narrow, MBText.faces, 1, scratch);
            d1.release();
            MBText.Drawn got = MBText.draw(reused, 1f, 0f, wide, MBText.faces, 2, scratch);
            MBText.Drawn want = MBText.draw(fresh, 1f, 0f, wide, MBText.faces, 2, scratch);
            check(got.w == want.w && got.h == want.h && got.x0 == want.x0 && got.y0 == want.y0,
                "slotGen bounds invalidation geometry mismatch");
            check(Arrays.equals(got.bytes, want.bytes), "slotGen bounds invalidation pixels mismatch");
            got.release();
            want.release();
        }
        System.out.println("Raster: exact pixels, offsets and dimensions across all four phases");
    }

    static final int ATLAS_SIZE = 256;

    static void clearAtlas(int texture) {
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
        check(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "atlas framebuffer");
        glClearColor(0, 0, 0, 0);
        glClear(GL_COLOR_BUFFER_BIT);
    }

    static byte[] atlasPixels(int texture) {
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
        ByteBuffer out = ByteBuffer.allocateDirect(ATLAS_SIZE * ATLAS_SIZE * 4);
        glReadPixels(0, 0, ATLAS_SIZE, ATLAS_SIZE, GL_RGBA, GL_UNSIGNED_BYTE, out);
        int error = glGetError();
        check(error == GL_NO_ERROR, "atlas GL error " + error);
        byte[] bytes = new byte[out.capacity()];
        out.get(bytes);
        return bytes;
    }

    static void fillAtlas(boolean before) {
        int x = 3;
        int colourX = 7;
        String[] texts = {"W", "漢", "j", "♥︎", "N", "👩🏽‍💻", "❤️"};
        double[] out = new double[7];
        for (int i = 0; i < texts.length; i++) {
            String text = texts[i];
            int size = i == 4 ? 147 : 19;
            int key = before ? MBTextBefore.textKey(text, size, 400, 0) : MBText.textKey(text, size, 400, 0);
            if (before) MBTextBefore.glyph(key, out);
            else MBText.glyph(key, out);
            int w = (int) out[2];
            check(w > 0, "no ink for " + text);
            boolean colour = out[6] != 0;
            int at = colour ? MBText.COLOUR_U + colourX : i == 0 ? 3 : x;
            int y = colour ? 14 : i == 0 ? 2 : 40;
            if (before) MBTextBefore.glyphPut(key, at, y);
            else MBText.glyphPut(key, at, y);
            if (colour) colourX += w + 1;
            else if (i != 0) x += w + 1;
        }
        if (before) MBTextBefore.flush();
        else MBText.flush();
    }

    static void atlas() {
        EGLDisplay display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        int[] version = new int[2];
        check(EGL14.eglInitialize(display, version, 0, version, 1), "EGL initialize");
        int[] attrs = {EGL14.EGL_RENDERABLE_TYPE, 0x40, EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT, EGL14.EGL_NONE};
        EGLConfig[] configs = new EGLConfig[1];
        check(EGL14.eglChooseConfig(display, attrs, 0, configs, 0, 1, version, 0) && version[0] > 0, "EGL config");
        int[] contextAttrs = {EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE};
        EGLContext context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT, contextAttrs, 0);
        int[] surfaceAttrs = {EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE};
        EGLSurface surface = EGL14.eglCreatePbufferSurface(display, configs[0], surfaceAttrs, 0);
        check(EGL14.eglMakeCurrent(display, surface, surface, context), "EGL context");
        try {
            int[] textures = new int[2];
            glGenTextures(2, textures, 0);
            Native.atlas = textures[0];
            Native.colour = textures[1];
            for (int i = 0; i < textures.length; i++) {
                glBindTexture(GL_TEXTURE_2D, textures[i]);
                glTexStorage2D(GL_TEXTURE_2D, 1, i == 0 ? GL_R8 : GL_RGBA8, ATLAS_SIZE, ATLAS_SIZE);
            }
            int[] framebuffer = new int[1];
            glGenFramebuffers(1, framebuffer, 0);
            glBindFramebuffer(GL_FRAMEBUFFER, framebuffer[0]);
            clearAtlas(Native.atlas);
            clearAtlas(Native.colour);
            fillAtlas(true);
            byte[] grey = atlasPixels(Native.atlas);
            byte[] colour = atlasPixels(Native.colour);
            clearAtlas(Native.atlas);
            clearAtlas(Native.colour);
            fillAtlas(false);
            check(Arrays.equals(grey, atlasPixels(Native.atlas)), "grey atlas pixels");
            check(Arrays.equals(colour, atlasPixels(Native.colour)), "colour atlas pixels");
        } finally {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
            EGL14.eglDestroySurface(display, surface);
            EGL14.eglDestroyContext(display, context);
            EGL14.eglTerminate(display);
        }
        System.out.println("Upload: exact R8 and RGBA atlas bytes, including single glyphs and packed rows");
    }

    static void drop() {
        double[] out = new double[7];
        int key = MBText.textKey("W", 19, 400, 0);
        MBText.glyph(key, out);
        check(MBText.heldBytes != null && MBText.held == null, "expected compact held pixels");
        MBText.glyphPut(key, 0, 0);
        MBText.Placed placed = MBText.placed.get(0);
        MBText.glyph(key, out);
        MBText.reset();
        check(MBText.heldBytes == null && placed.bytes == null && MBText.placed.isEmpty(), "reset releases pixels");
        MBText.Entry e = MBText.entries.get(key);
        int sg = MBText.faceGen[(e.style >>> 8) & 31];
        MBText.Drawn drawn = MBText.draw(e, 1f, 0f, MBText.paint(e.size, e.weight, e.style), MBText.faces, sg, MBText.mine);
        e.drawn[0] = drawn;
        e.have = 1;
        e.askScale = 1f;
        e.askFaces = MBText.faces;
        e.askSlotGen = sg;
        MBText.ahead.aheadCount = 1;
        MBText.glyph(key, out);
        check(MBText.heldBytes == drawn.bytes && e.drawn[0] == null, "take an ahead glyph");
        drawn = MBText.draw(e, 1f, 0f, MBText.paint(e.size, e.weight, e.style), MBText.faces, sg, MBText.mine);
        e.drawn[0] = drawn;
        e.have = 1;
        e.askScale = 1f;
        e.askFaces = MBText.faces;
        e.askSlotGen = sg;
        MBText.ahead.aheadCount = 1;
        MBText.keysStale = true;
        MBText.keysSweep();
        check(MBText.heldBytes == null && drawn.bytes == null && MBText.entries.isEmpty(), "sweep releases pixels");
        System.out.println("Reset and sweep: held, placed and ahead pixel owners release their buffers");
    }

    @Override public void onCreate(Bundle args) {
        super.onCreate(args);
        start();
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            System.out.println("Android API " + Build.VERSION.SDK_INT);
            shape();
            raster();
            atlas();
            drop();
            result.putString("stream", "MBText parity passed");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable failure) {
            result.putString("stream", Log.getStackTraceString(failure));
            finish(Activity.RESULT_CANCELED, result);
        }
    }
}

// The app supplies these adapters. This test supplies a density, two GL textures and a log.
final class Host {
    static final class View {
        float density = 1f;
        int getWidth() { return 1; }
        int getHeight() { return 1; }
    }
    static View view;
    static Activity activity;
    static void log(String text) { System.err.println(text); }
}

final class Native {
    static int atlas, colour;
    static int atlasTexture() { return atlas; }
    static int colourAtlasTexture() { return colour; }
}
