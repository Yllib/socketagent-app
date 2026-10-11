#include "desktop_shell.h"

#include <commctrl.h>
#include <windowsx.h>
#include <algorithm>
#include <flutter/standard_method_codec.h>

#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 41;
constexpr UINT_PTR kSaveTimer = 41;
constexpr wchar_t kPlacementKey[] = L"Software\\Rubano Enterprises\\SocketAgent\\Desktop";
constexpr wchar_t kPlacementValue[] = L"WindowPlacementV1";
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
// The installer deletes this value on uninstall; keep the two names in sync.
constexpr wchar_t kRunValue[] = L"SocketAgent Desktop";
constexpr wchar_t kBackgroundArgument[] = L"--background";
constexpr UINT kShowCommand = 1;
constexpr UINT kHideCommand = 2;
constexpr UINT kQuitCommand = 3;
}

DesktopShell::DesktopShell(HWND window, HWND content, flutter::BinaryMessenger* messenger)
    : window_(window), content_(content),
      taskbar_created_(RegisterWindowMessageW(L"TaskbarCreated")),
      activate_message_(RegisterWindowMessageW(L"SocketAgent.Desktop.Activate.v1")),
      quit_message_(RegisterWindowMessageW(L"SocketAgent.Desktop.Quit.v1")) {
  SetWindowSubclass(content_, ContentProc, 1, reinterpret_cast<DWORD_PTR>(this));
  // The application draws its caption. Keep the resize/minimize/maximize styles
  // so Windows still supports snapping, keyboard shortcuts and native resizing.
  SetWindowLongPtr(window_, GWL_STYLE, GetWindowLongPtr(window_, GWL_STYLE) & ~WS_CAPTION);
  SetWindowPos(window_, nullptr, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.socketagent.app/desktop_window",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& method = call.method_name();
    if (method == "getState") {
      result->Success(State());
      return;
    }
    if (method == "getStartWithWindows") {
      result->Success(flutter::EncodableValue(StartsWithWindows()));
      return;
    }
    if (method == "setStartWithWindows") {
      const auto* enabled = call.arguments()
          ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!enabled) {
        result->Error("INVALID_ARGUMENT", "Expected a boolean");
      } else if (SetStartWithWindows(*enabled)) {
        result->Success();
      } else {
        result->Error("UNAVAILABLE", "Windows did not accept the startup entry");
      }
      return;
    }
    if (method == "show") Show();
    else if (method == "hide") Hide();
    else if (method == "showMenu") {
      result->Success();
      PostMessage(window_, kTrayMessage, 0, WM_CONTEXTMENU);
      return;
    }
    else if (method == "minimize") ShowWindow(window_, SW_MINIMIZE);
    else if (method == "toggleMaximize") {
      ShowWindow(window_, IsZoomed(window_) ? SW_RESTORE : SW_MAXIMIZE);
    } else if (method == "quit") {
      // Reply before destroying the engine that owns this method result.
      result->Success();
      PostMessage(window_, quit_message_, 0, 0);
      return;
    } else {
      result->NotImplemented();
      return;
    }
    result->Success();
  });
  AddTrayIcon();
}

DesktopShell::~DesktopShell() {
  KillTimer(window_, kSaveTimer);
  RemoveWindowSubclass(content_, ContentProc, 1);
  if (tray_ready_) Shell_NotifyIconW(NIM_DELETE, &tray_);
}

bool DesktopShell::StartsWithWindows() const {
  return RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunValue, RRF_RT_REG_SZ,
      nullptr, nullptr, nullptr) == ERROR_SUCCESS;
}

