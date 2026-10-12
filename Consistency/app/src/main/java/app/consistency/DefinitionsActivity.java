package app.consistency;

import android.app.Activity;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.BaseAdapter;
import android.widget.EditText;
import android.widget.ListView;
import android.widget.Spinner;
import android.widget.TextView;

import java.text.SimpleDateFormat;
import java.util.Calendar;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/** Goal ("N unit per M unit") and the log of every session. */
public class DefinitionsActivity extends Activity {

    static final int GOLD = 0xFFF0B44C;     // goal reached
    static final int SILVER = 0xFF9A9FA8;   // not reached

    private static final String K_GOAL_N = "goal_n";        // 0 = no goal
    private static final String K_GOAL_UNIT = "goal_unit";
    private static final String K_PER_N = "per_n";
    private static final String K_PER_UNIT = "per_unit";

    private static final String[] UNITS = { "SECONDS", "MINUTES", "HOURS", "DAYS", "WEEKS", "MONTHS", "YEARS" };
    private static final int[] UNIT_FIELD = {
            Calendar.SECOND, Calendar.MINUTE, Calendar.HOUR_OF_DAY, Calendar.DAY_OF_YEAR,
            Calendar.WEEK_OF_YEAR, Calendar.MONTH, Calendar.YEAR };
    // Goal amounts in ms; months and years use their average Gregorian length.
    private static final long[] UNIT_MS = {
            1000L, 60_000L, 3_600_000L, 86_400_000L, 604_800_000L, 2_629_746_000L, 31_556_952_000L };

    private SharedPreferences prefs;
    private EditText goalN, perN;
    private Spinner goalUnit, perUnit;
    private TextView progress;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private boolean resumed;

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            renderProgress();
            if (resumed) handler.postDelayed(this, 1000);
        }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        setContentView(R.layout.activity_definitions);
        prefs = getSharedPreferences("consistency", MODE_PRIVATE);

        ListView log = (ListView) findViewById(R.id.log);
        View header = LayoutInflater.from(this).inflate(R.layout.definitions_header, log, false);
        log.addHeaderView(header, null, false);
        log.setAdapter(new LogAdapter(Events.all(this)));

        goalN = (EditText) header.findViewById(R.id.goal_n);
        perN = (EditText) header.findViewById(R.id.per_n);
        goalUnit = (Spinner) header.findViewById(R.id.goal_unit);
        perUnit = (Spinner) header.findViewById(R.id.per_unit);
        progress = (TextView) header.findViewById(R.id.goal_progress);

        for (Spinner s : new Spinner[] { goalUnit, perUnit }) {
            ArrayAdapter<String> a = new ArrayAdapter<>(this, R.layout.spinner_item, UNITS);
            a.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
            s.setAdapter(a);
        }

        int g = prefs.getInt(K_GOAL_N, 0);
        goalN.setText(g > 0 ? Integer.toString(g) : "");
        perN.setText(Integer.toString(prefs.getInt(K_PER_N, 1)));
        goalUnit.setSelection(prefs.getInt(K_GOAL_UNIT, 1));
        perUnit.setSelection(prefs.getInt(K_PER_UNIT, 3));

        TextWatcher w = new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int a, int b, int c) { }
            @Override public void onTextChanged(CharSequence s, int a, int b, int c) { }
            @Override public void afterTextChanged(Editable e) { save(); }
        };
        goalN.addTextChangedListener(w);
        perN.addTextChangedListener(w);
        AdapterView.OnItemSelectedListener l = new AdapterView.OnItemSelectedListener() {
            @Override public void onItemSelected(AdapterView<?> p, View v, int pos, long id) { save(); }
            @Override public void onNothingSelected(AdapterView<?> p) { }
        };
        goalUnit.setOnItemSelectedListener(l);
        perUnit.setOnItemSelectedListener(l);
    }

    @Override protected void onResume() { super.onResume(); resumed = true; handler.removeCallbacks(tick); tick.run(); }

    @Override protected void onPause() { super.onPause(); resumed = false; handler.removeCallbacks(tick); }

    /** Goal scaled to a window of windowMs (3 min per day -> 21 min per week), or -1 if none is set. */
    static double goalFor(SharedPreferences prefs, long windowMs) {
        int g = prefs.getInt(K_GOAL_N, 0);
        if (g <= 0) return -1;
        double goalMs = g * (double) UNIT_MS[prefs.getInt(K_GOAL_UNIT, 1)];
        double perMs = prefs.getInt(K_PER_N, 1) * (double) UNIT_MS[prefs.getInt(K_PER_UNIT, 3)];
        return goalMs * windowMs / perMs;
    }

    private static int num(EditText e, int dflt) {
        try { return Integer.parseInt(e.getText().toString().trim()); }
        catch (NumberFormatException x) { return dflt; }
    }

    private void save() {
        prefs.edit()
                .putInt(K_GOAL_N, Math.max(0, num(goalN, 0)))
                .putInt(K_GOAL_UNIT, goalUnit.getSelectedItemPosition())
                .putInt(K_PER_N, Math.max(1, num(perN, 1)))
                .putInt(K_PER_UNIT, perUnit.getSelectedItemPosition())
                .apply();
        renderProgress();
    }

    /** Time done in the last "per" window against the goal, counting a running session. */
    private void renderProgress() {
        int g = prefs.getInt(K_GOAL_N, 0);
        if (g <= 0) { progress.setText(""); return; }
        int p = prefs.getInt(K_PER_N, 1);
        int pu = prefs.getInt(K_PER_UNIT, 3);
        long target = g * UNIT_MS[prefs.getInt(K_GOAL_UNIT, 1)];
        long done = Events.sumLast(this, UNIT_FIELD[pu], p, System.currentTimeMillis(), prefs.getLong("start_ms", 0));
        long pct = target > 0 ? done * 100 / target : 0;
        progress.setTextColor(done >= target ? GOLD : SILVER);
        progress.setText(MainActivity.clock(done / 1000) + " / " + MainActivity.clock(target / 1000)
                + "   " + pct + "%   LAST " + p + " " + UNITS[pu]);
    }

    private final class LogAdapter extends BaseAdapter {
        private final List<long[]> events;
        private final SimpleDateFormat fmt = new SimpleDateFormat("yyyy-MM-dd  HH:mm", Locale.getDefault());

        LogAdapter(List<long[]> events) { this.events = events; }

        @Override public int getCount() { return events.size(); }

        @Override public Object getItem(int i) { return events.get(events.size() - 1 - i); }   // newest first

        @Override public long getItemId(int i) { return i; }

        @Override public View getView(int i, View v, ViewGroup parent) {
            if (v == null) v = LayoutInflater.from(DefinitionsActivity.this).inflate(R.layout.log_row, parent, false);
            long[] e = (long[]) getItem(i);
            ((TextView) v.findViewById(R.id.when)).setText(fmt.format(new Date(e[0])));
            ((TextView) v.findViewById(R.id.length)).setText(MainActivity.clock(e[1] / 1000));
            return v;
        }
    }
}
