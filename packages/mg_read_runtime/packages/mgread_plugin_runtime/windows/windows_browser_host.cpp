#include "windows_browser_host.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <mutex>
#include <utility>

namespace mgread_plugin_runtime {
namespace {

constexpr wchar_t kWindowClass[] = L"MgReadBrowserSessionWindow";
constexpr int kHideButtonId = 1001;
constexpr int kToolbarHeight = 42;

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                        value.data(), static_cast<int>(value.size()),
                                        nullptr, 0);
  if (count <= 0) return {};
  std::wstring output(count, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), output.data(), count);
  return output;
}

std::string WideToUtf8(const wchar_t* value) {
  if (value == nullptr || *value == L'\0') return {};
  const int length = static_cast<int>(wcslen(value));
  const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value,
                                        length, nullptr, 0, nullptr, nullptr);
  if (count <= 0) return {};
  std::string output(count, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, length,
                      output.data(), count, nullptr, nullptr);
  return output;
}

const flutter::EncodableValue* Find(const flutter::EncodableMap& map,
                                    const char* key) {
  const auto found = map.find(flutter::EncodableValue(key));
  return found == map.end() ? nullptr : &found->second;
}

const std::string* FindString(const flutter::EncodableMap& map,
                              const char* key) {
  const auto* value = Find(map, key);
  return value == nullptr ? nullptr : std::get_if<std::string>(value);
}

const flutter::EncodableMap* FindMap(const flutter::EncodableMap& map,
                                    const char* key) {
  const auto* value = Find(map, key);
  return value == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(value);
}

bool FindBool(const flutter::EncodableMap& map, const char* key,
              bool fallback = false) {
  const auto* value = Find(map, key);
  const auto* result = value == nullptr ? nullptr : std::get_if<bool>(value);
  return result == nullptr ? fallback : *result;
}

int64_t FindInt64(const flutter::EncodableMap& map, const char* key,
                  int64_t fallback = -1) {
  const auto* value = Find(map, key);
  if (value == nullptr) return fallback;
  if (const auto* number = std::get_if<int64_t>(value)) return *number;
  if (const auto* number = std::get_if<int32_t>(value)) return *number;
  return fallback;
}

double FindDouble(const flutter::EncodableMap& map, const char* key,
                  double fallback = -1.0) {
  const auto* value = Find(map, key);
  if (value == nullptr) return fallback;
  if (const auto* number = std::get_if<double>(value)) return *number;
  if (const auto* number = std::get_if<int64_t>(value)) {
    return static_cast<double>(*number);
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    return static_cast<double>(*number);
  }
  return fallback;
}

std::string NewSessionId() {
  GUID guid{};
  if (FAILED(CoCreateGuid(&guid))) return {};
  wchar_t value[40]{};
  if (StringFromGUID2(guid, value, 40) <= 0) return {};
  return WideToUtf8(value);
}

void SafeError(const std::shared_ptr<MethodResult>& result,
               const std::string& code) {
  result->Error(code, "The Windows browser session could not complete the operation.");
}

template <typename T>
Microsoft::WRL::ComPtr<T> Query(Microsoft::WRL::ComPtr<ICoreWebView2> webview) {
  Microsoft::WRL::ComPtr<T> result;
  if (webview != nullptr) webview.As(&result);
  return result;
}

HWND FindWebViewWindow(HWND parent) {
  for (HWND child = GetWindow(parent, GW_CHILD); child != nullptr;
       child = GetWindow(child, GW_HWNDNEXT)) {
    wchar_t class_name[128]{};
    GetClassName(child, class_name, ARRAYSIZE(class_name));
    if (wcsstr(class_name, L"Chrome_WidgetWin") != nullptr) return child;
    if (const HWND nested = FindWebViewWindow(child); nested != nullptr) {
      return nested;
    }
  }
  return nullptr;
}

}  // namespace

struct WindowsBrowserHost::Session {
  WindowsBrowserHost* owner = nullptr;
  std::string plugin_id;
  std::string session_id;
  std::wstring profile_path;
  HWND window = nullptr;
  HWND hide_button = nullptr;
  HWND input_window = nullptr;
  Microsoft::WRL::ComPtr<ICoreWebView2Environment> environment;
  Microsoft::WRL::ComPtr<ICoreWebView2Controller> controller;
  Microsoft::WRL::ComPtr<ICoreWebView2> webview;

