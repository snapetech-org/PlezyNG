#include "os_media_controls/os_media_controls_plugin.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>

// Windows headers
#include <objbase.h>
#include <DispatcherQueue.h>
#include <commctrl.h>

// Subclass ID for our window hook
#define SMTC_SUBCLASS_ID 1

// Additional WinRT headers for SMTC
#include <winrt/Windows.Media.Playback.h>
#include <winrt/Windows.System.h>

using namespace winrt;
using namespace winrt::Windows::Media;
using namespace winrt::Windows::Storage::Streams;
using namespace winrt::Windows::Foundation;

// Custom message ID for posting work to SMTC thread
#define WM_SMTC_WORK (WM_USER + 1)
// Custom message ID for posting events to main thread
#define WM_SMTC_EVENT (WM_USER + 2)

namespace os_media_controls {

// static
void OsMediaControlsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto method_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "com.edde746.os_media_controls/methods",
          &flutter::StandardMethodCodec::GetInstance());

  auto event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), "com.edde746.os_media_controls/events",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<OsMediaControlsPlugin>(registrar);

  method_channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  auto handler = std::make_unique<flutter::StreamHandlerFunctions<>>(
      [plugin_pointer =
           plugin.get()](const flutter::EncodableValue *arguments,
                         std::unique_ptr<flutter::EventSink<>> &&events)
          -> std::unique_ptr<flutter::StreamHandlerError<>> {
        plugin_pointer->event_sink_ = std::move(events);
        return nullptr;
      },
      [plugin_pointer = plugin.get()](const flutter::EncodableValue *arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<>> {
        plugin_pointer->event_sink_.reset();
        return nullptr;
      });

  event_channel->SetStreamHandler(std::move(handler));

  registrar->AddPlugin(std::move(plugin));
}

OsMediaControlsPlugin::OsMediaControlsPlugin(
    flutter::PluginRegistrarWindows *registrar)
    : registrar_(registrar) {

  // Get main window handle and subclass it for event dispatching
  auto view = registrar_->GetView();
  if (view) {
    main_window_ = view->GetNativeWindow();
    if (main_window_) {
      SetWindowSubclass(main_window_, WndProcHook, SMTC_SUBCLASS_ID,
                        reinterpret_cast<DWORD_PTR>(this));
    }
  }

  // Start dedicated STA thread for SMTC operations
  smtc_thread_running_ = true;
  smtc_thread_ = std::thread(&OsMediaControlsPlugin::SmtcThreadProc, this);

  // Wait for thread to initialize and get its ID
  while (smtc_thread_id_.load() == 0 && smtc_thread_running_) {
    Sleep(1);
  }
}

OsMediaControlsPlugin::~OsMediaControlsPlugin() {
  // Remove window subclass
  if (main_window_) {
    RemoveWindowSubclass(main_window_, WndProcHook, SMTC_SUBCLASS_ID);
  }

  // Signal thread to stop
  DWORD smtc_thread_id = smtc_thread_id_.load();
  if (smtc_thread_running_ && smtc_thread_id != 0) {
    smtc_thread_running_ = false;
    PostThreadMessage(smtc_thread_id, WM_QUIT, 0, 0);
  }

  // Wait for thread to finish
  if (smtc_thread_.joinable()) {
    smtc_thread_.join();
  }
}

LRESULT CALLBACK OsMediaControlsPlugin::WndProcHook(
    HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam,
    UINT_PTR subclassId, DWORD_PTR refData) {
  if (msg == WM_SMTC_EVENT) {
    auto* plugin = reinterpret_cast<OsMediaControlsPlugin*>(refData);
    if (plugin) {
      plugin->ProcessPendingEvents();
    }
    return 0;
  }
  return DefSubclassProc(hwnd, msg, wParam, lParam);
}

void OsMediaControlsPlugin::ProcessPendingEvents() {
  std::lock_guard<std::mutex> lock(events_mutex_);
  while (!pending_events_.empty()) {
    auto event = pending_events_.front();
    pending_events_.pop();
    SendEvent(event);
  }
}

