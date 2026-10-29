#include "evdev_manager.h"

#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstring>
#include <regex>
#include <unordered_set>
#include <vector>

#include "button_mapping.h"

namespace {
constexpr guint kHotplugRetryDelayMs = 50;
constexpr int kHotplugRetryAttempts = 8;

bool IsEventNodeName(const char* name) { return name && strncmp(name, "event", 5) == 0; }

// The xpad driver maps face buttons by label (physical X = BTN_X = BTN_NORTH,
// physical Y = BTN_Y = BTN_WEST) instead of by location as the Linux gamepad
// spec prescribes (and hid-playstation etc. follow). Detect it through the
// sysfs driver symlink for the device node, falling back to the Microsoft
// vendor ID when sysfs is unavailable.
bool UsesLabelMappedFaceButtons(const char* dev_path, uint16_t vendor_id) {
  const char* base = strrchr(dev_path, '/');
  base = base ? base + 1 : dev_path;
  std::string link = std::string("/sys/class/input/") + base + "/device/device/driver";
  char target[256];
  ssize_t len = readlink(link.c_str(), target, sizeof(target) - 1);
  if (len > 0) {
    target[len] = '\0';
    const char* driver = strrchr(target, '/');
    driver = driver ? driver + 1 : target;
    return strcmp(driver, "xpad") == 0;
  }
  constexpr uint16_t kVendorMicrosoft = 0x045e;
  return vendor_id == kVendorMicrosoft;
}

}  // namespace

EvdevManager::EvdevManager() = default;

EvdevManager::~EvdevManager() { Stop(); }

bool EvdevManager::ClaimEffects(const std::string& token) {
  if (!std::regex_match(token, std::regex("[0-9a-f]{32}-[0-9]{1,10}-[0-9]{1,10}"))) return false;
  std::lock_guard<std::mutex> lock(mutex_);
  if (effectsOwner_ != token) {
    for (auto& entry : devices_) entry.second.effects.reset();
    effectsOwner_ = token;
  }
  return true;
}
void EvdevManager::ReleaseEffects(const std::string& token) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (effectsOwner_ != token) return;
  for (auto& entry : devices_) entry.second.effects.reset();
  effectsOwner_.clear();
}
void EvdevManager::StopEffects() {
  std::lock_guard<std::mutex> lock(mutex_);
  for (auto& entry : devices_) entry.second.effects.reset();
  effectsOwner_.clear();
}
bool EvdevManager::ApplyEffects(
    const std::string& token, int id, int flags, const std::array<int, 6>& values, bool sensors) {
  if (flags < 0 || flags > 7) return false;
  for (size_t i = 0; i < values.size(); ++i)
    if (values[i] < 0 || values[i] > (i % 3 == 2 ? 1000 : 65535)) return false;
  std::lock_guard<std::mutex> lock(mutex_);
  if (effectsOwner_.empty() || effectsOwner_ != token) return false;
  unsigned allocated = 0;
  for (const auto& entry : devices_)
    if (entry.second.effects) ++allocated;
  for (auto& entry : devices_)
    if (entry.second.id == id) {
      auto& effects = entry.second.effects;
      if (!effects && allocated < 4) effects = std::make_shared<LinuxGamepadEffects>(entry.first, entry.second.fd);
      if (!effects) return false;
      if (flags & 1) effects->Rumble(values[0], values[1], values[2]);
      if (flags & 4) effects->Sensors(sensors);
      return true;
    }
  return false;
}
FlValue* EvdevManager::EffectsState(const std::string& token, int id) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (effectsOwner_.empty() || effectsOwner_ != token) return fl_value_new_null();
  for (auto& entry : devices_)
    if (entry.second.id == id && entry.second.effects) {
      auto* result = fl_value_new_list();
      for (double value : entry.second.effects->State()) fl_value_append_take(result, fl_value_new_float(value));
      return result;
    }
  return fl_value_new_null();
}

