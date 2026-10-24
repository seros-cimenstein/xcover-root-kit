package dev.cooler;

import android.os.Handler;
import android.os.Looper;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Quick Settings tile: a tap cycles Off -> Mild -> Cool -> Cold (-> Custom once saved) via {@code cool.sh next}. */
public class CoolerTile extends TileService {
    /** One worker, so taps run in order and never overlap. */
    private static final ExecutorService WORKER = Executors.newSingleThreadExecutor();
    /** Last answer from the script; shown at once while a fresh one is fetched. */
    private static volatile String last;

    private final Handler main = new Handler(Looper.getMainLooper());

    @Override
    public void onStartListening() {
        if (last != null) show(last);
        WORKER.execute(() -> deliver(Cool.run("get").out));
    }

    @Override
    public void onClick() {
        WORKER.execute(() -> deliver(Cool.run("next").out));
    }

    private void deliver(String result) {
        last = result;
        main.post(() -> show(result));
    }

    private void show(String result) {
        Tile tile = getQsTile();
        if (tile == null) return; // not listening anymore; onStartListening refreshes next time
        boolean profile = Cool.isProfile(result);
        tile.setLabel("Cooler");
        tile.setSubtitle(profile ? Cool.label(result) : errorText(result));
        tile.setState(profile && !result.equals("off") ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        tile.updateTile();
    }

    private static String errorText(String result) {
        return result.equals(Cool.NO_ROOT) || result.equals(Cool.NOT_INSTALLED) ? result : "Error";
    }
}
