// SPDX-License-Identifier: GPL-3.0-or-later
#include "steam_vulkan_sink.h"

#include <deque>
#include <thread>
namespace plezy::steam {
struct VulkanSink::Impl {
  std::shared_ptr<Sink> fallback;
  Prepare prepare;
  Complete complete;
  Selected selected;
  std::function<void()> failed;
  std::mutex mutex;
  std::condition_variable changed;
  struct Frame {
    std::vector<uint8_t> bytes;
    uint32_t id;
  };
  std::deque<Frame> frames;
  std::vector<uint8_t> extra;
  int width = 0, height = 0;
  uint64_t epoch = 0;
  bool stopping = false, initialized = false, available = false;
  std::atomic<bool> pyro{false}, hdrSupported{false}, hdrActive{false};
  std::atomic<int> chroma{0};
  std::thread worker;
  Impl(
      std::shared_ptr<Sink> f, GpuWindow window, bool hdr, Prepare p, Complete c, Selected s,
      std::function<void()> failure)
      : fallback(std::move(f)),
        prepare(std::move(p)),
        complete(std::move(c)),
        selected(std::move(s)),
        failed(std::move(failure)) {
    worker = std::thread([this, window, hdr] {
      try {
        run(window, hdr);
      } catch (...) {
        {
          std::lock_guard<std::mutex> lock(mutex);
          available = false;
          initialized = true;
          stopping = true;
          frames.clear();
        }
        changed.notify_all();
        // Runtime cancellation settles every remaining frame ticket.
        try {
          failed();
        } catch (...) {
        }
      }
    });
  }
  ~Impl() { close(); }
  void close() {
    {
      std::lock_guard<std::mutex> lock(mutex);
      stopping = true;
    }
    changed.notify_all();
    if (worker.joinable()) worker.join();
  }
  void run(GpuWindow window, bool hdr) {
    VulkanPresenter renderer;
    const bool opened = renderer.open(window, hdr);
    {
      std::lock_guard<std::mutex> lock(mutex);
      available = opened;
      initialized = true;
      hdrSupported = opened && renderer.supportsHdr10();
    }
    changed.notify_all();
    if (!opened) return;
    uint64_t configured = 0;
    int w = 0, h = 0;
    for (;;) {
      Frame frame;
      std::vector<uint8_t> config;
      uint64_t revision;
      {
        std::unique_lock<std::mutex> lock(mutex);
        changed.wait(lock, [&] { return stopping || !frames.empty(); });
        if (stopping) break;
        frame = std::move(frames.front());
        frames.pop_front();
        revision = epoch;
        if (configured != revision) {
          config = extra;
          w = width;
          h = height;
        }
      }
      bool valid = configured == revision || renderer.configure(w, h, config.data(), config.size());
      configured = revision;
      PyrowaveFrameInfo info;
      valid = valid && parsePyrowaveFrame(frame.bytes.data(), frame.bytes.size(), w, h, info, true, hdrSupported);
      Target target;
      if (valid) target = prepare(info);
      valid = valid && target.valid;
      auto result = PyrowaveDecodeStatus::pending;
      if (valid && target.permitted) {
        result = renderer.present(frame.bytes.data(), frame.bytes.size(), target.width, target.height);
        valid = result != PyrowaveDecodeStatus::invalid;
        if (result == PyrowaveDecodeStatus::frame) {
          hdrActive = renderer.hdr10Active();
          chroma = info.chroma444 ? 2 : 1;
        }
      }
      complete(frame.id, w, h, valid && result == PyrowaveDecodeStatus::frame, target.permitted);
      if (!valid) {
        failed();
        break;
      }
    }
    std::deque<Frame> abandoned;
    {
      std::lock_guard<std::mutex> lock(mutex);
      available = false;
      stopping = true;
      abandoned.swap(frames);
    }
    for (auto& frame : abandoned) complete(frame.id, w, h, false, false);
  }
};
VulkanSink::VulkanSink(
    std::shared_ptr<Sink> fallback, GpuWindow window, bool hdr, Prepare p, Complete c, Selected s,
    std::function<void()> failed)
    : impl_(std::make_unique<Impl>(
          std::move(fallback), window, hdr, std::move(p), std::move(c), std::move(s), std::move(failed))) {}
VulkanSink::~VulkanSink() = default;
bool VulkanSink::ready() {
  std::unique_lock<std::mutex> lock(impl_->mutex);
  return impl_->changed.wait_for(lock, std::chrono::seconds(5), [&] { return impl_->initialized; }) && impl_->available;
}
bool VulkanSink::supportsHdr10() const { return impl_->hdrSupported; }
bool VulkanSink::hdr10Active() const { return impl_->hdrActive; }
int VulkanSink::chromaFormat() const { return impl_->chroma; }
bool VulkanSink::video(int codec, int width, int height, const uint8_t* bytes, size_t length) {
  const bool pyro = codec == 9;
  impl_->selected(pyro);
  impl_->pyro = pyro;
  if (!pyro) return impl_->fallback->video(codec, width, height, bytes, length);
  if (width < 2 || height < 2 || width > 1920 || height > 1080 || (width & 1) || (height & 1) || length > 65536 ||
      (length && !bytes))
    return false;
  std::deque<Impl::Frame> abandoned;
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->available || impl_->stopping) return false;
    impl_->width = width;
    impl_->height = height;
    ++impl_->epoch;
    impl_->extra.clear();
    if (length) impl_->extra.assign(bytes, bytes + length);
    abandoned.swap(impl_->frames);
  }
  for (auto& frame : abandoned) impl_->complete(frame.id, width, height, false, false);
  return true;
}
bool VulkanSink::frame(const uint8_t* bytes, size_t length, uint32_t id, bool key) {
  if (!impl_->pyro) return impl_->fallback->frame(bytes, length, id, key);
  if (!bytes || !length || length > 2 * 1024 * 1024) return false;
  std::lock_guard<std::mutex> lock(impl_->mutex);
  if (impl_->stopping || !impl_->available || impl_->frames.size() >= 4) return false;
  impl_->frames.push_back({std::vector<uint8_t>(bytes, bytes + length), id});
  impl_->changed.notify_all();
  return true;
}
bool VulkanSink::audio(int channels, int rate) { return impl_->fallback->audio(channels, rate); }
void VulkanSink::samples(const int16_t* data, size_t count) { impl_->fallback->samples(data, count); }
void VulkanSink::audioUnavailable() { impl_->fallback->audioUnavailable(); }
void VulkanSink::close() { impl_->close(); }
}  // namespace plezy::steam