void OsMediaControlsPlugin::QueueEventForMainThread(const flutter::EncodableMap& event) {
  {
    std::lock_guard<std::mutex> lock(events_mutex_);
    pending_events_.push(event);
  }
  // Post message to main window to trigger event processing
  if (main_window_) {
    PostMessage(main_window_, WM_SMTC_EVENT, 0, 0);
  }
}

void OsMediaControlsPlugin::SmtcThreadProc() {
  // Initialize COM as STA on this thread
  HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(hr) && hr != S_FALSE) {
    OutputDebugStringW(L"Failed to initialize COM as STA on SMTC thread\n");
    smtc_thread_running_ = false;
    return;
  }

  // Create DispatcherQueue for this thread (required for MediaPlayer)
  DispatcherQueueOptions options{
      sizeof(DispatcherQueueOptions),
      DQTYPE_THREAD_CURRENT,
      DQTAT_COM_NONE
  };

  ABI::Windows::System::IDispatcherQueueController* controller = nullptr;
  hr = CreateDispatcherQueueController(options, &controller);
  if (SUCCEEDED(hr) && controller) {
    winrt::attach_abi(dispatcher_queue_controller_, controller);
  }

  // Create message queue
  MSG msg;
  PeekMessage(&msg, nullptr, 0, 0, PM_NOREMOVE);

  // Store thread ID after the message queue exists so PostThreadMessage works.
  smtc_thread_id_.store(GetCurrentThreadId());

  // Initialize SMTC with MediaPlayer
  InitializeSMTCOnThread();

  // Message loop
  while (smtc_thread_running_) {
    BOOL ret = GetMessage(&msg, nullptr, 0, 0);
    if (ret == 0 || ret == -1) {
      break;
    }

    if (msg.message == WM_SMTC_WORK) {
      auto* func = reinterpret_cast<std::function<void()>*>(msg.lParam);
      if (func) {
        (*func)();
        delete func;
      }
    } else {
      TranslateMessage(&msg);
      DispatchMessage(&msg);
    }
  }

  // Cleanup
  CleanupSMTC();
  CoUninitialize();
}

void OsMediaControlsPlugin::PostToSmtcThread(std::function<void()> func) {
  DWORD smtc_thread_id = smtc_thread_id_.load();
  if (smtc_thread_id != 0 && smtc_thread_running_) {
    auto* funcPtr = new std::function<void()>(std::move(func));
    if (!PostThreadMessage(smtc_thread_id, WM_SMTC_WORK, 0,
                           reinterpret_cast<LPARAM>(funcPtr))) {
      delete funcPtr;
    }
  }
}

void OsMediaControlsPlugin::InitializeSMTCOnThread() {
  try {
    // Create MediaPlayer instance - this is the correct way to get SMTC for desktop apps
    media_player_ = winrt::Windows::Media::Playback::MediaPlayer();

    // Get SMTC from MediaPlayer
    smtc_ = media_player_.SystemMediaTransportControls();

    // Disable automatic command manager integration (we control SMTC manually)
    media_player_.CommandManager().IsEnabled(false);

    // Enable basic controls by default
    smtc_.IsPlayEnabled(true);
    smtc_.IsPauseEnabled(true);
    smtc_.IsNextEnabled(false);
    smtc_.IsPreviousEnabled(false);
    smtc_.IsStopEnabled(false);

    // Initialize display updater with media type
    auto updater = smtc_.DisplayUpdater();
    updater.Type(MediaPlaybackType::Music);
    updater.AppMediaId(L"com.edde746.os_media_controls");
    updater.Update();

    // Enable SMTC
    smtc_.IsEnabled(true);

    // Register button pressed event handler
    button_pressed_token_ = smtc_.ButtonPressed(
        [this](SystemMediaTransportControls const &,
               SystemMediaTransportControlsButtonPressedEventArgs const &args) {
          HandleButtonPressed(args.Button());
        });

    // Register playback position change event handler (for seek)
    position_change_token_ = smtc_.PlaybackPositionChangeRequested(
        [this](SystemMediaTransportControls const &,
               PlaybackPositionChangeRequestedEventArgs const &args) {
          double positionSeconds =
              args.RequestedPlaybackPosition().count() / 10000000.0;

          flutter::EncodableMap event;
          event[flutter::EncodableValue("type")] =
              flutter::EncodableValue("seek");
          event[flutter::EncodableValue("position")] =
              flutter::EncodableValue(positionSeconds);

          QueueEventForMainThread(event);
        });

    OutputDebugStringW(L"SMTC initialized successfully with MediaPlayer\n");

  } catch (winrt::hresult_error const &ex) {
    OutputDebugStringW(L"SMTC initialization failed: ");
    OutputDebugStringW(ex.message().c_str());
    OutputDebugStringW(L"\n");
  }
}