bool DesktopShell::SetStartWithWindows(bool enabled) {
  HKEY key;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0,
          KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  LSTATUS status;
  if (enabled) {
    wchar_t path[MAX_PATH];
    const DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH);
    if (length == 0 || length == MAX_PATH) {
      RegCloseKey(key);
      return false;
    }
    const std::wstring command =
        L"\"" + std::wstring(path, length) + L"\" " + kBackgroundArgument;
    status = RegSetValueExW(key, kRunValue, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    status = RegDeleteValueW(key, kRunValue);
    if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
  }
  RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

void DesktopShell::ShowInitial() {
  // A sign-in launch from the Run key starts in the tray. Without a usable
  // tray icon the window shows anyway, so it is never unreachable.
  if (!tray_ready_) AddTrayIcon();
  const bool background =
      wcsstr(GetCommandLineW(), kBackgroundArgument) != nullptr &&
      tray_ready_ && HasReachableTrayIcon();
  WINDOWPLACEMENT placement{};
  DWORD size = sizeof(placement);
  bool restored = false;
  if (RegGetValueW(HKEY_CURRENT_USER, kPlacementKey, kPlacementValue,
          RRF_RT_REG_BINARY, nullptr, &placement, &size) == ERROR_SUCCESS &&
      size == sizeof(placement) && placement.length == sizeof(placement)) {
    const auto& r = placement.rcNormalPosition;
    if (r.right > r.left && r.bottom > r.top &&
        static_cast<long long>(r.right) - r.left <= 100000 &&
        static_cast<long long>(r.bottom) - r.top <= 100000) {
      placement.flags = 0;
      maximized_ = placement.showCmd == SW_SHOWMAXIMIZED;
      placement.showCmd = background ? SW_HIDE
          : maximized_ ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
      // Only SetWindowPlacement consumes these workspace coordinates. Windows
      // also moves a saved off-screen window back onto an available display.
      restored = SetWindowPlacement(window_, &placement) != FALSE;
    }
  }
  ready_ = true;
  if (!background) {
    if (!restored) ShowWindow(window_, SW_SHOWNORMAL);
    maximized_ = IsZoomed(window_) != FALSE;
    SetForegroundWindow(window_);
  }
  NotifyState();
}

void DesktopShell::SavePlacement() {
  if (!ready_) return;
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (!GetWindowPlacement(window_, &placement)) return;
  placement.flags = 0;
  placement.showCmd = maximized_ ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
  HKEY key;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kPlacementKey, 0, nullptr, 0,
          KEY_SET_VALUE, nullptr, &key, nullptr) == ERROR_SUCCESS) {
    RegSetValueExW(key, kPlacementValue, 0, REG_BINARY,
        reinterpret_cast<const BYTE*>(&placement), sizeof(placement));
    RegCloseKey(key);
  }
}

void DesktopShell::Show() {
  if (IsIconic(window_)) ShowWindow(window_, SW_RESTORE);
  else ShowWindow(window_, maximized_ ? SW_SHOWMAXIMIZED : SW_SHOW);
  SetForegroundWindow(window_);
  SetFocus(content_);
  NotifyState();
}

void DesktopShell::Hide() {
  SavePlacement();
  // Never strand a window if Explorer could not accept our tray icon.
  // Explorer can lose the icon without destroying our window. Verify the
  // registration now rather than trusting the result cached at startup.
  AddTrayIcon();
  ShowWindow(window_, tray_ready_ && HasReachableTrayIcon() ? SW_HIDE : SW_MINIMIZE);
  NotifyState();
}

void DesktopShell::AddTrayIcon() {
  tray_ = {};
  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = window_;
  tray_.uID = 1;
  tray_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP | NIF_STATE;
  tray_.dwStateMask = NIS_HIDDEN;
  tray_.dwState = 0;
  tray_.uCallbackMessage = kTrayMessage;
  tray_.hIcon = static_cast<HICON>(LoadImageW(GetModuleHandle(nullptr),
      MAKEINTRESOURCE(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_SHARED));
  if (!tray_.hIcon) {
    tray_ready_ = false;
    return;
  }
  wcscpy_s(tray_.szTip, L"SocketAgent Desktop");
  // Add first. Updating an icon is not evidence that Explorer actually added
  // it, especially after Explorer has restarted or lost its notification state.
  tray_ready_ = Shell_NotifyIconW(NIM_ADD, &tray_) != FALSE;
  if (!tray_ready_) tray_ready_ = Shell_NotifyIconW(NIM_MODIFY, &tray_) != FALSE;
  if (tray_ready_) {
    tray_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray_);
  } else if (!IsWindowVisible(window_) && ready_) {
    Show();
  }
}

bool DesktopShell::HasReachableTrayIcon() const {
  NOTIFYICONIDENTIFIER icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = window_;
  icon.uID = tray_.uID;
  RECT bounds{};
  const auto result = Shell_NotifyIconGetRect(&icon, &bounds);
  // Registration alone can succeed without an accessible icon. In that case
  // keep the ordinary taskbar button instead of stranding a hidden window.
  return SUCCEEDED(result) && bounds.right > bounds.left && bounds.bottom > bounds.top;
}

void DesktopShell::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kShowCommand, L"Open SocketAgent Desktop");
  AppendMenuW(menu, MF_STRING, kHideCommand, L"Hide to tray");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kQuitCommand, L"Quit SocketAgent Desktop");
  SetMenuDefaultItem(menu, kShowCommand, FALSE);
  POINT point;
  GetCursorPos(&point);
  SetForegroundWindow(window_);
  const auto command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
      point.x, point.y, 0, window_, nullptr);
  DestroyMenu(menu);
  PostMessage(window_, WM_NULL, 0, 0);
  if (command == kShowCommand) Show();
  else if (command == kHideCommand) Hide();
  else if (command == kQuitCommand) PostMessage(window_, quit_message_, 0, 0);
}

