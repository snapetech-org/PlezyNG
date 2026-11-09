// SPDX-License-Identifier: AGPL-3.0-only
#include "retro_api.h"
#include "retro_protocol.h"
#include "retro_sandbox.h"
#include "../../../shared/process/byte_pipe.h"
#include <array>
#include <cstdlib>
#include <thread>
#if defined(__linux__)
#include <sys/prctl.h>
#include <signal.h>
#endif
using namespace plezy::retro;
using plezy::process::BytePipe;

int main(int argc, char** argv) {
  try {
    Check(argc == 3 && std::string(argv[1]) == "--plezy-retro-pipe");
    char* end = nullptr; const auto raw = std::strtoull(argv[2], &end, 10);
    Check(end && !*end && raw);
#ifdef _WIN32
    const auto channel = reinterpret_cast<HANDLE>(static_cast<uintptr_t>(raw));
#else
    Check(raw == 3); const auto channel = static_cast<int>(raw);
#if defined(__linux__)
    const auto parent = getppid();
    Check(parent > 1 && prctl(PR_SET_PDEATHSIG, SIGKILL) == 0 && getppid() == parent);
#endif
#endif
    BytePipe pipe(channel);
    uint32_t sequence = 0; bool opened = false;
    for (;;) {
      const auto header = ReadHeader(pipe.Read(kHeaderSize, BytePipe::Deadline::max()));
      Check(!(header.command & kReply) && sequence != UINT32_MAX && header.sequence == ++sequence);
      const auto command = static_cast<Command>(header.command);
      const size_t maximum = command == Command::Restore ? kMaximumState + 8 :
        command == Command::Open ? 4 * (32768 + 4) : command == Command::Probe ? 32768 + 4 : 8;
      Check(header.size <= maximum);
      const auto payload = pipe.Read(header.size, BytePipe::Clock::now() + std::chrono::seconds(10));
      Reader reader(payload); Bytes reply; U32(reply, 0);
      try {
        Check(opened || command == Command::Open || command == Command::Probe);
        switch (command) {
          case Command::Probe: {
            Check(!opened && sequence == 1); const auto core = reader.Text(); reader.End();
            RestrictCore(core, "", "", "");
            U32(reply, plezy_retro_has_core(core.c_str())); break;
          }
          case Command::Open: {
            Check(!opened && sequence == 1);
            const auto core = reader.Text(), rom = reader.Text(), system = reader.Text(), saves = reader.Text(); reader.End();
            Check(!core.empty() && !rom.empty() && !system.empty() && !saves.empty());
            RestrictCore(core, rom, system, saves);
#ifndef _WIN32
            // Start only after entering Landlock so this thread inherits its
            // restrictions too. No privileged sibling thread survives dlopen.
            std::thread([channel] {
              for (;;) {
                pollfd fd{channel, 0, 0}; const int result = poll(&fd, 1, 250);
                if ((result > 0 && (fd.revents & (POLLHUP | POLLERR | POLLNVAL))) ||
                    (result < 0 && errno != EINTR)) std::_Exit(0);
              }
            }).detach();
#endif
            Check(plezy_retro_open(core.c_str(), rom.c_str(), system.c_str(), saves.c_str()) == 1);
            opened = true; const auto rate = plezy_retro_sample_rate(); const auto fps = plezy_retro_fps();
            Check(rate >= 8000 && rate <= 192000 && std::isfinite(fps) && fps >= 15 && fps <= 120);
            U32(reply, rate); Double(reply, fps); Text(reply, plezy_retro_identity(), 512); break;
          }
          case Command::Run: {
            reader.End(); plezy_retro_run(); Check(plezy_retro_healthy() == 1);
            const auto width = plezy_retro_width(), height = plezy_retro_height();
            const auto size = FrameSize(width, height); const auto pixels = plezy_retro_frame();
            Check(!size || pixels); const auto aspect = plezy_retro_aspect();
            Check(std::isfinite(aspect) && aspect >= 0 && aspect <= 8);
            std::array<int16_t, kMaximumSamples> pcm{};
            const auto count = plezy_retro_read_audio(pcm.data(), static_cast<int>(pcm.size()));
            Check(count >= 0 && count <= int(kMaximumSamples) && !(count % 2));
            U32(reply, width); U32(reply, height); Double(reply, aspect); U32(reply, static_cast<uint32_t>(size)); U32(reply, count);
            if (size) reply.insert(reply.end(), pixels, pixels + size);
            for (int n = 0; n < count; ++n) { const auto sample = uint16_t(pcm[n]); reply.push_back(sample & 255); reply.push_back(sample >> 8); }
            break;
          }
          case Command::Buttons: {
            const auto port = reader.U32(), buttons = reader.U32(); reader.End(); Check(port < 4 && buttons <= 65535);
            plezy_retro_buttons(port, buttons); break;
          }
          case Command::Pause: {
            const auto paused = reader.U32(); reader.End(); Check(paused <= 1); plezy_retro_pause_audio(paused); break;
          }
          case Command::Capture: {
            const auto kind = reader.U32(); reader.End(); Check(kind <= 2);
            const auto size = plezy_retro_capture(kind); Check(size >= 0 && size_t(size) <= kMaximumState);
            const auto bytes = plezy_retro_snapshot(); Check(!size || bytes); U32(reply, size);
            if (size) reply.insert(reply.end(), bytes, bytes + size); break;
          }
          case Command::Restore: {
            const auto kind = reader.U32(), size = reader.U32(); Check(kind <= 2 && size && size <= kMaximumState);
            const auto bytes = reader.Data(size); reader.End(); U32(reply, plezy_retro_restore(bytes.data(), size, kind)); break;
          }
          case Command::Close: reader.End(); plezy_retro_close(); opened = false; break;
        }
      } catch (...) { reply.clear(); U32(reply, 1); }
      auto out = HeaderBytes(header.command | kReply, header.sequence, reply.size());
      out.insert(out.end(), reply.begin(), reply.end());
      pipe.Write(out, BytePipe::Clock::now() + std::chrono::seconds(10));
      if (reply.front() || command == Command::Probe || command == Command::Close) std::_Exit(reply.front() ? 2 : 0);
    }
  } catch (...) { std::_Exit(2); }
}
