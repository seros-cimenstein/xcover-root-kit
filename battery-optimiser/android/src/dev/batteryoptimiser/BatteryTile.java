package dev.batteryoptimiser;

import android.os.Handler;
import android.os.Looper;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Quick Settings tile: a tap switches the optimiser on/off via {@code battery.sh toggle}. */
public class BatteryTile extends TileService {
    /** One worker, so taps run in order and never overlap. */
    private static final ExecutorService WORKER = Executors.newSingleThreadExecutor();
    /** Last answer from the script; shown at once while a fresh one is fetched. */
    private static volatile String last;

    private final Handler main = new Handler(Looper.getMainLooper());

    @Override
    public void onStartListening() {
        if (last != null) show(last);
        WORKER.execute(() -> deliver(Bat.run("get").out));
    }

    @Override
    public void onClick() {
        // Applying or restoring takes a few seconds (settings, Bluetooth, DeviceConfig).
        show("...");
        WORKER.execute(() -> {
            Bat.Result r = Bat.run("toggle");
            String[] lines = r.out.split("\n");
            deliver(r.unavailable() ? r.out : lines[lines.length - 1].trim());
        });
    }

    private void deliver(String result) {
        last = result;
        main.post(() -> show(result));
    }

    private void show(String result) {
        Tile tile = getQsTile();
        if (tile == null) return; // not listening anymore; onStartListening refreshes next time
        boolean on = result.equals("on");
        tile.setLabel("Battery");
        switch (result) {
            case "on": tile.setSubtitle("Optimised"); break;
            case "off": tile.setSubtitle("Stock"); break;
            case "...": tile.setSubtitle("Switching..."); break;
            case Bat.NO_ROOT: case Bat.NOT_INSTALLED: tile.setSubtitle(result); break;
            default: tile.setSubtitle("Error");
        }
        tile.setState(on ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        tile.updateTile();
    }
}
