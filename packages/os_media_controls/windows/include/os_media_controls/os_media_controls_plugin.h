#ifndef FLUTTER_PLUGIN_OS_MEDIA_CONTROLS_PLUGIN_H_
#define FLUTTER_PLUGIN_OS_MEDIA_CONTROLS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <atomic>
#include <functional>
#include <queue>
#include <optional>

// C++/WinRT headers for SystemMediaTransportControls
#include <winrt/base.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Media.Playback.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.System.h>
#include <DispatcherQueue.h>

namespace os_media_controls {

class OsMediaControlsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  OsMediaControlsPlugin(flutter::PluginRegistrarWindows *registrar);

  virtual ~OsMediaControlsPlugin();

  // Disallow copy and assign.
  OsMediaControlsPlugin(const OsMediaControlsPlugin&) = delete;
  OsMediaControlsPlugin& operator=(const OsMediaControlsPlugin&) = delete;

 private:
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Event sink for sending events to Dart
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;

  // MediaPlayer instance (required for SMTC on desktop apps)
  winrt::Windows::Media::Playback::MediaPlayer media_player_{nullptr};

  // SystemMediaTransportControls instance
  winrt::Windows::Media::SystemMediaTransportControls smtc_{nullptr};

  // Event tokens for SMTC event handlers
  winrt::event_token button_pressed_token_;
  winrt::event_token position_change_token_;

  // Store registrar reference
  flutter::PluginRegistrarWindows* registrar_;

  // STA thread for SMTC operations
  std::thread smtc_thread_;
  std::atomic<bool> smtc_thread_running_{false};
  std::atomic<DWORD> smtc_thread_id_{0};

  // Main thread window handle for dispatching events back to Flutter
  HWND main_window_{nullptr};

  // Pending events queue (thread-safe)
  std::mutex events_mutex_;
  std::queue<flutter::EncodableMap> pending_events_;

  // Window proc for handling events on main thread
  static LRESULT CALLBACK WndProcHook(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam, UINT_PTR subclassId, DWORD_PTR refData);
  void ProcessPendingEvents();
  void QueueEventForMainThread(const flutter::EncodableMap& event);

  // DispatcherQueue for WinRT (required for MediaPlayer)
  winrt::Windows::System::DispatcherQueueController dispatcher_queue_controller_{nullptr};

  // Duration from the latest metadata update, used for SMTC seek timelines.
  double current_duration_{0.0};

  // Helper methods for plugin functionality
  void SetMetadata(const flutter::EncodableValue *args);
  void SetPlaybackState(const flutter::EncodableValue *args);
  void SendEvent(const flutter::EncodableMap &event);
  std::string GetStringFromMap(const flutter::EncodableMap &map, const std::string &key);
  double GetDoubleFromMap(const flutter::EncodableMap &map, const std::string &key);

  // STA thread methods
  void SmtcThreadProc();
  void PostToSmtcThread(std::function<void()> func);

  // SMTC-specific helper methods (called on STA thread)
  void InitializeSMTCOnThread();
  void InitializeSMTCWithWindow(HWND hwnd);
  void CleanupSMTC();
  void HandleButtonPressed(winrt::Windows::Media::SystemMediaTransportControlsButton button);
  void EnableControlOnThread(const std::string& control);
  void DisableControlOnThread(const std::string& control);
  void SetMetadataOnThread(const std::string& title, const std::string& artist,
                           const std::string& album, const std::string& albumArtist,
                           const std::string& artworkUri, double duration);
  void SetPlaybackStateOnThread(const std::string& state, double position,
                                double duration, double speed);
  void ClearOnThread();

  // WinRT conversion helpers
  winrt::hstring StringToHString(const std::string& str);
  winrt::Windows::Storage::Streams::RandomAccessStreamReference
      CreateStreamReferenceFromUri(const std::string& uri);
};

}  // namespace os_media_controls

#endif  // FLUTTER_PLUGIN_OS_MEDIA_CONTROLS_PLUGIN_H_
