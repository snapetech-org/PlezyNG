// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
extern "C" {
void* plezy_retro_alloc(int size);
void plezy_retro_free(void* data);
int plezy_retro_has_core(const char* path);
int plezy_retro_open(const char* core, const char* rom, const char* system, const char* saves);
void plezy_retro_close();
int plezy_retro_shutdown_complete();
void plezy_retro_run();
int plezy_retro_healthy();
double plezy_retro_fps();
double plezy_retro_aspect();
const char* plezy_retro_identity();
int plezy_retro_width();
int plezy_retro_height();
const uint8_t* plezy_retro_frame();
void plezy_retro_buttons(int port, int buttons);
void plezy_retro_pause_audio(int paused);
int plezy_retro_capture(int kind);
const uint8_t* plezy_retro_snapshot();
int plezy_retro_restore(const uint8_t* bytes, int size, int kind);
// Only linked into the isolated host, never loaded from an untrusted core.
int plezy_retro_sample_rate();
int plezy_retro_read_audio(int16_t* output, int maximum);
}
