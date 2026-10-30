// SPDX-License-Identifier: AGPL-3.0-only
#include "visualizer_host.h"
#include "visualizer_pcm.h"
#include "../../../../shared/visualization/native_worker.h"
#include "../../../../shared/visualization/render_tv_process.h"
#include <dlfcn.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>
#include <atomic>
#include <limits>

namespace audioplayers_soloud_webos {
namespace {
using namespace plezy::visualization;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;

struct Binding {
  mutable std::mutex mutex;
  int64_t player = -1;
  bool bound = false, source_active = false, render_active = false;
  int Read(mpv_plezy_audio_block* block) {
    std::lock_guard<std::mutex> lock(mutex);
    return bound && source_active && render_active
        ? VisualizerPcm::Shared().Read(block) : 0;
  }
  std::string Reason() const {
    std::lock_guard<std::mutex> lock(mutex);
    return !bound || !source_active || !render_active
        ? "Waiting for the app-owned webOS audio output." : VisualizerPcm::Shared().Reason();
  }
  bool AcceptsFrame(uint32_t generation) const {
    std::lock_guard<std::mutex> lock(mutex);
    return bound && source_active && render_active &&
        VisualizerPcm::Shared().AcceptsFrame(generation);
  }
  void Refresh() {
    VisualizerPcm::Shared().SetActive(bound && source_active && render_active);
  }
  bool Bind(int64_t id) {
    std::lock_guard<std::mutex> lock(mutex);
    if (bound && player != id) return false;
    player = id; bound = true; source_active = false; Refresh();
    return true;
  }
  void Unbind(int64_t id) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!bound || player != id) return;
    bound = false; source_active = false; player = -1; Refresh();
  }
  bool SourceActive(int64_t id, bool active) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!bound || player != id) return false;
    source_active = active; Refresh();
    return true;
  }
  bool Discontinuity(int64_t id) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!bound || player != id) return false;
    VisualizerPcm::Shared().Discontinuity();
    return true;
  }
  void RenderActive(bool active) {
    std::lock_guard<std::mutex> lock(mutex);
    render_active = active; Refresh();
  }
};
struct FrameSlot {
  std::mutex mutex;
  std::shared_ptr<const NativeFrame> frame;
  std::atomic<unsigned> leases{0};
};
struct PixelLease {
  std::shared_ptr<FrameSlot> slot;
  std::shared_ptr<const NativeFrame> frame;
  FlutterDesktopPixelBuffer buffer{};
  PixelLease(std::shared_ptr<FrameSlot> owner, std::shared_ptr<const NativeFrame> value)
      : slot(std::move(owner)), frame(std::move(value)) {
    ++slot->leases;
    buffer.buffer = frame->rgba.data(); buffer.width = frame->width; buffer.height = frame->height;
    buffer.release_context = this;
    buffer.release_callback = [](void* context) { delete static_cast<PixelLease*>(context); };
  }
  ~PixelLease() { --slot->leases; }
};
struct Session {
  flutter::TextureRegistrar* registrar;
  std::shared_ptr<flutter::TextureVariant> texture;
  std::unique_ptr<NativeWorker> worker;
  int64_t texture_id = -1, lease;
  Session(flutter::TextureRegistrar* textures, std::shared_ptr<Binding> binding, int64_t id)
      : registrar(textures), lease(id) {
    auto slot = std::make_shared<FrameSlot>();
    texture = std::make_shared<flutter::TextureVariant>(flutter::PixelBufferTexture(
        [slot, binding](size_t, size_t) -> const FlutterDesktopPixelBuffer* {
          try {
            std::lock_guard<std::mutex> lock(slot->mutex);
            if (!slot->frame || slot->leases.load() >= 4 || !binding->AcceptsFrame(slot->frame->audio_generation)) return nullptr;
            return &(new PixelLease(slot, slot->frame))->buffer;
          } catch (...) { return nullptr; }
        }));
    texture_id = registrar->RegisterTexture(texture.get());
    if (texture_id < 0) throw std::runtime_error("Flutter rejected the TV visualization texture.");
    try {
      worker = std::make_unique<NativeWorker>([] { return std::make_unique<TvRenderBackend>(); },
          [binding](mpv_plezy_audio_block* block) { return binding->Read(block); },
          [slot, binding, textures, id = texture_id](std::shared_ptr<const NativeFrame> frame) {
            if (!binding->AcceptsFrame(frame->audio_generation)) return;
            { std::lock_guard<std::mutex> lock(slot->mutex); slot->frame = std::move(frame); }
            textures->MarkTextureFrameAvailable(id);
          });
    } catch (...) { registrar->UnregisterTexture(texture_id, [keep = texture] {}); throw; }
  }
  ~Session() {
    worker.reset();  // Stop publishing before unregistering; GL dies on its worker.
    if (texture_id >= 0) registrar->UnregisterTexture(texture_id, [keep = std::move(texture)] {});
  }
};

