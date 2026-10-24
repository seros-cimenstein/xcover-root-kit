package dev.cooler;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Cooler's screen: the four presets as tappable cards, a Custom card that opens the manual
 * controls, plus live temperatures, clocks and cores read from {@code cool.sh status} every 2 s
 * while visible. Opening it also raises Magisk's root prompt.
 */
public class InfoActivity extends Activity {
    private static final long REFRESH_MS = 2000;

    private static final String[][] PROFILES = {
            {"off", "Off", "Stock clocks. Full speed, runs hottest."},
            {"mild", "Mild", "Big cores 1.9 GHz, GPU 764 MHz. Barely slower."},
            {"cool", "Cool", "Little 1.46, big 1.51 GHz, GPU 572 MHz. About 35% less power."},
            {"cold", "Cold", "Little 1.22, big 1.25 GHz, GPU 455 MHz. About half the power."},
            {"custom", "Custom", "Your own clocks, governors and cores. Tap to set them."},
    };

    private static final Pattern PROFILE = Pattern.compile("^profile: (\\w+)", Pattern.MULTILINE);

    private final Handler main = new Handler(Looper.getMainLooper());
    private final LinearLayout[] cards = new LinearLayout[PROFILES.length];
    private Ui ui;
    private Readout readout;
    private TextView statusLine;
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

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        ui = new Ui(this);
        getWindow().setStatusBarColor(Ui.BG);
        getWindow().setNavigationBarColor(Ui.BG);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(ui.dp(16), ui.dp(20), ui.dp(16), ui.dp(24));

        root.addView(ui.text("Cooler", 28, Ui.FG, true));
        statusLine = ui.text("Checking...", 14, Ui.MUTED, false);
        statusLine.setPadding(0, ui.dp(2), 0, ui.dp(14));
        root.addView(statusLine);

        for (int i = 0; i < PROFILES.length; i++) {
            final String id = PROFILES[i][0];
            LinearLayout card = new LinearLayout(this);
            card.setOrientation(LinearLayout.VERTICAL);
            card.setPadding(ui.dp(16), ui.dp(14), ui.dp(16), ui.dp(14));
            card.setClickable(true);
            card.setFocusable(true);
            card.addView(ui.text(PROFILES[i][1], 19, Ui.FG, true));
            TextView d = ui.text(PROFILES[i][2], 13.5f, Ui.MUTED, false);
            d.setPadding(0, ui.dp(2), 0, 0);
            card.addView(d);
            card.setOnClickListener(v -> choose(id));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT);
            lp.setMargins(0, ui.dp(5), 0, ui.dp(5));
            root.addView(card, lp);
            cards[i] = card;
        }

        readout = new Readout(ui, root, false);

        TextView tip = ui.text("Quick switch: pull down the panel twice, tap the pencil, and drag the "
                + "Cooler tile in. Each tap cycles Off > Mild > Cool > Cold (> Custom once saved).", 13, Ui.MUTED, false);
        tip.setPadding(ui.dp(4), ui.dp(18), ui.dp(4), 0);
        root.addView(tip);

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(Ui.BG);
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
        if (id.equals("custom")) {
            startActivity(new Intent(this, ManualActivity.class));
            return;
        }
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
                Cool.Result r = Cool.run(command);
                if (!r.ok()) err = r.out;
            }
            Cool.Result s = Cool.run("status");
            final String error = err;
            runOnUiThread(() -> {
                busy = false;
                show(error, s);
            });
        }).start();
    }

    private void show(String error, Cool.Result s) {
        if (s.out.equals(Cool.NO_ROOT)) {
            statusLine.setText("No root: allow Cooler in Magisk, then reopen.");
            statusLine.setTextColor(Ui.HOT);
            return;
        }
        if (s.out.equals(Cool.NOT_INSTALLED)) {
            statusLine.setText("Scripts not installed: run phone_cooler/install.sh on the laptop.");
            statusLine.setTextColor(Ui.HOT);
            return;
        }
        Matcher p = PROFILE.matcher(s.out);
        if (p.find()) current = p.group(1);
        statusLine.setText(error != null ? error : "Profile: " + Cool.label(current));
        statusLine.setTextColor(error != null ? Ui.HOT : Ui.ACCENT);
        paintCards();
        readout.show(s.out);
    }

    private void paintCards() {
        for (int i = 0; i < PROFILES.length; i++) {
            boolean on = PROFILES[i][0].equals(current);
            cards[i].setBackground(ui.box(on ? Ui.SELECTED : Ui.CARD, on ? Ui.ACCENT : Ui.BORDER));
            cards[i].setAlpha(busy && !on ? 0.6f : 1f);
        }
    }
}
