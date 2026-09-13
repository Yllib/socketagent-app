#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  const auto arguments = GetCommandLineArguments();
  const bool quit = std::find(arguments.begin(), arguments.end(), "--quit") != arguments.end();
  HANDLE instance_mutex = CreateMutexW(nullptr, FALSE, L"Local\\SocketAgentDesktop.v1");
  const bool existing = instance_mutex && GetLastError() == ERROR_ALREADY_EXISTS;
  if (existing || quit) {
    HWND other = nullptr;
    for (int attempt = 0; attempt < 80 && !other && existing; ++attempt) {
      other = FindWindowW(L"SOCKETAGENT_DESKTOP_WINDOW", nullptr);
      if (!other) Sleep(25);
    }
    if (other) {
      DWORD process_id;
      GetWindowThreadProcessId(other, &process_id);
      AllowSetForegroundWindow(process_id);
      PostMessage(other, RegisterWindowMessageW(quit
          ? L"SocketAgent.Desktop.Quit.v1" : L"SocketAgent.Desktop.Activate.v1"), 0, 0);
    }
    if (instance_mutex) CloseHandle(instance_mutex);
    return other || quit ? EXIT_SUCCESS : EXIT_FAILURE;
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 900);
  if (!window.Create(L"SocketAgent Desktop", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex) CloseHandle(instance_mutex);
  return EXIT_SUCCESS;
}
