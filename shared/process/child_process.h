// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <array>
#include <atomic>
#include <filesystem>
#include <functional>
#include <mutex>
#include <string>

#include "byte_pipe.h"
#if defined(_WIN32)
#include <bcrypt.h>
#else
#include <spawn.h>
#include <sys/wait.h>

#include <csignal>
#if defined(__APPLE__)
#include <crt_externs.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#else
#include <sys/syscall.h>
extern char** environ;
#endif
#endif

namespace plezy::process {
namespace child_detail {
#if defined(_WIN32)
class OwnedHandle {
  HANDLE value_ = INVALID_HANDLE_VALUE;

 public:
  explicit OwnedHandle(HANDLE value = INVALID_HANDLE_VALUE) : value_(value) {}
  ~OwnedHandle() {
    if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_);
  }
  HANDLE Get() const { return value_; }
  HANDLE Release() {
    const auto value = value_;
    value_ = INVALID_HANDLE_VALUE;
    return value;
  }
  OwnedHandle(const OwnedHandle&) = delete;
};
#else
class OwnedFd {
  int value_ = -1;

 public:
  explicit OwnedFd(int value = -1) : value_(value) {}
  ~OwnedFd() {
    if (value_ >= 0) close(value_);
  }
  int Get() const { return value_; }
  int Release() {
    const auto value = value_;
    value_ = -1;
    return value;
  }
  OwnedFd(const OwnedFd&) = delete;
};
#endif
// Only OS process handles live in this object. Its cancellation callback can
// outlive the render thread without retaining any graphics or player object.
class Control {
  std::mutex mutex_;
  bool stopped_ = false;

 public:
#if defined(_WIN32)
  HANDLE process = nullptr, job = nullptr;
#else
  pid_t pid = 0;
#if defined(__linux__)
  int pidfd = -1;
#endif
#endif
  std::shared_ptr<void> resources;
  ~Control() {
    Abort();
#if defined(_WIN32)
    if (process) CloseHandle(process);
    if (job) CloseHandle(job);
#elif defined(__linux__)
    if (pidfd >= 0) close(pidfd);
#endif
  }
  bool Reaped() {
    std::lock_guard<std::mutex> lock(mutex_);
#if defined(_WIN32)
    return !process || WaitForSingleObject(process, 0) == WAIT_OBJECT_0;
#else
    if (!pid) return true;
    int status = 0;
    const auto result = waitpid(pid, &status, WNOHANG);
    if (result == pid || (result < 0 && errno == ECHILD)) {
      pid = 0;
      return true;
    }
    return false;
#endif
  }
#if defined(__APPLE__)
  void CheckMemory() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!pid || stopped_) return;
    proc_taskinfo usage{};
    const auto size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &usage, sizeof(usage));
    if (size != sizeof(usage) || usage.pti_resident_size > 768ull * 1024 * 1024) {
      kill(pid, SIGKILL);
      stopped_ = true;
    }
  }
#endif
  void Abort() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_) return;
    stopped_ = true;
#if defined(_WIN32)
    if (job)
      TerminateJobObject(job, 1);
    else if (process)
      TerminateProcess(process, 1);
#else
    if (!pid) return;
    int status = 0;
    const auto result = waitpid(pid, &status, WNOHANG);
    if (result == pid || (result < 0 && errno == ECHILD)) {
      pid = 0;
      return;
    }
#if defined(__linux__)
    if (pidfd >= 0) {
      syscall(SYS_pidfd_send_signal, pidfd, SIGKILL, nullptr, 0);
      return;
    }
#endif
    kill(pid, SIGKILL);
#endif
  }
};
struct RetiredProcesses {
  std::mutex mutex;
  std::array<std::shared_ptr<Control>, 16> children;
};
inline RetiredProcesses& Retired() {
  static auto* pool = new RetiredProcesses;
  return *pool;
}
inline void Admit() {
  auto& pool = Retired();
  std::lock_guard<std::mutex> lock(pool.mutex);
  bool pending = false;
  for (auto& child : pool.children) {
    if (child && child->Reaped()) child.reset();
    if (child) pending = true;
  }
  if (pending) throw std::runtime_error("A worker helper is still terminating; wait before retrying.");
}
inline void Retire(const std::shared_ptr<Control>& control) noexcept {
  control->Abort();
  if (!control->Reaped()) {
    auto& pool = Retired();
    std::lock_guard<std::mutex> lock(pool.mutex);
    for (auto& child : pool.children) {
      if (!child || child->Reaped()) {
        child = control;
        return;
      }
    }
  }
}

