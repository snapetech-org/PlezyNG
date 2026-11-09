// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
// Read-only, descriptor-backed libretro VFS. The isolated service never gains
// path-based access to app storage, including when a core opens its firmware.
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

#include "libretro.h"

namespace plezy::retro::inputs {
struct File {
  int fd;
  int64_t size;
};
inline std::map<std::string, File> files;
inline bool configured = false;
inline std::string core;
inline bool ValidPath(const std::string& path) {
  if (path.size() > 1032 || path.find('\0') != std::string::npos || path.find('\\') != std::string::npos) return false;
  if (path.rfind("/rom/", 0) != 0 && path.rfind("/system/", 0) != 0) return false;
  size_t start = 1;
  while (start <= path.size()) {
    const auto end = path.find('/', start);
    const auto part = path.substr(start, end - start);
    if (part.empty() || part == "." || part == "..") return false;
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return true;
}
inline void Add(const std::string& path, int fd) {
  struct stat status {};
  const int flags = fcntl(fd, F_GETFL);
  if (!ValidPath(path) || files.size() >= 65 || files.count(path) || flags < 0 || (flags & O_ACCMODE) != O_RDONLY ||
      fstat(fd, &status) || !S_ISREG(status.st_mode) || status.st_size <= 0 || status.st_size > 256ll * 1024 * 1024)
    throw std::runtime_error("Invalid read-only emulator input");
  files.emplace(path, File{fd, status.st_size});
}
inline bool Directory(const std::string& path) {
  if (path == "/system" || path == "/rom" || path == "/saves") return true;
  if (!ValidPath(path)) return false;
  const auto next = files.lower_bound(path + "/");
  return next != files.end() && next->first.rfind(path + "/", 0) == 0;
}
struct Stream {
  std::string path;
  File file;
  int64_t position = 0;
};
inline const char* Path(retro_vfs_file_handle* stream) {
  return stream ? reinterpret_cast<Stream*>(stream)->path.c_str() : nullptr;
}
inline retro_vfs_file_handle* Open(const char* path, unsigned mode, unsigned) {
  if (!path || mode != RETRO_VFS_FILE_ACCESS_READ) return nullptr;
  const auto it = files.find(path);
  if (it == files.end()) return nullptr;
  auto* stream = new (std::nothrow) Stream{it->first, it->second};
  return reinterpret_cast<retro_vfs_file_handle*>(stream);
}
inline int Close(retro_vfs_file_handle* stream) {
  delete reinterpret_cast<Stream*>(stream);
  return 0;
}
inline int64_t Size(retro_vfs_file_handle* stream) {
  return stream ? reinterpret_cast<Stream*>(stream)->file.size : -1;
}
inline int64_t Tell(retro_vfs_file_handle* stream) { return stream ? reinterpret_cast<Stream*>(stream)->position : -1; }
inline int64_t Seek(retro_vfs_file_handle* stream, int64_t offset, int where) {
  if (!stream || where < RETRO_VFS_SEEK_POSITION_START || where > RETRO_VFS_SEEK_POSITION_END) return -1;
  auto& value = *reinterpret_cast<Stream*>(stream);
  const int64_t base = where == RETRO_VFS_SEEK_POSITION_START ? 0
                       : where == RETRO_VFS_SEEK_POSITION_END ? value.file.size
                                                              : value.position;
  if (offset < -base || offset > value.file.size - base) return -1;
  return value.position = base + offset;
}
inline int64_t Read(retro_vfs_file_handle* stream, void* data, uint64_t length) {
  if (!stream || (!data && length)) return -1;
  auto& value = *reinterpret_cast<Stream*>(stream);
  const auto wanted = static_cast<size_t>(std::min<uint64_t>(length, value.file.size - value.position));
  ssize_t size;
  do {
    size = pread(value.file.fd, data, wanted, static_cast<off_t>(value.position));
  } while (size < 0 && errno == EINTR);
  if (size >= 0) value.position += size;
  return size;
}
inline int Stat(const char* path, int32_t* size) {
  if (!path || !size) return 0;
  *size = 0;
  const auto it = files.find(path);
  if (it != files.end()) {
    *size = static_cast<int32_t>(it->second.size);
    return RETRO_VFS_STAT_IS_VALID;
  }
  return Directory(path) ? RETRO_VFS_STAT_IS_VALID | RETRO_VFS_STAT_IS_DIRECTORY : 0;
}
struct Listing {
  std::vector<std::pair<std::string, bool>> entries;
  size_t next = 0;
};
inline retro_vfs_dir_handle* OpenDir(const char* path, bool) {
  if (!path || !Directory(path)) return nullptr;
  auto listing = std::make_unique<Listing>();
  std::map<std::string, bool> names;
  const std::string prefix = std::string(path) + "/";
  for (const auto& file : files)
    if (file.first.rfind(prefix, 0) == 0) {
      const auto name = file.first.substr(prefix.size());
      const auto slash = name.find('/');
      names[name.substr(0, slash)] = slash != std::string::npos;
    }
  listing->entries.assign(names.begin(), names.end());
  return reinterpret_cast<retro_vfs_dir_handle*>(listing.release());
}
inline bool ReadDir(retro_vfs_dir_handle* dir) {
  if (!dir) return false;
  auto& list = *reinterpret_cast<Listing*>(dir);
  if (list.next == list.entries.size()) return false;
  ++list.next;
  return true;
}
inline const char* DirName(retro_vfs_dir_handle* dir) {
  if (!dir) return nullptr;
  auto& list = *reinterpret_cast<Listing*>(dir);
  return list.next && list.next <= list.entries.size() ? list.entries[list.next - 1].first.c_str() : nullptr;
}
inline bool IsDir(retro_vfs_dir_handle* dir) {
  if (!dir) return false;
  auto& list = *reinterpret_cast<Listing*>(dir);
  return list.next && list.next <= list.entries.size() && list.entries[list.next - 1].second;
}
inline int CloseDir(retro_vfs_dir_handle* dir) {
  delete reinterpret_cast<Listing*>(dir);
  return 0;
}
inline retro_vfs_interface interface = {
    Path,
    Open,
    Close,
    Size,
    Tell,
    Seek,
    Read,
    [](retro_vfs_file_handle*, const void*, uint64_t) -> int64_t { return -1; },
    [](retro_vfs_file_handle*) { return -1; },
    [](const char*) { return -1; },
    [](const char*, const char*) { return -1; },
    [](retro_vfs_file_handle*, int64_t) -> int64_t { return -1; },
    Stat,
    [](const char*) { return -1; },
    OpenDir,
    ReadDir,
    DirName,
    IsDir,
    CloseDir};
inline bool Load(const std::string& path, std::vector<uint8_t>& output) {
  const auto it = files.find(path);
  if (it == files.end() || it->second.size > 128ll * 1024 * 1024) return false;
  output.resize(static_cast<size_t>(it->second.size));
  std::unique_ptr<retro_vfs_file_handle, decltype(&Close)> file(
      Open(path.c_str(), RETRO_VFS_FILE_ACCESS_READ, 0), Close);
  size_t done = 0;
  while (done < output.size()) {
    const auto size = Read(file.get(), output.data() + done, output.size() - done);
    if (size <= 0) return false;
    done += static_cast<size_t>(size);
  }
  return true;
}
}  // namespace plezy::retro::inputs
