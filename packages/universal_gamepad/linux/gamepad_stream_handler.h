#ifndef GAMEPAD_STREAM_HANDLER_H_
#define GAMEPAD_STREAM_HANDLER_H_

#include <flutter_linux/flutter_linux.h>

#include <functional>

/// Stream handler that bridges native gamepad events to the Dart EventChannel.
///
/// Wraps an FlEventChannel and registers listen/cancel callbacks. When Dart
/// starts listening, the handler notifies the caller via a callback.
/// When Dart cancels, the caller is notified again.
class GamepadStreamHandler {
 public:
  GamepadStreamHandler();
  ~GamepadStreamHandler();

  /// Attaches this handler to the given event channel. Must be called once
  /// during plugin registration. Takes ownership of nothing; the channel
  /// must outlive this handler.
  void SetChannel(FlEventChannel* channel);

  /// Sends an event (compact positional FlValue list; element 0 = type tag)
  /// to the Dart side. No-op if nobody is listening. The caller retains
  /// ownership of |event|.
  void SendEvent(FlValue* event);

  /// Returns true if a Dart listener is currently active.
  bool HasListener() const;

  /// Callback type for when listening starts or stops.
  using ListenCallback = std::function<void(bool listening)>;

  /// Sets a callback invoked when Dart starts or stops listening.
  void SetListenCallback(ListenCallback callback);

 private:
  /// The FlEventChannel used to send events to Dart.
  FlEventChannel* channel_ = nullptr;

  /// Whether the Dart side is currently listening.
  bool listening_ = false;

  /// Callback for listen state changes.
  ListenCallback listen_callback_;

  /// Static C callback for fl_event_channel_set_stream_handlers (listen).
  static FlMethodErrorResponse* OnListenCb(FlEventChannel* channel,
                                           FlValue* args,
                                           gpointer user_data);

  /// Static C callback for fl_event_channel_set_stream_handlers (cancel).
  static FlMethodErrorResponse* OnCancelCb(FlEventChannel* channel,
                                           FlValue* args,
                                           gpointer user_data);
};

#endif  // GAMEPAD_STREAM_HANDLER_H_
