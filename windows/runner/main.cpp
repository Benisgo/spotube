#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <ShlObj.h>

#include "flutter_window.h"
#include "utils.h"
#include "win32_window.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Set a consistent AppUserModelID so pinned taskbar shortcuts
  // don't create duplicate icons when launching from different paths.
  ::SetCurrentProcessExplicitAppUserModelID(L"com.github.KRTirtho.Spotube");

  // Single-instance guard: if Spotube is already running, forward this launch
  // to the existing window (deep link + focus + restore) and exit instead of
  // spawning a second process — which the taskbar would otherwise treat as a
  // completely separate app. The named mutex object is destroyed automatically
  // when this process exits, so a crash can't leave it stuck.
  HANDLE single_instance_mutex = ::CreateMutexW(
      nullptr, TRUE, L"Local\\com.github.KRTirtho.Spotube.SingleInstance");
  if (single_instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    Win32Window::ForwardToExistingInstance(L"spotube");
    return 0;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1200, 800);
  if (!window.CreateAndShow(L"spotube", origin, size)) {
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
