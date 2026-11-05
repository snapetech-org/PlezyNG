#include "gamepad_plugin.h"

#include <cstring>
#include <memory>

#include "evdev_manager.h"
#include "gamepad_stream_handler.h"

// Plugin state, allocated once per registration and freed on teardown.
struct GamepadPlugin {
  std::unique_ptr<GamepadStreamHandler> stream_handler;
  std::unique_ptr<EvdevManager> manager;
  FlMethodChannel* method_channel;
  FlEventChannel* event_channel;
};

static GamepadPlugin* g_plugin = nullptr;

// ---------------------------------------------------------------------------
// MethodChannel handler
// ---------------------------------------------------------------------------

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call, gpointer user_data) {
  auto* plugin = static_cast<GamepadPlugin*>(user_data);
  const gchar* method = fl_method_call_get_name(method_call);

  if (strncmp(method, "plezy", 5) == 0) {
    auto* args = fl_method_call_get_args(method_call);
    auto field = [args](const char* key) -> FlValue* {
      return args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP ? fl_value_lookup_string(args, key) : nullptr;
    };
    auto integer = [&field](const char* key, int max) -> int {
      auto* value = field(key);
      if (!value || fl_value_get_type(value) != FL_VALUE_TYPE_INT) return -1;
      const auto number = fl_value_get_int(value);
      return number >= 0 && number <= max ? int(number) : -1;
    };
    auto* owner = field("owner");
    const std::string token =
        owner && fl_value_get_type(owner) == FL_VALUE_TYPE_STRING ? fl_value_get_string(owner) : "";
    g_autoptr(FlValue) result = nullptr;
    if (strcmp(method, "plezyClaimEffects") == 0)
      result = fl_value_new_bool(plugin->manager->ClaimEffects(token));
    else if (strcmp(method, "plezyReleaseEffects") == 0) {
      plugin->manager->ReleaseEffects(token);
      result = fl_value_new_null();
    } else if (strcmp(method, "plezyControllerState") == 0)
      result = plugin->manager->EffectsState(token, integer("deviceId", INT32_MAX));
    else if (strcmp(method, "plezyControllerEffects") == 0) {
      auto* sensor = field("sensors");
      const bool enabled = sensor && fl_value_get_type(sensor) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(sensor);
      const std::array<int, 6> values{integer("low", 65535),          integer("high", 65535),
                                      integer("duration", 1000),      integer("leftTrigger", 65535),
                                      integer("rightTrigger", 65535), integer("triggerDuration", 1000)};
      result = fl_value_new_bool(
          plugin->manager->ApplyEffects(token, integer("deviceId", INT32_MAX), integer("flags", 7), values, enabled));
    } else
      result = fl_value_new_bool(false);
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  if (strcmp(method, "pause") == 0) {
    plugin->manager->StopEffects();
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  if (strcmp(method, "listGamepads") == 0) {
    FlValue* result = plugin->manager->ListGamepads();
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    fl_value_unref(result);
    g_autoptr(GError) error = nullptr;
    fl_method_call_respond(method_call, response, &error);
    if (error) {
      g_warning("gamepad: failed to respond to listGamepads: %s", error->message);
    }
  } else if (strcmp(method, "dispose") == 0) {
    plugin->manager->Stop();
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    g_autoptr(GError) error = nullptr;
    fl_method_call_respond(method_call, response, &error);
    if (error) {
      g_warning("gamepad: failed to respond to dispose: %s", error->message);
    }
  } else {
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    g_autoptr(GError) error = nullptr;
    fl_method_call_respond(method_call, response, &error);
    if (error) {
      g_warning("gamepad: failed to respond with not-implemented: %s", error->message);
    }
  }
}

// ---------------------------------------------------------------------------
// Plugin registration (C entry point)
// ---------------------------------------------------------------------------

void gamepad_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  // Clean up any previous registration (defensive).
  if (g_plugin) {
    delete g_plugin;
    g_plugin = nullptr;
  }

  g_plugin = new GamepadPlugin();
  g_plugin->stream_handler = std::make_unique<GamepadStreamHandler>();
  g_plugin->manager = std::make_unique<EvdevManager>();

  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);

  // Set up the MethodChannel.
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();

  g_plugin->method_channel = fl_method_channel_new(messenger, "dev.universal_gamepad/methods", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_plugin->method_channel, method_call_cb, g_plugin, nullptr);

  // Set up the EventChannel.
  g_plugin->event_channel = fl_event_channel_new(messenger, "dev.universal_gamepad/events", FL_METHOD_CODEC(codec));
  g_plugin->stream_handler->SetChannel(g_plugin->event_channel);

  // Start monitoring eagerly so that listGamepads() works before the Dart
  // event stream is subscribed to. SendEvent safely no-ops when not listening.
  GamepadStreamHandler* handler = g_plugin->stream_handler.get();
  EvdevManager* manager = g_plugin->manager.get();

  manager->Start([handler](FlValue* event) { handler->SendEvent(event); });

  // When Dart starts listening, emit connection events for already-connected
  // gamepads. On cancel, do nothing — the monitor keeps running so
  // listGamepads() stays accurate. dispose() calls Stop().
  g_plugin->stream_handler->SetListenCallback([manager](bool listening) {
    if (listening) {
      manager->EmitExistingDevices();
    }
  });
}