void OsMediaControlsPlugin::InitializeSMTCWithWindow(HWND hwnd) {
  // Not used - MediaPlayer approach is preferred
}

void OsMediaControlsPlugin::CleanupSMTC() {
  if (smtc_) {
    try {
      smtc_.ButtonPressed(button_pressed_token_);
      smtc_.PlaybackPositionChangeRequested(position_change_token_);
      smtc_.DisplayUpdater().ClearAll();
      smtc_.DisplayUpdater().Update();
      smtc_.IsEnabled(false);
      smtc_ = nullptr;
    } catch (...) {
    }
  }
  if (media_player_) {
    media_player_.Close();
    media_player_ = nullptr;
  }
  if (dispatcher_queue_controller_) {
    dispatcher_queue_controller_ = nullptr;
  }
}

void OsMediaControlsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto &method_name = method_call.method_name();

  if (method_name == "setMetadata") {
    SetMetadata(method_call.arguments());
    result->Success(flutter::EncodableValue(nullptr));
  } else if (method_name == "setPlaybackState") {
    SetPlaybackState(method_call.arguments());
    result->Success(flutter::EncodableValue(nullptr));
  } else if (method_name == "enableControls") {
    if (auto args = method_call.arguments()) {
      if (std::holds_alternative<flutter::EncodableList>(*args)) {
        const auto &list = std::get<flutter::EncodableList>(*args);
        for (const auto &item : list) {
          if (std::holds_alternative<std::string>(item)) {
            std::string control = std::get<std::string>(item);
            PostToSmtcThread([this, control]() {
              EnableControlOnThread(control);
            });
          }
        }
      }
    }
    result->Success(flutter::EncodableValue(nullptr));
  } else if (method_name == "disableControls") {
    if (auto args = method_call.arguments()) {
      if (std::holds_alternative<flutter::EncodableList>(*args)) {
        const auto &list = std::get<flutter::EncodableList>(*args);
        for (const auto &item : list) {
          if (std::holds_alternative<std::string>(item)) {
            std::string control = std::get<std::string>(item);
            PostToSmtcThread([this, control]() {
              DisableControlOnThread(control);
            });
          }
        }
      }
    }
    result->Success(flutter::EncodableValue(nullptr));
  } else if (method_name == "setSkipIntervals") {
    // Windows doesn't support custom skip intervals
    result->Success(flutter::EncodableValue(nullptr));
  } else if (method_name == "setQueueInfo") {
    // Windows doesn't display queue info
    result->Success(flutter::EncodableValue(nullptr));
  } else if (method_name == "clear") {
    PostToSmtcThread([this]() {
      ClearOnThread();
    });
    result->Success(flutter::EncodableValue(nullptr));
  } else {
    result->NotImplemented();
  }
}

void OsMediaControlsPlugin::SetMetadata(const flutter::EncodableValue *args) {
  if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
    return;
  }

  const auto &map = std::get<flutter::EncodableMap>(*args);

  std::string title = GetStringFromMap(map, "title");
  std::string artist = GetStringFromMap(map, "artist");
  std::string album = GetStringFromMap(map, "album");
  std::string albumArtist = GetStringFromMap(map, "albumArtist");
  std::string artworkUri = GetStringFromMap(map, "artworkUrl");
  double duration = GetDoubleFromMap(map, "duration");

  PostToSmtcThread([this, title, artist, album, albumArtist, artworkUri,
                    duration]() {
    SetMetadataOnThread(title, artist, album, albumArtist, artworkUri, duration);
  });
}