  void Resize() const {
    if (window == nullptr) return;
    RECT bounds{};
    GetClientRect(window, &bounds);
    if (hide_button != nullptr) {
      MoveWindow(hide_button, std::max(0L, bounds.right - 92L), 7, 80, 28, TRUE);
    }
    if (controller != nullptr) {
      RECT browser_bounds{0, kToolbarHeight, bounds.right,
                          std::max<LONG>(kToolbarHeight, bounds.bottom)};
      controller->put_Bounds(browser_bounds);
    }
  }

  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam) {
    auto* session = reinterpret_cast<Session*>(
        GetWindowLongPtr(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      const auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
      session = static_cast<Session*>(create->lpCreateParams);
      SetWindowLongPtr(window, GWLP_USERDATA,
                       reinterpret_cast<LONG_PTR>(session));
    }
    switch (message) {
      case WM_COMMAND:
        if (LOWORD(wparam) == kHideButtonId) {
          ShowWindow(window, SW_HIDE);
          return 0;
        }
        break;
      case WM_CLOSE:
        if (session != nullptr && session->owner != nullptr) {
          session->owner->DisposeSession(session->session_id);
        } else {
          ShowWindow(window, SW_HIDE);
        }
        return 0;
      case WM_SIZE:
        if (session != nullptr) session->Resize();
        return 0;
      default:
        break;
    }
    return DefWindowProc(window, message, wparam, lparam);
  }
};

WindowsBrowserHost::WindowsBrowserHost(HWND flutter_window)
    : flutter_window_(flutter_window) {
  static std::once_flag registration;
  std::call_once(registration, [] {
    WNDCLASS window_class{};
    window_class.lpfnWndProc = Session::WindowProc;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.lpszClassName = kWindowClass;
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    RegisterClass(&window_class);
  });
}

WindowsBrowserHost::~WindowsBrowserHost() {
  while (!sessions_.empty()) DisposeSession(sessions_.begin()->first);
}

void WindowsBrowserHost::Handle(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<MethodResult> unique_result) {
  auto result = std::shared_ptr<MethodResult>(std::move(unique_result));
  const auto* arguments =
      std::get_if<flutter::EncodableMap>(call.arguments());
  if (arguments == nullptr) {
    SafeError(result, "plugin_execution_failed");
    return;
  }
  if (call.method_name() == "create") {
    Create(*arguments, result);
    return;
  }
  const auto session = FindSession(*arguments);
  if (session == nullptr) {
    SafeError(result, "unsupported");
    return;
  }
  if (call.method_name() == "dispose") {
    DisposeSession(session->session_id);
    result->Success();
  } else if (call.method_name() == "show") {
    ShowSession(session);
    result->Success();
  } else if (call.method_name() == "hide") {
    ShowWindow(session->window, SW_HIDE);
    result->Success();
  } else if (call.method_name() == "stop") {
    if (session->webview != nullptr) session->webview->Stop();
    result->Success();
  } else if (call.method_name() == "load") {
    const auto* url = FindString(*arguments, "url");
    const auto wide = url == nullptr ? std::wstring() : Utf8ToWide(*url);
    if (wide.rfind(L"https://", 0) != 0 || session->webview == nullptr ||
        FAILED(session->webview->Navigate(wide.c_str()))) {
      SafeError(result, "plugin_execution_failed");
    } else {
      result->Success();
    }
  } else if (call.method_name() == "executeScript") {
    ExecuteScript(session, *arguments, result);
  } else if (call.method_name() == "dispatchMouseInput") {
    DispatchMouseInput(session, *arguments, result);
  } else if (call.method_name() == "insertText") {
    InsertText(session, *arguments, result);
  } else if (call.method_name() == "getCookies") {
    GetCookies(session, *arguments, result);
  } else if (call.method_name() == "setCookie") {
    SetCookie(session, *arguments, result);
  } else {
    result->NotImplemented();
  }
}

