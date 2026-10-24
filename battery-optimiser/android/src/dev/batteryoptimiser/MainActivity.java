package dev.batteryoptimiser;

import android.app.Activity;
import android.graphics.Typeface;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.view.Gravity;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Pattern;

/**
 * Battery's screen: the on/off switch, a live readout ({@code battery.sh now} every 2 s while
 * visible), the drain report, and every knob with Apply ({@code battery.sh apply ...}).
 * Opening it also raises Magisk's root prompt.
 */
public class MainActivity extends Activity {
    private static final long REFRESH_MS = 2000;

    /** key, title, description, values, labels (values and labels '|'-separated, same order). */
    private static final String[][] KNOBS = {
            {"protect_battery", "Protect battery",
                    "Charging stops at 85 % (Samsung's own limit). The cell ages much slower.",
                    "0|1", "Off|On (85 %)"},
            {"screen_timeout", "Screen timeout",
                    "The screen is the biggest drain while it is on.",
                    "15000|30000|60000|120000|300000|600000|1800000|2147483647",
                    "15 s|30 s|1 min|2 min|5 min|10 min|30 min|Never"},
            {"stay_awake", "Stay awake while charging",
                    "Keeps the screen on while plugged in: more power, and heat in the charging battery.",
                    "0|1|2|3|4|5|6|7", "Never|AC|USB|AC+USB|Wireless|AC+Wl|USB+Wl|Always"},
            {"doze", "Doze",
                    "Aggressive: deep sleep about 2 min after the screen goes off (stock: 35 min or more). "
                            + "Apps with a Doze exemption (below) keep their network while it sleeps.",
                    "stock|aggressive", "Stock|Aggressive"},
            {"exempt", "Doze exemptions",
                    "Keep: Tailscale, DevDeck, Termux, Termius and PhoneDeck stay exempt, so remote control "
                            + "works with the screen off. Apps: they lose it; best for battery, but adb over "
                            + "Tailscale, DevDeck, mosh and PhoneDeck stop while the phone sleeps and come back "
                            + "when the screen turns on. All: also Google Play services and Samsung extras; "
                            + "push messages (WhatsApp, banks) then wait for Doze's maintenance windows. "
                            + "Calls, SMS, alarms and emergency alerts are never touched.",
                    "keep|apps|all", "Keep|Apps|All"},
            {"wifi_scan", "Wi-Fi scanning",
                    "Location scans for Wi-Fi networks even while Wi-Fi is off.",
                    "0|1", "Off|On"},
            {"ble_scan", "Bluetooth scanning",
                    "Apps scan for Bluetooth devices even while Bluetooth is off.",
                    "0|1", "Off|On"},
            {"bluetooth", "Bluetooth",
                    "Set once on Apply; turning it on in Settings for headphones sticks.",
                    "0|1", "Off|On"},
    };
    private static final String FREEZE = "freeze";
    private static final Pattern FREEZE_OK = Pattern.compile("none|[A-Za-z0-9._:-]+(,[A-Za-z0-9._:-]+)*");

    private final Handler main = new Handler(Looper.getMainLooper());
    /** One worker, so commands never overlap. */
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Map<String, String> chosen = new HashMap<>();
    private final Map<String, String> defaults = new HashMap<>();
    private final Map<String, TextView[]> segments = new HashMap<>();
    private final Map<String, TextView> notes = new HashMap<>();
    private Ui ui;
    private LinearLayout powerCard;
    private TextView powerTitle, powerText, statusLine, message, report, freezeNote;
    private TextView level, current, limit, screen, extra;
    private EditText freeze;
    private boolean on, busy, visible, loaded;