void OsMediaControlsPlugin::SetMetadataOnThread(
    const std::string& title, const std::string& artist,
    const std::string& album, const std::string& albumArtist,
    const std::string& artworkUri, double duration) {

  if (!smtc_) return;

  try {
    if (duration > 0) {
      current_duration_ = duration;
    }

    auto updater = smtc_.DisplayUpdater();
    updater.Type(MediaPlaybackType::Music);

    auto musicProps = updater.MusicProperties();

    if (!title.empty()) {
      musicProps.Title(StringToHString(title));
    }
    if (!artist.empty()) {
      musicProps.Artist(StringToHString(artist));
    }
    if (!album.empty()) {
      musicProps.AlbumTitle(StringToHString(album));
    }
    if (!albumArtist.empty()) {
      musicProps.AlbumArtist(StringToHString(albumArtist));
    }

    if (!artworkUri.empty()) {
      auto streamRef = CreateStreamReferenceFromUri(artworkUri);
      if (streamRef) {
        updater.Thumbnail(streamRef);
      }
    }

    updater.Update();

  } catch (winrt::hresult_error const &) {
  }
}

void OsMediaControlsPlugin::SetPlaybackState(
    const flutter::EncodableValue *args) {
  if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
    return;
  }

  const auto &map = std::get<flutter::EncodableMap>(*args);

  std::string state = GetStringFromMap(map, "state");
  double position = GetDoubleFromMap(map, "position");
  double duration = GetDoubleFromMap(map, "duration");
  double speed = GetDoubleFromMap(map, "speed");

  PostToSmtcThread([this, state, position, duration, speed]() {
    SetPlaybackStateOnThread(state, position, duration, speed);
  });
}

void OsMediaControlsPlugin::SetPlaybackStateOnThread(
    const std::string& state, double position, double duration, double speed) {

  if (!smtc_) return;

  try {
    // Set playback status and ensure SMTC is enabled for active states
    if (state == "playing") {
      smtc_.IsEnabled(true);
      smtc_.PlaybackStatus(MediaPlaybackStatus::Playing);
    } else if (state == "paused") {
      smtc_.IsEnabled(true);
      smtc_.PlaybackStatus(MediaPlaybackStatus::Paused);
    } else if (state == "stopped") {
      smtc_.IsEnabled(true);
      smtc_.PlaybackStatus(MediaPlaybackStatus::Stopped);
    } else if (state == "none") {
      smtc_.PlaybackStatus(MediaPlaybackStatus::Closed);
      smtc_.IsEnabled(false);
    }

    // Update timeline properties for seek bar
    SystemMediaTransportControlsTimelineProperties timeline;

    int64_t positionTicks = static_cast<int64_t>(position * 10000000.0);
    timeline.Position(winrt::Windows::Foundation::TimeSpan(positionTicks));
    timeline.MinSeekTime(winrt::Windows::Foundation::TimeSpan(0));

    double timeline_duration = duration > 0 ? duration : current_duration_;
    if (timeline_duration > 0) {
      int64_t durationTicks = static_cast<int64_t>(timeline_duration * 10000000.0);
      timeline.EndTime(winrt::Windows::Foundation::TimeSpan(durationTicks));
      timeline.MaxSeekTime(timeline.EndTime());
    }

    smtc_.UpdateTimelineProperties(timeline);
    smtc_.PlaybackRate(speed);

  } catch (winrt::hresult_error const &) {
  }
}

void OsMediaControlsPlugin::ClearOnThread() {
  if (!smtc_) return;

  try {
    smtc_.DisplayUpdater().ClearAll();
    smtc_.DisplayUpdater().Update();
    smtc_.PlaybackStatus(MediaPlaybackStatus::Closed);
    smtc_.IsEnabled(false);
    current_duration_ = 0.0;
  } catch (...) {
  }
}

