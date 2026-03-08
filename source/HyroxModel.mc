import Toybox.System;
import Toybox.Timer;
import Toybox.Activity;
import Toybox.Application;
import Toybox.WatchUi;
import Toybox.Lang;

// ─── Colour palette ─────────────────────────────────────────────────────────
const COLOR_BG      = 0x120F0A;
const COLOR_YELLOW  = 0xE8D44D;
const COLOR_CYAN    = 0x4EC9D4;
const COLOR_ORANGE  = 0xE8863A;
const COLOR_RED     = 0xD94040;
const COLOR_CREAM   = 0xEAE0CD;
const COLOR_MUTED   = 0x948270;
const COLOR_SURFACE = 0x1E1810;
const COLOR_BORDER  = 0x3E3428;

// ─── App states ──────────────────────────────────────────────────────────────
// :ready | :active | :finish | :saved

class HyroxModel {

    // Screen geometry (set once at startup, used everywhere)
    var screenW;
    var screenH;
    var isRound;
    var centerX;
    var centerY;

    // Race state
    var state;
    var currentStep;
    var totalSteps;
    var splitTimer;    // seconds since last lap tap
    var totalTimer;    // seconds since session start
    var splits;        // Array of Dictionaries
    var hrValue;       // Number or null
    var showHR;        // Boolean — user setting
    var stations;      // Array of Dictionaries { "type", "label" }
    var simulationId;

    var _timer;

    function initialize() {
        var settings = System.getDeviceSettings();
        screenW  = settings.screenWidth;
        screenH  = settings.screenHeight;
        isRound  = (settings.screenShape == System.SCREEN_SHAPE_ROUND);
        centerX  = screenW / 2;
        centerY  = screenH / 2;

        state        = :ready;
        currentStep  = 0;
        splitTimer   = 0;
        totalTimer   = 0;
        splits       = [];
        hrValue      = null;
        simulationId = null;
        showHR       = true;
        _timer       = null;

        stations   = buildDefaultStations();
        totalSteps = stations.size();
    }

    // ── Station list ─────────────────────────────────────────────────────────

    function buildDefaultStations() {
        var names = [
            "Run 1",   "SkiErg",          "Run 2", "Sled Push",
            "Run 3",   "Sled Pull",        "Run 4", "Burpee Broad Jump",
            "Run 5",   "Rowing",           "Run 6", "Farmers Carry",
            "Run 7",   "Sandbag Lunges",   "Run 8", "Wall Balls"
        ];

        var seq = [];
        for (var i = 0; i < names.size(); i++) {
            seq.add({
                "type"  => (i % 2 == 0) ? "run" : "exercise",
                "label" => names[i]
            });
            if (i < names.size() - 1) {
                seq.add({
                    "type"  => "transition",
                    "label" => names[i] + " > " +names[i + 1]
                });
            }
        }
        return seq;
    }

    // Rebuild sequence from phone-provided station list (stations only, no transitions)
    function setStationsFromMessage(stationList) {
        stations = [];
        for (var i = 0; i < stationList.size(); i++) {
            stations.add(stationList[i]);
            if (i < stationList.size() - 1) {
                var trans = stationList[i]["label"] + " > " +stationList[i + 1]["label"];
                stations.add({ "type" => "transition", "label" => trans });
            }
        }
        totalSteps = stations.size();
    }

    // ── Session control ──────────────────────────────────────────────────────

    function startSession() {
        state       = :active;
        currentStep = 0;
        splitTimer  = 0;
        totalTimer  = 0;
        splits      = [];

        _timer = new Timer.Timer();
        _timer.start(method(:onTick), 1000, true);
    }

    function onTick() as Void {
        splitTimer++;
        totalTimer++;

        // Read heart rate
        var info = Activity.getActivityInfo();
        if (info != null && info.currentHeartRate != null) {
            hrValue = info.currentHeartRate;
        } else {
            hrValue = null;
        }

        WatchUi.requestUpdate();
    }

    // Called by delegate when the action button is pressed
    function advance() {
        if (state == :ready) {
            startSession();
            return;
        }

        if (state == :active) {
            var station   = stations[currentStep];
            var splitType = station["type"].equals("transition") ? "transition" : "station";

            splits.add({
                "order"    => splits.size() + 1,
                "type"     => splitType,
                "name"     => station["label"],
                "duration" => splitTimer
            });

            splitTimer  = 0;
            currentStep = currentStep + 1;

            if (currentStep >= totalSteps) {
                state = :finish;
                if (_timer != null) {
                    _timer.stop();
                    _timer = null;
                }
            }
        }
    }

    // ── Save & transmit ──────────────────────────────────────────────────────

    function saveAndTransmit() {
        var payload = {
            "type"        => "SESSION_COMPLETE",
            "simulationId" => (simulationId != null) ? simulationId : "standalone",
            "totalTime"   => totalTimer,
            "splits"      => splits
        };

        if ((Toybox has :Communications) && (Toybox.Communications has :transmitMessage)) {
            Toybox.Communications.transmitMessage(payload, {}, method(:onTransmitComplete));
        } else {
            // Phone not connected — persist locally so data isn't lost
            Application.Storage.setValue("pendingSplits", payload);
            state = :saved;
            WatchUi.requestUpdate();
        }
    }

    function onTransmitComplete(responseCode as Number, data as Dictionary?) as Void {
        state = :saved;
        WatchUi.requestUpdate();
        // Brief delay then exit (handled by view rendering "Saved!")
        var exitTimer = new Timer.Timer();
        exitTimer.start(method(:doExit), 2000, false);
    }

    function doExit() as Void {
        System.exit();
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function getCurrentAccentColor() {
        if (state == :ready || state == :finish || state == :saved) {
            return COLOR_YELLOW;
        }
        if (currentStep < totalSteps) {
            var t = stations[currentStep]["type"];
            if (t.equals("run"))        { return COLOR_CYAN;   }
            if (t.equals("exercise"))   { return COLOR_YELLOW; }
            if (t.equals("transition")) { return COLOR_YELLOW; }
        }
        return COLOR_CREAM;
    }

    function getProgress() {
        if (totalSteps == 0) { return 0.0f; }
        return currentStep.toFloat() / totalSteps.toFloat();
    }

    function formatTime(seconds) {
        var h = seconds / 3600;
        var m = (seconds % 3600) / 60;
        var s = seconds % 60;
        if (h > 0) {
            return h.format("%d") + ":" + m.format("%02d") + ":" + s.format("%02d");
        }
        return m.format("%d") + ":" + s.format("%02d");
    }
}
