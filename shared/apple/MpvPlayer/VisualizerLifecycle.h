// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#import <UIKit/UIKit.h>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <stdexcept>

// UIKit updates this gate on the main thread. A retired GL context waits on
// its owning render thread until foreground; the UI never waits for that wait.
class AppleVisualizerLifecycle {
  std::mutex mutex_;
  std::condition_variable condition_;
  bool foreground_;
  id inactive_, active_;
  AppleVisualizerLifecycle() : foreground_(UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
    auto* center = NSNotificationCenter.defaultCenter;
    inactive_ = [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil
        usingBlock:^(NSNotification*) { SetForeground(false); }];
    active_ = [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil
        usingBlock:^(NSNotification*) { SetForeground(true); }];
  }
 public:
  static AppleVisualizerLifecycle& Shared() { static auto* gate = new AppleVisualizerLifecycle; return *gate; }
  bool Foreground() { std::lock_guard<std::mutex> lock(mutex_); return foreground_; }
  void SetForeground(bool value) {
    { std::lock_guard<std::mutex> lock(mutex_); foreground_ = value; }
    condition_.notify_all();
  }
  void Cancel(std::atomic<bool>& cancelled) {
    { std::lock_guard<std::mutex> lock(mutex_); cancelled.store(true); }
    condition_.notify_all();
  }
  void Wait(const std::atomic<bool>* cancelled = nullptr) {
    std::unique_lock<std::mutex> lock(mutex_);
    condition_.wait(lock, [&] { return foreground_ || (cancelled && cancelled->load()); });
    if (cancelled && cancelled->load()) throw std::runtime_error("Visualization startup was cancelled.");
  }
};
struct AppleVisualizerPermit {
  std::atomic<bool> cancelled{false};
  AppleVisualizerPermit() { (void)AppleVisualizerLifecycle::Shared(); }
  void Cancel() { AppleVisualizerLifecycle::Shared().Cancel(cancelled); }
  void Wait() const { AppleVisualizerLifecycle::Shared().Wait(&cancelled); }
};
