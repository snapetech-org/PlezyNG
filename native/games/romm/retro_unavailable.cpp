// SPDX-License-Identifier: GPL-3.0-or-later
// ABI-compatible unavailable host for platforms without an OS-isolated worker.
// Do not load libraries or inspect game files here, including during probing.
#define PLEZY_RETRO_PROXY_BUILD
#include <cstdlib>

#include "retro_api.h"

extern "C" {
void* plezy_retro_alloc(int size) {
  return size > 0 && size <= 134217728 ? std::malloc(static_cast<size_t>(size)) : nullptr;
}
void plezy_retro_free(void* data) { std::free(data); }
int plezy_retro_isolation_version() { return 0; }
int plezy_retro_has_core(const char*) { return 0; }
int plezy_retro_open(const char*, const char*, const char*, const char*) { return 0; }
void plezy_retro_close() {}
int plezy_retro_shutdown_complete() { return 1; }
void plezy_retro_run() {}
int plezy_retro_healthy() { return 0; }
double plezy_retro_fps() { return 0; }
double plezy_retro_aspect() { return 0; }
const char* plezy_retro_identity() { return ""; }
int plezy_retro_width() { return 0; }
int plezy_retro_height() { return 0; }
const uint8_t* plezy_retro_frame() { return nullptr; }
void plezy_retro_buttons(int, int) {}
void plezy_retro_pause_audio(int) {}
int plezy_retro_capture(int) { return 0; }
const uint8_t* plezy_retro_snapshot() { return nullptr; }
int plezy_retro_restore(const uint8_t*, int, int) { return 0; }
}
