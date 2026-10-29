#include "button_mapping.h"

namespace ButtonMapping {

int EvdevButtonToW3C(uint16_t code, bool swap_north_west) {
  switch (code) {
    case BTN_SOUTH:
      return kButtonA;
    case BTN_EAST:
      return kButtonB;
    case BTN_WEST:
      return swap_north_west ? kButtonY : kButtonX;
    case BTN_NORTH:
      return swap_north_west ? kButtonX : kButtonY;
    case BTN_TL:
      return kLeftShoulder;
    case BTN_TR:
      return kRightShoulder;
    case BTN_TL2:
      return kLeftTrigger;
    case BTN_TR2:
      return kRightTrigger;
    case BTN_SELECT:
      return kBack;
    case BTN_START:
      return kStart;
    case BTN_THUMBL:
      return kLeftStickButton;
    case BTN_THUMBR:
      return kRightStickButton;
    case BTN_MODE:
      return kGuide;
    default:
      return -1;
  }
}

int EvdevAxisToW3C(uint16_t code) {
  switch (code) {
    case ABS_X:
      return kLeftStickX;
    case ABS_Y:
      return kLeftStickY;
    case ABS_RX:
      return kRightStickX;
    case ABS_RY:
      return kRightStickY;
    default:
      return -1;
  }
}

bool IsTriggerAxis(uint16_t code) {
  return code == ABS_Z || code == ABS_RZ;
}

int TriggerAxisToButtonIndex(uint16_t code) {
  if (code == ABS_Z) {
    return kLeftTrigger;
  }
  if (code == ABS_RZ) {
    return kRightTrigger;
  }
  return -1;
}

bool IsHatAxis(uint16_t code) {
  return code == ABS_HAT0X || code == ABS_HAT0Y;
}

}  // namespace ButtonMapping
