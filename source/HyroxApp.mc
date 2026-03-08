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
        var data = msg.data;
        if (data == null) { return; }

        var msgType = data["type"];
        if (msgType == null) { return; }

        if (msgType.equals("START_SESSION")) {
            if (data["simulationId"] != null) {
                gModel.simulationId = data["simulationId"];
            }
            if (data["stations"] != null) {
                gModel.setStationsFromMessage(data["stations"]);
            }
        }
    }

    function onStop(state as Dictionary?) as Void {
    }
}

function getApp() as HyroxApp {
    return Application.getApp() as HyroxApp;
}
