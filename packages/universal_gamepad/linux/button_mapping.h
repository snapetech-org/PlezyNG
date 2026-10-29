#ifndef BUTTON_MAPPING_H_
#define BUTTON_MAPPING_H_

#include <cstdint>
#include <linux/input-event-codes.h>

/// Maps Linux evdev button/axis codes to W3C Standard Gamepad indices.
///
/// W3C Standard Gamepad button mapping:
///   0 = a (bottom), 1 = b (right), 2 = x (left), 3 = y (top)
///   4 = leftShoulder, 5 = rightShoulder
///   6 = leftTrigger, 7 = rightTrigger
///   8 = back, 9 = start
///   10 = leftStickButton, 11 = rightStickButton
///   12 = dpadUp, 13 = dpadDown, 14 = dpadLeft, 15 = dpadRight
///   16 = guide
///
/// W3C Standard Gamepad axis mapping:
///   0 = leftStickX, 1 = leftStickY, 2 = rightStickX, 3 = rightStickY
///
/// Trigger axes (ABS_Z / ABS_RZ) are mapped to button indices 6 and 7
/// respectively, since the W3C spec treats triggers as analog buttons.
/// D-pad (12-15) comes from hat axis events (ABS_HAT0X / ABS_HAT0Y).
namespace ButtonMapping {

// W3C button indices.
constexpr int kButtonA = 0;
constexpr int kButtonB = 1;
constexpr int kButtonX = 2;
constexpr int kButtonY = 3;
constexpr int kLeftShoulder = 4;
constexpr int kRightShoulder = 5;
constexpr int kLeftTrigger = 6;
constexpr int kRightTrigger = 7;
constexpr int kBack = 8;
constexpr int kStart = 9;
constexpr int kLeftStickButton = 10;
constexpr int kRightStickButton = 11;
constexpr int kDpadUp = 12;
constexpr int kDpadDown = 13;
constexpr int kDpadLeft = 14;
constexpr int kDpadRight = 15;
constexpr int kGuide = 16;

// W3C axis indices.
constexpr int kLeftStickX = 0;
constexpr int kLeftStickY = 1;
constexpr int kRightStickX = 2;
constexpr int kRightStickY = 3;

/// Maps an evdev button code to its W3C Standard Gamepad button index.
/// Returns -1 if the button has no standard mapping.
///
/// `swap_north_west` handles drivers (notably xpad) that report face buttons
/// by label rather than by location: xpad emits BTN_X (== BTN_NORTH) for the
/// physical left/X button and BTN_Y (== BTN_WEST) for the physical top/Y
/// button, the opposite of the Linux gamepad spec that hid-playstation and
/// others follow. When true, BTN_NORTH/BTN_WEST are swapped so the W3C
/// indices match the physical layout.
int EvdevButtonToW3C(uint16_t code, bool swap_north_west = false);

/// Maps an evdev absolute axis code to its W3C Standard Gamepad axis index.
/// Returns -1 if the axis is a trigger or hat (those are treated as buttons).
int EvdevAxisToW3C(uint16_t code);

/// Returns true if the given evdev axis is a trigger axis (ABS_Z or ABS_RZ).
bool IsTriggerAxis(uint16_t code);

/// Returns the W3C button index for the given trigger axis.
/// Only valid when IsTriggerAxis() returns true.
int TriggerAxisToButtonIndex(uint16_t code);

/// Returns true if the given evdev axis is a hat/d-pad axis.
bool IsHatAxis(uint16_t code);

}  // namespace ButtonMapping

#endif  // BUTTON_MAPPING_H_
