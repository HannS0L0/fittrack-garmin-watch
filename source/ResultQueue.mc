import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;

// ─── Unsent result queue ────────────────────────────────────────────────────
// Every finished session is stored on the watch until it is CONFIRMED saved:
//   • Supabase answered 201 (or 409: already stored) to the direct POST, or
//   • the phone app replied RESULT_SAVED after saving it.
// A successful Communications.transmit only means Garmin Connect accepted the
// message, not that the phone app stored it, so it doesn't clear the result.
// Each result carries a clientResultId; hyrox_results has a unique index on
// (user_id, client_result_id), so re-sending one never creates a duplicate.
//
// Storage layout: "pendingKeys" => ["r_<id>", ...] (oldest first), and one
// entry per result under its key — one value each keeps every Storage value
// small on low-memory watches.

const PENDING_KEYS_KEY  = "pendingKeys";
const LEGACY_PENDING_KEY = "pendingSplits";
const MAX_PENDING        = 5;
const FLUSH_TIMEOUT_MS   = 20000;

class ResultQueue {

    var _flushing;
    var _flushKeys;
    var _flushIndex;
    var _onDone;     // Method() called once a flush ends
    var _timeout;

    function initialize() {
        _flushing   = false;
        _flushKeys  = [];
        _flushIndex = 0;
        _onDone     = null;
        _timeout    = null;
    }

    // ── Storage ──────────────────────────────────────────────────────────────

    function newResultId() as String {
        return Time.now().value().format("%d") + "-" + (System.getTimer() % 1000000).format("%d");
    }

    function getKeys() as Array {
        var keys = Application.Storage.getValue(PENDING_KEYS_KEY);
        keys = (keys == null) ? [] : keys as Array;

        // One-off migration of the old single-slot "pendingSplits"
        var legacy = Application.Storage.getValue(LEGACY_PENDING_KEY);
        if (legacy != null) {
            Application.Storage.deleteValue(LEGACY_PENDING_KEY);
            var p = legacy as Dictionary;
            if (p["clientResultId"] == null) { p["clientResultId"] = newResultId(); }
            keys = storeResult(keys, p);
        }
        return keys;
    }

    function storeResult(keys as Array, payload as Dictionary) as Array {
        var key = "r_" + payload["clientResultId"];
        Application.Storage.setValue(key, payload);
        keys.add(key);
        // Bounded: on a full queue the oldest result gives way
        while (keys.size() > MAX_PENDING) {
            Application.Storage.deleteValue(keys[0]);
            var rest = [];
            for (var i = 1; i < keys.size(); i++) { rest.add(keys[i]); }
            keys = rest;
        }
        Application.Storage.setValue(PENDING_KEYS_KEY, keys);
        return keys;
    }

    function enqueue(payload as Dictionary) as Void {
        storeResult(getKeys(), payload);
    }

    // Result confirmed stored (by Supabase or by the phone app): forget it
    function confirm(clientResultId) as Void {
        if (clientResultId == null) { return; }
        var key = "r_" + clientResultId;
        var keys = getKeys();
        var kept = [];
        for (var i = 0; i < keys.size(); i++) {
            if (!(keys[i] as String).equals(key)) { kept.add(keys[i]); }
        }
        Application.Storage.deleteValue(key);
        Application.Storage.setValue(PENDING_KEYS_KEY, kept);
    }

    function count() as Number {
        return getKeys().size();
    }

    // ── Flush ────────────────────────────────────────────────────────────────

    // Send every unconfirmed result, oldest first, one at a time (watches
    // allow only a few transfers in flight). onDone (Method or null) runs when
    // the flush ends — finished, stopped by an error, or timed out.
    function flush(onDone) as Void {
        if (_flushing) {
            // Already running; still honour a caller that is waiting to exit
            if (onDone != null) { _onDone = onDone; }
            return;
        }
        _flushing   = true;
        _onDone     = onDone;
        _flushKeys  = getKeys();
        _flushIndex = 0;

        _timeout = new Timer.Timer();
        _timeout.start(method(:onFlushTimeout), FLUSH_TIMEOUT_MS, false);

        sendNext();
    }

    function sendNext() as Void {
        if (!_flushing) { return; }
        if (_flushIndex >= _flushKeys.size()) { finish(); return; }

        var payload = Application.Storage.getValue(_flushKeys[_flushIndex]);
        if (payload == null) { advance(); return; }
        var p = payload as Dictionary;

        // 1. Direct to Supabase when the phone gave us credentials this run:
        //    the only path that confirms the row is stored.
        if (gModel.hasWebCredentials() && (Toybox.Communications has :makeWebRequest)) {
            var body = gModel.buildDbRow(p, gModel.userId);
            if (body != null) {
                Communications.makeWebRequest(
                    // select=id: a small JSON reply (an empty 201 body can surface as a
                    // body-parse error code instead of 201)
                    gModel.supabaseUrl + "/rest/v1/hyrox_results?on_conflict=user_id,client_result_id&select=id",
                    body,
                    {
                        :method       => Communications.HTTP_REQUEST_METHOD_POST,
                        :headers      => {
                            "Content-Type"  => "application/json",
                            "apikey"        => gModel.supabaseAnonKey,
                            "Authorization" => "Bearer " + gModel.accessToken,
                            "Prefer"        => "return=representation,resolution=ignore-duplicates"
                        },
                        :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
                    },
                    method(:onWebComplete)
                );
                return;
            }
            // No real simulation id for a standalone session yet: try the phone app
        }

        // 2. Hand it to the phone app, which saves it and replies RESULT_SAVED
        if (Toybox has :Communications) {
            Communications.transmit(p, null, new ResultTransmitListener(self));
            return;
        }

        finish();
    }

    function onWebComplete(responseCode as Number, data as Dictionary?) as Void {
        if (!_flushing) { return; }
        if (responseCode == 201 || responseCode == 200 || responseCode == 409) {
            var p = Application.Storage.getValue(_flushKeys[_flushIndex]);
            if (p != null) { confirm((p as Dictionary)["clientResultId"]); }
            advance();
        } else {
            // Offline / token expired: keep the rest queued for the next try
            finish();
        }
    }

    // From ResultTransmitListener
    function onTransmitted(ok as Boolean) as Void {
        if (!_flushing) { return; }
        if (ok) { advance(); } else { finish(); }
    }

    function advance() as Void {
        _flushIndex++;
        sendNext();
    }

    function onFlushTimeout() as Void {
        finish();
    }

    function finish() as Void {
        if (!_flushing) { return; }
        _flushing = false;
        if (_timeout != null) { _timeout.stop(); _timeout = null; }
        var cb = _onDone;
        _onDone = null;
        if (cb != null) { cb.invoke(); }
    }
}

class ResultTransmitListener extends Communications.ConnectionListener {
    var _queue;

    function initialize(queue) {
        ConnectionListener.initialize();
        _queue = queue;
    }

    function onComplete() as Void {
        _queue.onTransmitted(true);
    }

    function onError() as Void {
        _queue.onTransmitted(false);
    }
}
