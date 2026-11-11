#include "mpv_plugin.h"

#include <commctrl.h>
#include <flutter_windows.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

static flutter::EncodableMap DisplayModeToMap(const mpv::DisplayMode& mode) {
  flutter::EncodableMap m;
  m[flutter::EncodableValue("width")] = flutter::EncodableValue(static_cast<int32_t>(mode.width));
  m[flutter::EncodableValue("height")] = flutter::EncodableValue(static_cast<int32_t>(mode.height));
  m[flutter::EncodableValue("refreshRate")] = flutter::EncodableValue(static_cast<int32_t>(mode.refresh_rate));
  return m;
}

void MpvPlayerPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  mpv::MpvPlayerPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}

void MpvWorkspacePlayerPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  mpv::MpvPlayerPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar),
      "com.plezy/mpv_player/workspace", /*audio_only=*/false, WM_APP + 0x04D2);
}

void MpvAudioPlayerPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  mpv::MpvPlayerPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar),
      "com.plezy/mpv_audio_player", /*audio_only=*/true);
}

void MpvAudioOverlapPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  mpv::MpvPlayerPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar),
      "com.plezy/mpv_audio_player/overlap", /*audio_only=*/true, WM_APP + 0x04D3);
}

namespace mpv {

namespace {
constexpr UINT kPlatformTaskMessage = WM_APP + 0x04D0;
constexpr UINT kAudioPlatformTaskMessage = WM_APP + 0x04D1;
}  // namespace

void MpvPlayerPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar, const std::string& channel_name, bool audio_only,
    UINT platform_task_message) {
  auto plugin = std::make_unique<MpvPlayerPlugin>(registrar, channel_name, audio_only, platform_task_message);
  registrar->AddPlugin(std::move(plugin));
}

MpvPlayerPlugin::MpvPlayerPlugin(
    flutter::PluginRegistrarWindows* registrar, const std::string& channel_name, bool audio_only,
    UINT platform_task_message)
    : registrar_(registrar),
      platform_thread_id_(::GetCurrentThreadId()),
      audio_only_(audio_only),
      platform_task_message_(
          platform_task_message != 0 ? platform_task_message
                                     : (audio_only ? kAudioPlatformTaskMessage : kPlatformTaskMessage)) {
  method_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), channel_name, &flutter::StandardMethodCodec::GetInstance());

  method_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) { HandleMethodCall(call, std::move(result)); });

  event_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(), channel_name + "/events", &flutter::StandardMethodCodec::GetInstance());

  auto handler = std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [this](
          const flutter::EncodableValue* arguments,
          std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        event_sink_ = std::move(events);
        return nullptr;
      },
      [this](const flutter::EncodableValue* arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        event_sink_ = nullptr;
        return nullptr;
      });

  event_channel_->SetStreamHandler(std::move(handler));
}

MpvPlayerPlugin::~MpvPlayerPlugin() {
  AttachVideoWindow(false);
  DisposeVisualizer();
  player_generation_.fetch_add(1, std::memory_order_acq_rel);
  // Join the mpv event thread before draining: it enqueues platform tasks,
  // and platform_tasks_/platform_tasks_mutex_ are destroyed before player_
  // (reverse declaration order).
  if (player_) {
    player_->Dispose();
    player_.reset();
  }
  AttachVideoWindow(false);

  DrainPlatformTasks();

  if (proc_id_) {
    registrar_->UnregisterTopLevelWindowProcDelegate(proc_id_.value());
    proc_id_ = std::nullopt;
  }
}

HWND MpvPlayerPlugin::GetChildWindow() { return registrar_->GetView()->GetNativeWindow(); }

HWND MpvPlayerPlugin::GetWindow() { return ::GetAncestor(GetChildWindow(), GA_ROOT); }

namespace {
std::wstring DetachedText(const std::string& text) {
  const int length = static_cast<int>(std::min<size_t>(text.size(), 1024));
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), length, nullptr, 0);
  if (count <= 0) return L"Pleazyng";
  std::wstring result(count, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), length, result.data(), count);
  return result;
}
std::string DetachedArgument(const flutter::EncodableMap& map, const char* key) {
  const auto found = map.find(flutter::EncodableValue(key));
  return found != map.end() && std::holds_alternative<std::string>(found->second) ? std::get<std::string>(found->second)
                                                                                  : std::string();
}
LRESULT CALLBACK DetachedButtonProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam, UINT_PTR, DWORD_PTR) {
  if (message == WM_KEYDOWN && wparam == VK_TAB) {
    const HWND next = GetNextDlgTabItem(GetParent(window), window, (GetKeyState(VK_SHIFT) & 0x8000) != 0);
    if (next) SetFocus(next);
    return 0;
  }
  if (message == WM_NCDESTROY) RemoveWindowSubclass(window, DetachedButtonProc, 1);
  return DefSubclassProc(window, message, wparam, lparam);
}
}  // namespace

void MpvPlayerPlugin::SaveDetachedGeometry() {
  if (!detached_window_ || detached_geometry_key_.empty() || IsIconic(detached_window_) || IsZoomed(detached_window_))
    return;
  RECT rect{};
  if (GetWindowRect(detached_window_, &rect)) {
    RegSetKeyValueW(HKEY_CURRENT_USER, detached_geometry_key_.c_str(), L"Bounds", REG_BINARY, &rect, sizeof(rect));
  }
}

