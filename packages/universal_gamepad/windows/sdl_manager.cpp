#include "sdl_manager.h"

#include <chrono>
#include <cmath>
#include <limits>
#include <regex>

#include "gamepad_stream_handler.h"

namespace gamepad {

// Polling interval: ~60 Hz => ~16 ms.
static constexpr auto kPollInterval = std::chrono::milliseconds(16);

SdlManager::SdlManager(std::shared_ptr<GamepadStreamHandler> stream_handler)
    : stream_handler_(std::move(stream_handler)) {}

SdlManager::~SdlManager() { StopPolling(); }

void SdlManager::ClearEffectsLocked() {
  for (auto& entry : gamepads_) {
    auto& info = entry.second;
    SDL_RumbleGamepad(info.gamepad, 0, 0, 0);
    SDL_RumbleGamepadTriggers(info.gamepad, 0, 0, 0);
    if (SDL_GamepadHasSensor(info.gamepad, SDL_SENSOR_GYRO))
      SDL_SetGamepadSensorEnabled(info.gamepad, SDL_SENSOR_GYRO, false);
    if (SDL_GamepadHasSensor(info.gamepad, SDL_SENSOR_ACCEL))
      SDL_SetGamepadSensorEnabled(info.gamepad, SDL_SENSOR_ACCEL, false);
    info.sensors = false;
    info.motion.fill(0);
    info.motionTimestamp.fill(0);
  }
  effectsOwner_.clear();
}
void SdlManager::StopEffects() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  ClearEffectsLocked();
}
bool SdlManager::ClaimEffects(const std::string& token) {
  if (!std::regex_match(token, std::regex("[0-9a-f]{32}-[0-9]{1,10}-[0-9]{1,10}"))) return false;
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (!running_ || paused_) return false;
  if (effectsOwner_ != token) {
    ClearEffectsLocked();
    effectsOwner_ = token;
  }
  return true;
}
void SdlManager::ReleaseEffects(const std::string& token) {
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (effectsOwner_ == token) ClearEffectsLocked();
}
bool SdlManager::ApplyEffects(
    const std::string& token, int id, int flags, const std::array<int, 6>& values, bool sensors) {
  if (id < 0 || flags < 0 || flags > 7) return false;
  for (size_t i = 0; i < values.size(); ++i)
    if (values[i] < 0 || values[i] > (i % 3 == 2 ? 1000 : 65535)) return false;
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (effectsOwner_.empty() || effectsOwner_ != token || paused_) return false;
  auto found = gamepads_.find(static_cast<SDL_JoystickID>(id));
  if (found == gamepads_.end()) return false;
  auto& info = found->second;
  const auto props = SDL_GetGamepadProperties(info.gamepad);
  bool ok = true;
  if ((flags & 1) && SDL_GetBooleanProperty(props, SDL_PROP_GAMEPAD_CAP_RUMBLE_BOOLEAN, false))
    ok &= SDL_RumbleGamepad(
        info.gamepad, static_cast<Uint16>(values[0]), static_cast<Uint16>(values[1]), static_cast<Uint32>(values[2]));
  if ((flags & 2) && SDL_GetBooleanProperty(props, SDL_PROP_GAMEPAD_CAP_TRIGGER_RUMBLE_BOOLEAN, false))
    ok &= SDL_RumbleGamepadTriggers(
        info.gamepad, static_cast<Uint16>(values[3]), static_cast<Uint16>(values[4]), static_cast<Uint32>(values[5]));
  if (flags & 4) {
    info.motion.fill(0);
    info.motionTimestamp.fill(0);
    bool any = false;
    for (auto sensor : {SDL_SENSOR_GYRO, SDL_SENSOR_ACCEL})
      if (SDL_GamepadHasSensor(info.gamepad, sensor)) any |= SDL_SetGamepadSensorEnabled(info.gamepad, sensor, sensors);
    info.sensors = sensors && any;
  }
  return ok;
}
flutter::EncodableList SdlManager::EffectsState(const std::string& token, int id) {
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (effectsOwner_.empty() || effectsOwner_ != token || id < 0 || paused_) return {};
  auto found = gamepads_.find(static_cast<SDL_JoystickID>(id));
  if (found == gamepads_.end()) return {};
  auto& info = found->second;
  const auto props = SDL_GetGamepadProperties(info.gamepad);
  int caps = SDL_GetBooleanProperty(props, SDL_PROP_GAMEPAD_CAP_RUMBLE_BOOLEAN, false) ? 1 : 0;
  if (SDL_GetBooleanProperty(props, SDL_PROP_GAMEPAD_CAP_TRIGGER_RUMBLE_BOOLEAN, false)) caps |= 2;
  if (SDL_GamepadHasSensor(info.gamepad, SDL_SENSOR_GYRO)) caps |= 4;
  if (SDL_GamepadHasSensor(info.gamepad, SDL_SENSOR_ACCEL)) caps |= 8;
  flutter::EncodableList result{flutter::EncodableValue(double(caps))};
  const Uint64 now = SDL_GetTicksNS();
  for (size_t i = 0; i < 6; ++i) {
    const auto time = info.motionTimestamp[i / 3];
    result.emplace_back(info.sensors && time && time <= now && now - time < 250000000 ? info.motion[i] : 0.0);
  }
  return result;
}

