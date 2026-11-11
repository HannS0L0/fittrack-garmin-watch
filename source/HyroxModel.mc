import Toybox.System;
import Toybox.Timer;
import Toybox.Activity;
import Toybox.Application;
import Toybox.Math;
import Toybox.UserProfile;
import Toybox.Time;
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

// ─── Heart rate recording ───────────────────────────────────────────────────
// The whole-session HR trace is averaged into buckets of HR_BUCKET_START_S
// seconds. At HR_MAX_SAMPLES the trace is halved (pairs merged) and the
// bucket doubles, so the result stays small however long the session runs.
// 540 keeps memory low on older watches (S60) while giving the same detail
// as 720 for real sims: 1 h 15 → 450 points at 10 s, 2 h → 360 at 20 s.
// Never more than 539 points held or sent.
const HR_BUCKET_START_S = 5;
const HR_MAX_SAMPLES    = 540;

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
    var simulationName;
    var hrZones;       // Array of zone upper bounds from UserProfile, or null

    // HR recording — sent with the result
    var hrSamples;        // Array of Number|null: bucket averages, whole session
    var hrInterval;       // seconds per hrSamples entry
    var _hrBucketSum;
    var _hrBucketCount;
    var _hrBucketTicks;
    var _splitHrSum;      // current split
    var _splitHrCount;
    var _splitHrMax;
    var _sessionHrSum;    // whole session
    var _sessionHrCount;
    var _sessionHrMax;

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

        simulationName  = null;
        hrZones         = null;
        resetHr();

        stations   = buildDefaultStations();
        totalSteps = stations.size();

        loadSession();
    }

    // ── Loaded simulation (persisted so it survives the app being reopened) ──

    function saveSession() as Void {
        Application.Storage.setValue("session", {
            "simulationId"   => simulationId,
            "simulationName" => simulationName,
            "stations"       => stations
        });
    }

    function loadSession() as Void {
        var s = Application.Storage.getValue("session") as Dictionary?;
        if (s == null || s["stations"] == null) { return; }
        simulationId   = s["simulationId"];
        simulationName = s["simulationName"];
        stations       = s["stations"] as Array;
        totalSteps     = stations.size();
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
        resetHr();

        if (UserProfile has :getHeartRateZones) {
            hrZones = UserProfile.getHeartRateZones(UserProfile.HR_ZONE_SPORT_GENERIC);
        }

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
        recordHr(hrValue);

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

            var split = {
                "order"    => splits.size() + 1,
                "type"     => splitType,
                "name"     => station["label"],
                "duration" => splitTimer
            };
            if (_splitHrCount > 0) {
                split["avgHr"] = Math.round(_splitHrSum.toFloat() / _splitHrCount).toNumber();
                split["maxHr"] = _splitHrMax;
            }
            splits.add(split);

            splitTimer    = 0;
            _splitHrSum   = 0;
            _splitHrCount = 0;
            _splitHrMax   = 0;
            currentStep = currentStep + 1;

            if (currentStep >= totalSteps) {
                state = :finish;
                if (_timer != null) {
                    _timer.stop();
                    _timer = null;
                }
                flushHrBucket();
            }
        }
    }

    // ── Save ─────────────────────────────────────────────────────────────────

    // Queue the result for sync. It stays in watch Storage until the phone
    // app or Supabase confirms it, so nothing is lost if the phone is out of
    // range, the app is closed, or the session ran for hours.
    function saveAndTransmit() {
        state = :saved;
        gSync.onSynced = method(:onSynced);

        var now = Time.now().value();
        var payload = {
            "type"         => "SESSION_COMPLETE",
            "resultId"     => now.format("%d") + "-" + (Math.rand() % 100000).format("%d"),
            "simulationId" => (simulationId != null) ? simulationId : "standalone",
            "totalTime"    => totalTimer,
            "completedAt"  => now,   // Unix epoch seconds, UTC
            "splits"       => splits    // each may carry avgHr / maxHr
        };
        // HR: only when the watch got readings, so older app/server code
        // that doesn't know these keys sees exactly the old payload otherwise
        if (_sessionHrCount > 0) {
            payload["hrSamples"]  = hrSamples;
            payload["hrInterval"] = hrInterval;
            payload["avgHr"]      = Math.round(_sessionHrSum.toFloat() / _sessionHrCount).toNumber();
            payload["maxHr"]      = _sessionHrMax;
        }
        gSync.enqueue(payload);
        WatchUi.requestUpdate();
    }

    // Close the app shortly after the sync is confirmed. If it can't sync yet
    // the Saved screen stays up; BACK exits and the queue retries next launch.
    function onSynced() as Void {
        gSync.onSynced = null;
        _timer = new Timer.Timer();
        _timer.start(method(:doExit), 2000, false);
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
        resetHr();
        WatchUi.requestUpdate();
    }

    // ── Heart rate recording ─────────────────────────────────────────────────

    function resetHr() as Void {
        hrSamples       = [];
        hrInterval      = HR_BUCKET_START_S;
        _hrBucketSum    = 0;
        _hrBucketCount  = 0;
        _hrBucketTicks  = 0;
        _splitHrSum     = 0;
        _splitHrCount   = 0;
        _splitHrMax     = 0;
        _sessionHrSum   = 0;
        _sessionHrCount = 0;
        _sessionHrMax   = 0;
    }

    // Once per second while active; hr is the current reading or null
    function recordHr(hr) as Void {
        if (hr != null && hr > 0) {
            _hrBucketSum    += hr;
            _hrBucketCount  += 1;
            _splitHrSum     += hr;
            _splitHrCount   += 1;
            _sessionHrSum   += hr;
            _sessionHrCount += 1;
            if (hr > _splitHrMax)   { _splitHrMax   = hr; }
            if (hr > _sessionHrMax) { _sessionHrMax = hr; }
        }
        _hrBucketTicks += 1;
        if (_hrBucketTicks >= hrInterval) {
            flushHrBucket();
        }
    }

    // Close the bucket in progress (null when it had no readings)
    function flushHrBucket() as Void {
        if (_hrBucketTicks == 0) { return; }
        if (_hrBucketCount > 0) {
            hrSamples.add(Math.round(_hrBucketSum.toFloat() / _hrBucketCount).toNumber());
        } else {
            hrSamples.add(null);
        }
        _hrBucketSum   = 0;
        _hrBucketCount = 0;
        _hrBucketTicks = 0;
        if (hrSamples.size() >= HR_MAX_SAMPLES) {
            compactHrSamples();
        }
    }

    // Merge neighbouring pairs: half the points, double the interval
    function compactHrSamples() as Void {
        var merged = [];
        for (var i = 0; i < hrSamples.size(); i += 2) {
            var a = hrSamples[i];
            var b = (i + 1 < hrSamples.size()) ? hrSamples[i + 1] : null;
            if (a != null && b != null) {
                merged.add(Math.round((a + b) / 2.0f).toNumber());
            } else if (a != null) {
                merged.add(a);
            } else {
                merged.add(b);
            }
        }
        hrSamples  = merged;
        hrInterval = hrInterval * 2;
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
            if (t.equals("transition")) { return COLOR_ORANGE; }
        }
        return COLOR_CREAM;
    }

    // ── Display helpers ──────────────────────────────────────────────────────

    // Standard HYROX targets for the watch's built-in station names. Labels
    // from the phone carry their own target in brackets: "Sled Push (50m)".
    function standardTarget(name as String) {
        var targets = {
            "SkiErg" => "1000m", "Sled Push" => "50m", "Sled Pull" => "50m",
            "Burpee Broad Jump" => "80m", "Rowing" => "1000m",
            "Farmers Carry" => "200m", "Sandbag Lunges" => "100m",
            "Wall Balls" => "100 reps"
        };
        return targets[name];
    }

    // "Sled Push (50m)" → "Sled Push"
    function stationName(label as String) as String {
        var i = label.find(" (");
        return (i != null) ? label.substring(0, i) : label;
    }

    // "Sled Push (50m)" → "50m"; built-in names use the standard table
    function stationTarget(label as String) {
        var i = label.find(" (");
        if (i != null && label.substring(label.length() - 1, label.length()).equals(")")) {
            return label.substring(i + 2, label.length() - 1);
        }
        return standardTarget(label);
    }

    // 1-based position of step among steps of the same type, plus the total
    // of that type: RUN 3 / 8, STATION 2 / 8.
    function typeIndex(step as Number) as Array {
        var type = stations[step]["type"];
        var index = 0;
        var total = 0;
        for (var i = 0; i < stations.size(); i++) {
            if (stations[i]["type"].equals(type)) {
                total++;
                if (i <= step) { index++; }
            }
        }
        return [index, total];
    }

    function countType(type as String) as Number {
        var n = 0;
        for (var i = 0; i < stations.size(); i++) {
            if (stations[i]["type"].equals(type)) { n++; }
        }
        return n;
    }

    // Name of the next run/station after step, or null at the end
    function nextName(step as Number) {
        for (var i = step + 1; i < stations.size(); i++) {
            var s = stations[i];
            if (s["type"].equals("run")) {
                return "Run " + typeIndex(i)[0].format("%d");
            }
            if (s["type"].equals("exercise")) {
                return stationName(s["label"] as String);
            }
        }
        return null;
    }

    // Target of the next run/station (e.g. "50m"), or null
    function nextTarget(step as Number) {
        for (var i = step + 1; i < stations.size(); i++) {
            var s = stations[i];
            if (s["type"].equals("run")) { return "1km"; }
            if (s["type"].equals("exercise")) { return stationTarget(s["label"] as String); }
        }
        return null;
    }

    // Seconds spent on runs / stations / transitions — splits[i] is stations[i]
    function timeByType(type as String) as Number {
        var sum = 0;
        for (var i = 0; i < splits.size() && i < stations.size(); i++) {
            if (stations[i]["type"].equals(type)) {
                sum += splits[i]["duration"] as Number;
            }
        }
        return sum;
    }

    // HR zone 1–5 from the user's Garmin profile, or null if unknown
    function hrZone() {
        if (hrValue == null || hrZones == null || hrZones.size() < 6) { return null; }
        if (hrValue < hrZones[0]) { return null; }
        for (var z = 1; z <= 5; z++) {
            if (hrValue <= hrZones[z]) { return z; }
        }
        return 5;
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
