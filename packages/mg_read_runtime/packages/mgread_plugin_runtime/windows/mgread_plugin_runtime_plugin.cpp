#include "mgread_plugin_runtime_plugin.h"

#include <flutter/standard_method_codec.h>

#include <memory>

namespace mgread_plugin_runtime {

void MgreadPluginRuntimePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "mgread_plugin_runtime/browser_session",
      &flutter::StandardMethodCodec::GetInstance());
  const HWND flutter_window =
      GetAncestor(registrar->GetView()->GetNativeWindow(), GA_ROOT);
  auto plugin = std::make_unique<MgreadPluginRuntimePlugin>(flutter_window);
  channel->SetMethodCallHandler(
      [pointer = plugin.get()](const auto& call, auto result) {
        pointer->HandleMethodCall(call, std::move(result));
      });
  registrar->AddPlugin(std::move(plugin));
}

MgreadPluginRuntimePlugin::MgreadPluginRuntimePlugin(HWND flutter_window)
    : browser_host_(flutter_window) {}

MgreadPluginRuntimePlugin::~MgreadPluginRuntimePlugin() = default;

void MgreadPluginRuntimePlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  browser_host_.Handle(call, std::move(result));
}

}  // namespace mgread_plugin_runtime