void SdlManager::StartPolling() {
  if (running_.load()) return;
  running_.store(true);
  poll_thread_ = std::thread(&SdlManager::PollLoop, this);
}

void SdlManager::StopPolling() {
  StopEffects();
  running_.store(false);
  pause_cv_.notify_one();
  if (poll_thread_.joinable()) {
    poll_thread_.join();
  }
}

void SdlManager::Pause() {
  StopEffects();
  paused_.store(true);
}

void SdlManager::Resume() {
  paused_.store(false);
  pause_cv_.notify_one();
}

void SdlManager::CloseAllGamepads() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  ClearEffectsLocked();
  for (auto& [id, info] : gamepads_) {
    flutter::EncodableList event;
    event.push_back(flutter::EncodableValue(0));
    event.push_back(flutter::EncodableValue(static_cast<int32_t>(id)));
    event.push_back(flutter::EncodableValue(CurrentTimestamp()));
    event.push_back(flutter::EncodableValue(false));
    event.push_back(flutter::EncodableValue(info.name));
    event.push_back(flutter::EncodableValue(static_cast<int32_t>(info.vendor_id)));
    event.push_back(flutter::EncodableValue(static_cast<int32_t>(info.product_id)));
    stream_handler_->SendEvent(flutter::EncodableValue(event));
    if (info.gamepad) SDL_CloseGamepad(info.gamepad);
  }
  gamepads_.clear();
}

flutter::EncodableList SdlManager::ListGamepads() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  flutter::EncodableList result;

  for (const auto& [id, info] : gamepads_) {
    flutter::EncodableMap map;
    map[flutter::EncodableValue("id")] = flutter::EncodableValue(static_cast<int32_t>(id));
    map[flutter::EncodableValue("name")] = flutter::EncodableValue(info.name);
    map[flutter::EncodableValue("vendorId")] = flutter::EncodableValue(static_cast<int32_t>(info.vendor_id));
    map[flutter::EncodableValue("productId")] = flutter::EncodableValue(static_cast<int32_t>(info.product_id));
    result.push_back(flutter::EncodableValue(map));
  }
  return result;
}

void SdlManager::PollLoop() {
  if (!SDL_Init(SDL_INIT_GAMEPAD)) {
    // SDL_Init failed; cannot poll gamepads.
    running_.store(false);
    return;
  }

  while (running_.load()) {
    if (paused_.load()) {
      CloseAllGamepads();
      // Drain stale events
      SDL_Event discard;
      while (SDL_PollEvent(&discard)) {
      }
      // Sleep until resumed or stopped
      {
        std::unique_lock<std::mutex> lock(pause_mutex_);
        pause_cv_.wait(lock, [this] { return !paused_.load() || !running_.load(); });
      }
      // Drain again after wake
      while (SDL_PollEvent(&discard)) {
      }
      // Closing our handles doesn't make SDL re-emit ADDED events for
      // devices that stayed attached, so re-enumerate to re-open and
      // re-announce them (also covers devices attached while paused,
      // whose ADDED events were just drained).
      if (running_.load() && !paused_.load()) {
        RescanGamepads();
      }
      continue;
    }
    PollEvents();
    std::this_thread::sleep_for(kPollInterval);
  }

  // Cleanup: close all gamepads and quit the subsystem.
  CloseAllGamepads();

  SDL_QuitSubSystem(SDL_INIT_GAMEPAD);
}

