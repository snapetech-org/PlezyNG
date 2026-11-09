// SPDX-License-Identifier: AGPL-3.0-only
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>

#include "../../native/games/romm/retro_api.h"
namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;
void Require(bool value, const char* error) {
  if (!value) throw std::runtime_error(error);
}
void Reap() {
  const auto deadline = Clock::now() + std::chrono::seconds(3);
  while (!plezy_retro_shutdown_complete() && Clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  Require(plezy_retro_shutdown_complete() == 1, "Worker did not terminate; lease must remain held");
}
int main(int argc, char** argv) {
  try {
    Require(argc == 3 || argc == 4, "Expected fixture directory and test mode");
    const bool production = std::string(argv[2]) == "production";
    const bool descriptor = std::string(argv[2]) == "descriptor";
    Require(!production || argc == 4, "Expected production fixture core");
    const fs::path root = fs::u8path(argv[1]);
    fs::create_directories(root / "system");
    fs::create_directories(root / "saves");
    Require(!descriptor || argc == 4, "Expected descriptor fixture core");
    const auto core = descriptor ? std::string(argv[3]) : (root / "core.bin").u8string();
    const auto rom = (root / "game.bin").u8string();
    const auto system = (root / "system").u8string(), saves = (root / "saves").u8string();
    const auto secret = (root / "private-credential-fixture").u8string();
    if (production)
      fs::copy_file(fs::u8path(argv[3]), fs::u8path(core), fs::copy_options::overwrite_existing);
    else if (!descriptor)
      std::ofstream(core) << "fixture";
    std::ofstream(root / "system" / "bios.bin") << "DUMMY-FIRMWARE";
    std::ofstream(secret) << "DUMMY-CREDENTIAL";
    auto open = [&](char mode) {
      std::ofstream(rom) << mode << "\n" << secret << "\n";
      Require(plezy_retro_open(core.c_str(), rom.c_str(), system.c_str(), saves.c_str()) == 1, "Isolated open failed");
    };
    if (std::string(argv[2]) == "faults") {
      for (char mode : {'A', 'Q', 'T', 'R', 'N', 'L', 'I'}) {
        open(mode);
        const auto start = Clock::now();
        if (mode == 'I')
          plezy_retro_pause_audio(0);
        else
          plezy_retro_run();
        Require(!plezy_retro_healthy(), "Malformed worker response accepted");
        Require(Clock::now() - start < std::chrono::seconds(4), "Absolute response deadline exceeded");
        plezy_retro_close();
        Reap();
        std::cout << "Rejected protocol fault " << mode << "\n";
      }
    } else {
      Require(plezy_retro_has_core(core.c_str()) == 1, "Sandboxed core probe failed");
      Reap();
      for (char mode : {'O', 'P'}) {
        open(mode);
        plezy_retro_pause_audio(0);
        plezy_retro_buttons(0, 1);
        plezy_retro_run();
        Require(plezy_retro_healthy() && plezy_retro_width() == 2 && plezy_retro_height() == 2, "Valid frame rejected");
        Require(plezy_retro_frame() && plezy_retro_frame()[0] == 255, "Frame changed");
        const uint8_t state[]{7, 8, 9};
        Require(plezy_retro_restore(state, 3, 1) == 1, "Restore failed");
        Require(plezy_retro_capture(1) == 3 && plezy_retro_snapshot()[0] == 7, "Save round-trip failed");
        plezy_retro_close();
        Reap();
        std::cout << "Passed isolated session " << mode << "\n";
      }
      if (!production)
        for (char mode : (descriptor ? std::string("CHMD") : std::string("CHFMD"))) {
          open(mode);
          const auto start = Clock::now();
          if (mode == 'D')
            plezy_retro_close();
          else {
            if (mode == 'M')
              Require(plezy_retro_capture(1) == 0, "Oversized state accepted");
            else
              plezy_retro_run();
            // The production adapter rejects oversized states before IPC.
            if (!descriptor || mode != 'M') Require(!plezy_retro_healthy(), "Faulty core remained healthy");
            plezy_retro_close();
          }
          Reap();
          Require(Clock::now() - start < std::chrono::seconds(5), "Core fault escaped its deadline");
          open('O');
          plezy_retro_run();
          Require(plezy_retro_healthy() == 1, "Could not restart after core failure");
          plezy_retro_close();
          Reap();
          std::cout << "Recovered core fault " << mode << "\n";
        }
      std::ifstream check(secret);
      std::string value;
      check >> value;
      Require(value == "DUMMY-CREDENTIAL", "Sandbox modified unrelated credentials");
    }
    std::cout << "All emulator containment checks passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << "\n";
    plezy_retro_close();
    return 1;
  }
}
