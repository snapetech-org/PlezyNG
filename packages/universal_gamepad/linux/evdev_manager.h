#ifndef EVDEV_MANAGER_H_
#define EVDEV_MANAGER_H_

#include <flutter_linux/flutter_linux.h>
#include <libevdev/libevdev.h>
#include <linux/input.h>
#include <sys/stat.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "gamepad_effects.h"

/// Manages gamepad lifecycle via direct evdev on a dedicated GLib thread.
///
/// Device scanning, hotplug monitoring, and event reading all happen on a
/// private GMainLoop running in its own thread.  Finished events are queued
/// and drained by a 16 ms periodic timer on the main GMainContext so that
/// FlValue/EventChannel calls stay on the main thread.  No cross-thread
/// g_idle_add / g_main_context_wakeup is used — the worker just pushes to
/// the queue.
///
/// Axis events are throttled: a new value is only forwarded when it differs
/// from the previous value by more than kAxisEpsilon.  Duplicate axis events
/// in the same drain batch are coalesced to the latest value.
class EvdevManager {
 public:
  using EventCallback = std::function<void(FlValue* event)>;

  EvdevManager();
  ~EvdevManager();

  void Start(EventCallback callback);
  void Stop();
  FlValue* ListGamepads();
  void EmitExistingDevices();
  bool ClaimEffects(const std::string& token);
  void ReleaseEffects(const std::string& token);
  void StopEffects();
  bool ApplyEffects(const std::string& token, int id, int flags, const std::array<int, 6>& values, bool sensors);
  FlValue* EffectsState(const std::string& token, int id);

 private:
  static constexpr double kAxisEpsilon = 0.005;

  struct DeviceInfo {
    int fd;
    struct libevdev* evdev;
    int id;
    std::string name;
    uint16_t vendor_id;
    uint16_t product_id;
    dev_t node_dev;
    ino_t node_ino;
    dev_t rdev;
    // True when the driver reports face buttons by label (xpad), requiring
    // BTN_NORTH/BTN_WEST to be swapped to match the physical layout.
    bool swap_north_west;
    struct input_absinfo abs_info[ABS_MAX];
    GSource* io_source;
    // Last emitted axis values for throttling (indexed by W3C axis).
    double last_axis[4];
    // Last emitted trigger values for throttling (indexed by W3C button).
    double last_trigger[2];
    std::shared_ptr<LinuxGamepadEffects> effects;
  };

  static int64_t NowMillis();
  static bool IsSameDeviceNode(const DeviceInfo& info, const struct stat& statbuf);
  bool IsGamepad(struct libevdev* dev);
  void ScanDevices();
  bool AddDevice(const char* path);
  void RemoveDevice(const char* path);
  void ScheduleRemoveDevice(const std::string& path, bool rescan_after_removal = true);
  void ScheduleScanRetry(int attempts);
  void OnInput(DeviceInfo& info, const std::string& path);

  /// Queue an event for delivery on the next timer tick.
  void ForwardEvent(FlValue* event);

  /// Main-thread timer callback that drains pending_events_.
  static gboolean DrainEvents(gpointer user_data);

  static void OnDirectoryChanged(
      GFileMonitor* monitor, GFile* file, GFile* other, GFileMonitorEvent event_type, gpointer user_data);
  static gpointer ThreadFunc(gpointer user_data);

  // Worker thread state — accessed only from the worker thread.
  GMainContext* worker_context_ = nullptr;
  GMainLoop* worker_loop_ = nullptr;
  GThread* worker_thread_ = nullptr;
  GFileMonitor* dir_monitor_ = nullptr;
  gulong dir_monitor_signal_id_ = 0;
  std::unordered_map<std::string, DeviceInfo> devices_;
  int next_id_ = 0;
  GSource* scan_retry_source_ = nullptr;
  int scan_retry_attempts_left_ = 0;

  // Shared state — protected by mutex_.
  std::mutex mutex_;
  std::string effectsOwner_;
  EventCallback callback_;

  // Event queue — protected by queue_mutex_.
  std::mutex queue_mutex_;
  std::vector<FlValue*> pending_events_;
  GSource* drain_timer_ = nullptr;
};

#endif  // EVDEV_MANAGER_H_
