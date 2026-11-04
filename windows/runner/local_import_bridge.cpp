#include "local_import_bridge.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/flutter_view_controller.h>
#include <shellapi.h>
#include <windows.h>

#include <memory>
#include <cstdint>
#include <cwctype>
#include <algorithm>
#include <iterator>
#include <string>
#include <vector>

namespace {
using Channel = flutter::MethodChannel<flutter::EncodableValue>;
std::unique_ptr<Channel> channel;
HWND bridge_window = nullptr;
constexpr wchar_t kProgId[] = L"MgRead.LocalDocument";
constexpr wchar_t kOriginalWindowProcProperty[] = L"MgRead.LocalImport.OriginalWndProc";
constexpr ULONG_PTR kLocalImportCopyDataId = 0x4D475249;  // "MGRI"
constexpr size_t kMaxForwardPaths = 100;
constexpr size_t kMaxForwardBytes = 256 * 1024;
constexpr UINT kForwardTimeoutMs = 3000;
constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"MgRead";
flutter::EncodableList pending_files;
uint64_t next_open_id = 1;

bool SetStringValue(HKEY key, const wchar_t* name, const std::wstring& value) {
  const DWORD bytes = static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
  return RegSetValueExW(key, name, 0, REG_SZ,
                        reinterpret_cast<const BYTE*>(value.c_str()), bytes) == ERROR_SUCCESS;
}

bool RegisterOpenWith() {
  wchar_t executable[MAX_PATH + 1] = {};
  const DWORD length = GetModuleFileNameW(nullptr, executable, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return false;
  const std::wstring command = L"\"" + std::wstring(executable, length) + L"\" \"%1\"";

  HKEY progIdKey = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\MgRead.LocalDocument", 0,
                      nullptr, REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &progIdKey,
                      nullptr) != ERROR_SUCCESS) return false;
  bool ok = SetStringValue(progIdKey, L"FriendlyAppName", L"MgRead");
  RegCloseKey(progIdKey);

  HKEY commandKey = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Classes\\MgRead.LocalDocument\\shell\\open\\command", 0,
                      nullptr, REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &commandKey,
                      nullptr) != ERROR_SUCCESS) return false;
  ok = SetStringValue(commandKey, nullptr, command) && ok;
  RegCloseKey(commandKey);

  for (const wchar_t* extension : {L".txt", L".epub"}) {
    const std::wstring keyPath = L"Software\\Classes\\" + std::wstring(extension) + L"\\OpenWithProgids";
    HKEY openWithKey = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, keyPath.c_str(), 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &openWithKey,
                        nullptr) != ERROR_SUCCESS) return false;
    const LONG status = RegSetValueExW(openWithKey, kProgId, 0, REG_NONE, nullptr, 0);
    RegCloseKey(openWithKey);
    ok = status == ERROR_SUCCESS && ok;
  }
  return ok;
}

std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                                       static_cast<int>(value.size()), nullptr, 0,
                                       nullptr, nullptr);
  if (size <= 0) return {};
  std::string output(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), output.data(), size,
                      nullptr, nullptr);
  return output;
}

bool IsValidUtf16(const std::wstring& value) {
  for (size_t i = 0; i < value.size(); ++i) {
    const wchar_t unit = value[i];
    if (unit == L'\0') return false;
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (i + 1 >= value.size() || value[i + 1] < 0xDC00 || value[i + 1] > 0xDFFF) {
        return false;
      }
      ++i;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      return false;
    }
  }
  return true;
}

bool IsLocalDocumentPath(const std::wstring& path) {
  if (path.empty() || !IsValidUtf16(path)) return false;
  const size_t slash = path.find_last_of(L"\\/");
  const size_t dot = path.find_last_of(L'.');
  if (dot == std::wstring::npos || (slash != std::wstring::npos && dot < slash)) return false;
  std::wstring extension = path.substr(dot);
  std::transform(extension.begin(), extension.end(), extension.begin(), towlower);
  return extension == L".txt" || extension == L".epub";
}

bool IsAbsoluteWindowsPath(const std::wstring& path) {
  return path.size() >= 3 && ((path[0] >= L'A' && path[0] <= L'Z') ||
                              (path[0] >= L'a' && path[0] <= L'z')) &&
         path[1] == L':' && (path[2] == L'\\' || path[2] == L'/');
}

