// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>

#include "milkrust_engine.h"
#include "pcm_resampler.h"
#include "preset_transition.h"
#include "render_thread.h"

namespace plezy::visualization {
struct NativeFrame {
  uint32_t width = 0, height = 0;
  uint32_t audio_generation = 0;
  uint64_t preset_serial = 0;
  std::vector<uint8_t> rgba;
};
struct NativeStatus {
  std::string state = "starting", reason;
  uint64_t preset_serial = 0, frame_serial = 0;
  uint32_t dropped = 0;
  uint32_t audio_generation = 0;
  int width = 0, height = 0;
  bool has_frame = false;
};
// Platform context creation/destruction and all engine calls stay on one
// worker. Hosts retain frame ownership until Flutter releases its pixel lease.
class NativeContext {
 public:
  virtual ~NativeContext() = default;
  virtual milkrust_gl_loader Loader() const = 0;
  virtual bool IsGles() const = 0;
};
class NativeWorker {
 public:
  using AudioReader = std::function<int(mpv_plezy_audio_block*)>;
  using ContextFactory = std::function<std::unique_ptr<NativeContext>()>;
  using Publish = std::function<void(std::shared_ptr<const NativeFrame>)>;
 private:
  static bool IsPresetPath(const std::filesystem::path& path) {
    auto extension = path.extension().u8string();
    for (auto& character : extension) {
      if (character >= 'A' && character <= 'Z') character += 'a' - 'A';
    }
    return extension == ".milk" || extension == ".milk2";
  }
  struct WorkerState {
    WorkerState(ContextFactory context, MilkRustImageDecoder decoder, AudioReader audio, Publish publish, bool owned_publish)
        : context_(std::move(context)), decoder_(std::move(decoder)), audio_(std::move(audio)),
          publish_(std::move(publish)), owned_publish_(owned_publish) {}
    void Stop() {
      { std::lock_guard<std::mutex> lock(mutex_); stopping_ = true; }
      condition_.notify_all();
      // PCM reads and borrowed Flutter notifications are bounded host calls;
      // GPU compilation/render/readback and decoding never hold this gate.
      std::lock_guard<std::mutex> callbacks(callback_mutex_);
      callbacks_closed_ = true;
      audio_ = {};
      if (!owned_publish_) publish_ = {};
    }
    void Load(const std::string& path, const std::string& root, double transition_seconds) {
      if (path.empty() || root.empty() || path.size() > 32768 || root.size() > 32768)
        throw std::runtime_error("A bounded preset path and pack root are required.");
      if (!NativeWorker::IsPresetPath(std::filesystem::u8path(path)))
        throw std::runtime_error("Native MilkRust accepts .milk and supported .milk2 presets.");
      if (!PresetTransition::ValidDuration(transition_seconds))
        throw std::runtime_error("Preset transition must be between zero and ten seconds.");
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_ || status_.state == "failed")
          throw std::runtime_error("Create a new visualization session to retry.");
        path_ = path;
        root_ = root;
        transition_seconds_ = transition_seconds;
        ++serial_;
        status_.state = "loading";
        status_.reason.clear();
      }
      condition_.notify_all();
    }
    void Resize(int width, int height) {
      if (width < 1 || height < 1 || width > 16384 || height > 16384)
        throw std::runtime_error("Invalid visualization dimensions.");
      const double scale = std::min({1.0, 1280.0 / width, 720.0 / height});
      std::lock_guard<std::mutex> lock(mutex_);
      width_ = std::max(1, static_cast<int>(width * scale));
      height_ = std::max(1, static_cast<int>(height * scale));
    }
    void Pause(bool paused) {
      {
        std::lock_guard<std::mutex> lock(mutex_);
        paused_ = paused;
        if (paused && status_.state != "failed") status_.state = "paused";
      }
      condition_.notify_all();
    }
    void SetMouseState(bool down, double x, double y, double dx, double dy) {
      if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(dx) || !std::isfinite(dy))
        throw std::runtime_error("Invalid native mouse input.");
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_) return;
      mouse_down_ = down;
      mouse_x_ = std::clamp(x, 0.0, 1.0);
      mouse_y_ = std::clamp(y, 0.0, 1.0);
      mouse_dx_ = std::clamp(mouse_dx_ + dx, -1.0, 1.0);
      mouse_dy_ = std::clamp(mouse_dy_ + dy, -1.0, 1.0);
    }
    NativeStatus Status() {
      std::lock_guard<std::mutex> lock(mutex_);
      if (watchdog_.Expired()) {
        stopping_ = true;
        status_.state = "failed";
        status_.reason = "Visualization rendering exceeded its deadline; playback can continue.";
        condition_.notify_all();
      }
      auto result = status_;
      result.width = width_;
      result.height = height_;
      result.has_frame = !stopping_ && result.state != "failed" && result.frame_serial != 0 && result.preset_serial == serial_;
      if (paused_ && result.state != "failed" && result.state != "unavailable") result.state = "paused";
      return result;
    }

   private:
    using Clock = std::chrono::steady_clock;
    ContextFactory context_;
    MilkRustImageDecoder decoder_;
    AudioReader audio_;
    Publish publish_;
    mutable std::mutex mutex_;
    std::condition_variable condition_;
    bool stopping_ = false, paused_ = true, mouse_down_ = false;
    int width_ = 768, height_ = 432;
    double mouse_x_ = 0.5, mouse_y_ = 0.5, mouse_dx_ = 0, mouse_dy_ = 0;
    uint64_t serial_ = 0;
    double transition_seconds_ = 3;
    std::string path_, root_;
    NativeStatus status_;
    std::mutex callback_mutex_;
    bool callbacks_closed_ = false;
    const bool owned_publish_;
    RenderWatchdog watchdog_;
    int Read(mpv_plezy_audio_block* block) {
      std::lock_guard<std::mutex> lock(callback_mutex_);
      return callbacks_closed_ ? 0 : audio_(block);
    }
    void PublishFrame(std::shared_ptr<const NativeFrame> frame) {
      if (owned_publish_) {
        // This sink owns every resource it accesses, including any window lease.
        // It may finish an in-flight publication after Stop without touching a host.
        publish_(std::move(frame));
      } else {
        std::lock_guard<std::mutex> lock(callback_mutex_);
        if (!callbacks_closed_) publish_(std::move(frame));
      }
    }
    void State(const char* state, const std::string& reason = {}) {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_) return;
      status_.state = state;
      status_.reason = reason;
    }
   public:
    void Run() noexcept {
      try {
        auto context = [this] {
          RenderWatchdog::Operation operation(watchdog_);
          return context_();
        }();
        if (!context) throw std::runtime_error("No native graphics context.");
        std::unique_ptr<MilkRustEngine> engine;  // Destroy before its context.
        PresetTransition transition;
        std::shared_ptr<const NativeFrame> last_frame;
        PcmResampler resampler;
        std::vector<float> stereo;
        uint32_t generation = 0;
        uint64_t loaded = 0;
        double elapsed = 0;
        auto tick = Clock::time_point{}, audio_at = Clock::time_point{};
        for (;;) {
          std::string path, root;
          uint64_t serial;
          int width, height;
          double transition_seconds;
          bool mouse_down;
          double mouse_x, mouse_y, mouse_dx, mouse_dy;
          {
            std::unique_lock<std::mutex> lock(mutex_);
            if (paused_) {
              tick = {};
              audio_at = {};
            }
            condition_.wait(lock, [this] { return stopping_ || (!paused_ && serial_); });
            if (stopping_) break;
            path = path_;
            root = root_;
            serial = serial_;
            width = width_;
            height = height_;
            transition_seconds = transition_seconds_;
            mouse_down = mouse_down_;
            mouse_x = mouse_x_;
            mouse_y = mouse_y_;
            mouse_dx = mouse_dx_;
            mouse_dy = mouse_dy_;
            mouse_dx_ = 0;
            mouse_dy_ = 0;
          }
          RenderWatchdog::Operation operation(watchdog_);
          const auto started = Clock::now();
          bool received = false, unsupported = false;
          for (int reads = 0; reads < 32; ++reads) {
            mpv_plezy_audio_block block{};
            const int result = Read(&block);
            if (result == MPV_PLEZY_AUDIO_UNSUPPORTED) {
              unsupported = true;
              break;
            }
            if (result < 0) throw std::runtime_error("The music PCM tap was lost.");
            if (result == 0) break;
            if (!engine || generation != block.generation) {
              engine = std::make_unique<MilkRustEngine>(context->Loader(), context->IsGles());
              generation = block.generation;
              loaded = 0;
              transition.Clear();
              last_frame.reset();
              resampler = PcmResampler();
            }
            if (loaded != serial) {
              if (last_frame)
                transition.Start(last_frame->rgba, last_frame->width, last_frame->height, transition_seconds);
              else
                transition.Clear();
              engine->Load(std::filesystem::u8path(path), std::filesystem::u8path(root), decoder_);
              loaded = serial;
              elapsed = 0;
              tick = {};
            }
            if (!resampler.Convert(block, &stereo)) {
              unsupported = true;
              break;
            }
            engine->Pcm(stereo.data(), stereo.size() / 2, generation);
            received = true;
            {
              std::lock_guard<std::mutex> lock(mutex_);
              status_.dropped = block.dropped_frames;
            }
          }
          if (unsupported) {
            audio_at = {};
            tick = {};
            State("unavailable", "The active audio output or speaker layout cannot provide visualization PCM.");
          } else {
            if (received) audio_at = Clock::now();
            if (engine && loaded == serial && Clock::now() - audio_at < std::chrono::milliseconds(250)) {
              const auto now = Clock::now();
              if (tick != Clock::time_point{}) elapsed += std::chrono::duration<double>(now - tick).count();
              tick = now;
              auto frame = std::make_shared<NativeFrame>();
              frame->width = width;
              frame->height = height;
              frame->preset_serial = serial;
              frame->audio_generation = generation;
              engine->SetMouseState(mouse_down, mouse_x, mouse_y, mouse_dx, mouse_dy);
              engine->Capture(width, height, elapsed, frame->rgba);
              transition.Apply(frame->rgba, width, height, elapsed);
              bool current;
              {
                std::lock_guard<std::mutex> lock(mutex_);
                current = !paused_ && !stopping_ && serial_ == serial;
                if (current) {
                  status_.state = "rendering";
                  status_.reason.clear();
                  status_.preset_serial = serial;
                  status_.audio_generation = generation;
                  ++status_.frame_serial;
                }
              }
              if (current) {
                last_frame = frame;
                PublishFrame(std::move(frame));
              }
            } else {
              tick = {};
              State("waiting-audio");
            }
          }
          std::unique_lock<std::mutex> lock(mutex_);
          condition_.wait_until(lock, started + std::chrono::milliseconds(33), [this, serial] {
            return stopping_ || paused_ || serial_ != serial;
          });
          if (stopping_) break;
        }
      } catch (const std::exception& error) {
        State("failed", error.what());
      } catch (...) {
        State("failed", "The native renderer stopped unexpectedly.");
      }
    }
  };
  std::shared_ptr<WorkerState> state_;
  RenderThread worker_;
 public:
  // owned_publish is only for sinks that retain all resources they access;
  // borrowed registrar/player pointers must use the default guarded path.
  NativeWorker(ContextFactory context, MilkRustImageDecoder decoder, AudioReader audio, Publish publish,
               bool owned_publish = false)
      : state_(std::make_shared<WorkerState>(std::move(context), std::move(decoder), std::move(audio), std::move(publish), owned_publish)),
        worker_([state=state_] { state->Run(); }) {}
  ~NativeWorker() { Stop(); }
  NativeWorker(const NativeWorker&) = delete;
  NativeWorker& operator=(const NativeWorker&) = delete;
  void Stop() { state_->Stop(); worker_.Join(); }
  void Load(const std::string& path, const std::string& root, double transition_seconds = 3) {
    state_->Load(path, root, transition_seconds);
  }
  void Resize(int width, int height) { state_->Resize(width, height); }
  void Pause(bool paused) { state_->Pause(paused); }
  void SetMouseState(bool down, double x, double y, double dx, double dy) {
    state_->SetMouseState(down, x, y, dx, dy);
  }
  NativeStatus Status() const { return state_->Status(); }
};
}  // namespace plezy::visualization
