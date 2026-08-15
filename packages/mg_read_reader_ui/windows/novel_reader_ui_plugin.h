#ifndef FLUTTER_PLUGIN_NOVEL_READER_UI_PLUGIN_H_
#define FLUTTER_PLUGIN_NOVEL_READER_UI_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace novel_reader_ui {

class NovelReaderUiPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  NovelReaderUiPlugin();

  virtual ~NovelReaderUiPlugin();

  // Disallow copy and assign.
  NovelReaderUiPlugin(const NovelReaderUiPlugin&) = delete;
  NovelReaderUiPlugin& operator=(const NovelReaderUiPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
 void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  bool keep_screen_on_ = false;
};

}  // namespace novel_reader_ui

#endif  // FLUTTER_PLUGIN_NOVEL_READER_UI_PLUGIN_H_