flutter::EncodableValue DesktopShell::State() const {
  return flutter::EncodableValue(flutter::EncodableMap{
    {flutter::EncodableValue("maximized"), flutter::EncodableValue(IsZoomed(window_) != FALSE)},
    {flutter::EncodableValue("visible"), flutter::EncodableValue(IsWindowVisible(window_) != FALSE && !IsIconic(window_))},
    {flutter::EncodableValue("active"), flutter::EncodableValue(GetForegroundWindow() == window_)},
  });
}

void DesktopShell::NotifyState() {
  if (channel_ && ready_) {
    channel_->InvokeMethod("stateChanged", std::make_unique<flutter::EncodableValue>(State()));
  }
}

LRESULT DesktopShell::HitTest(HWND window, LPARAM point) {
  RECT bounds;
  GetWindowRect(window, &bounds);
  const int x = GET_X_LPARAM(point) - bounds.left;
  const int y = GET_Y_LPARAM(point) - bounds.top;
  const int width = bounds.right - bounds.left;
  const int height = bounds.bottom - bounds.top;
  const UINT dpi = GetDpiForWindow(window);
  const int border = MulDiv(6, dpi, 96);
  if (!IsZoomed(window)) {
    const bool left = x < border;
    const bool right = x >= width - border;
    const bool top = y < border;
    const bool bottom = y >= height - border;
    if (top && left) return HTTOPLEFT;
    if (top && right) return HTTOPRIGHT;
    if (bottom && left) return HTBOTTOMLEFT;
    if (bottom && right) return HTBOTTOMRIGHT;
    if (left) return HTLEFT;
    if (right) return HTRIGHT;
    if (top) return HTTOP;
    if (bottom) return HTBOTTOM;
  }
  // Must match DesktopWindowFrame's 44 px title bar and 184 px control area.
  POINT client{GET_X_LPARAM(point), GET_Y_LPARAM(point)};
  ScreenToClient(window, &client);
  RECT area;
  GetClientRect(window, &area);
  if (client.y < MulDiv(44, dpi, 96) &&
      client.x < area.right - MulDiv(184, dpi, 96)) return HTCAPTION;
  return HTCLIENT;
}

LRESULT CALLBACK DesktopShell::ContentProc(HWND window, UINT message,
    WPARAM wparam, LPARAM lparam, UINT_PTR id, DWORD_PTR data) {
  auto* shell = reinterpret_cast<DesktopShell*>(data);
  if (message == WM_NCHITTEST && HitTest(shell->window_, lparam) != HTCLIENT) {
    // Delegate caption/edge input through Flutter's full-size child window.
    return HTTRANSPARENT;
  }
  if (message == WM_NCDESTROY) RemoveWindowSubclass(window, ContentProc, id);
  return DefSubclassProc(window, message, wparam, lparam);
}

std::optional<LRESULT> DesktopShell::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == taskbar_created_) {
    tray_ready_ = false;
    AddTrayIcon();
    return 0;
  }
  if (message == activate_message_) { Show(); return 0; }
  if (message == quit_message_) {
    SavePlacement();
    // Destruction happens after returning from this object's handler.
    quitting_ = true;
    PostMessage(window_, WM_CLOSE, 0, 0);
    return 0;
  }
  switch (message) {
    case WM_CLOSE:
      if (quitting_) break;
      Hide(); return 0;
    case WM_SYSCOMMAND:
      if ((wparam & 0xfff0) == SC_CLOSE && !quitting_) { Hide(); return 0; }
      break;
    case WM_QUERYENDSESSION: SavePlacement(); return TRUE;
    case WM_EXITSIZEMOVE: SavePlacement(); break;
    case WM_SIZE:
      if (wparam != SIZE_MINIMIZED) maximized_ = wparam == SIZE_MAXIMIZED;
      if (ready_) SetTimer(window_, kSaveTimer, 400, nullptr);
      NotifyState();
      break;
    case WM_MOVE:
      if (ready_) SetTimer(window_, kSaveTimer, 400, nullptr);
      break;
    case WM_TIMER:
      if (wparam == kSaveTimer) { KillTimer(window_, kSaveTimer); SavePlacement(); return 0; }
      break;
    case WM_SHOWWINDOW:
    case WM_ACTIVATE: NotifyState(); break;
    case kTrayMessage:
      // Handle mouse notifications as well as version-4 keyboard selection.
      // NIM_SETVERSION may fail or Explorer may retain legacy callback behavior.
      switch (LOWORD(lparam)) {
        case NIN_SELECT:
        case NIN_KEYSELECT:
        case WM_LBUTTONUP:
        case WM_LBUTTONDBLCLK: Show(); break;
        case WM_CONTEXTMENU:
        case WM_RBUTTONUP: ShowTrayMenu(); break;
      }
      return 0;
  }
  return std::nullopt;
}