bool QueuePaths(const std::vector<std::wstring>& paths) {
  if (!channel || paths.empty() || paths.size() > kMaxForwardPaths ||
      pending_files.size() + paths.size() > kMaxForwardPaths) return false;
  flutter::EncodableList payload;
  for (const auto& path : paths) {
    if (!IsLocalDocumentPath(path) || !IsAbsoluteWindowsPath(path)) return false;
    const auto utf8 = Utf8(path);
    if (utf8.empty()) return false;
    const auto slash = utf8.find_last_of("/\\");
    const auto name = slash == std::string::npos ? utf8 : utf8.substr(slash + 1);
    payload.emplace_back(flutter::EncodableMap{
        {flutter::EncodableValue("path"), flutter::EncodableValue(utf8)},
        {flutter::EncodableValue("name"), flutter::EncodableValue(name)},
        {flutter::EncodableValue("openId"), flutter::EncodableValue("windows-" + std::to_string(next_open_id++))},
    });
  }
  if (payload.size() != paths.size()) return false;
  for (const auto& entry : payload) pending_files.emplace_back(entry);
  channel->InvokeMethod("filesOpened", std::make_unique<flutter::EncodableValue>(payload));
  return true;
}

bool DecodeCopyData(const COPYDATASTRUCT* copy, std::vector<std::wstring>* paths) {
  if (copy == nullptr || paths == nullptr || copy->dwData != kLocalImportCopyDataId ||
      copy->lpData == nullptr || copy->cbData < 2 * sizeof(wchar_t) ||
      copy->cbData > kMaxForwardBytes || copy->cbData % sizeof(wchar_t) != 0) return false;
  const auto* units = static_cast<const wchar_t*>(copy->lpData);
  const size_t count = copy->cbData / sizeof(wchar_t);
  if (units[count - 1] != L'\0' || units[count - 2] != L'\0') return false;
  std::vector<std::wstring> decoded;
  size_t start = 0;
  while (start < count - 1) {
    size_t end = start;
    while (end < count && units[end] != L'\0') ++end;
    if (end == start || end >= count - 1 || decoded.size() >= kMaxForwardPaths) return false;
    std::wstring path(units + start, units + end);
    if (!IsValidUtf16(path) || !IsAbsoluteWindowsPath(path) || !IsLocalDocumentPath(path)) return false;
    decoded.push_back(std::move(path));
    start = end + 1;
  }
  if (decoded.empty() || start != count - 1) return false;
  *paths = std::move(decoded);
  return true;
}

LRESULT CALLBACK LocalImportWindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  auto original = reinterpret_cast<WNDPROC>(GetPropW(window, kOriginalWindowProcProperty));
  if (message == WM_COPYDATA) {
    std::vector<std::wstring> paths;
    const auto* copy = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    if (copy != nullptr && copy->dwData == kLocalImportCopyDataId) {
      return DecodeCopyData(copy, &paths) && QueuePaths(paths) ? TRUE : FALSE;
    }
  }
  if (message == WM_NCDESTROY) RemovePropW(window, kOriginalWindowProcProperty);
  return original != nullptr ? CallWindowProcW(original, window, message, wparam, lparam)
                             : DefWindowProcW(window, message, wparam, lparam);
}

bool InstallCopyDataHandler(HWND window) {
  if (window == nullptr || GetPropW(window, kOriginalWindowProcProperty) != nullptr) return false;
  SetLastError(ERROR_SUCCESS);
  const LONG_PTR previous = SetWindowLongPtrW(window, GWLP_WNDPROC,
                                               reinterpret_cast<LONG_PTR>(LocalImportWindowProc));
  if (previous == 0 && GetLastError() != ERROR_SUCCESS) return false;
  if (SetPropW(window, kOriginalWindowProcProperty, reinterpret_cast<HANDLE>(previous))) return true;
  SetWindowLongPtrW(window, GWLP_WNDPROC, previous);
  return false;
}

bool IsSourceCheckInvocation(int argc, wchar_t** argv) {
  for (int i = 1; i < argc; ++i) {
    const std::wstring arg(argv[i]);
    if (arg == L"--source-check-all" || arg == L"--source-check" ||
        arg.rfind(L"--source-check=", 0) == 0) return true;
  }
  return false;
}

