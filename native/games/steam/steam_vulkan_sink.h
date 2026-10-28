// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <functional>

#include "steam_runtime.h"
#include "steam_vulkan_presenter.h"
namespace plezy::steam {
// Pyrowave video on a private GPU worker; conventional video and audio retain
// the platform sink. This adapter never waits on GTK from the transport thread.
class VulkanSink final : public Sink {
 public:
  struct Target {
    int width = 0, height = 0;
    bool permitted = false;
    bool valid = true;
  };
  using Prepare = std::function<Target(const PyrowaveFrameInfo&)>;
  using Complete = std::function<void(uint32_t, int, int, bool, bool)>;
  using Selected = std::function<void(bool)>;
  VulkanSink(
      std::shared_ptr<Sink> fallback, GpuWindow, bool hdr, Prepare, Complete, Selected, std::function<void()> failed);
  ~VulkanSink() override;
  bool ready();
  bool supportsHdr10() const;
  bool hdr10Active() const;
  bool video(int, int, int, const uint8_t*, size_t) override;
  bool frame(const uint8_t*, size_t, uint32_t, bool) override;
  bool audio(int channels, int rate) override;
  void samples(const int16_t*, size_t) override;
  void audioUnavailable() override;
  void close();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}  // namespace plezy::steam