void WindowsBrowserHost::Create(const flutter::EncodableMap& arguments,
                                std::shared_ptr<MethodResult> result) {
  const auto* plugin_id = FindString(arguments, "pluginId");
  const auto* profile_path = FindString(arguments, "profilePath");
  if (plugin_id == nullptr || plugin_id->empty() || profile_path == nullptr ||
      profile_path->empty()) {
    SafeError(result, "plugin_execution_failed");
    return;
  }
  const auto existing = plugin_sessions_.find(*plugin_id);
  if (existing != plugin_sessions_.end()) {
    result->Success(flutter::EncodableValue(existing->second));
    return;
  }
  const auto session = std::make_shared<Session>();
  session->owner = this;
  session->plugin_id = *plugin_id;
  session->session_id = NewSessionId();
  session->profile_path = Utf8ToWide(*profile_path);
  if (session->session_id.empty() || session->profile_path.empty()) {
    SafeError(result, "unsupported");
    return;
  }
  session->window = CreateWindowEx(
      WS_EX_APPWINDOW, kWindowClass, L"MgRead Browser Verification",
      WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 980, 760,
      flutter_window_, nullptr, GetModuleHandle(nullptr), session.get());
  if (session->window == nullptr) {
    SafeError(result, "unsupported");
    return;
  }
  session->hide_button = CreateWindow(
      L"BUTTON", L"\u9690\u85cf", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
      0, 0, 80, 28, session->window,
      reinterpret_cast<HMENU>(static_cast<INT_PTR>(kHideButtonId)),
      GetModuleHandle(nullptr), nullptr);
  sessions_[session->session_id] = session;
  plugin_sessions_[session->plugin_id] = session->session_id;

  const HRESULT started = CreateCoreWebView2EnvironmentWithOptions(
      nullptr, session->profile_path.c_str(), nullptr,
      Microsoft::WRL::Callback<
          ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [this, session, result](HRESULT environment_result,
                                  ICoreWebView2Environment* environment) -> HRESULT {
            if (FAILED(environment_result) || environment == nullptr) {
              DisposeSession(session->session_id);
              SafeError(result, "unsupported");
              return S_OK;
            }
            session->environment = environment;
            const HRESULT controller_started = environment->CreateCoreWebView2Controller(
                session->window,
                Microsoft::WRL::Callback<
                    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                    [this, session, result](HRESULT controller_result,
                                            ICoreWebView2Controller* controller) -> HRESULT {
                      if (FAILED(controller_result) || controller == nullptr) {
                        DisposeSession(session->session_id);
                        SafeError(result, "unsupported");
                        return S_OK;
                      }
                      session->controller = controller;
                      if (FAILED(controller->get_CoreWebView2(&session->webview)) ||
                          session->webview == nullptr) {
                        DisposeSession(session->session_id);
                        SafeError(result, "unsupported");
                        return S_OK;
                      }
                      Microsoft::WRL::ComPtr<ICoreWebView2Settings> settings;
                      if (SUCCEEDED(session->webview->get_Settings(&settings)) &&
                          settings != nullptr) {
                        settings->put_IsScriptEnabled(TRUE);
                        settings->put_IsWebMessageEnabled(FALSE);
                        settings->put_AreDefaultScriptDialogsEnabled(TRUE);
                        settings->put_IsStatusBarEnabled(FALSE);
                        settings->put_AreDevToolsEnabled(FALSE);
                        settings->put_IsZoomControlEnabled(FALSE);
                      }
                      session->controller->put_IsVisible(TRUE);
                      session->input_window = FindWebViewWindow(session->window);
                      session->Resize();
                      result->Success(flutter::EncodableValue(session->session_id));
                      return S_OK;
                    })
                    .Get());
            if (FAILED(controller_started)) {
              DisposeSession(session->session_id);
              SafeError(result, "unsupported");
            }
            return S_OK;
          })
          .Get());
  if (FAILED(started)) {
    DisposeSession(session->session_id);
    SafeError(result, "unsupported");
  }
}

void WindowsBrowserHost::DispatchMouseInput(
    const SessionPtr& session, const flutter::EncodableMap& arguments,
    std::shared_ptr<MethodResult> result) {
  const double x = FindDouble(arguments, "x");
  const double y = FindDouble(arguments, "y");
  const double device_pixel_ratio = FindDouble(arguments, "devicePixelRatio");
  if (!std::isfinite(x) || !std::isfinite(y) ||
      !std::isfinite(device_pixel_ratio) || x < 0 || y < 0 ||
      device_pixel_ratio <= 0 || device_pixel_ratio > 8) {
    SafeError(result, "plugin_execution_failed");
    return;
  }
  if (session->input_window == nullptr || !IsWindow(session->input_window)) {
    session->input_window = FindWebViewWindow(session->window);
  }
  if (session->input_window == nullptr) {
    SafeError(result, "unsupported");
    return;
  }
  RECT bounds{};
  GetClientRect(session->input_window, &bounds);
  const auto physical_x = static_cast<LONG>(std::lround(x * device_pixel_ratio));
  const auto physical_y = static_cast<LONG>(std::lround(y * device_pixel_ratio));
  if (physical_x < 0 || physical_y < 0 || physical_x >= bounds.right ||
      physical_y >= bounds.bottom) {
    SafeError(result, "plugin_execution_failed");
    return;
  }
  const LPARAM point = MAKELPARAM(physical_x, physical_y);
  SendMessage(session->input_window, WM_MOUSEMOVE, 0, point);
  SendMessage(session->input_window, WM_LBUTTONDOWN, MK_LBUTTON, point);
  SendMessage(session->input_window, WM_LBUTTONUP, 0, point);
  result->Success();
}

