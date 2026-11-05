// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <string>

namespace plezy::steam {
// Standard UTF-8 only: reject NUL, malformed/overlong sequences, surrogates,
// escape/control injection and payloads exceeding one bounded text operation.
inline bool validInputText(const std::string& text) {
  if (text.empty() || text.size() > 512) return false;
  for (size_t i = 0; i < text.size();) {
    const uint8_t first = uint8_t(text[i++]);
    if (first < 0x80) {
      if ((first < 32 && first != 9 && first != 10 && first != 13) || first == 127) return false;
      continue;
    }
    unsigned continuation;
    uint32_t point, minimum;
    if (first >= 0xc2 && first <= 0xdf) {
      continuation = 1;
      point = first & 31;
      minimum = 0x80;
    } else if (first >= 0xe0 && first <= 0xef) {
      continuation = 2;
      point = first & 15;
      minimum = 0x800;
    } else if (first >= 0xf0 && first <= 0xf4) {
      continuation = 3;
      point = first & 7;
      minimum = 0x10000;
    } else
      return false;
    if (text.size() - i < continuation) return false;
    while (continuation--) {
      const uint8_t next = uint8_t(text[i++]);
      if ((next & 0xc0) != 0x80) return false;
      point = (point << 6) | (next & 63);
    }
    if (point < minimum || point > 0x10ffff || (point >= 0xd800 && point <= 0xdfff) || (point >= 0x80 && point <= 0x9f))
      return false;
  }
  return true;
}
}  // namespace plezy::steam
