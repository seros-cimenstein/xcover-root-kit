package dev.cooler;

import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Live temperatures, clocks and online cores, filled from {@code cool.sh status}. */
final class Readout {
    private static final Pattern CLOCK = Pattern.compile("^(LITTLE|BIG|GPU): (\\d+) MHz now, max (\\d+) MHz", Pattern.MULTILINE);
    private static final Pattern TEMP = Pattern.compile("(BIG|LITTLE|G3D|battery) ([\\d.]+)C");
    private static final Pattern CORES = Pattern.compile("^cores online: ([\\d ]+)$", Pattern.MULTILINE);

    private final TextView tempBig, tempLittle, tempGpu, tempBattery, clockLittle, clockBig, clockGpu, cores;

    /** Adds the readout to {@code parent}; compact is the one-screen version above the manual controls. */
    Readout(Ui ui, LinearLayout parent, boolean compact) {
        if (compact) {
            LinearLayout r1 = ui.row(parent);
            tempBig = ui.stat(r1, "Big", true);
            tempLittle = ui.stat(r1, "Little", true);
            tempGpu = ui.stat(r1, "GPU", true);
            tempBattery = ui.stat(r1, "Battery", true);
            LinearLayout r2 = ui.row(parent);
            clockLittle = ui.stat(r2, "Little MHz", true);
            clockBig = ui.stat(r2, "Big MHz", true);
            clockGpu = ui.stat(r2, "GPU MHz", true);
        } else {
            ui.header(parent, "TEMPERATURE", 18);
            LinearLayout r1 = ui.row(parent);
            tempBig = ui.stat(r1, "Big cores", false);
            tempLittle = ui.stat(r1, "Little cores", false);
            LinearLayout r2 = ui.row(parent);
            tempGpu = ui.stat(r2, "GPU", false);
            tempBattery = ui.stat(r2, "Battery", false);
            ui.header(parent, "CLOCKS (NOW / MAX)", 14);
            LinearLayout r3 = ui.row(parent);
            clockLittle = ui.stat(r3, "Little", false);
            clockBig = ui.stat(r3, "Big", false);
            clockGpu = ui.stat(r3, "GPU", false);
        }
        cores = ui.text("Cores online: -", 13, Ui.MUTED, false);
        cores.setPadding(ui.dp(4), ui.dp(compact ? 2 : 6), 0, 0);
        parent.addView(cores);
    }

    void show(String status) {
        Matcher c = CLOCK.matcher(status);
        while (c.find()) {
            String v = c.group(2) + " / " + c.group(3);
            switch (c.group(1)) {
                case "LITTLE": clockLittle.setText(v); break;
                case "BIG": clockBig.setText(v); break;
                default: clockGpu.setText(v); break;
            }
        }
        Matcher t = TEMP.matcher(status);
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
            view.setTextColor(deg >= 70 ? Ui.HOT : deg >= 55 ? Ui.WARM : Ui.OK);
        }
        Matcher o = CORES.matcher(status);
        if (o.find()) cores.setText("Cores online: " + o.group(1).trim());
    }
}
