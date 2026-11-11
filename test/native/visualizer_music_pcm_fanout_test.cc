// SPDX-License-Identifier: AGPL-3.0-only
#include "../../shared/visualization/music_pcm_fanout.h"
#include <cassert>
#include <iostream>
using namespace plezy::visualization;
int main() {
  MusicPcmFanout bank;
  int toggles = 0, reads = 0;
  bool active = false;
  auto enable = [&](bool value) { ++toggles; active = value; return 0; };
  auto read = [&](mpv_plezy_audio_block* block) {
    *block = {};
    block->generation = 1;
    block->frames = 1;
    block->channels = 2;
    block->sample_rate = 44100;
    block->pts = ++reads;
    block->samples[0] = static_cast<float>(reads);
    return 1;
  };
  mpv_plezy_audio_block captured{}, visual{};
  assert(bank.EnableVisual(1, true, enable) == 0);
  assert(bank.ReadVisual(1, &visual, 0, read) == 1 && reads == 1);
  assert(bank.EnableCapture(1, true, enable) == 0 && toggles == 1);
  assert(bank.ReadCapture(1, &captured, 1, read) == 1 && captured.pts == 2);
  assert(bank.ReadVisual(1, &visual, 1, read) == 0 && reads == 2);
  assert(bank.ReadVisual(1, &visual, 2, read) == 1 && visual.pts == captured.pts);
  assert(reads == 2); // The visualizer consumed a copy, never the ordered tap.
  for (int i = 0; i < 40; ++i) assert(bank.ReadCapture(1, &captured, 100, read) == 1);
  assert(bank.ReadVisual(1, &visual, NAN, read) == 1 && visual.pts == captured.pts);
  assert(bank.ReadVisual(1, &visual, 100, read) == 0);
  assert(bank.ReadCapture(1, &captured, 100, read) == 1);
  auto next_generation = [](mpv_plezy_audio_block* block) {
    *block = {}; block->generation = 2; block->pts = 0.5; return 1;
  };
  assert(bank.ReadCapture(1, &captured, 1, next_generation) == 1);
  assert(bank.ReadVisual(1, &visual, 1, read) == 1 && visual.generation == 2);
  assert(bank.EnableCapture(1, false, enable) == 0 && toggles == 1 && active);
  assert(bank.ReadVisual(1, &visual, 100, read) == 1 && reads == 44);
  assert(bank.ReadCapture(1, &captured, 100, read) < 0);
  assert(bank.EnableVisual(1, false, enable) == 0 && toggles == 2 && !active);
  assert(bank.EnableCapture(0, true, enable) < 0);
  assert(bank.EnableCapture(1, true, [](bool) { return -1; }) < 0);
  for (uint64_t key = 1; key <= 16; ++key) assert(bank.EnableCapture(key, true, enable) == 0);
  assert(bank.EnableCapture(17, true, enable) < 0);
  bank.Forget(1);
  const uint64_t wide_key = uint64_t{1} << 40;
  assert(bank.EnableCapture(wide_key, true, enable) == 0);
  assert(bank.ReadCapture(1, &captured, 100, read) < 0);
  assert(bank.ReadCapture(wide_key, &captured, 100, read) == 1);
  std::cout << "Music PCM fan-out passed.\n";
}
