// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <memory>
#include "milkrust_engine.h"

namespace plezy::visualization {
class NativeContext {
 public:
  virtual ~NativeContext() = default;
  virtual milkrust_gl_loader Loader() const = 0;
  virtual bool IsGles() const = 0;
  // Mobile hosts may defer graphics destruction while the app is backgrounded.
  virtual void PrepareDestroy() {}
  virtual void Drain() {
    const auto finish = reinterpret_cast<void (*)()>(Loader()("glFinish"));
    if (!finish) throw std::runtime_error("The graphics context cannot finish pending visualization work.");
    finish();
  }
};

// All methods except the returned cancellation function belong to one worker.
// Cancellation must not capture a graphics context or wait for a driver call.
class RenderBackend {
 public:
  virtual ~RenderBackend() = default;
  virtual void Reset() = 0;
  virtual void Load(const std::string& path, const std::string& root, double transition = 0) = 0;
  virtual void Pcm(const float* samples, size_t frames, uint32_t generation) = 0;
  virtual void Capture(uint32_t width, uint32_t height, double seconds, std::vector<uint8_t>& rgba) = 0;
  virtual std::function<void()> Cancellation() const { return {}; }
  virtual bool CanPresent() const { return false; }
  virtual void Present(uint32_t, uint32_t, const std::vector<uint8_t>&) {}
  virtual void Pause(bool) {}
  virtual void SetMouseState(bool, double, double, double, double) {}
};

class LocalRenderBackend final : public RenderBackend {
  // Reverse destruction order keeps the context alive through engine teardown.
  std::unique_ptr<NativeContext> context_;
  std::unique_ptr<MilkRustEngine> engine_;
  MilkRustImageDecoder decoder_;
  MilkRustEngine& Engine() {
    if (!engine_) throw std::runtime_error("Visualization renderer has not been reset.");
    return *engine_;
  }
 public:
  LocalRenderBackend(std::unique_ptr<NativeContext> context, MilkRustImageDecoder decoder)
      : context_(std::move(context)), decoder_(std::move(decoder)) {
    if (!context_) throw std::runtime_error("No native graphics context.");
  }
  ~LocalRenderBackend() override {
    context_->PrepareDestroy();
    engine_.reset();
  }
  void Pause(bool paused) override { if (paused) context_->Drain(); }
  void Reset() override {
    engine_.reset();
    engine_ = std::make_unique<MilkRustEngine>(context_->Loader(), context_->IsGles());
  }
  void Load(const std::string& path, const std::string& root, double = 0) override {
    Engine().Load(std::filesystem::u8path(path), std::filesystem::u8path(root), decoder_);
  }
  void Pcm(const float* samples, size_t frames, uint32_t generation) override {
    Engine().Pcm(samples, frames, generation);
  }
  void SetMouseState(bool down, double x, double y, double dx, double dy) override {
    Engine().SetMouseState(down, x, y, dx, dy);
  }
  void Capture(uint32_t width, uint32_t height, double seconds, std::vector<uint8_t>& rgba) override {
    Engine().Capture(width, height, seconds, rgba);
  }
};
}  // namespace plezy::visualization
