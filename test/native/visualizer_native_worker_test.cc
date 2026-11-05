// SPDX-License-Identifier: AGPL-3.0-only
#include "../../shared/visualization/native_worker.h"
#include <iostream>

using namespace plezy::visualization;
namespace {
using Clock = std::chrono::steady_clock;
void Require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
struct Probe {
  std::mutex mutex;
  std::condition_variable condition;
  int created = 0, destroyed = 0, captures = 0, pauses = 0, resumes = 0;
  bool block_capture = false, block_pause = false, release = false, fail_capture = false;
  template<class Predicate> void Await(Predicate predicate) {
    std::unique_lock<std::mutex> lock(mutex);
    Require(condition.wait_for(lock, std::chrono::seconds(5), predicate), "Worker event timed out.");
  }
  void Release() {
    { std::lock_guard<std::mutex> lock(mutex); release = true; }
    condition.notify_all();
  }
};
class Backend final : public RenderBackend {
  std::shared_ptr<Probe> probe_;
 public:
  explicit Backend(std::shared_ptr<Probe> probe) : probe_(std::move(probe)) {
    std::lock_guard<std::mutex> lock(probe_->mutex); ++probe_->created; probe_->condition.notify_all();
  }
  ~Backend() override {
    std::lock_guard<std::mutex> lock(probe_->mutex); ++probe_->destroyed; probe_->condition.notify_all();
  }
  void Reset() override {}
  void Load(const std::string&, const std::string&, double) override {}
  void Pcm(const float*, size_t, uint32_t) override {}
  void Capture(uint32_t width, uint32_t height, double, std::vector<uint8_t>& rgba) override {
    std::unique_lock<std::mutex> lock(probe_->mutex);
    ++probe_->captures; probe_->condition.notify_all();
    probe_->condition.wait(lock, [&] { return !probe_->block_capture || probe_->release; });
    if (probe_->fail_capture) throw std::runtime_error("Original capture error.");
    rgba.assign(static_cast<size_t>(width) * height * 4, 127);
  }
  void Pause(bool paused) override {
    std::unique_lock<std::mutex> lock(probe_->mutex);
    if (paused) ++probe_->pauses; else ++probe_->resumes;
    probe_->condition.notify_all();
    if (paused) probe_->condition.wait(lock, [&] { return !probe_->block_pause || probe_->release; });
  }
};
std::unique_ptr<NativeWorker> Worker(const std::shared_ptr<Probe>& probe) {
  auto read = [sequence = uint64_t{0}](mpv_plezy_audio_block* block) mutable {
    block->frames = 1; block->channels = 2; block->sample_rate = 44100;
    block->seconds_per_frame = 1.0 / 44100; block->pts = sequence++ * block->seconds_per_frame;
    block->generation = 1; block->speaker_ids[0] = 0; block->speaker_ids[1] = 1;
    return 1;
  };
  auto worker = std::make_unique<NativeWorker>([probe] { return std::make_unique<Backend>(probe); },
      std::move(read), [](std::shared_ptr<const NativeFrame>) {});
  worker->Resize(1, 1);
  return worker;
}
void Start(NativeWorker& worker) { worker.Load("fixture.milk", "."); worker.Pause(false); }
void AwaitRetired(NativeWorker& worker) {
  const auto deadline = Clock::now() + std::chrono::seconds(5);
  while (!worker.Stop()) {
    Require(Clock::now() < deadline, "Quarantine did not retire.");
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
}
}
int main() {
  try {
    {
      RenderQuality quality(RenderBudget::Desktop());
      quality.Resize(3840, 2160);
      Require(quality.Size() == std::make_pair(1920, 1080), "Desktop render cap is incorrect.");
      auto now = RenderQuality::Clock::now();
      quality.ResetTiming(now);
      for (int window = 1; window <= 6; ++window) {
        now += std::chrono::seconds(2);
        for (int sample = 0; sample < 60; ++sample) quality.Observe(40, now);
      }
      Require(quality.Size() == std::make_pair(960, 540) && quality.FramesPerSecond() == 30,
          "Sustained render cost did not reduce scale and cadence.");
      for (int window = 0; window < 6; ++window) {
        now += std::chrono::seconds(11);
        for (int sample = 0; sample < 60; ++sample) quality.Observe(2, now);
      }
      Require(quality.Size() == std::make_pair(1920, 1080) && quality.FramesPerSecond() == 60,
          "Sustained headroom did not restore desktop quality.");
      RenderQuality constrained;
      constrained.Resize(3840, 2160);
      Require(constrained.Size() == std::make_pair(1280, 720) && constrained.FramesPerSecond() == 30,
          "Constrained hosts exceeded their budget.");
      // One compilation-like outlier must not reduce a healthy steady-state tier.
      constrained.ResetTiming(now);
      for (int sample = 0; sample < 60; ++sample) constrained.Observe(sample == 0 ? 1500 : 2, now + std::chrono::seconds(3));
      Require(constrained.Size() == std::make_pair(1280, 720), "A single outlier changed render quality.");
    }
    {
      auto probe = std::make_shared<Probe>(); auto worker = Worker(probe);
      worker->Load("fixture.milk", ".");
      Require(worker->PauseAndDrain(), "A hidden session must already be quiescent.");
      Require(worker->Stop(), "A hidden worker did not stop.");
      Require(probe->created == 0, "A hidden session created graphics resources.");
    }
    {
      auto probe = std::make_shared<Probe>(); auto worker = Worker(probe);
      worker->Pause(false); // No preset: do not create a context yet.
      Require(worker->PauseAndDrain(), "An empty session did not pause.");
      { std::lock_guard<std::mutex> lock(probe->mutex); Require(probe->created == 0, "An empty session created a context."); }
      Start(*worker); probe->Await([&] { return probe->captures > 0; });
      Require(worker->PauseAndDrain(), "A healthy renderer did not drain.");
      int captured;
      { std::lock_guard<std::mutex> lock(probe->mutex);
        Require(probe->pauses == 1, "Pause did not drain the backend exactly once."); captured = probe->captures; }
      Require(worker->PauseAndDrain(), "Repeated pause did not remain quiescent.");
      { std::lock_guard<std::mutex> lock(probe->mutex);
        Require(probe->pauses == 1 && probe->captures == captured, "Paused work continued."); }
      worker->Pause(false); probe->Await([&] { return probe->captures > captured; });
      Require(worker->PauseAndDrain() && worker->Stop(), "A resumed renderer did not retire.");
      Require(probe->created == 1 && probe->destroyed == 1 && probe->resumes == 2,
          "Pause/resume recreated or leaked the backend.");
    }
    for (bool capture : {false, true}) {
      auto probe = std::make_shared<Probe>();
      probe->block_capture = capture; probe->block_pause = !capture;
      auto worker = Worker(probe); Start(*worker);
      probe->Await([&] { return probe->captures > 0; });
      if (!capture) {
        worker->Pause(true);
        probe->Await([&] { return probe->pauses > 0; });
      }
      const auto start = Clock::now();
      Require(!worker->PauseAndDrain(std::chrono::milliseconds(50)), "A blocked GPU operation reported a clean pause.");
      Require(Clock::now() - start < std::chrono::seconds(2), "Pause exceeded its deadline.");
      Require(worker->Status().state == "failed", "A pause timeout was hidden.");
      Require(!worker->Stop(), "A blocked renderer reported retirement.");
      { std::lock_guard<std::mutex> lock(probe->mutex); Require(probe->destroyed == 0, "An active backend was destroyed."); }
      bool refused = false;
      try { auto next = Worker(probe); } catch (const std::runtime_error&) { refused = true; }
      Require(refused, "A quarantined renderer allowed a new session.");
      probe->Release(); AwaitRetired(*worker);
      Require(probe->destroyed == 1, "Retired renderer leaked its backend.");
    }
    {
      auto probe = std::make_shared<Probe>(); probe->fail_capture = true;
      auto worker = Worker(probe); Start(*worker);
      probe->Await([&] { return probe->destroyed == 1; });
      Require(!worker->PauseAndDrain(), "A failed renderer reported a healthy pause.");
      Require(worker->Status().reason == "Original capture error.", "Pause overwrote the original failure.");
      Require(worker->Stop(), "A failed renderer did not retire.");
    }
    std::cout << "Native worker lifecycle regressions passed\n";
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
