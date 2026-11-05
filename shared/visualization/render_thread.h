// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>

namespace plezy::visualization {
// Driver calls cannot safely be cancelled inside a process. A stalled thread
// retains its OWN context/state until the call returns. New sessions are refused
// while one is quarantined, preventing repeated retries from leaking resources.
// Callers must disconnect borrowed host callbacks before Join().
class RenderThread {
  struct Admission { std::mutex mutex; unsigned active=0, quarantined=0; };
  static Admission& Pool() { static auto* pool=new Admission(); return *pool; }
  struct Completion { std::mutex mutex; std::condition_variable condition; bool done=false, quarantined=false; };
  std::shared_ptr<Completion> completion_=std::make_shared<Completion>();
  std::thread thread_;
 public:
  explicit RenderThread(std::function<void()> run) {
    auto& pool=Pool();
    { std::lock_guard<std::mutex> lock(pool.mutex);
      if (pool.quarantined || pool.active>=4) throw std::runtime_error("Visualization renderer is busy or stalled; wait for recovery or restart the app.");
      ++pool.active;
    }
    try {
      thread_=std::thread([completion=completion_, run=std::move(run)]() mutable {
        try { run(); } catch (...) {} // The host records its own operation error.
        run={}; // Release captured state/context BEFORE marking completion.
        std::lock_guard<std::mutex> lock(completion->mutex);
        { auto& pool=Pool(); std::lock_guard<std::mutex> admission(pool.mutex);
          --pool.active; if (completion->quarantined) --pool.quarantined;
        }
        completion->done=true; completion->condition.notify_all();
      });
    } catch (...) { std::lock_guard<std::mutex> lock(pool.mutex); --pool.active; throw; }
  }
  ~RenderThread() { Join(); }
  RenderThread(const RenderThread&)=delete;
  RenderThread& operator=(const RenderThread&)=delete;
  bool Join() {
    if (!thread_.joinable()) {
      std::lock_guard<std::mutex> lock(completion_->mutex);
      return completion_->done;
    }
    std::unique_lock<std::mutex> lock(completion_->mutex);
    if (completion_->condition.wait_for(lock,std::chrono::milliseconds(250),[&] { return completion_->done; })) {
      lock.unlock(); thread_.join(); return true;
    } else {
      completion_->quarantined=true;
      { auto& pool=Pool(); std::lock_guard<std::mutex> admission(pool.mutex); ++pool.quarantined; }
      thread_.detach();
      return false;
    }
  }
};

class RenderWatchdog {
  using Clock=std::chrono::steady_clock;
  std::atomic<int64_t> started_{0};
  static int64_t Now() { return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count(); }
 public:
  class Operation {
    RenderWatchdog& watchdog_;
   public:
    explicit Operation(RenderWatchdog& watchdog):watchdog_(watchdog) { watchdog_.started_.store(Now(),std::memory_order_release); }
    ~Operation() { watchdog_.started_.store(0,std::memory_order_release); }
    Operation(const Operation&)=delete;
    Operation& operator=(const Operation&)=delete;
  };
  bool Expired() const {
    const auto started=started_.load(std::memory_order_acquire);
    return started && Now()-started>2000;
  }
};
}  // namespace plezy::visualization
