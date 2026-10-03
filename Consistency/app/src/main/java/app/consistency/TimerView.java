package app.consistency;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.util.AttributeSet;
import android.view.View;

/** Big auto-fitting cumulative clock. Shows Y / D / H only when reached. */
public class TimerView extends View {

    private static final float CAP = 0.72f;   // digit height / text size
    private static final float LAB = 0.15f;   // label size / text size
    private static final float LGAP = 0.17f;  // gap digits -> label
    private static final float SEP = 0.10f;   // padding each side of ':'

    private final Paint num = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint lab = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint colon = new Paint(Paint.ANTI_ALIAS_FLAG);

    private final String[] vals = new String[5];
    private final String[] labs = new String[5];
    private final float[] segW = new float[5];
    private int n;
    private long secs = -1;
    private boolean live;

    private float shaderKey = -1;

    public TimerView(Context c, AttributeSet a) {
        super(c, a);
        Typeface digits = Typeface.create("sans-serif-condensed", Typeface.BOLD);
        num.setTypeface(digits);
        num.setTextAlign(Paint.Align.CENTER);
        colon.setTypeface(digits);
        colon.setTextAlign(Paint.Align.CENTER);
        colon.setColor(0x38FFFFFF);
        lab.setTypeface(Typeface.create("sans-serif", Typeface.BOLD));
        lab.setTextAlign(Paint.Align.CENTER);
        lab.setLetterSpacing(0.25f);
        lab.setColor(0x66FFFFFF);
        set(0, false);
    }

    public void set(long s, boolean isLive) {
        if (s == secs && isLive == live) return;
        if (isLive != live) shaderKey = -1;
        secs = s;
        live = isLive;

        long y = s / 31536000L, r = s % 31536000L;
        long d = r / 86400L;  r %= 86400L;
        long h = r / 3600L;   r %= 3600L;
        long m = r / 60L, sec = r % 60L;

        n = 0;
        if (y > 0) add(Long.toString(y), y == 1 ? "YEAR" : "YEARS");
        if (s >= 86400L) add(Long.toString(d), d == 1 ? "DAY" : "DAYS");
        if (s >= 3600L) add(two(h), "HRS");
        add(two(m), "MIN");
        add(two(sec), "SEC");
        invalidate();
    }

    private void add(String v, String l) { vals[n] = v; labs[n] = l; n++; }

    private static String two(long v) { return v < 10 ? "0" + v : Long.toString(v); }

    @Override
    protected void onDraw(Canvas c) {
        int w = getWidth(), h = getHeight();
        if (w == 0 || h == 0) return;

        // Measure at reference size 100, then scale to fit both axes.
        num.setTextSize(100f);
        lab.setTextSize(100f * LAB);
        float gapRef = num.measureText(":") + 2 * SEP * 100f;
        float totalRef = gapRef * (n - 1);
        for (int i = 0; i < n; i++) {
            segW[i] = Math.max(num.measureText(vals[i]), lab.measureText(labs[i]));
            totalRef += segW[i];
        }
        float heightRef = (CAP + LGAP + LAB) * 100f;
        float size = Math.min(100f * w * 0.94f / totalRef, 100f * h * 0.86f / heightRef);
        float k = size / 100f;

        num.setTextSize(size);
        colon.setTextSize(size);
        lab.setTextSize(size * LAB);

        float block = (CAP + LGAP + LAB) * size;
        float base = (h - block) / 2f + CAP * size;
        float labBase = base + LGAP * size + LAB * size * 0.85f;

        if (shaderKey != size * 10000f + base) {
            shaderKey = size * 10000f + base;
            int top = live ? 0xFFFFE6A8 : 0xFFFFFFFF;
            int bot = live ? 0xFFF2A93B : 0xFFB4B9C4;
            num.setShader(new LinearGradient(0, base - CAP * size, 0, base, top, bot, Shader.TileMode.CLAMP));
            if (live) num.setShadowLayer(size * 0.16f, 0, 0, 0x80F2A93B);           // warm glow
            else      num.setShadowLayer(size * 0.07f, 0, size * 0.035f, 0xF0000000); // drop shadow
        }

        float x = (w - (totalRef * k)) / 2f;
        float gap = gapRef * k;
        for (int i = 0; i < n; i++) {
            float sw = segW[i] * k;
            float cx = x + sw / 2f;
            c.drawText(vals[i], cx, base, num);
            c.drawText(labs[i], cx, labBase, lab);
            x += sw;
            if (i < n - 1) {
                c.drawText(":", x + gap / 2f, base - size * 0.04f, colon);
                x += gap;
            }
        }
    }
}
