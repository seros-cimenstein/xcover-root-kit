package dev.cooler;

import android.app.Activity;
import android.content.res.ColorStateList;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Manual controls for the custom profile: every knob {@code cool.sh knobs} offers, with its real
 * allowed values. Nothing changes until Apply, which runs {@code cool.sh apply key=value ...};
 * cool.sh validates again and its errors are shown. The live readout refreshes every 2 s.
 */
public class ManualActivity extends Activity {
    private static final long REFRESH_MS = 2000;
    private static final Pattern PROFILE = Pattern.compile("^profile: (\\w+)", Pattern.MULTILINE);

    private final Handler main = new Handler(Looper.getMainLooper());
    private final Map<String, String[]> options = new HashMap<>();
    private final Map<String, String> stock = new HashMap<>();
    /** Controls by knob key, in display order. */
    private final Map<String, Control> controls = new LinkedHashMap<>();
    /** Views dimmed while a knob has no effect (GPU Interactive tunables, CPU min under performance). */
    private final Map<String, List<LinearLayout>> dims = new HashMap<>();
    private Ui ui;
    private Readout readout;
    private TextView profileLine, message, applyButton, resetButton;
    private LinearLayout body;
    private boolean busy, polling, visible, loaded;

    private final Runnable refresh = new Runnable() {
        @Override
        public void run() {
            if (!visible) return;
            if (!polling) poll();
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
        root.setBackgroundColor(Ui.BG);

        // Fixed header: title and live readout stay visible while the controls scroll.
        LinearLayout head = new LinearLayout(this);
        head.setOrientation(LinearLayout.VERTICAL);
        head.setPadding(ui.dp(12), ui.dp(14), ui.dp(12), ui.dp(6));
        head.addView(ui.text("Custom", 24, Ui.FG, true));
        profileLine = ui.text("Loading...", 13, Ui.MUTED, false);
        profileLine.setPadding(ui.dp(2), 0, 0, ui.dp(6));
        head.addView(profileLine);
        readout = new Readout(ui, head, true);
        root.addView(head);

        body = new LinearLayout(this);
        body.setOrientation(LinearLayout.VERTICAL);
        body.setPadding(ui.dp(12), 0, ui.dp(12), ui.dp(12));
        ScrollView scroll = new ScrollView(this);
        scroll.addView(body);
        root.addView(scroll, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));

        // Fixed footer: result line and the two actions.
        LinearLayout foot = new LinearLayout(this);
        foot.setOrientation(LinearLayout.VERTICAL);
        foot.setPadding(ui.dp(12), ui.dp(6), ui.dp(12), ui.dp(12));
        message = ui.text("Changes take effect on Apply.", 13, Ui.MUTED, false);
        message.setPadding(ui.dp(2), 0, 0, ui.dp(6));
        foot.addView(message);
        LinearLayout buttons = ui.row(foot);
        resetButton = ui.button("Reset to stock", false);
        applyButton = ui.button("Apply", true);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        lp.setMargins(ui.dp(3), 0, ui.dp(3), 0);
        buttons.addView(resetButton, lp);
        buttons.addView(applyButton, new LinearLayout.LayoutParams(lp));
        resetButton.setOnClickListener(v -> resetToStock());
        applyButton.setOnClickListener(v -> apply());
        root.addView(foot);

        setContentView(root);
        setBusy(true);
        loadKnobs();
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

    // ---- script calls ----

    private void loadKnobs() {
        new Thread(() -> {
            Cool.Result r = Cool.run("knobs");
            runOnUiThread(() -> {
                if (!r.ok()) {
                    say(failure(r), Ui.HOT);
                    profileLine.setText("Could not read the knobs.");
                    return;
                }
                build(r.out);
                loaded = true;
                setBusy(false);
            });
        }).start();
    }

    private void poll() {
        polling = true;
        new Thread(() -> {
            Cool.Result s = Cool.run("status");
            runOnUiThread(() -> {
                polling = false;
                if (!s.ok()) return;
                readout.show(s.out);
                Matcher p = PROFILE.matcher(s.out);
                if (p.find()) profileLine.setText("Profile now: " + Cool.label(p.group(1)));
            });
        }).start();
    }

    private void apply() {
        if (busy || !loaded) return;
        StringBuilder cmd = new StringBuilder("apply");
        for (Control c : controls.values()) {
            if (!c.key.equals("cpu0")) cmd.append(' ').append(c.key).append('=').append(c.value());
        }
        setBusy(true);
        say("Applying...", Ui.MUTED);
        new Thread(() -> {
            Cool.Result r = Cool.run(cmd.toString());
            runOnUiThread(() -> {
                setBusy(false);
                if (r.ok()) say("Applied. Profile: Custom.", Ui.OK);
                else say(failure(r), Ui.HOT);
                poll();
            });
        }).start();
    }

    private void resetToStock() {
        if (busy || !loaded) return;
        for (Control c : controls.values()) {
            String s = stock.get(c.key);
            if (s != null) c.set(s);
        }
        updateDims();
        say("Stock values set. Press Apply to use them.", Ui.WARM);
    }

    private static String failure(Cool.Result r) {
        if (r.out.equals(Cool.NO_ROOT)) return "No root: allow Cooler in Magisk, then reopen.";
        if (r.out.equals(Cool.NOT_INSTALLED)) return "Scripts not installed: run phone_cooler/install.sh on the laptop.";
        return r.out.isEmpty() ? "cool.sh failed (exit " + r.rc + ")" : r.out;
    }

    private void say(String s, int color) {
        message.setText(s);
        message.setTextColor(color);
    }

    private void setBusy(boolean b) {
        busy = b;
        applyButton.setAlpha(b ? 0.5f : 1f);
        resetButton.setAlpha(b ? 0.5f : 1f);
    }

    // ---- building the controls from `cool.sh knobs` ----

    private void build(String knobs) {
        Map<String, String> live = new HashMap<>(), saved = new HashMap<>();
        for (String line : knobs.split("\n")) {
            int eq = line.indexOf('=');
            if (eq <= 0) continue;
            String k = line.substring(0, eq), v = line.substring(eq + 1).trim();
            int dot = k.indexOf('.');
            if (dot < 0) {
                live.put(k, v);
                continue;
            }
            String key = k.substring(0, dot);
            switch (k.substring(dot + 1)) {
                case "options": options.put(key, v.split(" +")); break;
                case "stock": stock.put(key, v); break;
                case "saved": saved.put(key, v); break;
                default: break;
            }
        }
        boolean hasSaved = "1".equals(live.get("saved"));
        profileLine.setText("Profile now: " + Cool.label(live.getOrDefault("profile", "?")));
        say(hasSaved ? "Showing your saved custom settings. Changes take effect on Apply."
                : "Showing the current settings. Changes take effect on Apply.", Ui.MUTED);

        cluster("LITTLE CORES (0-3)", "little", 0, 3);
        cluster("BIG CORES (4-7)", "big", 4, 7);

        ui.header(body, "GPU (MALI-G72 MP3)", 16);
        LinearLayout gpu = card();
        slider(gpu, "gpu_max", "Max clock");
        slider(gpu, "gpu_min", "Min clock");
        segmented(gpu, "gpu_governor", "Governor");
        segmented(gpu, "gpu_cl_boost", "OpenCL boost (compute jobs jump to max)");
        LinearLayout hs = slider(gpu, "gpu_highspeed_clock", "Interactive: jump-to clock");
        LinearLayout hl = slider(gpu, "gpu_highspeed_load", "Interactive: jump above load");
        dims.put("gpu_governor", list(hs, hl));

        for (Control c : controls.values()) {
            String v = hasSaved ? saved.get(c.key) : null;
            if (v == null || indexOf(c.opts, v) < 0) v = live.get(c.key);
            if (v == null || indexOf(c.opts, v) < 0) v = stock.get(c.key);
            if (v != null) c.set(v);
        }
        updateDims();
    }

    private void cluster(String title, String prefix, int first, int last) {
        ui.header(body, title, 16);
        LinearLayout card = card();
        slider(card, prefix + "_max", "Max clock");
        LinearLayout min = slider(card, prefix + "_min", "Min clock");
        segmented(card, prefix + "_governor", "Governor");
        dims.put(prefix + "_governor", list(min));
        TextView l = ui.text("Cores online", 13, Ui.MUTED, false);
        l.setPadding(0, ui.dp(10), 0, ui.dp(4));
        card.addView(l);
        LinearLayout row = ui.row(card);
        for (int i = first; i <= last; i++) {
            if (options.containsKey("cpu" + i)) controls.put("cpu" + i, new Core(row, i, first, last));
        }
    }

    private LinearLayout card() {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setPadding(ui.dp(14), ui.dp(8), ui.dp(14), ui.dp(12));
        c.setBackground(ui.box(Ui.CARD, Ui.BORDER));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins(0, ui.dp(4), 0, ui.dp(4));
        body.addView(c, lp);
        return c;
    }

    /** Adds a slider for {@code key} if cool.sh offers it; returns its container (or an unused one). */
    private LinearLayout slider(LinearLayout parent, String key, String label) {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        if (options.containsKey(key)) {
            parent.addView(box);
            controls.put(key, new Slider(box, key, label));
        }
        return box;
    }

    private void segmented(LinearLayout parent, String key, String label) {
        if (!options.containsKey(key)) return;
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        parent.addView(box);
        controls.put(key, new Segmented(box, key, label));
    }

    private static List<LinearLayout> list(LinearLayout... views) {
        List<LinearLayout> l = new ArrayList<>();
        for (LinearLayout v : views) l.add(v);
        return l;
    }

    /** Dims the tunables that the chosen governor ignores. */
    private void updateDims() {
        for (Map.Entry<String, List<LinearLayout>> e : dims.entrySet()) {
            Control g = controls.get(e.getKey());
            if (g == null) continue;
            boolean used = e.getKey().equals("gpu_governor") ? g.value().equals("Interactive") : !g.value().equals("performance");
            for (LinearLayout v : e.getValue()) v.setAlpha(used ? 1f : 0.45f);
        }
    }

    /** A control changed by the user: keeps min <= max and refreshes the dimming. */
    private void changed(Control c) {
        if (c.key.endsWith("_max")) {
            Control min = controls.get(c.key.substring(0, c.key.length() - 4) + "_min");
            if (min != null && num(min.value()) > num(c.value())) min.set(highestAtMost(min.opts, num(c.value())));
        } else if (c.key.endsWith("_min")) {
            Control max = controls.get(c.key.substring(0, c.key.length() - 4) + "_max");
            if (max != null && num(max.value()) < num(c.value())) max.set(lowestAtLeast(max.opts, num(c.value())));
        }
        updateDims();
        say("Not applied yet: press Apply.", Ui.WARM);
    }

    private static long num(String s) {
        try {
            return Long.parseLong(s);
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    private static String highestAtMost(String[] opts, long v) {
        String best = opts[0];
        for (String o : opts) if (num(o) <= v && num(o) >= num(best)) best = o;
        return best;
    }

    private static String lowestAtLeast(String[] opts, long v) {
        String best = opts[opts.length - 1];
        for (String o : opts) if (num(o) >= v && num(o) <= num(best)) best = o;
        return best;
    }

    private static int indexOf(String[] a, String v) {
        for (int i = 0; i < a.length; i++) if (a[i].equals(v)) return i;
        return -1;
    }

    /** "1222000" -> "1222 MHz" for clocks, "75" -> "75 %" for the load, else the value itself. */
    private static String display(String key, String v) {
        if (key.equals("gpu_highspeed_load")) return v + " %";
        if (key.equals("gpu_cl_boost")) return v.equals("1") ? "On" : "Off";
        if (key.endsWith("_min") || key.endsWith("_max") || key.endsWith("_clock")) return (num(v) / 1000) + " MHz";
        return v.isEmpty() ? v : Character.toUpperCase(v.charAt(0)) + v.substring(1);
    }

    // ---- controls ----

    private abstract class Control {
        final String key;
        final String[] opts;
        int index;

        Control(String key) {
            this.key = key;
            this.opts = options.get(key);
        }

        String value() {
            return opts[index];
        }

        /** Shows {@code v} without counting it as a user change. */
        void set(String v) {
            int i = indexOf(opts, v);
            if (i < 0) return;
            index = i;
            render();
        }

        abstract void render();
    }

    /** A snapping slider over the knob's real values. */
    private final class Slider extends Control {
        private final SeekBar bar;
        private final TextView shown;

        Slider(LinearLayout box, String key, String label) {
            super(key);
            LinearLayout top = ui.row(box);
            top.setPadding(0, ui.dp(8), 0, 0);
            TextView l = ui.text(label, 14, Ui.FG, false);
            top.addView(l, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
            shown = ui.text("", 14, Ui.ACCENT, true);
            top.addView(shown);
            bar = new SeekBar(ManualActivity.this);
            bar.setMax(opts.length - 1);
            bar.setProgressTintList(ColorStateList.valueOf(Ui.ACCENT));
            bar.setThumbTintList(ColorStateList.valueOf(Ui.ACCENT));
            bar.setProgressBackgroundTintList(ColorStateList.valueOf(Ui.BORDER));
            bar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
                @Override
                public void onProgressChanged(SeekBar s, int p, boolean fromUser) {
                    if (!fromUser) return;
                    index = p;
                    shown.setText(display(Slider.this.key, value()));
                    changed(Slider.this);
                }

                @Override
                public void onStartTrackingTouch(SeekBar s) {}

                @Override
                public void onStopTrackingTouch(SeekBar s) {}
            });
            box.addView(bar);
        }

        @Override
        void render() {
            bar.setProgress(index);
            shown.setText(display(key, value()));
        }
    }

    /** One-of choice as a row (or rows of three) of segments. */
    private final class Segmented extends Control {
        private final TextView[] segs;

        Segmented(LinearLayout box, String key, String label) {
            super(key);
            TextView l = ui.text(label, 14, Ui.FG, false);
            l.setPadding(0, ui.dp(10), 0, ui.dp(4));
            box.addView(l);
            segs = new TextView[opts.length];
            LinearLayout row = null;
            for (int i = 0; i < opts.length; i++) {
                if (i % 3 == 0) row = ui.row(box);
                TextView s = ui.text(display(key, opts[i]), 13, Ui.FG, true);
                s.setGravity(Gravity.CENTER);
                s.setSingleLine();
                s.setPadding(ui.dp(4), ui.dp(9), ui.dp(4), ui.dp(9));
                s.setClickable(true);
                final int at = i;
                s.setOnClickListener(v -> {
                    if (index == at) return;
                    index = at;
                    render();
                    changed(this);
                });
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
                lp.setMargins(ui.dp(3), ui.dp(3), ui.dp(3), ui.dp(3));
                row.addView(s, lp);
                segs[i] = s;
            }
            // Pad a short last row so every segment keeps the same width.
            for (int i = opts.length; opts.length > 3 && i % 3 != 0; i++) {
                row.addView(new TextView(ManualActivity.this), new LinearLayout.LayoutParams(0, 1, 1f));
            }
        }

        @Override
        void render() {
            for (int i = 0; i < segs.length; i++) {
                boolean on = i == index;
                segs[i].setBackground(ui.box(on ? Ui.SELECTED : Ui.BG, on ? Ui.ACCENT : Ui.BORDER, 10));
                segs[i].setTextColor(on ? Ui.ACCENT : Ui.FG);
            }
        }
    }

    /** A core on/off tile. cpu0 is always on; the last online core of a cluster can't be turned off. */
    private final class Core extends Control {
        private final TextView tile;
        private final int first, last;

        Core(LinearLayout row, int cpu, int first, int last) {
            super("cpu" + cpu);
            this.first = first;
            this.last = last;
            tile = ui.text("", 14, Ui.FG, true);
            tile.setGravity(Gravity.CENTER);
            tile.setPadding(0, ui.dp(10), 0, ui.dp(10));
            tile.setClickable(true);
            tile.setOnClickListener(v -> toggle());
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
            lp.setMargins(ui.dp(3), ui.dp(3), ui.dp(3), ui.dp(3));
            row.addView(tile, lp);
        }

        private boolean on() {
            return value().equals("1");
        }

        private void toggle() {
            if (opts.length < 2) {
                say("cpu0 always stays online.", Ui.WARM);
                return;
            }
            if (on()) {
                int online = 0;
                for (int i = first; i <= last; i++) {
                    Control c = controls.get("cpu" + i);
                    if (c == null || c.value().equals("1")) online++;
                }
                if (online <= 1) {
                    say("Keep at least one core of each cluster online.", Ui.WARM);
                    return;
                }
            }
            set(on() ? "0" : "1");
            changed(this);
        }

        @Override
        void render() {
            boolean on = on(), fixed = opts.length < 2;
            tile.setText(key.substring(3) + (on ? (fixed ? "\nalways" : "\non") : "\noff"));
            tile.setBackground(ui.box(on ? Ui.SELECTED : Ui.BG, on ? Ui.ACCENT : Ui.BORDER, 10));
            tile.setTextColor(on ? Ui.ACCENT : Ui.MUTED);
            tile.setAlpha(fixed ? 0.7f : 1f);
        }
    }
}