bool TryForwardArguments(int argc, wchar_t** argv) {
  if (IsSourceCheckInvocation(argc, argv)) return false;
  std::vector<std::wstring> paths;
  size_t payload_bytes = sizeof(wchar_t);  // the final MULTI_SZ terminator
  for (int i = 1; i < argc; ++i) {
    std::wstring arg(argv[i]);
    if (arg.empty() || arg[0] == L'-' || arg[0] == L'/') continue;
    if (!IsValidUtf16(arg) || !IsLocalDocumentPath(arg)) continue;
    wchar_t full_path[MAX_PATH * 4] = {};
    const DWORD length = GetFullPathNameW(arg.c_str(), static_cast<DWORD>(std::size(full_path)),
                                          full_path, nullptr);
    if (length == 0 || length >= std::size(full_path)) return false;
    std::wstring absolute(full_path, length);
    if (!IsAbsoluteWindowsPath(absolute) || !IsLocalDocumentPath(absolute)) return false;
    payload_bytes += (absolute.size() + 1) * sizeof(wchar_t);
    if (paths.size() >= kMaxForwardPaths || payload_bytes > kMaxForwardBytes) return false;
    paths.push_back(std::move(absolute));
  }
  if (paths.empty()) return false;

  HWND target = FindWindowW(kWindowClass, kWindowTitle);
  if (target == nullptr) return false;
  std::vector<wchar_t> payload;
  payload.reserve(payload_bytes / sizeof(wchar_t));
  for (const auto& path : paths) {
    payload.insert(payload.end(), path.begin(), path.end());
    payload.push_back(L'\0');
  }
  payload.push_back(L'\0');
  COPYDATASTRUCT copy{ kLocalImportCopyDataId, static_cast<DWORD>(payload.size() * sizeof(wchar_t)),
                       payload.data() };
  DWORD_PTR acknowledged = FALSE;
  const LRESULT sent = SendMessageTimeoutW(target, WM_COPYDATA, 0,
      reinterpret_cast<LPARAM>(&copy), SMTO_ABORTIFHUNG | SMTO_BLOCK,
      kForwardTimeoutMs, &acknowledged);
  return sent != 0 && acknowledged != FALSE;
}
}  // namespace

bool TryForwardLocalImportArguments() {
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv == nullptr) return false;
  const bool forwarded = TryForwardArguments(argc, argv);
  LocalFree(argv);
  return forwarded;
}

void AttachLocalImportBridge(flutter::FlutterEngine* engine, HWND window) {
  if (engine == nullptr) return;
  channel = std::make_unique<Channel>(engine->messenger(), "mg_read/local_import",
                                     &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "drainPending") {
      flutter::EncodableList pending = std::move(pending_files);
      pending_files.clear();
      result->Success(flutter::EncodableValue(pending));
    } else if (call.method_name() == "registerOpenWith") {
      result->Success(flutter::EncodableValue(RegisterOpenWith()));
    } else {
      result->NotImplemented();
    }
  });
  bridge_window = window;
  if (bridge_window != nullptr) {
    InstallCopyDataHandler(bridge_window);
    DragAcceptFiles(bridge_window, TRUE);
  }
}

void DetachLocalImportBridge() {
  if (channel) channel->SetMethodCallHandler(nullptr);
  channel.reset();
  if (bridge_window != nullptr) DragAcceptFiles(bridge_window, FALSE);
  bridge_window = nullptr;
}

bool HandleLocalImportMessage(HWND, UINT message, WPARAM wparam, LPARAM) {
  if (message != WM_DROPFILES) return false;
  const HDROP drop = reinterpret_cast<HDROP>(wparam);
  const UINT count = std::min<UINT>(DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0), static_cast<UINT>(kMaxForwardPaths));
  std::vector<std::wstring> paths;
  paths.reserve(count);
  for (UINT index = 0; index < count; ++index) {
    const UINT length = DragQueryFileW(drop, index, nullptr, 0);
    if (length == 0) continue;
    std::wstring path(static_cast<size_t>(length) + 1, L'\0');
    DragQueryFileW(drop, index, path.data(), length + 1);
    path.resize(length);
    if (IsLocalDocumentPath(path)) paths.push_back(std::move(path));
  }
  DragFinish(drop);
  QueuePaths(paths);
  return true;
}