void MpvPlayerPlugin::DetachedAction(const char* action) {
  if (!event_sink_ || detached_token_.empty()) return;
  using V = flutter::EncodableValue;
  event_sink_->Success(
      V(flutter::EncodableMap{
          {V("type"), V("event")},
          {V("name"), V("detached-window-action")},
          {V("data"), V(flutter::EncodableMap{{V("token"), V(detached_token_)}, {V("action"), V(action)}})}}));
}

void MpvPlayerPlugin::LayoutDetachedVideo(HWND window) {
  if (window != detached_window_ || !player_ || !player_->GetHwnd()) return;
  RECT rect{};
  GetClientRect(window, &rect);
  const UINT dpi = FlutterDesktopGetDpiForMonitor(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST));
  const int bar = MulDiv(52, dpi, 96);
  const int width = (std::max)(1L, rect.right / 4);
  SetWindowPos(player_->GetHwnd(), HWND_TOP, 0, 0, rect.right, (std::max)(1L, rect.bottom - bar), SWP_NOACTIVATE);
  for (int i = 0; i < 4; ++i) {
    if (HWND button = GetDlgItem(window, 100 + i))
      SetWindowPos(button, HWND_TOP, i * width, rect.bottom - bar, width, bar, SWP_NOACTIVATE);
  }
}

