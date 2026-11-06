import Toybox.WatchUi;
import Toybox.Lang;

class HyroxDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        var key = keyEvent.getKey();

        // Primary action (ENTER / START) — advance or save
        if (key == WatchUi.KEY_ENTER || key == WatchUi.KEY_START) {
            if (gModel.state == :finish) {
                gModel.saveAndTransmit();
            } else if (gModel.state != :saved) {
                gModel.advance();
            }
            WatchUi.requestUpdate();
            return true;
        }

        return false;
    }

    function onBack() as Boolean {
        // Swallow BACK during an active session to prevent accidental exit
        if (gModel.state == :active) {
            return true;
        }
        // BACK on the finish screen used to exit and lose the workout —
        // confirm before throwing it away.
        if (gModel.state == :finish) {
            WatchUi.pushView(
                new WatchUi.Confirmation("Discard workout?"),
                new DiscardConfirmDelegate(),
                WatchUi.SLIDE_IMMEDIATE
            );
            return true;
        }
        return false;
    }
}

class DiscardConfirmDelegate extends WatchUi.ConfirmationDelegate {

    function initialize() {
        ConfirmationDelegate.initialize();
    }

    function onResponse(response as WatchUi.Confirm) as Boolean {
        if (response == WatchUi.CONFIRM_YES) {
            gModel.discard();
        }
        return true;
    }
}
