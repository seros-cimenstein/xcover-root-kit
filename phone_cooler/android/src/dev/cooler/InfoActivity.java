package dev.cooler;

import android.app.Activity;
import android.os.Bundle;
import android.widget.ScrollView;
import android.widget.TextView;

/** Short info screen plus the live {@code cool.sh status}; opening it also raises Magisk's root prompt. */
public class InfoActivity extends Activity {
    private static final String INFO =
            "Cooler caps the CPU and GPU clocks so the phone runs colder.\n\n"
                    + "Add the tile: pull down the panel twice, tap the pencil (edit), drag \"Cooler\" "
                    + "into the active tiles. Each tap cycles Off > Mild > Cool > Cold.\n\n"
                    + "Off: stock clocks. Mild: big cores 1.9 GHz, GPU 764 MHz. Cool: little 1.46 GHz, "
                    + "big 1.51 GHz, GPU 572 MHz. Cold: little 1.22 GHz, big 1.25 GHz, GPU 455 MHz.\n\n"
                    + "Needs root (allow Cooler in the Magisk prompt) and the phone_cooler scripts "
                    + "installed from the laptop.\n\n";

    private TextView text;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        text = new TextView(this);
        int pad = (int) (20 * getResources().getDisplayMetrics().density);
        text.setPadding(pad, pad, pad, pad);
        text.setTextSize(16);
        ScrollView scroll = new ScrollView(this);
        scroll.addView(text);
        setContentView(scroll);
    }

    @Override
    protected void onResume() {
        super.onResume();
        text.setText(INFO + "Status: checking...");
        new Thread(() -> {
            String status = Cool.run("status");
            runOnUiThread(() -> text.setText(INFO + "Status:\n" + status));
        }).start();
    }
}
