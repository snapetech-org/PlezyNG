#ifndef FLUTTER_PLUGIN_GAMEPAD_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_GAMEPAD_PLUGIN_C_API_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define GAMEPAD_EXPORT __declspec(dllexport)
#else
#define GAMEPAD_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

GAMEPAD_EXPORT void GamepadPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_GAMEPAD_PLUGIN_C_API_H_