    private final Runnable refresh = new Runnable() {
        @Override
        public void run() {
            if (!visible) return;
            if (!busy) worker.execute(() -> {
                Bat.Result r = Bat.run("now");
                runOnUiThread(() -> showNow(r));
            });
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
        root.addView(ui.text("Battery", 28, Ui.FG, true));
        statusLine = ui.text("Checking...", 14, Ui.MUTED, false);
        statusLine.setPadding(0, ui.dp(2), 0, ui.dp(12));
        root.addView(statusLine);

        powerCard = card(root);
        powerCard.setClickable(true);
        powerCard.setFocusable(true);
        powerTitle = ui.text("-", 20, Ui.FG, true);
        powerCard.addView(powerTitle);
        powerText = ui.text("", 13.5f, Ui.MUTED, false);
        powerText.setPadding(0, ui.dp(2), 0, 0);
        powerCard.addView(powerText);
        powerCard.setOnClickListener(v -> toggle());

        ui.header(root, "NOW", 16);
        LinearLayout r1 = ui.row(root);
        level = ui.stat(r1, "Battery", false);
        current = ui.stat(r1, "Current", false);
        LinearLayout r2 = ui.row(root);
        limit = ui.stat(r2, "Charge limit", false);
        screen = ui.stat(r2, "Screen", false);
        extra = ui.text("", 13, Ui.MUTED, false);
        extra.setPadding(ui.dp(4), ui.dp(4), ui.dp(4), 0);
        root.addView(extra);

        ui.header(root, "DRAIN", 16);
        LinearLayout rc = card(root);
        report = ui.text("Loading...", 11.5f, Ui.FG, false);
        report.setTypeface(Typeface.MONOSPACE);
        rc.addView(report);
        TextView again = ui.button("Refresh report", false);
        again.setOnClickListener(v -> loadReport());
        LinearLayout.LayoutParams alp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        alp.setMargins(0, ui.dp(10), 0, 0);
        rc.addView(again, alp);

        ui.header(root, "SETTINGS (OPTIMISED VALUES)", 16);
        for (String[] k : KNOBS) knob(root, k);
        freezeCard(root);

        message = ui.text("", 14, Ui.HOT, false);
        message.setPadding(ui.dp(4), ui.dp(12), ui.dp(4), ui.dp(4));
        root.addView(message);
        LinearLayout buttons = ui.row(root);
        TextView reset = ui.button("Defaults", false);
        reset.setOnClickListener(v -> fillDefaults());
        TextView apply = ui.button("Apply", true);
        apply.setOnClickListener(v -> apply());
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        blp.setMargins(ui.dp(4), ui.dp(4), ui.dp(4), ui.dp(4));
        buttons.addView(reset, blp);
        buttons.addView(apply, new LinearLayout.LayoutParams(blp));

        TextView tip = ui.text("Quick switch: pull down the panel twice, tap the pencil, and drag the Battery "
                + "tile in. A tap switches between optimised and stock.", 13, Ui.MUTED, false);
        tip.setPadding(ui.dp(4), ui.dp(18), ui.dp(4), 0);
        root.addView(tip);

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(Ui.BG);
        scroll.addView(root);
        setContentView(scroll);
        paintPower();
        loadKnobs();
        loadReport();
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

    // ---- building ----

    private LinearLayout card(LinearLayout parent) {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setPadding(ui.dp(16), ui.dp(14), ui.dp(16), ui.dp(14));
        c.setBackground(ui.box(Ui.CARD, Ui.BORDER));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins(0, ui.dp(5), 0, ui.dp(5));
        parent.addView(c, lp);
        return c;
    }

    private void cardHead(LinearLayout c, String title, String desc) {
        c.addView(ui.text(title, 17, Ui.FG, true));
        TextView d = ui.text(desc, 13, Ui.MUTED, false);
        d.setPadding(0, ui.dp(2), 0, ui.dp(6));
        c.addView(d);
    }

    /** A knob card: title, description, its values as segments (rows of four), now/stock line. */
    private void knob(LinearLayout parent, String[] k) {
        String key = k[0];
        String[] values = k[3].split("\\|"), labels = k[4].split("\\|");
        LinearLayout c = card(parent);
        cardHead(c, k[1], k[2]);
        TextView[] segs = new TextView[values.length];
        LinearLayout row = null;
        for (int i = 0; i < values.length; i++) {
            if (i % 4 == 0) row = ui.row(c);
            TextView s = ui.text(labels[i], 13, Ui.FG, true);
            s.setGravity(Gravity.CENTER);
            s.setSingleLine();
            s.setPadding(ui.dp(2), ui.dp(9), ui.dp(2), ui.dp(9));
            s.setClickable(true);
            final String value = values[i];
            s.setOnClickListener(v -> {
                chosen.put(key, value);
                paintKnob(key);
            });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
            lp.setMargins(ui.dp(3), ui.dp(3), ui.dp(3), ui.dp(3));
            row.addView(s, lp);
            segs[i] = s;
        }
        // Pad a short last row so every segment keeps the same width.
        for (int i = values.length; values.length > 4 && i % 4 != 0; i++) {
            row.addView(new TextView(this), new LinearLayout.LayoutParams(0, 1, 1f));
        }
        segments.put(key, segs);
        TextView note = ui.text("", 12, Ui.MUTED, false);
        note.setPadding(ui.dp(4), ui.dp(6), 0, 0);
        c.addView(note);
        notes.put(key, note);
        paintKnob(key);
    }

    private void freezeCard(LinearLayout parent) {
        LinearLayout c = card(parent);
        cardHead(c, "Freeze while the screen is off",
                "Processes (names as in /proc/<pid>/comm, comma-separated, or none) frozen while the screen "
                        + "is off. mosh-client otherwise keeps the mobile radio up with a packet every 3 s; "
                        + "it catches up when the screen comes on.");
        freeze = new EditText(this);
        freeze.setSingleLine();
        freeze.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        freeze.setTextColor(Ui.FG);
        freeze.setHintTextColor(Ui.MUTED);
        freeze.setHint("mosh-client");
        freeze.setTextSize(15);
        freeze.setPadding(ui.dp(12), ui.dp(10), ui.dp(12), ui.dp(10));
        freeze.setBackground(ui.box(Ui.BG, Ui.BORDER, 10));
        c.addView(freeze);
        freezeNote = ui.text("", 12, Ui.MUTED, false);
        freezeNote.setPadding(ui.dp(4), ui.dp(6), 0, 0);
        c.addView(freezeNote);
    }

    // ---- painting ----

    private void paintPower() {
        powerCard.setBackground(ui.box(on ? Ui.SELECTED : Ui.CARD, on ? Ui.ACCENT : Ui.BORDER));
        powerTitle.setText(!loaded ? "..." : on ? "On: optimised" : "Off: stock values");
        powerText.setText(!loaded ? "" : on ? "Tap to put the stock values back."
                : "Tap to apply the optimised values below.");
        powerCard.setAlpha(busy ? 0.6f : 1f);
    }

    private void paintKnob(String key) {
        TextView[] segs = segments.get(key);
        String[] values = spec(key)[3].split("\\|");
        String v = chosen.get(key);
        for (int i = 0; i < segs.length; i++) {
            boolean sel = values[i].equals(v);
            segs[i].setBackground(ui.box(sel ? Ui.SELECTED : Ui.BG, sel ? Ui.ACCENT : Ui.BORDER, 10));
            segs[i].setTextColor(sel ? Ui.ACCENT : Ui.FG);
        }
    }

    private static String[] spec(String key) {
        for (String[] k : KNOBS) if (k[0].equals(key)) return k;
        throw new IllegalArgumentException(key);
    }

    /** Label of value v of knob key ("2147483647" -> "Never"); unknown values as they are. */
    private static String label(String key, String v) {
        if (v == null || v.isEmpty()) return "-";
        String[] k = spec(key), values = k[3].split("\\|"), labels = k[4].split("\\|");
        for (int i = 0; i < values.length; i++) if (values[i].equals(v)) return labels[i];
        return v.equals("null") ? "unset" : v;
    }

    private void say(String s, int color) {
        message.setText(s);
        message.setTextColor(color);
    }

    private void setBusy(boolean b) {
        busy = b;
        paintPower();
    }

    /** No root or not installed: say so where the user looks first. */
    private boolean unavailable(Bat.Result r) {
        if (!r.unavailable()) return false;
        statusLine.setText(r.out.equals(Bat.NO_ROOT) ? "No root: allow Battery in Magisk, then reopen."
                : "Script not installed: run battery-optimiser/install.sh on the laptop.");
        statusLine.setTextColor(Ui.HOT);
        return true;
    }

    // ---- commands ----

    private void loadKnobs() {
        setBusy(true);
        worker.execute(() -> {
            Bat.Result r = Bat.run("knobs");
            runOnUiThread(() -> {
                setBusy(false);
                if (unavailable(r)) return;
                showKnobs(Bat.pairs(r.out));
            });
        });
    }

    private void showKnobs(Map<String, String> k) {
        loaded = true;
        on = "on".equals(k.get("state"));
        statusLine.setText(on ? "Optimiser on" : "Optimiser off (stock values)");
        statusLine.setTextColor(on ? Ui.OK : Ui.MUTED);
        for (String[] s : KNOBS) {
            String key = s[0];
            chosen.put(key, k.get(key + ".want"));
            defaults.put(key, k.get(key + ".default"));
            String stock = k.get(key + ".stock");
            String extra = "";
            if (key.equals("exempt")) {
                String apps = k.get("exempt.apps"), removed = k.get("exempt.removed");
                if (apps != null && !apps.isEmpty()) extra += "\nexempt now: " + apps.replace(",", ", ");
                if (removed != null && !removed.isEmpty()) extra += "\nremoved: " + removed.replace(",", ", ");
            }
            notes.get(key).setText("now: " + label(key, k.get(key))
                    + (stock == null || stock.isEmpty() ? "" : "   stock: " + label(key, stock)) + extra);
            paintKnob(key);
        }
        freeze.setText(k.get(FREEZE + ".want"));
        defaults.put(FREEZE, k.get(FREEZE + ".default"));
        freezeNote.setText("default: " + k.get(FREEZE + ".default"));
        paintPower();
    }

    private void showNow(Bat.Result r) {
        if (unavailable(r)) return;
        Map<String, String> n = Bat.pairs(r.out);
        level.setText(n.get("level") + " %");
        String st = n.get("status");
        long mA;
        try {
            mA = Long.parseLong(n.get("current"));
        } catch (NumberFormatException | NullPointerException e) {
            mA = 0;
        }
        current.setText(mA < 0 ? (-mA) + " mA out" : mA + " mA in");
        current.setTextColor(mA < 0 ? Ui.FG : Ui.OK);
        limit.setText(n.get("limit") + " %");
        screen.setText("1".equals(n.get("guard")) ? "guard" : n.get("screen"));
        String frozen = n.get("frozen");
        String daemon = n.get("daemon");
        extra.setText((st == null ? "" : st.replace('_', ' ')) + "   frozen: "
                + (frozen == null || frozen.isEmpty() ? "none" : frozen)
                + "   daemon: " + (daemon == null || daemon.isEmpty() ? "not running" : "running"));
        boolean nowOn = "on".equals(n.get("state"));
        if (loaded && nowOn != on) loadKnobs(); // switched from the tile or the laptop
    }

    private void loadReport() {
        report.setText("Loading (reads batterystats, a few seconds)...");
        worker.execute(() -> {
            Bat.Result r = Bat.run("report");
            runOnUiThread(() -> report.setText(r.out.isEmpty() ? "No data yet." : r.out));
        });
    }

    private void toggle() {
        if (busy || !loaded) return;
        setBusy(true);
        say("", Ui.MUTED);
        powerTitle.setText(on ? "Restoring stock values..." : "Applying...");
        worker.execute(() -> {
            Bat.Result r = Bat.run("toggle");
            Bat.Result k = Bat.run("knobs");
            runOnUiThread(() -> {
                setBusy(false);
                if (!r.ok()) say(r.out, Ui.HOT);
                if (!unavailable(k)) showKnobs(Bat.pairs(k.out));
            });
        });
    }

    private void fillDefaults() {
        if (!loaded) return;
        for (String[] s : KNOBS) {
            chosen.put(s[0], defaults.get(s[0]));
            paintKnob(s[0]);
        }
        freeze.setText(defaults.get(FREEZE));
        say("Defaults filled in: press Apply to use them.", Ui.ACCENT);
    }

    private void apply() {
        if (busy || !loaded) return;
        String f = freeze.getText().toString().trim();
        if (f.isEmpty()) f = "none";
        if (!FREEZE_OK.matcher(f).matches()) {
            say("Freeze: none, or process names separated by commas (letters, digits, . _ : -).", Ui.HOT);
            return;
        }
        // Every value is a table entry or matched FREEZE_OK, so the line is shell-safe.
        StringBuilder args = new StringBuilder("apply");
        for (String[] s : KNOBS) args.append(' ').append(s[0]).append('=').append(chosen.get(s[0]));
        args.append(' ').append(FREEZE).append('=').append(f);
        setBusy(true);
        say("Applying...", Ui.MUTED);
        worker.execute(() -> {
            Bat.Result r = Bat.run(args.toString());
            Bat.Result k = Bat.run("knobs");
            runOnUiThread(() -> {
                setBusy(false);
                say(r.ok() ? "Applied." : r.out, r.ok() ? Ui.OK : Ui.HOT);
                if (!unavailable(k)) showKnobs(Bat.pairs(k.out));
            });
        });
    }
}