void SdlManager::PollEvents() {
  SDL_Event event;
  while (SDL_PollEvent(&event)) {
    switch (event.type) {
      case SDL_EVENT_GAMEPAD_ADDED:
        HandleGamepadAdded(event.gdevice.which);
        break;
      case SDL_EVENT_GAMEPAD_REMOVED:
        HandleGamepadRemoved(event.gdevice.which);
        break;
      case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
        HandleButtonEvent(event.gbutton.which, event.gbutton.button, true);
        break;
      case SDL_EVENT_GAMEPAD_BUTTON_UP:
        HandleButtonEvent(event.gbutton.which, event.gbutton.button, false);
        break;
      case SDL_EVENT_GAMEPAD_SENSOR_UPDATE: {
        std::lock_guard<std::mutex> lock(state_mutex_);
        auto found = gamepads_.find(event.gsensor.which);
        if (found == gamepads_.end() || !found->second.sensors) break;
        int offset = event.gsensor.sensor == SDL_SENSOR_GYRO ? 0 : event.gsensor.sensor == SDL_SENSOR_ACCEL ? 3 : -1;
        if (offset < 0) break;
        bool valid = true;
        for (float value : event.gsensor.data) valid &= std::isfinite(value);
        if (!valid) break;
        for (int i = 0; i < 3; ++i) found->second.motion[offset + i] = event.gsensor.data[i];
        found->second.motionTimestamp[offset / 3] = event.gsensor.timestamp;
        break;
      }
      case SDL_EVENT_GAMEPAD_AXIS_MOTION:
        HandleAxisEvent(event.gaxis.which, event.gaxis.axis, event.gaxis.value);
        break;
      default:
        break;
    }
  }
}

void SdlManager::RescanGamepads() {
  int count = 0;
  SDL_JoystickID* ids = SDL_GetGamepads(&count);
  if (!ids) return;
  for (int i = 0; i < count; i++) {
    bool known;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      known = gamepads_.find(ids[i]) != gamepads_.end();
    }
    if (!known) {
      HandleGamepadAdded(ids[i]);
    }
  }
  SDL_free(ids);
}

void SdlManager::HandleGamepadAdded(SDL_JoystickID joystick_id) {
  SDL_Gamepad* gamepad = SDL_OpenGamepad(joystick_id);
  if (!gamepad) {
    return;
  }

  const char* name = SDL_GetGamepadName(gamepad);
  uint16_t vendor = SDL_GetGamepadVendor(gamepad);
  uint16_t product = SDL_GetGamepadProduct(gamepad);

  GamepadInfo info;
  info.joystick_id = joystick_id;
  info.gamepad = gamepad;
  info.name = name ? name : "Unknown Gamepad";
  info.vendor_id = vendor;
  info.product_id = product;
  for (int i = 0; i < 4; i++) info.last_axis[i] = std::numeric_limits<double>::quiet_NaN();
  for (int i = 0; i < 2; i++) info.last_trigger[i] = std::numeric_limits<double>::quiet_NaN();

  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    gamepads_[joystick_id] = info;
  }

  // Wire format: [0, gamepadId, timestamp, connected, name, vendorId, productId]
  flutter::EncodableList event;
  event.push_back(flutter::EncodableValue(0));
  event.push_back(flutter::EncodableValue(static_cast<int32_t>(joystick_id)));
  event.push_back(flutter::EncodableValue(CurrentTimestamp()));
  event.push_back(flutter::EncodableValue(true));
  event.push_back(flutter::EncodableValue(info.name));
  event.push_back(flutter::EncodableValue(static_cast<int32_t>(info.vendor_id)));
  event.push_back(flutter::EncodableValue(static_cast<int32_t>(info.product_id)));

  stream_handler_->SendEvent(flutter::EncodableValue(event));
}

void SdlManager::HandleGamepadRemoved(SDL_JoystickID joystick_id) {
  GamepadInfo info;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    auto it = gamepads_.find(joystick_id);
    if (it == gamepads_.end()) {
      return;
    }
    info = it->second;
    if (info.gamepad) {
      SDL_CloseGamepad(info.gamepad);
    }
    gamepads_.erase(it);
  }

  // Wire format: [0, gamepadId, timestamp, connected, name, vendorId, productId]
  flutter::EncodableList event;
  event.push_back(flutter::EncodableValue(0));
  event.push_back(flutter::EncodableValue(static_cast<int32_t>(joystick_id)));
  event.push_back(flutter::EncodableValue(CurrentTimestamp()));
  event.push_back(flutter::EncodableValue(false));
  event.push_back(flutter::EncodableValue(info.name));
  event.push_back(flutter::EncodableValue(static_cast<int32_t>(info.vendor_id)));
  event.push_back(flutter::EncodableValue(static_cast<int32_t>(info.product_id)));

  stream_handler_->SendEvent(flutter::EncodableValue(event));
}

