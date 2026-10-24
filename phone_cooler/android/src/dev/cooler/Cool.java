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

    private Cool() {}

    /**
     * Runs {@code cool.sh <args>} as root and returns its trimmed output, or {@link #NO_ROOT} (no su,
     * su denied or timed out) or {@link #NOT_INSTALLED} (script absent).
     */
    static String run(String args) {
        String sh = "if [ -x " + SCRIPT + " ]; then exec " + SCRIPT + " " + args + "; else echo " + MISSING + "; fi";
        Process p;
        try {
            p = new ProcessBuilder("su", "-c", sh).redirectErrorStream(true).start();
        } catch (IOException e) {
            return NO_ROOT;
        }
        try {
            p.getOutputStream().close();
            // The first call waits on Magisk's prompt; Magisk denies by itself after its timeout.
            String out = readAll(p.getInputStream()).trim();
            int rc = p.waitFor();
            if (out.equals(MISSING)) return NOT_INSTALLED;
            return rc == 0 ? out : NO_ROOT;
        } catch (IOException | InterruptedException e) {
            p.destroy();
            return NO_ROOT;
        }
    }

    /** "cool" -> "Cool"; anything that is not a profile name comes back unchanged. */
    static String label(String profile) {
        switch (profile) {
            case "off": return "Off";
            case "mild": return "Mild";
            case "cool": return "Cool";
            case "cold": return "Cold";
            default: return profile;
        }
    }

    static boolean isProfile(String s) {
        return s.equals("off") || s.equals("mild") || s.equals("cool") || s.equals("cold");
    }

    private static String readAll(InputStream in) throws IOException {
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        byte[] b = new byte[1024];
        for (int n; (n = in.read(b)) > 0; ) buf.write(b, 0, n);
        return buf.toString("UTF-8");
    }
}
