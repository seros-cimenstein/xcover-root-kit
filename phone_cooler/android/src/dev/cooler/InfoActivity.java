package dev.cooler;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Cooler's screen: the four profiles as tappable cards, plus live temperatures and clocks read
 * from {@code cool.sh status} every 2 s while visible. Opening it also raises Magisk's root prompt.
 */
public class InfoActivity extends Activity {
    private static final int BG = 0xff0d1117, CARD = 0xff161b22, BORDER = 0xff30363d;
    private static final int FG = 0xffe6edf3, MUTED = 0xff8b949e, ACCENT = 0xff58a6ff;
    private static final int OK = 0xff3fb950, WARM = 0xffd29922, HOT = 0xfff85149;
    private static final long REFRESH_MS = 2000;

    private static final String[][] PROFILES = {
            {"off", "Off", "Stock clocks. Full speed, runs hottest."},
            {"mild", "Mild", "Big cores 1.9 GHz, GPU 764 MHz. Barely slower."},
            {"cool", "Cool", "Little 1.46, big 1.51 GHz, GPU 572 MHz. About 35% less power."},
            {"cold", "Cold", "Little 1.22, big 1.25 GHz, GPU 455 MHz. About half the power."},
    };

    private static final Pattern PROFILE = Pattern.compile("^profile: (\\w+)", Pattern.MULTILINE);
    private static final Pattern CLOCK = Pattern.compile("^(LITTLE|BIG|GPU): (\\d+) MHz now, max (\\d+) MHz", Pattern.MULTILINE);
    private static final Pattern TEMP = Pattern.compile("(BIG|LITTLE|G3D|battery) ([\\d.]+)C");

    private final Handler main = new Handler(Looper.getMainLooper());
    private final LinearLayout[] cards = new LinearLayout[PROFILES.length];
    private TextView statusLine, tempBig, tempLittle, tempGpu, tempBattery, clockLittle, clockBig, clockGpu;
    private String current = "";
    private boolean busy, visible;

    private final Runnable refresh = new Runnable() {
        @Override
        public void run() {
            if (!visible) return;
            if (!busy) load(null);
            main.postDelayed(this, REFRESH_MS);
        }
    };

    private int dp(float v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    private GradientDrawable box(int fill, int stroke) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(fill);
        d.setCornerRadius(dp(14));
        d.setStroke(dp(1.5f), stroke);
        return d;
    }

