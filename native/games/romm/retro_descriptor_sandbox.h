// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
// Older TV kernels lack Landlock. Preload ONLY a package-pinned software core,
// open selected read-only inputs, then install a default-deny syscall policy
// before any ROM or firmware reaches the core. No path access follows admission.
#include <dirent.h>
#include <dlfcn.h>
#include <elf.h>
#include <linux/audit.h>
#include <linux/capability.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <array>
#include <cstddef>
#include <filesystem>
#include "retro_input_files.h"
#ifndef PR_CAP_AMBIENT
#define PR_CAP_AMBIENT 47
#define PR_CAP_AMBIENT_CLEAR_ALL 4
#endif

namespace plezy::retro {
inline void* descriptorCoreModule = nullptr;
inline std::string descriptorCorePath;

inline void RestrictDescriptorSyscalls() {
  // No sibling thread may survive PR_SET_SECCOMP. Bundled core constructors
  // must stay single-threaded. New cores receive no clone/fork/JIT permission.
  auto* tasks = opendir("/proc/self/task");
  if (!tasks) throw std::runtime_error("Cannot inspect emulator thread isolation");
  int count = 0;
  while (auto* item = readdir(tasks))
    if (item->d_name[0] != '.') ++count;
  closedir(tasks);
  if (count != 1) throw std::runtime_error("Emulator bootstrap must be single-threaded");
  __user_cap_header_struct header{_LINUX_CAPABILITY_VERSION_3, 0};
  __user_cap_data_struct capabilities[2]{};
  if (syscall(SYS_capset, &header, capabilities)) throw std::runtime_error("Cannot remove emulator capabilities");
  // Ambient capabilities were introduced after some supported TV kernels.
  if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) && errno != EINVAL)
    throw std::runtime_error("Cannot remove ambient emulator capabilities");
  const rlimit memory{768 * 1024 * 1024, 768 * 1024 * 1024}, none{0, 0}, files{128, 128};
  if (setrlimit(RLIMIT_AS, &memory) || setrlimit(RLIMIT_CORE, &none) || setrlimit(RLIMIT_FSIZE, &none) ||
      setrlimit(RLIMIT_NOFILE, &files) || prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0))
    throw std::runtime_error("Cannot bound emulator resources");
  std::vector<sock_filter> filter;
  auto stmt = [&](uint16_t code, uint32_t value) { filter.push_back(BPF_STMT(code, value)); };
  auto allow = [&](uint32_t call) {
    filter.push_back(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, call, 0, 1));
    stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
  };
  stmt(BPF_LD | BPF_W | BPF_ABS, offsetof(seccomp_data, arch));
#if defined(__x86_64__)
  constexpr auto arch = AUDIT_ARCH_X86_64;
#elif defined(__aarch64__)
  constexpr auto arch = AUDIT_ARCH_AARCH64;
#elif defined(__arm__) && !defined(__ARMEB__)
  constexpr auto arch = AUDIT_ARCH_ARM;
#else
#error Unsupported descriptor-isolated architecture
#endif
  filter.push_back(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, arch, 1, 0));
  stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL);
  stmt(BPF_LD | BPF_W | BPF_ABS, offsetof(seccomp_data, nr));
  // All code and dependencies are resolved. Untrusted inputs cannot create
  // executable mappings or convert writable pages into executable code.
  auto mapping = [&](uint32_t call) {
    filter.push_back(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, call, 0, 4));
    stmt(BPF_LD | BPF_W | BPF_ABS, offsetof(seccomp_data, args[2]));
    filter.push_back(BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, 4 /* PROT_EXEC */, 0, 1));
    stmt(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM);
    stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
  };
#if defined(SYS_mmap) && !defined(__arm__)
  mapping(SYS_mmap);
#endif
#ifdef SYS_mmap2
  mapping(SYS_mmap2);
#endif
  mapping(SYS_mprotect);
  for (const auto call : {SYS_read, SYS_write, SYS_close, SYS_pread64, SYS_lseek, SYS_munmap, SYS_brk,
                         SYS_rt_sigaction, SYS_rt_sigprocmask, SYS_rt_sigreturn, SYS_sigaltstack,
                         SYS_futex, SYS_sched_yield, SYS_exit, SYS_exit_group, SYS_getpid, SYS_gettid,
                         SYS_clock_gettime, SYS_gettimeofday, SYS_nanosleep, SYS_restart_syscall,
                         SYS_sendto, SYS_recvfrom}) allow(call);
#ifdef SYS_poll
  allow(SYS_poll);
#endif
#ifdef SYS_ppoll
  allow(SYS_ppoll);
