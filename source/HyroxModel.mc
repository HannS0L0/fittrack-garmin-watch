import Toybox.System;
import Toybox.Timer;
import Toybox.Activity;
import Toybox.Application;
import Toybox.Communications;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Sensor;
import Toybox.ActivityRecording;

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
// The whole-workout HR series is averaged into buckets of HR_BUCKET_START_S
// seconds. When the series reaches HR_MAX_SAMPLES it is halved (pairs merged)
// and the bucket doubles, so payload + memory stay bounded however long the
// session runs (720 points ≈ 1 h at 5 s, 2 h at 10 s, ...).
const HR_BUCKET_START_S = 5;
const HR_MAX_SAMPLES    = 720;

// ─── Garmin Connect activity type ────────────────────────────────────────────
// FIT profile values, used as numbers because the named constants moved
// from ActivityRecording to Activity in newer SDKs.
const FIT_SPORT_TRAINING            = 10;
const FIT_SUB_SPORT_CARDIO_TRAINING = 26;

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

    // HR recording
    var hrSamples;        // Array of Number|null — bucket averages for the whole session
    var hrInterval;       // seconds per hrSamples entry
    var _hrBucketSum;     // running sum for the bucket in progress
    var _hrBucketCount;   // valid readings in the bucket in progress
    var _hrBucketTicks;   // ticks elapsed in the bucket in progress
    var _splitHrSum;      // running sum for the current split
    var _splitHrCount;
    var _splitHrMax;
    var _sessionHrSum;    // running sum for the whole session
    var _sessionHrCount;
    var _sessionHrMax;

    // Auth credentials sent from phone with START_SESSION (used for makeWebRequest fallback)
    var userId;
    var supabaseUrl;
    var supabaseAnonKey;
    var accessToken;

    var _timer;

    var queue;            // ResultQueue — unsent results, kept until confirmed saved
    var _saving;          // true from Save until exit — ignores repeat presses
    var _activity;        // ActivityRecording.Session — the Garmin Connect activity

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

        resetHr();
        queue      = new ResultQueue();
        _saving    = false;
        _activity  = null;

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
        resetHr();
        startActivity();

        _timer = new Timer.Timer();
        _timer.start(method(:onTick), 1000, true);
    }

    function onTick() as Void {
        splitTimer++;
        totalTimer++;

        hrValue = readHeartRate();
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
                stopActivity();
            } else {
                lapActivity();
            }
        }
    }

    // ── Garmin Connect activity ──────────────────────────────────────────────
    // The sim is also recorded as a normal Garmin activity (one lap per run,
    // station and transition), so it shows in Garmin Connect with HR, calories
    // and training load. Saved on Save; discarded if the app closes unsaved.

    function startActivity() as Void {
        if (!(Toybox has :ActivityRecording) || _activity != null) { return; }
        _activity = ActivityRecording.createSession({
            :name    => "HYROX",
            :sport   => FIT_SPORT_TRAINING,
            :subSport => FIT_SUB_SPORT_CARDIO_TRAINING
        });
        _activity.start();
    }

    function lapActivity() as Void {
        if (_activity != null && _activity.isRecording() && (_activity has :addLap)) {
            _activity.addLap();
        }
    }

    function stopActivity() as Void {
        if (_activity != null && _activity.isRecording()) {
            _activity.stop();
        }
    }

    function saveActivity() as Void {
        if (_activity == null) { return; }
        stopActivity();
        _activity.save();
        _activity = null;
    }

    function discardActivity() as Void {
        if (_activity == null) { return; }
        stopActivity();
        _activity.discard();
        _activity = null;
    }

    // ── Heart rate ───────────────────────────────────────────────────────────

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

    // Called once per second while active. hr is the current reading or null.
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

    // Close the bucket in progress (null when no valid readings landed in it)
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

    // Merge neighbouring pairs, halving the series and doubling the interval
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

    function getAvgHr() {
        if (_sessionHrCount == 0) { return null; }
        return Math.round(_sessionHrSum.toFloat() / _sessionHrCount).toNumber();
    }

    function getMaxHr() {
        if (_sessionHrCount == 0) { return null; }
        return _sessionHrMax;
    }

    // ── Save & transmit ──────────────────────────────────────────────────────

    function saveAndTransmit() {
        // Sending can take a few seconds; a second press must not queue a copy
        if (_saving) { return; }
        _saving = true;

        var payload = {
            "type"           => "SESSION_COMPLETE",
            "clientResultId" => queue.newResultId(),
            "completedAt"    => Time.now().value(),
            "simulationId"   => (simulationId != null) ? simulationId : "standalone",
            "totalTime"      => totalTimer,
            "splits"         => splits,
            "hrSamples"      => hrSamples,
            "hrInterval"     => hrInterval,
            "avgHr"          => getAvgHr(),
            "maxHr"          => getMaxHr()
        };

        saveActivity();

        // Persist first: the result stays on the watch until Supabase or the
        // phone app confirms it is stored (see ResultQueue). Then send this one
        // along with anything older still unsent, and exit when that's done.
        queue.enqueue(payload);
        queue.flush(method(:onSaveFlushed));
    }

    function onSaveFlushed() as Void {
        state = :saved;
        WatchUi.requestUpdate();
        // Brief delay then exit (view renders "Saved!")
        var exitTimer = new Timer.Timer();
        exitTimer.start(method(:doExit), 2000, false);
    }

    function hasWebCredentials() as Boolean {
        return userId != null && supabaseUrl != null
            && supabaseAnonKey != null && accessToken != null;
    }

    // ── Heart rate sensor ────────────────────────────────────────────────────

    // Switch the optical HR sensor on explicitly. Without this some watches
    // never report HR to a watch app that isn't recording an activity.
    function enableHrSensor() as Void {
        if (Toybox has :Sensor) {
            Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
        }
    }

    function disableHrSensor() as Void {
        if (Toybox has :Sensor) {
            Sensor.setEnabledSensors([]);
        }
    }

    function readHeartRate() {
        var info = Activity.getActivityInfo();
        if (info != null && info.currentHeartRate != null) {
            return info.currentHeartRate;
        }
        if (Toybox has :Sensor) {
            var sensorInfo = Sensor.getInfo();
            if (sensorInfo != null && sensorInfo.heartRate != null) {
                return sensorInfo.heartRate;
            }
        }
        return null;
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
        discardActivity();
        WatchUi.requestUpdate();
    }

    function doExit() as Void {
        System.exit();
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    // Convert a SESSION_COMPLETE payload into a hyrox_results row for the
    // direct Supabase POST (ResultQueue).
    // simulation_id must be a real id: a standalone session uses the phone's
    // "Watch Session" simulation (sent with START_SESSION and kept in Storage).
    // Returns null when there is none yet — the caller keeps the result pending.
    function buildDbRow(payload as Dictionary, uid) as Dictionary? {
        var simId = payload["simulationId"];
        if (simId == null || simId.equals("standalone")) {
            simId = Application.Storage.getValue("standaloneSimId");
            if (simId == null) { return null; }
        }

        var rawSplits = payload["splits"] as Array;
        var dbSplits = [];
        for (var i = 0; i < rawSplits.size(); i++) {
            var s = rawSplits[i] as Dictionary;
            var row = {
                "order"   => s["order"],
                "type"    => s["type"],
                "label"   => s["name"],
                "time_ms" => (s["duration"] as Number) * 1000
            };
            if (s["avgHr"] != null) { row["avg_hr"] = s["avgHr"]; }
            if (s["maxHr"] != null) { row["max_hr"] = s["maxHr"]; }
            dbSplits.add(row);
        }
        var body = {
            "user_id"       => uid,
            "client_result_id" => payload["clientResultId"],
            "simulation_id" => simId,
            "total_time_ms" => (payload["totalTime"] as Number) * 1000,
            "completed_at"  => formatUtc(payload["completedAt"]),
            "splits"        => dbSplits
        };
        var samples = payload["hrSamples"];
        if (samples != null && (samples as Array).size() > 0) {
            body["hr_samples"]    = samples;
            body["hr_interval_s"] = payload["hrInterval"];
            body["avg_hr"]        = payload["avgHr"];
            body["max_hr"]        = payload["maxHr"];
        }
        return body;
    }

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

    // ISO-8601 UTC timestamp for a Unix-seconds value (now if null). Uses
    // utcInfo: the old code formatted LOCAL time and labelled it "Z".
    function formatUtc(epochSeconds) as String {
        var moment = (epochSeconds != null) ? new Time.Moment(epochSeconds) : Time.now();
        var t = Gregorian.utcInfo(moment, Time.FORMAT_SHORT);
        return t.year.format("%04d") + "-"
            + (t.month as Number).format("%02d") + "-"
            + t.day.format("%02d") + "T"
            + t.hour.format("%02d") + ":"
            + t.min.format("%02d") + ":"
            + t.sec.format("%02d") + "Z";
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
