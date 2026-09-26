#ifndef RUNNER_DESKTOP_SHELL_H_
#define RUNNER_DESKTOP_SHELL_H_

#include <windows.h>
#include <shellapi.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <functional>
#include <memory>
#include <optional>

// Windows owns placement, resizing and the tray; Flutter draws all title controls.
class DesktopShell {
 public:
  DesktopShell(HWND window, HWND content, flutter::BinaryMessenger* messenger);
  ~DesktopShell();
  void ShowInitial();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
  static LRESULT HitTest(HWND window, LPARAM point);

 private:
  void Show();
  void Hide();
  void SavePlacement();
  void AddTrayIcon();
  bool HasReachableTrayIcon() const;
  void ShowTrayMenu();
  void NotifyState();
  flutter::EncodableValue State() const;
  static LRESULT CALLBACK ContentProc(HWND window, UINT message, WPARAM wparam,
      LPARAM lparam, UINT_PTR id, DWORD_PTR data);

  HWND window_;
  HWND content_;
  bool ready_ = false;
  bool quitting_ = false;
  bool tray_ready_ = false;
  bool maximized_ = false;
  UINT taskbar_created_;
  UINT activate_message_;
  UINT quit_message_;
  NOTIFYICONDATAW tray_{};
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
