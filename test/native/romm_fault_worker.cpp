// SPDX-License-Identifier: AGPL-3.0-only
// Intentionally malicious protocol peer, used only by the native tests.
#include "../../native/games/romm/retro_protocol.h"
#include "../../shared/process/byte_pipe.h"
#include <fstream>
#include <thread>
#include <cstdlib>
using namespace plezy::retro;
using plezy::process::BytePipe;
int main(int argc, char** argv) {
  if (argc != 3) return 2;
  const auto raw = std::strtoull(argv[2], nullptr, 10);
#ifdef _WIN32
  BytePipe pipe(reinterpret_cast<HANDLE>(static_cast<uintptr_t>(raw)));
#else
  BytePipe pipe(static_cast<int>(raw));
#endif
  try {
    char mode = 'O';
    for (;;) {
      const auto header = ReadHeader(pipe.Read(kHeaderSize, BytePipe::Deadline::max()));
      const auto data = pipe.Read(header.size, BytePipe::Deadline::max()); Reader reader(data);
      Bytes reply; U32(reply, 0);
      if (header.command == uint32_t(Command::Open)) {
        reader.Text(); const auto rom = reader.Text(); std::ifstream(rom) >> mode;
        U32(reply, 48000); Double(reply, 60); Text(reply, "fault-peer");
      } else if (header.command == uint32_t(Command::Run)) {
        U32(reply, mode == 'R' ? 4096 : 2); U32(reply, 2);
        Double(reply, mode == 'N' ? std::numeric_limits<double>::quiet_NaN() : 1);
        U32(reply, 16); U32(reply, 0); reply.resize(reply.size() + 16);
      } else if (header.command == uint32_t(Command::Pause) && mode == 'I') U32(reply, 1);
      const bool run = header.command == uint32_t(Command::Run);
      auto out = HeaderBytes(header.command | kReply, header.sequence + (run && mode == 'Q' ? 1 : 0), reply.size());
      if (run && mode == 'A') { out.resize(16); U32(out, kMaximumMessage + 1); }
      if (run && mode == 'T') { out.push_back(0); pipe.Write(out, BytePipe::Deadline::max()); std::_Exit(0); }
      out.insert(out.end(), reply.begin(), reply.end());
      if (run && mode == 'L') {
        for (auto byte : out) { pipe.Write(Bytes{byte}, BytePipe::Deadline::max()); std::this_thread::sleep_for(std::chrono::milliseconds(250)); }
      } else pipe.Write(out, BytePipe::Deadline::max());
      if (header.command == uint32_t(Command::Close)) std::_Exit(0);
    }
  } catch (...) { return 2; }
}
