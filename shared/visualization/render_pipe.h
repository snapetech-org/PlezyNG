// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include "render_protocol.h"
#include <algorithm>
#include <chrono>
#include <memory>
#include <thread>
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <cerrno>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace plezy::visualization {
// Dedicated inherited IPC channel; stdout/stderr are never protocol streams.
// No graphics or audio callback runs in a pipe operation.
class RenderPipe {
 public:
  using Clock = std::chrono::steady_clock;
  using Deadline = Clock::time_point;
#if defined(_WIN32)
  using Handle = HANDLE;
  static Handle Invalid() { return INVALID_HANDLE_VALUE; }
#else
  using Handle = int;
  static Handle Invalid() { return -1; }
#endif
 private:
  Handle handle_ = Invalid();
#if defined(_WIN32)
  struct Pending {
    OVERLAPPED operation{};
    render_protocol::Bytes bytes;
    explicit Pending(size_t size) : bytes(size) {
      operation.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
      if (!operation.hEvent) throw std::runtime_error("Could not create a visualization IPC event.");
    }
    ~Pending() { CloseHandle(operation.hEvent); }
  };
  void Await(std::unique_ptr<Pending>& pending, Deadline deadline) {
    const auto wait = Remaining(deadline);
    const DWORD result = WaitForSingleObject(pending->operation.hEvent, wait < 0 ? INFINITE : DWORD(wait));
    if (result != WAIT_OBJECT_0) {
      CancelIoEx(handle_, &pending->operation);
      // OVERLAPPED and its buffer must survive cancellation. If the OS has
      // not completed it, retire both without blocking the player worker.
      if (WaitForSingleObject(pending->operation.hEvent, 100) != WAIT_OBJECT_0) {
        HANDLE retained = handle_;
        handle_ = Invalid();
        auto* retired = pending.release();
        try {
          std::thread([retired, retained] {
            WaitForSingleObject(retired->operation.hEvent, INFINITE);
            CloseHandle(retained);
            delete retired;
          }).detach();
        } catch (...) {
          // Under thread-allocation failure deliberately retain this one
          // pending buffer rather than let the OS write into freed memory.
          CloseHandle(retained);
        }
      }
      throw std::runtime_error("Visualization helper exceeded its response deadline.");
    }
  }
  render_protocol::Bytes Transfer(const uint8_t* input, size_t size, Deadline deadline) {
    auto pending = std::make_unique<Pending>(size);
    if (input) std::copy(input, input + size, pending->bytes.begin());
    size_t offset = 0;
    while (offset < size) {
      if (deadline != Deadline::max() && Clock::now() >= deadline)
        throw std::runtime_error("Visualization helper exceeded its response deadline.");
      ResetEvent(pending->operation.hEvent);
      DWORD transferred = 0;
      const auto count = static_cast<DWORD>(size - offset);
      const BOOL complete = input
          ? WriteFile(handle_, pending->bytes.data() + offset, count, &transferred, &pending->operation)
          : ReadFile(handle_, pending->bytes.data() + offset, count, &transferred, &pending->operation);
      if (!complete) {
        if (GetLastError() != ERROR_IO_PENDING) throw std::runtime_error("Visualization helper disconnected.");
        Await(pending, deadline);
        if (!GetOverlappedResult(handle_, &pending->operation, &transferred, FALSE))
          throw std::runtime_error("Visualization helper disconnected.");
      }
      if (!transferred || transferred > size - offset) throw std::runtime_error("Invalid visualization IPC transfer.");
      offset += transferred;
    }
    return std::move(pending->bytes);
  }
#else
  void Transfer(uint8_t* data, size_t size, bool writing, Deadline deadline) {
    while (size) {
      if (deadline != Deadline::max() && Clock::now() >= deadline)
        throw std::runtime_error("Visualization helper exceeded its response deadline.");
      pollfd descriptor{handle_, static_cast<short>(writing ? POLLOUT : POLLIN), 0};
      int ready;
      do { ready = poll(&descriptor, 1, Remaining(deadline)); } while (ready < 0 && errno == EINTR);
      if (ready == 0) throw std::runtime_error("Visualization helper exceeded its response deadline.");
      if (ready < 0 || (descriptor.revents & POLLNVAL)) throw std::runtime_error("Visualization helper IPC failed.");
      ssize_t count;
      if (writing) {
#if defined(MSG_NOSIGNAL)
        count = send(handle_, data, size, MSG_NOSIGNAL);
#else
        count = send(handle_, data, size, 0);
#endif
      } else {
        count = recv(handle_, data, size, 0);
      }
      if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
      if (count <= 0) throw std::runtime_error("Visualization helper disconnected.");
      data += count; size -= static_cast<size_t>(count);
    }
  }
#endif
  static int Remaining(Deadline deadline) {
    if (deadline == Deadline::max()) return -1;
    const auto now = Clock::now();
    if (now >= deadline) return 0;
    const auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count();
    return static_cast<int>(std::min<int64_t>(millis + 1, 2000000000));
  }
 public:
  explicit RenderPipe(Handle handle) : handle_(handle) {
    if (handle_ == Invalid()) throw std::runtime_error("Invalid visualization IPC handle.");
#if !defined(_WIN32)
    const int flags = fcntl(handle_, F_GETFL);
    if (flags < 0 || fcntl(handle_, F_SETFL, flags | O_NONBLOCK) < 0) {
      close(handle_); handle_ = Invalid(); throw std::runtime_error("Could not bound visualization IPC.");
    }
#if defined(SO_NOSIGPIPE)
    int enabled = 1;
    if (setsockopt(handle_, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0) {
      close(handle_); handle_ = Invalid(); throw std::runtime_error("Could not configure visualization IPC.");
    }
#endif
#endif
  }
  ~RenderPipe() {
    if (handle_ == Invalid()) return;
#if defined(_WIN32)
    CloseHandle(handle_);
#else
    close(handle_);
#endif
  }
  RenderPipe(const RenderPipe&) = delete;
  RenderPipe& operator=(const RenderPipe&) = delete;
  Handle NativeHandle() const { return handle_; }
#if defined(_WIN32)
  void Connect(Deadline deadline) {
    auto pending = std::make_unique<Pending>(0);
    if (ConnectNamedPipe(handle_, &pending->operation)) return;
    const auto error = GetLastError();
    if (error == ERROR_PIPE_CONNECTED) return;
    if (error != ERROR_IO_PENDING) throw std::runtime_error("Visualization IPC did not connect.");
    Await(pending, deadline);
    DWORD ignored = 0;
    if (!GetOverlappedResult(handle_, &pending->operation, &ignored, FALSE))
      throw std::runtime_error("Visualization IPC did not connect.");
  }
#endif
  render_protocol::Bytes Read(size_t size, Deadline deadline) {
    if (size > render_protocol::kMaxMessage) throw std::runtime_error("Visualization message is too large.");
#if defined(_WIN32)
    return Transfer(nullptr, size, deadline);
#else
    render_protocol::Bytes bytes(size); Transfer(bytes.data(), size, false, deadline); return bytes;
#endif
  }
  void Write(const render_protocol::Bytes& bytes, Deadline deadline) {
    if (bytes.size() > render_protocol::kMaxMessage + render_protocol::kHeaderSize)
      throw std::runtime_error("Visualization message is too large.");
#if defined(_WIN32)
    Transfer(bytes.data(), bytes.size(), deadline);
#else
    Transfer(const_cast<uint8_t*>(bytes.data()), bytes.size(), true, deadline);
#endif
  }
};
}  // namespace plezy::visualization