// ---------------------------------------------------------------------------
// Public API (called from main thread)
// ---------------------------------------------------------------------------

void EvdevManager::Start(EventCallback callback) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    callback_ = std::move(callback);
  }

  // Create a private GMainContext + GMainLoop for the worker thread.
  worker_context_ = g_main_context_new();
  worker_loop_ = g_main_loop_new(worker_context_, FALSE);

  // Push our context as the thread-default so that g_file_monitor and
  // g_source_attach use it rather than the global default.
  g_main_context_push_thread_default(worker_context_);

  ScanDevices();

  // Watch /dev/input/ for hotplug.
  GFile* dir = g_file_new_for_path("/dev/input");
  GError* error = nullptr;
  dir_monitor_ = g_file_monitor_directory(dir, G_FILE_MONITOR_NONE, nullptr, &error);
  g_object_unref(dir);

  if (dir_monitor_) {
    dir_monitor_signal_id_ = g_signal_connect(dir_monitor_, "changed", G_CALLBACK(OnDirectoryChanged), this);
  } else {
    g_warning("evdev: failed to monitor /dev/input: %s", error ? error->message : "unknown");
    if (error) g_error_free(error);
  }

  g_main_context_pop_thread_default(worker_context_);

  // Periodic timer on the main thread drains queued events.
  // No cross-thread g_idle_add / g_main_context_wakeup — the worker just
  // pushes to the queue and this timer picks them up at ~60 Hz.
  drain_timer_ = g_timeout_source_new(16);
  g_source_set_callback(drain_timer_, DrainEvents, this, nullptr);
  g_source_attach(drain_timer_, nullptr);  // default (main) context

  // Start the worker thread — it will run worker_loop_.
  worker_thread_ = g_thread_new("evdev-worker", ThreadFunc, this);
}

void EvdevManager::Stop() {
  StopEffects();
  // Signal the worker loop to quit.
  if (worker_loop_) {
    g_main_loop_quit(worker_loop_);
  }
  if (worker_thread_) {
    g_thread_join(worker_thread_);
    worker_thread_ = nullptr;
  }

  // Now single-threaded — safe to clean up without locks.
  if (dir_monitor_) {
    if (dir_monitor_signal_id_) {
      g_signal_handler_disconnect(dir_monitor_, dir_monitor_signal_id_);
      dir_monitor_signal_id_ = 0;
    }
    g_file_monitor_cancel(dir_monitor_);
    g_object_unref(dir_monitor_);
    dir_monitor_ = nullptr;
  }

  if (scan_retry_source_) {
    g_source_destroy(scan_retry_source_);
    g_source_unref(scan_retry_source_);
    scan_retry_source_ = nullptr;
    scan_retry_attempts_left_ = 0;
  }

  for (auto& [path, info] : devices_) {
    if (info.io_source) {
      g_source_destroy(info.io_source);
      g_source_unref(info.io_source);
    }
    libevdev_free(info.evdev);
    close(info.fd);
  }
  devices_.clear();

  if (worker_loop_) {
    g_main_loop_unref(worker_loop_);
    worker_loop_ = nullptr;
  }
  if (worker_context_) {
    g_main_context_unref(worker_context_);
    worker_context_ = nullptr;
  }

  if (drain_timer_) {
    g_source_destroy(drain_timer_);
    g_source_unref(drain_timer_);
    drain_timer_ = nullptr;
  }

  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    for (FlValue* ev : pending_events_) {
      fl_value_unref(ev);
    }
    pending_events_.clear();
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    callback_ = nullptr;
  }
}

FlValue* EvdevManager::ListGamepads() {
  std::lock_guard<std::mutex> lock(mutex_);
  FlValue* list = fl_value_new_list();

  for (const auto& [path, info] : devices_) {
    FlValue* map = fl_value_new_map();
    fl_value_set_string_take(map, "id", fl_value_new_int(info.id));
    fl_value_set_string_take(map, "name", fl_value_new_string(info.name.c_str()));
    fl_value_set_string_take(map, "vendorId", fl_value_new_int(info.vendor_id));
    fl_value_set_string_take(map, "productId", fl_value_new_int(info.product_id));
    fl_value_append_take(list, map);
  }

  return list;
}

