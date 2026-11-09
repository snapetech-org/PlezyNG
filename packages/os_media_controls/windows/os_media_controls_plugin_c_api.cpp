#include "os_media_controls/os_media_controls_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "os_media_controls/os_media_controls_plugin.h"

void OsMediaControlsPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  os_media_controls::OsMediaControlsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
