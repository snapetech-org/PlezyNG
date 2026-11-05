#include "button_mapping.h"

namespace gamepad {

int SdlButtonToW3C(SDL_GamepadButton button) {
  switch (button) {
    case SDL_GAMEPAD_BUTTON_SOUTH:
      return W3CButton::kA;
    case SDL_GAMEPAD_BUTTON_EAST:
      return W3CButton::kB;
    case SDL_GAMEPAD_BUTTON_WEST:
      return W3CButton::kX;
    case SDL_GAMEPAD_BUTTON_NORTH:
      return W3CButton::kY;
    case SDL_GAMEPAD_BUTTON_LEFT_SHOULDER:
      return W3CButton::kLeftShoulder;
    case SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER:
      return W3CButton::kRightShoulder;
    case SDL_GAMEPAD_BUTTON_BACK:
      return W3CButton::kBack;
    case SDL_GAMEPAD_BUTTON_START:
      return W3CButton::kStart;
    case SDL_GAMEPAD_BUTTON_LEFT_STICK:
      return W3CButton::kLeftStickButton;
    case SDL_GAMEPAD_BUTTON_RIGHT_STICK:
      return W3CButton::kRightStickButton;
    case SDL_GAMEPAD_BUTTON_DPAD_UP:
      return W3CButton::kDpadUp;
    case SDL_GAMEPAD_BUTTON_DPAD_DOWN:
      return W3CButton::kDpadDown;
    case SDL_GAMEPAD_BUTTON_DPAD_LEFT:
      return W3CButton::kDpadLeft;
    case SDL_GAMEPAD_BUTTON_DPAD_RIGHT:
      return W3CButton::kDpadRight;
    case SDL_GAMEPAD_BUTTON_GUIDE:
      return W3CButton::kGuide;
    default:
      return -1;
  }
}

int SdlAxisToW3C(SDL_GamepadAxis axis) {
  switch (axis) {
    case SDL_GAMEPAD_AXIS_LEFTX:
      return W3CAxis::kLeftStickX;
    case SDL_GAMEPAD_AXIS_LEFTY:
      return W3CAxis::kLeftStickY;
    case SDL_GAMEPAD_AXIS_RIGHTX:
      return W3CAxis::kRightStickX;
    case SDL_GAMEPAD_AXIS_RIGHTY:
      return W3CAxis::kRightStickY;
    default:
      return -1;
  }
}

bool IsTriggerAxis(SDL_GamepadAxis axis) {
  return axis == SDL_GAMEPAD_AXIS_LEFT_TRIGGER ||
         axis == SDL_GAMEPAD_AXIS_RIGHT_TRIGGER;
}

int TriggerAxisToButtonIndex(SDL_GamepadAxis axis) {
  if (axis == SDL_GAMEPAD_AXIS_LEFT_TRIGGER) {
    return W3CButton::kLeftTrigger;
  }
  if (axis == SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) {
    return W3CButton::kRightTrigger;
  }
  return -1;
}

double NormalizeStickAxis(int16_t value) {
  if (value < -32767) {
    value = -32767;
  }
  return static_cast<double>(value) / 32767.0;
}

double NormalizeTriggerAxis(int16_t value) {
  if (value < 0) {
    value = 0;
  }
  return static_cast<double>(value) / 32767.0;
}

}  // namespace gamepad
