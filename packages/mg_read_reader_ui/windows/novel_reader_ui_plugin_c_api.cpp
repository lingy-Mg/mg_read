#include "include/novel_reader_ui/novel_reader_ui_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "novel_reader_ui_plugin.h"

void NovelReaderUiPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  novel_reader_ui::NovelReaderUiPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