const Value* Argument(const Map* arguments, const char* key) {
  if (!arguments) return nullptr;
  const auto item = arguments->find(Value(key));
  return item == arguments->end() ? nullptr : &item->second;
}
int64_t Integer(const Map* arguments, const char* key) {
  const auto* value = Argument(arguments, key);
  if (value) {
    if (const auto* i = std::get_if<int64_t>(value)) return *i;
    if (const auto* i = std::get_if<int32_t>(value)) return *i;
  }
  throw std::runtime_error(std::string("Missing integer: ") + key);
}
double Number(const Map* arguments, const char* key, double fallback) {
  const auto* value = Argument(arguments, key);
  if (!value) return fallback;
  if (const auto* number = std::get_if<double>(value)) return *number;
  if (const auto* number = std::get_if<int32_t>(value)) return *number;
  if (const auto* number = std::get_if<int64_t>(value)) return static_cast<double>(*number);
  throw std::runtime_error(std::string("Invalid number: ") + key);
}
std::string String(const Map* arguments, const char* key) {
  const auto* value = Argument(arguments, key);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  if (!text) throw std::runtime_error(std::string("Missing string: ") + key);
  return *text;
}
}  // namespace

struct VisualizerHost::Impl {
  flutter::TextureRegistrar* textures;
  std::unique_ptr<flutter::MethodChannel<Value>> channel;
  std::shared_ptr<Binding> binding = std::make_shared<Binding>();
  std::unique_ptr<Session> session;
  int64_t next_lease = 0;

  explicit Impl(flutter::PluginRegistrar* registrar) : textures(registrar->texture_registrar()) {
    channel = std::make_unique<flutter::MethodChannel<Value>>(registrar->messenger(),
        "com.plezy/mpv_audio_player", &flutter::StandardMethodCodec::GetInstance());
    channel->SetMethodCallHandler([this](const auto& call, auto result) {
      try { Handle(call, std::move(result)); }
      catch (...) { /* Handle owns and completes all ordinary failures. */ }
    });
  }
  ~Impl() { channel->SetMethodCallHandler(nullptr); binding->RenderActive(false); session.reset(); }

