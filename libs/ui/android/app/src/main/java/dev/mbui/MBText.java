package dev.mbui;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.PorterDuff;
import android.graphics.PorterDuffXfermode;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.icu.text.Bidi;
import android.icu.text.BreakIterator;
import android.opengl.GLES30;
import android.opengl.GLUtils;
import android.os.Build;
import android.text.Layout;
import android.text.StaticLayout;
import android.text.TextPaint;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Text with Android's own engine: grapheme clusters and their advances
 * (with kerning, from Paint.getTextRunAdvances), and each cluster rasterized
 * as it is asked for, put where MoonBit says (its atlas.mbt: what goes where,
 * and what makes room) in an atlas: the words' (their cover, a byte a texel)
 * or colour glyphs' (RGBA). Called on the app's thread
 * only (MBView's), but for the drawing ahead (ahead): the glyphs shaped and not drawn
 * yet, drawn on threads of their own and taken when they are first asked
 * for; what was put in a frame handed over with it (MBView.handOver) and
 * uploaded on the GL thread once, a row of the atlas at a time, before the
 * frame is drawn (upload; flush with both on one thread).
 */
final class MBText {
    static final class Entry extends GlyphsAhead.Slot<Drawn> {
        final String text;
        final float size;
        final int weight;
        final int style;  // 1 italic, 2 the code face
        final boolean mayColour;
        // All phases at a scale and face generation share the same ink bounds.
        volatile GlyphBounds bounds;

        Entry(String text, float size, int weight, int style) {
            this.text = text;
            this.size = size;
            this.weight = weight;
            this.style = style;
            this.mayColour = mayBeColour(text);
        }
    }

    /** The phase-independent bounds. The rectangle is read-only after publication. */
    static final class GlyphBounds {
        final Rect rect = new Rect();
        final float scale;
        final int faces;
        final int slotGen;

        GlyphBounds(Entry e, float scale, int faces, int slotGen, Paint p) {
            this.scale = scale;
            this.faces = faces;
            this.slotGen = slotGen;
            p.getTextBounds(e.text, 0, e.text.length(), rect);
        }
    }

    /**
     * A cluster drawn in white, a pixel round its bounds (none: nothing to draw), at a scale, in the faces as they were,
     * moved right by its phase: where its picture's top left is from the pen (pixels).
     */
    static final class Drawn {
        Bitmap bmp;
        byte[] bytes;
        int w, h;
        int x0, y0;
        int color;
        float scale;
        int faces;

        void release() {
            if (bmp != null) bmp.recycle();
            bmp = null;
            bytes = null;
        }
    }

    /**
     * A glyph key's horizontal quarter-pixel phase (bits 26..27: text.mbt glyph_col_sub) in pixels: how far right of
     * the whole pixel column its quad is put on a glyph at it is drawn (win_text.cpp's sub_dx, the same).
     */
    static final int SUB_COUNT = 4, SUB_ALL = 0x0F;

    static float subDx(int sub) {
        switch (sub) {
            case 1: return 0.25f;
            case 2: return -0.5f;
            case 3: return -0.25f;
            default: return 0f;
        }
    }

    /** A glyph key's phase (its bits 26..27), 0 for a key of none. */
    static int glyphSub(int fullKey) {
        int sub = fullKey >= 0 ? (fullKey >>> 26) & 7 : 0;
        return sub < SUB_COUNT ? sub : 0;
    }

    /** A glyph put in an atlas this frame (colour glyphs' or the words'), its picture to be uploaded there (flush). */
    static final class Placed {
        final Bitmap bmp;
        byte[] bytes;
        final int w, h, x, y;
        final boolean colour;

        Placed(byte[] bytes, Bitmap bmp, int w, int h, int x, int y, boolean colour) {
            this.bytes = bytes;
            this.bmp = bmp;
            this.w = w;
            this.h = h;
            this.x = x;
            this.y = y;
            this.colour = colour;
        }

        void release() {
            if (bmp != null) bmp.recycle();
            bytes = null;
        }
    }

    /** A colour glyph's place across is this far past its place in colour glyphs' atlas (android_host.c MB_ATLAS_COLOR_U). */
    static final int COLOUR_U = 16384;

    /**
     * A font's clusters and their keys: by the cluster, and a cluster of one UTF-16 unit (a letter, a Han ideograph, a
     * mark of the full width: nearly every one) by that unit too, a page of 256 at a time (-1: none yet), its key found
     * with no string made and none hashed.
     */
    static final class Clusters {
        final int slotGen;
        final HashMap<String, Integer> map = new HashMap<>();
        final int[][] units = new int[256][];
        final float[][] unitAdv = new float[256][];
        float advScale;
        int advFaces;

        Clusters(int slotGen) {
            this.slotGen = slotGen;
        }
    }

    // each font's clusters (fontKey: its size, weight and style)
    static final HashMap<Long, Clusters> keys = new HashMap<>();
    static final ArrayList<Entry> entries = new ArrayList<>();
    static final HashMap<Long, Paint> paints = new HashMap<>();
    static long lastPaintKey;
    static Paint lastPaint;
    static long lastClustersKey;
    static Clusters lastClusters;
    static final ArrayList<Placed> placed = new ArrayList<>();
    static int generation;
    // the glyph drawn last (glyph), its picture until it is put in its atlas (glyphPut), and whether it is in colours
    static int heldKey = -1;
    static Bitmap held;
    static byte[] heldBytes;
    static int heldW, heldH;
    static boolean heldColour;
    // moves on as the faces change: what was drawn in them before is drawn again (read by the threads ahead too:
    // typeface)
    static volatile int faces;
    static float[] adv = new float[1024];
    static char[] chars = new char[1024];
    static final BreakIterator graphemes = BreakIterator.getCharacterInstance();

    /**
     * What drawing a glyph takes each time (draw), kept by each thread that draws (the app's: `mine`; each thread ahead
     * its own): a canvas, a small coverage bitmap, and the buffers that read coverage and colour pixels.
     */
    static final class Scratch {
        static final int ALPHA_SIZE = 96;
        final Canvas canvas = new Canvas();
        int[] px = new int[1024];
        Bitmap alphaBmp;
        ByteBuffer alphaBuf;
        int alphaStride;
        Paint clearPaint;

        void initAlpha() {
            Bitmap bmp = Bitmap.createBitmap(ALPHA_SIZE, ALPHA_SIZE, Bitmap.Config.ALPHA_8);
            alphaStride = bmp.getRowBytes();
            alphaBuf = ByteBuffer.allocate(alphaStride * ALPHA_SIZE);
            clearPaint = new Paint();
            clearPaint.setXfermode(new PorterDuffXfermode(PorterDuff.Mode.CLEAR));
            alphaBmp = bmp;
        }
    }

    // (the app's thread's)
    static final Scratch mine = new Scratch();

    /** What was drawn before is gone (a new surface, its atlas empty; the faces or the scale changed): drawn again as it is asked for. */
    static void reset() {
        generation++;
        dropHeld();
        dropPlaced();
    }

    /** A font's key: its size's bits, its weight and its style. */
    static long fontKey(float size, int weight, int style) {
        return ((long) Float.floatToIntBits(size) << 32) | ((long) (weight & 0xFFFF) << 16) | (style & 0xFFFF);
    }

    /** The face of style bits: 2 the monospaced (code) face, 4 the serif one (Noto Serif, its CJK for Han), else the system's. */
    static Typeface face(int style) {
        return (style & 2) != 0 ? Typeface.MONOSPACE : (style & 4) != 0 ? Typeface.SERIF : Typeface.DEFAULT;
    }

    /** The faces given (faceAdd, style.mbt): each a list of font files (a File, or a direct ByteBuffer of one) and the weight each is for (0: variable). */
    static final int FACES = 32;
    static final int FACE_TRY = 7;
    @SuppressWarnings("unchecked")
    static final ArrayList<Object>[] faceFiles = new ArrayList[FACES];
    @SuppressWarnings("unchecked")
    static final ArrayList<Integer>[] faceWeights = new ArrayList[FACES];
    static final boolean[] faceNoLig = new boolean[FACES];
    static final int[] faceGen = new int[FACES];

    /** The face a style is set in: the one it names; else code's, what people wrote's, the app's words' (not the serif face's); 0 none. */
    static int faceId(int style) {
        int f = (style >> 8) & 31;
        if (f > 0) return given(f) ? f : 0;
        if ((style & 2) != 0) return given(3) ? 3 : 0;
        if ((style & 4) != 0) return 0;
        if ((style & 16) != 0 && given(2)) return 2;
        return given(1) ? 1 : 0;
    }

    static boolean given(int f) {
        return faceFiles[f] != null && !faceFiles[f].isEmpty();
    }

    /** A font of a file or its bytes at a weight and slant (a variable one at the weight itself). */
    static android.graphics.fonts.Font font(Object src, int weight, int fileWeight, boolean italic) throws java.io.IOException {
        android.graphics.fonts.Font.Builder b = src instanceof File
            ? new android.graphics.fonts.Font.Builder((File) src)
            : new android.graphics.fonts.Font.Builder(((ByteBuffer) src).duplicate());
        if (fileWeight == 0) b.setFontVariationSettings("'wght' " + weight);
        return b.setWeight(fileWeight == 0 ? weight : fileWeight)
            .setSlant(italic ? android.graphics.fonts.FontStyle.FONT_SLANT_ITALIC : android.graphics.fonts.FontStyle.FONT_SLANT_UPRIGHT)
            .build();
    }

    /** Face `f` at a weight: its file for the nearest weight; what it lacks (Han, emoji) in the system's (null: unreadable). */
    static Typeface faceTypeface(int f, int weight, boolean italic) {
        int best = 0, bestd = Integer.MAX_VALUE;
        for (int i = 0; i < faceWeights[f].size(); i++) {
            int w = faceWeights[f].get(i);
            int d = w == 0 ? 0 : Math.abs(w - weight);
            if (d < bestd) {
                bestd = d;
                best = i;
            }
        }
        try {
            android.graphics.fonts.Font font = font(faceFiles[f].get(best), weight, faceWeights[f].get(best), italic);
            android.graphics.fonts.FontFamily fam = new android.graphics.fonts.FontFamily.Builder(font).build();
            return new Typeface.CustomFallbackBuilder(fam)
                .setStyle(new android.graphics.fonts.FontStyle(weight, italic ? android.graphics.fonts.FontStyle.FONT_SLANT_ITALIC : android.graphics.fonts.FontStyle.FONT_SLANT_UPRIGHT))
                .setSystemFallback((f == 3) ? "monospace" : "sans-serif")
                .build();
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * The style bits a typeface is chosen by (faceId, face, the slant): the face named (0x1F00), code's (2), the serif
     * one (4), what people wrote (16), italic (1). Not letter spacing (8), tabular digits (32) or narrow marks (64),
     * which are the paint's font features, nor the size, the paint's too: fonts of every size and feature share one.
     */
    static final int TYPEFACE_STYLE = 0x1F17;

    /** A typeface's key: the faces' generation, the style bits it is chosen by and its weight. */
    static long typefaceKey(int facesGen, int style, int weight) {
        return ((long) facesGen << 32) | ((long) (style & TYPEFACE_STYLE) << 16) | (weight & 0xFFFF);
    }

    /**
     * Each typeface made (typeface), by typefaceKey, in the faces of now (let go as they change: facesChanged). Read
     * with no lock: a typeface is made once (a font file read and its tables parsed, milliseconds), not for every
     * paint, and the threads ahead making their paints never hold the app's thread up making its own.
     */
    static final ConcurrentHashMap<Long, Typeface> typefaces = new ConcurrentHashMap<>();

    /**
     * The typeface a style is drawn in at a weight: its face given, else the system's (face). On either thread: the
     * faces given are changed on the app's thread, under MBText's lock, which one not made yet is made under (where the
     * faces are as they are now, and kept only in them).
     */
    static Typeface typeface(int style, int weight) {
        Typeface t = typefaces.get(typefaceKey(faces, style, weight));
        return t != null ? t : typefaceMade(style, weight);
    }

    static synchronized Typeface typefaceMade(int style, int weight) {
        long k = typefaceKey(faces, style, weight);
        Typeface t = typefaces.get(k);
        if (t != null) return t;
        int f = faceId(style);
        Typeface given = f > 0 ? faceTypeface(f, weight, (style & 1) != 0) : null;
        t = given != null ? given : Typeface.create(face(style), weight, (style & 1) != 0);
        typefaces.put(k, t);
        return t;
    }

    static synchronized boolean take(int f, Object src, int weight) {
        if (f <= 0 || f >= FACES) return false;
        // one Android can read as a font, or none taken
        try {
            font(src, weight == 0 ? 400 : weight, weight, false);
        } catch (Exception e) {
            return false;
        }
        if (faceFiles[f] == null) {
            faceFiles[f] = new ArrayList<>();
            faceWeights[f] = new ArrayList<>();
        }
        faceFiles[f].add(src);
        faceWeights[f].add(weight);
        faceChanged(f);
        return true;
    }

    static boolean faceAdd(int f, String path, int weight) {
        return take(f, new File(path), weight);
    }

    static boolean faceAddBytes(int f, byte[] data, int weight) {
        ByteBuffer b = ByteBuffer.allocateDirect(data.length);
        b.put(data);
        b.flip();
        return take(f, b, weight);
    }

    static synchronized void faceClear(int f) {
        if (f <= 0 || f >= FACES) return;
        faceNoLig[f] = false;
        if (!given(f)) return;
        faceFiles[f].clear();
        faceWeights[f].clear();
        faceChanged(f);
    }

    static synchronized void faceSetLigatures(int f, boolean on) {
        if (f <= 0 || f >= FACES) return;
        boolean noLig = !on;
        if (faceNoLig[f] == noLig) return;
        faceNoLig[f] = noLig;
        faceChanged(f);
    }

    /**
     * What was measured and drawn before a face changed: forgotten (MoonBit drops its glyphs as the generation moves on).
     * Lock order: {@code MBText.class -> ahead.lock}. Never call {@link #typeface} or {@link #paintIn} while holding
     * {@code ahead.lock}.
     */
    static void faceChanged(int f) {
        paints.clear();
        lastPaint = null;
        typefaces.clear();
        lastClusters = null;
        if (f >= FACE_TRY && f < FACES) {
            faceGen[f]++;
            return;
        }
        faces++;
        ahead.forget(entries);
        reset();
        keysStale = true;
    }

    static void facesChanged() {
        faceChanged(0);
    }

    static Paint paint(float size, int weight, int style) {
        long k = fontKey(size, weight, style);
        Paint p = lastPaint;
        if (p != null && lastPaintKey == k) return p;
        p = paintIn(paints, size, weight, style);
        lastPaintKey = k;
        lastPaint = p;
        return p;
    }

    /** The paint of a font at a size in pixels, kept in `paints` (the app's thread's, or the thread ahead's). */
    static Paint paintIn(HashMap<Long, Paint> paints, float size, int weight, int style) {
        long k = fontKey(size, weight, style);
        Paint p = paints.get(k);
        if (p == null) {
            p = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.SUBPIXEL_TEXT_FLAG);
            p.setTypeface(typeface(style, weight));
            p.setTextSize(size);
            // ligatures as the system draws them: shape() tells MoonBit which clusters a ligature covers; none for
            // words with letter spacing (style & 8), each cluster spaced on its own; digits all one width where
            // style & 32 (style.mbt style_tabular); a CJK face's marks narrow among Latin letters where style & 64
            // (style_proportional)
            StringBuilder fs = new StringBuilder();
            int f = faceId(style);
            if (f > 0 && faceNoLig[f]) fs.append(", 'calt' 0, 'liga' 0, 'clig' 0");
            else if ((style & 8) != 0) fs.append(", 'liga' 0, 'clig' 0");
            if ((style & 32) != 0) fs.append(", 'tnum' 1");
            if ((style & 64) != 0) fs.append(", 'pwid' 1");
            String features = fs.length() > 0 ? fs.substring(2) : "";
            if (!features.isEmpty()) p.setFontFeatureSettings(features);
            p.setColor(Color.WHITE);
            paints.put(k, p);
        }
        return p;
    }

    static int atlasGeneration() {
        keysSweep();
        return generation;
    }

    /** The most glyph keys kept (each a cluster of a size, weight and style ever shaped) before all are forgotten. */
    static final int KEYS_MOST = 65536;
    /** The faces changed since the keys were last forgotten (the app's thread's). */
    static boolean keysStale;

    /**
     * The glyphs' keys and what each is of forgotten (the faces changed, or more than KEYS_MOST of them: a run left
     * open on changing text growing them without end), the generation moved on. Only where MoonBit reads the generation
     * (text.mbt text_arrive, as a frame starts: what it shaped is dropped as it sees it moved; faces.mbt
     * words_forgotten, what it shaped dropped just before), never where it may still draw by a key made before (a face
     * given in a frame); a key past the table draws nothing (glyph). What is asked ahead of the old entries is let go
     * of: what a thread ahead draws of one now it recycles as it is done (`skip`), counted in aheadCount till then.
     */
    static void keysSweep() {
        if (!keysStale && entries.size() <= KEYS_MOST) return;
        keysStale = false;
        ahead.forget(entries);
        keys.clear();
        lastClusters = null;
        entries.clear();
        entries.trimToSize();
        dropHeld();
        generation++;
    }

    /** Pixels a point: text is measured at the size it is drawn in on the screen. */
    static float density() {
        return scale > 0 ? scale : Host.view != null ? Host.view.density : 1;
    }

    /** mbui-render's: the text at a draw list's scale, not the screen's (android_host.c mb_render_init_offscreen). */
    static float scale;

    static void setScale(float s) {
        scale = s;
        ahead.forget(entries);
        reset();
    }

    /** A Han ideograph: what the font Chinese words fall back to is measured by. */
    private static final String HAN = "国";

    static void fontMetrics(double size, int weight, int style, double[] out) {
        // in whole pixels, as android.text.StaticLayout (and so Compose) sets a line by them
        float d = density();
        Paint p = paint((float) size * d, weight, style);
        Paint.FontMetricsInt m = p.getFontMetricsInt();
        out[0] = -m.ascent / d;
        out[1] = m.descent / d;
        out[2] = Math.round(size * 1.42);
        // the font a Han ideograph is drawn in (Noto Sans CJK, taller than the Latin face): a line with Chinese in it is
        // measured by the taller of the two, as StaticLayout's fallback line spacing does
        if (Build.VERSION.SDK_INT >= 34) {
            Paint.FontMetricsInt c = new Paint.FontMetricsInt();
            p.getFontMetricsInt(HAN, 0, HAN.length(), 0, HAN.length(), false, c);
            out[3] = -c.ascent / d;
            out[4] = c.descent / d;
        } else {
            // the text-run getFontMetricsInt is API 34's (below it: NoSuchMethodError, the app aborted as it started);
            // StaticLayout's fallback line spacing gives the taller of the two directly
            StaticLayout l = StaticLayout.Builder.obtain(HAN, 0, HAN.length(), new TextPaint(p), 1 << 20)
                    .setIncludePad(false).setUseLineSpacingFromFallbacks(true).build();
            out[3] = -l.getLineAscent(0) / d;
            out[4] = l.getLineDescent(0) / d;
        }
        // lines set on whole pixels, as StaticLayout sets them
        out[5] = 1;
    }

    static final int SCAN_UNITS = 1;
    static final int SCAN_HAN = 2;
    static final int SCAN_TAB = 4;
    static final int MIN_CACHED_HAN_RUN = 4;

    static int shape(String text, double size, int weight, int style, double[] out) {
        // measured in pixels, as the screen has them (at the size in points the font's hinting rounds each
        // advance to a whole point: a long word came out a few points wider than the system draws it)
        int n = text.length();
        if (n == 0) return 0;
        float d = density();
        float fsize = (float) size;
        Paint p = paint(fsize * d, weight, style);
        if (adv.length < n) adv = new float[n * 2];
        if (MBText.chars.length < n) MBText.chars = new char[n * 2];
        char[] chars = MBText.chars;
        text.getChars(0, n, chars, 0);
        Clusters font = clusters(fsize, weight, style);
        int flags = scanChars(chars, n);
        boolean units = (flags & SCAN_UNITS) != 0;
        // a run at a time in its own direction (shaped left to right, Arabic came out in letters that do not join,
        // wider than the system draws the word); any pure LTR run reuses cached isolated Han advances even when
        // non-unit clusters (emoji, arrows, math symbols) appear elsewhere in the run
        if (!units && Bidi.requiresBidi(chars, 0, n)) {
            Bidi b = new Bidi(chars, 0, null, 0, n, Bidi.DIRECTION_DEFAULT_LEFT_TO_RIGHT);
            for (int r = 0; r < b.getRunCount(); r++) {
                int rs = b.getRunStart(r), rl = b.getRunLimit(r) - rs;
                p.getTextRunAdvances(chars, rs, rl, rs, rl, (b.getRunLevel(r) & 1) != 0, adv, rs);
            }
        } else if ((flags & SCAN_HAN) != 0) {
            measureUnits(p, font, chars, n, d);
        } else {
            p.getTextRunAdvances(chars, 0, n, 0, n, false, adv, 0);
        }
        // tabs to the next stop, as android.text.Layout puts them (every 20 pixels from the line's start)
        if ((flags & SCAN_TAB) != 0) {
            float x = 0;
            for (int i = 0; i < n; i++) {
                if (chars[i] == '\t') adv[i] = (float) Math.floor((x + 20) / 20) * 20 - x;
                x += adv[i];
            }
        }
        for (int i = 0; i < n; i++) adv[i] /= d;
        int cap = out.length / 4;
        if (units) {
            int limit = Math.min(n, cap);
            int prevKey = -1;
            for (int i = 0; i < limit; i++) {
                double a = adv[i];
                char c = chars[i];
                int key;
                if (c == '\n') {
                    a = 0;
                    key = -1;
                } else if (c == ' ' || c == '\t') {
                    key = -1;
                } else if (a == 0 && i > 0 && prevKey != -1) {
                    key = -2;
                } else {
                    key = unitKey(font, c, fsize, weight, style);
                }
                int base = i * 4;
                out[base] = i;
                out[base + 1] = 1;
                out[base + 2] = a;
                out[base + 3] = key;
                prevKey = key;
            }
            return limit;
        }
        // (words whose every unit is a cluster of its own, as ASCII's and nearly all of Chinese, Japanese and Korean
        // are, cut a unit at a time; the rest where ICU's grapheme rules cut them)
        graphemes.setText(text);
        int k = 0;
        int start = graphemes.first();
        for (int end = graphemes.next(); end != BreakIterator.DONE && k < cap;
                start = end, end = graphemes.next()) {
            double a = 0;
            for (int i = start; i < end; i++) a += adv[i];
            char c = chars[start];
            int key;
            if (c == '\n') {
                a = 0;
                key = -1;
            } else if (c == ' ' || c == '\t') {
                key = -1;
            } else if (a == 0 && k > 0 && out[(k - 1) * 4 + 3] != -1) {
                // no advance of its own: the shaper drew it as part of the glyph before it, a ligature ("fl"),
                // whose whole advance Paint puts on its first letter; MoonBit draws the ligature from that one
                // (drawn on its own, "flex" came out "f ɭex")
                key = -2;
            } else if (end - start == 1) {
                key = unitKey(font, c, fsize, weight, style);
            } else {
                key = intern(font.map, text.substring(start, end), fsize, weight, style);
            }
            out[k * 4] = start;
            out[k * 4 + 1] = end - start;
            out[k * 4 + 2] = a;
            out[k * 4 + 3] = key;
            k++;
        }
        return k;
    }

    /** Minikin's layout cache starts a new piece before each Han character. */
    static boolean isHan(char c) {
        return c >= 0x3400 && c <= 0x9FFF;
    }

    /** A Han piece of one unit ends at the end of the run or at the next Minikin boundary. */
    static boolean isolatedHan(char[] text, int i, int n) {
        if (!isHan(text[i])) return false;
        if (i + 1 == n) return true;
        char next = text[i + 1];
        return isHan(next) || next == ' ' || next == 0x3000;
    }

    static boolean isCachedIsolatedHan(Clusters font, char[] text, int i, int n) {
        if (!isolatedHan(text, i, n)) return false;
        char c = text[i];
        float[] page = font.unitAdv[c >>> 8];
        return page != null && !Float.isNaN(page[c & 255]);
    }

    /**
     * Reuse the advances of Han characters that Android shapes alone. Keep each other Minikin
     * piece whole, including kana, Hangul, punctuation, and line feeds. Coalesce short interior
     * cached runs (< MIN_CACHED_HAN_RUN) into surrounding uncached spans so scattered cached Han
     * characters never fragment a single getTextRunAdvances call into many tiny JNI calls.
     */
    static void measureUnits(Paint p, Clusters font, char[] text, int n, float scale) {
        if (font.advScale != scale || font.advFaces != faces) {
            Arrays.fill(font.unitAdv, null);
            font.advScale = scale;
            font.advFaces = faces;
        }
        int start = 0;
        int i = 0;
        while (i < n) {
            if (!isCachedIsolatedHan(font, text, i, n)) {
                i++;
                continue;
            }
            int runStart = i;
            do {
                i++;
            } while (i < n && isCachedIsolatedHan(font, text, i, n));
            if (runStart == start || i == n || i - runStart >= MIN_CACHED_HAN_RUN) {
                if (runStart > start) measureAndRemember(p, font, text, start, runStart, n);
                for (int j = runStart; j < i; j++) {
                    char c = text[j];
                    adv[j] = font.unitAdv[c >>> 8][c & 255];
                }
                start = i;
            }
        }
        if (start < n) measureAndRemember(p, font, text, start, n, n);
    }

    static void measureAndRemember(Paint p, Clusters font, char[] text, int start, int end, int n) {
        int count = end - start;
        if (count == 0) return;
        p.getTextRunAdvances(text, start, count, start, count, false, adv, start);
        for (int i = start; i < end; i++) {
            if (!isolatedHan(text, i, n)) continue;
            char c = text[i];
            int index = c >>> 8;
            float[] page = font.unitAdv[index];
            if (page == null) {
                page = new float[256];
                Arrays.fill(page, Float.NaN);
                font.unitAdv[index] = page;
            }
            page[c & 255] = adv[i];
        }
    }

    /**
     * Single-pass scan of `chars[0..n)`: returns SCAN_UNITS if every unit is an extended grapheme cluster of its own
     * (matching unitClusters), SCAN_HAN if any Han ideograph appears, and SCAN_TAB if any tab appears.
     */
    static int scanChars(char[] chars, int n) {
        int flags = SCAN_UNITS;
        for (int i = 0; i < n; i++) {
            char c = chars[i];
            if (c >= 0x20 && c <= 0x7E) continue;
            if (c < 0x3000) {
                if (c == '\t') {
                    flags |= SCAN_TAB;
                    continue;
                }
                if (c == '\n'
                        || c == 0x00A5 || c == 0x00A7 || c == 0x00B0 || c == 0x00B1
                        || c == 0x00B7 || c == 0x00D7 || c == 0x00F7
                        || c == 0x2013 || c == 0x2014 || (c >= 0x2018 && c <= 0x201D)
                        || c == 0x2022 || c == 0x2026 || c == 0x2030
                        || c == 0x2032 || c == 0x2033 || c == 0x20AC || c == 0x2103) {
                    continue;
                }
                flags &= ~SCAN_UNITS;
                continue;
            }
            if (isHan(c)) {
                flags |= SCAN_HAN;
                continue;
            }
            if (c <= 0x3029 || (c >= 0x3041 && c <= 0x3096) || (c >= 0x30A1 && c <= 0x30FF)
                    || (c >= 0xAC00 && c <= 0xD7A3) || (c >= 0xFF01 && c <= 0xFF60)) {
                continue;
            }
            flags &= ~SCAN_UNITS;
        }
        return flags;
    }

    /**
     * Whether each of `chars[0..n)` is an extended grapheme cluster of its own, whatever is beside it, as ICU's
     * BreakIterator cuts them (shape): only where every unit is a tab, a line feed, printable ASCII, or of CJK's ranges
     * below, none of which a rule joins to the unit before or after it. None of a surrogate, a carriage return, a
     * combining mark (U+0300-036F, U+302A-302F, U+3099-309A), a variation selector, U+200D or U+20E3 is in them; Hangul's
     * syllables (LV, LVT) join only the jamo, which are not.
     */
    static boolean unitClusters(char[] chars, int n) {
        return (scanChars(chars, n) & SCAN_UNITS) != 0;
    }

    /** A font's clusters and their keys. */
    static Clusters clusters(float size, int weight, int style) {
        int slot = (style >>> 8) & 31;
        int gen = faceGen[slot];
        long k = fontKey(size, weight, style);
        Clusters m = lastClusters;
        if (m != null && lastClustersKey == k && m.slotGen == gen) return m;
        m = keys.get(k);
        if (m == null || m.slotGen != gen) {
            m = new Clusters(gen);
            keys.put(k, m);
        }
        lastClustersKey = k;
        lastClusters = m;
        return m;
    }

    /** The key of the cluster of the one unit `c` in `font`, from its page once it has one (as intern gives it). */
    static int unitKey(Clusters font, char c, float size, int weight, int style) {
        int[] page = font.units[c >>> 8];
        if (page == null) {
            page = new int[256];
            Arrays.fill(page, -1);
            font.units[c >>> 8] = page;
        }
        int key = page[c & 255];
        if (key < 0) {
            key = intern(font.map, String.valueOf(c), size, weight, style);
            page[c & 255] = key;
        }
        return key;
    }

    static int intern(HashMap<String, Integer> font, String cluster, float size, int weight, int style) {
        Integer id = font.get(cluster);
        if (id != null) return id;
        entries.add(new Entry(cluster, size, weight, style));
        font.put(cluster, entries.size() - 1);
        return entries.size() - 1;
    }

    /** The key of a piece of text drawn whole (a word of a joining script, a ligature). */
    static int textKey(String text, double size, int weight, int style) {
        return intern(clusters((float) size, weight, style).map, text, (float) size, weight, style);
    }

    /**
     * Whether a cluster drawn in white came out in colours of its own (an emoji's, grey ones too): any pixel of some
     * opacity not white.
     */
    static boolean isColor(Bitmap b, Scratch sc) {
        int w = b.getWidth(), h = b.getHeight(), n = w * h;
        if (sc.px.length < n) sc.px = new int[Math.max(n, sc.px.length * 2)];
        int[] px = sc.px;
        b.getPixels(px, 0, w, 0, 0, w, h);
        for (int i = 0; i < n; i++) {
            int v = px[i];
            int a = v >>> 24, r = (v >> 16) & 255, g = (v >> 8) & 255, bl = v & 255;
            if (a > 64 && Math.min(r, Math.min(g, bl)) < 224) return true;
        }
        return false;
    }

    /**
     * Glyph `fullKey` (its cluster's key and its phase: glyphSub) drawn (ahead, else here), its picture held for
     * glyphPut: in `out` 0, 0 (where it goes is MoonBit's), its size in points (0: nothing to draw), where its top left
     * is from the pen, whether it is in colours of its own. The phases of it not drawn or asked yet asked of the thread
     * ahead, for where its words are moved to next (ui's view_rephase).
     */
    static void glyph(int fullKey, double[] out) {
        for (int i = 0; i < 7; i++) out[i] = 0;
        dropHeld();
        int key = fullKey >= 0 ? fullKey & 0x03FFFFFF : fullKey;
        int sub = glyphSub(fullKey);
        if (key < 0 || key >= entries.size()) return;
        Entry e = entries.get(key);
        float sc = density();
        int sg = faceGen[(e.style >>> 8) & 31];
        Drawn d = ahead.takeDrawn(e, sub, sc, faces, sg);
        if (d == null) d = draw(e, sc, subDx(sub), paint(e.size * sc, e.weight, e.style), faces, sg, mine);
        if (e.queuedScale != sc || e.queuedFaces != faces || e.queuedGen != generation || e.queuedSlotGen != sg) {
            e.subsQueued = 0;
            e.queuedScale = sc;
            e.queuedFaces = faces;
            e.queuedGen = generation;
            e.queuedSlotGen = sg;
        }
        int bit = 1 << sub;
        boolean moved = e.subsQueued != 0 && (e.subsQueued & bit) == 0;
        e.subsQueued |= bit;
        // (warm the other quarter-pixel phases only once this glyph is actually asked at a second phase)
        if (moved) {
            int rest = SUB_ALL & ~e.subsQueued;
            if (rest != 0) aheadOne(e, rest, sc);
        }
        if (d.bytes == null && d.bmp == null) return;
        heldKey = fullKey;
        held = d.bmp;
        heldBytes = d.bytes;
        heldW = d.w;
        heldH = d.h;
        heldColour = d.color != 0;
        out[2] = d.w / sc;
        out[3] = d.h / sc;
        out[4] = d.x0 / sc;
        out[5] = d.y0 / sc;
        out[6] = d.color;
    }

    /**
     * The glyph drawn last put in its atlas, its top left at x, y (a colour glyph's COLOUR_U across past its place in
     * theirs): uploaded with the frame's others (flush).
     */
    static void glyphPut(int key, int x, int y) {
        boolean colour = x >= COLOUR_U;
        if (key != heldKey || (heldBytes == null && held == null) || colour != heldColour) return;
        placed.add(new Placed(heldBytes, held, heldW, heldH, colour ? x - COLOUR_U : x, y, colour));
        held = null;
        heldBytes = null;
        heldKey = -1;
    }

    /** The glyph drawn last, not put in the atlas, let go. */
    static void dropHeld() {
        if (held != null) held.recycle();
        held = null;
        heldBytes = null;
        heldKey = -1;
    }

    /**
     * `e` drawn in white a pixel round its bounds, at `sc` pixels a point with `p` (its font at that size), its ink
     * moved right by `subDx` pixels (its phase) and the bitmap's edges on whole pixels round it so moved, a pixel of
     * room on both sides: on any thread, with that thread's scratch.
     */
    static Drawn draw(Entry e, float sc, float subDx, Paint p, int faces, int slotGen, Scratch scratch) {
        Drawn d = new Drawn();
        d.scale = sc;
        d.faces = faces;
        GlyphBounds bounds = e.bounds;
        if (bounds == null || bounds.scale != sc || bounds.faces != faces || bounds.slotGen != slotGen) {
            bounds = new GlyphBounds(e, sc, faces, slotGen, p);
            e.bounds = bounds;
        }
        Rect b = bounds.rect;
        int pad = 1;
        if (b.width() <= 0 || b.height() <= 0) return d;
        int x0 = (int) Math.floor(b.left + subDx) - pad, x1 = (int) Math.ceil(b.right + subDx) + pad;
        int pw = x1 - x0, ph = b.height() + 2 * pad;
        if (pw > 512 || ph > 512) return d;
        boolean reuseAlpha = !e.mayColour && pw <= Scratch.ALPHA_SIZE && ph <= Scratch.ALPHA_SIZE;
        Bitmap bmp;
        if (reuseAlpha) {
            if (scratch.alphaBmp == null) scratch.initAlpha();
            bmp = scratch.alphaBmp;
        } else {
            bmp = Bitmap.createBitmap(pw, ph, e.mayColour ? Bitmap.Config.ARGB_8888 : Bitmap.Config.ALPHA_8);
        }
        // (a canvas given the bitmap draws as one made for it, its matrix and clip put back; let go of it after, the
        // bitmap the frame's alone)
        Canvas c = scratch.canvas;
        c.setBitmap(bmp);
        try {
            if (reuseAlpha) c.drawRect(0, 0, pw, ph, scratch.clearPaint);
            c.drawText(e.text, -x0 + subDx, pad - b.top, p);
        } finally {
            c.setBitmap(null);
        }
        if (reuseAlpha) {
            ByteBuffer pixels = scratch.alphaBuf;
            pixels.clear();
            bmp.copyPixelsToBuffer(pixels);
            byte[] src = pixels.array();
            d.bytes = new byte[pw * ph];
            for (int y = 0; y < ph; y++) System.arraycopy(src, y * scratch.alphaStride, d.bytes, y * pw, pw);
        } else {
            d.color = e.mayColour && isColor(bmp, scratch) ? 1 : 0;
            d.bmp = bmp;
        }
        d.w = pw;
        d.h = ph;
        d.x0 = x0;
        d.y0 = b.top - pad;
        return d;
    }

    /**
     * Whether a cluster may be drawn in colours of its own (an emoji's): false only where every unit of it is of what
     * no font draws so (letters of Latin, Greek and Cyrillic and their marks, ASCII's, Han, kana, Hangul, the full
     * width's punctuation); a unit of anything else (a symbol, a pair of surrogates, U+FE0F, U+200D, U+20E3, © and ®,
     * 〰 and 〽) says it may.
     */
    static boolean mayBeColour(String s) {
        for (int i = 0, n = s.length(); i < n; i++) {
            char c = s.charAt(i);
            boolean plain = (c >= 0x20 && c <= 0x7E)
                || (c >= 0xA0 && c <= 0x24F && c != 0xA9 && c != 0xAE)
                || (c >= 0x300 && c <= 0x4FF)
                || (c >= 0x2010 && c <= 0x2027)
                || (c >= 0x2030 && c <= 0x2033)
                || c == 0x20AC
                || c == 0x2103
                || (c >= 0x3000 && c <= 0x30FF && c != 0x3030 && c != 0x303D)
                || (c >= 0x3400 && c <= 0x4DBF)
                || (c >= 0x4E00 && c <= 0x9FFF)
                || (c >= 0xAC00 && c <= 0xD7A3)
                || (c >= 0xFF01 && c <= 0xFF5E);
            if (!plain) return true;
        }
        return false;
    }

    /**
     * The glyphs put since the last frame was drawn, into their atlases before this one is: those put one after
     * another on a shelf of one in one upload (side by side, a pixel apart, right of what the shelf had), not one each;
     * one put anywhere else (another shelf, another plot, the other atlas) starts another. The words' atlas takes a
     * glyph's cover alone (drawn in white: its alpha), a byte a texel. The texture bound on the unit active, as it was
     * bound for each glyph before.
     */
    static void flush() {
        upload(placed);
    }

    /** The glyphs `placed` (in the order put) into their atlases, as flush says, and the list let go (GL thread). */
    static void upload(ArrayList<Placed> placed) {
        int n = placed.size();
        if (n == 0) return;
        int bound = -1;
        int i = 0;
        while (i < n) {
            Placed first = placed.get(i);
            int j = i, right = first.x - 1, h = 0;
            while (j < n && placed.get(j).colour == first.colour && placed.get(j).y == first.y
                    && placed.get(j).x == right + 1) {
                Placed g = placed.get(j);
                right = g.x + g.w;
                h = Math.max(h, g.h);
                j++;
            }
            int tex = first.colour ? Native.colourAtlasTexture() : Native.atlasTexture();
            if (tex != bound) {
                GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, tex);
                bound = tex;
            }
            int w = right - first.x;
            if (first.colour) {
                if (j - i == 1) {
                    GLUtils.texSubImage2D(GLES30.GL_TEXTURE_2D, 0, first.x, first.y, first.bmp);
                } else {
                    Bitmap row = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
                    Canvas c = new Canvas(row);
                    for (int k = i; k < j; k++) {
                        Placed g = placed.get(k);
                        c.drawBitmap(g.bmp, g.x - first.x, 0, null);
                    }
                    GLUtils.texSubImage2D(GLES30.GL_TEXTURE_2D, 0, first.x, first.y, row);
                    row.recycle();
                }
            } else {
                GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 1);
                if (j - i == 1 && first.bytes != null) {
                    ByteBuffer one = glyphBuffer(first.bytes.length);
                    one.put(first.bytes);
                    one.flip();
                    GLES30.glTexSubImage2D(GLES30.GL_TEXTURE_2D, 0, first.x, first.y, first.w, first.h,
                            GLES30.GL_RED, GLES30.GL_UNSIGNED_BYTE, one);
                } else if (j - i == 1 && first.bmp.getConfig() == Bitmap.Config.ALPHA_8
                        && first.bmp.getRowBytes() == first.w) {
                    // one glyph drawn as its cover alone: its bytes as they are
                    ByteBuffer one = coverOf(first.bmp);
                    GLES30.glTexSubImage2D(GLES30.GL_TEXTURE_2D, 0, first.x, first.y, first.w, first.h,
                            GLES30.GL_RED, GLES30.GL_UNSIGNED_BYTE, one);
                } else {
                    // each glyph's alpha where it lies in the row, nothing (0) round it
                    if (cover == null || cover.capacity() < w * h) {
                        cover = ByteBuffer.allocateDirect(Math.max(w * h, 1 << 16)).order(ByteOrder.nativeOrder());
                    }
                    cover.clear();
                    for (int b = 0; b < w * h; b += ZEROS.length) {
                        cover.position(b);
                        cover.put(ZEROS, 0, Math.min(ZEROS.length, w * h - b));
                    }
                    for (int k = i; k < j; k++) {
                        Placed g = placed.get(k);
                        int gw = g.w, gh = g.h;
                        int ox = g.x - first.x;
                        if (g.bytes != null) {
                            for (int y = 0; y < gh; y++) {
                                cover.position(y * w + ox);
                                cover.put(g.bytes, y * gw, gw);
                            }
                        } else if (g.bmp.getConfig() == Bitmap.Config.ALPHA_8) {
                            // (its rows as Android keeps them, each maybe longer than the glyph is wide)
                            ByteBuffer src = coverOf(g.bmp);
                            int rb = g.bmp.getRowBytes();
                            for (int y = 0; y < gh; y++) {
                                src.limit(y * rb + gw);
                                src.position(y * rb);
                                cover.position(y * w + ox);
                                cover.put(src);
                            }
                        } else {
                            if (px.length < gw * gh) px = new int[gw * gh * 2];
                            g.bmp.getPixels(px, 0, gw, 0, 0, gw, gh);
                            for (int y = 0; y < gh; y++)
                                for (int x = 0; x < gw; x++) cover.put(y * w + ox + x, (byte) (px[y * gw + x] >>> 24));
                        }
                    }
                    cover.position(0);
                    GLES30.glTexSubImage2D(GLES30.GL_TEXTURE_2D, 0, first.x, first.y, w, h, GLES30.GL_RED,
                            GLES30.GL_UNSIGNED_BYTE, cover);
                }
                GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 4);
            }
            for (int k = i; k < j; k++) placed.get(k).release();
            i = j;
        }
        placed.clear();
    }

    /**
     * A glyph's pixels as they are read (flush), its bytes where it was drawn as its cover alone, and a row's cover as
     * it is uploaded: kept from one to the next.
     */
    static int[] px = new int[4096];
    static ByteBuffer glyphBytes;
    static ByteBuffer cover;
    static final byte[] ZEROS = new byte[4096];

    /** The cleared upload buffer for one glyph. */
    static ByteBuffer glyphBuffer(int n) {
        if (glyphBytes == null || glyphBytes.capacity() < n) {
            glyphBytes = ByteBuffer.allocateDirect(Math.max(n, 1 << 16)).order(ByteOrder.nativeOrder());
        }
        glyphBytes.clear();
        return glyphBytes;
    }

    /** The bytes of `bmp` (ALPHA_8: a byte a pixel, a row getRowBytes long) in glyphBytes, from its start. */
    static ByteBuffer coverOf(Bitmap bmp) {
        ByteBuffer bytes = glyphBuffer(bmp.getRowBytes() * bmp.getHeight());
        bmp.copyPixelsToBuffer(bytes);
        bytes.flip();
        return bytes;
    }

    /** What was put and not uploaded, let go: the atlas is gone (reset). */
    static void dropPlaced() {
        for (Placed g : placed) g.release();
        placed.clear();
    }

    // ---- drawing ahead: the glyphs shaped and not drawn yet (text.mbt glyphs_ahead), on threads of their own ----
    // A phase at a time: each glyph asked by a frame at the phase its key says (bits 26..27: where its line put it,
    // text.mbt laid_ahead; phase 0 for one shaped and not laid out), in askedFirst. Extra phases are queued into
    // askedRest (breadth-first across glyphs) only once a glyph is actually requested at a second distinct phase
    // (sub-pixel horizontal motion), so static and whole-pixel-moving text never rasterizes 3x unused phases. A phase
    // the app's thread asks for is taken if ready, else drawn immediately on the app's thread without blocking on a
    // lower-priority worker thread.

    /** The most glyphs asked for or drawn ahead and not placed yet (the oldest drawn let go past it). */
    static final int AHEAD_MOST = GlyphsAhead.AHEAD_MOST;
    static final GlyphsAhead<Entry, Drawn> ahead =
            new GlyphsAhead<>(Drawn::release, AHEAD_MOST, e -> faceGen[(e.style >>> 8) & 31]);
    // the threads ahead (the app's thread's), started as the first glyph is asked
    static Thread[] aheadThreads;

    /** How many threads draw ahead: up to 2 (the app's thread and the GL thread have theirs). */
    static int aheadThreadCount() {
        return Math.min(2, Math.max(1, Runtime.getRuntime().availableProcessors() / 3));
    }

    /**
     * The glyphs of keys[0..n) (each with the phase to draw first: glyphSub) to draw ahead at that phase (and the
     * remaining phases only if the glyph was already seen at another phase), at the scale and in the faces of now.
     * The app's thread.
     */
    static void ahead(int[] ks, int n) {
        if (ahead.ahead(entries, ks, n, density(), faces, generation)) startAhead();
    }

    /** `e` asked of the threads ahead at the phases of `want`, after every first phase. The app's thread. */
    static void aheadOne(Entry e, int want, float sc) {
        if (ahead.aheadOne(e, want, sc, faces)) startAhead();
    }

    static void startAhead() {
        if (aheadThreads != null) return;
        aheadThreads = new Thread[aheadThreadCount()];
        for (int i = 0; i < aheadThreads.length; i++) {
            Thread t = new Thread(MBText::drawAhead, "mbui glyphs " + i);
            t.setDaemon(true);
            t.start();
            aheadThreads[i] = t;
        }
    }

    /**
     * What was drawn ahead of `e` at phase `sub` at `sc` in the faces of now, taken; null when it was not (asked and not
     * begun: that phase no longer asked, drawn here). The app's thread.
     */
    static Drawn drawnAhead(Entry e, int sub, float sc) {
        return ahead.takeDrawn(e, sub, sc, faces, faceGen[(e.style >>> 8) & 31]);
    }

    /**
     * A thread ahead: a phase of a glyph at a time taken, every first phase asked before any other, and drawn with its
     * own paints and scratch, as the app's thread would draw it.
     */
    static void drawAhead() {
        // Nice 0 keeps these threads in top-app, below the logic and GL threads. It lets the first
        // batch compete with other normal-priority work between layout and paint.
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_DEFAULT);
        HashMap<Long, Paint> paints = new HashMap<>();
        int paintsFaces = -1;
        int[] paintsSlotGen = new int[FACES];
        Scratch scratch = new Scratch();
        while (true) {
            GlyphsAhead.Claim<Entry> c;
            synchronized (ahead.lock) {
                while ((c = ahead.claimNext()) == null) {
                    try {
                        ahead.lock.wait();
                    } catch (InterruptedException x) {
                        return;
                    }
                }
            }
            Entry e = c.slot;
            int s = Integer.numberOfTrailingZeros(c.bit);
            Drawn d = null;
            try {
                int slot = (e.style >>> 8) & 31;
                if (c.faces != paintsFaces) {
                    paints.clear();
                    Arrays.fill(paintsSlotGen, -1);
                    paintsFaces = c.faces;
                    paintsSlotGen[slot] = c.slotGen;
                } else if (c.slotGen != paintsSlotGen[slot]) {
                    paints.clear();
                    paintsSlotGen[slot] = c.slotGen;
                }
                d = draw(e, c.scale, subDx(s), paintIn(paints, e.size * c.scale, e.weight, e.style), c.faces, c.slotGen, scratch);
            } catch (Throwable x) {
                // (out of memory for its picture, as much as anything: let be, drawn on the app's thread when it is asked
                // for; never left drawing for that thread to wait on)
                Host.log("glyph ahead: " + x);
            }
            ahead.finish(c, d);
        }
    }

    // ---- the platform's own text drawing (textref_native.mbt, for src/textdiff) ----
    // A line drawn as an app's text is (StaticLayout, as Compose's Text and TextView draw it, with the default font
    // features) into a bitmap at the places mbui draws it; and the window's own picture, read back from GL right after
    // the next frame is drawn. PNGs in the app's files/textdiff.

    static Bitmap refBitmap;
    static Canvas refCanvas;
    static float refScale;
    static String frameName;

    static File refFile(String name) {
        File d = new File(Host.activity.getFilesDir(), "textdiff");
        d.mkdirs();
        return new File(d, name + ".png");
    }

    static boolean save(Bitmap b, String name) {
        try (FileOutputStream o = new FileOutputStream(refFile(name))) {
            return b.compress(Bitmap.CompressFormat.PNG, 100, o);
        } catch (Exception e) {
            Host.log("textdiff: " + name + ": " + e);
            return false;
        }
    }

    static void refBegin(double w, double h, double scale, int bg) {
        refScale = (float) scale;
        refBitmap = Bitmap.createBitmap((int) Math.round(w * scale), (int) Math.round(h * scale), Bitmap.Config.ARGB_8888);
        refCanvas = new Canvas(refBitmap);
        refCanvas.drawColor(0xFF000000 | bg);
    }

    static void refText(String text, double size, int weight, int style, double x, double base, int color, double[] out) {
        for (int i = 0; i < 5; i++) out[i] = 0;
        if (refCanvas == null) return;
        float d = refScale;
        TextPaint p = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        p.setTypeface(typeface(style, weight));
        p.setTextSize((float) size * d);
        p.setColor(0xFF000000 | color);
        StaticLayout l = StaticLayout.Builder.obtain(text, 0, text.length(), p, 1 << 20)
                .setIncludePad(false).setAlignment(Layout.Alignment.ALIGN_NORMAL).build();
        // the line's left edge at x (a right-to-left paragraph is laid out against the right of its width)
        float left = l.getLineLeft(0);
        refCanvas.save();
        refCanvas.translate((float) x * d - left, (float) base * d - l.getLineBaseline(0));
        l.draw(refCanvas);
        refCanvas.restore();
        out[0] = l.getLineWidth(0) / d;
        Rect b = new Rect();
        p.getTextBounds(text, 0, text.length(), b);
        out[1] = b.left / d;
        out[2] = b.top / d;
        out[3] = b.right / d;
        out[4] = b.bottom / d;
    }

    static boolean refEnd(String name) {
        if (refBitmap == null) return false;
        boolean ok = save(refBitmap, name);
        refBitmap.recycle();
        refBitmap = null;
        refCanvas = null;
        return ok;
    }

    static boolean refFrame(String name) {
        frameName = name;
        return true;
    }

    /** The picture asked of the frame being made (refFrame), taken with it as it is handed over (the app's thread). */
    static String takeFrameName() {
        String name = frameName;
        frameName = null;
        return name;
    }

    /** After each frame is drawn, with both on the GL thread: the picture asked for (refFrame), before it is shown. */
    static void frameDrawn() {
        String name = takeFrameName();
        if (name != null) frameDrawn(name);
    }

    /** After a frame is drawn, on the GL thread: the picture of it asked for (refFrame), before it is shown. */
    static void frameDrawn(String name) {
        int w = Host.view.getWidth(), h = Host.view.getHeight();
        ByteBuffer buf = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder());
        GLES30.glReadPixels(0, 0, w, h, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, buf);
        Bitmap up = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        up.copyPixelsFromBuffer(buf);
        // GL's rows go up from the bottom
        android.graphics.Matrix m = new android.graphics.Matrix();
        m.preScale(1, -1);
        Bitmap b = Bitmap.createBitmap(up, 0, 0, w, h, m, false);
        save(b, name);
        up.recycle();
        b.recycle();
    }
}
