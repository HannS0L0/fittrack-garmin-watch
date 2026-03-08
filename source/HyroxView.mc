import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Lang;

class HyroxView extends WatchUi.View {

    function initialize() {
        View.initialize();
    }

    function onLayout(dc as Graphics.Dc) as Void {
        // Programmatic layout only — no XML layouts used
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var W  = gModel.screenW;
        var H  = gModel.screenH;
        var cx = gModel.centerX;
        var cy = gModel.centerY;
        var round = gModel.isRound;

        // ── Background ────────────────────────────────────────────────────────
        dc.setColor(COLOR_BG, COLOR_BG);
        dc.clear();

        // ── Route to correct screen ───────────────────────────────────────────
        var s = gModel.state;
        if (s == :ready) {
            drawReady(dc, W, H, cx, cy);
        } else if (s == :active) {
            drawActive(dc, W, H, cx, cy, round);
        } else if (s == :finish) {
            drawFinish(dc, W, H, cx, cy);
        } else if (s == :saved) {
            drawSaved(dc, W, H, cx, cy);
        }
    }

    // ── Font helpers (scale by screen width) ──────────────────────────────────

    function getBigFont(W as Number) as Graphics.FontType {
        if (W >= 260) { return Graphics.FONT_NUMBER_HOT;       }
        if (W >= 218) { return Graphics.FONT_NUMBER_THAI_HOT;  }
        return Graphics.FONT_NUMBER_MEDIUM;
    }

    function getLabelFont(W as Number) as Graphics.FontType {
        if (W >= 240) { return Graphics.FONT_SMALL; }
        return Graphics.FONT_TINY;
    }

    function getNameFont(W as Number) as Graphics.FontType {
        if (W >= 260) { return Graphics.FONT_MEDIUM; }
        return Graphics.FONT_SMALL;
    }

    // ── Screen 1: Ready ───────────────────────────────────────────────────────

    function drawReady(dc as Graphics.Dc, W as Number, H as Number,
                       cx as Number, cy as Number) as Void {
        // "FITTRACK" — small spaced label
        dc.setColor(COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (H * 0.33).toNumber(),
            Graphics.FONT_TINY, "F I T T R A C K",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // "HYROX" — large bold yellow
        dc.setColor(COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (H * 0.48).toNumber(),
            Graphics.FONT_LARGE, "HYROX",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // START pill button
        var btnW = (W * 0.58).toNumber();
        var btnH = (H * 0.14).toNumber();
        var btnX = cx - btnW / 2;
        var btnY = (H * 0.64).toNumber();
        dc.setColor(COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(btnX, btnY, btnW, btnH, btnH / 2);
        dc.setColor(COLOR_BG, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, btnY + btnH / 2,
            Graphics.FONT_SMALL, "> START",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ── Screen 2 / 3 / 4: Active (Run / Exercise / Transition) ───────────────

    function drawActive(dc as Graphics.Dc, W as Number, H as Number,
                        cx as Number, cy as Number,
                        isRound as Boolean) as Void {
        var station = gModel.stations[gModel.currentStep];
        var sType   = station["type"] as String;
        var sLabel  = station["label"] as String;
        var accent  = gModel.getCurrentAccentColor();
        var isTrans = sType.equals("transition");

        // Tag label row — shifted up slightly
        var tagText = isTrans ? "TRANSITION" : (sType.equals("run") ? "RUN" : "EXERCISE");
        var tagY    = isRound ? (H * 0.16).toNumber() : 14;
        dc.setColor(accent, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, tagY, getLabelFont(W), tagText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Station name
        var nameY    = isRound ? (H * 0.27).toNumber() : (tagY + 22);
        var nameFont = isTrans ? Graphics.FONT_TINY : getNameFont(W);
        var nameCol  = isTrans ? COLOR_MUTED : COLOR_CREAM;
        dc.setColor(nameCol, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, nameY, nameFont, sLabel,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Big split timer
        var bigFont = isTrans ? getNameFont(W) : getBigFont(W);
        var timerY  = isRound ? (H * 0.47).toNumber() : (H * 0.45).toNumber();
        dc.setColor(accent, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, timerY, bigFont,
            gModel.formatTime(gModel.splitTimer),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Total elapsed sub-row
        var totalY = isRound ? (H * 0.64).toNumber() : (H * 0.62).toNumber();
        dc.setColor(COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, totalY, Graphics.FONT_TINY,
            "Total  " + gModel.formatTime(gModel.totalTimer),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Progress bar above HR
        drawProgressBar(dc, W, H, accent);

        // HR pill at bottom
        if (gModel.showHR) {
            drawHRPill(dc, W, H, cx);
        }
    }

    // ── Progress bar — thin full-width bar at the bottom ─────────────────────

    function drawProgressBar(dc as Graphics.Dc, W as Number, H as Number,
                              accent as Number) as Void {
        var barY = (H * 0.74).toNumber();
        var barH = 4;

        // Track
        dc.setColor(COLOR_BORDER, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, barY, W, barH);

        // Fill
        var fillW = (gModel.getProgress() * W).toNumber();
        if (fillW > 0) {
            dc.setColor(accent, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(0, barY, fillW, barH);
        }
    }

    // ── HR pill ───────────────────────────────────────────────────────────────

    function drawHRPill(dc as Graphics.Dc, W as Number, H as Number,
                        cx as Number) as Void {
        var pillW = (W * 0.36).toNumber();
        var pillH = 26;
        var pillX = cx - pillW / 2;
        var pillY = (H * 0.87).toNumber() - pillH / 2;

        dc.setColor(COLOR_SURFACE, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(pillX, pillY, pillW, pillH, 13);

        var hrStr = (gModel.hrValue != null)
            ? ("HR " + gModel.hrValue.format("%d"))
            : "HR --";
        dc.setColor(COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, pillY + pillH / 2,
            Graphics.FONT_TINY, hrStr,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ── Screen 5: Finish ──────────────────────────────────────────────────────

    function drawFinish(dc as Graphics.Dc, W as Number, H as Number,
                        cx as Number, cy as Number) as Void {
        dc.setColor(COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (H * 0.24).toNumber(),
            getNameFont(W), "DONE",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(COLOR_CREAM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - (H * 0.04).toNumber(),
            getBigFont(W), gModel.formatTime(gModel.totalTimer),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (H * 0.62).toNumber(),
            Graphics.FONT_TINY, "total time",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        var btnW = (W * 0.52).toNumber();
        var btnH = (H * 0.12).toNumber();
        var btnX = cx - btnW / 2;
        var btnY = (H * 0.74).toNumber();
        dc.setColor(COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(btnX, btnY, btnW, btnH, 10);
        dc.setColor(COLOR_BG, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, btnY + btnH / 2,
            getNameFont(W), "SAVE",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ── Screen: Saved confirmation ────────────────────────────────────────────

    function drawSaved(dc as Graphics.Dc, W as Number, H as Number,
                       cx as Number, cy as Number) as Void {
        dc.setColor(COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - (H * 0.08).toNumber(),
            getNameFont(W), "Saved!",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(COLOR_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy + (H * 0.08).toNumber(),
            Graphics.FONT_TINY, "Sync complete",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
