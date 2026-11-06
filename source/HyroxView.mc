import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Math;
import Toybox.System;
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
        if (dc has :setAntiAlias) {
            dc.setAntiAlias(true);
        }

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

    // ── Layout helpers ────────────────────────────────────────────────────────

    // Usable text width at height y: the chord of a round screen, less a margin
    function widthAt(y as Number) as Number {
        var W = gModel.screenW;
        if (!gModel.isRound) { return W - 12; }
        var r  = W / 2;
        var dy = y - gModel.centerY;
        if (dy < 0) { dy = -dy; }
        if (dy >= r) { return 0; }
        return (2 * Math.sqrt(r * r - dy * dy)).toNumber() - 16;
    }

    // Largest font from the list that fits text on the line at y
    function fitFont(dc as Graphics.Dc, text as String, fonts as Array, y as Number) as Graphics.FontType {
        var maxW = widthAt(y);
        for (var i = 0; i < fonts.size(); i++) {
            if (dc.getTextWidthInPixels(text, fonts[i]) <= maxW) {
                return fonts[i];
            }
        }
        return fonts[fonts.size() - 1];
    }

    function drawCentered(dc as Graphics.Dc, x as Number, y as Number,
                          font as Graphics.FontType, text as String, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, font, text,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // One centred line made of differently styled pieces: [[text, font, color], …]
    function drawSegments(dc as Graphics.Dc, cx as Number, y as Number, segs as Array) as Void {
        var total = 0;
        for (var i = 0; i < segs.size(); i++) {
            total += dc.getTextWidthInPixels(segs[i][0], segs[i][1]);
        }
        var x = cx - total / 2;
        for (var i = 0; i < segs.size(); i++) {
            dc.setColor(segs[i][2], Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, y, segs[i][1], segs[i][0],
                Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
            x += dc.getTextWidthInPixels(segs[i][0], segs[i][1]);
        }
    }

    function truncateLabel(label as String, maxLen as Number) as String {
        if (label.length() > maxLen) {
            return label.substring(0, maxLen - 3) + "...";
        }
        return label;
    }

    // ── Progress: ring round the bezel (round) or bar (rectangular) ──────────

    function drawRing(dc as Graphics.Dc, cx as Number, cy as Number,
                      progress as Float, color as Number) as Void {
        var r = cx - 4;
        dc.setPenWidth(6);
        dc.setColor(COLOR_SURFACE, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy, r);

        var sweep = (360 * progress).toNumber();
        if (sweep > 0) {
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            if (sweep >= 360) {
                dc.drawCircle(cx, cy, r);
            } else {
                // Clockwise from 12 o'clock
                dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, 90, (90 - sweep + 360) % 360);
            }
        }
        dc.setPenWidth(1);
    }

    function drawProgressBar(dc as Graphics.Dc, W as Number, H as Number,
                              accent as Number) as Void {
        var barY = 4;
        var barH = 4;
        dc.setColor(COLOR_SURFACE, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, barY, W, barH);
        var fillW = (gModel.getProgress() * W).toNumber();
        if (fillW > 0) {
            dc.setColor(accent, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(0, barY, fillW, barH);
        }
    }

    function drawProgress(dc as Graphics.Dc, W as Number, H as Number, cx as Number,
                          cy as Number, progress as Float, color as Number) as Void {
        if (gModel.isRound) {
            drawRing(dc, cx, cy, progress, color);
        } else {
            drawProgressBar(dc, W, H, color);
        }
    }

    // Small notch next to the START key (top-right on most Garmin watches)
    function drawStartMarker(dc as Graphics.Dc, cx as Number, cy as Number) as Void {
        if (!gModel.isRound) { return; }
        dc.setPenWidth(6);
        dc.setColor(COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, cy, cx - 4, Graphics.ARC_COUNTER_CLOCKWISE, 20, 45);
        dc.setPenWidth(1);
    }

    function drawHR(dc as Graphics.Dc, cx as Number, y as Number) as Void {
        if (!gModel.showHR) { return; }
        var hr = (gModel.hrValue != null) ? gModel.hrValue.format("%d") : "--";
        var zone = gModel.hrZone();
        if (zone != null) {
            drawSegments(dc, cx, y, [
                [hr, Graphics.FONT_TINY, COLOR_RED],
                [" Z" + zone.format("%d"), Graphics.FONT_XTINY, COLOR_MUTED]
            ]);
        } else {
            drawCentered(dc, cx, y, Graphics.FONT_TINY, hr, COLOR_RED);
        }
    }

    function drawNext(dc as Graphics.Dc, cx as Number, y as Number) as Void {
        var next = gModel.nextName(gModel.currentStep);
        if (next == null) {
            drawCentered(dc, cx, y, Graphics.FONT_XTINY, "LAST ONE", COLOR_MUTED);
            return;
        }
        drawSegments(dc, cx, y, [
            ["NEXT ", Graphics.FONT_XTINY, COLOR_MUTED],
            [next, Graphics.FONT_TINY, COLOR_CREAM]
        ]);
    }

    // ── Screen 1: Ready ───────────────────────────────────────────────────────

    function drawReady(dc as Graphics.Dc, W as Number, H as Number,
                       cx as Number, cy as Number) as Void {
        drawStartMarker(dc, cx, cy);

        drawCentered(dc, cx, (H * 0.19).toNumber(), Graphics.FONT_XTINY,
            "FITTRACK HYROX", COLOR_MUTED);

        var nameY = (H * 0.34).toNumber();
        var name = (gModel.simulationName != null)
            ? (gModel.simulationName as String).toUpper() : "HYROX";
        drawCentered(dc, cx, nameY,
            fitFont(dc, name, [Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL], nameY),
            name, COLOR_CREAM);

        drawCentered(dc, cx, (H * 0.46).toNumber(), Graphics.FONT_XTINY,
            gModel.countType("run").format("%d") + " runs, "
                + gModel.countType("exercise").format("%d") + " stations",
            COLOR_MUTED);

        // START pill
        var btnW = (W * 0.62).toNumber();
        var btnH = (H * 0.15).toNumber();
        var btnY = (H * 0.56).toNumber();
        dc.setColor(COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cx - btnW / 2, btnY, btnW, btnH, btnH / 2);
        drawCentered(dc, cx, btnY + btnH / 2, Graphics.FONT_SMALL, "START", COLOR_BG);

        // Phone link + anything still waiting to sync
        var linked = System.getDeviceSettings().phoneConnected;
        var statusY = (H * 0.80).toNumber();
        var statusText = linked ? "Phone linked" : "No phone";
        var statusCol = linked ? COLOR_MINT : COLOR_MUTED;
        var tw = dc.getTextWidthInPixels(statusText, Graphics.FONT_XTINY);
        dc.setColor(statusCol, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx - tw / 2 - 7, statusY, 3);
        drawCentered(dc, cx + 4, statusY, Graphics.FONT_XTINY, statusText, statusCol);

        var pending = gSync.pendingCount();
        if (pending > 0) {
            drawCentered(dc, cx, (H * 0.89).toNumber(), Graphics.FONT_XTINY,
                pending.format("%d") + " unsynced", COLOR_ORANGE);
        }
    }

    // ── Screens 2 / 3 / 4: Run, Station, Roxzone ─────────────────────────────

    function drawActive(dc as Graphics.Dc, W as Number, H as Number,
                        cx as Number, cy as Number,
                        isRound as Boolean) as Void {
        var step    = gModel.currentStep;
        var station = gModel.stations[step];
        var sType   = station["type"] as String;
        var accent  = gModel.getCurrentAccentColor();

        drawProgress(dc, W, H, cx, cy, gModel.getProgress(), accent);

        if (sType.equals("transition")) {
            drawRoxzone(dc, W, H, cx, accent);
            return;
        }

        var idx = gModel.typeIndex(step);
        var isRun = sType.equals("run");
        var tag = (isRun ? "RUN " : "STATION ")
            + idx[0].format("%d") + " / " + idx[1].format("%d");
        drawCentered(dc, cx, (H * 0.18).toNumber(), getLabelFont(W), tag, accent);

        var total = gModel.formatTime(gModel.totalTimer);

        if (isRun) {
            drawCentered(dc, cx, (H * 0.42).toNumber(), getBigFont(W),
                gModel.formatTime(gModel.splitTimer), accent);
            drawSegments(dc, cx, (H * 0.61).toNumber(), [
                ["TOTAL ", Graphics.FONT_XTINY, COLOR_MUTED],
                [total, Graphics.FONT_SMALL, COLOR_CREAM]
            ]);
            drawNext(dc, cx, (H * 0.73).toNumber());
            drawHR(dc, cx, (H * 0.86).toNumber());
            return;
        }

        // Station: name, timer, target + total
        var label = station["label"] as String;
        var nameY = (H * 0.29).toNumber();
        var name = gModel.stationName(label).toUpper();
        drawCentered(dc, cx, nameY,
            fitFont(dc, name, [getNameFont(W), Graphics.FONT_TINY, Graphics.FONT_XTINY], nameY),
            name, COLOR_CREAM);

        drawCentered(dc, cx, (H * 0.48).toNumber(), getBigFont(W),
            gModel.formatTime(gModel.splitTimer), accent);

        var segs = [];
        var target = gModel.stationTarget(label);
        if (target != null) {
            segs.add([target + "   ", Graphics.FONT_TINY, COLOR_CREAM]);
        }
        segs.add(["TOTAL ", Graphics.FONT_XTINY, COLOR_MUTED]);
        segs.add([total, Graphics.FONT_TINY, COLOR_CREAM]);
        drawSegments(dc, cx, (H * 0.65).toNumber(), segs);

        drawNext(dc, cx, (H * 0.76).toNumber());
        drawHR(dc, cx, (H * 0.875).toNumber());
    }

    // Roxzone: "what's next" is the biggest thing on screen
    function drawRoxzone(dc as Graphics.Dc, W as Number, H as Number,
                         cx as Number, accent as Number) as Void {
        drawCentered(dc, cx, (H * 0.18).toNumber(), getLabelFont(W), "ROXZONE", accent);
        drawCentered(dc, cx, (H * 0.40).toNumber(), getBigFont(W),
            gModel.formatTime(gModel.splitTimer), accent);

        var next = gModel.nextName(gModel.currentStep);
        if (next == null) { next = "FINISH"; }
        next = (next as String).toUpper();

        drawCentered(dc, cx, (H * 0.58).toNumber(), Graphics.FONT_XTINY, "NEXT", COLOR_MUTED);
        var nextY = (H * 0.70).toNumber();
        drawCentered(dc, cx, nextY,
            fitFont(dc, next, [Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL, Graphics.FONT_TINY], nextY),
            next, COLOR_CREAM);

        var nextTarget = gModel.nextTarget(gModel.currentStep);
        if (nextTarget != null) {
            drawCentered(dc, cx, (H * 0.81).toNumber(), Graphics.FONT_XTINY, nextTarget, COLOR_MUTED);
        }
        drawHR(dc, cx, (H * 0.91).toNumber());
    }

    // ── Screen 5: Finish ──────────────────────────────────────────────────────

    function drawFinish(dc as Graphics.Dc, W as Number, H as Number,
                        cx as Number, cy as Number) as Void {
        drawProgress(dc, W, H, cx, cy, 1.0f, COLOR_YELLOW);

        drawCentered(dc, cx, (H * 0.19).toNumber(), getLabelFont(W), "DONE", COLOR_YELLOW);

        // Sized to fit past the hour mark (1:04:12)
        var totalY = (H * 0.36).toNumber();
        var total = gModel.formatTime(gModel.totalTimer);
        drawCentered(dc, cx, totalY,
            fitFont(dc, total, [getBigFont(W), Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD], totalY),
            total, COLOR_CREAM);

        // Run / station / Roxzone breakdown
        var colX = [cx - (W * 0.25).toNumber(), cx, cx + (W * 0.25).toNumber()];
        var labels = ["RUN", "STN", "ROX"];
        var colors = [COLOR_CYAN, COLOR_YELLOW, COLOR_ORANGE];
        var secs = [gModel.timeByType("run"), gModel.timeByType("exercise"), gModel.timeByType("transition")];
        for (var i = 0; i < 3; i++) {
            drawCentered(dc, colX[i], (H * 0.49).toNumber(), Graphics.FONT_XTINY, labels[i], colors[i]);
            drawCentered(dc, colX[i], (H * 0.57).toNumber(), Graphics.FONT_TINY,
                gModel.formatTime(secs[i]), COLOR_CREAM);
        }

        // SAVE button
        var btnW = (W * 0.5).toNumber();
        var btnH = (H * 0.13).toNumber();
        var btnY = (H * 0.68).toNumber();
        dc.setColor(COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cx - btnW / 2, btnY, btnW, btnH, btnH / 2);
        drawCentered(dc, cx, btnY + btnH / 2, Graphics.FONT_SMALL, "SAVE", COLOR_BG);

        drawCentered(dc, cx, (H * 0.90).toNumber(), Graphics.FONT_XTINY, "BACK to discard", COLOR_MUTED);
    }

    // ── Screen: Saved ─────────────────────────────────────────────────────────

    function drawSaved(dc as Graphics.Dc, W as Number, H as Number,
                       cx as Number, cy as Number) as Void {
        drawProgress(dc, W, H, cx, cy, 0.0f, COLOR_MINT);

        // Check mark: the result is safe on the watch either way
        var s  = W / 240.0;
        var iy = (H * 0.30).toNumber();
        dc.setPenWidth(4);
        dc.setColor(COLOR_MINT, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, iy, (22 * s).toNumber());
        dc.drawLine(cx - (11 * s).toNumber(), iy, cx - (3 * s).toNumber(), iy + (8 * s).toNumber());
        dc.drawLine(cx - (3 * s).toNumber(), iy + (8 * s).toNumber(), cx + (12 * s).toNumber(), iy - (8 * s).toNumber());
        dc.setPenWidth(1);

        var titleY = (H * 0.49).toNumber();
        drawCentered(dc, cx, titleY,
            fitFont(dc, "Saved on watch", [Graphics.FONT_MEDIUM, Graphics.FONT_SMALL, Graphics.FONT_TINY], titleY),
            "Saved on watch", COLOR_CREAM);

        // Real sync state
        var status = gSync.status;
        var statusY = (H * 0.62).toNumber();
        if (status == :synced) {
            drawCentered(dc, cx, statusY, Graphics.FONT_TINY, "Synced to app", COLOR_MINT);
        } else if (status == :waiting) {
            drawCentered(dc, cx, statusY, Graphics.FONT_TINY, "Waiting for phone", COLOR_ORANGE);
            drawCentered(dc, cx, (H * 0.73).toNumber(), Graphics.FONT_XTINY, "Syncs automatically", COLOR_MUTED);
            drawCentered(dc, cx, (H * 0.83).toNumber(), Graphics.FONT_XTINY, "BACK to exit", COLOR_MUTED);
        } else {
            drawCentered(dc, cx, statusY, Graphics.FONT_TINY, "Syncing...", COLOR_MUTED);
        }
    }
}
