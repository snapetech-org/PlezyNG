// SPDX-License-Identifier: AGPL-3.0-only
#include "workspace_views.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <map>
#include <string>
#include <utility>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
// Non-owning view ABI in the pinned Flutter 3.47 SDK. Never substitute the
// engine-owning FlutterDesktopViewControllerCreate constructor.
struct ViewProperties {
  int width;
  int height;
};
using CreateView = FlutterDesktopViewControllerRef (*)(FlutterDesktopEngineRef, const ViewProperties*);
const std::string* Text(const Map* args, const char* key) {
  if (!args) return nullptr;
  auto found = args->find(Value(key));
  return found == args->end() ? nullptr : std::get_if<std::string>(&found->second);
}
bool Identity(const std::string* value, size_t size, const char* alphabet) {
  return value && value->size() == size && value->find_first_not_of(alphabet) == std::string::npos;
}
std::wstring Wide(const std::string& value) {
  const int count =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (count <= 0) return L"Pleazyng";
  std::wstring result(count, L'\0');
  MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), count);
  return result;
}
}  // namespace

class WorkspaceViews::Impl {
 public:
  explicit Impl(flutter::FlutterEngine* engine) : engine_(engine) {
    const auto module = GetModuleHandleW(L"flutter_windows.dll");
    create_ = module ? reinterpret_cast<CreateView>(GetProcAddress(module, "FlutterDesktopEngineCreateViewController"))
                     : nullptr;
    channel_ = std::make_unique<flutter::MethodChannel<Value>>(
        engine->messenger(), "com.pleazyng/workspace_views", &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto& call, auto result) { Handle(call, std::move(result)); });
  }
  ~Impl() {
    channel_->SetMethodCallHandler(nullptr);
    while (!windows_.empty()) Close(windows_.begin()->first);
  }

 private:
  struct Window {
    Impl* owner;
    std::string token;
    HWND hwnd = nullptr;
    FlutterDesktopViewControllerRef controller = nullptr;
  };
  flutter::FlutterEngine* engine_;
  CreateView create_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  std::map<std::string, std::unique_ptr<Window>> windows_;

  void Close(const std::string& token) {
    const auto found = windows_.find(token);
    if (found == windows_.end()) return;
    auto window = std::move(found->second);
    windows_.erase(found);
    const auto controller = std::exchange(window->controller, nullptr);
    if (controller) FlutterDesktopViewControllerDestroy(controller);
    if (window->hwnd) DestroyWindow(window->hwnd);
  }

  static LRESULT CALLBACK Procedure(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    auto* window = reinterpret_cast<Window*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      window = static_cast<Window*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
      window->hwnd = hwnd;
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(window));
    }
    if (!window) return DefWindowProcW(hwnd, message, wparam, lparam);
    if (message == WM_CLOSE) {
      window->owner->channel_->InvokeMethod(
          "closeRequested", std::make_unique<Value>(Map{{Value("token"), Value(window->token)}}));
      return 0;
    }
    if (message == WM_GETMINMAXINFO) {
      auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
      const UINT dpi = GetDpiForWindow(hwnd);
      limits->ptMinTrackSize = {MulDiv(320, static_cast<int>(dpi), 96), MulDiv(240, static_cast<int>(dpi), 96)};
      return 0;
    }
    if (message == WM_DPICHANGED) {
      const auto* rect = reinterpret_cast<RECT*>(lparam);
      SetWindowPos(
          hwnd, nullptr, rect->left, rect->top, rect->right - rect->left, rect->bottom - rect->top,
          SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }
    if (window->controller) {
      LRESULT result;
      if (FlutterDesktopViewControllerHandleTopLevelWindowProc(
              window->controller, hwnd, message, wparam, lparam, &result))
        return result;
      if (message == WM_SIZE) {
        const auto child = FlutterDesktopViewGetHWND(FlutterDesktopViewControllerGetView(window->controller));
        RECT bounds;
        GetClientRect(hwnd, &bounds);
        SetWindowPos(child, nullptr, 0, 0, bounds.right, bounds.bottom, SWP_NOZORDER);
        FlutterDesktopViewControllerForceRedraw(window->controller);
        return 0;
      }
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }

  void Handle(const flutter::MethodCall<Value>& call, std::unique_ptr<flutter::MethodResult<Value>> result) {
    if (call.method_name() == "available") {
      result->Success(Value(create_ != nullptr));
      return;
    }
    const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    const auto* token = Text(args, "token");
    if (!Identity(token, 32, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")) {
      result->Error("INVALID_WINDOW", "Invalid window identity");
      return;
    }
    if (call.method_name() == "close") {
      Close(*token);
      result->Success();
      return;
    }
    if (call.method_name() == "show") {
      const auto found = windows_.find(*token);
      if (found != windows_.end()) {
        ShowWindow(found->second->hwnd, SW_SHOWNORMAL);
        SetForegroundWindow(found->second->hwnd);
      }
      result->Success();
      return;
    }
    if (call.method_name() != "create") {
      result->NotImplemented();
      return;
    }
    const auto* title = Text(args, "title");
    const auto* geometry = Text(args, "geometryKey");
    if (!create_ || windows_.size() >= 8 || windows_.count(*token) || !title || title->size() > 1024 ||
        !Identity(geometry, 64, "0123456789abcdef")) {
      result->Error("INVALID_WINDOW", "Invalid window configuration");
      return;
    }
    static const wchar_t* name = L"PleazyngWorkspaceFlutterView";
    WNDCLASSW type{};
    type.hInstance = GetModuleHandleW(nullptr);
    type.lpfnWndProc = Procedure;
    type.lpszClassName = name;
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      result->Error("WINDOW_UNAVAILABLE", "Could not register the native window");
      return;
    }
    auto window = std::make_unique<Window>();
    window->owner = this;
    window->token = *token;
    const ViewProperties properties{900, 640};
    window->controller = create_(engine_->PlezyNativeHandle(), &properties);
    if (!window->controller) {
      result->Error("WINDOW_UNAVAILABLE", "Could not add a Flutter view");
      return;
    }
    const auto hwnd = CreateWindowExW(
        WS_EX_APPWINDOW, name, Wide(*title).c_str(), WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 900, 640,
        nullptr, nullptr, type.hInstance, window.get());
    if (!hwnd) {
      FlutterDesktopViewControllerDestroy(std::exchange(window->controller, nullptr));
      result->Error("WINDOW_UNAVAILABLE", "Could not create the native window");
      return;
    }
    const auto child = FlutterDesktopViewGetHWND(FlutterDesktopViewControllerGetView(window->controller));
    SetParent(child, hwnd);
    RECT bounds;
    GetClientRect(hwnd, &bounds);
    MoveWindow(child, 0, 0, bounds.right, bounds.bottom, TRUE);
    ShowWindow(child, SW_SHOW);
    const auto id = FlutterDesktopViewControllerGetViewId(window->controller);
    windows_.emplace(*token, std::move(window));
    result->Success(Value(Map{{Value("viewId"), Value(static_cast<int64_t>(id))}}));
  }
};
WorkspaceViews::WorkspaceViews(flutter::FlutterEngine* engine) : impl_(std::make_unique<Impl>(engine)) {}
WorkspaceViews::~WorkspaceViews() = default;
