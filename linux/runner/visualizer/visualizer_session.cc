#include "visualizer_session.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>

#include "../../../shared/visualization/render_process.h"
#include "../../../shared/visualization/pcm_resampler.h"
#include "../../../shared/visualization/preset_transition.h"
#include "../../../shared/visualization/render_thread.h"

namespace {
using Clock = std::chrono::steady_clock;
struct Frame {
  uint32_t width = 0, height = 0;
  std::vector<uint8_t> pixels;
};
struct FrameState {
  std::mutex mutex;
  std::shared_ptr<const Frame> latest;
  std::atomic<uint64_t> serial{0};
  std::atomic<uint64_t> preset_serial{0};
};

typedef struct _PlezyBufferTexture {
  FlPixelBufferTexture parent_instance;
  std::shared_ptr<FrameState>* state;
  std::shared_ptr<const Frame>* displayed;
} PlezyBufferTexture;
typedef struct _PlezyBufferTextureClass {
  FlPixelBufferTextureClass parent_class;
} PlezyBufferTextureClass;
G_DEFINE_TYPE(PlezyBufferTexture, plezy_buffer_texture, fl_pixel_buffer_texture_get_type())

gboolean CopyPixels(
    FlPixelBufferTexture* texture, const uint8_t** buffer, uint32_t* width, uint32_t* height, GError**) {
  auto* self = reinterpret_cast<PlezyBufferTexture*>(texture);
  const auto& state = *self->state;
  if (!state) return FALSE;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    *self->displayed = state->latest;
  }
  // Flutter consumes the pointer after this callback returns. The texture
  // retains this immutable snapshot until its next callback or finalization.
  const auto& frame = *self->displayed;
  if (!frame) return FALSE;
  *buffer = frame->pixels.data();
  *width = frame->width;
  *height = frame->height;
  return TRUE;
}
void TextureFinalize(GObject* object) {
  auto* texture = reinterpret_cast<PlezyBufferTexture*>(object);
  delete texture->displayed;
  delete texture->state;
  G_OBJECT_CLASS(plezy_buffer_texture_parent_class)->finalize(object);
}
void plezy_buffer_texture_class_init(PlezyBufferTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = CopyPixels;
  G_OBJECT_CLASS(klass)->finalize = TextureFinalize;
}
void plezy_buffer_texture_init(PlezyBufferTexture* self) {
  self->state = new std::shared_ptr<FrameState>();
  self->displayed = new std::shared_ptr<const Frame>();
}

struct Engine {
  bool native;
  std::unique_ptr<plezy::visualization::IsolatedRenderBackend> renderer;
  double elapsed = 0;
  Clock::time_point tick{};
  explicit Engine(bool use_rust) : native(use_rust) {}
  bool Has() const { return bool(renderer); }
  void Reset() {
    if (renderer) renderer->Reset();
    elapsed = 0; tick = {};
  }
  void Pause(bool paused) {
    if (renderer) renderer->Pause(paused);
    if (paused) tick = {};
  }
  void Create() {
    using namespace plezy::visualization;
    renderer = std::make_unique<IsolatedRenderBackend>(render_process_detail::HelperPath(),
        native ? render_protocol::Backend::MilkRust : render_protocol::Backend::ProjectM);
    renderer->Reset();
  }
  void Load(const std::string& path, const std::string& root, double transition) {
    renderer->Load(path, root, transition); elapsed = 0; tick = {};
  }
  void Pcm(const std::vector<float>& pcm, uint32_t generation) {
    renderer->Pcm(pcm.data(), pcm.size() / 2, generation);
  }
  void SetMouseState(bool down, double x, double y, double dx, double dy) {
    if (native) renderer->SetMouseState(down, x, y, dx, dy);
  }
  std::function<void()> Cancellation() const { return renderer ? renderer->Cancellation() : std::function<void()>{}; }
  void Capture(int width, int height, std::vector<uint8_t>& pixels) {
    const auto now = Clock::now();
    if (tick != Clock::time_point{}) elapsed += std::chrono::duration<double>(now - tick).count();
    tick = now;
    renderer->Capture(width, height, elapsed, pixels);
  }
};
}  // namespace

