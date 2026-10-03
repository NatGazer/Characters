package app.consistency;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.HapticFeedbackConstants;
import android.view.View;
import android.widget.TextView;

public class MainActivity extends Activity {

    private static final String K_TOTAL = "total_ms";   // committed time
    private static final String K_START = "start_ms";   // wall-clock start of open session, 0 = none

    private SharedPreferences prefs;
    private TimerView timer;
    private TextView session;
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
        timer = (TimerView) findViewById(R.id.timer);
        session = (TextView) findViewById(R.id.session);
        startBtn = findViewById(R.id.start);
        runningRow = findViewById(R.id.running);

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

    /** Updates UI; returns ms until the next visible change, or 0 if idle. */
    private long render() {
        long total = prefs.getLong(K_TOTAL, 0);
        long start = prefs.getLong(K_START, 0);
        boolean live = start != 0;
        long el = live ? Math.max(0, System.currentTimeMillis() - start) : 0;
        long shown = total + el;

        timer.set(shown / 1000, live);
        startBtn.setVisibility(live ? View.GONE : View.VISIBLE);
        runningRow.setVisibility(live ? View.VISIBLE : View.GONE);
        session.setVisibility(live ? View.VISIBLE : View.INVISIBLE);
        if (!live) return 0;

        session.setText("+ " + clock(el / 1000) + "   THIS SESSION");
        long d1 = 1000 - (el % 1000);
        long d2 = 1000 - (shown % 1000);
        return Math.min(d1, d2) + 2;
    }

    private static String clock(long s) {
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
