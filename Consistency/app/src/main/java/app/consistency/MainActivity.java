package app.consistency;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.HapticFeedbackConstants;
import android.view.View;
import android.widget.TextView;

import java.util.Calendar;

public class MainActivity extends Activity {

    private static final String K_TOTAL = "total_ms";   // committed time
    private static final String K_START = "start_ms";   // wall-clock start of open session, 0 = none
    private static final String K_CONVERTED = "legacy_converted";   // TODO(next update): remove

    // Rolling windows, top to bottom, then the overall total.
    private static final int[] STAT_FIELD = { Calendar.DAY_OF_YEAR, Calendar.DAY_OF_YEAR, Calendar.MONTH, Calendar.YEAR, Calendar.YEAR };
    private static final int[] STAT_AMOUNT = { 1, 7, 1, 1, 10 };
    private static final String[] LABELS = { "THIS DAY", "THIS WEEK", "THIS MONTH", "THIS YEAR", "THIS DECADE", "TOTAL" };
    private static final float[] SCALE = { 1f, 0.86f, 0.74f, 0.63f, 0.52f, 0.68f };
    // Same rows plus the goal under the total, when one is set.
    private static final String[] LABELS_GOAL = { "THIS DAY", "THIS WEEK", "THIS MONTH", "THIS YEAR", "THIS DECADE", "TOTAL", "GOAL" };
    private static final float[] SCALE_GOAL = { 1f, 0.86f, 0.74f, 0.63f, 0.52f, 0.68f, 0.5f };

    private SharedPreferences prefs;
    private TextView session;
    private StatsView stats;
    private View startBtn, runningRow;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private boolean resumed;

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            long delay = render();
            if (resumed && delay > 0) handler.postDelayed(this, delay);
        }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        setContentView(R.layout.activity_main);
        prefs = getSharedPreferences("consistency", MODE_PRIVATE);
        stats = (StatsView) findViewById(R.id.stats);
        session = (TextView) findViewById(R.id.session);
        startBtn = findViewById(R.id.start);
        runningRow = findViewById(R.id.running);

        // TODO(next update): remove. Time recorded before the log existed becomes 10 minutes per day.
        if (!prefs.getBoolean(K_CONVERTED, false)) {
            Events.convertLegacyTotal(this, prefs.getLong(K_TOTAL, 0), System.currentTimeMillis());
            prefs.edit().putBoolean(K_CONVERTED, true).apply();
        }

        findViewById(R.id.definitions).setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                startActivity(new Intent(MainActivity.this, DefinitionsActivity.class));
            }
        });

        startBtn.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                buzz(v);
                prefs.edit().putLong(K_START, System.currentTimeMillis()).apply();
                restartTick();
            }
        });

        findViewById(R.id.submit).setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                buzz(v);
                long start = prefs.getLong(K_START, 0);
                if (start == 0) return;
                long el = Math.max(0, System.currentTimeMillis() - start);
                Events.add(MainActivity.this, start, el);
                prefs.edit()
                        .putLong(K_TOTAL, prefs.getLong(K_TOTAL, 0) + el)
                        .putLong(K_START, 0)
                        .apply();
                restartTick();
            }
        });

        findViewById(R.id.cancel).setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                buzz(v);
                new AlertDialog.Builder(MainActivity.this)
                        .setTitle("Discard session?")
                        .setMessage("This session's time will not be added.")
                        .setNegativeButton("Keep going", null)
                        .setPositiveButton("Discard", new DialogInterface.OnClickListener() {
                            @Override public void onClick(DialogInterface d, int w) {
                                prefs.edit().putLong(K_START, 0).apply();
                                restartTick();
                            }
                        })
                        .show();
            }
        });
    }

    @Override protected void onResume() { super.onResume(); resumed = true; restartTick(); }

    @Override protected void onPause() { super.onPause(); resumed = false; handler.removeCallbacks(tick); }

    private void restartTick() {
        handler.removeCallbacks(tick);
        tick.run();
    }

    /** Updates UI; returns ms until the next visible change. */
    private long render() {
        long now = System.currentTimeMillis();
        long total = prefs.getLong(K_TOTAL, 0);
        long start = prefs.getLong(K_START, 0);
        boolean live = start != 0;
        long el = live ? Math.max(0, now - start) : 0;
        long shown = total + el;

        // Windows show "done" over "of expected", expected being the goal scaled to the window.
        String goalText = DefinitionsActivity.goalText(prefs);
        String[] labels = goalText != null ? LABELS_GOAL : LABELS;
        String[] vals = new String[labels.length];
        String[] subs = new String[labels.length];
        boolean[] gold = new boolean[labels.length];
        for (int i = 0; i < STAT_FIELD.length; i++) {
            long ms = Events.sumLast(this, STAT_FIELD[i], STAT_AMOUNT[i], now, start);
            double goal = DefinitionsActivity.goalFor(prefs, now - Events.windowStart(STAT_FIELD[i], STAT_AMOUNT[i], now));
            vals[i] = Fmt.amount(ms);
            if (goal >= 0) subs[i] = "of " + Fmt.amount(goal);
            gold[i] = goal >= 0 && ms >= goal;
        }
        vals[5] = Fmt.elapsed(shown);   // the only clock; no goal, always silver
        if (goalText != null) { vals[6] = goalText; gold[6] = true; }   // always gold
        stats.set(vals, subs, labels, goalText != null ? SCALE_GOAL : SCALE, gold);
        startBtn.setVisibility(live ? View.GONE : View.VISIBLE);
        runningRow.setVisibility(live ? View.VISIBLE : View.GONE);
        session.setVisibility(live ? View.VISIBLE : View.INVISIBLE);
        if (!live) return 1000;   // windows keep sliding while idle

        session.setText("+ " + clock(el / 1000) + "   THIS SESSION");
        long d1 = 1000 - (el % 1000);
        long d2 = 1000 - (shown % 1000);
        return Math.min(d1, d2) + 2;
    }

    static String clock(long s) {
        long h = s / 3600, m = (s / 60) % 60, sec = s % 60;
        StringBuilder sb = new StringBuilder();
        if (h > 0) sb.append(h).append(':').append(m < 10 ? "0" : "");
        sb.append(m).append(':').append(sec < 10 ? "0" : "").append(sec);
        return sb.toString();
    }

    private static void buzz(View v) {
        v.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY);
    }
}
