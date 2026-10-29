// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

namespace plezy::steam {
struct StreamOptions {
  int width = 1920, height = 1080, fps = 60, bitrateKbps = 30000;
  int controllerCount = 1;
  int audioChannels = 2;
  bool hdr10 = false;  // Actual qualified native output, not merely a preference.
  bool microphone = true;  // Native capture availability; consent is separate.
  // Current request bounds, not the decoder's theoretical limits.
  bool valid() const {
    return width >= 640 && width <= 3840 && height >= 360 && height <= 2160 && width % 2 == 0 && height % 2 == 0 &&
           fps >= 15 && fps <= 120 && bitrateKbps >= 1000 && bitrateKbps <= 100000 && controllerCount >= 1 &&
           controllerCount <= 4 && (audioChannels == 2 || audioChannels == 4 || audioChannels == 6);
  }
};
}  // namespace plezy::steam
