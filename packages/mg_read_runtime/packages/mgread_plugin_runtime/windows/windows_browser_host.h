// Package-private WebView2 primitive host. Only Dart's fixed browser-session
// state machine may call this channel; plugins cannot supply scripts or paths.
#ifndef FLUTTER_PLUGIN_MGREAD_WINDOWS_BROWSER_HOST_H_
#define FLUTTER_PLUGIN_MGREAD_WINDOWS_BROWSER_HOST_H_

#include <windows.h>
#include <wrl.h>
#include <WebView2.h>

#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>

#include <map>
#include <memory>
#include <string>

namespace mgread_plugin_runtime {

using MethodResult = flutter::MethodResult<flutter::EncodableValue>;

class WindowsBrowserHost {
 public:
  explicit WindowsBrowserHost(HWND flutter_window);
  ~WindowsBrowserHost();
  WindowsBrowserHost(const WindowsBrowserHost&) = delete;
  WindowsBrowserHost& operator=(const WindowsBrowserHost&) = delete;

  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<MethodResult> result);

 private:
  struct Session;
  using SessionPtr = std::shared_ptr<Session>;

  void Create(const flutter::EncodableMap& arguments,
              std::shared_ptr<MethodResult> result);
  void ExecuteScript(const SessionPtr& session,
                     const flutter::EncodableMap& arguments,
                     std::shared_ptr<MethodResult> result);
  void GetCookies(const SessionPtr& session,
                  const flutter::EncodableMap& arguments,
                  std::shared_ptr<MethodResult> result);
  void SetCookie(const SessionPtr& session,
                 const flutter::EncodableMap& arguments,
                 std::shared_ptr<MethodResult> result);
  SessionPtr FindSession(const flutter::EncodableMap& arguments) const;
  void DisposeSession(const std::string& session_id);
  void ShowSession(const SessionPtr& session);

  HWND flutter_window_;
  HWND foreground_window_ = nullptr;
  std::map<std::string, SessionPtr> sessions_;
  std::map<std::string, std::string> plugin_sessions_;
};

}  // namespace mgread_plugin_runtime

#endif
