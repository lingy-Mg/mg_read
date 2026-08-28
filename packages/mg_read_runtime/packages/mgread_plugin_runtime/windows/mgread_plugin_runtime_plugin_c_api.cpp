#include "include/mgread_plugin_runtime/mgread_plugin_runtime_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "mgread_plugin_runtime_plugin.h"

void MgreadPluginRuntimePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  mgread_plugin_runtime::MgreadPluginRuntimePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
