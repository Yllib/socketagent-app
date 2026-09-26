#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  desktop_shell_ = std::make_unique<DesktopShell>(GetHandle(),
      flutter_controller_->view()->GetNativeWindow(),
      flutter_controller_->engine()->messenger());
  security_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "com.socketagent.app/window_security",
      &flutter::StandardMethodCodec::GetInstance());
  security_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() != "setScreenshotProtection") {
          result->NotImplemented();
          return;
        }
        const auto* enabled = call.arguments()
            ? std::get_if<bool>(call.arguments()) : nullptr;
        if (!enabled) {
          result->Error("INVALID_ARGUMENT", "Expected a boolean");
          return;
        }
        // WDA_EXCLUDEFROMCAPTURE on Windows 10 2004 and newer.
        if (::SetWindowDisplayAffinity(GetHandle(), *enabled ? 0x11 : WDA_NONE)) {
          result->Success();
        } else {
          result->Error("UNAVAILABLE", "Windows could not protect this window");
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    desktop_shell_->ShowInitial();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  desktop_shell_.reset();
  security_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // The entire window is client area, including during activation and the
  // native move/resize loop. DefWindowProc would briefly paint a stock frame.
  if (message == WM_NCPAINT) return 0;
  if (message == WM_NCACTIVATE && !IsIconic(hwnd)) {
    return DefWindowProc(hwnd, message, wparam, -1);
  }
  if (message == WM_NCCALCSIZE) return 0;
  if (message == WM_NCHITTEST) return DesktopShell::HitTest(hwnd, lparam);
  if (message == WM_GETMINMAXINFO) {
    auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
    const UINT dpi = GetDpiForWindow(hwnd);
    info->ptMinTrackSize = {MulDiv(620, dpi, 96), MulDiv(460, dpi, 96)};
    // Constrain the outer window, not just Flutter's client area. An outer
    // window covering the monitor makes Explorer treat it as fullscreen and
    // hide the taskbar even when we leave empty space inside the client area.
    MONITORINFO monitor{sizeof(MONITORINFO)};
    if (GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor)) {
      info->ptMaxPosition = {monitor.rcWork.left - monitor.rcMonitor.left,
                            monitor.rcWork.top - monitor.rcMonitor.top};
      info->ptMaxSize = {monitor.rcWork.right - monitor.rcWork.left,
                        monitor.rcWork.bottom - monitor.rcWork.top};
    }
    return 0;
  }
  if (desktop_shell_) {
    auto result = desktop_shell_->HandleMessage(message, wparam, lparam);
    if (result) return *result;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
