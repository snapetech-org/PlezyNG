#ifndef FLUTTER_PLUGIN_BUTTON_MAPPING_H_
#define FLUTTER_PLUGIN_BUTTON_MAPPING_H_

#include <SDL3/SDL.h>

#include <cstdint>

namespace gamepad {

/// W3C Standard Gamepad button indices.
namespace W3CButton {
constexpr int kA = 0;
constexpr int kB = 1;
constexpr int kX = 2;
constexpr int kY = 3;
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
constexpr int kCount = 17;
}  // namespace W3CButton

/// W3C Standard Gamepad axis indices.
namespace W3CAxis {
constexpr int kLeftStickX = 0;
constexpr int kLeftStickY = 1;
constexpr int kRightStickX = 2;
constexpr int kRightStickY = 3;
constexpr int kCount = 4;
}  // namespace W3CAxis

/// Maps an SDL_GamepadButton to its W3C Standard Gamepad button index.
/// Returns -1 if the button has no standard mapping.
int SdlButtonToW3C(SDL_GamepadButton button);

/// Maps an SDL_GamepadAxis to its W3C Standard Gamepad axis index.
/// Returns -1 if the axis is a trigger (triggers are treated as buttons).
int SdlAxisToW3C(SDL_GamepadAxis axis);

/// Returns true if the given SDL axis is a trigger axis.
bool IsTriggerAxis(SDL_GamepadAxis axis);

/// Returns the W3C button index for the given trigger axis.
/// Only valid when IsTriggerAxis() returns true.
int TriggerAxisToButtonIndex(SDL_GamepadAxis axis);

/// Normalizes an SDL stick axis value (-32768..32767) to -1.0..1.0.
double NormalizeStickAxis(int16_t value);

/// Normalizes an SDL trigger axis value (0..32767) to 0.0..1.0.
double NormalizeTriggerAxis(int16_t value);

}  // namespace gamepad

#endif  // FLUTTER_PLUGIN_BUTTON_MAPPING_H_
