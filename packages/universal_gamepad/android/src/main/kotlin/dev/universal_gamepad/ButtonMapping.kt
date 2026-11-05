package dev.universal_gamepad

import android.view.KeyEvent
import android.view.MotionEvent

/**
 * Maps Android keycodes and motion event axes to W3C Standard Gamepad indices.
 *
 * W3C Standard Gamepad button mapping:
 *   0 = A (bottom), 1 = B (right), 2 = X (left), 3 = Y (top)
 *   4 = leftShoulder, 5 = rightShoulder
 *   6 = leftTrigger, 7 = rightTrigger
 *   8 = back (select), 9 = start
 *   10 = leftStickButton, 11 = rightStickButton
 *   12 = dpadUp, 13 = dpadDown, 14 = dpadLeft, 15 = dpadRight
 *   16 = guide (home/mode)
 *
 * W3C Standard Gamepad axis mapping:
 *   0 = leftStickX, 1 = leftStickY, 2 = rightStickX, 3 = rightStickY
 */
object ButtonMapping {

    // -- Button indices (W3C) --------------------------------------------------

    const val BUTTON_A = 0
    const val BUTTON_B = 1
    const val BUTTON_X = 2
    const val BUTTON_Y = 3
    const val LEFT_SHOULDER = 4
    const val RIGHT_SHOULDER = 5
    const val LEFT_TRIGGER = 6
    const val RIGHT_TRIGGER = 7
    const val BACK = 8
    const val START = 9
    const val LEFT_STICK_BUTTON = 10
    const val RIGHT_STICK_BUTTON = 11
    const val DPAD_UP = 12
    const val DPAD_DOWN = 13
    const val DPAD_LEFT = 14
    const val DPAD_RIGHT = 15
    const val GUIDE = 16

    // -- Axis indices (W3C) ----------------------------------------------------

    const val AXIS_LEFT_STICK_X = 0
    const val AXIS_LEFT_STICK_Y = 1
    const val AXIS_RIGHT_STICK_X = 2
    const val AXIS_RIGHT_STICK_Y = 3

    // -- Keycode -> W3C button index -------------------------------------------

    /**
     * Returns the W3C button index for a given Android [KeyEvent] keycode,
     * or `null` if the keycode does not map to a standard gamepad button.
     */
    fun buttonIndexForKeyCode(keyCode: Int): Int? {
        return when (keyCode) {
            KeyEvent.KEYCODE_BUTTON_A -> BUTTON_A
            KeyEvent.KEYCODE_BUTTON_B -> BUTTON_B
            KeyEvent.KEYCODE_BUTTON_X -> BUTTON_X
            KeyEvent.KEYCODE_BUTTON_Y -> BUTTON_Y
            KeyEvent.KEYCODE_BUTTON_L1 -> LEFT_SHOULDER
            KeyEvent.KEYCODE_BUTTON_R1 -> RIGHT_SHOULDER
            // KEYCODE_BUTTON_L2 / R2 are intentionally omitted here.
            // Triggers are handled via the analog AXIS_LTRIGGER / AXIS_RTRIGGER
            // path in onGenericMotionEvent, which provides the proper 0.0–1.0
            // value.  Mapping the key event as well would cause the value to
            // flash between 1.0 (digital) and the real analog value.
            KeyEvent.KEYCODE_BUTTON_SELECT -> BACK
            KeyEvent.KEYCODE_BUTTON_START -> START
            KeyEvent.KEYCODE_BUTTON_THUMBL -> LEFT_STICK_BUTTON
            KeyEvent.KEYCODE_BUTTON_THUMBR -> RIGHT_STICK_BUTTON
            KeyEvent.KEYCODE_DPAD_UP -> DPAD_UP
            KeyEvent.KEYCODE_DPAD_DOWN -> DPAD_DOWN
            KeyEvent.KEYCODE_DPAD_LEFT -> DPAD_LEFT
            KeyEvent.KEYCODE_DPAD_RIGHT -> DPAD_RIGHT
            KeyEvent.KEYCODE_BUTTON_MODE -> GUIDE
            else -> null
        }
    }

    // -- MotionEvent axis -> W3C axis index ------------------------------------

    /**
     * Returns the W3C axis index for a given Android [MotionEvent] axis constant,
     * or `null` if the axis does not map to a standard gamepad axis.
     */
    fun axisIndexForMotionAxis(axis: Int): Int? {
        return when (axis) {
            MotionEvent.AXIS_X -> AXIS_LEFT_STICK_X
            MotionEvent.AXIS_Y -> AXIS_LEFT_STICK_Y
            MotionEvent.AXIS_Z -> AXIS_RIGHT_STICK_X
            MotionEvent.AXIS_RZ -> AXIS_RIGHT_STICK_Y
            else -> null
        }
    }

    // -- Trigger axes ----------------------------------------------------------

    /**
     * Returns the W3C button index for an analog trigger axis constant,
     * or `null` if the axis is not a trigger.
     */
    fun triggerButtonIndexForAxis(axis: Int): Int? {
        return when (axis) {
            MotionEvent.AXIS_LTRIGGER -> LEFT_TRIGGER
            MotionEvent.AXIS_RTRIGGER -> RIGHT_TRIGGER
            else -> null
        }
    }

    // -- Hat (D-pad) axes ------------------------------------------------------

    /** The axes that represent the D-pad hat switch. */
    val HAT_AXES = intArrayOf(MotionEvent.AXIS_HAT_X, MotionEvent.AXIS_HAT_Y)

    /** All stick and trigger axes to monitor in motion events. */
    val STICK_AXES = intArrayOf(
        MotionEvent.AXIS_X,
        MotionEvent.AXIS_Y,
        MotionEvent.AXIS_Z,
        MotionEvent.AXIS_RZ,
    )

    val TRIGGER_AXES = intArrayOf(
        MotionEvent.AXIS_LTRIGGER,
        MotionEvent.AXIS_RTRIGGER,
    )
}
