// SPDX-License-Identifier: AGPL-3.0-only
// Linked only into the enhanced-security extension, never into PlezyRetro.
#include <cstdlib>
#include <filesystem>
#include "retro_input_files.h"
int RommWorkerMain(int channel);

extern "C" int plezy_retro_apple_configure(const char* core, const char* const* names,
                                          const int* descriptors, int count) {
  try {
    using namespace plezy::retro;
    if (inputs::configured || !core || count < 0 || count > 65 || (count && (!names || !descriptors)))
      return 0;
    const auto path = std::filesystem::path(core);
    const auto name = path.filename().string();
    if ((name != "gambatte_libretro" && name != "mgba_libretro" && name != "fceumm_libretro") ||
        path.parent_path().filename() != name + ".framework" ||
        path.parent_path().parent_path().filename() != "Frameworks")
      return 0;
    inputs::core = core;
    uint64_t total = 0;
    size_t games = 0;
    for (int n = 0; n < count; ++n) {
      if (!names[n]) return 0;
      const std::string virtualPath(names[n]);
      inputs::Add(virtualPath, descriptors[n]);
      total += inputs::files.at(virtualPath).size;
      games += virtualPath.rfind("/rom/", 0) == 0;
    }
    if (games > 1 || (count && !games) || total > 384ull * 1024 * 1024) return 0;
    inputs::configured = true;
    return 1;
  } catch (...) {
    return 0;
  }
}

extern "C" void plezy_retro_apple_run(int descriptor) {
  if (!plezy::retro::inputs::configured || descriptor < 0) std::_Exit(2);
  RommWorkerMain(descriptor);
  std::_Exit(0);
}
