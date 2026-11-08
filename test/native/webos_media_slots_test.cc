#include <cassert>

#include "../../shared/webos/ndl_media_slots.h"

int main() {
  int owners[5] = {};
  int* slots[5] = {};
  for (int i = 1; i < 5; ++i) {
    assert(pleazyng::webos::AcquireVideoSlot(slots, &owners[i]) == i);
  }
  assert(slots[pleazyng::webos::kAudioSlot] == nullptr);
  assert(pleazyng::webos::AcquireVideoSlot(slots, &owners[0]) == -1);
  slots[2] = nullptr;
  assert(pleazyng::webos::AcquireVideoSlot(slots, &owners[0]) == 2);
  assert(slots[2] == &owners[0]);
}
