#include "gamepad_stream_handler.h"

GamepadStreamHandler::GamepadStreamHandler() = default;

GamepadStreamHandler::~GamepadStreamHandler() = default;

void GamepadStreamHandler::SetChannel(FlEventChannel* channel) {
  channel_ = channel;
  fl_event_channel_set_stream_handlers(
      channel_, OnListenCb, OnCancelCb, this, nullptr);
}

void GamepadStreamHandler::SendEvent(FlValue* event) {
  if (channel_ && listening_) {
    g_autoptr(GError) error = nullptr;
    fl_event_channel_send(channel_, event, nullptr, &error);
    if (error) {
      g_warning("gamepad: failed to send event: %s", error->message);
    }
  }
}

bool GamepadStreamHandler::HasListener() const { return listening_; }

void GamepadStreamHandler::SetListenCallback(ListenCallback callback) {
  listen_callback_ = std::move(callback);
}

FlMethodErrorResponse* GamepadStreamHandler::OnListenCb(
    FlEventChannel* channel, FlValue* args, gpointer user_data) {
  auto* self = static_cast<GamepadStreamHandler*>(user_data);
  self->listening_ = true;
  if (self->listen_callback_) {
    self->listen_callback_(true);
  }
  return nullptr;
}

FlMethodErrorResponse* GamepadStreamHandler::OnCancelCb(
    FlEventChannel* channel, FlValue* args, gpointer user_data) {
  auto* self = static_cast<GamepadStreamHandler*>(user_data);
  self->listening_ = false;
  if (self->listen_callback_) {
    self->listen_callback_(false);
  }
  return nullptr;
}
