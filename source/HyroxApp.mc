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
        // On from launch so the optical sensor has a lock before the race starts
        gModel.enableHrSensor();
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
            // Simulation that standalone sessions are saved under (persisted so
            // a session run later without the phone can still be uploaded)
            if (data["standaloneSimulationId"] != null) {
                Application.Storage.setValue("standaloneSimId", data["standaloneSimulationId"]);
            }
        }

        // Phone asking for results that were never confirmed saved (e.g. the
        // phone wasn't reachable when Save was tapped): send the whole backlog.
        if (msgType.equals("QUERY_PENDING")) {
            gModel.queue.flush(null);
        }

        // Phone app stored a result we transmitted: drop it from the queue
        if (msgType.equals("RESULT_SAVED")) {
            gModel.queue.confirm(data["clientResultId"]);
        }
    }

    function onStop(state as Dictionary?) as Void {
        gModel.disableHrSensor();
    }
}

function getApp() as HyroxApp {
    return Application.getApp() as HyroxApp;
}
