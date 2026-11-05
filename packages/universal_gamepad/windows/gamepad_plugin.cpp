#include "gamepad_plugin.h"

// This must be included before many other Windows headers.
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <atomic>
#include <memory>
#include <optional>
#include <string>

namespace gamepad {

// static
void GamepadPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  // Create the stream handler (shared between plugin and SDL manager).
  auto stream_handler = std::make_shared<GamepadStreamHandler>();

  // Create the SDL manager.
  auto sdl_manager = std::make_unique<SdlManager>(stream_handler);

  // Set up the MethodChannel.
  auto method_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "dev.universal_gamepad/methods", &flutter::StandardMethodCodec::GetInstance());

  // Set up the EventChannel.
  auto event_channel = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(), "dev.universal_gamepad/events", &flutter::StandardMethodCodec::GetInstance());

  auto window_handle = std::make_shared<std::atomic<HWND>>(nullptr);
  const int window_proc_delegate_id = registrar->RegisterTopLevelWindowProcDelegate(
      [stream_handler, window_handle](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        if (window_handle->load() == nullptr) {
          window_handle->store(hwnd);
          // Events sent before the HWND was known couldn't be posted;
          // flush them now that we're on the platform thread.
          stream_handler->FlushQueuedEvents();
        }
        if (message == GamepadStreamHandler::kFlushMessage) {
          stream_handler->FlushQueuedEvents();
          return std::optional<LRESULT>(0);
        }
        return std::optional<LRESULT>();
      });

  stream_handler->SetWakeCallback([window_handle]() -> bool {
    const HWND hwnd = window_handle->load();
    if (hwnd == nullptr) {
      return false;
    }
    return ::PostMessage(hwnd, GamepadStreamHandler::kFlushMessage, 0, 0) != 0;
  });

  // Create the plugin instance.
  auto plugin = std::make_unique<GamepadPlugin>(
      std::move(stream_handler), std::move(sdl_manager), registrar, window_proc_delegate_id);

  // Register the method call handler.
  method_channel->SetMethodCallHandler([plugin_pointer = plugin.get()](const auto& call, auto result) {
    plugin_pointer->HandleMethodCall(call, std::move(result));
  });

  // Register the stream handler. SetStreamHandler requires a unique_ptr, so
  // we use a ForwardingStreamHandler that delegates to the shared handler
  // that the SdlManager also sends events through.
  event_channel->SetStreamHandler(std::make_unique<ForwardingStreamHandler>(plugin->stream_handler_));

  // Start polling immediately so we capture connections that happen before
  // the Dart side starts listening.
  plugin->sdl_manager_->StartPolling();

  // Transfer ownership to the registrar.
  registrar->AddPlugin(std::move(plugin));
}

GamepadPlugin::GamepadPlugin(
    std::shared_ptr<GamepadStreamHandler> stream_handler, std::unique_ptr<SdlManager> sdl_manager,
    flutter::PluginRegistrarWindows* registrar, int window_proc_delegate_id)
    : stream_handler_(std::move(stream_handler)),
      sdl_manager_(std::move(sdl_manager)),
      registrar_(registrar),
      window_proc_delegate_id_(window_proc_delegate_id) {}

GamepadPlugin::~GamepadPlugin() {
  if (sdl_manager_) {
    sdl_manager_->StopPolling();
  }
  if (registrar_) {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_delegate_id_);
  }
}

void GamepadPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();

  if (method.rfind("plezy", 0) == 0) {
    const auto* args = method_call.arguments() ? std::get_if<flutter::EncodableMap>(method_call.arguments()) : nullptr;
    auto field = [args](const char* key) -> const flutter::EncodableValue* {
      if (!args) return nullptr;
      auto found = args->find(flutter::EncodableValue(key));
      return found == args->end() ? nullptr : &found->second;
    };
    auto integer = [&field](const char* key, int maximum) {
      const auto* value = field(key);
      int64_t number = -1;
      if (value) {
        if (const auto* small = std::get_if<int32_t>(value))
          number = *small;
        else if (const auto* large = std::get_if<int64_t>(value))
          number = *large;
      }
      return number >= 0 && number <= maximum ? int(number) : -1;
    };
    const auto* owner = field("owner");
    const auto* token = owner ? std::get_if<std::string>(owner) : nullptr;
    const std::string text = token ? *token : "";
    if (method == "plezyClaimEffects")
      result->Success(flutter::EncodableValue(sdl_manager_->ClaimEffects(text)));
    else if (method == "plezyReleaseEffects") {
      sdl_manager_->ReleaseEffects(text);
      result->Success();
    } else if (method == "plezyControllerState")
      result->Success(flutter::EncodableValue(sdl_manager_->EffectsState(text, integer("deviceId", INT32_MAX))));
    else if (method == "plezyControllerEffects") {
      const auto* value = field("sensors");
      const auto* enabled = value ? std::get_if<bool>(value) : nullptr;
      const std::array<int, 6> values{integer("low", 65535),          integer("high", 65535),
                                      integer("duration", 1000),      integer("leftTrigger", 65535),
                                      integer("rightTrigger", 65535), integer("triggerDuration", 1000)};
      result->Success(flutter::EncodableValue(sdl_manager_->ApplyEffects(
          text, integer("deviceId", INT32_MAX), integer("flags", 7), values, enabled && *enabled)));
    } else
      result->NotImplemented();
    return;
  }
  if (method == "listGamepads") {
    auto gamepads = sdl_manager_->ListGamepads();
    result->Success(flutter::EncodableValue(gamepads));
  } else if (method == "dispose") {
    sdl_manager_->StopPolling();
    result->Success();
  } else if (method == "pause") {
    sdl_manager_->Pause();
    result->Success();
  } else if (method == "resume") {
    sdl_manager_->Resume();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace gamepad

// ---------------------------------------------------------------------------
// C API wrapper - the entry point that the Flutter Windows embedder calls.
// ---------------------------------------------------------------------------

extern "C" {

__declspec(dllexport) void GamepadPluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  gamepad::GamepadPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}

}  // extern "C"
