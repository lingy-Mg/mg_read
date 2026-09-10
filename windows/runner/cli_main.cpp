// Windows console companion for MgRead source verification.
//
// This executable owns no Flutter state. It starts the GUI-subsystem app from
// the same release bundle, keeps the caller's console attached for Dart
// stdout/stderr, and waits for the app's real verification exit code.
#include <windows.h>

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

} // namespace

int wmain() {
  const std::wstring gui_executable_path = GetGuiExecutablePath();
  if (gui_executable_path.empty()) {
    return 2;
  }

  const wchar_t *current_command_line = ::GetCommandLineW();
  std::vector<wchar_t> command_line(current_command_line,
                                    current_command_line +
                                        ::wcslen(current_command_line) + 1);
  STARTUPINFOW startup_info = {};
  startup_info.cb = sizeof(startup_info);
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
