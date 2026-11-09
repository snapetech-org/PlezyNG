// SPDX-License-Identifier: AGPL-3.0-only
// A tiny test core exercises the production dlopen/LoadLibrary and libretro
// adapter. It is never installed or included in an application package.
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <vector>

#include "libretro.h"

namespace {
retro_environment_t environment = nullptr;
retro_video_refresh_t video = nullptr;
retro_audio_sample_batch_t audio = nullptr;
std::vector<uint8_t> state{1, 2, 3, 4};
// Run in the library constructor, not only in retro_load_game.
const bool privateEnvironment = std::getenv("PLEZY_TEST_SECRET") == nullptr;
}  // namespace
extern "C" {
RETRO_API void retro_set_environment(retro_environment_t callback) { environment = callback; }
RETRO_API void retro_set_video_refresh(retro_video_refresh_t callback) { video = callback; }
RETRO_API void retro_set_audio_sample(retro_audio_sample_t) {}
RETRO_API void retro_set_audio_sample_batch(retro_audio_sample_batch_t callback) { audio = callback; }
RETRO_API void retro_set_input_poll(retro_input_poll_t) {}
RETRO_API void retro_set_input_state(retro_input_state_t) {}
RETRO_API void retro_set_controller_port_device(unsigned, unsigned) {}
RETRO_API void retro_init() {
  retro_pixel_format format = RETRO_PIXEL_FORMAT_XRGB8888;
  environment(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &format);
}
RETRO_API void retro_deinit() {}
RETRO_API unsigned retro_api_version() { return RETRO_API_VERSION; }
RETRO_API void retro_get_system_info(retro_system_info* info) {
  *info = {"isolated-test-core", "1", "bin", false, false};
}
RETRO_API void retro_get_system_av_info(retro_system_av_info* info) { *info = {{2, 2, 2, 2, 1}, {60, 48000}}; }
RETRO_API bool retro_load_game(const retro_game_info* game) {
  if (!privateEnvironment || !game || !game->data || !game->size) return false;
  std::istringstream input(std::string(static_cast<const char*>(game->data), game->size));
  std::string mode, secret;
  std::getline(input, mode);
  std::getline(input, secret);
  if (!input) return false;
  if (mode == "P") {
    std::ifstream denied(std::filesystem::u8path(secret));
    if (denied.good()) return false;
    std::ofstream blocked(std::filesystem::u8path(secret), std::ios::app);
    if (blocked.good()) return false;
    const char* saves = nullptr;
    if (!environment(RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY, &saves) || !saves) return false;
    std::ofstream write(std::filesystem::u8path(saves) / "forbidden");
    if (write.good()) return false;
  }
  return true;
}
RETRO_API void retro_unload_game() {}
RETRO_API void retro_run() {
  const uint32_t pixels[]{0xff0000, 0x00ff00, 0x0000ff, 0xffffff};
  const int16_t pcm[]{100, -100, 200, -200};
  video(pixels, 2, 2, 8);
  audio(pcm, 2);
}
RETRO_API size_t retro_serialize_size() { return state.size(); }
RETRO_API bool retro_serialize(void* bytes, size_t size) {
  if (size != state.size()) return false;
  std::memcpy(bytes, state.data(), size);
  return true;
}
RETRO_API bool retro_unserialize(const void* bytes, size_t size) {
  const auto* data = static_cast<const uint8_t*>(bytes);
  state.assign(data, data + size);
  return true;
}
RETRO_API void* retro_get_memory_data(unsigned) { return state.data(); }
RETRO_API size_t retro_get_memory_size(unsigned) { return state.size(); }
}
