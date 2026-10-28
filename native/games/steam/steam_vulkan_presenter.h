// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "steam_pyrowave.h"

namespace plezy::steam {
// Native windows must outlive the presenter. All operations, including destroy,
// belong to one decoder worker; no Vulkan/WSI work runs on the Flutter thread.
struct GpuWindow {
  enum class Kind { android, wayland } kind;
  void* display = nullptr;  // wl_display on Wayland
  void* window = nullptr;   // ANativeWindow or wl_surface
};

class VulkanPresenter {
 public:
  VulkanPresenter();
  ~VulkanPresenter();
  VulkanPresenter(const VulkanPresenter&) = delete;
  VulkanPresenter& operator=(const VulkanPresenter&) = delete;

  bool open(GpuWindow window, bool allowHdr10);
  bool supportsHdr10() const;
  bool hdr10Active() const;
  bool configure(int width, int height, const uint8_t* initial, size_t length);
  // Decodes into R16 GPU planes, samples them in a fragment shader, and
  // presents the native swapchain. No pixel buffers cross the CPU or Flutter.
  // pending means incomplete input or WSI backpressure, never first-frame success.
  PyrowaveDecodeStatus present(const uint8_t* bytes, size_t length, int outputWidth, int outputHeight);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}  // namespace plezy::steam
