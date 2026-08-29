//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <file_selector_windows/file_selector_windows.h>
#include <mgread_plugin_runtime/mgread_plugin_runtime_plugin_c_api.h>
#include <novel_reader_ui/novel_reader_ui_plugin_c_api.h>
#include <share_plus/share_plus_windows_plugin_c_api.h>
#include <url_launcher_windows/url_launcher_windows.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  FileSelectorWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FileSelectorWindows"));
  MgreadPluginRuntimePluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("MgreadPluginRuntimePluginCApi"));
  NovelReaderUiPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("NovelReaderUiPluginCApi"));
  SharePlusWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("SharePlusWindowsPluginCApi"));
  UrlLauncherWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("UrlLauncherWindows"));
}
