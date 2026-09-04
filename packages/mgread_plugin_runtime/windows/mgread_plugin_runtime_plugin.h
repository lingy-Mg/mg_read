#ifndef FLUTTER_PLUGIN_MGREAD_PLUGIN_RUNTIME_PLUGIN_H_
#define FLUTTER_PLUGIN_MGREAD_PLUGIN_RUNTIME_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

#include "windows_browser_host.h"

namespace mgread_plugin_runtime {

class MgreadPluginRuntimePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
  explicit MgreadPluginRuntimePlugin(HWND flutter_window);
  ~MgreadPluginRuntimePlugin() override;
  MgreadPluginRuntimePlugin(const MgreadPluginRuntimePlugin&) = delete;
  MgreadPluginRuntimePlugin& operator=(const MgreadPluginRuntimePlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  WindowsBrowserHost browser_host_;
};

}  // namespace mgread_plugin_runtime

#endif