void SdlManager::HandleButtonEvent(SDL_JoystickID joystick_id, uint8_t button, bool pressed) {
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (gamepads_.find(joystick_id) == gamepads_.end()) {
      return;
    }
  }

  int w3c_index = SdlButtonToW3C(static_cast<SDL_GamepadButton>(button));
  if (w3c_index < 0) {
    return;
  }

  // Wire format: [1, gamepadId, timestamp, buttonIndex, pressed, value]
  flutter::EncodableList event;
  event.push_back(flutter::EncodableValue(1));
  event.push_back(flutter::EncodableValue(static_cast<int32_t>(joystick_id)));
  event.push_back(flutter::EncodableValue(CurrentTimestamp()));
  event.push_back(flutter::EncodableValue(static_cast<int32_t>(w3c_index)));
  event.push_back(flutter::EncodableValue(pressed));
  event.push_back(flutter::EncodableValue(pressed ? 1.0 : 0.0));

  stream_handler_->SendEvent(flutter::EncodableValue(event));
}

void SdlManager::HandleAxisEvent(SDL_JoystickID joystick_id, uint8_t axis, int16_t value) {
  auto sdl_axis = static_cast<SDL_GamepadAxis>(axis);

  // Look up the device info so we can access last_axis/last_trigger.
  // Holding this pointer after unlocking is safe only because gamepads_ is
  // inserted/erased exclusively on this poll thread; other threads (e.g.
  // ListGamepads) only read under the lock. Revisit if that ever changes.
  GamepadInfo* info_ptr = nullptr;
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    auto it = gamepads_.find(joystick_id);
    if (it == gamepads_.end()) return;
    info_ptr = &it->second;
  }

  // Trigger axes map to analog buttons, not stick axes.
  if (IsTriggerAxis(sdl_axis)) {
    int button_index = TriggerAxisToButtonIndex(sdl_axis);
    if (button_index < 0) {
      return;
    }

    int trigger_idx = (sdl_axis == SDL_GAMEPAD_AXIS_LEFT_TRIGGER) ? 0 : 1;
    double normalized = NormalizeTriggerAxis(value);

    if (!std::isnan(info_ptr->last_trigger[trigger_idx]) &&
        std::abs(normalized - info_ptr->last_trigger[trigger_idx]) < kAxisEpsilon) {
      return;
    }
    info_ptr->last_trigger[trigger_idx] = normalized;

    bool pressed = normalized > 0.5;

    // Wire format: [1, gamepadId, timestamp, buttonIndex, pressed, value]
    flutter::EncodableList event;
    event.push_back(flutter::EncodableValue(1));
    event.push_back(flutter::EncodableValue(static_cast<int32_t>(joystick_id)));
    event.push_back(flutter::EncodableValue(CurrentTimestamp()));
    event.push_back(flutter::EncodableValue(static_cast<int32_t>(button_index)));
    event.push_back(flutter::EncodableValue(pressed));
    event.push_back(flutter::EncodableValue(normalized));

    stream_handler_->SendEvent(flutter::EncodableValue(event));
    return;
  }

  // Regular stick axis.
  int w3c_index = SdlAxisToW3C(sdl_axis);
  if (w3c_index < 0) {
    return;
  }

  double normalized = NormalizeStickAxis(value);

  if (!std::isnan(info_ptr->last_axis[w3c_index]) &&
      std::abs(normalized - info_ptr->last_axis[w3c_index]) < kAxisEpsilon) {
    return;
  }
  info_ptr->last_axis[w3c_index] = normalized;

  // Wire format: [2, gamepadId, timestamp, axisIndex, value]
  flutter::EncodableList event;
  event.push_back(flutter::EncodableValue(2));
  event.push_back(flutter::EncodableValue(static_cast<int32_t>(joystick_id)));
  event.push_back(flutter::EncodableValue(CurrentTimestamp()));
  event.push_back(flutter::EncodableValue(static_cast<int32_t>(w3c_index)));
  event.push_back(flutter::EncodableValue(normalized));

  stream_handler_->SendEvent(flutter::EncodableValue(event));
}

int64_t SdlManager::CurrentTimestamp() {
  auto now = std::chrono::system_clock::now();
  auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();
  return static_cast<int64_t>(ms);
}

}  // namespace gamepad
