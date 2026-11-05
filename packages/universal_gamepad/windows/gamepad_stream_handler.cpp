#include "gamepad_stream_handler.h"

namespace gamepad {

// ---------------------------------------------------------------------------
// GamepadStreamHandler
// ---------------------------------------------------------------------------

GamepadStreamHandler::GamepadStreamHandler() = default;
GamepadStreamHandler::~GamepadStreamHandler() = default;

void GamepadStreamHandler::SendEvent(const flutter::EncodableValue& event) {
  std::function<bool()> wake_callback;
  bool should_post = false;
  {
    std::lock_guard<std::mutex> lock(sink_mutex_);
    if (!event_sink_) {
      return;
    }
    pending_events_.push_back(event);
    should_post = !flush_posted_.exchange(true);
    wake_callback = wake_callback_;
  }
  if (should_post) {
    const bool posted = wake_callback && wake_callback();
    if (!posted) {
      // The platform thread couldn't be woken (e.g. the HWND isn't known
      // yet). Clear the latch so the next event retries the post; queued
      // events are also flushed when the HWND is first captured.
      flush_posted_.store(false);
    }
  }
}

void GamepadStreamHandler::FlushQueuedEvents() {
  std::deque<flutter::EncodableValue> local_events;
  {
    std::lock_guard<std::mutex> lock(sink_mutex_);
    local_events.swap(pending_events_);
    flush_posted_.store(false);
    if (!event_sink_) {
      return;
    }
  }

  for (const auto& event : local_events) {
    event_sink_->Success(event);
  }

  std::function<bool()> wake_callback;
  bool should_post = false;
  {
    std::lock_guard<std::mutex> lock(sink_mutex_);
    if (!pending_events_.empty()) {
      should_post = !flush_posted_.exchange(true);
      wake_callback = wake_callback_;
    }
  }
  if (should_post) {
    const bool posted = wake_callback && wake_callback();
    if (!posted) {
      flush_posted_.store(false);
    }
  }
}

bool GamepadStreamHandler::HasListener() const {
  std::lock_guard<std::mutex> lock(sink_mutex_);
  return event_sink_ != nullptr;
}

void GamepadStreamHandler::SetWakeCallback(std::function<bool()> callback) {
  std::lock_guard<std::mutex> lock(sink_mutex_);
  wake_callback_ = std::move(callback);
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
GamepadStreamHandler::OnListenInternal(
    const flutter::EncodableValue* arguments,
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
  std::lock_guard<std::mutex> lock(sink_mutex_);
  event_sink_ = std::move(events);
  pending_events_.clear();
  flush_posted_.store(false);
  return nullptr;
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
GamepadStreamHandler::OnCancelInternal(
    const flutter::EncodableValue* arguments) {
  std::lock_guard<std::mutex> lock(sink_mutex_);
  event_sink_ = nullptr;
  pending_events_.clear();
  flush_posted_.store(false);
  return nullptr;
}

// ---------------------------------------------------------------------------
// ForwardingStreamHandler
// ---------------------------------------------------------------------------

ForwardingStreamHandler::ForwardingStreamHandler(
    std::shared_ptr<GamepadStreamHandler> delegate)
    : delegate_(std::move(delegate)) {}

ForwardingStreamHandler::~ForwardingStreamHandler() = default;

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
ForwardingStreamHandler::OnListenInternal(
    const flutter::EncodableValue* arguments,
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
  // Forward the sink to the shared handler.
  return delegate_->OnListenInternal(arguments, std::move(events));
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
ForwardingStreamHandler::OnCancelInternal(
    const flutter::EncodableValue* arguments) {
  return delegate_->OnCancelInternal(arguments);
}

}  // namespace gamepad
