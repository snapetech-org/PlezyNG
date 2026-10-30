// SPDX-License-Identifier: AGPL-3.0-only
// A real child process implements deliberate protocol faults without loading
// MilkRust or a GPU. Parent-side deadlines must survive each failure.
#include "../../shared/visualization/render_process.h"
#include <iostream>
#include <cstdlib>
#if defined(__linux__)
#include <sys/prctl.h>
#endif
using namespace plezy::visualization;
using namespace plezy::visualization::render_protocol;
namespace {
void Require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
template<typename F> void Reject(F action, const char* message) {
  bool rejected = false;
  try { action(); } catch (const std::exception&) { rejected = true; }
  Require(rejected, message);
}
[[noreturn]] void FakeHelper(RenderPipe::Handle handle) {
#if defined(__linux__)
  const auto parent = getppid();
  if (parent <= 1 || prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != parent) std::_Exit(2);
#endif
  try {
    RenderPipe pipe(handle);
#if !defined(_WIN32)
    std::thread([handle] {
      for (;;) {
        pollfd descriptor{handle, 0, 0};
        const int result = poll(&descriptor, 1, 250);
        if ((result > 0 && (descriptor.revents & (POLLHUP | POLLERR | POLLNVAL))) ||
            (result < 0 && errno != EINTR)) std::_Exit(0);
      }
    }).detach();
#endif
    std::string mode;
    for (;;) {
      const auto header = DecodeHeader(pipe.Read(kHeaderSize, RenderPipe::Deadline::max()));
      const auto payload = pipe.Read(header.size, RenderPipe::Deadline::max());
      Reader reader(payload);
      Bytes response; U32(response, 0);
      if (header.command == uint32_t(Command::Hello)) {
        const auto kind = reader.U32(); reader.End(); U32(response, kind); U32(response, kind == 0 ? MILKRUST_ABI_VERSION : 0);
      }
      if (header.command == uint32_t(Command::Load)) { mode = reader.Text(); reader.Text(); reader.Double(); reader.End(); }
      if (header.command == uint32_t(Command::Pcm)) {
        Require(reader.U32() == 7, "PCM generation changed");
        const auto frames = reader.U32(); Require(frames && frames <= kMaxPcmFrames, "PCM was not chunked");
        for (uint32_t i = 0; i < frames * 2; ++i) Require(reader.Float() == 0.25f, "PCM sample changed");
        reader.End();
      }
      if (header.command == uint32_t(Command::Mouse)) {
        Require(reader.U32() == 1 && reader.Double() == 0.25 && reader.Double() == 0.75 &&
            reader.Double() == -0.5 && reader.Double() == 0.5, "Pointer payload changed"); reader.End();
      }
      if (header.command == uint32_t(Command::Pause)) {
        Require(reader.U32() <= 1, "Pause payload changed"); reader.End();
        if (mode == "ack") response.push_back(1);
      }
      if (header.command == uint32_t(Command::Capture)) {
        if (mode == "hang") for (;;) std::this_thread::sleep_for(std::chrono::seconds(1));
        if (mode == "crash") std::_Exit(7);
        const auto width = reader.U32(), height = reader.U32(); reader.Double(); reader.End();
        response.resize(4 + FrameBytes(width, height), 79);
        if (mode == "short-frame") response.pop_back();
        if (mode == "oversized") {
          Bytes broken; U32(broken, kMagic); U32(broken, kVersion); U32(broken, header.command | kReply);
          U32(broken, header.sequence); U32(broken, kMaxMessage + 1);
          pipe.Write(broken, RenderPipe::Deadline::max()); continue;
        }
        if (mode == "truncated") {
          auto broken = EncodeHeader(header.command | kReply, header.sequence, response.size());
          broken.push_back(0); broken.push_back(0);
          pipe.Write(broken, RenderPipe::Deadline::max()); std::_Exit(8);
        }
      }
      const bool wrong = header.command == uint32_t(Command::Capture) && mode == "sequence";
      auto bytes = EncodeHeader(header.command | kReply, header.sequence + (wrong ? 1 : 0), response.size());
      bytes.insert(bytes.end(), response.begin(), response.end());
      pipe.Write(bytes, RenderPipe::Deadline::max());
    }
  } catch (...) { std::_Exit(3); }
}
std::unique_ptr<IsolatedRenderBackend> Client(Backend backend = Backend::MilkRust) {
  const auto deadline = RenderPipe::Clock::now() + std::chrono::seconds(5);
  for (;;) {
    try { return std::make_unique<IsolatedRenderBackend>(render_process_detail::ExecutablePath(), backend); }
    catch (const std::exception& error) {
      if (std::string(error.what()).find("still terminating") == std::string::npos || RenderPipe::Clock::now() >= deadline) throw;
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
  }
}
void ProtocolCases() {
  const Bytes expected{0x31, 0x52, 0x56, 0x50, 1, 0, 0, 0, 5, 0, 0, 0, 7, 0, 0, 0, 3, 0, 0, 0};
  Require(EncodeHeader(uint32_t(Command::Capture), 7, 3) == expected, "Header wire format changed");
  const auto header = DecodeHeader(expected);
  Require(header.command == 5 && header.sequence == 7 && header.size == 3, "Header decode differs");
  for (size_t length = 0; length < expected.size(); ++length)
    Reject([&] { DecodeHeader(Bytes(expected.begin(), expected.begin() + length)); }, "Truncated header accepted");
  auto invalid = expected; invalid[0] = 0;
  Reject([&] { DecodeHeader(invalid); }, "Foreign protocol accepted");
  invalid = expected; invalid[4] = 2;
  Reject([&] { DecodeHeader(invalid); }, "Wrong protocol version accepted");
  invalid = expected; invalid[8] = 8;
  Reject([&] { DecodeHeader(invalid); }, "Unknown command accepted");
  invalid = expected; invalid[12] = 0;
  Reject([&] { DecodeHeader(invalid); }, "Zero sequence accepted");
  invalid = expected; invalid[16] = 1; invalid[18] = 0x40;
  Reject([&] { DecodeHeader(invalid); }, "Oversized header accepted");
  Bytes values; U32(values, 0x87654321); Float(values, -0.0f); Double(values, 123.25); Text(values, "preset/texture");
  Reader reader(values);
  Require(reader.U32() == 0x87654321 && std::signbit(reader.Float()) && reader.Double() == 123.25 &&
      reader.Text() == "preset/texture", "Typed wire values changed"); reader.End();
  Reject([&] { Text(values, std::string(32769, 'a')); }, "Unbounded path accepted");
  Reject([&] { Text(values, std::string("a\0b", 3)); }, "NUL path accepted");
  Reject([&] { FrameBytes(0, 720); }, "Empty capture accepted");
  Reject([&] { FrameBytes(1281, 720); }, "Oversized capture accepted");
}
void ProcessCases() {
  {
    auto client = Client(); client->Reset(); client->Load("healthy", "fixture");
    std::vector<float> audio(20000, 0.25f); // Exercises multi-message PCM chunking.
    client->Pcm(audio.data(), audio.size() / 2, 7);
    client->SetMouseState(true, 0.25, 0.75, -0.5, 0.5);
    client->Pause(true); client->Pause(false);
    std::vector<uint8_t> frame; client->Capture(1280, 720, 0, frame);
    Require(frame.size() == 1280 * 720 * 4 && frame.front() == 79 && frame.back() == 79, "Frame payload changed");
    float invalid[]{std::numeric_limits<float>::infinity(), 0};
    Reject([&] { client->Pcm(invalid, 1, 7); }, "Non-finite PCM accepted");
    Reject([&] { client->Capture(1, 1, std::numeric_limits<double>::quiet_NaN(), frame); }, "Invalid render clock accepted");
    Reject([&] { client->SetMouseState(true, 1.1, 0, 0, 0); }, "Invalid pointer position accepted");
    Reject([&] { client->Load("healthy", "fixture", 10.1); }, "Unbounded transition accepted");
    client->Reset(); client->Load("healthy", "fixture"); client->Capture(2, 2, 0, frame);
    Require(frame.size() == 16, "Generation reset lost the helper");
  }
  for (const char* mode : {"hang", "crash", "oversized", "truncated", "sequence", "short-frame"}) {
    auto client = Client(); client->Reset(); client->Load(mode, "fixture");
    std::vector<uint8_t> frame;
    const auto started = RenderPipe::Clock::now();
    Reject([&] { client->Capture(2, 2, 0, frame); }, "Helper fault was accepted");
    Require(RenderPipe::Clock::now() - started < std::chrono::seconds(4), "Helper fault exceeded the parent deadline");
    Require(frame.empty(), "Invalid helper published a partial frame");
  }
  {
    auto client = Client(); client->Reset(); client->Load("hang", "fixture");
    const auto cancel = client->Cancellation();
    std::thread stop([cancel] { std::this_thread::sleep_for(std::chrono::milliseconds(40)); cancel(); });
    bool rejected = false; std::vector<uint8_t> frame;
    const auto started = RenderPipe::Clock::now();
    try { client->Capture(2, 2, 0, frame); } catch (const std::exception&) { rejected = true; }
    stop.join();
    Require(rejected && RenderPipe::Clock::now() - started < std::chrono::seconds(1), "Explicit cancellation waited for rendering");
  }
  {
    auto client = Client(); client->Reset(); client->Load("ack", "fixture");
    Reject([&] { client->Pause(false); }, "Malformed acknowledgement accepted");
    std::vector<uint8_t> frame;
    Reject([&] { client->Capture(1, 1, 0, frame); }, "Malformed helper remained usable");
  }
  {
    auto projectm = Client(Backend::ProjectM); projectm->Reset(); projectm->Load("healthy", "fixture", 3);
    std::vector<uint8_t> frame; projectm->Capture(2, 2, 0, frame);
    Require(frame.size() == 16, "projectM handshake changed");
  }
  auto recovered = Client(); recovered->Reset(); recovered->Load("healthy", "fixture");
}
}
int main(int argc, char** argv) {
  if (argc == 3 && std::string(argv[1]) == "--plezy-render-pipe") {
    uintptr_t value = 0;
    for (const auto* digit = argv[2]; *digit; ++digit) {
      if (*digit < '0' || *digit > '9' || value > (UINTPTR_MAX - (*digit - '0')) / 10) return 64;
      value = value * 10 + (*digit - '0');
    }
#if defined(_WIN32)
    FakeHelper(reinterpret_cast<HANDLE>(value));
#else
    if (value != 3) return 64;
    FakeHelper(3);
#endif
  }
  try {
    ProtocolCases(); ProcessCases();
    std::cout << "Isolated visualization protocol and process cases passed\n";
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
