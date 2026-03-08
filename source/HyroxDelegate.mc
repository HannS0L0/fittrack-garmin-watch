import Toybox.WatchUi;
import Toybox.Lang;

class HyroxDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        var key = keyEvent.getKey();

        // Primary action button (ENTER on most devices, also called LAP on some)
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

    // Swallow BACK during an active session to prevent accidental exit
    function onBack() as Boolean {
        if (gModel.state == :active) {
            return true;
        }
        return false;
    }
}