    private TextView text(String s, float sp, int color, boolean bold) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        return t;
    }

    /** A value tile in the readout grid; returns its value view. */
    private TextView stat(LinearLayout row, String label) {
        LinearLayout cell = new LinearLayout(this);
        cell.setOrientation(LinearLayout.VERTICAL);
        cell.setPadding(dp(12), dp(10), dp(12), dp(10));
        cell.setBackground(box(CARD, BORDER));
        cell.addView(text(label, 12, MUTED, false));
        TextView value = text("-", 20, FG, true);
        cell.addView(value);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        lp.setMargins(dp(4), dp(4), dp(4), dp(4));
        row.addView(cell, lp);
        return value;
    }

    private LinearLayout row(LinearLayout parent) {
        LinearLayout r = new LinearLayout(this);
        r.setOrientation(LinearLayout.HORIZONTAL);
        parent.addView(r);
        return r;
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setStatusBarColor(BG);
        getWindow().setNavigationBarColor(BG);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(16), dp(20), dp(16), dp(24));

        root.addView(text("Cooler", 28, FG, true));
        statusLine = text("Checking...", 14, MUTED, false);
        statusLine.setPadding(0, dp(2), 0, dp(14));
        root.addView(statusLine);

        for (int i = 0; i < PROFILES.length; i++) {
            final String id = PROFILES[i][0];
            LinearLayout card = new LinearLayout(this);
            card.setOrientation(LinearLayout.VERTICAL);
            card.setPadding(dp(16), dp(14), dp(16), dp(14));
            card.setClickable(true);
            card.setFocusable(true);
            card.addView(text(PROFILES[i][1], 19, FG, true));
            TextView d = text(PROFILES[i][2], 13.5f, MUTED, false);
            d.setPadding(0, dp(2), 0, 0);
            card.addView(d);
            card.setOnClickListener(v -> choose(id));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT);
            lp.setMargins(0, dp(5), 0, dp(5));
            root.addView(card, lp);
            cards[i] = card;
        }

        TextView temps = text("TEMPERATURE", 12, MUTED, true);
        temps.setPadding(dp(4), dp(18), 0, dp(2));
        root.addView(temps);
        LinearLayout r1 = row(root);
        tempBig = stat(r1, "Big cores");
        tempLittle = stat(r1, "Little cores");
        LinearLayout r2 = row(root);
        tempGpu = stat(r2, "GPU");
        tempBattery = stat(r2, "Battery");

        TextView clocks = text("CLOCKS (NOW / MAX)", 12, MUTED, true);
        clocks.setPadding(dp(4), dp(14), 0, dp(2));
        root.addView(clocks);
        LinearLayout r3 = row(root);
        clockLittle = stat(r3, "Little");
        clockBig = stat(r3, "Big");
        clockGpu = stat(r3, "GPU");

        TextView tip = text("Quick switch: pull down the panel twice, tap the pencil, and drag the "
                + "Cooler tile in. Each tap cycles Off > Mild > Cool > Cold.", 13, MUTED, false);
        tip.setPadding(dp(4), dp(18), dp(4), 0);
        root.addView(tip);

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(BG);
        scroll.addView(root);
        setContentView(scroll);
        paintCards();
    }

    @Override
    protected void onResume() {
        super.onResume();
        visible = true;
        main.removeCallbacks(refresh);
        main.post(refresh);
    }

    @Override
    protected void onPause() {
        visible = false;
        main.removeCallbacks(refresh);
        super.onPause();
    }

    private void choose(String id) {
        if (busy || id.equals(current)) return;
        busy = true;
        current = id;
        paintCards();
        statusLine.setText("Switching to " + Cool.label(id) + "...");
        load("set " + id);
    }

    /** Runs an optional command, then reads the status, off the main thread. */
    private void load(String command) {
        new Thread(() -> {
            String err = null;
            if (command != null) {
                String r = Cool.run(command);
                if (r.equals(Cool.NO_ROOT) || r.equals(Cool.NOT_INSTALLED)) err = r;
            }
            String s = Cool.run("status");
            final String error = err;
            runOnUiThread(() -> {
                busy = false;
                show(error, s);
            });
        }).start();
    }

    private void show(String error, String s) {
        if (s.equals(Cool.NO_ROOT)) {
            statusLine.setText("No root: allow Cooler in Magisk, then reopen.");
            statusLine.setTextColor(HOT);
            return;
        }
        if (s.equals(Cool.NOT_INSTALLED)) {
            statusLine.setText("Scripts not installed: run phone_cooler/install.sh on the laptop.");
            statusLine.setTextColor(HOT);
            return;
        }
        Matcher p = PROFILE.matcher(s);
        if (p.find()) current = p.group(1);
        statusLine.setText(error != null ? error : "Profile: " + Cool.label(current));
        statusLine.setTextColor(error != null ? HOT : ACCENT);
        paintCards();

        Matcher c = CLOCK.matcher(s);
        while (c.find()) {
            String v = c.group(2) + " / " + c.group(3);
            switch (c.group(1)) {
                case "LITTLE": clockLittle.setText(v); break;
                case "BIG": clockBig.setText(v); break;
                default: clockGpu.setText(v); break;
            }
        }
        Matcher t = TEMP.matcher(s);
        while (t.find()) {
            float deg = Float.parseFloat(t.group(2));
            TextView view;
            switch (t.group(1)) {
                case "BIG": view = tempBig; break;
                case "LITTLE": view = tempLittle; break;
                case "G3D": view = tempGpu; break;
                default: view = tempBattery; break;
            }
            view.setText(String.format("%.0f \u00b0C", deg));
            view.setTextColor(deg >= 70 ? HOT : deg >= 55 ? WARM : OK);
        }
    }

    private void paintCards() {
        for (int i = 0; i < PROFILES.length; i++) {
            boolean on = PROFILES[i][0].equals(current);
            cards[i].setBackground(box(on ? 0xff10283d : CARD, on ? ACCENT : BORDER));
            cards[i].setAlpha(busy && !on ? 0.6f : 1f);
        }
    }
}
