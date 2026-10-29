#ifndef FLUTTER_PLUGIN_GAMEPAD_PLUGIN_H_
#define FLUTTER_PLUGIN_GAMEPAD_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

#include "gamepad_stream_handler.h"
#include "sdl_manager.h"

namespace gamepad {

/// Windows implementation of the gamepad Flutter plugin.
///
/// Registers an EventChannel (`dev.universal_gamepad/events`) and a
/// MethodChannel (`dev.universal_gamepad/methods`) with the Flutter engine.
/// Uses SDL3 to detect and poll gamepads on a background thread.
class GamepadPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  GamepadPlugin(
      std::shared_ptr<GamepadStreamHandler> stream_handler,
      std::unique_ptr<SdlManager> sdl_manager,
      flutter::PluginRegistrarWindows* registrar,
      int window_proc_delegate_id);

  ~GamepadPlugin() override;

  // Disallow copy and assign.
  GamepadPlugin(const GamepadPlugin&) = delete;
  GamepadPlugin& operator=(const GamepadPlugin&) = delete;

 private:
  /// Handles MethodChannel calls from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::shared_ptr<GamepadStreamHandler> stream_handler_;
  std::unique_ptr<SdlManager> sdl_manager_;
  flutter::PluginRegistrarWindows* registrar_;
  int window_proc_delegate_id_;
};

}  // namespace gamepad

#endif  // FLUTTER_PLUGIN_GAMEPAD_PLUGIN_H_
