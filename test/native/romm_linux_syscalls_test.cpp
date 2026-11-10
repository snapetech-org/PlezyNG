// SPDX-License-Identifier: AGPL-3.0-only
// Exercise the production syscall filter without requiring Landlock support.
#include <fcntl.h>
#include <mqueue.h>
#include <sys/ioctl.h>
#include <sys/ipc.h>
#include <sys/sem.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

// Model an older build sysroot on a newer kernel. Neither omission may turn a
// newer syscall into an allowed operation or prevent libc's thread fallback.
#undef SYS_fchmodat2
#undef SYS_clone3
#include "../../native/games/romm/retro_sandbox.h"

namespace {
bool Denied(long result, const char* name, bool newer = false) {
  if (result == -1 && (errno == EPERM || (newer && errno == ENOSYS))) return true;
  std::fprintf(stderr, "%s was not blocked: result=%ld errno=%d\n", name, result, errno);
  return false;
}

bool Exercise(const char* file, int semaphore, mqd_t queue, const char* queueName) {
  const int input = open(file, O_RDONLY | O_CLOEXEC);
  int sockets[2]{};
  if (input < 0 || socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets)) return false;
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) return false;
  plezy::retro::RestrictLinuxSyscalls();
  bool ok = true;
  __user_cap_header_struct capabilityHeader{_LINUX_CAPABILITY_VERSION_3, 0};
  __user_cap_data_struct capabilities[2]{};
  ok &= syscall(SYS_capget, &capabilityHeader, capabilities) == 0;
  for (const auto& capability : capabilities)
    ok &= !capability.effective && !capability.permitted && !capability.inheritable;
  ok &= Denied(syscall(SYS_capset, &capabilityHeader, capabilities), "capset");
  // Set only an owner in these probes; never enable asynchronous notifications.
  // A failing old filter therefore cannot send a signal to the test parent.
  int parent = getppid();
  ok &= Denied(fcntl(sockets[0], F_SETOWN, parent), "fcntl F_SETOWN");
  f_owner_ex owner{F_OWNER_PID, parent};
  ok &= Denied(fcntl(sockets[0], F_SETOWN_EX, &owner), "fcntl F_SETOWN_EX");
  ok &= Denied(ioctl(sockets[0], FIOSETOWN, &parent), "ioctl FIOSETOWN");
  ok &= Denied(fcntl(input, F_SETLEASE, F_RDLCK), "fcntl F_SETLEASE");
  ok &= Denied(syscall(SYS_flock, input, LOCK_EX | LOCK_NB), "flock");
  ok &= Denied(syscall(SYS_inotify_add_watch, -1, file, 0), "inotify_add_watch");
  const int flags = fcntl(sockets[0], F_GETFL);
  ok &= flags >= 0 && fcntl(sockets[0], F_SETFL, flags | O_NONBLOCK) == 0;
  close(input);
  close(sockets[0]);
  close(sockets[1]);
  sembuf decrement{0, -1, IPC_NOWAIT};
  timespec immediate{};
  ok &= Denied(semop(semaphore, &decrement, 1), "semop");
  ok &= Denied(semtimedop(semaphore, &decrement, 1, &immediate), "semtimedop");
  ok &= Denied(mq_open(queueName, O_RDONLY | O_NONBLOCK), "mq_open");
  // glibc translates mq_unlink's EPERM into EACCES; inspect the kernel result.
  ok &= Denied(syscall(SYS_mq_unlink, queueName + 1), "mq_unlink");
  char message[64]{};
  ok &= Denied(mq_receive(queue, message, sizeof(message), nullptr), "mq_receive");
  ok &= Denied(mq_send(queue, "changed", 7, 0), "mq_send");
  ok &= Denied(syscall(SYS_ioprio_set, 1, -1, 0), "ioprio_set");
  ok &= Denied(syscall(SYS_sched_setattr, -1, nullptr, 0), "sched_setattr");

  // Since 424, x86_64 and arm64 use the same syscall numbering. Use the actual
  // ABI numbers, independent of build headers. The parent verifies its file's
  // mode afterwards; no path outside this test's private fixture is touched.
  ok &= Denied(syscall(452, AT_FDCWD, file, 0777, 0), "fchmodat2", true);
  for (const auto number : {463, 466, 469}) {
    errno = 0;
    const auto result = syscall(number, AT_FDCWD, file, 0, nullptr, nullptr, 0);
    if (result != -1 || errno != ENOSYS) {
      std::fprintf(stderr, "Unreviewed metadata syscall %d was not rejected\n", number);
      ok = false;
    }
  }
  rlimit limits{};
  ok &= getrlimit(RLIMIT_NOFILE, &limits) == 0;
  ok &= Denied(syscall(SYS_prlimit64, getppid(), RLIMIT_NOFILE, nullptr, &limits), "parent prlimit64");
  std::atomic<bool> threadDenied{false};
  std::thread thread([&] { threadDenied = Denied(semop(semaphore, &decrement, 1), "thread semop"); });
  thread.join();
  return ok && threadDenied;
}
}  // namespace

int main() {
  char file[] = "/tmp/pleazyng-syscalls-XXXXXX";
  const int fd = mkstemp(file);
  if (fd < 0) return 1;
  close(fd);
  const auto name = std::string("/pleazyng-syscalls-") + std::filesystem::path(file).filename().string();
  const int semaphore = semget(IPC_PRIVATE, 1, IPC_CREAT | 0600);
  mq_attr attributes{};
  attributes.mq_maxmsg = 4;
  attributes.mq_msgsize = 64;
  const auto queue = mq_open(name.c_str(), O_CREAT | O_EXCL | O_RDWR | O_NONBLOCK, 0600, &attributes);
  bool ok = semaphore >= 0 && queue != static_cast<mqd_t>(-1);
  if (ok) ok = semctl(semaphore, 0, SETVAL, 1) == 0 && mq_send(queue, "original", 8, 0) == 0;
  if (ok) {
    const auto child = fork();
    if (child == 0) {
      try {
        std::_Exit(Exercise(file, semaphore, queue, name.c_str()) ? 0 : 1);
      } catch (const std::exception& error) {
        std::fprintf(stderr, "Filter regression: %s\n", error.what());
        std::_Exit(1);
      }
    }
    int status = 0;
    ok = child > 0 && waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
    struct stat metadata {};
    char message[64]{};
    ok &= stat(file, &metadata) == 0 && (metadata.st_mode & 0777) == 0600;
    ok &= semctl(semaphore, 0, GETVAL) == 1;
    ok &= mq_receive(queue, message, sizeof(message), nullptr) == 8 && std::memcmp(message, "original", 8) == 0;
  }
  if (semaphore >= 0) semctl(semaphore, 0, IPC_RMID);
  if (queue != static_cast<mqd_t>(-1)) {
    mq_close(queue);
    mq_unlink(name.c_str());
  }
  unlink(file);
  if (!ok) {
    std::fprintf(stderr, "Linux syscall containment regression failed\n");
    return 1;
  }
  std::puts(
      "Linux syscall containment passed: capabilities, shared IPC, metadata, parent controls and thread fallback");
  return 0;
}
