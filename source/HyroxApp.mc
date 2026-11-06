import Toybox.Application;
import Toybox.Communications;
import Toybox.WatchUi;
import Toybox.Lang;

// Global model instance — accessible from View and Delegate
var gModel as HyroxModel = new HyroxModel();
// Global result sync queue — see SyncQueue.mc
var gSync as SyncQueue = new SyncQueue();

class HyroxApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
        gModel = new HyroxModel();

        if (Communications has :registerForPhoneAppMessages) {
            Communications.registerForPhoneAppMessages(method(:onPhoneMessage));
        }
    }

    function onStart(state as Dictionary?) as Void {
        // Retry anything still queued from earlier sessions
        gSync.start();
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
            gModel.simulationName = data["simulationName"];
            gModel.saveSession();
            WatchUi.requestUpdate();
        }

        // Credentials, SESSION_ACK and QUERY_PENDING are handled by the sync queue
        gSync.handlePhoneMessage(data);
    }

    function onStop(state as Dictionary?) as Void {
    }
}

function getApp() as HyroxApp {
    return Application.getApp() as HyroxApp;
}
