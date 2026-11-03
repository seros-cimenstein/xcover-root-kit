package dev.batteryoptimiser;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Typeface;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
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
            {"fast_charge", "Fast charging",
                    "Samsung's Fast charging (9 V charger).\n"
                            + "Off: charges at 5 V. Less current into the battery, so it stays cooler while "
                            + "charging and ages slower, but charging takes longer.\n"
                            + "On: up to about 2.7 A into the battery with the screen off; it gets warm. "
                            + "Samsung limits charging to about 1.2 A while the screen is on either way.\n"
                            + "If the phone is charging when you change it, plug it in again.",
                    "0|1", "Off|On"},
            {"screen_timeout", "Screen timeout",
                    "The screen is the biggest drain while it is on.",
                    "15000|30000|60000|120000|300000|600000|1800000|2147483647",
                    "15 s|30 s|1 min|2 min|5 min|10 min|30 min|Never"},
            {"stay_awake", "Stay awake while charging",
                    "Keeps the screen on while plugged in: more power, and heat in the charging battery.",
                    "0|1|2|3|4|5|6|7", "Never|AC|USB|AC+USB|Wireless|AC+Wl|USB+Wl|Always"},
            {"doze", "Doze",
                    "When Doze starts after the screen goes off.\n"
                            + "Stock: Samsung's timings: light Doze after 1 min, deep Doze only after 35 min or "
                            + "more with the phone lying still.\n"
                            + "Aggressive: light Doze after 15 s, deep Doze about 2 min after the screen goes off "
                            + "if the phone lies still. Most of the screen-off saving comes from this.",
                    "stock|aggressive", "Stock|Aggressive"},
            {"exempt_sys", "Doze exemptions: Google and Samsung",
                    "System apps that Doze leaves alone.\n"
                            + "Keep: they stay exempt, as Samsung set them.\n"
                            + "Remove: Google Play services, the calendar and download providers and the Samsung "
                            + "extras (screenshots, file sharing, one-handed mode, blue light filter, handwriting, "
                            + "video, adaptive brightness) lose their exemption. Push messages (WhatsApp, banks, "
                            + "Gmail) and Google sync then wait for the next maintenance window. More battery, "
                            + "later messages.\n"
                            + "Never touched either way: calls, SMS, alarms, emergency alerts, contacts.",
                    "keep|remove", "Keep|Remove"},
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
    private static final String FREEZE = "freeze", ALLOW = "allow", EXEMPT = "exempt";
    private static final Pattern FREEZE_OK = Pattern.compile("none|[A-Za-z0-9._:-]+(,[A-Za-z0-9._:-]+)*");
    private static final Pattern PACKAGE_OK = Pattern.compile("[A-Za-z0-9._]+");
    private static final String DOZE_INFO =
            "Doze is Android's sleep for apps. While the screen is off, Android holds apps back so the CPU "
                    + "and the mobile radio can sleep: no network, their jobs and syncs wait. Every so often "
                    + "it opens a short maintenance window in which apps catch up, then sleeps again.\n\n"
                    + "Light Doze starts soon after the screen goes off, even in a pocket. Maintenance windows "
                    + "come every 15 min, growing to 1 h (with Aggressive).\n\n"
                    + "Deep Doze starts once the phone also lies still. It also ignores apps' wakelocks and "
                    + "delays their ordinary alarms. Windows come every 1 h, growing to 6 h. Picking the phone "
                    + "up or turning the screen on ends it at once.\n\n"
                    + "Still working while it sleeps: calls, SMS, the alarms you set, and high-priority push "
                    + "messages (WhatsApp, banks) while Google Play services is exempt.\n\n"
                    + "Exemptions: an exempt app (\"Unrestricted\" in its battery settings) is not held back. "
                    + "It keeps its network, jobs and wakelocks while the phone sleeps. Fewer exemptions save "
                    + "more battery, but those apps stop while the screen is off, until it comes on or a "
                    + "maintenance window opens. Tailscale needs one for adb, DevDeck and mosh to reach the "
                    + "phone while it sleeps.";

    private final Handler main = new Handler(Looper.getMainLooper());
    /** One worker, so commands never overlap. */
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Map<String, String> chosen = new HashMap<>();
    private final Map<String, String> defaults = new HashMap<>();
    private final Map<String, TextView[]> segments = new HashMap<>();
    private final Map<String, TextView> notes = new HashMap<>();
    /** Apps kept running (allow) and apps exempt from Doze (exempt). */
    private final AppList allow = new AppList(ALLOW, "Keep these apps running"),
            exempt = new AppList(EXEMPT, "Doze exemptions: apps");
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

    /** An app-list knob (allow, exempt): the chosen apps' names and a picker of the launcher apps. */
    private final class AppList {
        final String key, title;
        /** Packages chosen, in the order shown. */
        final List<String> pkgs = new ArrayList<>();
        /** exempt only: the value is "keep", the user exemptions stay as found ({@link #found}). */
        boolean keep;
        /** exempt: the user exemptions now (outside allow), ticked in the picker while keep. */
        final List<String> found = new ArrayList<>();
        TextView names, note;

        AppList(String key, String title) {
            this.key = key;
            this.title = title;
        }

        void set(String v) {
            keep = "keep".equals(v);
            pkgs.clear();
            if (!keep) pkgs.addAll(packages(v));
        }

        String value() {
            return keep ? "keep" : pkgs.isEmpty() ? "none" : String.join(",", pkgs);
        }

        List<String> ticked() {
            return keep ? found : pkgs;
        }

        void paint() {
            names.setText(keep ? "As found: " + labels(found) : labels(pkgs));
        }
    }

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
        for (String[] k : KNOBS) {
            if (k[0].equals("doze")) infoCard(root, "What is Doze?", DOZE_INFO);
            if (k[0].equals("exempt_sys")) appCard(root, exempt,
                    "Your apps that Doze leaves alone.\n"
                            + "Ticked: stays exempt (or becomes it): keeps its network, jobs and wakelocks while "
                            + "the phone sleeps.\n"
                            + "Unticked: loses its exemption and sleeps with the phone until the screen comes on "
                            + "or a maintenance window. Untick Tailscale, DevDeck, Termux or PhoneDeck and remote "
                            + "control stops while the phone sleeps.\n"
                            + "As found (Defaults): exemptions stay as they were before the optimiser.\n"
                            + "Apps in Keep these apps running (below) are always exempt.");
            knob(root, k);
            if (k[0].equals("exempt_sys")) appCard(root, allow,
                    "Made Unrestricted: exempt from Doze, and Android's background restriction is lifted too "
                            + "(Android kills a restricted app soon after it goes to the background, which cuts "
                            + "Brave's background play). Use it for apps that must keep working in the "
                            + "background. They cost battery while they do.");
        }
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

    /** A card whose title shows or hides an explanation when tapped (closed at first). */
    private void infoCard(LinearLayout parent, String title, String body) {
        LinearLayout c = card(parent);
        c.setClickable(true);
        c.setFocusable(true);
        TextView head = ui.text(title + "   ▾", 17, Ui.ACCENT, true);
        c.addView(head);
        TextView text = ui.text(body, 13.5f, Ui.FG, false);
        text.setPadding(0, ui.dp(8), 0, 0);
        text.setVisibility(View.GONE);
        c.addView(text);
        c.setOnClickListener(v -> {
            boolean open = text.getVisibility() != View.VISIBLE;
            text.setVisibility(open ? View.VISIBLE : View.GONE);
            head.setText(title + (open ? "   ▴" : "   ▾"));
        });
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

    /** An app-list card: the chosen apps and a button to pick them from the launcher apps. */
    private void appCard(LinearLayout parent, AppList a, String desc) {
        LinearLayout c = card(parent);
        cardHead(c, a.title, desc);
        a.names = ui.text("None", 15, Ui.FG, true);
        c.addView(a.names);
        TextView choose = ui.button("Choose apps", false);
        choose.setOnClickListener(v -> chooseApps(a));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins(0, ui.dp(10), 0, 0);
        c.addView(choose, lp);
        a.note = ui.text("", 12, Ui.MUTED, false);
        a.note.setPadding(ui.dp(4), ui.dp(6), 0, 0);
        c.addView(a.note);
    }

    /** App label of a package, or the package name if it can't be resolved. */
    private String appLabel(String pkg) {
        PackageManager pm = getPackageManager();
        try {
            return pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString();
        } catch (PackageManager.NameNotFoundException e) {
            return pkg;
        }
    }

    private String labels(List<String> pkgs) {
        if (pkgs.isEmpty()) return "None";
        StringBuilder b = new StringBuilder();
        for (String p : pkgs) b.append(b.length() == 0 ? "" : ", ").append(appLabel(p));
        return b.toString();
    }

    /** Lists the launcher apps (plus any ticked ones that aren't) off the main thread, then the picker. */
    private void chooseApps(AppList a) {
        if (!loaded) return;
        List<String> ticked = new ArrayList<>(a.ticked());
        new Thread(() -> {
            PackageManager pm = getPackageManager();
            Intent launcher = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
            Set<String> seen = new HashSet<>();
            List<String[]> apps = new ArrayList<>();
            for (ResolveInfo ri : pm.queryIntentActivities(launcher, 0)) {
                String p = ri.activityInfo.packageName;
                if (p.equals(getPackageName()) || !seen.add(p)) continue;
                apps.add(new String[]{ri.loadLabel(pm).toString(), p});
            }
            for (String p : ticked) if (seen.add(p)) apps.add(new String[]{appLabel(p), p});
            apps.sort((x, y) -> x[0].compareToIgnoreCase(y[0]));
            runOnUiThread(() -> showPicker(a, ticked, apps));
        }).start();
    }

    private void showPicker(AppList a, List<String> ticked, List<String[]> apps) {
        String[] names = new String[apps.size()];
        boolean[] checked = new boolean[apps.size()];
        for (int i = 0; i < apps.size(); i++) {
            names[i] = apps.get(i)[0];
            checked[i] = ticked.contains(apps.get(i)[1]);
        }
        new AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
                .setTitle(a.title)
                .setMultiChoiceItems(names, checked, (d, which, isChecked) -> checked[which] = isChecked)
                .setPositiveButton("OK", (d, w) -> {
                    a.keep = false;
                    a.pkgs.clear();
                    for (int i = 0; i < apps.size(); i++) if (checked[i]) a.pkgs.add(apps.get(i)[1]);
                    a.paint();
                    say("Press Apply to use them.", Ui.ACCENT);
                })
                .setNegativeButton("Cancel", null)
                .show();
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
            if (key.equals("exempt_sys")) {
                String removed = k.get("exempt_sys.removed");
                if (removed != null && !removed.isEmpty()) extra += "\nremoved: " + removed.replace(",", ", ");
            }
            notes.get(key).setText("now: " + label(key, k.get(key))
                    + (stock == null || stock.isEmpty() ? "" : "   stock: " + label(key, stock)) + extra);
            paintKnob(key);
        }
        freeze.setText(k.get(FREEZE + ".want"));
        defaults.put(FREEZE, k.get(FREEZE + ".default"));
        freezeNote.setText("default: " + k.get(FREEZE + ".default"));
        allow.set(k.get(ALLOW + ".want"));
        allow.paint();
        allow.note.setText("unrestricted now: " + labels(packages(k.get(ALLOW))));
        exempt.found.clear();
        exempt.found.addAll(packages(k.get(EXEMPT + ".apps")));
        exempt.set(k.get(EXEMPT + ".want"));
        exempt.paint();
        String removed = k.get(EXEMPT + ".removed"), added = k.get(EXEMPT + ".added");
        exempt.note.setText("exempt now: " + labels(exempt.found)
                + (removed == null || removed.isEmpty() ? "" : "\nremoved: " + labels(packages(removed)))
                + (added == null || added.isEmpty() ? "" : "\nadded: " + labels(packages(added))));
        paintPower();
    }

    /** "a,b" -> [a, b]; "none", empty or missing -> []. */
    private static List<String> packages(String v) {
        if (v == null || v.isEmpty() || v.equals("none")) return new ArrayList<>();
        return new ArrayList<>(Arrays.asList(v.split(",")));
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
        allow.set("none");
        allow.paint();
        exempt.set("keep");
        exempt.paint();
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
        for (AppList a : new AppList[]{exempt, allow}) {
            for (String p : a.pkgs) {
                if (!PACKAGE_OK.matcher(p).matches()) {
                    say(a.title + ": bad package name " + p, Ui.HOT);
                    return;
                }
            }
        }
        // Every value is a table entry or matched FREEZE_OK / PACKAGE_OK, so the line is shell-safe.
        StringBuilder args = new StringBuilder("apply");
        for (String[] s : KNOBS) args.append(' ').append(s[0]).append('=').append(chosen.get(s[0]));
        args.append(' ').append(FREEZE).append('=').append(f);
        args.append(' ').append(EXEMPT).append('=').append(exempt.value());
        args.append(' ').append(ALLOW).append('=').append(allow.value());
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
