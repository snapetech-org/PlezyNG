import GameController

/// Maps GCController extended gamepad elements to W3C Standard Gamepad indices.
///
/// W3C Standard Gamepad button mapping:
///   0 = A (bottom), 1 = B (right), 2 = X (left), 3 = Y (top)
///   4 = leftShoulder, 5 = rightShoulder
///   6 = leftTrigger, 7 = rightTrigger
///   8 = back (options), 9 = start (menu)
///   10 = leftThumbstickButton, 11 = rightThumbstickButton
///   12 = dpadUp, 13 = dpadDown, 14 = dpadLeft, 15 = dpadRight
///   16 = guide (home)
///
/// W3C Standard Gamepad axis mapping:
///   0 = leftStickX, 1 = leftStickY, 2 = rightStickX, 3 = rightStickY
///
/// Note: GCController reports Y-axes with up as positive, but the W3C
/// standard expects up as negative. Y-axis values must be inverted.
enum ButtonMapping {
    // MARK: - Button indices

    static let buttonA = 0
    static let buttonB = 1
    static let buttonX = 2
    static let buttonY = 3
    static let leftShoulder = 4
    static let rightShoulder = 5
    static let leftTrigger = 6
    static let rightTrigger = 7
    static let back = 8
    static let start = 9
    static let leftStickButton = 10
    static let rightStickButton = 11
    static let dpadUp = 12
    static let dpadDown = 13
    static let dpadLeft = 14
    static let dpadRight = 15
    static let guide = 16

    // MARK: - Axis indices

    static let leftStickX = 0
    static let leftStickY = 1
    static let rightStickX = 2
    static let rightStickY = 3

    // MARK: - Element to index resolution

    /// Returns the W3C button index for a given `GCControllerButtonInput`, or `nil`
    /// if the element does not map to a standard button.
    static func buttonIndex(for element: GCControllerButtonInput,
                            in gamepad: GCExtendedGamepad) -> Int? {
        // Face buttons
        if element === gamepad.buttonA { return buttonA }
        if element === gamepad.buttonB { return buttonB }
        if element === gamepad.buttonX { return buttonX }
        if element === gamepad.buttonY { return buttonY }

        // Shoulders
        if element === gamepad.leftShoulder { return leftShoulder }
        if element === gamepad.rightShoulder { return rightShoulder }

        // Triggers
        if element === gamepad.leftTrigger { return leftTrigger }
        if element === gamepad.rightTrigger { return rightTrigger }

        // Thumbstick buttons (optional on GCExtendedGamepad)
        if let lsb = gamepad.leftThumbstickButton, element === lsb {
            return leftStickButton
        }
        if let rsb = gamepad.rightThumbstickButton, element === rsb {
            return rightStickButton
        }

        // D-pad individual directions
        if element === gamepad.dpad.up { return dpadUp }
        if element === gamepad.dpad.down { return dpadDown }
        if element === gamepad.dpad.left { return dpadLeft }
        if element === gamepad.dpad.right { return dpadRight }

        // Menu / Options / Home (some are optional)
        if element === gamepad.buttonMenu { return start }
        if let options = gamepad.buttonOptions, element === options {
            return back
        }
        if let home = gamepad.buttonHome, element === home {
            return guide
        }

        return nil
    }

    /// Determines the W3C axis index and value for a `GCControllerAxisInput` change
    /// within an extended gamepad. Returns `nil` if the axis is not mapped.
    ///
    /// Y-axis values are inverted to conform to the W3C standard (up = negative).
    static func axisIndexAndValue(for element: GCControllerElement,
                                  in gamepad: GCExtendedGamepad) -> (index: Int, value: Float)? {
        if element === gamepad.leftThumbstick {
            // We cannot distinguish which sub-axis changed from just the
            // thumbstick element, so the caller handles thumbstick specially.
            return nil
        }
        if element === gamepad.rightThumbstick {
            return nil
        }

        // Individual axis inputs
        if let axisInput = element as? GCControllerAxisInput {
            if axisInput === gamepad.leftThumbstick.xAxis {
                return (leftStickX, axisInput.value)
            }
            if axisInput === gamepad.leftThumbstick.yAxis {
                return (leftStickY, -axisInput.value) // Invert Y
            }
            if axisInput === gamepad.rightThumbstick.xAxis {
                return (rightStickX, axisInput.value)
            }
            if axisInput === gamepad.rightThumbstick.yAxis {
                return (rightStickY, -axisInput.value) // Invert Y
            }
        }

        return nil
    }
}
