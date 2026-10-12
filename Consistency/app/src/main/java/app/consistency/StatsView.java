package app.consistency;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.util.AttributeSet;
import android.view.View;

import java.util.Arrays;

/**
 * Stacked rolling totals that fill the available space: each row is a big value with a small
 * label under it, rows shrinking top to bottom, spread evenly over the height.
 */
public class StatsView extends View {

    private static final float CAP = 0.72f;   // digit height / text size
    private static final float SUB = 0.42f;   // "of ..." line size / text size
    private static final float SGAP = 0.16f;  // gap value -> "of ..." line
    private static final float LAB = 0.26f;   // label size / text size
    private static final float LGAP = 0.18f;  // gap above label

    private final Paint num = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint sub = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint lab = new Paint(Paint.ANTI_ALIAS_FLAG);

    private String[] vals = new String[0];
    private String[] subs = new String[0];
    private String[] labels = new String[0];
    private float[] scale = new float[0];
    private boolean[] gold = new boolean[0];

    public StatsView(Context c, AttributeSet a) {
        super(c, a);
        num.setTypeface(Typeface.create("sans-serif-condensed", Typeface.BOLD));
        num.setTextAlign(Paint.Align.CENTER);
        sub.setTypeface(Typeface.create("sans-serif-condensed", Typeface.BOLD));
        sub.setTextAlign(Paint.Align.CENTER);
        lab.setTypeface(Typeface.create("sans-serif", Typeface.BOLD));
        lab.setTextAlign(Paint.Align.CENTER);
        lab.setLetterSpacing(0.25f);
    }

    /**
     * Rows top to bottom: big value, optional smaller line under it (null = none), then the label.
     * scale is each row's size relative to the largest.
     */
    public void set(String[] vals, String[] subs, String[] labels, float[] scale, boolean[] gold) {
        if (Arrays.equals(vals, this.vals) && Arrays.equals(subs, this.subs)
                && Arrays.equals(gold, this.gold) && labels == this.labels) return;
        this.vals = vals.clone();
        this.subs = subs.clone();
        this.labels = labels;
        this.scale = scale;
        this.gold = gold.clone();
        invalidate();
    }

    private float rowHeight(int i) {
        return CAP + (subs[i] != null ? SGAP + SUB * CAP : 0) + LGAP + LAB * CAP;
    }

    @Override
    protected void onDraw(Canvas c) {
        int w = getWidth(), h = getHeight(), n = vals.length;
        if (w == 0 || h == 0 || n == 0) return;

        // Fit at reference size 100: widest line to the width, stacked rows to most of the height.
        num.setTextSize(100f);
        sub.setTextSize(100f * SUB);
        lab.setTextSize(100f * LAB);
        float widest = 0, stack = 0;
        for (int i = 0; i < n; i++) {
            float rw = Math.max(num.measureText(vals[i]), lab.measureText(labels[i]));
            if (subs[i] != null) rw = Math.max(rw, sub.measureText(subs[i]));
            widest = Math.max(widest, rw * scale[i]);
            stack += rowHeight(i) * 100f * scale[i];
        }
        float size = Math.min(100f * w * 0.92f / widest, 100f * h * 0.80f / stack);

        // Remaining height is shared evenly around the rows.
        float gap = (h - stack * size / 100f) / (n + 1);
        float y = gap;
        float cx = w / 2f;
        for (int i = 0; i < n; i++) {
            float s = size * scale[i];
            float base = y + CAP * s;
            num.setTextSize(s);
            sub.setTextSize(s * SUB);
            lab.setTextSize(s * LAB);

            int top = gold[i] ? 0xFFFFE6A8 : 0xFFFFFFFF;
            int bot = gold[i] ? 0xFFF2A93B : 0xFFB4B9C4;
            num.setShader(new LinearGradient(0, base - CAP * s, 0, base, top, bot, Shader.TileMode.CLAMP));
            if (gold[i]) num.setShadowLayer(s * 0.16f, 0, 0, 0x80F2A93B);            // warm glow
            else         num.setShadowLayer(s * 0.07f, 0, s * 0.035f, 0xF0000000);   // drop shadow
            sub.setColor(gold[i] ? 0xE6F2B24C : 0xB3C4C8D0);
            lab.setColor(gold[i] ? 0xB3F2A93B : 0x80FFFFFF);

            c.drawText(vals[i], cx, base, num);
            if (subs[i] != null) {
                base += (SGAP + SUB * CAP) * s;
                c.drawText(subs[i], cx, base, sub);
            }
            c.drawText(labels[i], cx, base + (LGAP + LAB * CAP) * s, lab);
            y += rowHeight(i) * s + gap;
        }
    }
}
