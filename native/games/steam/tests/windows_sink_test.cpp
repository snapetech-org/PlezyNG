// SPDX-License-Identifier: GPL-3.0-or-later
#include <algorithm>
#include <cassert>
#include <condition_variable>
#include <cstdint>
#include <cstdio>

#include "SteamWindowsSink.h"
#include "red_h264.h"

int main() {
  using namespace plezy::steam;
  // Windows N without the Media Feature Pack is an unsupported deployment,
  // not a passing receiver test. CI must actually have a decoder installed.
  assert(WindowsSink::supported());
  for (int iteration = 0; iteration < 3; ++iteration) {
    std::mutex mutex;
    std::condition_variable ready;
    bool failed = false, presented = false, red = false;
    WindowsSink sink(
        [&](DecodedPixels&& image) {
          const bool geometry = image.id == 7 && image.width == 64 && image.height == 64 &&
                                image.rgba.size() == 64 * 64 * 4;
          bool valid = false;
          uint8_t center[4]{};
          if (geometry) {
            constexpr int patchStart = 24;
            constexpr int patchSize = 16;
            uint32_t channels[3]{};
            for (int y = patchStart; y < patchStart + patchSize; ++y) {
              for (int x = patchStart; x < patchStart + patchSize; ++x) {
                const size_t offset = (static_cast<size_t>(y) * 64 + x) * 4;
                channels[0] += image.rgba[offset];
                channels[1] += image.rgba[offset + 1];
                channels[2] += image.rgba[offset + 2];
              }
            }
            const size_t centerOffset = (32 * 64 + 32) * 4;
            std::copy_n(image.rgba.data() + centerOffset, 4, center);
            constexpr uint32_t pixelCount = patchSize * patchSize;
            valid = channels[0] / pixelCount > 200 && channels[1] / pixelCount < 50 &&
                    channels[2] / pixelCount < 50 && center[3] == 255;
          }
          if (!valid) {
            std::fprintf(stderr,
                         "Windows sink returned unexpected frame: id=%u size=%ux%u bytes=%zu center=(%u,%u,%u,%u)\n",
                         image.id, image.width, image.height, image.rgba.size(), center[0], center[1], center[2],
                         center[3]);
          }
          {
            std::lock_guard<std::mutex> lock(mutex);
            presented = true;
            red = valid;
          }
          ready.notify_all();
          return true;
        },
        [](uint32_t, bool) {},
        [&](bool) {
          {
            std::lock_guard<std::mutex> lock(mutex);
            failed = true;
          }
          ready.notify_all();
        });
    assert(!sink.video(99, 64, 64, nullptr, 0));
    assert(!sink.video(4, 100000, 64, nullptr, 0));
    assert(!sink.frame(redH264, 2 * 1024 * 1024 + 1, 1, true));
    assert(!sink.audio(8, 48000));
    assert(sink.video(4, 64, 64, nullptr, 0));
    assert(sink.frame(redH264, sizeof(redH264), 7, true));
    {
      std::unique_lock<std::mutex> lock(mutex);
      ready.wait_for(lock, std::chrono::seconds(5), [&] { return presented || failed; });
      assert(!failed && presented && red);
    }
    sink.close();
    sink.close();
    assert(!sink.frame(redH264, sizeof(redH264), 8, true));
  }
}
