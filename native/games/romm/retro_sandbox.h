// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <filesystem>
#include <string>
#include <vector>
#include <stdexcept>
#if defined(__linux__)
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/landlock.h>
#include <linux/seccomp.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstddef>
#include <cerrno>
#elif defined(__APPLE__)
#include <sandbox.h>
#elif defined(_WIN32)
#include <windows.h>
#endif

namespace plezy::retro {
// Apply before dlopen: even a core's static constructors run inside this policy.
// No fallback to an unrestricted core if the OS cannot enforce the boundary.
inline void RestrictCore(const std::string& core, const std::string& rom,
                         const std::string& system, const std::string& saves) {
#if defined(__linux__)
  const int abi = static_cast<int>(syscall(SYS_landlock_create_ruleset, nullptr, 0, LANDLOCK_CREATE_RULESET_VERSION));
  if (abi < 3) throw std::runtime_error("Emulator isolation requires Landlock ABI 3 or later");
  // ABI 3 includes truncate; later rights are handled where supported.
  constexpr uint64_t read = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR;
  uint64_t handled = (uint64_t(1) << 15) - 1;
  if (abi >= 5) handled |= uint64_t(1) << 15;  // IOCTL_DEV
  landlock_ruleset_attr attr{}; attr.handled_access_fs = handled;
  const int rules = static_cast<int>(syscall(SYS_landlock_create_ruleset, &attr, sizeof(attr), 0));
  if (rules < 0) throw std::runtime_error("Could not create emulator filesystem policy");
  try {
    auto allow = [&](const std::filesystem::path& path, uint64_t rights, bool required) {
      if (path.empty()) return;
      const int fd = open(path.c_str(), O_PATH | O_CLOEXEC);
      if (fd < 0) { if (!required && errno == ENOENT) return; throw std::runtime_error("Missing emulator sandbox resource"); }
      if (!std::filesystem::is_directory(path)) rights &= ~(LANDLOCK_ACCESS_FS_READ_DIR | LANDLOCK_ACCESS_FS_MAKE_DIR |
        LANDLOCK_ACCESS_FS_MAKE_REG | LANDLOCK_ACCESS_FS_REMOVE_DIR | LANDLOCK_ACCESS_FS_REMOVE_FILE |
        LANDLOCK_ACCESS_FS_REFER);
      landlock_path_beneath_attr rule{}; rule.parent_fd = fd; rule.allowed_access = rights;
      const int result = static_cast<int>(syscall(SYS_landlock_add_rule, rules, LANDLOCK_RULE_PATH_BENEATH, &rule, 0));
      close(fd); if (result) throw std::runtime_error("Could not restrict emulator files");
    };
    // Dynamic linker inputs are read-only. No home directory, app configuration,
    // credential files, /proc, devices, or inherited network endpoints are granted.
    for (const auto* path : {"/usr/lib", "/usr/lib64", "/lib", "/lib64", "/etc/ld.so.cache"})
      allow(path, read, false);
    allow(core, read, true); allow(rom, read, true); allow(system, read, true);
    // SRAM, RTC and states leave through bounded IPC. A core never needs to
    // write the app's files directly, even inside the selected game directory.
    allow(saves, read, true);
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) || syscall(SYS_landlock_restrict_self, rules, 0))
      throw std::runtime_error("Could not enter emulator filesystem sandbox");
    close(rules);
  } catch (...) { close(rules); throw; }
  // Landlock does not cover every metadata syscall. Deny mutations outside the
  // save-file API, networking, process introspection, and new executable code.
  std::vector<sock_filter> filter;
  auto stmt = [&](uint16_t code, uint32_t value) { filter.push_back(BPF_STMT(code, value)); };
  auto deny = [&](uint32_t call, uint32_t error = EPERM) {
    filter.push_back(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, call, 0, 1));
    stmt(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | error);
  };
  stmt(BPF_LD | BPF_W | BPF_ABS, offsetof(seccomp_data, arch));
#if defined(__x86_64__)
  constexpr uint32_t arch = AUDIT_ARCH_X86_64;
#elif defined(__aarch64__)
  constexpr uint32_t arch = AUDIT_ARCH_AARCH64;
#else
#error Unsupported isolated emulator Linux architecture
#endif
  filter.push_back(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, arch, 1, 0));
  stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
  stmt(BPF_LD | BPF_W | BPF_ABS, offsetof(seccomp_data, nr));
#if defined(__x86_64__)
  // The x32 ABI shares AUDIT_ARCH_X86_64 but uses different syscall numbers.
  filter.push_back(BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, 0x40000000, 0, 1));
  stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