void EvdevManager::EmitExistingDevices() {
  // Snapshot under the lock, emit after releasing it — callback_ re-enters
  // Flutter engine code and must not run under mutex_.
  struct Snapshot {
    int id;
    std::string name;
    uint16_t vendor_id;
    uint16_t product_id;
  };
  std::vector<Snapshot> snapshot;
  EventCallback cb;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    cb = callback_;
    if (!cb) return;
    for (const auto& [path, info] : devices_) {
      snapshot.push_back({info.id, info.name, info.vendor_id, info.product_id});
    }
  }

  // Drop queued connect events: the snapshot below already announces every
  // tracked device, so letting them drain afterwards would deliver duplicate
  // connects to the fresh listener. (A connect queued between the snapshot
  // and this purge can still slip through, but that window is microseconds
  // around a hotplug racing the first listen.)
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    pending_events_.erase(
        std::remove_if(
            pending_events_.begin(), pending_events_.end(),
            [](FlValue* ev) {
              bool is_connect = fl_value_get_length(ev) >= 4 && fl_value_get_int(fl_value_get_list_value(ev, 0)) == 0 &&
                                fl_value_get_bool(fl_value_get_list_value(ev, 3));
              if (is_connect) fl_value_unref(ev);
              return is_connect;
            }),
        pending_events_.end());
  }

  for (const auto& d : snapshot) {
    int64_t ts = NowMillis();
    // Wire format: [0, gamepadId, timestamp, connected, name, vendorId, productId]
    FlValue* event = fl_value_new_list();
    fl_value_append_take(event, fl_value_new_int(0));
    fl_value_append_take(event, fl_value_new_int(d.id));
    fl_value_append_take(event, fl_value_new_int(ts));
    fl_value_append_take(event, fl_value_new_bool(TRUE));
    fl_value_append_take(event, fl_value_new_string(d.name.c_str()));
    fl_value_append_take(event, fl_value_new_int(d.vendor_id));
    fl_value_append_take(event, fl_value_new_int(d.product_id));
    cb(event);
    fl_value_unref(event);
  }
}

// ---------------------------------------------------------------------------
// Worker thread
// ---------------------------------------------------------------------------

gpointer EvdevManager::ThreadFunc(gpointer user_data) {
  auto* self = static_cast<EvdevManager*>(user_data);
  g_main_context_push_thread_default(self->worker_context_);
  g_main_loop_run(self->worker_loop_);
  g_main_context_pop_thread_default(self->worker_context_);
  return nullptr;
}

// ---------------------------------------------------------------------------
// Event forwarding (worker → main thread)
// ---------------------------------------------------------------------------

void EvdevManager::ForwardEvent(FlValue* event) {
  fl_value_ref(event);
  std::lock_guard<std::mutex> lock(queue_mutex_);
  pending_events_.push_back(event);
}

