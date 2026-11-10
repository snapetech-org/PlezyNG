#include <flutter_linux/flutter_linux.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>

#include "mpv_player.h"

namespace mpv {
class MpvPlayerLifecycleTestPeer {
 public:
  static mpv_handle* Handle(MpvPlayer& player) { return player.mpv_; }
};
}  // namespace mpv

namespace {
void Check(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

class AudioFixture {
 public:
  AudioFixture() {
    char pattern[] = "/tmp/pleazyng-music-dual-core-XXXXXX";
    const int descriptor = mkstemp(pattern);
    Check(descriptor >= 0, "could not create PCM fixture");
    path = pattern;
    close(descriptor);
    std::ofstream output(path, std::ios::binary);
    auto write_number = [&output](uint32_t value, unsigned bytes) {
      for (unsigned byte = 0; byte < bytes; ++byte) output.put(static_cast<char>(value >> (8 * byte)));
    };
    constexpr uint32_t samples = 48000 * 8;
    output.write("RIFF", 4);
    write_number(36 + samples * 2, 4);
    output.write("WAVEfmt ", 8);
    write_number(16, 4);
    write_number(1, 2);
    write_number(1, 2);
    write_number(48000, 4);
    write_number(96000, 4);
    write_number(2, 2);
    write_number(16, 2);
    output.write("data", 4);
    write_number(samples * 2, 4);
    for (uint32_t sample = 0; sample < samples; ++sample) {
      const auto value = static_cast<int16_t>(8000 * std::sin(sample * 2 * 3.141592653589793 * 440 / 48000));
      write_number(static_cast<uint16_t>(value), 2);
    }
    output.close();
    Check(output.good(), "could not write PCM fixture");
  }

  ~AudioFixture() { unlink(path.c_str()); }
  std::string path;
};

double Property(mpv_handle* handle, const char* name) {
  double value = -1;
  if (mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) < 0) return -1;
  return value;
}

template <typename Predicate>
void Await(Predicate predicate, const char* message) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (std::chrono::steady_clock::now() < deadline) {
    while (g_main_context_iteration(nullptr, false)) {
    }
    if (predicate()) return;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  throw std::runtime_error(message);
}

void Open(mpv_handle* handle, const std::string& path, const char* volume) {
  Check(mpv_set_property_string(handle, "ao", "null") >= 0, "null audio output unavailable");
  Check(mpv_set_property_string(handle, "volume", volume) >= 0, "volume write failed");
  const char* command[] = {"loadfile", path.c_str(), nullptr};
  Check(mpv_command(handle, command) >= 0, "PCM source did not open");
  Check(mpv_set_property_string(handle, "pause", "no") >= 0, "unpause failed");
}
}  // namespace

int main() {
  try {
    // Disposal transfers ownership to a process-lifetime worker. Observe real
    // handle destruction rather than exiting while its Lua clients still run.
    const auto destroyed = std::make_shared<std::atomic<unsigned>>(0);
    mpv::NativeRenderTeardownOperations teardown;
    teardown.terminate_handle = [destroyed](mpv_handle* handle) {
      mpv_terminate_destroy(handle);
      destroyed->fetch_add(1, std::memory_order_release);
    };
    mpv::ConfigureNativeRenderTeardownQueueForTesting(std::move(teardown));
    AudioFixture fixture;
    mpv::MpvPlayer outgoing(true);
    mpv::MpvPlayer incoming(true);
    Check(outgoing.Initialize() && incoming.Initialize(), "audio-only initialization failed");
    auto* first = mpv::MpvPlayerLifecycleTestPeer::Handle(outgoing);
    auto* second = mpv::MpvPlayerLifecycleTestPeer::Handle(incoming);
    Check(first != second, "music decoders share a native handle");
    Open(first, fixture.path, "25");
    Open(second, fixture.path, "75");
    Await(
        [&]() { return Property(first, "time-pos") > 0.25 && Property(second, "time-pos") > 0.25; },
        "both music decoders must advance concurrently");
    Check(std::abs(Property(first, "volume") - 25) < 0.01, "outgoing volume changed across cores");
    Check(std::abs(Property(second, "volume") - 75) < 0.01, "incoming volume changed across cores");
    Check(mpv_set_property_string(first, "pause", "yes") >= 0, "outgoing pause failed");
    outgoing.Dispose();
    Await(
        [&]() { return destroyed->load(std::memory_order_acquire) == 1; },
        "outgoing native decoder did not finish teardown");
    const double incoming_position = Property(second, "time-pos");
    Await(
        [&]() { return Property(second, "time-pos") > incoming_position + 0.2; },
        "disposing the outgoing decoder stopped the incoming decoder");
    Check(incoming.IsInitialized(), "surviving music decoder lost initialization");
    incoming.Dispose();
    Await(
        [&]() { return destroyed->load(std::memory_order_acquire) == 2; },
        "incoming native decoder did not finish teardown");
    std::cout << "music_dual_core_test: PASS (null output; no acoustic/device qualification)\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "music_dual_core_test: " << error.what() << '\n';
    return 1;
  }
}
