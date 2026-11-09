// SPDX-License-Identifier: AGPL-3.0-only
// The application loads only this proxy. dlopen of a core happens in a packaged
// worker, after entering its sandbox; all replies are bounded and validated.
#define PLEZY_RETRO_PROXY_BUILD
#include <mutex>

#if defined(__ANDROID__)
#include <filesystem>

#include "retro_android_process.h"
#else
#include "../../../shared/process/child_process.h"
#endif
#include "retro_api.h"
#include "retro_audio.h"
#include "retro_protocol.h"
#include "retro_windows_sandbox.h"
#ifdef PLEZY_RETRO_TEST_NO_AUDIO
#include <cstdio>
#endif
#if defined(_WIN32)
#define API extern "C" __declspec(dllexport)
#else
#include <dlfcn.h>
#define API extern "C" __attribute__((visibility("default")))
#endif
using namespace plezy::retro;
using plezy::process::BytePipe;
#if defined(__ANDROID__)
namespace child = plezy::retro::android_process;
#else
namespace child = plezy::process::child_detail;
#endif
namespace {
void Diagnostic(const std::exception& error) {
#ifdef PLEZY_RETRO_TEST_NO_AUDIO
  std::fprintf(stderr, "Isolated worker: %s\n", error.what());
#ifdef _WIN32
  std::fprintf(stderr, "Windows error: %lu\n", GetLastError());
#endif
#else
  (void)error;
#endif
}
std::recursive_mutex mutex;
std::shared_ptr<child::Control> retiring;
#if !defined(__ANDROID__)
std::filesystem::path Helper() {
#if defined(_WIN32)
  HMODULE library = nullptr;
  Check(
      GetModuleHandleExW(
          GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
          reinterpret_cast<LPCWSTR>(&plezy_retro_open), &library) != 0);
  std::vector<wchar_t> name(32768);
  const auto count = GetModuleFileNameW(library, name.data(), DWORD(name.size()));
  Check(count && count < name.size());
  const auto path = std::filesystem::path(std::wstring(name.data(), count)).parent_path() / L"plezy_retro_worker.exe";
#elif defined(__APPLE__)
  const auto path = child::ExecutablePath().parent_path() / "plezy_retro_worker";
#else
  Dl_info info{};
  Check(dladdr(reinterpret_cast<void*>(&plezy_retro_open), &info) != 0 && info.dli_fname);
  const auto path = std::filesystem::canonical(info.dli_fname).parent_path() / "plezy_retro_worker";
#endif
  Check(std::filesystem::is_regular_file(path) && !std::filesystem::is_symlink(path));
  return path;
}
#endif
class Session {
 public:
  std::shared_ptr<child::Control> control = std::make_shared<child::Control>();
  std::unique_ptr<BytePipe> pipe;
  std::unique_ptr<AudioOutput> audio;
  uint32_t sequence = 0, width = 0, height = 0;
  double fps = 60, aspect = 0;
  std::string identity, core, rom, system, saves;
  Bytes frame, snapshot;
  bool healthy = false;
  Session(const char* corePath, const char* romPath = "", const char* systemPath = "", const char* savesPath = "") {
    Check(corePath && romPath && systemPath && savesPath);
#if defined(__ANDROID__)
    core = corePath;  // Android's linker resolves only the allowlisted APK libraries.
#else
    core = std::filesystem::canonical(std::filesystem::u8path(corePath)).u8string();
#endif
    if (*romPath) rom = std::filesystem::canonical(std::filesystem::u8path(romPath)).u8string();
    if (*systemPath) system = std::filesystem::canonical(std::filesystem::u8path(systemPath)).u8string();
    if (*savesPath) saves = std::filesystem::canonical(std::filesystem::u8path(savesPath)).u8string();
    try {
#if defined(__ANDROID__)
      pipe = child::Spawn(core, rom, system, control);
      if (!rom.empty()) rom = "/rom/" + std::filesystem::u8path(rom).filename().u8string();
      system = "/system";
      saves = "/saves";
#elif defined(_WIN32)
      auto sandbox = std::make_shared<WindowsSandbox>(Helper(), std::filesystem::u8path(core), rom, system);
      control->resources = sandbox;
      core = sandbox->core.u8string();
      rom = sandbox->rom.u8string();
      system = sandbox->system.u8string();
      saves = sandbox->saves.u8string();
      pipe = child::Spawn(sandbox->helper, control, sandbox->Sid());
#else
      pipe = child::Spawn(Helper(), control);
#endif
    } catch (...) {
      child::Retire(control);
      retiring = control;
      throw;
    }
  }
  ~Session() {
    control->Abort();
    pipe.reset();
    child::Retire(control);
    retiring = control;
  }
  Bytes Request(Command command, const Bytes& body = {}, size_t maximum = 4, int seconds = 2) {
    try {
      Check(sequence != UINT32_MAX);
      const auto id = ++sequence;
      const auto deadline = BytePipe::Clock::now() + std::chrono::seconds(seconds);
      auto message = HeaderBytes(uint32_t(command), id, body.size());
      message.insert(message.end(), body.begin(), body.end());
      pipe->Write(message, deadline);
      const auto header = ReadHeader(pipe->Read(kHeaderSize, deadline));
      Check(
          header.command == (uint32_t(command) | kReply) && header.sequence == id && header.size >= 4 &&
          header.size <= maximum);
      auto response = pipe->Read(header.size, deadline);
      Reader reader(response);
      Check(reader.U32() == 0);
      response.erase(response.begin(), response.begin() + 4);
      return response;
    } catch (...) {
      healthy = false;
      control->Abort();
      throw;
    }
  }
  void Ack(Command command, const Bytes& body = {}) { Check(Request(command, body).empty()); }
};
std::unique_ptr<Session> session;
bool Reaped() {
  if (retiring && !retiring->Reaped()) return false;
  retiring.reset();
  return true;
}
void Stop() noexcept {
  if (!session) return;
  try {
    session->Ack(Command::Close);
  } catch (...) {
  }
  session.reset();
}
}  // namespace
API void* plezy_retro_alloc(int size) {
  return size > 0 && size_t(size) <= kMaximumState ? std::malloc(size) : nullptr;
}
API void plezy_retro_free(void* data) { std::free(data); }
API int plezy_retro_isolation_version() { return 1; }
API int plezy_retro_has_core(const char* path) {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  if (session || !Reaped()) return 0;
  try {
    Session probe(path);
    Bytes body;
    Text(body, probe.core);
    const auto result = probe.Request(Command::Probe, body, 8);
    Reader reader(result);
    const auto available = reader.U32();
    reader.End();
    Check(available <= 1);
    return available;
  } catch (const std::exception& error) {
    Diagnostic(error);
    return 0;
  } catch (...) {
    return 0;
  }
}
API int plezy_retro_open(const char* core, const char* rom, const char* system, const char* saves) {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  if (session || !Reaped()) return 0;
  try {
    session = std::make_unique<Session>(core, rom, system, saves);
    Bytes body;
    for (const auto& value : {session->core, session->rom, session->system, session->saves}) Text(body, value);
    const auto result = session->Request(Command::Open, body, 4 + 4 + 8 + 4 + 512, 10);
    Reader reader(result);
    const auto rate = reader.U32();
    session->fps = reader.Double();
    session->identity = reader.Text(512);
    reader.End();
    Check(rate >= 8000 && rate <= 192000 && std::isfinite(session->fps) && session->fps >= 15 && session->fps <= 120);
    session->audio = std::make_unique<AudioOutput>(rate);
    session->healthy = true;
    return 1;
  } catch (const std::exception& error) {
    Diagnostic(error);
    Stop();
    return 0;
  } catch (...) {
    Stop();
    return 0;
  }
}
API void plezy_retro_close() {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  Stop();
}
API int plezy_retro_shutdown_complete() {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  return !session && Reaped() ? 1 : 0;
}
API int plezy_retro_healthy() {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  return session && session->healthy ? 1 : 0;
}
API void plezy_retro_run() {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  if (!session || !session->healthy) return;
  try {
    const auto bytes =
        session->Request(Command::Run, {}, 4 + 24 + kMaximumDimension * kMaximumDimension * 4 + kMaximumSamples * 2);
    Reader reader(bytes);
    const auto width = reader.U32(), height = reader.U32();
    const auto aspect = reader.Double();
    const auto size = reader.U32(), samples = reader.U32();
    Check(
        size == FrameSize(width, height) && std::isfinite(aspect) && aspect >= 0 && aspect <= 8 &&
        samples <= kMaximumSamples && !(samples % 2));
    auto frame = reader.Data(size);
    auto audio = reader.Data(samples * 2);
    reader.End();
    session->width = width;
    session->height = height;
    session->aspect = aspect;
    session->frame = std::move(frame);
    session->audio->Push(audio);
  } catch (...) {
    session->healthy = false;
    session->control->Abort();
  }
}
API double plezy_retro_fps() {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  return session ? session->fps : 60;
}
API double plezy_retro_aspect() {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  return session ? session->aspect : 0;
}
API const char* plezy_retro_identity() {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  return session ? session->identity.c_str() : "";
}
API int plezy_retro_width() {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  return session ? session->width : 0;
}
API int plezy_retro_height() {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  return session ? session->height : 0;
}
API const uint8_t* plezy_retro_frame() {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  return session && !session->frame.empty() ? session->frame.data() : nullptr;
}
API void plezy_retro_buttons(int port, int buttons) {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  if (!session || !session->healthy || port < 0 || port >= 4 || buttons < 0 || buttons > 65535) return;
  try {
    Bytes body;
    U32(body, port);
    U32(body, buttons);
    session->Ack(Command::Buttons, body);
  } catch (...) {
    session->healthy = false;
    session->control->Abort();
  }
}
API void plezy_retro_pause_audio(int paused) {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  if (!session || !session->healthy) return;
  try {
    Bytes body;
    U32(body, paused ? 1 : 0);
    session->Ack(Command::Pause, body);
    session->audio->Pause(paused != 0);
  } catch (...) {
    session->healthy = false;
    session->control->Abort();
  }
}
API int plezy_retro_capture(int kind) {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  if (!session || !session->healthy || kind < 0 || kind > 2) return 0;
  try {
    Bytes body;
    U32(body, kind);
    const auto result = session->Request(Command::Capture, body, 8 + kMaximumState, 10);
    Reader reader(result);
    const auto size = reader.U32();
    Check(size <= kMaximumState);
    auto snapshot = reader.Data(size);
    reader.End();
    session->snapshot = std::move(snapshot);
    return size;
  } catch (...) {
    session->healthy = false;
    session->control->Abort();
    return 0;
  }
}
API const uint8_t* plezy_retro_snapshot() {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  return session && !session->snapshot.empty() ? session->snapshot.data() : nullptr;
}
API int plezy_retro_restore(const uint8_t* bytes, int size, int kind) {
  std::lock_guard<std::recursive_mutex> lock(mutex);
  if (!session || !session->healthy || !bytes || size <= 0 || size_t(size) > kMaximumState || kind < 0 || kind > 2)
    return 0;
  try {
    Bytes body;
    U32(body, kind);
    U32(body, size);
    body.insert(body.end(), bytes, bytes + size);
    const auto result = session->Request(Command::Restore, body, 8, 10);
    Reader reader(result);
    const auto success = reader.U32();
    reader.End();
    Check(success <= 1);
    return success;
  } catch (...) {
    session->healthy = false;
    session->control->Abort();
    return 0;
  }
}
