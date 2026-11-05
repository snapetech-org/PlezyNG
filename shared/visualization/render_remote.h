// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include "render_backend.h"
#include "render_pipe.h"

namespace plezy::visualization {
// Transport ownership is independent of desktop process spawning or mobile
// service binding. Retirement must never enter graphics or player code.
struct RenderConnection {
  std::unique_ptr<RenderPipe> pipe;
  std::function<void()> cancel, retire;
  RenderConnection(std::unique_ptr<RenderPipe> transport, std::function<void()> stop,
                   std::function<void()> cleanup)
      : pipe(std::move(transport)), cancel(std::move(stop)), retire(std::move(cleanup)) {}
  RenderConnection(RenderConnection&& other) noexcept
      : pipe(std::move(other.pipe)), cancel(std::move(other.cancel)), retire(std::move(other.retire)) {
    other.retire = {};
  }
  RenderConnection(const RenderConnection&) = delete;
  RenderConnection& operator=(const RenderConnection&) = delete;
  ~RenderConnection() { if (retire) { try { retire(); } catch (...) {} } }
};

class RemoteRenderBackend : public RenderBackend {
  RenderConnection connection_;
  bool present_ = false;
  uint32_t sequence_ = 0;
  render_protocol::Bytes Request(render_protocol::Command command, const render_protocol::Bytes& payload = {}) {
    using namespace render_protocol;
    if (sequence_ == UINT32_MAX) throw std::runtime_error("Visualization helper sequence exhausted.");
    const auto sequence = ++sequence_;
    try {
      const auto deadline = RenderPipe::Clock::now() + std::chrono::seconds(2);
      auto request = EncodeHeader(uint32_t(command), sequence, payload.size());
      request.insert(request.end(), payload.begin(), payload.end()); connection_.pipe->Write(request, deadline);
      const auto header = DecodeHeader(connection_.pipe->Read(kHeaderSize, deadline));
      if (header.command != (uint32_t(command) | kReply) || header.sequence != sequence)
        throw std::runtime_error("Visualization helper returned an obsolete response.");
      auto response = connection_.pipe->Read(header.size, deadline);
      Reader reader(response);
      const auto status = reader.U32();
      if (status) {
        if (status != 1) throw std::runtime_error("Invalid visualization helper response.");
        const auto error = reader.Text(8192); reader.End(); throw std::runtime_error(error);
      }
      response.erase(response.begin(), response.begin() + 4);
      return response;
    } catch (...) { connection_.cancel(); throw; }
  }
  void Acknowledge(render_protocol::Command command, const render_protocol::Bytes& payload = {}) {
    if (!Request(command, payload).empty()) {
      connection_.cancel(); throw std::runtime_error("Unexpected visualization helper response.");
    }
  }
 public:
  explicit RemoteRenderBackend(RenderConnection connection,
      render_protocol::Backend backend = render_protocol::Backend::MilkRust, bool present = false)
      : connection_(std::move(connection)), present_(present) {
    if (!connection_.pipe || !connection_.cancel) throw std::runtime_error("Incomplete visualization connection.");
    render_protocol::Bytes payload; render_protocol::U32(payload, uint32_t(backend));
    const auto response = Request(render_protocol::Command::Hello, payload);
    render_protocol::Reader reader(response);
    if (reader.U32() != uint32_t(backend) || reader.U32() != (backend == render_protocol::Backend::MilkRust ? MILKRUST_ABI_VERSION : 0))
      throw std::runtime_error("Visualization helper ABI does not match this app.");
    const auto features = reader.U32(); reader.End();
    if ((features & ~render_protocol::kCanPresent) || (present && !(features & render_protocol::kCanPresent)))
      throw std::runtime_error("Visualization helper cannot present to this surface.");
  }
  std::function<void()> Cancellation() const override { return connection_.cancel; }
  bool CanPresent() const override { return present_; }
  void Present(uint32_t width, uint32_t height, const std::vector<uint8_t>& rgba) override {
    if (!present_) return;
    if (rgba.size() != render_protocol::FrameBytes(width, height)) throw std::runtime_error("Invalid presentation frame.");
    render_protocol::Bytes payload; payload.reserve(rgba.size() + 8);
    render_protocol::U32(payload, width); render_protocol::U32(payload, height);
    payload.insert(payload.end(), rgba.begin(), rgba.end());
    Acknowledge(render_protocol::Command::Present, payload);
  }
  void Reset() override { Acknowledge(render_protocol::Command::Reset); }
  void Load(const std::string& path, const std::string& root, double transition = 0) override {
    if (!std::isfinite(transition) || transition < 0 || transition > 10) throw std::runtime_error("Invalid visualization transition duration.");
    render_protocol::Bytes payload; render_protocol::Text(payload, path); render_protocol::Text(payload, root);
    render_protocol::Double(payload, transition);
    Acknowledge(render_protocol::Command::Load, payload);
  }
  void Pause(bool paused) override {
    render_protocol::Bytes payload; render_protocol::U32(payload, paused ? 1 : 0);
    Acknowledge(render_protocol::Command::Pause, payload);
  }
  void SetMouseState(bool down, double x, double y, double dx, double dy) override {
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(dx) || !std::isfinite(dy) ||
        x < 0 || x > 1 || y < 0 || y > 1 || dx < -1 || dx > 1 || dy < -1 || dy > 1)
      throw std::runtime_error("Invalid isolated pointer input.");
    render_protocol::Bytes payload; render_protocol::U32(payload, down ? 1 : 0);
    for (const auto value : {x, y, dx, dy}) render_protocol::Double(payload, value);
    Acknowledge(render_protocol::Command::Mouse, payload);
  }
  void Pcm(const float* samples, size_t frames, uint32_t generation) override {
    if (!samples || !frames) throw std::runtime_error("Invalid helper PCM block.");
    for (size_t offset = 0; offset < frames;) {
      const auto count = std::min<size_t>(frames - offset, render_protocol::kMaxPcmFrames);
      render_protocol::Bytes payload; payload.reserve(8 + count * 8);
      render_protocol::U32(payload, generation); render_protocol::U32(payload, static_cast<uint32_t>(count));
      for (size_t i = 0; i < count * 2; ++i) {
        const auto value = samples[offset * 2 + i];
        if (!std::isfinite(value)) throw std::runtime_error("Non-finite visualization PCM.");
        render_protocol::Float(payload, value);
      }
      Acknowledge(render_protocol::Command::Pcm, payload);
      offset += count;
    }
  }
  void Capture(uint32_t width, uint32_t height, double seconds, std::vector<uint8_t>& rgba) override {
    const auto expected = render_protocol::FrameBytes(width, height);
    if (!std::isfinite(seconds) || seconds < 0) throw std::runtime_error("Invalid visualization render clock.");
    render_protocol::Bytes payload; render_protocol::U32(payload, width); render_protocol::U32(payload, height); render_protocol::Double(payload, seconds);
    auto frame = Request(render_protocol::Command::Capture, payload);
    if (frame.size() != expected) {
      connection_.cancel(); throw std::runtime_error("Visualization helper returned an invalid frame size.");
    }
    rgba = std::move(frame);
  }
};
}  // namespace plezy::visualization