inline std::filesystem::path ExecutablePath() {
#if defined(_WIN32)
  std::vector<wchar_t> buffer(32768);
  const auto size = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  if (!size || size >= buffer.size()) throw std::runtime_error("Could not locate the worker helper.");
  const auto executable = std::filesystem::path(std::wstring(buffer.data(), size));
#elif defined(__APPLE__)
  uint32_t size = 0;
  _NSGetExecutablePath(nullptr, &size);
  if (!size || size > 32768) throw std::runtime_error("Could not locate the worker helper.");
  std::vector<char> buffer(size);
  if (_NSGetExecutablePath(buffer.data(), &size) != 0) throw std::runtime_error("Could not locate the worker helper.");
  const auto executable = std::filesystem::canonical(buffer.data());
#else
  std::vector<char> buffer(32768);
  const auto size = readlink("/proc/self/exe", buffer.data(), buffer.size());
  if (size <= 0 || size >= static_cast<ssize_t>(buffer.size()))
    throw std::runtime_error("Could not locate the worker helper.");
  const auto executable = std::filesystem::path(std::string(buffer.data(), static_cast<size_t>(size)));
#endif
  return executable;
}
inline std::unique_ptr<BytePipe> Spawn(
    const std::filesystem::path& path, const std::shared_ptr<Control>& control
#if defined(_WIN32)
    ,
    PSID appContainer = nullptr
#endif
) {
  Admit();
#if defined(_WIN32)
  uint8_t random[16];
  if (BCryptGenRandom(nullptr, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0)
    throw std::runtime_error("Could not name the worker IPC channel.");
  std::wstring pipe_name = L"\\\\.\\pipe\\PlezyRomm-";
  for (const auto value : random) {
    pipe_name += L"0123456789abcdef"[value >> 4];
    pipe_name += L"0123456789abcdef"[value & 15];
  }
  OwnedHandle server(CreateNamedPipeW(
      pipe_name.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, nullptr));
  if (server.Get() == INVALID_HANDLE_VALUE) throw std::runtime_error("Could not open worker IPC.");
  SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
  OwnedHandle child(CreateFileW(
      pipe_name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, &security, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr));
  if (child.Get() == INVALID_HANDLE_VALUE) throw std::runtime_error("Could not connect worker IPC.");
  auto pipe = std::make_unique<BytePipe>(server.Release());
  pipe->Connect(BytePipe::Clock::now() + std::chrono::seconds(2));

  SIZE_T size = 0;
  InitializeProcThreadAttributeList(nullptr, appContainer ? 2 : 1, 0, &size);
  if (!size || size > 65536) throw std::runtime_error("Invalid helper process attributes.");
  std::vector<uint8_t> storage(size);
  auto* attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
  if (!InitializeProcThreadAttributeList(attributes, appContainer ? 2 : 1, 0, &size))
    throw std::runtime_error("Could not initialize helper process attributes.");
  struct DeleteAttributes {
    LPPROC_THREAD_ATTRIBUTE_LIST value;
    ~DeleteAttributes() { DeleteProcThreadAttributeList(value); }
  } cleanup{attributes};
  HANDLE inherited = child.Get();
  if (!UpdateProcThreadAttribute(
          attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &inherited, sizeof(inherited), nullptr, nullptr))
    throw std::runtime_error("Could not restrict worker handle inheritance.");
  SECURITY_CAPABILITIES capabilities{};
  capabilities.AppContainerSid = appContainer;
  if (appContainer && !UpdateProcThreadAttribute(
                          attributes, 0, PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &capabilities,
                          sizeof(capabilities), nullptr, nullptr))
    throw std::runtime_error("Could not restrict worker capabilities");
  control->job = CreateJobObjectW(nullptr, nullptr);
  if (!control->job) throw std::runtime_error("Could not isolate the worker process.");
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags =
      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_ACTIVE_PROCESS | JOB_OBJECT_LIMIT_PROCESS_MEMORY;
  limits.ProcessMemoryLimit = 768 * 1024 * 1024;
  limits.BasicLimitInformation.ActiveProcessLimit = 1;
  if (!SetInformationJobObject(control->job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)))
    throw std::runtime_error("Could not configure the worker job.");
  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(startup);
  startup.lpAttributeList = attributes;
  PROCESS_INFORMATION process{};
  auto command =
      L"\"" + path.wstring() + L"\" --plezy-retro-pipe " + std::to_wstring(reinterpret_cast<uintptr_t>(inherited));
  wchar_t windows[32768];
  const auto windowsSize = GetWindowsDirectoryW(windows, 32768);
  if (!windowsSize || windowsSize >= 32768) throw std::runtime_error("Could not locate Windows runtime");
  std::wstring environment = L"SystemRoot=" + std::wstring(windows) + L'\0' + L"WINDIR=" + windows + L'\0' + L'\0';
  if (!CreateProcessW(
          path.c_str(), command.data(), nullptr, nullptr, TRUE,
          EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
          environment.data(), path.parent_path().c_str(), &startup.StartupInfo, &process))
    throw std::runtime_error(
        "Could not launch the worker helper (Windows error " + std::to_string(GetLastError()) + ").");
  control->process = process.hProcess;
  OwnedHandle thread(process.hThread);
  if (!AssignProcessToJobObject(control->job, control->process)) {
    TerminateProcess(control->process, 1);
    throw std::runtime_error("Could not attach the worker helper to its job.");
  }
  if (ResumeThread(thread.Get()) == DWORD(-1)) throw std::runtime_error("Could not start the worker helper.");
  return pipe;
#else
  int descriptors[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) != 0) throw std::runtime_error("Could not create worker IPC.");
  OwnedFd parent(descriptors[0]), original_child(descriptors[1]);
  if (fcntl(parent.Get(), F_SETFD, FD_CLOEXEC) < 0 || fcntl(original_child.Get(), F_SETFD, FD_CLOEXEC) < 0)
    throw std::runtime_error("Could not restrict worker descriptors.");
  OwnedFd child(fcntl(original_child.Get(), F_DUPFD_CLOEXEC, 10));
  if (child.Get() < 0) throw std::runtime_error("Could not reserve worker IPC descriptor.");
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attributes;
  if (posix_spawn_file_actions_init(&actions) != 0)
    throw std::runtime_error("Could not initialize helper spawn actions.");
  struct DestroyActions {
    posix_spawn_file_actions_t* value;
    ~DestroyActions() { posix_spawn_file_actions_destroy(value); }
  } close_actions{&actions};
  if (posix_spawnattr_init(&attributes) != 0) throw std::runtime_error("Could not initialize helper spawn attributes.");
  struct DestroyAttributes {
    posix_spawnattr_t* value;
    ~DestroyAttributes() { posix_spawnattr_destroy(value); }
  } close_attributes{&attributes};
  auto check = [](int result) {
    if (result) throw std::runtime_error("Could not configure worker process isolation.");
  };
  check(posix_spawn_file_actions_addclose(&actions, parent.Get()));
  for (int fd = 0; fd < 3; ++fd)
    check(posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0));
  check(posix_spawn_file_actions_adddup2(&actions, child.Get(), 3));
#if defined(__APPLE__)
  check(posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT));
#else
  // Linux Flutter's supported desktop baseline has glibc >= 2.34. Closing the
  // entire tail prevents unrelated audio/network descriptors escaping a race.
  check(posix_spawn_file_actions_addclosefrom_np(&actions, 4));
#endif
  const std::string executable = path.string();
  char mode[] = "--plezy-retro-pipe", descriptor[] = "3";
  char* args[] = {const_cast<char*>(executable.c_str()), mode, descriptor, nullptr};
  char locale[] = "LANG=C", timezone[] = "TZ=UTC";
  char* environment[] = {locale, timezone, nullptr};
  check(posix_spawn(&control->pid, executable.c_str(), &actions, &attributes, args, environment));
#if defined(__linux__)
  control->pidfd = static_cast<int>(syscall(SYS_pidfd_open, control->pid, 0));
  if (control->pidfd < 0) throw std::runtime_error("This kernel lacks worker process handles.");
#endif
#if defined(__APPLE__)
  std::thread([control] {
    while (!control->Reaped()) {
      control->CheckMemory();
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
  }).detach();
#endif
  return std::make_unique<BytePipe>(parent.Release());
#endif
}
}  // namespace child_detail

}  // namespace plezy::process
