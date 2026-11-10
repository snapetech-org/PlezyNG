// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <atomic>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>
#include "../../../shared/process/byte_pipe.h"

namespace plezy::retro::apple_process {
using Launch = int (*)(const char*, const char*, const char*, void**);
using Stop = void (*)(void*);
using Dead = int (*)(void*);
using Release = void (*)(void*);
inline Launch launch = nullptr;
inline Stop stop = nullptr;
inline Dead dead = nullptr;
inline Release release = nullptr;
inline std::atomic<bool> ready{false};

class Control {
 public:
  void* worker = nullptr;
  ~Control() {
    Abort();
    if (worker && release) release(worker);
  }
  void Abort() noexcept { if (worker && stop) stop(worker); }
  bool Reaped() noexcept { return !worker || (dead && dead(worker) == 1); }
};
inline void Retire(const std::shared_ptr<Control>& control) noexcept { control->Abort(); }
inline std::unique_ptr<plezy::process::BytePipe> Spawn(
    const std::string& core, const std::string& rom, const std::string& system,
    const std::shared_ptr<Control>& control) {
  if (!ready.load(std::memory_order_acquire) || !launch)
    throw std::runtime_error("Enhanced Security emulator extension is unavailable");
  const int descriptor = launch(core.c_str(), rom.c_str(), system.c_str(), &control->worker);
  if (descriptor < 0 || !control->worker)
    throw std::runtime_error("Enhanced Security emulator extension failed to launch");
  return std::make_unique<plezy::process::BytePipe>(descriptor);
}
}  // namespace plezy::retro::apple_process
