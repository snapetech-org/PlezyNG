// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include "render_backend.h"
#include "render_pipe.h"
#include <cstdlib>
#if defined(__linux__) && !defined(__ANDROID__)
#include <csignal>
#include <sys/prctl.h>
#endif

namespace plezy::visualization {
// This entry point runs only in the packaged helper executable. On channel
// closure or protocol failure, exit the process without invoking a potentially
// stuck graphics destructor. The parent also enforces a per-request deadline.
[[noreturn]] inline void RunRenderHelper(RenderPipe::Handle channel,
    const std::function<std::unique_ptr<RenderBackend>(render_protocol::Backend)>& create) {
  using namespace render_protocol;
  try {
#if defined(__linux__) && !defined(__ANDROID__)
    const auto parent = getppid();
    if (parent <= 1 || prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != parent) std::_Exit(2);
#endif
    RenderPipe pipe(channel);
#if !defined(_WIN32)
    // macOS has no Linux parent-death signal. Monitor the dedicated socket,
    // independently of the thread which may be inside a graphics driver.
    std::thread([channel] {
      for (;;) {
        pollfd descriptor{channel, 0, 0};
        const int result = poll(&descriptor, 1, 250);
        if ((result > 0 && (descriptor.revents & (POLLHUP | POLLERR | POLLNVAL))) ||
            (result < 0 && errno != EINTR)) std::_Exit(0);
      }
    }).detach();
#endif
    // The process owns this object until _Exit. Do not unwind into a driver
    // destructor when the protocol fails or the parent closes the channel.
    RenderBackend* engine = nullptr;
    bool hello = false, loaded = false;
    uint32_t previous = 0;
    for (;;) {
      const auto header = DecodeHeader(pipe.Read(kHeaderSize, RenderPipe::Deadline::max()));
      if ((header.command & kReply) || previous == UINT32_MAX || header.sequence != previous + 1 ||
          header.size > (header.command == uint32_t(Command::Present) ? kMaxWidth * kMaxHeight * 4 + 8 : 2 * 32768 + 16)) std::_Exit(2);
      previous = header.sequence;
      const auto payload = pipe.Read(header.size, RenderPipe::Clock::now() + std::chrono::seconds(2));
      Reader reader(payload);
      Bytes response;
      bool failed = false;
      try {
        const auto command = static_cast<Command>(header.command);
        if (command != Command::Hello && !hello) throw std::runtime_error("Visualization handshake required.");
        switch (command) {
          case Command::Hello: {
            const auto kind = reader.U32();
            reader.End();
            if (hello) throw std::runtime_error("Visualization helper was already initialized.");
            if (kind > uint32_t(Backend::ProjectM)) throw std::runtime_error("Unknown isolated visualization backend.");
            if (kind == uint32_t(Backend::MilkRust) && !MilkRustApi::Shared().error.empty())
              throw std::runtime_error(MilkRustApi::Shared().error);
            engine = create(static_cast<Backend>(kind)).release();
            if (!engine) throw std::runtime_error("Could not create the isolated visualization renderer.");
            hello = true; U32(response, kind); U32(response, kind == uint32_t(Backend::MilkRust) ? MILKRUST_ABI_VERSION : 0);
            U32(response, engine->CanPresent() ? kCanPresent : 0); break;
          }
          case Command::Reset:
            reader.End();
            engine->Reset(); loaded = false; break;
          case Command::Load: {
            const auto path = reader.Text(), root = reader.Text(); const auto transition = reader.Double(); reader.End();
            if (!engine || path.empty() || root.empty() || !std::isfinite(transition) || transition < 0 || transition > 10)
              throw std::runtime_error("Invalid isolated preset load.");
            engine->Load(path, root, transition); loaded = true; break;
          }
          case Command::Pcm: {
            const auto generation = reader.U32(), frames = reader.U32();
            if (!loaded || !frames || frames > kMaxPcmFrames || payload.size() != 8 + size_t(frames) * 8)
              throw std::runtime_error("Invalid isolated PCM payload.");
            std::vector<float> stereo(size_t(frames) * 2);
            for (auto& value : stereo) {
              value = reader.Float();
              if (!std::isfinite(value)) throw std::runtime_error("Non-finite isolated PCM sample.");
            }
            reader.End(); engine->Pcm(stereo.data(), frames, generation); break;
          }
          case Command::Capture: {
            const auto width = reader.U32(), height = reader.U32(); const auto seconds = reader.Double(); reader.End();
            const auto expected = FrameBytes(width, height);
            if (!loaded || !std::isfinite(seconds) || seconds < 0) throw std::runtime_error("Invalid isolated capture request.");
            engine->Capture(width, height, seconds, response);
            if (response.size() != expected) throw std::runtime_error("Isolated renderer returned an invalid pixel count.");
            break;
          }
          case Command::Present: {
            const auto width = reader.U32(), height = reader.U32();
            const auto expected = FrameBytes(width, height);
            if (!loaded || !engine->CanPresent() || payload.size() != expected + 8)
              throw std::runtime_error("Invalid isolated presentation request.");
            const Bytes rgba(payload.begin() + 8, payload.end());
            engine->Present(width, height, rgba); break;
          }
          case Command::Mouse: {
            const auto down = reader.U32();
            const auto x = reader.Double(), y = reader.Double(), dx = reader.Double(), dy = reader.Double(); reader.End();
            if (!loaded || down > 1 || !std::isfinite(x) || !std::isfinite(y) || !std::isfinite(dx) || !std::isfinite(dy) ||
                x < 0 || x > 1 || y < 0 || y > 1 || dx < -1 || dx > 1 || dy < -1 || dy > 1)
              throw std::runtime_error("Invalid isolated pointer input.");
            engine->SetMouseState(down != 0, x, y, dx, dy); break;
          }
          case Command::Pause: {
            const auto paused = reader.U32(); reader.End();
            if (paused > 1) throw std::runtime_error("Invalid isolated pause request.");
            engine->Pause(paused != 0); break;
          }
        }
        response.insert(response.begin(), 4, 0); // Success status precedes the typed result.
      } catch (const std::exception& error) {
        response.clear(); U32(response, 1);
        std::string message = error.what(); if (message.size() > 8192) message.resize(8192);
        Text(response, message, 8192); failed = true;
      } catch (...) {
        response.clear(); U32(response, 1); Text(response, "The isolated visualization renderer failed."); failed = true;
      }
      auto bytes = EncodeHeader(header.command | kReply, header.sequence, response.size());
      bytes.insert(bytes.end(), response.begin(), response.end());
      pipe.Write(bytes, RenderPipe::Clock::now() + std::chrono::seconds(2));
      if (failed) std::_Exit(2);
    }
  } catch (...) { std::_Exit(2); }
}
}  // namespace plezy::visualization
