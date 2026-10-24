package dev.batteryoptimiser;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;

/** Runs the root script /data/adb/battery-optimiser/battery.sh through Magisk's su. Blocking: call off the main thread. */
final class Bat {
    static final String SCRIPT = "/data/adb/battery-optimiser/battery.sh";
    static final String NO_ROOT = "No root";
    static final String NOT_INSTALLED = "Not installed";
    private static final String MISSING = "missing-script";
    /** Printed after the script with its exit code; its absence means su itself failed or was denied. */
    private static final String RC = "\nbat-rc=";

    /** Output of one script run. */
    static final class Result {
        /** The script's exit code, or -1 with {@link #out} = {@link #NO_ROOT} or {@link #NOT_INSTALLED}. */
        final int rc;
        /** Trimmed stdout and stderr. */
        final String out;

        Result(int rc, String out) {
            this.rc = rc;
            this.out = out;
        }

        boolean ok() {
            return rc == 0;
        }

        /** The script could not run at all (no root, or not installed). */
        boolean unavailable() {
            return rc == -1;
        }
    }

    private Bat() {}

    /** Runs {@code battery.sh <args>} as root. Args must already be shell-safe. */
    static Result run(String args) {
        String sh = "if [ -x " + SCRIPT + " ]; then " + SCRIPT + " " + args + "; echo \"" + RC.substring(1)
                + "$?\"; else echo " + MISSING + "; fi";
        Process p;
        try {
            p = new ProcessBuilder("su", "-c", sh).redirectErrorStream(true).start();
        } catch (IOException e) {
            return new Result(-1, NO_ROOT);
        }
        try {
            p.getOutputStream().close();
            // The first call waits on Magisk's prompt; Magisk denies by itself after its timeout.
            String out = "\n" + readAll(p.getInputStream()).trim();
            p.waitFor();
            if (out.equals("\n" + MISSING)) return new Result(-1, NOT_INSTALLED);
            int at = out.lastIndexOf(RC);
            if (at < 0) return new Result(-1, NO_ROOT);
            int rc;
            try {
                rc = Integer.parseInt(out.substring(at + RC.length()).trim());
            } catch (NumberFormatException e) {
                return new Result(-1, NO_ROOT);
            }
            return new Result(rc, out.substring(0, at).trim());
        } catch (IOException | InterruptedException e) {
            p.destroy();
            return new Result(-1, NO_ROOT);
        }
    }

    /** "key=value" lines -> map (the first '=' splits; later lines win). */
    static Map<String, String> pairs(String out) {
        Map<String, String> m = new HashMap<>();
        for (String line : out.split("\n")) {
            int eq = line.indexOf('=');
            if (eq > 0) m.put(line.substring(0, eq), line.substring(eq + 1));
        }
        return m;
    }

    private static String readAll(InputStream in) throws IOException {
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        byte[] b = new byte[1024];
        for (int n; (n = in.read(b)) > 0; ) buf.write(b, 0, n);
        return buf.toString("UTF-8");
    }
}
