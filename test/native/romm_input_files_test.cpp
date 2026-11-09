// SPDX-License-Identifier: AGPL-3.0-only
#include <cassert>
#include <cstdio>
#include <filesystem>
#include <fstream>

#include "../../native/games/romm/retro_input_files.h"
int main() {
  using namespace plezy::retro::inputs;
  char folder[] = "/tmp/romm-vfs-XXXXXX";
  assert(mkdtemp(folder));
  const auto path = std::filesystem::path(folder) / "input";
  std::ofstream(path) << "ROM-BYTES";
  const int writable = open(path.c_str(), O_RDWR);
  bool rejected = false;
  try {
    Add("/rom/game.bin", writable);
  } catch (...) {
    rejected = true;
  }
  assert(rejected);
  ::close(writable);
  const int fd = open(path.c_str(), O_RDONLY);
  Add("/rom/game.bin", fd);
  Add("/system/nested/bios.bin", fd);
  assert(!ValidPath("/system/../private") && !ValidPath("/system//bios") && !ValidPath("/private/credentials"));
  assert(!Open("/rom/game.bin", RETRO_VFS_FILE_ACCESS_READ_WRITE, 0));
  assert(!Open("/system/../private", RETRO_VFS_FILE_ACCESS_READ, 0));
  auto* stream = Open("/rom/game.bin", RETRO_VFS_FILE_ACCESS_READ, 0);
  assert(stream && Size(stream) == 9 && Tell(stream) == 0);
  assert(Seek(stream, INT64_MIN, RETRO_VFS_SEEK_POSITION_CURRENT) == -1);
  assert(Seek(stream, INT64_MAX, RETRO_VFS_SEEK_POSITION_END) == -1);
  assert(Seek(stream, -5, RETRO_VFS_SEEK_POSITION_END) == 4);
  char bytes[16]{};
  assert(Read(stream, bytes, UINT64_MAX) == 5 && std::string(bytes, 5) == "BYTES");
  assert(Read(stream, bytes, sizeof(bytes)) == 0 && interface.write(stream, "X", 1) == -1);
  Close(stream);
  std::vector<uint8_t> contents;
  assert(Load("/rom/game.bin", contents) && std::string(contents.begin(), contents.end()) == "ROM-BYTES");
  auto* directory = OpenDir("/system", false);
  assert(directory && ReadDir(directory) && std::string(DirName(directory)) == "nested" && IsDir(directory));
  assert(!ReadDir(directory));
  CloseDir(directory);
  // The descriptor remains usable after the private parent pathname is gone.
  std::filesystem::remove(path);
  assert(Load("/rom/game.bin", contents) && contents.size() == 9);
  ::close(fd);
  std::filesystem::remove(folder);
  std::puts("Read-only emulator VFS checks passed");
}
