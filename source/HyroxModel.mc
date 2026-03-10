import Toybox.System;
import Toybox.Timer;
import Toybox.Activity;
import Toybox.Application;
import Toybox.Communications;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;
import Toybox.Lang;

// ─── Colour palette ─────────────────────────────────────────────────────────
const COLOR_BG      = 0x120F0A;
const COLOR_YELLOW  = 0xE8D44D;
const COLOR_CYAN    = 0x4EC9D4;
const COLOR_MINT    = 0x2ECC71;
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

    // Auth credentials sent from phone with START_SESSION (used for makeWebRequest fallback)
    var userId;
    var supabaseUrl;
    var supabaseAnonKey;
    var accessToken;

    var _timer;

    function initialize() {
        var settings = System.getDeviceSettings();
        screenW  = settings.screenWidth;
        screenH  = settings.screenHeight;
        isRound  = (settings.screenShape == System.SCREEN_SHAPE_ROUND);
        centerX  = screenW / 2;
        centerY  = screenH / 2;

        state           = :ready;
        currentStep     = 0;
        splitTimer      = 0;
        totalTimer      = 0;
        splits          = [];
        hrValue         = null;
        simulationId    = null;
        showHR          = true;
        _timer          = null;
        userId          = null;
        supabaseUrl     = null;
        supabaseAnonKey = null;
        accessToken     = null;

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

        // Always persist locally first so data survives if the phone isn't
        // connected or the transmission fails silently.
        Application.Storage.setValue("pendingSplits", payload);

        if ((Toybox has :Communications) && (Toybox.Communications has :transmitMessage)) {
            Toybox.Communications.transmitMessage(payload, {}, method(:onTransmitComplete));
        } else if ((Toybox has :Communications) && (Toybox.Communications has :makeWebRequest)
                   && userId != null && supabaseUrl != null
                   && supabaseAnonKey != null && accessToken != null) {
            // Older watches (e.g. Approach S60): POST directly to Supabase via the
            // Garmin Connect HTTP relay (Bluetooth → phone → internet).
            var now = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
            var completedAt = now.year.format("%04d") + "-"
                + now.month.format("%02d") + "-"
                + now.day.format("%02d") + "T"
                + now.hour.format("%02d") + ":"
                + now.min.format("%02d") + ":"
                + now.sec.format("%02d") + "Z";

            var dbSplits = [];
            for (var i = 0; i < splits.size(); i++) {
                var s = splits[i] as Dictionary;
                dbSplits.add({
                    "order"   => s["order"],
                    "type"    => s["type"],
                    "label"   => s["name"],
                    "time_ms" => s["duration"] * 1000
                });
            }

            var body = {
                "user_id"       => userId,
                "simulation_id" => (simulationId != null) ? simulationId : "standalone",
                "total_time_ms" => totalTimer * 1000,
                "completed_at"  => completedAt,
                "splits"        => dbSplits
            };
            var headers = {
                "Content-Type"  => "application/json",
                "apikey"        => supabaseAnonKey,
                "Authorization" => "Bearer " + accessToken,
                "Prefer"        => "return=minimal"
            };
            Communications.makeWebRequest(
                supabaseUrl + "/rest/v1/hyrox_results",
                body,
                {
                    :method       => Communications.HTTP_REQUEST_METHOD_POST,
                    :headers      => headers,
                    :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
                },
                method(:onWebRequestComplete)
            );
        } else {
            state = :saved;
            WatchUi.requestUpdate();
        }
    }

    function onWebRequestComplete(responseCode as Number, data as Dictionary?) as Void {
        // 201 = HTTP Created — Supabase REST API successfully stored the result.
        // Clear the local copy so it isn't resent on QUERY_PENDING.
        if (responseCode == 201) {
            Application.Storage.deleteValue("pendingSplits");
        }
        state = :saved;
        WatchUi.requestUpdate();
        var exitTimer = new Timer.Timer();
        exitTimer.start(method(:doExit), 2000, false);
    }

    function discard() as Void {
        if (_timer != null) {
            _timer.stop();
            _timer = null;
        }
        state       = :ready;
        currentStep = 0;
        splitTimer  = 0;
        totalTimer  = 0;
        splits      = [];
        WatchUi.requestUpdate();
    }

    function onTransmitComplete(responseCode as Number, data as Dictionary?) as Void {
        // 200 = Communications.SUCCESS — phone received the message cleanly.
        // On success, clear the local copy so it isn't resent on QUERY_PENDING.
        if (responseCode == 200) {
            Application.Storage.deleteValue("pendingSplits");
        }
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
            if (t.equals("exercise"))   { return COLOR_MINT;   }
            if (t.equals("transition")) { return COLOR_ORANGE; }
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
