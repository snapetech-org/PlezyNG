// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <flutter/plugin_registrar.h>
#include <memory>

namespace video_player_videohole_tizen {
class VisualizerHost {
 public:
  explicit VisualizerHost(flutter::PluginRegistrar* registrar);
  ~VisualizerHost();
  VisualizerHost(const VisualizerHost&) = delete;
  VisualizerHost& operator=(const VisualizerHost&) = delete;
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}  // namespace video_player_videohole_tizen
