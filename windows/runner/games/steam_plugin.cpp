// SPDX-License-Identifier: GPL-3.0-or-later
// Winsock must precede Flutter's Windows headers.
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>

// Keep Winsock2 before all dependent Windows SDK and Flutter headers.
#include <bcrypt.h>
#include <dxgi1_6.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>
#include <wincred.h>
#include <windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <deque>
#include <map>
#include <stdexcept>
#include <thread>

#include "SteamWindowsSink.h"
#include "steam_input.h"
#include "steam_plugin.h"
#include "steam_vulkan_sink.h"

using namespace plezy::steam;
namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Call = flutter::MethodCall<Value>;
using Reply = std::shared_ptr<flutter::MethodResult<Value>>;
using Channel = flutter::MethodChannel<Value>;
const Value* field(const Value* value, const char* key) {
  auto* map = value ? std::get_if<Map>(value) : nullptr;
  if (!map || map->size() > 64) return nullptr;
  auto it = map->find(Value(key));
  return it == map->end() ? nullptr : &it->second;
}
std::string text(const Value* args, const char* key) {
  const auto* value = field(args, key);
  auto* string = value ? std::get_if<std::string>(value) : nullptr;
  if (!string || string->size() > 256 || string->find('\0') != std::string::npos)
    throw std::invalid_argument("Invalid argument");
  return *string;
}
uint64_t identifier(const std::string& value, bool zero = false) {
  if (value.empty() || value.size() > 20 || value.find_first_not_of("0123456789") != std::string::npos)
    throw std::invalid_argument("Invalid identifier");
  const auto id = std::stoull(value);
  if (!zero && !id) throw std::invalid_argument("Invalid identifier");
  return id;
}
int64_t integer(const Value& value) {
  if (const auto* n = std::get_if<int32_t>(&value)) return *n;
  if (const auto* n = std::get_if<int64_t>(&value)) return *n;
  throw std::invalid_argument("Invalid integer");
}
int number(const Value* args, const char* key, int fallback, int low, int high) {
  auto* value = field(args, key);
  if (!value) return fallback;
  auto n = integer(*value);
  if (n < low || n > high) throw std::invalid_argument("Invalid limit");
  return int(n);
}
bool boolean(const Value* args, const char* key, bool fallback = false) {
  auto* value = field(args, key);
  if (!value) return fallback;
  auto* result = std::get_if<bool>(value);
  if (!result) throw std::invalid_argument("Invalid boolean");
  return *result;
}
double real(const Value* args, const char* key) {
  auto* value = field(args, key);
  auto* n = value ? std::get_if<double>(value) : nullptr;
  if (!n || !std::isfinite(*n)) throw std::invalid_argument("Invalid coordinate");
  return *n;
}
Host hostFrom(const Value* args) {
  Host host{text(args, "address"), uint16_t(number(args, "port", 27036, 1, 65535)), identifier(text(args, "hostId"))};
  for (int i = 0; i < 6; ++i) host.relayPorts[i] = number(args, ("relayPort" + std::to_string(i)).c_str(), 0, 1, 65535);
  if (!host.validRelay()) throw std::invalid_argument("Invalid relay route");
  return host;
}
void error(const Reply& reply, const char* code = "UNAVAILABLE") { reply->Error(code, "Steam connection unavailable"); }
std::wstring credentialName(uint64_t id) { return L"PlezyNG/Steam/" + std::to_wstring(id); }
void loadTrust(uint64_t id, Credentials& out) {
  PCREDENTIALW stored = nullptr;
  if (!CredReadW(credentialName(id).c_str(), CRED_TYPE_GENERIC, 0, &stored))
    throw std::runtime_error("Pairing required");
  const bool valid = stored->CredentialBlobSize == 48 && stored->CredentialBlob;
  if (valid) {
    out.device = out.user = 0;
    for (int i = 0; i < 8; ++i) {
      out.device |= uint64_t(stored->CredentialBlob[i]) << (8 * i);
      out.user |= uint64_t(stored->CredentialBlob[8 + i]) << (8 * i);
    }
    std::copy_n(stored->CredentialBlob + 16, 32, out.key.data());
    SecureZeroMemory(stored->CredentialBlob, stored->CredentialBlobSize);
  }
  CredFree(stored);
  if (!valid || !out.device || !out.user) throw std::runtime_error("Pairing required");
}
bool saveTrust(uint64_t id, const Credentials& credentials) {
  std::array<uint8_t, 48> bytes{};
  for (int i = 0; i < 8; ++i) {
    bytes[i] = uint8_t(credentials.device >> (8 * i));
    bytes[8 + i] = uint8_t(credentials.user >> (8 * i));
  }
  std::copy(credentials.key.begin(), credentials.key.end(), bytes.begin() + 16);
  auto name = credentialName(id);
  CREDENTIALW record{};
  record.Type = CRED_TYPE_GENERIC;
  record.TargetName = name.data();
  record.Persist = CRED_PERSIST_LOCAL_MACHINE;
  record.CredentialBlob = bytes.data();
  record.CredentialBlobSize = DWORD(bytes.size());
  const bool saved = CredWriteW(&record, 0) != 0;
  SecureZeroMemory(bytes.data(), bytes.size());
  return saved;
}
bool forgetTrust(uint64_t id) {
  return CredDeleteW(credentialName(id).c_str(), CRED_TYPE_GENERIC, 0) || GetLastError() == ERROR_NOT_FOUND;
}
void randomBytes(uint8_t* bytes, size_t length) {
  if (BCryptGenRandom(nullptr, bytes, ULONG(length), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0)
    throw std::runtime_error("No entropy");
}
struct SocketScope {
  bool ready;
  SocketScope() {
    WSADATA data;
    ready = WSAStartup(MAKEWORD(2, 2), &data) == 0;
  }
  ~SocketScope() {
    if (ready) WSACleanup();
  }
};
Host resolve(Host host, const std::atomic<bool>& cancel) {
  SocketScope sockets;
  if (!sockets.ready || cancel) throw std::runtime_error("Cancelled");
  // These APIs are absent from some cross-SDK headers. Resolve their documented
  // signatures from the OS module; never substitute an uncancellable DNS call.
  using CancelLookup = INT(WSAAPI*)(LPHANDLE);
  using LookupResult = INT(WSAAPI*)(LPOVERLAPPED);
  const auto module = GetModuleHandleW(L"ws2_32.dll");
  const auto cancelAddress = GetProcAddress(module, "GetAddrInfoExCancel");
  const auto resultAddress = GetProcAddress(module, "GetAddrInfoExOverlappedResult");
  CancelLookup cancelLookup = nullptr;
  LookupResult lookupResult = nullptr;
  static_assert(sizeof(cancelLookup) == sizeof(cancelAddress));
  std::memcpy(&cancelLookup, &cancelAddress, sizeof(cancelLookup));
  std::memcpy(&lookupResult, &resultAddress, sizeof(lookupResult));
  if (!cancelLookup || !lookupResult) throw std::runtime_error("Resolution unavailable");
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, host.address.c_str(), -1, nullptr, 0);
  if (count < 2 || count > 257) throw std::runtime_error("Invalid address");
  std::wstring name(size_t(count), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, host.address.c_str(), -1, name.data(), count);
  ADDRINFOEXW hints{};
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_DGRAM;
  PADDRINFOEXW addresses = nullptr;
  HANDLE request = nullptr;
  OVERLAPPED overlapped{};
  overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!overlapped.hEvent) throw std::runtime_error("Resolution unavailable");
  const auto started = std::chrono::steady_clock::now();
  int status = GetAddrInfoExW(
      name.c_str(), nullptr, NS_DNS, nullptr, &hints, &addresses, nullptr, &overlapped, nullptr, &request);
  if (status == WSA_IO_PENDING) {
    while (WaitForSingleObject(overlapped.hEvent, 100) == WAIT_TIMEOUT) {
      if (cancel || std::chrono::steady_clock::now() - started > std::chrono::seconds(10)) {
        cancelLookup(&request);
        WaitForSingleObject(overlapped.hEvent, INFINITE);
        break;
      }
    }
    status = lookupResult(&overlapped);
  }
  CloseHandle(overlapped.hEvent);
  std::string selected;
  if (!status && !cancel)
    for (auto* item = addresses; item; item = item->ai_next) {
      if (item->ai_family != AF_INET || item->ai_addrlen != sizeof(sockaddr_in)) continue;
      const auto* address = reinterpret_cast<const sockaddr_in*>(item->ai_addr);
      const uint32_t ip = ntohl(address->sin_addr.s_addr);
      if (!ip || ip == UINT32_MAX || (ip >> 28) >= 14) continue;
      char buffer[INET_ADDRSTRLEN];
      if (InetNtopA(AF_INET, const_cast<IN_ADDR*>(&address->sin_addr), buffer, sizeof(buffer))) {
        selected = buffer;
        break;
      }
    }
  if (addresses) FreeAddrInfoExW(addresses);
  if (selected.empty()) throw std::runtime_error("Resolution failed");
  host.address = selected;
  return host;
}
constexpr UINT taskMessage = WM_APP + 0x04D3;
struct MainQueue {
  HWND window;
  std::mutex mutex;
  std::deque<std::function<void()>> tasks;
  bool closed = false;
  explicit MainQueue(HWND hwnd) : window(hwnd) {}
  void post(std::function<void()> action) {
    std::lock_guard<std::mutex> lock(mutex);
    if (closed) return;
    tasks.push_back(std::move(action));
    PostMessageW(window, taskMessage, 0, 0);
  }
  void drain() {
    std::deque<std::function<void()>> copy;
    {
      std::lock_guard<std::mutex> lock(mutex);
      copy.swap(tasks);
    }
    for (auto& action : copy) action();
  }
};
struct Manager;
// Query the actual output mode, not just the panel's advertised capabilities.
// No Windows HDR setting is changed by the receiver.
bool hdrOutput(HWND window) {
  using Microsoft::WRL::ComPtr;
  ComPtr<IDXGIFactory1> factory;
  if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return false;
  const auto monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  for (UINT a = 0;; ++a) {
    ComPtr<IDXGIAdapter1> adapter;
    if (factory->EnumAdapters1(a, &adapter) != S_OK) break;
    for (UINT o = 0;; ++o) {
      ComPtr<IDXGIOutput> output;
      if (adapter->EnumOutputs(o, &output) != S_OK) break;
      DXGI_OUTPUT_DESC desc{};
      if (FAILED(output->GetDesc(&desc)) || desc.Monitor != monitor) continue;
      ComPtr<IDXGIOutput6> output6;
      DXGI_OUTPUT_DESC1 current{};
      return SUCCEEDED(output.As(&output6)) && SUCCEEDED(output6->GetDesc1(&current)) && current.BitsPerColor >= 10 &&
             current.ColorSpace == DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020;
    }
  }
  return false;
}
struct Session : std::enable_shared_from_this<Session> {
  std::weak_ptr<Manager> owner;
  std::shared_ptr<MainQueue> main;
  flutter::TextureRegistrar* registrar;
  uint64_t id;
  Host host;
  uint64_t game;
  StreamOptions options;
  bool hevc, pyrowave, audible = false;
  HWND plane = nullptr;
  bool nativeActive = false;
  std::atomic<uint64_t> planeSize{0};
  std::atomic<bool> planeVisible{false};
  InputState input;
  std::unique_ptr<Channel> channel;
  std::unique_ptr<flutter::TextureVariant> texture;
  int64_t textureId = -1;
  FlutterDesktopPixelBuffer buffer{};
  std::vector<uint8_t> output = std::vector<uint8_t>(1920 * 1080 * 4);
  struct Pixels {
    DecodedPixels data;
    std::weak_ptr<Runtime> source;
  };
  std::mutex pixelMutex;
  std::unique_ptr<Pixels> pendingPixels;
  std::thread worker, joiner;
  std::mutex mutex;
  std::shared_ptr<Runtime> runtime;
  std::shared_ptr<WindowsSink> sink;
  std::shared_ptr<VulkanSink> gpuSink;
  std::atomic<bool> closing{false}, active{false};
  std::atomic<uint64_t> renderedEpoch{0}, renderedSize{0};
  std::vector<Reply> stopReplies;
  std::string state = "connecting";
  Session(
      uint64_t n, Host h, uint64_t g, StreamOptions o, bool codec, bool pyro, flutter::PluginRegistrarWindows* plugin,
      std::shared_ptr<MainQueue> queue)
      : main(std::move(queue)),
        registrar(plugin->texture_registrar()),
        id(n),
        host(std::move(h)),
        game(g),
        options(o),
        hevc(codec),
        pyrowave(pyro),
        input(o.controllerCount) {
    channel = std::make_unique<Channel>(
        plugin->messenger(), "com.plezy/games/steam_stream/" + std::to_string(id),
        &flutter::StandardMethodCodec::GetInstance());
    buffer.buffer = output.data();
    buffer.width = buffer.height = 1;
    if (pyrowave) {
      // Match the existing mpv child-plane placement. Flutter's DComp visual
      // remains above this input-transparent window, including all controls.
      plane = CreateWindowExW(
          WS_EX_NOPARENTNOTIFY, L"STATIC", L"", WS_CHILD | WS_DISABLED | WS_CLIPSIBLINGS, 0, 0, 1, 1,
          plugin->GetView()->GetNativeWindow(), nullptr, GetModuleHandleW(nullptr), nullptr);
      pyrowave = plane != nullptr;
    }
    options.hdr10 = options.hdr10 && plane && hdrOutput(plane);
  }
  ~Session() {
    if (joiner.joinable()) joiner.join();
    if (worker.joinable()) worker.join();
    if (pendingPixels)
      if (auto r = pendingPixels->source.lock()) r->frameComplete(pendingPixels->data.id, false);
    if (plane) DestroyWindow(plane);
  }
  void setState(const char* value) {
    if (closing || state == value) return;
    state = value;
    channel->InvokeMethod("sessionState", std::make_unique<Value>(state));
  }
  void notifyState(const char* value) {
    main->post([weak = weak_from_this(), value] {
      if (auto self = weak.lock()) self->setState(value);
    });
  }
  void setNative(bool selected) {
    nativeActive = selected && plane && !closing;
    planeVisible = nativeActive && planeSize != 0;
    if (plane) ShowWindow(plane, planeVisible ? SW_SHOWNOACTIVATE : SW_HIDE);
    channel->InvokeMethod("nativePresentation", std::make_unique<Value>(nativeActive));
  }
  void completeGpu(std::weak_ptr<Runtime> source, uint32_t frame, int w, int h, bool shown, bool prepared) {
    auto r = source.lock();
    if (!r) return;
    const bool displayed = shown && prepared && active && !closing && planeVisible;
    r->frameComplete(frame, displayed);
    if (!displayed) return;
    const uint64_t size = (uint64_t(w) << 32) | uint32_t(h);
    const bool first = renderedEpoch.exchange(r->metrics().epoch) != r->metrics().epoch;
    if (renderedSize.exchange(size) == size && !first) return;
    main->post([weak = weak_from_this(), source, size] {
      if (auto self = weak.lock()) {
        std::lock_guard<std::mutex> lock(self->mutex);
        if (!self->active || self->closing || self->runtime != source.lock()) return;
        self->channel->InvokeMethod(
            "videoSize",
            std::make_unique<Value>(Map{
                {Value("width"), Value(int32_t(size >> 32))}, {Value("height"), Value(int32_t(size & UINT32_MAX))}}));
        self->setState("playing");
      }
    });
  }
  const FlutterDesktopPixelBuffer* copyPixels() {
    std::unique_ptr<Pixels> pixels;
    {
      std::lock_guard<std::mutex> lock(pixelMutex);
      pixels = std::move(pendingPixels);
    }
    if (pixels) {
      std::copy(pixels->data.rgba.begin(), pixels->data.rgba.end(), output.begin());
      buffer.width = pixels->data.width;
      buffer.height = pixels->data.height;
      if (auto r = pixels->source.lock()) {
        r->frameComplete(pixels->data.id, !closing);
        const auto epoch = r->metrics().epoch;
        const uint64_t size = (uint64_t(buffer.width) << 32) | buffer.height;
        const bool first = renderedEpoch.exchange(epoch) != epoch;
        const bool resized = renderedSize.exchange(size) != size;
        if (!closing && (first || resized))
          main->post([weak = weak_from_this(), source = pixels->source, size] {
            if (auto self = weak.lock()) {
              {
                std::lock_guard<std::mutex> lock(self->mutex);
                if (!self->active || self->runtime != source.lock()) return;
              }
              self->channel->InvokeMethod(
                  "videoSize", std::make_unique<Value>(
                                   Map{{Value("width"), Value(int32_t(size >> 32))},
                                       {Value("height"), Value(int32_t(size & UINT32_MAX))}}));
              self->setState("playing");
            }
          });
      }
    }
    return &buffer;
  }
  bool pixels(DecodedPixels&& pixels, std::weak_ptr<Runtime> source) {
    if (closing || !pixels.width || !pixels.height || pixels.width > 1920 || pixels.height > 1080 ||
        pixels.rgba.size() != size_t(pixels.width) * pixels.height * 4)
      return false;
    auto next = std::make_unique<Pixels>(Pixels{std::move(pixels), source});
    std::unique_ptr<Pixels> old;
    {
      std::lock_guard<std::mutex> lock(pixelMutex);
      old = std::move(pendingPixels);
      pendingPixels = std::move(next);
    }
    if (old)
      if (auto r = old->source.lock()) r->frameComplete(old->data.id, false);
    registrar->MarkTextureFrameAvailable(textureId);
    return true;
  }
  void start();
  void stop();
  void close(Reply reply = nullptr);
  void finalize();
  void method(const Call&, Reply);
};
struct Manager : std::enable_shared_from_this<Manager> {
  flutter::PluginRegistrarWindows* registrar;
  std::shared_ptr<MainQueue> main;
  std::map<uint64_t, std::shared_ptr<Session>> sessions;
  std::unique_ptr<Channel> control, receiver;
  std::thread worker;
  uint64_t next = 1;
  std::atomic<bool> closed{false}, cancelled{false};
  bool busy = false;
  std::mutex mutex;
  std::shared_ptr<Runtime> operation;
  Manager(flutter::PluginRegistrarWindows* r, std::shared_ptr<MainQueue> q) : registrar(r), main(std::move(q)) {}
  void shutdown() {
    closed = true;
    cancelled = true;
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (operation) operation->cancel();
    }
    if (worker.joinable()) worker.join();
    auto copy = sessions;
    for (auto& entry : copy) entry.second->stop();
    for (auto& entry : copy) {
      auto& session = entry.second;
      if (session->joiner.joinable()) session->joiner.join();
      if (session->worker.joinable()) session->worker.join();
      session->finalize();
    }
    main->drain();
    sessions.clear();
    std::lock_guard<std::mutex> lock(main->mutex);
    main->closed = true;
    main->tasks.clear();
  }
  void neutralize() {
    for (auto& entry : sessions) {
      auto& session = entry.second;
      std::lock_guard<std::mutex> lock(session->mutex);
      if (session->runtime) session->input.enabled(*session->runtime, false);
    }
  }
  void method(const Call&, Reply, bool);
};
void Session::start() {
  auto weak = weak_from_this();
  worker = std::thread([this, weak] {
    try {
      Credentials credentials;
      loadTrust(host.id, credentials);
      auto target = resolve(host, closing);
      int channels = options.audioChannels;
      bool allowHevc = hevc, allowPyrowave = pyrowave;
      for (int attempt = 0; attempt < 4 && !closing; ++attempt) {
        active = false;
        auto current = std::make_shared<Runtime>();
        std::atomic<bool> audioFailed{false}, videoFailed{false};
        auto decoder = std::make_shared<WindowsSink>(
            [weak, source = std::weak_ptr<Runtime>(current)](DecodedPixels&& pixels) {
              auto self = weak.lock();
              return self && self->pixels(std::move(pixels), source);
            },
            [source = std::weak_ptr<Runtime>(current)](uint32_t frame, bool shown) {
              if (auto r = source.lock()) r->frameComplete(frame, shown);
            },
            [source = std::weak_ptr<Runtime>(current), &audioFailed, &videoFailed](bool audio) {
              (audio ? audioFailed : videoFailed) = true;
              if (auto r = source.lock()) r->cancel();
            });
        std::shared_ptr<VulkanSink> gpu;
        if (allowPyrowave && plane) {
          gpu = std::make_shared<VulkanSink>(
              decoder, GpuWindow{GpuWindow::Kind::win32, nullptr, plane}, options.hdr10,
              [this, checked = std::chrono::steady_clock::time_point{}, hdr = false,
               monitor = HMONITOR{}](const PyrowaveFrameInfo& info) mutable {
                VulkanSink::Target target;
                const auto size = planeSize.load();
                target.width = int(size >> 32);
                target.height = int(size & UINT32_MAX);
                target.permitted = planeVisible && !closing;
                if (info.hdr10) {
                  const auto now = std::chrono::steady_clock::now();
                  const auto output = MonitorFromWindow(plane, MONITOR_DEFAULTTONEAREST);
                  if (monitor != output || now - checked > std::chrono::milliseconds(250)) {
                    hdr = hdrOutput(plane);
                    checked = now;
                    monitor = output;
                  }
                  target.valid = hdr;
                }
                return target;
              },
              [weak, source = std::weak_ptr<Runtime>(current)](
                  uint32_t frame, int w, int h, bool shown, bool prepared) {
                if (auto self = weak.lock()) self->completeGpu(source, frame, w, h, shown, prepared);
              },
              [weak, source = std::weak_ptr<Runtime>(current)](bool selected) {
                if (auto self = weak.lock())
                  self->main->post([weak, source, selected] {
                    if (auto s = weak.lock()) {
                      std::lock_guard<std::mutex> lock(s->mutex);
                      if (s->runtime == source.lock()) s->setNative(selected);
                    }
                  });
              },
              [source = std::weak_ptr<Runtime>(current), &videoFailed] {
                videoFailed = true;
                if (auto r = source.lock()) r->cancel();
              });
          if (!gpu->ready()) {
            gpu->close();
            gpu.reset();
            allowPyrowave = false;
          }
        }
        {
          std::lock_guard<std::mutex> lock(mutex);
          runtime = current;
          sink = decoder;
          gpuSink = gpu;
          active = true;
          input.reset(*current);
          decoder->volume(audible);
          if (closing) current->cancel();
        }
        auto request = options;
        request.audioChannels = channels;
        request.hdr10 = gpu && gpu->supportsHdr10();
        std::shared_ptr<Sink> receiver = gpu ? std::static_pointer_cast<Sink>(gpu) : decoder;
        const int result = current->run(target, credentials, game, allowHevc, allowPyrowave, receiver, request);
        active = false;
        if (gpu) gpu->close();
        main->post([weak] {
          if (auto self = weak.lock()) self->setNative(false);
        });
        decoder->close();
        {
          std::lock_guard<std::mutex> lock(mutex);
          sink.reset();
          gpuSink.reset();
        }
        if (closing) break;
        const bool dropSurround = audioFailed && channels > 2;
        const bool dropHevc = (videoFailed || result == -4) && allowHevc && current->metrics().codec == 5;
        const bool dropPyrowave = (videoFailed || result == -4) && allowPyrowave && current->metrics().codec == 9;
        if (dropSurround || dropHevc || dropPyrowave) {
          if (dropPyrowave) allowPyrowave = false;
          if (dropSurround) channels = 2;
          if (dropHevc) allowHevc = false;
          notifyState("reconnecting");
          continue;
        }
        notifyState(result == 0 && !audioFailed && !videoFailed ? "disconnected" : "failed");
        break;
      }
    } catch (...) {
      if (!closing) notifyState("failed");
    }
  });
}
void Session::stop() {
  closing = true;
  active = false;
  setNative(false);
  std::lock_guard<std::mutex> lock(mutex);
  if (runtime) {
    input.enabled(*runtime, false);
    runtime->cancel();
  }
}
void Session::close(Reply reply) {
  if (reply) stopReplies.push_back(std::move(reply));
  if (closing) return;
  stop();
  auto self = shared_from_this();
  joiner = std::thread([self] {
    if (self->worker.joinable()) self->worker.join();
    self->main->post([self] { self->finalize(); });
  });
}
void Session::finalize() {
  if (textureId < 0) return;
  if (plane) {
    DestroyWindow(plane);
    plane = nullptr;
  }
  const auto textureToRemove = textureId;
  textureId = -1;
  channel->SetMethodCallHandler(nullptr);
  auto self = shared_from_this();
  registrar->UnregisterTexture(textureToRemove, [self] {
    self->main->post([self] {
      if (auto manager = self->owner.lock()) manager->sessions.erase(self->id);
      for (auto& reply : self->stopReplies) reply->Success();
      self->stopReplies.clear();
    });
  });
}
void Session::method(const Call& call, Reply reply) {
  const auto& method = call.method_name();
  const auto* args = call.arguments();
  if (method == "disconnect") {
    close(std::move(reply));
    return;
  }
  if (method == "getSessionState") {
    reply->Success(Value(state));
    return;
  }
  if (method == "getNativePresentation") {
    reply->Success(Value(nativeActive));
    return;
  }
  if (method == "setNativeRect" && plane && !closing) {
    const int x = number(args, "x", 0, -32768, 32768), y = number(args, "y", 0, -32768, 32768);
    const int w = number(args, "width", 0, 0, 16384), h = number(args, "height", 0, 0, 16384);
    number(args, "scale", 1, 1, 8);
    planeSize = w && h ? (uint64_t(w) << 32) | uint32_t(h) : 0;
    SetWindowPos(plane, HWND_TOP, x, y, w, h, SWP_NOACTIVATE);
    planeVisible = nativeActive && w && h;
    ShowWindow(plane, planeVisible ? SW_SHOWNOACTIVATE : SW_HIDE);
    reply->Success();
    return;
  }
  if (closing) {
    error(reply);
    return;
  }
  std::lock_guard<std::mutex> lock(mutex);
  const bool live = runtime && active && runtime->metrics().epoch == renderedEpoch;
  if (method == "setControllerMapping") {
    const auto* encoded = field(args, "mapping");
    const auto* values = encoded ? std::get_if<flutter::EncodableList>(encoded) : nullptr;
    if (!values || values->size() != 19) throw std::invalid_argument("Invalid controller mapping");
    std::vector<int64_t> mapping;
    for (const auto& value : *values) mapping.push_back(integer(value));
    if (runtime) input.reset(*runtime);
    reply->Success(Value(runtime && runtime->controllerMapping(number(args, "seat", 0, 0, 3), mapping)));
    return;
  }
  if (method == "setAudioEnabled") {
    audible = boolean(args, "enabled");
    if (sink) sink->volume(audible);
  } else if (method == "setInputEnabled") {
    if (runtime) input.enabled(*runtime, boolean(args, "enabled") && state == "playing");
  } else if (method == "resetInput") {
    if (runtime) input.reset(*runtime);
  } else if (method == "releaseTouchControls") {
    if (runtime) input.releaseAssistance(*runtime);
  } else if (method == "inputKey") {
    if (live) {
      if (field(args, "usage"))
        input.hidKey(*runtime, number(args, "usage", 0, 4, 231), boolean(args, "down"));
      else
        input.key(*runtime, text(args, "key"), boolean(args, "down"));
    }
  } else if (method == "inputMouse" || method == "inputWheel" || method == "releasePointer") {
    if (live) {
      if (method == "releasePointer")
        input.releasePointer(*runtime);
      else if (method == "inputWheel")
        input.wheel(*runtime, number(args, "direction", 0, 1, 4));
      else
        input.mouse(
            *runtime, real(args, "x"), real(args, "y"), number(args, "button", 0, 0, 16), boolean(args, "down"));
    }
  } else if (
      method == "disconnectController" || method == "setControllerDeviceState" || method == "setTouchControllerState") {
    const bool assistance = method == "setTouchControllerState";
    const auto* device = field(args, "deviceId");
    if (!assistance && !device) throw std::invalid_argument("Invalid device");
    const int64_t deviceId = assistance ? 0 : integer(*device);
    if (live) {
      if (method == "disconnectController")
        input.disconnect(*runtime, deviceId);
      else
        for (const char* group : {"buttons", "axes"}) {
          const auto* value = field(args, group);
          if (!value) continue;
          const auto* values = std::get_if<Map>(value);
          if (!values || values->size() > 32) throw std::invalid_argument("Invalid controller state");
          for (const auto& entry : *values) {
            const auto* name = std::get_if<std::string>(&entry.first);
            if (!name || name->size() > 64) continue;
            if (std::string(group) == "buttons") {
              if (const auto* pressed = std::get_if<bool>(&entry.second))
                input.button(*runtime, deviceId, *name, *pressed, assistance);
            } else if (const auto* n = std::get_if<double>(&entry.second))
              input.axis(*runtime, deviceId, *name, *n, assistance);
            else if (const auto* n = std::get_if<int32_t>(&entry.second))
              input.axis(*runtime, deviceId, *name, *n, assistance);
            else if (const auto* n = std::get_if<int64_t>(&entry.second))
              input.axis(*runtime, deviceId, *name, double(*n), assistance);
          }
        }
    }
  } else if (method == "getStreamMetrics") {
    if (!runtime) {
      reply->Success();
      return;
    }
    const auto m = runtime->metrics();
    Map metrics;
    auto put = [&](const char* key, uint64_t value) { metrics[Value(key)] = Value(int64_t(value)); };
    put("version", 1);
    put("epoch", m.epoch);
    put("sampledAtUs", m.sampledAtUs);
    put("receivedFrames", m.receivedFrames);
    put("presentedFrames", m.presentedFrames);
    put("droppedFrames", m.droppedFrames);
    put("resetFrames", m.resetFrames);
    put("videoBytes", m.videoBytes);
    put("completionTotalUs", m.completionTotalUs);
    put("completedFrames", m.completedFrames);
    put("width", m.width);
    put("height", m.height);
    put("codec", m.codec);
    put("audioChannels", m.audioChannels);
    put("fpsNumerator", m.fpsNumerator);
    put("fpsDenominator", m.fpsDenominator);
    put("fpsReasons", m.fpsReasons);
    put("targetBitrate", m.targetBitrate);
    put("reliableRetries", m.reliability.reliableRetries);
    put("reliableGiveUps", m.reliability.reliableGiveUps);
    put("reliableOutstanding", m.reliability.reliableOutstanding);
    put("maxAckLatencyMs", m.reliability.reliableMaxAckLatencyMs);
    put("hidPending", m.reliability.hidPending);
    put("hidInFlight", m.reliability.hidInFlight);
    put("decoderKind", m.codec == 9 && gpuSink ? 4 : 2);
    put("hdr10", gpuSink && gpuSink->hdr10Active() ? 1 : 0);
    put("chromaFormat", gpuSink && m.codec == 9 ? gpuSink->chromaFormat() : 0);
    reply->Success(Value(metrics));
    return;
  } else {
    reply->NotImplemented();
    return;
  }
  reply->Success();
}
void Manager::method(const Call& call, Reply reply, bool stream) {
  if (closed) {
    error(reply);
    return;
  }
  const auto& name = call.method_name();
  const auto* args = call.arguments();
  if (name == "cancel" && !stream) {
    cancelled = true;
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (operation) operation->cancel();
    }
    reply->Success();
    return;
  }
  if (!args || !std::holds_alternative<Map>(*args) || std::get<Map>(*args).size() > 64)
    throw std::invalid_argument("Invalid arguments");
  if (!stream && name == "capabilities") {
    static const bool decoderAvailable = WindowsSink::supported();
    const bool available = text(args, "protocol") == "steam" && decoderAvailable;
    Map result;
    for (const char* key : {"available", "inlinePairing", "library", "embeddedSurface", "internetTunnel"})
      result[Value(key)] = Value(available);
    reply->Success(Value(result));
    return;
  }
  if (stream && name == "create") {
    if (busy) {
      error(reply, "BUSY");
      return;
    }
    if (sessions.size() >= 8 || !WindowsSink::supported()) {
      error(reply);
      return;
    }
    auto host = hostFrom(args);
    auto game = identifier(text(args, "appId"), true);
    StreamOptions options;
    options.width = number(args, "streamWidth", 1920, 640, 1920);
    options.height = number(args, "streamHeight", 1080, 360, 1080);
    options.fps = number(args, "streamFps", 60, 15, 60);
    options.bitrateKbps = number(args, "streamBitrateKbps", 30000, 1000, 50000);
    options.controllerCount = number(args, "controllerCount", 1, 1, 4);
    options.audioChannels = number(args, "audioChannels", 2, 2, 6);
    options.hdr10 = boolean(args, "allowHdr");
    if (!options.valid()) throw std::invalid_argument("Invalid options");
    auto session = std::make_shared<Session>(
        next++, host, game, options, boolean(args, "allowHevc", true) && WindowsSink::supported(true),
        boolean(args, "pyrowave"), registrar, main);
    session->owner = shared_from_this();
    const auto weak = std::weak_ptr<Session>(session);
    session->texture = std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture([weak](size_t, size_t) {
      auto self = weak.lock();
      return self ? self->copyPixels() : nullptr;
    }));
    session->textureId = session->registrar->RegisterTexture(session->texture.get());
    if (session->textureId < 0) {
      error(reply);
      return;
    }
    sessions.emplace(session->id, session);
    session->channel->SetMethodCallHandler(
        [weak](const Call& call, std::unique_ptr<flutter::MethodResult<Value>> uniqueReply) {
          Reply reply(std::move(uniqueReply));
          try {
            if (auto self = weak.lock())
              self->method(call, reply);
            else
              error(reply);
          } catch (...) {
            error(reply, "INVALID_ARGUMENT");
          }
        });
    session->start();
    reply->Success(Value(
        Map{{Value("id"), Value(int64_t(session->id))},
            {Value("textureId"), Value(session->textureId)},
            {Value("nativePlane"), Value(session->plane != nullptr)}}));
    return;
  }
  if (stream || text(args, "protocol") != "steam" || (name != "pair" && name != "games" && name != "forget")) {
    reply->NotImplemented();
    return;
  }
  if (busy) {
    error(reply, "BUSY");
    return;
  }
  const auto host = hostFrom(args);
  const std::string pin = name == "pair" ? text(args, "pin") : "";
  if (name == "pair" && (pin.size() != 4 || pin.find_first_not_of("0123456789") != std::string::npos))
    throw std::invalid_argument("Invalid PIN");
  if (name == "forget")
    for (auto& entry : sessions)
      if (entry.second->host.id == host.id) entry.second->close();
  if (worker.joinable()) worker.join();
  busy = true;
  cancelled = false;
  auto r = std::make_shared<Runtime>();
  {
    std::lock_guard<std::mutex> lock(mutex);
    operation = r;
  }
  auto self = shared_from_this();
  worker = std::thread([self, r, reply, host, pin, name] {
    bool success = false, pairingRequired = false;
    try {
      Credentials credentials;
      if (name == "forget")
        success = forgetTrust(host.id);
      else if (name == "games") {
        loadTrust(host.id, credentials);
        success = true;
      } else {
        do {
          randomBytes(reinterpret_cast<uint8_t*>(&credentials.device), sizeof(credentials.device));
        } while (!credentials.device);
        randomBytes(credentials.key.data(), credentials.key.size());
        success = r->pair(resolve(host, self->cancelled), credentials, pin) == 0;
        if (success && !self->cancelled && !self->closed)
          success = saveTrust(host.id, credentials);
        else
          success = false;
        if (self->cancelled || self->closed) {
          success = false;
          try {
            Credentials stored;
            loadTrust(host.id, stored);
            if (stored.device == credentials.device) forgetTrust(host.id);
          } catch (...) {
          }
        }
      }
    } catch (...) {
      pairingRequired = name == "games";
    }
    self->main->post([self, r, reply, success, pairingRequired, name] {
      self->busy = false;
      {
        std::lock_guard<std::mutex> lock(self->mutex);
        if (self->operation == r) self->operation.reset();
      }
      if (self->closed) return;
      if (self->cancelled)
        error(reply, "CANCELLED");
      else if (!success)
        error(reply, pairingRequired ? "PAIRING_REQUIRED" : "UNAVAILABLE");
      else
        reply->Success(name == "games" ? Value(flutter::EncodableList{}) : Value(true));
    });
  });
}
class SteamPlugin final : public flutter::Plugin {
 public:
  explicit SteamPlugin(flutter::PluginRegistrarWindows* registrar) : registrar_(registrar) {
    auto queue = std::make_shared<MainQueue>(GetAncestor(registrar->GetView()->GetNativeWindow(), GA_ROOT));
    manager_ = std::make_shared<Manager>(registrar, queue);
    const auto weak = std::weak_ptr<Manager>(manager_);
    proc_ = registrar->RegisterTopLevelWindowProcDelegate(
        [weak, queue](HWND, UINT message, WPARAM wparam, LPARAM) -> std::optional<LRESULT> {
          if (message == taskMessage) {
            queue->drain();
            return 0;
          }
          if ((message == WM_ACTIVATEAPP && !wparam) || (message == WM_POWERBROADCAST && wparam == PBT_APMSUSPEND))
            if (auto self = weak.lock()) self->neutralize();
          return std::nullopt;
        });
    for (bool stream : {false, true}) {
      auto channel = std::make_unique<Channel>(
          registrar->messenger(), stream ? "com.plezy/games/steam_receiver" : "com.plezy/games",
          &flutter::StandardMethodCodec::GetInstance());
      channel->SetMethodCallHandler(
          [weak, stream](const Call& call, std::unique_ptr<flutter::MethodResult<Value>> uniqueReply) {
            Reply reply(std::move(uniqueReply));
            try {
              if (auto self = weak.lock())
                self->method(call, reply, stream);
              else
                error(reply);
            } catch (...) {
              error(reply, "INVALID_ARGUMENT");
            }
          });
      (stream ? manager_->receiver : manager_->control) = std::move(channel);
    }
  }
  ~SteamPlugin() override {
    manager_->shutdown();
    registrar_->UnregisterTopLevelWindowProcDelegate(proc_);
    manager_.reset();
  }

 private:
  flutter::PluginRegistrarWindows* registrar_;
  int proc_ = 0;
  std::shared_ptr<Manager> manager_;
};
}  // namespace
void SteamPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  auto* plugin =
      flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  plugin->AddPlugin(std::make_unique<SteamPlugin>(plugin));
}
