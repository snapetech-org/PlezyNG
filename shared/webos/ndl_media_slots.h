#ifndef PLEAZYNG_WEBOS_NDL_MEDIA_SLOTS_H_
#define PLEAZYNG_WEBOS_NDL_MEDIA_SLOTS_H_

#include <cstddef>

namespace pleazyng::webos {

// NDL's slots belong to the process, across both Flutter plugins. UI/music
// audio keeps slot 0 alive, including between sounds. Video must never replace
// that slot's window binding or event subscription.
inline constexpr int kAudioSlot = 0;

template <typename Owner, std::size_t N>
int AcquireVideoSlot(Owner* (&slots)[N], Owner* owner) {
  static_assert(N > 1, "NDL needs a separate video slot");
  for (std::size_t slot = kAudioSlot + 1; slot < N; ++slot) {
    if (slots[slot] == nullptr) {
      slots[slot] = owner;
      return static_cast<int>(slot);
    }
  }
  return -1;
}

}  // namespace pleazyng::webos

#endif  // PLEAZYNG_WEBOS_NDL_MEDIA_SLOTS_H_
