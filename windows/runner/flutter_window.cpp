#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Where the window's placement is kept between runs.
constexpr wchar_t kWindowStateKey[] = L"Software\\Outsmartis\\Conductore";
constexpr wchar_t kWindowPlacementValue[] = L"WindowPlacement";

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  int length = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                     static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring utf16(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        utf16.data(), length);
  return utf16;
}

// Moves the (still hidden) window to where it was last closed.
void RestoreWindowPlacement(HWND window) {
  WINDOWPLACEMENT placement{};
  DWORD size = sizeof(placement);
  if (::RegGetValueW(HKEY_CURRENT_USER, kWindowStateKey, kWindowPlacementValue,
                     RRF_RT_REG_BINARY, nullptr, &placement,
                     &size) != ERROR_SUCCESS ||
      size != sizeof(placement) || placement.length != sizeof(placement)) {
    return;
  }
  const RECT& rect = placement.rcNormalPosition;
  if (rect.right - rect.left < 400 || rect.bottom - rect.top < 300) {
    return;
  }
  // Only onto a monitor that is still there.
  if (::MonitorFromRect(&rect, MONITOR_DEFAULTTONULL) == nullptr) {
    return;
  }
  ::SetWindowPos(window, nullptr, rect.left, rect.top, rect.right - rect.left,
                 rect.bottom - rect.top, SWP_NOZORDER | SWP_NOACTIVATE);
}

void SaveWindowPlacement(HWND window) {
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (!::GetWindowPlacement(window, &placement)) {
    return;
  }
  ::RegSetKeyValueW(HKEY_CURRENT_USER, kWindowStateKey, kWindowPlacementValue,
                    REG_BINARY, &placement, sizeof(placement));
}

}  // namespace

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
  RestoreWindowPlacement(GetHandle());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "conductore/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setTitle") {
          const auto* title = std::get_if<std::string>(call.arguments());
          if (title != nullptr) {
            ::SetWindowTextW(GetHandle(), Utf16FromUtf8(*title).c_str());
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

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
  window_channel_ = nullptr;
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
    case WM_CLOSE:
      SaveWindowPlacement(hwnd);
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
