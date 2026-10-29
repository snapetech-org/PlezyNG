// SPDX-License-Identifier: AGPL-3.0-only
#include "visualizer_host.h"
#include "ffi_messages.h"
#include "visualizer_pcm.h"
#include "../../../../../shared/visualization/native_worker.h"
#include "../../../../../shared/visualization/bounded_stb_decoder.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <dlfcn.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>
#include <atomic>
#include <limits>

namespace video_player_videohole_tizen {
namespace {
using namespace plezy::visualization;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;

struct EglApi {
  // Static-plugin USER_LIBS are not propagated by flutter-tizen's combined
  // plugin link. Resolve optional graphics functions explicitly instead.
  void* library = dlopen("libEGL.so.1", RTLD_NOW | RTLD_LOCAL);
  void* gles = dlopen("libGLESv2.so.2", RTLD_NOW | RTLD_LOCAL);
  void* Symbol(const char* name) {
    if (!library) library = dlopen("libEGL.so", RTLD_NOW | RTLD_LOCAL);
    return library ? dlsym(library, name) : nullptr;
  }
#define EGL_API(name) decltype(&::name) name = reinterpret_cast<decltype(&::name)>(Symbol(#name));
  EGL_API(eglGetDisplay) EGL_API(eglInitialize) EGL_API(eglBindAPI)
  EGL_API(eglChooseConfig) EGL_API(eglCreatePbufferSurface) EGL_API(eglCreateContext)
  EGL_API(eglMakeCurrent) EGL_API(eglDestroyContext) EGL_API(eglDestroySurface)
  EGL_API(eglReleaseThread) EGL_API(eglGetProcAddress)
#undef EGL_API
  bool Available() const {
    return eglGetDisplay && eglInitialize && eglBindAPI && eglChooseConfig && eglCreatePbufferSurface &&
        eglCreateContext && eglMakeCurrent && eglDestroyContext && eglDestroySurface && eglReleaseThread && eglGetProcAddress;
  }
  EglApi() { if (!gles) gles = dlopen("libGLESv2.so", RTLD_NOW | RTLD_LOCAL); }
  static EglApi& Get() { static EglApi api; return api; }
};

class EglContext final : public NativeContext {
 public:
  EglContext() {
    try {
      if (!api_.Available()) throw std::runtime_error("The TV EGL library is unavailable.");
      display_ = api_.eglGetDisplay(EGL_DEFAULT_DISPLAY);
      EGLint major = 0, minor = 0;
      if (display_ == EGL_NO_DISPLAY || !api_.eglInitialize(display_, &major, &minor) || !api_.eglBindAPI(EGL_OPENGL_ES_API))
        throw std::runtime_error("Samsung EGL initialization failed.");
      const EGLint attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
          EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
      EGLConfig config{}; EGLint count = 0;
      if (!api_.eglChooseConfig(display_, attributes, &config, 1, &count) || !count)
        throw std::runtime_error("The TV does not expose a GLES 3 pbuffer configuration.");
      const EGLint surface_attributes[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
      surface_ = api_.eglCreatePbufferSurface(display_, config, surface_attributes);
      const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
      context_ = api_.eglCreateContext(display_, config, EGL_NO_CONTEXT, context_attributes);
      if (surface_ == EGL_NO_SURFACE || context_ == EGL_NO_CONTEXT ||
          !api_.eglMakeCurrent(display_, surface_, surface_, context_))
        throw std::runtime_error("Could not create the TV visualization context.");
    } catch (...) { Release(); throw; }
  }
  ~EglContext() override { Release(); }
  milkrust_gl_loader Loader() const override { return Proc; }
  bool IsGles() const override { return true; }
 private:
  EglApi& api_ = EglApi::Get();
  EGLDisplay display_ = EGL_NO_DISPLAY;
  EGLContext context_ = EGL_NO_CONTEXT;
  EGLSurface surface_ = EGL_NO_SURFACE;
  static const void* Proc(const char* name) {
    auto& api = EglApi::Get();
    auto address = api.eglGetProcAddress(name);
    if (address) return reinterpret_cast<const void*>(address);
    auto* symbol = dlsym(RTLD_DEFAULT, name);
    return symbol ? symbol : api.gles ? dlsym(api.gles, name) : nullptr;
  }
  void Release() {
    if (display_ == EGL_NO_DISPLAY) return;
    api_.eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (context_ != EGL_NO_CONTEXT) api_.eglDestroyContext(display_, context_);
    if (surface_ != EGL_NO_SURFACE) api_.eglDestroySurface(display_, surface_);
    // Flutter may own the same EGLDisplay. Never terminate that shared display.
    context_ = EGL_NO_CONTEXT; surface_ = EGL_NO_SURFACE; display_ = EGL_NO_DISPLAY;
    api_.eglReleaseThread();
  }
};

struct Binding {
  mutable std::mutex mutex;
  int64_t player = -1;
  bool enabled = false;
  std::shared_ptr<VisualizerPcm> pcm;
  int Read(mpv_plezy_audio_block* block) {
    std::lock_guard<std::mutex> lock(mutex);
    return pcm ? pcm->Read(block) : 0;
  }
  std::string Reason() const {
    std::lock_guard<std::mutex> lock(mutex);
    return pcm ? pcm->Reason() : "";
  }
  bool AcceptsFrame(uint32_t generation) const {
    std::lock_guard<std::mutex> lock(mutex);
    return pcm && pcm->AcceptsFrame(generation);
  }
  void Enable(bool value) {
    std::lock_guard<std::mutex> lock(mutex);
    enabled = value;
    if (pcm) pcm->Enabled(value);
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
      worker = std::make_unique<NativeWorker>([] { return std::make_unique<EglContext>(); }, DecodeBoundedImage,
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
  ~Impl() { channel->SetMethodCallHandler(nullptr); binding->Enable(false); session.reset(); }

  std::string Unavailable(const std::string& engine) const {
    if (engine != "milkrust") return "Samsung native presets currently require the MilkRust engine.";
    if (!textures) return "Flutter has no native texture registrar.";
    if (!MilkRustApi::Shared().error.empty()) return MilkRustApi::Shared().error;
    if (!VisualizerPcm::ApiAvailable()) return "This Samsung firmware lacks the decoded-audio API.";
    return binding->Reason();
  }
  void Handle(const flutter::MethodCall<Value>& call, std::unique_ptr<flutter::MethodResult<Value>> result) {
    try {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto& method = call.method_name();
      if (method == "visualizerBindPlayer" || method == "visualizerUnbindPlayer") {
        const auto id = Integer(args, "playerId");
        if (method == "visualizerBindPlayer") {
          auto pcm = GetVisualizationPcm(id);
          if (!pcm) { result->Error("VISUALIZER_SOURCE", "The selected Samsung player is not a music PCM source."); return; }
          std::lock_guard<std::mutex> lock(binding->mutex);
          if (binding->pcm) binding->pcm->Enabled(false);
          binding->player = id; binding->pcm = std::move(pcm);
          binding->pcm->Enabled(binding->enabled);
        } else {
          std::lock_guard<std::mutex> lock(binding->mutex);
          if (binding->player == id) {
            if (binding->pcm) binding->pcm->Enabled(false);
            binding->pcm.reset(); binding->player = -1;
          }
        }
        result->Success(); return;
      }
      if (method == "visualizerCapabilities" || method == "visualizerCreate") {
        const auto reason = Unavailable(String(args, "engine"));
        if (method == "visualizerCapabilities") {
          result->Success(Value(Map{{Value("available"), Value(reason.empty())}, {Value("reason"), Value(reason)},
              {Value("engine"), Value("milkrust-tizen-native")}})); return;
        }
        if (!reason.empty()) { result->Error("VISUALIZER_UNAVAILABLE", reason); return; }
        if (session) { result->Error("VISUALIZER_BUSY", "A visualization session already owns this host."); return; }
        if (next_lease == INT64_MAX) throw std::runtime_error("The visualization lease counter is exhausted.");
        session = std::make_unique<Session>(textures, binding, ++next_lease);
        result->Success(Value(Map{{Value("sessionId"), Value(session->lease)}, {Value("textureId"), Value(session->texture_id)}}));
        return;
      }
      if (method != "visualizerLoad" && method != "visualizerResize" && method != "visualizerSetPaused" &&
          method != "visualizerStatus" && method != "visualizerDispose") { result->NotImplemented(); return; }
      if (!session || Integer(args, "sessionId") != session->lease) {
        result->Error("VISUALIZER_STALE", "The visualization session has expired."); return;
      }
      if (method == "visualizerDispose") { binding->Enable(false); session.reset(); }
      else if (method == "visualizerLoad") session->worker->Load(String(args, "path"), String(args, "root"));
      else if (method == "visualizerResize") {
        const auto width = Integer(args, "width"), height = Integer(args, "height");
        if (width < 1 || height < 1 || width > 16384 || height > 16384) throw std::runtime_error("Invalid dimensions.");
        session->worker->Resize(static_cast<int>(width), static_cast<int>(height));
      } else if (method == "visualizerSetPaused") {
        const auto* value = Argument(args, "paused");
        const auto* paused = value ? std::get_if<bool>(value) : nullptr;
        if (!paused) throw std::runtime_error("Missing pause state.");
        session->worker->Pause(*paused);
        binding->Enable(!*paused);
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
      catch (...) { result->Error("VISUALIZER_ERROR", "The Samsung visualization request failed."); }
  }
};
VisualizerHost::VisualizerHost(flutter::PluginRegistrar* registrar) : impl_(std::make_unique<Impl>(registrar)) {}
VisualizerHost::~VisualizerHost() = default;
}  // namespace video_player_videohole_tizen
