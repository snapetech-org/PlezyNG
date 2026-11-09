// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#if defined(_WIN32) && defined(PLEZY_RETRO_PROXY_BUILD)
// MSVC requires exported declarations and their definitions to agree.
#define PLEZY_RETRO_EXPORT __declspec(dllexport)
#elif defined(_WIN32)
#define PLEZY_RETRO_EXPORT
#else
#define PLEZY_RETRO_EXPORT __attribute__((visibility("default")))
#endif
extern "C" {
PLEZY_RETRO_EXPORT void* plezy_retro_alloc(int size);
PLEZY_RETRO_EXPORT void plezy_retro_free(void* data);
PLEZY_RETRO_EXPORT int plezy_retro_isolation_version();
PLEZY_RETRO_EXPORT int plezy_retro_has_core(const char* path);
PLEZY_RETRO_EXPORT int plezy_retro_open(const char* core, const char* rom, const char* system, const char* saves);
PLEZY_RETRO_EXPORT void plezy_retro_close();
PLEZY_RETRO_EXPORT int plezy_retro_shutdown_complete();
PLEZY_RETRO_EXPORT void plezy_retro_run();
PLEZY_RETRO_EXPORT int plezy_retro_healthy();
PLEZY_RETRO_EXPORT double plezy_retro_fps();
PLEZY_RETRO_EXPORT double plezy_retro_aspect();
PLEZY_RETRO_EXPORT const char* plezy_retro_identity();
PLEZY_RETRO_EXPORT int plezy_retro_width();
PLEZY_RETRO_EXPORT int plezy_retro_height();
PLEZY_RETRO_EXPORT const uint8_t* plezy_retro_frame();
PLEZY_RETRO_EXPORT void plezy_retro_buttons(int port, int buttons);
PLEZY_RETRO_EXPORT void plezy_retro_pause_audio(int paused);
PLEZY_RETRO_EXPORT int plezy_retro_capture(int kind);
PLEZY_RETRO_EXPORT const uint8_t* plezy_retro_snapshot();
PLEZY_RETRO_EXPORT int plezy_retro_restore(const uint8_t* bytes, int size, int kind);
// Only linked into the isolated host, never loaded from an untrusted core.
int plezy_retro_sample_rate();
int plezy_retro_read_audio(int16_t* output, int maximum);
}
