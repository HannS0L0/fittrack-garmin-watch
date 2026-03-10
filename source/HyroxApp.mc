import Toybox.Application;
import Toybox.Communications;
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
                    Toybox.Communications.transmitMessage(pending, {}, null);
                }
            }
        }
    }

    function onStop(state as Dictionary?) as Void {
    }
}

function getApp() as HyroxApp {
    return Application.getApp() as HyroxApp;
}