#endif
  for (const auto call : {SYS_socket, SYS_socketpair, SYS_connect, SYS_bind, SYS_listen, SYS_accept,
       SYS_accept4, SYS_execve, SYS_execveat, SYS_ptrace, SYS_process_vm_readv, SYS_process_vm_writev,
       SYS_mount, SYS_umount2, SYS_unshare, SYS_setns, SYS_bpf, SYS_perf_event_open,
       SYS_open_by_handle_at, SYS_keyctl, SYS_add_key, SYS_request_key, SYS_userfaultfd,
       SYS_fchmod, SYS_fchmodat, SYS_fchown, SYS_fchownat,
       SYS_setxattr, SYS_lsetxattr, SYS_fsetxattr, SYS_removexattr, SYS_lremovexattr,
       SYS_fremovexattr, SYS_utimensat, SYS_kill, SYS_tkill, SYS_tgkill,
       SYS_shmget, SYS_shmat, SYS_shmctl, SYS_semget, SYS_semctl, SYS_msgget, SYS_msgsnd,
       SYS_msgrcv, SYS_msgctl, SYS_prctl, SYS_setpriority, SYS_sched_setaffinity,
       SYS_sched_setscheduler, SYS_sched_setparam}) deny(call);
#ifdef SYS_fsopen
  deny(SYS_fsopen); deny(SYS_fsmount); deny(SYS_move_mount); deny(SYS_open_tree);
#endif
#ifdef SYS_mount_setattr
  deny(SYS_mount_setattr);
#endif
#ifdef SYS_pidfd_open
  deny(SYS_pidfd_open); deny(SYS_pidfd_send_signal);
#endif
#ifdef SYS_pidfd_getfd
  deny(SYS_pidfd_getfd);
#endif
#ifdef SYS_chmod
  deny(SYS_chmod);
#endif
#ifdef SYS_chown
  deny(SYS_chown);
#endif
#ifdef SYS_fork
  deny(SYS_fork);
#endif
#ifdef SYS_vfork
  deny(SYS_vfork);
#endif
#ifdef SYS_io_uring_setup
  deny(SYS_io_uring_setup);
#endif
#ifdef SYS_clone3
  deny(SYS_clone3, ENOSYS);  // Let libc use the inspectable legacy clone ABI.
#endif
  // Software cores may create threads, but never another process.
  filter.push_back(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_clone, 0, 3));
  stmt(BPF_LD | BPF_W | BPF_ABS, offsetof(seccomp_data, args[0]));
  filter.push_back(BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, 0x10000 /* CLONE_THREAD */, 1, 0));
  stmt(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM);
  stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
  sock_fprog program{static_cast<unsigned short>(filter.size()), filter.data()};
  if (syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC, &program))
    throw std::runtime_error("Could not enter emulator syscall sandbox");
  rlimit memory{768 * 1024 * 1024, 768 * 1024 * 1024};
  rlimit dumps{0, 0};
  if (setrlimit(RLIMIT_AS, &memory) || setrlimit(RLIMIT_CORE, &dumps))
    throw std::runtime_error("Could not bound emulator resources");
#elif defined(__APPLE__)
  auto quote = [](const std::string& path) {
    std::string out = "\"";
    for (const char c : path) { if (c == '\\' || c == '"') out += '\\'; out += c; }
    return out + "\"";
  };
  std::string policy = "(version 1)(deny default)(allow sysctl-read)(allow process-info* (target self))"
    "(allow file-read* (subpath \"/System/Library\") (subpath \"/usr/lib\")";
  for (const auto& path : {core, rom}) if (!path.empty()) policy += "(literal " + quote(path) + ")";
  if (!system.empty()) policy += "(subpath " + quote(system) + ")";
  if (!saves.empty()) policy += "(subpath " + quote(saves) + ")";
  policy += ")";
  char* error = nullptr;
  if (sandbox_init(policy.c_str(), 0, &error)) {
    if (error) sandbox_free_error(error);
    throw std::runtime_error("Could not enter emulator filesystem sandbox");
  }
#elif defined(_WIN32)
  // Refuse even a valid protocol if packaging accidentally launches us outside
  // the AppContainer configured by the parent.
  HANDLE token = nullptr; DWORD isolated = 0, returned = 0;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
    throw std::runtime_error("Missing emulator AppContainer token");
  const bool valid = GetTokenInformation(token, TokenIsAppContainer, &isolated, sizeof(isolated), &returned) != 0;
  CloseHandle(token);
  if (!valid || !isolated) throw std::runtime_error("The emulator worker is not isolated");
#else
  throw std::runtime_error("No emulator sandbox is available on this platform");
#endif
}
}  // namespace plezy::retro
