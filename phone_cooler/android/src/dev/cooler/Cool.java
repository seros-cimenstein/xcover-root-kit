package dev.cooler;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;

/** Runs the root script /data/adb/phone-cooler/cool.sh through Magisk's su. Blocking: call off the main thread. */
final class Cool {
    static final String SCRIPT = "/data/adb/phone-cooler/cool.sh";
    static final String NO_ROOT = "No root";
    static final String NOT_INSTALLED = "Not installed";
    private static final String MISSING = "missing-script";
    /** Printed after the script with its exit code; its absence means su itself failed or was denied. */
    private static final String RC = "\ncool-rc=";

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
    }

    private Cool() {}

    /** Runs {@code cool.sh <args>} as root. */
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

    /** "cool" -> "Cool"; anything that is not a profile name comes back unchanged. */
    static String label(String profile) {
        switch (profile) {
            case "off": return "Off";
            case "mild": return "Mild";
            case "cool": return "Cool";
            case "cold": return "Cold";
            case "custom": return "Custom";
            default: return profile;
        }
    }

    static boolean isProfile(String s) {
        return s.equals("off") || s.equals("mild") || s.equals("cool") || s.equals("cold") || s.equals("custom");
    }

    private static String readAll(InputStream in) throws IOException {
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        byte[] b = new byte[1024];
        for (int n; (n = in.read(b)) > 0; ) buf.write(b, 0, n);
        return buf.toString("UTF-8");
    }
}
