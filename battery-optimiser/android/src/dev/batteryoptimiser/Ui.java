package dev.batteryoptimiser;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.widget.LinearLayout;
import android.widget.TextView;

/** The dark look of the Battery screen (same as phone_cooler's): colors and small view builders. */
final class Ui {
    static final int BG = 0xff0d1117, CARD = 0xff161b22, BORDER = 0xff30363d, SELECTED = 0xff10283d;
    static final int FG = 0xffe6edf3, MUTED = 0xff8b949e, ACCENT = 0xff58a6ff;
    static final int OK = 0xff3fb950, WARM = 0xffd29922, HOT = 0xfff85149;

    private final Context context;
    private final float density;

    Ui(Context context) {
        this.context = context;
        density = context.getResources().getDisplayMetrics().density;
    }

    int dp(float v) {
        return Math.round(v * density);
    }

    GradientDrawable box(int fill, int stroke, float radiusDp) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(fill);
        d.setCornerRadius(dp(radiusDp));
        d.setStroke(dp(1.5f), stroke);
        return d;
    }

    GradientDrawable box(int fill, int stroke) {
        return box(fill, stroke, 14);
    }

    TextView text(String s, float sp, int color, boolean bold) {
        TextView t = new TextView(context);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        return t;
    }

    /** A small bold caption above a group, e.g. "TEMPERATURE". */
    TextView header(LinearLayout parent, String s, float topDp) {
        TextView t = text(s, 12, MUTED, true);
        t.setPadding(dp(4), dp(topDp), 0, dp(2));
        parent.addView(t);
        return t;
    }

    LinearLayout row(LinearLayout parent) {
        LinearLayout r = new LinearLayout(context);
        r.setOrientation(LinearLayout.HORIZONTAL);
        parent.addView(r);
        return r;
    }

    /** A value tile in a readout row; returns its value view. Compact tiles are smaller. */
    TextView stat(LinearLayout row, String label, boolean compact) {
        LinearLayout cell = new LinearLayout(context);
        cell.setOrientation(LinearLayout.VERTICAL);
        int ph = dp(compact ? 8 : 12), pv = dp(compact ? 5 : 10);
        cell.setPadding(ph, pv, ph, pv);
        cell.setBackground(box(CARD, BORDER, compact ? 10 : 14));
        cell.addView(text(label, compact ? 11 : 12, MUTED, false));
        TextView value = text("-", compact ? 15 : 20, FG, true);
        value.setSingleLine();
        cell.addView(value);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        int m = dp(compact ? 3 : 4);
        lp.setMargins(m, m, m, m);
        row.addView(cell, lp);
        return value;
    }

    /** A rounded button; filled ones are the primary action. */
    TextView button(String label, boolean filled) {
        TextView b = text(label, 16, filled ? BG : FG, true);
        b.setGravity(Gravity.CENTER);
        b.setPadding(dp(12), dp(12), dp(12), dp(12));
        b.setBackground(filled ? box(ACCENT, ACCENT, 12) : box(CARD, BORDER, 12));
        b.setClickable(true);
        b.setFocusable(true);
        return b;
    }
}
