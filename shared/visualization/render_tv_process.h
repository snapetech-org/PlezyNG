// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#if !defined(__linux__) || defined(__ANDROID__)
#error This transport is for Linux TV application packages.
#endif
#include "render_socket.h"
#include <array>
#include <csignal>
#include <mutex>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sys/wait.h>
extern char** environ;

namespace plezy::visualization {
namespace tv_process_detail {
struct Fd {
  int value = -1;
  explicit Fd(int fd) : value(fd) {}
  ~Fd() { if (value >= 0) close(value); }
  Fd(const Fd&) = delete;
};
struct Control {
  std::mutex mutex;
  pid_t pid = 0;
  std::shared_ptr<RenderSocketControl> socket;
  void Abort() const noexcept { if (socket) socket->Abort(); }
  bool Reaped() {
    std::lock_guard<std::mutex> lock(mutex);
    if (!pid) return true;
    int status = 0;
    const auto result = waitpid(pid, &status, WNOHANG);
    if (result == pid || (result < 0 && errno == ECHILD)) { pid = 0; return true; }
    return false;
  }
  ~Control() { Abort(); }
};
struct Retired {
  std::mutex mutex;
  std::array<std::shared_ptr<Control>, 4> children;
};
inline Retired& Pool() { static auto* pool = new Retired; return *pool; }
inline void Admit() {
  auto& pool = Pool(); std::lock_guard<std::mutex> lock(pool.mutex);
  bool pending = false;
  for (auto& child : pool.children) {
    if (child && child->Reaped()) child.reset();
    if (child) pending = true;
  }
  if (pending) throw std::runtime_error("A TV visualization helper is still terminating; wait before retrying.");
}
inline void Retire(const std::shared_ptr<Control>& control) noexcept {
  control->Abort();
  if (control->Reaped()) return;
  auto& pool = Pool(); std::lock_guard<std::mutex> lock(pool.mutex);
  for (auto& child : pool.children) {
    if (!child || child->Reaped()) { child = control; return; }
  }
}
inline std::filesystem::path HelperPath() {
  Dl_info module{};
  if (!dladdr(reinterpret_cast<const void*>(&HelperPath), &module) || !module.dli_fname)
    throw std::runtime_error("Could not locate the TV visualization package.");
  const auto directory = std::filesystem::canonical(module.dli_fname).parent_path();
  // webOS puts plugins in lib/. Tizen statically links its plugin into bin/.
  for (const auto& folder : {directory, directory.parent_path() / "lib"}) {
    const auto helper = folder / "plezy_visualizer_helper";
    if (!std::filesystem::is_symlink(helper) && std::filesystem::is_regular_file(helper) && access(helper.c_str(), X_OK) == 0)
      return helper;
  }
  throw std::runtime_error("The isolated TV visualization helper is missing or not executable.");
}
inline RenderConnection Connect(const std::filesystem::path& path) {
  Admit();
  auto control = std::make_shared<Control>();
  try {
    rlimit descriptors{};
    if (getrlimit(RLIMIT_NOFILE, &descriptors) != 0 || descriptors.rlim_max > INT32_MAX)
      throw std::runtime_error("Could not bound inherited TV descriptors.");
    const int maximum = static_cast<int>(descriptors.rlim_max);
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair) != 0)
      throw std::runtime_error("Could not create the TV visualization socket.");
    Fd parent(pair[0]), child(pair[1]);
    control->socket = std::make_shared<RenderSocketControl>(parent.value);
    auto pipe = std::unique_ptr<RenderPipe>(new RenderPipe(control->socket->Duplicate()));
    // Allocate all arguments before fork. The child uses only system calls and
    // execve; it never enters a copied C++/graphics/player mutex or allocator.
    const auto executable = path.string();
    char* arguments[] = {const_cast<char*>(executable.c_str()), const_cast<char*>("--plezy-render-pipe"), const_cast<char*>("3"), nullptr};
    char** environment = environ;
    const pid_t owner = getpid();
    const pid_t pid = fork();
    if (pid < 0) throw std::runtime_error("The TV denied visualization helper startup.");
    if (pid == 0) {
      if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != owner || dup2(child.value, 3) < 0 || fcntl(3, F_SETFD, 0) < 0)
        _exit(126);
      // close_range is optional on older firmware. The fallback is bounded by
      // the inherited descriptor limit and requires no libc allocation.
#if defined(SYS_close_range)
      if (syscall(SYS_close_range, 4u, ~0u, 0u) != 0)
#endif
        for (int fd = 4; fd < maximum; ++fd) close(fd);
      execve(executable.c_str(), arguments, environment);
      _exit(127);
    }
    control->pid = pid;
    return RenderConnection(std::move(pipe), [control] { control->Abort(); }, [control] { Retire(control); });
  } catch (...) { Retire(control); throw; }
}
}  // namespace tv_process_detail

// Older TV kernels need not expose pidfds. Cancellation shuts down a retained
// socket; the helper exits itself from an independent monitor. No PID-based
// signal is sent from the player, so an unrelated SIGCHLD reaper cannot cause
// signaling of a reused PID. An unreaped child keeps admission closed.
class TvRenderBackend final : public RemoteRenderBackend {
 public:
  static std::string DependencyError() {
    try { tv_process_detail::HelperPath(); return {}; }
    catch (const std::exception& error) { return error.what(); }
  }
  explicit TvRenderBackend(const std::filesystem::path& path = tv_process_detail::HelperPath())
      : RemoteRenderBackend(tv_process_detail::Connect(path)) {}
};
}  // namespace plezy::visualization