gboolean EvdevManager::DrainEvents(gpointer user_data) {
  auto* self = static_cast<EvdevManager*>(user_data);

  std::vector<FlValue*> events;
  {
    std::lock_guard<std::mutex> lock(self->queue_mutex_);
    if (self->pending_events_.empty()) return G_SOURCE_CONTINUE;
    events.swap(self->pending_events_);
  }

  // Coalesce axis events: keep only the latest per (gamepadId, axisIndex).
  // Scan in reverse so the first occurrence we see is the newest.
  // Wire format for axis: [2, gamepadId, timestamp, axisIndex, value]
  std::unordered_set<uint64_t> seen_axes;
  for (int i = static_cast<int>(events.size()) - 1; i >= 0; --i) {
    FlValue* ev = events[i];
    if (fl_value_get_length(ev) >= 5 && fl_value_get_int(fl_value_get_list_value(ev, 0)) == 2) {
      int64_t gid = fl_value_get_int(fl_value_get_list_value(ev, 1));
      int64_t axis = fl_value_get_int(fl_value_get_list_value(ev, 3));
      uint64_t key = (static_cast<uint64_t>(gid) << 8) | static_cast<uint64_t>(axis);
      if (!seen_axes.insert(key).second) {
        fl_value_unref(ev);
        events[i] = nullptr;
      }
    }
  }

  EventCallback cb;
  {
    std::lock_guard<std::mutex> lock(self->mutex_);
    cb = self->callback_;
  }

  for (FlValue* ev : events) {
    if (!ev) continue;
    if (cb) cb(ev);
    fl_value_unref(ev);
  }

  return G_SOURCE_CONTINUE;
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

int64_t EvdevManager::NowMillis() {
  auto now = std::chrono::system_clock::now();
  auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();
  return static_cast<int64_t>(ms);
}

bool EvdevManager::IsGamepad(struct libevdev* dev) {
  bool has_buttons = libevdev_has_event_code(dev, EV_KEY, BTN_A) || libevdev_has_event_code(dev, EV_KEY, BTN_TRIGGER) ||
                     libevdev_has_event_code(dev, EV_KEY, BTN_1);
  bool has_axes = libevdev_has_event_code(dev, EV_ABS, ABS_RX) || libevdev_has_event_code(dev, EV_ABS, ABS_RY) ||
                  libevdev_has_event_code(dev, EV_ABS, ABS_RZ) || libevdev_has_event_code(dev, EV_ABS, ABS_THROTTLE) ||
                  libevdev_has_event_code(dev, EV_ABS, ABS_RUDDER) || libevdev_has_event_code(dev, EV_ABS, ABS_WHEEL) ||
                  libevdev_has_event_code(dev, EV_ABS, ABS_GAS) || libevdev_has_event_code(dev, EV_ABS, ABS_BRAKE);
  return has_buttons || has_axes;
}

bool EvdevManager::IsSameDeviceNode(const DeviceInfo& info, const struct stat& statbuf) {
  return info.node_dev == statbuf.st_dev && info.node_ino == statbuf.st_ino && info.rdev == statbuf.st_rdev;
}

void EvdevManager::ScanDevices() {
  DIR* dir = opendir("/dev/input");
  if (!dir) return;

  std::unordered_set<std::string> seen_paths;
  struct dirent* entry;
  while ((entry = readdir(dir)) != nullptr) {
    if (!IsEventNodeName(entry->d_name)) continue;
    std::string path = std::string("/dev/input/") + entry->d_name;
    seen_paths.insert(path);
    AddDevice(path.c_str());
  }
  closedir(dir);

  std::vector<std::string> stale_paths;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& [path, info] : devices_) {
      if (seen_paths.find(path) == seen_paths.end()) {
        stale_paths.push_back(path);
      }
    }
  }

  for (const auto& path : stale_paths) {
    RemoveDevice(path.c_str());
  }
}

