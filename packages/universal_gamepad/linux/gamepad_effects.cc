// SPDX-License-Identifier: MIT
#include "gamepad_effects.h"

#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>

namespace {
std::string Parent(const std::string& path) {
  const auto name = path.substr(path.rfind('/') + 1);
  char resolved[PATH_MAX]{};
  return realpath(("/sys/class/input/" + name + "/device/..").c_str(), resolved) ? resolved : "";
}
bool Bit(const unsigned long* bits, unsigned bit) {
  return (bits[bit / (8 * sizeof(unsigned long))] & (1ul << (bit % (8 * sizeof(unsigned long))))) != 0;
}
constexpr unsigned axes[] = {ABS_RX, ABS_RY, ABS_RZ, ABS_X, ABS_Y, ABS_Z};
}  // namespace
LinuxGamepadEffects::LinuxGamepadEffects(const std::string& path, int inputFd) : path_(path) {
  struct stat original {
  }, opened{};
  if (fstat(inputFd, &original) != 0 || ioctl(inputFd, EVIOCGID, &identity_) != 0) return;
  int fd = open(path.c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) return;
  unsigned long feedback[FF_MAX / (8 * sizeof(unsigned long)) + 1]{};
  if (fstat(fd, &opened) != 0 || !S_ISCHR(opened.st_mode) || opened.st_dev != original.st_dev ||
      opened.st_ino != original.st_ino || opened.st_rdev != original.st_rdev ||
      ioctl(fd, EVIOCGBIT(EV_FF, sizeof(feedback)), feedback) < 0 || !Bit(feedback, FF_RUMBLE)) {
    close(fd);
    return;
  }
  feedbackFd_ = fd;
  capabilities_ = 1;
}
LinuxGamepadEffects::~LinuxGamepadEffects() {
  Rumble(0, 0, 0);
  if (feedbackFd_ >= 0) {
    if (effectId_ >= 0) ioctl(feedbackFd_, EVIOCRMFF, effectId_);
    close(feedbackFd_);
  }
  CloseSensor();
}
void LinuxGamepadEffects::Rumble(unsigned low, unsigned high, unsigned milliseconds) {
  if (feedbackFd_ < 0 || low > 65535 || high > 65535 || milliseconds > 1000) return;
  if (!milliseconds || (!low && !high)) {
    if (effectId_ >= 0) {
      input_event stop{};
      stop.type = EV_FF;
      stop.code = static_cast<uint16_t>(effectId_);
      (void)write(feedbackFd_, &stop, sizeof(stop));
    }
    return;
  }
  ff_effect effect{};
  effect.type = FF_RUMBLE;
  effect.id = static_cast<int16_t>(effectId_);
  effect.u.rumble.strong_magnitude = static_cast<uint16_t>(low);
  effect.u.rumble.weak_magnitude = static_cast<uint16_t>(high);
  effect.replay.length = static_cast<uint16_t>(milliseconds);
  if (ioctl(feedbackFd_, EVIOCSFF, &effect) < 0) return;
  effectId_ = effect.id;
  input_event play{};
  play.type = EV_FF;
  play.code = static_cast<uint16_t>(effectId_);
  play.value = 1;
  (void)write(feedbackFd_, &play, sizeof(play));
}
void LinuxGamepadEffects::CloseSensor() {
  enabled_ = false;
  if (sensorFd_ >= 0) close(sensorFd_);
  sensorFd_ = -1;
  lastSensorNs_ = 0;
  resolutions_.fill(0);
  capabilities_ &= 3;
}
void LinuxGamepadEffects::Sensors(bool enabled) {
  if (!enabled) {
    CloseSensor();
    return;
  }
  if (enabled_) return;
  const std::string parent = Parent(path_);
  if (parent.empty()) return;
  DIR* directory = opendir("/dev/input");
  if (!directory) return;
  unsigned visited = 0;
  while (dirent* entry = readdir(directory)) {
    if (++visited > 256) break;
    const std::string name = entry->d_name;
    if (name.size() <= 5 || name.size() > 15 || name.compare(0, 5, "event") ||
        name.find_first_not_of("0123456789", 5) != std::string::npos)
      continue;
    const std::string candidate = "/dev/input/" + name;
    if (candidate == path_ || Parent(candidate) != parent) continue;
    int fd = open(candidate.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) continue;
    input_id identity{};
    struct stat node {};
    unsigned long props[INPUT_PROP_MAX / (8 * sizeof(unsigned long)) + 1]{};
    int clock = CLOCK_MONOTONIC;
    bool valid = fstat(fd, &node) == 0 && S_ISCHR(node.st_mode) && ioctl(fd, EVIOCGID, &identity) == 0 &&
                 identity.bustype == identity_.bustype && identity.vendor == identity_.vendor &&
                 identity.product == identity_.product && ioctl(fd, EVIOCGPROP(sizeof(props)), props) >= 0 &&
                 Bit(props, INPUT_PROP_ACCELEROMETER) && ioctl(fd, EVIOCSCLOCKID, &clock) == 0;
    std::array<int, 6> resolution{};
    if (valid)
      for (size_t i = 0; i < 6; ++i) {
        input_absinfo info{};
        if (ioctl(fd, EVIOCGABS(axes[i]), &info) == 0 && info.resolution > 0) resolution[i] = info.resolution;
      }
    unsigned caps = 0;
    if (resolution[0] && resolution[1] && resolution[2]) caps |= 4;
    if (resolution[3] && resolution[4] && resolution[5]) caps |= 8;
    if (!valid || !caps) {
      close(fd);
      continue;
    }
    resolutions_ = resolution;
    sensorFd_ = fd;
    capabilities_ |= caps;
    enabled_ = true;
    break;
  }
  closedir(directory);
}
std::array<double, 7> LinuxGamepadEffects::State() {
  std::array<double, 7> result{};
  result[0] = capabilities_;
  if (!enabled_ || sensorFd_ < 0) return result;
  input_event events[64]{};
  for (unsigned batch = 0; batch < 4; ++batch) {
    ssize_t bytes = read(sensorFd_, events, sizeof(events));
    if (bytes < 0 && errno == EAGAIN) break;
    if (bytes <= 0 || bytes % sizeof(input_event)) {
      CloseSensor();
      return {};
    }
    for (size_t i = 0; i < size_t(bytes) / sizeof(input_event); ++i) {
      if (events[i].type == EV_SYN && events[i].code == SYN_REPORT && events[i].input_event_sec >= 0)
        lastSensorNs_ = uint64_t(events[i].input_event_sec) * 1000000000 + uint64_t(events[i].input_event_usec) * 1000;
    }
  }
  timespec now{};
  clock_gettime(CLOCK_MONOTONIC, &now);
  const uint64_t ns = uint64_t(now.tv_sec) * 1000000000 + uint64_t(now.tv_nsec);
  if (!lastSensorNs_ || lastSensorNs_ > ns || ns - lastSensorNs_ > 250000000) return result;
  for (size_t i = 0; i < 6; ++i) {
    input_absinfo info{};
    if (!resolutions_[i] || ioctl(sensorFd_, EVIOCGABS(axes[i]), &info) < 0) continue;
    // INPUT_PROP_ACCELEROMETER changes the kernel ABI units to g and deg/s.
    result[i + 1] = double(info.value) / resolutions_[i] * (i < 3 ? 0.017453292519943295 : 9.80665);
  }
  return result;
}
