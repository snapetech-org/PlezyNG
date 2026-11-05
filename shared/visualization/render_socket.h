// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include "render_remote.h"
#if defined(_WIN32)
#error Socket-bound rendering requires a POSIX platform.
#endif

namespace plezy::visualization {
// A duplicate keeps the socket identity stable while cancellation races an IPC
// operation. shutdown wakes both endpoints; the helper's independent monitor
// exits its process even when its render thread is inside a driver call.
class RenderSocketControl {
  int socket_ = -1;
 public:
  explicit RenderSocketControl(int channel) : socket_(fcntl(channel, F_DUPFD_CLOEXEC, 3)) {
    if (socket_ < 0) throw std::runtime_error("Could not retain visualization socket.");
  }
  ~RenderSocketControl() { close(socket_); }
  RenderSocketControl(const RenderSocketControl&) = delete;
  void Abort() const noexcept { shutdown(socket_, SHUT_RDWR); }
  int Duplicate() const {
    const int descriptor = fcntl(socket_, F_DUPFD_CLOEXEC, 3);
    if (descriptor < 0) throw std::runtime_error("Could not duplicate visualization socket.");
    return descriptor;
  }
};
inline RenderConnection ConnectRenderSocket(int channel) {
  auto control = std::make_shared<RenderSocketControl>(channel);
  auto pipe = std::unique_ptr<RenderPipe>(new RenderPipe(control->Duplicate()));
  return RenderConnection(std::move(pipe), [control] { control->Abort(); }, [control] { control->Abort(); });
}
}  // namespace plezy::visualization