bool EvdevManager::AddDevice(const char* path) {
  std::string path_str(path);

  int fd = open(path, O_RDONLY | O_NONBLOCK);
  if (fd < 0) {
    g_debug("evdev: failed to open %s: %s", path, g_strerror(errno));
    return false;
  }

  struct stat statbuf;
  if (fstat(fd, &statbuf) < 0) {
    g_debug("evdev: failed to stat %s: %s", path, g_strerror(errno));
    close(fd);
    return false;
  }

  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = devices_.find(path_str);
    if (it != devices_.end() && IsSameDeviceNode(it->second, statbuf)) {
      close(fd);
      return true;
    }
  }

  RemoveDevice(path);

  struct libevdev* dev = nullptr;
  int rc = libevdev_new_from_fd(fd, &dev);
  if (rc < 0) {
    g_debug("evdev: failed to initialize %s: %s", path, g_strerror(-rc));
    close(fd);
    return false;
  }

  if (!IsGamepad(dev)) {
    libevdev_free(dev);
    close(fd);
    return true;
  }

  DeviceInfo info{};
  info.fd = fd;
  info.evdev = dev;
  info.id = next_id_++;

  const char* name = libevdev_get_name(dev);
  info.name = name ? name : "Unknown Gamepad";
  info.vendor_id = static_cast<uint16_t>(libevdev_get_id_vendor(dev));
  info.product_id = static_cast<uint16_t>(libevdev_get_id_product(dev));
  info.swap_north_west = UsesLabelMappedFaceButtons(path, info.vendor_id);
  info.node_dev = statbuf.st_dev;
  info.node_ino = statbuf.st_ino;
  info.rdev = statbuf.st_rdev;

  // Initialize last-emitted values to NaN so the first event always fires.
  for (int i = 0; i < 4; ++i) info.last_axis[i] = NAN;
  for (int i = 0; i < 2; ++i) info.last_trigger[i] = NAN;

  // Cache abs_info for axis normalization.
  for (unsigned int code = 0; code < ABS_MAX; ++code) {
    if (libevdev_has_event_code(dev, EV_ABS, code)) {
      const struct input_absinfo* ai = libevdev_get_abs_info(dev, code);
      if (ai) {
        info.abs_info[code] = *ai;
      }
    }
  }

  // Attach an IO source to the worker context.
  GIOChannel* channel = g_io_channel_unix_new(fd);

  GSource* source = g_io_create_watch(channel, static_cast<GIOCondition>(G_IO_IN | G_IO_HUP | G_IO_ERR));
  g_io_channel_unref(channel);

  struct WatchData {
    EvdevManager* self;
    std::string path;
  };
  auto* wd = new WatchData{this, path_str};

  g_source_set_callback(
      source,
      G_SOURCE_FUNC(static_cast<GIOFunc>([](GIOChannel* src, GIOCondition condition, gpointer user_data) -> gboolean {
        auto* wd = static_cast<WatchData*>(user_data);
        auto* self = wd->self;

        // No mutex_ needed: all worker-thread callbacks (IO, AddDevice,
        // RemoveDevice) are serialized by the worker GMainLoop. The main
        // thread only reads devices_ under mutex_ in ListGamepads /
        // EmitExistingDevices, and concurrent reads are safe.
        auto it = self->devices_.find(wd->path);
        if (it == self->devices_.end()) return G_SOURCE_REMOVE;

        if (condition & (G_IO_HUP | G_IO_ERR)) {
          self->ScheduleRemoveDevice(wd->path);
          return G_SOURCE_REMOVE;
        }

        self->OnInput(it->second, wd->path);
        return G_SOURCE_CONTINUE;
      })),
      wd, [](gpointer data) { delete static_cast<WatchData*>(data); });

  g_source_attach(source, worker_context_);
  info.io_source = source;

  // Build connection event before inserting (we need the info fields).
  int64_t ts = NowMillis();
  // Wire format: [0, gamepadId, timestamp, connected, name, vendorId, productId]
  FlValue* event = fl_value_new_list();
  fl_value_append_take(event, fl_value_new_int(0));
  fl_value_append_take(event, fl_value_new_int(info.id));
  fl_value_append_take(event, fl_value_new_int(ts));
  fl_value_append_take(event, fl_value_new_bool(TRUE));
  fl_value_append_take(event, fl_value_new_string(info.name.c_str()));
  fl_value_append_take(event, fl_value_new_int(info.vendor_id));
  fl_value_append_take(event, fl_value_new_int(info.product_id));

  {
    std::lock_guard<std::mutex> lock(mutex_);
    devices_[path_str] = std::move(info);
  }

  ForwardEvent(event);
  fl_value_unref(event);
  return true;
}

