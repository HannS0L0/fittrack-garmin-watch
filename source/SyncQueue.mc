import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

// ─── Store-and-forward result sync ──────────────────────────────────────────
// Same idea as Garmin Connect activity sync: a finished session is written to
// Storage first and only deleted once it is confirmed saved, either by
//   1. the phone app (it replies SESSION_ACK after Supabase has the row), or
//   2. a direct POST to Supabase (rpc/submit_watch_result) through the
//      Garmin Connect relay — works even when the FitTrack app is closed.
// Both paths carry the same resultId, so the server never stores it twice.
//
// Credentials are a long-lived watch token (not the 1 h Supabase access
// token), persisted in Storage so they survive the app being closed.

class SyncQueue {

    const OUTBOX_KEY    = "outbox";       // Array<String> of result ids
    const RESULT_PREFIX = "result_";      // "result_<id>" => payload
    const CREDS_KEY     = "creds";        // { watchToken, supabaseUrl, supabaseAnonKey }
    const LEGACY_KEY    = "pendingSplits"; // single slot used by older builds
    const MIN_BACKOFF   = 15000;
    const MAX_BACKOFF   = 300000;

    // :idle | :syncing | :synced | :waiting — drives the Saved screen
    var status = :idle;
    // Called after a result is confirmed synced (Model uses it to exit)
    var onSynced = null;

    private var _inFlightId = null;
    private var _timer = null;
    private var _backoffMs = MIN_BACKOFF;

    function initialize() {
    }

    // Call once from AppBase.onStart()
    function start() as Void {
        migrateLegacy();
        syncNow();
    }

    // Queue a SESSION_COMPLETE payload (must contain "resultId") and sync it.
    function enqueue(payload as Dictionary) as Void {
        var id = payload["resultId"] as String;
        Application.Storage.setValue(RESULT_PREFIX + id, payload);
        var ids = outbox();
        if (ids.indexOf(id) < 0) {
            ids.add(id);
            Application.Storage.setValue(OUTBOX_KEY, ids);
        }
        _backoffMs = MIN_BACKOFF;
        syncNow();
    }

    function pendingCount() as Number {
        return outbox().size();
    }

    // Feed every phone message through here (from registerForPhoneAppMessages).
    function handlePhoneMessage(data as Dictionary) as Void {
        if (data["watchToken"] != null && data["supabaseUrl"] != null
            && data["supabaseAnonKey"] != null) {
            Application.Storage.setValue(CREDS_KEY, {
                "watchToken"      => data["watchToken"],
                "supabaseUrl"     => data["supabaseUrl"],
                "supabaseAnonKey" => data["supabaseAnonKey"]
            });
        }

        var type = data["type"];
        if ("SESSION_ACK".equals(type)) {
            if (data["resultId"] != null) {
                markSynced(data["resultId"] as String);
            }
        } else if ("QUERY_PENDING".equals(type) || "CREDENTIALS".equals(type)
                   || "START_SESSION".equals(type)) {
            // Fresh credentials and/or the phone asking — retry right away.
            _backoffMs = MIN_BACKOFF;
            syncNow();
        }
    }

    // Try to sync the oldest queued result. Safe to call at any time.
    function syncNow() as Void {
        if (_inFlightId != null) { return; }

        var ids = outbox();
        if (ids.size() == 0) { return; }

        var id = ids[0] as String;
        var payload = Application.Storage.getValue(RESULT_PREFIX + id);
        if (payload == null) {
            removeId(id);
            syncNow();
            return;
        }

        setStatus(:syncing);

        // Path 1: hand it to the phone app. Delivery isn't confirmation —
        // we wait for SESSION_ACK, which only comes after Supabase saved it.
        Communications.transmit(payload, null, new SyncTransmitListener());

        // Path 2: upload directly.
        var creds = Application.Storage.getValue(CREDS_KEY) as Dictionary?;
        if (creds == null) {
            // No token yet (session started without the phone). The phone
            // path above may still save it; otherwise we wait for credentials.
            scheduleRetry();
            return;
        }

        _inFlightId = id;
        Communications.makeWebRequest(
            (creds["supabaseUrl"] as String) + "/rest/v1/rpc/submit_watch_result",
            { "p_token" => creds["watchToken"], "p_payload" => payload },
            {
                :method       => Communications.HTTP_REQUEST_METHOD_POST,
                :headers      => {
                    "Content-Type"  => Communications.REQUEST_CONTENT_TYPE_JSON,
                    "apikey"        => creds["supabaseAnonKey"],
                    "Authorization" => "Bearer " + (creds["supabaseAnonKey"] as String)
                },
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            method(:onWebResponse)
        );
    }

    function onWebResponse(responseCode as Number, data as Dictionary or String or Null) as Void {
        var id = _inFlightId;
        _inFlightId = null;

        if (responseCode == 200) {
            markSynced(id);
            return;
        }

        if (responseCode == 400 || responseCode == 404) {
            // Malformed payload / simulation deleted — can never succeed.
            removeId(id);
            _backoffMs = MIN_BACKOFF;
            syncNow();
            return;
        }

        if (responseCode == 401 || responseCode == 403) {
            // Token rejected: ask the phone for a new one. Result is kept.
            Communications.transmit({ "type" => "CREDENTIALS_REQUEST" }, null, new SyncTransmitListener());
        }

        // Negative codes = no Bluetooth / phone / internet. Keep and retry.
        scheduleRetry();
    }

    // ── Internals ────────────────────────────────────────────────────────────

    private function markSynced(id) as Void {
        if (id == null || outbox().indexOf(id) < 0) { return; }
        removeId(id);
        _backoffMs = MIN_BACKOFF;
        if (pendingCount() == 0) {
            setStatus(:synced);
            if (onSynced != null) { onSynced.invoke(); }
        }
        syncNow();
    }

    private function scheduleRetry() as Void {
        setStatus(:waiting);
        if (_timer == null) { _timer = new Timer.Timer(); }
        _timer.stop();
        _timer.start(method(:syncNow), _backoffMs, false);
        _backoffMs = (_backoffMs * 2 > MAX_BACKOFF) ? MAX_BACKOFF : _backoffMs * 2;
    }

    private function setStatus(s) as Void {
        status = s;
        WatchUi.requestUpdate();
    }

    private function outbox() as Array {
        var ids = Application.Storage.getValue(OUTBOX_KEY);
        return (ids == null) ? [] : (ids as Array);
    }

    private function removeId(id) as Void {
        if (id == null) { return; }
        var ids = outbox();
        ids.remove(id);
        Application.Storage.setValue(OUTBOX_KEY, ids);
        Application.Storage.deleteValue(RESULT_PREFIX + id);
    }

    // Older builds kept one unsynced result under "pendingSplits".
    private function migrateLegacy() as Void {
        var legacy = Application.Storage.getValue(LEGACY_KEY) as Dictionary?;
        if (legacy == null) { return; }
        if (legacy["resultId"] == null) {
            legacy["resultId"] = "legacy-" + (legacy["totalTime"] as Number).format("%d");
        }
        enqueue(legacy);
        Application.Storage.deleteValue(LEGACY_KEY);
    }
}

class SyncTransmitListener extends Communications.ConnectionListener {
    function initialize() {
        ConnectionListener.initialize();
    }
    function onComplete() as Void {}
    function onError() as Void {}
}
