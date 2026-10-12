package app.consistency;

import android.content.Context;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.Collections;
import java.util.List;

/** Append-only log of submitted sessions: one "startMs durationMs" line per session. */
final class Events {

    private static ArrayList<long[]> cache;

    private Events() {}

    private static File file(Context c) { return new File(c.getFilesDir(), "events.txt"); }

    /** All sessions, oldest first, as {startMs, durationMs}. */
    static synchronized List<long[]> all(Context c) {
        if (cache != null) return cache;
        cache = new ArrayList<>();
        File f = file(c);
        if (!f.exists()) return cache;
        try (BufferedReader r = new BufferedReader(new FileReader(f))) {
            String line;
            while ((line = r.readLine()) != null) {
                String[] p = line.trim().split(" ");
                if (p.length != 2) continue;
                try {
                    cache.add(new long[] { Long.parseLong(p[0]), Long.parseLong(p[1]) });
                } catch (NumberFormatException ignored) { }
            }
        } catch (IOException ignored) { }
        return cache;
    }

    static synchronized void add(Context c, long start, long dur) {
        all(c).add(new long[] { start, dur });
        try (FileWriter w = new FileWriter(file(c), true)) {
            w.write(start + " " + dur + "\n");
        } catch (IOException ignored) { }
    }

    // TODO(next update): remove. One-time conversion of the time recorded before the log existed.
    /** Spreads legacyMs over the log as 10 minutes per day, going back day by day from now. */
    static synchronized void convertLegacyTotal(Context c, long legacyMs, long now) {
        if (legacyMs <= 0 || !all(c).isEmpty()) return;
        final long chunk = 10 * 60 * 1000L;
        ArrayList<long[]> back = new ArrayList<>();
        Calendar cal = Calendar.getInstance();
        cal.setTimeInMillis(now);
        for (long left = legacyMs; left > 0; left -= chunk) {
            long dur = Math.min(chunk, left);
            long end = cal.getTimeInMillis();
            back.add(new long[] { end - dur, dur });
            cal.add(Calendar.DAY_OF_YEAR, -1);
        }
        Collections.reverse(back);   // oldest first
        StringBuilder sb = new StringBuilder();
        for (long[] e : back) sb.append(e[0]).append(' ').append(e[1]).append('\n');
        try (FileWriter w = new FileWriter(file(c), true)) {
            w.write(sb.toString());
        } catch (IOException ignored) { return; }
        cache.addAll(back);
    }

    /**
     * Time logged in the rolling window (now - amount field, now], counting only the part of each
     * session inside it. liveStart != 0 adds the session still running.
     */
    static long sumLast(Context c, int field, int amount, long now, long liveStart) {
        Calendar cal = Calendar.getInstance();
        cal.setTimeInMillis(now);
        cal.add(field, -amount);
        long from = cal.getTimeInMillis();

        long sum = liveStart != 0 ? overlap(liveStart, now, from, now) : 0;
        List<long[]> list = all(c);
        for (int i = list.size() - 1; i >= 0; i--) {
            long[] e = list.get(i);
            sum += overlap(e[0], e[0] + e[1], from, now);
        }
        return sum;
    }

    private static long overlap(long s, long e, long from, long to) {
        return Math.max(0, Math.min(e, to) - Math.max(s, from));
    }
}