LRESULT CALLBACK MpvPlayerPlugin::DetachedWindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<MpvPlayerPlugin*>(GetWindowLongPtr(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<MpvPlayerPlugin*>(reinterpret_cast<CREATESTRUCT*>(lparam)->lpCreateParams);
    SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (!self) return DefWindowProc(window, message, wparam, lparam);
  switch (message) {
    case WM_SIZE:
      self->LayoutDetachedVideo(window);
      self->SaveDetachedGeometry();
      return 0;
    case WM_MOVE:
      self->SaveDetachedGeometry();
      return 0;
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize = {360, 240};
      return 0;
    }
    case WM_DPICHANGED: {
      const auto* rect = reinterpret_cast<RECT*>(lparam);
      SetWindowPos(
          window, nullptr, rect->left, rect->top, rect->right - rect->left, rect->bottom - rect->top,
          SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }
    case WM_COMMAND:
      if (HIWORD(wparam) == BN_CLICKED) {
        switch (LOWORD(wparam)) {
          case 100:
            self->DetachedAction("seekBackward");
            return 0;
          case 101:
            self->DetachedAction("togglePlayback");
            return 0;
          case 102:
            self->DetachedAction("seekForward");
            return 0;
          case 103:
            self->AttachVideoWindow(true);
            return 0;
        }
      }
      break;
    case WM_CLOSE:
      self->AttachVideoWindow(true);
      return 0;
    case WM_DISPLAYCHANGE:
      if (self->player_) self->player_->NotifyDisplayChange(wparam, lparam);
      break;
    case WM_NCDESTROY:
      SetWindowLongPtr(window, GWLP_USERDATA, 0);
      break;
  }
  return DefWindowProc(window, message, wparam, lparam);
}

bool MpvPlayerPlugin::DetachVideoWindow(const flutter::EncodableMap& args) {
  const auto token = DetachedArgument(args, "token");
  if (token.empty() || token.size() > 80 || audio_only_ || !player_ || !player_->GetHwnd()) return false;
  if (detached_window_) return token == detached_token_;
  static const wchar_t* class_name = L"PleazyngDetachedVideo";
  WNDCLASSW cls{};
  cls.lpfnWndProc = DetachedWindowProc;
  cls.hInstance = GetModuleHandle(nullptr);
  cls.lpszClassName = class_name;
  cls.hCursor = LoadCursor(nullptr, IDC_ARROW);
  cls.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  if (!RegisterClassW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
  const auto title = DetachedText(DetachedArgument(args, "title"));
  const auto geometry = DetachedArgument(args, "geometryKey");
  detached_geometry_key_.clear();
  RECT saved{};
  bool restore = false;
  if (geometry.size() == 64 && geometry.find_first_not_of("abcdef0123456789") == std::string::npos) {
    detached_geometry_key_ = L"Software\\Plezy\\DetachedWindows\\" + DetachedText(geometry);
    DWORD bytes = sizeof(saved);
    restore = RegGetValueW(
                  HKEY_CURRENT_USER, detached_geometry_key_.c_str(), L"Bounds", RRF_RT_REG_BINARY, nullptr, &saved,
                  &bytes) == ERROR_SUCCESS &&
              bytes == sizeof(saved) && static_cast<int64_t>(saved.right) - saved.left >= 360 &&
              static_cast<int64_t>(saved.right) - saved.left <= 16384 &&
              static_cast<int64_t>(saved.bottom) - saved.top >= 240 &&
              static_cast<int64_t>(saved.bottom) - saved.top <= 16384;
    // Removed displays must not strand the title bar beyond every work area.
    MONITORINFO monitor{sizeof(MONITORINFO)};
    if (restore && GetMonitorInfo(MonitorFromRect(&saved, MONITOR_DEFAULTTONEAREST), &monitor)) {
      const int width = (std::min)(saved.right - saved.left, monitor.rcWork.right - monitor.rcWork.left);
      const int height = (std::min)(saved.bottom - saved.top, monitor.rcWork.bottom - monitor.rcWork.top);
      saved.left = (std::max)(monitor.rcWork.left, (std::min)(saved.left, monitor.rcWork.right - width));
      saved.top = (std::max)(monitor.rcWork.top, (std::min)(saved.top, monitor.rcWork.bottom - height));
      saved.right = saved.left + width;
      saved.bottom = saved.top + height;
    }
  }
  HWND window = CreateWindowExW(
      0, class_name, title.c_str(), WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, restore ? saved.left : CW_USEDEFAULT,
      restore ? saved.top : CW_USEDEFAULT, restore ? saved.right - saved.left : 900,
      restore ? saved.bottom - saved.top : 560, nullptr, nullptr, cls.hInstance, this);
  if (!window) return false;
  HWND video = player_->GetHwnd();
  video_parent_ = GetParent(video);
  GetWindowRect(video, &video_rect_);
  MapWindowPoints(nullptr, video_parent_, reinterpret_cast<POINT*>(&video_rect_), 2);
  SetLastError(0);
  if (!SetParent(video, window) && GetLastError() != 0) {
    SetWindowLongPtr(window, GWLP_USERDATA, 0);
    DestroyWindow(window);
    video_parent_ = nullptr;
    return false;
  }
  detached_window_ = window;
  detached_token_ = token;
  flutter::EncodableMap labels;
  const auto entry = args.find(flutter::EncodableValue("labels"));
  if (entry != args.end() && std::holds_alternative<flutter::EncodableMap>(entry->second))
    labels = std::get<flutter::EncodableMap>(entry->second);
  const char* keys[] = {"back", "playPause", "forward", "restore"};
  for (int i = 0; i < 4; ++i) {
    const auto label = DetachedText(DetachedArgument(labels, keys[i]));
    HWND button = CreateWindowW(
        L"BUTTON", label.c_str(), WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 1, 1, window,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(100 + i)), cls.hInstance, nullptr);
    if (button) SetWindowSubclass(button, DetachedButtonProc, 1, 0);
  }
  LayoutDetachedVideo(window);
  ShowWindow(video, SW_SHOW);
  ShowWindow(window, SW_SHOW);
  return true;
}

void MpvPlayerPlugin::AttachVideoWindow(bool notify) {
  if (!detached_window_) return;
  SaveDetachedGeometry();
  if (player_ && player_->GetHwnd()) {
    HWND video = player_->GetHwnd();
    SetLastError(0);
    if (!SetParent(video, video_parent_) && GetLastError() != 0) return;
    player_->SetRect(video_rect_, 1.0);
    player_->SetVisible(requested_video_visible_);
  }
  HWND window = detached_window_;
  detached_window_ = nullptr;
  video_parent_ = nullptr;
  if (notify) DetachedAction("restored");
  detached_token_.clear();
  detached_geometry_key_.clear();
  SetWindowLongPtr(window, GWLP_USERDATA, 0);
  DestroyWindow(window);
}

void MpvPlayerPlugin::PostToPlatformThread(std::function<void()> task) {
  if (::GetCurrentThreadId() == platform_thread_id_) {
    task();
    return;
  }

  bool post_wakeup = false;
  {
    std::lock_guard<std::mutex> lock(platform_tasks_mutex_);
    platform_tasks_.push(std::move(task));
    if (!wakeup_posted_ && flutter_window_) {
      wakeup_posted_ = true;
      post_wakeup = true;
    }
  }

  if (post_wakeup && !::PostMessage(flutter_window_, platform_task_message_, 0, 0)) {
    // Wakeup lost (e.g. message queue full during a log storm); let the next
    // enqueue retry instead of stranding the queue.
    std::lock_guard<std::mutex> lock(platform_tasks_mutex_);
    wakeup_posted_ = false;
  }
}

void MpvPlayerPlugin::DrainPlatformTasks() {
  std::queue<std::function<void()>> tasks;
  {
    std::lock_guard<std::mutex> lock(platform_tasks_mutex_);
    tasks.swap(platform_tasks_);
    wakeup_posted_ = false;
  }

  while (!tasks.empty()) {
    tasks.front()();
    tasks.pop();
  }
}

void MpvPlayerPlugin::DisposeVisualizer() {
  visualizer_.reset();
  ++visualizer_session_id_;
  if (player_) player_->SetVisualizationTap(false);
}
void MpvPlayerPlugin::HandleVisualizerMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  using V = flutter::EncodableValue;
  using M = flutter::EncodableMap;
  const auto* args = call.arguments() ? std::get_if<M>(call.arguments()) : nullptr;
  auto arg = [args](const char* key) -> const V* {
    if (!args) return nullptr;
    const auto it = args->find(V(key));
    return it == args->end() ? nullptr : &it->second;
  };
  auto string = [&arg](const char* key, const std::string& fallback = "") {
    auto value = arg(key);
    const auto* text = value ? std::get_if<std::string>(value) : nullptr;
    return text ? *text : fallback;
  };
  auto integer = [&arg](const char* key, int64_t fallback = -1) -> int64_t {
    auto value = arg(key);
    if (!value) return fallback;
    if (auto p = std::get_if<int32_t>(value)) return *p;
    if (auto p = std::get_if<int64_t>(value)) return *p;
    return fallback;
  };
  auto number = [&arg](const char* key, double fallback) -> double {
    const auto* value = arg(key);
    if (!value) return fallback;
    if (const auto* p = std::get_if<double>(value)) return *p;
    if (const auto* p = std::get_if<int32_t>(value)) return *p;
    if (const auto* p = std::get_if<int64_t>(value)) return static_cast<double>(*p);
    throw std::runtime_error(std::string("Invalid number: ") + key);
  };
  const auto& method = call.method_name();
  const auto engine = string("engine", "projectm");
  auto reason = [&]() -> std::string {
    if (!audio_only_ || !player_ || !player_->IsInitialized())
      return "Initialize the music player before opening a preset.";
    if (engine != "milkrust") return "Select native MilkRust on Windows; this host does not bundle projectM.";
    if (!MpvPlayer::VisualizationTapAvailable()) return "This mpv build lacks the visualization PCM tap ABI v1.";
    return plezy::visualization::WindowsVisualizerSession::DependencyError();
  };
  if (method == "visualizerCapabilities") {
    const auto unavailable = reason();
    result->Success(
        V(M{{V("available"), V(unavailable.empty())},
            {V("engine"), V("milkrust-native-abi1")},
            {V("audioTap"), V(MpvPlayer::VisualizationTapAvailable())},
            {V("reason"), V(unavailable)}}));
    return;
  }
  try {
    if (method == "visualizerCreate") {
      const auto unavailable = reason();
      if (!unavailable.empty()) throw std::runtime_error(unavailable);
      DisposeVisualizer();
      if (player_->SetVisualizationTap(true) < 0) throw std::runtime_error("Could not attach to music PCM.");
      try {
        visualizer_ = std::make_unique<plezy::visualization::WindowsVisualizerSession>(
            registrar_->texture_registrar(),
            [player = player_.get()](mpv_plezy_audio_block* block) { return player->ReadVisualizationAudio(block); });
      } catch (...) {
        player_->SetVisualizationTap(false);
        throw;
      }
      result->Success(
          V(M{{V("sessionId"), V(visualizer_session_id_)}, {V("textureId"), V(visualizer_->texture_id())}}));
      return;
    }
    if (!visualizer_ || integer("sessionId") != visualizer_session_id_) {
      result->Error("VISUALIZER_STALE", "This visualization session has ended.");
      return;
    }
    auto& worker = visualizer_->worker();
    if (method == "visualizerDispose")
      DisposeVisualizer();
    else if (method == "visualizerLoad")
      worker.Load(string("path"), string("root"), number("transitionSeconds", 3));
    else if (method == "visualizerResize") {
      const auto width = integer("width"), height = integer("height");
      if (width < 1 || height < 1 || width > 16384 || height > 16384) throw std::runtime_error("Invalid dimensions.");
      worker.Resize(static_cast<int>(width), static_cast<int>(height));
    } else if (method == "visualizerSetPaused") {
      auto value = arg("paused");
      auto paused = value ? std::get_if<bool>(value) : nullptr;
      if (!paused) throw std::runtime_error("A paused boolean is required.");
      worker.Pause(*paused);
    } else if (method == "visualizerSetMouse") {
      auto value = arg("down");
      auto down = value ? std::get_if<bool>(value) : nullptr;
      if (!down) throw std::runtime_error("A mouse button state is required.");
      worker.SetMouseState(*down, number("x", 0.5), number("y", 0.5), number("dx", 0), number("dy", 0));
    } else if (method == "visualizerStatus") {
      const auto status = worker.Status();
      result->Success(
          V(M{{V("state"), V(status.state)},
              {V("reason"), V(status.reason)},
              {V("hasFrame"), V(status.has_frame)},
              {V("droppedFrames"), V(static_cast<int64_t>(status.dropped))},
              {V("width"), V(status.width)},
              {V("height"), V(status.height)},
              {V("engine"), V("milkrust")}}));
      return;
    } else {
      result->NotImplemented();
      return;
    }
    result->Success();
  } catch (const std::exception& error) {
    result->Error("VISUALIZER_NATIVE", error.what());
  }
}

void MpvPlayerPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& method = method_call.method_name();

  const bool music_pcm =
      method == "musicPcmCaptureAvailable" || method == "setMusicPcmCaptureEnabled" || method == "drainMusicPcmCapture";
  if (method == "subtitlePcmCaptureAvailable" || method == "musicPcmCaptureAvailable") {
    const bool available = player_ && player_->IsInitialized() &&
                           (music_pcm ? audio_only_ && player_->MusicPcmCaptureAvailable()
                                      : !audio_only_ && MpvPlayer::SubtitlePcmCaptureAvailable());
    result->Success(flutter::EncodableValue(available));
    return;
  }
  if (method == "setSubtitlePcmCaptureEnabled" || method == "drainSubtitlePcmCapture" || music_pcm) {
    if ((music_pcm ? !audio_only_ : audio_only_) || !player_ || !player_->IsInitialized()) {
      result->Error("SUBTITLE_PCM_UNAVAILABLE", "The video MPV session is not available.");
      return;
    }
    using V = flutter::EncodableValue;
    if (method == "setSubtitlePcmCaptureEnabled" || method == "setMusicPcmCaptureEnabled") {
      const auto* args =
          method_call.arguments() ? std::get_if<flutter::EncodableMap>(method_call.arguments()) : nullptr;
      const bool* enabled = nullptr;
      if (args) {
        const auto it = args->find(V("enabled"));
        if (it != args->end()) enabled = std::get_if<bool>(&it->second);
      }
      if (!enabled) {
        result->Error("INVALID_ARGS", "An enabled boolean is required.");
        return;
      }
      result->Success(
          V((music_pcm ? player_->SetMusicPcmCaptureEnabled(*enabled)
                       : player_->SetSubtitlePcmCaptureEnabled(*enabled)) >= 0));
      return;
    }

    flutter::EncodableList packets;
    constexpr int kMaximumBlocksPerDrain = 32;
    for (int i = 0; i < kMaximumBlocksPerDrain; ++i) {
      mpv_plezy_audio_block block{};
      const int read_result =
          music_pcm ? player_->ReadMusicPcmCapture(&block) : player_->ReadSubtitlePcmCapture(&block);
      if (read_result == 0) break;
      if (read_result < 0) {
        result->Error("SUBTITLE_PCM_READ", "The native PCM capture tap failed.");
        return;
      }
      if (!std::isfinite(block.pts) || block.frames == 0 || block.frames > MPV_PLEZY_AUDIO_TAP_FRAMES ||
          block.sample_rate == 0 || block.channels == 0 || block.channels > MPV_PLEZY_AUDIO_TAP_CHANNELS) {
        continue;
      }
      const double pts_us = block.pts * 1000000.0;
      if (!std::isfinite(pts_us) || pts_us >= static_cast<double>(std::numeric_limits<int64_t>::max()) ||
          pts_us < static_cast<double>(std::numeric_limits<int64_t>::min())) {
        continue;
      }
      const size_t sample_count = static_cast<size_t>(block.frames) * block.channels;
      std::vector<uint8_t> pcm(sample_count * sizeof(float));
      std::memcpy(pcm.data(), block.samples, pcm.size());
      flutter::EncodableMap packet;
      packet[V("presentationTimeUs")] = V(static_cast<int64_t>(std::llround(pts_us)));
      packet[V("generation")] = V(static_cast<int64_t>(block.generation));
      packet[V("sampleRate")] = V(static_cast<int32_t>(block.sample_rate));
      packet[V("channels")] = V(static_cast<int32_t>(block.channels));
      packet[V("encoding")] = V("float32");
      packet[V("pcm")] = V(std::move(pcm));
      packet[V("droppedFrames")] = V(static_cast<int64_t>(block.dropped_frames));
      packets.emplace_back(std::move(packet));
    }
    result->Success(V(std::move(packets)));
    return;
  }

  if (method.rfind("visualizer", 0) == 0) {
    HandleVisualizerMethod(method_call, std::move(result));
    return;
  }
  if (method == "detachVideoWindow") {
    const auto* args = method_call.arguments();
    result->Success(
        flutter::EncodableValue(
            args && std::holds_alternative<flutter::EncodableMap>(*args) &&
            DetachVideoWindow(std::get<flutter::EncodableMap>(*args))));
    return;
  } else if (method == "attachVideoWindow") {
    const auto* args = method_call.arguments();
    if (detached_window_ && (!args || !std::holds_alternative<flutter::EncodableMap>(*args) ||
                             DetachedArgument(std::get<flutter::EncodableMap>(*args), "token") != detached_token_)) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    AttachVideoWindow(false);
    result->Success(flutter::EncodableValue(detached_window_ == nullptr));
    return;
  } else if (method == "initialize") {
    // Method-channel calls are serialized on the platform thread. Keep an
    // already-live core instead of replacing it (which would synchronously
    // join its event thread before MpvPlayer::Initialize can see its guard).
    if (player_ && player_->IsInitialized()) {
      result->Success(flutter::EncodableValue(true));
      return;
    }

    if (proc_id_) {
      registrar_->UnregisterTopLevelWindowProcDelegate(proc_id_.value());
      proc_id_ = std::nullopt;
    }

    flutter_window_ = GetWindow();

    // Top-level messages handled here: the platform-task wakeup, power
    // broadcasts, and display changes. Mouse-over-video input is forwarded by
    // the mpv inner-window subclass (see MpvPlayer), and compositing/z-order is
    // handled by the engine's topmost DComp visual — there is no separate
    // container window to manage.
    proc_id_ =
        registrar_->RegisterTopLevelWindowProcDelegate([this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
          if (message == platform_task_message_) {
            DrainPlatformTasks();
            return std::optional<HRESULT>(0);
          }
          // Both resume variants are handled: which of the two arrives (or
          // both) depends on S3 vs Modern Standby; re-arming is idempotent.
          // player_ create/reset also happens on this thread, so the
          // null-check suffices. Never consume the message.
          if (message == WM_POWERBROADCAST && player_ && player_->IsInitialized()) {
            if (wparam == PBT_APMSUSPEND) {
              player_->NotifyPowerSuspend();
            } else if (wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND) {
              player_->NotifyPowerResume();
            }
          }
          if (message == WM_DISPLAYCHANGE && player_ && player_->IsInitialized()) {
            player_->NotifyDisplayChange(wparam, lparam);
          }
          return std::optional<HRESULT>(std::nullopt);
        });

    // The video window is a child of the FLUTTER VIEW itself, so DWM's
    // per-window layer model puts it above the view's own (layer 1) content
    // and below the view's topmost DComp visual carrying the UI (layer 4). As
    // a *sibling* of the view, either the view's never-painted white content
    // covers the video or the video covers the UI — the in-subtree placement
    // is the only ordering that yields white < video < UI. The audio-only
    // core is windowless, so it gets no view at all.
    HWND view = audio_only_ ? nullptr : GetChildWindow();

    bool experimental_dolby_vision = true;
    const auto* initialization_arguments = method_call.arguments();
    if (initialization_arguments && std::holds_alternative<flutter::EncodableMap>(*initialization_arguments)) {
      const auto& arguments = std::get<flutter::EncodableMap>(*initialization_arguments);
      const auto experimental = arguments.find(flutter::EncodableValue("experimentalDolbyVision"));
      if (experimental != arguments.end() && std::holds_alternative<bool>(experimental->second)) {
        experimental_dolby_vision = std::get<bool>(experimental->second);
      }
    }

    const uint64_t generation = player_generation_.fetch_add(1, std::memory_order_acq_rel) + 1;
    player_ = std::make_unique<MpvPlayer>(audio_only_);
    player_->ConfigureDolbyVisionExperiment(experimental_dolby_vision);
    bool success = player_->Initialize(view);

    if (success) {
      // Set up event callback.
      player_->SetEventCallback(
          [this, generation](const flutter::EncodableValue& event) { SendEvent(generation, event); });

      if (!audio_only_) {
        // Start hidden.
        requested_video_visible_ = false;
        player_->SetVisible(false);
      }
      result->Success(flutter::EncodableValue(true));
    } else {
      player_.reset();  // Clear the player so we don't have a half-initialized state
      result->Error("INIT_FAILED", "Failed to initialize MPV player");
    }
  } else if (method == "dispose") {
    AttachVideoWindow(false);
    DisposeVisualizer();
    player_generation_.fetch_add(1, std::memory_order_acq_rel);
    if (player_) {
      player_->Dispose();
      player_.reset();
    }
    AttachVideoWindow(false);
    result->Success();
  } else if (method == "command") {
    if (!player_ || !player_->IsInitialized()) {
      result->Error("NOT_INITIALIZED", "Player not initialized");
      return;
    }

    const auto* args = method_call.arguments();
    if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
      result->Error("INVALID_ARGS", "Expected map argument");
      return;
    }

    const auto& map = std::get<flutter::EncodableMap>(*args);
    auto it = map.find(flutter::EncodableValue("args"));
    if (it == map.end() || !std::holds_alternative<flutter::EncodableList>(it->second)) {
      result->Error("INVALID_ARGS", "Missing 'args' list");
      return;
    }

    const auto& list = std::get<flutter::EncodableList>(it->second);
    std::vector<std::string> command_args;
    for (const auto& item : list) {
      if (std::holds_alternative<std::string>(item)) {
        command_args.push_back(std::get<std::string>(item));
      }
    }

    // Use async command to prevent UI blocking during network operations
    // Move result into shared_ptr for safe capture in callback
    auto result_ptr =
        std::make_shared<std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>>(std::move(result));
    std::string cmd_name = command_args.empty() ? "unknown" : command_args[0];
    player_->CommandAsync(command_args, [this, result_ptr, cmd_name](int error, const mpv_node* command_result) {
      // `loadfile` answers with the playlist entry it created so Dart can tie
      // the load to that source's start-file/playback-restart/end-file events;
      // every other command answers null. The node belongs to the reply event,
      // so the id is read here, before the hop to the platform thread.
      int64_t playlist_entry_id = 0;
      const bool has_playlist_entry =
          error >= 0 && plezy::mpv_common::PlaylistEntryIdFromCommandResult(command_result, &playlist_entry_id);
      PostToPlatformThread([result_ptr, cmd_name, error, has_playlist_entry, playlist_entry_id]() {
        if (error < 0) {
          (*result_ptr)
              ->Error("COMMAND_FAILED", "MPV command failed: " + cmd_name + " (error " + std::to_string(error) + ")");
        } else if (has_playlist_entry) {
          flutter::EncodableMap reply;
          reply[flutter::EncodableValue("playlistEntryId")] = flutter::EncodableValue(playlist_entry_id);
          (*result_ptr)->Success(flutter::EncodableValue(reply));
        } else {
          (*result_ptr)->Success();
        }
      });
    });
    return;  // Response will be sent asynchronously
  } else if (method == "setProperty") {
    if (!player_ || !player_->IsInitialized()) {
      result->Error(plezy::mpv_common::kSetPropertyNotInitializedCode, "Player not initialized");
      return;
    }

    const auto* args = method_call.arguments();
    if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
      result->Error("INVALID_ARGS", "Expected map argument");
      return;
    }

    const auto& map = std::get<flutter::EncodableMap>(*args);
    auto name_it = map.find(flutter::EncodableValue("name"));
    auto value_it = map.find(flutter::EncodableValue("value"));

    if (name_it == map.end() || !std::holds_alternative<std::string>(name_it->second)) {
      result->Error("INVALID_ARGS", "Missing 'name'");
      return;
    }
    if (value_it == map.end() || !std::holds_alternative<std::string>(value_it->second)) {
      result->Error("INVALID_ARGS", "Missing 'value'");
      return;
    }

    auto result_ptr =
        std::make_shared<std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>>(std::move(result));
    player_->SetPropertyAsync(
        std::get<std::string>(name_it->second), std::get<std::string>(value_it->second), [this, result_ptr](int error) {
          PostToPlatformThread([result_ptr, error]() {
            if (plezy::mpv_common::SetPropertyStatusSucceeded(error)) {
              (*result_ptr)->Success();
            } else {
              const auto* error_code = plezy::mpv_common::SetPropertyErrorCode(error);
              const auto description = error == MPV_ERROR_UNINITIALIZED
                                           ? std::string("Player not initialized")
                                           : plezy::mpv_common::SetPropertyErrorDescription(error);
              (*result_ptr)->Error(error_code, description);
            }
          });
        });
    return;
  } else if (method == "setLogLevel") {
    if (!player_ || !player_->IsInitialized()) {
      result->Error("NOT_INITIALIZED", "Player not initialized");
      return;
    }

    const auto* args = method_call.arguments();
    if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
      result->Error("INVALID_ARGS", "Expected map argument");
      return;
    }

    const auto& map = std::get<flutter::EncodableMap>(*args);
    auto level_it = map.find(flutter::EncodableValue("level"));

    if (level_it == map.end() || !std::holds_alternative<std::string>(level_it->second)) {
      result->Error("INVALID_ARGS", "Missing 'level'");
      return;
    }

    player_->SetLogLevel(std::get<std::string>(level_it->second));
    result->Success();
  } else if (method == "getProperty") {
    if (!player_ || !player_->IsInitialized()) {
      result->Error("NOT_INITIALIZED", "Player not initialized");
      return;
    }

    const auto* args = method_call.arguments();
    if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
      result->Error("INVALID_ARGS", "Expected map argument");
      return;
    }

    const auto& map = std::get<flutter::EncodableMap>(*args);
    auto name_it = map.find(flutter::EncodableValue("name"));

    if (name_it == map.end() || !std::holds_alternative<std::string>(name_it->second)) {
      result->Error("INVALID_ARGS", "Missing 'name'");
      return;
    }

    auto result_ptr =
        std::make_shared<std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>>(std::move(result));
    player_->GetPropertyAsync(
        std::get<std::string>(name_it->second), [this, result_ptr](int error, const std::string& value) {
          PostToPlatformThread([result_ptr, error, value]() {
            if (error < 0 || value.empty()) {
              (*result_ptr)->Success();
            } else {
              (*result_ptr)->Success(flutter::EncodableValue(value));
            }
          });
        });
    return;
  } else if (method == "observeProperty") {
    if (!player_ || !player_->IsInitialized()) {
      result->Error("NOT_INITIALIZED", "Player not initialized");
      return;
    }

    const auto* args = method_call.arguments();
    if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
      result->Error("INVALID_ARGS", "Expected map argument");
      return;
    }

    const auto& map = std::get<flutter::EncodableMap>(*args);
    auto name_it = map.find(flutter::EncodableValue("name"));
    auto format_it = map.find(flutter::EncodableValue("format"));
    auto id_it = map.find(flutter::EncodableValue("id"));

    if (name_it == map.end() || !std::holds_alternative<std::string>(name_it->second)) {
      result->Error("INVALID_ARGS", "Missing 'name'");
      return;
    }
    if (format_it == map.end() || !std::holds_alternative<std::string>(format_it->second)) {
      result->Error("INVALID_ARGS", "Missing 'format'");
      return;
    }
    if (id_it == map.end() || !std::holds_alternative<int32_t>(id_it->second)) {
      result->Error("INVALID_ARGS", "Missing 'id'");
      return;
    }

    player_->ObserveProperty(
        std::get<std::string>(name_it->second), std::get<std::string>(format_it->second),
        std::get<int32_t>(id_it->second));
    result->Success();
  } else if (method == "setVisible") {
    if (audio_only_) {
      // Windowless core: nothing to show or hide, tolerate as a success no-op.
      result->Success();
      return;
    }

    const auto* args = method_call.arguments();
    if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
      result->Error("INVALID_ARGS", "Expected map argument");
      return;
    }

    const auto& map = std::get<flutter::EncodableMap>(*args);
    auto visible_it = map.find(flutter::EncodableValue("visible"));

    if (visible_it == map.end() || !std::holds_alternative<bool>(visible_it->second)) {
      result->Error("INVALID_ARGS", "Missing 'visible'");
      return;
    }

    bool visible = std::get<bool>(visible_it->second);
    requested_video_visible_ = visible;

    if (player_) {
      player_->SetVisible(detached_window_ != nullptr || visible);
    }

    result->Success();
  } else if (method == "setVideoRect") {
    if (audio_only_) {
      // Windowless core: no rect to position, tolerate as a success no-op.
      result->Success();
      return;
    }

    const auto* args = method_call.arguments();
    if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
      result->Error("INVALID_ARGS", "Expected map argument");
      return;
    }

    const auto& map = std::get<flutter::EncodableMap>(*args);

    auto get_int = [&map](const char* key) -> int {
      auto it = map.find(flutter::EncodableValue(key));
      if (it != map.end()) {
        if (std::holds_alternative<int32_t>(it->second)) {
          return std::get<int32_t>(it->second);
        } else if (std::holds_alternative<int64_t>(it->second)) {
          return static_cast<int>(std::get<int64_t>(it->second));
        }
      }
      return 0;
    };

    auto get_double = [&map](const char* key) -> double {
      auto it = map.find(flutter::EncodableValue(key));
      if (it != map.end() && std::holds_alternative<double>(it->second)) {
        return std::get<double>(it->second);
      }
      return 1.0;
    };

    RECT rect;
    rect.left = get_int("left");
    rect.top = get_int("top");
    rect.right = get_int("right");
    rect.bottom = get_int("bottom");
    double dpr = get_double("devicePixelRatio");

    if (player_) {
      if (detached_window_)
        video_rect_ = rect;
      else
        player_->SetRect(rect, dpr);
    }

    result->Success();
  } else if (audio_only_ && method == "updateFrame") {
    // No frames to pump on the windowless core; tolerate as a success no-op.
    result->Success();
  } else if (method == "isInitialized") {
    bool initialized = player_ && player_->IsInitialized();
    result->Success(flutter::EncodableValue(initialized));

    // --- Display mode matching (video instance only) ---
  } else if (!audio_only_ && method == "getDisplayModes") {
    HWND hwnd = GetWindow();
    auto modes = display_mode_manager_.EnumerateDisplayModes(hwnd);
    flutter::EncodableList list;
    for (const auto& mode : modes) {
      list.push_back(flutter::EncodableValue(DisplayModeToMap(mode)));
    }
    result->Success(flutter::EncodableValue(list));
  } else if (!audio_only_ && method == "getCurrentDisplayMode") {
    HWND hwnd = GetWindow();
    auto mode = display_mode_manager_.GetCurrentMode(hwnd);
    result->Success(flutter::EncodableValue(DisplayModeToMap(mode)));
  } else if (!audio_only_ && method == "setDisplayMode") {
    const auto* args = method_call.arguments();
    if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
      result->Error("INVALID_ARGS", "Expected map argument");
      return;
    }
    const auto& map = std::get<flutter::EncodableMap>(*args);
    auto get_int = [&map](const char* key) -> int {
      auto it = map.find(flutter::EncodableValue(key));
      if (it != map.end() && std::holds_alternative<int32_t>(it->second)) return std::get<int32_t>(it->second);
      return 0;
    };
    HWND hwnd = GetWindow();
    bool success =
        display_mode_manager_.SetDisplayMode(hwnd, get_int("width"), get_int("height"), get_int("refreshRate"));
    result->Success(flutter::EncodableValue(success));
  } else if (!audio_only_ && method == "restoreDisplayMode") {
    HWND hwnd = GetWindow();
    bool success = display_mode_manager_.RestoreOriginalMode(hwnd);
    result->Success(flutter::EncodableValue(success));
  } else if (!audio_only_ && method == "isHDRSupported") {
    HWND hwnd = GetWindow();
    result->Success(flutter::EncodableValue(display_mode_manager_.IsHDRSupported(hwnd)));
  } else if (!audio_only_ && method == "isHDREnabled") {
    HWND hwnd = GetWindow();
    result->Success(flutter::EncodableValue(display_mode_manager_.IsHDREnabled(hwnd)));
  } else if (!audio_only_ && method == "setSystemHDR") {
    const auto* args = method_call.arguments();
    if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
      result->Error("INVALID_ARGS", "Expected map argument");
      return;
    }
    const auto& map = std::get<flutter::EncodableMap>(*args);
    auto it = map.find(flutter::EncodableValue("enabled"));
    if (it == map.end() || !std::holds_alternative<bool>(it->second)) {
      result->Error("INVALID_ARGS", "Missing 'enabled'");
      return;
    }
    bool enabled = std::get<bool>(it->second);
    HWND hwnd = GetWindow();
    bool success = display_mode_manager_.SetHDREnabled(hwnd, enabled);
    result->Success(flutter::EncodableValue(success));
  } else if (!audio_only_ && method == "restoreSystemHDR") {
    HWND hwnd = GetWindow();
    bool success = display_mode_manager_.RestoreOriginalHDRState(hwnd);
    result->Success(flutter::EncodableValue(success));
  } else if (!audio_only_ && method == "isModeChanged") {
    result->Success(flutter::EncodableValue(display_mode_manager_.IsModeChanged()));
  } else if (!audio_only_ && method == "isHDRChanged") {
    result->Success(flutter::EncodableValue(display_mode_manager_.IsHDRChanged()));
  } else {
    result->NotImplemented();
  }
}

void MpvPlayerPlugin::SendEvent(uint64_t player_generation, const flutter::EncodableValue& event) {
  // mpv events arrive on the mpv event thread; Flutter channel APIs are
  // platform-thread-only. Capture the player generation at receipt so queued
  // property/event callbacks from a disposed player cannot publish into its
  // replacement's stream.
  PostToPlatformThread([this, player_generation, event]() {
    if (player_generation_.load(std::memory_order_acquire) == player_generation && event_sink_) {
      event_sink_->Success(event);
    }
  });
}

}  // namespace mpv
