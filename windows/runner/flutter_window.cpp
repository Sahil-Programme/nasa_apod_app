#include "flutter_window.h"

#include <optional>
#include <string>
#include <vector>
#include <windows.h>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
constexpr int kMinWindowWidth = 1280;
constexpr int kMinWindowHeight = 720;

bool Utf16FromUtf8(const std::string& utf8, std::wstring* out) {
  if (utf8.empty() || out == nullptr) {
    return false;
  }
  const int utf16_length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8.c_str(), -1, nullptr, 0);
  if (utf16_length <= 0) {
    return false;
  }

  std::vector<wchar_t> buffer(static_cast<size_t>(utf16_length));
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.c_str(), -1,
                          buffer.data(), utf16_length) == 0) {
    return false;
  }

  *out = std::wstring(buffer.data());
  return true;
}

bool ApplyWindowsWallpaperStyle(const std::string& style) {
  const wchar_t* wallpaper_style = L"10";
  const wchar_t* tile_wallpaper = L"0";
  if (style == "stretch") {
    wallpaper_style = L"2";
  } else if (style == "fit") {
    wallpaper_style = L"6";
  } else if (style != "fill") {
    return false;
  }

  HKEY key;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Control Panel\\Desktop", 0,
                    KEY_SET_VALUE, &key) != ERROR_SUCCESS) {
    return false;
  }

  const auto ok_style = RegSetValueExW(
      key, L"WallpaperStyle", 0, REG_SZ,
      reinterpret_cast<const BYTE*>(wallpaper_style),
      static_cast<DWORD>((wcslen(wallpaper_style) + 1) * sizeof(wchar_t)));
  const auto ok_tile = RegSetValueExW(
      key, L"TileWallpaper", 0, REG_SZ,
      reinterpret_cast<const BYTE*>(tile_wallpaper),
      static_cast<DWORD>((wcslen(tile_wallpaper) + 1) * sizeof(wchar_t)));
  RegCloseKey(key);
  return ok_style == ERROR_SUCCESS && ok_tile == ERROR_SUCCESS;
}

bool SetWindowsWallpaper(const std::string& path, const std::string& style) {
  std::wstring utf16_path;
  if (!Utf16FromUtf8(path, &utf16_path) || utf16_path.empty()) {
    return false;
  }
  if (GetFileAttributesW(utf16_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return false;
  }
  if (!ApplyWindowsWallpaperStyle(style)) {
    return false;
  }
  return SystemParametersInfoW(
      SPI_SETDESKWALLPAPER, 0, reinterpret_cast<PVOID>(utf16_path.data()),
      SPIF_UPDATEINIFILE | SPIF_SENDCHANGE);
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
  RegisterWallpaperChannel();
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

void FlutterWindow::RegisterWallpaperChannel() {
  wallpaper_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "nasa_apod_app/wallpaper",
          &flutter::StandardMethodCodec::GetInstance());

  wallpaper_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& method_call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (method_call.method_name() != "setWallpaper") {
          result->NotImplemented();
          return;
        }

        const auto* args =
            std::get_if<flutter::EncodableMap>(method_call.arguments());
        if (args == nullptr) {
          result->Success(flutter::EncodableValue(false));
          return;
        }

        const auto path_it = args->find(flutter::EncodableValue("path"));
        const auto style_it = args->find(flutter::EncodableValue("style"));
        if (path_it == args->end() || style_it == args->end()) {
          result->Success(flutter::EncodableValue(false));
          return;
        }

        const auto* path = std::get_if<std::string>(&path_it->second);
        const auto* style = std::get_if<std::string>(&style_it->second);
        if (path == nullptr || style == nullptr) {
          result->Success(flutter::EncodableValue(false));
          return;
        }

        const bool ok = SetWindowsWallpaper(*path, *style);
        result->Success(flutter::EncodableValue(ok));
      });
}

void FlutterWindow::OnDestroy() {
  wallpaper_channel_ = nullptr;
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
    case WM_GETMINMAXINFO: {
      auto* min_max_info = reinterpret_cast<MINMAXINFO*>(lparam);
      UINT dpi = GetDpiForWindow(hwnd);
      if (dpi == 0) {
        dpi = 96;
      }
      min_max_info->ptMinTrackSize.x = MulDiv(kMinWindowWidth, dpi, 96);
      min_max_info->ptMinTrackSize.y = MulDiv(kMinWindowHeight, dpi, 96);
      return 0;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
