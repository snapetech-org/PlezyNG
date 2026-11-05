// SPDX-License-Identifier: AGPL-3.0-only
#include "../../shared/visualization/preset_transition.h"
#include <iostream>
#include <limits>
#include <utility>
using plezy::visualization::PresetTransition;
namespace {
void Require(bool condition) {
  if (!condition) throw std::runtime_error("Preset transition regression failed.");
}
}
int main() {
  try {
    PresetTransition fade;
    const std::vector<uint8_t> old = {0, 64, 255, 255}, next = {255, 192, 0, 255};
    auto frame = next;
    fade.Start(old, 1, 1, 2);
    fade.Apply(frame, 1, 1, 0);
    Require(frame == old);
    frame = next;
    fade.Apply(frame, 1, 1, 0.5);
    Require(frame == std::vector<uint8_t>({40, 84, 215, 255})); // Smoothstep(0.25).
    frame = next;
    fade.Apply(frame, 1, 1, 1);
    Require(frame == std::vector<uint8_t>({128, 128, 128, 255}));
    const auto midpoint = frame;
    frame = next;
    fade.Apply(frame, 1, 1, 1); // A paused clock must preserve the same mixture.
    Require(frame == midpoint);
    fade.Start(midpoint, 1, 1, 1); // Rapid changes start at the last displayed mix.
    frame = next;
    fade.Apply(frame, 1, 1, 0);
    Require(frame == midpoint);
    frame = next;
    fade.Apply(frame, 1, 1, 1);
    Require(frame == next);
    fade.Apply(frame, 1, 1, 0); // Completion releases the source image.
    Require(frame == next);
    fade.Start(old, 1, 1, 2);
    fade.Start(old, 1, 1, 0); // Explicit hard cut cancels an active transition.
    frame = next;
    fade.Apply(frame, 1, 1, 0);
    Require(frame == next);
    fade.Start(old, 1, 1, 2);
    fade.Clear(); // Audio generation reset must not carry another track's image.
    fade.Apply(frame, 1, 1, 0);
    Require(frame == next);

    const std::vector<uint8_t> row = {0, 10, 20, 255, 100, 110, 120, 255};
    fade.Start(row, 2, 1, 2);
    frame.assign(4 * 2 * 4, 0);
    fade.Apply(frame, 4, 2, 0);
    for (size_t y = 0; y < 2; ++y)
      for (size_t x = 0; x < 4; ++x)
        for (size_t c = 0; c < 4; ++c)
          Require(frame[(y * 4 + x) * 4 + c] == row[(x / 2) * 4 + c]);

    for (double duration : {-1.0, 10.01, std::numeric_limits<double>::infinity(),
                            std::numeric_limits<double>::quiet_NaN()}) {
      bool rejected = false;
      try { fade.Start(old, 1, 1, duration); }
      catch (const std::runtime_error&) { rejected = true; }
      Require(rejected);
    }
    for (const auto dimensions : {std::pair<uint32_t, uint32_t>{0, 1}, {4097, 1}, {4096, 4096}, {2, 1}}) {
      fade.Start(old, dimensions.first, dimensions.second, 1);
      frame = next;
      fade.Apply(frame, 1, 1, 0);
      Require(frame == next); // Invalid sizes never index outside a buffer.
    }
    fade.Start(old, 1, 1, 1);
    frame.clear();
    fade.Apply(frame, 1, 1, 0);
    frame = next;
    fade.Apply(frame, 1, 1, 0);
    Require(frame == next);
    fade.Start(old, 1, 1, 1);
    fade.Apply(frame, 1, 1, std::numeric_limits<double>::quiet_NaN());
    Require(frame == next);
    std::cout << "Preset transition regressions passed\n";
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
