package app.consistency;

import java.util.Locale;

/** Human time amounts: "54.3 minutes", "2.3 days", "7.5 years", and the total's "1y 2mo 3w 4d 05:06:07". */
final class Fmt {

    static final String[] NAMES = { "second", "minute", "hour", "day", "week", "month", "year" };
    // Months and years use their average Gregorian length.
    static final long[] UNIT_MS = {
            1000L, 60_000L, 3_600_000L, 86_400_000L, 604_800_000L, 2_629_746_000L, 31_556_952_000L };

    private Fmt() {}

    /** In the largest unit already reached in full, one decimal at most. */
    static String amount(double ms) {
        int u = 0;
        for (int i = UNIT_MS.length - 1; i > 0; i--) if (ms >= UNIT_MS[i]) { u = i; break; }
        return count(ms / UNIT_MS[u], u);
    }

    /** "1 hour", "2.5 days"; trailing ".0" dropped. */
    static String count(double v, int unit) {
        String n = String.format(Locale.US, "%.1f", v);
        if (n.endsWith(".0")) n = n.substring(0, n.length() - 2);
        return n + " " + NAMES[unit] + (n.equals("1") ? "" : "s");
    }

    /** The unit name alone for 1 ("day"), else the count ("2 weeks"). */
    static String per(int n, int unit) {
        return n == 1 ? NAMES[unit] : count(n, unit);
    }

    /** Full breakdown for the total; larger units appear only once reached. */
    static String elapsed(long ms) {
        long s = ms / 1000;
        long y = s / (UNIT_MS[6] / 1000); s -= y * (UNIT_MS[6] / 1000);
        long mo = s / (UNIT_MS[5] / 1000); s -= mo * (UNIT_MS[5] / 1000);
        long w = s / 604_800L; s -= w * 604_800L;
        long d = s / 86_400L; s -= d * 86_400L;
        long h = s / 3600, m = (s / 60) % 60, sec = s % 60;

        StringBuilder sb = new StringBuilder();
        if (y > 0) sb.append(y).append("y ");
        if (y > 0 || mo > 0) sb.append(mo).append("mo ");
        if (sb.length() > 0 || w > 0) sb.append(w).append("w ");
        if (sb.length() > 0 || d > 0) sb.append(d).append("d ");
        sb.append(String.format(Locale.US, "%02d:%02d:%02d", h, m, sec));
        return sb.toString();
    }
}