void EvdevManager::RemoveDevice(const char* path) {
  DeviceInfo info;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = devices_.find(path);
    if (it == devices_.end()) return;
    info = std::move(it->second);
    devices_.erase(it);
  }

  if (info.io_source) {
    g_source_destroy(info.io_source);
    g_source_unref(info.io_source);
  }
  libevdev_free(info.evdev);
  close(info.fd);

  int64_t ts = NowMillis();
  // Wire format: [0, gamepadId, timestamp, connected, name, vendorId, productId]
  FlValue* event = fl_value_new_list();
  fl_value_append_take(event, fl_value_new_int(0));
  fl_value_append_take(event, fl_value_new_int(info.id));
  fl_value_append_take(event, fl_value_new_int(ts));
  fl_value_append_take(event, fl_value_new_bool(FALSE));
  fl_value_append_take(event, fl_value_new_string(info.name.c_str()));
  fl_value_append_take(event, fl_value_new_int(info.vendor_id));
  fl_value_append_take(event, fl_value_new_int(info.product_id));

  ForwardEvent(event);
  fl_value_unref(event);
}

void EvdevManager::ScheduleRemoveDevice(const std::string& path, bool rescan_after_removal) {
  if (!worker_context_) {
    RemoveDevice(path.c_str());
    return;
  }

  struct RemoveData {
    EvdevManager* self;
    std::string path;
    bool rescan_after_removal;
  };

  GSource* idle = g_idle_source_new();
  g_source_set_callback(
      idle,
      [](gpointer data) -> gboolean {
        auto* remove_data = static_cast<RemoveData*>(data);
        remove_data->self->RemoveDevice(remove_data->path.c_str());
        if (remove_data->rescan_after_removal) {
          remove_data->self->ScheduleScanRetry(kHotplugRetryAttempts);
        }
        delete remove_data;
        return G_SOURCE_REMOVE;
      },
      new RemoveData{this, path, rescan_after_removal}, nullptr);
  g_source_attach(idle, worker_context_);
  g_source_unref(idle);
}

void EvdevManager::ScheduleScanRetry(int attempts) {
  if (!worker_context_) return;
  if (scan_retry_attempts_left_ < attempts) {
    scan_retry_attempts_left_ = attempts;
  }
  if (scan_retry_source_) return;

  scan_retry_source_ = g_timeout_source_new(kHotplugRetryDelayMs);
  g_source_set_callback(
      scan_retry_source_,
      [](gpointer data) -> gboolean {
        auto* self = static_cast<EvdevManager*>(data);
        self->ScanDevices();

        if (--self->scan_retry_attempts_left_ <= 0) {
          GSource* source = self->scan_retry_source_;
          self->scan_retry_source_ = nullptr;
          self->scan_retry_attempts_left_ = 0;
          if (source) {
            g_source_unref(source);
          }
          return G_SOURCE_REMOVE;
        }

        return G_SOURCE_CONTINUE;
      },
      this, nullptr);
  g_source_attach(scan_retry_source_, worker_context_);
}

// ---------------------------------------------------------------------------
// Event reading (runs on worker thread, mutex held by caller)
// ---------------------------------------------------------------------------

