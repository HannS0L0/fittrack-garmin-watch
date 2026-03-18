import Toybox.Application;
import Toybox.Communications;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;
import Toybox.Lang;

// Global model instance — accessible from View and Delegate
var gModel as HyroxModel = new HyroxModel();

class HyroxApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
        gModel = new HyroxModel();

        if (Communications has :registerForPhoneAppMessages) {
            Communications.registerForPhoneAppMessages(method(:onPhoneMessage));
        }
    }

    function onStart(state as Dictionary?) as Void {
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new HyroxView(), new HyroxDelegate()];
    }

    // ── Phone → Watch message handler ────────────────────────────────────────
    function onPhoneMessage(msg as Communications.PhoneAppMessage) as Void {
        if (msg.data == null) { return; }
        var data = msg.data as Dictionary;

        var msgType = data["type"];
        if (msgType == null) { return; }

        if (msgType.equals("START_SESSION")) {
            if (data["simulationId"] != null) {
                gModel.simulationId = data["simulationId"];
            }
            if (data["stations"] != null) {
                gModel.setStationsFromMessage(data["stations"]);
            }
            if (data["userId"] != null)          { gModel.userId = data["userId"]; }
            if (data["supabaseUrl"] != null)      { gModel.supabaseUrl = data["supabaseUrl"]; }
            if (data["supabaseAnonKey"] != null)  { gModel.supabaseAnonKey = data["supabaseAnonKey"]; }
            if (data["accessToken"] != null)      { gModel.accessToken = data["accessToken"]; }
        }

        // Phone asking if there is a locally-stored result that was never
        // delivered (e.g. phone was not reachable when Save was tapped).
        if (msgType.equals("QUERY_PENDING")) {
            var pending = Application.Storage.getValue("pendingSplits");
            if (pending != null) {
                if ((Toybox has :Communications) && (Toybox.Communications has :transmitMessage)) {
                    // Modern watches: send directly to the phone app.
                    Toybox.Communications.transmitMessage(pending, {}, null);
                } else if ((Toybox has :Communications) && (Toybox.Communications has :makeWebRequest)
                           && gModel.userId != null && gModel.supabaseUrl != null
                           && gModel.supabaseAnonKey != null && gModel.accessToken != null) {
                    // Older watches (e.g. Approach S60): retry the HTTP POST to
                    // Supabase. The phone detects the new row via useFocusEffect.
                    // Cast Storage Object → Dictionary before accessing string keys.
                    var pd = pending as Dictionary;
                    var rawSplits = pd["splits"] as Array;
                    var dbSplits = [] as Array;
                    for (var i = 0; i < rawSplits.size(); i++) {
                        var s = rawSplits[i] as Dictionary;
                        dbSplits.add({
                            "order"   => s["order"],
                            "type"    => s["type"],
                            "label"   => s["name"],
                            "time_ms" => (s["duration"] as Number) * 1000
                        });
                    }
                    var now = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
                    var completedAt = now.year.format("%04d") + "-"
                        + now.month.format("%02d") + "-"
                        + now.day.format("%02d") + "T"
                        + now.hour.format("%02d") + ":"
                        + now.min.format("%02d") + ":"
                        + now.sec.format("%02d") + "Z";
                    var body = {
                        "user_id"       => gModel.userId,
                        "simulation_id" => pd["simulationId"],
                        "total_time_ms" => (pd["totalTime"] as Number) * 1000,
                        "completed_at"  => completedAt,
                        "splits"        => dbSplits
                    };
                    var headers = {
                        "Content-Type"  => "application/json",
                        "apikey"        => gModel.supabaseAnonKey,
                        "Authorization" => "Bearer " + gModel.accessToken,
                        "Prefer"        => "return=minimal"
                    };
                    Communications.makeWebRequest(
                        gModel.supabaseUrl + "/rest/v1/hyrox_results",
                        body,
                        {
                            :method       => Communications.HTTP_REQUEST_METHOD_POST,
                            :headers      => headers,
                            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
                        },
                        method(:onQueryPendingWebComplete)
                    );
                }
            }
        }
    }

    // Callback for QUERY_PENDING makeWebRequest retry.
    // On HTTP 201 (Created) the data reached Supabase — clear local storage
    // so it isn't re-sent on the next QUERY_PENDING.
    function onQueryPendingWebComplete(responseCode as Number, data as Dictionary?) as Void {
        if (responseCode == 201) {
            Application.Storage.deleteValue("pendingSplits");
        }
    }

    function onStop(state as Dictionary?) as Void {
    }
}

function getApp() as HyroxApp {
    return Application.getApp() as HyroxApp;
}
