// SPDX-License-Identifier: AGPL-3.0-only
#include "workspace_views.h"

#include <cstring>
#include <map>
#include <memory>
#include <string>

namespace {
constexpr char kChannel[] = "com.pleazyng/workspace_views";
struct Host;
struct Window {
  Host* host;
  std::string token;
  GtkWidget* widget;
};
struct Host {
  FlEngine* engine;
  GtkApplication* application;
  FlMethodChannel* channel;
  std::map<std::string, std::unique_ptr<Window>> windows;
  ~Host() {
    fl_method_channel_set_method_call_handler(channel, nullptr, nullptr, nullptr);
    auto previous = std::move(windows);
    for (const auto& row : previous) gtk_widget_destroy(row.second->widget);
    g_object_unref(channel);
    g_object_unref(engine);
  }
};
const char* String(FlValue* args, const char* key) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
  auto* value = fl_value_lookup_string(args, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING ? fl_value_get_string(value) : nullptr;
}
bool Identity(const char* value, size_t size, const char* alphabet) {
  return value && strlen(value) == size && strspn(value, alphabet) == size;
}
void Success(FlMethodCall* call, FlValue* value = nullptr) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(call, response, nullptr);
}
void Error(FlMethodCall* call) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_error_response_new("INVALID_WINDOW", "Invalid window configuration", nullptr));
  fl_method_call_respond(call, response, nullptr);
}
gboolean CloseRequested(GtkWidget*, GdkEvent*, gpointer data) {
  auto* window = static_cast<Window*>(data);
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "token", fl_value_new_string(window->token.c_str()));
  fl_method_channel_invoke_method(window->host->channel, "closeRequested", args, nullptr, nullptr, nullptr);
  return TRUE;
}
void Handle(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* host = static_cast<Host*>(data);
  const std::string method = fl_method_call_get_name(call);
  if (method == "available") {
    g_autoptr(FlValue) value = fl_value_new_bool(true);
    Success(call, value);
    return;
  }
  auto* args = fl_method_call_get_args(call);
  const char* token = String(args, "token");
  if (!Identity(token, 32, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")) {
    Error(call);
    return;
  }
  if (method == "create") {
    const char* title = String(args, "title");
    const char* geometry = String(args, "geometryKey");
    if (!title || strlen(title) > 1024 || !Identity(geometry, 64, "0123456789abcdef") || host->windows.size() >= 8 ||
        host->windows.count(token)) {
      Error(call);
      return;
    }
    GtkWidget* window = gtk_application_window_new(host->application);
    gtk_window_set_title(GTK_WINDOW(window), title);
    gtk_window_set_default_size(GTK_WINDOW(window), 900, 640);
    gtk_widget_set_size_request(window, 320, 240);
    FlView* view = fl_view_new_for_engine(host->engine);
    if (!view) {
      gtk_widget_destroy(window);
      Error(call);
      return;
    }
    gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));
    gtk_widget_show(GTK_WIDGET(view));
    auto owned = std::make_unique<Window>(Window{host, token, window});
    g_signal_connect(window, "delete-event", G_CALLBACK(CloseRequested), owned.get());
    host->windows.emplace(token, std::move(owned));
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(result, "viewId", fl_value_new_int(fl_view_get_id(view)));
    Success(call, result);
  } else if (method == "show") {
    const auto found = host->windows.find(token);
    if (found != host->windows.end()) {
      gtk_widget_show(found->second->widget);
      gtk_window_present(GTK_WINDOW(found->second->widget));
    }
    Success(call);
  } else if (method == "close") {
    const auto found = host->windows.find(token);
    if (found != host->windows.end()) {
      gtk_widget_destroy(found->second->widget);
      host->windows.erase(found);
    }
    Success(call);
  } else {
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
  }
}
void Release(gpointer data) { delete static_cast<Host*>(data); }
}  // namespace

void plezy_workspace_views_register(FlView* root, GtkWindow* parent) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  auto* engine = fl_view_get_engine(root);
  auto* host = new Host{
      FL_ENGINE(g_object_ref(engine)),
      gtk_window_get_application(parent),
      fl_method_channel_new(fl_engine_get_binary_messenger(engine), kChannel, FL_METHOD_CODEC(codec)),
      {}};
  fl_method_channel_set_method_call_handler(host->channel, Handle, host, nullptr);
  g_object_set_data_full(G_OBJECT(root), "plezy-workspace-views", host, Release);
}