void OsMediaControlsPlugin::HandleButtonPressed(
    SystemMediaTransportControlsButton button) {

  flutter::EncodableMap event;

  switch (button) {
  case SystemMediaTransportControlsButton::Play:
    event[flutter::EncodableValue("type")] = flutter::EncodableValue("play");
    break;

  case SystemMediaTransportControlsButton::Pause:
    event[flutter::EncodableValue("type")] = flutter::EncodableValue("pause");
    break;

  case SystemMediaTransportControlsButton::Stop:
    event[flutter::EncodableValue("type")] = flutter::EncodableValue("stop");
    break;

  case SystemMediaTransportControlsButton::Next:
    event[flutter::EncodableValue("type")] = flutter::EncodableValue("next");
    break;

  case SystemMediaTransportControlsButton::Previous:
    event[flutter::EncodableValue("type")] =
        flutter::EncodableValue("previous");
    break;

  default:
    return;
  }

  QueueEventForMainThread(event);
}

void OsMediaControlsPlugin::EnableControlOnThread(const std::string &control) {
  if (!smtc_) return;

  try {
    if (control == "play") {
      smtc_.IsPlayEnabled(true);
    } else if (control == "pause") {
      smtc_.IsPauseEnabled(true);
    } else if (control == "stop") {
      smtc_.IsStopEnabled(true);
    } else if (control == "next") {
      smtc_.IsNextEnabled(true);
    } else if (control == "previous") {
      smtc_.IsPreviousEnabled(true);
    }
  } catch (winrt::hresult_error const &) {
  }
}

void OsMediaControlsPlugin::DisableControlOnThread(const std::string &control) {
  if (!smtc_) return;

  try {
    if (control == "play") {
      smtc_.IsPlayEnabled(false);
    } else if (control == "pause") {
      smtc_.IsPauseEnabled(false);
    } else if (control == "stop") {
      smtc_.IsStopEnabled(false);
    } else if (control == "next") {
      smtc_.IsNextEnabled(false);
    } else if (control == "previous") {
      smtc_.IsPreviousEnabled(false);
    }
  } catch (winrt::hresult_error const &) {
  }
}

winrt::hstring OsMediaControlsPlugin::StringToHString(const std::string &str) {
  if (str.empty())
    return winrt::hstring();

  int size_needed = MultiByteToWideChar(CP_UTF8, 0, str.c_str(),
                                        static_cast<int>(str.length()),
                                        nullptr, 0);
  if (size_needed <= 0)
    return winrt::hstring();

  std::wstring wide(size_needed, 0);
  MultiByteToWideChar(CP_UTF8, 0, str.c_str(),
                      static_cast<int>(str.length()),
                      &wide[0], size_needed);

  return winrt::hstring(wide);
}

RandomAccessStreamReference
OsMediaControlsPlugin::CreateStreamReferenceFromUri(const std::string &uri_str) {
  if (uri_str.empty()) {
    return nullptr;
  }

  try {
    auto uri = winrt::Windows::Foundation::Uri(StringToHString(uri_str));
    return RandomAccessStreamReference::CreateFromUri(uri);
  } catch (...) {
    return nullptr;
  }
}

void OsMediaControlsPlugin::SendEvent(const flutter::EncodableMap &event) {
  if (event_sink_) {
    event_sink_->Success(flutter::EncodableValue(event));
  }
}

std::string
OsMediaControlsPlugin::GetStringFromMap(const flutter::EncodableMap &map,
                                        const std::string &key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it != map.end() && std::holds_alternative<std::string>(it->second)) {
    return std::get<std::string>(it->second);
  }
  return "";
}

double OsMediaControlsPlugin::GetDoubleFromMap(const flutter::EncodableMap &map,
                                               const std::string &key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it != map.end() && std::holds_alternative<double>(it->second)) {
    return std::get<double>(it->second);
  }
  return 0.0;
}

} // namespace os_media_controls
