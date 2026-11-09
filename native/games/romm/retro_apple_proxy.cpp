// SPDX-License-Identifier: AGPL-3.0-only
#include "retro_apple_process.h"
extern "C" __attribute__((visibility("default"))) void plezy_retro_apple_initialize(
    plezy::retro::apple_process::Launch launch, plezy::retro::apple_process::Stop stop,
    plezy::retro::apple_process::Dead dead, plezy::retro::apple_process::Release release) {
  using namespace plezy::retro::apple_process;
  if (!launch || !stop || !dead || !release || ready.load(std::memory_order_acquire)) return;
  plezy::retro::apple_process::launch = launch;
  plezy::retro::apple_process::stop = stop;
  plezy::retro::apple_process::dead = dead;
  plezy::retro::apple_process::release = release;
  ready.store(true, std::memory_order_release);
}
