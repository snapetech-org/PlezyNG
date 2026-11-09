// SPDX-License-Identifier: AGPL-3.0-only
// Deliberately faulty core adapter. Linked only by the containment tests.
#include "../../native/games/romm/retro_api.h"
#include <fstream>
#include <filesystem>
#include <string>
#include <vector>
#include <chrono>
#include <thread>
#include <cstdlib>
#include <cstring>
#ifdef _WIN32
#include <windows.h>
#else
#include <sys/socket.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#include <sys/resource.h>
#include <signal.h>
#endif
#endif
namespace {
char mode = 'O'; bool loaded = false;
std::vector<uint8_t> snapshot{1, 2, 3, 4};
const uint8_t frame[16] = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255};
void Hang() { for (;;) std::this_thread::sleep_for(std::chrono::seconds(1)); }
}
extern "C" {
void* plezy_retro_alloc(int size) { return std::malloc(size); }
void plezy_retro_free(void* value) { std::free(value); }
int plezy_retro_has_core(const char*) { return 1; }
int plezy_retro_open(const char*, const char* rom, const char*, const char* saves) {
  std::ifstream source(std::filesystem::u8path(rom)); std::string secret; source.get(mode); source.get(); std::getline(source, secret);
  if (!source) return 0;
  if (mode == 'P') {
    std::ifstream denied(std::filesystem::u8path(secret)); if (denied.good() || std::getenv("PLEZY_TEST_SECRET")) return 0;
    std::ofstream alsoDenied(std::filesystem::u8path(secret), std::ios::app); if (alsoDenied.good()) return 0;
    std::ofstream blocked(std::filesystem::u8path(saves) / "fixture-save"); if (blocked.good()) return 0;
#ifdef _WIN32
    HANDLE token = nullptr; DWORD isolated = 0, size = 0;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return 0;
    const auto ok = GetTokenInformation(token, TokenIsAppContainer, &isolated, sizeof(isolated), &size);
    CloseHandle(token); if (!ok || !isolated) return 0;
#elif defined(__linux__)
    const int connection = socket(AF_INET, SOCK_STREAM, 0);
    if (connection >= 0) { close(connection); return 0; }
    // Signal 0 only checks permission. Never send an actual signal to the
    // test parent, even if a future sandbox regression allows this syscall.
    siginfo_t signal{};
    if (syscall(SYS_rt_sigqueueinfo, getppid(), 0, &signal) != -1 || errno != EPERM) return 0;
    rlimit limit{};
    if (syscall(SYS_prlimit64, getppid(), RLIMIT_NOFILE, nullptr, &limit) != -1 || errno != EPERM) return 0;
#endif
  }
  loaded = true; return 1;
}
void plezy_retro_close() { if (mode == 'D') Hang(); loaded = false; }
int plezy_retro_shutdown_complete() { return !loaded; }
int plezy_retro_healthy() { return loaded; }
void plezy_retro_run() {
  if (mode == 'H') Hang();
  if (mode == 'C') *static_cast<volatile int*>(nullptr) = 1;
}
double plezy_retro_fps() { return 60; }
double plezy_retro_aspect() { return 1; }
const char* plezy_retro_identity() { return "fixture/1"; }
int plezy_retro_width() { return mode == 'F' ? 4096 : 2; }
int plezy_retro_height() { return 2; }
const uint8_t* plezy_retro_frame() { return frame; }
void plezy_retro_buttons(int, int) {}
void plezy_retro_pause_audio(int) {}
int plezy_retro_sample_rate() { return 48000; }
int plezy_retro_read_audio(int16_t*, int) { return 0; }
int plezy_retro_capture(int) { return mode == 'M' ? 134217729 : int(snapshot.size()); }
const uint8_t* plezy_retro_snapshot() { return snapshot.data(); }
int plezy_retro_restore(const uint8_t* data, int size, int) { snapshot.assign(data, data + size); return 1; }
}