namespace plezy::visualization {
struct VisualizerSession::Impl {
  struct Work {
    std::shared_ptr<FrameState> frames = std::make_shared<FrameState>();
    AudioReader reader;
    const std::string engine_name;
    mutable std::mutex mutex;
    std::condition_variable condition;
    bool stopping = false, paused = true;
    int width = 768, height = 432;
    double transition_seconds = 3;
    bool mouse_down = false, mouse_click_pending = false;
    double mouse_x = 0.5, mouse_y = 0.5, mouse_dx = 0, mouse_dy = 0;
    std::string path, root, state = "starting", error;
    uint64_t preset_serial = 0;
    uint32_t dropped = 0;
    std::mutex reader_mutex;
    bool reader_closed = false;
    RenderWatchdog watchdog;
    std::function<void()> cancel;
    Work(AudioReader callback, std::string engine):reader(std::move(callback)),engine_name(std::move(engine)) {}
    void Stop() {
      std::function<void()> interrupt;
      { std::lock_guard<std::mutex> lock(mutex); stopping = true; interrupt = cancel; }
      if (interrupt) interrupt();
      condition.notify_all();
      std::lock_guard<std::mutex> callback(reader_mutex);
      reader_closed = true; reader = {};
    }
    int Read(mpv_plezy_audio_block* block) {
      std::lock_guard<std::mutex> callback(reader_mutex);
      return reader_closed ? 0 : reader(block);
    }
    void State(const std::string& value, const std::string& reason = {}) {
      std::lock_guard<std::mutex> lock(mutex);
      if (stopping) return;
      state = value;
      error = reason;
    }
    void Run() {
      try {
        const auto dependency = VisualizerSession::DependencyError(engine_name);
        if (!dependency.empty()) throw std::runtime_error(dependency);
        Engine engine(engine_name == "milkrust");
        PresetTransition fade;
        std::shared_ptr<const Frame> last_frame;
        uint64_t loaded_serial = 0;
        uint32_t generation = 0;
        PcmResampler resampler;
        std::vector<float> pcm;
        auto audio_at = Clock::time_point{};
        for (;;) {
          auto started = Clock::now();
          std::string requested_path, requested_root;
          uint64_t serial;
          int w, h;
          double transition;
          bool pause_requested, mouse_down;
          double mouse_x, mouse_y, mouse_dx, mouse_dy;
          { std::lock_guard<std::mutex> lock(mutex); pause_requested = paused; }
          if (pause_requested && engine.Has()) {
            RenderWatchdog::Operation operation(watchdog);
            engine.Pause(true);
          }
          {
            std::unique_lock<std::mutex> lock(mutex);
            condition.wait(lock, [this] { return stopping || (!paused && !path.empty()); });
            if (stopping) break;
            requested_path = path;
            requested_root = root;
            serial = preset_serial;
            w = width;
            h = height;
            transition = transition_seconds;
          }
          RenderWatchdog::Operation operation(watchdog);
          mpv_plezy_audio_block block{};
          bool audio_received = false;
          for (int n = 0; n < 32; ++n) {
            const int result = Read(&block);
            if (result == MPV_PLEZY_AUDIO_UNSUPPORTED) {
              State("unavailable", "The active audio output cannot provide visualization PCM.");
              audio_received = false;
              audio_at = Clock::time_point{};
              break;
            }
            if (result < 0) throw std::runtime_error("The music PCM tap was lost.");
            if (result == 0) break;
            if (block.generation != generation) {
              engine.Reset();
              generation = block.generation;
              loaded_serial = 0;
              fade.Clear();
              last_frame.reset();
              resampler = PcmResampler();
            }
            if (!engine.Has()) {
              engine.Create();
              std::function<void()> interrupt;
              { std::lock_guard<std::mutex> lock(mutex); cancel = engine.Cancellation(); if (stopping) interrupt = cancel; }
              if (interrupt) interrupt();
            }
            if (loaded_serial != serial) {
              if (engine.native && last_frame)
                fade.Start(last_frame->pixels, last_frame->width, last_frame->height, transition);
              else
                fade.Clear();
              engine.Load(requested_path, requested_root, transition);
              loaded_serial = serial;
            }
            if (!resampler.Convert(block, &pcm)) {
              State("unavailable", "This sample rate or speaker layout is not supported for analysis.");
              audio_received = false;
              audio_at = Clock::time_point{};
              break;
            }
            engine.Pcm(pcm, generation);
            audio_received = true;
            {
              std::lock_guard<std::mutex> lock(mutex);
              dropped = block.dropped_frames;
            }
          }
          if (audio_received) audio_at = Clock::now();
          if (engine.Has() && loaded_serial == serial && Clock::now() - audio_at < std::chrono::milliseconds(250)) {
            engine.Pause(false);
            auto frame = std::make_shared<Frame>();
            frame->width = w;
            frame->height = h;
            {
              std::lock_guard<std::mutex> lock(mutex);
              if (stopping || paused || preset_serial != serial) continue;
              mouse_down = this->mouse_down || this->mouse_click_pending;
              this->mouse_click_pending = false;
              mouse_x = this->mouse_x;
              mouse_y = this->mouse_y;
              mouse_dx = this->mouse_dx;
              mouse_dy = this->mouse_dy;
              this->mouse_dx = 0;
              this->mouse_dy = 0;
            }
            engine.SetMouseState(mouse_down, mouse_x, mouse_y, mouse_dx, mouse_dy);
            engine.Capture(w, h, frame->pixels);
            if (engine.native) fade.Apply(frame->pixels, w, h, engine.elapsed);
            {
              std::lock_guard<std::mutex> control(mutex);
              if (stopping || paused || preset_serial != serial) continue;
              std::lock_guard<std::mutex> lock(frames->mutex);
              last_frame = frame;
              frames->latest = std::move(frame);
            }
            frames->preset_serial.store(serial);
            frames->serial.fetch_add(1);
            State("rendering");
          } else {
            if (engine.Has()) engine.Pause(true);
            std::lock_guard<std::mutex> lock(mutex);
            if (!stopping && state != "unavailable") {
              state = "waiting-audio";
              error.clear();
            }
          }
          std::unique_lock<std::mutex> lock(mutex);
          condition.wait_until(lock, started + std::chrono::milliseconds(33), [this] { return stopping || paused; });
          if (stopping) break;
        }
      } catch (const std::exception& ex) {
        State("failed", ex.what());
      } catch (...) {
        State("failed", "The native visualization engine stopped unexpectedly.");
      }
    }
  };
  std::shared_ptr<Work> work;
  FlTextureRegistrar* registrar;
  PlezyBufferTexture* texture;
  std::unique_ptr<RenderThread> worker;
  guint timer = 0;
  uint64_t marked_serial = 0;

