// SPDX-License-Identifier: AGPL-3.0-only
#include "../../shared/visualization/music_pcm_downmix.h"
#include <cassert>
#include <iostream>
#include <limits>
using namespace plezy::visualization;
int main() {
  mpv_plezy_audio_block block{};
  block.generation = 7; block.frames = 2; block.channels = 2;
  block.sample_rate = 96000; block.pts = 4.25;
  block.speaker_ids[0] = 0; block.speaker_ids[1] = 1;
  block.samples[0] = .25f; block.samples[1] = -.5f; block.samples[2] = .5f; block.samples[3] = -.25f;
  assert(DownmixMusicPcm(&block));
  assert(block.samples[0] == .25f && block.samples[1] == -.5f && block.samples[2] == .5f);
  assert(block.generation == 7 && block.sample_rate == 96000 && block.pts == 4.25);
  block.speaker_ids[0] = 1; block.speaker_ids[1] = 0;
  assert(DownmixMusicPcm(&block) && block.samples[0] == -.5f && block.samples[1] == .25f);
  block.frames = 2; block.channels = 1; block.speaker_ids[0] = 2;
  block.samples[0] = .125f; block.samples[1] = -.25f;
  assert(DownmixMusicPcm(&block) && block.channels == 2);
  assert(block.samples[0] == .125f && block.samples[1] == .125f &&
    block.samples[2] == -.25f && block.samples[3] == -.25f);
  const std::array<uint8_t, 8> surround{0,1,2,3,4,5,9,10};
  block.frames = MPV_PLEZY_AUDIO_TAP_FRAMES; block.channels = 8;
  std::copy(surround.begin(),surround.end(),block.speaker_ids);
  std::fill(std::begin(block.samples),std::end(block.samples),1.0f);
  assert(DownmixMusicPcm(&block));
  for (uint32_t i = 0; i < block.frames*2; ++i) assert(block.samples[i] == 1.0f);
  block.frames = 1; block.channels = 6;
  std::copy(surround.begin(),surround.begin()+6,block.speaker_ids);
  std::fill(std::begin(block.samples),std::end(block.samples),0.0f);
  block.samples[2] = 1.0f;
  assert(DownmixMusicPcm(&block));
  assert(block.samples[0] > .29f && block.samples[0] < .30f && block.samples[0] == block.samples[1]);
  block.channels = 2; block.speaker_ids[0] = 3; block.speaker_ids[1] = 35;
  block.samples[0] = 1; block.samples[1] = 1;
  assert(DownmixMusicPcm(&block) && block.samples[0] == 0 && block.samples[1] == 0);
  block.channels = 2; block.speaker_ids[0] = 64; block.speaker_ids[1] = 64;
  assert(DownmixMusicPcm(&block));
  block.channels = 2; block.speaker_ids[0] = 0; block.speaker_ids[1] = 0;
  assert(!DownmixMusicPcm(&block));
  block.speaker_ids[1] = 18;
  assert(!DownmixMusicPcm(&block));
  block.speaker_ids[1] = 1; block.samples[0] = std::numeric_limits<float>::quiet_NaN();
  assert(!DownmixMusicPcm(&block));
  block.frames = MPV_PLEZY_AUDIO_TAP_FRAMES + 1;
  assert(!DownmixMusicPcm(&block));
  std::cout << "Music PCM speaker downmix passed.\n";
}
