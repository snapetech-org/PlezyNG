// SPDX-License-Identifier: AGPL-3.0-only
#include "visualizer_session.h"

#include "../../../shared/visualization/render_process.h"

namespace plezy::visualization {
namespace {
struct FrameSlot {
  std::mutex mutex;
  std::shared_ptr<const NativeFrame> frame;
};
struct PixelLease {
  std::shared_ptr<const NativeFrame> frame;
  FlutterDesktopPixelBuffer buffer{};
  explicit PixelLease(std::shared_ptr<const NativeFrame> value) : frame(std::move(value)) {
    buffer.buffer = frame->rgba.data();
    buffer.width = frame->width;
    buffer.height = frame->height;
    buffer.release_context = this;
    buffer.release_callback = [](void* context) { delete static_cast<PixelLease*>(context); };
  }
};
}  // namespace
WindowsVisualizerSession::WindowsVisualizerSession(
    flutter::TextureRegistrar* registrar, NativeWorker::AudioReader reader)
    : registrar_(registrar) {
  const auto unavailable = DependencyError();
  if (!unavailable.empty()) throw std::runtime_error(unavailable);
  auto slot = std::make_shared<FrameSlot>();
  texture_ = std::make_shared<flutter::TextureVariant>(
      flutter::PixelBufferTexture([slot](size_t, size_t) -> const FlutterDesktopPixelBuffer* {
        std::lock_guard<std::mutex> lock(slot->mutex);
        return slot->frame ? &(new PixelLease(slot->frame))->buffer : nullptr;
      }));
  texture_id_ = registrar_->RegisterTexture(texture_.get());
  if (texture_id_ < 0) throw std::runtime_error("Flutter rejected the native visualization texture.");
  try {
    worker_ = std::make_unique<NativeWorker>(
        [] { return std::make_unique<IsolatedRenderBackend>(); }, std::move(reader),
        [slot, registrar, id = texture_id_](std::shared_ptr<const NativeFrame> frame) {
          {
            std::lock_guard<std::mutex> lock(slot->mutex);
            slot->frame = std::move(frame);
          }
          registrar->MarkTextureFrameAvailable(id);
        }, false, RenderBudget::Desktop());
  } catch (...) {
    registrar_->UnregisterTexture(texture_id_, [keep = texture_] {});
    throw;
  }
}
WindowsVisualizerSession::~WindowsVisualizerSession() {
  worker_.reset();
  if (texture_id_ >= 0) registrar_->UnregisterTexture(texture_id_, [keep = std::move(texture_)] {});
}
std::string WindowsVisualizerSession::DependencyError() { return IsolatedRenderBackend::DependencyError(); }
}  // namespace plezy::visualization