  Impl(FlTextureRegistrar* r, AudioReader callback, std::string engine)
      : work(std::make_shared<Work>(std::move(callback), std::move(engine))), registrar(FL_TEXTURE_REGISTRAR(g_object_ref(r))) {
    texture = reinterpret_cast<PlezyBufferTexture*>(g_object_new(plezy_buffer_texture_get_type(), nullptr));
    *texture->state = work->frames;
    if (!fl_texture_registrar_register_texture(registrar, FL_TEXTURE(texture))) {
      g_object_unref(texture);
      g_object_unref(registrar);
      throw std::runtime_error("Flutter rejected the visualization texture.");
    }
    timer = g_timeout_add(
        33,
        [](gpointer data) -> gboolean {
          auto* self = static_cast<Impl*>(data);
          auto serial = self->work->frames->serial.load();
          if (serial != self->marked_serial) {
            self->marked_serial = serial;
            fl_texture_registrar_mark_texture_frame_available(self->registrar, FL_TEXTURE(self->texture));
          }
          return G_SOURCE_CONTINUE;
        },
        this);
    try {
      worker = std::make_unique<RenderThread>([state=work] { state->Run(); });
    } catch (...) {
      g_source_remove(timer);
      fl_texture_registrar_unregister_texture(registrar, FL_TEXTURE(texture));
      g_object_unref(texture);
      g_object_unref(registrar);
      throw;
    }
  }
  ~Impl() {
    if (timer) g_source_remove(timer);
    work->Stop();
    worker.reset();
    fl_texture_registrar_unregister_texture(registrar, FL_TEXTURE(texture));
    g_object_unref(texture);
    g_object_unref(registrar);
  }
};

std::string VisualizerSession::DependencyError(const std::string& engine) {
  if (engine == "milkrust" || engine == "projectm") return IsolatedRenderBackend::DependencyError();
  return "Unknown visualization engine.";
}
VisualizerSession::VisualizerSession(FlTextureRegistrar* registrar, AudioReader reader, const std::string& engine)
    : impl_(std::make_unique<Impl>(registrar, std::move(reader), engine)) {}
VisualizerSession::~VisualizerSession() = default;
int64_t VisualizerSession::texture_id() const { return fl_texture_get_id(FL_TEXTURE(impl_->texture)); }
bool VisualizerSession::LoadPreset(
    const std::string& path, const std::string& root, double transition_seconds, std::string* error) {
  try {
    if (!std::isfinite(transition_seconds) || transition_seconds < 0 || transition_seconds > 10)
      throw std::runtime_error("Transition duration must be between 0 and 10 seconds.");
    const auto base = std::filesystem::canonical(root);
    const auto file = std::filesystem::canonical(path);
    const auto relative = file.lexically_relative(base);
    std::string extension = file.extension().string();
    std::transform(
        extension.begin(), extension.end(), extension.begin(), [](unsigned char c) { return std::tolower(c); });
    if (relative.empty() || *relative.begin() == ".." ||
        (extension != ".milk" && !(impl_->work->engine_name == "milkrust" && extension == ".milk2")) ||
        !std::filesystem::is_regular_file(file) || std::filesystem::file_size(file) > 2 * 1024 * 1024)
      throw std::runtime_error("Select a supported preset within the installed library, no larger than 2 MB.");
    {
      std::lock_guard<std::mutex> lock(impl_->work->mutex);
      if (impl_->work->state == "failed" || impl_->work->stopping)
        throw std::runtime_error("Create a new visualization session to retry this preset.");
      impl_->work->path = file.string();
      impl_->work->root = base.string();
      ++impl_->work->preset_serial;
      impl_->work->transition_seconds = transition_seconds;
      impl_->work->error.clear();
      impl_->work->state = "loading";
    }
    impl_->work->condition.notify_all();
    return true;
  } catch (const std::exception& ex) {
    *error = ex.what();
    return false;
  }
}
void VisualizerSession::Resize(int width, int height) {
  width = std::clamp(width, 1, 16384);
  height = std::clamp(height, 1, 16384);
  const double scale = std::min({1.0, 1280.0 / width, 720.0 / height});
  std::lock_guard<std::mutex> lock(impl_->work->mutex);
  impl_->work->width = std::max(1, static_cast<int>(width * scale));
  impl_->work->height = std::max(1, static_cast<int>(height * scale));
}
void VisualizerSession::SetMouseState(bool down, double x, double y, double dx, double dy) {
  if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(dx) || !std::isfinite(dy))
    throw std::runtime_error("Invalid native mouse input.");
  std::lock_guard<std::mutex> lock(impl_->work->mutex);
  if (impl_->work->stopping) return;
  if (impl_->work->paused) {
    impl_->work->mouse_down = false;
    impl_->work->mouse_click_pending = false;
  } else {
    if (down && !impl_->work->mouse_down) impl_->work->mouse_click_pending = true;
    impl_->work->mouse_down = down;
  }
  impl_->work->mouse_x = std::clamp(x, 0.0, 1.0);
  impl_->work->mouse_y = std::clamp(y, 0.0, 1.0);
  impl_->work->mouse_dx = std::clamp(impl_->work->mouse_dx + dx, -1.0, 1.0);
  impl_->work->mouse_dy = std::clamp(impl_->work->mouse_dy + dy, -1.0, 1.0);
}
void VisualizerSession::SetPaused(bool paused) {
  {
    std::lock_guard<std::mutex> lock(impl_->work->mutex);
    impl_->work->paused = paused;
    if (paused) {
      impl_->work->mouse_down = false;
      impl_->work->mouse_click_pending = false;
      impl_->work->mouse_dx = 0;
      impl_->work->mouse_dy = 0;
    }
  }
  impl_->work->condition.notify_all();
}
FlValue* VisualizerSession::Status() const {
  std::unique_lock<std::mutex> lock(impl_->work->mutex);
  std::function<void()> interrupt;
  if (impl_->work->watchdog.Expired()) {
    impl_->work->stopping = true;
    impl_->work->state = "failed";
    impl_->work->error = "Visualization rendering exceeded its deadline; playback can continue.";
    interrupt = impl_->work->cancel;
    impl_->work->condition.notify_all();
  }
  FlValue* result = fl_value_new_map();
  fl_value_set_string_take(result, "engine", fl_value_new_string(impl_->work->engine_name.c_str()));
  const bool inactive = impl_->work->paused && impl_->work->state != "failed" && impl_->work->state != "unavailable";
  fl_value_set_string_take(result, "state", fl_value_new_string(inactive ? "paused" : impl_->work->state.c_str()));
  fl_value_set_string_take(result, "reason", fl_value_new_string(impl_->work->error.c_str()));
  fl_value_set_string_take(
      result, "hasFrame",
      fl_value_new_bool(
          !impl_->work->stopping && impl_->work->state != "failed" && impl_->work->frames->serial.load() != 0 && impl_->work->frames->preset_serial.load() == impl_->work->preset_serial));
  fl_value_set_string_take(result, "droppedFrames", fl_value_new_int(impl_->work->dropped));
  fl_value_set_string_take(result, "width", fl_value_new_int(impl_->work->width));
  fl_value_set_string_take(result, "height", fl_value_new_int(impl_->work->height));
  lock.unlock();
  if (interrupt) interrupt();
  return result;
}
}  // namespace plezy::visualization
