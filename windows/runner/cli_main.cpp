// Windows console companion for MgRead source verification.
//
// This executable owns no Flutter state. It starts the GUI-subsystem app from
// the same release bundle, keeps the caller's console attached for Dart
// stdout/stderr, and waits for the app's real verification exit code.
#include <windows.h>

#include <cwctype>
#include <string>
#include <vector>

namespace {

std::wstring GetGuiExecutablePath() {
  std::vector<wchar_t> module_path(32768);
  const DWORD length = ::GetModuleFileNameW(
      nullptr, module_path.data(), static_cast<DWORD>(module_path.size()));
  if (length == 0 || length >= module_path.size()) {
    return std::wstring();
  }

  std::wstring executable_path(module_path.data(), length);
  const size_t separator = executable_path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    return std::wstring();
  }
  return executable_path.substr(0, separator + 1) + L"mg_read.exe";
}

// Replaces the console companion's argv[0] with the GUI executable path while
// preserving every user-supplied argument verbatim. Passing the companion's
// original command line to CreateProcess makes Flutter see `mg_read_cli.exe`
// as a regular argument, so source-check parsing rejects an otherwise valid
// invocation before it can emit its diagnostic records.
std::wstring BuildGuiCommandLine(const std::wstring &gui_executable_path) {
  const wchar_t *cursor = ::GetCommandLineW();
  if (cursor == nullptr) {
    return std::wstring();
  }

  if (*cursor == L'"') {
    ++cursor;
    while (*cursor != L'\0' && *cursor != L'"') {
      ++cursor;
    }
    if (*cursor == L'"') {
      ++cursor;
    }
  } else {
    while (*cursor != L'\0' && !std::iswspace(*cursor)) {
      ++cursor;
    }
  }
  while (std::iswspace(*cursor)) {
    ++cursor;
  }

  std::wstring command_line = L"\"" + gui_executable_path + L"\"";
  if (*cursor != L'\0') {
    command_line += L" ";
    command_line += cursor;
  }
  return command_line;
}

} // namespace

int wmain() {
  const std::wstring gui_executable_path = GetGuiExecutablePath();
  if (gui_executable_path.empty()) {
    return 2;
  }

  const std::wstring gui_command_line = BuildGuiCommandLine(gui_executable_path);
  if (gui_command_line.empty()) {
    return 2;
  }
  std::vector<wchar_t> command_line(gui_command_line.begin(),
                                    gui_command_line.end());
  command_line.push_back(L'\0');
  STARTUPINFOW startup_info = {};
  startup_info.cb = sizeof(startup_info);
  // `mg_read.exe` is a GUI-subsystem binary. Without explicitly supplying
  // these inherited handles, Dart sees invalid standard streams and silently
  // drops the source-check diagnostics even though the console companion is
  // waiting for its exit code.
  startup_info.dwFlags = STARTF_USESTDHANDLES;
  startup_info.hStdInput = ::GetStdHandle(STD_INPUT_HANDLE);
  startup_info.hStdOutput = ::GetStdHandle(STD_OUTPUT_HANDLE);
  startup_info.hStdError = ::GetStdHandle(STD_ERROR_HANDLE);
  PROCESS_INFORMATION process_information = {};
  if (!::CreateProcessW(gui_executable_path.c_str(), command_line.data(),
                        nullptr, nullptr, TRUE, 0, nullptr, nullptr,
                        &startup_info, &process_information)) {
    return 2;
  }

  const DWORD wait_result =
      ::WaitForSingleObject(process_information.hProcess, INFINITE);
  DWORD exit_code = 2;
  if (wait_result == WAIT_OBJECT_0) {
    ::GetExitCodeProcess(process_information.hProcess, &exit_code);
  }
  ::CloseHandle(process_information.hThread);
  ::CloseHandle(process_information.hProcess);
  return static_cast<int>(exit_code);
}