#endif
#ifdef SYS_fstat
  allow(SYS_fstat);
#endif
#ifdef SYS_fstat64
  allow(SYS_fstat64);
#endif
#ifdef SYS__llseek
  allow(SYS__llseek);
#endif
#ifdef SYS_clock_gettime64
  allow(SYS_clock_gettime64);
#endif
#ifdef SYS_clock_nanosleep
  allow(SYS_clock_nanosleep);
#endif
#ifdef SYS_clock_nanosleep_time64
  allow(SYS_clock_nanosleep_time64);
#endif
#ifdef SYS_ppoll_time64
  allow(SYS_ppoll_time64);
#endif
#ifdef SYS_futex_time64
  allow(SYS_futex_time64);
#endif
#ifdef SYS_getrandom
  allow(SYS_getrandom);
#endif
  // No descriptor signal ownership, leases or locks. Only the private socket,
  // null stdio and selected read-only regular files survive bootstrap.
  auto descriptor = [&](uint32_t call) {
    filter.push_back(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, call, 0, 14));
    stmt(BPF_LD | BPF_W | BPF_ABS, offsetof(seccomp_data, args[1]));
    for (const auto command : {F_GETFD, F_SETFD, F_GETFL, F_SETFL, F_DUPFD, F_DUPFD_CLOEXEC}) allow(command);
    stmt(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM);
  };
  descriptor(SYS_fcntl);
#ifdef SYS_fcntl64
  descriptor(SYS_fcntl64);
#endif
  // Includes open/stat/readlink, sockets, devices, shared IPC, process control,
  // fork/clone, executable loading and every unreviewed future syscall.
  stmt(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | ENOSYS);
  sock_fprog program{static_cast<unsigned short>(filter.size()), filter.data()};
  if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program))
    throw std::runtime_error("This device cannot isolate an emulator worker");
}

inline void PrepareDescriptorCore(const std::string& core, const std::string& rom, const std::string& system) {
  namespace fs = std::filesystem;
  const auto name = fs::path(core).filename().string();
  if (name != "gambatte_libretro.so" && name != "mgba_libretro.so" && name != "fceumm_libretro.so")
    throw std::runtime_error("Only bundled software cores can run on this platform");
  std::array<char, 32768> executable{};
  const auto size = readlink("/proc/self/exe", executable.data(), executable.size());
  if (size <= 0 || size >= static_cast<ssize_t>(executable.size())) throw std::runtime_error("Unknown worker path");
  const auto expected = fs::path(std::string(executable.data(), size)).parent_path() / name;
  if (fs::is_symlink(expected) || fs::canonical(core) != expected || !fs::is_regular_file(expected))
    throw std::runtime_error("Core is outside the application bundle");
  descriptorCorePath = expected.string();
  descriptorCoreModule = dlopen(descriptorCorePath.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!descriptorCoreModule) throw std::runtime_error("Cannot preload bundled core");
  inputs::core = core;
  auto add = [&](const fs::path& path, const std::string& virtualPath) {
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) throw std::runtime_error("Cannot open emulator input");
    try { inputs::Add(virtualPath, fd); } catch (...) { close(fd); throw; }
  };
  if (!rom.empty()) {
    add(rom, "/rom/" + fs::path(rom).filename().string());
    uint64_t total = inputs::files.begin()->second.size;
    size_t visited = 0;
    for (const auto& entry : fs::recursive_directory_iterator(system)) {
      if (++visited > 4096) throw std::runtime_error("Firmware directory budget exceeded");
      if (entry.is_symlink()) throw std::runtime_error("Firmware symlinks are not allowed");
      if (!entry.is_regular_file()) continue;
      const auto path = "/system/" + entry.path().lexically_relative(system).generic_string();
      add(entry.path(), path);
      total += inputs::files.at(path).size;
      if (total > 384ull * 1024 * 1024) throw std::runtime_error("Emulator input budget exceeded");
    }
  }
  inputs::configured = true;
  auto* descriptors = opendir("/proc/self/fd");
  if (!descriptors) throw std::runtime_error("Cannot inspect emulator descriptors");
  std::vector<int> unwanted;
  while (auto* entry = readdir(descriptors)) {
    char* end = nullptr;
    const long value = std::strtol(entry->d_name, &end, 10);
    if (!end || *end || value < 4 || value == dirfd(descriptors)) continue;
    bool selected = false;
    for (const auto& input : inputs::files) selected |= input.second.fd == value;
    if (!selected) unwanted.push_back(static_cast<int>(value));
  }
  closedir(descriptors);
  for (const auto fd : unwanted) close(fd);
  RestrictDescriptorSyscalls();
}
}  // namespace plezy::retro
