import Foundation
import GameController

/// Manages GCController lifecycle and translates events into the plugin wire format.
///
/// Each connected controller is assigned a stable integer identifier. The manager
/// observes `GCController.didConnectNotification` and
/// `GCController.didDisconnectNotification`, and installs a
/// `valueChangedHandler` on each controller's `extendedGamepad` to receive
/// button and axis input.
class GCControllerManager {

    private let streamHandler: GamepadStreamHandler
    let effects = GamepadEffects()

    func controller(for id: Int) -> GCController? {
        GCController.controllers().first { controllerIds[ObjectIdentifier($0)] == id }
    }

    /// Maps a GCController instance (by ObjectIdentifier) to its assigned int ID.
    private var controllerIds: [ObjectIdentifier: Int] = [:]

    /// Auto-incrementing counter used to generate unique IDs.
    private var nextIndex: Int = 0

    /// Retained notification observers so they can be removed on `stop()`.
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    // MARK: - Initialisation

    init(streamHandler: GamepadStreamHandler) {
        self.streamHandler = streamHandler
    }

    // MARK: - Lifecycle

    /// Begins observing controller connections and registers handlers on any
    /// controllers that are already connected.
    func start() {
        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let controller = notification.object as? GCController else { return }
            self.controllerConnected(controller)
        }

        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let controller = notification.object as? GCController else { return }
            self.controllerDisconnected(controller)
        }

        // Register controllers that are already connected at start time.
        for controller in GCController.controllers() {
            controllerConnected(controller)
        }
    }

    /// Stops observing controller notifications and removes all handlers.
    func stop() {
        effects.stop()
        if let observer = connectObserver {
            NotificationCenter.default.removeObserver(observer)
            connectObserver = nil
        }
        if let observer = disconnectObserver {
            NotificationCenter.default.removeObserver(observer)
            disconnectObserver = nil
        }

        // Remove valueChangedHandlers from all tracked controllers.
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
        }

        controllerIds.removeAll()
    }

    /// Returns a list of currently connected gamepads in the wire format used by
    /// `listGamepads` on the Dart side (MethodChannel — still uses maps).
    func listGamepads() -> [[String: Any]] {
        var results: [[String: Any]] = []
        for controller in GCController.controllers() {
            let key = ObjectIdentifier(controller)
            guard let gamepadId = controllerIds[key] else { continue }
            // GCController exposes no numeric vendor/product IDs through the
            // public API, so those keys are omitted (optional on the Dart side).
            let info: [String: Any] = [
                "id": gamepadId,
                "name": controllerName(controller),
            ]
            results.append(info)
        }
        return results
    }

    // MARK: - Connection handling

    private func controllerConnected(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        // Guard against duplicate connection notifications.
        guard controllerIds[key] == nil else { return }

        let gamepadId = nextIndex
        nextIndex += 1
        controllerIds[key] = gamepadId

        installValueChangedHandler(on: controller, gamepadId: gamepadId)

        // Wire format: [0, gamepadId, timestamp, connected, name, vendorId, productId]
        // vendor/product IDs are not publicly exposed by GCController; send null.
        let event: [Any] = [
            0,
            gamepadId,
            currentTimestamp(),
            true,
            controllerName(controller),
            NSNull(),
            NSNull(),
        ]
        streamHandler.send(event: event)
    }

    private func controllerDisconnected(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        guard let gamepadId = controllerIds.removeValue(forKey: key) else { return }

        effects.remove(gamepadId)
        controller.extendedGamepad?.valueChangedHandler = nil

        // Wire format: [0, gamepadId, timestamp, connected, name, vendorId, productId]
        let event: [Any] = [
            0,
            gamepadId,
            currentTimestamp(),
            false,
            controllerName(controller),
            NSNull(),
            NSNull(),
        ]
        streamHandler.send(event: event)
    }

    // MARK: - Input handling

    private func installValueChangedHandler(on controller: GCController, gamepadId: Int) {
        guard let gamepad = controller.extendedGamepad else { return }

        gamepad.valueChangedHandler = { [weak self] (gp: GCExtendedGamepad,
                                                      element: GCControllerElement) in
            guard let self = self else { return }
            let timestamp = self.currentTimestamp()

            // --- Thumbstick (axes) ---
            if element === gp.leftThumbstick {
                self.sendAxisEvent(gamepadId: gamepadId, axisIndex: ButtonMapping.leftStickX,
                                   value: gp.leftThumbstick.xAxis.value, timestamp: timestamp)
                self.sendAxisEvent(gamepadId: gamepadId, axisIndex: ButtonMapping.leftStickY,
                                   value: -gp.leftThumbstick.yAxis.value, timestamp: timestamp)
                return
            }
            if element === gp.rightThumbstick {
                self.sendAxisEvent(gamepadId: gamepadId, axisIndex: ButtonMapping.rightStickX,
                                   value: gp.rightThumbstick.xAxis.value, timestamp: timestamp)
                self.sendAxisEvent(gamepadId: gamepadId, axisIndex: ButtonMapping.rightStickY,
                                   value: -gp.rightThumbstick.yAxis.value, timestamp: timestamp)
                return
            }

            // --- Individual axis inputs ---
            if let axisResult = ButtonMapping.axisIndexAndValue(for: element, in: gp) {
                self.sendAxisEvent(gamepadId: gamepadId, axisIndex: axisResult.index,
                                   value: axisResult.value, timestamp: timestamp)
                return
            }

            // --- D-pad as a whole element ---
            if element === gp.dpad {
                self.sendButtonEvent(gamepadId: gamepadId, buttonIndex: ButtonMapping.dpadUp,
                                     pressed: gp.dpad.up.isPressed,
                                     value: gp.dpad.up.value, timestamp: timestamp)
                self.sendButtonEvent(gamepadId: gamepadId, buttonIndex: ButtonMapping.dpadDown,
                                     pressed: gp.dpad.down.isPressed,
                                     value: gp.dpad.down.value, timestamp: timestamp)
                self.sendButtonEvent(gamepadId: gamepadId, buttonIndex: ButtonMapping.dpadLeft,
                                     pressed: gp.dpad.left.isPressed,
                                     value: gp.dpad.left.value, timestamp: timestamp)
                self.sendButtonEvent(gamepadId: gamepadId, buttonIndex: ButtonMapping.dpadRight,
                                     pressed: gp.dpad.right.isPressed,
                                     value: gp.dpad.right.value, timestamp: timestamp)
                return
            }

            // --- Button inputs ---
            if let buttonInput = element as? GCControllerButtonInput,
               let buttonIndex = ButtonMapping.buttonIndex(for: buttonInput, in: gp) {
                self.sendButtonEvent(gamepadId: gamepadId, buttonIndex: buttonIndex,
                                     pressed: buttonInput.isPressed,
                                     value: buttonInput.value, timestamp: timestamp)
                return
            }
        }
    }

    // MARK: - Event dispatch helpers

    private func sendButtonEvent(gamepadId: Int, buttonIndex: Int,
                                 pressed: Bool, value: Float, timestamp: Int) {
        // Wire format: [1, gamepadId, timestamp, buttonIndex, pressed, value]
        streamHandler.send(event: [1, gamepadId, timestamp, buttonIndex, pressed, Double(value)])
    }

    private func sendAxisEvent(gamepadId: Int, axisIndex: Int,
                               value: Float, timestamp: Int) {
        // Wire format: [2, gamepadId, timestamp, axisIndex, value]
        streamHandler.send(event: [2, gamepadId, timestamp, axisIndex, Double(value)])
    }

    // MARK: - Utilities

    /// Returns the current time as milliseconds since the Unix epoch.
    private func currentTimestamp() -> Int {
        return Int(Date().timeIntervalSince1970 * 1000)
    }

    /// Returns the human-readable name for a controller.
    ///
    /// Prefers `vendorName` (e.g. "Xbox Wireless Controller") as it is the
    /// most descriptive. Falls back to `productCategory` which is available
    /// from macOS 11.0+.
    private func controllerName(_ controller: GCController) -> String {
        if let name = controller.vendorName, !name.isEmpty {
            return name
        }
        let category = controller.productCategory
        if !category.isEmpty {
            return category
        }
        return "Unknown Controller"
    }
}
