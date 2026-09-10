#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  bool source_check_command = false;
  for (const auto &argument : command_line_arguments) {
    if (argument == "--source-check-all" || argument == "--source-check" ||
        argument.rfind("--source-check=", 0) == 0) {
      source_check_command = true;
      break;
    }
  }

  // A source-check invocation is a real console command. Attach to the
  // caller's console when possible, create one otherwise, and rebind the
  // standard streams so Dart stdout/stderr are visible.
  if (source_check_command) {
    ::AttachConsole(ATTACH_PARENT_PROCESS);
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // The current product UI is mobile-first. Keep the desktop runner close to
  // the compact phone canvas until a separately designed desktop layout ships.
  Win32Window::Point origin(80, 80);
  // Win32Window::Create takes the outer frame size. At the standard Windows
  // decoration size this yields a 400 x 700 Flutter client canvas.
  Win32Window::Size size(416, 739);
  if (!window.Create(L"MgRead", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
