// SPDX-License-Identifier: AGPL-3.0-only
#include <iostream>

#include "../../native/games/romm/retro_api.h"

int main(int argc, char** argv) {
  if (argc != 2) return 2;
  // The fixture aborts in its constructor if loaded into this process.
  if (plezy_retro_isolation_version() != 0 || plezy_retro_has_core(argv[1]) != 0 ||
      plezy_retro_open(argv[1], "untrusted.rom", "firmware", "saves") != 0)
    return 1;
  plezy_retro_run();
  plezy_retro_close();
  if (plezy_retro_healthy() || !plezy_retro_shutdown_complete() || plezy_retro_frame() || plezy_retro_snapshot() ||
      plezy_retro_capture(1) || plezy_retro_restore(nullptr, 0, 1))
    return 1;
  std::cout << "Unavailable host refused core execution and preserved safe shutdown\n";
  return 0;
}
