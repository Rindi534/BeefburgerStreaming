#include "flutter_window.h"

#include <optional>
#include <dwmapi.h>

#include "flutter/generated_plugin_registrant.h"

#pragma comment(lib, "dwmapi.lib")

// DWM attribute values for dark mode.
//   20 = Windows 10 20H1 (build 19041) and later / Windows 11
//   19 = Windows 10 1903-19H2 (builds 18985-19044 preview)
// We try 20 first, then fall back to 19 so older Windows 10 builds also get
// the dark title bar.
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#define DWMWA_USE_IMMERSIVE_DARK_MODE_OLD 19

// Windows 11 22H2+ (build 22621): lets us set an exact caption color,
// overriding the system theme. 0x0A0A0A = AppTheme.background.
#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif
#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif
#ifndef DWMWA_TEXT_COLOR
#define DWMWA_TEXT_COLOR 36
#endif

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // Apply dark title bar (Windows 10 1903+ / Windows 11) so the native window
  // chrome matches our dark app theme. Try the new attribute value first, then
  // fall back to the old one used on early Windows 10 builds.
  BOOL use_dark_mode = TRUE;
  HRESULT hr = ::DwmSetWindowAttribute(GetHandle(),
                                        DWMWA_USE_IMMERSIVE_DARK_MODE,
                                        &use_dark_mode, sizeof(use_dark_mode));
  if (FAILED(hr)) {
    ::DwmSetWindowAttribute(GetHandle(), DWMWA_USE_IMMERSIVE_DARK_MODE_OLD,
                            &use_dark_mode, sizeof(use_dark_mode));
  }

  // On Windows 11 22H2+, set the caption / border / text colors explicitly
  // so the title bar exactly matches our app background (#0A0A0A) instead of
  // relying on the system's "dark" shade (which is a lighter gray). These
  // calls silently fail on older Windows versions, which is fine.
  // COLORREF is 0x00BBGGRR.
  COLORREF caption_color = RGB(0x0A, 0x0A, 0x0A);
  COLORREF text_color = RGB(0xF5, 0xF5, 0xF5);
  ::DwmSetWindowAttribute(GetHandle(), DWMWA_CAPTION_COLOR,
                          &caption_color, sizeof(caption_color));
  ::DwmSetWindowAttribute(GetHandle(), DWMWA_BORDER_COLOR,
                          &caption_color, sizeof(caption_color));
  ::DwmSetWindowAttribute(GetHandle(), DWMWA_TEXT_COLOR,
                          &text_color, sizeof(text_color));

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

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