void EvdevManager::OnInput(DeviceInfo& info, const std::string& path) {
  struct input_event ev;
  int rc;

  while ((rc = libevdev_next_event(info.evdev, LIBEVDEV_READ_FLAG_NORMAL, &ev)) == LIBEVDEV_READ_STATUS_SUCCESS) {
    if (ev.type == EV_KEY) {
      int w3c_index = ButtonMapping::EvdevButtonToW3C(ev.code, info.swap_north_west);
      if (w3c_index < 0) continue;

      bool pressed = ev.value != 0;
      int64_t ts = NowMillis();
      // Wire format: [1, gamepadId, timestamp, buttonIndex, pressed, value]
      FlValue* fe = fl_value_new_list();
      fl_value_append_take(fe, fl_value_new_int(1));
      fl_value_append_take(fe, fl_value_new_int(info.id));
      fl_value_append_take(fe, fl_value_new_int(ts));
      fl_value_append_take(fe, fl_value_new_int(w3c_index));
      fl_value_append_take(fe, fl_value_new_bool(pressed ? TRUE : FALSE));
      fl_value_append_take(fe, fl_value_new_float(pressed ? 1.0 : 0.0));
      ForwardEvent(fe);
      fl_value_unref(fe);

    } else if (ev.type == EV_ABS) {
      if (ButtonMapping::IsHatAxis(ev.code)) {
        int64_t ts = NowMillis();
        int gid = info.id;

        if (ev.code == ABS_HAT0X) {
          {
            // Wire format: [1, gamepadId, timestamp, buttonIndex, pressed, value]
            FlValue* fe = fl_value_new_list();
            fl_value_append_take(fe, fl_value_new_int(1));
            fl_value_append_take(fe, fl_value_new_int(gid));
            fl_value_append_take(fe, fl_value_new_int(ts));
            fl_value_append_take(fe, fl_value_new_int(ButtonMapping::kDpadLeft));
            bool pressed = ev.value < 0;
            fl_value_append_take(fe, fl_value_new_bool(pressed ? TRUE : FALSE));
            fl_value_append_take(fe, fl_value_new_float(pressed ? 1.0 : 0.0));
            ForwardEvent(fe);
            fl_value_unref(fe);
          }
          {
            FlValue* fe = fl_value_new_list();
            fl_value_append_take(fe, fl_value_new_int(1));
            fl_value_append_take(fe, fl_value_new_int(gid));
            fl_value_append_take(fe, fl_value_new_int(ts));
            fl_value_append_take(fe, fl_value_new_int(ButtonMapping::kDpadRight));
            bool pressed = ev.value > 0;
            fl_value_append_take(fe, fl_value_new_bool(pressed ? TRUE : FALSE));
            fl_value_append_take(fe, fl_value_new_float(pressed ? 1.0 : 0.0));
            ForwardEvent(fe);
            fl_value_unref(fe);
          }
        } else if (ev.code == ABS_HAT0Y) {
          {
            FlValue* fe = fl_value_new_list();
            fl_value_append_take(fe, fl_value_new_int(1));
            fl_value_append_take(fe, fl_value_new_int(gid));
            fl_value_append_take(fe, fl_value_new_int(ts));
            fl_value_append_take(fe, fl_value_new_int(ButtonMapping::kDpadUp));
            bool pressed = ev.value < 0;
            fl_value_append_take(fe, fl_value_new_bool(pressed ? TRUE : FALSE));
            fl_value_append_take(fe, fl_value_new_float(pressed ? 1.0 : 0.0));
            ForwardEvent(fe);
            fl_value_unref(fe);
          }
          {
            FlValue* fe = fl_value_new_list();
            fl_value_append_take(fe, fl_value_new_int(1));
            fl_value_append_take(fe, fl_value_new_int(gid));
            fl_value_append_take(fe, fl_value_new_int(ts));
            fl_value_append_take(fe, fl_value_new_int(ButtonMapping::kDpadDown));
            bool pressed = ev.value > 0;
            fl_value_append_take(fe, fl_value_new_bool(pressed ? TRUE : FALSE));
            fl_value_append_take(fe, fl_value_new_float(pressed ? 1.0 : 0.0));
            ForwardEvent(fe);
            fl_value_unref(fe);
          }
        }

      } else if (ButtonMapping::IsTriggerAxis(ev.code)) {
        int button_index = ButtonMapping::TriggerAxisToButtonIndex(ev.code);
        if (button_index < 0) continue;

        const struct input_absinfo& ai = info.abs_info[ev.code];
        double range = ai.maximum - ai.minimum;
        double value = (range != 0) ? static_cast<double>(ev.value - ai.minimum) / range : 0.0;

        // Throttle: skip if value hasn't changed meaningfully.
        int trigger_idx = (ev.code == ABS_Z) ? 0 : 1;
        if (!std::isnan(info.last_trigger[trigger_idx]) &&
            std::fabs(value - info.last_trigger[trigger_idx]) < kAxisEpsilon) {
          continue;
        }
        info.last_trigger[trigger_idx] = value;

        bool pressed = value > 0.5;
        int64_t ts = NowMillis();
        // Wire format: [1, gamepadId, timestamp, buttonIndex, pressed, value]
        FlValue* fe = fl_value_new_list();
        fl_value_append_take(fe, fl_value_new_int(1));
        fl_value_append_take(fe, fl_value_new_int(info.id));
        fl_value_append_take(fe, fl_value_new_int(ts));
        fl_value_append_take(fe, fl_value_new_int(button_index));
        fl_value_append_take(fe, fl_value_new_bool(pressed ? TRUE : FALSE));
        fl_value_append_take(fe, fl_value_new_float(value));
        ForwardEvent(fe);
        fl_value_unref(fe);

      } else {
        int w3c_index = ButtonMapping::EvdevAxisToW3C(ev.code);
        if (w3c_index < 0) continue;

        const struct input_absinfo& ai = info.abs_info[ev.code];
        double range = ai.maximum - ai.minimum;
        double value = (range != 0) ? 2.0 * (ev.value - ai.minimum) / range - 1.0 : 0.0;

        // Throttle: skip if value hasn't changed meaningfully.
        if (w3c_index < 4 && !std::isnan(info.last_axis[w3c_index]) &&
            std::fabs(value - info.last_axis[w3c_index]) < kAxisEpsilon) {
          continue;
        }
        if (w3c_index < 4) info.last_axis[w3c_index] = value;

        int64_t ts = NowMillis();
        // Wire format: [2, gamepadId, timestamp, axisIndex, value]
        FlValue* fe = fl_value_new_list();
        fl_value_append_take(fe, fl_value_new_int(2));
        fl_value_append_take(fe, fl_value_new_int(info.id));
        fl_value_append_take(fe, fl_value_new_int(ts));
        fl_value_append_take(fe, fl_value_new_int(w3c_index));
        fl_value_append_take(fe, fl_value_new_float(value));
        ForwardEvent(fe);
        fl_value_unref(fe);
      }
    }
  }

  // Handle SYN_DROPPED: re-sync the device.
  if (rc == LIBEVDEV_READ_STATUS_SYNC) {
    while ((rc = libevdev_next_event(info.evdev, LIBEVDEV_READ_FLAG_SYNC, &ev)) == LIBEVDEV_READ_STATUS_SYNC) {
      // Drain sync events.
    }
  }

  if (rc == -ENODEV || rc == -EIO) {
    g_debug("evdev: removing unavailable gamepad %s: %s", path.c_str(), g_strerror(-rc));
    ScheduleRemoveDevice(path);
  }
}

void EvdevManager::OnDirectoryChanged(
    GFileMonitor* monitor, GFile* file, GFile* other, GFileMonitorEvent event_type, gpointer user_data) {
  auto* self = static_cast<EvdevManager*>(user_data);

  g_autofree gchar* basename = g_file_get_basename(file);
  if (!IsEventNodeName(basename)) return;

  g_autofree gchar* path = g_file_get_path(file);
  if (!path) return;

  if (event_type == G_FILE_MONITOR_EVENT_CREATED || event_type == G_FILE_MONITOR_EVENT_ATTRIBUTE_CHANGED ||
      event_type == G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT) {
    if (!self->AddDevice(path)) {
      self->ScheduleScanRetry(kHotplugRetryAttempts);
    }
  } else if (event_type == G_FILE_MONITOR_EVENT_DELETED || event_type == G_FILE_MONITOR_EVENT_UNMOUNTED) {
    self->RemoveDevice(path);
    self->ScheduleScanRetry(kHotplugRetryAttempts);
  }
}