void WindowsBrowserHost::InsertText(
    const SessionPtr& session, const flutter::EncodableMap& arguments,
    std::shared_ptr<MethodResult> result) {
  const auto* text = FindString(arguments, "text");
  if (text == nullptr || text->size() > 64 * 1024) {
    SafeError(result, "plugin_execution_failed");
    return;
  }
  if (session->input_window == nullptr || !IsWindow(session->input_window)) {
    session->input_window = FindWebViewWindow(session->window);
  }
  if (session->input_window == nullptr) {
    SafeError(result, "unsupported");
    return;
  }
  const auto wide = Utf8ToWide(*text);
  if (text->empty() != wide.empty()) {
    SafeError(result, "plugin_execution_failed");
    return;
  }
  SetFocus(session->input_window);
  for (const wchar_t character : wide) {
    SendMessage(session->input_window, WM_CHAR,
                static_cast<WPARAM>(character), 1);
  }
  result->Success();
}

void WindowsBrowserHost::ExecuteScript(
    const SessionPtr& session, const flutter::EncodableMap& arguments,
    std::shared_ptr<MethodResult> result) {
  const auto* script = FindString(arguments, "script");
  const auto wide = script == nullptr ? std::wstring() : Utf8ToWide(*script);
  if (wide.empty() || session->webview == nullptr) {
    SafeError(result, "plugin_execution_failed");
    return;
  }
  const HRESULT started = session->webview->ExecuteScript(
      wide.c_str(),
      Microsoft::WRL::Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
          [result](HRESULT error, LPCWSTR value) -> HRESULT {
            if (FAILED(error) || value == nullptr) {
              SafeError(result, "plugin_execution_failed");
            } else {
              result->Success(flutter::EncodableValue(WideToUtf8(value)));
            }
            return S_OK;
          })
          .Get());
  if (FAILED(started)) SafeError(result, "plugin_execution_failed");
}

void WindowsBrowserHost::GetCookies(
    const SessionPtr& session, const flutter::EncodableMap& arguments,
    std::shared_ptr<MethodResult> result) {
  const auto* url = FindString(arguments, "url");
  const auto wide = url == nullptr ? std::wstring() : Utf8ToWide(*url);
  const auto webview2 = Query<ICoreWebView2_2>(session->webview);
  Microsoft::WRL::ComPtr<ICoreWebView2CookieManager> manager;
  if (wide.rfind(L"https://", 0) != 0 || webview2 == nullptr ||
      FAILED(webview2->get_CookieManager(&manager)) || manager == nullptr) {
    SafeError(result, "plugin_execution_failed");
    return;
  }
  const HRESULT started = manager->GetCookies(
      wide.c_str(),
      Microsoft::WRL::Callback<ICoreWebView2GetCookiesCompletedHandler>(
          [result](HRESULT error, ICoreWebView2CookieList* list) -> HRESULT {
            if (FAILED(error) || list == nullptr) {
              SafeError(result, "plugin_execution_failed");
              return S_OK;
            }
            UINT count = 0;
            if (FAILED(list->get_Count(&count)) || count > 512) {
              SafeError(result, "overloaded");
              return S_OK;
            }
            flutter::EncodableList values;
            for (UINT index = 0; index < count; ++index) {
              Microsoft::WRL::ComPtr<ICoreWebView2Cookie> cookie;
              if (FAILED(list->GetValueAtIndex(index, &cookie)) || cookie == nullptr) continue;
              LPWSTR name = nullptr;
              LPWSTR value = nullptr;
              LPWSTR domain = nullptr;
              LPWSTR path = nullptr;
              BOOL http_only = FALSE;
              BOOL secure = FALSE;
              cookie->get_Name(&name);
              cookie->get_Value(&value);
              cookie->get_Domain(&domain);
              cookie->get_Path(&path);
              cookie->get_IsHttpOnly(&http_only);
              cookie->get_IsSecure(&secure);
              flutter::EncodableMap item;
              item[flutter::EncodableValue("name")] = flutter::EncodableValue(WideToUtf8(name));
              item[flutter::EncodableValue("value")] = flutter::EncodableValue(WideToUtf8(value));
              item[flutter::EncodableValue("domain")] = flutter::EncodableValue(WideToUtf8(domain));
              item[flutter::EncodableValue("path")] = flutter::EncodableValue(WideToUtf8(path));
              item[flutter::EncodableValue("httpOnly")] = flutter::EncodableValue(http_only != FALSE);
              item[flutter::EncodableValue("secure")] = flutter::EncodableValue(secure != FALSE);
              values.emplace_back(item);
              CoTaskMemFree(name);
              CoTaskMemFree(value);
              CoTaskMemFree(domain);
              CoTaskMemFree(path);
            }
            result->Success(flutter::EncodableValue(values));
            return S_OK;
          })
          .Get());
  if (FAILED(started)) SafeError(result, "plugin_execution_failed");
}