  std::string Unavailable(const std::string& engine) const {
    if (engine != "milkrust") return "webOS native presets currently require the MilkRust engine.";
    if (!textures) return "Flutter has no webOS native texture registrar.";
    const auto renderer = TvRenderBackend::DependencyError();
    if (!renderer.empty()) return renderer;
    if (!VisualizerPcm::Shared().Available()) return "The app-owned SoLoud PCM tap is unavailable.";
    return {};
  }
  void Handle(const flutter::MethodCall<Value>& call, std::unique_ptr<flutter::MethodResult<Value>> result) {
    try {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto& method = call.method_name();
      if (method == "visualizerBindPlayer" || method == "visualizerUnbindPlayer") {
        const auto id = Integer(args, "playerId");
        if (method == "visualizerBindPlayer") {
          if (!binding->Bind(id)) { result->Error("VISUALIZER_BUSY", "Another webOS audio source is already bound."); return; }
        } else {
          binding->Unbind(id);
        }
        result->Success(); return;
      }
      if (method == "visualizerAudioDiscontinuity") {
        const auto id = Integer(args, "playerId");
        if (!binding->Discontinuity(id)) {
          result->Error("VISUALIZER_STALE", "The webOS audio source binding has expired."); return;
        }
        result->Success(); return;
      }
      if (method == "visualizerSetAudioActive") {
        const auto id = Integer(args, "playerId");
        const auto* value = Argument(args, "active");
        const auto* active = value ? std::get_if<bool>(value) : nullptr;
        if (!active) throw std::runtime_error("Missing audio-active state.");
        if (!binding->SourceActive(id, *active)) {
          result->Error("VISUALIZER_STALE", "The webOS audio source binding has expired."); return;
        }
        result->Success(); return;
      }
      if (method == "visualizerCapabilities" || method == "visualizerCreate") {
        const auto reason = Unavailable(String(args, "engine"));
        if (method == "visualizerCapabilities") {
          result->Success(Value(Map{{Value("available"), Value(reason.empty())}, {Value("reason"), Value(reason)},
              {Value("engine"), Value("milkrust-webos-native")}})); return;
        }
        if (!reason.empty()) { result->Error("VISUALIZER_UNAVAILABLE", reason); return; }
        if (session) { result->Error("VISUALIZER_BUSY", "A visualization session already owns this host."); return; }
        if (next_lease == INT64_MAX) throw std::runtime_error("The visualization lease counter is exhausted.");
        session = std::make_unique<Session>(textures, binding, ++next_lease);
        result->Success(Value(Map{{Value("sessionId"), Value(session->lease)}, {Value("textureId"), Value(session->texture_id)}}));
        return;
      }
      if (method != "visualizerLoad" && method != "visualizerResize" && method != "visualizerSetMouse" && method != "visualizerSetPaused" &&
          method != "visualizerStatus" && method != "visualizerDispose") { result->NotImplemented(); return; }
      if (!session || Integer(args, "sessionId") != session->lease) {
        result->Error("VISUALIZER_STALE", "The visualization session has expired."); return;
      }
      if (method == "visualizerDispose") { binding->RenderActive(false); session.reset(); }
      else if (method == "visualizerLoad")
        session->worker->Load(String(args, "path"), String(args, "root"), Number(args, "transitionSeconds", 3));
      else if (method == "visualizerResize") {
        const auto width = Integer(args, "width"), height = Integer(args, "height");
        if (width < 1 || height < 1 || width > 16384 || height > 16384) throw std::runtime_error("Invalid dimensions.");
        session->worker->Resize(static_cast<int>(width), static_cast<int>(height));
      } else if (method == "visualizerSetMouse") {
        const auto* value = Argument(args, "down");
        const auto* down = value ? std::get_if<bool>(value) : nullptr;
        if (!down) throw std::runtime_error("Missing pointer button state.");
        session->worker->SetMouseState(*down, Number(args, "x", 0.5), Number(args, "y", 0.5),
            Number(args, "dx", 0), Number(args, "dy", 0));
      } else if (method == "visualizerSetPaused") {
        const auto* value = Argument(args, "paused");
        const auto* paused = value ? std::get_if<bool>(value) : nullptr;
        if (!paused) throw std::runtime_error("Missing pause state.");
        session->worker->Pause(*paused);
        binding->RenderActive(!*paused);
      } else if (method == "visualizerStatus") {
        auto status = session->worker->Status();
        if (status.has_frame && !binding->AcceptsFrame(status.audio_generation)) {
          status.has_frame = false;
          if (status.state == "rendering") status.state = "waiting-audio";
        }
        const auto reason = binding->Reason();
        if (!reason.empty() && status.state != "failed") { status.state = "unavailable"; status.reason = reason; status.has_frame = false; }
        result->Success(Value(Map{{Value("state"), Value(status.state)}, {Value("reason"), Value(status.reason)},
            {Value("hasFrame"), Value(status.has_frame)}, {Value("droppedFrames"), Value(int64_t(status.dropped))},
            {Value("width"), Value(status.width)}, {Value("height"), Value(status.height)}})); return;
      }
      result->Success();
    } catch (const std::exception& error) { result->Error("VISUALIZER_ERROR", error.what()); }
      catch (...) { result->Error("VISUALIZER_ERROR", "The webOS visualization request failed."); }
  }
};
VisualizerHost::VisualizerHost(flutter::PluginRegistrar* registrar) : impl_(std::make_unique<Impl>(registrar)) {}
VisualizerHost::~VisualizerHost() = default;
}  // namespace audioplayers_soloud_webos