void WindowsBrowserHost::SetCookie(
    const SessionPtr& session, const flutter::EncodableMap& arguments,
    std::shared_ptr<MethodResult> result) {
  const auto* value = FindMap(arguments, "cookie");
  const auto* name = value == nullptr ? nullptr : FindString(*value, "name");
  const auto* content = value == nullptr ? nullptr : FindString(*value, "value");
  const auto* domain = value == nullptr ? nullptr : FindString(*value, "domain");
  const auto* path = value == nullptr ? nullptr : FindString(*value, "path");
  const auto webview2 = Query<ICoreWebView2_2>(session->webview);
  Microsoft::WRL::ComPtr<ICoreWebView2CookieManager> manager;
  if (name == nullptr || content == nullptr || domain == nullptr || path == nullptr ||
      webview2 == nullptr || FAILED(webview2->get_CookieManager(&manager)) || manager == nullptr) {
    SafeError(result, "plugin_execution_failed");
    return;
  }
  Microsoft::WRL::ComPtr<ICoreWebView2Cookie> cookie;
  if (FAILED(manager->CreateCookie(Utf8ToWide(*name).c_str(),
                                   Utf8ToWide(*content).c_str(),
                                   Utf8ToWide(*domain).c_str(),
                                   Utf8ToWide(*path).c_str(), &cookie)) ||
      cookie == nullptr) {
    SafeError(result, "plugin_execution_failed");
    return;
  }
  cookie->put_IsHttpOnly(FindBool(*value, "httpOnly") ? TRUE : FALSE);
  cookie->put_IsSecure(FindBool(*value, "secure") ? TRUE : FALSE);
  const int64_t expires = FindInt64(*value, "expires");
  if (expires > 0) cookie->put_Expires(static_cast<double>(expires) / 1000.0);
  if (FAILED(manager->AddOrUpdateCookie(cookie.Get()))) {
    SafeError(result, "plugin_execution_failed");
  } else {
    result->Success();
  }
}

WindowsBrowserHost::SessionPtr WindowsBrowserHost::FindSession(
    const flutter::EncodableMap& arguments) const {
  const auto* id = FindString(arguments, "sessionId");
  if (id == nullptr) return nullptr;
  const auto found = sessions_.find(*id);
  return found == sessions_.end() ? nullptr : found->second;
}

void WindowsBrowserHost::DisposeSession(const std::string& session_id) {
  const auto found = sessions_.find(session_id);
  if (found == sessions_.end()) return;
  const auto session = found->second;
  if (foreground_window_ == session->window) foreground_window_ = nullptr;
  plugin_sessions_.erase(session->plugin_id);
  sessions_.erase(found);
  if (session->controller != nullptr) session->controller->Close();
  session->webview.Reset();
  session->controller.Reset();
  session->environment.Reset();
  if (session->window != nullptr) DestroyWindow(session->window);
  session->window = nullptr;
}

void WindowsBrowserHost::ShowSession(const SessionPtr& session) {
  if (foreground_window_ != nullptr && foreground_window_ != session->window) {
    ShowWindow(foreground_window_, SW_HIDE);
  }
  foreground_window_ = session->window;
  ShowWindow(session->window, SW_SHOWNORMAL);
  SetForegroundWindow(session->window);
}

}  // namespace mgread_plugin_runtime
